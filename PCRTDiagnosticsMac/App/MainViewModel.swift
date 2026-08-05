import Foundation
import Combine
import AppKit
import PCRTCore

@MainActor
final class MainViewModel: ObservableObject {
    @Published var sessionCode = ""
    @Published private(set) var state: AppRunState = .idle
    @Published private(set) var currentMode = "Waiting for session"
    @Published private(set) var progress = 0
    @Published private(set) var currentTest = "Ready"
    @Published private(set) var completedTests = 0
    @Published private(set) var totalTests = 0
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var statusMessage = "Ready. Enter the session code, then click Start."
    @Published private(set) var detailLines: [String] = []
    @Published private(set) var reportLocation: String?
    @Published private(set) var serverReceivedReports = false

    private var api = ServerAPIClient()
    private var helper: HelperSessionController?
    private var config: SessionConfig?
    private var reportPaths: ReportPaths?
    private var claimClientID = ""
    private var claimStarted = false
    private var claimed = false
    private var uploadStarted = false
    private var elapsedTimer: Timer?
    private var lastServerProgress = Date.distantPast

    var versionText: String { "Version \(PCRTProduct.version)" }
    var isCodeValid: Bool { (try? SessionCode.validate(sessionCode)) != nil }
    var canStart: Bool { isCodeValid && !state.isActive && state != .uploadFailed && state != .complete }
    var canCancel: Bool { state.isActive && state != .uploading }
    var showRetryUpload: Bool { state == .uploadFailed && reportPaths != nil }
    var showReportLocation: Bool { reportLocation != nil }

    func updateCode(_ value: String) {
        sessionCode = SessionCode.normalized(value)
    }

    func start() {
        guard canStart else { return }
        resetRunState()
        startElapsedTimer()
        state = .loadingConfiguration
        statusMessage = "Loading session configuration without consuming the code."
        currentTest = "Loading PCRT session"
        appendDetail("Fetching session configuration from the PCRT server.")
        let code = sessionCode
        Task {
            do {
                let fetched = try await api.fetchConfiguration(code: code)
                config = fetched
                currentMode = fetched.displayName
                state = .unprivilegedPreflight
                currentTest = "Local preflight"
                statusMessage = "Checking the app bundle, report location, and local capacity."
                let controller = try localPreflight(config: fetched)
                helper = controller
                reportLocation = controller.workspaceURL.path
                state = .awaitingAuthorization
                currentTest = "Administrator authorization"
                statusMessage = "Administrator authorization is required to start diagnostics."
                try controller.start(onMessage: { [weak self] message in self?.handle(message) }, onFailure: { [weak self] error in self?.handleHelperFailure(error) }, onAuthorizationStarted: { [weak self] in
                    self?.appendDetail("macOS administrator authorization requested.")
                })
            } catch {
                failBeforeClaim(error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard canCancel else { return }
        state = .cancelling
        currentTest = "Cancelling"
        statusMessage = "Stopping the current diagnostic safely and removing temporary workload files."
        helper?.cancel()
        appendDetail("Cancellation requested.")
        if claimed, let config = config {
            Task { try? await api.updateStatus(config: config, status: "failed", progress: progress, stage: "Cancelled", detail: "The macOS diagnostic run was cancelled by the user.", computerName: ProcessInfo.processInfo.hostName) }
        }
    }

    func retryUpload() {
        guard let paths = reportPaths, let config = config, claimed else { return }
        uploadStarted = false
        Task { await upload(paths: paths, config: config) }
    }

    func showReportsInFinder() {
        guard let location = reportLocation else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: location)])
    }

