import AnalysisCore
import Foundation

/// Deterministic synthetic programme for `--demo`, window snapshots and the offscreen preview.
/// It never touches an audio device; values only resemble a mix so the layout can be judged.
enum DemoSignal {
    static let updateRate = 30.0
    /// The programme alternates 14 s of Spatial (every role up to 9.1.6) with 16 s of stereo so the detector's
    /// transitions can be reviewed.
    static let formatCycle = 30.0
    static let spatialSpan = 14.0

    static func isSpatial(at time: Double) -> Bool {
        time.truncatingRemainder(dividingBy: formatCycle) < spatialSpan
    }

    static func snapshot(at time: Double, sequence: Int, layout: SpeakerLayout = .s916) -> MeterSnapshot {
        var result = MeterSnapshot()
        result.sequence = Float(sequence % 1_000_000 + 1)
        result.spectrogramSerial = result.sequence
        result.streamID = 1
        // The synthetic programme has no DC and nothing below 20 Hz, and says so as a settled measurement would.
        result.healthStatus = 1
        let sweep = 0.5 + 0.5 * sin(time * 0.35)
        func level(_ index: Int, bands: Int) -> Float {
            let x = Double(index) / Double(bands)
            // Pink-ish slope, a kick/bass bump, a vocal formant and a moving lead line.
            var db = -50 - 34 * x
            db += 22 * exp(-pow((x - 0.14) / 0.05, 2)) * (0.6 + 0.4 * sin(time * 7.5))
            db += 16 * exp(-pow((x - 0.52) / 0.07, 2))
            db += 18 * exp(-pow((x - (0.35 + 0.4 * sweep)) / 0.012, 2))
            db += 2 * sin(x * 61)
            return Float(max(-120, min(-3, db)))
        }
        result.spectrum = (0..<MeterSnapshot.bandCount).map { level($0, bands: MeterSnapshot.bandCount) }
        result.spectrumFine = (0..<MeterSnapshot.fineBandCount).map { level($0, bands: MeterSnapshot.fineBandCount) }
        result.spectrogram = (0..<MeterSnapshot.spectrogramBandCount).map {
            level($0, bands: MeterSnapshot.spectrogramBandCount)
        }
        if let loudest = result.spectrogram.indices.max(by: { result.spectrogram[$0] < result.spectrogram[$1] }) {
            let fraction = (Double(loudest) + 0.5) / Double(MeterSnapshot.spectrogramBandCount)
            result.peakFrequency = Float(20 * pow(1_000, fraction))
            result.peakLevel = result.spectrogram[loudest]
        }
        // The demo's tonal lines as notes: the sweep, the pulsing bass and the steady mid partial.
        let lines: [Double] = [0.35 + 0.4 * sweep, 0.14, 0.52]
        for (index, x) in lines.enumerated() {
            let band = min(MeterSnapshot.spectrogramBandCount - 1, Int(x * Double(MeterSnapshot.spectrogramBandCount)))
            result.notes[2 * index] = Float(20 * pow(1_000, x))
            result.notes[2 * index + 1] = result.spectrogram[band]
        }
        // Role order: L R C LFE Ls Rs Ltf Rtf Lrs Rrs Lw Rw Ltm Rtm Ltr Rtr.
        let base: [Double] = [-11, -10, -9, -16, -17, -18, -22, -23, -20, -21, -15, -14, -25, -24, -27, -26]
        let spatial = isSpatial(at: time)
        for role in 0..<Role.count {
            let wobble = 4 * sin(time * (1.3 + Double(role) * 0.37) + Double(role))
            // Sit the channel levels where a −18 LUFS mix really is (≈ −20 dBFS RMS on the fronts), so the
            // meters, the VU needle and the loudness readouts tell one story.
            let rms = base[role] + wobble - 15 + (Diagnostics.snapshotHot ? 10 : 0)
            let crest = role == Role.lfe ? 5.0 : 9 + 2 * sin(time * 2.1 + Double(role))
            let silent = !spatial && role >= 2
            result.channelRMS[role] = silent ? 0 : Float(pow(10, rms / 20))
            let ceiling = Diagnostics.snapshotHot ? 1.2 : 0.3
            result.channelPeaks[role] = silent ? 0 : Float(pow(10, min(-0.4, rms + crest) / 20))
            result.channelTruePeaks[role] = silent ? 0 : Float(pow(10, min(ceiling, rms + crest + 0.4) / 20))
        }
        // Band energy per role for the Immersive room: bass in the front and LFE, mids spread out, air in the
        // surrounds and the upper layer, each breathing a little, so every band points somewhere of its own.
        let fronts: [Double] = [1, 0.8, 0.6, 0.35, 0.2], lfe: [Double] = [1, 0.2, 0, 0, 0]
        let sides: [Double] = [0.12, 0.35, 0.6, 0.8, 0.7], uppers: [Double] = [0.04, 0.12, 0.4, 0.8, 1]
        for role in 0..<Role.count {
            let tilt = role < 3 ? fronts : (role == Role.lfe ? lfe : ([6, 7, 12, 13, 14, 15].contains(role) ? uppers : sides))
            let power = Double(result.channelRMS[role] * result.channelRMS[role])
            for band in 0..<StereoBands.count {
                let breathe = 1 + 0.5 * sin(time * (0.6 + 0.2 * Double(band)) + Double(role))
                result.roleBandPower[role * StereoBands.count + band] = Float(power * tilt[band] * breathe)
            }
        }
        result.correlation = Float(0.62 + 0.25 * sin(time * 0.7))
        // Stereo bands: a centred, near-mono bass that widens up the spectrum, a lead drifting across the mids and
        // an airy top with a brief dip toward out of phase, so every band colour and arc can be reviewed.
        let bandCorrelation = [0.96 + 0.03 * sin(time * 0.9), 0.82 + 0.1 * sin(time * 0.6), 0.55 + 0.25 * sin(time * 0.7),
                               0.3 + 0.3 * sin(time * 0.5 + 1), 0.05 + 0.4 * sin(time * 0.33)]
        let bandBalance = [0.02 * sin(time), 0.08 * sin(time * 0.4), 0.35 * sin(time * 0.3), -0.2 * sin(time * 0.45), 0.1 * sin(time * 0.8)]
        let bandLevel = [-19 + 3 * sin(time * 7.5), -22.0, -24 + 2 * sin(time * 0.9), -29.0, -38 + 2 * sin(time * 1.3)]
        // Each band's L², R² and L·R, summed per group (five, three, overall) and read out as the DSP does.
        let sums = (0..<StereoBands.count).map { band -> (left: Double, right: Double, cross: Double) in
            let energy = 2 * pow(10, bandLevel[band] / 10)
            let left = energy * (1 - bandBalance[band]) / 2, right = energy * (1 + bandBalance[band]) / 2
            return (left, right, max(-1, min(1, bandCorrelation[band])) * (left * right).squareRoot())
        }
        for (group, members) in StereoBands.groups.enumerated() {
            let left = members.reduce(0) { $0 + sums[$1].left }, right = members.reduce(0) { $0 + sums[$1].right }
            let cross = members.reduce(0) { $0 + sums[$1].cross }
            result.bandCorrelation[group] = Float(cross / (left * right).squareRoot())
            result.bandWidth[group] = Float((left + right - 2 * cross) / (2 * (left + right)))
            result.bandBalance[group] = Float((right - left) / (left + right))
            result.bandLevel[group] = Float(10 * log10((left + right) / 2))
        }
        // Stereometer cloud: per band, a tone on each side with the phase offset that gives its correlation and
        // the gains that give its balance, sampled over 1/30 s like the DSP's points.
        let tones = [55.0, 230, 910, 3_450, 10_900]
        for band in 0..<StereoBands.count {
            let amplitude = pow(10, bandLevel[band] / 20) * 2.0.squareRoot()
            let phase = acos(max(-1, min(1, bandCorrelation[band])))
            let left = amplitude * (1 - bandBalance[band]).squareRoot(), right = amplitude * (1 + bandBalance[band]).squareRoot()
            for point in 0..<StereoBands.scopePoints {
                let t = time + Double(point) / Double(StereoBands.scopePoints) / 30
                let swell = 0.6 + 0.4 * sin(t * 13 + Double(band * point))
                let index = (band * StereoBands.scopePoints + point) * 2
                result.bandPoints[index] = Float(left * swell * sin(2 * .pi * tones[band] * t))
                result.bandPoints[index + 1] = Float(right * swell * sin(2 * .pi * tones[band] * t + phase))
            }
        }
        result.loudnessRange = Float(6.8 + 0.4 * sin(time * 0.03))
        // Envelopes at 240 columns/s: a 120 BPM kick under a slowly breathing bed, each role with its own
        // level and phase so the lanes read apart.
        let columnsPerUpdate = Int(WaveformEnvelope.columnRate / updateRate)
        let newest = sequence * columnsPerUpdate
        result.waveSerial = Float(newest % WaveformEnvelope.serialModulus)
        for index in 0..<WaveformEnvelope.publishedColumns {
            let column = Double(newest - WaveformEnvelope.publishedColumns + 1 + index)
            let t = column / WaveformEnvelope.columnRate
            let beat = (t * 2).truncatingRemainder(dividingBy: 1)
            let columnBase = index * WaveformEnvelope.valuesPerColumn
            for role in 0..<Role.count {
                if !spatial && role >= 2 { continue }
                let gain = pow(10, (base[role] + 11) / 20)
                let shift = Double(role) * 0.071
                let body = 0.16 + 0.07 * sin(t * 1.7 + Double(role)) + 0.05 * sin(column * (0.9 - 0.03 * Double(role)))
                let kick = (role == Role.lfe ? 0.75 : 0.55) * exp(-((beat + shift).truncatingRemainder(dividingBy: 1)) * 9)
                let snare = role == Role.lfe ? 0 : 0.30 * exp(-abs(beat - 0.5 + shift) * 30)
                let high = min(0.98, (body + kick + snare) * gain)
                let low = high * (0.88 + 0.1 * sin(column * (0.53 + 0.02 * Double(role))))
                result.waveform[columnBase + role * 2] = Float(-low)
                result.waveform[columnBase + role * 2 + 1] = Float(high)
            }
        }
        field(at: time, spatial: spatial, layout: layout, into: &result)
        result.heldPeaks = result.channelPeaks
        result.heldTruePeaks = result.channelTruePeaks
        result.leftPeak = result.channelPeaks[0]
        result.rightPeak = result.channelPeaks[1]
        result.leftRMS = result.channelRMS[0]
        result.rightRMS = result.channelRMS[1]
        let hot: Double = Diagnostics.snapshotHot ? 10 : 0
        result.momentaryLUFS = Float(-17.5 + hot + 3 * sin(time * 0.9))
        result.shortLUFS = Float(-18.6 + hot + 1.6 * sin(time * 0.25))
        result.integratedLUFS = Float(-19.2 + hot + 0.3 * sin(time * 0.05))
        return result
    }

