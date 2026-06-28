import Foundation

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

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let showMenuBarLyrics = "showMenuBarLyrics"
        static let menuBarLyricBackgroundStyle = "menuBarLyricBackgroundStyle"
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
        menuBarLyricBackgroundOpacity = Self.double(
            forKey: Key.menuBarLyricBackgroundOpacity,
            in: 0.06...0.36,
            defaultValue: 0.16,
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
