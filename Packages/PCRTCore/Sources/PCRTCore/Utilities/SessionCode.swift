import Foundation

public enum SessionCodeError: LocalizedError, Equatable {
    case invalid

    public var errorDescription: String? {
        "Enter the five-character session code provided by the technician."
    }
}

public enum SessionCode {
    public static func normalized(_ input: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let scalars = input.uppercased().unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars.prefix(5)))
    }

    public static func validate(_ input: String) throws -> String {
        let value = normalized(input)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard value.count == 5, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw SessionCodeError.invalid
        }
        return value
    }
}
