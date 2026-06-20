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
        var components = URLComponents(string: "https://music.163.com/api/cloudsearch/pc")
        components?.queryItems = [
            .init(name: "s", value: "\(title) \(artist)"),
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
            return bestSongID(from: songs ?? [], title: title, artist: artist)
        } catch {
            return nil
        }
    }

    private func bestSongID(from songs: [[String: Any]], title: String, artist: String) -> Int? {
        let targetTitle = normalized(title)
        let targetArtist = normalized(artist)

        let ranked = songs.compactMap { song -> (id: Int, score: Int)? in
            guard let id = song["id"] as? Int else { return nil }
            let songTitle = normalized(song["name"] as? String ?? "")
            let artists = (song["ar"] as? [[String: Any]] ?? song["artists"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
                .map(normalized)

            var score = 0
            if songTitle == targetTitle {
                score += 100
            } else if songTitle.contains(targetTitle) || targetTitle.contains(songTitle) {
                score += 60
            }

            if artists.contains(where: { $0 == targetArtist }) {
                score += 50
            } else if artists.contains(where: { $0.contains(targetArtist) || targetArtist.contains($0) }) {
                score += 25
            }

            return (id, score)
        }

        return ranked.max { $0.score < $1.score }?.id ?? songs.first?["id"] as? Int
    }

    private func normalized(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]+"#, with: "", options: .regularExpression)
    }

    private func fetchLyrics(songID: Int) async -> [LyricLine] {
        var components = URLComponents(string: "https://music.163.com/api/song/lyric")
        components?.queryItems = [
            .init(name: "id", value: "\(songID)"),
            .init(name: "lv", value: "1"),
            .init(name: "kv", value: "1"),
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
