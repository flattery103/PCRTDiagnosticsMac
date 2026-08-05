import Foundation

public struct DiagnosticResult: Codable, Equatable {
    public var category: String
    public var domain: String
    public var name: String
    public var status: CheckStatus
    public var summary: String
    public var reason: String?
    public var evidence: String?
    public var recommendedAction: String?
    public var details: [String]
    public var durationSeconds: Double
    public var raw: [String: JSONValue]

    public init(
        category: String,
        domain: String,
        name: String,
        status: CheckStatus,
        summary: String,
        reason: String? = nil,
        evidence: String? = nil,
        recommendedAction: String? = nil,
        details: [String] = [],
        durationSeconds: Double = 0,
        raw: [String: JSONValue] = [:]
    ) {
        self.category = category
        self.domain = domain
        self.name = name
        self.status = status
        self.summary = summary
        self.reason = reason
        self.evidence = evidence
        self.recommendedAction = recommendedAction
        self.details = details
        self.durationSeconds = durationSeconds
        self.raw = raw
    }
}

public struct InventoryTable: Codable, Equatable {
    public var title: String
    public var columns: [String]
    public var rows: [[String]]

    public init(title: String, columns: [String], rows: [[String]]) {
        self.title = title
        self.columns = columns
        self.rows = rows
    }
}

public struct InventorySection: Codable, Equatable {
    public var title: String
    public var items: [String: String]
    public var tables: [InventoryTable]

    public init(title: String, items: [String: String] = [:], tables: [InventoryTable] = []) {
        self.title = title
        self.items = items
        self.tables = tables
    }
}

public struct DomainResult: Codable, Equatable {
    public var name: String
    public var status: CheckStatus
    public var summary: String
    public var total: Int
    public var passed: Int
    public var requiringAttention: Int

    public init(name: String, status: CheckStatus, summary: String, total: Int, passed: Int, requiringAttention: Int) {
        self.name = name
        self.status = status
        self.summary = summary
        self.total = total
        self.passed = passed
        self.requiringAttention = requiringAttention
    }
}

public struct CommandEvidence: Codable, Equatable {
    public var command: String
    public var arguments: [String]
    public var exitCode: Int32
    public var timedOut: Bool
    public var cancelled: Bool
    public var durationSeconds: Double
    public var standardOutput: String
    public var standardError: String

    public init(command: String, arguments: [String], exitCode: Int32, timedOut: Bool, cancelled: Bool, durationSeconds: Double, standardOutput: String, standardError: String) {
        self.command = command
        self.arguments = arguments
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.durationSeconds = durationSeconds
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public struct DiagnosticRun: Codable, Equatable {
    public var productName: String
    public var version: String
    public var platform: String
    public var computerName: String
    public var mode: String
    public var modeDisplayName: String
    public var customer: String?
    public var technician: String?
    public var startedLocal: Date
    public var finishedLocal: Date?
    public var overallStatus: CheckStatus
    public var serviceConclusion: String
    public var inventory: [InventorySection]
    public var results: [DiagnosticResult]
    public var domains: [DomainResult]
    public var commands: [String: CommandEvidence]
    public var metadata: [String: JSONValue]

    public init(
        productName: String = "PCRT Diagnostics for macOS",
        version: String,
        platform: String,
        computerName: String,
        mode: String,
        modeDisplayName: String,
        customer: String? = nil,
        technician: String? = nil,
        startedLocal: Date = Date(),
        finishedLocal: Date? = nil,
        overallStatus: CheckStatus = .info,
        serviceConclusion: String = "In progress",
        inventory: [InventorySection] = [],
        results: [DiagnosticResult] = [],
        domains: [DomainResult] = [],
        commands: [String: CommandEvidence] = [:],
        metadata: [String: JSONValue] = [:]
    ) {
        self.productName = productName
        self.version = version
        self.platform = platform
        self.computerName = computerName
        self.mode = mode
        self.modeDisplayName = modeDisplayName
        self.customer = customer
        self.technician = technician
        self.startedLocal = startedLocal
        self.finishedLocal = finishedLocal
        self.overallStatus = overallStatus
        self.serviceConclusion = serviceConclusion
        self.inventory = inventory
        self.results = results
        self.domains = domains
        self.commands = commands
        self.metadata = metadata
    }
}

public struct ReportPaths: Codable, Equatable {
    public var systemInfoHTML: String
    public var testResultsHTML: String
    public var rawJSON: String
    public var log: String

    public init(systemInfoHTML: String, testResultsHTML: String, rawJSON: String, log: String) {
        self.systemInfoHTML = systemInfoHTML
        self.testResultsHTML = testResultsHTML
        self.rawJSON = rawJSON
        self.log = log
    }

    public var requiredFiles: [(name: String, path: String)] {
        [
            ("system-info.html", systemInfoHTML),
            ("test-results.html", testResultsHTML),
            ("raw-data.json", rawJSON),
            ("run-log.txt", log)
        ]
    }
}
