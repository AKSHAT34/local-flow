import Foundation
import LocalFlowCore

@main
enum ChecksMain {
    static func main() async throws {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }

        let cleaner = RuleCleaner()

        let fillers = cleaner.clean("um hello uh world world", context: CleanupContext())
        check(!fillers.lowercased().contains("um") && !fillers.lowercased().contains("uh"), "fillers stripped -> \(fillers)")
        check(fillers.lowercased().components(separatedBy: "world").count - 1 == 1, "repeat collapsed -> \(fillers)")

        let commands = cleaner.clean("hello comma world period", context: CleanupContext())
        check(commands.contains("Hello, world."), "commands + punctuation -> \(commands)")

        let backtrack = cleaner.clean("meet at 3, actually 4 pm", context: CleanupContext())
        check(backtrack.contains("4"), "backtrack -> \(backtrack)")

        let numbers = cleaner.clean("we grew twenty five percent", context: CleanupContext())
        check(numbers.contains("25%"), "number words -> \(numbers)")

        let snippetContext = CleanupContext(snippets: ["my email": "a@b.com"])
        check(cleaner.clean("my email", context: snippetContext) == "a@b.com", "snippet expansion")

        let literal = cleaner.clean("print hello world", context: CleanupContext(literalMode: true))
        check(literal == "print hello world", "literal mode -> \(literal)")

        let casual = cleaner.clean("hello world how are you", context: CleanupContext(style: .casual))
        check(casual == "Hello world how are you", "casual single sentence -> \(casual)")
        let casualMulti = cleaner.clean("hello world period how are you", context: CleanupContext(style: .casual))
        check(casualMulti.hasSuffix("."), "casual multi-sentence period -> \(casualMulti)")
        let veryCasual = cleaner.clean("hello world how are you", context: CleanupContext(style: .veryCasual))
        check(veryCasual == "hello world how are you", "very casual lowercases -> \(veryCasual)")
        let veryCasualPronoun = cleaner.clean("I think so", context: CleanupContext(style: .veryCasual))
        check(veryCasualPronoun.hasPrefix("I "), "very casual keeps I -> \(veryCasualPronoun)")
        let veryCasualAcronym = cleaner.clean("NASA launched today", context: CleanupContext(style: .veryCasual))
        check(veryCasualAcronym.hasPrefix("NASA"), "very casual keeps acronym -> \(veryCasualAcronym)")

        var samples = [Float](repeating: 0, count: 1600)
        for i in 0..<3200 { samples.append(sin(Float(i) * 0.1) * 0.2) }
        samples.append(contentsOf: [Float](repeating: 0, count: 1600))
        check(!VoiceActivity.trim(samples: samples).isEmpty, "VAD trims speech")
        check(VoiceActivity.trim(samples: [Float](repeating: 0, count: 16000)).isEmpty, "VAD silence")

        // MARK: - UtteranceSegmenter checks

