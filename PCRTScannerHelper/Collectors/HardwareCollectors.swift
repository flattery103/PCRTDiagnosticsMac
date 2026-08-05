import Foundation
import PCRTCore
import Metal

extension MacCollectors {
    static func smartHealth(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let disks = physicalDisks(context)
        guard !disks.isEmpty else {
            return DiagnosticResult(
                category: "Storage",
                domain: "Hardware Functional",
                name: "Physical-drive SMART, NVMe, and partition-map health",
                status: .incomplete,
                summary: "No physical disks were available for native health review.",
                reason: "macOS did not return a usable physical-media inventory.",
                durationSeconds: Date().timeIntervalSince(started)
            )
        }

        var status: CheckStatus = .pass
        var details: [String] = []
        var rawRows: [JSONValue] = []
        var devicesWithHealth = 0
        var warningReasons: [String] = []
        var failureReasons: [String] = []

        for disk in disks {
            let device = "/dev/\(disk.identifier)"
            let smart = disk.smartStatus ?? "Not reported"
            let health = disk.healthValues
            let criticalWarning = nvmeCounter(health, base: "CRITICAL_WARNING") ?? 0
            let mediaErrors = nvmeCounter(health, base: "MEDIA_ERRORS") ?? 0
            let errorEntries = nvmeCounter(health, base: "NUM_ERROR_INFO_LOG_ENTRIES") ?? 0
            let percentageUsed = nvmeCounter(health, base: "PERCENTAGE_USED")
            let availableSpare = nvmeCounter(health, base: "AVAILABLE_SPARE")
            let spareThreshold = nvmeCounter(health, base: "AVAILABLE_SPARE_THRESHOLD")
            let powerOnHours = nvmeCounter(health, base: "POWER_ON_HOURS")
            let powerCycles = nvmeCounter(health, base: "POWER_CYCLES")
            let unsafeShutdowns = nvmeCounter(health, base: "UNSAFE_SHUTDOWNS")

            if disk.smartStatus != nil || !health.isEmpty { devicesWithHealth += 1 }

            details.append("\(device) \(disk.model) (\(disk.busProtocol), \(SystemUtilities.humanBytes(disk.sizeBytes))): SMART \(smart)")
            if let temperature = disk.temperatureCelsius {
                details.append(String(format: "%@ current storage temperature: %.1f °C", device, temperature))
                if temperature >= 80 {
                    warningReasons.append(String(format: "%@ reported a high storage temperature of %.1f °C.", device, temperature))
                }
            } else {
                details.append("\(device) numerical storage temperature: Not available")
            }
            if let value = percentageUsed { details.append("\(device) NVMe percentage used: \(value)%") }
            if let value = availableSpare { details.append("\(device) available spare: \(value)%") }
            if let value = spareThreshold { details.append("\(device) available-spare threshold: \(value)%") }
            if let value = mediaErrors { details.append("\(device) media/data-integrity errors: \(value)") }
            if let value = errorEntries { details.append("\(device) NVMe error-log entries: \(value)") }
            if let value = unsafeShutdowns { details.append("\(device) unsafe shutdowns: \(value)") }
            if let value = powerOnHours { details.append("\(device) power-on hours: \(value)") }
            if let value = powerCycles { details.append("\(device) power cycles: \(value)") }

            let smartLower = smart.lowercased()
            if smartLower.contains("fail") || smartLower.contains("fatal") {
                failureReasons.append("\(device) reported SMART status \(smart).")
            }
            if criticalWarning != 0 {
                failureReasons.append("\(device) reported NVMe critical-warning value \(criticalWarning).")
            }
            if mediaErrors > 0 {
                failureReasons.append("\(device) reported \(mediaErrors) NVMe media/data-integrity error(s).")
            }
            if let availableSpare, let spareThreshold, availableSpare < spareThreshold {
                failureReasons.append("\(device) available spare (\(availableSpare)%) is below its threshold (\(spareThreshold)%).")
            }
            if let percentageUsed, percentageUsed >= 100 {
                warningReasons.append("\(device) reports NVMe percentage used at \(percentageUsed)%.")
            } else if let percentageUsed, percentageUsed >= 90 {
                warningReasons.append("\(device) reports high NVMe wear at \(percentageUsed)% used.")
            }

            let verify = command(
                context,
                key: "diskutil-verify-disk-\(disk.identifier)",
                executable: "/usr/sbin/diskutil",
                arguments: ["verifyDisk", device],
                timeout: 120
            )
            let verifyText = verify.combinedOutput
            if verify.exitCode == 0 {
                details.append("\(device) partition map: Verified")
            } else if verifyText.localizedCaseInsensitiveContains("corrupt") ||
                        verifyText.localizedCaseInsensitiveContains("problems were found") {
                failureReasons.append("\(device) partition-map verification reported corruption.")
                details.append("\(device) partition map: Failed")
            } else {
                warningReasons.append("\(device) partition-map verification could not be completed.")
                details.append("\(device) partition map: Incomplete (\(SystemUtilities.firstLine(verifyText)))")
            }

            for path in ["/opt/homebrew/sbin/smartctl", "/usr/local/sbin/smartctl", "/usr/local/bin/smartctl"] where FileManager.default.isExecutableFile(atPath: path) {
                let extra = command(context, key: "smartctl-\(disk.identifier)", executable: path, arguments: ["-x", "-j", device], timeout: 90)
                if extra.stdout.localizedCaseInsensitiveContains("FAILED") ||
                    extra.stdout.localizedCaseInsensitiveContains("\"critical_warning\":1") {
                    failureReasons.append("Existing optional smartctl reported failure evidence for \(device).")
                } else if extra.exitCode == 0 {
                    details.append("Existing optional smartctl returned additional health data for \(device).")
                }
                break
            }

            rawRows.append(.object([
                "device": .string(device),
                "model": .string(disk.model),
                "protocol": .string(disk.busProtocol),
                "size_bytes": .number(Double(disk.sizeBytes)),
                "smart_status": .string(smart),
                "critical_warning": .number(Double(criticalWarning)),
                "media_errors": .number(Double(mediaErrors)),
                "error_log_entries": .number(Double(errorEntries)),
                "percentage_used": percentageUsed.map { .number(Double($0)) } ?? .null,
                "temperature_celsius": disk.temperatureCelsius.map { .number($0) } ?? .null,
                "partition_map_exit_code": .number(Double(verify.exitCode))
            ]))
        }

        if !failureReasons.isEmpty {
            status = .fail
        } else if !warningReasons.isEmpty {
            status = .warning
        } else if devicesWithHealth == 0 {
            status = .notAvailable
        } else if devicesWithHealth < disks.count {
            status = .incomplete
        }

        let summary: String
        switch status {
        case .pass:
            summary = "Native SMART/NVMe health and partition-map verification did not report a physical-drive failure."
        case .warning:
            summary = "One or more physical-drive health indicators require technician review."
        case .fail:
            summary = "One or more physical drives reported confirmed native failure evidence."
        case .incomplete:
            summary = "Native drive-health evidence was unavailable for part of the installed physical storage."
        default:
            summary = "SMART or native health data was not exposed by this Mac or storage controller."
        }

        return DiagnosticResult(
            category: "Storage",
            domain: "Hardware Functional",
            name: "Physical-drive SMART, NVMe, and partition-map health",
            status: status,
            summary: summary,
            reason: !failureReasons.isEmpty ? failureReasons.joined(separator: " ") : !warningReasons.isEmpty ? warningReasons.joined(separator: " ") : status == .incomplete ? "Not all physical devices exposed health evidence; missing SMART data alone is not proof of failure." : nil,
            recommendedAction: status == .fail ? "Back up affected data immediately and verify the named physical drive with Apple Diagnostics or the manufacturer diagnostic." : status == .warning ? "Review the named drive indicators, confirm backups, and repeat the storage checks before making a replacement decision." : nil,
            details: details,
            durationSeconds: Date().timeIntervalSince(started),
            raw: ["physical_drives": .array(rawRows)]
        )
    }

    static func batteryPower(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let profiler = systemProfiler(context, dataTypes: ["SPPowerDataType"], key: "system-profiler-power", timeout: 120)
        let pmset = command(context, key: "pmset-batt", executable: "/usr/bin/pmset", arguments: ["-g", "batt"])
        let powerSource = command(context, key: "pmset-ps", executable: "/usr/bin/pmset", arguments: ["-g", "ps"])
        let flat = profiler.1.map { SystemUtilities.flatten($0) } ?? [:]
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
