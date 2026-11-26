import Foundation

enum Stage: Int, CaseIterable, Identifiable {
    case unscored = -1, wake = 0, light = 1, deep = 2, rem = 3
    var id: Int { rawValue }
    var name: String { switch self { case .wake: "Awake"; case .light: "Light"; case .deep: "Deep"; case .rem: "REM"; case .unscored: "No signal" } }
    /// Row in a hypnogram, top to bottom: Awake, REM, Light, Deep.
    var level: Int { switch self { case .wake: 3; case .rem: 2; case .light: 1; case .deep: 0; case .unscored: -1 } }
}

struct Epoch {
    let start: Date
    var hr: Double?          // median valid HR
    var hrSD: Double = 0
    var act: Double = 0      // seconds with motion (0...30)
    var spo2Min: Double?
    var x10: Double = 0
    var sRough: Double = 0
    var wakeScore: Double = 0
    var stage: Stage = .unscored
    /// Posterior probability of `stage` from HMM forward-backward (1 for rule-scored wake, 0 when unscored).
    var confidence: Double = 0
}

/// One SpO2 desaturation. `drop` = baseline − nadir (%), `area` = Σ(baseline − SpO2) over the event (%·s).
struct DesatEvent: Identifiable { let id = UUID(); let start: Date; let end: Date; let nadir: Int; let drop: Int; var area: Double = 0 }

struct SeriesPoint: Identifiable { let id: Int; let date: Date; let hr: Double?; let spo2: Double?; let motion: Double; let x10: Double }

struct NightMetrics {
    var inBedMin = 0.0, tstMin = 0.0, latencyMin = 0.0, wasoMin = 0.0, efficiency = 0.0
    var stageMin: [Stage: Double] = [:]
    var remLatencyMin: Double?
    var awakenings = 0
    var longAwakenings = 0             // wake bouts >= 2 min inside the sleep period
    var hrAvg = 0.0, hrMin = 0, restingHR = 0.0
    var hrNadirFraction: Double?       // time of lowest 5-min HR as a fraction of the sleep period
    var spo2Avg = 0.0, spo2Min = 0, t90Sec = 0
    var spo2ValidMin = 0.0
    var odi3 = 0.0, odi4 = 0.0
    var hypoxicBurden = 0.0            // %·min per hour of sleep (Azarbarzin 2019 style, simplified)
    var movementsPerHour = 0.0
    var badSignalPct = 0.0
    var stageConfidence = 0.0          // mean posterior of the reported stage over sleep epochs
    var sleepMidpoint: Date?
    var flags: [String] = []           // e.g. "atypical REM", "SOREMP"
    func pct(_ s: Stage) -> Double { tstMin > 0 ? 100 * (stageMin[s] ?? 0) / tstMin : 0 }
}

struct ScoreComponent: Identifiable { let id: String; let label: String; let value: Double; let weight: Double; let detail: String }
struct SleepScore { let total: Int; let components: [ScoreComponent] }

/// Per-user reference values from preceding nights (used by the timing and restoration score components).
struct PersonalBaseline {
    var midpointMin: Double?   // median sleep midpoint, minutes after 12:00
    var lowHR: Double?         // median lowest 5-min sleep HR
}

struct Night: Identifiable {
    var id: Date { start }
    let start: Date
    let end: Date
    let epochs: [Epoch]
    let series: [SeriesPoint]
    let desats: [DesatEvent]
    let metrics: NightMetrics
    let score: SleepScore
    var sleepOnset: Date?
    var wakeTime: Date?
}

/// Dense 1 Hz arrays for one night (index = seconds since the night start). Missing seconds: hr = NaN, spo2 = 0.
struct NightSeconds {
    var hr: [Double], motion: [Double], x10: [Double], signal: [Double], spo2: [Int], present: [Bool]
    init(count: Int) {
        hr = .init(repeating: .nan, count: count); motion = .init(repeating: 0, count: count); x10 = .init(repeating: 0, count: count)
        signal = .init(repeating: .nan, count: count); spo2 = .init(repeating: 0, count: count); present = .init(repeating: false, count: count)
    }
}

/// Transparent, on-device staging (spec: research/staging_research.md):
/// Cole–Kripke + movement/HR-supported Webster wake, Walch-style HR features, a cycle-aware expanded-state HMM
/// (forward-backward, posterior-marginal decoding) and soft per-night proportion calibration.
/// Not validated against polysomnography.
enum SleepEngine {
    static let epochLen = 30
    static let ckWeights: [Double] = [106, 54, 58, 76, 230, 74, 67]   // t-4 ... t+2
    static let wakeThreshold = 0.20
    static let minWakeEpochs = 2

    static func analyse(records: [SecondRecord]) -> [Night] {
        guard !records.isEmpty else { return [] }
        var sessions: [[SecondRecord]] = []; var cur: [SecondRecord] = [records[0]]
        for r in records.dropFirst() {
            if r.t - cur.last!.t > 600 { sessions.append(cur); cur = [] }
            cur.append(r)
        }
        sessions.append(cur)
        let nights = sessions.filter { Int($0.last!.t - $0.first!.t) >= 3600 }.map(analyseNight).sorted { $0.start < $1.start }
        // Second pass: personal baselines from up to 14 preceding nights (causal, deterministic).
        var out: [Night] = []
        for (i, n) in nights.enumerated() {
            let prev = nights[max(0, i - 14)..<i].map(\.metrics).filter { $0.tstMin >= 180 }
            var base = PersonalBaseline()
            if prev.count >= 3 {
                let mids = prev.compactMap { $0.sleepMidpoint.map(minutesAfterNoon) }
                if mids.count >= 3 { base.midpointMin = median(mids) }
                let lows = prev.map(\.restingHR).filter { $0 > 0 }
                if lows.count >= 3 { base.lowHR = median(lows) }
            }
            out.append(Night(start: n.start, end: n.end, epochs: n.epochs, series: n.series, desats: n.desats, metrics: n.metrics,
                             score: score(n.metrics, baseline: base), sleepOnset: n.sleepOnset, wakeTime: n.wakeTime))
        }
        return out.sorted { $0.start > $1.start }
    }