    private func localPreflight(config: SessionConfig) throws -> HelperSessionController {
        guard Bundle.main.path(forAuxiliaryExecutable: "PCRTScannerHelper") != nil else {
            throw ServerAPIError(statusCode: nil, message: "The app bundle does not contain PCRTScannerHelper.")
        }
        let controller = try HelperSessionController()
        let root = FileManager.default.homeDirectoryForCurrentUser
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        let requestedMB = max(config.diskTestMB, config.scanType == "quick" ? 128 : 512)
        let required = Int64(requestedMB + 256) * 1_048_576
        guard available <= 0 || available >= required else {
            throw ServerAPIError(statusCode: nil, message: "There is not enough free space for the configured disk test and report files. Required: approximately \(requestedMB + 256) MB.")
        }
        appendDetail("Unprivileged preflight passed. Report folder: \(controller.workspaceURL.path)")
        return controller
    }

    private func handle(_ message: IPCMessage) {
        switch message.type {
        case .hello:
            appendDetail("Authenticated the temporary root helper over the local socket.")
        case .privilegedPreflight:
            state = .privilegedPreflight
            currentTest = "Privileged preflight"
            statusMessage = message.message ?? "Running privileged preflight."
            appendDetail(statusMessage)
        case .ready:
            appendDetail(message.message ?? "Privileged helper is ready.")
            claimAndBegin()
        case .status:
            if let text = message.message { statusMessage = text; appendDetail(text) }
        case .progress:
            state = message.percent ?? 0 >= 95 ? .generatingReports : .running
            progress = message.percent ?? progress
            currentTest = message.test ?? currentTest
            completedTests = message.completed ?? completedTests
            totalTests = message.total ?? totalTests
            statusMessage = message.message ?? currentTest
            sendProgressToServerIfNeeded()
        case .result:
            progress = message.percent ?? progress
            currentTest = message.test ?? currentTest
            completedTests = message.completed ?? completedTests
            totalTests = message.total ?? totalTests
            let line = "\(message.status?.rawValue ?? "RESULT"): \(message.test ?? "Test") — \(message.message ?? "")"
            appendDetail(line)
            sendProgressToServerIfNeeded(force: true)
        case .warning, .log:
            if let text = message.message { appendDetail(text) }
        case .reportPaths:
            if let paths = message.reportPaths {
                reportPaths = paths
                reportLocation = URL(fileURLWithPath: paths.rawJSON).deletingLastPathComponent().path
                state = .generatingReports
                statusMessage = "The four required report files were created."
            }
        case .complete:
            if let paths = message.reportPaths { reportPaths = paths }
            guard let paths = reportPaths, let config = config else {
                handleHelperFailure(ServerAPIError(statusCode: nil, message: "The helper completed without returning all report paths."))
                return
            }
            helper?.stop()
            if config.uploadReports {
                Task { await upload(paths: paths, config: config) }
            } else {
                state = .complete
                progress = 100
                currentTest = "Complete"
                statusMessage = "Reports were saved locally. Server upload was disabled by the session configuration, so the app will remain open."
                stopElapsedTimer()
            }
        case .cancelled:
            state = .cancelled
            currentTest = "Cancelled"
            statusMessage = message.message ?? "The diagnostic run was cancelled."
            helper?.stop()
            stopElapsedTimer()
        case .fatalError:
            handleHelperFailure(ServerAPIError(statusCode: nil, message: message.message ?? "The privileged helper encountered an error."))
        case .begin, .heartbeat, .cancel:
            break
        }
    }

    private func claimAndBegin() {
        guard !claimStarted, let config = config, let helper = helper else { return }
        claimStarted = true
        state = .claimingSession
        currentTest = "Claiming PCRT session"
        statusMessage = "Preflight succeeded. Claiming the one-time session code."
        claimClientID = "mac-" + UUID().uuidString
        Task {
            do {
                try await api.claim(config: config, computerName: ProcessInfo.processInfo.hostName, clientID: claimClientID)
                claimed = true
                appendDetail("The session was claimed and a server claim token was received.")
                try await api.updateStatus(config: config, status: "running", progress: 2, stage: "Starting macOS diagnostics", detail: config.displayName, computerName: ProcessInfo.processInfo.hostName)
                try helper.sendBegin(configuration: HelperScanConfiguration(session: config))
                state = .running
                currentTest = "Starting diagnostics"
                statusMessage = "The temporary helper is starting the macOS diagnostic plan."
            } catch {
                handleHelperFailure(error)
            }
        }
    }

