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

    static func snapshot(at time: Double, sequence: Int) -> MeterSnapshot {
        var result = MeterSnapshot()
        result.sequence = Float(sequence % 1_000_000 + 1)
        result.spectrogramSerial = result.sequence
        result.streamID = 1
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
}
