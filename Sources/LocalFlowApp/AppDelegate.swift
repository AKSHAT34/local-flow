import AppKit
import Combine
import LocalFlowCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = Settings()
    let store: HistoryStore?
    let engines = ASREngineProvider()
    let session: DictationSession
    let meeting: MeetingSession

    private var menuBar: MenuBarController!
    private var settingsWindow: SettingsWindowController!
    private var hubWindow: HubWindowController!
    private var flowBar: FlowBarController!
    private var cancellables = Set<AnyCancellable>()

    override init() {
        store = try? HistoryStore()
        session = DictationSession(settings: settings, store: store, engines: engines)
        meeting = MeetingSession(settings: settings, engines: engines, store: store, dictation: session)
        session.meetingSession = meeting
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(session: session, meeting: meeting, settings: settings, appDelegate: self)
        settingsWindow = SettingsWindowController(settings: settings, session: session)
        hubWindow = HubWindowController(store: store, session: session, meeting: meeting, settings: settings, appDelegate: self)
        flowBar = FlowBarController(session: session, meeting: meeting, settings: settings)
        flowBar.start()

        session.objectWillChange
            .sink { [weak self] _ in self?.menuBar?.refresh() }
            .store(in: &cancellables)
        meeting.objectWillChange
            .sink { [weak self] _ in self?.menuBar?.refresh() }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in self?.menuBar?.refresh() }
            .store(in: &cancellables)

        session.startServices()
        meeting.startServices()
        menuBar.refresh()

        // Apply a non-default speech locale before the first dictation warms.
        if settings.asrLocale != "en-US" {
            Task { await engines.setSpeechLocale(settings.asrLocale) }
        }

        LocalFlowLog.write("launch: axTrusted=\(Permissions.accessibilityTrusted) screenCapture=\(Permissions.screenCaptureTrusted)")
        if !Permissions.accessibilityTrusted {
            LocalFlowLog.write("launch: requesting accessibility prompt")
            _ = Permissions.requestAccessibility(prompt: true)
        }

        Task {
            let status = await Permissions.status()
            guard !(status.microphone && status.speechRecognition && status.accessibility) else { return }
            LocalFlowLog.write("launch: permissions incomplete; opening Hub on Setup")
            hubWindow.show(pane: .setup)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.stopServices()
        meeting.stopServices()
        flowBar?.stop()
        Task { await meeting.emergencyStop() }
    }

    func showSettings() {
        settingsWindow.show()
    }

    func showHub() {
        hubWindow.show()
    }
}
