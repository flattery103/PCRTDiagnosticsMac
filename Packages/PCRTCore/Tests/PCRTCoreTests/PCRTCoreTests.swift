import XCTest
@testable import PCRTCore

final class PCRTCoreTests: XCTestCase {
    func testSessionCodeNormalization() throws {
        XCTAssertEqual(SessionCode.normalized("ab-cd e"), "ABCDE")
        XCTAssertEqual(try SessionCode.validate("a1b2c"), "A1B2C")
        XCTAssertThrowsError(try SessionCode.validate("ABCD"))
    }

    func testKnownPrimeCount() {
        XCTAssertEqual(DiagnosticAlgorithms.primeCount(upTo: 1_000_000), 78_498)
    }

    func testDriveSampleOffsetsAreUniqueAnd64BitSafe() {
        let size: UInt64 = 8 * 1024 * 1024 * 1024 * 1024
        let result = DiagnosticAlgorithms.driveSampleOffsets(size: size)
        XCTAssertEqual(result.generatedCount, 52)
        XCTAssertEqual(result.offsets.count, Set(result.offsets).count)
        XCTAssertEqual(result.offsets.count, 50)
        XCTAssertTrue(result.offsets.allSatisfy { $0 % 4096 == 0 })
        XCTAssertTrue(result.offsets.allSatisfy { $0 <= size - 1_048_576 })
    }

    func testSHA256KnownVector() {
        XCTAssertEqual(SHA256Hasher.hexDigest(data: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testDomainSeparationAndOverall() {
        let results = [
            DiagnosticResult(category: "Storage", domain: "Hardware Functional", name: "Read", status: .pass, summary: "Passed"),
            DiagnosticResult(category: "macOS", domain: "macOS Maintenance", name: "Updates", status: .warning, summary: "Updates available")
        ]
        let domains = StatusScoring.calculateDomains(results: results)
        let overall = StatusScoring.calculateOverall(domains: domains, results: results)
        XCTAssertEqual(overall.0, .warning)
        XCTAssertEqual(overall.1, "Review required")
        XCTAssertEqual(domains.first(where: { $0.name == "Hardware Functional" })?.status, .pass)
        XCTAssertEqual(domains.first(where: { $0.name == "macOS Maintenance" })?.status, .warning)
    }

    func testIPCLineFraming() throws {
        let original = IPCMessage(runID: "run", sequence: 1, type: .progress, message: "Working", test: "CPU", completed: 2, total: 10, percent: 20)
        var buffer = try LineDelimitedJSON.encode(original)
        let decoded = try LineDelimitedJSON.decodeMessages(buffer: &buffer)
        XCTAssertEqual(decoded, [original])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testReportsContainExpectedEvidenceBehavior() throws {
        var run = DiagnosticRun(version: "0.1.3", platform: "macOS/arm64", computerName: "Test-Mac", mode: "quick", modeDisplayName: "Quick")
        run.results = [
            DiagnosticResult(category: "CPU", domain: "Hardware Functional", name: "CPU test", status: .pass, summary: "Passed", details: ["Evidence"]),
            DiagnosticResult(category: "Storage", domain: "Hardware Functional", name: "Disk test", status: .incomplete, summary: "Unavailable", details: ["Access denied"])
        ]
        StatusScoring.finalize(run: &run)
        let html = ReportRenderer.testResultsHTML(run: run)
        XCTAssertTrue(html.contains("PCRT Diagnostics for macOS"))
        XCTAssertTrue(html.contains("Disk test"))
        XCTAssertTrue(html.contains("<details open>"))
        XCTAssertTrue(html.contains("<details><summary>Technical evidence"))
    }
    func testThermalAndDrivePlansIncludeNewEvidence() {
        let thermal = ScanPlanner.plan(for: "thermal", memoryPressurePercent: 0, diskTestMB: 0).map(\.identifier)
        XCTAssertTrue(thermal.contains(.temperatureSensors))
        XCTAssertTrue(thermal.contains(.thermalPressure))
        XCTAssertTrue(thermal.contains(.cpuWorkload))
        XCTAssertTrue(thermal.contains(.gpuFunctionalWorkload))
        XCTAssertTrue(thermal.contains(.postWorkloadEvents))

        let drive = ScanPlanner.plan(for: "drive", memoryPressurePercent: 0, diskTestMB: 1024).map(\.identifier)
        XCTAssertTrue(drive.contains(.temperatureSensors))
        XCTAssertTrue(drive.contains(.smartHealth))
        XCTAssertTrue(drive.contains(.physicalDriveRead))
        XCTAssertTrue(drive.contains(.filesystemHealth))
        XCTAssertTrue(drive.contains(.externalDriveHealth))
        XCTAssertTrue(drive.contains(.postWorkloadEvents))
    }

    func testFullPlanIncludesUnattendedReliabilityChecks() {
        let full = ScanPlanner.plan(for: "full", memoryPressurePercent: 70, diskTestMB: 512).map(\.identifier)
        XCTAssertTrue(full.contains(.gpuFunctionalWorkload))
        XCTAssertTrue(full.contains(.externalDriveHealth))
        XCTAssertTrue(full.contains(.networkQuality))
        XCTAssertTrue(full.contains(.batteryPower))
        XCTAssertTrue(full.contains(.postWorkloadEvents))
        XCTAssertTrue(full.contains(.diskWriteRead))
        XCTAssertTrue(full.firstIndex(of: .postWorkloadEvents)! > full.firstIndex(of: .gpuFunctionalWorkload)!)
    }

}
