import Foundation

public enum ReportRendererError: LocalizedError {
    case missingRunLog(String)

    public var errorDescription: String? {
        switch self {
        case .missingRunLog(let path): return "The required run log was not found at \(path)."
        }
    }
}

public enum ReportRenderer {
    private static let css = """
    :root { color-scheme: light; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif; margin:0; background:#f4f6f8; color:#1f2937; }
    header { background:#173a63; color:#fff; padding:24px 32px; }
    header h1 { margin:0 0 8px; font-size:28px; }
    header .meta { display:flex; flex-wrap:wrap; gap:12px 24px; font-size:14px; opacity:.96; }
    main, section.card, footer { max-width:1200px; margin-left:auto; margin-right:auto; }
    .card { background:#fff; margin-top:18px; padding:20px 24px; border:1px solid #d9e2ec; box-shadow:0 1px 2px rgba(0,0,0,.04); }
    h2 { margin:0 0 14px; font-size:20px; color:#102a43; border-bottom:2px solid #d9e2ec; padding-bottom:8px; }
    table { border-collapse:collapse; width:100%; margin:10px 0 18px; }
    caption { text-align:left; font-weight:700; margin:8px 0; color:#243b53; }
    th,td { padding:8px 10px; border-bottom:1px solid #e6edf3; vertical-align:top; text-align:left; font-size:14px; }
    th { background:#eef4fb; color:#102a43; font-weight:700; }
    tr:nth-child(even) td { background:#fbfdff; }
    .service-row { display:flex; flex-wrap:wrap; gap:12px; align-items:center; margin-bottom:16px; }
    .overall { display:inline-block; padding:8px 14px; border-radius:4px; font-weight:700; }
    .technical { color:#475569; font-size:13px; }
    .summary-grid { display:grid; grid-template-columns:repeat(7,minmax(100px,1fr)); gap:12px; }
    .summary-grid div { background:#f8fafc; border:1px solid #e2e8f0; padding:14px; text-align:center; }
    .summary-grid strong { display:block; font-size:28px; }
    .summary-grid span { color:#64748b; }
    .domain-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(260px,1fr)); gap:12px; }
    .domain-card { border:1px solid #d9e2ec; border-left:6px solid #94a3b8; padding:12px; background:#fff; }
    .domain-card.PASS { border-left-color:#16a34a; }.domain-card.WARNING { border-left-color:#d97706; }
    .domain-card.FAIL { border-left-color:#dc2626; }.domain-card.INCOMPLETE { border-left-color:#ea580c; }
    .domain-card.DEFERRED { border-left-color:#ca8a04; }
    .domain-heading { display:flex; justify-content:space-between; gap:10px; align-items:flex-start; }
    .domain-card p { margin:8px 0; font-size:13px; }.domain-counts { color:#64748b; font-size:12px; }
    .status-chip { display:inline-block; min-width:92px; padding:3px 7px; border-radius:4px; font-weight:700; text-align:center; white-space:nowrap; }
    .status-chip.PASS,.PASS.overall { color:#166534; background:#dcfce7; }
    .status-chip.WARNING,.WARNING.overall { color:#92400e; background:#fef3c7; }
    .status-chip.FAIL,.FAIL.overall { color:#991b1b; background:#fee2e2; }
    .status-chip.INCOMPLETE,.INCOMPLETE.overall { color:#7c2d12; background:#ffedd5; }
    .status-chip.DEFERRED,.DEFERRED.overall { color:#6b4f00; background:#fef9c3; }
    .status-chip.NOT-AVAILABLE,.status-chip.NOT-APPLICABLE { color:#374151; background:#e5e7eb; }
    .status-chip.INFO { color:#1e40af; background:#dbeafe; }
    .action-list { margin:0; padding:0; list-style:none; }.action-list li { margin:8px 0; padding:11px; border:1px solid #e2e8f0; }
    .action-next { display:block; margin:6px 0 0 104px; color:#334155; }
    .finding { margin-top:8px; padding:8px 10px; border-radius:4px; }
    .reason { background:#f8fafc; border-left:4px solid #64748b; }.evidence { background:#fff7ed; }.action { background:#eff6ff; }
    details { margin-top:10px; border-top:1px solid #e2e8f0; padding-top:8px; } details summary { cursor:pointer; font-weight:700; color:#334155; }
    ul { margin:8px 0 0 18px; padding:0; } pre { white-space:pre-wrap; overflow-wrap:anywhere; font-size:12px; background:#f8fafc; padding:10px; }
    footer { color:#64748b; font-size:12px; padding:24px 0 40px; }
    @media(max-width:800px){.summary-grid{grid-template-columns:repeat(2,1fr)}header{padding:20px}.card{margin:12px;padding:16px;overflow-x:auto}}
    @media print { body{background:#fff}.card{box-shadow:none;break-inside:avoid}details:not([open]){display:none!important} }
    """

