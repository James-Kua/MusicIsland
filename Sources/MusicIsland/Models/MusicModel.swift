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
        track.isPlaying.toggle()
        NetEaseController.sendMediaKey(.playPause)
        refreshSoon()
    }

    func nextTrack() {
        NetEaseController.sendMediaKey(.next)
        refreshSoon()
    }

    func previousTrack() {
        NetEaseController.sendMediaKey(.previous)
        refreshSoon()
    }

    func seek(to target: TimeInterval) {
        let boundedTarget = min(max(0, target), max(duration, 0))
        playbackElapsed = boundedTarget
        elapsed = boundedTarget
        updateLyric()
        NetEaseController.seek(to: boundedTarget)
        refreshSoon()
    }

    func openNetEaseMusic() {
        NetEaseController.openNetEaseMusic()
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
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
        playbackElapsed = snapshot.elapsed
        if isExpanded, abs(elapsed - snapshot.elapsed) > 0.25 {
            elapsed = snapshot.elapsed
        }
        if duration != snapshot.duration {
            duration = snapshot.duration
        }
        if track != snapshot.track {
            track = snapshot.track
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

    private var refreshInterval: TimeInterval {
        if refreshTask != nil {
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
