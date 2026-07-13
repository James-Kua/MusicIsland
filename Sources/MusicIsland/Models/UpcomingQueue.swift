import Foundation

struct UpcomingQueueItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let artworkURL: URL?

    init(id: String, title: String, subtitle: String, artworkURL: URL? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
    }
}

enum UpcomingQueueState: Equatable, Sendable {
    case idle
    case loading
    case loaded(source: String, items: [UpcomingQueueItem])
    case unavailable(String)
}
