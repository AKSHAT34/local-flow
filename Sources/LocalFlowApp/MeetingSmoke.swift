import AppKit
import Foundation
import LocalFlowCore

/// `--meeting-smoke [seconds]` launch mode.
///
/// Starts a real MeetingSession (mic + ScreenCaptureKit system audio), records
/// for the given duration, stops, and exits. Used to verify the live capture
/// path end-to-end without driving the menu bar UI. Must run inside the app
/// bundle so TCC attributes permissions to LocalFlow.
@MainActor
final class MeetingSmokeDelegate: NSObject, NSApplicationDelegate {
    private let duration: TimeInterval

    init(duration: TimeInterval) {
        self.duration = duration
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await run() }
    }

    private func run() async {
        defer { NSApp.terminate(nil) }
        let startedAt = Date()
        LocalFlowLog.write("meeting-smoke: starting (\(Int(duration))s)")
        let settings = Settings()
        let store = try? HistoryStore()
        let engines = ASREngineProvider()
        let session = MeetingSession(settings: settings, engines: engines, store: store)

        await session.start()
        guard session.isRecording else {
            LocalFlowLog.write("meeting-smoke: did not reach recording state (state=\(session.state))")
            return
        }
        LocalFlowLog.write("meeting-smoke: recording -> \(session.filePath ?? "?")")

        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        await session.stop()

        let elapsed = Date().timeIntervalSince(startedAt)
        let mb = MemoryProbe.currentMB().map { String(format: "%.1f", $0) } ?? "?"
        LocalFlowLog.write(
            "meeting-smoke: done state=\(session.state) lines=\(session.lineCount) " +
            "elapsed=\(String(format: "%.1f", elapsed))s footprintMB=\(mb) file=\(session.filePath ?? "none")"
        )
    }
}