    // MARK: per night
    static func analyseNight(_ recs: [SecondRecord]) -> Night {
        let t0 = Int(recs.first!.t), n = (Int(recs.last!.t) - t0) / epochLen + 1, N = n * epochLen
        var sec = NightSeconds(count: N)
        for r in recs {
            let i = Int(r.t) - t0; guard i >= 0 && i < N else { continue }
            sec.present[i] = true
            if r.hr >= 35 && r.hr <= 130 { sec.hr[i] = Double(r.hr) }
            sec.motion[i] = Double(r.motion); sec.x10[i] = Double(r.x10); sec.signal[i] = Double(r.signalS)
            if r.spo2 > 0 { sec.spo2[i] = Int(r.spo2) }
        }
        var ep: [Epoch] = []; ep.reserveCapacity(n)
        for e in 0..<n {
            var x = Epoch(start: Date(timeIntervalSince1970: TimeInterval(t0 + e * epochLen)))
            let r = (e * epochLen)..<((e + 1) * epochLen)
            let hrs = r.map { sec.hr[$0] }.filter { !$0.isNaN }
            if hrs.count >= 20 { x.hr = median(hrs); x.hrSD = sd(hrs) }
            x.act = Double(r.filter { sec.motion[$0] > 0 }.count)
            x.spo2Min = r.compactMap { sec.spo2[$0] > 0 ? Double(sec.spo2[$0]) : nil }.min()
            let pres = r.filter { sec.present[$0] }
            x.x10 = pres.isEmpty ? 0 : pres.map { sec.x10[$0] }.reduce(0, +) / Double(pres.count)
            let d = r.dropFirst().compactMap { i -> Double? in let v = abs(sec.signal[i] - sec.signal[i - 1]); return v.isNaN ? nil : v }
            if d.count > 1 { x.sRough = d.reduce(0, +) / Double(d.count) }
            ep.append(x)
        }
        let flags = stage(&ep, sec: sec)
        let desats = detectDesats(recs)
        var m = metrics(ep, recs, desats)
        m.flags = flags
        let series = downsample(recs, t0: t0, step: 10)
        let onset = ep.firstIndex { [.light, .deep, .rem].contains($0.stage) }.map { ep[$0].start }
        let wake = ep.lastIndex { [.light, .deep, .rem].contains($0.stage) }.map { ep[$0].start.addingTimeInterval(30) }
        m.badSignalPct = 100 * Double(ep.filter { $0.stage == .unscored }.count) / Double(max(1, ep.count))
        return Night(start: Date(timeIntervalSince1970: TimeInterval(t0)), end: Date(timeIntervalSince1970: TimeInterval(recs.last!.t)),
                     epochs: ep, series: series, desats: desats, metrics: m, score: score(m), sleepOnset: onset, wakeTime: wake)
    }

    // MARK: staging

    /// Emission parameters [Light, Deep, REM] in night-normalised units (research §4.3 table).
    private static let muHRL = [0.2, -0.4, 1.0], sdHRL = [0.8, 0.5, 0.8]
    private static let muInst = [0.0, -1.0, 0.8], sdInst = [0.9, 0.6, 0.9]
    private static let lamBurst = [0.25, 0.025, 0.04]   // spec λ for ±5 min, halved for the ±2.5-min window
    private static let muStill = [1.5, 2.4, 2.2], sdStill = [0.9, 0.6, 0.7]
    private static let muX10 = [0.1, -0.6, 0.1], sdX10 = [1.0, 0.8, 1.0]
    private static let muSR = [0.1, -0.5, 0.1], sdSR = [1.0, 0.8, 1.0]

    struct Features { var hrLocal, hrInst, burst, burst2, still, x10z, srz: [Double]; var localFloor: [Bool] }

