
import Foundation

struct HistoricalScreenInterval: Decodable {
    let start: TimeInterval
    let duration: TimeInterval
    let screenOn: TimeInterval
}

enum HistoricalScreenRecovery {

    static func estimate(
        session: BatterySession,
        intervals: [HistoricalScreenInterval]
    ) -> (seconds: Double, coverage: Double)? {

        guard let end = session.end else {
            return nil
        }

        let startTime = session.start.timeIntervalSince1970
        let endTime = end.timeIntervalSince1970
        let total = endTime - startTime

        guard total > 0 else { return nil }

        var cursor = startTime
        var covered = 0.0
        var screenSeconds = 0.0

        let sorted = intervals.sorted { $0.start < $1.start }

        for interval in sorted {
            guard interval.duration > 0,
                  interval.duration <= 86400,
                  interval.screenOn >= 0,
                  interval.screenOn <= interval.duration else {
                continue
            }

            let intervalEnd = interval.start + interval.duration

            // Avoid counting overlapping records twice.
            let left = max(startTime, max(interval.start, cursor))
            let right = min(endTime, intervalEnd)

            guard right > left else { continue }

            let overlap = right - left
            let fraction = overlap / interval.duration

            screenSeconds += interval.screenOn * fraction
            covered += overlap
            cursor = right
        }

        guard covered > 0 else { return nil }

        return (
            seconds: min(screenSeconds, total),
            coverage: min(covered / total, 1.0)
        )
    }
}
