import Foundation

/// The currently playing track as surfaced to the UI.
struct Track: Equatable {
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
}
