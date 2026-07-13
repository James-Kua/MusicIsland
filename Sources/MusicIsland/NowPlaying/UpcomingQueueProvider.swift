import AppKit
import ApplicationServices
import Foundation

/// Best-effort queue discovery for sources that do not publish their queue
/// through macOS Now Playing. YouTube playlist links and NetEase accessibility
/// rows are intentionally handled separately so unrelated recommendations are
/// never presented as a real queue.
final class UpcomingQueueProvider: @unchecked Sendable {
    func queue(for track: Track) async -> UpcomingQueueState {
        await Task.detached(priority: .utility) {
            self.loadQueue(for: track)
        }.value
    }

    private func loadQueue(for track: Track) -> UpcomingQueueState {
        if Self.isBrowser(track.appName) {
            return youtubeQueue(for: track)
        }
        if Self.isNetEase(track.appName)
            || (track.appName.isEmpty && NetEaseController.runningApplication() != nil) {
            return netEaseQueue(for: track)
        }
        return .unavailable("Up Next is not available for \(track.appName.isEmpty ? "this player" : track.appName).")
    }

    private func youtubeQueue(for track: Track) -> UpcomingQueueState {
        guard let app = runningApplication(named: track.appName) else {
            return .unavailable("The browser playing YouTube could not be found.")
        }

        let snapshot = AccessibilitySnapshot(application: app)
        guard let pageURL = snapshot.webPageURLs.first(where: YouTubeQueueParser.isWatchURL) else {
            return .unavailable("Open the playing YouTube tab to read its playlist.")
        }

        let items = YouTubeQueueParser.upcomingItems(
            currentURL: pageURL,
            links: snapshot.links,
            limit: 5
        )
        guard !items.isEmpty else {
            return .unavailable("No upcoming YouTube playlist items were found. Start a playlist and try again.")
        }
        return .loaded(source: "YouTube", items: items)
    }

    private func netEaseQueue(for track: Track) -> UpcomingQueueState {
        guard let app = NetEaseController.runningApplication() else {
            return .unavailable("NetEase Music is not running.")
        }

        if let data = NetEasePlayingListReader.read() {
            let items = NetEasePlayingListParser.upcomingItems(
                after: track.title,
                artist: track.artist,
                data: data,
                limit: 5
            )
            if !items.isEmpty {
                return .loaded(source: "NetEase Music", items: items)
            }
        }

        var snapshot = AccessibilitySnapshot(application: app, targetRowText: track.title)
        var items = NetEaseQueueParser.upcomingItems(
            after: track.title,
            rowGroups: snapshot.rowGroups,
            limit: 5
        )

        // NetEase commonly keeps the queue outside the accessibility tree until
        // its queue button is opened. Press it only after a read-only scan fails.
        if items.isEmpty, snapshot.pressFirstButton(matching: NetEaseQueueParser.queueButtonLabels) {
            Thread.sleep(forTimeInterval: 0.25)
            snapshot = AccessibilitySnapshot(application: app, targetRowText: track.title)
            items = NetEaseQueueParser.upcomingItems(
                after: track.title,
                rowGroups: snapshot.rowGroups,
                limit: 5
            )
        }

        guard !items.isEmpty else {
            return .unavailable("NetEase did not expose its play queue. Open the queue in NetEase and refresh.")
        }
        return .loaded(source: "NetEase Music", items: items)
    }

    private func runningApplication(named name: String) -> NSRunningApplication? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.localizedCaseInsensitiveCompare(normalizedName) == .orderedSame
        }
    }

    private static func isBrowser(_ appName: String) -> Bool {
        let name = appName.lowercased()
        return ["safari", "chrome", "chromium", "arc", "edge", "brave", "firefox"]
            .contains { name.contains($0) }
    }

    private static func isNetEase(_ appName: String) -> Bool {
        let name = appName.lowercased()
        return name.contains("netease") || name.contains("网易云音乐") || name.contains("music.163")
    }

}

private enum NetEasePlayingListReader {
    static func read() -> Data? {
        let relativePath = "Library/Containers/com.netease.163music/Data/Documents/storage/file_storage/webdata/file/playingList"
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relativePath)
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }
}

enum NetEasePlayingListParser {
    static func upcomingItems(
        after currentTitle: String,
        artist currentArtist: String,
        data: Data,
        limit: Int
    ) -> [UpcomingQueueItem] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawEntries = root["list"] as? [[String: Any]]
        else { return [] }