    /// Stages the epochs in place and returns night-level flags.
    @discardableResult
    static func stage(_ ep: inout [Epoch], sec: NightSeconds) -> [String] {
        let n = ep.count
        guard n > 40 else { for i in ep.indices { ep[i].stage = ep[i].hr == nil ? .unscored : .light; ep[i].confidence = 0.5 }; return [] }
        var flags: [String] = []
        let bad = ep.map { $0.hr == nil }

        // 1. Wake: Cole–Kripke weighted activity (1992), threshold recalibrated for "fraction of seconds moving".
        let a = ep.map { $0.act / Double(epochLen) }
        var wake = [Bool](repeating: false, count: n)
        let wsum = ckWeights.reduce(0, +)
        for i in 0..<n {
            var s = 0.0
            for (k, w) in ckWeights.enumerated() { let j = i + k - 4; if j >= 0 && j < n { s += w * a[j] } }
            ep[i].wakeScore = s / wsum; wake[i] = ep[i].wakeScore > wakeThreshold
        }
        // Note: an HDCZA-style sleep-period window (van Hees 2018) was tried and dropped: on this ring the morning light
        // sleep moves often enough that the window truncated real sleep. C–K + Webster handle wake instead.

        // 2. Features (research §2.1)
        var sleepRef = (0..<n).map { !wake[$0] && !bad[$0] }
        if sleepRef.filter({ $0 }).count < 40 { sleepRef = bad.map { !$0 } }
        let f = features(ep, sec: sec, sleepRef: sleepRef)
        // Webster 1982 rescoring, applied only to epochs with evidence of wake (motion within ±1 epoch or HR well above
        // the sleep floor), so a quiet sleeper's efficiency is not cut by the rule alone.
        let support = (0..<n).map { t in (max(0, t - 1)...min(n - 1, t + 1)).contains { a[$0] > 0 } || f.hrLocal[t] > 1.5 }
        webster(&wake, support: support)
        dropShortRuns(&wake, value: true, minLen: minWakeEpochs)

        // HR-rise wake: quiet wake lying still that C–K misses (§4.2.3). Only where the HR floor comes from >= 20 min of
        // preceding sleep: early in the night HR is naturally above the whole-night floor, which is not evidence of wake.
        var i = 0
        func rise(_ t: Int) -> Bool { !wake[t] && f.localFloor[t] && f.hrLocal[t] > 2.5 }
        while i < n {
            if rise(i) {
                var j = i; while j < n && rise(j) { j += 1 }
                if j - i >= 3 && (i..<j).contains(where: { f.burst2[$0] >= 1 }) { for k in i..<j { wake[k] = true } }
                i = j
            } else { i += 1 }
        }

        // Sleep onset: first 10-min window with >= 9 min of sleep (AASM-like persistent sleep).
        var onset = wake.firstIndex(of: false) ?? 0
        for s in 0..<(n - 20) where (s..<(s + 20)).filter({ !wake[$0] }).count >= 18 { onset = s; break }
        let lastSleep = wake.lastIndex(of: false) ?? n - 1
        let hours = (0..<n).map { max(0, Double($0 - onset) * Double(epochLen) / 3600) }
        let clock = (0..<n).map { Double($0 - onset) * Double(epochLen) / 3600 }   // < 0 before onset: cycle clock frozen

        // Long signal gaps (> 3 min) become Unscored; short ones are imputed by the HMM from movement only (§4.6.5).
        var longBad = [Bool](repeating: false, count: n)
        i = 0
        while i < n { if bad[i] { var j = i; while j < n && bad[j] { j += 1 }; if j - i > 6 { for k in i..<j { longBad[k] = true } }; i = j } else { i += 1 } }

        // 3. Log-emissions per epoch over [W, L, D, R]; wake is fixed by the rules above.
        // Feature rows × [Light, Deep, REM] means (last row: Poisson λ of bursts); adapted per night below.
        let gauss: [[Double]] = [f.hrLocal, f.hrInst, f.still, f.x10z, f.srz, f.burst]
        let priorMu = [muHRL, muInst, muStill, muX10, muSR, lamBurst], sds = [sdHRL, sdInst, sdStill, sdX10, sdSR]
        let quality = (0..<n).map { t -> Double in let r = max(0, t - 5)...min(n - 1, t + 5); return Double(r.filter { !bad[$0] }.count) / Double(r.count) }
        func emissions(_ mu: [[Double]]) -> [[Double]] {
            var out = [[Double]](repeating: [0, 0, 0, 0], count: n)
            for t in 0..<n {
                if wake[t] { out[t] = [0, -.infinity, -.infinity, -.infinity]; continue }
                var l = [-Double.infinity, 0, 0, 0]
                if !longBad[t] && !bad[t] {   // short bad-signal gaps: uninformative, imputed by the HMM from neighbours
                    for s in 0..<3 {
                        // burst counts and stillness come from overlapping windows, so each is down-weighted by 0.5
                        var v = 0.5 * poissonLog(f.burst[t], mu[5][s]) + 0.5 * gaussLog(f.still[t], mu[2][s], sds[2][s])
                        // optical/HR terms scaled by local signal quality (share of scorable epochs within ±5 epochs)
                        v += quality[t] * (studentLog(f.hrLocal[t], mu[0][s], sds[0][s]) + studentLog(f.hrInst[t], mu[1][s], sds[1][s])
                            + 0.5 * gaussLog(f.x10z[t], mu[3][s], sds[3][s]) + 0.5 * gaussLog(f.srz[t], mu[4][s], sds[4][s]))
                        l[s + 1] = v
                    }
                }
                // N3 time prior (§3): concentrated early, rarely reached within 10 min of onset.
                l[2] += log(min(1, max(0.1, exp(-hours[t] / 2.5)))) + (t >= onset && t - onset < 20 ? log(0.5) : 0)
                out[t] = l
            }
            return out
        }
        let scoredSleep = (0..<n).filter { $0 >= onset && $0 <= lastSleep && !wake[$0] && !longBad[$0] }

        // 4. Cycle-aware HMM + soft proportion calibration (§4.3, §4.5).
        let hmm = CycleHMM(hours: clock)
        // Unsupervised per-night adaptation of emission means (§4.4): MAP update μ = (n·μ̂ + κ·μ₀)/(n + κ), κ = 200 epochs,
        // with ordering constraints hrLocal D < L < R and hrInst D < L ≤ R (revert to the prior if violated).
        var mu = priorMu
        var baseE = emissions(mu)
        let hrEpochs = scoredSleep.filter { !bad[$0] }
        if hrEpochs.count > 120 {
            for _ in 0..<2 {
                let g = hmm.posteriors(baseE)
                var next = priorMu
                for fi in 0..<gauss.count {
                    for s in 0..<3 {
                        var w = 0.0, sx = 0.0
                        for t in (fi == 2 || fi == 5 ? scoredSleep : hrEpochs) { let p = g[t][s + 1]; w += p; sx += p * gauss[fi][t] }
                        if w > 0 { next[fi][s] = (sx + 200 * priorMu[fi][s]) / (w + 200) }
                    }
                }
                if !(next[0][1] < next[0][0] && next[0][0] < next[0][2]) { next[0] = priorMu[0] }
                if !(next[1][1] < next[1][0] && next[1][0] <= next[1][2]) { next[1] = priorMu[1] }
                mu = next; baseE = emissions(mu)
            }
        }
        func biased(_ bR: Double, _ bD: Double) -> [[Double]] { baseE.map { [$0[0], $0[1], $0[2] + bD, $0[3] + bR] } }
        // Decoding by posterior marginals (MPM), not Viterbi: in a single best path the Erlang phase clock is cheaper
        // to hold (log(1−q) per epoch) than to advance (log q per bin), so Viterbi effectively disables the cycle prior.
        // Forward-backward sums over phase correctly. Posteriors are averaged over ±1 min before the argmax.
        func decode(_ post: [[Double]]) -> [Stage] {
            (0..<n).map { t in
                if wake[t] { return .wake }
                var acc = [0.0, 0, 0, 0]
                for k in max(0, t - 2)...min(n - 1, t + 2) where !wake[k] { for c in 1...3 { acc[c] += post[k][c] } }
                return [Stage.wake, .light, .deep, .rem][(1...3).max { acc[$0] < acc[$1] }!]
            }
        }
        func fractions(_ bR: Double, _ bD: Double) -> (rem: Double, deep: Double) {
            // Calibrated on the decoded hypnogram so the reported percentages are the quantity the bias controls;
            // the |β| <= 1 cap keeps this a prior nudge, not a quota.
            let st = decode(hmm.posteriors(biased(bR, bD))); var r = 0.0, d = 0.0
            for t in scoredSleep { if st[t] == .rem { r += 1 } else if st[t] == .deep { d += 1 } }
            let c = Double(max(1, scoredSleep.count)); return (r / c, d / c)
        }
        func calibrate(_ band: ClosedRange<Double>, _ pick: (Double) -> Double) -> (Double, Bool) {
            let r0 = pick(0); guard !band.contains(r0) else { return (0, false) }
            let target = r0 < band.lowerBound ? band.lowerBound : band.upperBound
            var lo = -1.5, hi = 1.5
            for _ in 0..<12 { let mid = (lo + hi) / 2; if pick(mid) < target { lo = mid } else { hi = mid } }
            let b = (lo + hi) / 2
            return (max(-1, min(1, b)), abs(b) > 1)
        }
        var bR = 0.0, bD = 0.0, capR = false, capD = false
        if scoredSleep.count > 60 {
            (bR, capR) = calibrate(0.15...0.27) { fractions($0, bD).rem }
            (bD, capD) = calibrate(0.08...0.25) { fractions(bR, $0).deep }
            (bR, capR) = calibrate(0.15...0.27) { fractions($0, bD).rem }
        }
        if capR { flags.append("atypical REM") }
        if capD { flags.append("atypical deep") }
        let finalE = biased(bR, bD)
        let post = hmm.posteriors(finalE)
        var st = decode(post)

        // 5. Post-processing (§4.6)
        // No REM in the first 45 min after onset (§4.6.2). Strongly supported early REM is flagged as a possible SOREMP,
        // but still shown as Light: on this ring it is more often quiet wake lying still with an elevated HR.
        i = onset
        while i < min(n, onset + 90) {
            if st[i] == .rem {
                var j = i; while j < n && st[j] == .rem { j += 1 }
                if j - i >= 20 && (i..<j).allSatisfy({ post[$0][3] > 0.8 }) && !flags.contains("possible SOREMP") { flags.append("possible SOREMP") }
                for k in i..<j { st[k] = .light }
                i = j
            } else { i += 1 }
        }
        // Deep directly adjacent to REM -> Light buffer.
        for t in 0..<n where st[t] == .deep && ((t > 0 && st[t - 1] == .rem) || (t + 1 < n && st[t + 1] == .rem)) { st[t] = .light }
        // Last 15 min before final awakening cannot be Deep unless HR is at the floor.
        for t in max(0, lastSleep - 29)...lastSleep where st[t] == .deep && f.hrLocal[t] >= -0.5 { st[t] = .light }
        // REM bouts < 3 min and isolated Deep < 2 min -> Light.
        relabelShortRuns(&st, .rem, minLen: 6, to: .light)
        relabelShortRuns(&st, .deep, minLen: 4, to: .light)
        for t in 0..<n where longBad[t] { st[t] = .unscored }

        for t in 0..<n {
            ep[t].stage = st[t]
            switch st[t] {
            case .unscored: ep[t].confidence = 0
            case .wake: ep[t].confidence = wake[t] ? 1 : post[t][0]
            default: ep[t].confidence = post[t][st[t].rawValue]
            }
        }
        return flags
    }

