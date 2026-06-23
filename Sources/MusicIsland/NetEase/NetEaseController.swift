import AppKit
import CoreGraphics
import Foundation

/// Drives NetEase Music playback: locating/launching the app, sending system
/// media keys, and seeking via `MRMediaRemoteSendCommand`.
enum NetEaseController {
    static let bundleIdentifiers = ["com.netease.163music", "com.netease.music"]
    static let appNameHints = ["NetEase", "网易云音乐", "NeteaseMusic", "Music.163"]

    static func runningApplication() -> NSRunningApplication? {
        for identifier in bundleIdentifiers {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
                return app
            }
        }

        return NSWorkspace.shared.runningApplications.first { app in
            let name = app.localizedName ?? ""
            return appNameHints.contains { name.localizedCaseInsensitiveContains($0) }
        }
    }

    static func openNetEaseMusic() {
        for identifier in bundleIdentifiers {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                return
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/NetEaseMusic.app"))
    }

    static func sendMediaKey(_ key: MediaKey) {
        postSystemMediaKey(key.systemKeyCode)
    }

    static func seek(to target: TimeInterval) {
        guard target.isFinite else { return }
        sendSeekCommand(to: target)
        Task.detached(priority: .utility) {
            runInterpreterSeek(to: target)
        }
    }

    private static func sendSeekCommand(to target: TimeInterval) {
        guard
            let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
            let symbol = dlsym(handle, "MRMediaRemoteSendCommand")
        else { return }

        typealias SendCommand = @convention(c) (Int, NSDictionary?) -> Void
        let sendCommand = unsafeBitCast(symbol, to: SendCommand.self)
        sendCommand(24, ["kMRMediaRemoteOptionPlaybackPosition": target])
        dlclose(handle)
    }

    private static func runInterpreterSeek(to target: TimeInterval) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [
            "-e",
            """
            import Foundation
            typealias SendCommand = @convention(c) (Int, NSDictionary?) -> Void
            guard
                let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
                let symbol = dlsym(handle, "MRMediaRemoteSendCommand")
            else { exit(2) }
            let sendCommand = unsafeBitCast(symbol, to: SendCommand.self)
            sendCommand(24, ["kMRMediaRemoteOptionPlaybackPosition": \(target)])
            """
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            ProcessRunner.run(process, timeout: 2.5)
        } catch {
            return
        }
    }

    private static func postSystemMediaKey(_ keyCode: Int) {
        postSystemMediaKey(keyCode, isDown: true)
        postSystemMediaKey(keyCode, isDown: false)
    }

    private static func postSystemMediaKey(_ keyCode: Int, isDown: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: isDown ? 0xA00 : 0xB00)
        let data1 = (keyCode << 16) | ((isDown ? 0xA : 0xB) << 8)
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
