import AnalysisCore
import Foundation

/// One 10 Hz reading of everything the master check gathers, taken from a snapshot by `Readouts`.
struct SessionSample {
    var momentary: Float
    var shortTerm: Float
    /// Highest true peak and sample peak of any routed channel this tick, dBFS.
    var truePeak: Float
    var samplePeak: Float
    /// Power sum of the routed channels except LFE, dBFS (the VU's programme level).
    var programme: Float
    /// The live spectrum's 128 bands, dBFS, log-spaced from 20 Hz to `upper`.
    var spectrum: [Float]
    var upper: Double
    /// L/R readings per `StereoBands.groups` entry (five bands, three, overall).
    var bandCorrelation: [Float]
    var bandWidth: [Float]
    var bandBalance: [Float]
    var bandLevel: [Float]
    /// L and R RMS, linear.
    var leftRMS: Float
    var rightRMS: Float
    /// `SignalHealthMeter` per role: DC offset and infrasonic mean square (linear), its status (1 settled), and the
    /// roles routed.
    var dcOffset: [Float] = []
    var infrasonic: [Float] = []
    var healthStatus: Float = 0
    var routed: [Bool] = []
}

/// The whole session reduced as it runs: the long-term average spectrum, energy-weighted stereo readings, per-tick
/// series for the dynamics and the counts the integrity checks need. Plain values, so the analysis is testable.
struct SessionStatistics {
    static let bands = 128
    /// Below this momentary loudness a tick is silence: it counts toward leading and trailing silence only.
    static let silence: Float = -70

    private(set) var ticks = 0
    private(set) var firstSound: Int?
    private(set) var lastSound: Int?
    /// Long-term average spectrum: mean power per band over the ticks with sound.
    private(set) var spectrumPower = [Double](repeating: 0, count: bands)
    private(set) var spectrumTicks = 0
    private(set) var upper = 20_000.0
    /// Per tick with sound: true peak, short-term loudness, programme level and the lowest band's level.
    private(set) var truePeaks: [Float] = []
    private(set) var shortTerms: [Float] = []
    private(set) var programme: [Float] = []
    private(set) var lowLevels: [Float] = []
    /// The overall L/R correlation per tick with sound (for its low percentile).
    private(set) var correlations: [Float] = []
    /// Energy-weighted sums per band group: correlation, width, balance, and the weights.
    private(set) var correlationSum = [Double](repeating: 0, count: 9)
    private(set) var widthSum = [Double](repeating: 0, count: 9)
    private(set) var balanceSum = [Double](repeating: 0, count: 9)
    private(set) var weightSum = [Double](repeating: 0, count: 9)
    private(set) var leftPower = 0.0
    private(set) var rightPower = 0.0
    /// Ticks whose sample peak reached full scale, and the separate runs of them.
    private(set) var fullScaleTicks = 0
    private(set) var fullScaleEvents = 0
    private var fullScaleBefore = false
    /// Signal health over the settled ticks with sound: each role's mean DC offset, the infrasonic energy of the
    /// programme channels against their full-band energy, and whether any source measured it at all.
    private(set) var dcSum = [Double](repeating: 0, count: 16)
    private(set) var healthTicks = 0
    private(set) var infrasonicPower = 0.0
    private(set) var programmePower = 0.0
    private(set) var healthRoles = [Bool](repeating: false, count: 16)
    /// A tick arrived from a source that does not measure signal health (a plugin before build 90).
    private(set) var healthMissing = false

