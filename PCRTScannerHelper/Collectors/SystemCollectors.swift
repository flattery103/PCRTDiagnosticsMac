import Foundation
import PCRTCore

extension MacCollectors {
    static func networkQuality(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let route = command(context, key: "route-default", executable: "/sbin/route", arguments: ["-n", "get", "default"], timeout: 20)
        let ifconfig = command(context, key: "ifconfig-all", executable: "/sbin/ifconfig", arguments: ["-a"], timeout: 30)
        let dns = command(context, key: "scutil-dns", executable: "/usr/sbin/scutil", arguments: ["--dns"], timeout: 30)
        let counters = command(context, key: "netstat-interfaces", executable: "/usr/sbin/netstat", arguments: ["-ib"], timeout: 30)
        let dnsTest = command(context, key: "dns-resolution", executable: "/usr/bin/dscacheutil", arguments: ["-q", "host", "-a", "name", "scan.pcrtdiag.com"], timeout: 20)
        let https = command(context, key: "https-health", executable: "/usr/bin/curl", arguments: ["--silent", "--show-error", "--fail", "--max-time", "15", "https://scan.pcrtdiag.com:8443/api/v1/health"], timeout: 20)
        let gateway = parseRouteValue(route.stdout, key: "gateway")
        let interface = parseRouteValue(route.stdout, key: "interface")
        let gatewayPing = gateway.map { command(context, key: "ping-gateway", executable: "/sbin/ping", arguments: ["-c", "4", "-W", "1000", $0], timeout: 15) }
        let internetPing = command(context, key: "ping-internet", executable: "/sbin/ping", arguments: ["-c", "4", "-W", "1000", "1.1.1.1"], timeout: 15)

        var status: CheckStatus = .pass
        var reasons: [String] = []
        if route.exitCode != 0 || gateway == nil {
            status = .warning
            reasons.append("No usable default gateway was reported.")
        }
        if dnsTest.exitCode != 0 {
            status = .warning
            reasons.append("DNS resolution for scan.pcrtdiag.com failed.")
        }
        if https.exitCode != 0 {
            status = .warning
            reasons.append("HTTPS connectivity to the PCRT server failed.")
        }
        let gatewayLoss = gatewayPing.flatMap { parsePacketLoss($0.stdout) }
        let internetLoss = parsePacketLoss(internetPing.stdout)
        if let loss = gatewayLoss, loss > 5 {
            status = .warning
            reasons.append(String(format: "Gateway packet loss was %.1f%%.", loss))
        }
        if let loss = internetLoss, loss > 5 {
            status = .warning
            reasons.append(String(format: "Internet packet loss was %.1f%%.", loss))
        }
        let gatewayStats = gatewayPing.flatMap { parsePingStatistics($0.stdout) }
        let internetStats = parsePingStatistics(internetPing.stdout)
        if route.exitCode == -1 && ifconfig.exitCode == -1 && dns.exitCode == -1 { status = .incomplete }
        context.appendInventory(InventorySection(title: "Network", items: ["Primary interface": interface ?? "Not reported", "Default gateway": gateway ?? "Not reported", "DNS resolution": dnsTest.exitCode == 0 ? "Pass" : "Failed", "PCRT HTTPS": https.exitCode == 0 ? "Pass" : "Failed", "Gateway packet loss": gatewayLoss.map { String(format: "%.1f%%", $0) } ?? "Not available", "Gateway average latency": gatewayStats.map { String(format: "%.1f ms", $0.average) } ?? "Not available", "Internet packet loss": internetLoss.map { String(format: "%.1f%%", $0) } ?? "Not available", "Internet average latency": internetStats.map { String(format: "%.1f ms", $0.average) } ?? "Not available"]))
        let summary = status == .pass ? "Gateway, DNS, HTTPS, packet-loss, and interface evidence did not show an obvious connectivity problem." : status == .warning ? "One or more network connectivity checks require review." : "Network evidence could not be collected completely."
        return DiagnosticResult(category: "Network", domain: "Network / Power", name: "Network quality and connectivity", status: status, summary: summary, reason: reasons.isEmpty ? nil : reasons.joined(separator: " "), recommendedAction: status == .warning ? "Verify the active interface, gateway, DNS, and Internet connection, then retry the upload." : nil, details: ["Interface: \(interface ?? "Not reported")", "Gateway: \(gateway ?? "Not reported")", "Gateway latency: \(gatewayStats.map { String(format: "min %.1f / avg %.1f / max %.1f / stddev %.1f ms", $0.minimum, $0.average, $0.maximum, $0.stddev) } ?? "Not available")", "Internet latency: \(internetStats.map { String(format: "min %.1f / avg %.1f / max %.1f / stddev %.1f ms", $0.minimum, $0.average, $0.maximum, $0.stddev) } ?? "Not available")", "HTTPS response: \(SystemUtilities.firstLine(https.combinedOutput))", "Interface inventory size: \(ifconfig.stdout.count) characters", "Counter inventory size: \(counters.stdout.count) characters"], durationSeconds: Date().timeIntervalSince(started))
    }

