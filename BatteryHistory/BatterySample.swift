
import Foundation

struct BatterySample: Identifiable, Codable {
    var id = UUID()
    let timestamp: Date
    let percentage: Int
    let isPluggedIn: Bool
}

enum BatterySampleStore {
    static var fileURL: URL {
        BatteryHistoryStorage.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("batterySamples.json")
    }

    static func load() -> [BatterySample] {
        guard let data = try? Data(contentsOf: fileURL),
              let samples = try? JSONDecoder().decode(
                [BatterySample].self,
                from: data
              ) else {
            return []
        }

        return samples
    }

    static func save(_ samples: [BatterySample]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let data = try JSONEncoder().encode(samples)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Battery sample save failed:", error)
        }
    }
}
