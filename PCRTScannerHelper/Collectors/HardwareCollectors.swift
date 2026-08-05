import Foundation
import Darwin
import PCRTCore
import Metal

private struct BatterySnapshot {
    let currentCapacity: Int64?
    let maximumCapacity: Int64?
    let designCapacity: Int64?
    let voltageMillivolts: Int64?
    let amperageMilliamps: Int64?
    let temperatureCelsius: Double?
    let cycleCount: Int64?
    let externalConnected: Bool?
    let isCharging: Bool?
    let fullyCharged: Bool?
    let adapterWatts: Int64?
}

private final class CommandResultBox {
    private let lock = NSLock()
    private var stored: CommandResult?

    func set(_ value: CommandResult) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func get() -> CommandResult? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private struct MetalResources {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let computePipeline: MTLComputePipelineState
    let renderPipeline: MTLRenderPipelineState
    let input: MTLBuffer
    let output: MTLBuffer
    let texture: MTLTexture
    let elementCount: Int
}

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
            details.append("\(device) media/data-integrity errors: \(mediaErrors)")
            details.append("\(device) NVMe error-log entries: \(errorEntries)")
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
        let first = batterySnapshot(context, key: "ioreg-battery-initial")
        let flat = profiler.1.map { SystemUtilities.flatten($0) } ?? [:]
        let combinedProfiler = flat.values.joined(separator: " ")
        let condition = firstMatchingValue(flat, keyContainsAny: ["battery_health", "condition"]) ?? "Not reported"
        let maximumCapacityPercent = parsePercentage(firstMatchingValue(flat, keyContainsAny: ["maximum_capacity"]) ?? "")
        let batteryPresent = first != nil || !pmset.stdout.localizedCaseInsensitiveContains("No batteries") && flat.keys.contains(where: { $0.localizedCaseInsensitiveContains("battery") })

        guard batteryPresent else {
            context.appendInventory(InventorySection(title: "Battery and power", items: ["Current power": SystemUtilities.trimmed(pmset.stdout), "Power source": SystemUtilities.trimmed(powerSource.stdout)]))
            return DiagnosticResult(category: "Power", domain: "Network / Power", name: "Expanded battery health and charging observation", status: .notApplicable, summary: "This Mac does not report an installed battery.", durationSeconds: Date().timeIntervalSince(started))
        }

        var samples: [BatterySnapshot] = first.map { [$0] } ?? []
        let shouldObserveCharging = first?.externalConnected == true && first?.fullyCharged != true
        if shouldObserveCharging {
            for index in 1...6 {
                for _ in 0..<10 {
                    if context.cancellation.isCancelled {
                        return DiagnosticResult(category: "Power", domain: "Network / Power", name: "Expanded battery health and charging observation", status: .incomplete, summary: "The battery observation was cancelled.", durationSeconds: Date().timeIntervalSince(started))
                    }
                    Thread.sleep(forTimeInterval: 1)
                }
                if let sample = batterySnapshot(context, key: "ioreg-battery-observation-\(index)") { samples.append(sample) }
            }
        }

        let final = samples.last ?? first
        var details: [String] = [
            "macOS battery condition: \(condition)",
            "Current power source: \(SystemUtilities.firstLine(pmset.combinedOutput))"
        ]
        if let maximumCapacityPercent { details.append("Maximum capacity: \(maximumCapacityPercent)%") }
        if let value = final?.cycleCount { details.append("Cycle count: \(value)") }
        if let value = final?.designCapacity { details.append("Design capacity: \(value) mAh") }
        if let value = final?.maximumCapacity { details.append("Full-charge capacity: \(value) mAh") }
        if let value = final?.currentCapacity { details.append("Current capacity: \(value) mAh") }
        if let value = final?.voltageMillivolts { details.append("Battery voltage: \(value) mV") }
        if let value = final?.amperageMilliamps { details.append("Battery current: \(value) mA") }
        if let value = final?.temperatureCelsius { details.append(String(format: "Battery temperature: %.1f °C", value)) }
        if let value = final?.adapterWatts { details.append("Connected adapter rating: \(value) W") }
        if let value = final?.externalConnected { details.append("External power connected: \(value ? "Yes" : "No")") }
        if let value = final?.isCharging { details.append("Charging: \(value ? "Yes" : "No")") }
        if samples.count > 1, let initialCapacity = samples.first?.currentCapacity, let finalCapacity = samples.last?.currentCapacity {
            let elapsed = max(Date().timeIntervalSince(started), 1)
            let delta = finalCapacity - initialCapacity
            let hourlyRate = Double(delta) * 3600.0 / elapsed
            details.append("Observed capacity change over approximately \(Int(elapsed.rounded())) seconds: \(delta) mAh")
            details.append(String(format: "Estimated short-window charge/discharge rate: %.0f mAh/hour", hourlyRate))
        } else {
            details.append("A 60-second charging observation was not required because external power was absent or the battery was already full.")
        }