        let entries = rawEntries.sorted {
            integerValue($0["displayOrder"]) < integerValue($1["displayOrder"])
        }
        let titleKey = NetEaseQueueParser.normalized(currentTitle)
        let artistKey = NetEaseQueueParser.normalized(currentArtist)
        guard let currentIndex = entries.firstIndex(where: { entry in
            guard let track = entry["track"] as? [String: Any] else { return false }
            let candidateTitle = NetEaseQueueParser.normalized(track["name"] as? String ?? "")
            guard candidateTitle == titleKey else { return false }
            guard !artistKey.isEmpty else { return true }
            let candidateArtists = artistNames(in: track).map(NetEaseQueueParser.normalized)
            return candidateArtists.contains { artist in
                artist == artistKey || artist.contains(artistKey) || artistKey.contains(artist)
            }
        }) ?? entries.firstIndex(where: { entry in
            guard let track = entry["track"] as? [String: Any] else { return false }
            return NetEaseQueueParser.normalized(track["name"] as? String ?? "") == titleKey
        }) else { return [] }

        return entries.dropFirst(currentIndex + 1).compactMap { entry -> UpcomingQueueItem? in
            guard
                let track = entry["track"] as? [String: Any],
                let title = track["name"] as? String,
                title.hasReadableContent
            else { return nil }
            let artists = artistNames(in: track).joined(separator: ", ")
            let duration = formattedDuration(in: track)
            let identifier = stringValue(track["id"])
            return UpcomingQueueItem(
                id: "netease:\(identifier.isEmpty ? NetEaseQueueParser.normalized(title) : identifier)",
                title: title,
                subtitle: subtitle(artist: artists, duration: duration),
                artworkURL: artworkURL(in: track)
            )
        }.prefix(limit).map { $0 }
    }

    private static func artistNames(in track: [String: Any]) -> [String] {
        let artists = track["artists"] as? [[String: Any]] ?? track["ar"] as? [[String: Any]] ?? []
        return artists.compactMap { $0["name"] as? String }.filter(\.hasReadableContent)
    }

    private static func artworkURL(in track: [String: Any]) -> URL? {
        let album = track["album"] as? [String: Any] ?? track["al"] as? [String: Any]
        guard let value = album?["picUrl"] as? String, var components = URLComponents(string: value) else {
            return nil
        }
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }
        return components.url
    }

    private static func formattedDuration(in track: [String: Any]) -> String? {
        let value = track["duration"] ?? track["dt"]
        let milliseconds: Double?
        if let value = value as? NSNumber {
            milliseconds = value.doubleValue
        } else if let value = value as? String {
            milliseconds = Double(value)
        } else {
            milliseconds = value as? Double
        }
        guard let milliseconds, milliseconds > 0 else { return nil }
        return formatDuration(seconds: Int(milliseconds / 1_000))
    }

    private static func subtitle(artist: String, duration: String?) -> String {
        if !artist.isEmpty, let duration {
            return "\(artist) • \(duration)"
        }
        if !artist.isEmpty { return artist }
        return duration ?? "NetEase Music"
    }

    private static func formatDuration(seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
            : String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private static func integerValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? .max }
        return .max
    }

    private static func stringValue(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        if let value = value as? Int { return String(value) }
        return ""
    }
}

struct AccessibilityLink: Equatable, Sendable {
    let title: String
    let url: URL
}

