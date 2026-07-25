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

/// Readable lyric lines plus a cursor at the current playback position.
///
/// The unreadable lines are filtered out once, at construction, and the cursor
/// usually only has to step forward by one line per tick — so keeping the
/// on-screen lyric in sync costs the same whether a song has 20 lines or 200.
struct LyricTimeline {
    private(set) var lines: [LyricLine]
    private var cursor: Int?

    init(_ lines: [LyricLine] = []) {
        self.lines = lines.filter { $0.text.hasReadableContent }
    }

    var isEmpty: Bool { lines.isEmpty }

    mutating func window(at elapsed: TimeInterval) -> LyricWindow {
        guard !lines.isEmpty else {
            return LyricWindow(previous: nil, current: nil, next: nil)
        }

        cursor = index(at: elapsed)
        guard let cursor else {
            return LyricWindow(previous: nil, current: nil, next: lines.first)
        }

        return LyricWindow(
            previous: cursor > 0 ? lines[cursor - 1] : nil,
            current: lines[cursor],
            next: cursor + 1 < lines.count ? lines[cursor + 1] : nil
        )
    }

    /// The last line at or before `elapsed`. Walks forward from the cursor for
    /// ordinary playback and falls back to a binary search after a seek.
    private func index(at elapsed: TimeInterval) -> Int? {
        if let cursor, lines[cursor].time <= elapsed {
            var index = cursor
            while index + 1 < lines.count, lines[index + 1].time <= elapsed {
                index += 1
            }
            return index
        }

        guard let first = lines.first, first.time <= elapsed else { return nil }
        var low = 0
        var high = lines.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lines[middle].time <= elapsed {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }
}

extension Array where Element == LyricLine {
    func lyricWindow(at elapsed: TimeInterval) -> LyricWindow {
        var timeline = LyricTimeline(self)
        return timeline.window(at: elapsed)
    }
}
