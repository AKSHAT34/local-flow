import Foundation

public protocol ASREngine: Sendable {
    var kind: ASREngineKind { get }
    var displayName: String { get }
    func prepare(progress: (@Sendable (Double, String) -> Void)?) async throws
    func transcribe(samples: [Float], hints: ASRHints) async throws -> Transcript
    func unload() async
    func isPrepared() async -> Bool
}

public extension ASREngine {
    func prepare() async throws { try await prepare(progress: nil) }
}
