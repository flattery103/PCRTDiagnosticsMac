import Foundation

public enum ScanStepIdentifier: String, Codable, CaseIterable {
    case administratorPermissions
    case systemInventory
    case cpuInventory
    case primeCalculation
    case cpuWorkload
    case memoryInventory
    case memoryPatterns
    case memoryPressure
    case storageInventory
    case filesystemHealth
    case smartHealth
    case physicalDriveRead
    case diskWriteRead
    case batteryPower
    case usbThunderboltPCI
    case gpuDisplayMetal
    case networkQuality
    case panicShutdownHistory
    case servicesHealth
    case softwareUpdates
    case securityConfiguration
    case rtcProgression
    case temperatureSensors
    case thermalPressure
}

public struct ScanPlanStep: Codable, Equatable {
    public var identifier: ScanStepIdentifier
    public var displayName: String

    public init(_ identifier: ScanStepIdentifier, _ displayName: String) {
        self.identifier = identifier
        self.displayName = displayName
    }
}

public enum ScanPlanner {
    private static let inventory = ScanPlanStep(.systemInventory, "macOS and Mac hardware inventory")
    private static let cpuInventory = ScanPlanStep(.cpuInventory, "CPU inventory")
    private static let prime = ScanPlanStep(.primeCalculation, "CPU prime-number validation")
    private static let cpuStress = ScanPlanStep(.cpuWorkload, "Multi-core sustained CPU workload")
    private static let memoryInventory = ScanPlanStep(.memoryInventory, "Installed and available memory")
    private static let memoryPatterns = ScanPlanStep(.memoryPatterns, "Application-level memory pattern test")
    private static let memoryPressure = ScanPlanStep(.memoryPressure, "Memory pressure workload")
    private static let storage = ScanPlanStep(.storageInventory, "Physical disk, APFS, and volume inventory")
    private static let filesystem = ScanPlanStep(.filesystemHealth, "Filesystem capacity and live APFS verification")
    private static let smart = ScanPlanStep(.smartHealth, "Physical-drive SMART, NVMe, and partition-map health")
    private static let physicalRead = ScanPlanStep(.physicalDriveRead, "Read-only physical-drive sampling")
    private static let diskWrite = ScanPlanStep(.diskWriteRead, "Temporary file write/read/SHA-256 verification")
    private static let battery = ScanPlanStep(.batteryPower, "Battery and power status")
    private static let devices = ScanPlanStep(.usbThunderboltPCI, "USB, Thunderbolt, and PCI inventory")
    private static let gpu = ScanPlanStep(.gpuDisplayMetal, "GPU, display, and Metal capability inventory")
    private static let network = ScanPlanStep(.networkQuality, "Network quality and connectivity")
    private static let logs = ScanPlanStep(.panicShutdownHistory, "Kernel panic, shutdown, and hardware-log review")
    private static let services = ScanPlanStep(.servicesHealth, "Failed and repeatedly crashing services")
    private static let updates = ScanPlanStep(.softwareUpdates, "Available macOS software updates")
    private static let security = ScanPlanStep(.securityConfiguration, "FileVault, SIP, Gatekeeper, and Secure Boot")
    private static let rtc = ScanPlanStep(.rtcProgression, "RTC progression consistency")
    private static let temperatures = ScanPlanStep(.temperatureSensors, "Numerical temperature coverage")
    private static let thermal = ScanPlanStep(.thermalPressure, "Thermal pressure, power, and throttling evidence")

    public static func plan(for scanType: String, memoryPressurePercent: Int, diskTestMB: Int) -> [ScanPlanStep] {
        let mode = scanType.lowercased().replacingOccurrences(of: "-", with: "")
        var common = [inventory, cpuInventory, prime, memoryInventory, storage, filesystem, smart, diskWrite, battery, devices, gpu, network, logs, services, updates, security, rtc, temperatures, thermal]
        switch mode {
        case "hardware":
            return [inventory, cpuInventory, prime, cpuStress, memoryInventory, memoryPatterns, storage, smart, physicalRead, devices, gpu, battery, rtc, temperatures, thermal, logs]
        case "drive":
            return [inventory, storage, temperatures, smart, physicalRead, filesystem, diskWrite, logs]
        case "thermal":
            return [inventory, cpuInventory, temperatures, thermal, cpuStress, temperatures, thermal, logs]
        case "gpu":
            return [inventory, gpu, devices, temperatures, thermal, logs]
        case "full", "deep", "burnin":
            common.insert(memoryPatterns, at: 5)
            common.insert(physicalRead, at: 10)
            common.insert(cpuStress, at: 4)
            if memoryPressurePercent > 0 { common.insert(memoryPressure, at: 7) }
            return common
        default:
            common.insert(memoryPatterns, at: 5)
            return common
        }
    }
}
