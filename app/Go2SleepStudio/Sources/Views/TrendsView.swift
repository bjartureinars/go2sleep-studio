import SwiftUI
import Charts

struct TrendsView: View {
    @Environment(DataStore.self) private var store
    var scrolls = true
    @AppStorage("sleepGoalHours") private var goal = 8.0

    /// Minutes after noon, so times around midnight average correctly (23:30 and 00:30 -> 00:00).
    private func onsetMinutes(_ n: Night) -> Double? {
        guard let d = n.sleepOnset else { return nil }
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return Double((((c.hour ?? 0) + 12) % 24) * 60 + (c.minute ?? 0))
    }
    private func clock(_ minutesAfterNoon: Double) -> String {
        let m = (Int(minutesAfterNoon.rounded()) + 12 * 60) % (24 * 60)
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
    private func onsetText(_ nights: ArraySlice<Night>) -> String {
        let v = nights.compactMap(onsetMinutes)
        return v.isEmpty ? "–" : clock(v.reduce(0, +) / Double(v.count))
    }
    private func onsetRange(_ nights: ArraySlice<Night>) -> String? {
        let v = nights.compactMap(onsetMinutes)
        guard let lo = v.min(), let hi = v.max() else { return nil }
        return "earliest \(clock(lo)) · latest \(clock(hi))"
    }

    struct StageSlice: Identifiable { let id = UUID(); let day: Date; let stage: Stage; let hours: Double }

    var body: some View {
        let nights = store.nights.sorted { $0.start < $1.start }
        let last7 = nights.suffix(7)
        let debt = last7.map { goal - $0.metrics.tstMin / 60 }.reduce(0, +)
        MaybeScroll(on: scrolls) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Trends").font(.largeTitle.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    MetricTile(title: "Avg score (7 nights)", value: last7.isEmpty ? "–" : "\(last7.map { $0.score.total }.reduce(0, +) / last7.count)", symbol: "star.fill", tint: .yellow)
                    MetricTile(title: "Avg sleep", value: last7.isEmpty ? "–" : (last7.map { $0.metrics.tstMin }.reduce(0, +) / Double(last7.count)).hm, symbol: "moon.fill", tint: Stage.light.color)
                    MetricTile(title: "Sleep debt (7 nights)", value: String(format: "%.1f", max(0, debt)), unit: "h", symbol: "hourglass", tint: debt > 3 ? .orange : Palette.perfusion, footnote: "goal \(goal.formatted()) h per night")
                    MetricTile(title: "Avg sleep onset (7 nights)", value: onsetText(last7), symbol: "bed.double.fill", tint: Stage.deep.color, footnote: onsetRange(last7))
                    MetricTile(title: "Resting HR", value: last7.isEmpty ? "–" : "\(Int(last7.map { $0.metrics.restingHR }.reduce(0, +) / Double(last7.count)))", unit: "bpm", symbol: "heart.fill", tint: Palette.heart)
                }
                Card(title: "Sleep score", symbol: "star.fill", tint: .yellow) {
                    Chart(nights) { n in
                        BarMark(x: .value("Night", n.nightOf, unit: .day), y: .value("Score", n.score.total))
                            .foregroundStyle(Palette.score(n.score.total)).cornerRadius(4)
                            .annotation(position: .top) { Text("\(n.score.total)").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .chartYScale(domain: 0...100).frame(height: 180)
                }
                Card(title: "Sleep stages per night", symbol: "bed.double.fill", tint: Stage.light.color) {
                    Chart(nights.flatMap { n in [Stage.deep, .light, .rem, .wake].map { StageSlice(day: n.nightOf, stage: $0, hours: (n.metrics.stageMin[$0] ?? 0) / 60) } }) { s in
                        BarMark(x: .value("Night", s.day, unit: .day), y: .value("Hours", s.hours))
                            .foregroundStyle(by: .value("Stage", s.stage.name)).cornerRadius(2)
                    }
                    .chartForegroundStyleScale(domain: ["Deep", "Light", "REM", "Awake"], range: [Stage.deep.color, Stage.light.color, Stage.rem.color, Stage.wake.color])
                    .chartYAxisLabel("hours")
                    .frame(height: 220)
                }
                HStack(spacing: 16) {
                    Card(title: "Resting heart rate", symbol: "heart.fill", tint: Palette.heart) {
                        Chart(nights) { n in
                            LineMark(x: .value("Night", n.nightOf, unit: .day), y: .value("BPM", n.metrics.restingHR)).foregroundStyle(Palette.heart).symbol(.circle)
                        }
                        .chartYScale(domain: .automatic(includesZero: false)).frame(height: 160)
                    }
                    Card(title: "Breathing disturbances", symbol: "wind", tint: Palette.oxygen) {
                        Chart(nights) { n in
                            BarMark(x: .value("Night", n.nightOf, unit: .day), y: .value("ODI", n.metrics.odi3)).foregroundStyle(Palette.oxygen.gradient)
                        }
                        .chartYAxisLabel("desaturations / h").frame(height: 160)
                    }
                }
                Card(title: "Lowest SpO₂ per night", symbol: "lungs.fill", tint: Palette.oxygen) {
                    Chart(nights) { n in
                        PointMark(x: .value("Night", n.nightOf, unit: .day), y: .value("Lowest", n.metrics.spo2Min)).foregroundStyle(Palette.oxygen).symbolSize(80)
                        RuleMark(y: .value("90", 90)).foregroundStyle(.red.opacity(0.4)).lineStyle(StrokeStyle(dash: [4, 4]))
                    }
                    .chartYScale(domain: 60...100).frame(height: 160)
                }
                Stepper("Sleep goal: \(goal.formatted()) h", value: $goal, in: 5...10, step: 0.5).frame(maxWidth: 260)
            }
            .padding(20)
        }
    }
}