enum YouTubeQueueParser {
    static func isWatchURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("youtube.com") && url.path == "/watch"
    }

    static func upcomingItems(
        currentURL: URL,
        links: [AccessibilityLink],
        limit: Int
    ) -> [UpcomingQueueItem] {
        guard
            let current = URLComponents(url: currentURL, resolvingAgainstBaseURL: false),
            let playlistID = current.queryValue(named: "list"),
            !playlistID.isEmpty
        else { return [] }

        let currentVideoID = current.queryValue(named: "v")
        let explicitIndex = current.queryValue(named: "index").flatMap(Int.init)
        let candidates = links.compactMap { link -> (index: Int, videoID: String, title: String, duration: String?, channel: String?)? in
            guard
                isWatchURL(link.url),
                let components = URLComponents(url: link.url, resolvingAgainstBaseURL: false),
                components.queryValue(named: "list") == playlistID,
                let videoID = components.queryValue(named: "v"),
                let index = components.queryValue(named: "index").flatMap(Int.init),
                link.title.hasReadableContent
            else { return nil }
            let label = parsedYouTubeLabel(link.title)
            return (index, videoID, label.title, label.duration, label.channel)
        }

        let currentIndex = explicitIndex
            ?? candidates.first(where: { $0.videoID == currentVideoID })?.index
        guard let currentIndex else { return [] }

        var seen = Set<String>()
        return candidates
            .filter { $0.index > currentIndex }
            .sorted { $0.index < $1.index }
            .filter { seen.insert($0.videoID).inserted }
            .prefix(limit)
            .map {
                UpcomingQueueItem(
                    id: "youtube:\($0.videoID)",
                    title: $0.title,
                    subtitle: youtubeSubtitle(channel: $0.channel, duration: $0.duration),
                    artworkURL: URL(string: "https://i.ytimg.com/vi/\($0.videoID)/mqdefault.jpg")
                )
            }
    }

    private static func parsedYouTubeLabel(
        _ label: String
    ) -> (title: String, duration: String?, channel: String?) {
        if let match = match(#"(?<!\d)(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\s+(.+))?\s*$"#, in: label) {
            let first = capturedInteger(1, match: match, in: label) ?? 0
            let second = capturedInteger(2, match: match, in: label) ?? 0
            let third = capturedInteger(3, match: match, in: label)
            let duration = third.map { String(format: "%d:%02d:%02d", first, second, $0) }
                ?? String(format: "%d:%02d", first, second)
            return (titleBefore(match, in: label), duration, capturedText(4, match: match, in: label))
        }

        if let match = match(
            #"(?i)(?:(\d+)\s*hours?,?\s*)?(?:(\d+)\s*minutes?,?\s*)?(\d+)\s*seconds?(?:\s+(.+))?\s*$"#,
            in: label
        ) {
            let hours = capturedInteger(1, match: match, in: label) ?? 0
            let minutes = capturedInteger(2, match: match, in: label) ?? 0
            let seconds = capturedInteger(3, match: match, in: label) ?? 0
            let duration = hours > 0
                ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                : String(format: "%d:%02d", minutes, seconds)
            return (titleBefore(match, in: label), duration, capturedText(4, match: match, in: label))
        }

        return (label.trimmingCharacters(in: .whitespacesAndNewlines), nil, nil)
    }

    private static func youtubeSubtitle(channel: String?, duration: String?) -> String {
        switch (channel, duration) {
        case let (.some(channel), .some(duration)):
            "\(channel) • \(duration)"
        case let (.some(channel), nil):
            channel
        case let (nil, .some(duration)):
            duration
        case (nil, nil):
            "YouTube"
        }
    }

    private static func match(_ pattern: String, in value: String) -> NSTextCheckingResult? {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return try? NSRegularExpression(pattern: pattern).firstMatch(in: value, range: range)
    }

    private static func capturedInteger(
        _ index: Int,
        match: NSTextCheckingResult,
        in value: String
    ) -> Int? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return nil }
        return Int(value[swiftRange])
    }

    private static func capturedText(
        _ index: Int,
        match: NSTextCheckingResult,
        in value: String
    ) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return nil }
        let text = value[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func titleBefore(_ match: NSTextCheckingResult, in value: String) -> String {
        guard let range = Range(match.range, in: value) else { return value }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—,"))
        return String(value[..<range.lowerBound]).trimmingCharacters(in: separators)
    }
}

enum NetEaseQueueParser {
    static let queueButtonLabels = ["播放列表", "播放队列", "当前播放", "Play Queue", "Queue"]

    static func upcomingItems(
        after currentTitle: String,
        rowGroups: [[[String]]],
        limit: Int
    ) -> [UpcomingQueueItem] {
        let currentKey = normalized(currentTitle)
        guard !currentKey.isEmpty else { return [] }

        for rows in rowGroups {
            guard let currentIndex = rows.firstIndex(where: { row in
                row.contains { value in
                    let key = normalized(value)
                    return key == currentKey || key.contains(currentKey) || currentKey.contains(key)
                }
            }) else { continue }

            var seen = Set<String>()
            let items = rows.dropFirst(currentIndex + 1).compactMap { row -> UpcomingQueueItem? in
                let duration = row.first(where: isDurationField)
                let fields = row
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { isUsefulField($0) }
                guard let title = fields.first else { return nil }
                let key = normalized(title)
                guard !key.isEmpty, seen.insert(key).inserted else { return nil }
                return UpcomingQueueItem(
                    id: "netease:\(key)",
                    title: title,
                    subtitle: subtitle(artist: fields.dropFirst().first, duration: duration)
                )
            }
            if !items.isEmpty {
                return Array(items.prefix(limit))
            }
        }
        return []
    }

