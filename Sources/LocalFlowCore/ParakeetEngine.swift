import FluidAudio
import Foundation

/// Parakeet TDT 0.6B v3 through FluidAudio/CoreML on the Apple Neural Engine.
public actor ParakeetEngine: ASREngine {
    public nonisolated let kind: ASREngineKind = .parakeetV3
    public nonisolated let displayName = ASREngineKind.parakeetV3.displayName

    private var models: AsrModels?
    private var manager: AsrManager?
    private var decoderLayers = 2

    public init() {}

    public func isPrepared() async -> Bool { manager != nil }

    public func prepare(progress: (@Sendable (Double, String) -> Void)?) async throws {
        if manager != nil { return }

        let loadedModels: AsrModels
        if let progress {
            loadedModels = try await AsrModels.downloadAndLoad(version: .v3) { update in
                let fraction = update.fractionCompleted
                let phase: String
                switch update.phase {
                case .downloading(let completed, let total):
                    phase = "Downloading model \(completed)/\(total)"
                case .compiling(let name):
                    phase = "Compiling \(name)"
                default:
                    phase = "Preparing model"
                }
                progress(fraction, phase)
            }
        } else {
            loadedModels = try await AsrModels.downloadAndLoad(version: .v3)
        }

        let config = ASRConfig(
            sampleRate: 16_000,
            parallelChunkConcurrency: 1,
            streamingEnabled: false
        )
        let asrManager = AsrManager(config: config, models: loadedModels)
        decoderLayers = await asrManager.decoderLayerCount
        models = loadedModels
        manager = asrManager
    }

    public func transcribe(samples: [Float], hints: ASRHints) async throws -> Transcript {
        guard let manager else { throw LocalFlowError.asrUnavailable("Parakeet model is not loaded") }
        guard !samples.isEmpty else { throw LocalFlowError.asrUnavailable("no audio samples") }

        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let language = hints.language.flatMap { Language(rawValue: $0) }
        let result = try await manager.transcribe(samples, decoderState: &state, language: language)
        return Transcript(
            text: result.text,
            confidence: result.confidence,
            language: hints.language,
            duration: result.duration,
            processingTime: result.processingTime
        )
    }

    public func unload() async {
        manager = nil
        models = nil
        decoderLayers = 2
    }
}
