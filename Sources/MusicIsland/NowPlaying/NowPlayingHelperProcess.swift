import Foundation

/// Streams now-playing updates from a helper process.
///
/// Since macOS 15.4, `MRMediaRemoteGetNowPlayingInfo` only answers binaries
/// Apple has signed: read from inside MusicIsland it returns an empty
/// dictionary, while the very same code run through `/usr/bin/swift` returns the
/// real metadata. So the read is delegated to a Swift interpreter process.
///
/// That process is started **once** and kept alive. It registers for
/// MediaRemote's change notifications and writes a JSON line whenever the track
/// or playback state changes, which both removes the repeated interpreter
/// start-up cost and lets a skip show up immediately instead of on the next
/// poll.
final class NowPlayingHelperProcess: @unchecked Sendable {
    struct Payload {
        let title: String
        let artist: String
        let album: String
        let appName: String
        let artworkData: Data?
        let isPlaying: Bool
        let elapsed: TimeInterval
        let duration: TimeInterval
        let timestamp: Date?
    }

    /// Called on the main thread for every update the helper reports.
    var onPayload: ((Payload) -> Void)?

    /// True once the helper has been tried and cannot be run at all — the Swift
    /// toolchain it needs is missing, so now-playing metadata is unavailable.
    /// Set on the helper's queue and read from the poll, hence the lock.
    var isUnavailable: Bool {
        get {
            unavailableLock.lock()
            defer { unavailableLock.unlock() }
            return unavailable
        }
        set {
            unavailableLock.lock()
            unavailable = newValue
            unavailableLock.unlock()
        }
    }

    private let unavailableLock = NSLock()
    private var unavailable = false

    private let interpreterURL = URL(fileURLWithPath: "/usr/bin/swift")
    private let queue = DispatchQueue(label: "app.musicisland.nowplaying-helper")
    private var process: Process?
    private var standardInput: Pipe?
    private var buffer = Data()
    private var restartDelay: TimeInterval = 2
    private var isStopping = false
    private var launchedAt = Date()
    private var consecutiveQuickFailures = 0
    private let quickFailureLimit = 3

    deinit {
        stop()
    }

    /// Starts the helper if it is not already running. Safe to call on every
    /// read; only the first call does any work.
    func startIfNeeded() {
        queue.async { [self] in
            guard process == nil, !isUnavailable, !isStopping else { return }
            launch()
        }
    }

    func stop() {
        isStopping = true
        process?.terminate()
        process = nil
        standardInput = nil
    }

    private func launch() {
        guard FileManager.default.isExecutableFile(atPath: interpreterURL.path), hasDeveloperToolchain() else {
            isUnavailable = true
            DebugLog.write("nowplaying helper unavailable: no Swift toolchain at \(interpreterURL.path)")
            return
        }

        let process = Process()
        process.executableURL = interpreterURL
        process.arguments = ["-e", Self.streamingProbeSource]

        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // The helper exits when this pipe closes, so it cannot outlive the app.
        process.standardInput = input

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }

        process.terminationHandler = { [weak self] terminated in
            self?.queue.async { self?.handleTermination(status: terminated.terminationStatus) }
        }

