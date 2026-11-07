import Foundation
import os

/// Result of feeding audio to the segmenter: speech-bearing segments ready for ASR
/// plus a count of samples discarded inside all-silence segments.
public struct SegmenterOutput: Sendable {
    public var segments: [[Float]]
    /// Absolute 16 kHz sample index of each segment's first sample within the stream
    /// fed to this segmenter (parallel to `segments`; resets on `reset()`).
    public var segmentStarts: [Int]
    public var droppedSamples: Int

    public init(segments: [[Float]] = [], segmentStarts: [Int] = [], droppedSamples: Int = 0) {
        self.segments = segments
        self.segmentStarts = segmentStarts
        self.droppedSamples = droppedSamples
    }
}

/// Splits a 16 kHz mono stream into utterance-sized segments for transcription.
///
/// Frames are 30 ms. Speech is detected against an adaptive noise floor (slow-tracking
/// 10th percentile of recent frame RMS; threshold = max(0.004, floor * 3)). A segment is
/// emitted after >= 700 ms of silence following >= 1.0 s of speech, or force-cut at 25 s
/// at the lowest-energy frame in the trailing 3 s. ~150 ms of padding is kept at cut
/// edges and segments form a contiguous partition of the input — no samples are lost.
///
/// Thread-safe and synchronous so it can run on the realtime audio thread; all mutable
/// state lives behind a lock.
public struct UtteranceSegmenter: Sendable {
    public static let frameSize = 480           // 30 ms at 16 kHz
    public static let padSamples = 2400         // 150 ms
    public static let padFrames = 5
    public static let silenceFramesToCut = 24   // >= 720 ms
    public static let minSpeechFrames = 34      // >= 1.02 s
    public static let maxSegmentSamples = 400_000  // 25 s at 16 kHz
    public static let forcedCutWindowFrames = 100  // last 3 s
    public static let floorWindowFrames = 266   // ~8 s

    private struct State {
        var pending: [Float] = []
        var segSamples: [Float] = []
        var frameRMS: [Float] = []
        var frameSpeech: [Bool] = []
        var speechFrames = 0
        var silenceRun = 0
        var lastSpeechEndSamples = 0
        var floorWindow: [Float] = []
        var emittedSamples = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Feed 16 kHz mono samples; returns any segments completed by this chunk.
    public func feed(_ samples: [Float]) -> SegmenterOutput {
        guard !samples.isEmpty else { return SegmenterOutput() }
        return state.withLock { s in
            var output = SegmenterOutput()
            s.pending.append(contentsOf: samples)
            while s.pending.count >= Self.frameSize {
                let frame = Array(s.pending.prefix(Self.frameSize))
                s.pending.removeFirst(Self.frameSize)
                processFrame(frame, into: &s, output: &output)
            }
            return output
        }
    }

    /// End of stream: emit the remainder (if it contains speech) and reset.
    public func flush() -> SegmenterOutput {
        state.withLock { s in
            s.segSamples.append(contentsOf: s.pending)
            s.pending.removeAll(keepingCapacity: false)
            var output = SegmenterOutput()
            if s.speechFrames > 0 {
                output.segments.append(s.segSamples)
                output.segmentStarts.append(s.emittedSamples)
            } else {
                output.droppedSamples = s.segSamples.count
            }
            resetLocked(&s)
            return output
        }
    }

    /// Drop all buffered audio (cancel path).
    public func reset() {
        state.withLock { s in resetLocked(&s) }
    }

    private func resetLocked(_ s: inout State) {
        s.pending.removeAll(keepingCapacity: true)
        s.segSamples.removeAll(keepingCapacity: true)
        s.frameRMS.removeAll(keepingCapacity: true)
        s.frameSpeech.removeAll(keepingCapacity: true)
        s.speechFrames = 0
        s.silenceRun = 0
        s.lastSpeechEndSamples = 0
        s.floorWindow.removeAll(keepingCapacity: true)
        s.emittedSamples = 0
    }

    private func processFrame(_ frame: [Float], into s: inout State, output: inout SegmenterOutput) {
        var sum: Float = 0
        for sample in frame { sum += sample * sample }
        let rms = sqrt(sum / Float(frame.count))

        s.floorWindow.append(rms)
        if s.floorWindow.count > Self.floorWindowFrames {
            s.floorWindow.removeFirst(s.floorWindow.count - Self.floorWindowFrames)
        }
        let threshold = max(0.004, percentile10(s.floorWindow) * 3)
        let isSpeech = rms > threshold

        s.segSamples.append(contentsOf: frame)
        s.frameRMS.append(rms)
        s.frameSpeech.append(isSpeech)
        if isSpeech {
            s.speechFrames += 1
            s.silenceRun = 0
            s.lastSpeechEndSamples = s.segSamples.count
        } else {
            s.silenceRun += 1
        }

        // Silence cut: enough speech followed by a long pause.
        if s.speechFrames >= Self.minSpeechFrames,
           s.silenceRun >= Self.silenceFramesToCut {
            let cut = min(s.segSamples.count, s.lastSpeechEndSamples + Self.padSamples)
            emit(upTo: cut, into: &s, output: &output)
            return
        }

        // Forced cut at 25 s: lowest-energy frame in the trailing 3 s, emitted edge
        // padded 150 ms early so the next segment keeps pre-roll context.
        if s.segSamples.count >= Self.maxSegmentSamples {
            let windowStart = max(0, s.frameRMS.count - Self.forcedCutWindowFrames)
            var minIndex = windowStart
            for i in (windowStart + 1)..<s.frameRMS.count where s.frameRMS[i] < s.frameRMS[minIndex] {
                minIndex = i
            }
            let cutFrame = max(1, minIndex - Self.padFrames)
            let cut = min(s.segSamples.count, cutFrame * Self.frameSize)
            emit(upTo: cut, into: &s, output: &output)
        }
    }

