import AppKit

final class StatusItemView: NSView {
    private let icon = NSImage(systemSymbolName: "music.note", accessibilityDescription: "MusicIsland")
    private var lyric: String?
    private var fontSize: Double = 13
    private var backgroundStyle: MenuBarLyricBackgroundStyle = .pill
    private var backgroundColor: MenuBarLyricBackgroundColor = .sky
    private var backgroundOpacity: Double = 0.55
    // Laid out once per lyric change. AppKit asks for the intrinsic size more
    // than once per update and then draws, and text layout is the expensive part
    // of both — doing it in `update` keeps it off the menu bar's draw path.
    private var lyricAttributedString = NSAttributedString()
    private var lyricTextSize: NSSize = .zero

    override var intrinsicContentSize: NSSize {
        let textWidth = lyricTextSize.width
        let width = textWidth > 0 ? 19 + 6 + textWidth + 18 : 24
        return NSSize(width: ceil(width), height: NSStatusBar.system.thickness)
    }

    func update(
        lyric: String?,
        fontSize: Double,
        backgroundStyle: MenuBarLyricBackgroundStyle,
        backgroundColor: MenuBarLyricBackgroundColor,
        backgroundOpacity: Double
    ) {
        guard lyric != self.lyric
            || fontSize != self.fontSize
            || backgroundStyle != self.backgroundStyle
            || backgroundColor != self.backgroundColor
            || backgroundOpacity != self.backgroundOpacity
        else { return }

        self.lyric = lyric
        self.fontSize = fontSize
        self.backgroundStyle = backgroundStyle
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        layOutLyric()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private func layOutLyric() {
        guard let lyric, !lyric.isEmpty else {
            lyricAttributedString = NSAttributedString()
            lyricTextSize = .zero
            return
        }

        lyricAttributedString = NSAttributedString(
            string: lyric,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor.labelColor,
                .kern: 0.05,
            ]
        )
        lyricTextSize = lyricAttributedString.size()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let height = bounds.height
        let iconSize = NSSize(width: 15, height: 15)
        let iconRect = NSRect(
            x: 4,
            y: floor((height - iconSize.height) / 2),
            width: iconSize.width,
            height: iconSize.height
        )
        let configuredIcon = icon?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        )
        configuredIcon?.draw(
            in: iconRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )

        guard let lyric, !lyric.isEmpty else { return }

        let textSize = lyricTextSize
        let textRect = NSRect(
            x: iconRect.maxX + 9,
            y: floor((height - textSize.height) / 2),
            width: textSize.width,
            height: textSize.height
        )

        if backgroundStyle == .pill {
            let pillRect = textRect.insetBy(dx: -8, dy: -3)
            backgroundColor.nsColor
                .withAlphaComponent(backgroundOpacity)
                .setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: 7, yRadius: 7).fill()
        }

        lyricAttributedString.draw(in: textRect)
    }
}