    mutating func add(_ sample: SessionSample) {
        defer { ticks += 1 }
        let fullScale = sample.samplePeak >= -0.01
        if fullScale { fullScaleTicks += 1; if !fullScaleBefore { fullScaleEvents += 1 } }
        fullScaleBefore = fullScale
        guard sample.momentary > Self.silence else { return }
        if firstSound == nil { firstSound = ticks }
        lastSound = ticks
        if sample.spectrum.count == Self.bands {
            for band in 0..<Self.bands { spectrumPower[band] += pow(10, Double(sample.spectrum[band]) / 10) }
            spectrumTicks += 1
            upper = sample.upper
        }
        truePeaks.append(sample.truePeak)
        shortTerms.append(sample.shortTerm)
        programme.append(sample.programme)
        if let low = sample.bandLevel.first { lowLevels.append(low) }
        for group in 0..<min(9, sample.bandLevel.count) where sample.bandCorrelation[group] > -1.5 {
            let weight = pow(10, Double(sample.bandLevel[group]) / 10)
            correlationSum[group] += weight * Double(sample.bandCorrelation[group])
            widthSum[group] += weight * Double(sample.bandWidth[group])
            balanceSum[group] += weight * Double(sample.bandBalance[group])
            weightSum[group] += weight
        }
        if sample.bandCorrelation.count > 8, sample.bandCorrelation[8] > -1.5 { correlations.append(sample.bandCorrelation[8]) }
        leftPower += Double(sample.leftRMS * sample.leftRMS)
        rightPower += Double(sample.rightRMS * sample.rightRMS)
        if sample.healthStatus == 0 { healthMissing = true }
        if sample.healthStatus >= 1, sample.dcOffset.count == 16, sample.infrasonic.count == 16, sample.routed.count == 16 {
            healthTicks += 1
            for role in 0..<16 where sample.routed[role] {
                healthRoles[role] = true
                dcSum[role] += Double(sample.dcOffset[role])
                // LFE carries low frequencies by design; the programme channels are what the check is about.
                if role != 3 { infrasonicPower += Double(sample.infrasonic[role]) }
            }
            programmePower += pow(10, Double(sample.programme) / 10)
        }
    }

    /// Each analysed role's mean DC offset over the session (linear), nil before any settled reading.
    var meanDC: [(role: Int, offset: Double)]? {
        guard healthTicks > 0 else { return nil }
        return (0..<16).filter { healthRoles[$0] }.map { ($0, dcSum[$0] / Double(healthTicks)) }
    }

    /// Infrasonic energy of the programme channels against their full-band energy, dB; nil before any reading.
    var infrasonicRatio: Float? {
        guard healthTicks > 0, programmePower > 0 else { return nil }
        return Float(10 * log10(max(infrasonicPower / programmePower, 1e-14)))
    }

    /// The long-term average spectrum in dBFS (empty before any sound).
    var averageSpectrum: [Float] {
        guard spectrumTicks > 0 else { return [] }
        return spectrumPower.map { Float(10 * log10(max($0 / Double(spectrumTicks), 1e-14))) }
    }

    /// Centre frequency of `band`.
    func frequency(_ band: Int) -> Double { LogFrequencyAxis.centre(band, of: Self.bands, upper: upper) }
}

/// The master check: every measurement the report states, each judged against a published rule or a stated
/// guideline. Rules for loudness and true peak come from the standard; the others are mastering guidance, written
/// beside each verdict so a reader can weigh them.
struct MasteringCheck {
    enum Status: Int, Comparable {
        case ok, note, check, unavailable
        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    struct Item: Identifiable {
        let name: String
        let value: String
        let status: Status
        /// What the value means, and the guideline it was judged against.
        let note: String
        var id: String { name }
    }

    struct Section: Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
        var worst: Status { items.map(\.status).filter { $0 != .unavailable }.max() ?? .ok }
    }

    /// One band of the tonal-balance table: its share of the energy, in dB relative to the whole.
    struct Band {
        let name: String
        let range: ClosedRange<Double>
        let relative: Float
    }

    struct Resonance {
        let frequency: Double
        let excess: Float
    }

    var sections: [Section] = []
    var bands: [Band] = []
    var resonances: [Resonance] = []
    /// Tilt of the average spectrum, dB per octave from 60 Hz to 12 kHz.
    var tilt: Float?
    var spectrum: [Float] = []
    var spectrumUpper = 20_000.0
    /// Frequency above which the spectrum falls away steeply, if it does.
    var cutoff: Double?

