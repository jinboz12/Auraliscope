import Foundation

// Critically damped, time-based display filter. Raw DSP and LUFS measurements remain untouched.
final class DampedDisplayState {
    private var value = MeterSnapshot()
    private var spectrumVelocity = [Float](repeating: 0, count: MeterSnapshot.bandCount)
    private var peakVelocity = [Float](repeating: 0, count: Role.count)
    private var rmsVelocity = [Float](repeating: 0, count: Role.count)
    private var loudnessVelocity = [Float](repeating: 0, count: 3)
    private var correlationVelocity: Float = 0
    private var initialized = false

    func step(target: MeterSnapshot, deltaTime: Float) -> MeterSnapshot {
        if !initialized || value.streamID != target.streamID {
            value = target
            spectrumVelocity = Array(repeating: 0, count: MeterSnapshot.bandCount)
            peakVelocity = Array(repeating: 0, count: Role.count)
            rmsVelocity = Array(repeating: 0, count: Role.count)
            loudnessVelocity = Array(repeating: 0, count: 3)
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
        // A gentle needle: correlation flickers tick to tick, so it settles more slowly than levels.
        if target.correlation == MeterSnapshot.noCorrelation || value.correlation == MeterSnapshot.noCorrelation {
            value.correlation = target.correlation
            correlationVelocity = 0
        } else {
            damp(&value.correlation, &correlationVelocity, target.correlation, dt, 6)
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
