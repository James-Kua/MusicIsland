import AppKit
import Combine
import Foundation
import SwiftUI

/// The app's observable state. Polls `NowPlayingBridge`, drives playback
/// commands through `NetEaseController`, and keeps the displayed lyric in sync
/// with the current playback position.
@MainActor
final class MusicModel: ObservableObject {
    @Published var track = Track.empty
    @Published var elapsed: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var coverImage: NSImage?
    @Published var accentColor: Color = MusicModel.defaultAccent
    @Published var lyric = "Lyrics will appear here"
    @Published var translatedLyric = ""
    @Published var nextLyric = ""
    @Published var isLoadingLyrics = false
    @Published var isShowingQueue = false
    @Published var upcomingQueue: UpcomingQueueState = .idle
    @Published var isExpanded = false {
        didSet {
            guard isExpanded else { return }
            if abs(elapsed - playbackElapsed) > 0.25 {
                elapsed = playbackElapsed
            }
            // Opening the island is the moment the lyric actually matters, so
            // take it as a cue to pick up a lookup that ran out of retries.
            retryLyricsIfStalled()
        }
    }

    private let nowPlaying = NowPlayingBridge()
    private let netEase = NetEaseMusicClient()
    private let queueProvider = UpcomingQueueProvider()
    private var refreshLoopTask: Task<Void, Never>?
    private var lyricTimeline = LyricTimeline()
    private var lyricTask: Task<Void, Never>?
    private var lyricRetryTask: Task<Void, Never>?
    private var lyricAttempt = 0
    private var refreshTask: Task<Void, Never>?
    private var hasPendingRefresh = false
    private var currentSongKey = ""
    private var lastArtworkData: Data?
    private var artworkColorTask: Task<Void, Never>?
    private var artworkGeneration = 0
    private var playbackElapsed: TimeInterval = 0
    private var pendingPlaybackState: (isPlaying: Bool, songKey: String, expiresAt: Date)?
    private var pendingSeek: (target: TimeInterval, songKey: String, requestedAt: Date, wasPlaying: Bool, expiresAt: Date)?
    private var displayTickTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var elapsedAnchor: TimeInterval = 0
    private var elapsedAnchorAt = Date()

    deinit {
        refreshLoopTask?.cancel()
        displayTickTask?.cancel()
        lyricTask?.cancel()
        lyricRetryTask?.cancel()
        refreshTask?.cancel()
        artworkColorTask?.cancel()
        queueTask?.cancel()
    }

