import Foundation

/// Runs short-lived helper processes without allowing them to stall app state.
enum ProcessRunner {
    @discardableResult
    static func run(_ process: Process, timeout: TimeInterval) -> Bool {
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            _ = finished.wait(timeout: .now() + 0.5)
            return false
        }

        return process.terminationStatus == 0
    }
}