    /// Night-normalised per-epoch features (research §2.1).
    static func features(_ ep: [Epoch], sec: NightSeconds, sleepRef: [Bool]) -> Features {
        let n = ep.count, N = sec.hr.count
        // hrLocal: 2.5-min median HR above the floor of the preceding hour of sleep, in robust SD units.
        let ehr = interpolate(ep.map { $0.hr })
        let hr5 = rolling(ehr, 5, median)
        let refHR = (0..<n).filter { sleepRef[$0] }.map { ehr[$0] }
        let globalFloor = percentile(refHR, 0.10)
        let m0 = median(refHR)
        let rsd = max(1.5, 1.4826 * median(refHR.map { abs($0 - m0) }))
        var hrLocal = [Double](repeating: 0, count: n), localFloor = [Bool](repeating: false, count: n)
        for e in 0..<n {
            let w = (max(0, e - 120)..<e).filter { sleepRef[$0] }.map { ehr[$0] }
            localFloor[e] = w.count >= 40
            let floor = localFloor[e] ? percentile(w, 0.10) : globalFloor
            hrLocal[e] = clampZ((hr5[e] - floor) / rsd)
        }
        // hrInst: Walch-style band-pass (Gauss σ=10 s − Gauss σ=120 s) of 1 Hz HR, SD over ±2.5 min, log, night z.
        // Seconds from 10 s before to 60 s after any motion are excluded: movement-evoked HR surges are not REM instability.
        var nearMotion = [Bool](repeating: false, count: N)
        for s in 0..<N where sec.motion[s] > 0 { for k in max(0, s - 10)..<min(N, s + 61) { nearMotion[k] = true } }
        let validHR = (0..<N).map { !sec.hr[$0].isNaN }
        let instOK = (0..<N).map { validHR[$0] && !nearMotion[$0] }
        let hr1 = interpolate(sec.hr.map { $0.isNaN ? nil : $0 })
        let g10 = gaussSmooth(hr1, sigma: 10), g120 = gaussSmooth(hr1, sigma: 120)
        var c1 = [Double](repeating: 0, count: N + 1), c2 = c1, cn = c1
        for s in 0..<N {
            let v = instOK[s] ? g10[s] - g120[s] : 0, k = instOK[s] ? 1.0 : 0
            c1[s + 1] = c1[s] + v; c2[s + 1] = c2[s] + v * v; cn[s + 1] = cn[s] + k
        }
        var inst = [Double?](repeating: nil, count: n)
        for e in 0..<n {
            let lo = max(0, (e - 5) * epochLen), hi = min(N, (e + 6) * epochLen)
            let k = cn[hi] - cn[lo]; guard k >= 60 else { continue }
            let mu = (c1[hi] - c1[lo]) / k, v = max(0, (c2[hi] - c2[lo]) / k - mu * mu)
            inst[e] = log(sqrt(v) + 0.05)
        }
        let hrInst = robustZ(interpolate(inst), sleepRef)
        // Movement: gross-movement bursts within ±2.5 min and ±2 min (±5 min in the spec; halved to limit smoothing); stillness = log1p(min since the last burst).
        // A burst is a run of motion > 0 whose peak is >= 10; weaker 5-s runs are treated as twitches, which REM atonia allows (§2.2).
        var gross = [Bool](repeating: false, count: N)
        var s0 = 0
        while s0 < N {
            if sec.motion[s0] > 0 {
                var j = s0, peak = 0.0; while j < N && sec.motion[j] > 0 { peak = max(peak, sec.motion[j]); j += 1 }
                if peak >= 10 { for k in s0..<j { gross[k] = true } }
                s0 = j
            } else { s0 += 1 }
        }
        var bc = [Double](repeating: 0, count: N + 1)
        var last = -1_000_000
        var still = [Double](repeating: 0, count: n)
        for s in 0..<N {
            let start = gross[s] && (s == 0 || !gross[s - 1])
            bc[s + 1] = bc[s] + (start ? 1 : 0)
            if gross[s] { last = s }
            if (s + 1) % epochLen == 0 { still[s / epochLen] = log1p(Double(min(1800, s - last)) / 60) }
        }
        func bursts(_ e: Int, _ w: Int) -> Double { bc[min(N, (e + w + 1) * epochLen)] - bc[max(0, (e - w) * epochLen)] }
        let burst = (0..<n).map { bursts($0, 5) }, burst2 = (0..<n).map { bursts($0, 4) }
        let x10z = robustZ(rolling(ep.map { $0.x10 }, 5, mean), sleepRef)
        let srz = robustZ(rolling(ep.map { $0.sRough }, 5, mean), sleepRef)
        return Features(hrLocal: hrLocal, hrInst: hrInst, burst: burst, burst2: burst2, still: still, x10z: x10z, srz: srz, localFloor: localFloor)
    }

