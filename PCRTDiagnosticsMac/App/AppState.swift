import Foundation

enum AppRunState: Equatable {
    case idle
    case loadingConfiguration
    case unprivilegedPreflight
    case awaitingAuthorization
    case privilegedPreflight
    case claimingSession
    case running
    case cancelling
    case generatingReports
    case uploading
    case uploadFailed
    case complete
    case cancelled
    case error

    var isActive: Bool {
        switch self {
        case .loadingConfiguration, .unprivilegedPreflight, .awaitingAuthorization, .privilegedPreflight, .claimingSession, .running, .cancelling, .generatingReports, .uploading:
            return true
        default:
            return false
        }
    }
}
