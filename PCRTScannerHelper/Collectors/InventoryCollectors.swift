import Foundation
import Darwin
import PCRTCore

extension MacCollectors {
    static func systemInventory(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let swVers = command(context, key: "sw-vers", executable: "/usr/bin/sw_vers")
        let hardware = systemProfiler(context, dataTypes: ["SPHardwareDataType"], key: "system-profiler-hardware")
        let installHistory = systemProfiler(context, dataTypes: ["SPInstallHistoryDataType"], key: "system-profiler-install-history", timeout: 180)
        let uptime = command(context, key: "uptime", executable: "/usr/bin/uptime")
        let sysctlBoot = command(context, key: "sysctl-boottime", executable: "/usr/sbin/sysctl", arguments: ["-n", "kern.boottime"])

        var items: [String: String] = [:]
        for line in swVers.stdout.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { items[parts[0]] = parts[1] }
        }
        items["Architecture"] = SystemUtilities.machineArchitecture()
        items["Uptime"] = SystemUtilities.trimmed(uptime.stdout)
        items["Boot time evidence"] = SystemUtilities.trimmed(sysctlBoot.stdout)

        var hardwareRows: [[String]] = []
        if let object = hardware.1 {
            let flat = SystemUtilities.flatten(object)
            let interesting = flat.filter { key, _ in
                ["machine_name", "machine_model", "model_number", "serial_number", "chip_type", "processor_name", "boot_rom_version", "system_firmware_version", "os_loader_version", "platform_UUID"].contains(where: { key.localizedCaseInsensitiveContains($0) })
            }
            hardwareRows = interesting.sorted { $0.key < $1.key }.map { [$0.key, $0.value] }
        }
        context.appendInventory(InventorySection(title: "macOS and Mac hardware", items: items, tables: [InventoryTable(title: "Hardware details", columns: ["Property", "Value"], rows: hardwareRows)]))

