import Foundation

/// Lightweight append-only file logger used for diagnosing playback-control and
/// now-playing issues. Writes to `/private/tmp/musicisland-debug.log`.
enum DebugLog {
    private static let url = URL(fileURLWithPath: "/private/tmp/musicisland-debug.log")
    /// Callers include the main thread, and opening, appending to, and closing a
    /// file is not something the UI should ever wait on.
    private static let queue = DispatchQueue(label: "app.musicisland.debuglog", qos: .utility)

    static func write(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async { append(data) }
    }

    private static func append(_ data: Data) {
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
