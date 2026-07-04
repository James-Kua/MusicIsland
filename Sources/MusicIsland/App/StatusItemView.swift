import AppKit

final class StatusItemView: NSView {
    private let icon = NSImage(systemSymbolName: "music.note", accessibilityDescription: "MusicIsland")
    private var lyric: String?
    private var fontSize: Double = 13
    private var backgroundStyle: MenuBarLyricBackgroundStyle = .pill
    private var backgroundColor: MenuBarLyricBackgroundColor = .sky
    private var backgroundOpacity: Double = 0.55

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
        self.lyric = lyric
        self.fontSize = fontSize
        self.backgroundStyle = backgroundStyle
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        invalidateIntrinsicContentSize()
        needsDisplay = true
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

    private var lyricTextSize: NSSize {
        guard lyric?.isEmpty == false else { return .zero }
        return lyricAttributedString.size()
    }

    private var lyricAttributedString: NSAttributedString {
        NSAttributedString(
            string: lyric ?? "",
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor.labelColor,
                .kern: 0.05,
            ]
        )
    }
}
