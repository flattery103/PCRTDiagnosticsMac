import Foundation
import Darwin
import PCRTCore

enum MacCollectors {
    struct PhysicalDisk {
        let identifier: String
        let sizeBytes: UInt64
        let model: String
        let internalDisk: Bool
        let removable: Bool
        let solidState: Bool
        let busProtocol: String
        let smartStatus: String?
        let healthValues: [String: UInt64]
        let temperatureCelsius: Double?
    }

    struct MountedExternalVolume {
        let identifier: String
        let name: String
        let mountPoint: String
        let filesystem: String
        let parentWholeDisk: String
        let writable: Bool
        let availableBytes: UInt64
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

    static func physicalDisks(_ context: DiagnosticContext, keyPrefix: String = "") -> [PhysicalDisk] {
        let result = command(context, key: "\(keyPrefix)diskutil-list-plist", executable: "/usr/sbin/diskutil", arguments: ["list", "-plist"], timeout: 60)
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let root = SystemUtilities.plistDictionary(data),
              let entries = root["AllDisksAndPartitions"] as? [[String: Any]] else {
            return []
        }

        var output: [PhysicalDisk] = []
        var seen = Set<String>()

        for entry in entries {
            guard let identifier = entry["DeviceIdentifier"] as? String,
                  !seen.contains(identifier) else { continue }

            // APFS containers such as disk1/disk2/disk3 are synthesized whole disks.
            // Only inspect top-level candidates here, then use diskutil info to retain
            // actual physical media. This prevents one Apple SSD from appearing as
            // several independent drives.
            if entry["APFSPhysicalStores"] != nil { continue }
            if let content = entry["Content"] as? String,
               content.localizedCaseInsensitiveContains("APFS_Container") { continue }

            let infoResult = command(
                context,
                key: "\(keyPrefix)diskutil-info-\(identifier)",
                executable: "/usr/sbin/diskutil",
                arguments: ["info", "-plist", "/dev/\(identifier)"],
                timeout: 30
            )
            guard infoResult.exitCode == 0,
                  let infoData = infoResult.stdout.data(using: .utf8),
                  let info = SystemUtilities.plistDictionary(infoData),
                  (info["WholeDisk"] as? Bool) == true else { continue }

            let virtualOrPhysical = (info["VirtualOrPhysical"] as? String) ?? ""
            let infoContent = (info["Content"] as? String) ?? ""
            if virtualOrPhysical.caseInsensitiveCompare("Virtual") == .orderedSame ||
                infoContent.localizedCaseInsensitiveContains("APFS_Container") {
                continue
            }

            // Real media normally has a bus protocol and/or an I/O Registry media
            // name. Keep Unknown physical status because Apple Silicon internal SSDs
            // currently report VirtualOrPhysical=Unknown.
            let busProtocol = (info["BusProtocol"] as? String) ?? "Not reported"
            let registryName = (info["IORegistryEntryName"] as? String) ?? ""
            if busProtocol == "Not reported" && registryName.isEmpty && virtualOrPhysical.isEmpty {
                continue
            }

            let size = numericUInt64(info["TotalSize"])
                ?? numericUInt64(info["Size"])
                ?? numericUInt64(entry["Size"])
                ?? 0
            guard size > 0 else { continue }

            let health = nvmeHealthDictionary(info["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"])
            let temperature = storageTemperatureCelsius(health["TEMPERATURE"])
            let model = (info["MediaName"] as? String)
                ?? (info["DeviceModel"] as? String)
                ?? (registryName.isEmpty ? "Unknown physical disk" : registryName)

            output.append(PhysicalDisk(
                identifier: identifier,
                sizeBytes: size,
                model: model,
                internalDisk: (info["Internal"] as? Bool) ?? false,
                removable: (info["Removable"] as? Bool) ?? false,
                solidState: (info["SolidState"] as? Bool) ?? false,
                busProtocol: busProtocol,
                smartStatus: info["SMARTStatus"] as? String,
                healthValues: health,
                temperatureCelsius: temperature
            ))
            seen.insert(identifier)
        }

        return output.sorted { $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending }
    }

