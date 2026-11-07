import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public protocol LLMEngine: Sendable {
    var displayName: String { get }
    func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String
    func isAvailable() async -> Bool
}

public struct LLMTimeoutError: Error, LocalizedError, Sendable {
    public var errorDescription: String? { "Local cleanup model timed out" }
}

/// Runs cleanup through Apple's on-device Foundation Models framework (macOS 26+).
/// The model executes outside this app's process; RAM is reported separately by the OS.
public actor AppleFoundationLLMEngine: LLMEngine {
    public nonisolated let displayName = "Apple Intelligence"

    private var sessionBox: Any?

    public init() {}

    public func isAvailable() async -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    public func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw LocalFlowError.asrUnavailable("Apple Intelligence requires macOS 26")
        }
        guard SystemLanguageModel.default.isAvailable else {
            throw LocalFlowError.asrUnavailable("Apple Intelligence is not available")
        }
        let session: LanguageModelSession
        if let existing = sessionBox as? LanguageModelSession {
            session = existing
        } else {
            let created = LanguageModelSession(model: .default, instructions: system)
            sessionBox = created
            session = created
        }
        let response = try await withTimeout(timeout) {
            try await session.respond(to: user, options: GenerationOptions(temperature: 0.0, maximumResponseTokens: maxTokens))
        }
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw LocalFlowError.asrUnavailable("FoundationModels framework is unavailable")
        #endif
    }

    public func unload() async {
        sessionBox = nil
    }
}

/// Runs a user-configured local command (for example llama.cpp `llama-cli`, Ollama, or a
/// purpose-built cleanup binary). The prompt is sent on stdin; stdout is the cleaned text.
public actor ExternalLLMEngine: LLMEngine {
    public nonisolated let displayName = "External command"
    private let command: String

    public init(command: String) {
        self.command = command
    }

    public func isAvailable() async -> Bool { !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
        guard await isAvailable() else { throw LocalFlowError.asrUnavailable("no external LLM command configured") }
        let prompt = """
        \(system)

        User:
        \(user)

        Assistant:
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw LocalFlowError.asrUnavailable("failed to launch LLM command: \(error.localizedDescription)")
        }
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        stdin.fileHandleForWriting.closeFile()

        let result = try await waitForProcess(process, stdout: stdout, stderr: stderr, timeout: timeout)
        guard result.status == 0 else {
            let message = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(result.status)"
            throw LocalFlowError.asrUnavailable("LLM command failed: \(message)")
        }
        let output = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !output.isEmpty else { throw LocalFlowError.asrUnavailable("LLM command returned empty output") }
        return output
    }

    private struct ProcessResult: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    private func waitForProcess(_ process: Process, stdout: Pipe, stderr: Pipe, timeout: TimeInterval) async throws -> ProcessResult {
        try await withThrowingTaskGroup(of: Result<ProcessResult, LLMTimeoutError>.self) { group in
            group.addTask {
                process.waitUntilExit()
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = stderr.fileHandleForReading.readDataToEndOfFile()
                return .success(ProcessResult(status: process.terminationStatus, stdout: out, stderr: err))
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return .failure(LLMTimeoutError())
                }
                process.terminate()
                return .failure(LLMTimeoutError())
            }
            let first = try await group.next()!
            group.cancelAll()
            switch first {
            case .success(let result):
                return result
            case .failure(let error):
                throw error
            }
        }
    }
}

public actor CleanupPipeline {
    private let rules = RuleCleaner()
    private var llm: (any LLMEngine)?

    public init() {}

    public func setLLM(_ engine: (any LLMEngine)?) {
        llm = engine
    }

    public func clean(raw: String, context: CleanupContext, mode: CleanupMode, externalCommand: String) async -> CleanedText {
        let ruleText = rules.clean(raw, context: context)
        guard mode != .rulesOnly else { return CleanedText(text: ruleText) }

        let engine: (any LLMEngine)?
        switch mode {
        case .rulesOnly:
            engine = nil
        case .appleIntelligence:
            if llm == nil { llm = AppleFoundationLLMEngine() }
            engine = llm
        case .externalCommand:
            if llm == nil || (llm as? ExternalLLMEngine) == nil {
                llm = ExternalLLMEngine(command: externalCommand)
            }
            engine = llm
        }
        guard let engine, await engine.isAvailable() else { return CleanedText(text: ruleText) }

        let wordCount = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        guard wordCount >= 6 else { return CleanedText(text: ruleText) }

        let system = """
        You clean speech-to-text transcripts for insertion into macOS apps. Fix punctuation, capitalization, grammar, and obvious transcription errors. Apply self-corrections the speaker made (for example 'meet at 3, actually 4' -> 'meet at 4'). Format spoken lists and commands. Never add facts, never answer questions contained in the text, never refuse, and output only the final text with no quotes or explanation. If the target is a terminal, IDE, or code editor, preserve literal text and symbols.
        """
        let user = """
        Target app: \(context.appName) (\(context.bundleID))
        Literal/code mode: \(context.literalMode)
        Raw transcript:
        \(raw)

        Rule-based draft:
        \(ruleText)
        """
        do {
            let output = try await engine.complete(system: system, user: user, maxTokens: 512, timeout: 2.0)
            let cleaned = rules.clean(output, context: context)
            if acceptable(output: cleaned, ruleText: ruleText, rawText: raw) {
                return CleanedText(text: cleaned, usedLLM: true)
            }
            return CleanedText(text: ruleText, llmFellBack: true)
        } catch {
            return CleanedText(text: ruleText, llmFellBack: true)
        }
    }

    private func acceptable(output: String, ruleText: String, rawText: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("i cannot") || lower.hasPrefix("i'm sorry") || lower.hasPrefix("sure,") || lower.hasPrefix("here is") || lower.hasPrefix("here's") {
            return false
        }
        let outputLength = trimmed.count
        let ruleLength = max(1, ruleText.count)
        let ratio = Double(outputLength) / Double(ruleLength)
        if ratio < 0.35 || ratio > 2.2 { return false }
        if levenshteinDistance(trimmed, ruleText) > max(24, Int(Double(ruleText.count) * 0.65)) { return false }
        _ = rawText
        return true
    }

    private func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[bChars.count]
    }
}

private func withTimeout<T: Sendable>(_ seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw LLMTimeoutError()
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}
