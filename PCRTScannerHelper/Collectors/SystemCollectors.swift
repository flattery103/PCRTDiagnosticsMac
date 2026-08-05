import Foundation
import PCRTCore

extension MacCollectors {
    static func networkQuality(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let route = command(context, key: "route-default", executable: "/sbin/route", arguments: ["-n", "get", "default"], timeout: 20)
        let route6 = command(context, key: "route-default-ipv6", executable: "/sbin/route", arguments: ["-n", "get", "-inet6", "default"], timeout: 20)
        let ifconfig = command(context, key: "ifconfig-all", executable: "/sbin/ifconfig", arguments: ["-a"], timeout: 30)
        let dns = command(context, key: "scutil-dns", executable: "/usr/sbin/scutil", arguments: ["--dns"], timeout: 30)
        let counters = command(context, key: "netstat-interfaces", executable: "/usr/sbin/netstat", arguments: ["-ib"], timeout: 30)
        let gateway = parseRouteValue(route.stdout, key: "gateway")
        let interface = parseRouteValue(route.stdout, key: "interface")
        let ipv6Interface = parseRouteValue(route6.stdout, key: "interface")
        let hasIPv6Route = route6.exitCode == 0 && ipv6Interface != nil

        var dnsSamples: [CommandResult] = []
        for index in 1...3 {
            dnsSamples.append(command(context, key: "dns-resolution-\(index)", executable: "/usr/bin/dscacheutil", arguments: ["-q", "host", "-a", "name", "scan.pcrtdiag.com"], timeout: 20))
        }
        let health = command(context, key: "https-health", executable: "/usr/bin/curl", arguments: ["--silent", "--show-error", "--fail", "--max-time", "15", "https://scan.pcrtdiag.com:8443/api/v1/health"], timeout: 20)
        var ipv4HTTPS: [CommandResult] = []
        for index in 1...5 {
            ipv4HTTPS.append(command(
                context,
                key: "https-ipv4-quality-\(index)",
                executable: "/usr/bin/curl",
                arguments: ["-4", "--silent", "--show-error", "--output", "/dev/null", "--write-out", "%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}", "--connect-timeout", "5", "--max-time", "15", "https://scan.pcrtdiag.com:8443/api/v1/health"],
                timeout: 20
            ))
        }
        var ipv6HTTPS: [CommandResult] = []
        if hasIPv6Route {
            for index in 1...3 {
                ipv6HTTPS.append(command(
                    context,
                    key: "https-ipv6-quality-\(index)",
                    executable: "/usr/bin/curl",
                    arguments: ["-6", "--silent", "--show-error", "--output", "/dev/null", "--write-out", "%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}", "--connect-timeout", "5", "--max-time", "15", "https://scan.pcrtdiag.com:8443/api/v1/health"],
                    timeout: 20
                ))
            }
        }

        let gatewayPing = gateway.map { command(context, key: "ping-gateway", executable: "/sbin/ping", arguments: ["-c", "10", "-W", "1000", $0], timeout: 20) }
        let internetPing = command(context, key: "ping-internet", executable: "/sbin/ping", arguments: ["-c", "10", "-W", "1000", "1.1.1.1"], timeout: 20)
        let wifi = systemProfiler(context, dataTypes: ["SPAirPortDataType"], key: "system-profiler-wifi", timeout: 75)
        let wdutil = FileManager.default.isExecutableFile(atPath: "/usr/bin/wdutil")
            ? command(context, key: "wdutil-info", executable: "/usr/bin/wdutil", arguments: ["info"], timeout: 30)
            : nil
        let wifiFlat = wifi.1.map { SystemUtilities.flatten($0) } ?? [:]
        let wifiCombined = wifiFlat.map { "\($0.key): \($0.value)" }.joined(separator: "\n") + "\n" + (wdutil?.combinedOutput ?? "")
        let wifiSignal = parseWiFiSignal(wifiCombined)
        let wifiRate = parseFirstDouble(wifiCombined, patterns: ["(?:Tx Rate|Transmit Rate|lastTxRate)[^0-9]*([0-9.]+)", "spairport_network_rate[^0-9]*([0-9.]+)"])
        let wifiChannel = firstMatchingWiFiValue(wifiFlat, keyNeedles: ["channel"]) ?? parseFirstString(wifiCombined, pattern: "(?:Channel|channel)[^:]*:\\s*([^\\n]+)")
        let wifiPHY = firstMatchingWiFiValue(wifiFlat, keyNeedles: ["phy", "mode"]) ?? firstMatchingWiFiValue(wifiFlat, keyNeedles: ["supported_phymodes"])
        let activeVPNs = activeTunnelInterfaces(ifconfig.stdout)

        var networkQuality: CommandResult?
        let mode = context.config.scanType.lowercased().replacingOccurrences(of: "-", with: "")
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/networkQuality") && ["full", "deep", "burnin"].contains(mode) {
            networkQuality = command(context, key: "network-quality-built-in", executable: "/usr/bin/networkQuality", arguments: ["-s"], timeout: 75)
        }

