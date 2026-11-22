import SwiftUI
import Charts
import UniformTypeIdentifiers
import AppKit

private enum HistoryPeriod: String, CaseIterable, Identifiable {
    case day = "24 Hours"
    case week = "7 Days"
    case month = "30 Days"
    case all = "All Time"

    var id: String { rawValue }

    var cutoff: Date {
        switch self {
        case .day: return Date().addingTimeInterval(-86400)
        case .week: return Date().addingTimeInterval(-7 * 86400)
        case .month: return Date().addingTimeInterval(-30 * 86400)
        case .all: return .distantPast
        }
    }
}

private struct BatteryChartPoint: Identifiable {
    let sample: BatterySample
    let segment: Int
    var id: UUID { sample.id }
}

struct HistoryDashboardView: View {
    @ObservedObject var monitor: BatteryMonitor
    @State private var period: HistoryPeriod = .day
    @State private var showingImportResult = false
    @State private var importMessage = ""
    @State private var hoveredSample: BatterySample?

    private var samples: [BatterySample] {
        monitor.batterySamples
            .filter { $0.timestamp >= period.cutoff }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var sessions: [BatterySession] {
        monitor.history.completed
            .filter { ($0.end ?? $0.start) >= period.cutoff }
            .sorted { $0.start > $1.start }
    }

    private var averageScreenHours: Double {
        let tracked = sessions.compactMap(\.screenOnSeconds)
        guard !tracked.isEmpty else { return 0 }
        return tracked.reduce(0, +) / Double(tracked.count) / 3600
    }

    private var chartPoints: [BatteryChartPoint] {
        var segment = 0
        var previousDate: Date?
        return samples.map { sample in
            if let previousDate,
               sample.timestamp.timeIntervalSince(previousDate) > 1200 {
                segment += 1
            }
            previousDate = sample.timestamp
            return BatteryChartPoint(sample: sample, segment: segment)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                toolbarSection
                statsSection
                dataProtectionSection
                batteryChartSection
                screenChartSection
                sessionHistorySection
            }
            .padding(28)
        }
        .frame(minWidth: 650, minHeight: 450)
        .alert("Battery History Import", isPresented: $showingImportResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage)
        }
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("Battery History").font(.largeTitle.bold())
                Text("Your MacBook's battery activity")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let status = monitor.status {
                Label("\(status.percentage)%", systemImage: "battery.100percent")
                    .font(.title2.bold())
                    .foregroundStyle(.green)
            }
        }
    }

    private var toolbarSection: some View {
        HStack(spacing: 12) {
            Picker("Period", selection: $period) {
                ForEach(HistoryPeriod.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 440)

            Spacer(minLength: 8)

            Menu {
                Button("Import Battery Readings", systemImage: "square.and.arrow.down") {
                    importHistory()
                }
                Button("Recover Charging Sessions", systemImage: "clock.arrow.circlepath") {
                    recoverSessions()
                }
                Button("Recover Screen-on Time", systemImage: "display") {
                    recoverHistoricalScreenTime()
                }
            } label: {
                Label("Import & Recovery", systemImage: "square.and.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                Button {
                    chooseBackupFolder()
                } label: {
                    Label("Choose Backup Folder", systemImage: "folder")
                }
                Button {
                    backupNow()
                } label: {
                    Label("Back Up Now", systemImage: "externaldrive")
                }
                Button {
                    exportSessionsCSV()
                } label: {
                    Label("Export Sessions CSV", systemImage: "tablecells")
                }
                Divider()
                Button {
                    restoreFromBackup()
                } label: {
                    Label("Restore from Backup", systemImage: "arrow.counterclockwise")
                }
            } label: {
                Label("Backup & Export", systemImage: "externaldrive.badge.checkmark")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var dataProtectionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Data Protection", systemImage: "shield.checkered")
                    .font(.title3.bold())
                Spacer()
                Text(BatteryBackupService.isConfigured ? "Configured" : "Not configured")
                    .font(.caption.bold())
                    .foregroundStyle(BatteryBackupService.isConfigured ? Color.green : Color.orange)
            }

            Divider()

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("AUTOMATIC BACKUPS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label(
                        BatteryBackupService.isConfigured ? "Configured" : "Not configured",
                        systemImage: BatteryBackupService.isConfigured
                            ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .foregroundStyle(BatteryBackupService.isConfigured ? Color.green : Color.orange)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("LAST SUCCESSFUL BACKUP DAY")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(BatteryBackupService.lastBackupDay ?? "Never")
                        .font(.headline)
                }
            }

            Text("Daily backups are attempted while Battery History is running. The folder permission must remain valid.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var statsSection: some View {
        HStack(spacing: 12) {
            summaryCard(title: "Battery Sessions", value: "\(sessions.count)", symbol: "battery.100percent")
            summaryCard(title: "Screen-on Average", value: String(format: "%.1f h", averageScreenHours), symbol: "display")
            summaryCard(title: "Battery Samples", value: "\(samples.count)", symbol: "chart.xyaxis.line")
        }
    }

    @ViewBuilder
    private var batteryChartSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Battery Level").font(.title3.bold())
            if samples.isEmpty {
                emptyMessage("No battery samples in this period")
            } else {
                hoverDetails
                batteryLevelChart
                HStack(spacing: 18) {
                    Label("On battery", systemImage: "circle.fill").foregroundStyle(.green)
                    Label("Connected", systemImage: "circle.fill").foregroundStyle(.blue)
                    Label("20% or below", systemImage: "circle.fill").foregroundStyle(.red)
                }
                .font(.caption)
            }
        }
        .padding(20)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var hoverDetails: some View {
        if let sample = hoveredSample {
            HStack(spacing: 12) {
                Image(systemName: sample.isPluggedIn ? "bolt.fill" : "battery.100percent")
                    .foregroundStyle(sample.isPluggedIn ? Color.blue : Color.green)
                Text("\(sample.percentage)%")
                    .font(.headline)
                    .monospacedDigit()
                Text(sample.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(sample.isPluggedIn ? "Connected to power" : "On Battery")
                    .font(.caption)
            }
        } else {
            Text("Hover over the graph to inspect a reading")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var batteryLevelChart: some View {
        Chart(chartPoints) { point in
            LineMark(
                x: .value("Time", point.sample.timestamp),
                y: .value("Battery", point.sample.percentage),
                series: .value("Segment", point.segment)
            )
            .foregroundStyle(Color.green)
            .lineStyle(StrokeStyle(lineWidth: 2))

            PointMark(
                x: .value("Time", point.sample.timestamp),
                y: .value("Battery", point.sample.percentage)
            )
            .symbolSize(12)
            .foregroundStyle(color(for: point.sample))
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 25, 50, 75, 100]) {
                AxisGridLine()
                AxisTick()
                AxisValueLabel()
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let x = location.x - geometry[plotFrame].origin.x
                            guard let date: Date = proxy.value(atX: x, as: Date.self) else { return }
                            hoveredSample = samples.min {
                                abs($0.timestamp.timeIntervalSince(date)) <
                                abs($1.timestamp.timeIntervalSince(date))
                            }
                        case .ended:
                            hoveredSample = nil
                        }
                    }
            }
        }
        .frame(height: 230)
    }

    private func color(for sample: BatterySample) -> Color {
        if sample.percentage <= 20 { return .red }
        return sample.isPluggedIn ? .blue : .green
    }

    @ViewBuilder
    private var screenChartSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Screen-on Time by Session").font(.title3.bold())
            let tracked = sessions.filter { $0.screenOnSeconds != nil }
            if tracked.isEmpty {
                emptyMessage("No tracked sessions in this period")
            } else {
                Chart(tracked) { session in
                    BarMark(
                        x: .value("Session", session.start),
                        y: .value("Hours", (session.screenOnSeconds ?? 0) / 3600)
                    )
                    .foregroundStyle(.blue.gradient)
                }
                .frame(height: 180)
            }
        }
        .padding(20)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var sessionHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session History").font(.title3.bold())
            if sessions.isEmpty {
                emptyMessage("No completed sessions yet")
            } else {
                ForEach(sessions) { session in
                    sessionRow(session)
                    Divider()
                }
            }
        }
        .padding(20)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func sessionRow(_ session: BatterySession) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(session.start.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Text("\(session.startPercent)% → \(session.endPercent ?? 0)%")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(session.formattedDuration)
                    .font(.headline)
                    .monospacedDigit()
                if session.isHistoricalEstimate == true {
                    Label("Estimated from PowerLog", systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if session.powerTransitionDuringSleep == true {
                    Label("Charging time uncertain", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let seconds = session.screenOnSeconds {
                    Text("Screen on: \(formatTime(seconds))")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Screen on: Not tracked")
                        .foregroundStyle(.secondary)
                }
                if let coverage = session.screenOnCoverage {
                    Text("PowerLog coverage: \(Int((coverage * 100).rounded()))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func summaryCard(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value).font(.title.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func emptyMessage(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 100)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds)) / 60
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func chooseBackupFolder() {
        do {
            guard try BatteryBackupService.chooseFolder() else { return }
            let url = try BatteryBackupService.backup(
                history: monitor.history,
                samples: monitor.batterySamples
            )
            importMessage = "Backup folder selected.\n\nFirst backup saved to:\n\(url.path)"
        } catch {
            importMessage = "Backup setup failed:\n\(error.localizedDescription)"
        }
        showingImportResult = true
    }

    private func backupNow() {
        do {
            let url = try BatteryBackupService.backup(
                history: monitor.history,
                samples: monitor.batterySamples
            )
            importMessage = "Backup saved successfully:\n\(url.path)"
        } catch {
            importMessage = "Backup failed:\n\(error.localizedDescription)"
        }
        showingImportResult = true
    }

    private func exportSessionsCSV() {
        let panel = NSSavePanel()
        panel.title = "Export Battery Sessions"
        panel.nameFieldStringValue = "BatteryHistory-Sessions.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let csv = BatteryBackupService.sessionsCSV(monitor.history.completed)
            try Data(csv.utf8).write(to: url, options: .atomic)
            importMessage = "CSV exported successfully."
        } catch {
            importMessage = "Export failed:\n\(error.localizedDescription)"
        }
        showingImportResult = true
    }

    private func restoreFromBackup() {
        let panel = NSOpenPanel()
        panel.title = "Restore Battery History"
        panel.message = "Select a dated BatteryHistory backup folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let alert = NSAlert()
        alert.messageText = "Restore Battery History?"
        alert.informativeText = "This will replace your current history with the selected backup. Your current files will be copied to a recovery folder first. Do not restore an older backup containing an active session while monitoring is running."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try monitor.restoreBackup(from: folder)
            importMessage = "Backup restored.\nSessions: \(monitor.history.completed.count)\nBattery readings: \(monitor.batterySamples.count)\nYour previous files were preserved in Application Support."
        } catch {
            importMessage = "Restore failed:\n\(error.localizedDescription)"
        }
        showingImportResult = true
    }

    private func importHistory() {
        let panel = NSOpenPanel()
        panel.title = "Import Battery History"
        panel.message = "Choose historicalSamples.json"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try monitor.importBatterySamples(from: url)
            importMessage = "Imported \(count) battery readings. Total saved: \(monitor.batterySamples.count)."
        } catch {
            importMessage = "Import failed: \(error.localizedDescription)"
        }
        showingImportResult = true
    }

    private func recoverSessions() {
        let count = monitor.recoverHistoricalSessions()
        importMessage = "Recovered \(count) historical sessions. Total completed: \(monitor.history.completed.count). Recovered durations are estimates."
        showingImportResult = true
    }

    private func recoverHistoricalScreenTime() {
        let panel = NSOpenPanel()
        panel.title = "Recover Historical Screen Time"
        panel.message = "Choose historicalScreenOn.json"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try monitor.importHistoricalScreenTime(from: url)
            importMessage = "Updated \(count) historical battery sessions. Screen-on durations are estimates from PowerLog."
        } catch {
            importMessage = "Recovery failed: \(error.localizedDescription)"
        }
        showingImportResult = true
    }
}