    static func panicAndShutdownHistory(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let predicate = "eventMessage CONTAINS[c] \"Previous shutdown cause\" OR eventMessage CONTAINS[c] \"panic\" OR eventMessage CONTAINS[c] \"I/O error\" OR eventMessage CONTAINS[c] \"disk arbitration\" OR eventMessage CONTAINS[c] \"GPU Restart\""
        let logs = command(context, key: "unified-hardware-log", executable: "/usr/bin/log", arguments: ["show", "--last", "30d", "--style", "compact", "--predicate", predicate], timeout: 90)
        let last = command(context, key: "last-reboots", executable: "/usr/bin/last", arguments: ["reboot", "shutdown"], timeout: 30)
        let reportDirectory = URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true)
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let reportFiles = ((try? FileManager.default.contentsOfDirectory(at: reportDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []).filter { url in
            let lower = url.lastPathComponent.lowercased()
            guard lower.contains("panic") || lower.contains("kernel") || lower.contains("gpu") else { return false }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return date >= cutoff
        }
        let logLines = logs.stdout.split(whereSeparator: \.isNewline).map(String.init)
        let shutdownLines = logLines.filter { $0.localizedCaseInsensitiveContains("Previous shutdown cause") }
        let panicLines = logLines.filter { $0.localizedCaseInsensitiveContains("panic") }
        let storageLines = logLines.filter { $0.localizedCaseInsensitiveContains("I/O error") || $0.localizedCaseInsensitiveContains("disk arbitration") }
        let gpuLines = logLines.filter { $0.localizedCaseInsensitiveContains("GPU Restart") }
        var status: CheckStatus = .pass
        var reasons: [String] = []
        if !reportFiles.isEmpty || !panicLines.isEmpty {
            status = .warning
            reasons.append("Recent kernel panic evidence was found.")
        }
        if !shutdownLines.isEmpty {
            status = .warning
            reasons.append("Unexpected-shutdown cause evidence was found.")
        }
        if !storageLines.isEmpty || !gpuLines.isEmpty {
            status = .warning
            reasons.append("Recent storage or GPU log evidence requires review.")
        }
        if logs.timedOut || logs.exitCode == -1 { status = status == .warning ? .warning : .incomplete }
        let files = reportFiles.prefix(20).map(\.lastPathComponent)
        let details = ["Recent panic/kernel diagnostic files: \(reportFiles.count)", "Shutdown-cause lines: \(shutdownLines.count)", "Panic lines: \(panicLines.count)", "Storage I/O lines: \(storageLines.count)", "GPU restart lines: \(gpuLines.count)"] + files
        return DiagnosticResult(category: "macOS", domain: "macOS Integrity", name: "Kernel panic, shutdown, and hardware-log review", status: status, summary: status == .pass ? "No recent kernel panic, unexpected-shutdown, storage I/O, or GPU restart evidence was found in the reviewed sources." : status == .warning ? "Recent panic, shutdown, storage, or GPU evidence requires review." : "Unified-log review could not be completed.", reason: reasons.isEmpty ? nil : reasons.joined(separator: " "), recommendedAction: status == .warning ? "Review the named DiagnosticReports and unified-log entries, then repeat hardware tests after correcting any software or peripheral cause." : nil, details: details + ["Boot/shutdown history entries: \(last.stdout.split(whereSeparator: \.isNewline).count)"], durationSeconds: Date().timeIntervalSince(started))
    }

    static func servicesHealth(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let predicate = "process == \"launchd\" AND (eventMessage CONTAINS[c] \"exited with abnormal code\" OR eventMessage CONTAINS[c] \"crashed\" OR eventMessage CONTAINS[c] \"throttling respawn\")"
        let logs = command(context, key: "launchd-failure-log", executable: "/usr/bin/log", arguments: ["show", "--last", "14d", "--style", "compact", "--predicate", predicate], timeout: 90)
        let launchctl = command(context, key: "launchctl-system", executable: "/bin/launchctl", arguments: ["print", "system"], timeout: 90)
        let lines = logs.stdout.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.contains("Timestamp") }
        var grouped: [String: Int] = [:]
        for line in lines {
            let key = String(line.suffix(240))
            grouped[key, default: 0] += 1
        }
        let repeated = grouped.filter { $0.value >= 3 }.sorted { $0.value > $1.value }
        let status: CheckStatus
        if !repeated.isEmpty { status = .warning }
        else if logs.timedOut || (logs.exitCode != 0 && launchctl.exitCode != 0) { status = .incomplete }
        else { status = .pass }
        return DiagnosticResult(category: "macOS", domain: "macOS Maintenance", name: "Failed and repeatedly crashing services", status: status, summary: status == .pass ? "No repeatedly abnormal launchd service pattern was found in the review period." : status == .warning ? "One or more launchd service failures repeated during the review period." : "Service and launchd evidence could not be reviewed completely.", reason: status == .warning ? "\(repeated.count) repeated launchd failure pattern(s) occurred at least three times." : nil, recommendedAction: status == .warning ? "Review the named launchd jobs and their owning applications; do not treat a stopped on-demand service as a failure by itself." : nil, details: repeated.prefix(15).map { "\($0.value)x: \($0.key)" } + ["System launchd inventory size: \(launchctl.stdout.count) characters"], durationSeconds: Date().timeIntervalSince(started))
    }

