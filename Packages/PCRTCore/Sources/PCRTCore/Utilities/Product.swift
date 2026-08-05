import Foundation

public enum PCRTProduct {
    public static let version = "0.1.3"
    public static let productName = "PCRT Diagnostics for macOS"
    public static let serverURL = URL(string: "https://scan.pcrtdiag.com:8443/")!
    public static let ipcProtocolVersion = 1
    public static let expectedReportNames: Set<String> = [
        "system-info.html",
        "test-results.html",
        "raw-data.json",
        "run-log.txt"
    ]
}
