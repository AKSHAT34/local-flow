import AppKit
import CoreAudio
import Foundation
import os

/// Meeting transcription session: captures mic ("Me") + system audio ("Them"),
/// transcribes with speaker labels, and writes a live markdown transcript.
/// While active it blocks Fn dictation (`DictationSession.meetingSession`).
@MainActor
public final class MeetingSession: ObservableObject {
    public enum State: Equatable {
        case idle
        case starting
        case recording(startedAt: Date)
        case finishing
        case error(String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var elapsed: TimeInterval = 0
    @Published public private(set) var lineCount = 0
    @Published public private(set) var lastLine = ""
    @Published public private(set) var filePath: String?
    @Published public private(set) var meLevel: Float = 0
    @Published public private(set) var themLevel: Float = 0
    @Published public private(set) var notice: String?
    /// Action run when the Flow Bar notice pill is clicked (open file, start meeting…).
    public private(set) var noticeAction: (@MainActor () -> Void)?

    public var isActive: Bool {
        switch state {
        case .starting, .recording, .finishing: return true
        case .idle, .error: return false
        }
    }

    public var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    private static let suggestionText = "Meeting detected — click to transcribe"
    private static let suggestionCooldown: TimeInterval = 15 * 60

    private let settings: Settings
    private let engines: ASREngineProvider
    private let store: HistoryStore?
    private weak var dictation: DictationSession?

    private var recorder: MeetingRecorder?
    private var worker: MeetingWorker?
    private var pipeline: MeetingLinePipeline?
    private var meetingStartedAt: Date?
    private var elapsedTimer: Timer?
    private var flushTimer: Timer?
    private var suggestionTimer: Timer?
    private var noticeClearTask: Task<Void, Never>?
    private var lastMemoryLog = Date.distantPast
    private var startGeneration = 0
    private var startTask: Task<Void, Never>?

    private var suggestedBundleID: String?
    private var lastSuggestedAt: [String: Date] = [:]

    public init(settings: Settings, engines: ASREngineProvider, store: HistoryStore? = nil, dictation: DictationSession? = nil) {
        self.settings = settings
        self.engines = engines
        self.store = store
        self.dictation = dictation
    }

    // MARK: - Services (meeting detection)

    public func startServices() {
        stopServices()
        suggestionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollSuggestion() }
        }
    }

    public func stopServices() {
        suggestionTimer?.invalidate()
        suggestionTimer = nil
    }

    /// 5 s poll: frontmost call app (or browser with a call-ish window title) while
    /// the mic is running somewhere → suggest meeting transcription once per app
    /// per 15 minutes.
    private func pollSuggestion() {
        guard settings.suggestMeetings else {
            clearSuggestion()
            return
        }
        guard state == .idle, let detection = MeetingDetection.evaluate() else {
            // No qualifying call in front (or a dictation/meeting is active):
            // drop any suggestion that is no longer relevant.
            clearSuggestion()
            return
        }
        if suggestedBundleID == detection { return }
        clearSuggestion()
        if let last = lastSuggestedAt[detection],
           Date().timeIntervalSince(last) < Self.suggestionCooldown { return }
        lastSuggestedAt[detection] = Date()
        suggestedBundleID = detection
        LocalFlowLog.write("meeting: call detected (\(detection)); suggesting transcription")
        notice = Self.suggestionText
        noticeAction = { [weak self] in
            Task { @MainActor in await self?.start() }
        }
    }

    private func clearSuggestion() {
        suggestedBundleID = nil
        if notice == Self.suggestionText {
            notice = nil
            noticeAction = nil
        }
    }

    /// Flow Bar notice click: runs the pending action (open file / start meeting).
    public func activateNotice() {
        guard let action = noticeAction else { return }
        noticeAction = nil
        notice = nil
        action()
    }

    // MARK: - Lifecycle

