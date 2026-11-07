import AVFoundation
import AppKit
import Foundation
import LocalFlowCore
import os

/// `--transcribe-meeting <me.aiff> <them.aiff> [--out path]` launch mode.
///
/// Feeds two 16 kHz-converted audio files through the same downstream pipeline as
/// live meeting capture — per-stream UtteranceSegmenters → MeetingWorker (diarize
/// Them, transcribe, Speaker N labels) → MeetingLinePipeline (echo dedupe,
/// timestamp-ordered markdown) — then writes the .md transcript and exits.
/// Must run inside the app bundle so speech permission is attributed to LocalFlow.
@MainActor
final class TranscribeMeetingDelegate: NSObject, NSApplicationDelegate {
    private let mePath: String
    private let themPath: String
    private let outputPath: String

    init(mePath: String, themPath: String, outputPath: String) {
        self.mePath = mePath
        self.themPath = themPath
        self.outputPath = outputPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await run() }
    }

    private func run() async {
        defer { NSApp.terminate(nil) }
        let startedAt = Date()
        LocalFlowLog.write("transcribe-meeting: me=\(mePath) them=\(themPath) out=\(outputPath)")
        do {
            guard await Permissions.requestSpeechRecognition() else {
                throw LocalFlowError.permissionDenied("Speech recognition")
            }

            let settings = Settings()
            let store = try? HistoryStore()
            var dictionary: [String: String] = [:]
            if let store {
                dictionary = (try? await store.loadDictionary()) ?? [:]
            }

            let engines = ASREngineProvider()
            if settings.asrLocale != "en-US" {
                await engines.setSpeechLocale(settings.asrLocale)
            }
            let kind = settings.asrEngine
            let hints = ASRHints(vocabulary: Array(dictionary.keys))

            let writer = try MeetingTranscriptWriter(
                fileURL: URL(fileURLWithPath: outputPath),
                meetingStart: startedAt,
                appName: "Meeting (file)"
            )
            let pipeline = MeetingLinePipeline(writer: writer)

            // Collect lines thread-safely; appended to the pipeline on the main
            // actor once the worker is idle (deterministic order for the writer).
            let collected = OSAllocatedUnfairLock<[MeetingLine]>(initialState: [])
            let worker = MeetingWorker(engines: engines, kind: kind, hints: hints, dictionary: dictionary) { line in
                collected.withLock { $0.append(line) }
            }

            LocalFlowLog.write("transcribe-meeting: preparing engines + diarizer")
            try await worker.prepare { fraction, name in
                LocalFlowLog.write("transcribe-meeting prepare [\(kind.rawValue)]: \(name) \(Int(fraction * 100))%")
            }

            var meReader = try AudioFileReader(url: URL(fileURLWithPath: mePath))
            var themReader = try AudioFileReader(url: URL(fileURLWithPath: themPath))
            let meSegmenter = UtteranceSegmenter()
            let themSegmenter = UtteranceSegmenter()
            var meFed = 0
            var themFed = 0
            var meSegments = 0
            var themSegments = 0

            meFed = try feedFile(
                reader: &meReader, segmenter: meSegmenter, stream: .me,
                worker: worker, fed: meFed, segmentCount: &meSegments)
            themFed = try feedFile(
                reader: &themReader, segmenter: themSegmenter, stream: .them,
                worker: worker, fed: themFed, segmentCount: &themSegments)

            let maxSeconds = Double(max(meFed, themFed)) / AudioCapture.outputSampleRate
            LocalFlowLog.write("transcribe-meeting: fed me=\(meFed) them=\(themFed) samples (\(String(format: "%.1f", maxSeconds))s), segments me=\(meSegments) them=\(themSegments)")

            await worker.waitForIdle()
            LocalFlowLog.write("transcribe-meeting: worker idle")

            for line in collected.withLock({ $0 }) {
                pipeline.append(line)
            }
            pipeline.noteElapsed(maxSeconds)
            pipeline.flushReady()
            let url = try pipeline.finish(duration: maxSeconds)

            let elapsed = Date().timeIntervalSince(startedAt)
            let endMB = MemoryProbe.currentMB()
            LocalFlowLog.write(
                "transcribe-meeting: done lines=\(pipeline.lineCount) echoes=\(pipeline.droppedEchoCount) " +
                "elapsed=\(String(format: "%.1f", elapsed))s footprintMB=\(endMB.map { String(format: "%.1f", $0) } ?? "?") out=\(url.path)"
            )
        } catch {
            let nsError = error as NSError
            LocalFlowLog.write("transcribe-meeting failed: \(error.localizedDescription) [\(nsError.domain) \(nsError.code)]")
        }
    }

    /// Reads one file to EOF through the segmenter, submitting each emitted
    /// segment to the worker with its stream-relative start offset.
    /// Returns total 16 kHz samples fed.
    private func feedFile(
        reader: inout AudioFileReader,
        segmenter: UtteranceSegmenter,
        stream: MeetingStream,
        worker: MeetingWorker,
        fed: Int,
        segmentCount: inout Int
    ) throws -> Int {
        var total = fed
        func submit(_ output: SegmenterOutput) {
            for (index, segment) in output.segments.enumerated() {
                let start = index < output.segmentStarts.count ? output.segmentStarts[index] : 0
                segmentCount += 1
                worker.submit(PendingMeetingSegment(stream: stream, startSample: start, samples: segment))
            }
        }
        while let chunk = try reader.readChunk() {
            total += chunk.count
            submit(segmenter.feed(chunk))
        }
        if let tail = try reader.finish() {
            total += tail.count
            submit(segmenter.feed(tail))
        }
        submit(segmenter.flush())
        return total
    }
}
