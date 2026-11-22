
import SwiftUI
import AppKit
import Combine
import IOKit.ps
import CoreGraphics
import Charts

@main
struct BatteryHistoryApp: App {
    @StateObject private var monitor = BatteryMonitor()

    var body: some Scene {
        MenuBarExtra {
            BatteryMenuView(monitor: monitor)
        } label: {
            Image(
                nsImage: BatteryMenuIcon.make(
                    percentage: monitor.status?.percentage
                )
            )
        }
        .menuBarExtraStyle(.window)

        Window("Battery History", id: "history") {
            HistoryDashboardView(monitor: monitor)
        }
        .defaultSize(width: 900, height: 700)
    }
}

struct BatteryMenuIcon {

    static func make(percentage: Int?) -> NSImage {
        let size = NSSize(width: 39, height: 19)

        let image = NSImage(
            size: size,
            flipped: false
        ) { _ in

            NSColor.black.setStroke()

            // Battery outline
            let outline = NSBezierPath(
                roundedRect: NSRect(
                    x: 1,
                    y: 2,
                    width: 33,
                    height: 15
                ),
                xRadius: 3,
                yRadius: 3
            )

            outline.lineWidth = 1.5
            outline.stroke()

            // Battery tip
            let tip = NSBezierPath(
                roundedRect: NSRect(
                    x: 35,
                    y: 6,
                    width: 3,
                    height: 7
                ),
                xRadius: 1,
                yRadius: 1
            )

            NSColor.black.setFill()
            tip.fill()

            // Battery percentage in the middle
            let value = percentage.map {
                String($0)
            } ?? "–"

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: 10,
                    weight: .bold
                ),
                .foregroundColor: NSColor.black
            ]

            let text = value as NSString
            let textSize = text.size(
                withAttributes: attributes
            )

            let textRect = NSRect(
                x: 17.5 - textSize.width / 2,
                y: 9.5 - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )

            text.draw(
                in: textRect,
                withAttributes: attributes
            )

            return true
        }

        // Let macOS adapt the icon to light/dark menu bars.
        image.isTemplate = true

        return image
    }
}



// MARK: - Battery Monitoring

struct BatteryStatus {
    let percentage: Int
    let isPluggedIn: Bool
    let isCharging: Bool
}

final class BatteryMonitor: ObservableObject {
    @Published var status: BatteryStatus?
    @Published var unpluggedSince: Date?
    @Published var now = Date()
    @Published var history = BatteryHistoryStorage.load()
    @Published var batterySamples = BatterySampleStore.load()


    private var pendingPlugDate: Date?
    private var previousConnected: Bool?
    private var timer: Timer?
    private let startKey = "batteryUnpluggedSince"
    
    private var lastScreenSample: Date?
    private var wasOnBattery = false
    private var wasScreenOn = false
    private var lastScreenSave = Date()
    
    
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    private var isMacSleeping = false
    private var powerStateBeforeSleep: Bool?

    
    
