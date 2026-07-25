import Foundation

/// The currently playing track as surfaced to the UI.
struct Track: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var appName: String

    static let empty = Track(
        title: "Nothing playing",
        artist: "Open NetEase Music",
        album: "",
        isPlaying: false,
        appName: ""
    )

    /// NetEase is running but macOS has not published its metadata yet.
    static let netEaseWaiting = Track(
        title: "NetEase Music is active",
        artist: "Waiting for macOS Now Playing metadata",
        album: "",
        isPlaying: true,
        appName: ""
    )

    /// macOS is refusing to hand this app any now-playing metadata.
    static let nowPlayingUnavailable = Track(
        title: "Now Playing unavailable",
        artist: "Run xcode-select --install, then reopen MusicIsland",
        album: "",
        isPlaying: false,
        appName: ""
    )

    /// Whether this stands in for app state rather than describing real media.
    /// Placeholders never get a lyric lookup — there is nothing to look up.
    var isPlaceholder: Bool {
        title == Track.empty.title
            || title == Track.netEaseWaiting.title
            || title == Track.nowPlayingUnavailable.title
    }
}
