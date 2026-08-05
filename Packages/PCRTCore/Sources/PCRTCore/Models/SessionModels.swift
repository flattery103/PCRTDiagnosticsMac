import Foundation

public struct SessionConfig: Codable, Equatable {
    public var code: String
    public var scanType: String
    public var displayName: String
    public var customerName: String
    public var technicianName: String
    public var uploadReports: Bool
    public var claimEndpoint: String
    public var uploadEndpoint: String
    public var statusEndpoint: String
    public var cpuStressMinutes: Int
    public var memoryPressurePercent: Int
    public var diskTestMB: Int
    public var gpuStressMinutes: Int
    public var rawConfig: [String: JSONValue]

    public init(
        code: String,
        scanType: String,
        displayName: String,
        customerName: String,
        technicianName: String,
        uploadReports: Bool,
        claimEndpoint: String,
        uploadEndpoint: String,
        statusEndpoint: String,
        cpuStressMinutes: Int,
        memoryPressurePercent: Int,
        diskTestMB: Int,
        gpuStressMinutes: Int,
        rawConfig: [String: JSONValue]
    ) {
        self.code = code
        self.scanType = scanType
        self.displayName = displayName
        self.customerName = customerName
        self.technicianName = technicianName
        self.uploadReports = uploadReports
        self.claimEndpoint = claimEndpoint
        self.uploadEndpoint = uploadEndpoint
        self.statusEndpoint = statusEndpoint
        self.cpuStressMinutes = cpuStressMinutes
        self.memoryPressurePercent = memoryPressurePercent
        self.diskTestMB = diskTestMB
        self.gpuStressMinutes = gpuStressMinutes
        self.rawConfig = rawConfig
    }
}

public struct HelperScanConfiguration: Codable, Equatable {
    public var scanType: String
    public var displayName: String
    public var customerName: String
    public var technicianName: String
    public var cpuStressMinutes: Int
    public var memoryPressurePercent: Int
    public var diskTestMB: Int
    public var gpuStressMinutes: Int

    public init(session: SessionConfig) {
        scanType = session.scanType
        displayName = session.displayName
        customerName = session.customerName
        technicianName = session.technicianName
        cpuStressMinutes = session.cpuStressMinutes
        memoryPressurePercent = session.memoryPressurePercent
        diskTestMB = session.diskTestMB
        gpuStressMinutes = session.gpuStressMinutes
    }

    public init(scanType: String, displayName: String, customerName: String, technicianName: String, cpuStressMinutes: Int, memoryPressurePercent: Int, diskTestMB: Int, gpuStressMinutes: Int) {
        self.scanType = scanType
        self.displayName = displayName
        self.customerName = customerName
        self.technicianName = technicianName
        self.cpuStressMinutes = cpuStressMinutes
        self.memoryPressurePercent = memoryPressurePercent
        self.diskTestMB = diskTestMB
        self.gpuStressMinutes = gpuStressMinutes
    }
}
