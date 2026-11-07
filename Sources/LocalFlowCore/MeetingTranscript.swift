import Foundation

/// Crash-safe markdown transcript writer for meetings.
///
/// The file is created at meeting start with a header; lines are appended in the
/// order the pipeline hands them over (already sorted and deduped). Consecutive
/// lines from the same speaker within 2 s merge into one paragraph — including
/// across calls, by appending to the last paragraph in place. No audio is stored.
public final class MeetingTranscriptWriter {
    /// `~/Documents/LocalFlow Meetings`
    public static func meetingsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("LocalFlow Meetings", isDirectory: true)
    }

    /// `YYYY-MM-DD HHmm <AppName or "Meeting">.md` inside the meetings directory.
    public static func fileURL(appName: String, date: Date = Date()) -> URL {
        let stamp = Self.fileStampFormatter().string(from: date)
        let safe = appName
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = safe.isEmpty ? "Meeting" : safe
        return meetingsDirectory().appendingPathComponent("\(stamp) \(name).md")
    }

    public let fileURL: URL
    public let meetingStart: Date

    private var handle: FileHandle?
    /// Byte offset just past the last written paragraph text (merge appends here).
    private var lastTextEndOffset: UInt64 = 0
    private var lastParagraphSpeaker: String?
    private var lastParagraphLineStart: TimeInterval = -.infinity
    /// File offset where the participants value starts + its allocated width.
    private var participantsOffset: UInt64 = 0
    private var participantsWidth = 0
    private var finished = false

    /// Creates the file and writes the header. `fileURL` may point anywhere (the
    /// `--transcribe-meeting` hook uses it for `--out`).
    public init(fileURL: URL, meetingStart: Date = Date(), appName: String = "Meeting") throws {
        self.fileURL = fileURL
        self.meetingStart = meetingStart
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: fileURL)

        let header = """
        # Meeting — \(Self.headerFormatter().string(from: meetingStart))

        App: \(appName)

        Participants:\(String(repeating: " ", count: Self.participantsPadding))

        _Transcribed locally by LocalFlow_

        """
        let data = Data(header.utf8)
        try handle?.write(contentsOf: data)
        // Offset of the first padding space after "Participants:" — the value is
        // filled in at finish() by seeking back here.
        let marker = Data("Participants:".utf8)
        if let range = data.range(of: marker) {
            participantsOffset = UInt64(range.upperBound)
            participantsWidth = Self.participantsPadding
        }
    }

    /// Writes one line, merging into the previous paragraph when the speaker
    /// matches and the gap is within the merge window. Call in timestamp order.
    public func writeLine(_ line: MeetingLine) {
        guard !finished, let handle else { return }
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if line.speaker == lastParagraphSpeaker,
           line.start - lastParagraphLineStart <= MeetingLineRenderer.mergeGapSeconds {
            // Merge into the open paragraph: append " text" at the tracked offset.
            let addition = " " + text
            _ = try? handle.seek(toOffset: lastTextEndOffset)
            _ = try? handle.write(contentsOf: Data(addition.utf8))
            lastTextEndOffset += UInt64(addition.utf8.count)
            lastParagraphLineStart = line.start
        } else {
            let stamp = Self.timeFormatter().string(from: meetingStart.addingTimeInterval(line.start))
            let block = "\n\n**[\(stamp)] \(line.speaker):** \(text)"
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: Data(block.utf8))
            lastParagraphSpeaker = line.speaker
            lastParagraphLineStart = line.start
            lastTextEndOffset = (try? handle.offset()) ?? lastTextEndOffset
        }
    }

    /// Writes the footer (duration + per-speaker word counts), fills the participants
    /// line reserved in the header, and closes the file. Safe to call once.
    @discardableResult
    public func finish(duration: TimeInterval, participants: [String], wordCounts: [String: Int]) throws -> URL {
        guard !finished else { return fileURL }
        finished = true
        let wordsPart = participants.isEmpty
            ? "—"
            : participants.map { "\($0) \(wordCounts[$0] ?? 0)" }.joined(separator: " · ")
        let footer = """

        ---

        - Duration: \(Self.durationString(duration))
        - Words: \(wordsPart)

        """
        try appendRaw(footer)
        try fillParticipants(participants)
        try handle?.synchronize()
        try handle?.close()
        handle = nil
        return fileURL
    }

    private func appendRaw(_ string: String) throws {
        guard let handle else { return }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(string.utf8))
    }

    /// Rewrites the blank participants field with the real value, space-padded to the
    /// width reserved at header time so later content is never shifted.
    private func fillParticipants(_ participants: [String]) throws {
        guard participantsOffset > 0, participantsWidth > 0, let handle else { return }
        // Leading space separates the value from the colon; truncated to the reserved
        // width because NSString.padding(toLength:) never truncates.
        let value = " " + participants.joined(separator: ", ")
        let truncated = String(value.prefix(participantsWidth))
        let padded = (truncated as NSString).padding(toLength: participantsWidth, withPad: " ", startingAt: 0)
        try handle.seek(toOffset: participantsOffset)
        try handle.write(contentsOf: Data((padded as String).utf8))
    }

    private static func durationString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    private static func fileStampFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    private static func headerFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    private static func timeFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    private static let participantsPadding = 220
}

