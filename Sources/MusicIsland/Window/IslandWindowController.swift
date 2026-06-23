import AppKit
import SwiftUI

/// Owns the floating island window: positions it under the menu bar icon,
/// shows it on hover, and collapses it after a short delay once the pointer
/// leaves both the icon and the window.
final class IslandWindowController: NSWindowController {
    private static let expandedSize = NSSize(width: 520, height: 184)
    private let model: MusicModel
    private var collapseTask: Task<Void, Never>?

    init(model: MusicModel) {
        let screenFrame = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let compactSize = Self.expandedSize
        let origin = NSPoint(
            x: screenFrame.maxX - compactSize.width - 12,
            y: screenFrame.maxY - compactSize.height - 10
        )
        self.model = model

        let window = IslandWindow(
            contentRect: NSRect(origin: origin, size: compactSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.ignoresMouseEvents = false

        super.init(window: window)
        window.contentView = NSHostingView(rootView: IslandView(model: model, windowController: self))
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The on-screen frame of the island window while it is expanded, used by
    /// the hover controller to keep the island open while the pointer is over it.
    var expandedWindowFrame: NSRect? {
        guard model.isExpanded, let window, window.isVisible else { return nil }
        return window.frame
    }

    func showExpanded(anchoredTo button: NSStatusBarButton) {
        collapseTask?.cancel()
        guard let window else { return }

        model.isExpanded = true
        positionWindow(anchoredTo: button)
        showWindow(nil)
        window.orderFrontRegardless()
    }

    func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            model.isExpanded = false
            window?.orderOut(nil)
        }
    }

    func cancelCollapse() {
        collapseTask?.cancel()
    }

    private func positionWindow(anchoredTo button: NSStatusBarButton) {
        guard let window, let buttonWindow = button.window else { return }

        let buttonFrame = button.convert(button.bounds, to: nil)
        let anchorFrame = buttonWindow.convertToScreen(buttonFrame)
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = Self.expandedSize
        let x = min(max(anchorFrame.midX - size.width / 2, screenFrame.minX + 8), screenFrame.maxX - size.width - 8)
        let y = max(screenFrame.minY + 8, anchorFrame.minY - size.height - 8)

        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}
