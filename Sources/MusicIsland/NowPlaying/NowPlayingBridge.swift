import AppKit
import Foundation

/// Reads now-playing information from macOS's private `MediaRemote` framework
/// (loaded dynamically via `dlopen`), and reports track/playback changes as they
/// happen so the UI does not have to wait for the next poll.
///
/// On macOS 15.4 and later the in-process read returns nothing — MediaRemote
/// only answers Apple-signed binaries — so the read falls through to
/// `NowPlayingHelperProcess`, which streams the same metadata from a helper.
/// A NetEase-specific placeholder covers the case where neither path has data.
final class NowPlayingBridge: @unchecked Sendable {
    private typealias CopyNowPlayingInfo = @convention(c) (DispatchQueue, @escaping (NSDictionary) -> Void) -> Void
    private typealias GetNowPlayingApplicationPID = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void
    private typealias RegisterForNotifications = @convention(c) (DispatchQueue) -> Void

    /// Called on the main thread when MediaRemote reports a change. Set it
    /// before the first read; it is only ever touched from the main thread.
    var onNowPlayingChange: (() -> Void)?

    private static let changeNotificationNames = [
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"
    ]

    private let callbackQueue = DispatchQueue(label: "app.musicisland.mediaremote")
    private let handle: UnsafeMutableRawPointer?
    private let copyInfo: CopyNowPlayingInfo?
    private let getPID: GetNowPlayingApplicationPID?
    private let helper = NowPlayingHelperProcess()
    private var observers: [NSObjectProtocol] = []
    private var changeCoalesceTask: DispatchWorkItem?
    private var cachedSnapshot = NowPlayingSnapshot(track: .empty, elapsed: 0, duration: 0, artworkData: nil)
    /// Written on the main thread when a helper line arrives, read from the
    /// background poll, so both sides go through this lock.
    private let helperLock = NSLock()
    private var helperSnapshot: NowPlayingSnapshot?
    private var helperSnapshotAt: Date?
    private var lastPopulatedRead: Date?
    /// How long a populated read keeps standing when MediaRemote answers with an
    /// empty dictionary. Those blanks are usually a dropped reply rather than a
    /// stopped player, and reacting to them resets the track identity — which
    /// wipes the lyric that was already on screen.
    private let emptyReadGracePeriod: TimeInterval = 4

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        if let handle {
            copyInfo = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo").map {
                unsafeBitCast($0, to: CopyNowPlayingInfo.self)
            }
            getPID = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID").map {
                unsafeBitCast($0, to: GetNowPlayingApplicationPID.self)
            }
            registerForChangeNotifications(handle: handle)
        } else {
            copyInfo = nil
            getPID = nil
        }

        helper.onPayload = { [weak self] payload in
            self?.applyHelperPayload(payload)
        }
    }

    deinit {
        changeCoalesceTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        helper.stop()
        if let handle {
            dlclose(handle)
        }
    }

    /// Whether now-playing metadata cannot be read at all: this macOS blocks the
    /// in-process read and the helper it would fall back on cannot run.
    var isNowPlayingAccessBlocked: Bool {
        helperLock.lock()
        defer { helperLock.unlock() }
        return helper.isUnavailable && helperSnapshot == nil
    }

    private func applyHelperPayload(_ payload: NowPlayingHelperProcess.Payload) {
        let elapsed = adjustedElapsed(
            baseElapsed: payload.elapsed,
            timestamp: payload.timestamp,
            playbackRate: payload.isPlaying ? 1 : 0
        )

        helperLock.lock()
        // Heartbeat lines leave artwork out to keep them small, so carry the
        // cover over from the change event — but only while the same song is
        // playing, never onto a new one.
        let isSameTrack = helperSnapshot?.track.title == payload.title
            && helperSnapshot?.track.artist == payload.artist
        helperSnapshot = NowPlayingSnapshot(
            track: Track(
                title: payload.title,
                artist: payload.artist,
                album: payload.album,
                isPlaying: payload.isPlaying,
                appName: payload.appName.isEmpty ? "NetEase Music" : payload.appName
            ),
            elapsed: elapsed,
            duration: payload.duration > 0 ? payload.duration : (isSameTrack ? helperSnapshot?.duration ?? 0 : 0),
            artworkData: payload.artworkData ?? (isSameTrack ? helperSnapshot?.artworkData : nil)
        )
        helperSnapshotAt = Date()
        helperLock.unlock()

        onNowPlayingChange?()
    }

    private func registerForChangeNotifications(handle: UnsafeMutableRawPointer) {
        guard let symbol = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") else { return }
        unsafeBitCast(symbol, to: RegisterForNotifications.self)(callbackQueue)

        observers = Self.changeNotificationNames.map { name in
            NotificationCenter.default.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleChangeNotification()
            }
        }
    }

    /// A single skip fires several notifications in a row; collapse them into
    /// one read so a burst does not queue up redundant MediaRemote round-trips.
    private func handleChangeNotification() {
        changeCoalesceTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.onNowPlayingChange?()
        }
        changeCoalesceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: task)
    }

    func currentTrack() -> NowPlayingSnapshot {
        guard let copyInfo else {
            helper.startIfNeeded()
            return streamedSnapshot() ?? netEaseFallback() ?? cachedSnapshot
        }

        let group = DispatchGroup()
        var info = NSDictionary()
        var pid: Int32 = 0

        group.enter()
        copyInfo(callbackQueue) { dictionary in
            info = dictionary
            group.leave()
        }

        if let getPID {
            group.enter()
            getPID(callbackQueue) { value in
                pid = value
                group.leave()
            }
        }

        // One shared budget for both replies, rather than one per callback.
        _ = group.wait(timeout: .now() + 0.8)

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
            // Either nothing is playing, or this macOS refuses the in-process
            // read. The helper answers both cases; while it is starting up, an
            // established snapshot keeps standing briefly, because a blank read
            // resets the track identity and wipes the lyric already on screen.
            helper.startIfNeeded()
            if let streamed = streamedSnapshot() {
                lastPopulatedRead = Date()
                cachedSnapshot = streamed
                return streamed
            }
            if let lastPopulatedRead,
               Date().timeIntervalSince(lastPopulatedRead) < emptyReadGracePeriod,
               cachedSnapshot.track.title != Track.empty.title {
                return cachedSnapshot
            }
            self.lastPopulatedRead = nil
            cachedSnapshot = netEaseFallback()
                ?? blockedAccessSnapshot()
                ?? .init(track: .empty, elapsed: 0, duration: 0, artworkData: nil)
            return cachedSnapshot
        }

        lastPopulatedRead = Date()
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

    /// The most recent line from the helper, with its position projected to now.
    /// Lines stop arriving if the helper dies, so anything older than a few
    /// heartbeats is treated as no data rather than reported as current.
    private func streamedSnapshot() -> NowPlayingSnapshot? {
        helperLock.lock()
        defer { helperLock.unlock() }
        guard let snapshot = helperSnapshot, let receivedAt = helperSnapshotAt,
              Date().timeIntervalSince(receivedAt) < 12
        else { return nil }

        guard snapshot.track.isPlaying else { return snapshot }
        return NowPlayingSnapshot(
            track: snapshot.track,
            elapsed: snapshot.elapsed + Date().timeIntervalSince(receivedAt),
            duration: snapshot.duration,
            artworkData: snapshot.artworkData
        )
    }

    /// Shown when this macOS blocks the in-process read and the helper cannot
    /// run either. Without it the island just says "Nothing playing" forever,
    /// with no hint that anything is wrong or how to fix it.
    private func blockedAccessSnapshot() -> NowPlayingSnapshot? {
        guard isNowPlayingAccessBlocked else { return nil }
        return NowPlayingSnapshot(track: .nowPlayingUnavailable, elapsed: 0, duration: 0, artworkData: nil)
    }

    private func netEaseFallback() -> NowPlayingSnapshot? {
        guard let app = NetEaseController.runningApplication() else { return nil }
        var track = Track.netEaseWaiting
        track.appName = app.localizedName ?? "NetEase Music"
        return NowPlayingSnapshot(
            track: track,
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
