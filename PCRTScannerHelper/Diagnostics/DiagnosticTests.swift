import Foundation
import Darwin
import PCRTCore

enum DiagnosticTests {
    static func primeCalculation(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        let expected = 78_498
        let actual = DiagnosticAlgorithms.primeCount(upTo: 1_000_000)
        if actual != expected {
            return DiagnosticResult(
                category: "CPU",
                domain: "Hardware Functional",
                name: "CPU prime-number validation",
                status: .fail,
                summary: "The deterministic CPU calculation returned an incorrect result.",
                reason: "Expected \(expected) primes but calculated \(actual).",
                recommendedAction: "Repeat the test and verify the Mac with Apple Diagnostics before replacing hardware.",
                details: ["Validated range: 2 through 1,000,000", "Expected primes: \(expected)", "Calculated primes: \(actual)"],
                durationSeconds: Date().timeIntervalSince(started)
            )
        }
        return DiagnosticResult(
            category: "CPU",
            domain: "Hardware Functional",
            name: "CPU prime-number validation",
            status: .pass,
            summary: "CPU prime-number generation matched the known-correct result.",
            details: ["Validated range: 2 through 1,000,000", "Known-correct prime count: 78,498"],
            durationSeconds: Date().timeIntervalSince(started)
        )
    }

    static func cpuWorkload(_ context: DiagnosticContext) throws -> DiagnosticResult {
        let started = Date()
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let defaultMinutes = context.config.scanType.lowercased() == "burnin" ? 10 : 5
        let requestedMinutes = context.config.cpuStressMinutes > 0 ? context.config.cpuStressMinutes : defaultMinutes
        let minutes = min(max(requestedMinutes, 1), 30)
        let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let group = DispatchGroup()
        let lock = NSLock()
        var batches: UInt64 = 0
        var errors = 0
        var stopThermalMonitor = false
        var thermalCounts: [String: Int] = [:]
        var highestThermalRank = 0
        let input: UInt64 = 10_000
        let expected = DiagnosticAlgorithms.sumOfSquares(input)

        let thermalGroup = DispatchGroup()
        thermalGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { thermalGroup.leave() }
            while true {
                lock.lock()
                let stop = stopThermalMonitor
                lock.unlock()
                if stop { break }

                let state: String
                let rank: Int
                switch ProcessInfo.processInfo.thermalState {
                case .nominal: state = "Nominal"; rank = 0
                case .fair: state = "Fair"; rank = 1
                case .serious: state = "Serious"; rank = 2
                case .critical: state = "Critical"; rank = 3
                @unknown default: state = "Unknown"; rank = 0
                }
                lock.lock()
                thermalCounts[state, default: 0] += 1
                highestThermalRank = max(highestThermalRank, rank)
                lock.unlock()
                Thread.sleep(forTimeInterval: 1)
            }
        }

