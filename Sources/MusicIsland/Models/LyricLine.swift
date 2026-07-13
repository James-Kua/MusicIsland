import Foundation

/// A single timed lyric line, optionally paired with a translation.
struct LyricLine: Equatable {
    let time: TimeInterval
    let text: String
    let translatedText: String?
}

/// The readable lyric lines surrounding the current playback position.
/// Empty and punctuation-only LRC entries are skipped so the context remains
/// useful during instrumental gaps.
struct LyricWindow: Equatable {
    let previous: LyricLine?
    let current: LyricLine?
    let next: LyricLine?
}

extension Array where Element == LyricLine {
    func lyricWindow(at elapsed: TimeInterval) -> LyricWindow {
        let readableLines = filter { $0.text.hasReadableContent }
        guard !readableLines.isEmpty else {
            return LyricWindow(previous: nil, current: nil, next: nil)
        }

        guard let currentIndex = readableLines.lastIndex(where: { $0.time <= elapsed }) else {
            return LyricWindow(previous: nil, current: nil, next: readableLines.first)
        }

        let previous = currentIndex > readableLines.startIndex
            ? readableLines[readableLines.index(before: currentIndex)]
            : nil
        let nextIndex = readableLines.index(after: currentIndex)
        let next = nextIndex < readableLines.endIndex ? readableLines[nextIndex] : nil

        return LyricWindow(
            previous: previous,
            current: readableLines[currentIndex],
            next: next
        )
    }
}