    public func start() async {
        guard canStartFresh else { return }
        if let dictation, dictation.isGestureActive || dictation.isListening || !dictation.canStart {
            flashNotice("Dictation in progress")
            return
        }

        clearSuggestion()
        state = .starting
        let generation = startGeneration
        LocalFlowLog.write("meeting: starting")

        let micGranted = await Permissions.requestMicrophone()
        let speechGranted = await Permissions.requestSpeechRecognition()
        guard micGranted, speechGranted else {
            failStart("Microphone and speech recognition permissions are required")
            return
        }
        var screenGranted = Permissions.screenCaptureTrusted
        if !screenGranted {
            screenGranted = Permissions.requestScreenCaptureAccess()
        }
        guard screenGranted else {
            failStart("Screen & System Audio Recording permission needed for meeting transcription")
            openScreenCaptureSettings()
            return
        }

        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Meeting"
        let startedAt = Date()
        meetingStartedAt = startedAt
        let fileURL = MeetingTranscriptWriter.fileURL(appName: appName, date: startedAt)
        filePath = fileURL.path

        do {
            let writer = try MeetingTranscriptWriter(fileURL: fileURL, meetingStart: startedAt, appName: appName)
            pipeline = MeetingLinePipeline(writer: writer)

            var dictionary: [String: String] = [:]
            if let store {
                dictionary = (try? await store.loadDictionary()) ?? [:]
            }
            let hints = ASRHints(vocabulary: Array(dictionary.keys))
            let recorder = MeetingRecorder()
            self.recorder = recorder
            let worker = MeetingWorker(
                engines: engines,
                kind: settings.asrEngine,
                hints: hints,
                dictionary: dictionary
            ) { [weak self] line in
                Task { @MainActor in self?.handleLine(line) }
            }
            self.worker = worker

            LocalFlowLog.write("meeting: preparing engines + diarizer models")
            flashNotice("Preparing meeting transcription…", clearAfter: 120)
            try await worker.prepare()
            guard generation == startGeneration, state == .starting else {
                cleanupFailedStart()
                return
            }

            let meThrottle = OSAllocatedUnfairLock<Date?>(initialState: nil)
            let themThrottle = OSAllocatedUnfairLock<Date?>(initialState: nil)
            try await recorder.start(
                worker: worker,
                meLevel: { [weak self] rms in
                    Self.forwardLevel(rms, throttle: meThrottle) { [weak self] v in
                        Task { @MainActor in self?.meLevel = v }
                    }
                },
                themLevel: { [weak self] rms in
                    Self.forwardLevel(rms, throttle: themThrottle) { [weak self] v in
                        Task { @MainActor in self?.themLevel = v }
                    }
                }
            )
            guard generation == startGeneration, state == .starting else {
                await recorder.stop()
                cleanupFailedStart()
                return
            }

            state = .recording(startedAt: startedAt)
            elapsed = 0
            lineCount = 0
            lastLine = ""
            meLevel = 0
            themLevel = 0
            LocalFlowLog.write("meeting: recording -> \(fileURL.path)")
            flashNotice("Meeting transcription running — let participants know", clearAfter: 5)
            playSound(.start)

            elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.meetingStartedAt else { return }
                    self.elapsed = Date().timeIntervalSince(start)
                }
            }
            flushTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.flushTranscript() }
            }
        } catch {
            failStart(error.localizedDescription)
        }
    }

    public var canStart: Bool { canStartFresh }

    private var canStartFresh: Bool {
        switch state {
        case .idle, .error: return true
        case .starting, .recording, .finishing: return false
        }
    }

    /// Throttles level callbacks to ~12 Hz before hopping to the main actor.
    /// Called on realtime audio threads — must stay nonisolated.
    private nonisolated static func forwardLevel(
        _ rms: Float,
        throttle: OSAllocatedUnfairLock<Date?>,
        emit: @escaping @Sendable (Float) -> Void
    ) {
        let fire = throttle.withLock { last -> Bool in
            let now = Date()
            if let last, now.timeIntervalSince(last) < 0.08 { return false }
            last = now
            return true
        }
        if fire { emit(rms) }
    }

    public func stop() async {
        guard isActive, state != .finishing else { return }
        startGeneration += 1
        startTask?.cancel()
        startTask = nil

        if case .starting = state {
            // Prepare still in flight: invalidate it via the generation check.
            cleanupFailedStart()
            state = .idle
            return
        }
        guard let recorder else {
            state = .idle
            return
        }
        state = .finishing
        LocalFlowLog.write("meeting: stopping")
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        flushTimer?.invalidate()
        flushTimer = nil

        await recorder.stop()
        if let worker {
            await worker.waitForIdle()
        }

        let duration = meetingStartedAt.map { Date().timeIntervalSince($0) } ?? elapsed
        meetingStartedAt = nil
        var savedPath: String?
        if let pipeline {
            do {
                let url = try pipeline.finish(duration: duration)
                savedPath = url.path
                filePath = url.path
                LocalFlowLog.write("meeting: transcript saved (\(pipeline.lineCount) lines, \(pipeline.droppedEchoCount) echoes dropped) -> \(url.path)")
            } catch {
                LocalFlowLog.write("meeting: transcript finalize failed: \(error.localizedDescription)")
            }
        }

        self.recorder = nil
        self.worker = nil
        self.pipeline = nil
        elapsed = 0
        meLevel = 0
        themLevel = 0
        state = .idle
        playSound(.stop)

        if let savedPath {
            flashNotice("Saved meeting transcript", clearAfter: 10) {
                NSWorkspace.shared.open(URL(fileURLWithPath: savedPath))
            }
        }
    }

    /// Best-effort finalize on quit so a recording meeting doesn't lose its tail.
    public func emergencyStop() async {
        await stop()
    }

    // MARK: - Pipeline callbacks

    private func handleLine(_ line: MeetingLine) {
        guard isRecording || state == .finishing else { return }
        lineCount += 1
        lastLine = "\(line.speaker): \(line.text)"
        pipeline?.append(line)
        pipeline?.noteElapsed(recorder?.elapsedSeconds ?? elapsed)
        flushTranscript()
    }

    private func flushTranscript() {
        guard let recorder, let pipeline else { return }
        pipeline.noteElapsed(recorder.elapsedSeconds)
        pipeline.flushReady()
        if Date().timeIntervalSince(lastMemoryLog) > 60 {
            lastMemoryLog = Date()
            if let mb = MemoryProbe.currentMB() {
                LocalFlowLog.write("meeting: footprint \(String(format: "%.1f", mb)) MB, \(pipeline.lineCount) lines")
            }
        }
    }

    // MARK: - Helpers

    private func failStart(_ message: String) {
        cleanupFailedStart()
        state = .error(message)
        flashNotice(message, clearAfter: 6)
        playSound(.failure)
        LocalFlowLog.write("meeting: start failed: \(message)")
    }

    /// Tears down a failed/cancelled start: drops the pipeline and removes the
    /// header-only transcript file if nothing was ever written.
    private func cleanupFailedStart() {
        startGeneration += 1
        recorder = nil
        worker = nil
        pipeline = nil
        meetingStartedAt = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        flushTimer?.invalidate()
        flushTimer = nil
        if let path = filePath {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            if size <= 700 { try? FileManager.default.removeItem(atPath: path) }
        }
        filePath = nil
        elapsed = 0
        meLevel = 0
        themLevel = 0
        lineCount = 0
        lastLine = ""
    }

    private func flashNotice(_ text: String, clearAfter: TimeInterval = 4, action: (@MainActor () -> Void)? = nil) {
        notice = text
        noticeAction = action
        noticeClearTask?.cancel()
        noticeClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(clearAfter * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.notice == text {
                self.notice = nil
                self.noticeAction = nil
            }
        }
    }

    private func playSound(_ kind: Sound) {
        guard settings.soundsEnabled else { return }
        let name: String
        switch kind {
        case .start: name = "Tink"
        case .stop: name = "Pop"
        case .failure: name = "Basso"
        }
        NSSound(named: NSSound.Name(name))?.play()
    }

    private enum Sound {
        case start
        case stop
        case failure
    }

    private func openScreenCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Cheap meeting-call detection for the suggestion poll.