    init() {
        unpluggedSince = UserDefaults.standard.object(
            forKey: startKey
        ) as? Date
        
        
        unpluggedSince = history.current?.start
        
        print("🔋 Loaded sessions:",
              history.completed.count)
        print("🔋 History file:",
              BatteryHistoryStorage.fileURL.path)   


        refresh()

        timer = Timer.scheduledTimer(
            withTimeInterval: 10,
            repeats: true
        ) { [weak self] _ in
            self?.refresh()
        }
        
        
        let center = NSWorkspace.shared.notificationCenter

        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSleep()
        }

        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }

    }

    
    deinit {
        timer?.invalidate()

        let center = NSWorkspace.shared.notificationCenter

        if let sleepObserver {
            center.removeObserver(sleepObserver)
        }

        if let wakeObserver {
            center.removeObserver(wakeObserver)
        }
    }


    func restoreBackup(from folder: URL) throws {
        let access = folder.startAccessingSecurityScopedResource()
        defer {
            if access {
                folder.stopAccessingSecurityScopedResource()
            }
        }

        let sourceHistory = folder.appendingPathComponent(
            "sessions.json"
        )
        let sourceSamples = folder.appendingPathComponent(
            "batterySamples.json"
        )

        // Read and validate both files before changing anything.
        let historyData = try Data(contentsOf: sourceHistory)
        let samplesData = try Data(contentsOf: sourceSamples)

        let restoredHistory = try JSONDecoder().decode(
            BatteryHistoryData.self,
            from: historyData
        )

        let restoredSamples = try JSONDecoder().decode(
            [BatterySample].self,
            from: samplesData
        )

        guard !restoredSamples.isEmpty,
              !restoredHistory.completed.isEmpty ||
              restoredHistory.current != nil else {
            throw NSError(
                domain: "BatteryHistoryRestore",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The backup is empty or incomplete."
                ]
            )
        }

        // Preserve the existing files before restoring.
        let historyURL = BatteryHistoryStorage.fileURL
        let samplesURL = BatterySampleStore.fileURL

        let recoveryFolder = historyURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "BeforeRestore-\(UUID().uuidString)",
                isDirectory: true
            )

        try FileManager.default.createDirectory(
            at: recoveryFolder,
            withIntermediateDirectories: true
        )

        let oldHistory = try? Data(contentsOf: historyURL)
        let oldSamples = try? Data(contentsOf: samplesURL)

        if let oldHistory {
            try oldHistory.write(
                to: recoveryFolder.appendingPathComponent("sessions.json"),
                options: .atomic
            )
        }

        if let oldSamples {
            try oldSamples.write(
                to: recoveryFolder.appendingPathComponent("batterySamples.json"),
                options: .atomic
            )
        }

        // Write both restored files.
        // Roll back if either write fails.
        do {
            try historyData.write(
                to: historyURL,
                options: .atomic
            )

            try samplesData.write(
                to: samplesURL,
                options: .atomic
            )
        } catch {
            if let oldHistory {
                try? oldHistory.write(
                    to: historyURL,
                    options: .atomic
                )
            }

            if let oldSamples {
                try? oldSamples.write(
                    to: samplesURL,
                    options: .atomic
                )
            }

            throw error
        }

        // Update the dashboard immediately.
        history = restoredHistory
        batterySamples = restoredSamples
        unpluggedSince = restoredHistory.current?.start

        print("✅ Backup restored")
        print("Safety copy:", recoveryFolder.path)
    }

    
    @discardableResult
    func importHistoricalScreenTime(
        from url: URL
    ) throws -> Int {

        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)

        let intervals = try JSONDecoder().decode(
            [HistoricalScreenInterval].self,
            from: data
        )

        guard !intervals.isEmpty else {
            throw NSError(
                domain: "BatteryHistory",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No historical screen-on records found."
                ]
            )
        }

        var updated = 0

        for index in history.completed.indices {
            let session = history.completed[index]

            // Only update recovered PowerLog sessions.
            guard session.isHistoricalEstimate == true,
                  session.screenOnSeconds == nil else {
                continue
            }

            guard let result = HistoricalScreenRecovery.estimate(
                session: session,
                intervals: intervals
            ) else {
                continue
            }

            history.completed[index].screenOnSeconds =
                result.seconds

            history.completed[index].screenOnCoverage =
                result.coverage

            updated += 1
        }

        if updated > 0 {
            BatteryHistoryStorage.save(history)
        }

        return updated
    }

    
    @discardableResult
    func recoverHistoricalSessions() -> Int {

        let candidates = HistoricalSessionRecovery.recover(
            from: batterySamples
        )

        var added = 0

        for session in candidates {

            // Avoid importing sessions overlapping
            // anything we already recorded.
            let overlapsExisting = history.completed.contains {
                existing in

                guard let existingEnd = existing.end,
                      let newEnd = session.end else {
                    return false
                }

                return session.start < existingEnd &&
                       newEnd > existing.start
            }

            let overlapsCurrent: Bool = {
                guard let current = history.current,
                      let newEnd = session.end else {
                    return false
                }

                return newEnd > current.start
            }()

            guard !overlapsExisting,
                  !overlapsCurrent else {
                continue
            }

            history.completed.append(session)
            added += 1
        }

        history.completed.sort {
            $0.start > $1.start
        }

        if added > 0 {
            BatteryHistoryStorage.save(history)
        }

        return added
    }

    
    @discardableResult
    func importBatterySamples(from url: URL) throws -> Int {
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        let imported = try JSONDecoder().decode(
            [BatterySample].self,
            from: data
        )

        let currentTime = Date()

        // Only accept reasonable battery readings.
        let valid = imported.filter { sample in
            sample.percentage >= 0 &&
            sample.percentage <= 100 &&
            sample.timestamp >= Date(timeIntervalSince1970: 0) &&
            sample.timestamp <= currentTime.addingTimeInterval(300)
        }

        guard !valid.isEmpty else {
            throw NSError(
                domain: "BatteryHistory",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No valid battery samples were found."
                ]
            )
        }

        // Retain existing samples and avoid duplicates
        // within the same minute and charger state.
        var merged = batterySamples
        var seen = Set<String>()

        func sampleKey(_ sample: BatterySample) -> String {
            let minute = Int(
                sample.timestamp.timeIntervalSince1970 / 60
            )
            return "\(minute)-\(sample.isPluggedIn)"
        }

        for sample in batterySamples {
            seen.insert(sampleKey(sample))
        }

        var added = 0

        for sample in valid.sorted(
            by: { $0.timestamp < $1.timestamp }
        ) {
            if seen.insert(sampleKey(sample)).inserted {
                merged.append(sample)
                added += 1
            }
        }

        merged.sort { $0.timestamp < $1.timestamp }

        batterySamples = merged
        BatterySampleStore.save(merged)

        return added
    }

    
    private func handleSleep() {
        print("🌙 Mac is going to sleep")

        isMacSleeping = true
        powerStateBeforeSleep = status?.isPluggedIn

        // Prevent the time spent asleep from being
        // added to screen-on duration.
        lastScreenSample = nil
        wasScreenOn = false
        wasOnBattery = false

        // Preserve the current session's progress.
        BatteryHistoryStorage.save(history)
    }

    private func handleWake() {
        print("☀️ Mac woke up")

        isMacSleeping = false

        // Start screen sampling fresh after wake.
        lastScreenSample = nil
        wasScreenOn = false
        wasOnBattery = false

        // Update battery and charger information.
        refresh()

        if let before = powerStateBeforeSleep,
           let after = status?.isPluggedIn,
           before != after {

            print("⚠️ Power connection changed during sleep")

            if history.current != nil {
                history.current?.powerTransitionDuringSleep = true
                BatteryHistoryStorage.save(history)
            }
        }

        powerStateBeforeSleep = nil
    }

   
    func refresh() {
        now = Date()
        
        
        guard !isMacSleeping else {
            return
        }


        guard let battery = readBattery() else {
            status = nil
            lastScreenSample = nil
            return
        }
        
        updateScreenTime(at: now, battery: battery)

        status = battery
        
        // Record a battery sample every 5 minutes
        // and whenever the charger state changes.

        let lastSample = batterySamples.last

        let shouldRecord =
            lastSample == nil ||
            now.timeIntervalSince(
                lastSample?.timestamp ?? .distantPast
            ) >= 300 ||
            lastSample?.isPluggedIn != battery.isPluggedIn

        if shouldRecord {
            let sample = BatterySample(
                timestamp: now,
                percentage: battery.percentage,
                isPluggedIn: battery.isPluggedIn
            )

            batterySamples.append(sample)
            BatterySampleStore.save(batterySamples)
        }


        // First observation
        if previousConnected == nil {
            previousConnected = battery.isPluggedIn
        }

        if !battery.isPluggedIn {
            pendingPlugDate = nil

            if history.current == nil {
                history.current = BatterySession(
                    start: now,
                    startPercent: battery.percentage
                )
                BatteryHistoryStorage.save(history)
            }

            unpluggedSince = history.current?.start

        } else {
            if history.current != nil {

                if pendingPlugDate == nil {
                    pendingPlugDate = now
                }

                // Only count a reconnection after
                // 30 seconds of continuous AC power.
                if let plugDate = pendingPlugDate,
                   now.timeIntervalSince(plugDate) >= 30 {

                    var finished = history.current!
                    finished.end = plugDate
                    finished.endPercent = battery.percentage

                    if finished.duration >= 60 {
                        history.completed.insert(
                            finished,
                            at: 0
                        )
                    }

                    history.current = nil
                    unpluggedSince = nil
                    pendingPlugDate = nil

                    BatteryHistoryStorage.save(history)
                }
            } else {
                unpluggedSince = nil
            }
        }

        previousConnected = battery.isPluggedIn
        
        
        // Save ongoing screen time about once a minute.
        if history.current != nil &&
           now.timeIntervalSince(lastScreenSave) >= 60 {

            BatteryHistoryStorage.save(history)
            lastScreenSave = now
        }
        
        
        // Automatically back up history once per day
        // whenever the app is running.
        BatteryBackupService.backupIfNeeded(
            history: history,
            samples: batterySamples
        )


    }


    private func readBattery() -> BatteryStatus? {
        let info = IOPSCopyPowerSourcesInfo()
            .takeRetainedValue()

        let sources = IOPSCopyPowerSourcesList(info)
            .takeRetainedValue() as Array

        for source in sources {
            guard let description =
                IOPSGetPowerSourceDescription(
                    info, source
                ).takeUnretainedValue()
                    as? [String: Any]
            else {
                continue
            }

            guard let current = description[
                kIOPSCurrentCapacityKey as String
            ] as? Int,
            let maximum = description[
                kIOPSMaxCapacityKey as String
            ] as? Int,
            maximum > 0
            else {
                continue
            }

            let percentage = Int(
                (Double(current) / Double(maximum)
                 * 100).rounded()
            )

            let powerSource = description[
                kIOPSPowerSourceStateKey as String
            ] as? String

            let pluggedIn = powerSource ==
                (kIOPSACPowerValue as String)

            let charging = description[
                kIOPSIsChargingKey as String
            ] as? Bool ?? false

            return BatteryStatus(
                percentage: percentage,
                isPluggedIn: pluggedIn,
                isCharging: charging
            )
        }

        return nil
    }
    
    
    private func updateScreenTime(
        at date: Date,
        battery: BatteryStatus
    ) {
        if let previous = lastScreenSample,
           wasOnBattery,
           wasScreenOn,
           history.current != nil {

            let elapsed = date.timeIntervalSince(previous)

            // Ignore long gaps, such as Mac sleep.
            if elapsed > 0 && elapsed <= 15 {
                history.current?.screenOnSeconds =
                    (history.current?.screenOnSeconds ?? 0)
                    + elapsed
            }
        }

        lastScreenSample = date
        wasOnBattery = !battery.isPluggedIn
        wasScreenOn =
            CGDisplayIsActive(CGMainDisplayID()) != 0

    }


    var unpluggedDuration: String {
        guard let start = unpluggedSince else {
            return "—"
        }

        let seconds = max(
            0, Int(now.timeIntervalSince(start))
        )

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60

        return "\(hours)h \(minutes)m"
    }
}