        func segNoise(_ seconds: Double, rms: Float) -> [Float] {
            let count = Int(seconds * 16000)
            var state: UInt64 = 0x9E3779B97F4A7C15
            return (0..<count).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let u = Float((state >> 33) & 0xFFFFFF) / Float(0xFFFFFF) * 2 - 1
                return u * rms * Float(3).squareRoot()
            }
        }
        func segSine(_ seconds: Double, rms: Float, freq: Float = 220) -> [Float] {
            let amp = rms * Float(2).squareRoot()
            let count = Int(seconds * 16000)
            return (0..<count).map { sin(2 * .pi * freq * Float($0) / 16000) * amp }
        }
        func segSilence(_ seconds: Double) -> [Float] { segNoise(seconds, rms: 0.0005) }
        func segGated(_ seconds: Double) -> [Float] {
            let count = Int(seconds * 16000)
            return (0..<count).map { i in
                let t = Float(i) / 16000
                let gate = sin(2 * .pi * 3 * t) > 0 ? Float(1) : Float(0.05)
                return sin(2 * .pi * 220 * t) * 0.08 * gate
            }
        }
        func runSegmenter(_ input: [Float], chunkSize: Int = 4000) -> (segments: [[Float]], droppedSamples: Int) {
            let segmenter = UtteranceSegmenter()
            var segments: [[Float]] = []
            var dropped = 0
            var index = 0
            while index < input.count {
                let end = min(input.count, index + chunkSize)
                let out = segmenter.feed(Array(input[index..<end]))
                segments += out.segments
                dropped += out.droppedSamples
                index = end
            }
            let tail = segmenter.flush()
            segments += tail.segments
            dropped += tail.droppedSamples
            return (segments, dropped)
        }

        var burstInput: [Float] = []
        burstInput += segSilence(0.5)
        burstInput += segSine(2.0, rms: 0.08)
        burstInput += segSilence(1.0)
        burstInput += segSine(2.0, rms: 0.08)
        burstInput += segSilence(1.0)
        burstInput += segSine(2.0, rms: 0.08)
        burstInput += segSilence(0.5)
        let burst = runSegmenter(burstInput)
        let burstTotal = burst.segments.reduce(0) { $0 + $1.count } + burst.droppedSamples
        check(burst.segments.count == 3, "segmenter: 3 bursts -> \(burst.segments.count) segments")
        check(burstTotal == burstInput.count, "segmenter: burst samples accounted \(burstTotal)/\(burstInput.count)")

        let continuous = segGated(60)
        let cont = runSegmenter(continuous, chunkSize: 16000)
        let contTotal = cont.segments.reduce(0) { $0 + $1.count } + cont.droppedSamples
        let withinLimit = cont.segments.allSatisfy { Double($0.count) / 16000 <= 25.1 }
        check(cont.segments.count >= 2, "segmenter: 60s tone -> \(cont.segments.count) segments")
        check(withinLimit, "segmenter: 60s segments <= 25s")
        check(contTotal == continuous.count, "segmenter: 60s contiguous \(contTotal)/\(continuous.count)")

        let still = segSilence(10)
        let stillResult = runSegmenter(still)
        check(stillResult.segments.isEmpty, "segmenter: pure silence -> 0 segments")
        check(stillResult.droppedSamples == still.count, "segmenter: silence dropped \(stillResult.droppedSamples)/\(still.count)")

        var quietInput: [Float] = []
        quietInput += segNoise(0.5, rms: 0.001)
        quietInput += segSine(2.0, rms: 0.006, freq: 180)
        quietInput += segNoise(0.5, rms: 0.001)
        let quiet = runSegmenter(quietInput)
        check(!quiet.segments.isEmpty, "segmenter: quiet speech detected -> \(quiet.segments.count) segment(s)")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try HistoryStore(directory: dir)
        _ = try await store.insertHistory(HistoryEntry(
            appName: "Notes", bundleID: "com.apple.Notes", rawText: "um hi",
            cleanText: "Hi.", engine: "appleSpeech", cleanupMode: "rulesOnly", durationMilliseconds: 1000
        ))
        let history = try await store.recentHistory(limit: 5)
        check(history.count == 1 && history[0].cleanText == "Hi.", "history round-trip")

        try await store.upsertDictionary(VocabularyItem(term: "acme", replacement: "ACME"))
        check((try await store.loadDictionary())["acme"] == "ACME", "dictionary round-trip")

        try await store.upsertSnippet(VocabularyItem(term: "my email", replacement: "a@b.com"))
        check((try await store.loadSnippets())["my email"] == "a@b.com", "snippet round-trip")

        let pipeline = CleanupPipeline()
        let cleaned = await pipeline.clean(raw: "um hello world", context: CleanupContext(), mode: .rulesOnly, externalCommand: "")
        check(cleaned.text.contains("Hello"), "cleanup pipeline rules -> \(cleaned.text)")

        // MARK: Meeting checks

        var namer = MeetingSpeakerNamer()
        check(
            namer.label(for: "spkA") == "Speaker 1"
                && namer.label(for: "spkB") == "Speaker 2"
                && namer.label(for: "spkA") == "Speaker 1",
            "meeting: speaker id -> Speaker N mapping order"
        )

        var echo = MeetingEchoFilter()
        echo.addThemLine(MeetingLine(start: 10, speaker: "Speaker 1", text: "hello there friend"))
        check(echo.isEcho(MeetingLine(start: 12, speaker: "Me", text: "hello there friend")), "meeting: echo filter positive")
        check(!echo.isEcho(MeetingLine(start: 12, speaker: "Me", text: "completely different words here")), "meeting: echo filter negative")
        check(!echo.isEcho(MeetingLine(start: 30, speaker: "Me", text: "hello there friend")), "meeting: echo filter window")

        let meetingDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let meetingURL = meetingDir.appendingPathComponent("check.md")
        let meetingStart = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            try await MainActor.run {
                let writer = try MeetingTranscriptWriter(fileURL: meetingURL, meetingStart: meetingStart, appName: "Check")
                let meetingPipeline = MeetingLinePipeline(writer: writer)
                // Deliberately out of order; lines stay buffered until the meeting
                // clock passes them (30 s flush age), then flush sorted.
                meetingPipeline.append(MeetingLine(start: 9.0, speaker: "Speaker 1", text: "second part"))
                meetingPipeline.append(MeetingLine(start: 5.0, speaker: "Them", text: "the quick brown fox jumps"))
                meetingPipeline.append(MeetingLine(start: 5.5, speaker: "Me", text: "the quick brown fox jumps over"))
                meetingPipeline.append(MeetingLine(start: 6.0, speaker: "Me", text: "my own words entirely"))
                meetingPipeline.append(MeetingLine(start: 8.0, speaker: "Speaker 1", text: "first part"))
                meetingPipeline.noteElapsed(40)
                meetingPipeline.flushReady()
                _ = try meetingPipeline.finish(duration: 40)
            }
            let markdown = try String(contentsOf: meetingURL, encoding: .utf8)
            check(markdown.contains("first part second part"), "meeting: same-speaker lines merge -> \(markdown.suffix(200))")
            check(!markdown.contains("jumps over"), "meeting: echo line dropped")
            check(markdown.contains("my own words entirely"), "meeting: unique Me line kept")
            let themIdx = markdown.range(of: "**[")?.lowerBound
            let meIdx = markdown.range(of: "my own words")?.lowerBound
            let speakerIdx = markdown.range(of: "Speaker 1:**")?.lowerBound
            check(
                themIdx != nil && meIdx != nil && speakerIdx != nil
                    && themIdx! < meIdx! && meIdx! < speakerIdx!,
                "meeting: lines written in timestamp order"
            )
            check(markdown.contains("- Duration: 0:00:40"), "meeting: footer duration")
        } catch {
            check(false, "meeting pipeline threw: \(error.localizedDescription)")
        }

        if failures > 0 {
            print("\(failures) check(s) failed")
            throw NSError(domain: "LocalFlowChecks", code: 1)
        }
        print("ALL CHECKS PASSED")
    }
}