        var warnings: [String] = []
        let lowerCondition = (condition + " " + combinedProfiler).lowercased()
        if lowerCondition.contains("service recommended") || lowerCondition.contains("service battery") || lowerCondition.contains("replace soon") || lowerCondition.contains("replace now") || lowerCondition.contains("check battery") {
            warnings.append("macOS reported a battery service or replacement condition.")
        }
        if let maximumCapacityPercent, maximumCapacityPercent < 80 {
            warnings.append("Maximum battery capacity is below 80% of the original rating.")
        }
        if let temperature = final?.temperatureCelsius, temperature >= 50 {
            warnings.append(String(format: "Battery temperature was elevated at %.1f °C.", temperature))
        }
        if let initial = samples.first, let final,
           final.externalConnected == true,
           final.fullyCharged != true,
           final.isCharging != true,
           let currentCapacity = final.currentCapacity,
           let initialCapacity = initial.currentCapacity,
           currentCapacity < initialCapacity,
           (final.amperageMilliamps ?? 0) < -500 {
            warnings.append("The battery discharged while external power was connected.")
        }

        let status: CheckStatus
        if !warnings.isEmpty { status = .warning }
        else if profiler.0.exitCode != 0 && first == nil { status = .incomplete }
        else { status = .pass }

        context.appendInventory(InventorySection(
            title: "Battery and power",
            items: [
                "Condition": condition,
                "Maximum capacity": maximumCapacityPercent.map { "\($0)%" } ?? "Not reported",
                "Cycle count": final?.cycleCount.map { String($0) } ?? "Not reported",
                "Battery temperature": final?.temperatureCelsius.map { String(format: "%.1f °C", $0) } ?? "Not available",
                "Adapter": final?.adapterWatts.map { "\($0) W" } ?? "Not reported",
                "Current power": SystemUtilities.trimmed(pmset.stdout)
            ]
        ))