    /// Webster et al. 1982 rescoring rules on 30-s epochs (minutes × 2).
    static func webster(_ w: inout [Bool], support: [Bool]) {
        let n = w.count, orig = w
        var i = 0
        while i < n {   // (a)-(c): after >=4/10/15 min wake, the next 1/3/4 min of sleep -> wake
            if orig[i] {
                var j = i; while j < n && orig[j] { j += 1 }
                let len = j - i, k = len >= 30 ? 8 : (len >= 20 ? 6 : (len >= 8 ? 2 : 0))
                for m in j..<min(n, j + k) { if !support[m] { break }; w[m] = true }
                i = j
            } else { i += 1 }
        }
        // (d): <=6 min sleep between >=10 min wake, or <=10 min between >=20 min wake -> wake
        var runs: [(v: Bool, s: Int, len: Int)] = []; i = 0
        while i < n { var j = i; while j < n && w[j] == w[i] { j += 1 }; runs.append((w[i], i, j - i)); i = j }
        for r in 1..<max(1, runs.count - 1) where !runs[r].v {
            let p = runs[r - 1].len, q = runs[r + 1].len, s = runs[r].len
            if ((s <= 12 && p >= 20 && q >= 20) || (s <= 20 && p >= 40 && q >= 40)) && (runs[r].s..<(runs[r].s + s)).contains(where: { support[$0] }) {
                for k in runs[r].s..<(runs[r].s + s) { w[k] = true }
            }
        }
    }

    // MARK: cycle-aware HMM

    /// Expanded-state HMM (research §4.3): W_k, L_k, D_k carry "time since the last REM" in 12 phase bins (~10 min each);
    /// R_0…R_5 is a REM duration chain (Erlang-like minimum bout ≈ 5 min, mature REM lengthens across the night).
    struct CycleHMM {
        static let K = 12, M = 6, S = 3 * K + M
        static func w(_ k: Int) -> Int { k }
        static func l(_ k: Int) -> Int { K + k }
        static func d(_ k: Int) -> Int { 2 * K + k }
        static func r(_ m: Int) -> Int { 3 * K + m }
        /// 0 W, 1 L, 2 D, 3 R
        static func stageOf(_ s: Int) -> Int { s < 3 * K ? s / K : 3 }
        /// Entry probability Light -> REM per epoch by phase bin (min since last REM: 0-30, 30-50, 50-70, 70-90, 90+).
        static let pLR: [Double] = [0.0005, 0.0005, 0.0005, 0.003, 0.003, 0.012, 0.012, 0.025, 0.025, 0.030, 0.030, 0.030]
        static let stageIdx: [Int] = (0..<S).map(stageOf)

        let from: [Int], to: [Int]
        let p: [[Double]]   // per epoch, transition into epoch t

        /// N3 sits early in each cycle and REM at its end (research §3): Light -> Deep entry is scaled down, and Deep -> Light
        /// exit up, as the time since the last REM grows. [design choice: ×1 for 0-60 min, ×0.5 for 60-90, ×0.25 beyond]
        static let n3Phase: [Double] = [1, 1, 1, 1, 1, 1, 0.5, 0.5, 0.5, 0.25, 0.25, 0.25]

        /// `h` = hours since sleep onset; negative before onset, where the cycle clock does not advance.
        static func edges(h: Double) -> [(Int, Int, Double)] {
            var e: [(Int, Int, Double)] = []
            let q = h < 0 ? 0 : 0.05, hp = max(0, h), pLD = 0.025 * exp(-hp / 3)
            let dest: [(Int) -> Int] = [w, l, d]
            for k in 0..<K {
                let pr = pLR[k] * (hp < 1 ? 0.5 : 1)
                let rows: [(src: Int, out: [Double], rem: Double)] = [
                    (w(k), [0, 0.20, 0.005], 0.003 * pr / 0.03),
                    (l(k), [0.012, 0, pLD * n3Phase[k]], pr),
                    (d(k), [0.004, 0.035 / n3Phase[k], 0], 0)]
                for (ri, row) in rows.enumerated() {
                    var probs = row.out; probs[ri] = 1 - probs.reduce(0, +) - row.rem
                    for (y, py) in probs.enumerated() where py > 0 {
                        if k < K - 1 && q > 0 { e.append((row.src, dest[y](k), py * (1 - q))); e.append((row.src, dest[y](k + 1), py * q)) }
                        else { e.append((row.src, dest[y](k), py)); if k < K - 1 { e.append((row.src, dest[y](k + 1), 0)) } }
                    }
                    if row.rem > 0 { e.append((row.src, r(0), row.rem)) }
                }
            }
            // REM chain: 5 sub-states of mean 2 epochs (≈ 5-min minimum bout, as §4.3 intends); mature REM mean
            // 4 epochs early rising to 20 epochs after 6 h, so bouts run ~7 min early to ~15 min late.
            let sR = 1 - 1 / (4 + 16 * min(1, max(0, (hp - 2) / 4)))
            for m in 0..<(M - 1) { e += [(r(m), r(m), 0.5), (r(m), r(m + 1), 0.49), (r(m), w(0), 0.01)] }
            e += [(r(M - 1), r(M - 1), sR - 0.01), (r(M - 1), l(0), 1 - sR), (r(M - 1), w(0), 0.01)]
            return e
        }

        init(hours: [Double]) {
            let e0 = Self.edges(h: 0)
            from = e0.map { $0.0 }; to = e0.map { $0.1 }
            p = hours.map { Self.edges(h: $0).map { $0.2 } }
        }

        private func prior(_ s: Int) -> Double { s == Self.w(0) || s == Self.l(0) ? 0.5 : 0 }

        /// Forward-backward (scaled); returns per-epoch posteriors collapsed to [W, L, D, R].
        func posteriors(_ logE: [[Double]]) -> [[Double]] {
            let n = logE.count, S = Self.S, E = from.count
            var em = [Double](repeating: 0, count: n * S)
            for t in 0..<n {
                let mx = logE[t].max()!
                let ex = logE[t].map { $0.isFinite ? exp($0 - mx) : 0 }
                for s in 0..<S { em[t * S + s] = ex[Self.stageIdx[s]] }
            }
            var alpha = [Double](repeating: 0, count: n * S), beta = alpha
            var z = 0.0
            for s in 0..<S { alpha[s] = prior(s) * em[s]; z += alpha[s] }
            for s in 0..<S { alpha[s] /= max(z, 1e-300) }
            for t in 1..<n {
                let pt = p[t], b0 = (t - 1) * S, b1 = t * S
                for i in 0..<E { alpha[b1 + to[i]] += alpha[b0 + from[i]] * pt[i] }
                z = 0; for s in 0..<S { alpha[b1 + s] *= em[b1 + s]; z += alpha[b1 + s] }
                if z <= 0 { for s in 0..<S { alpha[b1 + s] = em[b1 + s] }; z = (0..<S).reduce(0) { $0 + alpha[b1 + $1] } }
                for s in 0..<S { alpha[b1 + s] /= max(z, 1e-300) }
            }
            for s in 0..<S { beta[(n - 1) * S + s] = 1 }
            for t in stride(from: n - 2, through: 0, by: -1) {
                let pt = p[t + 1], b0 = t * S, b1 = (t + 1) * S
                for i in 0..<E { beta[b0 + from[i]] += pt[i] * em[b1 + to[i]] * beta[b1 + to[i]] }
                z = 0; for s in 0..<S { z += beta[b0 + s] }
                if z <= 0 { for s in 0..<S { beta[b0 + s] = 1 }; z = Double(S) }
                for s in 0..<S { beta[b0 + s] /= z }
            }
            var out = [[Double]](repeating: [0, 0, 0, 0], count: n)
            for t in 0..<n {
                var g = [0.0, 0, 0, 0]
                for s in 0..<S { g[Self.stageIdx[s]] += alpha[t * S + s] * beta[t * S + s] }
                let tot = g.reduce(0, +); out[t] = tot > 0 ? g.map { $0 / tot } : [0.25, 0.25, 0.25, 0.25]
            }
            return out
        }
    }

