import Foundation
import PCRTCore
import Metal

extension MacCollectors {
    static func smartHealth(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let disks = physicalDisks(context)
        guard !disks.isEmpty else {
            return DiagnosticResult(category: "Storage", domain: "Hardware Functional", name: "SMART and native drive-health evidence", status: .incomplete, summary: "No physical disks were available for native health review.", durationSeconds: Date().timeIntervalSince(started))
        }
        var status: CheckStatus = .pass
        var details: [String] = []
        var anyHealth = false
        for disk in disks {
            let info = command(context, key: "smart-diskutil-\(disk.identifier)", executable: "/usr/sbin/diskutil", arguments: ["info", "-plist", "/dev/\(disk.identifier)"], timeout: 45)
            var smart = "Not reported"
            if let data = info.stdout.data(using: .utf8), let dict = SystemUtilities.plistDictionary(data) {
                if let value = dict["SMARTStatus"] as? String { smart = value; anyHealth = true }
                else if let value = dict["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? String { smart = value; anyHealth = true }
            }
            details.append("/dev/\(disk.identifier) \(disk.model): SMART status \(smart)")
            let lower = smart.lowercased()
            if lower.contains("fail") || lower.contains("fatal") {
                status = .fail
            } else if smart == "Not reported" && status != .fail {
                status = .incomplete
            }

            for path in ["/opt/homebrew/sbin/smartctl", "/usr/local/sbin/smartctl", "/usr/local/bin/smartctl"] where FileManager.default.isExecutableFile(atPath: path) {
                let extra = command(context, key: "smartctl-\(disk.identifier)", executable: path, arguments: ["-a", "-j", "/dev/\(disk.identifier)"], timeout: 90)
                if extra.exitCode == 0 || !extra.stdout.isEmpty {
                    anyHealth = true
                    if extra.stdout.localizedCaseInsensitiveContains("PASSED") { details.append("Existing optional smartctl: overall-health PASSED for /dev/\(disk.identifier).") }
                    if extra.stdout.localizedCaseInsensitiveContains("FAILED") || extra.stdout.localizedCaseInsensitiveContains("critical_warning\":1") { status = .fail }
                }
                break
            }
        }
        let nvme = systemProfiler(context, dataTypes: ["SPNVMeDataType"], key: "system-profiler-nvme", timeout: 120)
        if nvme.0.exitCode == 0, let object = nvme.1 {
            anyHealth = true
            details.append("NVMe inventory entries: \(countNamedItems(object))")
        }
        if !anyHealth { status = .notAvailable }
        let summary: String
        switch status {
        case .pass: summary = "Native macOS drive-health evidence did not report a predicted failure."
        case .fail: summary = "One or more drives reported confirmed native failure evidence."
        case .incomplete: summary = "Native drive-health evidence was unavailable for part of the installed storage."
        default: summary = "SMART or native health data was not exposed by this Mac or storage controller."
        }
        return DiagnosticResult(category: "Storage", domain: "Hardware Functional", name: "SMART and native drive-health evidence", status: status, summary: summary, reason: status == .fail ? "A native SMART status or optional existing smartctl result reported failure." : status == .incomplete ? "Not all storage devices exposed a health status; this is not proof of failure." : nil, recommendedAction: status == .fail ? "Back up affected data immediately and verify the named drive with Apple Diagnostics or the manufacturer diagnostic." : nil, details: details, durationSeconds: Date().timeIntervalSince(started))
    }

    static func batteryPower(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let profiler = systemProfiler(context, dataTypes: ["SPPowerDataType"], key: "system-profiler-power", timeout: 120)
        let pmset = command(context, key: "pmset-batt", executable: "/usr/bin/pmset", arguments: ["-g", "batt"])
        let powerSource = command(context, key: "pmset-ps", executable: "/usr/bin/pmset", arguments: ["-g", "ps"])
        let flat = profiler.1.map(SystemUtilities.flatten) ?? [:]
        var rows = flat.filter { key, _ in
            ["cycle_count", "condition", "maximum_capacity", "full_charge_capacity", "charge_remaining", "charging", "fully_charged", "connected"].contains(where: { key.localizedCaseInsensitiveContains($0) })
        }.sorted { $0.key < $1.key }.map { [$0.key, $0.value] }
        if rows.isEmpty { rows = [["Power source", SystemUtilities.trimmed(pmset.stdout)]] }
        context.appendInventory(InventorySection(title: "Battery and power", items: ["Current power": SystemUtilities.trimmed(pmset.stdout), "Power source": SystemUtilities.trimmed(powerSource.stdout)], tables: [InventoryTable(title: "Battery details", columns: ["Property", "Value"], rows: rows)]))

        let combined = flat.values.joined(separator: " ").lowercased()
        var status: CheckStatus = .pass
        var reason: String?
        if combined.contains("service battery") || combined.contains("replace soon") || combined.contains("replace now") {
            status = .warning
            reason = "macOS reported a battery service or replacement condition."
        } else if profiler.0.exitCode != 0 && pmset.exitCode != 0 {
            status = .incomplete
            reason = "Power information could not be collected."
        } else if !combined.contains("cycle") && pmset.stdout.localizedCaseInsensitiveContains("No batteries") {
            status = .notApplicable
        }
        let summary: String
        switch status {
        case .pass: summary = "Battery condition, charge state, and power-source information did not show an obvious problem."
        case .warning: summary = "The battery condition requires service review."
        case .notApplicable: summary = "This Mac does not report an installed battery."
        default: summary = "Battery and power information was incomplete."
        }
        return DiagnosticResult(category: "Power", domain: "Network / Power", name: "Battery and power status", status: status, summary: summary, reason: reason, recommendedAction: status == .warning ? "Confirm the condition in System Settings or Apple Diagnostics and replace the battery only when service is indicated." : nil, details: rows.prefix(20).map { "\($0[0]): \($0[1])" }, durationSeconds: Date().timeIntervalSince(started))
    }

    static func devices(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let usb = systemProfiler(context, dataTypes: ["SPUSBDataType"], key: "system-profiler-usb", timeout: 120)
        let thunderbolt = systemProfiler(context, dataTypes: ["SPThunderboltDataType"], key: "system-profiler-thunderbolt", timeout: 120)
        let pci = systemProfiler(context, dataTypes: ["SPPCIDataType"], key: "system-profiler-pci", timeout: 120)
        let usbCount = usb.1.map(countNamedItems) ?? 0
        let thunderboltCount = thunderbolt.1.map(countNamedItems) ?? 0
        let pciCount = pci.1.map(countNamedItems) ?? 0
        context.appendInventory(InventorySection(title: "Connected devices", items: ["USB inventory entries": "\(usbCount)", "Thunderbolt inventory entries": "\(thunderboltCount)", "PCI inventory entries": "\(pciCount)"]))
        let completed = [usb.0.exitCode == 0, thunderbolt.0.exitCode == 0, pci.0.exitCode == 0].filter { $0 }.count
        let status: CheckStatus = completed == 3 ? .info : completed > 0 ? .incomplete : .notAvailable
        return DiagnosticResult(category: "Devices", domain: "Hardware Functional", name: "USB, Thunderbolt, and PCI inventory", status: status, summary: status == .info ? "Collected USB, Thunderbolt, and available PCI device inventory." : completed > 0 ? "Some device inventory was unavailable on this Mac." : "macOS did not expose USB, Thunderbolt, or PCI inventory.", reason: status == .incomplete ? "One or more system_profiler data types were unavailable or timed out; this is not a device failure." : nil, details: ["USB entries: \(usbCount)", "Thunderbolt entries: \(thunderboltCount)", "PCI entries: \(pciCount)"], durationSeconds: Date().timeIntervalSince(started))
    }

    static func gpuDisplayMetal(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let displays = systemProfiler(context, dataTypes: ["SPDisplaysDataType"], key: "system-profiler-displays", timeout: 120)
        let displayCount = displays.1.map(countNamedItems) ?? 0
        let devices = MTLCopyAllDevices()
        var metalRows: [[String]] = []
        for device in devices {
            var capabilities = [device.isLowPower ? "Low power" : "High power"]
            if device.isRemovable { capabilities.append("Removable") }
            if #available(macOS 10.15, *) {
                capabilities.append(device.hasUnifiedMemory ? "Unified memory" : "Discrete memory")
            }
            metalRows.append([device.name, String(device.registryID), capabilities.joined(separator: ", ")])
        }
        context.appendInventory(InventorySection(title: "GPU, displays, and Metal", items: ["Display/GPU entries": "\(displayCount)", "Metal devices": "\(devices.count)"], tables: [InventoryTable(title: "Metal devices", columns: ["Name", "Registry ID", "Capabilities"], rows: metalRows)]))
        let status: CheckStatus
        if displays.0.exitCode == 0 && !devices.isEmpty { status = .info }
        else if displays.0.exitCode == 0 || !devices.isEmpty { status = .incomplete }
        else { status = .notAvailable }
        return DiagnosticResult(category: "Display", domain: "Hardware Functional", name: "GPU, display, and Metal capability inventory", status: status, summary: status == .info ? "Collected graphics adapter, display, and Metal capability information." : status == .incomplete ? "Graphics inventory was partially available." : "Graphics and Metal capability information was not available.", reason: status == .incomplete ? "One graphics inventory source was unavailable; no GPU failure is inferred." : nil, details: metalRows.map { "\($0[0]): \($0[2])" }, durationSeconds: Date().timeIntervalSince(started))
    }
}
