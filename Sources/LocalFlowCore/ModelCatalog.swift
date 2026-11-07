import Foundation

public struct ModelInfo: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String
    public var sizeMB: Double
    public var license: String
    public var notes: String

    public init(id: String, name: String, kind: String, sizeMB: Double, license: String, notes: String) {
        self.id = id; self.name = name; self.kind = kind; self.sizeMB = sizeMB; self.license = license; self.notes = notes
    }
}

public enum ModelCatalog {
    public static let models: [ModelInfo] = [
        ModelInfo(id: "parakeet-v3", name: "Parakeet TDT 0.6B v3", kind: "ASR", sizeMB: 445, license: "CC-BY-4.0", notes: "Default local ASR via FluidAudio/CoreML; auto-downloads on first use."),
        ModelInfo(id: "apple-speech", name: "Apple Speech", kind: "ASR", sizeMB: 0, license: "Apple", notes: "On-device fallback; no app-managed download."),
        ModelInfo(id: "apple-intelligence", name: "Apple Intelligence", kind: "Cleanup LLM", sizeMB: 0, license: "Apple", notes: "System-managed on-device model; RAM reported separately."),
        ModelInfo(id: "qwen3-0.6b", name: "Qwen3 0.6B", kind: "Cleanup LLM", sizeMB: 397, license: "Apache-2.0", notes: "Optional external command only; unload ASR first to stay near 1 GB."),
        ModelInfo(id: "kokoro-82m", name: "Kokoro 82M", kind: "TTS", sizeMB: 177, license: "Apache-2.0", notes: "Optional read-aloud; not loaded by default."),
    ]

    public static func info(for id: String) -> ModelInfo? {
        models.first { $0.id == id }
    }
}