    static let bandSplits: [(String, ClosedRange<Double>)] = [
        (LKey("Sub"), 20...60), (LKey("Bass"), 60...250), (LKey("Low mids"), 250...2_000),
        (LKey("Upper mids"), 2_000...6_000), (LKey("Highs"), 6_000...20_000)
    ]

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    init(statistics s: SessionStatistics, integrated: Float, range: Float, truePeak: Float, samplePeak: Float,
         overs: Int, breaks: Int, missingSeconds: Double, dropped: UInt64, ceiling: Double, stereo: Bool) {
        let rate = SessionStatistics.rateHz
        func seconds(_ ticks: Int) -> String { String(format: "%.1f s", Double(ticks) / rate) }
        func db(_ value: Float) -> String { MeterScale.tenths(value, floor: -119) }

        // Loudness and peaks
        var loud: [Item] = []
        let plr = truePeak - integrated
        loud.append(Item(name: L("Integrated"), value: integrated > -70 ? "\(db(integrated)) LUFS" : "—",
                         status: integrated > -70 ? .ok : .unavailable, note: L("BS.1770 gated programme loudness, judged above against the standard.")))
        loud.append(Item(name: L("True peak"), value: "\(truePeak > 0.05 ? MeterScale.signedTenths(truePeak) : db(truePeak)) dBTP",
                         status: Double((truePeak * 10).rounded() / 10) <= ceiling ? .ok : .check,
                         note: L("Highest inter-sample peak; the ceiling is %@ dBTP.", MeterScale.tenths(Float(ceiling)))))
        loud.append(Item(name: L("Full-scale samples"), value: s.fullScaleEvents == 0 ? L("None") : L("%d times", s.fullScaleEvents),
                         status: s.fullScaleEvents == 0 ? .ok : .check,
                         note: L("Readings that touched 0 dBFS, where a converter or a lossy encoder is likely to clip.")))
        loud.append(Item(name: L("True-peak overs"), value: overs == 0 ? L("None") : L("%d times", overs), status: overs == 0 ? .ok : .check,
                         note: L("Separate overshoots above 0 dBTP.")))
        loud.append(Item(name: L("Peak to loudness (PLR)"), value: integrated > -70 ? "\(MeterScale.tenths(plr)) LU" : "—",
                         status: integrated <= -70 ? .unavailable : (plr < 6 ? .check : (plr < 8 ? .note : .ok)),
                         note: L("True peak above integrated loudness. Below 8 LU the master is densely limited; below 6 LU transients are usually flattened.")))
        sections.append(Section(title: L("Loudness & peaks"), items: loud))

        // Dynamics
        var dynamics: [Item] = []
        dynamics.append(Item(name: L("Loudness range (LRA)"), value: range >= 0 ? "\(MeterScale.tenths(range)) LU" : "—",
                             status: range < 0 ? .unavailable : (range < 3 ? .note : .ok),
                             note: L("EBU Tech 3342 spread of short-term loudness: the programme's macro-dynamics. Under 3 LU reads as nearly constant.")))
        let psr = Self.peakToShortTerm(peaks: s.truePeaks, shortTerms: s.shortTerms)
        dynamics.append(Item(name: L("Peak to short-term (PSR)"), value: psr.map { "\(MeterScale.tenths($0)) LU" } ?? "—",
                             status: psr.map { $0 < 6 ? .check : ($0 < 8 ? .note : .ok) } ?? .unavailable,
                             note: L("Median of the 3 s true peak above short-term loudness: how much the transients stand out moment to moment.")))
        let crest = Self.crestFactor(peaks: s.truePeaks, programme: s.programme)
        dynamics.append(Item(name: L("Crest factor"), value: crest.map { "\(MeterScale.tenths($0)) dB" } ?? "—",
                             status: crest.map { $0 < 8 ? .note : .ok } ?? .unavailable,
                             note: L("Highest peak above the programme's mean RMS level.")))
        let lowRange = Self.spread(s.lowLevels)
        dynamics.append(Item(name: L("Low-end movement"), value: lowRange.map { "\(MeterScale.tenths($0)) dB" } ?? "—",
                             status: lowRange.map { $0 < 4 ? .note : .ok } ?? .unavailable,
                             note: L("Spread (10th to 95th percentile) of the level below 120 Hz. Little movement suggests heavy low-end compression.")))
        sections.append(Section(title: L("Dynamics"), items: dynamics))

        // Tonal balance and bandwidth, from the long-term average spectrum
        spectrum = s.averageSpectrum
        spectrumUpper = s.upper
        var tonal: [Item] = []
        var bandwidth: [Item] = []
        if spectrum.isEmpty {
            tonal.append(Item(name: L("Average spectrum"), value: "—", status: .unavailable, note: L("Nothing measured yet.")))
            bandwidth.append(Item(name: L("High-frequency extent"), value: "—", status: .unavailable, note: L("Nothing measured yet.")))
        } else {
            let power = spectrum.map { pow(10, Double($0) / 10) }
            let total = power.reduce(0, +)
            for (name, range) in Self.bandSplits where range.lowerBound < s.upper {
                let share = (0..<power.count).filter { range.contains(s.frequency($0)) }.map { power[$0] }.reduce(0, +)
                bands.append(Band(name: L(name), range: range, relative: Float(10 * log10(max(share / total, 1e-12)))))
            }
            tilt = Self.tilt(spectrum, statistics: s)
            if let tilt {
                tonal.append(Item(name: L("Spectral tilt"), value: String(format: "%+.1f dB/oct", tilt).replacingOccurrences(of: "-", with: "−"),
                                  status: tilt > -2 ? .note : (tilt < -6.5 ? .note : .ok),
                                  note: tilt > -2 ? L("Brighter than most finished music, which falls about 3 to 6 dB per octave.")
                                       : (tilt < -6.5 ? L("Darker than most finished music, which falls about 3 to 6 dB per octave.")
                                                      : L("Within the 3 to 6 dB per octave fall of most finished music."))))
            }
            let presence = Self.presence(spectrum, statistics: s)
            if let presence {
                tonal.append(Item(name: L("Upper-mid presence"), value: MeterScale.signedTenths(presence) + " dB",
                                  status: presence > 6 ? .check : (presence > 3 ? .note : .ok),
                                  note: L("Level of 2 to 5 kHz against a line between its neighbours (1 to 2 kHz, 6 to 10 kHz). Above +3 dB it tends to sound harsh.")))
            }
            resonances = Self.resonances(spectrum, statistics: s)
            tonal.append(Item(name: L("Resonances"),
                              value: resonances.isEmpty ? L("None") : resonances.prefix(3).map { Self.hertz($0.frequency) }.joined(separator: ", "),
                              status: resonances.isEmpty ? .ok : (resonances.contains { $0.excess > 8 } ? .check : .note),
                              note: L("Narrow peaks standing more than 5 dB above the average spectrum's half-octave trend, held over the session.")))
            cutoff = Self.cutoff(spectrum, statistics: s)
            if s.upper < 18_000 {
                bandwidth.append(Item(name: L("High-frequency extent"), value: "—", status: .unavailable,
                                      note: L("The sample rate stops the analysis at %@.", Self.hertz(s.upper))))
            } else if let cutoff {
                bandwidth.append(Item(name: L("High-frequency extent"), value: L("Falls away above %@", Self.hertz(cutoff)), status: .check,
                                      note: L("A steep loss above this frequency, as a lossy encoder or a low-pass filter leaves. Check that the source is not a decoded MP3 or AAC.")))
            } else {
                bandwidth.append(Item(name: L("High-frequency extent"), value: L("Full band"), status: .ok,
                                      note: L("No steep loss up to %@.", Self.hertz(s.upper))))
            }
            let air = (0..<power.count).filter { s.frequency($0) >= 12_000 }.map { power[$0] }.reduce(0, +)
            let airShare = Float(10 * log10(max(air / total, 1e-12)))
            bandwidth.append(Item(name: L("Air (12 kHz and up)"), value: MeterScale.signedTenths(airShare) + " dB",
                                  status: airShare < -40 ? .note : .ok,
                                  note: L("Energy above 12 kHz against the whole. Much below −35 dB sounds closed-in.")))
            let infra = (0..<power.count).filter { s.frequency($0) < 30 }.map { power[$0] }.reduce(0, +)
            let infraShare = Float(10 * log10(max(infra / total, 1e-12)))
            tonal.append(Item(name: L("Below 30 Hz"), value: MeterScale.signedTenths(infraShare) + " dB",
                              status: infraShare > -12 ? .note : .ok,
                              note: L("Energy from 20 to 30 Hz against the whole. Much above −12 dB wastes headroom on what few systems reproduce.")))
        }
        sections.append(Section(title: L("Tonal balance"), items: tonal))
        sections.append(Section(title: L("Bandwidth"), items: bandwidth))

        // Stereo image
        var image: [Item] = []
        if !stereo || s.weightSum[8] <= 0 {
            image.append(Item(name: L("Stereo image"), value: "—", status: .unavailable, note: L("Measured on L and R in Stereo.")))
        } else {
            let correlation = Float(s.correlationSum[8] / s.weightSum[8])
            let low = Self.percentile(s.correlations, 0.01)
            image.append(Item(name: L("Correlation"), value: String(format: "%+.2f", correlation).replacingOccurrences(of: "-", with: "−"),
                              status: correlation < 0 ? .check : (correlation < 0.2 ? .note : .ok),
                              note: L("Energy-weighted L/R phase correlation over the session. Below 0 parts of the mix cancel in mono.")))
            if let low {
                image.append(Item(name: L("Lowest correlation"), value: String(format: "%+.2f", low).replacingOccurrences(of: "-", with: "−"),
                                  status: low < -0.3 ? .check : (low < 0 ? .note : .ok),
                                  note: L("The worst one percent of the session's moments.")))
            }
            if s.weightSum[0] > 0 {
                let bass = Float(s.correlationSum[0] / s.weightSum[0])
                image.append(Item(name: L("Bass correlation (below 120 Hz)"), value: String(format: "%+.2f", bass).replacingOccurrences(of: "-", with: "−"),
                                  status: bass < 0.3 ? .check : (bass < 0.7 ? .note : .ok),
                                  note: L("Low frequencies are best near mono (+0.7 and up) for vinyl, clubs and mono playback.")))
            }
            let width = Float(s.widthSum[8] / s.weightSum[8]) * 100
            image.append(Item(name: L("Width"), value: String(format: "%.0f %%", width), status: width > 45 ? .note : .ok,
                              note: L("Side share of the energy, in percent: 0 is mono, 50 is unrelated channels. Above 45 the centre may feel hollow.")))
            let balance = Float(10 * log10(max(s.rightPower, 1e-20) / max(s.leftPower, 1e-20)))
            image.append(Item(name: L("Balance"), value: abs(balance) < 0.05 ? L("Centred")
                                  : (balance > 0 ? "R \(MeterScale.tenths(abs(balance))) dB" : "L \(MeterScale.tenths(abs(balance))) dB"),
                              status: abs(balance) > 1 ? .note : .ok, note: L("Energy of R against L over the session.")))
            let mono = Self.monoChange(correlation: correlation)
            image.append(Item(name: L("Mono fold-down"), value: MeterScale.signedTenths(mono) + " dB", status: mono < -3 ? .note : .ok,
                              note: L("Level change when L and R are summed to mono, from the session's correlation.")))
        }
        sections.append(Section(title: L("Stereo image"), items: image))

        // Signal integrity
        var integrity: [Item] = []
        let leading = s.firstSound ?? s.ticks
        let trailing = s.lastSound.map { s.ticks - 1 - $0 } ?? 0
        integrity.append(Item(name: L("Leading silence"), value: seconds(leading), status: Double(leading) / rate > 2 ? .note : .ok,
                              note: L("From the start of the measurement to the first sound above −70 LUFS.")))
        integrity.append(Item(name: L("Trailing silence"), value: seconds(trailing), status: .ok,
                              note: L("From the last sound to the end of the measurement.")))
        integrity.append(Item(name: L("Interruptions"), value: breaks == 0 ? L("None") : L("%d · %@ s missing", breaks, String(format: "%.1f", missingSeconds)),
                              status: breaks == 0 ? .ok : .check, note: L("Breaks in the analysed audio; the readings span them.")))
        integrity.append(Item(name: L("Dropped frames"), value: dropped == 0 ? L("None") : "\(dropped)", status: dropped == 0 ? .ok : .check,
                              note: L("Audio the meter could not take in time.")))
        if let dc = s.meanDC, let worst = dc.max(by: { abs($0.offset) < abs($1.offset) }) {
            let level = Float(20 * log10(max(abs(worst.offset), 1e-9)))
            let percent = abs(worst.offset) * 100
            integrity.append(Item(name: L("DC offset"),
                                  value: level < -90 ? L("None") : "\(db(level)) dBFS (\(String(format: "%.2f", percent)) %) · \(Self.roleName(worst.role))",
                                  status: level > -46 ? .check : (level > -60 ? .note : .ok),
                                  note: L("The largest channel's mean over the session. Above −60 dBFS it costs headroom and can click at edits; above −46 dBFS (0.5 percent) remove it with a high-pass.")))
        } else {
            integrity.append(Item(name: L("DC offset"), value: "—", status: .unavailable,
                                  note: s.healthMissing ? L("This plugin does not measure it. Install the plugins of build 90 or later.") : L("Nothing measured yet.")))
        }
        if let ratio = s.infrasonicRatio {
            integrity.append(Item(name: L("Below 20 Hz"), value: ratio < -90 ? L("None") : MeterScale.signedTenths(ratio) + " dB",
                                  status: ratio > -15 ? .check : (ratio > -25 ? .note : .ok),
                                  note: L("Energy from about 2 to 20 Hz (rumble, wind, subsonic oscillation) against the programme's full-band energy, LFE left out. Above −25 dB it eats headroom no speaker turns into sound; a strong 30 to 40 Hz bass reads a little here too.")))
        } else {
            integrity.append(Item(name: L("Below 20 Hz"), value: "—", status: .unavailable,
                                  note: s.healthMissing ? L("This plugin does not measure it. Install the plugins of build 90 or later.") : L("Nothing measured yet.")))
        }
        sections.append(Section(title: L("Signal integrity"), items: integrity))
    }