/// A saved meeting transcript discovered in the meetings directory.
public struct MeetingFileInfo: Sendable {
    public let url: URL
    public let modified: Date
    /// Parsed from the footer's "- Duration: H:MM:SS" line, when present.
    public let duration: TimeInterval?

    public var name: String { url.deletingPathExtension().lastPathComponent }
}

extension MeetingTranscriptWriter {
    /// Newest-first list of `.md` transcripts in the meetings directory.
    public static func listTranscripts() -> [MeetingFileInfo] {
        let dir = meetingsDirectory()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                return MeetingFileInfo(
                    url: url,
                    modified: values?.contentModificationDate ?? .distantPast,
                    duration: parseDuration(url)
                )
            }
            .sorted { $0.modified > $1.modified }
    }

    /// Reads the file tail for the footer duration line.
    private static func parseDuration(_ url: URL) -> TimeInterval? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let tail = min(size, 8192)
        try? handle.seek(toOffset: size - tail)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for rawLine in text.split(separator: "\n").reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- Duration:") else { continue }
            let value = line.dropFirst("- Duration:".count).trimmingCharacters(in: .whitespaces)
            let parts = value.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
        }
        return nil
    }
}

/// Buffers meeting lines, applies echo dedupe at flush time (when every Them-side
/// line for the window is guaranteed to have been transcribed), and writes them to
/// the transcript in timestamp order. Used by both the live `MeetingSession` and
/// the `--transcribe-meeting` hook.
@MainActor
public final class MeetingLinePipeline {
    public static let flushAgeSeconds: TimeInterval = 30

    public let writer: MeetingTranscriptWriter
    private var echo = MeetingEchoFilter()
    private var pending: [MeetingLine] = []
    private var wordCounts: [String: Int] = [:]
    private var speakerOrder: [String] = []
    public private(set) var lineCount = 0
    public private(set) var droppedEchoCount = 0
    /// Highest meeting-elapsed seconds observed (drives the flush watermark).
    public private(set) var highWaterMark: TimeInterval = 0

    public init(writer: MeetingTranscriptWriter) {
        self.writer = writer
    }

    /// `meetingElapsed` = seconds since meeting start covered by audio fed so far.
    public func noteElapsed(_ meetingElapsed: TimeInterval) {
        highWaterMark = max(highWaterMark, meetingElapsed)
    }

    public func append(_ line: MeetingLine) {
        lineCount += 1
        if line.speaker != "Me" {
            // Them-side lines become echo reference immediately, even before they
            // are old enough to write out.
            echo.addThemLine(line)
        }
        pending.append(line)
        flushReady()
    }

    /// Writes buffered lines older than the flush age, sorted by start.
    public func flushReady() {
        let watermark = highWaterMark - Self.flushAgeSeconds
        let ready = pending.filter { $0.start < watermark }
        guard !ready.isEmpty else { return }
        pending.removeAll { $0.start < watermark }
        writeSorted(ready)
    }

    /// Flushes everything remaining (stop path), then writes the footer.
    @discardableResult
    public func finish(duration: TimeInterval) throws -> URL {
        writeSorted(pending)
        pending.removeAll()
        try writer.finish(duration: duration, participants: speakerOrder, wordCounts: wordCounts)
        return writer.fileURL
    }

    /// Sorted write with echo dedupe: Me lines repeating recent Them-side speech
    /// are dropped and logged.
    private func writeSorted(_ lines: [MeetingLine]) {
        for line in lines.sorted(by: { $0.start < $1.start }) {
            if line.speaker == "Me" && echo.isEcho(line) {
                droppedEchoCount += 1
                LocalFlowLog.write("meeting: dropped echo line at \(String(format: "%.1f", line.start))s: \(line.text.prefix(60))")
                continue
            }
            writer.writeLine(line)
            if wordCounts[line.speaker] == nil { speakerOrder.append(line.speaker) }
            wordCounts[line.speaker, default: 0] += line.wordCount
        }
    }
}
