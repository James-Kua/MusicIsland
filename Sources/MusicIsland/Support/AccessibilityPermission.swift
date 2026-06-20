import ApplicationServices
import Foundation

/// Requests Accessibility (AX) access, which MusicIsland uses to drive NetEase
/// Music's menu bar playback controls. Prompts the user the first time.
enum AccessibilityPermission {
    static func requestIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        DebugLog.write("accessibility trusted=\(trusted)")
    }
}
