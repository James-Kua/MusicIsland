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

    /// The log is only ever read for its recent tail, so start it over rather
    /// than letting an app that runs for weeks grow it without bound.
    private static let maximumSize: UInt64 = 2_000_000

    private static func append(_ data: Data) {
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
           size.uint64Value > maximumSize {
            try? FileManager.default.removeItem(at: url)
        }
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