        return DiagnosticResult(
            category: "Power",
            domain: "Network / Power",
            name: "Expanded battery health and charging observation",
            status: status,
            summary: status == .pass ? "Battery health, capacity, temperature, power-source, and available charging evidence did not show an obvious problem." : status == .warning ? "One or more battery or charging indicators require review." : "Battery health evidence could not be collected completely.",
            reason: warnings.isEmpty ? nil : warnings.joined(separator: " "),
            recommendedAction: status == .warning ? "Confirm battery condition and adapter operation in System Settings or Apple Diagnostics before replacing the battery or charger." : nil,
            details: details,
            durationSeconds: Date().timeIntervalSince(started),
            raw: [
                "sample_count": .number(Double(samples.count)),
                "maximum_capacity_percent": maximumCapacityPercent.map { .number(Double($0)) } ?? .null,
                "condition": .string(condition)
            ]
        )
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
            capabilities.append(device.hasUnifiedMemory ? "Unified memory" : "Discrete memory")
            metalRows.append([device.name, String(device.registryID), capabilities.joined(separator: ", ")])
        }
        context.appendInventory(InventorySection(title: "GPU, displays, and Metal", items: ["Display/GPU entries": "\(displayCount)", "Metal devices": "\(devices.count)"], tables: [InventoryTable(title: "Metal devices", columns: ["Name", "Registry ID", "Capabilities"], rows: metalRows)]))
        let status: CheckStatus
        if displays.0.exitCode == 0 && !devices.isEmpty { status = .info }
        else if displays.0.exitCode == 0 || !devices.isEmpty { status = .incomplete }
        else { status = .notAvailable }
        return DiagnosticResult(category: "Display", domain: "Hardware Functional", name: "GPU, display, and Metal capability inventory", status: status, summary: status == .info ? "Collected graphics adapter, display, and Metal capability information." : status == .incomplete ? "Graphics inventory was partially available." : "Graphics and Metal capability information was not available.", reason: status == .incomplete ? "One graphics inventory source was unavailable; no GPU failure is inferred." : nil, details: metalRows.map { "\($0[0]): \($0[2])" }, durationSeconds: Date().timeIntervalSince(started))
    }

    static func gpuFunctionalWorkload(_ context: DiagnosticContext) throws -> DiagnosticResult {
        let started = Date()
        context.markWorkloadStart(started)
        let devices = MTLCopyAllDevices()
        guard !devices.isEmpty else {
            return DiagnosticResult(category: "GPU", domain: "Hardware Functional", name: "Metal GPU functional and sustained workload", status: .notAvailable, summary: "No Metal-capable GPU was exposed by macOS.", durationSeconds: Date().timeIntervalSince(started))
        }

        var details: [String] = []
        var rawDevices: [JSONValue] = []
        var initializationFailures: [String] = []
        var functionalFailures: [String] = []
        var resourcesByRegistry: [UInt64: MetalResources] = [:]

        for device in devices {
            do {
                let resources = try makeMetalResources(device: device)
                resourcesByRegistry[device.registryID] = resources
                let result = try runMetalCommand(resources: resources, seed: 1, validate: true)
                details.append("\(device.name): compute and offscreen-render validation passed (\(result.validatedComputeValues) compute values; \(result.validatedRenderPixels) render pixels).")
                rawDevices.append(.object([
                    "name": .string(device.name),
                    "registry_id": .number(Double(device.registryID)),
                    "functional_validation": .bool(true)
                ]))
            } catch {
                initializationFailures.append("\(device.name): \(error.localizedDescription)")
                rawDevices.append(.object([
                    "name": .string(device.name),
                    "registry_id": .number(Double(device.registryID)),
                    "functional_validation": .bool(false),
                    "error": .string(error.localizedDescription)
                ]))
            }
        }

        let selectedResources: MetalResources?
        if let defaultDevice = MTLCreateSystemDefaultDevice(), let defaultResources = resourcesByRegistry[defaultDevice.registryID] {
            selectedResources = defaultResources
        } else {
            selectedResources = resourcesByRegistry.values.first
        }
        guard let resources = selectedResources else {
            return DiagnosticResult(
                category: "GPU",
                domain: "Hardware Functional",
                name: "Metal GPU functional and sustained workload",
                status: .incomplete,
                summary: "Metal devices were detected, but a usable default workload device could not be initialized.",
                reason: initializationFailures.joined(separator: " "),
                details: details + initializationFailures,
                durationSeconds: Date().timeIntervalSince(started),
                raw: ["metal_devices": .array(rawDevices)]
            )
        }

        let duration = gpuWorkloadDuration(context)
        let deadline = Date().addingTimeInterval(duration)
        let telemetryBox = CommandResultBox()
        let telemetryGroup = DispatchGroup()
        let telemetryStarted = FileManager.default.isExecutableFile(atPath: "/usr/bin/powermetrics")
        if telemetryStarted {
            telemetryGroup.enter()
            let sampleCount = min(max(Int(duration.rounded(.up)) + 3, 5), 1_805)
            DispatchQueue.global(qos: .utility).async {
                let result = context.commandRunner.run(
                    "/usr/bin/powermetrics",
                    ["-n", "\(sampleCount)", "-i", "1000", "--samplers", "gpu_power,thermal", "--show-plimits"],
                    timeout: duration + 20
                )
                telemetryBox.set(result)
                telemetryGroup.leave()
            }
        }

        var commandBuffers = 0
        var computeValidations = 0
        var renderValidations = 0
        var seed: UInt32 = 2
        var thermalCounts: [String: Int] = [:]
        var highestThermalRank = 0

        while Date() < deadline {
            try context.cancellation.throwIfCancelled()
            let validate = commandBuffers % 20 == 0
            do {
                let result = try runMetalCommand(resources: resources, seed: seed, validate: validate)
                if validate {
                    computeValidations += result.validatedComputeValues
                    renderValidations += result.validatedRenderPixels
                }
            } catch {
                functionalFailures.append(error.localizedDescription)
                break
            }
            commandBuffers += 1
            seed &+= 1
            let thermal = thermalStateAndRank(ProcessInfo.processInfo.thermalState)
            thermalCounts[thermal.name, default: 0] += 1
            highestThermalRank = max(highestThermalRank, thermal.rank)
        }

        if functionalFailures.isEmpty {
            do {
                let result = try runMetalCommand(resources: resources, seed: seed, validate: true)
                computeValidations += result.validatedComputeValues
                renderValidations += result.validatedRenderPixels
                commandBuffers += 1
            } catch {
                functionalFailures.append(error.localizedDescription)
            }
        }

        if telemetryStarted {
            if telemetryGroup.wait(timeout: .now() + duration + 25) == .success,
               let telemetry = telemetryBox.get() {
                context.recordCommand("powermetrics-gpu-workload", telemetry)
                let telemetryLines = hardwareTelemetryLines(telemetry.combinedOutput)
                details.append(contentsOf: telemetryLines.prefix(80))
                if telemetry.exitCode != 0 && telemetryLines.isEmpty {
                    details.append("Concurrent GPU power/frequency telemetry was unavailable: \(SystemUtilities.firstLine(telemetry.combinedOutput))")
                }
            } else {
                details.append("Concurrent GPU power/frequency telemetry did not finish within its bounded collection window.")
            }
        } else {
            details.append("powermetrics was not available for concurrent GPU power/frequency telemetry.")
        }

        let highestThermal = ["Nominal", "Fair", "Serious", "Critical"][min(max(highestThermalRank, 0), 3)]
        details.insert("Stress device: \(resources.device.name)", at: 0)
        details.insert(String(format: "Requested workload duration: %.0f seconds", duration), at: 1)
        details.insert("Completed Metal command buffers: \(commandBuffers)", at: 2)
        details.insert("Validated compute values: \(computeValidations)", at: 3)
        details.insert("Validated render pixels: \(renderValidations)", at: 4)
        details.insert("Highest thermal pressure during GPU workload: \(highestThermal)", at: 5)
        for name in ["Nominal", "Fair", "Serious", "Critical"] {
            details.append("GPU workload thermal samples \(name.lowercased()): \(thermalCounts[name, default: 0])")
        }
        details.append(contentsOf: initializationFailures.map { "Additional Metal device initialization: \($0)" })

        let status: CheckStatus
        var reason: String?
        if !functionalFailures.isEmpty {
            status = .fail
            reason = functionalFailures.joined(separator: " ")
        } else if commandBuffers == 0 {
            status = .incomplete
            reason = "The Metal workload did not complete a command buffer."
        } else if highestThermalRank >= 2 {
            status = .warning
            reason = "macOS reached \(highestThermal) thermal pressure during the GPU workload."
        } else if resourcesByRegistry.count < devices.count {
            status = .warning
            reason = "At least one additional Metal device could not complete functional initialization."
        } else {
            status = .pass
        }

        return DiagnosticResult(
            category: "GPU",
            domain: "Workload Stability",
            name: "Metal GPU functional and sustained workload",
            status: status,
            summary: status == .pass ? "Metal compute and offscreen rendering completed with deterministic validation and no command-buffer errors." : status == .warning ? "The Metal workload completed, but thermal pressure or an additional GPU device requires review." : status == .fail ? "The Metal workload produced a command, compute, or render validation failure." : "The Metal workload could not be completed.",
            reason: reason,
            recommendedAction: status == .fail ? "Repeat the test after a restart and verify the Mac with Apple Diagnostics before concluding that the GPU or logic board has failed." : status == .warning ? "Check airflow, connected displays or eGPUs, and repeat the workload after the Mac returns to nominal thermal pressure." : nil,
            details: details,
            durationSeconds: Date().timeIntervalSince(started),
            raw: [
                "metal_devices": .array(rawDevices),
                "command_buffers": .number(Double(commandBuffers)),
                "compute_validations": .number(Double(computeValidations)),
                "render_validations": .number(Double(renderValidations)),
                "highest_thermal_pressure": .string(highestThermal)
            ]
        )
    }

    static func externalDriveHealth(_ context: DiagnosticContext) throws -> DiagnosticResult {
        let started = Date()
        context.markWorkloadStart(started)
        let beforeDisks = physicalDisks(context, keyPrefix: "external-before-").filter { !$0.internalDisk || $0.removable }
        let volumes = mountedExternalVolumes(context)
        guard !beforeDisks.isEmpty || !volumes.isEmpty else {
            return DiagnosticResult(category: "Storage", domain: "Hardware Functional", name: "External-drive health and temporary integrity test", status: .notApplicable, summary: "No external physical drive or mounted external volume was present during the scan.", durationSeconds: Date().timeIntervalSince(started))
        }

        var details: [String] = []
        var failures: [String] = []
        var warnings: [String] = []
        var successfulWrites = 0
        var unavailableWrites = 0
        var rawVolumes: [JSONValue] = []

        for disk in beforeDisks {
            let smart = disk.smartStatus ?? "Not reported"
            let mediaErrors = nvmeCounter(disk.healthValues, base: "MEDIA_ERRORS") ?? 0
            let critical = nvmeCounter(disk.healthValues, base: "CRITICAL_WARNING") ?? 0
            details.append("/dev/\(disk.identifier) \(disk.model): \(disk.busProtocol), \(SystemUtilities.humanBytes(disk.sizeBytes)), SMART \(smart), media errors \(mediaErrors)")
            if let temperature = disk.temperatureCelsius { details.append(String(format: "/dev/%@ external-drive temperature: %.1f °C", disk.identifier, temperature)) }
            if smart.lowercased().contains("fail") || critical != 0 || mediaErrors > 0 {
                failures.append("/dev/\(disk.identifier) reported native external-drive failure evidence.")
            }
        }

        for volume in volumes {
            try context.cancellation.throwIfCancelled()
            details.append("\(volume.mountPoint): \(volume.name), \(volume.filesystem), parent \(volume.parentWholeDisk), writable \(volume.writable ? "Yes" : "No"), free \(SystemUtilities.humanBytes(volume.availableBytes))")
            guard volume.writable, volume.availableBytes >= 256 * 1024 * 1024 else {
                unavailableWrites += 1
                rawVolumes.append(.object([
                    "mount_point": .string(volume.mountPoint),
                    "name": .string(volume.name),
                    "write_test": .string("Not available")
                ]))
                continue
            }

            let sizeMB = context.config.scanType.lowercased() == "burnin" ? 128 : 64
            do {
                let result = try externalVolumeIntegrityTest(context, volume: volume, sizeMB: sizeMB)
                successfulWrites += 1
                details.append(contentsOf: result.details)
                rawVolumes.append(.object([
                    "mount_point": .string(volume.mountPoint),
                    "name": .string(volume.name),
                    "write_test": .string("Pass"),
                    "size_mb": .number(Double(sizeMB)),
                    "write_mbps": .number(result.writeMBps),
                    "read_mbps": .number(result.readMBps)
                ]))
            } catch HelperError.cancelled {
                throw HelperError.cancelled
            } catch {
                let text = error.localizedDescription
                let nsError = error as NSError
                if nsError.domain == "PCRTExternalStorage" && (nsError.code == 1 || nsError.code == 2) {
                    failures.append("\(volume.mountPoint) failed temporary external-volume data-integrity verification: \(text)")
                } else {
                    warnings.append("\(volume.mountPoint) could not complete the temporary external-volume integrity test: \(text)")
                }
                rawVolumes.append(.object([
                    "mount_point": .string(volume.mountPoint),
                    "name": .string(volume.name),
                    "write_test": .string(nsError.domain == "PCRTExternalStorage" ? "Fail" : "Warning"),
                    "error": .string(text)
                ]))
            }
        }

        let afterDisks = physicalDisks(context, keyPrefix: "external-after-").filter { !$0.internalDisk || $0.removable }
        let beforeByID = Dictionary(uniqueKeysWithValues: beforeDisks.map { ($0.identifier, $0) })
        for disk in afterDisks {
            if let temperature = disk.temperatureCelsius, temperature >= 80 {
                warnings.append(String(format: "/dev/%@ reached a high external-drive temperature of %.1f °C.", disk.identifier, temperature))
            }
            guard let before = beforeByID[disk.identifier] else { continue }
            let beforeMedia = nvmeCounter(before.healthValues, base: "MEDIA_ERRORS") ?? 0
            let afterMedia = nvmeCounter(disk.healthValues, base: "MEDIA_ERRORS") ?? 0
            let beforeLog = nvmeCounter(before.healthValues, base: "NUM_ERROR_INFO_LOG_ENTRIES") ?? 0
            let afterLog = nvmeCounter(disk.healthValues, base: "NUM_ERROR_INFO_LOG_ENTRIES") ?? 0
            if afterMedia > beforeMedia {
                failures.append("/dev/\(disk.identifier) recorded new media/data-integrity errors during the external-drive workload.")
            } else if afterLog > beforeLog {
                warnings.append("/dev/\(disk.identifier) recorded new NVMe error-log entries during the external-drive workload.")
            }
        }

        let status: CheckStatus
        if !failures.isEmpty { status = .fail }
        else if !warnings.isEmpty { status = .warning }
        else if successfulWrites > 0 { status = .pass }
        else if !beforeDisks.isEmpty { status = .info }
        else { status = .notAvailable }

        if unavailableWrites > 0 {
            details.append("Temporary write/read testing was not attempted on \(unavailableWrites) read-only, permission-restricted, or low-free-space external volume(s).")
        }
        details.append("PCRT created only uniquely named temporary files and removed them after verification.")

        return DiagnosticResult(
            category: "Storage",
            domain: "Hardware Functional",
            name: "External-drive health and temporary integrity test",
            status: status,
            summary: status == .pass ? "Connected external storage completed native health review and temporary write/read/hash verification." : status == .info ? "External physical-drive health was collected, but no writable mounted volume was available for the temporary integrity test." : status == .notAvailable ? "External storage was detected, but functional testing was unavailable." : status == .warning ? "One or more external-drive indicators require review." : "An external drive produced confirmed native or data-integrity failure evidence.",
            reason: !failures.isEmpty ? failures.joined(separator: " ") : !warnings.isEmpty ? warnings.joined(separator: " ") : nil,
            recommendedAction: status == .fail ? "Back up the affected external drive immediately and verify the enclosure, cable, port, and media before returning it to service." : status == .warning ? "Review the named external volume, cable, port, free space, and native health evidence, then repeat the test." : nil,
            details: details,
            durationSeconds: Date().timeIntervalSince(started),
            raw: ["external_volumes": .array(rawVolumes)]
        )
    }

    private static func batterySnapshot(_ context: DiagnosticContext, key: String) -> BatterySnapshot? {
        let result = command(context, key: key, executable: "/usr/sbin/ioreg", arguments: ["-r", "-c", "AppleSmartBattery", "-a"], timeout: 20)
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let dictionary = batteryDictionary(data) else { return nil }
        let adapter = dictionary["AdapterDetails"] as? [String: Any]
        return BatterySnapshot(
            currentCapacity: numericInt64(dictionary["CurrentCapacity"]),
            maximumCapacity: numericInt64(dictionary["MaxCapacity"]),
            designCapacity: numericInt64(dictionary["DesignCapacity"]),
            voltageMillivolts: numericInt64(dictionary["Voltage"]),
            amperageMilliamps: numericInt64(dictionary["Amperage"]),
            temperatureCelsius: batteryTemperatureCelsius(numericInt64(dictionary["Temperature"])),
            cycleCount: numericInt64(dictionary["CycleCount"]),
            externalConnected: booleanValue(dictionary["ExternalConnected"]),
            isCharging: booleanValue(dictionary["IsCharging"]),
            fullyCharged: booleanValue(dictionary["FullyCharged"]),
            adapterWatts: numericInt64(adapter?["Watts"])
        )
    }

    private static func batteryTemperatureCelsius(_ raw: Int64?) -> Double? {
        guard let raw else { return nil }
        let value = Double(raw)
        if value >= 2_000 && value <= 5_000 { return value / 10.0 - 273.15 }
        if value >= 200 && value <= 500 { return value - 273.15 }
        if value >= 0 && value <= 100 { return value }
        return nil
    }

    private static func firstMatchingValue(_ flat: [String: String], keyContainsAny needles: [String]) -> String? {
        flat.sorted { $0.key < $1.key }.first { key, _ in needles.contains(where: { key.localizedCaseInsensitiveContains($0) }) }?.value
    }

    private static func parsePercentage(_ text: String) -> Int? {
        parseInteger(from: text, pattern: "([0-9]{1,3})\\s*%")
    }

    private static func makeMetalResources(device: MTLDevice) throws -> MetalResources {
        enum MetalSetupError: LocalizedError {
            case queue
            case function(String)
            case buffer
            case texture
            var errorDescription: String? {
                switch self {
                case .queue: return "Metal command queue creation failed."
                case .function(let name): return "Metal shader function \(name) was not created."
                case .buffer: return "Metal validation buffers could not be allocated."
                case .texture: return "Metal validation texture could not be allocated."
                }
            }
        }

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void pcrt_compute(const device uint *input [[buffer(0)]],
                                 device uint *output [[buffer(1)]],
                                 constant uint &seed [[buffer(2)]],
                                 uint id [[thread_position_in_grid]]) {
            uint value = input[id] ^ seed ^ 0xA5A5A5A5u;
            for (uint round = 0; round < 64; ++round) {
                value = value * 1664525u + 1013904223u + round;
            }
            output[id] = value;
        }

        struct PCRTVertexOut { float4 position [[position]]; };
        vertex PCRTVertexOut pcrt_vertex(uint id [[vertex_id]]) {
            const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
            PCRTVertexOut out;
            out.position = float4(positions[id], 0.0, 1.0);
            return out;
        }
        fragment float4 pcrt_fragment() { return float4(0.25, 0.50, 0.75, 1.0); }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        guard let computeFunction = library.makeFunction(name: "pcrt_compute") else { throw MetalSetupError.function("pcrt_compute") }
        guard let vertexFunction = library.makeFunction(name: "pcrt_vertex") else { throw MetalSetupError.function("pcrt_vertex") }
        guard let fragmentFunction = library.makeFunction(name: "pcrt_fragment") else { throw MetalSetupError.function("pcrt_fragment") }
        guard let queue = device.makeCommandQueue() else { throw MetalSetupError.queue }
        let computePipeline = try device.makeComputePipelineState(function: computeFunction)
        let renderDescriptor = MTLRenderPipelineDescriptor()
        renderDescriptor.vertexFunction = vertexFunction
        renderDescriptor.fragmentFunction = fragmentFunction
        renderDescriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let renderPipeline = try device.makeRenderPipelineState(descriptor: renderDescriptor)

        let elementCount = 262_144
        let byteCount = elementCount * MemoryLayout<UInt32>.size
        guard let input = device.makeBuffer(length: byteCount, options: .storageModeShared),
              let output = device.makeBuffer(length: byteCount, options: .storageModeShared) else { throw MetalSetupError.buffer }
        let pointer = input.contents().bindMemory(to: UInt32.self, capacity: elementCount)
        for index in 0..<elementCount {
            pointer[index] = UInt32(truncatingIfNeeded: UInt64(index + 1) &* 2_654_435_761)
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1024, height: 1024, mipmapped: false)
        textureDescriptor.usage = [.renderTarget]
        textureDescriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { throw MetalSetupError.texture }
        return MetalResources(device: device, queue: queue, computePipeline: computePipeline, renderPipeline: renderPipeline, input: input, output: output, texture: texture, elementCount: elementCount)
    }

    private static func runMetalCommand(resources: MetalResources, seed: UInt32, validate: Bool) throws -> (validatedComputeValues: Int, validatedRenderPixels: Int) {
        enum MetalRunError: LocalizedError {
            case commandBuffer
            case encoder
            case commandFailure(String)
            case computeMismatch(Int)
            case renderMismatch
            var errorDescription: String? {
                switch self {
                case .commandBuffer: return "Metal command-buffer creation failed."
                case .encoder: return "Metal command encoder creation failed."
                case .commandFailure(let message): return "Metal command buffer failed: \(message)"
                case .computeMismatch(let index): return "Metal compute validation mismatch at element \(index)."
                case .renderMismatch: return "Metal offscreen-render validation returned an unexpected pixel value."
                }
            }
        }

        guard let commandBuffer = resources.queue.makeCommandBuffer(),
              let compute = commandBuffer.makeComputeCommandEncoder() else { throw MetalRunError.commandBuffer }
        compute.setComputePipelineState(resources.computePipeline)
        compute.setBuffer(resources.input, offset: 0, index: 0)
        compute.setBuffer(resources.output, offset: 0, index: 1)
        var mutableSeed = seed
        compute.setBytes(&mutableSeed, length: MemoryLayout<UInt32>.size, index: 2)
        let width = resources.computePipeline.threadExecutionWidth
        let threadsPerGroup = MTLSize(width: width, height: 1, depth: 1)
        let grid = MTLSize(width: resources.elementCount, height: 1, depth: 1)
        compute.dispatchThreads(grid, threadsPerThreadgroup: threadsPerGroup)
        compute.endEncoding()

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = resources.texture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let render = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { throw MetalRunError.encoder }
        render.setRenderPipelineState(resources.renderPipeline)
        render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        render.endEncoding()
        if resources.texture.storageMode == .managed, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: resources.texture)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw MetalRunError.commandFailure(commandBuffer.error?.localizedDescription ?? "status \(String(describing: commandBuffer.status))")
        }

        guard validate else { return (0, 0) }
        let input = resources.input.contents().bindMemory(to: UInt32.self, capacity: resources.elementCount)
        let output = resources.output.contents().bindMemory(to: UInt32.self, capacity: resources.elementCount)
        let stride = max(resources.elementCount / 64, 1)
        var validated = 0
        for index in Swift.stride(from: 0, to: resources.elementCount, by: stride) {
            var expected = input[index] ^ seed ^ 0xA5A5A5A5
            for round in 0..<64 {
                expected = expected &* 1_664_525 &+ 1_013_904_223 &+ UInt32(round)
            }
            if output[index] != expected { throw MetalRunError.computeMismatch(index) }
            validated += 1
        }

        var pixels = [UInt8](repeating: 0, count: resources.texture.width * resources.texture.height * 4)
        pixels.withUnsafeMutableBytes { raw in
            resources.texture.getBytes(raw.baseAddress!, bytesPerRow: resources.texture.width * 4, from: MTLRegionMake2D(0, 0, resources.texture.width, resources.texture.height), mipmapLevel: 0)
        }
        let expectedPixel: [UInt8] = [64, 128, 191, 255]
        let sampleOffsets = [
            0,
            ((resources.texture.height / 2) * resources.texture.width + resources.texture.width / 2) * 4,
            (resources.texture.height * resources.texture.width - 1) * 4
        ]
        for offset in sampleOffsets {
            let pixel = Array(pixels[offset..<(offset + 4)])
            let matches = zip(pixel, expectedPixel).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 1 }
            if !matches { throw MetalRunError.renderMismatch }
        }
        return (validated, sampleOffsets.count)
    }

    private static func gpuWorkloadDuration(_ context: DiagnosticContext) -> TimeInterval {
        if context.config.gpuStressMinutes > 0 {
            return TimeInterval(min(max(context.config.gpuStressMinutes, 1), 30) * 60)
        }
        switch context.config.scanType.lowercased().replacingOccurrences(of: "-", with: "") {
        case "burnin": return 600
        case "full", "deep", "hardware", "gpu", "thermal": return 180
        default: return 30
        }
    }

    private static func thermalStateAndRank(_ state: ProcessInfo.ThermalState) -> (name: String, rank: Int) {
        switch state {
        case .nominal: return ("Nominal", 0)
        case .fair: return ("Fair", 1)
        case .serious: return ("Serious", 2)
        case .critical: return ("Critical", 3)
        @unknown default: return ("Unknown", 0)
        }
    }

    private static func hardwareTelemetryLines(_ output: String) -> [String] {
        let needles = ["gpu power", "gpu active", "gpu frequency", "thermal pressure", "pressure level", "plimit", "limit"]
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).map(String.init).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            guard !trimmed.isEmpty, needles.contains(where: { lower.contains($0) }), seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    private static func externalVolumeIntegrityTest(_ context: DiagnosticContext, volume: MountedExternalVolume, sizeMB: Int) throws -> (writeMBps: Double, readMBps: Double, details: [String]) {
        let folder = URL(fileURLWithPath: volume.mountPoint, isDirectory: true).appendingPathComponent(".pcrt-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("temporary-integrity-test.bin")
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let writeHandle = try FileHandle(forWritingTo: file)
        var writeHasher = SHA256Hasher()
        let writeStarted = Date()
        for blockIndex in 0..<sizeMB {
            try context.cancellation.throwIfCancelled()
            let data = DiagnosticAlgorithms.deterministicBlock(blockIndex: blockIndex, byteCount: 1_048_576)
            try writeHandle.write(contentsOf: data)
            writeHasher.update(data: data)
        }
        try writeHandle.synchronize()
        try writeHandle.close()
        let writeDuration = max(Date().timeIntervalSince(writeStarted), 0.001)
        let expectedHash = writeHasher.finalize().map { String(format: "%02x", $0) }.joined()

        let readHandle = try FileHandle(forReadingFrom: file)
        let readStarted = Date()
        var readHasher = SHA256Hasher()
        var bytesRead = 0
        while true {
            try context.cancellation.throwIfCancelled()
            let data = try readHandle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            bytesRead += data.count
            readHasher.update(data: data)
        }
        try readHandle.close()
        let readDuration = max(Date().timeIntervalSince(readStarted), 0.001)
        let actualHash = readHasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard bytesRead == sizeMB * 1_048_576 else {
            throw NSError(domain: "PCRTExternalStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Read \(bytesRead) of \(sizeMB * 1_048_576) expected bytes."])
        }
        guard actualHash == expectedHash else {
            throw NSError(domain: "PCRTExternalStorage", code: 2, userInfo: [NSLocalizedDescriptionKey: "The external-volume SHA-256 hash did not match after reading."])
        }
        let writeMBps = Double(sizeMB) / writeDuration
        let readMBps = Double(sizeMB) / readDuration
        return (
            writeMBps,
            readMBps,
            [
                String(format: "%@ temporary %d MB write throughput: %.1f MB/s", volume.mountPoint, sizeMB, writeMBps),
                String(format: "%@ temporary %d MB read throughput: %.1f MB/s", volume.mountPoint, sizeMB, readMBps),
                "\(volume.mountPoint) temporary write/read SHA-256 verification: Pass"
            ]
        )
    }
}