    /// Emit segSamples[0..<cut] as a segment (or drop it if it has no speech) and
    /// carry the remainder into the next segment. `cut` is always frame-aligned.
    private func emit(upTo cut: Int, into s: inout State, output: inout SegmenterOutput) {
        guard cut > 0 else { return }
        let piece = Array(s.segSamples[0..<cut])
        let pieceStart = s.emittedSamples
        s.emittedSamples += cut
        if s.speechFrames > 0 {
            output.segments.append(piece)
            output.segmentStarts.append(pieceStart)
        } else {
            output.droppedSamples += piece.count
        }
        let cutFrames = cut / Self.frameSize
        s.segSamples.removeFirst(cut)
        s.frameRMS.removeFirst(min(cutFrames, s.frameRMS.count))
        s.frameSpeech.removeFirst(min(cutFrames, s.frameSpeech.count))
        recount(&s)
    }

    private func recount(_ s: inout State) {
        s.speechFrames = s.frameSpeech.reduce(0) { $0 + ($1 ? 1 : 0) }
        s.silenceRun = 0
        for flag in s.frameSpeech.reversed() {
            if flag { break }
            s.silenceRun += 1
        }
        s.lastSpeechEndSamples = 0
        for (index, flag) in s.frameSpeech.enumerated() where flag {
            s.lastSpeechEndSamples = (index + 1) * Self.frameSize
        }
    }

    private func percentile10(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * 0.1).rounded(.down))))
        return sorted[index]
    }
}

/// Serial worker that transcribes utterance segments one at a time, preserving order.
/// `submit` is synchronous and thread-safe so it can be called from the realtime audio
/// thread; ordering is guaranteed because submissions on a given thread are serialized
/// and the audio thread finishes before the main actor submits the stream tail.
public actor SegmentTranscriber {
    private struct PendingState {
        var queue: [[Float]] = []
        var draining = false
    }

    private let engines: ASREngineProvider
    private let kind: ASREngineKind
    private let hints: ASRHints
    private let pending = OSAllocatedUnfairLock(initialState: PendingState())
    private let progressHandler = OSAllocatedUnfairLock<(@Sendable (Int) -> Void)?>(initialState: nil)
    private var texts: [String] = []
    private var segmentIndex = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(engines: ASREngineProvider, kind: ASREngineKind, hints: ASRHints = ASRHints()) {
        self.engines = engines
        self.kind = kind
        self.hints = hints
    }

    /// Ordered enqueue; safe to call from any thread. Kicks the drain loop if idle.
    public nonisolated func submit(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let shouldDrain = pending.withLock { s -> Bool in
            s.queue.append(samples)
            if s.draining { return false }
            s.draining = true
            return true
        }
        if shouldDrain { Task { await self.drain() } }
    }

    /// Called with the number of segments still queued after each completion.
    public nonisolated func setProgressHandler(_ handler: (@Sendable (Int) -> Void)?) {
        progressHandler.withLock { $0 = handler }
    }

    private func drain() async {
        while true {
            enum Step {
                case item([Float])
                case done
            }
            // Atomically dequeue, or mark not-draining when the queue is empty —
            // a submit racing this point either lands in the queue (picked up next
            // iteration is impossible, so it must see draining == false and restart).
            let step = pending.withLock { s -> Step in
                if !s.queue.isEmpty { return .item(s.queue.removeFirst()) }
                s.draining = false
                return .done
            }
            guard case .item(let segment) = step else { break }

            let index = segmentIndex
            segmentIndex += 1
            let duration = Double(segment.count) / AudioCapture.outputSampleRate
            do {
                try await engines.ensurePrepared(kind: kind)
                let engine = await engines.engine(for: kind)
                let transcript = try await engine.transcribe(samples: segment, hints: hints)
                texts.append(transcript.text)
                LocalFlowLog.write("segment \(index) (\(String(format: "%.1f", duration))s): \(transcript.text)")
            } catch {
                texts.append("")
                LocalFlowLog.write("segment \(index) failed: \(error.localizedDescription)")
            }
            let remaining = pending.withLock { $0.queue.count }
            if let handler = progressHandler.withLock({ $0 }) {
                handler(remaining)
            }
        }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    public func pendingCount() -> Int { pending.withLock { $0.queue.count } }

    /// Suspends until every submitted segment has been transcribed.
    public func waitForIdle() async {
        let idle = pending.withLock { !$0.draining && $0.queue.isEmpty }
        if idle { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    /// Ordered transcript parts ("" for failed segments).
    public func results() -> [String] { texts }
}