    /// Each field band's centre (Hz) and analysis band, and the bed's share of each band (a broad bump around
    /// 350 Hz, summing to 1): the same every snapshot, so computed once.
    private static let bandHz = (0..<SpatialField.bandCount).map { SpatialField.centre($0) }
    private static let bandFive = (0..<SpatialField.bandCount).map { band in
        StereoBands.edges.lastIndex { SpatialField.centre(band) >= $0 } ?? 0
    }
    private static let bedShape: [Double] = {
        let shape = (0..<SpatialField.bandCount).map { band -> Double in
            let distance = log2(SpatialField.centre(band) / 350) / 3
            return pow(10, -1.2 * distance * distance)
        }
        let sum = shape.reduce(0, +)
        return shape.map { $0 / sum }
    }()

    /// One virtual source of the demo's spatial field: a spectral bump (centre and width in octaves, peak level in dB
    /// mean square per field band) fed to speakers with amplitude gains and phases; coherent (one signal in every
    /// speaker) or independent (its own signal in each).
    private struct Source {
        var centre: Double
        var octaves: Double
        var level: Double
        var feeds: [(role: Int, gain: Double, phase: Double)]
        var coherent: Bool
        var slot: Int
    }

    /// The demo's spatial field (`SpatialField`), as the analysis would decompose these sources: a centred bass
    /// phantom with the LFE under it, a kick and a voice in the centre, a guitar drifting between the front left
    /// speakers, keys between the right side speakers, a pad overhead, reverb independent in every surround and height,
    /// hi-hats alternating behind, and every few seconds a widener's anti-phase highs; under them a bed independent in
    /// every channel tops each one up to its channel level, so the field and the meters tell one story. In the stereo
    /// part of the cycle only L and R carry the bass, voice, guitar, keys and reverb. Each band's role energies also
    /// make the five-band powers the room and the centroid read.
    static func field(at time: Double, spatial: Bool, layout: SpeakerLayout, into result: inout MeterSnapshot) {
        let has = { (role: Int) in layout.contains(role) && (spatial || role <= Role.right) }
        let drift = 0.5 + 0.5 * sin(time * 0.31)
        let pulse = exp(-((time * 2).truncatingRemainder(dividingBy: 1)) * 7)
        let hats = (time * 4).truncatingRemainder(dividingBy: 2) < 1
        let widen = sin(time * 0.45) > 0.55
        var sources: [Source] = [
            Source(centre: 60, octaves: 1.2, level: -38, feeds: [(Role.left, 0.707, 0), (Role.right, 0.707, 0)], coherent: true, slot: 0),
            Source(centre: 55, octaves: 0.6, level: -36 + 10 * pulse, feeds: [(Role.lfe, 1, 0)], coherent: false, slot: 0),
            Source(centre: 70, octaves: 0.8, level: -40 + 14 * pulse, feeds: [(spatial ? Role.center : Role.left, 1, 0)] + (spatial ? [] : [(Role.right, 1, 0)]),
                   coherent: !spatial, slot: 1),
            Source(centre: 900, octaves: 1.6, level: -44 + 3 * sin(time * 1.7),
                   feeds: spatial ? [(Role.center, 1, 0)] : [(Role.left, 0.707, 0), (Role.right, 0.707, 0)], coherent: !spatial, slot: 0),
            Source(centre: 600, octaves: 1.4, level: -47,
                   feeds: [(Role.left, cos(drift * .pi / 2), 0), (spatial ? Role.leftWide : Role.right, sin(drift * .pi / 2) * (spatial ? 1 : 0.4), 0)],
                   coherent: true, slot: 1),
            Source(centre: 1_800, octaves: 1.2, level: -50,
                   feeds: [(Role.right, 0.8, 0), (spatial ? Role.rightSurround : Role.left, spatial ? 0.6 : 0.3, 0)], coherent: true, slot: 2),
            Source(centre: 3_000, octaves: 2.2, level: -60, feeds: [(Role.left, 0.707, 0), (Role.right, 0.707, 0)] +
                   (spatial ? [Role.leftSurround, Role.rightSurround, Role.leftRearSurround, Role.rightRearSurround, Role.leftTopFront,
                               Role.rightTopFront, Role.leftTopRear, Role.rightTopRear].map { ($0, 0.6, 0) } : []), coherent: false, slot: 0),
        ]
        if spatial {
            sources.append(Source(centre: 700, octaves: 1.3, level: -52 + 2 * sin(time * 0.6),
                                  feeds: [(Role.leftTopFront, 0.707, 0), (Role.rightTopFront, 0.707, 0)], coherent: true, slot: 2))
            sources.append(Source(centre: 9_000, octaves: 0.9, level: -54,
                                  feeds: [(hats ? Role.rightRearSurround : Role.leftTopRear, 1, 0)], coherent: false, slot: 0))
        }
        if widen {
            sources.append(Source(centre: 5_000, octaves: 0.8, level: -56, feeds: [(Role.left, 0.707, 0), (Role.right, 0.707, Double.pi)],
                                  coherent: true, slot: 0))
        }
        var field = [Float](repeating: 0, count: SpatialField.floats)
        field[SpatialField.status] = 1
        field[SpatialField.threshold] = SpatialField.defaultThreshold
        field[SpatialField.speakers] = Float(layout.speakers.filter { $0.group != .lfe }.count)
        var power = [Float](repeating: 0, count: StereoBands.roleFloats)
        let sides = layout.sidesAtNinety
        // Each source's feeds, once per snapshot rather than once per band: the ones this layout has, the directed ones
        // among them and, for a coherent source, its speakers' directions, energies and phases.
        struct Prepared {
            var feeds: [(role: Int, gain: Double, phase: Double)]
            var coherent: Bool
            var directions: [SIMD3<Float>] = [], energies: [Float] = [], cosines: [Float] = [], sines: [Float] = []
            var directedEnergy = 0.0
            /// The image for each velocity weight met so far (most bands are wholly bass or wholly treble).
            var images: [Float: [Float]] = [:]
        }
        var prepared = sources.map { source -> Prepared in
            let feeds = source.feeds.filter { has($0.role) && $0.gain > 0.001 }
            let directed = feeds.filter { $0.role != Role.lfe }
            var p = Prepared(feeds: feeds, coherent: source.coherent && directed.count >= 2)
            guard p.coherent else { return p }
            p.directions = directed.map { feed -> SIMD3<Float> in
                let d = SpeakerGeometry.direction(role: feed.role, sidesAtNinety: sides) ?? .zero
                return SIMD3(Float(d.x), Float(d.y), Float(d.z))
            }
            p.energies = directed.map { Float($0.gain * $0.gain) }
            p.cosines = directed.map { Float(cos($0.phase)) }
            p.sines = directed.map { Float(sin($0.phase)) }
            p.directedEnergy = directed.reduce(0) { $0 + $1.gain * $1.gain }
            return p
        }
        let hzs = Self.bandHz, fives = Self.bandFive
        var image = [Float](repeating: 0, count: SpatialField.componentFloats)
        for band in 0..<SpatialField.bandCount {
            let hz = hzs[band], five = fives[band]
            let weight = SpatialField.velocityWeight(hz: hz)
            for (index, source) in sources.enumerated() {
                let distance = log2(hz / source.centre) / source.octaves
                let energy = pow(10, (source.level - 12 * distance * distance) / 10)
                guard energy > 1e-12, !prepared[index].feeds.isEmpty else { continue }
                for feed in prepared[index].feeds { power[feed.role * StereoBands.count + five] += Float(energy * feed.gain * feed.gain) }
                if !prepared[index].coherent {
                    for feed in prepared[index].feeds {
                        field[SpatialField.independent(band: band, role: feed.role)] += Float(energy * feed.gain * feed.gain)
                    }
                    continue
                }
                // A coherent source: one image where the analysis puts it (`SpatialField.image`).
                let o = SpatialField.component(band: band, slot: source.slot)
                let e = Float(energy * prepared[index].directedEnergy)
                // Two sources in one slot of a band: the louder keeps it.
                guard e > field[o + SpatialField.Component.energy] else { continue }
                if let known = prepared[index].images[weight] {
                    for k in SpatialField.Component.x...SpatialField.Component.stability { field[o + k] = known[k] }
                } else {
                    let p = prepared[index]
                    image.withUnsafeMutableBufferPointer { out in
                        SpatialField.image(count: p.directions.count, directions: p.directions, energies: p.energies, cosines: p.cosines,
                                           sines: p.sines, velocityWeight: weight, into: out.baseAddress!)
                    }
                    prepared[index].images[weight] = image
                    for k in SpatialField.Component.x...SpatialField.Component.stability { field[o + k] = image[k] }
                }
                field[o + SpatialField.Component.energy] = e
                field[o + SpatialField.Component.coherence] = 1
            }
        }
        // The bed (strings and room, a broad bump around 350 Hz): whatever each channel's level has left over.
        let shape = Self.bedShape
        for role in 0..<Role.count where role != Role.lfe && has(role) {
            let rms = Double(result.channelRMS[role])
            let carried = (0..<StereoBands.count).reduce(0.0) { $0 + Double(power[role * StereoBands.count + $1]) }
            let missing = rms * rms - carried
            guard missing > 0 else { continue }
            for band in 0..<SpatialField.bandCount {
                let energy = Float(missing * shape[band])
                field[SpatialField.independent(band: band, role: role)] += energy
                power[role * StereoBands.count + fives[band]] += energy
            }
        }
        result.spatialField = field
        result.roleBandPower = power
    }
}
