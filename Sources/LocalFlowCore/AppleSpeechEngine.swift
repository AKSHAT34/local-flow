import AVFoundation
import Foundation
@preconcurrency import Speech
import os

/// Apple's on-device speech recognizer. Used as the zero-download fallback and for languages
/// Parakeet does not cover (for example Hindi/Hinglish).
///
/// With `shouldReportPartialResults` the recognizer resets `formattedString` at each new
/// utterance, so results are accumulated: `current` tracks the live partial and completed
/// utterances move into `committed` (on the macOS 11+ `speechRecognitionMetadata` end-of-
/// utterance marker, on `isFinal`, or defensively when the partial resets). The resolved
/// transcript is the join of all committed utterances — nothing is dropped on long audio.
public actor AppleSpeechEngine: ASREngine {
    public nonisolated let kind: ASREngineKind = .appleSpeech
    public nonisolated let displayName = ASREngineKind.appleSpeech.displayName

    private let locale: Locale
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?

    private struct Accumulation {
        var committed: [String] = []
        var current: String = ""
        var lastCommitted: String = ""
    }

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    public func isPrepared() async -> Bool { recognizer != nil }

    public func prepare(progress: (@Sendable (Double, String) -> Void)?) async throws {
        if recognizer != nil { return }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized else {
            throw LocalFlowError.permissionDenied("Speech recognition")
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw LocalFlowError.asrUnavailable("no recognizer for \(locale.identifier)")
        }
        if #available(macOS 10.15, *) {
            // Read before setting: the getter reports on-device capability. Never
            // fall back to network recognition — `requiresOnDeviceRecognition`
            // stays true on every request.
            let onDeviceSupported = recognizer.supportsOnDeviceRecognition
            recognizer.supportsOnDeviceRecognition = true
            guard onDeviceSupported else {
                throw LocalFlowError.asrUnavailable("On-device recognition not available for \(locale.identifier)")
            }
        }
        guard recognizer.isAvailable else {
            throw LocalFlowError.asrUnavailable("recognizer unavailable for \(locale.identifier)")
        }
        self.recognizer = recognizer
        progress?(1.0, "Apple Speech ready")
    }

    public func transcribe(samples: [Float], hints: ASRHints) async throws -> Transcript {
        guard let recognizer else { throw LocalFlowError.asrUnavailable("Apple Speech is not prepared") }
        guard !samples.isEmpty else { throw LocalFlowError.asrUnavailable("no audio samples") }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        if !hints.vocabulary.isEmpty {
            request.contextualStrings = hints.vocabulary
        }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.outputSampleRate,
            channels: AudioCapture.outputChannels,
            interleaved: false
        )!

        let localeID = locale.identifier
        let duration = TimeInterval(samples.count) / AudioCapture.outputSampleRate
        let timeoutSeconds = max(15.0, duration * 2)
        let accumulation = OSAllocatedUnfairLock(initialState: Accumulation())
        let finished = OSAllocatedUnfairLock(initialState: false)

        return try await withCheckedThrowingContinuation { continuation in
            let resumeOnce: @Sendable (Result<Transcript, Error>) -> Void = { result in
                let first = finished.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(with: result) }
            }
            let makeTranscript: @Sendable (String) -> Transcript = { text in
                Transcript(text: text, confidence: 0, language: localeID, duration: duration, processingTime: 0)
            }
            let accumulatedText: @Sendable (Accumulation) -> String = { state in
                var parts = state.committed
                let leftover = state.current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !leftover.isEmpty { parts.append(leftover) }
                return parts.joined(separator: " ")
            }

            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    let text = accumulation.withLock { accumulatedText($0) }
                    if text.isEmpty {
                        resumeOnce(.failure(LocalFlowError.asrUnavailable(error.localizedDescription)))
                    } else {
                        resumeOnce(.success(makeTranscript(text)))
                    }
                    return
                }
                guard let result else { return }
                accumulation.withLock { state in
                    Self.handleResult(result, into: &state)
                }
                if result.isFinal {
                    let text = accumulation.withLock { accumulatedText($0) }
                    resumeOnce(.success(makeTranscript(text)))
                }
            }

            // Safety net: never hang on a recognizer that stops producing results.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.cancelRecognitionTask()
                let text = accumulation.withLock { accumulatedText($0) }
                if text.isEmpty {
                    resumeOnce(.failure(LocalFlowError.asrUnavailable("speech recognition timed out")))
                } else {
                    resumeOnce(.success(makeTranscript(text)))
                }
            }

            let chunkSize = 4096
            var offset = 0
            while offset < samples.count {
                let count = min(chunkSize, samples.count - offset)
                if let buffer = Self.makeBuffer(samples: samples, offset: offset, count: count, format: format) {
                    request.append(buffer)
                }
                offset += count
            }
            request.endAudio()
        }
    }

    /// Folds one recognition result into the accumulation. Commits `current` when the
    /// result marks an utterance end (metadata on macOS 11+, or `isFinal`), and
    /// defensively when the partial text resets to a different utterance.
    private static func handleResult(_ result: SFSpeechRecognitionResult, into state: inout Accumulation) {
        let text = result.bestTranscription.formattedString

        if !state.current.isEmpty, Double(text.count) < Double(state.current.count) * 0.6 {
            let oldFirst = state.current.split(separator: " ").first.map(String.init) ?? ""
            let newFirst = text.split(separator: " ").first.map(String.init) ?? ""
            if !newFirst.isEmpty, newFirst != oldFirst {
                commit(state.current, into: &state)
            }
        }
        state.current = text

        if result.speechRecognitionMetadata != nil || result.isFinal {
            commit(state.current, into: &state)
            state.current = ""
        }
    }

    private static func commit(_ text: String, into state: inout Accumulation) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != state.lastCommitted else { return }
        if !state.committed.isEmpty, trimmed.hasPrefix(state.lastCommitted + " ") {
            // Same utterance still growing (metadata can arrive on partials): replace.
            state.committed[state.committed.count - 1] = trimmed
        } else {
            state.committed.append(trimmed)
        }
        state.lastCommitted = trimmed
        LocalFlowLog.write("asr utterance committed (\(state.committed.count)): \(trimmed.prefix(80))")
    }

    private func cancelRecognitionTask() {
        recognitionTask?.cancel()
    }

    public func unload() async {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognizer = nil
    }

    private static func makeBuffer(samples: [Float], offset: Int, count: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        guard let dst = buffer.floatChannelData?[0] else { return nil }
        for i in 0..<count {
            dst[i] = samples[offset + i]
        }
        return buffer
    }
}
