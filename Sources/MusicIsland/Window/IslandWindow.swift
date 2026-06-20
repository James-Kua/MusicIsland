import AppKit

/// Borderless floating window that hosts the island. Can become key (so its
/// controls respond) but never main.
final class IslandWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
