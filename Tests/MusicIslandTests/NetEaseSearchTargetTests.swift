import XCTest
@testable import MusicIsland

final class NetEaseSearchTargetTests: XCTestCase {
    func testFeatureCreditIsRemovedFromTitle() {
        let target = NetEaseMusicClient.SearchTarget(title: "너에게 쓰는 편지 (Feat. 린)", artist: "")

        XCTAssertEqual(target.cleanTitle, "너에게 쓰는 편지")
    }

    func testBilingualTitlePrefersParentheticalCatalogTitle() {
        let target = NetEaseMusicClient.SearchTarget(
            title: "It's Because I Miss You Today (오늘따라 보고싶어서 그래)",
            artist: ""
        )

        XCTAssertEqual(target.cleanTitle, "오늘따라 보고싶어서 그래")
    }

    func testYouTubeTopicSuffixIsRemovedFromSearchQuery() {
        let target = NetEaseMusicClient.SearchTarget(
            title: "It's Because I Miss You Today (오늘따라 보고싶어서 그래)",
            artist: "DAVICHI - Topic"
        )

        XCTAssertEqual(target.searchQuery, "오늘따라 보고싶어서 그래 DAVICHI")
    }

    func testNestedBilingualFeatureTitlePrefersCatalogTitle() {
        let target = NetEaseMusicClient.SearchTarget(
            title: "Greatest Time (feat.HuhGak) (내 생애 가장 행복한 시간 (FEAT.허각))",
            artist: "MC MONG - Topic"
        )

        XCTAssertEqual(target.cleanTitle, "내 생애 가장 행복한 시간")
        XCTAssertEqual(target.searchQuery, "내 생애 가장 행복한 시간 MC MONG")
    }

    func testGenericReleaseTopicArtistIsRemovedFromSearchQuery() {
        let target = NetEaseMusicClient.SearchTarget(
            title: "Bubble Love",
            artist: "Release - Topic"
        )

        XCTAssertEqual(target.cleanTitle, "Bubble Love")
        XCTAssertEqual(target.searchQuery, "Bubble Love")
    }

    func testCornerBracketTitleIsPreservedFromOfficialMVTitle() {
        let target = NetEaseMusicClient.SearchTarget(
            title: "林俊傑 JJ Lin【小酒窩 Dimples】（合唱：蔡卓妍 A-Sa）官方完整版 MV",
            artist: "太合音樂 Taihe Music-精選"
        )

        XCTAssertEqual(target.cleanTitle, "小酒窩")
        XCTAssertEqual(target.searchQuery, "小酒窩 林俊傑 JJ Lin")
    }

    func testPartNumberIsPreservedWhenRemovingFeatureCredit() {
        let target = NetEaseMusicClient.SearchTarget(
            title: "너에게 쓰는 편지 Part 2 (Feat. LISA)",
            artist: "MC MONG - Topic"
        )

        XCTAssertEqual(target.cleanTitle, "너에게 쓰는 편지 Part 2")
        XCTAssertEqual(target.searchQuery, "너에게 쓰는 편지 Part 2 MC MONG")
    }
}
