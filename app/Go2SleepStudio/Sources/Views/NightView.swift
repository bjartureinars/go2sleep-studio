import SwiftUI
import Charts

struct NightView: View {
    let night: Night
    var scrolls = true
    @State private var selected: Date?

    private var m: NightMetrics { night.metrics }
    private var point: SeriesPoint? {
        guard let selected else { return nil }
        return night.series.min { abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected)) }
    }
    private var stageAtSelection: Stage? {
        guard let selected else { return nil }
        return night.epochs.last { $0.start <= selected }?.stage
    }

    var body: some View {
        MaybeScroll(on: scrolls) {
            VStack(alignment: .leading, spacing: 16) {
                header
                metricGrid
                Card(title: "Sleep stages", symbol: "bed.double.fill", tint: Stage.light.color) {
                    HypnogramChart(epochs: night.epochs, selection: $selected).frame(height: 170)
                    HStack { StageLegend(); Spacer(); selectionReadout }
                    StageBreakdown(metrics: m)
                }
                Card(title: "Heart rate", symbol: "heart.fill", tint: Palette.heart) {
                    Chart {
                        ForEach(night.series) { p in
                            if let hr = p.hr { LineMark(x: .value("Time", p.date), y: .value("BPM", hr)).foregroundStyle(Palette.heart).interpolationMethod(.monotone) }
                        }
                        RuleMark(y: .value("Resting", m.restingHR)).foregroundStyle(Palette.heart.opacity(0.45)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        if let selected { RuleMark(x: .value("Sel", selected)).foregroundStyle(.secondary.opacity(0.5)) }
                    }
                    .chartXSelection(value: $selected)
                    .chartYScale(domain: hrDomain)
                    .frame(height: 150)
                    Text("Dashed line: resting heart rate \(Int(m.restingHR)) bpm (lowest 5-minute average) · average \(Int(m.hrAvg)) bpm").font(.caption).foregroundStyle(.secondary)
                }
                Card(title: "Blood oxygen", symbol: "lungs.fill", tint: Palette.oxygen) {
                    Chart {
                        ForEach(night.desats) { e in
                            RectangleMark(xStart: .value("Start", e.start), xEnd: .value("End", e.end)).foregroundStyle(Color.red.opacity(0.14))
                        }
                        ForEach(night.series) { p in
                            if let s = p.spo2 { LineMark(x: .value("Time", p.date), y: .value("SpO₂", s)).foregroundStyle(Palette.oxygen) }
                        }
                        RuleMark(y: .value("90%", 90)).foregroundStyle(.red.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        if let selected { RuleMark(x: .value("Sel", selected)).foregroundStyle(.secondary.opacity(0.5)) }
                    }
                    .chartXSelection(value: $selected)
                    .chartYScale(domain: max(70, Double(m.spo2Min) - 2)...100)
                    .frame(height: 150)
                    Text("\(night.desats.count) desaturation\(night.desats.count == 1 ? "" : "s") of 3 % or more (shaded) · ODI \(m.odi3, specifier: "%.1f")/h · \(m.t90Sec) s below 90 %").font(.caption).foregroundStyle(.secondary)
                }
                Card(title: "Movement", symbol: "figure.walk.motion", tint: Palette.motion) {
                    Chart {
                        ForEach(night.series) { p in
                            if p.motion > 0 { BarMark(x: .value("Time", p.date), y: .value("Motion", p.motion), width: .fixed(2)).foregroundStyle(Palette.motion) }
                        }
                        if let selected { RuleMark(x: .value("Sel", selected)).foregroundStyle(.secondary.opacity(0.5)) }
                    }
                    .chartXSelection(value: $selected)
                    .frame(height: 90)
                    Text("\(m.movementsPerHour, specifier: "%.1f") position changes per hour").font(.caption).foregroundStyle(.secondary)
                }
                Card(title: "Score breakdown", symbol: "chart.bar.doc.horizontal", tint: Palette.score(night.score.total)) {
                    ForEach(night.score.components) { c in
                        HStack {
                            Text(c.label).frame(width: 110, alignment: .leading)
                            ScoreBar(value: c.value)
                            Text("\(Int(c.value))").monospacedDigit().frame(width: 32, alignment: .trailing)
                            Text(c.detail).font(.caption).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
                        }
                    }
                    Text("Staging uses heart rate, movement and the ring's optical signals. It is experimental and has not been validated against a sleep lab.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem { Button { exportPDF() } label: { Label("Export PDF", systemImage: "square.and.arrow.up") }.help("Save this night as a PDF report") }
        }
        .navigationTitle("Night of " + night.nightOf.formatted(.dateTime.weekday(.wide).day().month(.wide)))
    }

    @MainActor private func exportPDF() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Sleep report " + night.nightOf.formatted(.iso8601.year().month().day()) + ".pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Self.writePDF(night: night, to: url)
    }

    @MainActor static func writePDF(night: Night, to url: URL) {
        let page = NightView(night: night, scrolls: false).frame(width: 1000).padding(10)
            .background(Color.white).environment(\.colorScheme, .light)
        let r = ImageRenderer(content: page)
        r.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil); draw(ctx); ctx.endPDFPage(); ctx.closePDF()
        }
    }

    private var hrDomain: ClosedRange<Double> {
        let v = night.series.compactMap(\.hr)
        guard let lo = v.min(), let hi = v.max() else { return 40...100 }
        return (lo - 4).rounded(.down)...(hi + 4).rounded(.up)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            ScoreRing(score: night.score.total)
            VStack(alignment: .leading, spacing: 8) {
                Text(summary).font(.title3.weight(.semibold))
                HStack(spacing: 16) {
                    Label("\(night.sleepOnset ?? night.start, format: .dateTime.hour().minute()) – \(night.wakeTime ?? night.end, format: .dateTime.hour().minute())", systemImage: "clock")
                    Label(m.tstMin.hm + " asleep", systemImage: "moon.zzz.fill")
                    Label("\(Int(m.efficiency))% efficiency", systemImage: "gauge.with.dots.needle.67percent")
                }
                .font(.callout).foregroundStyle(.secondary)
                if m.badSignalPct > 5 { Label(String(format: "%.0f%% of the night had poor signal", m.badSignalPct), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
        }
    }

    private var summary: String {
        let weakest = night.score.components.min { $0.value < $1.value }
        return "\(Palette.scoreWord(night.score.total)) night" + (weakest.map { " · weakest area: " + ($0.label.hasPrefix("REM") ? $0.label : $0.label.lowercased()) } ?? "")
    }

    private var metricGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            MetricTile(title: "Time asleep", value: m.tstMin.hm, symbol: "moon.fill", tint: Stage.light.color, footnote: "in bed " + m.inBedMin.hm)
            MetricTile(title: "Deep", value: String(format: "%.0f", m.pct(.deep)), unit: "%", symbol: "water.waves", tint: Stage.deep.color, footnote: (m.stageMin[.deep] ?? 0).hm)
            MetricTile(title: "REM", value: String(format: "%.0f", m.pct(.rem)), unit: "%", symbol: "eye.fill", tint: Stage.rem.color, footnote: m.remLatencyMin.map { "first after " + $0.hm } ?? "none detected")
            MetricTile(title: "Awake", value: m.wasoMin.hm, symbol: "sun.horizon.fill", tint: Stage.wake.color, footnote: "\(m.awakenings) wake-ups · fell asleep in \(m.latencyMin.hm)")
            MetricTile(title: "Resting HR", value: "\(Int(m.restingHR))", unit: "bpm", symbol: "heart.fill", tint: Palette.heart, footnote: "avg \(Int(m.hrAvg)) · min \(m.hrMin)")
            MetricTile(title: "SpO₂", value: String(format: "%.0f", m.spo2Avg), unit: "%", symbol: "lungs.fill", tint: Palette.oxygen, footnote: "lowest \(m.spo2Min)%")
            MetricTile(title: "ODI", value: String(format: "%.1f", m.odi3), unit: "/h", symbol: "wind", tint: m.odi3 >= 15 ? .red : (m.odi3 >= 5 ? .orange : Palette.perfusion), footnote: m.odi3 >= 15 ? "moderate+ desaturation" : (m.odi3 >= 5 ? "mild desaturation" : "normal range"))
            MetricTile(title: "Restlessness", value: String(format: "%.1f", m.movementsPerHour), unit: "/h", symbol: "figure.walk.motion", tint: Palette.motion, footnote: "position changes")
        }
    }

    @ViewBuilder private var selectionReadout: some View {
        if let p = point, let selected {
            HStack(spacing: 10) {
                Text(selected, format: .dateTime.hour().minute()).monospacedDigit()
                if let s = stageAtSelection { Text(s.name).foregroundStyle(s.color) }
                if let hr = p.hr { Text("\(Int(hr)) bpm").foregroundStyle(Palette.heart) }
                if let s = p.spo2 { Text("\(Int(s))%").foregroundStyle(Palette.oxygen) }
            }.font(.caption.weight(.semibold))
        }
    }
}

struct StageBreakdown: View {
    let metrics: NightMetrics
    var body: some View {
        let stages: [Stage] = [.deep, .light, .rem, .wake]
        let total = stages.map { metrics.stageMin[$0] ?? 0 }.reduce(0, +)
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(stages) { s in
                    let w = total > 0 ? (metrics.stageMin[s] ?? 0) / total : 0
                    RoundedRectangle(cornerRadius: 4).fill(s.color).frame(width: max(0, g.size.width * w - 2))
                        .overlay { if w > 0.08 { Text("\(s.name) \((metrics.stageMin[s] ?? 0).hm)").font(.caption2.weight(.semibold)).foregroundStyle(.white).lineLimit(1) } }
                }
            }
        }
        .frame(height: 24)
        .accessibilityLabel(stages.map { "\($0.name) \((metrics.stageMin[$0] ?? 0).hm)" }.joined(separator: ", "))
    }
}
