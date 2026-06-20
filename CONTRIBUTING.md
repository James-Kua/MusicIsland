# Contributing to MusicIsland

Thanks for your interest in improving MusicIsland! This is a small, experimental macOS app and contributions of all sizes are welcome — bug reports, fixes, features, and docs.

## Getting set up

You'll need macOS 13+ and the Swift 5.9 toolchain (install Xcode or the Command Line Tools).

```bash
# Build the binary
swift build

# Build, bundle into a .app, code-sign, and launch
./Scripts/restart-app.sh
```

`restart-app.sh` is the fastest inner loop: it rebuilds, kills the running instance, re-bundles, signs, and relaunches. Run it again after each change.

For playback control and lyrics to work end to end you'll want [NetEase Cloud Music](https://music.163.com/) installed and running, and MusicIsland granted **Accessibility** access (System Settings → Privacy & Security → Accessibility).

## Project layout

The app is a single executable target organized **one type per file**. See the [Architecture section in the README](README.md#architecture) for the full map. In short:

- `App/` — entry point, app delegate, menu bar hover handling
- `Models/` — value types and the observable `MusicModel`
- `Window/` + `Views/` — the floating island window and its SwiftUI views
- `NowPlaying/` — reading system now-playing state
- `NetEase/` — playback control, the lyrics HTTP client, and the LRC parser
- `Support/` — logging and permissions helpers

When adding a new type, please give it its own file in the matching folder to keep things easy to navigate.

## App icon

The icon lives at `Resources/AppIcon.icns`. The bundling scripts (`restart-app.sh`, `build-dmg.sh`) copy it into the app and reference it via `CFBundleIconFile`. To change it, replace the `.icns` file.

## Conventions

- Match the surrounding Swift style (4-space indentation, no semicolons, `// MARK:`-free unless it helps).
- Keep UI work on the main actor; the now-playing bridge does blocking work off the main thread on purpose.
- Prefer small, focused PRs with a clear description of what changed and why.
- If you touch behavior that depends on private APIs (`MediaRemote`) or NetEase's web API, please note which macOS / app version you tested against.

## Debugging

MusicIsland writes a debug log to `/private/tmp/musicisland-debug.log` (see `Support/DebugLog.swift`). Tail it while reproducing an issue:

```bash
tail -f /private/tmp/musicisland-debug.log
```

## Reporting bugs

Please open an issue with your macOS version, NetEase Music version, and steps to reproduce. Logs from the file above are very helpful.