        let gatewayLoss = gatewayPing.flatMap { parsePacketLoss($0.stdout) }
        let internetLoss = parsePacketLoss(internetPing.stdout)
        let gatewayStats = gatewayPing.flatMap { parsePingStatistics($0.stdout) }
        let internetStats = parsePingStatistics(internetPing.stdout)
        let dnsSuccesses = dnsSamples.filter { $0.exitCode == 0 && !$0.stdout.isEmpty }.count
        let dnsAverage = dnsSamples.isEmpty ? nil : dnsSamples.map(\.duration).reduce(0, +) / Double(dnsSamples.count)
        let ipv4Metrics = ipv4HTTPS.compactMap(parseHTTPMetric)
        let ipv4Successes = ipv4Metrics.filter { $0.code >= 200 && $0.code < 400 }.count
        let ipv6Metrics = ipv6HTTPS.compactMap(parseHTTPMetric)
        let ipv6Successes = ipv6Metrics.filter { $0.code >= 200 && $0.code < 400 }.count

        var status: CheckStatus = .pass
        var reasons: [String] = []
        if route.exitCode != 0 || gateway == nil {
            status = .warning
            reasons.append("No usable IPv4 default gateway was reported.")
        }
        if dnsSuccesses == 0 {
            status = .warning
            reasons.append("All DNS resolution samples for scan.pcrtdiag.com failed.")
        }
        if health.exitCode != 0 || ipv4Successes < 4 {
            status = .warning
            reasons.append("Repeated IPv4 HTTPS connectivity to the PCRT server was unreliable.")
        }
        if let loss = gatewayLoss, loss > 10 {
            status = .warning
            reasons.append(String(format: "Gateway packet loss was %.1f%%.", loss))
        }
        if hasIPv6Route && !ipv6HTTPS.isEmpty && ipv6Successes == 0 {
            status = .warning
            reasons.append("An IPv6 default route was present, but all IPv6 HTTPS samples failed.")
        }
        if let rssi = wifiSignal.rssi, rssi <= -75 {
            status = .warning
            reasons.append("Wi-Fi signal strength was weak at \(rssi) dBm.")
        }
        if let snr = wifiSignal.snr, snr < 15 {
            status = .warning
            reasons.append("Wi-Fi signal-to-noise ratio was low at \(snr) dB.")
        }
        if route.exitCode == -1 && ifconfig.exitCode == -1 && dns.exitCode == -1 {
            status = .incomplete
        }

