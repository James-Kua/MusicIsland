import Foundation
import XCTest
@testable import MusicIsland

final class NetEaseVideoIntegrationTests: XCTestCase {
    func testYouTubeVideosMatchExpectedNetEaseTitles() async throws {
        guard ProcessInfo.processInfo.environment["MUSICISLAND_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set MUSICISLAND_RUN_NETWORK_TESTS=1 to run YouTube/NetEase integration fixtures.")
        }

        let fixtures = [
            Fixture(
                url: "https://www.youtube.com/watch?v=XdQjIBiEDnc",
                expectedTitle: "오늘따라 보고싶어서 그래"
            ),
            Fixture(
                url: "https://www.youtube.com/watch?v=EHGj-RRzK_8",
                expectedTitle: "내 생애 가장 행복한 시간"
            ),
            Fixture(
                url: "https://www.youtube.com/watch?v=wt2qlecXbUc",
                expectedTitle: "Bubble Love"
            ),
            Fixture(
                url: "https://www.youtube.com/watch?v=h-woMj_Vt0A",
                expectedTitle: "小酒窝"
            ),
            Fixture(
                url: "https://www.youtube.com/watch?v=Yb1ym-cyh2U",
                expectedTitle: "너에게 쓰는 편지 Part 2"
            )
        ]

        for fixture in fixtures {
            let metadata = try await fetchYouTubeMetadata(for: fixture.url)
            let target = NetEaseMusicClient.SearchTarget(title: metadata.title, artist: metadata.authorName)
            let songs = try await fetchNetEaseSongs(query: target.searchQuery)
            let match = NetEaseMusicClient().bestSongMatch(from: songs, target: target)

            XCTAssertEqual(
                match?.title,
                fixture.expectedTitle,
                "Expected \(fixture.url) to match \(fixture.expectedTitle), got \(match?.title ?? "nil") from query \(target.searchQuery)"
            )
        }
    }

    private struct Fixture {
        let url: String
        let expectedTitle: String
    }

    private struct YouTubeMetadata: Decodable {
        let title: String
        let authorName: String

        enum CodingKeys: String, CodingKey {
            case title
            case authorName = "author_name"
        }
    }

    private func fetchYouTubeMetadata(for videoURL: String) async throws -> YouTubeMetadata {
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [
            .init(name: "url", value: videoURL),
            .init(name: "format", value: "json")
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try JSONDecoder().decode(YouTubeMetadata.self, from: data)
    }

    private func fetchNetEaseSongs(query: String) async throws -> [[String: Any]] {
        var components = URLComponents(string: "https://music.163.com/api/cloudsearch/pc")!
        components.queryItems = [
            .init(name: "s", value: query),
            .init(name: "type", value: "1"),
            .init(name: "limit", value: "10"),
            .init(name: "offset", value: "0")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Mozilla/5.0 MusicIsland", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = json?["result"] as? [String: Any]
        return result?["songs"] as? [[String: Any]] ?? []
    }
}
