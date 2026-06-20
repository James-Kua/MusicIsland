import Foundation

/// Playback transport actions, mapped to macOS system-defined media key codes.
enum MediaKey {
    case previous
    case playPause
    case next

    var systemKeyCode: Int {
        switch self {
        case .previous: return 18
        case .playPause: return 16
        case .next: return 17
        }
    }
}
