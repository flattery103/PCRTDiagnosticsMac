import Foundation

public enum IPCMessageType: String, Codable {
    case hello
    case privilegedPreflight
    case ready
    case begin
    case heartbeat
    case status
    case progress
    case result
    case warning
    case log
    case reportPaths
    case cancel
    case cancelled
    case fatalError
    case complete
}

public struct IPCMessage: Codable, Equatable {
    public var protocolVersion: Int
    public var runID: String
    public var sequence: Int
    public var type: IPCMessageType
    public var message: String?
    public var test: String?
    public var status: CheckStatus?
    public var completed: Int?
    public var total: Int?
    public var percent: Int?
    public var acknowledged: Bool?
    public var reportPaths: ReportPaths?
    public var scanConfiguration: HelperScanConfiguration?

    public init(
        protocolVersion: Int = PCRTProduct.ipcProtocolVersion,
        runID: String,
        sequence: Int,
        type: IPCMessageType,
        message: String? = nil,
        test: String? = nil,
        status: CheckStatus? = nil,
        completed: Int? = nil,
        total: Int? = nil,
        percent: Int? = nil,
        acknowledged: Bool? = nil,
        reportPaths: ReportPaths? = nil,
        scanConfiguration: HelperScanConfiguration? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.runID = runID
        self.sequence = sequence
        self.type = type
        self.message = message
        self.test = test
        self.status = status
        self.completed = completed
        self.total = total
        self.percent = percent
        self.acknowledged = acknowledged
        self.reportPaths = reportPaths
        self.scanConfiguration = scanConfiguration
    }
}
