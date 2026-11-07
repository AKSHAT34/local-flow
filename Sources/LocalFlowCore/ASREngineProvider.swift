import Foundation

/// Owns ASR engine instances and enforces the single-heavy-model memory rule.
public actor ASREngineProvider {
    private var parakeet: ParakeetEngine?
    private var appleSpeech: AppleSpeechEngine?
    private var preparing: [ASREngineKind: Task<Void, Error>] = [:]
    /// Locale identifier for Apple Speech (e.g. "en-US", "en-IN", "hi-IN").
    /// Changing it drops the cached engine so the recognizer is re-created.
    public private(set) var speechLocale = "en-US"

    public init() {}

    /// Updates the Apple Speech locale; recreates the engine on next use.
    public func setSpeechLocale(_ locale: String) async {
        guard locale != speechLocale else { return }
        speechLocale = locale
        await unload(kind: .appleSpeech)
    }

    public func engine(for kind: ASREngineKind) -> any ASREngine {
        switch kind {
        case .parakeetV3:
            if parakeet == nil { parakeet = ParakeetEngine() }
            return parakeet!
        case .appleSpeech:
            if appleSpeech == nil {
                appleSpeech = AppleSpeechEngine(locale: Locale(identifier: speechLocale))
            }
            return appleSpeech!
        }
    }

    public func preferredEngine(for kind: ASREngineKind) -> any ASREngine {
        engine(for: kind)
    }

    public func warmUp(kind: ASREngineKind, progress: (@Sendable (Double, String) -> Void)? = nil) async throws {
        let engine = self.engine(for: kind)
        if await engine.isPrepared() { return }
        if let existing = preparing[kind] {
            try await existing.value
            return
        }
        let task = Task { try await engine.prepare(progress: progress) }
        preparing[kind] = task
        do {
            try await task.value
            preparing[kind] = nil
        } catch {
            preparing[kind] = nil
            throw error
        }
    }

    public func ensurePrepared(kind: ASREngineKind, progress: (@Sendable (Double, String) -> Void)? = nil) async throws {
        try await warmUp(kind: kind, progress: progress)
    }

    public func unloadAll() async {
        await parakeet?.unload()
        await appleSpeech?.unload()
        parakeet = nil
        appleSpeech = nil
    }

    public func unload(kind: ASREngineKind) async {
        switch kind {
        case .parakeetV3:
            await parakeet?.unload()
            parakeet = nil
        case .appleSpeech:
            await appleSpeech?.unload()
            appleSpeech = nil
        }
    }

    public func estimatedFootprintMB(for kind: ASREngineKind) -> Double {
        switch kind {
        case .parakeetV3: return 550
        case .appleSpeech: return 80
        }
    }
}