    // MARK: oximetry
    /// AASM-style relative desaturations (research §5.2, PhysioZoo `pobm` relative method):
    /// SpO2 valid in 70...100 and not within ±3 s of motion; 3-s median; baseline = max of the preceding 120 s capped at
    /// (5-min median + 1), recomputed after every event; event = 10-120 s from the drop to recovery (>= baseline − 1, or 2/3 of
    /// the depth regained). Dips still unrecovered after 120 s are baseline shifts and are not counted.
    static func detectDesats(_ recs: [SecondRecord], drop: Int = 3) -> [DesatEvent] {
        guard let first = recs.first, let lastR = recs.last else { return [] }
        let t0 = Int(first.t), N = Int(lastR.t) - t0 + 1
        guard N > 300 else { return [] }
        var raw = [Int](repeating: 0, count: N); var mot = [Bool](repeating: false, count: N)
        for r in recs {
            let i = Int(r.t) - t0; guard i >= 0 && i < N else { continue }
            if r.spo2 >= 70 && r.spo2 <= 100 { raw[i] = Int(r.spo2) }
            if r.motion > 0 { mot[i] = true }
        }
        for i in 0..<N where mot[i] { for j in max(0, i - 3)...min(N - 1, i + 3) { raw[j] = 0 } }
        var s3 = [Int](repeating: 0, count: N)
        for i in 0..<N where raw[i] > 0 {
            let w = [i - 1, i, i + 1].filter { $0 >= 0 && $0 < N && raw[$0] > 0 }.map { raw[$0] }.sorted()
            s3[i] = w[w.count / 2]
        }
        // Rolling histograms (SpO2 is integer 70...100) for the 5-min median and the 120-s max.
        var hLong = [Int](repeating: 0, count: 31), hShort = hLong, nLong = 0, nShort = 0
        func add(_ v: Int, _ h: inout [Int], _ c: inout Int, _ d: Int) { if v > 0 { h[v - 70] += d; c += d } }
        func baseline() -> Int? {
            guard nShort >= 30 && nLong >= 90 else { return nil }
            var acc = 0, med = 0
            for b in 0..<31 { acc += hLong[b]; if acc * 2 >= nLong { med = b + 70; break } }
            let mx = (0..<31).last { hShort[$0] > 0 }! + 70
            return min(mx, med + 1)
        }
        var out: [DesatEvent] = []
        var t = 0, filled = 0   // histograms contain s3[t-300 ..< t] / s3[t-120 ..< t]
        func advance(to target: Int) {
            while filled < target {
                add(s3[filled], &hLong, &nLong, 1); add(s3[filled], &hShort, &nShort, 1)
                if filled - 300 >= 0 { add(s3[filled - 300], &hLong, &nLong, -1) }
                if filled - 120 >= 0 { add(s3[filled - 120], &hShort, &nShort, -1) }
                filled += 1
            }
        }
        while t < N {
            advance(to: t)
            guard s3[t] > 0, let b = baseline(), s3[t] <= b - drop else { t += 1; continue }
            var st = t   // walk back (<= 30 s) to the last sample near baseline
            for k in 1...30 { let j = t - k; if j < 0 { break }; if s3[j] >= b - 1 { st = j + 1; break }; if k == 30 { st = t } }
            var nad = s3[t], u = t + 1, recovered = false
            while u < N && u - st < 120 {
                if s3[u] > 0 {
                    nad = min(nad, s3[u])
                    if Double(s3[u]) >= Double(nad) + max(2, 0.67 * Double(b - nad)) || s3[u] >= b - 1 { recovered = true; break }
                }
                u += 1
            }
            let end = min(u, N - 1), span = st..<max(st + 1, end)
            let validFrac = Double(span.filter { s3[$0] > 0 }.count) / Double(span.count)
            // A dip that has not recovered within 120 s is a baseline shift (slow drift), not a desaturation event.
            if recovered && span.count >= 10 && validFrac >= 0.8 {
                let area = span.reduce(0.0) { $0 + (s3[$1] > 0 ? Double(max(0, b - s3[$1])) : 0) }
                out.append(DesatEvent(start: Date(timeIntervalSince1970: TimeInterval(t0 + st)), end: Date(timeIntervalSince1970: TimeInterval(t0 + end)),
                                      nadir: nad, drop: b - nad, area: area))
                t = end + 5
            } else { t = max(t + 1, end) }
        }
        return out
    }

