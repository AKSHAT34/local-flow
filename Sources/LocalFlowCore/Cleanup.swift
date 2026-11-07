import Foundation

public struct CleanedText: Sendable {
    public var text: String
    public var usedLLM: Bool
    public var llmFellBack: Bool

    public init(text: String, usedLLM: Bool = false, llmFellBack: Bool = false) {
        self.text = text
        self.usedLLM = usedLLM
        self.llmFellBack = llmFellBack
    }
}

public struct RuleCleaner: Sendable {
    public init() {}

    public func clean(_ raw: String, context: CleanupContext) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        if let snippet = snippetExpansion(for: text, snippets: context.snippets) {
            return snippet
        }

        text = applySpokenCommands(text)
        text = applyBacktracks(text)
        text = stripFillers(text)
        text = collapseRepeats(text)
        text = applyDictionary(text, dictionary: context.dictionary)
        text = normalizeNumbersAndMeasures(text)
        text = tidy(text, context: context)
        return text
    }

    // MARK: - Snippets

    private func snippetExpansion(for text: String, snippets: [String: String]) -> String? {
        let key = normalizeKey(text)
        for (trigger, expansion) in snippets {
            if normalizeKey(trigger) == key { return expansion }
        }
        return nil
    }

    private func normalizeKey(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Spoken commands

    private func applySpokenCommands(_ text: String) -> String {
        let replacements: [(String, String)] = [
            ("new paragraph", "\n\n"),
            ("new line", "\n"),
            ("question mark", "?"),
            ("exclamation mark", "!"),
            ("exclamation point", "!"),
            ("full stop", "."),
            ("period", "."),
            ("comma", ","),
            ("semicolon", ";"),
            ("colon", ":"),
            ("open quote", "\""),
            ("close quote", "\""),
            ("bullet point", "\n- "),
            ("new bullet", "\n- "),
            ("hyphen", "-"),
            ("dash", "—"),
        ]
        var result = text
        for (phrase, replacement) in replacements.sorted(by: { $0.0.count > $1.0.count }) {
            result = replacePhrase(result, phrase: phrase, replacement: replacement)
        }
        return result
    }

    private func replacePhrase(_ text: String, phrase: String, replacement: String) -> String {
        let pattern = #"(?<![A-Za-z0-9])"# + NSRegularExpression.escapedPattern(for: phrase) + #"(?![A-Za-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    // MARK: - Backtracking (limited, deterministic)

    private func applyBacktracks(_ text: String) -> String {
        var result = text
        // "3, actually 4" / "3pm, no, 4pm" style corrections for short tokens.
        let pattern = #"\b([A-Za-z0-9$€£₹%]+),\s*(?:actually|no|i mean)\s+([A-Za-z0-9$€£₹%]+)\b"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$2"
            )
        }
        return result
    }

    // MARK: - Fillers and repeats

    private func stripFillers(_ text: String) -> String {
        let fillers = ["um+", "uh+", "er+", "ah+", "hmm+", "you know"]
        var result = text
        for filler in fillers {
            let pattern = #"(?<![A-Za-z0-9])"# + filler + #"(?![A-Za-z0-9])"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " ")
            }
        }
        return result
    }

    private func collapseRepeats(_ text: String) -> String {
        let pattern = #"\b([A-Za-z][A-Za-z']*)(?:\s+\1\b)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    }

    // MARK: - Dictionary

    private func applyDictionary(_ text: String, dictionary: [String: String]) -> String {
        var result = text
        for (term, replacement) in dictionary.sorted(by: { $0.key.count > $1.key.count }) where !term.isEmpty {
            let pattern = #"(?<![A-Za-z0-9])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![A-Za-z0-9])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = replaceMatches(regex: regex, in: result, transform: { _ in replacement })
        }
        return result
    }

    private func replaceMatches(regex: NSRegularExpression, in text: String, transform: (String) -> String) -> String {
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += String(text[cursor..<range.lowerBound])
            result += transform(nsText.substring(with: match.range))
            cursor = range.upperBound
        }
        result += String(text[cursor...])
        return result
    }

    // MARK: - Numbers and measures

    private func normalizeNumbersAndMeasures(_ text: String) -> String {
        var result = text
        result = numberWordsToDigits(result)
        result = result.replacingOccurrences(of: #"\s+percent\b"#, with: "%", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: #"\bpercent\b"#, with: "%", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: #"\s+dollars?\b"#, with: " dollars", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: #"\brupees?\b"#, with: "₹", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: #"\brs\.?(?=\s|$)"#, with: "₹", options: [.regularExpression, .caseInsensitive])
        return result
    }

    private func numberWordsToDigits(_ text: String) -> String {
        let small: [String: Int] = [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
            "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
            "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
            "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
            "hundred": 100, "thousand": 1000, "million": 1_000_000,
        ]
        let tokens = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var output: [String] = []
        var i = 0
        while i < tokens.count {
            let lower = tokens[i].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?"))
            if small[lower] != nil || lower == "point" || lower == "and" {
                var j = i
                var parts: [String] = []
                while j < tokens.count {
                    let token = tokens[j].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?"))
                    if small[token] != nil || token == "point" || token == "and" {
                        parts.append(token)
                        j += 1
                    } else {
                        break
                    }
                }
                if let number = parseNumberWords(parts, small: small) {
                    output.append(number)
                    i = j
                    continue
                }
            }
            output.append(tokens[i])
            i += 1
        }
        return output.joined(separator: " ")
    }

    private func parseNumberWords(_ words: [String], small: [String: Int]) -> String? {
        var total = 0
        var current = 0
        var fraction = ""
        var inFraction = false
        var sawNumber = false
        for word in words {
            if word == "and" { continue }
            if word == "point" { inFraction = true; continue }
            guard let value = small[word] else { return nil }
            sawNumber = true
            if inFraction {
                fraction += String(value)
                continue
            }
            if value == 100 {
                current = max(1, current) * 100
            } else if value >= 1000 {
                total += max(1, current) * value
                current = 0
            } else {
                current += value
            }
        }
        guard sawNumber else { return nil }
        total += current
        if !fraction.isEmpty {
            return "\(total).\(fraction)"
        }
        return "\(total)"
    }

    // MARK: - Tidying

    private func tidy(_ text: String, context: CleanupContext) -> String {
        var result = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([,.;:!?%)\]}])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"([(\[{])\s+"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+\n"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n\s+"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !context.literalMode else { return result }

        let wordCount = result.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let hasTerminal = result.last.map { ".!?…:;".contains($0) } ?? false
        let eligibleForPeriod = wordCount >= 4 && !result.contains("\n") && !hasTerminal
        let multiSentence = result.range(of: #"[.!?]+\s+\S"#, options: .regularExpression) != nil

        switch context.style {
        case .formal:
            capitalizeFirst(&result)
            if eligibleForPeriod { result += "." }
        case .casual:
            capitalizeFirst(&result)
            if eligibleForPeriod && multiSentence { result += "." }
        case .veryCasual:
            lowercaseFirst(&result)
        }
        return result
    }

    private func capitalizeFirst(_ text: inout String) {
        guard let first = text.first, first.isLetter, first.isLowercase else { return }
        text = first.uppercased() + text.dropFirst()
    }

    private func lowercaseFirst(_ text: inout String) {
        guard let first = text.first, first.isLetter, first.isUppercase else { return }
        let firstToken = text.prefix { !$0.isWhitespace }
        let isPronounI = firstToken == "I" || firstToken.hasPrefix("I'")
        let isAllCapsToken = firstToken.count > 1
            && firstToken.allSatisfy { !$0.isLetter || $0.isUppercase }
            && firstToken.contains(where: { $0.isLetter })
        guard !isPronounI, !isAllCapsToken else { return }
        text = first.lowercased() + text.dropFirst()
    }
}
