import Combine
import Foundation

@MainActor
public final class Settings: ObservableObject {
    private let defaults: UserDefaults
    private let prefix = "LocalFlow."

    @Published public var asrEngine: ASREngineKind {
        didSet { defaults.set(asrEngine.rawValue, forKey: key("asrEngine")) }
    }
    @Published public var cleanupMode: CleanupMode {
        didSet { defaults.set(cleanupMode.rawValue, forKey: key("cleanupMode")) }
    }
    @Published public var triggerKey: TriggerKey {
        didSet { defaults.set(triggerKey.rawValue, forKey: key("triggerKey")) }
    }
    @Published public var showFlowBar: Bool {
        didSet { defaults.set(showFlowBar, forKey: key("showFlowBar")) }
    }
    @Published public var autoStopOnSilence: Bool {
        didSet { defaults.set(autoStopOnSilence, forKey: key("autoStopOnSilence")) }
    }
    @Published public var messagingStyle: WritingStyle {
        didSet { defaults.set(messagingStyle.rawValue, forKey: key("messagingStyle")) }
    }
    @Published public var emailStyle: WritingStyle {
        didSet { defaults.set(emailStyle.rawValue, forKey: key("emailStyle")) }
    }
    @Published public var otherStyle: WritingStyle {
        didSet { defaults.set(otherStyle.rawValue, forKey: key("otherStyle")) }
    }
    @Published public var soundsEnabled: Bool {
        didSet { defaults.set(soundsEnabled, forKey: key("soundsEnabled")) }
    }
    @Published public var whisperMode: Bool {
        didSet { defaults.set(whisperMode, forKey: key("whisperMode")) }
    }
    @Published public var historyRetentionDays: Int {
        didSet { defaults.set(historyRetentionDays, forKey: key("historyRetentionDays")) }
    }
    @Published public var maxRecordingSeconds: Int {
        didSet { defaults.set(maxRecordingSeconds, forKey: key("maxRecordingSeconds")) }
    }
    @Published public var silenceTimeoutSeconds: Double {
        didSet { defaults.set(silenceTimeoutSeconds, forKey: key("silenceTimeoutSeconds")) }
    }
    @Published public var externalLLMCommand: String {
        didSet { defaults.set(externalLLMCommand, forKey: key("externalLLMCommand")) }
    }
    @Published public var selectedInputDeviceUID: String? {
        didSet { defaults.set(selectedInputDeviceUID, forKey: key("selectedInputDeviceUID")) }
    }
    @Published public var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: key("onboardingCompleted")) }
    }
    @Published public var asrLocale: String {
        didSet { defaults.set(asrLocale, forKey: key("asrLocale")) }
    }
    @Published public var suggestMeetings: Bool {
        didSet { defaults.set(suggestMeetings, forKey: key("suggestMeetings")) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T>(_ key: String, _ fallback: T) -> T {
            (defaults.object(forKey: "LocalFlow." + key) as? T) ?? fallback
        }
        asrEngine = ASREngineKind(rawValue: value("asrEngine", ASREngineKind.appleSpeech.rawValue)) ?? .appleSpeech
        cleanupMode = CleanupMode(rawValue: value("cleanupMode", CleanupMode.rulesOnly.rawValue)) ?? .rulesOnly
        triggerKey = TriggerKey(rawValue: value("triggerKey", TriggerKey.fn.rawValue)) ?? .fn
        showFlowBar = value("showFlowBar", true)
        autoStopOnSilence = value("autoStopOnSilence", false)
        messagingStyle = WritingStyle(rawValue: value("messagingStyle", WritingStyle.casual.rawValue)) ?? .casual
        emailStyle = WritingStyle(rawValue: value("emailStyle", WritingStyle.formal.rawValue)) ?? .formal
        otherStyle = WritingStyle(rawValue: value("otherStyle", WritingStyle.formal.rawValue)) ?? .formal
        soundsEnabled = value("soundsEnabled", true)
        whisperMode = value("whisperMode", false)
        historyRetentionDays = value("historyRetentionDays", 7)
        maxRecordingSeconds = value("maxRecordingSeconds", 7200)
        silenceTimeoutSeconds = value("silenceTimeoutSeconds", 1.2)
        externalLLMCommand = value("externalLLMCommand", "")
        selectedInputDeviceUID = value("selectedInputDeviceUID", nil as String?)
        onboardingCompleted = value("onboardingCompleted", false)
        asrLocale = value("asrLocale", "en-US")
        suggestMeetings = value("suggestMeetings", true)
    }

    private func key(_ name: String) -> String { prefix + name }

    public func reset() {
        let keys = ["asrEngine", "cleanupMode", "triggerKey", "showFlowBar", "autoStopOnSilence", "messagingStyle", "emailStyle", "otherStyle", "soundsEnabled", "whisperMode", "historyRetentionDays", "maxRecordingSeconds", "silenceTimeoutSeconds", "externalLLMCommand", "selectedInputDeviceUID", "onboardingCompleted", "asrLocale", "suggestMeetings"]
        keys.forEach { defaults.removeObject(forKey: key($0)) }
        asrEngine = .appleSpeech
        cleanupMode = .rulesOnly
        triggerKey = .fn
        showFlowBar = true
        autoStopOnSilence = false
        messagingStyle = .casual
        emailStyle = .formal
        otherStyle = .formal
        soundsEnabled = true
        whisperMode = false
        historyRetentionDays = 7
        maxRecordingSeconds = 7200
        silenceTimeoutSeconds = 1.2
        externalLLMCommand = ""
        selectedInputDeviceUID = nil
        onboardingCompleted = false
        asrLocale = "en-US"
        suggestMeetings = true
    }
}
