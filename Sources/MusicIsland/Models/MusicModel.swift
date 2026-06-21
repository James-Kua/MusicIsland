import AppKit
import Combine
import Foundation

/// The app's observable state. Polls `NowPlayingBridge`, drives playback
/// commands through `NetEaseController`, and keeps the displayed lyric in sync
/// with the current playback position.
@MainActor
final class MusicModel: ObservableObject {
    @Published var track = Track.empty
    @Published var elapsed: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var coverImage: NSImage?
    @Published var lyric = "Lyrics will appear here"
    @Published var translatedLyric = ""
    @Published var isLoadingLyrics = false
    @Published var isExpanded = false {
        didSet {
            if isExpanded, abs(elapsed - playbackElapsed) > 0.25 {
                elapsed = playbackElapsed
            }
        }
    }

    private let nowPlaying = NowPlayingBridge()
    private let netEase = NetEaseMusicClient()
    private var refreshLoopTask: Task<Void, Never>?
    private var lyricLines: [LyricLine] = []
    private var lyricTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastLyricLookupKey = ""
    private var currentSongKey = ""
    private var lastArtworkData: Data?
    private var playbackElapsed: TimeInterval = 0
    private var pendingPlaybackState: (isPlaying: Bool, songKey: String, expiresAt: Date)?
    private var pendingSeek: (target: TimeInterval, songKey: String, requestedAt: Date, wasPlaying: Bool, expiresAt: Date)?

    deinit {
        refreshLoopTask?.cancel()
        lyricTask?.cancel()
        refreshTask?.cancel()
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
        let displayElapsed = elapsedForDisplay(from: snapshot)
        playbackElapsed = displayElapsed
        if isExpanded, abs(elapsed - displayElapsed) > 0.25 {
            elapsed = displayElapsed
        }
        if duration != snapshot.duration {
            duration = snapshot.duration
        }
        let visibleTrack = trackForDisplay(from: snapshot.track)
        if track != visibleTrack {
            track = visibleTrack
        }
        if let artworkData = snapshot.artworkData, artworkData != lastArtworkData {
            lastArtworkData = artworkData
            coverImage = NSImage(data: artworkData)
        } else if snapshot.track == Track.empty {
            lastArtworkData = nil
            coverImage = nil
        }

        let songKey = lyricKey(for: snapshot.track)
        if songKey != currentSongKey {
            currentSongKey = songKey
            lyricLines = []
            lyric = snapshot.track.title == Track.empty.title ? "Lyrics will appear here" : "Finding lyrics..."
            translatedLyric = ""
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
            await MainActor.run {
                self.isLoadingLyrics = false
                self.lyricLines = lines
                self.updateLyric()
                if lines.isEmpty {
                    self.lyric = "No synced lyric found"
                    self.translatedLyric = ""
                }
            }
        }
    }

    private func lyricKey(for track: Track) -> String {
        "\(track.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(track.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private func updateLyric() {
        guard !lyricLines.isEmpty else {
            setDisplayedLyric(lyric, translated: "")
            return
        }
        let active = lyricLines.last { $0.time <= playbackElapsed }
        let line = active ?? lyricLines.first
        setDisplayedLyric(
            line?.text.isEmpty == false ? line!.text : lyricLines.first?.text ?? "",
            translated: line?.translatedText ?? ""
        )
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
