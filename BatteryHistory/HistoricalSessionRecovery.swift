
import Foundation

enum HistoricalSessionRecovery {

    private struct PowerRun {
        let pluggedIn: Bool
        var samples: [BatterySample]

        var first: BatterySample {
            samples[0]
        }

        var last: BatterySample {
            samples[samples.count - 1]
        }

        var duration: TimeInterval {
            last.timestamp.timeIntervalSince(
                first.timestamp
            )
        }
    }

    static func recover(
        from samples: [BatterySample]
    ) -> [BatterySession] {

        let sorted = samples
            .filter {
                (0...100).contains($0.percentage)
            }
            .sorted {
                $0.timestamp < $1.timestamp
            }

        guard !sorted.isEmpty else {
            return []
        }

        // Group consecutive readings with the
        // same external-power connection state.
        var runs: [PowerRun] = []

        for sample in sorted {
            if let last = runs.indices.last,
               runs[last].pluggedIn == sample.isPluggedIn {

                runs[last].samples.append(sample)

            } else {
                runs.append(
                    PowerRun(
                        pluggedIn: sample.isPluggedIn,
                        samples: [sample]
                    )
                )
            }
        }

        guard runs.count >= 3 else {
            return []
        }

        var recovered: [BatterySession] = []

        // Require observed connected power before
        // and after each battery-powered interval.
        for index in 1..<(runs.count - 1) {

            let before = runs[index - 1]
            let battery = runs[index]
            let after = runs[index + 1]

            guard before.pluggedIn,
                  !battery.pluggedIn,
                  after.pluggedIn else {
                continue
            }

            let start = battery.first.timestamp
            let end = after.first.timestamp

            guard end > start else {
                continue
            }

            // Ignore very short disconnections.
            guard end.timeIntervalSince(start) >= 300,
                  battery.duration >= 60 else {
                continue
            }

            // Confirm that reconnection wasn't
            // merely a brief power-state fluctuation.
            guard after.duration >= 60 else {
                continue
            }

            var session = BatterySession(
                start: start,
                end: end,
                startPercent: battery.first.percentage,
                endPercent: after.first.percentage
            )

            // Our earlier PowerLog import contains
            // battery levels, not screen-on duration.
            session.screenOnSeconds = nil
            session.isHistoricalEstimate = true

            recovered.append(session)
        }

        return recovered
    }
}
