import Foundation

public enum CheckStatus: String, Codable, CaseIterable, Hashable {
    case pass = "PASS"
    case warning = "WARNING"
    case fail = "FAIL"
    case incomplete = "INCOMPLETE"
    case deferred = "DEFERRED"
    case notAvailable = "NOT AVAILABLE"
    case notApplicable = "NOT APPLICABLE"
    case info = "INFO"

    public var requiresAttention: Bool {
        switch self {
        case .fail, .warning, .incomplete, .deferred:
            return true
        case .pass, .notAvailable, .notApplicable, .info:
            return false
        }
    }

    public var cssClass: String {
        rawValue.replacingOccurrences(of: " ", with: "-")
    }
}
