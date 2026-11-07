import FluidAudio
import Foundation
import os

/// Which capture stream a segment came from.
public enum MeetingStream: Sendable {
    case me
    case them
}

/// A speech segment queued for meeting transcription, with its stream-relative
/// start offset in 16 kHz samples.
public struct PendingMeetingSegment: Sendable {
    public var stream: MeetingStream
    public var startSample: Int
    public var samples: [Float]

    public init(stream: MeetingStream, startSample: Int, samples: [Float]) {
        self.stream = stream
        self.startSample = startSample
        self.samples = samples
    }

    public var startSeconds: TimeInterval { TimeInterval(startSample) / AudioCapture.outputSampleRate }
    public var durationSeconds: TimeInterval { TimeInterval(samples.count) / AudioCapture.outputSampleRate }
}

/// Serial worker for meeting transcription. "Me" segments go straight to ASR;
/// "Them" segments are diarized first (one `DiarizerManager` for the whole meeting
/// so speaker identities persist across calls — `speakerManager` is instance state
/// that `performCompleteDiarization` never resets), then each merged turn is
/// transcribed and labeled "Speaker N" by first appearance. Lines are emitted via
/// `onLine` as `MeetingLine`s.
public actor MeetingWorker {
    private struct QueueState {
        var items: [PendingMeetingSegment] = []
        var draining = false
        var queuedAudioSeconds: Double = 0
    }

    private let engines: ASREngineProvider
    private let kind: ASREngineKind
    private let hints: ASRHints
    private let dictionary: [String: String]
    private let onLine: @Sendable (MeetingLine) -> Void
    private let pending = OSAllocatedUnfairLock(initialState: QueueState())

    private var namer = MeetingSpeakerNamer()
    private var diarizer: DiarizerManager?
    private var diarizerDisabled = false
    private var diarizerFailureLogged = false
    private var backlogWarned = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private let cleaner = RuleCleaner()
    private let diarizerConfig = DiarizerConfig(minSpeechDuration: 0.4)

    /// Turns shorter than this are merged into a neighbor before transcription.
    private static let minTurnSeconds: TimeInterval = 0.4

    public init(
        engines: ASREngineProvider,
        kind: ASREngineKind,
        hints: ASRHints = ASRHints(),
        dictionary: [String: String] = [:],
        onLine: @escaping @Sendable (MeetingLine) -> Void
    ) {
        self.engines = engines
        self.kind = kind
        self.hints = hints
        self.dictionary = dictionary
        self.onLine = onLine
    }

    /// Warms the ASR engine and downloads/loads diarizer models up front so the
    /// first meeting segment does not stall on a multi-hundred-MB model fetch.
    public func prepare(progress: (@Sendable (Double, String) -> Void)? = nil) async throws {
        try await engines.ensurePrepared(kind: kind, progress: progress)
        _ = try await ensureDiarizer()
    }

    /// Ordered enqueue; safe to call from the realtime audio thread.
    public nonisolated func submit(_ segment: PendingMeetingSegment) {
        guard !segment.samples.isEmpty else { return }
        let shouldDrain = pending.withLock { s -> Bool in
            s.items.append(segment)
            s.queuedAudioSeconds += segment.durationSeconds
            if s.draining { return false }
            s.draining = true
            return true
        }
        if shouldDrain { Task { await self.drain() } }
    }

    /// Suspends until every submitted segment has been processed. Actor-isolated so
    /// the idle check and waiter registration are atomic with respect to `drain`.
    public func waitForIdle() async {
        let idle = pending.withLock { !$0.draining && $0.items.isEmpty }
        if idle { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    // MARK: - Drain

    private func drain() async {
        while true {
            enum Step {
                case item(PendingMeetingSegment)
                case done
            }
            let step = pending.withLock { s -> Step in
                if !s.items.isEmpty { return .item(s.items.removeFirst()) }
                s.draining = false
                return .done
            }
            guard case .item(let item) = step else { break }
            await processItem(item)
            let backlog = pending.withLock { $0.queuedAudioSeconds }
            if backlog > 60, !backlogWarned {
                backlogWarned = true
                LocalFlowLog.write("meeting: transcription backlog \(String(format: "%.0f", backlog))s of audio")
            } else if backlog < 30 {
                backlogWarned = false
            }
        }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func processItem(_ item: PendingMeetingSegment) async {
        defer {
            pending.withLock { $0.queuedAudioSeconds = max(0, $0.queuedAudioSeconds - item.durationSeconds) }
        }
        switch item.stream {
        case .me:
            await processMe(item)
        case .them:
            await processThem(item)
        }
    }

    // MARK: - Me

    private func processMe(_ item: PendingMeetingSegment) async {
        do {
            let text = try await transcribe(item.samples)
            guard !text.isEmpty else { return }
            onLine(MeetingLine(start: item.startSeconds, speaker: "Me", text: text))
            LocalFlowLog.write("meeting line [Me @\(String(format: "%.1f", item.startSeconds))s]: \(text.prefix(80))")
        } catch {
            LocalFlowLog.write("meeting: Me segment failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Them (diarized)

    private struct Turn {
        var speakerID: String
        var start: TimeInterval
        var end: TimeInterval
    }

    private func processThem(_ item: PendingMeetingSegment) async {
        let segStart = item.startSeconds
        do {
            let manager = try await ensureDiarizer()
            let result = try manager.performCompleteDiarization(
                item.samples, sampleRate: Int(AudioCapture.outputSampleRate), atTime: segStart)
            let turns = Self.mergeTurns(result.segments.map {
                Turn(speakerID: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds))
            })
            guard !turns.isEmpty else {
                // Diarizer heard no speech structure — transcribe whole segment as Them.
                let text = try await transcribe(item.samples)
                if !text.isEmpty {
                    onLine(MeetingLine(start: segStart, speaker: "Them", text: text))
                }
                return
            }
            for turn in turns {
                let slice = Self.audioSlice(
                    item.samples,
                    from: max(0, turn.start - segStart),
                    to: min(item.durationSeconds, turn.end - segStart))
                guard slice.count > 1600 else { continue }  // > 0.1 s at 16 kHz
                let label = namer.label(for: turn.speakerID)
                do {
                    let text = try await transcribe(slice)
                    guard !text.isEmpty else { continue }
                    onLine(MeetingLine(start: turn.start, speaker: label, text: text))
                    LocalFlowLog.write("meeting line [\(label) @\(String(format: "%.1f", turn.start))s]: \(text.prefix(80))")
                } catch {
                    LocalFlowLog.write("meeting: Them turn transcription failed: \(error.localizedDescription)")
                }
            }
        } catch {
            if !diarizerFailureLogged {
                diarizerFailureLogged = true
                LocalFlowLog.write("meeting: diarization unavailable, falling back to Them: \(error.localizedDescription)")
            }
            do {
                let text = try await transcribe(item.samples)
                if !text.isEmpty {
                    onLine(MeetingLine(start: segStart, speaker: "Them", text: text))
                }
            } catch {
                LocalFlowLog.write("meeting: Them fallback transcription failed: \(error.localizedDescription)")
            }
        }
    }

    /// Coalesces adjacent same-speaker turns, then merges turns shorter than
    /// `minTurnSeconds` into a neighbor (previous preferred, else next).
    private static func mergeTurns(_ input: [Turn]) -> [Turn] {
        let sorted = input.sorted { $0.start < $1.start }
        var coalesced: [Turn] = []
        for turn in sorted {
            if let last = coalesced.last, last.speakerID == turn.speakerID {
                coalesced[coalesced.count - 1].end = max(last.end, turn.end)
            } else {
                coalesced.append(turn)
            }
        }

        var merged: [Turn] = []
        var leadingShorts: [Turn] = []
        for turn in coalesced {
            if turn.end - turn.start < minTurnSeconds {
                if !merged.isEmpty {
                    merged[merged.count - 1].end = max(merged[merged.count - 1].end, turn.end)
                } else {
                    leadingShorts.append(turn)
                }
            } else {
                var t = turn
                for short in leadingShorts { t.start = min(t.start, short.start) }
                leadingShorts.removeAll()
                merged.append(t)
            }
        }
        if !leadingShorts.isEmpty {
            if let lastIndex = merged.indices.last {
                merged[lastIndex].end = max(merged[lastIndex].end, leadingShorts.map(\.end).max() ?? 0)
            } else {
                merged = leadingShorts
            }
        }
        return merged
    }

    /// Slices `samples` (16 kHz mono) to the [from, to) second range, clamped.
    private static func audioSlice(_ samples: [Float], from start: TimeInterval, to end: TimeInterval) -> [Float] {
        let rate = AudioCapture.outputSampleRate
        let lo = max(0, min(samples.count, Int(start * rate)))
        let hi = max(lo, min(samples.count, Int(end * rate)))
        guard hi > lo else { return [] }
        return Array(samples[lo..<hi])
    }

    // MARK: - ASR + diarizer

    private func transcribe(_ samples: [Float]) async throws -> String {
        try await engines.ensurePrepared(kind: kind)
        let engine = await engines.engine(for: kind)
        let transcript = try await engine.transcribe(samples: samples, hints: hints)
        let context = CleanupContext(style: .formal, dictionary: dictionary)
        return cleaner.clean(transcript.text, context: context)
    }

    private func ensureDiarizer() async throws -> DiarizerManager {
        if let diarizer { return diarizer }
        if diarizerDisabled { throw LocalFlowError.asrUnavailable("speaker diarization unavailable") }
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager(config: diarizerConfig)
            manager.initialize(models: models)
            diarizer = manager
            LocalFlowLog.write("meeting: diarizer models ready")
            return manager
        } catch {
            diarizerDisabled = true
            throw error
        }
    }
}

/// Live meeting capture: microphone ("Me") + system audio ("Them"), each through
/// its own UtteranceSegmenter, feeding a shared MeetingWorker.
public final class MeetingRecorder: Sendable {
    private struct State {
        var worker: MeetingWorker?
        var running = false
        var meFedSamples = 0
        var themFedSamples = 0
    }

    private let mic = AudioCapture()
    private let system = SystemAudioCapture()
    private let meSegmenter = UtteranceSegmenter()
    private let themSegmenter = UtteranceSegmenter()
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Seconds of audio fed so far on the longer stream — the meeting clock used
    /// for transcript flush watermarking.
    public var elapsedSeconds: Double {
        state.withLock { s in
            Double(max(s.meFedSamples, s.themFedSamples)) / AudioCapture.outputSampleRate
        }
    }

    public func start(
        worker: MeetingWorker,
        meLevel: @escaping @Sendable (Float) -> Void,
        themLevel: @escaping @Sendable (Float) -> Void
    ) async throws {
        let shouldStart = state.withLock { s -> Bool in
            guard !s.running else { return false }
            s.running = true
            s.worker = worker
            s.meFedSamples = 0
            s.themFedSamples = 0
            return true
        }
        guard shouldStart else { return }
        meSegmenter.reset()
        themSegmenter.reset()

        do {
            try mic.start(
                chunkHandler: { [weak self] samples in self?.ingest(.me, samples) },
                levelHandler: meLevel
            )
        } catch {
            state.withLock { $0.running = false; $0.worker = nil }
            throw error
        }
        do {
            try await system.start(
                chunkHandler: { [weak self] samples in self?.ingest(.them, samples) },
                levelHandler: themLevel
            )
        } catch {
            _ = mic.stop()
            state.withLock { s in
                s.running = false
                s.worker = nil
                s.meFedSamples = 0
                s.themFedSamples = 0
            }
            meSegmenter.reset()
            themSegmenter.reset()
            throw error
        }
    }

    /// Stops both captures and submits the flushed remainders to the worker.
    public func stop() async {
        let meTail = mic.stop()
        let themTail = await system.stop()

        let (meFeed, meFlush, themFeed, themFlush, worker) = state.withLock { s -> (
            SegmenterOutput, SegmenterOutput, SegmenterOutput, SegmenterOutput, MeetingWorker?
        ) in
            let meFeed = meSegmenter.feed(meTail)
            let meFlush = meSegmenter.flush()
            let themFeed = themSegmenter.feed(themTail)
            let themFlush = themSegmenter.flush()
            let worker = s.worker
            s.running = false
            s.worker = nil
            return (meFeed, meFlush, themFeed, themFlush, worker)
        }

        submit(worker: worker, stream: .me, outputs: [meFeed, meFlush])
        submit(worker: worker, stream: .them, outputs: [themFeed, themFlush])
    }

    /// Feeds one converted 16 kHz chunk into the right stream's segmenter and
    /// submits any completed segments. Called on the audio capture threads.
    private func ingest(_ stream: MeetingStream, _ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let (output, worker) = state.withLock { s -> (SegmenterOutput, MeetingWorker?) in
            switch stream {
            case .me:
                s.meFedSamples += samples.count
                return (meSegmenter.feed(samples), s.worker)
            case .them:
                s.themFedSamples += samples.count
                return (themSegmenter.feed(samples), s.worker)
            }
        }
        guard let worker else { return }
        for (index, segment) in output.segments.enumerated() {
            let start = index < output.segmentStarts.count ? output.segmentStarts[index] : 0
            worker.submit(PendingMeetingSegment(stream: stream, startSample: start, samples: segment))
        }
    }

    private func submit(worker: MeetingWorker?, stream: MeetingStream, outputs: [SegmenterOutput]) {
        guard let worker else { return }
        for output in outputs {
            for (index, segment) in output.segments.enumerated() {
                let start = index < output.segmentStarts.count ? output.segmentStarts[index] : 0
                worker.submit(PendingMeetingSegment(stream: stream, startSample: start, samples: segment))
            }
        }
    }
}
