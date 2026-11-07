import Foundation

/// One transcribed utterance in a meeting, timestamped relative to meeting start.
public struct MeetingLine: Sendable, Equatable {
    /// Seconds since meeting start (stream-relative capture offset).
    public var start: TimeInterval
    /// "Me", "Them", or "Speaker N" for remote participants.
    public var speaker: String
    public var text: String

    public init(start: TimeInterval, speaker: String, text: String) {
        self.start = start
        self.speaker = speaker
        self.text = text
    }

    public var wordCount: Int {
        text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }
}

/// Maps FluidAudio speaker ids to "Speaker N" labels in order of first appearance.
public struct MeetingSpeakerNamer: Sendable {
    private var order: [String] = []

    public init() {}

    public mutating func label(for speakerID: String) -> String {
        let trimmed = speakerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Them" }
        if let index = order.firstIndex(of: trimmed) {
            return "Speaker \(index + 1)"
        }
        order.append(trimmed)
        return "Speaker \(order.count)"
    }
}

/// Echo duplicate suppression: without headphones the mic hears remote participants,
/// so a "Me" line that repeats what the system-audio side already captured is dropped.
public struct MeetingEchoFilter: Sendable {
    public static let windowSeconds: TimeInterval = 6
    public static let wordThreshold = 0.6

    public struct Entry: Sendable {
        public var start: TimeInterval
        public var words: Set<String>
    }

    /// All non-Me lines seen so far (retained for the whole meeting; small word sets).
    public private(set) var themEntries: [Entry] = []

    public init() {}

    public mutating func addThemLine(_ line: MeetingLine) {
        guard line.speaker != "Me" else { return }
        let words = Self.qualifyingWords(line.text)
        guard !words.isEmpty else { return }
        themEntries.append(Entry(start: line.start, words: words))
    }

    /// True when >= 60% of the Me line's qualifying words appear in Them lines
    /// whose start is within +/- `windowSeconds`.
    public func isEcho(_ meLine: MeetingLine, window: TimeInterval = MeetingEchoFilter.windowSeconds) -> Bool {
        let words = Self.qualifyingWords(meLine.text)
        guard !words.isEmpty else { return false }
        var heard = Set<String>()
        for entry in themEntries where abs(entry.start - meLine.start) <= window {
            heard.formUnion(entry.words)
        }
        guard !heard.isEmpty else { return false }
        let matched = words.intersection(heard).count
        return Double(matched) / Double(words.count) >= Self.wordThreshold
    }

    /// Lowercased alphanumeric words of length >= 3.
    public static func qualifyingWords(_ text: String) -> Set<String> {
        var words = Set<String>()
        var current = ""
        for scalar in text.lowercased() {
            if scalar.isLetter || scalar.isNumber {
                current.append(scalar)
            } else if current.count >= 3 {
                words.insert(current)
                current = ""
            } else {
                current = ""
            }
        }
        if current.count >= 3 { words.insert(current) }
        return words
    }
}

/// Renders meeting lines as markdown paragraphs: sorted by start, consecutive lines
/// from the same speaker within `mergeGapSeconds` merged into one paragraph.
public enum MeetingLineRenderer {
    public static let mergeGapSeconds: TimeInterval = 2.0

    /// One rendered paragraph: timestamp of its first line + merged text.
    public struct Paragraph: Sendable, Equatable {
        public var start: TimeInterval
        public var speaker: String
        public var text: String
    }

    /// Sorts lines by start and merges consecutive same-speaker lines within the gap.
    public static func paragraphs(_ lines: [MeetingLine]) -> [Paragraph] {
        let sorted = lines.sorted { $0.start < $1.start }
        var result: [Paragraph] = []
        var lastLineStart: TimeInterval = -.infinity
        for line in sorted {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let last = result.last,
               last.speaker == line.speaker,
               line.start - lastLineStart <= mergeGapSeconds {
                result[result.count - 1].text += " " + trimmed
            } else {
                result.append(Paragraph(start: line.start, speaker: line.speaker, text: trimmed))
            }
            lastLineStart = line.start
        }
        return result
    }

    /// `**[HH:MM:SS] Speaker:** text` with the timestamp offset by meeting start.
    public static func format(_ paragraph: Paragraph, meetingStart: Date) -> String {
        let date = meetingStart.addingTimeInterval(paragraph.start)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "**[\(formatter.string(from: date))] \(paragraph.speaker):** \(paragraph.text)"
    }

    public static func render(_ lines: [MeetingLine], meetingStart: Date) -> String {
        paragraphs(lines).map { format($0, meetingStart: meetingStart) }.joined(separator: "\n\n")
    }
}
