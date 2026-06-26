import Foundation

/// Fetches time-synced lyrics from NetEase Cloud Music's public web API by
/// searching for the best-matching song and downloading its LRC lyrics.
final class NetEaseMusicClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 MusicIsland",
            "Referer": "https://music.163.com/"
        ]
        session = URLSession(configuration: configuration)
    }

    func lyrics(title: String, artist: String) async -> [LyricLine] {
        guard let id = await searchSongID(title: title, artist: artist) else {
            return []
        }
        return await fetchLyrics(songID: id)
    }

    private func searchSongID(title: String, artist: String) async -> Int? {
        let target = SearchTarget(title: title, artist: artist)
        var components = URLComponents(string: "https://music.163.com/api/cloudsearch/pc")
        components?.queryItems = [
            .init(name: "s", value: target.searchQuery),
            .init(name: "type", value: "1"),
            .init(name: "limit", value: "10"),
            .init(name: "offset", value: "0")
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, _) = try await session.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let result = json?["result"] as? [String: Any]
            let songs = result?["songs"] as? [[String: Any]]
            return bestSongMatch(from: songs ?? [], target: target)?.id
        } catch {
            return nil
        }
    }

    struct SongMatch {
        let id: Int
        let title: String
        let artists: String
        let score: Int
    }

    func bestSongMatch(from songs: [[String: Any]], target: SearchTarget) -> SongMatch? {
        let ranked = songs.compactMap { song -> SongMatch? in
            guard let id = song["id"] as? Int else { return nil }
            let songTitle = song["name"] as? String ?? ""
            let songArtists = (song["ar"] as? [[String: Any]] ?? song["artists"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
            let songTitleKeys = Self.normalizedKeys(songTitle)
            let artistKeys = songArtists.flatMap(Self.normalizedKeys)

            let score = titleScore(songKeys: songTitleKeys, targetKeys: target.titleKeys)
                + artistScore(songKeys: artistKeys, targetKeys: target.artistKeys)
                - versionPenalty(songTitle: songTitle, targetTitle: target.rawTitle)

            return SongMatch(id: id, title: songTitle, artists: songArtists.joined(separator: ", "), score: score)
        }

        if let best = ranked.max(by: { $0.score < $1.score }) {
            let candidates = ranked
                .sorted { $0.score > $1.score }
                .prefix(3)
                .map { "\($0.id):\($0.score):\($0.title) [\($0.artists)]" }
                .joined(separator: " | ")
            DebugLog.write("lyrics bestMatch query=\"\(target.searchQuery)\" title=\"\(target.rawTitle)\" artist=\"\(target.rawArtist)\" id=\(best.id) score=\(best.score) candidates=\(candidates)")
            return best
        }

        guard let first = songs.first, let id = first["id"] as? Int else { return nil }
        let title = first["name"] as? String ?? ""
        let artists = (first["ar"] as? [[String: Any]] ?? first["artists"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
            .joined(separator: ", ")
        return SongMatch(id: id, title: title, artists: artists, score: 0)
    }

    struct SearchTarget {
        let rawTitle: String
        let rawArtist: String
        let cleanTitle: String
        let searchQuery: String
        let titleKeys: [String]
        let artistKeys: [String]

        init(title: String, artist: String) {
            rawTitle = title
            rawArtist = artist
            let parsed = Self.parseVideoTitle(title)
            let cleanArtist = Self.cleanedExternalArtist(artist)
            cleanTitle = parsed.title.isEmpty ? title : parsed.title
            if !parsed.artist.isEmpty && !parsed.title.isEmpty {
                searchQuery = "\(parsed.title) \(parsed.artist)"
            } else {
                searchQuery = "\(parsed.title.isEmpty ? title : parsed.title) \(cleanArtist)"
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            titleKeys = Self.uniqueKeys([title, parsed.title, parsed.subtitle])
            artistKeys = Self.uniqueKeys([cleanArtist, parsed.artist])
        }

        private static func parseVideoTitle(_ value: String) -> (artist: String, title: String, subtitle: String) {
            if let bracketed = prominentBracketTitle(in: value) {
                return bracketed
            }

            let withoutQuotedLyrics = value
                .replacingOccurrences(of: #"『[^』]*』"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"【[^】]*】"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\([^)]*(動態|动态|歌詞|歌词|mv|MV)[^)]*\)"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let separators = [" - ", " – ", " — ", " | ", "｜"]
            for separator in separators where withoutQuotedLyrics.contains(separator) {
                let parts = withoutQuotedLyrics
                    .components(separatedBy: separator)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if parts.count >= 2 {
                    return (artist: parts[0], title: preferredCatalogTitle(from: parts[1]), subtitle: withoutQuotedLyrics)
                }
            }

            return (artist: "", title: preferredCatalogTitle(from: withoutQuotedLyrics), subtitle: "")
        }

        private static func prominentBracketTitle(in value: String) -> (artist: String, title: String, subtitle: String)? {
            let regex = try? NSRegularExpression(pattern: #"【([^】]+)】"#)
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            let matches = regex?.matches(in: value, range: range) ?? []

            for match in matches {
                guard
                    let contentRange = Range(match.range(at: 1), in: value),
                    let fullRange = Range(match.range(at: 0), in: value)
                else { continue }

                let content = String(value[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !isBracketNoise(content) else { continue }

                let artist = String(value[..<fullRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (artist: artist, title: preferredCatalogTitle(from: content), subtitle: value)
            }

            return nil
        }

        private static func isBracketNoise(_ value: String) -> Bool {
            value.range(of: #"(動態|动态|歌詞|歌词|lyrics?|mv|official|完整版|官方)"#, options: [.regularExpression, .caseInsensitive]) != nil
        }

        private static func preferredCatalogTitle(from value: String) -> String {
            var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

            while let feature = parentheticalParts(in: trimmed).first(where: { isFeatureCredit($0.content) }) {
                trimmed = trimmed
                    .replacingCharacters(in: feature.fullRange, with: "")
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            for part in parentheticalParts(in: trimmed).reversed() {
                let content = preferredCatalogTitle(from: part.content)
                if shouldPreferParentheticalTitle(content, over: trimmed, removing: part.fullRange) {
                    return content
                }
            }

            return cjkTitleWithoutLatinAlias(trimmed)
        }

        private static func isFeatureCredit(_ value: String) -> Bool {
            value.range(of: #"^(feat\.?|ft\.?|featuring)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        }

        private static func parentheticalParts(in value: String) -> [(fullRange: Range<String.Index>, content: String)] {
            var stack: [String.Index] = []
            var parts: [(fullRange: Range<String.Index>, content: String)] = []

            var index = value.startIndex
            while index < value.endIndex {
                let character = value[index]
                if character == "(" {
                    stack.append(index)
                } else if character == ")", let start = stack.popLast(), stack.isEmpty {
                    let contentStart = value.index(after: start)
                    let fullEnd = value.index(after: index)
                    let content = String(value[contentStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                    parts.append((start..<fullEnd, content))
                }
                index = value.index(after: index)
            }

            return parts
        }

        private static func cleanedExternalArtist(_ value: String) -> String {
            let cleaned = value
                .replacingOccurrences(of: #"\s+-\s+Topic$"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let genericTopicArtists = ["release"]
            return genericTopicArtists.contains(cleaned.lowercased()) ? "" : cleaned
        }

        private static func shouldPreferParentheticalTitle(
            _ content: String,
            over title: String,
            removing fullRange: Range<String.Index>
        ) -> Bool {
            let titleWithoutParenthetical = title.replacingCharacters(in: fullRange, with: "")
            return containsCJKOrKorean(content) && !containsCJKOrKorean(titleWithoutParenthetical)
        }

        private static func containsCJKOrKorean(_ value: String) -> Bool {
            value.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]"#, options: .regularExpression) != nil
        }

        private static func cjkTitleWithoutLatinAlias(_ value: String) -> String {
            guard containsCJKOrKorean(value), value.range(of: #"[a-z]"#, options: [.regularExpression, .caseInsensitive]) != nil else {
                return value
            }

            return value
                .replacingOccurrences(of: #"(?i)\b(?!part\s*\d+\b)[a-z][a-z0-9'’.\- ]*"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func uniqueKeys(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values
                .flatMap(normalizedKeys)
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
    }

    private static func normalizedKeys(_ value: String) -> [String] {
        let lowercased = value.lowercased()
        let simplified = lowercased.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? lowercased
        var seen = Set<String>()
        return [lowercased, simplified]
            .map(normalized)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]+"#, with: "", options: .regularExpression)
    }

    private func titleScore(songKeys: [String], targetKeys: [String]) -> Int {
        bestScore(songKeys: songKeys, targetKeys: targetKeys, exact: 120, contains: 80)
    }

    private func artistScore(songKeys: [String], targetKeys: [String]) -> Int {
        bestScore(songKeys: songKeys, targetKeys: targetKeys, exact: 70, contains: 35)
    }

    private func bestScore(songKeys: [String], targetKeys: [String], exact: Int, contains: Int) -> Int {
        var score = 0
        for songKey in songKeys where !songKey.isEmpty {
            for targetKey in targetKeys where !targetKey.isEmpty {
                if songKey == targetKey {
                    score = max(score, exact)
                } else if songKey.contains(targetKey) || targetKey.contains(songKey) {
                    score = max(score, contains)
                }
            }
        }
        return score
    }

    private func versionPenalty(songTitle: String, targetTitle: String) -> Int {
        let song = Self.normalized(songTitle)
        let target = Self.normalized(targetTitle)
        let versionMarkers = ["dj", "remix", "伴奏", "翻自", "cover", "live", "纯音乐", "instrumental"]
        return versionMarkers.reduce(0) { penalty, marker in
            song.contains(marker) && !target.contains(marker) ? penalty + 25 : penalty
        }
    }

    private func fetchLyrics(songID: Int) async -> [LyricLine] {
        var components = URLComponents(string: "https://music.163.com/api/song/lyric")
        components?.queryItems = [
            .init(name: "id", value: "\(songID)"),
            .init(name: "lv", value: "-1"),
            .init(name: "kv", value: "-1"),
            .init(name: "tv", value: "-1")
        ]
        guard let url = components?.url else { return [] }

        do {
            let (data, _) = try await session.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let lyricContainer = json?["lrc"] as? [String: Any]
            let lyric = lyricContainer?["lyric"] as? String ?? ""
            let translationContainer = json?["tlyric"] as? [String: Any]
            let translatedLyric = translationContainer?["lyric"] as? String ?? ""
            return LyricParser.parse(lyric, translated: translatedLyric)
        } catch {
            return []
        }
    }
}
