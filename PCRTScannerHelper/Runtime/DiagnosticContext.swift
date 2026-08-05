import Foundation
import Darwin
import PCRTCore

final class DiagnosticContext {
    let config: HelperScanConfiguration
    let workspace: URL
    let logger: RunLogger
    let commandRunner: CommandRunner
    let cancellation: CancellationController
    private let sendMessage: (IPCMessage) -> Void
    private var sequence = 100
    private let workloadLock = NSLock()
    private var firstWorkloadStart: Date?
    var run: DiagnosticRun

    init(config: HelperScanConfiguration, workspace: URL, logger: RunLogger, commandRunner: CommandRunner, cancellation: CancellationController, runID: String, sendMessage: @escaping (IPCMessage) -> Void) {
        self.config = config
        self.workspace = workspace
        self.logger = logger
        self.commandRunner = commandRunner
        self.cancellation = cancellation
        self.sendMessage = sendMessage
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let architecture = SystemUtilities.machineArchitecture()
        self.run = DiagnosticRun(
            version: PCRTProduct.version,
            platform: "macOS/\(architecture)",
            computerName: host,
            mode: config.scanType,
            modeDisplayName: config.displayName,
            customer: config.customerName.isEmpty ? nil : config.customerName,
            technician: config.technicianName.isEmpty ? nil : config.technicianName,
            metadata: [
                "architecture": .string(architecture),
                "effective_uid": .number(Double(geteuid())),
                "privileged_helper": .bool(true),
                "persistent_helper_installed": .bool(false)
            ]
        )
        self.runID = runID
    }

    private let runID: String

    func message(type: IPCMessageType, message: String? = nil, test: String? = nil, status: CheckStatus? = nil, completed: Int? = nil, total: Int? = nil, percent: Int? = nil, reportPaths: ReportPaths? = nil) {
        sequence += 1
        sendMessage(IPCMessage(runID: runID, sequence: sequence, type: type, message: message, test: test, status: status, completed: completed, total: total, percent: percent, reportPaths: reportPaths))
    }

    func recordCommand(_ key: String, _ result: CommandResult) {
        run.commands[key] = result.evidence
    }

    func markWorkloadStart(_ date: Date = Date()) {
        workloadLock.lock()
        if firstWorkloadStart == nil { firstWorkloadStart = date }
        workloadLock.unlock()
    }

    var workloadStartedAt: Date {
        workloadLock.lock()
        defer { workloadLock.unlock() }
        return firstWorkloadStart ?? run.startedLocal
    }

    func appendInventory(_ section: InventorySection) {
        if let index = run.inventory.firstIndex(where: { $0.title == section.title }) {
            var existing = run.inventory[index]
            existing.items.merge(section.items) { _, new in new }
            existing.tables.append(contentsOf: section.tables)
            run.inventory[index] = existing
        } else {
            run.inventory.append(section)
        }
    }
}

enum SystemUtilities {
    static func machineArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    static func humanBytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(clamping: value))
    }

    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func plistDictionary(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    static func jsonObject(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    static func flatten(_ value: Any, prefix: String = "") -> [String: String] {
        var result: [String: String] = [:]
        if let dict = value as? [String: Any] {
            for key in dict.keys.sorted() {
                let childPrefix = prefix.isEmpty ? key : "\(prefix).\(key)"
                result.merge(flatten(dict[key] as Any, prefix: childPrefix)) { _, new in new }
            }
        } else if let array = value as? [Any] {
            for (index, item) in array.enumerated() {
                result.merge(flatten(item, prefix: "\(prefix)[\(index)]")) { _, new in new }
            }
        } else if let value = value as? NSNumber {
            result[prefix] = value.stringValue
        } else if let value = value as? String {
            result[prefix] = value
        }
        return result
    }
}
