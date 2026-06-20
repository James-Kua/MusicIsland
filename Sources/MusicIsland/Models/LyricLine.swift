import Foundation

/// A single timed lyric line, optionally paired with a translation.
struct LyricLine: Equatable {
    let time: TimeInterval
    let text: String
    let translatedText: String?
}