    // MARK: Measures

    /// Median of (highest true peak in the last 3 s − short-term loudness), over ticks with sound.
    static func peakToShortTerm(peaks: [Float], shortTerms: [Float]) -> Float? {
        guard peaks.count >= 30, peaks.count == shortTerms.count else { return nil }
        var values: [Float] = []
        values.reserveCapacity(peaks.count)
        var window: [Float] = []
        for index in peaks.indices {
            window.append(peaks[index])
            if window.count > 30 { window.removeFirst() }
            if index >= 29, shortTerms[index] > SessionStatistics.silence, let peak = window.max() {
                values.append(peak - shortTerms[index])
            }
        }
        return percentile(values, 0.5)
    }

    /// Highest peak above the mean power of the programme level.
    static func crestFactor(peaks: [Float], programme: [Float]) -> Float? {
        guard let peak = peaks.max(), !programme.isEmpty else { return nil }
        let mean = programme.map { pow(10, Double($0) / 10) }.reduce(0, +) / Double(programme.count)
        return peak - Float(10 * log10(max(mean, 1e-14)))
    }

    /// Spread from the 10th to the 95th percentile.
    static func spread(_ values: [Float]) -> Float? {
        let valid = values.filter { $0 > -100 }
        guard valid.count >= 30, let low = percentile(valid, 0.10), let high = percentile(valid, 0.95) else { return nil }
        return high - low
    }

