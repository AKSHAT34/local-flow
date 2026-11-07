import AppKit
import ApplicationServices
import Combine
import Foundation

/// Central dictation state machine. Runs on the main actor so the UI can observe it directly.
@MainActor
public final class DictationSession: ObservableObject {
    @Published public private(set) var state: SessionState = .idle
    @Published public private(set) var level: Float = 0
    @Published public private(set) var memoryMB: Double?
    @Published public private(set) var lastTranscript: Transcript?
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastInsertedText: String?
    @Published public private(set) var isHandsFree: Bool = false
    @Published public private(set) var isCommandMode: Bool = false
    @Published public private(set) var notice: String?

    private let settings: Settings
    private let capture = AudioCapture()
    private let engines: ASREngineProvider
    private let cleanup = CleanupPipeline()
    private let insertion = TextInsertion()
    private let hotkey = GlobalHotkeyService()
    private let store: HistoryStore?
    /// Set by the app while a meeting records; Fn/menu dictation is blocked then.
    public weak var meetingSession: MeetingSession?
    private lazy var commandEngine = AppleFoundationLLMEngine()

    private var cancellables = Set<AnyCancellable>()

    private var silenceTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private var permissionWatchTask: Task<Void, Never>?
    private var tapWindowTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var commandSelectionTask: Task<String, Never>?
    private var transcriptionWorker: SegmentTranscriber?
    private nonisolated let segmenter = UtteranceSegmenter()
    private var recordingStartedAt: Date?
    private var lastSpeechAt = Date()
    private var dictionary: [String: String] = [:]
    private var snippets: [String: String] = [:]

    private var activeEpoch: UUID?
    private var purpose: Purpose = .dictation
    private var phase: GesturePhase = .idle
    private var gestureLocksHandsFree = false
    private var triggerDownAt: Date?
    private var pendingRelease: (at: Date, longHold: Bool)?

    private enum Purpose: String {
        case dictation
        case command
    }

    private enum GesturePhase {
        case idle
        case pending
        case holding
        case tapWindow
        case handsFree
    }

    private enum SoundKind {
        case start
        case stop
        case cancel
        case failure
    }

    private static let longHoldThreshold: TimeInterval = 0.30
    private static let tapWindowSeconds: TimeInterval = 0.35

