import Foundation

public enum ASREngineKind: String, Codable, CaseIterable, Sendable {
    case parakeetV3
    case appleSpeech

    public var displayName: String {
        switch self {
        case .parakeetV3: return "Parakeet TDT 0.6B v3 (local CoreML)"
        case .appleSpeech: return "Apple Speech (on-device)"
        }
    }
}

public enum CleanupMode: String, Codable, CaseIterable, Sendable {
    case rulesOnly
    case appleIntelligence
    case externalCommand

    public var displayName: String {
        switch self {
        case .rulesOnly: return "Rules only"
        case .appleIntelligence: return "Apple Intelligence (system LLM)"
        case .externalCommand: return "External local command"
        }
    }
}

public enum TriggerKey: String, Codable, CaseIterable, Sendable {
    case fn
    case rightOption
    case rightCommand

    public var displayName: String {
        switch self {
        case .fn: return "Fn (Globe)"
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        }
    }

    /// Short label for UI hints like "Hold fn to dictate".
    public var shortName: String {
        switch self {
        case .fn: return "fn"
        case .rightOption: return "right ⌥"
        case .rightCommand: return "right ⌘"
        }
    }
}

public enum WritingStyle: String, Codable, CaseIterable, Sendable {
    case formal
    case casual
    case veryCasual

    public var displayName: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very casual"
        }
    }
}

public enum SessionState: Equatable, Sendable {
    case idle
    case warming(String)
    case listening(startedAt: Date)
    case transcribing
    case cleaning
    case inserting
    case error(String)
}

public struct Transcript: Sendable {
    public var text: String
    public var confidence: Float
    public var language: String?
    public var duration: TimeInterval
    public var processingTime: TimeInterval

    public init(text: String, confidence: Float = 0, language: String? = nil, duration: TimeInterval = 0, processingTime: TimeInterval = 0) {
        self.text = text
        self.confidence = confidence
        self.language = language
        self.duration = duration
        self.processingTime = processingTime
    }
}

public struct ASRHints: Sendable {
    public var vocabulary: [String]
    public var language: String?

    public init(vocabulary: [String] = [], language: String? = nil) {
        self.vocabulary = vocabulary
        self.language = language
    }
}

public struct CleanupContext: Sendable {
    public var bundleID: String
    public var appName: String
    public var isSecureField: Bool
    public var literalMode: Bool
    public var style: WritingStyle
    public var dictionary: [String: String]
    public var snippets: [String: String]

    public init(bundleID: String = "", appName: String = "", isSecureField: Bool = false, literalMode: Bool = false, style: WritingStyle = .formal, dictionary: [String: String] = [:], snippets: [String: String] = [:]) {
        self.bundleID = bundleID
        self.appName = appName
        self.isSecureField = isSecureField
        self.literalMode = literalMode
        self.style = style
        self.dictionary = dictionary
        self.snippets = snippets
    }
}

public enum LocalFlowError: Error, LocalizedError, Sendable {
    case permissionDenied(String)
    case audioUnavailable(String)
    case asrUnavailable(String)
    case modelNotDownloaded(String)
    case insertionFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let what): return "Permission denied: \(what)"
        case .audioUnavailable(let why): return "Audio unavailable: \(why)"
        case .asrUnavailable(let why): return "Speech recognition unavailable: \(why)"
        case .modelNotDownloaded(let name): return "Model not downloaded: \(name)"
        case .insertionFailed(let why): return "Insertion failed: \(why)"
        case .cancelled: return "Dictation cancelled"
        }
    }
}
