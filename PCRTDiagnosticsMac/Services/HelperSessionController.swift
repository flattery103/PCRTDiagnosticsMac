import Foundation
import AppKit
import Darwin
import PCRTCore

final class HelperSessionController {
    typealias MessageHandler = (IPCMessage) -> Void
    typealias FailureHandler = (Error) -> Void

    let runID = UUID().uuidString
    let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let workspaceURL: URL

    private let socketDirectory: URL
    private let socketPath: String
    private let listener: UnixSocketListener
    private var connection: UnixSocketConnection?
    private var heartbeatTimer: Timer?
    private var connectionTimeout: DispatchWorkItem?
    private var validatedHello = false
    private var sequence = 10
    private let lock = NSLock()
    private var stopped = false

    init() throws {
        let reportsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("PCRTDiagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let host = ProcessInfo.processInfo.hostName.replacingOccurrences(of: "/", with: "-")
        workspaceURL = reportsRoot.appendingPathComponent("\(host)_\(formatter.string(from: Date()))", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        let shortID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        socketDirectory = URL(fileURLWithPath: "/private/tmp/pcrt-\(shortID)", isDirectory: true)
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        socketPath = socketDirectory.appendingPathComponent("helper.sock").path
        listener = UnixSocketListener(path: socketPath)
    }

    deinit { stop() }

    func start(onMessage: @escaping MessageHandler, onFailure: @escaping FailureHandler, onAuthorizationStarted: @escaping () -> Void) throws {
        try listener.start { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async { onFailure(error) }
            case .success(let connection):
                do {
                    try connection.requirePeer(uid: 0)
                    self.connection = connection
                    self.connectionTimeout?.cancel()
                    connection.startReading(onMessage: { [weak self] message in
                        guard let self = self else { return }
                        if message.runID != self.runID || message.protocolVersion != PCRTProduct.ipcProtocolVersion {
                            DispatchQueue.main.async { onFailure(ServerAPIError(statusCode: nil, message: "The privileged helper used an unexpected IPC protocol.")) }
                            self.stop()
                            return
                        }
                        if message.type == .hello {
                            guard message.message == self.nonce else {
                                DispatchQueue.main.async { onFailure(ServerAPIError(statusCode: nil, message: "The privileged helper authentication nonce did not match.")) }
                                self.stop()
                                return
                            }
                            self.validatedHello = true
                        } else if !self.validatedHello {
                            return
                        }
                        DispatchQueue.main.async { onMessage(message) }
                    }, onDisconnect: { [weak self] error in
                        guard let self = self else { return }
                        if let error = error, !self.isStopped {
                            DispatchQueue.main.async { onFailure(error) }
                        }
                    })
                    DispatchQueue.main.async { self.startHeartbeat() }
                } catch {
                    connection.close()
                    DispatchQueue.main.async { onFailure(error) }
                }
            }
        }
        onAuthorizationStarted()
        launchPrivilegedHelper { [weak self] result in
            guard let self = self else { return }
            if case .failure(let error) = result {
                onFailure(error)
                self.stop()
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.connection == nil else { return }
            onFailure(ServerAPIError(statusCode: nil, message: "The privileged helper did not connect after administrator authorization."))
            self.stop()
        }
        connectionTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: timeout)
    }

    func sendBegin(configuration: HelperScanConfiguration) throws {
        sequence += 1
        try connection?.send(IPCMessage(runID: runID, sequence: sequence, type: .begin, scanConfiguration: configuration))
    }

    func cancel() {
        sequence += 1
        try? connection?.send(IPCMessage(runID: runID, sequence: sequence, type: .cancel, message: "Cancel requested by the user."))
    }

    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        lock.unlock()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        connectionTimeout?.cancel()
        connection?.close()
        connection = nil
        listener.stop()
        try? FileManager.default.removeItem(at: socketDirectory)
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.sequence += 1
            try? self.connection?.send(IPCMessage(runID: self.runID, sequence: self.sequence, type: .heartbeat))
        }
        heartbeatTimer?.fire()
    }

    private func launchPrivilegedHelper(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let helperPath = Bundle.main.path(forAuxiliaryExecutable: "PCRTScannerHelper"), FileManager.default.isExecutableFile(atPath: helperPath) else {
            completion(.failure(ServerAPIError(statusCode: nil, message: "The bundled PCRTScannerHelper executable is missing.")))
            return
        }
        let arguments = [
            helperPath,
            "--socket", socketPath,
            "--run-id", runID,
            "--nonce", nonce,
            "--uid", String(getuid()),
            "--workspace", workspaceURL.path
        ]
        let helperCommand = arguments.map(shellQuote).joined(separator: " ")
        let detachedCommand = "/usr/bin/nohup \(helperCommand) </dev/null >/dev/null 2>&1 &"
        let source = "do shell script \(appleScriptLiteral(detachedCommand)) with administrator privileges"
        DispatchQueue.main.async {
            var errorInfo: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
            if result == nil, let errorInfo = errorInfo {
                let number = errorInfo["NSAppleScriptErrorNumber"] as? Int
                let message = (errorInfo["NSAppleScriptErrorMessage"] as? String) ?? "Administrator authorization was cancelled or failed."
                completion(.failure(ServerAPIError(statusCode: number, message: message)))
            } else {
                completion(.success(()))
            }
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