    static func normalized(_ value: String) -> String {
        value.lowercased().replacingOccurrences(
            of: #"[^a-z0-9\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]+"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func isUsefulField(_ value: String) -> Bool {
        guard value.hasReadableContent else { return false }
        if isDurationField(value) { return false }
        if value.range(of: #"^\d+$"#, options: .regularExpression) != nil { return false }
        return !queueButtonLabels.contains { value.localizedCaseInsensitiveCompare($0) == .orderedSame }
    }

    private static func isDurationField(_ value: String) -> Bool {
        value.range(of: #"^(?:\d+:)?\d{1,2}:\d{2}$"#, options: .regularExpression) != nil
    }

    private static func subtitle(artist: String?, duration: String?) -> String {
        if let artist, let duration { return "\(artist) • \(duration)" }
        return artist ?? duration ?? "NetEase Music"
    }
}

private final class AccessibilitySnapshot {
    private static let webAreaRole = "AXWebArea"
    private static let linkRole = "AXLink"
    private let root: AXUIElement
    private(set) var links: [AccessibilityLink] = []
    private(set) var webPageURLs: [URL] = []
    private(set) var rowGroups: [[[String]]] = []
    private var buttons: [(element: AXUIElement, label: String)] = []
    private let targetRowText: String?
    private var visitedNodes = 0
    private let nodeLimit = 6_000

    init(
        application: NSRunningApplication,
        targetRowText: String? = nil
    ) {
        root = AXUIElementCreateApplication(application.processIdentifier)
        self.targetRowText = targetRowText
        if application.localizedName?.localizedCaseInsensitiveContains("Chrome") == true {
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        scan(root, depth: 0)
    }

    func pressFirstButton(matching labels: [String]) -> Bool {
        guard let button = buttons.first(where: { candidate in
            labels.contains { label in
                candidate.label.localizedCaseInsensitiveContains(label)
            }
        }) else { return false }
        return AXUIElementPerformAction(button.element, kAXPressAction as CFString) == .success
    }

    private func scan(_ element: AXUIElement, depth: Int) {
        guard depth < 24, visitedNodes < nodeLimit else { return }
        visitedNodes += 1

        let role = stringAttribute(kAXRoleAttribute, from: element)
        let title = preferredText(from: element)
        if role == Self.webAreaRole, let url = urlAttribute(from: element) {
            webPageURLs.append(url)
        }
        if role == Self.linkRole, let url = urlAttribute(from: element), !title.isEmpty {
            links.append(AccessibilityLink(title: title, url: url))
        }
        if role == kAXButtonRole, !title.isEmpty {
            buttons.append((element, title))
        }

        let children = childElements(of: element)
        let rows = children.filter { stringAttribute(kAXRoleAttribute, from: $0) == kAXRowRole }
        if rows.count >= 2 {
            let fields = rows.map { readableTexts(in: $0, depth: 0) }
            if fields.contains(where: { !$0.isEmpty }) {
                rowGroups.append(fields)
            }
        } else if let targetRowText, (2...80).contains(children.count) {
            // Electron versions of NetEase sometimes expose song entries as
            // groups rather than AX rows. Accept a repeated group only when it
            // contains the current song, which avoids treating sidebars and
            // unrelated library lists as the active queue.
            let fields = children.map { readableTexts(in: $0, depth: 0) }
            let plausibleRows = fields.filter { (1...6).contains($0.count) }
            let containsCurrentTrack = plausibleRows.contains { row in
                row.contains { value in
                    value.localizedCaseInsensitiveContains(targetRowText)
                        || targetRowText.localizedCaseInsensitiveContains(value)
                }
            }
            if plausibleRows.count >= 2, containsCurrentTrack {
                rowGroups.append(plausibleRows)
            }
        }
        for child in children {
            scan(child, depth: depth + 1)
        }
    }

    private func readableTexts(in element: AXUIElement, depth: Int) -> [String] {
        guard depth < 6 else { return [] }
        let role = stringAttribute(kAXRoleAttribute, from: element)
        var values: [String] = []
        if role == kAXStaticTextRole || role == Self.linkRole || role == kAXCellRole {
            let text = preferredText(from: element)
            if text.hasReadableContent {
                values.append(text)
            }
        }
        for child in childElements(of: element) {
            values.append(contentsOf: readableTexts(in: child, depth: depth + 1))
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func preferredText(from element: AXUIElement) -> String {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            let value = stringAttribute(attribute, from: element)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return ""
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return ""
        }
        return value as? String ?? ""
    }

    private func urlAttribute(from element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else {
            return nil
        }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }
}

private extension URLComponents {
    func queryValue(named name: String) -> String? {
        queryItems?.first(where: { $0.name == name })?.value
    }
}