    private static let messagingBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "com.apple.MobileSMS",
        "ru.keepcoder.Telegram", "com.hnc.Discord", "com.microsoft.teams2", "com.microsoft.teams",
    ]
    private static let emailBundleIDs: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron",
    ]

    public init(settings: Settings, store: HistoryStore? = nil, engines: ASREngineProvider = ASREngineProvider()) {
        self.settings = settings
        self.store = store
        self.engines = engines
        hotkey.onTriggerDown = { [weak self] withControl in self?.triggerDown(withControl: withControl) }
        hotkey.onTriggerUp = { [weak self] in self?.triggerUp() }
        hotkey.onEscape = { [weak self] in self?.cancelDictation() }
        hotkey.onPasteLast = { [weak self] in self?.pasteLastTranscript() }
        hotkey.triggerKeyProvider = { [weak self] in self?.settings.triggerKey ?? .fn }
        settings.$asrEngine
            .sink { [weak self] kind in
                Task { @MainActor in await self?.warmEngine(kind) }
            }
            .store(in: &cancellables)
        settings.$asrLocale
            .dropFirst()
            .sink { [weak self] locale in
                Task { @MainActor in await self?.engines.setSpeechLocale(locale) }
            }
            .store(in: &cancellables)
    }

    public var canStart: Bool {
        switch state {
        case .idle, .error: return true
        default: return false
        }
    }

    public var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    public var isGestureActive: Bool { phase != .idle }

    public func startServices() {
        hotkey.start()
        if !hotkey.isRunning {
            showNotice("Grant Accessibility to enable fn")
        }
        permissionWatchTask?.cancel()
        permissionWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if !self.hotkey.isRunning && Permissions.accessibilityTrusted {
                    LocalFlowLog.write("accessibility granted; starting hotkey tap")
                    self.hotkey.start()
                }
            }
        }
        Task { await reloadVocabulary() }
        Task { [weak self] in
            guard let self else { return }
            await self.warmEngine(self.settings.asrEngine)
        }
    }

    public func stopServices() {
        hotkey.stop()
        permissionWatchTask?.cancel()
        permissionWatchTask = nil
        silenceTask?.cancel()
        maxDurationTask?.cancel()
        tapWindowTask?.cancel()
        noticeTask?.cancel()
        commandSelectionTask?.cancel()
        commandSelectionTask = nil
    }

    public func reloadVocabulary() async {
        guard let store else { return }
        dictionary = (try? await store.loadDictionary()) ?? [:]
        snippets = (try? await store.loadSnippets()) ?? [:]
    }

    private func warmEngine(_ kind: ASREngineKind) async {
        let permissions = await Permissions.status()
        guard permissions.microphone, permissions.speechRecognition else {
            LocalFlowLog.write("engine warm-up skipped: mic/speech not authorized")
            return
        }
        do {
            try await engines.warmUp(kind: kind)
            LocalFlowLog.write("engine \(kind.rawValue) warmed")
        } catch {
            LocalFlowLog.write("engine warm-up failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Trigger gestures

    private func triggerDown(withControl: Bool) {
        if withControl && phase == .idle {
            Task { await startCommandMode() }
            return
        }
        // Control held during an active gesture acts as a normal trigger press:
        // locks hands-free from the tap window or stops a hands-free session.
        switch phase {
        case .idle:
            guard canStart, !withControl else { return }
            beginGesture(purpose: .dictation, locked: false)
        case .tapWindow:
            lockHandsFree()
        case .handsFree:
            if isListening {
                requestStop()
            } else {
                setPhase(.idle)
            }
        case .pending, .holding:
            break
        }
    }

    private func triggerUp() {
        switch phase {
        case .pending:
            let held = triggerDownAt.map { Date().timeIntervalSince($0) } ?? 0
            pendingRelease = (at: Date(), longHold: held >= Self.longHoldThreshold)
        case .holding:
            let held = triggerDownAt.map { Date().timeIntervalSince($0) } ?? 0
            if held >= Self.longHoldThreshold {
                requestStop()
            } else {
                openTapWindow()
            }
        case .tapWindow, .handsFree, .idle:
            break
        }
    }

    private func beginGesture(purpose: Purpose, locked: Bool) {
        if meetingSession?.isActive == true {
            showNotice("Meeting transcription running")
            return
        }
        let epoch = UUID()
        activeEpoch = epoch
        self.purpose = purpose
        gestureLocksHandsFree = locked
        triggerDownAt = Date()
        pendingRelease = nil
        isCommandMode = (purpose == .command)
        segmenter.reset()
        let hints = ASRHints(vocabulary: Array(dictionary.keys) + Array(snippets.keys))
        transcriptionWorker = SegmentTranscriber(engines: engines, kind: settings.asrEngine, hints: hints)
        setPhase(.pending)
        Task { await beginCapture(epoch: epoch) }
    }

    /// Starts audio capture immediately; engine preparation runs concurrently so the
    /// first words are not lost while a cold model loads.
    private func beginCapture(epoch: UUID) async {
        guard activeEpoch == epoch else { return }
        lastError = nil
        LocalFlowLog.write("beginCapture purpose=\(purpose.rawValue)")

        state = .warming("Checking permissions")
        _ = await Permissions.requestMicrophone()
        _ = await Permissions.requestSpeechRecognition()
        guard activeEpoch == epoch else { return }
        let permissions = await Permissions.status()
        LocalFlowLog.write("permissions mic=\(permissions.microphone) speech=\(permissions.speechRecognition) ax=\(permissions.accessibility)")
        guard permissions.microphone, permissions.speechRecognition else {
            failStart("Microphone and speech recognition permissions are required", epoch: epoch)
            return
        }
        if !permissions.accessibility {
            LocalFlowLog.write("beginCapture warning: accessibility not granted; paste may fail")
        }

        state = .warming("Starting microphone")
        playSound(.start)
        guard let worker = transcriptionWorker else {
            failStart("Transcription worker unavailable", epoch: epoch)
            return
        }
        do {
            try capture.start(
                chunkHandler: { [weak self] samples in
                    self?.ingestAudioChunk(samples, worker: worker)
                },
                levelHandler: { [weak self] rms in
                    Task { @MainActor in self?.handleLevel(rms) }
                }
            )
        } catch {
            failStart(error.localizedDescription, epoch: epoch)
            return
        }
        guard activeEpoch == epoch else {
            _ = capture.stop()
            return
        }

        state = .listening(startedAt: Date())
        recordingStartedAt = Date()
        lastSpeechAt = Date()
        level = 0
        setPhase(gestureLocksHandsFree ? .handsFree : .holding)
        LocalFlowLog.write("listening started (purpose=\(purpose.rawValue))")
        scheduleTimers()

        let kind = settings.asrEngine
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.engines.warmUp(kind: kind) { fraction, phaseName in
                    LocalFlowLog.write("engine prepare [\(kind.rawValue)]: \(phaseName) \(Int(fraction * 100))%")
                }
            } catch {
                LocalFlowLog.write("engine warm-up during capture failed: \(error.localizedDescription)")
            }
        }

        applyPendingReleaseIfNeeded()
    }

    private func applyPendingReleaseIfNeeded() {
        guard let release = pendingRelease else { return }
        pendingRelease = nil
        if release.longHold {
            requestStop()
        } else {
            openTapWindow(releasedAt: release.at)
        }
    }

    private func openTapWindow(releasedAt: Date? = nil) {
        let base = releasedAt ?? Date()
        let deadline = base.addingTimeInterval(Self.tapWindowSeconds)
        setPhase(.tapWindow)
        tapWindowTask?.cancel()
        tapWindowTask = Task { [weak self] in
            let delay = deadline.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.expireTapWindow()
        }
    }

    private func expireTapWindow() {
        guard phase == .tapWindow else { return }
        LocalFlowLog.write("tap window expired; cancelling accidental tap")
        activeEpoch = nil
        silenceTask?.cancel()
        maxDurationTask?.cancel()
        commandSelectionTask?.cancel()
        commandSelectionTask = nil
        _ = capture.stop()
        segmenter.reset()
        transcriptionWorker = nil
        recordingStartedAt = nil
        level = 0
        state = .idle
        setPhase(.idle)
        isCommandMode = false
        purpose = .dictation
    }

    private func lockHandsFree() {
        guard phase == .tapWindow, isListening else { return }
        tapWindowTask?.cancel()
        tapWindowTask = nil
        setPhase(.handsFree)
        LocalFlowLog.write("hands-free locked")
    }

    private func setPhase(_ newPhase: GesturePhase) {
        phase = newPhase
        isHandsFree = (newPhase == .handsFree)
        updateSilenceTask()
        syncHotkeyConsume()
    }

    private func syncHotkeyConsume() {
        hotkey.consumeEscape = (phase != .idle)
    }

    private func failStart(_ message: String, epoch: UUID) {
        guard activeEpoch == epoch else { return }
        activeEpoch = nil
        lastError = message
        segmenter.reset()
        transcriptionWorker = nil
        state = .idle
        setPhase(.idle)
        isCommandMode = false
        purpose = .dictation
        showNotice(message)
        playSound(.failure)
        LocalFlowLog.write("start failed: \(message)")
    }

    // MARK: - Dictation lifecycle

    /// Programmatic start (menu bar / Flow Bar click): locked hands-free until stopped.
    public func startDictation() async {
        guard canStart, phase == .idle else { return }
        beginGesture(purpose: .dictation, locked: true)
    }

    public func requestStop() {
        if isListening {
            tapWindowTask?.cancel()
            tapWindowTask = nil
            silenceTask?.cancel()
            maxDurationTask?.cancel()
            setPhase(.idle)
            state = .transcribing
            let remainder = capture.stop()
            LocalFlowLog.write("capture stopped: \(remainder.count) tail samples")
            let startedAt = recordingStartedAt ?? Date()
            recordingStartedAt = nil
            guard let worker = transcriptionWorker else {
                finishIdle(notice: "No speech detected", failure: true)
                return
            }
            ingestAudioChunk(remainder, worker: worker)
            let tail = segmenter.flush()
            for segment in tail.segments {
                submitSegment(segment, worker: worker)
            }
            if purpose == .command {
                Task { await runCommandPipeline(worker: worker, startedAt: startedAt) }
            } else {
                Task { await runDictationPipeline(worker: worker, startedAt: startedAt) }
            }
        } else if phase == .pending {
            pendingRelease = (at: Date(), longHold: true)
        }
    }

    public func cancelDictation() {
        guard phase != .idle else { return }
        activeEpoch = nil
        tapWindowTask?.cancel()
        tapWindowTask = nil
        silenceTask?.cancel()
        maxDurationTask?.cancel()
        commandSelectionTask?.cancel()
        commandSelectionTask = nil
        _ = capture.stop()
        segmenter.reset()
        transcriptionWorker = nil
        recordingStartedAt = nil
        lastSpeechAt = Date()
        level = 0
        state = .idle
        setPhase(.idle)
        isCommandMode = false
        purpose = .dictation
        playSound(.cancel)
        LocalFlowLog.write("dictation cancelled")
    }

    public func pasteLastTranscript() {
        guard let text = lastInsertedText, !text.isEmpty else {
            showNotice("Nothing to paste yet")
            return
        }
        guard AXIsProcessTrusted() else {
            copyToClipboard(text)
            showNotice("Grant Accessibility to enable paste")
            return
        }
        do {
            try insertion.insert(text)
            playSound(.stop)
            LocalFlowLog.write("paste-last inserted (\(text.count) chars)")
        } catch {
            copyToClipboard(text)
            showNotice("Copied to clipboard — grant Accessibility")
            playSound(.failure)
            LocalFlowLog.write("paste-last failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Command mode

    private func startCommandMode() async {
        guard canStart, phase == .idle else { return }
        guard await commandEngine.isAvailable() else {
            showNotice("Command Mode needs Apple Intelligence")
            LocalFlowLog.write("command mode: Apple Intelligence unavailable")
            return
        }
        commandSelectionTask?.cancel()
        commandSelectionTask = Task { [weak self] in await self?.captureSelection() ?? "" }
        LocalFlowLog.write("command mode: gesture started, capturing selection")
        beginGesture(purpose: .command, locked: false)
    }

    /// Copies the frontmost app's selection via Cmd+C, then restores the pasteboard.
    /// A sentinel guards against apps that leave the pasteboard untouched on empty selection.
    private func captureSelection() async -> String {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        let savedCount = pasteboard.changeCount
        let sentinel = "LOCALFLOW_NO_SELECTION_9f3b2c71"
        pasteboard.clearContents()
        pasteboard.setString(sentinel, forType: .string)
        insertion.copySelection()
        try? await Task.sleep(nanoseconds: 150_000_000)
        let captured = pasteboard.string(forType: .string) ?? ""
        let selected = (captured == sentinel) ? "" : captured
        if pasteboard.changeCount != savedCount {
            pasteboard.clearContents()
            if let saved {
                pasteboard.setString(saved, forType: .string)
            }
        }
        LocalFlowLog.write("command mode: captured selection \(selected.count) chars")
        return selected
    }

    // MARK: - Streaming ingest

    /// Feeds a 16 kHz chunk into the segmenter and submits any completed segments to
    /// the transcription worker. Runs on the realtime audio thread — synchronous and
    /// nonisolated; `segmenter` is a lock-protected Sendable value.
    private nonisolated func ingestAudioChunk(_ samples: [Float], worker: SegmentTranscriber) {
        guard !samples.isEmpty else { return }
        let output = segmenter.feed(samples)
        for segment in output.segments {
            submitSegment(segment, worker: worker)
        }
    }

    private nonisolated func submitSegment(_ samples: [Float], worker: SegmentTranscriber) {
        worker.submit(samples)
    }

    /// Waits for all queued segment transcriptions and returns the joined raw text.
    private func collectTranscript(from worker: SegmentTranscriber) async -> String {
        await worker.waitForIdle()
        let parts = await worker.results()
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Pipelines

    private func runDictationPipeline(worker: SegmentTranscriber, startedAt: Date) async {
        defer {
            memoryMB = MemoryProbe.currentMB()
            purpose = .dictation
            isCommandMode = false
            transcriptionWorker = nil
        }
        worker.setProgressHandler { [weak self] remaining in
            Task { @MainActor in
                guard let self, remaining > 0 else { return }
                if case .transcribing = self.state {
                    self.showNotice("Transcribing… (\(remaining) left)")
                }
            }
        }
        let raw = await collectTranscript(from: worker)
        let partCount = await worker.results().count
        let duration = Date().timeIntervalSince(startedAt)
        lastTranscript = Transcript(text: raw, confidence: 0, language: "", duration: duration, processingTime: 0)
        lastError = nil
        LocalFlowLog.write("transcript joined (\(partCount) parts): \(raw)")
        guard !raw.isEmpty else {
            finishIdle(notice: "No speech detected", failure: true)
            return
        }

        state = .cleaning
        let context = makeContext()
        let cleaned = await cleanup.clean(
            raw: raw,
            context: context,
            mode: settings.cleanupMode,
            externalCommand: settings.externalLLMCommand
        )
        LocalFlowLog.write("cleaned [\(settings.cleanupMode.rawValue) llm=\(cleaned.usedLLM) fallback=\(cleaned.llmFellBack)]: \(cleaned.text)")

        state = .inserting
        var inserted = false
        if AXIsProcessTrusted() {
            do {
                try insertion.insert(cleaned.text)
                inserted = true
                LocalFlowLog.write("inserted via paste")
            } catch {
                LocalFlowLog.write("paste insertion threw: \(error.localizedDescription)")
            }
        } else {
            LocalFlowLog.write("accessibility not trusted; using clipboard fallback")
        }
        if !inserted {
            copyToClipboard(cleaned.text)
            showNotice("Copied to clipboard — grant Accessibility")
            lastError = "Copied to clipboard (grant Accessibility for auto-paste)"
            LocalFlowLog.write("clipboard fallback: \(cleaned.text)")
        }
        lastInsertedText = cleaned.text

        await recordHistory(
            raw: raw,
            clean: cleaned.text,
            engine: settings.asrEngine.rawValue,
            cleanupMode: settings.cleanupMode.rawValue,
            duration: duration,
            processingTime: 0
        )

        state = .idle
        playSound(.stop)
    }

    private func runCommandPipeline(worker: SegmentTranscriber, startedAt: Date) async {
        defer {
            memoryMB = MemoryProbe.currentMB()
            purpose = .dictation
            isCommandMode = false
            commandSelectionTask = nil
            transcriptionWorker = nil
        }
        let instruction = await collectTranscript(from: worker)
        let duration = Date().timeIntervalSince(startedAt)
        lastTranscript = Transcript(text: instruction, confidence: 0, language: "", duration: duration, processingTime: 0)
        lastError = nil
        LocalFlowLog.write("command transcript: \(instruction)")
        guard !instruction.isEmpty else {
            finishIdle(notice: "No speech detected", failure: true)
            return
        }

        do {
            state = .cleaning
            let selected = await commandSelectionTask?.value ?? ""
            let system = "You edit text per the user's spoken instruction. If selected text is provided, transform it; otherwise write new text that fulfills the instruction. Output only the resulting text."
            let user = "Instruction: \(instruction)\n\nSelected text:\n\(selected)"
            LocalFlowLog.write("command mode: LLM call (selection \(selected.count) chars)")
            let result = try await commandEngine.complete(system: system, user: user, maxTokens: 768, timeout: 8.0)
            let output = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else {
                throw LocalFlowError.asrUnavailable("command model returned empty text")
            }
            LocalFlowLog.write("command result: \(output)")

            state = .inserting
            var inserted = false
            if AXIsProcessTrusted() {
                do {
                    try insertion.insert(output)
                    inserted = true
                    LocalFlowLog.write("command result inserted")
                } catch {
                    LocalFlowLog.write("command insert threw: \(error.localizedDescription)")
                }
            } else {
                LocalFlowLog.write("command: accessibility not trusted; clipboard fallback")
            }
            if !inserted {
                copyToClipboard(output)
                showNotice("Copied to clipboard — grant Accessibility")
            }
            lastInsertedText = output

            await recordHistory(
                raw: instruction,
                clean: output,
                engine: settings.asrEngine.rawValue,
                cleanupMode: "command",
                duration: duration,
                processingTime: 0
            )

            state = .idle
            playSound(.stop)
        } catch {
            finishIdle(notice: error.localizedDescription, failure: true)
            LocalFlowLog.write("command pipeline error: \(error.localizedDescription)")
        }
    }

    private func finishIdle(notice message: String, failure: Bool) {
        state = .idle
        lastError = message
        showNotice(message)
        playSound(failure ? .failure : .stop)
    }

    // MARK: - Timers, level, notices, sounds

    private func scheduleTimers() {
        maxDurationTask?.cancel()
        maxDurationTask = Task { [weak self] in
            let seconds = UInt64(max(1, self?.settings.maxRecordingSeconds ?? 7200))
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard let self, !Task.isCancelled, self.isListening else { return }
            self.requestStop()
        }
    }

    private func updateSilenceTask() {
        silenceTask?.cancel()
        silenceTask = nil
        guard phase == .handsFree, settings.autoStopOnSilence, isListening else { return }
        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.phase == .handsFree, self.isListening else { return }
                if Date().timeIntervalSince(self.lastSpeechAt) > self.settings.silenceTimeoutSeconds,
                   Date().timeIntervalSince(self.recordingStartedAt ?? Date()) > 0.8 {
                    self.requestStop()
                    return
                }
            }
        }
    }

    private func handleLevel(_ rms: Float) {
        level = rms
        if rms > 0.012 {
            lastSpeechAt = Date()
        }
    }

    private func showNotice(_ text: String, clearAfter: TimeInterval = 2.6) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(clearAfter * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.notice == text {
                self.notice = nil
            }
        }
    }

    private func playSound(_ kind: SoundKind) {
        guard settings.soundsEnabled else { return }
        let name: String
        switch kind {
        case .start: name = "Tink"
        case .stop: name = "Pop"
        case .cancel: name = "Bottle"
        case .failure: name = "Basso"
        }
        NSSound(named: NSSound.Name(name))?.play()
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Context and history

    private func makeContext() -> CleanupContext {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier ?? ""
        let name = app?.localizedName ?? "Unknown"
        let literalIDs: Set<String> = [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode",
            "com.apple.dt.Xcode", "com.jetbrains.", "com.sublimetext",
        ]
        let secureIDs = ["com.1password", "com.bitwarden", "com.apple.keychainaccess"]
        let isLiteral = literalIDs.contains(where: { bundleID.hasPrefix($0) || name.localizedCaseInsensitiveContains($0.replacingOccurrences(of: "com.", with: "")) })
        let isSecure = secureIDs.contains(where: { bundleID.contains($0) })
        let style: WritingStyle
        if Self.messagingBundleIDs.contains(bundleID) {
            style = settings.messagingStyle
        } else if Self.emailBundleIDs.contains(bundleID) {
            style = settings.emailStyle
        } else {
            style = settings.otherStyle
        }
        return CleanupContext(
            bundleID: bundleID,
            appName: name,
            isSecureField: isSecure,
            literalMode: isLiteral,
            style: style,
            dictionary: dictionary,
            snippets: snippets
        )
    }

    private func recordHistory(raw: String, clean: String, engine: String, cleanupMode: String, duration: TimeInterval, processingTime: TimeInterval) async {
        guard let store else { return }
        let context = makeContext()
        let entry = HistoryEntry(
            appName: context.appName,
            bundleID: context.bundleID,
            rawText: raw,
            cleanText: clean,
            engine: engine,
            cleanupMode: cleanupMode,
            durationMilliseconds: duration * 1000
        )
        _ = processingTime
        _ = try? await store.insertHistory(entry)
    }
}
