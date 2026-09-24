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
        result.spectrogram = (0..<MeterSnapshot.spectrogramBandCount).map {
            level($0, bands: MeterSnapshot.spectrogramBandCount)
        }
        if let loudest = result.spectrogram.indices.max(by: { result.spectrogram[$0] < result.spectrogram[$1] }) {
            let fraction = (Double(loudest) + 0.5) / Double(MeterSnapshot.spectrogramBandCount)
            result.peakFrequency = Float(20 * pow(1_000, fraction))
            result.peakLevel = result.spectrogram[loudest]
        }
        // Role order: L R C LFE Ls Rs Ltf Rtf Lrs Rrs Lw Rw Ltm Rtm Ltr Rtr.
        let base: [Double] = [-11, -10, -9, -16, -17, -18, -22, -23, -20, -21, -15, -14, -25, -24, -27, -26]
        let spatial = isSpatial(at: time)
        for role in 0..<Role.count {
            let wobble = 4 * sin(time * (1.3 + Double(role) * 0.37) + Double(role))
            // Sit the channel levels where a −18 LUFS mix really is (≈ −20 dBFS RMS on the fronts), so the
            // meters, the VU needle and the loudness readouts tell one story.
            let rms = base[role] + wobble - 15
            let crest = role == Role.lfe ? 5.0 : 9 + 2 * sin(time * 2.1 + Double(role))
            let silent = !spatial && role >= 2
            result.channelRMS[role] = silent ? 0 : Float(pow(10, rms / 20))
            result.channelPeaks[role] = silent ? 0 : Float(pow(10, min(-0.4, rms + crest) / 20))
            result.channelTruePeaks[role] = silent ? 0 : Float(pow(10, min(0.3, rms + crest + 0.4) / 20))
        }
        result.correlation = Float(0.62 + 0.25 * sin(time * 0.7))
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
        result.momentaryLUFS = Float(-17.5 + 3 * sin(time * 0.9))
        result.shortLUFS = Float(-18.6 + 1.6 * sin(time * 0.25))
        result.integratedLUFS = Float(-19.2 + 0.3 * sin(time * 0.05))
        return result
    }
}
