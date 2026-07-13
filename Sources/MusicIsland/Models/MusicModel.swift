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
            if isExpanded, abs(elapsed - playbackElapsed) > 0.25 {
                elapsed = playbackElapsed
            }
        }
    }

    private let nowPlaying = NowPlayingBridge()
    private let netEase = NetEaseMusicClient()
    private let queueProvider = UpcomingQueueProvider()
    private var refreshLoopTask: Task<Void, Never>?
    private var lyricLines: [LyricLine] = []
    private var lyricTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastLyricLookupKey = ""
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
        refreshTask?.cancel()
        artworkColorTask?.cancel()
        queueTask?.cancel()
    }

    func start() {
        guard refreshLoopTask == nil else { return }
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
        guard refreshTask == nil else { return }

        let bridge = nowPlaying
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            let snapshot = bridge.currentTrack()
            await self?.apply(snapshot)
        }
    }

    private func apply(_ snapshot: NowPlayingSnapshot) {
        refreshTask = nil
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
            lyricLines = []
            lyric = snapshot.track.title == Track.empty.title ? "Lyrics will appear here" : "Finding lyrics..."
            translatedLyric = ""
            nextLyric = ""
            if isShowingQueue {
                refreshUpcomingQueue()
            }
            fetchLyricsIfNeeded(for: snapshot.track)
        }

        updateLyric()
    }

    private func fetchLyricsIfNeeded(for track: Track) {
        let key = lyricKey(for: track)
        guard track.title != Track.empty.title, key != lastLyricLookupKey else { return }
        lastLyricLookupKey = key

        lyricTask?.cancel()
        isLoadingLyrics = true
        lyricTask = Task { [netEase] in
            let lines = await netEase.lyrics(title: track.title, artist: track.artist)
            guard !Task.isCancelled, key == self.currentSongKey else { return }
            await MainActor.run {
                guard key == self.currentSongKey else { return }
                self.isLoadingLyrics = false
                self.lyricLines = lines
                self.updateLyric()
                if lines.isEmpty {
                    self.lyric = "No synced lyric found"
                    self.translatedLyric = ""
                    self.nextLyric = ""
                }
            }
        }
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
        guard !lyricLines.isEmpty else {
            setNextLyric("")
            setDisplayedLyric(lyric, translated: "")
            return
        }

        let window = lyricLines.lyricWindow(at: playbackElapsed)
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

    private var refreshInterval: TimeInterval {
        if refreshTask != nil {
            return 1
        }
        if pendingPlaybackState != nil || pendingSeek != nil {
            return 1
        }
        if isExpanded || track.isPlaying {
            return 1
        }
        if track == Track.empty {
            return 3
        }
        return 4
    }
}