        var details = [
            "Primary interface: \(interface ?? "Not reported")",
            "Default gateway: \(gateway ?? "Not reported")",
            "Gateway latency: \(gatewayStats.map { String(format: "min %.1f / avg %.1f / max %.1f / stddev %.1f ms", $0.minimum, $0.average, $0.maximum, $0.stddev) } ?? "Not available")",
            "Gateway packet loss: \(gatewayLoss.map { String(format: "%.1f%%", $0) } ?? "Not available")",
            "Internet ICMP latency: \(internetStats.map { String(format: "min %.1f / avg %.1f / max %.1f / stddev %.1f ms", $0.minimum, $0.average, $0.maximum, $0.stddev) } ?? "Not available")",
            "Internet ICMP packet loss: \(internetLoss.map { String(format: "%.1f%%", $0) } ?? "Not available")",
            "DNS samples: \(dnsSuccesses)/\(dnsSamples.count) successful; average duration \(dnsAverage.map { String(format: "%.3f sec", $0) } ?? "Not available")",
            "IPv4 HTTPS samples: \(ipv4Successes)/\(ipv4HTTPS.count) successful; average total time \(averageHTTPTime(ipv4Metrics))",
            hasIPv6Route ? "IPv6 HTTPS samples: \(ipv6Successes)/\(ipv6HTTPS.count) successful; average total time \(averageHTTPTime(ipv6Metrics))" : "IPv6: No usable default route was reported; IPv6 connectivity was not required.",
            "HTTPS health response: \(SystemUtilities.firstLine(health.combinedOutput))",
            "Active VPN/tunnel interfaces: \(activeVPNs.isEmpty ? "None detected" : activeVPNs.joined(separator: ", "))"
        ]
        if let rssi = wifiSignal.rssi { details.append("Wi-Fi RSSI: \(rssi) dBm") }
        if let noise = wifiSignal.noise { details.append("Wi-Fi noise: \(noise) dBm") }
        if let snr = wifiSignal.snr { details.append("Wi-Fi signal-to-noise ratio: \(snr) dB") }
        if let wifiRate { details.append(String(format: "Wi-Fi negotiated/transmit rate: %.1f Mbps", wifiRate)) }
        if let wifiChannel { details.append("Wi-Fi channel: \(wifiChannel)") }
        if let wifiPHY { details.append("Wi-Fi PHY mode: \(wifiPHY)") }
        if let networkQuality {
            details.append("Built-in networkQuality: \(networkQuality.exitCode == 0 ? SystemUtilities.firstLine(networkQuality.combinedOutput) : "Unavailable (\(SystemUtilities.firstLine(networkQuality.combinedOutput)))")")
            details.append(contentsOf: selectedLines(networkQuality.combinedOutput, containingAny: ["uplink", "downlink", "responsiveness", "rpm"]).prefix(20))
        } else if FileManager.default.isExecutableFile(atPath: "/usr/bin/networkQuality") {
            details.append("Built-in upload/download responsiveness testing is reserved for Full, Deep, and Burn-in scans.")
        }
        if let loss = internetLoss, loss > 10, ipv4Successes == ipv4HTTPS.count {
            details.append("Internet ICMP loss was observed, but all HTTPS samples succeeded; remote ICMP filtering or deprioritization may explain the difference.")
        }
        details.append("Interface inventory size: \(ifconfig.stdout.count) characters")
        details.append("Counter inventory size: \(counters.stdout.count) characters")

        context.appendInventory(InventorySection(title: "Network", items: [
            "Primary interface": interface ?? "Not reported",
            "Default gateway": gateway ?? "Not reported",
            "DNS samples": "\(dnsSuccesses)/\(dnsSamples.count)",
            "IPv4 HTTPS": "\(ipv4Successes)/\(ipv4HTTPS.count)",
            "IPv6 route": hasIPv6Route ? "Available on \(ipv6Interface ?? "unknown interface")" : "Not available",
            "Wi-Fi RSSI": wifiSignal.rssi.map { "\($0) dBm" } ?? "Not available",
            "Wi-Fi SNR": wifiSignal.snr.map { "\($0) dB" } ?? "Not available",
            "Active tunnels": activeVPNs.isEmpty ? "None" : activeVPNs.joined(separator: ", ")
        ]))

