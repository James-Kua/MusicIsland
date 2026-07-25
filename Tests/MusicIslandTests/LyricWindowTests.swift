import XCTest
@testable import MusicIsland

final class LyricWindowTests: XCTestCase {
    private let lines = [
        LyricLine(time: 5, text: "First", translatedText: nil),
        LyricLine(time: 10, text: "♪", translatedText: nil),
        LyricLine(time: 15, text: "Second", translatedText: "Translation"),
        LyricLine(time: 20, text: "Third", translatedText: nil),
    ]

    func testBeforeFirstReadableLineShowsItAsNext() {
        let window = lines.lyricWindow(at: 2)

        XCTAssertNil(window.previous)
        XCTAssertNil(window.current)
        XCTAssertEqual(window.next?.text, "First")
    }

    func testSkipsUnreadableLinesWhenBuildingContext() {
        let window = lines.lyricWindow(at: 16)

        XCTAssertEqual(window.previous?.text, "First")
        XCTAssertEqual(window.current?.text, "Second")
        XCTAssertEqual(window.current?.translatedText, "Translation")
        XCTAssertEqual(window.next?.text, "Third")
    }

    func testLastLineHasNoNextContext() {
        let window = lines.lyricWindow(at: 30)

        XCTAssertEqual(window.previous?.text, "Second")
        XCTAssertEqual(window.current?.text, "Third")
        XCTAssertNil(window.next)
    }

    func testTimelineCursorFollowsPlaybackForward() {
        var timeline = LyricTimeline(lines)

        XCTAssertNil(timeline.window(at: 0).current)
        XCTAssertEqual(timeline.window(at: 6).current?.text, "First")
        XCTAssertEqual(timeline.window(at: 11).current?.text, "First")
        XCTAssertEqual(timeline.window(at: 15).current?.text, "Second")
        XCTAssertEqual(timeline.window(at: 21).current?.text, "Third")
    }

    func testTimelineCursorRewindsAfterSeekingBackwards() {
        var timeline = LyricTimeline(lines)
        _ = timeline.window(at: 30)

        XCTAssertEqual(timeline.window(at: 16).current?.text, "Second")
        XCTAssertEqual(timeline.window(at: 5).current?.text, "First")
        XCTAssertNil(timeline.window(at: 1).current)
        XCTAssertEqual(timeline.window(at: 1).next?.text, "First")
    }

    func testTimelineSkipsSeveralLinesInOneStep() {
        var timeline = LyricTimeline(lines)
        _ = timeline.window(at: 5)

        XCTAssertEqual(timeline.window(at: 25).current?.text, "Third")
    }

    func testTimelineWithoutReadableLinesIsEmpty() {
        var timeline = LyricTimeline([LyricLine(time: 0, text: "♪", translatedText: nil)])

        XCTAssertTrue(timeline.isEmpty)
        XCTAssertNil(timeline.window(at: 10).current)
        XCTAssertNil(timeline.window(at: 10).next)
    }
}
