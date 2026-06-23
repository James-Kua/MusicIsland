import AppKit

/// Tracks pointer hover over the menu bar status item. Combines `NSTrackingArea`
/// events with a short polling timer so the island stays open while the pointer
/// moves onto the expanded window.
final class StatusItemHoverController: NSObject {
    private let onEnter: () -> Void
    private let onExit: () -> Void
    private let activeWindowFrame: () -> NSRect?
    private weak var button: NSStatusBarButton?
    private var trackingArea: NSTrackingArea?
    private var hoverTimer: Timer?
    private var isHovering = false

    init(
        onEnter: @escaping () -> Void,
        onExit: @escaping () -> Void,
        activeWindowFrame: @escaping () -> NSRect?
    ) {
        self.onEnter = onEnter
        self.onExit = onExit
        self.activeWindowFrame = activeWindowFrame
    }

    deinit {
        hoverTimer?.invalidate()
    }

    func attach(to button: NSStatusBarButton?) {
        guard let button else { return }
        self.button = button
        let area = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        button.addTrackingArea(area)
        trackingArea = area
        startHoverPolling()
    }

    @objc func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    @objc func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    private func startHoverPolling() {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.pollHover()
        }
    }

    private func pollHover() {
        guard let button, let buttonWindow = button.window else { return }
        let mouse = NSEvent.mouseLocation
        let buttonFrame = button.convert(button.bounds, to: nil)
        let screenFrame = buttonWindow.convertToScreen(buttonFrame).insetBy(dx: -6, dy: -6)

        // Treat the pointer as still hovering while it is over the button or
        // anywhere on the expanded island window, so moving the pointer onto
        // the open island never collapses it. The window frame is grown by 8pt
        // so the top edge reaches up to bridge the gap to the button.
        var hovering = screenFrame.contains(mouse)
        if !hovering, let windowFrame = activeWindowFrame() {
            hovering = windowFrame.insetBy(dx: -8, dy: -8).contains(mouse)
        }
        setHovering(hovering)
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        hovering ? onEnter() : onExit()
    }
}