        let summary = status == .pass ? "Wi-Fi, gateway, DNS, repeated HTTPS, IPv4/IPv6, VPN, and available built-in quality evidence did not show an obvious connectivity problem." : status == .warning ? "One or more network quality or connectivity checks require review." : "Network evidence could not be collected completely."
        return DiagnosticResult(
            category: "Network",
            domain: "Network / Power",
            name: "Wi-Fi, IPv4, IPv6, DNS, VPN, and Internet quality",
            status: status,
            summary: summary,
            reason: reasons.isEmpty ? nil : reasons.joined(separator: " "),
            recommendedAction: status == .warning ? "Verify Wi-Fi signal, gateway, DNS, VPN routing, IPv6 configuration, and Internet connection, then repeat the upload." : nil,
            details: details,
            durationSeconds: Date().timeIntervalSince(started),
            raw: [
                "dns_successes": .number(Double(dnsSuccesses)),
                "ipv4_https_successes": .number(Double(ipv4Successes)),
                "ipv6_https_successes": .number(Double(ipv6Successes)),
                "wifi_rssi_dbm": wifiSignal.rssi.map { .number(Double($0)) } ?? .null,
                "wifi_noise_dbm": wifiSignal.noise.map { .number(Double($0)) } ?? .null,
                "active_tunnels": .array(activeVPNs.map { .string($0) })
            ]
        )
    }

    static func postWorkloadEventReview(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let windowStart = context.workloadStartedAt
        let predicate = """
        (eventMessage CONTAINS[c] "I/O error") OR
        (eventMessage CONTAINS[c] "media error") OR
        (eventMessage CONTAINS[c] "data integrity") OR
        (eventMessage CONTAINS[c] "GPU Restart") OR
        (eventMessage CONTAINS[c] "channel exception") OR
        ((eventMessage CONTAINS[c] "IOGPU" OR eventMessage CONTAINS[c] "AGX") AND (eventMessage CONTAINS[c] "fault" OR eventMessage CONTAINS[c] "hang" OR eventMessage CONTAINS[c] "reset" OR eventMessage CONTAINS[c] "timeout")) OR
        ((eventMessage CONTAINS[c] "NVMe" OR eventMessage CONTAINS[c] "AppleANS") AND (eventMessage CONTAINS[c] "error" OR eventMessage CONTAINS[c] "reset" OR eventMessage CONTAINS[c] "timeout" OR eventMessage CONTAINS[c] "critical")) OR
        (eventMessage CONTAINS[c] "APFS" AND (eventMessage CONTAINS[c] "corrupt" OR eventMessage CONTAINS[c] "invalid" OR eventMessage CONTAINS[c] "error")) OR
        (eventMessage CONTAINS[c] "thermal" AND (eventMessage CONTAINS[c] "serious" OR eventMessage CONTAINS[c] "critical" OR eventMessage CONTAINS[c] "shutdown")) OR
        (eventMessage CONTAINS[c] "memory pressure" AND eventMessage CONTAINS[c] "critical") OR
        (eventMessage CONTAINS[c] "panic") OR
        ((eventMessage CONTAINS[c] "USB" OR eventMessage CONTAINS[c] "Thunderbolt") AND (eventMessage CONTAINS[c] "disconnect" OR eventMessage CONTAINS[c] "reset" OR eventMessage CONTAINS[c] "overcurrent"))
        """
        let logs = command(
            context,
            key: "post-workload-hardware-log",
            executable: "/usr/bin/log",
            arguments: ["show", "--start", formatter.string(from: windowStart), "--style", "compact", "--predicate", predicate],
            timeout: 35
        )
        let lines = logs.stdout.split(whereSeparator: \.isNewline).map(String.init).filter { line in
            let lower = line.lowercased()
            return !line.contains("Timestamp") && !lower.contains("pcrt diagnostics") && !lower.contains("log show")
        }
        let storage = lines.filter { containsAny($0, ["i/o error", "media error", "data integrity", "nvme", "appleans", "apfs"]) }
        let gpu = lines.filter { containsAny($0, ["gpu restart", "channel exception", "iogpu", "agx"]) }
        let thermal = lines.filter { containsAny($0, ["thermal", "throttl"]) }
        let memory = lines.filter { containsAny($0, ["memory pressure", "memorystatus", "jetsam"]) }
        let panic = lines.filter { $0.localizedCaseInsensitiveContains("panic") }
        let peripheral = lines.filter { containsAny($0, ["usb", "thunderbolt"]) }

        var reasons: [String] = []
        if !storage.isEmpty { reasons.append("Storage or APFS events were recorded during the workload window.") }
        if !gpu.isEmpty { reasons.append("GPU reset, hang, or fault events were recorded during the workload window.") }
        if !thermal.isEmpty { reasons.append("Serious thermal-management events were recorded during the workload window.") }
        if !memory.isEmpty { reasons.append("Critical memory-pressure events were recorded during the workload window.") }
        if !panic.isEmpty { reasons.append("Panic evidence was recorded during the workload window.") }
        if !peripheral.isEmpty { reasons.append("USB or Thunderbolt reset/disconnect events were recorded during the workload window.") }

        let status: CheckStatus
        if !reasons.isEmpty { status = .warning }
        else if logs.timedOut || logs.exitCode != 0 { status = .incomplete }
        else { status = .pass }
        var details = [
            "Workload event-review start: \(formatter.string(from: windowStart))",
            "Workload event-review finish: \(formatter.string(from: Date()))",
            "Storage/APFS lines: \(storage.count)",
            "GPU lines: \(gpu.count)",
            "Thermal lines: \(thermal.count)",
            "Memory-pressure lines: \(memory.count)",
            "Panic lines: \(panic.count)",
            "USB/Thunderbolt lines: \(peripheral.count)"
        ]
        details.append(contentsOf: lines.prefix(40))
        return DiagnosticResult(
            category: "macOS",
            domain: "Workload Stability",
            name: "Post-workload hardware event review",
            status: status,
            summary: status == .pass ? "No targeted storage, GPU, thermal, memory, panic, USB, or Thunderbolt event was found during the diagnostic workload window." : status == .warning ? "One or more hardware-related events occurred during the workload window and require review." : "The bounded post-workload event review could not be completed.",
            reason: reasons.isEmpty ? (status == .incomplete ? "The targeted unified-log query timed out or returned an error." : nil) : reasons.joined(separator: " "),
            recommendedAction: status == .warning ? "Review the named event lines alongside the functional test results, then repeat the affected workload after correcting software, cooling, cable, port, or storage conditions." : nil,
            details: details,
            durationSeconds: Date().timeIntervalSince(started),
            raw: [
                "window_start": .string(formatter.string(from: windowStart)),
                "matched_lines": .number(Double(lines.count))
            ]
        )
    }

    static func panicAndShutdownHistory(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let predicate = "process == \"kernel\" AND (eventMessage CONTAINS[c] \"Previous shutdown cause\" OR eventMessage CONTAINS[c] \"panic\")"
        let logs = command(context, key: "unified-panic-shutdown-log", executable: "/usr/bin/log", arguments: ["show", "--last", "7d", "--style", "compact", "--predicate", predicate], timeout: 25)
        let last = command(context, key: "last-reboots", executable: "/usr/bin/last", arguments: ["reboot", "shutdown"], timeout: 20)
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
        var status: CheckStatus = .pass
        var reasons: [String] = []
        if !reportFiles.isEmpty || !panicLines.isEmpty {
            status = .warning
            reasons.append("Recent kernel panic or GPU diagnostic-report evidence was found.")
        }
        if !shutdownLines.isEmpty {
            status = .warning
            reasons.append("Unexpected-shutdown cause evidence was found.")
        }
        if logs.timedOut || logs.exitCode == -1 { status = status == .warning ? .warning : .incomplete }
        let files = reportFiles.prefix(20).map(\.lastPathComponent)
        let details = ["Recent panic/kernel/GPU diagnostic files: \(reportFiles.count)", "Shutdown-cause lines: \(shutdownLines.count)", "Panic lines: \(panicLines.count)"] + files
        return DiagnosticResult(category: "macOS", domain: "macOS Integrity", name: "Kernel panic and unexpected-shutdown history", status: status, summary: status == .pass ? "No recent kernel panic or unexpected-shutdown evidence was found in the bounded review." : status == .warning ? "Recent panic or unexpected-shutdown evidence requires review." : "The bounded panic and shutdown review could not be completed.", reason: reasons.isEmpty ? nil : reasons.joined(separator: " "), recommendedAction: status == .warning ? "Review the named DiagnosticReports and shutdown evidence, then repeat hardware tests after correcting any software or peripheral cause." : nil, details: details + ["Boot/shutdown history entries: \(last.stdout.split(whereSeparator: \.isNewline).count)"], durationSeconds: Date().timeIntervalSince(started))
    }

    static func servicesHealth(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let predicate = "process == \"launchd\" AND (eventMessage CONTAINS[c] \"exited with abnormal code\" OR eventMessage CONTAINS[c] \"crashed\" OR eventMessage CONTAINS[c] \"throttling respawn\")"
        let logs = command(context, key: "launchd-failure-log", executable: "/usr/bin/log", arguments: ["show", "--last", "7d", "--style", "compact", "--predicate", predicate], timeout: 25)
        let launchctl = command(context, key: "launchctl-system", executable: "/bin/launchctl", arguments: ["print", "system"], timeout: 30)
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
        return DiagnosticResult(category: "macOS", domain: "macOS Maintenance", name: "Failed and repeatedly crashing services", status: status, summary: status == .pass ? "No repeatedly abnormal launchd service pattern was found in the bounded seven-day review." : status == .warning ? "One or more launchd service failures repeated during the review period." : "Service and launchd evidence could not be reviewed completely.", reason: status == .warning ? "\(repeated.count) repeated launchd failure pattern(s) occurred at least three times." : nil, recommendedAction: status == .warning ? "Review the named launchd jobs and their owning applications; do not treat a stopped on-demand service as a failure by itself." : nil, details: repeated.prefix(15).map { "\($0.value)x: \($0.key)" } + ["System launchd inventory size: \(launchctl.stdout.count) characters"], durationSeconds: Date().timeIntervalSince(started))
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

    private struct HTTPMetric {
        let code: Int
        let dns: Double
        let connect: Double
        let tls: Double
        let firstByte: Double
        let total: Double
    }

    private static func parseHTTPMetric(_ result: CommandResult) -> HTTPMetric? {
        let fields = result.stdout.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 6,
              let code = Int(fields[0]),
              let dns = Double(fields[1]),
              let connect = Double(fields[2]),
              let tls = Double(fields[3]),
              let firstByte = Double(fields[4]),
              let total = Double(fields[5]) else { return nil }
        return HTTPMetric(code: code, dns: dns, connect: connect, tls: tls, firstByte: firstByte, total: total)
    }

    private static func averageHTTPTime(_ metrics: [HTTPMetric]) -> String {
        guard !metrics.isEmpty else { return "Not available" }
        return String(format: "%.3f sec", metrics.map(\.total).reduce(0, +) / Double(metrics.count))
    }

    private static func parseWiFiSignal(_ text: String) -> (rssi: Int?, noise: Int?, snr: Int?) {
        let pairPatterns = [
            "(?:Signal / Noise|agrCtlRSSI[^\\n]*agrCtlNoise)[^\\-0-9]*(-?[0-9]+)[^\\-0-9]+(-?[0-9]+)",
            "RSSI[^\\-0-9]*(-?[0-9]+)[^\\n]*Noise[^\\-0-9]*(-?[0-9]+)"
        ]
        for pattern in pairPatterns {
            if let values = regexIntegers(text, pattern: pattern, count: 2) {
                return (values[0], values[1], values[0] - values[1])
            }
        }
        let rssi = regexIntegers(text, pattern: "(?:RSSI|agrCtlRSSI|signal)[^\\-0-9]*(-?[0-9]+)", count: 1)?.first
        let noise = regexIntegers(text, pattern: "(?:Noise|agrCtlNoise)[^\\-0-9]*(-?[0-9]+)", count: 1)?.first
        return (rssi, noise, rssi.flatMap { r in noise.map { r - $0 } })
    }

    private static func regexIntegers(_ text: String, pattern: String, count: Int) -> [Int]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > count else { return nil }
        var values: [Int] = []
        for index in 1...count {
            guard let valueRange = Range(match.range(at: index), in: text), let value = Int(text[valueRange]) else { return nil }
            values.append(value)
        }
        return values
    }

    private static func parseFirstDouble(_ text: String, patterns: [String]) -> Double? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
               let valueRange = Range(match.range(at: 1), in: text), let value = Double(text[valueRange]) { return value }
        }
        return nil
    }

    private static func parseFirstString(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatchingWiFiValue(_ flat: [String: String], keyNeedles: [String]) -> String? {
        flat.sorted { $0.key < $1.key }.first { key, _ in keyNeedles.allSatisfy { key.localizedCaseInsensitiveContains($0) } }?.value
    }

    private static func activeTunnelInterfaces(_ ifconfig: String) -> [String] {
        ifconfig.split(whereSeparator: \.isNewline).compactMap { line in
            let text = String(line)
            guard text.hasPrefix("utun"), text.localizedCaseInsensitiveContains("UP") else { return nil }
            return text.split(separator: ":", maxSplits: 1).first.map(String.init)
        }
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        let lower = text.lowercased()
        return needles.contains(where: { lower.contains($0) })
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
