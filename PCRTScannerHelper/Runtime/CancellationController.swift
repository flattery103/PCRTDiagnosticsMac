import Foundation
import Darwin

final class CancellationController {
    private let lock = NSLock()
    private var cancelled = false
    private var activeProcesses: [Int32: Process] = [:]

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func throwIfCancelled() throws {
        if isCancelled { throw HelperError.cancelled }
    }

    func register(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        if cancelled {
            process.terminate()
        } else if process.processIdentifier > 0 {
            activeProcesses[process.processIdentifier] = process
        }
    }

    func unregister(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        activeProcesses.removeValue(forKey: process.processIdentifier)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let processes = Array(activeProcesses.values)
        lock.unlock()
        for process in processes where process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { Darwin.kill(pid, SIGKILL) }
            }
        }
    }
}
