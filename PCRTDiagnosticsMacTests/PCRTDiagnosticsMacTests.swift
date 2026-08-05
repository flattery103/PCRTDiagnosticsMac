import XCTest
import PCRTCore

final class PCRTDiagnosticsMacProjectTests: XCTestCase {
    func testProductVersionAndExpectedReports() {
        XCTAssertEqual(PCRTProduct.version, "0.1.1")
        XCTAssertEqual(PCRTProduct.expectedReportNames, ["system-info.html", "test-results.html", "raw-data.json", "run-log.txt"])
    }

    func testMacScanPlanUsesMacSpecificDomains() {
        let plan = ScanPlanner.plan(for: "full", memoryPressurePercent: 70, diskTestMB: 512)
        XCTAssertTrue(plan.contains(where: { $0.identifier == .securityConfiguration }))
        XCTAssertTrue(plan.contains(where: { $0.identifier == .gpuDisplayMetal }))
        XCTAssertFalse(plan.map(\.displayName).contains(where: { $0.localizedCaseInsensitiveContains("Windows") }))
    }
}