    static func mountedExternalVolumes(_ context: DiagnosticContext, keyPrefix: String = "external-") -> [MountedExternalVolume] {
        let result = command(context, key: "\(keyPrefix)diskutil-list-volumes", executable: "/usr/sbin/diskutil", arguments: ["list", "-plist"], timeout: 60)
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let root = SystemUtilities.plistDictionary(data),
              let identifiers = root["AllDisks"] as? [String] else { return [] }

        var output: [MountedExternalVolume] = []
        var seenMounts = Set<String>()
        for identifier in identifiers {
            let infoResult = command(
                context,
                key: "\(keyPrefix)diskutil-volume-info-\(identifier)",
                executable: "/usr/sbin/diskutil",
                arguments: ["info", "-plist", "/dev/\(identifier)"],
                timeout: 20
            )
            guard infoResult.exitCode == 0,
                  let infoData = infoResult.stdout.data(using: .utf8),
                  let info = SystemUtilities.plistDictionary(infoData),
                  let mountPoint = info["MountPoint"] as? String,
                  !mountPoint.isEmpty,
                  !seenMounts.contains(mountPoint) else { continue }

            let internalMedia = (info["Internal"] as? Bool) ?? true
            let externalFlag = (info["RemovableMediaOrExternalDevice"] as? Bool) ?? false
            guard !internalMedia || externalFlag else { continue }

            let writable = (info["WritableVolume"] as? Bool) ?? false
            let name = (info["VolumeName"] as? String) ?? identifier
            let filesystem = (info["FilesystemType"] as? String)
                ?? (info["FilesystemName"] as? String)
                ?? (info["Content"] as? String)
                ?? "Not reported"
            let parent = (info["ParentWholeDisk"] as? String) ?? identifier
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: mountPoint)
            let available = numericUInt64(attributes?[.systemFreeSize]) ?? 0
            output.append(MountedExternalVolume(
                identifier: identifier,
                name: name,
                mountPoint: mountPoint,
                filesystem: filesystem,
                parentWholeDisk: parent,
                writable: writable,
                availableBytes: available
            ))
            seenMounts.insert(mountPoint)
        }
        return output.sorted { $0.mountPoint.localizedStandardCompare($1.mountPoint) == .orderedAscending }
    }

    static func batteryDictionary(_ data: Data) -> [String: Any]? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        if let array = object as? [[String: Any]] { return array.first }
        return object as? [String: Any]
    }

    static func nvmeHealthDictionary(_ value: Any?) -> [String: UInt64] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        var result: [String: UInt64] = [:]
        for (key, item) in dictionary {
            if let number = numericUInt64(item) { result[key] = number }
        }
        return result
    }

    static func nvmeCounter(_ health: [String: UInt64], base: String) -> UInt64? {
        if let direct = health[base] { return direct }
        let low = health[base + "_0"]
        let high = health[base + "_1"] ?? 0
        guard low != nil || high != 0 else { return nil }
        // Current Apple NVMe data exposes a low/high pair. Values used for
        // diagnostic thresholds are safely representable in UInt64 on real Macs.
        if high == 0 { return low ?? 0 }
        return UInt64.max
    }

    static func storageTemperatureCelsius(_ raw: UInt64?) -> Double? {
        guard let raw else { return nil }
        let value = Double(raw)
        if value >= 200 && value <= 500 { return value - 273.15 } // Kelvin, as exposed by Apple NVMe
        if value >= 0 && value <= 125 { return value }            // Celsius on some controllers
        if value >= 2_000 && value <= 5_000 { return value / 10.0 - 273.15 }
        return nil
    }

    static func numericUInt64(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 { return value }
        if let value = value as? Int { return value >= 0 ? UInt64(value) : nil }
        if let value = value as? NSNumber { return value.uint64Value }
        if let value = value as? String { return UInt64(value) }
        return nil
    }

    static func numericInt64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    static func booleanValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
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
