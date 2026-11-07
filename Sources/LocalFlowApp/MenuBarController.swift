import AppKit
import LocalFlowCore

@MainActor
final class MenuBarController: NSObject {
    private let session: DictationSession
    private let meeting: MeetingSession
    private let settings: Settings
    private weak var appDelegate: AppDelegate?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var stateItem: NSMenuItem!
    private var memoryItem: NSMenuItem!
    private var hubItem: NSMenuItem!
    private var pasteItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var cancelItem: NSMenuItem!
    private var meetingToggleItem: NSMenuItem!
    private var meetingsFolderItem: NSMenuItem!

    init(session: DictationSession, meeting: MeetingSession, settings: Settings, appDelegate: AppDelegate) {
        self.session = session
        self.meeting = meeting
        self.settings = settings
        self.appDelegate = appDelegate
        super.init()
        buildMenu()
        statusItem.button?.title = "LocalFlow"
        statusItem.button?.font = .systemFont(ofSize: 12, weight: .semibold)
    }

    private func buildMenu() {
        let menu = NSMenu()

        stateItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        memoryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        memoryItem.isEnabled = false
        menu.addItem(memoryItem)

        menu.addItem(.separator())

        hubItem = NSMenuItem(title: "Open LocalFlow Hub", action: #selector(openHub), keyEquivalent: "h")
        hubItem.target = self
        menu.addItem(hubItem)

        meetingsFolderItem = NSMenuItem(title: "Open Meetings Folder", action: #selector(openMeetingsFolder), keyEquivalent: "")
        meetingsFolderItem.target = self
        menu.addItem(meetingsFolderItem)

        menu.addItem(.separator())

        pasteItem = NSMenuItem(title: "Paste Last Transcript", action: #selector(pasteLast), keyEquivalent: "v")
        pasteItem.target = self
        pasteItem.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(pasteItem)

        toggleItem = NSMenuItem(title: "Start Dictation", action: #selector(toggleDictation), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        cancelItem = NSMenuItem(title: "Cancel", action: #selector(cancelDictation), keyEquivalent: "")
        cancelItem.target = self
        menu.addItem(cancelItem)

        meetingToggleItem = NSMenuItem(title: "Start Meeting Transcription", action: #selector(toggleMeeting), keyEquivalent: "")
        meetingToggleItem.target = self
        menu.addItem(meetingToggleItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit LocalFlow", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func refresh() {
        stateItem.title = stateDescription
        if let mb = session.memoryMB {
            memoryItem.title = String(format: "Memory: %.1f MB", mb)
        } else {
            memoryItem.title = "Memory: not measured"
        }
        toggleItem.title = session.canStart ? "Start Dictation" : "Stop & Insert"
        toggleItem.isEnabled = session.canStart || session.isListening
        cancelItem.isEnabled = session.isGestureActive
        pasteItem.isEnabled = session.lastInsertedText != nil

        if meeting.isRecording {
            let seconds = Int(meeting.elapsed)
            meetingToggleItem.title = String(format: "Stop Meeting Transcription (%d:%02d)", seconds / 60, seconds % 60)
        } else {
            meetingToggleItem.title = "Start Meeting Transcription"
        }
        meetingToggleItem.isEnabled = meeting.isActive || meeting.canStart
        statusItem.button?.title = statusTitle
    }

    private var statusTitle: String {
        if meeting.isRecording { return "● LocalFlow REC" }
        switch session.state {
        case .idle: return "LocalFlow"
        case .warming: return "LocalFlow…"
        case .listening: return "● LocalFlow"
        case .transcribing, .cleaning, .inserting: return "LocalFlow…"
        case .error: return "! LocalFlow"
        }
    }

    private var stateDescription: String {
        switch meeting.state {
        case .idle, .error: break
        case .starting: return "Meeting: starting"
        case .recording(let startedAt):
            let seconds = Int(Date().timeIntervalSince(startedAt))
            return String(format: "Meeting: recording %d:%02d", seconds / 60, seconds % 60)
        case .finishing: return "Meeting: finishing"
        }
        switch session.state {
        case .idle: return "State: idle"
        case .warming(let phase): return "State: \(phase)"
        case .listening(let date): return "State: listening since \(date.formatted(date: .omitted, time: .standard))"
        case .transcribing: return "State: transcribing"
        case .cleaning: return "State: cleaning"
        case .inserting: return "State: inserting"
        case .error(let message): return "State: error — \(message)"
        }
    }

    @objc private func toggleDictation() {
        if session.canStart {
            Task { await session.startDictation() }
        } else {
            session.requestStop()
        }
        refresh()
    }

    @objc private func cancelDictation() {
        session.cancelDictation()
        refresh()
    }

    @objc private func toggleMeeting() {
        if meeting.isRecording {
            Task { await meeting.stop() }
        } else {
            Task { await meeting.start() }
        }
        refresh()
    }

    @objc private func openMeetingsFolder() {
        let dir = MeetingTranscriptWriter.meetingsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func pasteLast() {
        session.pasteLastTranscript()
    }

    @objc private func openHub() {
        appDelegate?.showHub()
    }

    @objc private func openSettings() {
        appDelegate?.showSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
