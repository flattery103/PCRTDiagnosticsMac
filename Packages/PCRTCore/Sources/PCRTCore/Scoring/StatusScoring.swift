import Foundation

public enum StatusScoring {
    public static let domainOrder = [
        "Hardware Functional",
        "Workload Stability",
        "macOS Integrity",
        "macOS Maintenance",
        "Security / Configuration",
        "Network / Power"
    ]

    public static func calculateDomains(results: [DiagnosticResult]) -> [DomainResult] {
        let groups = Dictionary(grouping: results, by: { $0.domain })
        return domainOrder.compactMap { name in
            guard let items = groups[name], !items.isEmpty else { return nil }
            var status: CheckStatus = .pass
            var passed = 0
            var attention = 0
            for item in items {
                switch item.status {
                case .fail:
                    status = .fail
                    attention += 1
                case .warning:
                    if status != .fail { status = .warning }
                    attention += 1
                case .incomplete:
                    if status != .fail && status != .warning { status = .incomplete }
                    attention += 1
                case .deferred:
                    if status == .pass { status = .deferred }
                    attention += 1
                case .pass:
                    passed += 1
                case .notAvailable, .notApplicable, .info:
                    break
                }
            }
            let summary = "\(items.count) result(s); \(passed) passed; \(attention) requiring attention"
            return DomainResult(name: name, status: status, summary: summary, total: items.count, passed: passed, requiringAttention: attention)
        }
    }

    public static func calculateOverall(domains: [DomainResult], results: [DiagnosticResult]) -> (CheckStatus, String) {
        let byName = Dictionary(uniqueKeysWithValues: domains.map { ($0.name, $0.status) })
        if byName["Hardware Functional"] == .fail {
            return (.fail, "Hardware failure confirmed")
        }
        if byName["Workload Stability"] == .fail {
            return (.fail, "Stability failure confirmed")
        }
        if byName["macOS Integrity"] == .fail {
            return (.fail, "macOS repair required")
        }
        if results.contains(where: { $0.status == .fail }) {
            return (.fail, "Action required")
        }
        if results.contains(where: { $0.status == .warning || $0.status == .incomplete || $0.status == .deferred }) {
            return (.warning, "Review required")
        }
        return (.pass, "Ready")
    }

    public static func finalize(run: inout DiagnosticRun, finished: Date = Date()) {
        run.finishedLocal = finished
        run.domains = calculateDomains(results: run.results)
        let overall = calculateOverall(domains: run.domains, results: run.results)
        run.overallStatus = overall.0
        run.serviceConclusion = overall.1
    }

    public static func counts(results: [DiagnosticResult]) -> [CheckStatus: Int] {
        var counts: [CheckStatus: Int] = [:]
        for status in CheckStatus.allCases { counts[status] = 0 }
        for result in results { counts[result.status, default: 0] += 1 }
        return counts
    }
}
