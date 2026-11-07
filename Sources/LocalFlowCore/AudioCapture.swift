import AVFoundation
import Foundation

/// Captures microphone audio and streams it as 16 kHz mono Float32 chunks.
///
/// The tap callback runs on a realtime audio thread, so all shared state is guarded by `lock`.
/// Conversion to 16 kHz happens incrementally inside the tap via a persistent
/// `AVAudioConverter`; raw native-rate buffers are never retained, so memory stays flat
/// for hour-long sessions. `stop()` returns only the small converter remainder.
public final class AudioCapture: @unchecked Sendable {
    public static let outputSampleRate: Double = 16_000
    public static let outputChannels: AVAudioChannelCount = 1

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var tapInstalled = false
    private var running = false
    private var finishing = false
    private var tailSamples: [Float] = []
    private var chunkHandler: (@Sendable ([Float]) -> Void)?
    private var levelHandler: (@Sendable (Float) -> Void)?

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    public init() {}

    public func start(chunkHandler: @escaping @Sendable ([Float]) -> Void, levelHandler: @escaping @Sendable (Float) -> Void) throws {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        converter = nil
        outputFormat = nil
        tailSamples.removeAll(keepingCapacity: true)
        self.chunkHandler = chunkHandler
        self.levelHandler = levelHandler
        running = true
        finishing = false
        lock.unlock()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            cleanupAfterFailedStart()
            throw LocalFlowError.audioUnavailable("input node has an invalid format")
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer)
        }
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            cleanupAfterFailedStart()
            throw LocalFlowError.audioUnavailable(error.localizedDescription)
        }
    }

    /// Stops capture and returns the remaining 16 kHz mono samples not yet delivered
    /// through the chunk handler (converter tail plus any straggler tap buffers).
    public func stop() -> [Float] {
        // Divert in-flight tap buffers into tailSamples, then stop the render thread.
        lock.lock()
        finishing = true
        lock.unlock()

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()

        // Give an already-dispatched tap callback a moment to finish converting.
        Thread.sleep(forTimeInterval: 0.003)

        lock.lock()
        running = false
        var remainder = tailSamples
        tailSamples.removeAll(keepingCapacity: false)
        remainder.append(contentsOf: flushConverterLocked())
        converter = nil
        outputFormat = nil
        chunkHandler = nil
        levelHandler = nil
        lock.unlock()
        return remainder
    }

    public func cancel() {
        _ = stop()
    }

    private func cleanupAfterFailedStart() {
        lock.lock()
        running = false
        finishing = false
        chunkHandler = nil
        levelHandler = nil
        converter = nil
        outputFormat = nil
        tailSamples.removeAll()
        lock.unlock()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    private func handleTap(buffer: AVAudioPCMBuffer) {
        guard let mono = downmixToMono(buffer) else { return }

        // Chunk delivery happens under `lock` so stop()'s critical section is strictly
        // ordered after every delivered chunk — the session can then flush the segmenter
        // without a chunk arriving late and being lost.
        var rms: Float = 0
        lock.lock()
        if running {
            let samples = convertStreamingLocked(mono)
            rms = rootMeanSquare(samples)
            if !samples.isEmpty { chunkHandler?(samples) }
        } else if finishing, converter != nil {
            let samples = convertStreamingLocked(mono)
            if !samples.isEmpty {
                tailSamples.append(contentsOf: samples)
                rms = rootMeanSquare(samples)
            }
        }
        let handler = levelHandler
        lock.unlock()

        handler?(rms)
    }

    /// Converts one mono native-rate buffer to 16 kHz, returning all produced samples.
    /// The persistent converter retains unconsumed input internally between calls.
    private func convertStreamingLocked(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if converter == nil {
            guard let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.outputSampleRate,
                channels: Self.outputChannels,
                interleaved: false
            ), let conv = AVAudioConverter(from: buffer.format, to: outFormat) else {
                return []
            }
            converter = conv
            outputFormat = outFormat
        }
        guard let converter, let outputFormat else { return [] }

        let ratio = Self.outputSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(max(2048, Int(Double(buffer.frameLength) * ratio) + 2048))
        var samples: [Float] = []
        var conversionError: NSError?
        var gaveInput = false

        for _ in 0..<8 {
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { break }
            let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
                if !gaveInput {
                    gaveInput = true
                    outStatus.pointee = .haveData
                    return buffer
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

    /// Drains the converter at end-of-stream; returns any remaining 16 kHz samples.
    private func flushConverterLocked() -> [Float] {
        guard let converter, let outputFormat else { return [] }
        var samples: [Float] = []
        var conversionError: NSError?

        for _ in 0..<32 {
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
        return samples
    }

    private func downmixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let sampleRate = buffer.format.sampleRate
        let channels = Int(buffer.format.channelCount)
        guard channels > 0, buffer.frameLength > 0 else { return nil }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else { return nil }
        output.frameLength = buffer.frameLength
        guard let dst = output.floatChannelData?[0] else { return nil }

        let frames = Int(buffer.frameLength)
        if !buffer.format.isInterleaved, let srcChannels = buffer.floatChannelData {
            if channels == 1 {
                memcpy(dst, srcChannels[0], frames * MemoryLayout<Float>.size)
            } else {
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        sum += srcChannels[channel][frame]
                    }
                    dst[frame] = sum / Float(channels)
                }
            }
        } else if let src = buffer.floatChannelData?[0] {
            // Interleaved fallback: stride by channel count.
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += src[frame * channels + channel]
                }
                dst[frame] = sum / Float(channels)
            }
        } else {
            return nil
        }

        return output
    }

    private func rootMeanSquare(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return sqrt(sum / Float(samples.count))
    }
}