    static func percentile(_ values: [Float], _ p: Double) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[Int((Double(sorted.count - 1) * p).rounded())]
    }

    /// Least-squares slope of level against octaves, 60 Hz to 12 kHz.
    static func tilt(_ spectrum: [Float], statistics s: SessionStatistics) -> Float? {
        let points = spectrum.indices.compactMap { band -> (Double, Double)? in
            let f = s.frequency(band)
            return (60...12_000).contains(f) ? (log2(f / 1_000), Double(spectrum[band])) : nil
        }
        guard points.count > 8 else { return nil }
        let mx = points.map(\.0).reduce(0, +) / Double(points.count), my = points.map(\.1).reduce(0, +) / Double(points.count)
        let sxy = points.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +), sxx = points.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +)
        return sxx > 0 ? Float(sxy / sxx) : nil
    }

    /// Mean level of 2–5 kHz above the line through the means of 1–2 kHz and 6–10 kHz (interpolated in octaves).
    static func presence(_ spectrum: [Float], statistics s: SessionStatistics) -> Float? {
        func mean(_ range: ClosedRange<Double>) -> (level: Double, octave: Double)? {
            let bands = spectrum.indices.filter { range.contains(s.frequency($0)) }
            guard !bands.isEmpty else { return nil }
            return (bands.map { Double(spectrum[$0]) }.reduce(0, +) / Double(bands.count),
                    bands.map { log2(s.frequency($0)) }.reduce(0, +) / Double(bands.count))
        }
        guard s.upper >= 10_000, let below = mean(1_000...2_000), let middle = mean(2_000...5_000), let above = mean(6_000...10_000) else { return nil }
        let line = below.level + (above.level - below.level) * (middle.octave - below.octave) / (above.octave - below.octave)
        return Float(middle.level - line)
    }

    /// Bands more than 5 dB above the median of the surrounding half octave, 40 Hz to 12 kHz, local maxima only,
    /// strongest first.
    static func resonances(_ spectrum: [Float], statistics s: SessionStatistics) -> [Resonance] {
        let perOctave = Double(spectrum.count) / LogFrequencyAxis.octaves(upper: s.upper)
        let reach = max(2, Int((perOctave / 4).rounded()))
        var found: [Resonance] = []
        for band in reach..<(spectrum.count - reach) {
            let f = s.frequency(band)
            guard (40...12_000).contains(f), spectrum[band] >= spectrum[band - 1], spectrum[band] >= spectrum[band + 1] else { continue }
            let neighbours = (band - reach...band + reach).filter { $0 != band }.map { spectrum[$0] }.sorted()
            let trend = neighbours[neighbours.count / 2]
            let excess = spectrum[band] - trend
            if excess > 5 { found.append(Resonance(frequency: f, excess: excess)) }
        }
        return found.sorted { $0.excess > $1.excess }
    }

    /// Lowest frequency above 12 kHz from which every band lies more than 30 dB below the 4–12 kHz mean.
    static func cutoff(_ spectrum: [Float], statistics s: SessionStatistics) -> Double? {
        let reference = spectrum.indices.filter { (4_000...12_000).contains(s.frequency($0)) }.map { Double(spectrum[$0]) }
        guard s.upper >= 18_000, !reference.isEmpty else { return nil }
        let level = reference.reduce(0, +) / Double(reference.count)
        let high = spectrum.indices.filter { s.frequency($0) > 12_000 }
        guard let start = high.first(where: { band in high.filter { $0 >= band }.allSatisfy { Double(spectrum[$0]) < level - 30 } }) else {
            return nil
        }
        return s.frequency(start)
    }

    /// Level change of L+R summed to mono for equal-level channels of correlation `c`: 10·log10((1 + c) / 2) dB
    /// relative to their power sum (+3 dB coherent sum normalised to 0 for c = 1).
    static func monoChange(correlation c: Float) -> Float { 10 * log10(max((1 + c) / 2, 1e-6)) }

    /// The speaker name of a role for the report (L, R, C, LFE, Ls…).
    static func roleName(_ role: Int) -> String {
        ["L", "R", "C", "LFE", "Ls", "Rs", "Ltf", "Rtf", "Lrs", "Rrs", "Lw", "Rw", "Ltm", "Rtm", "Ltr", "Rtr"][max(0, min(15, role))]
    }

    static func hertz(_ value: Double) -> String {
        value >= 1_000 ? String(format: "%.1f kHz", value / 1_000) : "\(Int(value.rounded())) Hz"
    }
}

extension SessionStatistics {
    static let rateHz = 10.0
}
