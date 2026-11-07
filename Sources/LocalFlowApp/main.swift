import AppKit
import LocalFlowCore

@main
enum LocalFlowMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate: NSApplicationDelegate
        if let mode = transcribeMeetingArguments() {
            delegate = TranscribeMeetingDelegate(mePath: mode.me, themPath: mode.them, outputPath: mode.output)
        } else if let seconds = meetingSmokeArguments() {
            delegate = MeetingSmokeDelegate(duration: seconds)
        } else if let mode = transcribeFileArguments() {
            delegate = TranscribeFileDelegate(inputPath: mode.input, outputPath: mode.output)
        } else {
            delegate = AppDelegate()
        }
        app.delegate = delegate
        app.run()
    }

    /// Parses `--transcribe-meeting <me> <them> [--out <path>]`; nil for normal launch.
    private static func transcribeMeetingArguments() -> (me: String, them: String, output: String)? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "--transcribe-meeting"),
              args.indices.contains(flagIndex + 2) else { return nil }
        var output = "/tmp/localflow_meeting.md"
        if let outIndex = args.firstIndex(of: "--out"), args.indices.contains(outIndex + 1) {
            output = args[outIndex + 1]
        }
        return (args[flagIndex + 1], args[flagIndex + 2], output)
    }

    /// Parses `--meeting-smoke [seconds]` (default 12); nil for normal launch.
    private static func meetingSmokeArguments() -> TimeInterval? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "--meeting-smoke") else { return nil }
        if args.indices.contains(flagIndex + 1), let value = TimeInterval(args[flagIndex + 1]), value > 0 {
            return value
        }
        return 12
    }

    /// Parses `--transcribe-file <path> [--out <path>]`; returns nil for normal launch.
    private static func transcribeFileArguments() -> (input: String, output: String)? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "--transcribe-file"),
              args.indices.contains(flagIndex + 1) else { return nil }
        var output = "/tmp/localflow_transcribe.txt"
        if let outIndex = args.firstIndex(of: "--out"), args.indices.contains(outIndex + 1) {
            output = args[outIndex + 1]
        }
        return (args[flagIndex + 1], output)
    }
}