    // MARK: metrics
    static func metrics(_ ep: [Epoch], _ recs: [SecondRecord], _ desats: [DesatEvent]) -> NightMetrics {
        var m = NightMetrics(); let e = Double(epochLen) / 60
        let scored = ep.filter { $0.stage != .unscored }
        m.inBedMin = Double(scored.count) * e
        let asleep = ep.map { [.light, .deep, .rem].contains($0.stage) }
        // onset: first run of >=10 min mostly asleep
        var first = asleep.firstIndex(of: true) ?? 0
        if ep.count > 20 { for i in 0..<(ep.count - 20) where asleep[i..<(i + 20)].filter({ $0 }).count >= 18 { first = i; break } }
        let last = asleep.lastIndex(of: true) ?? 0
        guard last > first else { return m }
        let win = ep[first...last]
        m.latencyMin = Double(first) * e
        m.tstMin = Double(win.filter { [.light, .deep, .rem].contains($0.stage) }.count) * e
        m.wasoMin = Double(win.filter { $0.stage == .wake }.count) * e
        m.efficiency = m.inBedMin > 0 ? 100 * m.tstMin / m.inBedMin : 0
        for s in [Stage.light, .deep, .rem, .wake] { m.stageMin[s] = Double(win.filter { $0.stage == s }.count) * e }
        if let r = win.firstIndex(where: { $0.stage == .rem }) { m.remLatencyMin = Double(r - first) * e }
        var run = 0
        for x in win {
            if x.stage == .wake { if run == 0 { m.awakenings += 1 }; run += 1; if run == 4 { m.longAwakenings += 1 } } else { run = 0 }
        }
        let conf = win.filter { [.light, .deep, .rem].contains($0.stage) }.map(\.confidence)
        m.stageConfidence = mean(conf)
        let t0 = win.first!.start.timeIntervalSince1970, t1 = win.last!.start.timeIntervalSince1970 + 30
        m.sleepMidpoint = Date(timeIntervalSince1970: (t0 + t1) / 2)
        let sleepRecs = recs.filter { Double($0.t) >= t0 && Double($0.t) < t1 }
        let hrRecs = sleepRecs.filter { $0.hr >= 35 && $0.hr <= 130 }
        if !hrRecs.isEmpty {
            let hrs = hrRecs.map { Int($0.hr) }
            m.hrAvg = Double(hrs.reduce(0, +)) / Double(hrs.count); m.hrMin = hrs.min()!
            // resting HR: lowest 5-minute average during sleep; its timing feeds the restoration score
            var best = Double.infinity, bestT = 0.0
            var c = [Int](repeating: 0, count: hrs.count + 1); for i in hrs.indices { c[i + 1] = c[i] + hrs[i] }
            stride(from: 0, to: max(0, hrs.count - 300), by: 60).forEach { s in
                let v = Double(c[s + 300] - c[s]) / 300; if v < best { best = v; bestT = Double(hrRecs[s + 150].t) }
            }
            m.restingHR = best.isFinite ? best : m.hrAvg
            if best.isFinite { m.hrNadirFraction = (bestT - t0) / max(1, t1 - t0) }
        }
        let sp = sleepRecs.map { Int($0.spo2) }.filter { $0 >= 70 && $0 <= 100 }
        if !sp.isEmpty { m.spo2Avg = Double(sp.reduce(0, +)) / Double(sp.count); m.spo2Min = sp.min()!; m.t90Sec = sp.filter { $0 < 90 }.count }
        m.spo2ValidMin = Double(sp.count) / 60
        let hours = max(0.5, m.tstMin / 60)
        let inWin = desats.filter { $0.start.timeIntervalSince1970 >= t0 && $0.start.timeIntervalSince1970 < t1 }
        m.odi3 = Double(inWin.count) / hours
        m.odi4 = Double(inWin.filter { $0.drop >= 4 }.count) / hours
        m.hypoxicBurden = inWin.reduce(0) { $0 + $1.area } / 60 / hours
        var moves = 0, still = 0
        for r in sleepRecs { if r.motion > 0 { if still >= 30 { moves += 1 }; still = 0 } else { still += 1 } }
        m.movementsPerHour = Double(moves) / hours
        return m
    }

    // MARK: score
    /// Transparent 0-100 score (research §6): piecewise-linear sub-scores, weights renormalised over available components.
    static func score(_ m: NightMetrics, baseline: PersonalBaseline = PersonalBaseline()) -> SleepScore {
        func curve(_ x: Double, _ pts: [(Double, Double)]) -> Double {
            if x <= pts.first!.0 { return pts.first!.1 }
            for (a, b) in zip(pts, pts.dropFirst()) where x <= b.0 { return a.1 + (b.1 - a.1) * (x - a.0) / (b.0 - a.0) }
            return pts.last!.1
        }
        let h = m.tstMin / 60
        // Stage-confidence damping: blend stage-based sub-scores toward 75 by (1 − confidence).
        let c = min(1, max(0, (m.stageConfidence - 0.5) / 0.4))
        func damp(_ v: Double) -> Double { 75 + (v - 75) * c }
        var comps: [ScoreComponent] = [
            .init(id: "dur", label: "Total sleep", value: curve(h, [(3, 0), (4, 25), (5, 50), (6, 70), (7, 90), (7.5, 100), (9, 100), (10, 85), (11, 65), (12, 50)]),
                  weight: 0.30, detail: String(format: "%.1f h", h)),
            .init(id: "eff", label: "Efficiency", value: curve(m.efficiency, [(60, 0), (70, 35), (80, 70), (85, 85), (90, 95), (93, 100)]),
                  weight: 0.10, detail: String(format: "%.0f%%", m.efficiency)),
            .init(id: "lat", label: "Latency", value: curve(m.latencyMin, [(0, 70), (3, 85), (7, 100), (20, 100), (30, 80), (45, 50), (60, 25), (90, 0)]),
                  weight: 0.05, detail: String(format: "%.0f min", m.latencyMin)),
            .init(id: "cont", label: "Continuity",
                  value: 0.6 * curve(m.wasoMin, [(0, 100), (10, 100), (20, 90), (30, 80), (45, 60), (60, 45), (90, 20), (120, 0)])
                       + 0.4 * curve(Double(m.longAwakenings), [(0, 100), (2, 100), (4, 80), (6, 60), (8, 40), (12, 0)]),
                  weight: 0.15, detail: String(format: "%.0f min awake, %d wakes ≥2 min", m.wasoMin, m.longAwakenings)),
        ]
        if m.tstMin >= 60 {
            let deepMin = m.stageMin[.deep] ?? 0
            comps.append(.init(id: "deep", label: "Deep sleep", value: damp(curve(deepMin, [(0, 0), (20, 25), (40, 55), (60, 80), (75, 95), (90, 100), (120, 100), (150, 90)])),
                               weight: 0.10, detail: String(format: "%.0f min (%.0f%%)", deepMin, m.pct(.deep))))
            comps.append(.init(id: "rem", label: "REM sleep", value: damp(curve(m.pct(.rem), [(0, 0), (5, 15), (10, 40), (15, 70), (18, 90), (20, 100), (26, 100), (30, 90), (35, 70)])),
                               weight: 0.10, detail: String(format: "%.0f%%", m.pct(.rem))))
        }
        if let mid = m.sleepMidpoint {
            let mm = minutesAfterNoon(mid), clock = 12 + mm / 60   // hours, 22 = 22:00, 26 = 02:00
            var v = curve(clock, [(22, 20), (23, 40), (24.5, 70), (26, 100), (28, 100), (29, 70), (30, 40), (32, 0)])
            var detail = String(format: "midpoint %02d:%02d", Int(clock.truncatingRemainder(dividingBy: 24)), Int(mm.truncatingRemainder(dividingBy: 60)))
            if let b = baseline.midpointMin {
                v = 0.5 * v + 0.5 * curve(abs(mm - b), [(0, 100), (15, 100), (30, 90), (60, 70), (90, 45), (120, 20), (180, 0)])
                detail += String(format: ", %+.0f min vs usual", mm - b)
            }
            comps.append(.init(id: "timing", label: "Timing", value: v, weight: 0.10, detail: detail))
        }
        if m.restingHR > 0, let nf = m.hrNadirFraction {
            var v = curve(nf, [(0, 100), (0.5, 100), (0.7, 75), (0.9, 45), (1, 30)])
            var detail = String(format: "low %.0f bpm at %.0f%% of night", m.restingHR, 100 * nf)
            if let b = baseline.lowHR {
                v = 0.6 * curve(m.restingHR - b, [(-3, 100), (0, 95), (2, 80), (4, 60), (7, 30), (10, 0)]) + 0.4 * v
                detail += String(format: ", %+.0f vs usual", m.restingHR - b)
            }
            comps.append(.init(id: "resto", label: "Restoration", value: v, weight: 0.05, detail: detail))
        }
        if m.spo2ValidMin >= 60 {
            let t90 = m.tstMin > 0 ? 100 * Double(m.t90Sec) / 60 / m.tstMin : 0
            comps.append(.init(id: "breath", label: "Breathing",
                               value: 0.7 * curve(m.odi3, [(5, 100), (10, 80), (15, 60), (30, 20), (45, 0)]) + 0.3 * curve(t90, [(1, 100), (3, 80), (5, 60), (10, 20), (20, 0)]),
                               weight: 0.05, detail: String(format: "ODI %.1f/h, T90 %.1f%%", m.odi3, t90)))
        }
        var total = comps.reduce(0) { $0 + $1.value * $1.weight } / max(1e-9, comps.reduce(0) { $0 + $1.weight })
        if h < 4 { total = min(total, 50) } else if h < 5 { total = min(total, 65) }
        if m.odi3 >= 30 { total = min(total, 70) }
        return SleepScore(total: Int(total.rounded()), components: comps)
    }

