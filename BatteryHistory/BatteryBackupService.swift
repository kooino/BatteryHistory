
import Foundation
import AppKit
import UniformTypeIdentifiers

enum BatteryBackupService {

    private static let folderKey = "batteryBackupFolder"
    private static let lastBackupKey = "batteryLastBackupDay"

    private static var lastAttempt = Date.distantPast

    static var isConfigured: Bool {
        UserDefaults.standard.data(forKey: folderKey) != nil
    }

    static var lastBackupDay: String? {
        UserDefaults.standard.string(forKey: lastBackupKey)
    }

    private static var today: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: - Choose backup destination

    static func chooseFolder() throws -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose Battery History Backup Folder"
        panel.message = "Choose a folder outside the app container"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK,
              let url = panel.url else {
            return false
        }

        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        UserDefaults.standard.set(bookmark, forKey: folderKey)
        UserDefaults.standard.removeObject(forKey: lastBackupKey)

        return true
    }

    private static func backupFolder() throws -> URL {
        guard let bookmark = UserDefaults.standard.data(
            forKey: folderKey
        ) else {
            throw backupError("Choose a backup folder first.")
        }

        var stale = false

        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )

        if stale {
            throw backupError(
                "Backup folder permission expired. Choose it again."
            )
        }

        return url
    }

    // MARK: - CSV generation

    static func sessionsCSV(
        _ sessions: [BatterySession]
    ) -> String {

        let formatter = ISO8601DateFormatter()

        let header = [
            "Session ID",
            "Start",
            "End",
            "Elapsed Seconds",
            "Start Battery %",
            "End Battery %",
            "Screen On Seconds",
            "PowerLog Coverage %",
            "Historical Estimate",
            "Power Change During Sleep"
        ].joined(separator: ",")

        let rows = sessions.map { session -> String in
            let end = session.end

            let elapsed = end.map {
                max(0, Int($0.timeIntervalSince(session.start)))
            }

            let fields: [String] = [
                session.id.uuidString,
                formatter.string(from: session.start),
                end.map { formatter.string(from: $0) } ?? "",
                elapsed.map(String.init) ?? "",
                String(session.startPercent),
                session.endPercent.map(String.init) ?? "",
                session.screenOnSeconds.map {
                    String(Int($0.rounded()))
                } ?? "",
                session.screenOnCoverage.map {
                    String(Int(($0 * 100).rounded()))
                } ?? "",
                session.isHistoricalEstimate == true ? "Yes" : "No",
                session.powerTransitionDuringSleep == true
                    ? "Yes" : "No"
            ]

            return fields.joined(separator: ",")
        }

        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    // MARK: - Create backup

    @discardableResult
    static func backup(
        history: BatteryHistoryData,
        samples: [BatterySample]
    ) throws -> URL {

        let folder = try backupFolder()

        guard folder.startAccessingSecurityScopedResource() else {
            throw backupError(
                "Cannot access backup folder. Choose it again."
            )
        }

        defer {
            folder.stopAccessingSecurityScopedResource()
        }

        let destination = folder.appendingPathComponent(
            "BatteryHistory-\(today)",
            isDirectory: true
        )

        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let historyData = try encoder.encode(history)
        let samplesData = try encoder.encode(samples)
        let csvData = Data(sessionsCSV(history.completed).utf8)

        try historyData.write(
            to: destination.appendingPathComponent("sessions.json"),
            options: .atomic
        )

        try samplesData.write(
            to: destination.appendingPathComponent("batterySamples.json"),
            options: .atomic
        )

        try csvData.write(
            to: destination.appendingPathComponent("sessions.csv"),
            options: .atomic
        )

        UserDefaults.standard.set(today, forKey: lastBackupKey)

        print("✅ Battery backup saved:", destination.path)

        return destination
    }

    // MARK: - Automatic daily backup

    static func backupIfNeeded(
        history: BatteryHistoryData,
        samples: [BatterySample]
    ) {
        guard isConfigured,
              lastBackupDay != today else {
            return
        }

        // Avoid repeated attempts every 10 seconds
        // if the backup destination is unavailable.
        guard Date().timeIntervalSince(lastAttempt) >= 3600 else {
            return
        }

        lastAttempt = Date()

        do {
            try backup(history: history, samples: samples)
        } catch {
            print("⚠️ Automatic backup failed:", error)
        }
    }

    private static func backupError(_ message: String) -> NSError {
        NSError(
            domain: "BatteryHistoryBackup",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: message
            ]
        )
    }
}
