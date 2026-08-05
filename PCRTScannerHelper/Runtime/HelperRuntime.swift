import Foundation
import Darwin
import PCRTCore

final class HelperRuntime {
    private let arguments: HelperArguments
    private let workspace: URL
    private let connection: UnixSocketConnection
    private let cancellation = CancellationController()
    private let stateCondition = NSCondition()
    private var scanConfiguration: HelperScanConfiguration?
    private var disconnectedError: Error?
    private var sequence = 0
    private let sendLock = NSLock()
    private let heartbeatLock = NSLock()
    private var lastHeartbeat = Date()

    init(arguments: HelperArguments) throws {
        self.arguments = arguments
        workspace = try WorkspaceValidator.validate(arguments: arguments)
        var lastError: Error?
        var connected: UnixSocketConnection?
        for _ in 0..<40 {
            do {
                connected = try UnixSocketClient.connect(path: arguments.socketPath)
                break
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        guard let connection = connected else { throw lastError ?? UnixSocketError.disconnected }
        try connection.requirePeer(uid: arguments.userUID)
        self.connection = connection
    }

    func run() throws {
        connection.startReading(onMessage: { [weak self] message in self?.receive(message) }, onDisconnect: { [weak self] error in self?.disconnected(error) })
        send(type: .hello, message: arguments.nonce)
        let preflightMessage = privilegedPreflight()
        send(type: .privilegedPreflight, message: preflightMessage)
        send(type: .ready, message: "Privileged preflight succeeded. The session can now be claimed.")
        startWatchdog()

        stateCondition.lock()
        let deadline = Date().addingTimeInterval(300)
        while scanConfiguration == nil && disconnectedError == nil && !cancellation.isCancelled && Date() < deadline {
            stateCondition.wait(until: Date().addingTimeInterval(1))
        }
        let config = scanConfiguration
        let connectionError = disconnectedError
        stateCondition.unlock()

        if let error = connectionError { throw error }
        if cancellation.isCancelled { throw HelperError.cancelled }
        guard let config = config else { throw HelperError.protocolError("The GUI did not send a scan configuration within five minutes.") }

        let logURL = workspace.appendingPathComponent("run-log.txt")
        let logger = try RunLogger(url: logURL) { [weak self] line in self?.send(type: .log, message: line) }
        logger.write("PCRT Diagnostics for macOS \(PCRTProduct.version) helper starting.")
        logger.write("Architecture: \(SystemUtilities.machineArchitecture())")
        logger.write("Workspace: \(workspace.path)")
        logger.write("No persistent privileged helper is installed.")
        let commandRunner = CommandRunner(cancellation: cancellation, logger: logger)
        let context = DiagnosticContext(config: config, workspace: workspace, logger: logger, commandRunner: commandRunner, cancellation: cancellation, runID: arguments.runID, sendMessage: { [weak self] message in self?.send(message) })
        let coordinator = ScanCoordinator(context: context)
        do {
            let paths = try coordinator.execute()
            logger.write("Diagnostic run complete. Waiting for GUI upload processing.")
            WorkspaceValidator.returnOwnership(of: workspace, to: arguments.userUID)
            send(type: .reportPaths, message: "Report files are ready for upload.", reportPaths: paths)
            send(type: .complete, message: "Local diagnostics and report generation completed.", reportPaths: paths)
            Thread.sleep(forTimeInterval: 1)
        } catch HelperError.cancelled {
            logger.write("Diagnostic run cancelled.")
            WorkspaceValidator.returnOwnership(of: workspace, to: arguments.userUID)
            send(type: .cancelled, message: "The diagnostic run was cancelled.")
            throw HelperError.cancelled
        } catch {
            logger.write("Fatal helper error: \(error.localizedDescription)")
            WorkspaceValidator.returnOwnership(of: workspace, to: arguments.userUID)
            send(type: .fatalError, message: error.localizedDescription)
            throw error
        }
    }

    private func privilegedPreflight() -> String {
        let required = ["/usr/bin/sw_vers", "/usr/sbin/system_profiler", "/usr/sbin/diskutil", "/usr/bin/log", "/usr/sbin/softwareupdate"]
        let missing = required.filter { !FileManager.default.isExecutableFile(atPath: $0) }
        if missing.isEmpty {
            return "Administrator authorization succeeded; helper, workspace, and required Apple commands are available."
        }
        return "Administrator authorization succeeded. Some Apple commands are unavailable and affected checks will be Incomplete or Not Available: \(missing.joined(separator: ", "))"
    }

    private func receive(_ message: IPCMessage) {
        guard message.protocolVersion == PCRTProduct.ipcProtocolVersion, message.runID == arguments.runID else {
            cancellation.cancel()
            return
        }
        switch message.type {
        case .begin:
            stateCondition.lock()
            scanConfiguration = message.scanConfiguration
            stateCondition.signal()
            stateCondition.unlock()
        case .cancel:
            cancellation.cancel()
            stateCondition.lock(); stateCondition.signal(); stateCondition.unlock()
        case .heartbeat:
            heartbeatLock.lock(); lastHeartbeat = Date(); heartbeatLock.unlock()
        default:
            break
        }
    }

    private func disconnected(_ error: Error?) {
        stateCondition.lock()
        disconnectedError = error ?? UnixSocketError.disconnected
        stateCondition.signal()
        stateCondition.unlock()
        cancellation.cancel()
    }

    private func startWatchdog() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let self = self, !self.cancellation.isCancelled {
                Thread.sleep(forTimeInterval: 5)
                self.heartbeatLock.lock()
                let age = Date().timeIntervalSince(self.lastHeartbeat)
                self.heartbeatLock.unlock()
                if age > 35 {
                    self.cancellation.cancel()
                    return
                }
            }
        }
    }

    private func send(type: IPCMessageType, message: String? = nil, reportPaths: ReportPaths? = nil) {
        send(IPCMessage(runID: arguments.runID, sequence: 0, type: type, message: message, reportPaths: reportPaths))
    }

    private func send(_ message: IPCMessage) {
        sendLock.lock()
        defer { sendLock.unlock() }
        sequence += 1
        let normalized = IPCMessage(
            protocolVersion: PCRTProduct.ipcProtocolVersion,
            runID: arguments.runID,
            sequence: sequence,
            type: message.type,
            message: message.message,
            test: message.test,
            status: message.status,
            completed: message.completed,
            total: message.total,
            percent: message.percent,
            acknowledged: message.acknowledged,
            reportPaths: message.reportPaths,
            scanConfiguration: message.scanConfiguration
        )
        do { try connection.send(normalized) } catch { cancellation.cancel() }
    }
}
