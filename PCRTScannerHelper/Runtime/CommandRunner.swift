import Foundation
import Darwin
import PCRTCore

struct CommandResult {
    let executable: String
    let arguments: [String]
    let exitCode: Int32
    let timedOut: Bool
    let cancelled: Bool
    let duration: TimeInterval
    let stdout: String
    let stderr: String

    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var evidence: CommandEvidence {
        CommandEvidence(command: executable, arguments: arguments, exitCode: exitCode, timedOut: timedOut, cancelled: cancelled, durationSeconds: duration, standardOutput: stdout, standardError: stderr)
    }
}

final class CommandRunner {
    private let cancellation: CancellationController
    private let logger: RunLogger
    private let maximumOutputBytes = 8 * 1024 * 1024

    init(cancellation: CancellationController, logger: RunLogger) {
        self.cancellation = cancellation
        self.logger = logger
    }

    func run(_ executable: String, _ arguments: [String] = [], timeout: TimeInterval = 60) -> CommandResult {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C", "LANG": "C"]) { _, new in new }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let lock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            if stdoutData.count < self.maximumOutputBytes {
                stdoutData.append(data.prefix(self.maximumOutputBytes - stdoutData.count))
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            if stderrData.count < self.maximumOutputBytes {
                stderrData.append(data.prefix(self.maximumOutputBytes - stderrData.count))
            }
        }

        logger.write("Command: \(([executable] + arguments).joined(separator: " "))")
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            return CommandResult(executable: executable, arguments: arguments, exitCode: -1, timedOut: false, cancelled: false, duration: Date().timeIntervalSince(started), stdout: "", stderr: error.localizedDescription)
        }
        cancellation.register(process)
        var timedOut = false
        while process.isRunning {
            if cancellation.isCancelled {
                process.terminate()
                break
            }
            if Date().timeIntervalSince(started) > timeout {
                timedOut = true
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            Thread.sleep(forTimeInterval: 1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        cancellation.unregister(process)
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        let remainingOut = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let remainingErr = errorPipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        stdoutData.append(remainingOut.prefix(max(0, maximumOutputBytes - stdoutData.count)))
        stderrData.append(remainingErr.prefix(max(0, maximumOutputBytes - stderrData.count)))
        let out = String(data: stdoutData, encoding: .utf8) ?? ""
        let err = String(data: stderrData, encoding: .utf8) ?? ""
        lock.unlock()

        let result = CommandResult(executable: executable, arguments: arguments, exitCode: process.terminationStatus, timedOut: timedOut, cancelled: cancellation.isCancelled, duration: Date().timeIntervalSince(started), stdout: out, stderr: err)
        logger.write("Command completed: exit \(result.exitCode), timeout \(result.timedOut), duration \(String(format: "%.2f", result.duration)) sec")
        return result
    }
}
