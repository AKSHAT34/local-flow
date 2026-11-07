import Foundation

/// Appends timestamped diagnostic lines to LocalFlow.log in Application Support.
public enum LocalFlowLog {
    private static let queue = DispatchQueue(label: "com.localflow.log")

    public static func write(_ message: String) {
        queue.async {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("LocalFlow", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let url = base.appendingPathComponent("localflow.log")
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }
}
