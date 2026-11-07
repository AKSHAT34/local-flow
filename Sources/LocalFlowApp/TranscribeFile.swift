import AVFoundation
import AppKit
import Foundation
import LocalFlowCore

/// `--transcribe-file <path> [--out <path>]` launch mode.
///
/// Runs a local audio file through the same UtteranceSegmenter + SegmentTranscriber
/// pipeline as live dictation (fast, not realtime), writes the joined raw and cleaned
/// transcript to --out, logs per-segment lines and peak footprint, then terminates.
/// Must run inside the app bundle so speech permission is attributed to LocalFlow.
@MainActor
final class TranscribeFileDelegate: NSObject, NSApplicationDelegate {
    private let inputPath: String
    private let outputPath: String

    init(inputPath: String, outputPath: String) {
        self.inputPath = inputPath
        self.outputPath = outputPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await run() }
    }

    private func run() async {
        defer { NSApp.terminate(nil) }
        let startedAt = Date()
        LocalFlowLog.write("transcribe-file: input=\(inputPath) out=\(outputPath)")
        do {
            guard await Permissions.requestSpeechRecognition() else {
                throw LocalFlowError.permissionDenied("Speech recognition")
            }

            let settings = Settings()
            let store = try? HistoryStore()
            var dictionary: [String: String] = [:]
            var snippets: [String: String] = [:]
            if let store {
                dictionary = (try? await store.loadDictionary()) ?? [:]
                snippets = (try? await store.loadSnippets()) ?? [:]
            }

            let engines = ASREngineProvider()
            let kind = settings.asrEngine
            let hints = ASRHints(vocabulary: Array(dictionary.keys) + Array(snippets.keys))
            let worker = SegmentTranscriber(engines: engines, kind: kind, hints: hints)
            worker.setProgressHandler { remaining in
                LocalFlowLog.write("transcribe-file: \(remaining) segment(s) left")
            }
            let segmenter = UtteranceSegmenter()

            try await engines.ensurePrepared(kind: kind) { fraction, name in
                LocalFlowLog.write("transcribe-file prepare [\(kind.rawValue)]: \(name) \(Int(fraction * 100))%")
            }

            var reader = try AudioFileReader(url: URL(fileURLWithPath: inputPath))
            LocalFlowLog.write("transcribe-file: reader opened")
            var fedSamples = 0
            var queuedSegments = 0
            var chunks = 0
            while let chunk = try reader.readChunk() {
                chunks += 1
                fedSamples += chunk.count
                let output = segmenter.feed(chunk)
                for segment in output.segments {
                    queuedSegments += 1
                    worker.submit(segment)
                }
            }
            LocalFlowLog.write("transcribe-file: read \(chunks) chunks")
            if let tail = try reader.finish() {
                fedSamples += tail.count
                let output = segmenter.feed(tail)
                for segment in output.segments {
                    queuedSegments += 1
                    worker.submit(segment)
                }
            }
            let flushed = segmenter.flush()
            for segment in flushed.segments {
                queuedSegments += 1
                worker.submit(segment)
            }
            LocalFlowLog.write("transcribe-file: fed \(fedSamples) samples (\(String(format: "%.1f", Double(fedSamples) / AudioCapture.outputSampleRate))s), \(queuedSegments) segments")
            let fedMB = MemoryProbe.currentMB()

            await worker.waitForIdle()
            LocalFlowLog.write("transcribe-file: worker idle")
            let parts = await worker.results()
            let raw = parts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            let context = CleanupContext(dictionary: dictionary, snippets: snippets)
            let cleaned = await CleanupPipeline().clean(
                raw: raw,
                context: context,
                mode: settings.cleanupMode,
                externalCommand: settings.externalLLMCommand
            )

            let elapsed = Date().timeIntervalSince(startedAt)
            let endMB = MemoryProbe.currentMB()
            let peakMB = [fedMB, endMB].compactMap { $0 }.max().map { String(format: "%.1f", $0) } ?? "?"
            let report = """
            input: \(inputPath)
            segments: \(queuedSegments)
            elapsed: \(String(format: "%.1f", elapsed))s
            peakFootprintMB: \(peakMB)

            --- RAW TRANSCRIPT ---
            \(raw)

            --- CLEANED ---
            \(cleaned.text)
            """
            try report.write(toFile: outputPath, atomically: true, encoding: .utf8)
            LocalFlowLog.write("transcribe-file: done segments=\(queuedSegments) parts=\(parts.count) elapsed=\(String(format: "%.1f", elapsed))s peakMB=\(peakMB) out=\(outputPath)")
        } catch {
            let nsError = error as NSError
            LocalFlowLog.write("transcribe-file failed: \(error.localizedDescription) [\(nsError.domain) \(nsError.code)]")
            try? "ERROR: \(error.localizedDescription)\n".write(toFile: outputPath, atomically: true, encoding: .utf8)
        }
    }
}

/// Reads an audio file and yields 16 kHz mono Float32 chunks via AVAudioConverter.
struct AudioFileReader {
    private let file: AVAudioFile
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputEnded = false

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.outputSampleRate,
            channels: AudioCapture.outputChannels,
            interleaved: false
        ) else {
            throw LocalFlowError.audioUnavailable("cannot create 16 kHz output format")
        }
        outputFormat = format
    }

    /// Next chunk of 16 kHz samples, or nil at end of file.
    /// (`AVAudioFile.read` throws a generic ObjC error at EOF instead of returning 0
    /// frames, so the position is checked before every read.)
    mutating func readChunk() throws -> [Float]? {
        if inputEnded || file.framePosition >= file.length {
            inputEnded = true
            return nil
        }
        let inputFormat = file.processingFormat
        let capacity = AVAudioFrameCount(16384)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: capacity) else {
            throw LocalFlowError.audioUnavailable("cannot allocate input buffer")
        }
        try file.read(into: inputBuffer)
        guard inputBuffer.frameLength > 0 else {
            inputEnded = true
            return nil
        }
        return try convert(inputBuffer)
    }

    /// Drains the converter's resampler tail after EOF.
    mutating func finish() throws -> [Float]? {
        guard let converter else { return nil }
        var samples: [Float] = []
        var conversionError: NSError?
        for _ in 0..<16 {
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8192) else { break }
            let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if out.frameLength > 0, let data = out.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            }
            if status == .endOfStream || status == .error || conversionError != nil { break }
        }
        return samples.isEmpty ? nil : samples
    }

    private mutating func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
        if input.format.sampleRate == AudioCapture.outputSampleRate,
           input.format.channelCount == AudioCapture.outputChannels,
           input.format.commonFormat == .pcmFormatFloat32,
           !input.format.isInterleaved {
            guard let data = input.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: data, count: Int(input.frameLength)))
        }
        if converter == nil {
            guard let conv = AVAudioConverter(from: input.format, to: outputFormat) else {
                throw LocalFlowError.audioUnavailable("cannot convert \(input.format.sampleRate) Hz audio")
            }
            converter = conv
        }
        guard let converter else { return [] }

        let ratio = AudioCapture.outputSampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(max(4096, Int(Double(input.frameLength) * ratio) + 4096))
        var samples: [Float] = []
        var conversionError: NSError?
        var gaveInput = false

        for _ in 0..<8 {
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { break }
            let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
                if !gaveInput {
                    gaveInput = true
                    outStatus.pointee = .haveData
                    return input
                }
                outStatus.pointee = .noDataNow
                return nil
            }
            if out.frameLength > 0, let data = out.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            }
            if status != .haveData || conversionError != nil { break }
        }
        return samples
    }
}
