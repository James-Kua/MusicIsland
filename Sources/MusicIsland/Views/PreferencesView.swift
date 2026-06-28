import SwiftUI

struct PreferencesView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Preferences")
                .font(.system(size: 20, weight: .semibold))

            Form {
                Toggle("Show menu bar lyrics", isOn: $settings.showMenuBarLyrics)

                Picker("Background", selection: $settings.menuBarLyricBackgroundStyle) {
                    ForEach(MenuBarLyricBackgroundStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Opacity")
                    Slider(value: $settings.menuBarLyricBackgroundOpacity, in: 0.06...0.36)
                        .disabled(settings.menuBarLyricBackgroundStyle == .plain)
                    Text("\(Int(settings.menuBarLyricBackgroundOpacity * 100))%")
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }

                Stepper(
                    "Font size: \(Int(settings.menuBarLyricFontSize)) pt",
                    value: $settings.menuBarLyricFontSize,
                    in: 11...16,
                    step: 1
                )

                Stepper(
                    "Max characters: \(settings.menuBarLyricMaxCharacters)",
                    value: $settings.menuBarLyricMaxCharacters,
                    in: 18...80,
                    step: 1
                )
            }
            .formStyle(.grouped)

            Divider()

            preview
        }
        .padding(22)
        .frame(width: 420)
    }

    private var preview: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 13, weight: .medium))

            Text("Meet me where the music starts")
                .font(.system(size: settings.menuBarLyricFontSize, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, settings.menuBarLyricBackgroundStyle == .pill ? 9 : 0)
        .padding(.vertical, settings.menuBarLyricBackgroundStyle == .pill ? 4 : 0)
        .background(previewBackground)
    }

    @ViewBuilder
    private var previewBackground: some View {
        if settings.menuBarLyricBackgroundStyle == .pill {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(settings.menuBarLyricBackgroundOpacity))
        }
    }
}