    static func softwareUpdates(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let result = command(context, key: "softwareupdate-list", executable: "/usr/sbin/softwareupdate", arguments: ["--list"], timeout: 300)
        if result.timedOut {
            return DiagnosticResult(category: "macOS", domain: "macOS Maintenance", name: "Available macOS software updates", status: .incomplete, summary: "The macOS update search did not finish within five minutes.", reason: "softwareupdate --list timed out.", recommendedAction: "Open System Settings > General > Software Update and retry the check.", durationSeconds: Date().timeIntervalSince(started))
        }
        let text = result.combinedOutput
        if result.exitCode != 0 {
            return DiagnosticResult(category: "macOS", domain: "macOS Maintenance", name: "Available macOS software updates", status: .incomplete, summary: "macOS could not complete the software-update search.", reason: SystemUtilities.firstLine(text), recommendedAction: "Check network access and retry Software Update.", durationSeconds: Date().timeIntervalSince(started))
        }
        let noUpdates = text.localizedCaseInsensitiveContains("No new software available") || text.localizedCaseInsensitiveContains("No updates are available")
        let updateLines = text.split(whereSeparator: \.isNewline).map(String.init).filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("*") || $0.localizedCaseInsensitiveContains("Label:") }
        let status: CheckStatus = noUpdates ? .pass : updateLines.isEmpty ? .info : .warning
        return DiagnosticResult(category: "macOS", domain: "macOS Maintenance", name: "Available macOS software updates", status: status, summary: noUpdates ? "macOS did not report any available software updates." : updateLines.isEmpty ? "The software-update search completed without a clearly parsed update list." : "macOS reported \(updateLines.count) available update item(s).", reason: status == .warning ? "Software maintenance updates are available; this is not a hardware failure." : nil, recommendedAction: status == .warning ? "Review and install appropriate macOS updates after the diagnostic session and normal backup/change procedures." : nil, details: Array(updateLines.prefix(30)), durationSeconds: Date().timeIntervalSince(started))
    }

    static func securityConfiguration(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let fileVault = command(context, key: "filevault-status", executable: "/usr/bin/fdesetup", arguments: ["status"], timeout: 30)
        let sip = command(context, key: "sip-status", executable: "/usr/bin/csrutil", arguments: ["status"], timeout: 30)
        let gatekeeper = command(context, key: "gatekeeper-status", executable: "/usr/sbin/spctl", arguments: ["--status"], timeout: 30)
        let secureBoot = FileManager.default.isExecutableFile(atPath: "/usr/bin/bputil") ? command(context, key: "secure-boot", executable: "/usr/bin/bputil", arguments: ["-d"], timeout: 30) : nil
        let bridge = systemProfiler(context, dataTypes: ["SPiBridgeDataType"], key: "system-profiler-bridge", timeout: 90)
        var warnings: [String] = []
        if fileVault.combinedOutput.localizedCaseInsensitiveContains("FileVault is Off") { warnings.append("FileVault is off.") }
        if sip.combinedOutput.localizedCaseInsensitiveContains("disabled") { warnings.append("System Integrity Protection is disabled.") }
        if gatekeeper.combinedOutput.localizedCaseInsensitiveContains("disabled") { warnings.append("Gatekeeper assessments are disabled.") }
        let completedCoreCollectors = [fileVault, sip, gatekeeper].filter { $0.exitCode == 0 && !$0.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let status: CheckStatus
        if !warnings.isEmpty { status = .warning }
        else if completedCoreCollectors < 2 { status = .incomplete }
        else { status = .pass }
        context.appendInventory(InventorySection(title: "Security and configuration", items: ["FileVault": SystemUtilities.trimmed(fileVault.combinedOutput), "System Integrity Protection": SystemUtilities.trimmed(sip.combinedOutput), "Gatekeeper": SystemUtilities.trimmed(gatekeeper.combinedOutput), "Secure Boot evidence": secureBoot.map { SystemUtilities.firstLine($0.combinedOutput) } ?? (bridge.0.exitCode == 0 ? "Apple security-controller inventory collected" : "Not available")]))
        return DiagnosticResult(category: "Security", domain: "Security / Configuration", name: "FileVault, SIP, Gatekeeper, and Secure Boot", status: status, summary: status == .pass ? "The available macOS security controls did not show an obvious disabled state." : status == .warning ? "One or more macOS security controls are disabled." : "macOS security-control status could not be collected completely.", reason: !warnings.isEmpty ? warnings.joined(separator: " ") : status == .incomplete ? "Fewer than two core security collectors returned usable output." : nil, recommendedAction: status == .warning ? "Confirm the configuration is intentional before changing FileVault, SIP, Gatekeeper, or startup security settings." : nil, details: ["FileVault: \(SystemUtilities.trimmed(fileVault.combinedOutput))", "SIP: \(SystemUtilities.trimmed(sip.combinedOutput))", "Gatekeeper: \(SystemUtilities.trimmed(gatekeeper.combinedOutput))", "Secure Boot: \(secureBoot.map { SystemUtilities.firstLine($0.combinedOutput) } ?? "Not directly available")"], durationSeconds: Date().timeIntervalSince(started))
    }

    static func temperatureSensors(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let disks = physicalDisks(context)
        var details: [String] = []
        var rawSensors: [JSONValue] = []
        var highestStorageTemperature: Double?

        for disk in disks {
            if let temperature = disk.temperatureCelsius {
                highestStorageTemperature = max(highestStorageTemperature ?? temperature, temperature)
                details.append(String(format: "/dev/%@ %@ storage temperature: %.1f °C", disk.identifier, disk.model, temperature))
                rawSensors.append(.object([
                    "category": .string("Storage"),
                    "device": .string("/dev/\(disk.identifier)"),
                    "name": .string(disk.model),
                    "temperature_celsius": .number(temperature),
                    "source": .string("diskutil NVMe SMART data")
                ]))
            }
        }

        let architecture = SystemUtilities.machineArchitecture()
        var intelTemperatureLines: [String] = []
        if architecture == "x86_64" {
            let smc = command(context, key: "powermetrics-smc-temperature", executable: "/usr/bin/powermetrics", arguments: ["-n", "3", "-i", "1000", "--samplers", "smc"], timeout: 15)
            intelTemperatureLines = extractTemperatureLines(smc.combinedOutput)
            details.append(contentsOf: intelTemperatureLines.prefix(50))
        } else {
            let sensorRegistry = command(context, key: "ioreg-temperature-sensor-availability", executable: "/usr/sbin/ioreg", arguments: ["-l", "-w0", "-p", "IOService"], timeout: 20)
            let names = sensorRegistry.stdout.split(whereSeparator: \.isNewline).map(String.init).filter { line in
                let lower = line.lowercased()
                return lower.contains("temperature") || lower.contains("temp sensor") || lower.contains("nand ch0 temp") || lower.contains("pmu tdev")
            }
            if !names.isEmpty {
                details.append("Apple Silicon temperature-sensor services were detected, but macOS did not expose reliable CPU/GPU Celsius values through the supported command-line interfaces.")
                details.append("Detected sensor-registry lines: \(min(names.count, 100))")
            }
        }

        let numericalCount = rawSensors.count + intelTemperatureLines.count
        let status: CheckStatus
        var reason: String?
        if let highestStorageTemperature, highestStorageTemperature >= 80 {
            status = .warning
            reason = String(format: "A physical storage device reported a high temperature of %.1f °C.", highestStorageTemperature)
        } else if numericalCount > 0 {
            status = .info
        } else {
            status = .notAvailable
            reason = "This Mac did not expose reliable numerical temperatures through the currently supported read-only interfaces."
        }

        let summary: String
        if status == .warning {
            summary = "One or more reliable numerical temperature readings require review."
        } else if numericalCount > 0 {
            summary = "Collected \(numericalCount) reliable numerical temperature reading(s); unavailable CPU/GPU sensor categories are stated explicitly."
        } else {
            summary = "Reliable numerical temperature readings were not available on this Mac."
        }

        details.append("Numerical temperature coverage is reported independently from macOS thermal-pressure status.")
        details.append("No missing numerical sensor category is marked Pass.")

        return DiagnosticResult(
            category: "Thermals",
            domain: "Hardware Functional",
            name: "Numerical temperature coverage",
            status: status,
            summary: summary,
            reason: reason,
            recommendedAction: status == .warning ? "Verify airflow and ambient conditions, allow the Mac to cool, and repeat the storage and thermal tests." : nil,
            details: details,
            durationSeconds: Date().timeIntervalSince(started),
            raw: ["temperature_sensors": .array(rawSensors)]
        )
    }

    static func thermalPressure(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let pmset = command(context, key: "pmset-therm", executable: "/usr/bin/pmset", arguments: ["-g", "therm"], timeout: 30)
        let thermal = command(context, key: "powermetrics-thermal-pressure", executable: "/usr/bin/powermetrics", arguments: ["-n", "3", "-i", "1000", "--samplers", "thermal"], timeout: 15)
        let power = command(context, key: "powermetrics-cpu-gpu-power", executable: "/usr/bin/powermetrics", arguments: ["-n", "3", "-i", "1000", "--samplers", "cpu_power,gpu_power", "--show-plimits"], timeout: 15)

        let processState = thermalStateName(ProcessInfo.processInfo.thermalState)
        let pressureLines = selectedLines(thermal.combinedOutput, containingAny: ["pressure level", "thermal pressure"])
        let powerLines = selectedLines(power.combinedOutput, containingAny: ["cpu power", "gpu power", "combined power", "frequency", "active residency", "plimit", "limit"])
        let combinedPressure = ([processState] + pressureLines).joined(separator: " ").lowercased()

        var status: CheckStatus = .pass
        var reason: String?
        if combinedPressure.contains("critical") || combinedPressure.contains("serious") {
            status = .warning
            reason = "macOS reported serious or critical thermal pressure."
        } else if combinedPressure.contains("fair") {
            status = .warning
            reason = "macOS reported fair thermal pressure, indicating active thermal management."
        } else if thermal.exitCode != 0 && pmset.exitCode != 0 {
            status = .notAvailable
            reason = "macOS did not expose thermal-pressure evidence on this hardware or OS version."
        }

        let summary: String
        switch status {
        case .pass: summary = "macOS thermal pressure remained nominal in the available samples."
        case .warning: summary = "macOS reported elevated thermal pressure or active thermal mitigation."
        default: summary = "Thermal-pressure evidence was not available on this Mac."
        }

        var details = [
            "Process thermal state: \(processState)",
            "pmset thermal evidence: \(SystemUtilities.firstLine(pmset.combinedOutput))"
        ]
        details.append(contentsOf: pressureLines.prefix(20))
        details.append(contentsOf: powerLines.prefix(50))
        if power.exitCode != 0 {
            details.append("CPU/GPU power-frequency telemetry was not available: \(SystemUtilities.firstLine(power.combinedOutput))")
        }
        details.append("Thermal pressure is a separate macOS health signal and does not imply that numerical CPU/GPU temperatures were collected.")

        return DiagnosticResult(
            category: "Thermals",
            domain: "Workload Stability",
            name: "Thermal pressure, power, and throttling evidence",
            status: status,
            summary: summary,
            reason: reason,
            recommendedAction: status == .warning ? "Verify airflow, workload, and ambient temperature, then repeat the test after the Mac returns to nominal thermal pressure." : nil,
            details: details,
            durationSeconds: Date().timeIntervalSince(started)
        )
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private static func selectedLines(_ output: String, containingAny needles: [String]) -> [String] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).map(String.init).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            guard !trimmed.isEmpty, needles.contains(where: { lower.contains($0) }), !seen.contains(trimmed) else { return nil }
            seen.insert(trimmed)
            return trimmed
        }
    }

    private static func parseRouteValue(_ output: String, key: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.lowercased().hasPrefix(key.lowercased() + ":") {
                return text.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }

    private static func parsePacketLoss(_ output: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)% packet loss", options: [.caseInsensitive]) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range), let valueRange = Range(match.range(at: 1), in: output) else { return nil }
        return Double(output[valueRange])
    }

    private static func parsePingStatistics(_ output: String) -> (minimum: Double, average: Double, maximum: Double, stddev: Double)? {
        guard let regex = try? NSRegularExpression(pattern: "(?:round-trip|rtt) min/avg/max/(?:stddev|mdev) = ([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+) ms", options: [.caseInsensitive]) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range), match.numberOfRanges == 5 else { return nil }
        var values: [Double] = []
        for index in 1..<5 {
            guard let valueRange = Range(match.range(at: index), in: output), let value = Double(output[valueRange]) else { return nil }
            values.append(value)
        }
        return (values[0], values[1], values[2], values[3])
    }

    private static func extractTemperatureLines(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map(String.init).filter { line in
            let lower = line.lowercased()
            return lower.contains("temperature") && (lower.contains(" c") || lower.contains("°c"))
        }
    }
}
