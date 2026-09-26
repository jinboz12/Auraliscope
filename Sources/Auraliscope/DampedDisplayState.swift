import Foundation

// Critically damped, time-based display filter. Raw DSP and LUFS measurements remain untouched.
final class DampedDisplayState {
    private var value = MeterSnapshot()
    private var spectrumVelocity = [Float](repeating: 0, count: MeterSnapshot.bandCount)
    private var peakVelocity = [Float](repeating: 0, count: Role.count)
    private var rmsVelocity = [Float](repeating: 0, count: Role.count)
    private var loudnessVelocity = [Float](repeating: 0, count: 3)
    private var correlationVelocity: Float = 0
    private var bandVelocity = [Float](repeating: 0, count: 3 * StereoBands.groups.count)
    private var initialized = false

    func step(target: MeterSnapshot, deltaTime: Float) -> MeterSnapshot {
        if !initialized || value.streamID != target.streamID {
            value = target
            spectrumVelocity = Array(repeating: 0, count: MeterSnapshot.bandCount)
            peakVelocity = Array(repeating: 0, count: Role.count)
            rmsVelocity = Array(repeating: 0, count: Role.count)
            loudnessVelocity = Array(repeating: 0, count: 3)
            bandVelocity = Array(repeating: 0, count: 3 * StereoBands.groups.count)
            initialized = true
            return value
        }
        let dt = max(0, min(0.1, deltaTime))
        for i in 0..<MeterSnapshot.bandCount {
            damp(&value.spectrum[i], &spectrumVelocity[i], target.spectrum[i], dt, 22)
        }
        for i in 0..<Role.count {
            let peakSpeed: Float = target.channelPeaks[i] > value.channelPeaks[i] ? 34 : 11
            damp(&value.channelPeaks[i], &peakVelocity[i], target.channelPeaks[i], dt, peakSpeed)
            damp(&value.channelRMS[i], &rmsVelocity[i], target.channelRMS[i], dt, 15)
        }
        damp(&value.momentaryLUFS, &loudnessVelocity[0], target.momentaryLUFS, dt, 13)
        damp(&value.shortLUFS, &loudnessVelocity[1], target.shortLUFS, dt, 10)
        damp(&value.integratedLUFS, &loudnessVelocity[2], target.integratedLUFS, dt, 7)
        // The DSP already integrates correlation over 0.25 s, so the needle only needs smoothing between ticks.
        if target.correlation == MeterSnapshot.noCorrelation || value.correlation == MeterSnapshot.noCorrelation {
            value.correlation = target.correlation
            correlationVelocity = 0
        } else {
            damp(&value.correlation, &correlationVelocity, target.correlation, dt, 12)
        }
        // Band correlations rest in silence like the broadband one; width and balance only move while it reads.
        for band in 0..<StereoBands.groups.count {
            value.bandLevel[band] = target.bandLevel[band]
            if target.bandCorrelation[band] == MeterSnapshot.noCorrelation || value.bandCorrelation[band] == MeterSnapshot.noCorrelation {
                value.bandCorrelation[band] = target.bandCorrelation[band]
                value.bandWidth[band] = target.bandWidth[band]
                value.bandBalance[band] = target.bandBalance[band]
                for k in 0..<3 { bandVelocity[3 * band + k] = 0 }
            } else {
                damp(&value.bandCorrelation[band], &bandVelocity[3 * band], target.bandCorrelation[band], dt, 12)
                damp(&value.bandWidth[band], &bandVelocity[3 * band + 1], target.bandWidth[band], dt, 12)
                damp(&value.bandBalance[band], &bandVelocity[3 * band + 2], target.bandBalance[band], dt, 12)
            }
        }
        value.sequence = target.sequence
        return value
    }

    private func damp(_ position: inout Float, _ velocity: inout Float, _ target: Float,
                      _ dt: Float, _ omega: Float) {
        let displacement = position - target
        let factor = exp(-omega * dt)
        let impulse = velocity + omega * displacement
        position = target + (displacement + impulse * dt) * factor
        velocity = (velocity - omega * impulse * dt) * factor
    }
}
