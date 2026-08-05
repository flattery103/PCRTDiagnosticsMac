import SwiftUI
import PCRTCore

struct MainView: View {
    @StateObject private var model = MainViewModel()
    @State private var detailsExpanded = false

    var body: some View {
        VStack(spacing: 18) {
            branding
            sessionControls
            Divider()
            scanSummary
            progressSection
            actionButtons
            statusPanel
            detailsPanel
        }
        .padding(24)
        .frame(minWidth: 720, idealWidth: 780, minHeight: 650, idealHeight: 760)
    }

    private var branding: some View {
        HStack(spacing: 16) {
            Image("Branding")
                .resizable()
                .scaledToFit()
                .frame(width: 54, height: 54)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("PCRT Diagnostics")
                    .font(.system(size: 30, weight: .semibold))
                Text("Native macOS client • \(model.versionText)")
                    .font(.subheadline)
                    .opacity(0.9)
            }
            Spacer()
        }
        .foregroundColor(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(Color(red: 0.09, green: 0.23, blue: 0.39))
        .cornerRadius(18)
    }

    private var sessionControls: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Session code")
                    .font(.headline)
                TextField("ABCDE", text: Binding(get: { model.sessionCode }, set: { model.updateCode($0) }))
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .frame(width: 230)
                    .disabled(model.state.isActive || model.state == .uploadFailed || model.state == .complete)
                    .accessibilityLabel("Five-character session code")
            }
            Button(action: model.start) {
                Text("Start")
                    .font(.headline)
                    .frame(minWidth: 150)
                    .padding(.vertical, 8)
            }
            .buttonStyle(PCRTPrimaryButtonStyle(enabled: model.canStart))
            .disabled(!model.canStart)
            Spacer()
        }
    }

    private var scanSummary: some View {
        HStack(spacing: 12) {
            summaryCard(title: "Scan mode", value: model.currentMode)
            summaryCard(title: "Current test", value: model.currentTest)
            summaryCard(title: "Completed", value: model.totalTests > 0 ? "\(model.completedTests) of \(model.totalTests)" : "0")
            summaryCard(title: "Elapsed", value: elapsedText)
        }
    }

    private func summaryCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(NSColor.separatorColor)))
        .cornerRadius(8)
    }

    private var progressSection: some View {
        VStack(spacing: 8) {
            ProgressView(value: Double(model.progress), total: 100)
                .progressViewStyle(LinearProgressViewStyle())
            HStack {
                Text("\(model.progress)%")
                    .font(.system(.body, design: .monospaced))
                Spacer()
                if model.serverReceivedReports {
                    Label("Server received reports", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            if model.canCancel {
                Button("Cancel", action: model.cancel)
                    .keyboardShortcut(.cancelAction)
            }
            if model.showRetryUpload {
                Button("Retry Upload", action: model.retryUpload)
                    .buttonStyle(PCRTPrimaryButtonStyle(enabled: true))
            }
            if model.showReportLocation {
                Button("Show Reports in Finder", action: model.showReportsInFinder)
            }
            Spacer()
        }
    }

    private var statusPanel: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundColor(statusColor)
                .font(.title3)
            Text(model.statusMessage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color(NSColor.textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor)))
        .cornerRadius(10)
    }

    private var detailsPanel: some View {
        DisclosureGroup(isExpanded: $detailsExpanded) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.detailLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(10)
                }
                .frame(minHeight: 140, maxHeight: 260)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(NSColor.separatorColor)))
                .onChange(of: model.detailLines.count) { count in
                    guard detailsExpanded, count > 0 else { return }
                    withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        } label: {
            Text("Live details and log (\(model.detailLines.count))")
                .font(.headline)
        }
    }

    private var elapsedText: String {
        let hours = model.elapsedSeconds / 3600
        let minutes = (model.elapsedSeconds % 3600) / 60
        let seconds = model.elapsedSeconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
    }

    private var statusSymbol: String {
        switch model.state {
        case .complete: return "checkmark.circle.fill"
        case .uploadFailed, .error: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        case .idle: return "info.circle"
        default: return "gearshape.2.fill"
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .complete: return .green
        case .uploadFailed, .error: return .orange
        case .cancelled: return .secondary
        default: return Color(red: 0.09, green: 0.23, blue: 0.39)
        }
    }
}

private struct PCRTPrimaryButtonStyle: ButtonStyle {
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .background(enabled ? Color(red: 0.09, green: 0.23, blue: 0.39).opacity(configuration.isPressed ? 0.75 : 1) : Color.gray.opacity(0.45))
            .cornerRadius(7)
    }
}
