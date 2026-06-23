import AppKit
import Foundation

/// Reads now-playing information from macOS's private `MediaRemote` framework
/// (loaded dynamically via `dlopen`). Falls back to a sub-process probe and a
/// NetEase-specific placeholder when no media metadata is available.
final class NowPlayingBridge: @unchecked Sendable {
    private typealias CopyNowPlayingInfo = @convention(c) (DispatchQueue, @escaping (NSDictionary) -> Void) -> Void
    private typealias GetNowPlayingApplicationPID = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void

    private let callbackQueue = DispatchQueue(label: "app.musicisland.mediaremote")
    private let handle: UnsafeMutableRawPointer?
    private let copyInfo: CopyNowPlayingInfo?
    private let getPID: GetNowPlayingApplicationPID?
    private var cachedSnapshot = NowPlayingSnapshot(track: .empty, elapsed: 0, duration: 0, artworkData: nil)
    private var lastHelperSuccess: Date?
    private let helperCooldown: TimeInterval = 2

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        if let handle {
            copyInfo = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo").map {
                unsafeBitCast($0, to: CopyNowPlayingInfo.self)
            }
            getPID = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID").map {
                unsafeBitCast($0, to: GetNowPlayingApplicationPID.self)
            }
        } else {
            copyInfo = nil
            getPID = nil
        }
    }

    deinit {
        if let handle {
            dlclose(handle)
        }
    }

    func currentTrack() -> NowPlayingSnapshot {
        guard let copyInfo else { return netEaseFallback() ?? cachedSnapshot }

        let semaphore = DispatchSemaphore(value: 0)
        var info = NSDictionary()
        var pid: Int32 = 0
        var pendingCallbacks = 1

        copyInfo(callbackQueue) { dictionary in
            info = dictionary
            semaphore.signal()
        }

        if let getPID {
            pendingCallbacks += 1
            getPID(callbackQueue) { value in
                pid = value
                semaphore.signal()
            }
        }

        for _ in 0..<pendingCallbacks {
            _ = semaphore.wait(timeout: .now() + 0.8)
        }

        let title = stringValue(info, keys: ["kMRMediaRemoteNowPlayingInfoTitle", "title"])
        let artist = stringValue(info, keys: ["kMRMediaRemoteNowPlayingInfoArtist", "artist"])
        let album = stringValue(info, keys: ["kMRMediaRemoteNowPlayingInfoAlbum", "album"])
        let artworkData = dataValue(info, keys: ["kMRMediaRemoteNowPlayingInfoArtworkData"])
        let rate = numberValue(info, keys: ["kMRMediaRemoteNowPlayingInfoPlaybackRate"]) ?? 0
        let duration = numberValue(info, keys: ["kMRMediaRemoteNowPlayingInfoDuration"]) ?? cachedSnapshot.duration
        let elapsed = adjustedElapsed(
            baseElapsed: numberValue(info, keys: ["kMRMediaRemoteNowPlayingInfoElapsedTime"]) ?? cachedSnapshot.elapsed,
            timestamp: dateValue(info, keys: ["kMRMediaRemoteNowPlayingInfoTimestamp"]),
            playbackRate: rate
        )
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""

        guard !title.isEmpty else {
            cachedSnapshot = throttledHelperSnapshot() ?? netEaseFallback() ?? .init(track: .empty, elapsed: 0, duration: 0, artworkData: nil)
            return cachedSnapshot
        }

        cachedSnapshot = NowPlayingSnapshot(
            track: Track(
                title: title,
                artist: artist,
                album: album,
                isPlaying: rate > 0,
                appName: appName
            ),
            elapsed: elapsed,
            duration: duration,
            artworkData: artworkData ?? cachedSnapshot.artworkData
        )
        return cachedSnapshot
    }

    /// Runs the now-playing probe in a fresh `swift` interpreter process. This is
    /// a fallback for cases where the in-process MediaRemote call returns nothing.
    private func throttledHelperSnapshot() -> NowPlayingSnapshot? {
        let now = Date()
        if let lastHelperSuccess, now.timeIntervalSince(lastHelperSuccess) < helperCooldown {
            return cachedSnapshot.track.title == Track.empty.title ? nil : cachedSnapshot
        }
        guard let snapshot = helperSnapshot() else { return nil }
        lastHelperSuccess = now
        return snapshot
    }

    private func helperSnapshot() -> NowPlayingSnapshot? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["-e", Self.interpreterProbeSource]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        guard ProcessRunner.run(process, timeout: 2.5) else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let title = json["title"] as? String,
            !title.isEmpty
        else { return nil }

        let artist = json["artist"] as? String ?? ""
        let album = json["album"] as? String ?? ""
        let appName = json["appName"] as? String ?? "NetEase Music"
        let artworkData = (json["artworkBase64"] as? String).flatMap { Data(base64Encoded: $0) }
        let isPlaying = (json["isPlaying"] as? Bool) ?? true
        let rate = isPlaying ? 1.0 : 0.0
        let duration = json["duration"] as? TimeInterval ?? cachedSnapshot.duration
        let elapsed = adjustedElapsed(
            baseElapsed: json["elapsed"] as? TimeInterval ?? cachedSnapshot.elapsed,
            timestamp: (json["timestamp"] as? String).flatMap(Self.isoDateFormatter.date(from:)),
            playbackRate: rate
        )

        return NowPlayingSnapshot(
            track: Track(
                title: title,
                artist: artist,
                album: album,
                isPlaying: isPlaying,
                appName: appName
            ),
            elapsed: elapsed,
            duration: duration,
            artworkData: artworkData ?? cachedSnapshot.artworkData
        )
    }

    /// Source for the out-of-process now-playing probe (see `helperSnapshot`).
    private static let interpreterProbeSource = #"""
    import AppKit
    import Foundation

    typealias CopyNowPlayingInfo = @convention(c) (DispatchQueue, @escaping (NSDictionary) -> Void) -> Void
    typealias GetNowPlayingApplicationPID = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void

    func stringValue(_ info: NSDictionary, _ key: String) -> String {
        if let value = info[key] as? String { return value }
        if let value = info[key] as? NSString { return value as String }
        return ""
    }

    func numberValue(_ info: NSDictionary, _ key: String) -> Double {
        if let value = info[key] as? NSNumber { return value.doubleValue }
        if let value = info[key] as? Double { return value }
        if let value = info[key] as? String, let number = Double(value) { return number }
        if let value = info[key] as? NSString { return value.doubleValue }
        return 0
    }

    let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
    guard let handle, let copySymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else { exit(2) }

    let copyInfo = unsafeBitCast(copySymbol, to: CopyNowPlayingInfo.self)
    let getPID = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID").map {
        unsafeBitCast($0, to: GetNowPlayingApplicationPID.self)
    }

    let queue = DispatchQueue(label: "app.musicisland.interpreter-probe")
    let semaphore = DispatchSemaphore(value: 0)
    var info = NSDictionary()
    var pid: Int32 = 0
    var callbacks = 1

    copyInfo(queue) { dictionary in
        info = dictionary
        semaphore.signal()
    }

    if let getPID {
        callbacks += 1
        getPID(queue) { value in
            pid = value
            semaphore.signal()
        }
    }

    for _ in 0..<callbacks {
        _ = semaphore.wait(timeout: .now() + 1.5)
    }

    let title = stringValue(info, "kMRMediaRemoteNowPlayingInfoTitle")
    guard !title.isEmpty else { exit(1) }

    let rate = numberValue(info, "kMRMediaRemoteNowPlayingInfoPlaybackRate")
    let payload: [String: Any] = [
        "title": title,
        "artist": stringValue(info, "kMRMediaRemoteNowPlayingInfoArtist"),
        "album": stringValue(info, "kMRMediaRemoteNowPlayingInfoAlbum"),
        "artworkBase64": (info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data)?.base64EncodedString() ?? "",
        "elapsed": numberValue(info, "kMRMediaRemoteNowPlayingInfoElapsedTime"),
        "duration": numberValue(info, "kMRMediaRemoteNowPlayingInfoDuration"),
        "timestamp": ISO8601DateFormatter().string(from: (info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date) ?? Date()),
        "isPlaying": rate > 0,
        "appName": NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
    ]

    let data = try JSONSerialization.data(withJSONObject: payload)
    FileHandle.standardOutput.write(data)
    """#

    private func netEaseFallback() -> NowPlayingSnapshot? {
        guard let app = NetEaseController.runningApplication() else { return nil }
        return NowPlayingSnapshot(
            track: Track(
                title: "NetEase Music is active",
                artist: "Waiting for macOS Now Playing metadata",
                album: "",
                isPlaying: true,
                appName: app.localizedName ?? "NetEase Music"
            ),
            elapsed: cachedSnapshot.elapsed,
            duration: cachedSnapshot.duration,
            artworkData: cachedSnapshot.artworkData
        )
    }

    private func stringValue(_ info: NSDictionary, keys: [String]) -> String {
        for key in keys {
            if let value = info[key] as? String, !value.isEmpty {
                return value
            }
            if let value = info[key] as? NSString, value.length > 0 {
                return value as String
            }
        }
        return ""
    }

    private func numberValue(_ info: NSDictionary, keys: [String]) -> TimeInterval? {
        for key in keys {
            if let value = info[key] as? NSNumber {
                return value.doubleValue
            }
            if let value = info[key] as? Double {
                return value
            }
            if let value = info[key] as? String, let number = Double(value) {
                return number
            }
            if let value = info[key] as? NSString {
                return value.doubleValue
            }
        }
        return nil
    }

    private func dataValue(_ info: NSDictionary, keys: [String]) -> Data? {
        for key in keys {
            if let value = info[key] as? Data {
                return value
            }
            if let value = info[key] as? NSData {
                return value as Data
            }
        }
        return nil
    }

    private func dateValue(_ info: NSDictionary, keys: [String]) -> Date? {
        for key in keys {
            if let value = info[key] as? Date {
                return value
            }
            if let value = info[key] as? String {
                if let date = Self.isoDateFormatter.date(from: value) {
                    return date
                }
                if let date = Self.mediaRemoteDateFormatter.date(from: value) {
                    return date
                }
            }
        }
        return nil
    }

    private func adjustedElapsed(baseElapsed: TimeInterval, timestamp: Date?, playbackRate: Double) -> TimeInterval {
        guard playbackRate > 0, let timestamp else { return baseElapsed }
        return max(0, baseElapsed + Date().timeIntervalSince(timestamp) * playbackRate)
    }

    private static let isoDateFormatter = ISO8601DateFormatter()
    private static let mediaRemoteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()
}
