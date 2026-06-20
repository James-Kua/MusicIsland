import Foundation

/// An immutable snapshot of player state produced by `NowPlayingBridge`.
struct NowPlayingSnapshot {
    let track: Track
    let elapsed: TimeInterval
    let duration: TimeInterval
    let artworkData: Data?
}
