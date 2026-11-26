import SwiftUI
import Charts

extension Stage {
    var color: Color {
        switch self {
        case .wake: Color(red: 1.00, green: 0.58, blue: 0.30)
        case .rem: Color(red: 0.36, green: 0.80, blue: 0.98)
        case .light: Color(red: 0.36, green: 0.52, blue: 0.98)
        case .deep: Color(red: 0.40, green: 0.27, blue: 0.86)
        case .unscored: Color.gray.opacity(0.35)
        }
    }
    static let chartOrder: [Stage] = [.wake, .rem, .light, .deep]
}

enum Palette {
    static let heart = Color(red: 1.00, green: 0.33, blue: 0.42)
    static let oxygen = Color(red: 0.20, green: 0.72, blue: 1.00)
    static let motion = Color(red: 1.00, green: 0.75, blue: 0.20)
    static let perfusion = Color(red: 0.25, green: 0.85, blue: 0.60)
    static let battery = Color(red: 0.55, green: 0.85, blue: 0.35)
    static func score(_ s: Int) -> Color { s >= 85 ? Color(red: 0.25, green: 0.85, blue: 0.55) : s >= 70 ? Color(red: 0.36, green: 0.72, blue: 1.0) : s >= 55 ? Color(red: 1.0, green: 0.72, blue: 0.25) : Color(red: 1.0, green: 0.42, blue: 0.40) }
    static func scoreWord(_ s: Int) -> String { s >= 85 ? "Excellent" : s >= 70 ? "Good" : s >= 55 ? "Fair" : "Poor" }
}

/// Rounded card used for every dashboard section.
struct Card<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    var tint: Color = .secondary
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label(title, systemImage: symbol ?? "circle").font(.headline).foregroundStyle(tint).labelStyle(.titleAndIcon)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var unit: String = ""
    var symbol: String
    var tint: Color
    var footnote: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.medium)).foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                if !unit.isEmpty { Text(unit).font(.callout).foregroundStyle(.secondary) }
            }
            if let footnote { Text(footnote).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct ScoreRing: View {
    let score: Int
    var size: CGFloat = 140
    var body: some View {
        let c = Palette.score(score)
        ZStack {
            Circle().stroke(c.opacity(0.18), lineWidth: size * 0.1)
            Circle().trim(from: 0, to: CGFloat(score) / 100)
                .stroke(AngularGradient(colors: [c.opacity(0.6), c], center: .center), style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)").font(.system(size: size * 0.32, weight: .bold, design: .rounded)).monospacedDigit()
                Text(Palette.scoreWord(score)).font(.system(size: size * 0.11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Sleep score \(score) of 100, \(Palette.scoreWord(score))")
    }
}

struct StageLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(Stage.chartOrder) { s in
                HStack(spacing: 5) { RoundedRectangle(cornerRadius: 3).fill(s.color).frame(width: 12, height: 12); Text(s.name).font(.caption) }
            }
        }
    }
}

/// Hypnogram: one colored band per stage run, rows Awake / REM / Light / Deep.
struct HypnogramChart: View {
    let epochs: [Epoch]
    var selection: Binding<Date?>? = nil
    var compact = false
    struct Run: Identifiable { let id: Int; let stage: Stage; let start: Date; let end: Date }
    var runs: [Run] {
        var out: [Run] = []; var i = 0
        while i < epochs.count {
            var j = i; while j < epochs.count && epochs[j].stage == epochs[i].stage { j += 1 }
            if epochs[i].stage != .unscored { out.append(Run(id: i, stage: epochs[i].stage, start: epochs[i].start, end: epochs[j - 1].start.addingTimeInterval(30))) }
            i = j
        }
        return out
    }
    var body: some View {
        let chart = Chart(runs) { r in
            RectangleMark(xStart: .value("Start", r.start), xEnd: .value("End", r.end),
                          yStart: .value("Lo", Double(r.stage.level) + 0.08), yEnd: .value("Hi", Double(r.stage.level) + 0.92))
                .foregroundStyle(r.stage.color)
                .cornerRadius(compact ? 1 : 3)
        }
        .chartYScale(domain: 0...4)
        .chartYAxis {
            if !compact {
                AxisMarks(values: [0.5, 1.5, 2.5, 3.5]) { v in
                    AxisValueLabel { Text(["Deep", "Light", "REM", "Awake"][Int(v.as(Double.self) ?? 0)]).font(.caption) }
                }
            }
        }
        .chartXAxis(compact ? .hidden : .automatic)
        if let selection {
            chart.chartXSelection(value: selection)
                .chartOverlay { _ in EmptyView() }
        } else { chart }
    }
}

extension Double {
    var hm: String { let m = Int(self.rounded()); return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }
}

/// ScrollView that can be switched off (ImageRenderer cannot draw ScrollView content; used by snapshot mode).
struct MaybeScroll<Content: View>: View {
    var on: Bool
    @ViewBuilder var content: Content
    var body: some View { if on { ScrollView { content } } else { content } }
}

/// Colored horizontal bar for 0...100 values (drawn by hand so it renders everywhere, including snapshots).
struct ScoreBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(LinearGradient(colors: [Palette.score(Int(value)).opacity(0.7), Palette.score(Int(value))], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, g.size.width * min(1, max(0, value / 100))))
            }
        }
        .frame(height: 10)
        .accessibilityValue("\(Int(value)) of 100")
    }
}

extension Night {
    /// The evening a night belongs to ("night of"), so a session starting after midnight is grouped with the previous day.
    var nightOf: Date { Calendar.current.startOfDay(for: start.addingTimeInterval(-12 * 3600)) }
}
