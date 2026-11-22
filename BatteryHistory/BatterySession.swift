
import Foundation

struct BatterySession: Identifiable, Codable {
    var id = UUID()
    var start: Date
    var end: Date?
    var startPercent: Int
    var endPercent: Int?
    var screenOnSeconds: TimeInterval? = nil
    var isHistoricalEstimate: Bool? = nil
    var screenOnCoverage: Double? = nil
    var powerTransitionDuringSleep: Bool? = nil




    var duration: TimeInterval {
        (end ?? Date()).timeIntervalSince(start)
    }

    var formattedDuration: String {
        let seconds = max(0, Int(duration))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return "\(hours)h \(minutes)m"
    }
    
    
    var formattedScreenCoverage: String? {
        guard let coverage = screenOnCoverage else {
            return nil
        }

        return "PowerLog coverage: \(Int(coverage * 100))%"
    }

}

struct BatteryHistoryData: Codable {
    var completed: [BatterySession] = []
    var current: BatterySession?
}

enum BatteryHistoryStorage {
    static var fileURL: URL {
        let folder = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(
            "BatteryHistory",
            isDirectory: true
        )

        return folder.appendingPathComponent(
            "sessions.json"
        )
    }

    static func load() -> BatteryHistoryData {
        guard let data = try? Data(
            contentsOf: fileURL
        ) else {
            return BatteryHistoryData()
        }

        return (try? JSONDecoder().decode(
            BatteryHistoryData.self,
            from: data
        )) ?? BatteryHistoryData()
    }

    static func save(_ history: BatteryHistoryData) {
        do {
            let folder = fileURL
                .deletingLastPathComponent()

            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )

            let data = try JSONEncoder().encode(history)

            try data.write(
                to: fileURL,
                options: .atomic
            )
        } catch {
            print("Failed to save battery history: \(error)")
        }
    }
}