    // MARK: helpers
    static func minutesAfterNoon(_ d: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return Double(((c.hour ?? 0) + 12) % 24 * 60 + (c.minute ?? 0))
    }
    static func downsample(_ recs: [SecondRecord], t0: Int, step: Int) -> [SeriesPoint] {
        var bins: [Int: [SecondRecord]] = [:]
        for r in recs { bins[(Int(r.t) - t0) / step, default: []].append(r) }
        return bins.keys.sorted().map { k in
            let b = bins[k]!; let hrs = b.map { Double($0.hr) }.filter { $0 >= 35 && $0 <= 130 }; let sp = b.map { Double($0.spo2) }.filter { $0 > 0 }
            return SeriesPoint(id: k, date: Date(timeIntervalSince1970: TimeInterval(t0 + k * step)), hr: hrs.isEmpty ? nil : mean(hrs),
                               spo2: sp.min(), motion: Double(b.map { $0.motion }.max() ?? 0), x10: mean(b.map { Double($0.x10) }))
        }
    }
    static func mean(_ x: [Double]) -> Double { x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count) }
    static func median(_ x: [Double]) -> Double { guard !x.isEmpty else { return 0 }; let s = x.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2 }
    static func percentile(_ x: [Double], _ q: Double) -> Double { guard !x.isEmpty else { return 0 }; let s = x.sorted(); return s[min(s.count - 1, Int(q * Double(s.count - 1)))] }
    static func sd(_ x: [Double]) -> Double { guard x.count > 1 else { return 0 }; let m = mean(x); return sqrt(x.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(x.count)) }
    static func rolling(_ x: [Double], _ w: Int, _ f: ([Double]) -> Double) -> [Double] {
        let h = w / 2; return x.indices.map { f(Array(x[max(0, $0 - h)...min(x.count - 1, $0 + h)])) }
    }
    static func boxMean(_ x: [Double], _ r: Int) -> [Double] {
        let n = x.count; var c = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { c[i + 1] = c[i] + x[i] }
        return (0..<n).map { i in let a = max(0, i - r), b = min(n, i + r + 1); return (c[b] - c[a]) / Double(b - a) }
    }
    /// Gaussian smoothing approximated by three box passes (r(r+1) = σ²).
    static func gaussSmooth(_ x: [Double], sigma: Double) -> [Double] {
        let r = max(1, Int((sqrt(sigma * sigma + 0.25) - 0.5).rounded()))
        return boxMean(boxMean(boxMean(x, r), r), r)
    }
    static func interpolate(_ x: [Double?]) -> [Double] {
        let known: [(Int, Double)] = x.enumerated().compactMap { item in item.element.map { (item.offset, $0) } }
        guard let f = known.first else { return x.map { _ in 0 } }
        var out = [Double](repeating: f.1, count: x.count); var k = 0
        for i in x.indices {
            while k + 1 < known.count && known[k + 1].0 <= i { k += 1 }
            if let v = x[i] { out[i] = v } else if k + 1 < known.count && known[k].0 < i {
                let (i0, v0) = known[k], (i1, v1) = known[k + 1]; out[i] = v0 + (v1 - v0) * Double(i - i0) / Double(i1 - i0)
            } else { out[i] = known[k].1 }
        }
        return out
    }
    static func clampZ(_ z: Double) -> Double { max(-6, min(6, z)) }
    static func robustZ(_ x: [Double], _ ref: [Bool]) -> [Double] {
        let r = x.enumerated().filter { ref[$0.offset] }.map { $0.element }; guard !r.isEmpty else { return x.map { _ in 0 } }
        let m = median(r), mad = max(1e-3, 1.4826 * median(r.map { abs($0 - m) }))
        return x.map { clampZ(($0 - m) / mad) }
    }
    static func gaussLog(_ x: Double, _ mu: Double, _ s: Double) -> Double { let d = (x - mu) / s; return -0.5 * d * d - log(s) }
    /// Student-t (ν = 4) log-density: tolerant of PPG glitches.
    static func studentLog(_ x: Double, _ mu: Double, _ s: Double) -> Double { let d = (x - mu) / s; return -2.5 * log(1 + d * d / 4) - log(s) }
    static func poissonLog(_ k: Double, _ lam: Double) -> Double { k * log(lam) - lam - lgamma(k + 1) }
    static func dropShortRuns(_ x: inout [Bool], value: Bool, minLen: Int) {
        var i = 0
        while i < x.count { if x[i] == value { var j = i; while j < x.count && x[j] == value { j += 1 }; if j - i < minLen { for k in i..<j { x[k] = !value } }; i = j } else { i += 1 } }
    }
    static func relabelShortRuns(_ st: inout [Stage], _ s: Stage, minLen: Int, to: Stage) {
        var i = 0
        while i < st.count { if st[i] == s { var j = i; while j < st.count && st[j] == s { j += 1 }; if j - i < minLen { for k in i..<j { st[k] = to } }; i = j } else { i += 1 } }
    }
}
