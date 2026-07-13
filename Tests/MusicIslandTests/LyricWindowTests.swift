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
}
