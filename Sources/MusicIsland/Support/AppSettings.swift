import AppKit
import SwiftUI

enum MenuBarLyricBackgroundStyle: String, CaseIterable, Identifiable {
    case pill
    case plain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pill:
            "Pill"
        case .plain:
            "Plain"
        }
    }
}

enum MenuBarLyricBackgroundColor: String, CaseIterable, Identifiable {
    case blush
    case peach
    case butter
    case mint
    case seafoam
    case sky
    case lavender
    case lilac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blush:
            "Blush"
        case .peach:
            "Peach"
        case .butter:
            "Butter"
        case .mint:
            "Mint"
        case .seafoam:
            "Seafoam"
        case .sky:
            "Sky"
        case .lavender:
            "Lavender"
        case .lilac:
            "Lilac"
        }
    }

    private var components: (red: Double, green: Double, blue: Double) {
        switch self {
        case .blush:
            (1.00, 0.72, 0.78)
        case .peach:
            (1.00, 0.79, 0.63)
        case .butter:
            (1.00, 0.91, 0.57)
        case .mint:
            (0.72, 0.91, 0.67)
        case .seafoam:
            (0.62, 0.91, 0.84)
        case .sky:
            (0.62, 0.82, 1.00)
        case .lavender:
            (0.77, 0.73, 1.00)
        case .lilac:
            (0.91, 0.72, 1.00)
        }
    }

    var swiftUIColor: Color {
        Color(red: components.red, green: components.green, blue: components.blue)
    }

    var nsColor: NSColor {
        NSColor(
            calibratedRed: components.red,
            green: components.green,
            blue: components.blue,
            alpha: 1
        )
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let showMenuBarLyrics = "showMenuBarLyrics"
        static let menuBarLyricBackgroundStyle = "menuBarLyricBackgroundStyle"
        static let menuBarLyricBackgroundColor = "menuBarLyricBackgroundColor"
        static let menuBarLyricBackgroundOpacity = "menuBarLyricBackgroundOpacity"
        static let menuBarLyricFontSize = "menuBarLyricFontSize"
        static let menuBarLyricMaxCharacters = "menuBarLyricMaxCharacters"
    }

    private let defaults: UserDefaults

    @Published var showMenuBarLyrics: Bool {
        didSet { defaults.set(showMenuBarLyrics, forKey: Key.showMenuBarLyrics) }
    }

    @Published var menuBarLyricBackgroundStyle: MenuBarLyricBackgroundStyle {
        didSet { defaults.set(menuBarLyricBackgroundStyle.rawValue, forKey: Key.menuBarLyricBackgroundStyle) }
    }

    @Published var menuBarLyricBackgroundColor: MenuBarLyricBackgroundColor {
        didSet { defaults.set(menuBarLyricBackgroundColor.rawValue, forKey: Key.menuBarLyricBackgroundColor) }
    }

    @Published var menuBarLyricBackgroundOpacity: Double {
        didSet { defaults.set(menuBarLyricBackgroundOpacity, forKey: Key.menuBarLyricBackgroundOpacity) }
    }

    @Published var menuBarLyricFontSize: Double {
        didSet { defaults.set(menuBarLyricFontSize, forKey: Key.menuBarLyricFontSize) }
    }

    @Published var menuBarLyricMaxCharacters: Int {
        didSet { defaults.set(menuBarLyricMaxCharacters, forKey: Key.menuBarLyricMaxCharacters) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        showMenuBarLyrics = defaults.object(forKey: Key.showMenuBarLyrics) as? Bool ?? true
        let styleValue = defaults.string(forKey: Key.menuBarLyricBackgroundStyle) ?? MenuBarLyricBackgroundStyle.pill.rawValue
        menuBarLyricBackgroundStyle = MenuBarLyricBackgroundStyle(rawValue: styleValue) ?? .pill
        let colorValue = defaults.string(forKey: Key.menuBarLyricBackgroundColor) ?? MenuBarLyricBackgroundColor.sky.rawValue
        menuBarLyricBackgroundColor = MenuBarLyricBackgroundColor(rawValue: colorValue) ?? .sky
        menuBarLyricBackgroundOpacity = Self.double(
            forKey: Key.menuBarLyricBackgroundOpacity,
            in: 0.2...0.8,
            defaultValue: 0.55,
            defaults: defaults
        )
        menuBarLyricFontSize = Self.double(
            forKey: Key.menuBarLyricFontSize,
            in: 11...16,
            defaultValue: 13,
            defaults: defaults
        )
        menuBarLyricMaxCharacters = Self.integer(
            forKey: Key.menuBarLyricMaxCharacters,
            in: 18...80,
            defaultValue: 40,
            defaults: defaults
        )
    }

    private static func double(
        forKey key: String,
        in range: ClosedRange<Double>,
        defaultValue: Double,
        defaults: UserDefaults
    ) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return min(max(defaults.double(forKey: key), range.lowerBound), range.upperBound)
    }

    private static func integer(
        forKey key: String,
        in range: ClosedRange<Int>,
        defaultValue: Int,
        defaults: UserDefaults
    ) -> Int {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return min(max(defaults.integer(forKey: key), range.lowerBound), range.upperBound)
    }
}
