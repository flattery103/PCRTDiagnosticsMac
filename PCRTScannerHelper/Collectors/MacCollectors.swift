import Foundation
import Darwin
import PCRTCore

enum MacCollectors {
    struct PhysicalDisk {
        let identifier: String
        let sizeBytes: UInt64
        let model: String
        let internalDisk: Bool
    }

    static func command(_ context: DiagnosticContext, key: String, executable: String, arguments: [String] = [], timeout: TimeInterval = 60) -> CommandResult {
        let result = context.commandRunner.run(executable, arguments, timeout: timeout)
        context.recordCommand(key, result)
        return result
    }

    static func systemProfiler(_ context: DiagnosticContext, dataTypes: [String], key: String, timeout: TimeInterval = 120) -> (CommandResult, Any?) {
        let result = command(context, key: key, executable: "/usr/sbin/system_profiler", arguments: dataTypes + ["-json", "-detailLevel", "full"], timeout: timeout)
        let object = result.stdout.data(using: .utf8).flatMap(SystemUtilities.jsonObject)
        return (result, object)
    }

    static func physicalDisks(_ context: DiagnosticContext) -> [PhysicalDisk] {
        let result = command(context, key: "diskutil-list-plist", executable: "/usr/sbin/diskutil", arguments: ["list", "-plist"], timeout: 60)
        guard result.exitCode == 0, let data = result.stdout.data(using: .utf8), let root = SystemUtilities.plistDictionary(data) else { return [] }
        var output: [PhysicalDisk] = []
        if let partitions = root["AllDisksAndPartitions"] as? [[String: Any]] {
            for entry in partitions {
                guard let identifier = entry["DeviceIdentifier"] as? String,
                      let size = numericUInt64(entry["Size"]) else { continue }
                let info = command(context, key: "diskutil-info-\(identifier)", executable: "/usr/sbin/diskutil", arguments: ["info", "-plist", "/dev/\(identifier)"], timeout: 30)
                var model = ""
                var internalDisk = false
                if let infoData = info.stdout.data(using: .utf8), let dict = SystemUtilities.plistDictionary(infoData) {
                    model = (dict["MediaName"] as? String) ?? (dict["DeviceModel"] as? String) ?? ""
                    internalDisk = (dict["Internal"] as? Bool) ?? false
                }
                output.append(PhysicalDisk(identifier: identifier, sizeBytes: size, model: model, internalDisk: internalDisk))
            }
        }
        return output
    }

    static func numericUInt64(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 { return value }
        if let value = value as? Int { return value >= 0 ? UInt64(value) : nil }
        if let value = value as? NSNumber { return value.uint64Value }
        if let value = value as? String { return UInt64(value) }
        return nil
    }

    static func countNamedItems(_ value: Any) -> Int {
        if let dict = value as? [String: Any] {
            let own = dict["_name"] != nil ? 1 : 0
            return own + dict.values.reduce(0) { $0 + countNamedItems($1) }
        }
        if let array = value as? [Any] { return array.reduce(0) { $0 + countNamedItems($1) } }
        return 0
    }

    static func findValues(_ flat: [String: String], containing needles: [String]) -> [(String, String)] {
        flat.filter { key, _ in needles.allSatisfy { key.localizedCaseInsensitiveContains($0) } }.sorted { $0.key < $1.key }
    }

    static func parseInteger(from text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[valueRange])
    }
}