    func start() {
        guard refreshLoopTask == nil else { return }
        // MediaRemote tells us the moment a track or playback state changes, so
        // a skip lands immediately instead of waiting out the next poll. Polling
        // stays on as the safety net for players that update silently.
        nowPlaying.onNowPlayingChange = { [weak self] in
            self?.refresh()
        }
        refreshLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                let nanoseconds = UInt64(self.refreshInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
        // Advance the displayed position from a smooth local clock between polls
        // so the scrubber ticks continuously instead of hopping each refresh.
        displayTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                self.tickDisplay()
            }
        }
    }

    /// The position projected forward from the last snapshot using wall-clock time.
    private var projectedElapsed: TimeInterval {
        guard track.isPlaying else { return elapsedAnchor }
        let projected = elapsedAnchor + Date().timeIntervalSince(elapsedAnchorAt)
        return duration > 0 ? min(projected, duration) : projected
    }

    private func tickDisplay() {
        // Nothing moves while paused: the projected position is pinned to the
        // anchor, and seeking updates the position and lyric on the spot.
        guard track.isPlaying else { return }
        let value = projectedElapsed
        playbackElapsed = value
        if abs(elapsed - value) > 0.05 {
            elapsed = value
        }
        updateLyric()
    }

    func togglePlayPause() {
        let requestedState = !track.isPlaying
        pendingPlaybackState = (
            isPlaying: requestedState,
            songKey: lyricKey(for: track),
            expiresAt: Date().addingTimeInterval(2.5)
        )
        track.isPlaying = requestedState
        NetEaseController.sendMediaKey(.playPause)
        refreshSoon(after: 0.35)
        refreshSoon(after: 1.2)
        refreshSoon(after: 2.4)
    }

    func nextTrack() {
        pendingSeek = nil
        NetEaseController.sendMediaKey(.next)
        refreshSoon(after: 0.35)
        refreshSoon(after: 1.2)
        refreshSoon(after: 2.4)
    }

    func previousTrack() {
        pendingSeek = nil
        NetEaseController.sendMediaKey(.previous)
        refreshSoon(after: 0.35)
        refreshSoon(after: 1.2)
        refreshSoon(after: 2.4)
    }

    func seek(to target: TimeInterval) {
        let boundedTarget = min(max(0, target), max(duration, 0))
        pendingSeek = (
            target: boundedTarget,
            songKey: lyricKey(for: track),
            requestedAt: Date(),
            wasPlaying: track.isPlaying,
            expiresAt: Date().addingTimeInterval(2.5)
        )
        elapsedAnchor = boundedTarget
        elapsedAnchorAt = Date()
        playbackElapsed = boundedTarget
        elapsed = boundedTarget
        updateLyric()
        NetEaseController.seek(to: boundedTarget)
        refreshSoon(after: 0.35)
        refreshSoon(after: 1.2)
        refreshSoon(after: 2.4)
    }

    func openNetEaseMusic() {
        NetEaseController.openNetEaseMusic()
    }

    func toggleUpcomingQueue() {
        isShowingQueue.toggle()
        if isShowingQueue {
            refreshUpcomingQueue()
        } else {
            queueTask?.cancel()
            queueTask = nil
            upcomingQueue = .idle
        }
    }

    func closeUpcomingQueue() {
        guard isShowingQueue else { return }
        isShowingQueue = false
        queueTask?.cancel()
        queueTask = nil
        upcomingQueue = .idle
    }

    func refreshUpcomingQueue() {
        guard isShowingQueue else { return }
        queueTask?.cancel()
        upcomingQueue = .loading
        let requestedTrack = track
        let requestedKey = lyricKey(for: requestedTrack)
        queueTask = Task { [queueProvider] in
            let state = await queueProvider.queue(for: requestedTrack)
            guard !Task.isCancelled, requestedKey == self.lyricKey(for: self.track) else { return }
            self.upcomingQueue = state
            self.queueTask = nil
        }
    }

    private func refreshSoon(after delay: TimeInterval = 0.2) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        // A read already in flight will not reflect a change that arrived after
        // it started, so remember the request and re-read once it lands instead
        // of dropping it.
        guard refreshTask == nil else {
            hasPendingRefresh = true
            return
        }

        let bridge = nowPlaying
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            let snapshot = bridge.currentTrack()
            await self?.apply(snapshot)
        }
    }

    private func apply(_ snapshot: NowPlayingSnapshot) {
        refreshTask = nil
        let shouldRereadAfterApplying = hasPendingRefresh
        hasPendingRefresh = false
        defer {
            if shouldRereadAfterApplying {
                refresh()
            }
        }
        if duration != snapshot.duration {
            duration = snapshot.duration
        }
        let visibleTrack = trackForDisplay(from: snapshot.track)
        if track != visibleTrack {
            track = visibleTrack
        }

        // Resync the smooth local clock to the polled snapshot only when they
        // diverge enough to signal a real seek/skip — routine polling jitter is
        // left to the local tick so the scrubber doesn't jump.
        let displayElapsed = elapsedForDisplay(from: snapshot)
        if !track.isPlaying || abs(projectedElapsed - displayElapsed) > 1.5 {
            elapsedAnchor = displayElapsed
            elapsedAnchorAt = Date()
            playbackElapsed = displayElapsed
            if isExpanded {
                elapsed = displayElapsed
            }
        }
        if let artworkData = snapshot.artworkData, artworkData != lastArtworkData {
            lastArtworkData = artworkData
            let image = NSImage(data: artworkData)
            coverImage = image
            updateAccentColorAsync(from: artworkData)
        } else if snapshot.track == Track.empty {
            lastArtworkData = nil
            artworkGeneration += 1
            artworkColorTask?.cancel()
            coverImage = nil
            updateAccentColor(from: nil)
        }

        let songKey = lyricKey(for: snapshot.track)
        if songKey != currentSongKey {
            currentSongKey = songKey
            lyricTimeline = LyricTimeline()
            lyric = snapshot.track.isPlaceholder ? "Lyrics will appear here" : "Finding lyrics..."
            translatedLyric = ""
            nextLyric = ""
            if isShowingQueue {
                refreshUpcomingQueue()
            }
            startLyricLookup(for: snapshot.track, key: songKey)
        }

        updateLyric()
    }

    private static let lyricRetryDelays: [TimeInterval] = [1.5, 4, 9, 20]

    /// Begins a fresh lyric lookup for `track`. Any in-flight lookup or pending
    /// retry belongs to a song that is no longer playing, so both are dropped.
    private func startLyricLookup(for track: Track, key: String) {
        lyricTask?.cancel()
        lyricRetryTask?.cancel()
        lyricRetryTask = nil
        lyricAttempt = 0
        guard !track.isPlaceholder, !key.isEmpty else {
            lyricTask = nil
            isLoadingLyrics = false
            return
        }
        performLyricLookup(for: track, key: key)
    }

    private func performLyricLookup(for track: Track, key: String) {
        isLoadingLyrics = true
        lyricTask = Task { [netEase] in
            let result = await netEase.lyrics(title: track.title, artist: track.artist)
            guard !Task.isCancelled, key == self.currentSongKey else { return }
            self.applyLyricLookup(result, for: track, key: key)
        }
    }

    private func applyLyricLookup(_ result: LyricLookup, for track: Track, key: String) {
        guard key == currentSongKey else { return }
        lyricTask = nil

        switch result {
        case let .lines(lines):
            lyricAttempt = 0
            isLoadingLyrics = false
            lyricTimeline = LyricTimeline(lines)
            updateLyric()
        case .notFound:
            lyricAttempt = 0
            isLoadingLyrics = false
            lyricTimeline = LyricTimeline()
            setDisplayedLyric("No synced lyric found", translated: "")
            setNextLyric("")
        case .failed:
            // The lookup failed for a reason that may not still hold — a dropped
            // request, a timeout, a throttled response. Back off and try again
            // rather than leaving the song permanently without lyrics.
            scheduleLyricRetry(for: track, key: key)
        }
    }

    private func scheduleLyricRetry(for track: Track, key: String) {
        guard lyricAttempt < Self.lyricRetryDelays.count else {
            isLoadingLyrics = false
            setDisplayedLyric("Lyrics unavailable", translated: "")
            setNextLyric("")
            return
        }

        let delay = Self.lyricRetryDelays[lyricAttempt]
        lyricAttempt += 1
        DebugLog.write("lyrics retry attempt=\(lyricAttempt) in=\(delay)s key=\"\(key)\"")
        lyricRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, key == self.currentSongKey else { return }
            self.lyricRetryTask = nil
            self.performLyricLookup(for: track, key: key)
        }
    }

    /// Restarts a lookup that gave up, so the island never gets stuck without
    /// lyrics for a song that does have them.
    private func retryLyricsIfStalled() {
        guard lyricTimeline.isEmpty,
              lyricTask == nil,
              lyricRetryTask == nil,
              lyricAttempt >= Self.lyricRetryDelays.count,
              !track.isPlaceholder
        else { return }
        lyricAttempt = 0
        performLyricLookup(for: track, key: currentSongKey)
    }

    static let defaultAccent = Color(red: 0.09, green: 0.09, blue: 0.11)

    private func updateAccentColorAsync(from data: Data) {
        artworkGeneration += 1
        let generation = artworkGeneration
        artworkColorTask?.cancel()

        artworkColorTask = Task.detached(priority: .utility) { [weak self, data] in
            guard !Task.isCancelled else { return }
            var components: (red: Double, green: Double, blue: Double)?
            if let color = NSImage(data: data)?.islandAccentColor()?.usingColorSpace(.deviceRGB) {
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                components = (Double(red), Double(green), Double(blue))
            }
            guard !Task.isCancelled else { return }

            await self?.applyArtworkAccent(
                red: components?.red,
                green: components?.green,
                blue: components?.blue,
                generation: generation
            )
        }
    }

    private func applyArtworkAccent(red: Double?, green: Double?, blue: Double?, generation: Int) {
        guard generation == artworkGeneration else { return }
        let resolved: Color
        if let red, let green, let blue {
            resolved = Color(red: red, green: green, blue: blue)
        } else {
            resolved = Self.defaultAccent
        }
        withAnimation(.easeInOut(duration: 0.5)) {
            accentColor = resolved
        }
    }

    private func updateAccentColor(from image: NSImage?) {
        let resolved = image?.islandAccentColor().map(Color.init(nsColor:)) ?? Self.defaultAccent
        withAnimation(.easeInOut(duration: 0.5)) {
            accentColor = resolved
        }
    }

    private func lyricKey(for track: Track) -> String {
        "\(track.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(track.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private func updateLyric() {
        guard !lyricTimeline.isEmpty else {
            setNextLyric("")
            setDisplayedLyric(lyric, translated: "")
            return
        }

        let window = lyricTimeline.window(at: playbackElapsed)
        setNextLyric(window.next?.text ?? "")
        setDisplayedLyric(
            window.current?.text ?? "",
            translated: window.current?.translatedText ?? ""
        )
    }

    private func setNextLyric(_ text: String) {
        if nextLyric != text {
            nextLyric = text
        }
    }

    private func setDisplayedLyric(_ text: String, translated: String) {
        if lyric != text {
            lyric = text
        }
        if translatedLyric != translated {
            translatedLyric = translated
        }
    }

    private func trackForDisplay(from snapshotTrack: Track) -> Track {
        guard let pending = pendingPlaybackState else {
            return snapshotTrack
        }

        let snapshotKey = lyricKey(for: snapshotTrack)
        guard Date() < pending.expiresAt, snapshotKey == pending.songKey else {
            pendingPlaybackState = nil
            return snapshotTrack
        }

        if snapshotTrack.isPlaying == pending.isPlaying {
            pendingPlaybackState = nil
            return snapshotTrack
        }

        var visibleTrack = snapshotTrack
        visibleTrack.isPlaying = pending.isPlaying
        return visibleTrack
    }

    private func elapsedForDisplay(from snapshot: NowPlayingSnapshot) -> TimeInterval {
        guard let pending = pendingSeek else {
            return snapshot.elapsed
        }

        let snapshotKey = lyricKey(for: snapshot.track)
        guard Date() < pending.expiresAt, snapshotKey == pending.songKey else {
            pendingSeek = nil
            return snapshot.elapsed
        }

        let expectedElapsed = expectedSeekElapsed(for: pending, duration: snapshot.duration)
        if abs(snapshot.elapsed - expectedElapsed) < 1.5 {
            pendingSeek = nil
            return snapshot.elapsed
        }

        return expectedElapsed
    }

    private func expectedSeekElapsed(
        for pending: (target: TimeInterval, songKey: String, requestedAt: Date, wasPlaying: Bool, expiresAt: Date),
        duration: TimeInterval
    ) -> TimeInterval {
        let advanced = pending.wasPlaying ? Date().timeIntervalSince(pending.requestedAt) : 0
        let upperBound = duration > 0 ? duration : .greatestFiniteMagnitude
        return min(max(0, pending.target + advanced), upperBound)
    }

    /// How often to poll. MediaRemote now pushes track and playback changes, so
    /// polling is a backstop rather than the primary signal — it can run slower
    /// while the island is closed without the UI falling behind. The scrubber
    /// and lyric run off the local clock between polls either way.
    private var refreshInterval: TimeInterval {
        if refreshTask != nil {
            return 1
        }
        if pendingPlaybackState != nil || pendingSeek != nil || isExpanded {
            return 1
        }
        if track.isPlaying {
            return 2
        }
        if track == Track.empty {
            return 5
        }
        return 4
    }
}
