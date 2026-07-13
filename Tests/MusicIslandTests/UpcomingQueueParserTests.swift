import XCTest
@testable import MusicIsland

final class UpcomingQueueParserTests: XCTestCase {
    func testYouTubeParserReturnsLaterPlaylistItemsInOrder() throws {
        let current = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=current&list=PL123&index=2"))
        let links = [
            AccessibilityLink(
                title: "Later Song 4 minutes, 1 second Later Channel",
                url: try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=later&list=PL123&index=4"))
            ),
            AccessibilityLink(
                title: "Next Song 3:25 Next Channel",
                url: try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=next&list=PL123&index=3"))
            ),
            AccessibilityLink(
                title: "Unrelated recommendation",
                url: try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=nope"))
            ),
        ]

        let items = YouTubeQueueParser.upcomingItems(currentURL: current, links: links, limit: 5)

        XCTAssertEqual(items.map(\.title), ["Next Song", "Later Song"])
        XCTAssertEqual(items.map(\.subtitle), ["Next Channel • 3:25", "Later Channel • 4:01"])
        XCTAssertEqual(items.first?.artworkURL?.absoluteString, "https://i.ytimg.com/vi/next/mqdefault.jpg")
    }

    func testYouTubeParserDoesNotTreatRecommendationsAsQueue() throws {
        let current = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=current"))
        let recommendation = AccessibilityLink(
            title: "Recommended video",
            url: try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=other"))
        )

        XCTAssertTrue(
            YouTubeQueueParser.upcomingItems(currentURL: current, links: [recommendation], limit: 5).isEmpty
        )
    }

    func testNetEaseParserReturnsRowsAfterCurrentTrack() {
        let rows = [[
            ["1", "Current Song", "Current Artist", "3:10"],
            ["2", "Next Song", "Next Artist", "4:02"],
            ["3", "Later Song", "Later Artist", "2:58"],
        ]]

        let items = NetEaseQueueParser.upcomingItems(after: "Current Song", rowGroups: rows, limit: 5)

        XCTAssertEqual(items.map(\.title), ["Next Song", "Later Song"])
        XCTAssertEqual(items.map(\.subtitle), ["Next Artist • 4:02", "Later Artist • 2:58"])
    }

    func testNetEasePlayingListParserReadsTracksAfterCurrentSong() throws {
        let payload: [String: Any] = [
            "list": [
                playingListEntry(order: 2, id: "next", title: "Next Song", artist: "Next Artist"),
                playingListEntry(order: 1, id: "current", title: "Current Song", artist: "Current Artist"),
                playingListEntry(order: 3, id: "later", title: "Later Song", artist: "Later Artist"),
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let items = NetEasePlayingListParser.upcomingItems(
            after: "Current Song",
            artist: "Current Artist",
            data: data,
            limit: 5
        )

        XCTAssertEqual(items.map(\.title), ["Next Song", "Later Song"])
        XCTAssertEqual(items.map(\.subtitle), ["Next Artist • 3:14", "Later Artist • 3:14"])
        XCTAssertEqual(items.map(\.id), ["netease:next", "netease:later"])
        XCTAssertEqual(items.first?.artworkURL?.absoluteString, "https://example.com/next.jpg")
    }

    private func playingListEntry(
        order: Int,
        id: String,
        title: String,
        artist: String
    ) -> [String: Any] {
        [
            "displayOrder": order,
            "track": [
                "id": id,
                "name": title,
                "artists": [["name": artist]],
                "album": ["picUrl": "http://example.com/\(id).jpg"],
                "duration": 194_000,
            ],
        ]
    }
}