public enum MeetingDetection {
    /// Native meeting apps (bundle ids) that imply a call when frontmost.
    public static let callApps: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.cisco.webexmeetingsapp",
        "com.apple.FaceTime",
        "com.tinyspeck.slackmacgap",
    ]

    /// Browsers that can host web meetings (Meet / Zoom / Teams in a tab).
    public static let browsers: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",   // Arc
        "com.brave.Browser",
        "org.mozilla.firefox",
    ]

    /// Returns the frontmost app's bundle id when it looks like an active call:
    /// a known call app, or a browser whose on-screen window titles mention
    /// Meet / Zoom / Teams — and only while the default input device is running
    /// (something is capturing the mic).
    public static func evaluate() -> String? {
        guard micIsRunning() else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }
        if callApps.contains(bundleID) { return bundleID }
        if browsers.contains(bundleID),
           browserWindowSuggestsCall(pid: app.processIdentifier) {
            return bundleID
        }
        return nil
    }

    /// Whether the default audio input device is running somewhere (mic in use).
    public static func micIsRunning() -> Bool {
        var deviceID = AudioDeviceID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return false }

        var running: UInt32 = 0
        var runAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &runAddress, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// True when any on-screen window owned by `pid` has a title mentioning
    /// Meet / Zoom / Teams. Window titles require Screen Recording permission;
    /// without it `kCGWindowName` is absent and this returns false.
    public static func browserWindowSuggestsCall(pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let name = window[kCGWindowName as String] as? String,
                  !name.isEmpty else { continue }
            let lower = name.lowercased()
            if lower.contains("meet") || lower.contains("zoom") || lower.contains("teams") {
                return true
            }
        }
        return false
    }
}
