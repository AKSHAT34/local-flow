import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures system audio (everything the Mac plays) via ScreenCaptureKit and streams
/// it as 16 kHz mono Float32 chunks — the "Them" side of a meeting.
///
/// Only an `.audio` stream output is registered; video is configured minimal
/// (2x2 px, 1 fps) so the screen pipeline stays cheap. `excludesCurrentProcessAudio`
/// keeps LocalFlow's own sounds out of the transcript. Requires Screen & System
/// Audio Recording permission (`CGPreflightScreenCaptureAccess`).
public final class SystemAudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    public static let outputSampleRate: Double = AudioCapture.outputSampleRate

    private let lock = NSLock()
    private let sampleQueue = DispatchQueue(label: "com.localflow.sck.audio")
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var running = false
    private var finishing = false
    private var tailSamples: [Float] = []
    private var chunkHandler: (@Sendable ([Float]) -> Void)?
    private var levelHandler: (@Sendable (Float) -> Void)?
    private var nativeSampleRate: Double = 48_000

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    public override init() {}

    public func start(chunkHandler: @escaping @Sendable ([Float]) -> Void, levelHandler: @escaping @Sendable (Float) -> Void) async throws {
        guard beginStart(chunkHandler: chunkHandler, levelHandler: levelHandler) else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                throw LocalFlowError.audioUnavailable("no display available for system audio capture")
            }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 1
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 3
            config.showsCursor = false

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            _ = try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
            markStreamStarted(stream)
            LocalFlowLog.write("system audio capture started (48 kHz -> 16 kHz)")
        } catch {
            cleanupAfterFailedStart()
            throw mapError(error)
        }
    }

    /// Stops the stream and returns remaining 16 kHz samples not yet delivered.
    public func stop() async -> [Float] {
        let stream = beginStop()

        if let stream {
            try? await stream.stopCapture()
            _ = try? stream.removeStreamOutput(self, type: .audio)
        }
        // Drain any in-flight sample callbacks, then collect the converter tail.
        sampleQueue.sync {}

        return finishStop()
    }

    public func cancel() async {
        _ = await stop()
    }

    // MARK: - Locked state transitions (sync helpers: NSLock is unavailable in async bodies)

    /// Returns false when already running.
    private func beginStart(chunkHandler: @escaping @Sendable ([Float]) -> Void, levelHandler: @escaping @Sendable (Float) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return false }
        converter = nil
        outputFormat = nil
        tailSamples.removeAll(keepingCapacity: true)
        self.chunkHandler = chunkHandler
        self.levelHandler = levelHandler
        running = true
        finishing = false
        return true
    }

    private func markStreamStarted(_ stream: SCStream) {
        lock.lock()
        self.stream = stream
        lock.unlock()
    }

    private func beginStop() -> SCStream? {
        lock.lock()
        defer { lock.unlock() }
        finishing = true
        let stream = self.stream
        self.stream = nil
        return stream
    }

    private func finishStop() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        running = false
        var remainder = tailSamples
        tailSamples.removeAll(keepingCapacity: false)
        remainder.append(contentsOf: flushConverterLocked())
        converter = nil
        outputFormat = nil
        chunkHandler = nil
        levelHandler = nil
        return remainder
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
    }

    private func mapError(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == "com.apple.ScreenCaptureKit.SCStreamError" || ns.domain.contains("ScreenCapture") {
            return LocalFlowError.permissionDenied("Screen & System Audio Recording")
        }
        return LocalFlowError.audioUnavailable(error.localizedDescription)
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let mono = samplesFromAudioBuffer(sampleBuffer) else { return }
        guard !mono.samples.isEmpty else { return }

        var rms: Float = 0
        var delivered: [Float] = []
        var level: (@Sendable (Float) -> Void)?
        var chunk: (@Sendable ([Float]) -> Void)?
        lock.lock()
        if running {
            let converted = convertStreamingLocked(mono.samples, inputRate: mono.sampleRate)
            rms = rootMeanSquare(converted)
            if !converted.isEmpty { delivered = converted }
        } else if finishing, converter != nil {
            let converted = convertStreamingLocked(mono.samples, inputRate: mono.sampleRate)
            if !converted.isEmpty {
                tailSamples.append(contentsOf: converted)
                rms = rootMeanSquare(converted)
            }
        }
        level = levelHandler
        chunk = chunkHandler
        lock.unlock()

        if !delivered.isEmpty { chunk?(delivered) }
        level?(rms)
    }

    /// Extracts mono Float32 samples + sample rate from an SCK audio sample buffer.
    private func samplesFromAudioBuffer(_ sampleBuffer: CMSampleBuffer) -> (samples: [Float], sampleRate: Double)? {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return nil }
        var blockBuffer: CMBlockBuffer?
        var listSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: nil
        )
        guard status == noErr, listSize > 0 else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        var sampleRate = nativeSampleRate
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
            sampleRate = asbd.pointee.mSampleRate
        }

        // mNumberBuffers buffers of Float32; non-interleaved => one buffer per channel.
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        var channelData: [[Float]] = []
        for buffer in buffers {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let floats = data.assumingMemoryBound(to: Float.self)
            channelData.append(Array(UnsafeBufferPointer(start: floats, count: count)))
        }
        guard let first = channelData.first else { return nil }

        let frames = first.count
        var mono = [Float](repeating: 0, count: frames)
        if channelData.count == 1 {
            mono = first
        } else {
            for channel in channelData {
                for i in 0..<min(frames, channel.count) { mono[i] += channel[i] }
            }
            let inv = 1 / Float(channelData.count)
            for i in 0..<frames { mono[i] *= inv }
        }
        return (mono, sampleRate)
    }

    // MARK: - Conversion (same incremental-converter pattern as AudioCapture)

    /// Caller must hold `lock`.
    private func convertStreamingLocked(_ samples: [Float], inputRate: Double) -> [Float] {
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputRate,
            channels: AudioCapture.outputChannels,
            interleaved: false
        ) else { return [] }
        guard samples.count <= Int(UInt32.max) else { return [] }
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        guard let dst = input.floatChannelData?[0] else { return [] }
        samples.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress { memcpy(dst, base, samples.count * MemoryLayout<Float>.size) }
        }

        if converter == nil {
            guard let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.outputSampleRate,
                channels: AudioCapture.outputChannels,
                interleaved: false
            ), let conv = AVAudioConverter(from: inputFormat, to: outFormat) else {
                return []
            }
            converter = conv
            outputFormat = outFormat
            nativeSampleRate = inputRate
        }
        guard let converter, let outputFormat else { return [] }

        let ratio = Self.outputSampleRate / inputRate
        let capacity = AVAudioFrameCount(max(2048, Int(Double(input.frameLength) * ratio) + 2048))
        var output: [Float] = []
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
                output.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            }
            if status != .haveData || conversionError != nil { break }
        }
        return output
    }

    /// Caller must hold `lock`.
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

    private func rootMeanSquare(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return sqrt(sum / Float(samples.count))
    }
}