        let status: CheckStatus = swVers.exitCode == 0 && hardware.0.exitCode == 0 ? .info : .incomplete
        return DiagnosticResult(category: "Inventory", domain: "macOS Integrity", name: "macOS and Mac hardware inventory", status: status, summary: status == .info ? "Collected macOS version, architecture, uptime, model, serial, and firmware information." : "Some macOS or hardware inventory could not be collected.", reason: status == .incomplete ? "One or more Apple inventory commands did not complete successfully." : nil, details: ["Installation-history records: \(installHistory.1.map(countNamedItems) ?? 0)", "Architecture: \(SystemUtilities.machineArchitecture())"], durationSeconds: Date().timeIntervalSince(started))
    }

    static func cpuInventory(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let keys = ["machdep.cpu.brand_string", "hw.ncpu", "hw.physicalcpu", "hw.logicalcpu", "hw.cpufrequency", "hw.byteorder", "hw.optional.arm64", "hw.optional.x86_64"]
        var rows: [[String]] = []
        var successful = 0
        for key in keys {
            let result = command(context, key: "sysctl-\(key.replacingOccurrences(of: ".", with: "-"))", executable: "/usr/sbin/sysctl", arguments: ["-n", key])
            if result.exitCode == 0 {
                rows.append([key, SystemUtilities.trimmed(result.stdout)])
                successful += 1
            }
        }
        context.appendInventory(InventorySection(title: "CPU", tables: [InventoryTable(title: "Processor information", columns: ["Property", "Value"], rows: rows)]))
        let status: CheckStatus = successful >= 3 ? .info : .incomplete
        return DiagnosticResult(category: "CPU", domain: "Hardware Functional", name: "CPU inventory", status: status, summary: status == .info ? "Collected processor model, architecture, and core-count information." : "Processor inventory was incomplete.", details: rows.map { "\($0[0]): \($0[1])" }, durationSeconds: Date().timeIntervalSince(started))
    }

    static func memoryInventory(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let memsize = command(context, key: "sysctl-hw-memsize", executable: "/usr/sbin/sysctl", arguments: ["-n", "hw.memsize"])
        let vmStat = command(context, key: "vm-stat", executable: "/usr/bin/vm_stat")
        let pressure = command(context, key: "memory-pressure", executable: "/usr/bin/memory_pressure", timeout: 30)
        let profiler = systemProfiler(context, dataTypes: ["SPMemoryDataType"], key: "system-profiler-memory", timeout: 120)
        let installed = UInt64(SystemUtilities.trimmed(memsize.stdout)) ?? ProcessInfo.processInfo.physicalMemory
        let flat = profiler.1.map { SystemUtilities.flatten($0) } ?? [:]
        let rows = flat.sorted { $0.key < $1.key }.prefix(120).map { [$0.key, $0.value] }
        context.appendInventory(InventorySection(title: "Memory", items: ["Installed memory": SystemUtilities.humanBytes(installed), "Memory pressure summary": SystemUtilities.firstLine(pressure.combinedOutput)], tables: [InventoryTable(title: "Memory hardware", columns: ["Property", "Value"], rows: Array(rows))]))
        let status: CheckStatus = memsize.exitCode == 0 ? .info : .incomplete
        return DiagnosticResult(category: "Memory", domain: "Hardware Functional", name: "Installed and available memory", status: status, summary: status == .info ? "macOS reports \(SystemUtilities.humanBytes(installed)) of installed memory; current pressure information was collected." : "Installed-memory information was incomplete.", details: [SystemUtilities.firstLine(vmStat.stdout), SystemUtilities.firstLine(pressure.combinedOutput)].filter { !$0.isEmpty }, durationSeconds: Date().timeIntervalSince(started))
    }

    static func storageInventory(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let list = command(context, key: "diskutil-list-full-plist", executable: "/usr/sbin/diskutil", arguments: ["list", "-plist"], timeout: 60)
        let physicalList = command(context, key: "diskutil-list-physical", executable: "/usr/sbin/diskutil", arguments: ["list", "physical"], timeout: 60)
        let apfs = command(context, key: "diskutil-apfs-list-plist", executable: "/usr/sbin/diskutil", arguments: ["apfs", "list", "-plist"], timeout: 90)
        let disks = physicalDisks(context)

        let rows: [[String]] = disks.map { disk in
            [
                "/dev/\(disk.identifier)",
                disk.model,
                SystemUtilities.humanBytes(disk.sizeBytes),
                disk.busProtocol,
                disk.solidState ? "Solid state" : "Rotational/other",
                disk.internalDisk ? "Internal" : disk.removable ? "Removable" : "External",
                disk.smartStatus ?? "Not reported",
                disk.temperatureCelsius.map { String(format: "%.1f °C", $0) } ?? "Not available"
            ]
        }

        let apfsContainers: Int
        if let data = apfs.stdout.data(using: .utf8),
           let root = SystemUtilities.plistDictionary(data),
           let containers = root["Containers"] as? [Any] {
            apfsContainers = containers.count
        } else {
            apfsContainers = 0
        }

        context.appendInventory(InventorySection(
            title: "Storage",
            items: [
                "Physical disks": "\(disks.count)",
                "APFS containers": "\(apfsContainers)",
                "Physical diskutil inventory": SystemUtilities.firstLine(physicalList.stdout)
            ],
            tables: [InventoryTable(
                title: "Physical disks",
                columns: ["Device", "Model", "Size", "Protocol", "Media", "Location", "SMART", "Temperature"],
                rows: rows
            )]
        ))

        let status: CheckStatus = list.exitCode == 0 && !rows.isEmpty ? .info : .incomplete
        return DiagnosticResult(
            category: "Storage",
            domain: "Hardware Functional",
            name: "Physical disk, APFS, and volume inventory",
            status: status,
            summary: status == .info ? "Mapped actual physical media separately from synthesized APFS containers and volumes." : "macOS did not return a complete physical-storage inventory.",
            reason: status == .incomplete ? "No validated physical-media entries were parsed; synthesized APFS devices were not counted as separate drives." : nil,
            details: [
                "Physical drives reported: \(disks.count)",
                "APFS containers reported: \(apfsContainers)",
                "Synthesized APFS whole disks are intentionally excluded from the physical-drive count."
            ],
            durationSeconds: Date().timeIntervalSince(started)
        )
    }

    static func filesystemHealth(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let df = command(context, key: "df-k", executable: "/bin/df", arguments: ["-k"])
        let mount = command(context, key: "mount", executable: "/sbin/mount")
        let verify = command(context, key: "diskutil-verify-root-volume", executable: "/usr/sbin/diskutil", arguments: ["verifyVolume", "/"], timeout: 240)
        let rootURL = URL(fileURLWithPath: "/")
        let values = try? rootURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeIsReadOnlyKey, .volumeLocalizedFormatDescriptionKey])
        let total = UInt64(max(values?.volumeTotalCapacity ?? 0, 0))
        let available = UInt64(max(values?.volumeAvailableCapacityForImportantUsage ?? 0, 0))
        let percent = total > 0 ? Double(available) * 100 / Double(total) : 0
        let readOnly = values?.volumeIsReadOnly ?? false
        let verifyText = verify.combinedOutput

        var status: CheckStatus = .pass
        var reasons: [String] = []
        if verifyText.localizedCaseInsensitiveContains("corrupt") ||
            verifyText.localizedCaseInsensitiveContains("file system check exit code is 8") ||
            verifyText.localizedCaseInsensitiveContains("problems were found") {
            status = .fail
            reasons.append("Live filesystem verification reported corruption or an unsuccessful filesystem check.")
        } else if verify.exitCode != 0 || verify.timedOut {
            status = .incomplete
            reasons.append("Live APFS/filesystem verification could not be completed; this alone is not proof of disk failure.")
        }
        if readOnly {
            if status != .fail { status = .warning }
            reasons.append("The root data volume was reported as read-only.")
        } else if total == 0 {
            if status != .fail { status = .incomplete }
            reasons.append("Root filesystem capacity could not be determined.")
        } else if percent < 10 {
            if status != .fail { status = .warning }
            reasons.append(String(format: "The root filesystem has only %.1f%% available.", percent))
        }

        context.appendInventory(InventorySection(
            title: "Filesystems",
            items: [
                "Root format": values?.volumeLocalizedFormatDescription ?? "Unknown",
                "Root capacity": SystemUtilities.humanBytes(total),
                "Root available": SystemUtilities.humanBytes(available),
                "Root available percent": String(format: "%.1f%%", percent),
                "Live verification": verify.exitCode == 0 ? "Completed successfully" : verify.timedOut ? "Timed out" : "Exit \(verify.exitCode)"
            ]
        ))

        let summary: String
        switch status {
        case .pass: summary = "The root filesystem has adequate free space and live APFS/filesystem verification completed successfully."
        case .fail: summary = "Live filesystem verification reported confirmed filesystem damage."
        case .warning: summary = "The root filesystem requires capacity or mount-state review."
        default: summary = "Filesystem capacity or live verification evidence was incomplete."
        }

        return DiagnosticResult(
            category: "Storage",
            domain: "Hardware Functional",
            name: "Filesystem capacity and live APFS verification",
            status: status,
            summary: summary,
            reason: reasons.isEmpty ? nil : reasons.joined(separator: " "),
            recommendedAction: status == .fail ? "Back up important data immediately and run Disk Utility First Aid from Recovery or follow an approved repair workflow." : status == .warning ? "Free space or review the mount state before returning the Mac to service." : nil,
            details: [
                SystemUtilities.firstLine(df.stdout),
                mount.stdout.split(whereSeparator: \.isNewline).map(String.init).first(where: { $0.contains(" on / ") || $0.contains(" on /(") }) ?? "Root mount line not parsed",
                "Live verification: \(SystemUtilities.firstLine(verifyText))"
            ],
            durationSeconds: Date().timeIntervalSince(started)
        )
    }

}