struct BatteryLevelChart: View {
    let samples: [BatterySample]

    private var last24Hours: [BatterySample] {
        let cutoff = Date().addingTimeInterval(-86400)

        return samples.filter {
            $0.timestamp >= cutoff
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BATTERY LEVEL")
                .font(.caption)
                .foregroundStyle(.secondary)

            if last24Hours.isEmpty {
                Text("Collecting battery history...")
                    .foregroundStyle(.secondary)
            } else {
                Chart(last24Hours) { sample in
                    BarMark(
                        x: .value(
                            "Time",
                            sample.timestamp
                        ),
                        y: .value(
                            "Battery",
                            sample.percentage
                        ),
                        width: .fixed(3)
                    )
                    .foregroundStyle(
                        sample.percentage <= 10
                            ? Color.red
                            : Color.green
                    )
                }
                .chartYScale(domain: 0...100)
                
                .chartXScale(
                    domain: Date().addingTimeInterval(-86400)...Date()
                )

                .chartYAxis {
                    AxisMarks(
                        position: .trailing,
                        values: [0, 25, 50, 75, 100]
                    )
                }
                .frame(height: 170)
            }
        }
    }
}


// MARK: - Menu Bar Interface


struct BatteryMenuView: View {
    @ObservedObject var monitor: BatteryMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            HStack {
                Image(systemName: "battery.100percent")
                    .foregroundStyle(.green)

                Text("Battery History")
                    .font(.headline)

                Spacer()

                if let battery = monitor.status {
                    Text(battery.isPluggedIn
                         ? "Plugged In"
                         : "On Battery")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            if let battery = monitor.status {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(battery.percentage)%")
                        .font(.system(
                            size: 40,
                            weight: .semibold,
                            design: .rounded
                        ))

                    Spacer()

                    Image(systemName:
                        battery.isCharging
                        ? "bolt.fill"
                        : "battery.100percent"
                    )
                    .foregroundStyle(
                        battery.isCharging
                        ? Color.green
                        : Color.secondary
                    )
                }

                ProgressView(
                    value: Double(battery.percentage),
                    total: 100
                )
                .tint(
                    battery.percentage <= 20
                    ? .red
                    : .green
                )
            }

            Divider()

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("TIME UNPLUGGED")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(monitor.unpluggedDuration)
                        .font(.title3.bold())
                        .monospacedDigit()
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 5) {
                    Text("SCREEN ON")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    let seconds =
                        monitor.history.current?.screenOnSeconds ?? 0
                    let minutes = Int(seconds) / 60

                    Text(
                        "\(minutes / 60)h \(minutes % 60)m"
                    )
                    .font(.title3.bold())
                    .monospacedDigit()
                }
            }

            Divider()

            Button {
                openWindow(id: "history")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label(
                    "Open Full History",
                    systemImage: "chart.bar.xaxis"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            HStack {
                Button("Refresh") {
                    monitor.refresh()
                }

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 320)
    }
}


