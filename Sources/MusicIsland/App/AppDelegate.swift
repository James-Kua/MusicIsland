import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var islandController: IslandWindowController?
    private var statusItem: NSStatusItem?
    private var statusHoverController: StatusItemHoverController?
    private var model: MusicModel?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AccessibilityPermission.requestIfNeeded()
        let model = MusicModel()
        self.model = model
        let controller = IslandWindowController(model: model)
        islandController = controller
        installStatusItem(controller: controller)
        observe(model)
        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installStatusItem(controller: IslandWindowController) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "MusicIsland")
        item.button?.imagePosition = .imageLeading
        item.button?.imageHugsTitle = true

        let hoverController = StatusItemHoverController(
            onEnter: { [weak controller, weak item] in
                guard let button = item?.button else { return }
                controller?.showExpanded(anchoredTo: button)
            },
            onExit: { [weak controller] in
                controller?.scheduleCollapse()
            },
            activeWindowFrame: { [weak controller] in
                controller?.expandedWindowFrame
            }
        )
        hoverController.attach(to: item.button)

        statusItem = item
        statusHoverController = hoverController
    }

    /// Mirror the live lyric into the menu bar (beside the icon) while playing.
    private func observe(_ model: MusicModel) {
        model.$lyric
            .combineLatest(model.$track)
            .receive(on: RunLoop.main)
            .sink { [weak self] lyric, track in
                self?.updateStatusTitle(lyric: lyric, isPlaying: track.isPlaying)
            }
            .store(in: &cancellables)
    }

    private static let lyricPlaceholders: Set<String> = [
        "Lyrics will appear here",
        "Finding lyrics...",
        "No synced lyric found",
    ]

    private func updateStatusTitle(lyric: String, isPlaying: Bool) {
        guard let button = statusItem?.button else { return }

        let trimmed = lyric.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlaying, !trimmed.isEmpty, !Self.lyricPlaceholders.contains(trimmed) else {
            button.title = ""
            return
        }

        let maxCharacters = 40
        let display = trimmed.count > maxCharacters
            ? trimmed.prefix(maxCharacters - 1).trimmingCharacters(in: .whitespaces) + "…"
            : trimmed
        button.title = " \(display)"
    }
}
