import Foundation
import PCRTCore

final class ScanCoordinator {
    private let context: DiagnosticContext

    init(context: DiagnosticContext) {
        self.context = context
    }

    func execute() throws -> ReportPaths {
        let plan = ScanPlanner.plan(for: context.config.scanType, memoryPressurePercent: context.config.memoryPressurePercent, diskTestMB: context.config.diskTestMB)
        let total = plan.count + 1
        context.run.results.append(DiagnosticResult(category: "Runtime", domain: "macOS Integrity", name: "Administrator permissions", status: .pass, summary: "The temporary diagnostic helper is running with administrator rights.", details: ["Effective UID: \(geteuid())", "The helper is bundled with the app and is not installed permanently."]))
        context.message(type: .result, test: "Administrator permissions", status: .pass, completed: 1, total: total, percent: 2)

        for (index, step) in plan.enumerated() {
            try context.cancellation.throwIfCancelled()
            let completedBefore = index + 1
            let percent = 3 + Int(Double(index) * 88.0 / Double(max(plan.count, 1)))
            context.logger.write("Starting test: \(step.displayName)")
            context.message(type: .progress, message: "Running \(step.displayName)", test: step.displayName, completed: completedBefore, total: total, percent: percent)
            let started = Date()
            var result: DiagnosticResult
            do {
                result = try run(step.identifier)
            } catch HelperError.cancelled {
                throw HelperError.cancelled
            } catch {
                result = DiagnosticResult(category: "Runtime", domain: "macOS Integrity", name: step.displayName, status: .incomplete, summary: "The test stopped because PCRT encountered an internal error.", reason: error.localizedDescription, recommendedAction: "Review run-log.txt and repeat the test with the latest client.")
            }
            if result.durationSeconds <= 0 { result.durationSeconds = Date().timeIntervalSince(started) }
            context.run.results.append(result)
            context.logger.write("Completed test: \(step.displayName) => \(result.status.rawValue)")
            context.message(type: .result, message: result.summary, test: result.name, status: result.status, completed: completedBefore + 1, total: total, percent: min(93, percent + 1))
        }

        StatusScoring.finalize(run: &context.run)
        context.message(type: .status, message: "Creating report files", test: "Report generation", completed: total, total: total, percent: 95)
        let logURL = context.logger.url
        let paths = try ReportRenderer.write(run: context.run, outputDirectory: context.workspace, existingLogURL: logURL)
        context.logger.write("Reports created in \(context.workspace.path)")
        return paths
    }

    private func run(_ identifier: ScanStepIdentifier) throws -> DiagnosticResult {
        switch identifier {
        case .administratorPermissions:
            return DiagnosticResult(category: "Runtime", domain: "macOS Integrity", name: "Administrator permissions", status: .pass, summary: "Running with administrator rights.")
        case .systemInventory: return MacCollectors.systemInventory(context)
        case .cpuInventory: return MacCollectors.cpuInventory(context)
        case .primeCalculation: return DiagnosticTests.primeCalculation(context)
        case .cpuWorkload: return try DiagnosticTests.cpuWorkload(context)
        case .memoryInventory: return MacCollectors.memoryInventory(context)
        case .memoryPatterns: return try DiagnosticTests.memoryPatterns(context)
        case .memoryPressure: return try DiagnosticTests.memoryPressure(context)
        case .storageInventory: return MacCollectors.storageInventory(context)
        case .filesystemHealth: return MacCollectors.filesystemHealth(context)
        case .smartHealth: return MacCollectors.smartHealth(context)
        case .physicalDriveRead: return try DiagnosticTests.physicalDriveRead(context)
        case .diskWriteRead: return try DiagnosticTests.diskWriteRead(context)
        case .batteryPower: return MacCollectors.batteryPower(context)
        case .usbThunderboltPCI: return MacCollectors.devices(context)
        case .gpuDisplayMetal: return MacCollectors.gpuDisplayMetal(context)
        case .networkQuality: return MacCollectors.networkQuality(context)
        case .panicShutdownHistory: return MacCollectors.panicAndShutdownHistory(context)
        case .servicesHealth: return MacCollectors.servicesHealth(context)
        case .softwareUpdates: return MacCollectors.softwareUpdates(context)
        case .securityConfiguration: return MacCollectors.securityConfiguration(context)
        case .rtcProgression: return DiagnosticTests.rtcProgression(context)
        case .temperatureSensors: return MacCollectors.temperatureSensors(context)
        case .thermalPressure: return MacCollectors.thermalPressure(context)
        }
    }
}
