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
///
/// A helper that lives that long has to be supervised: after the Mac sleeps it
/// can be left running but deaf, reporting nothing while music plays. So the
/// helper is replaced when the system wakes, when it stops writing, and — with
/// a growing delay — when it keeps reporting that nothing is playing.
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
    // Everything below is only touched on `queue` (apart from `stop()`, which
    // runs once, at teardown).
    private var process: Process?
    private var standardInput: Pipe?
    private var outputHandle: FileHandle?
    private var buffer = Data()
    private var restartDelay: TimeInterval = 2
    private var isStopping = false
    private var launchedAt = Date()
    private var consecutiveQuickFailures = 0
    private let quickFailureLimit = 3
    /// Bumped for every launch and teardown, so output and exit callbacks from
    /// a helper that has already been replaced are ignored.
    private var generation = 0
    /// When the helper last wrote a line. It writes one every few seconds even
    /// with nothing playing, so a long silence means it is hung.
    private var lastLineAt = Date()
    /// Set while the helper keeps reporting that nothing is playing. After the
    /// Mac sleeps, a long-running helper can be left with a dead MediaRemote
    /// connection that answers "nothing" forever; only a fresh process recovers.
    private var emptySince: Date?
    private var emptyRestartDelay: TimeInterval = NowPlayingHelperProcess.initialEmptyRestartDelay
    /// When a crashed helper is due to be relaunched. Wall-clock based and
    /// checked from the poll, so the backoff holds across sleep.
    private var relaunchAt: Date?
    private var unavailableSince: Date?
    /// Whether the helper may look past the app macOS has elected as "now
    /// playing" to find another one that is actually playing. That uses less
    /// well-trodden MediaRemote calls, so it is switched off for the rest of
    /// the session if the helper crashes while doing it.
    private var scanClientsEnabled = true
    private var scanInFlight = false
    private var scanUsed = false
    private var scanCrashes = 0

    private static let silenceLimit: TimeInterval = 25
    private static let initialEmptyRestartDelay: TimeInterval = 15
    private static let unavailableRetryInterval: TimeInterval = 300

    deinit {
        stop()
    }

    /// Starts the helper if it is not running, and replaces it if it has gone
    /// quiet or stale. Safe (and intended) to call on every read.
    ///
    /// `playerRunning` says a known player app is open, which makes a helper
    /// that reports "nothing playing" more suspicious and worth replacing
    /// sooner.
    func startIfNeeded(playerRunning: Bool = false) {
        queue.async { [self] in
            guard !isStopping else { return }
            let now = Date()

            guard process != nil else {
                if isUnavailable {
                    // Never give up for good: whatever stopped the helper from
                    // running (a toolchain update, a busy system right after
                    // wake) may well have passed.
                    guard let since = unavailableSince,
                          now.timeIntervalSince(since) > Self.unavailableRetryInterval
                    else { return }
                    clearFailureState()
                    DebugLog.write("nowplaying helper retrying after being unavailable")
                }
                if let relaunchAt, now < relaunchAt { return }
                launch()
                return
            }

            checkHealth(now: now, playerRunning: playerRunning)
        }
    }

    /// The Mac just woke up. A helper that was running through sleep is not
    /// trusted to still have a working MediaRemote connection, so replace it.
    func handleWake() {
        queue.async { [self] in
            guard !isStopping else { return }
            let wasInUse = process != nil || isUnavailable || relaunchAt != nil
            clearFailureState()
            guard wasInUse else { return }
            restart(reason: "system woke")
        }
    }

    /// The user is looking at an island that shows no track. If the helper is
    /// the one saying nothing is playing, get a second opinion from a fresh one.
    func recheckIfIdle() {
        queue.async { [self] in
            guard !isStopping else { return }
            if process == nil {
                guard isUnavailable || relaunchAt != nil else { return }
                clearFailureState()
                restart(reason: "island opened while helper was down")
            } else if emptySince != nil, Date().timeIntervalSince(launchedAt) > 10 {
                restart(reason: "island opened with no metadata")
            }
        }
    }

    func stop() {
        isStopping = true
        outputHandle?.readabilityHandler = nil
        try? standardInput?.fileHandleForWriting.close()
        process?.terminate()
        process = nil
        standardInput = nil
    }

    private func clearFailureState() {
        isUnavailable = false
        unavailableSince = nil
        consecutiveQuickFailures = 0
        restartDelay = 2
        relaunchAt = nil
        emptyRestartDelay = Self.initialEmptyRestartDelay
    }

    private func markUnavailable(_ message: String) {
        isUnavailable = true
        unavailableSince = Date()
        DebugLog.write(message)
    }

    private func checkHealth(now: Date, playerRunning: Bool) {
        let silence = now.timeIntervalSince(max(lastLineAt, launchedAt))
        if silence > Self.silenceLimit {
            restart(reason: "no output for \(Int(silence))s")
            return
        }

        guard let emptySince else { return }
        let limit = min(emptyRestartDelay, playerRunning ? 120 : 600)
        let emptyFor = now.timeIntervalSince(emptySince)
        if emptyFor > limit {
            // Usually nothing really is playing, so each fruitless restart
            // waits longer than the last.
            emptyRestartDelay = min(emptyRestartDelay * 3, 600)
            restart(reason: "no metadata for \(Int(emptyFor))s (playerRunning=\(playerRunning))")
        }
    }

    private func restart(reason: String) {
        DebugLog.write("nowplaying helper restarting: \(reason)")
        tearDown()
        launch()
    }

    /// Detaches from the current helper and makes it exit. Its remaining output
    /// and its termination callback are ignored via `generation`.
    private func tearDown() {
        generation += 1
        outputHandle?.readabilityHandler = nil
        outputHandle = nil
        // Closing stdin is what actually ends the helper; the signal is a
        // backstop, and may only reach the interpreter's launcher process.
        try? standardInput?.fileHandleForWriting.close()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        standardInput = nil
        buffer.removeAll(keepingCapacity: false)
    }

    private func launch() {
        relaunchAt = nil
        guard FileManager.default.isExecutableFile(atPath: interpreterURL.path), hasDeveloperToolchain() else {
            markUnavailable("nowplaying helper unavailable: no Swift toolchain at \(interpreterURL.path)")
            return
        }

        generation += 1
        let generation = self.generation

        let process = Process()
        process.executableURL = interpreterURL
        process.arguments = ["-e", Self.streamingProbeSource]
        var environment = ProcessInfo.processInfo.environment
        environment["MUSICISLAND_SCAN_CLIENTS"] = scanClientsEnabled ? "1" : "0"
        process.environment = environment

        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // The helper exits when this pipe closes, so it cannot outlive the app.
        process.standardInput = input

        let outputHandle = output.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // End of file. Left installed, the handler would be called in
                // a tight loop for as long as the handle lives.
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.consume(data, generation: generation) }
        }

        process.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            self?.queue.async { self?.handleTermination(status: status, generation: generation) }
        }

        do {
            try process.run()
            self.process = process
            self.outputHandle = outputHandle
            standardInput = input
            launchedAt = Date()
            lastLineAt = launchedAt
            emptySince = nil
            scanInFlight = false
            scanUsed = false
            buffer.removeAll(keepingCapacity: false)
            DebugLog.write("nowplaying helper started pid=\(process.processIdentifier) scanClients=\(scanClientsEnabled)")
        } catch {
            outputHandle.readabilityHandler = nil
            markUnavailable("nowplaying helper failed to start: \(error.localizedDescription)")
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

    private func handleTermination(status: Int32, generation: Int) {
        guard generation == self.generation else { return }
        outputHandle?.readabilityHandler = nil
        outputHandle = nil
        process = nil
        standardInput = nil
        guard !isStopping else { return }

        // Exit status 3 is the helper's own "MediaRemote stopped answering".
        if scanClientsEnabled, scanUsed, status != 0, status != 3 {
            scanCrashes += 1
            if scanInFlight || scanCrashes >= 2 {
                scanClientsEnabled = false
                DebugLog.write("nowplaying helper: looking at other players disabled after a crash (status=\(status))")
            }
        }

        // A helper that dies immediately is a helper that cannot run right now.
        // Stop spawning it for a while rather than once per poll.
        if status != 0, Date().timeIntervalSince(launchedAt) < 3 {
            consecutiveQuickFailures += 1
            if consecutiveQuickFailures >= quickFailureLimit {
                markUnavailable("nowplaying helper paused after \(consecutiveQuickFailures) immediate failures")
                return
            }
        }

        DebugLog.write("nowplaying helper exited status=\(status), restarting in \(restartDelay)s")
        // The next poll after this moment relaunches it; see `startIfNeeded`.
        relaunchAt = Date().addingTimeInterval(restartDelay)
        restartDelay = min(restartDelay * 2, 60)
    }

    private func consume(_ data: Data, generation: Int) {
        guard generation == self.generation else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            // A line that parses means the helper is alive; reset the backoff
            // so an unrelated crash later is retried promptly.
            lastLineAt = Date()
            restartDelay = 2
            consecutiveQuickFailures = 0

            if let event = json["event"] as? String {
                if event == "scan-begin" {
                    scanInFlight = true
                    scanUsed = true
                } else if event == "scan-ok" {
                    scanInFlight = false
                }
                continue
            }

            guard let payload = Self.payload(from: json) else {
                // Alive, but reporting that nothing is playing.
                if emptySince == nil {
                    emptySince = Date()
                }
                continue
            }
            emptySince = nil
            emptyRestartDelay = Self.initialEmptyRestartDelay
            DispatchQueue.main.async { [weak self] in
                self?.onPayload?(payload)
            }
        }
    }

    private static func payload(from json: [String: Any]) -> Payload? {
        guard let title = json["title"] as? String, !title.isEmpty else { return nil }

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
    ///
    /// macOS elects one app as "now playing" and can keep a paused player
    /// elected while another one (a YouTube tab, say) is playing. So when the
    /// elected app is not playing, the helper looks through every registered
    /// player and reports one that is. That player then stays on screen while
    /// paused, until the elected app starts playing again.
    ///
    /// A line is written even when nothing is playing (with an empty title), so
    /// the app can tell a quiet helper from a hung one. If MediaRemote stops
    /// answering altogether the helper exits and gets replaced.
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

    final class ProbeState {
        var consecutiveTimeouts = 0
        var lastSourceKey = ""
        var stickyPID: Int32 = 0
        var reportedScan = false
        var playerPaths: [Int32: AnyObject] = [:]
    }
    let probeState = ProbeState()

    final class Box<T> {
        var value: T?
    }

    let titleKey = "kMRMediaRemoteNowPlayingInfoTitle"
    let rateKey = "kMRMediaRemoteNowPlayingInfoPlaybackRate"

    typealias GetClients = @convention(c) (DispatchQueue, @escaping (NSArray?) -> Void) -> Void
    typealias GetLocalOrigin = @convention(c) () -> Unmanaged<AnyObject>?
    typealias CreatePlayerPath = @convention(c) (AnyObject?, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
    typealias GetInfoForPlayer = @convention(c) (AnyObject?, AnyObject?, DispatchQueue, @escaping (NSDictionary?, NSError?) -> Void) -> Void
    typealias ClientGetPID = @convention(c) (AnyObject?) -> Int32

    struct ClientAPI {
        let getClients: GetClients
        let getLocalOrigin: GetLocalOrigin
        let createPlayerPath: CreatePlayerPath
        let getInfoForPlayer: GetInfoForPlayer
        let clientPID: ClientGetPID
    }

    func loadClientAPI() -> ClientAPI? {
        guard
            ProcessInfo.processInfo.environment["MUSICISLAND_SCAN_CLIENTS"] == "1",
            let clients = dlsym(handle, "MRMediaRemoteGetNowPlayingClients"),
            let origin = dlsym(handle, "MRMediaRemoteGetLocalOrigin"),
            let path = dlsym(handle, "MRNowPlayingPlayerPathCreate"),
            let playerInfo = dlsym(handle, "MRMediaRemoteGetNowPlayingInfoForPlayer"),
            let clientPID = dlsym(handle, "MRNowPlayingClientGetProcessIdentifier")
        else { return nil }
        return ClientAPI(
            getClients: unsafeBitCast(clients, to: GetClients.self),
            getLocalOrigin: unsafeBitCast(origin, to: GetLocalOrigin.self),
            createPlayerPath: unsafeBitCast(path, to: CreatePlayerPath.self),
            getInfoForPlayer: unsafeBitCast(playerInfo, to: GetInfoForPlayer.self),
            clientPID: unsafeBitCast(clientPID, to: ClientGetPID.self)
        )
    }
    let clientAPI = loadClientAPI()

    // Looks through every player registered with MediaRemote, other than the
    // elected one, for one that is playing. Failing that, the player this
    // helper switched to earlier is kept, so pausing it does not flip the
    // display back to the elected app.
    func scanClients(_ api: ClientAPI, excluding electedPID: Int32) -> (info: NSDictionary, pid: Int32)? {
        let listed = DispatchSemaphore(value: 0)
        let clientsBox = Box<NSArray>()
        api.getClients(workQueue) { clients in
            clientsBox.value = clients
            listed.signal()
        }
        guard listed.wait(timeout: .now() + 1) == .success,
              let clients = clientsBox.value, clients.count > 0,
              let origin = api.getLocalOrigin()?.takeUnretainedValue()
        else { return nil }

        var sticky: (info: NSDictionary, pid: Int32)?
        for element in clients {
            let client = element as AnyObject
            let pid = api.clientPID(client)
            guard pid > 0, pid != electedPID else { continue }

            let path: AnyObject
            if let cached = probeState.playerPaths[pid] {
                path = cached
            } else if let created = api.createPlayerPath(origin, client, nil)?.takeUnretainedValue() {
                probeState.playerPaths[pid] = created
                path = created
            } else {
                continue
            }

            let answered = DispatchSemaphore(value: 0)
            let infoBox = Box<NSDictionary>()
            api.getInfoForPlayer(path, nil, workQueue) { playerInfo, _ in
                infoBox.value = playerInfo
                answered.signal()
            }
            guard answered.wait(timeout: .now() + 1) == .success, let playerInfo = infoBox.value else { continue }
            guard !stringValue(playerInfo, titleKey).isEmpty else { continue }

            if numberValue(playerInfo, rateKey) > 0 {
                probeState.stickyPID = pid
                return (playerInfo, pid)
            }
            if pid == probeState.stickyPID {
                sticky = (playerInfo, pid)
            }
        }
        if sticky == nil {
            probeState.stickyPID = 0
        }
        return sticky
    }

    func alternativeSource(excluding electedPID: Int32) -> (info: NSDictionary, pid: Int32)? {
        guard let clientAPI else { return nil }
        // The app watches for a crash between these two lines, and turns this
        // feature off if there is one.
        if !probeState.reportedScan { writeLine(["event": "scan-begin"]) }
        let result = scanClients(clientAPI, excluding: electedPID)
        if !probeState.reportedScan {
            probeState.reportedScan = true
            writeLine(["event": "scan-ok"])
        }
        return result
    }

    func writeLine(_ payload: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

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
        guard group.wait(timeout: .now() + 2) == .success else {
            // MediaRemote is not answering. A few in a row means this
            // process's connection is gone; exit so the app starts a new one.
            probeState.consecutiveTimeouts += 1
            if probeState.consecutiveTimeouts >= 3 { exit(3) }
            return
        }
        probeState.consecutiveTimeouts = 0

        if numberValue(info, rateKey) > 0, !stringValue(info, titleKey).isEmpty {
            probeState.stickyPID = 0
        } else if let other = alternativeSource(excluding: pid) {
            info = other.info
            pid = other.pid
        }

        let title = stringValue(info, titleKey)
        guard !title.isEmpty else {
            probeState.lastSourceKey = ""
            writeLine(["title": ""])
            return
        }

        // Heartbeats normally skip the artwork, but a different song or player
        // needs its own cover even when no notification announced it.
        let sourceKey = "\(pid)|\(title)"
        let withArtwork = includeArtwork || sourceKey != probeState.lastSourceKey
        probeState.lastSourceKey = sourceKey

        let rate = numberValue(info, rateKey)
        let artwork = withArtwork
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

        writeLine(payload)
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