    public static func write(run: DiagnosticRun, outputDirectory: URL, existingLogURL: URL) throws -> ReportPaths {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750])
        guard FileManager.default.fileExists(atPath: existingLogURL.path) else {
            throw ReportRendererError.missingRunLog(existingLogURL.path)
        }
        let systemInfo = outputDirectory.appendingPathComponent("system-info.html")
        let testResults = outputDirectory.appendingPathComponent("test-results.html")
        let rawData = outputDirectory.appendingPathComponent("raw-data.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(run).write(to: rawData, options: .atomic)
        try systemInformationHTML(run: run).write(to: systemInfo, atomically: true, encoding: .utf8)
        try testResultsHTML(run: run).write(to: testResults, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: systemInfo.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: testResults.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: rawData.path)

        return ReportPaths(systemInfoHTML: systemInfo.path, testResultsHTML: testResults.path, rawJSON: rawData.path, log: existingLogURL.path)
    }

    public static func testResultsHTML(run: DiagnosticRun) -> String {
        let counts = StatusScoring.counts(results: run.results)
        let infoCount = (counts[.info] ?? 0) + (counts[.notApplicable] ?? 0)
        let actions = run.results.filter { $0.status.requiresAttention }
        let categoryOrder = ["Runtime", "Inventory", "CPU", "Memory", "Storage", "Devices", "Display", "System Board", "Thermals", "Network", "Power", "Security", "macOS"]
        let grouped = Dictionary(grouping: run.results, by: { $0.category })

        var html = documentStart(title: "PCRT macOS Test Results")
        html += header(title: "PCRT Diagnostics for macOS - Test Results", run: run)
        html += "<section class=\"card\"><div class=\"service-row\"><span class=\"overall \(run.overallStatus.cssClass)\">Overall service result: \(escape(run.serviceConclusion))</span><span class=\"technical\">Technical status: <strong>\(run.overallStatus.rawValue)</strong></span></div>"
        html += "<div class=\"summary-grid\">"
        html += summaryCell(counts[.fail] ?? 0, "Confirmed failures")
        html += summaryCell(counts[.warning] ?? 0, "Warnings")
        html += summaryCell(counts[.incomplete] ?? 0, "Incomplete")
        html += summaryCell(counts[.deferred] ?? 0, "Deferred")
        html += summaryCell(counts[.notAvailable] ?? 0, "Not available")
        html += summaryCell(counts[.pass] ?? 0, "Passed")
        html += summaryCell(infoCount, "Info / N/A")
        html += "</div><h2 style=\"margin-top:22px\">Domain results</h2><div class=\"domain-grid\">"
        for domain in run.domains {
            html += "<div class=\"domain-card \(domain.status.cssClass)\"><div class=\"domain-heading\"><strong>\(escape(domain.name))</strong>\(statusChip(domain.status))</div><p>\(escape(domain.summary))</p><div class=\"domain-counts\">\(domain.total) result(s); \(domain.passed) passed; \(domain.requiringAttention) requiring attention</div></div>"
        }
        html += "</div><h2 style=\"margin-top:22px\">Action summary</h2>"
        if actions.isEmpty {
            html += "<p>No warnings, failures, incomplete checks, or deferred checks require action.</p>"
        } else {
            html += "<ul class=\"action-list\">"
            for result in actions {
                html += "<li>\(statusChip(result.status)) <strong>\(escape(result.name)):</strong> \(escape(result.summary))"
                if let action = result.recommendedAction, !action.isEmpty {
                    html += "<span class=\"action-next\">Next: \(escape(action))</span>"
                }
                html += "</li>"
            }
            html += "</ul>"
        }
        html += "</section>"

        for category in categoryOrder {
            guard let results = grouped[category], !results.isEmpty else { continue }
            html += "<section class=\"card\"><h2>\(escape(category))</h2><table><thead><tr><th>Status</th><th>Test</th><th>Result</th><th>Duration</th></tr></thead><tbody>"
            for result in results {
                html += "<tr><td>\(statusChip(result.status))</td><td><strong>\(escape(result.name))</strong></td><td>\(escape(result.summary))"
                if let reason = result.reason, !reason.isEmpty { html += "<div class=\"finding reason\"><strong>Reason for status:</strong> \(escape(reason))</div>" }
                if let action = result.recommendedAction, !action.isEmpty { html += "<div class=\"finding action\"><strong>Recommended action:</strong> \(escape(action))</div>" }
                if result.evidence != nil || !result.details.isEmpty {
                    let open = result.status.requiresAttention ? " open" : ""
                    html += "<details\(open)><summary>Technical evidence</summary>"
                    if let evidence = result.evidence, !evidence.isEmpty { html += "<div class=\"finding evidence\"><strong>Key evidence:</strong> \(escape(evidence))</div>" }
                    if !result.details.isEmpty {
                        html += "<ul>" + result.details.map { "<li>\(escape($0))</li>" }.joined() + "</ul>"
                    }
                    html += "</details>"
                }
                let duration = result.durationSeconds > 0 ? String(format: "%.2f sec", result.durationSeconds) : ""
                html += "</td><td>\(duration)</td></tr>"
            }
            html += "</tbody></table></section>"
        }
        html += footer(run: run)
        html += "</body></html>"
        return html
    }

    public static func systemInformationHTML(run: DiagnosticRun) -> String {
        var html = documentStart(title: "PCRT macOS System Information")
        html += header(title: "PCRT Diagnostics for macOS - System Information", run: run)
        for section in run.inventory {
            html += "<section class=\"card\"><h2>\(escape(section.title))</h2>"
            if !section.items.isEmpty {
                html += "<table><tbody>"
                for key in section.items.keys.sorted() {
                    html += "<tr><th>\(escape(key))</th><td>\(escape(section.items[key] ?? ""))</td></tr>"
                }
                html += "</tbody></table>"
            }
            for table in section.tables {
                html += "<table><caption>\(escape(table.title))</caption><thead><tr>"
                html += table.columns.map { "<th>\(escape($0))</th>" }.joined()
                html += "</tr></thead><tbody>"
                if table.rows.isEmpty {
                    html += "<tr><td colspan=\"99\">No records reported.</td></tr>"
                } else {
                    for row in table.rows {
                        html += "<tr>" + row.map { "<td>\(escape($0))</td>" }.joined() + "</tr>"
                    }
                }
                html += "</tbody></table>"
            }
            html += "</section>"
        }
        html += footer(run: run)
        html += "</body></html>"
        return html
    }

    private static func documentStart(title: String) -> String {
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>\(escape(title))</title><style>\(css)</style></head><body>"
    }

    private static func header(title: String, run: DiagnosticRun) -> String {
        var meta = "<div><strong>Product:</strong> \(escape(run.productName)) \(escape(run.version))</div><div><strong>Computer:</strong> \(escape(run.computerName))</div><div><strong>Mode:</strong> \(escape(run.modeDisplayName))</div><div><strong>Started:</strong> \(escape(format(run.startedLocal)))</div>"
        if let customer = run.customer, !customer.isEmpty { meta += "<div><strong>Customer:</strong> \(escape(customer))</div>" }
        if let technician = run.technician, !technician.isEmpty { meta += "<div><strong>Technician:</strong> \(escape(technician))</div>" }
        return "<header><h1>\(escape(title))</h1><div class=\"meta\">\(meta)</div></header>"
    }

    private static func footer(run: DiagnosticRun) -> String {
        "<footer>Generated by \(escape(run.productName)) \(escape(run.version)) on \(escape(format(Date()))). This report is intended as a technician aid. Review warnings and failures before making repair decisions.</footer>"
    }

    private static func summaryCell(_ count: Int, _ label: String) -> String {
        "<div><strong>\(count)</strong><span>\(escape(label))</span></div>"
    }

    private static func statusChip(_ status: CheckStatus) -> String {
        "<span class=\"status-chip \(status.cssClass)\">\(escape(status.rawValue))</span>"
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    public static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