        for worker in 0..<workers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                var localBatches: UInt64 = 0
                var localErrors = 0
                var state = UInt64(worker + 1) &* 0x9e3779b97f4a7c15
                while Date() < deadline && !context.cancellation.isCancelled {
                    var sum: UInt64 = 0
                    for value in 1...input { sum &+= value &* value }
                    state ^= state << 13; state ^= state >> 7; state ^= state << 17
                    if sum != expected || state == 0 { localErrors += 1 }
                    localBatches &+= 1
                }
                lock.lock()
                batches &+= localBatches
                errors += localErrors
                lock.unlock()
            }
        }
        group.wait()
        lock.lock(); stopThermalMonitor = true; lock.unlock()
        thermalGroup.wait()

        if context.cancellation.isCancelled { throw HelperError.cancelled }
        let peakThermal = ["Nominal", "Fair", "Serious", "Critical"][min(max(highestThermalRank, 0), 3)]
        let thermalDetails = ["Nominal", "Fair", "Serious", "Critical"].map { "Thermal samples \($0.lowercased()): \(thermalCounts[$0, default: 0])" }
        let commonDetails = [
            "Workers: \(workers)",
            "Completed deterministic batches: \(batches)",
            "Calculation errors: \(errors)",
            "Highest thermal pressure observed during workload: \(peakThermal)"
        ] + thermalDetails

        if errors > 0 {
            return DiagnosticResult(
                category: "CPU",
                domain: "Workload Stability",
                name: "Multi-core sustained CPU workload",
                status: .fail,
                summary: "The sustained CPU workload returned one or more calculation errors.",
                reason: "Calculation mismatches: \(errors)",
                recommendedAction: "Repeat the test and verify cooling, power, and CPU stability with Apple Diagnostics.",
                details: commonDetails,
                durationSeconds: Date().timeIntervalSince(started)
            )
        }
        if highestThermalRank >= 2 {
            return DiagnosticResult(
                category: "CPU",
                domain: "Workload Stability",
                name: "Multi-core sustained CPU workload",
                status: .warning,
                summary: "The CPU completed the workload without calculation errors, but macOS reported elevated thermal pressure.",
                reason: "Highest thermal state during the workload: \(peakThermal).",
                recommendedAction: "Check airflow and ambient temperature, allow the Mac to cool, and repeat the workload.",
                details: commonDetails,
                durationSeconds: Date().timeIntervalSince(started)
            )
        }
        return DiagnosticResult(
            category: "CPU",
            domain: "Workload Stability",
            name: "Multi-core sustained CPU workload",
            status: .pass,
            summary: "The CPU sustained a \(minutes)-minute all-core application workload without calculation errors or serious thermal pressure.",
            details: commonDetails,
            durationSeconds: Date().timeIntervalSince(started)
        )
    }

    static func memoryPatterns(_ context: DiagnosticContext) throws -> DiagnosticResult {
        let started = Date()
        let available = availableMemoryBytes()
        let preferredMB = ["hardware", "full", "deep", "burnin"].contains(context.config.scanType.lowercased()) ? 512 : 128
        let safeBytes = min(UInt64(preferredMB) * 1_048_576, max(32 * 1_048_576, available * 35 / 100))
        let wordCount = Int(safeBytes / UInt64(MemoryLayout<UInt64>.size))
        guard wordCount > 0 else {
            return DiagnosticResult(category: "Memory", domain: "Hardware Functional", name: "Application-level memory pattern test", status: .incomplete, summary: "There was not enough safely available memory to run the pattern test.", durationSeconds: Date().timeIntervalSince(started))
        }

        guard let allocation = malloc(wordCount * MemoryLayout<UInt64>.size) else {
            return DiagnosticResult(category: "Memory", domain: "Hardware Functional", name: "Application-level memory pattern test", status: .incomplete, summary: "macOS could not allocate the requested memory test buffer.", reason: "The allocation request was refused; this does not prove a memory failure.", durationSeconds: Date().timeIntervalSince(started))
        }
        let pointer = allocation.bindMemory(to: UInt64.self, capacity: wordCount)
        defer { free(allocation) }

        let patterns: [(String, (Int) -> UInt64)] = [
            ("Bit low", { _ in 0x0000000000000000 }),
            ("Bit high", { _ in 0xffffffffffffffff }),
            ("Checkerboard", { _ in 0xaaaaaaaaaaaaaaaa }),
            ("Inverse checkerboard", { _ in 0x5555555555555555 }),
            ("Walking ones", { index in UInt64(1) << UInt64(index % 64) }),
            ("Walking zeros", { index in ~(UInt64(1) << UInt64(index % 64)) }),
            ("Address-as-data", { index in UInt64(index) &* 0x9e3779b97f4a7c15 }),
            ("Modulo20", { index in index % 20 == 0 ? 0xf0f0f0f0f0f0f0f0 : 0x0f0f0f0f0f0f0f0f }),
            ("Moving inversion", { index in index.isMultiple(of: 2) ? 0x3333333333333333 : 0xcccccccccccccccc }),
            ("Block move", { index in UInt64(index / 256) ^ UInt64(index) }),
            ("Seeded random", { index in
                var state = UInt64(index + 1) &* 0xd1342543de82ef95
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                return state
            })
        ]

        for (name, valueForIndex) in patterns {
            context.logger.write("Memory pattern: \(name)")
            for index in 0..<wordCount {
                if index % 1_048_576 == 0 { try context.cancellation.throwIfCancelled() }
                pointer[index] = valueForIndex(index)
            }
            for index in 0..<wordCount {
                if index % 1_048_576 == 0 { try context.cancellation.throwIfCancelled() }
                let expected = valueForIndex(index)
                let actual = pointer[index]
                if actual != expected {
                    return DiagnosticResult(category: "Memory", domain: "Hardware Functional", name: "Application-level memory pattern test", status: .fail, summary: "A memory pattern mismatch was detected.", reason: "Pattern \(name) mismatched at word \(index): expected \(String(expected, radix: 16)), read \(String(actual, radix: 16)).", recommendedAction: "Repeat the test and run Apple Diagnostics or a bootable memory diagnostic before replacing memory or the logic board.", details: ["Tested \(SystemUtilities.humanBytes(UInt64(wordCount * MemoryLayout<UInt64>.size)))", "This application-level test cannot access memory used by macOS."], durationSeconds: Date().timeIntervalSince(started))
                }
            }
        }
        return DiagnosticResult(category: "Memory", domain: "Hardware Functional", name: "Application-level memory pattern test", status: .pass, summary: "Verified \(SystemUtilities.humanBytes(UInt64(wordCount * MemoryLayout<UInt64>.size))) with 11 deterministic memory patterns without a mismatch.", details: ["Patterns: \(DiagnosticAlgorithms.memoryPatternNames.joined(separator: ", "))", "This test operates only on memory allocated to PCRT and does not replace an offline full-memory diagnostic."], durationSeconds: Date().timeIntervalSince(started))
    }

    static func memoryPressure(_ context: DiagnosticContext) throws -> DiagnosticResult {
        let started = Date()
        let available = availableMemoryBytes()
        let requestedPercent = min(max(context.config.memoryPressurePercent, 10), 80)
        let target = min(available * UInt64(requestedPercent) / 100, 3 * 1024 * 1024 * 1024)
        guard target >= 32 * 1024 * 1024 else {
            return DiagnosticResult(category: "Memory", domain: "Workload Stability", name: "Memory pressure workload", status: .incomplete, summary: "There was not enough safely available memory for the requested workload.", durationSeconds: Date().timeIntervalSince(started))
        }
        let wordCount = Int(target / 8)
        guard let allocation = malloc(wordCount * MemoryLayout<UInt64>.size) else {
            return DiagnosticResult(category: "Memory", domain: "Workload Stability", name: "Memory pressure workload", status: .incomplete, summary: "macOS could not allocate the requested memory-pressure buffer.", reason: "The allocation request was refused; this does not prove a memory failure.", durationSeconds: Date().timeIntervalSince(started))
        }
        let pointer = allocation.bindMemory(to: UInt64.self, capacity: wordCount)
        defer { free(allocation) }
        let duration = context.config.scanType.lowercased() == "burnin" ? 240.0 : 120.0
        let deadline = Date().addingTimeInterval(duration)
        var passes = 0
        while Date() < deadline {
            try context.cancellation.throwIfCancelled()
            for index in 0..<wordCount {
                if index % 1_048_576 == 0 { try context.cancellation.throwIfCancelled() }
                pointer[index] = UInt64(index) ^ UInt64(passes) &* 0x9e3779b97f4a7c15
            }
            for index in 0..<wordCount {
                if index % 1_048_576 == 0 { try context.cancellation.throwIfCancelled() }
                let expected = UInt64(index) ^ UInt64(passes) &* 0x9e3779b97f4a7c15
                if pointer[index] != expected {
                    return DiagnosticResult(category: "Memory", domain: "Workload Stability", name: "Memory pressure workload", status: .fail, summary: "The sustained memory workload detected a data mismatch.", reason: "Verification failed on pass \(passes + 1) at word \(index).", recommendedAction: "Repeat the test and verify memory with Apple Diagnostics.", durationSeconds: Date().timeIntervalSince(started))
                }
            }
            passes += 1
        }
        return DiagnosticResult(category: "Memory", domain: "Workload Stability", name: "Memory pressure workload", status: .pass, summary: "Allocated and repeatedly verified approximately \(SystemUtilities.humanBytes(UInt64(wordCount * 8))) of memory.", details: ["Requested percentage of safely available memory: \(requestedPercent)%", "Verification passes: \(passes)"], durationSeconds: Date().timeIntervalSince(started))
    }

    static func diskWriteRead(_ context: DiagnosticContext) throws -> DiagnosticResult {
        let started = Date()
        context.markWorkloadStart(started)
        let defaultMB = context.config.scanType.lowercased() == "quick" ? 128 : 512
        let sizeMB = min(max(context.config.diskTestMB > 0 ? context.config.diskTestMB : defaultMB, 32), 2048)
        let testURL = context.workspace.appendingPathComponent(".pcrt-disk-test.bin")
        try? FileManager.default.removeItem(at: testURL)
        FileManager.default.createFile(atPath: testURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: testURL) }

        let beforeDisks = MacCollectors.physicalDisks(context, keyPrefix: "storage-workload-before-")
        let beforeByID = Dictionary(uniqueKeysWithValues: beforeDisks.map { ($0.identifier, $0) })
        var writeLatencies: [Double] = []
        var readLatencies: [Double] = []
        var writeIntervals: [Double] = []
        var readIntervals: [Double] = []

        do {
            let handle = try FileHandle(forWritingTo: testURL)
            var writeHasher = SHA256Hasher()
            let writeStarted = Date()
            var intervalStarted = writeStarted
            var intervalBlocks = 0
            for blockIndex in 0..<sizeMB {
                try context.cancellation.throwIfCancelled()
                let block = DiagnosticAlgorithms.deterministicBlock(blockIndex: blockIndex, byteCount: 1_048_576)
                let blockStarted = Date()
                try handle.write(contentsOf: block)
                writeLatencies.append(Date().timeIntervalSince(blockStarted) * 1000)
                writeHasher.update(data: block)
                intervalBlocks += 1
                if intervalBlocks == 64 || blockIndex == sizeMB - 1 {
                    let duration = max(Date().timeIntervalSince(intervalStarted), 0.001)
                    writeIntervals.append(Double(intervalBlocks) / duration)
                    intervalBlocks = 0
                    intervalStarted = Date()
                }
            }
            try handle.synchronize()
            try handle.close()
            let writeDuration = Date().timeIntervalSince(writeStarted)
            let writeHash = writeHasher.finalize().map { String(format: "%02x", $0) }.joined()

            let afterWriteDisks = MacCollectors.physicalDisks(context, keyPrefix: "storage-workload-after-write-")
            let readStarted = Date()
            let readHandle = try FileHandle(forReadingFrom: testURL)
            var readHasher = SHA256Hasher()
            var totalRead = 0
            intervalStarted = readStarted
            intervalBlocks = 0
            while true {
                try context.cancellation.throwIfCancelled()
                let blockStarted = Date()
                let data = try readHandle.read(upToCount: 1_048_576) ?? Data()
                let latency = Date().timeIntervalSince(blockStarted) * 1000
                if data.isEmpty { break }
                readLatencies.append(latency)
                totalRead += data.count
                readHasher.update(data: data)
                intervalBlocks += 1
                if intervalBlocks == 64 || totalRead == sizeMB * 1_048_576 {
                    let duration = max(Date().timeIntervalSince(intervalStarted), 0.001)
                    readIntervals.append(Double(intervalBlocks) / duration)
                    intervalBlocks = 0
                    intervalStarted = Date()
                }
            }
            try readHandle.close()
            let readDuration = Date().timeIntervalSince(readStarted)
            let readHash = readHasher.finalize().map { String(format: "%02x", $0) }.joined()
            let expectedBytes = sizeMB * 1_048_576
            guard totalRead == expectedBytes else {
                return DiagnosticResult(category: "Storage", domain: "Workload Stability", name: "Storage temperature, performance, and SHA-256 workload", status: .fail, summary: "Reading the temporary storage workload file returned incomplete data.", reason: "Read \(totalRead) of \(expectedBytes) bytes.", recommendedAction: "Review APFS and storage evidence, back up important data, and repeat the test.", durationSeconds: Date().timeIntervalSince(started))
            }
            guard writeHash == readHash else {
                return DiagnosticResult(category: "Storage", domain: "Workload Stability", name: "Storage temperature, performance, and SHA-256 workload", status: .fail, summary: "The storage workload SHA-256 hash did not match after reading.", reason: "Written hash \(writeHash); read hash \(readHash).", recommendedAction: "Back up important data and verify the storage device before returning it to service.", durationSeconds: Date().timeIntervalSince(started))
            }

            let afterReadDisks = MacCollectors.physicalDisks(context, keyPrefix: "storage-workload-after-read-")
            var details: [String] = [
                String(format: "Overall write throughput: %.1f MB/s", Double(sizeMB) / max(writeDuration, 0.001)),
                String(format: "Overall read throughput: %.1f MB/s", Double(sizeMB) / max(readDuration, 0.001)),
                String(format: "Write block latency: average %.2f ms, 95th percentile %.2f ms, maximum %.2f ms", average(writeLatencies), percentile(writeLatencies, 0.95), writeLatencies.max() ?? 0),
                String(format: "Read block latency: average %.2f ms, 95th percentile %.2f ms, maximum %.2f ms", average(readLatencies), percentile(readLatencies, 0.95), readLatencies.max() ?? 0),
                String(format: "64 MiB write intervals: minimum %.1f / average %.1f / maximum %.1f MB/s", writeIntervals.min() ?? 0, average(writeIntervals), writeIntervals.max() ?? 0),
                String(format: "64 MiB read intervals: minimum %.1f / average %.1f / maximum %.1f MB/s", readIntervals.min() ?? 0, average(readIntervals), readIntervals.max() ?? 0)
            ]
            var warnings: [String] = []
            var failures: [String] = []
            var rawTemperatures: [JSONValue] = []
            let writeByID = Dictionary(uniqueKeysWithValues: afterWriteDisks.map { ($0.identifier, $0) })
            let readByID = Dictionary(uniqueKeysWithValues: afterReadDisks.map { ($0.identifier, $0) })
            let identifiers = Set(beforeByID.keys).union(writeByID.keys).union(readByID.keys).sorted()
            for identifier in identifiers {
                let before = beforeByID[identifier]
                let afterWrite = writeByID[identifier]
                let afterRead = readByID[identifier]
                let model = before?.model ?? afterWrite?.model ?? afterRead?.model ?? "Unknown drive"
                let beforeTemp = before?.temperatureCelsius
                let writeTemp = afterWrite?.temperatureCelsius
                let readTemp = afterRead?.temperatureCelsius
                details.append("/dev/\(identifier) \(model) temperatures: before \(formatTemperature(beforeTemp)), after write \(formatTemperature(writeTemp)), after read \(formatTemperature(readTemp))")
                let highest = [beforeTemp, writeTemp, readTemp].compactMap { $0 }.max()
                if let highest, highest >= 80 {
                    warnings.append(String(format: "/dev/%@ reached a high workload temperature of %.1f °C.", identifier, highest))
                }
                let beforeMedia = MacCollectors.nvmeCounter(before?.healthValues ?? [:], base: "MEDIA_ERRORS") ?? 0
                let afterMedia = MacCollectors.nvmeCounter(afterRead?.healthValues ?? afterWrite?.healthValues ?? [:], base: "MEDIA_ERRORS") ?? beforeMedia
                let beforeLog = MacCollectors.nvmeCounter(before?.healthValues ?? [:], base: "NUM_ERROR_INFO_LOG_ENTRIES") ?? 0
                let afterLog = MacCollectors.nvmeCounter(afterRead?.healthValues ?? afterWrite?.healthValues ?? [:], base: "NUM_ERROR_INFO_LOG_ENTRIES") ?? beforeLog
                if afterMedia > beforeMedia {
                    failures.append("/dev/\(identifier) recorded new media/data-integrity errors during the storage workload.")
                } else if afterLog > beforeLog {
                    warnings.append("/dev/\(identifier) recorded new NVMe error-log entries during the storage workload.")
                }
                rawTemperatures.append(.object([
                    "device": .string("/dev/\(identifier)"),
                    "before_celsius": beforeTemp.map { .number($0) } ?? .null,
                    "after_write_celsius": writeTemp.map { .number($0) } ?? .null,
                    "after_read_celsius": readTemp.map { .number($0) } ?? .null,
                    "media_errors_before": .number(Double(beforeMedia)),
                    "media_errors_after": .number(Double(afterMedia)),
                    "error_log_entries_before": .number(Double(beforeLog)),
                    "error_log_entries_after": .number(Double(afterLog))
                ]))
            }
            details.append("The temporary workload file was removed.")
            details.append("Throughput is reported as comparative evidence; ordinary model-to-model speed differences are not treated as failures.")

            let status: CheckStatus
            let reason: String?
            if !failures.isEmpty {
                status = .fail
                reason = failures.joined(separator: " ")
            } else if !warnings.isEmpty {
                status = .warning
                reason = warnings.joined(separator: " ")
            } else {
                status = .pass
                reason = nil
            }
            return DiagnosticResult(
                category: "Storage",
                domain: "Workload Stability",
                name: "Storage temperature, performance, and SHA-256 workload",
                status: status,
                summary: status == .pass ? "The temporary storage workload completed with stable interval performance, matching SHA-256 data, and no new native media errors." : status == .warning ? "The storage workload completed with matching data, but temperature or native error-log evidence requires review." : "The storage workload detected a data-integrity or new native media-error failure.",
                reason: reason,
                recommendedAction: status == .fail ? "Back up important data immediately and verify the physical drive before returning it to service." : status == .warning ? "Review storage temperatures and new error-log evidence, confirm backups, and repeat the workload after cooling or correcting enclosure conditions." : nil,
                details: details,
                durationSeconds: Date().timeIntervalSince(started),
                raw: [
                    "write_sha256": .string(writeHash),
                    "read_sha256": .string(readHash),
                    "size_mb": .number(Double(sizeMB)),
                    "write_interval_mbps": .array(writeIntervals.map { .number($0) }),
                    "read_interval_mbps": .array(readIntervals.map { .number($0) }),
                    "drive_snapshots": .array(rawTemperatures)
                ]
            )
        } catch HelperError.cancelled {
            throw HelperError.cancelled
        } catch {
            return DiagnosticResult(category: "Storage", domain: "Workload Stability", name: "Storage temperature, performance, and SHA-256 workload", status: .incomplete, summary: "The temporary storage workload could not be completed.", reason: error.localizedDescription, recommendedAction: "Review free space, APFS, permissions, and storage logs, then repeat the test. A collector error does not prove drive failure.", durationSeconds: Date().timeIntervalSince(started))
        }
    }

    static func physicalDriveRead(_ context: DiagnosticContext) throws -> DiagnosticResult {
        let started = Date()
        context.markWorkloadStart(started)
        let disks = MacCollectors.physicalDisks(context)
        guard !disks.isEmpty else {
            return DiagnosticResult(category: "Storage", domain: "Hardware Functional", name: "Read-only physical-drive sampling", status: .incomplete, summary: "No physical drives were available for read-only sampling.", reason: "macOS did not return a usable whole-disk inventory.", durationSeconds: Date().timeIntervalSince(started))
        }
        let blockSize = 1_048_576
        var hadReadFailure = false
        var openedDrives = 0
        var unavailableDrives = 0
        var details: [String] = []
        var rawRows: [JSONValue] = []
        for disk in disks {
            try context.cancellation.throwIfCancelled()
            let rawPath = "/dev/r\(disk.identifier)"
            let fd = Darwin.open(rawPath, O_RDONLY)
            if fd < 0 {
                unavailableDrives += 1
                let reason = String(cString: strerror(errno))
                details.append("\(rawPath): optional direct raw-device sampling was not available (\(reason)); native SMART/NVMe, partition-map, filesystem, and data-integrity checks remain valid.")
                rawRows.append(.object(["device": .string(rawPath), "unavailable": .bool(true), "reason": .string(reason)]))
                continue
            }
            openedDrives += 1
            defer { Darwin.close(fd) }
            let plan = DiagnosticAlgorithms.driveSampleOffsets(size: disk.sizeBytes, blockSize: UInt64(blockSize))
            var completed = 0
            var errors = 0
            var totalLatency = 0.0
            var maximumLatency = 0.0
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: 4096)
            defer { buffer.deallocate() }
            for offset in plan.offsets {
                try context.cancellation.throwIfCancelled()
                let sampleStart = Date()
                var count: Int
                repeat {
                    count = Darwin.pread(fd, buffer, blockSize, off_t(offset))
                } while count < 0 && errno == EINTR
                let latency = Date().timeIntervalSince(sampleStart) * 1000
                maximumLatency = max(maximumLatency, latency)
                if count != blockSize {
                    errors += 1
                    hadReadFailure = true
                } else {
                    completed += 1
                    totalLatency += latency
                }
            }
            let averageLatency = completed > 0 ? totalLatency / Double(completed) : 0
            details.append(String(format: "%@: %d/%d unique 1 MiB samples, average %.1f ms, maximum %.1f ms, read errors %d", rawPath, completed, plan.offsets.count, averageLatency, maximumLatency, errors))
            rawRows.append(.object(["device": .string(rawPath), "generated_positions": .number(Double(plan.generatedCount)), "unique_positions": .number(Double(plan.offsets.count)), "completed_samples": .number(Double(completed)), "read_errors": .number(Double(errors)), "average_latency_ms": .number(averageLatency), "maximum_latency_ms": .number(maximumLatency)]))
        }
        if hadReadFailure {
            return DiagnosticResult(category: "Storage", domain: "Hardware Functional", name: "Read-only physical-drive sampling", status: .fail, summary: "One or more physical drives opened successfully but returned an error or short read.", reason: "A valid raw-device read did not return the requested 1 MiB data block.", recommendedAction: "Back up affected data and verify the named drive with Apple Diagnostics or the manufacturer diagnostic.", details: details, durationSeconds: Date().timeIntervalSince(started), raw: ["drives": .array(rawRows)])
        }
        if openedDrives == 0 {
            return DiagnosticResult(category: "Storage", domain: "Hardware Functional", name: "Read-only physical-drive sampling", status: .notAvailable, summary: "macOS did not permit optional direct raw-device sampling on the installed physical drive(s).", reason: "Direct /dev/rdisk access is restricted on this Mac. This does not indicate drive failure.", details: details, durationSeconds: Date().timeIntervalSince(started), raw: ["drives": .array(rawRows)])
        }
        if unavailableDrives > 0 {
            return DiagnosticResult(category: "Storage", domain: "Hardware Functional", name: "Read-only physical-drive sampling", status: .info, summary: "Read-only sampling completed on available physical drives; macOS restricted optional direct access to one or more other drives.", details: details, durationSeconds: Date().timeIntervalSince(started), raw: ["drives": .array(rawRows)])
        }
        return DiagnosticResult(category: "Storage", domain: "Hardware Functional", name: "Read-only physical-drive sampling", status: .pass, summary: "Read-only distributed samples completed on \(disks.count) physical drive(s).", details: details, durationSeconds: Date().timeIntervalSince(started), raw: ["drives": .array(rawRows)])
    }

    static func rtcProgression(_ context: DiagnosticContext) -> DiagnosticResult {
        let started = Date()
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let monotonicStart = mach_continuous_time()
        let wallStart = Date()
        for _ in 0..<80 {
            if context.cancellation.isCancelled {
                return DiagnosticResult(category: "System Board", domain: "Hardware Functional", name: "RTC progression consistency", status: .incomplete, summary: "The RTC progression test was cancelled.", durationSeconds: Date().timeIntervalSince(started))
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let monotonicEnd = mach_continuous_time()
        let wallEnd = Date()
        let monotonicSeconds = Double(monotonicEnd - monotonicStart) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        let wallSeconds = wallEnd.timeIntervalSince(wallStart)
        let differenceMS = abs(monotonicSeconds - wallSeconds) * 1000
        let status: CheckStatus = differenceMS <= 250 ? .pass : .warning
        let summary = status == .pass ? "The macOS wall clock advanced consistently with the monotonic clock." : "The wall clock and monotonic clock differed during the short progression test."
        return DiagnosticResult(category: "System Board", domain: "Hardware Functional", name: "RTC progression consistency", status: status, summary: summary, reason: status == .warning ? String(format: "Observed difference: %.1f ms.", differenceMS) : nil, details: [String(format: "Monotonic progression: %.3f seconds", monotonicSeconds), String(format: "Wall-clock progression: %.3f seconds", wallSeconds), "This powered-on progression test is not a CMOS battery test."], durationSeconds: Date().timeIntervalSince(started))
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(max(Int((Double(sorted.count - 1) * fraction).rounded()), 0), sorted.count - 1)
        return sorted[index]
    }

    private static func formatTemperature(_ value: Double?) -> String {
        value.map { String(format: "%.1f °C", $0) } ?? "Not available"
    }

    private static func availableMemoryBytes() -> UInt64 {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return ProcessInfo.processInfo.physicalMemory / 4 }
        let pages = UInt64(stats.free_count + stats.inactive_count + stats.speculative_count)
        return pages * UInt64(pageSize)
    }
}