        do {
            try process.run()
            self.process = process
            standardInput = input
            launchedAt = Date()
            buffer.removeAll(keepingCapacity: false)
            DebugLog.write("nowplaying helper started pid=\(process.processIdentifier)")
        } catch {
            isUnavailable = true
            DebugLog.write("nowplaying helper failed to start: \(error.localizedDescription)")
        }
    }

    /// `/usr/bin/swift` is only a stub until the developer tools are installed,
    /// and running the stub asks the user to install them. `xcode-select -p`
    /// answers whether a real toolchain is behind it without prompting.
    private func hasDeveloperToolchain() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func handleTermination(status: Int32) {
        process = nil
        standardInput = nil
        guard !isStopping else { return }

        // A helper that dies immediately is a helper that cannot run here.
        // Retrying it forever would spawn processes for the life of the app.
        if status != 0, Date().timeIntervalSince(launchedAt) < 3 {
            consecutiveQuickFailures += 1
            if consecutiveQuickFailures >= quickFailureLimit {
                isUnavailable = true
                DebugLog.write("nowplaying helper gave up after \(consecutiveQuickFailures) immediate failures")
                return
            }
        }

        DebugLog.write("nowplaying helper exited status=\(status), restarting in \(restartDelay)s")
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 60)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, process == nil, !isStopping else { return }
            launch()
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let payload = Self.payload(from: Data(line)) else { continue }
            // A line that parses means the helper is healthy; reset the backoff
            // so an unrelated crash later is retried promptly.
            restartDelay = 2
            consecutiveQuickFailures = 0
            DispatchQueue.main.async { [weak self] in
                self?.onPayload?(payload)
            }
        }
    }

    private static func payload(from data: Data) -> Payload? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let title = json["title"] as? String,
            !title.isEmpty
        else { return nil }

        let artwork = (json["artworkBase64"] as? String).flatMap { $0.isEmpty ? nil : Data(base64Encoded: $0) }
        return Payload(
            title: title,
            artist: json["artist"] as? String ?? "",
            album: json["album"] as? String ?? "",
            appName: json["appName"] as? String ?? "",
            artworkData: artwork,
            isPlaying: json["isPlaying"] as? Bool ?? false,
            elapsed: json["elapsed"] as? TimeInterval ?? 0,
            duration: json["duration"] as? TimeInterval ?? 0,
            timestamp: (json["timestamp"] as? String).flatMap(isoDateFormatter.date(from:))
        )
    }

    private static let isoDateFormatter = ISO8601DateFormatter()

    /// Source for the streaming now-playing helper. It emits a JSON line on
    /// every MediaRemote change notification, plus a lighter heartbeat line in
    /// case a notification is missed. Artwork only rides along with change
    /// events — it is by far the largest field, and it does not change between
    /// them.
    private static let streamingProbeSource = #"""
    import AppKit
    import Foundation

    typealias CopyNowPlayingInfo = @convention(c) (DispatchQueue, @escaping (NSDictionary) -> Void) -> Void
    typealias GetNowPlayingApplicationPID = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void
    typealias RegisterForNotifications = @convention(c) (DispatchQueue) -> Void

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

    let workQueue = DispatchQueue(label: "app.musicisland.helper-probe")
    let formatter = ISO8601DateFormatter()

    func emit(includeArtwork: Bool) {
        let group = DispatchGroup()
        var info = NSDictionary()
        var pid: Int32 = 0

        group.enter()
        copyInfo(workQueue) { dictionary in
            info = dictionary
            group.leave()
        }
        if let getPID {
            group.enter()
            getPID(workQueue) { value in
                pid = value
                group.leave()
            }
        }
        guard group.wait(timeout: .now() + 2) == .success else { return }

        let title = stringValue(info, "kMRMediaRemoteNowPlayingInfoTitle")
        guard !title.isEmpty else { return }

        let rate = numberValue(info, "kMRMediaRemoteNowPlayingInfoPlaybackRate")
        let artwork = includeArtwork
            ? (info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data)?.base64EncodedString() ?? ""
            : ""
        let payload: [String: Any] = [
            "title": title,
            "artist": stringValue(info, "kMRMediaRemoteNowPlayingInfoArtist"),
            "album": stringValue(info, "kMRMediaRemoteNowPlayingInfoAlbum"),
            "artworkBase64": artwork,
            "elapsed": numberValue(info, "kMRMediaRemoteNowPlayingInfoElapsedTime"),
            "duration": numberValue(info, "kMRMediaRemoteNowPlayingInfoDuration"),
            "timestamp": formatter.string(from: (info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date) ?? Date()),
            "isPlaying": rate > 0,
            "appName": NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        ]

        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    // Exit as soon as the parent goes away and its end of the pipe closes.
    DispatchQueue.global().async {
        while !FileHandle.standardInput.availableData.isEmpty {}
        exit(0)
    }

    if let registerSymbol = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
        unsafeBitCast(registerSymbol, to: RegisterForNotifications.self)(DispatchQueue.main)
        let names = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { _ in
                emit(includeArtwork: true)
            }
        }
    }

    emit(includeArtwork: true)
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
        emit(includeArtwork: false)
    }
    RunLoop.main.run()
    """#
}
