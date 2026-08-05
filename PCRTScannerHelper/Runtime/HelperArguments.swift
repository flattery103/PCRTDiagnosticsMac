import Foundation

struct HelperArguments {
    let socketPath: String
    let runID: String
    let nonce: String
    let userUID: uid_t
    let workspacePath: String

    static func parse(_ arguments: [String] = CommandLine.arguments) throws -> HelperArguments {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), index + 1 < arguments.count else {
                throw HelperError.invalidArguments("Expected a value after \(key).")
            }
            values[key] = arguments[index + 1]
            index += 2
        }
        guard let socket = values["--socket"],
              let runID = values["--run-id"],
              let nonce = values["--nonce"],
              let uidText = values["--uid"],
              let uidValue = UInt32(uidText),
              let workspace = values["--workspace"] else {
            throw HelperError.invalidArguments("Required helper arguments are missing.")
        }
        guard runID.count >= 16, nonce.count >= 32 else {
            throw HelperError.invalidArguments("The run identifier or nonce is invalid.")
        }
        return HelperArguments(socketPath: socket, runID: runID, nonce: nonce, userUID: uid_t(uidValue), workspacePath: workspace)
    }
}

enum HelperError: LocalizedError {
    case invalidArguments(String)
    case notRoot
    case invalidWorkspace(String)
    case protocolError(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): return message
        case .notRoot: return "PCRTScannerHelper must run with administrator privileges."
        case .invalidWorkspace(let message): return message
        case .protocolError(let message): return message
        case .cancelled: return "The diagnostic run was cancelled."
        }
    }
}
