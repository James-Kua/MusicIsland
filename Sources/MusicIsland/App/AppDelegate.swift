import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var islandController: IslandWindowController?
    private var preferencesController: PreferencesWindowController?
    private var statusItem: NSStatusItem?
    private var statusView: StatusItemView?
    private var statusHoverController: StatusItemHoverController?
    private var model: MusicModel?
    private let settings = AppSettings()
    private var latestStatusLyric = ""
    private var latestStatusIsPlaying = false
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AccessibilityPermission.requestIfNeeded()
        let model = MusicModel()
        self.model = model
        let preferencesController = PreferencesWindowController(settings: settings)
        self.preferencesController = preferencesController
        let controller = IslandWindowController(
            model: model,
            onOpenPreferences: { [weak preferencesController] in
                preferencesController?.show()
            }
        )
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
        let view = StatusItemView()
        view.autoresizingMask = [.width, .height]
        item.button?.image = nil
        item.button?.title = ""
        item.button?.wantsLayer = true
        item.button?.addSubview(view)

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
        statusView = view
        statusHoverController = hoverController
        updateStatusItemLength()
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

        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refreshStatusTitle()
                }
            }
            .store(in: &cancellables)
    }

    private static let lyricPlaceholders: Set<String> = [
        "Lyrics will appear here",
        "Finding lyrics...",
        "No synced lyric found",
    ]

    private func updateStatusTitle(lyric: String, isPlaying: Bool) {
        latestStatusLyric = lyric
        latestStatusIsPlaying = isPlaying

        let trimmed = lyric.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.showMenuBarLyrics,
              isPlaying,
              trimmed.hasReadableContent,
              !Self.lyricPlaceholders.contains(trimmed) else {
            clearStatusLyric()
            return
        }

        let maxCharacters = settings.menuBarLyricMaxCharacters
        let display = trimmed.count > maxCharacters
            ? trimmed.prefix(maxCharacters - 1).trimmingCharacters(in: .whitespaces) + "…"
            : trimmed
        applyStatusLyric(display)
    }

    private func applyStatusLyric(_ lyric: String) {
        statusView?.update(
            lyric: lyric,
            fontSize: settings.menuBarLyricFontSize,
            backgroundStyle: settings.menuBarLyricBackgroundStyle,
            backgroundColor: settings.menuBarLyricBackgroundColor,
            backgroundOpacity: settings.menuBarLyricBackgroundOpacity
        )
        updateStatusItemLength()
    }

    private func clearStatusLyric() {
        statusView?.update(
            lyric: nil,
            fontSize: settings.menuBarLyricFontSize,
            backgroundStyle: settings.menuBarLyricBackgroundStyle,
            backgroundColor: settings.menuBarLyricBackgroundColor,
            backgroundOpacity: settings.menuBarLyricBackgroundOpacity
        )
        updateStatusItemLength()
    }

    private func refreshStatusTitle() {
        updateStatusTitle(lyric: latestStatusLyric, isPlaying: latestStatusIsPlaying)
    }

    private func updateStatusItemLength() {
        guard let statusItem, let statusView else { return }
        let size = statusView.intrinsicContentSize
        statusItem.length = size.width
        statusView.frame = NSRect(origin: .zero, size: size)
    }
}