    private func sendProgressToServerIfNeeded(force: Bool = false) {
        guard claimed, let config = config else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastServerProgress) >= 2 else { return }
        lastServerProgress = now
        let progressValue = progress
        let stage = totalTests > 0 ? "Testing (\(completedTests)/\(totalTests))" : "Testing"
        let detail = currentTest
        Task { try? await api.updateStatus(config: config, status: "running", progress: progressValue, stage: stage, detail: detail, computerName: ProcessInfo.processInfo.hostName) }
    }

    private func upload(paths: ReportPaths, config: SessionConfig) async {
        guard !uploadStarted else { return }
        uploadStarted = true
        state = .uploading
        progress = 98
        currentTest = "Uploading report files"
        statusMessage = "Uploading system-info.html, test-results.html, raw-data.json, and run-log.txt."
        appendDetail(statusMessage)
        do {
            try await api.updateStatus(config: config, status: "running", progress: 98, stage: "Uploading reports", detail: "Sending the four macOS diagnostic report files.", computerName: ProcessInfo.processInfo.hostName)
            let acknowledgement = try await api.upload(config: config, paths: paths, computerName: ProcessInfo.processInfo.hostName)
            let missing = PCRTProduct.expectedReportNames.subtracting(acknowledgement.uploadedNames)
            guard acknowledgement.acknowledged, missing.isEmpty else {
                throw ServerAPIError(statusCode: nil, message: "The server did not acknowledge all four report files. Missing acknowledgement: \(missing.sorted().joined(separator: ", ")).")
            }
            try await api.updateStatus(config: config, status: "complete", progress: 100, stage: "Complete", detail: "The PCRT server acknowledged all four macOS report files.", computerName: ProcessInfo.processInfo.hostName)
            serverReceivedReports = true
            progress = 100
            state = .complete
            currentTest = "Complete"
            statusMessage = "The PCRT server received all four report files. This app will close automatically."
            appendDetail("Server acknowledgement received for: \(acknowledgement.uploadedNames.sorted().joined(separator: ", ")).")
            stopElapsedTimer()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { NSApp.terminate(nil) }
        } catch {
            uploadStarted = false
            state = .uploadFailed
            currentTest = "Upload failed"
            statusMessage = "Report upload failed. The local reports remain available at \(reportLocation ?? paths.rawJSON). Use Retry Upload after correcting connectivity. Error: \(error.localizedDescription)"
            appendDetail(statusMessage)
            stopElapsedTimer()
        }
    }

    private func handleHelperFailure(_ error: Error) {
        helper?.stop()
        if claimed, let config = config {
            Task { try? await api.updateStatus(config: config, status: "failed", progress: progress, stage: "Client stopped", detail: error.localizedDescription, computerName: ProcessInfo.processInfo.hostName) }
        }
        state = .error
        currentTest = "Stopped"
        statusMessage = error.localizedDescription
        appendDetail("ERROR: \(error.localizedDescription)")
        stopElapsedTimer()
    }

    private func failBeforeClaim(_ message: String) {
        state = .error
        currentTest = "Unable to start"
        statusMessage = message
        appendDetail("ERROR: \(message)")
        stopElapsedTimer()
    }

    private func resetRunState() {
        helper?.stop()
        helper = nil
        api = ServerAPIClient()
        config = nil
        reportPaths = nil
        claimClientID = ""
        claimStarted = false
        claimed = false
        uploadStarted = false
        serverReceivedReports = false
        progress = 0
        completedTests = 0
        totalTests = 0
        elapsedSeconds = 0
        detailLines = []
        reportLocation = nil
        currentMode = "Loading session"
    }

    private func appendDetail(_ line: String) {
        guard !line.isEmpty else { return }
        detailLines.append(line)
        if detailLines.count > 2_000 { detailLines.removeFirst(detailLines.count - 2_000) }
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedSeconds = 0
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsedSeconds += 1 }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}
