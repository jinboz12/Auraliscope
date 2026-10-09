import Foundation

/// A cosine-sum analysis window, w[n] = Σₖ (−1)ᵏ aₖ cos(2πkn/N) for n = 0…N−1 (periodic, as an FFT frame wants), and
/// what its users need from it: its samples, its spectral kernel, and the tone estimator that kernel implies.
///
/// - Hann (a = ½, ½) has the narrowest main lobe of the family (±2 bins) but sidelobes from −31 dB, falling 18 dB
///   per octave: a loud tone keeps leaking for ±14 bins before it is 78 dB down. The live spectrum uses it.
/// - The minimum 4-term Blackman–Harris (Harris 1978) has a main lobe of ±4 bins and no sidelobe above −92 dB: the
///   whole lobe of a full-scale tone fits inside a spectrogram's colour range and nothing leaks outside it. The
///   spectrogram uses it, at twice the length Hann would need for the same main-lobe width in Hz.
package struct SpectralWindow: Equatable, Sendable {
    package let coefficients: [Double]

    package static let hann = SpectralWindow(coefficients: [0.5, 0.5])
    package static let blackmanHarris = SpectralWindow(coefficients: [0.35875, 0.48829, 0.14128, 0.01168])

    /// Half the main lobe's width, in bins (its first null).
    package var mainLobe: Double { Double(coefficients.count) }

    /// The N samples of the window, periodic.
    package func samples(_ length: Int) -> [Float] {
        (0..<length).map { n in
            var value = 0.0
            for (k, a) in coefficients.enumerated() {
                value += (k.isMultiple(of: 2) ? a : -a) * cos(2 * Double.pi * Double(k * n) / Double(length))
            }
            return Float(value)
        }
    }

    /// The magnitude of the window's transform `offset` bins from its centre, relative to the centre (large-N form:
    /// each cosine term shifts a sinc by ±k bins, and the window's centring makes every term add in phase).
    package func kernel(_ offset: Double) -> Double {
        func sinc(_ x: Double) -> Double { abs(x) < 1e-12 ? 1 : sin(Double.pi * x) / (Double.pi * x) }
        var value = coefficients[0] * sinc(offset)
        for k in 1..<coefficients.count {
            value += coefficients[k] / 2 * (sinc(offset - Double(k)) + sinc(offset + Double(k)))
        }
        return abs(value) / coefficients[0]
    }
}

/// A tone's position and level from the three bins around a spectral peak, for one window: exact for a single
/// steady tone (up to leakage from elsewhere), with no transcendental function per call.
///
/// With the tone δ bins from the loudest bin k (|δ| ≤ ½), the louder neighbour sits 1 − |δ| bins from it, so the dB
/// gap between bin k and that neighbour is 20·log₁₀(W(δ) / W(1 − δ)), W the window's kernel: a function of |δ| alone,
/// falling monotonically from `gapLimit` (the tone on the bin) to 0 (half-way between two bins). Inverting it gives
/// δ, and W(δ) the level lost to scalloping. For Hann this is Grandke's estimator, δ = (2α − 1)/(α + 1).
package final class PeakEstimator: Sendable {
    package let window: SpectralWindow
    /// The gap with the tone exactly on a bin: Hann 6.02 dB, Blackman–Harris 3.35 dB. Wider gaps give no offset.
    package let gapLimit: Float
    private static let steps = 1024
    /// Offset (bins) and level correction (dB) for gaps from `gapLimit` (entry 0) down to 0 (the last).
    private let table: [(offset: Float, gain: Float)]

    package static let hann = PeakEstimator(window: .hann)
    package static let blackmanHarris = PeakEstimator(window: .blackmanHarris)

    package init(window: SpectralWindow) {
        self.window = window
        func gap(_ delta: Double) -> Double { 20 * log10(window.kernel(delta) / window.kernel(1 - delta)) }
        let limit = gap(0)
        gapLimit = Float(limit)
        // Sample δ finely, then read it back on an even grid of gaps (the gap falls monotonically with δ).
        let fine = 16_384
        let deltas = (0...fine).map { 0.5 * Double($0) / Double(fine) }
        let gaps = deltas.map(gap)
        var index = 0
        table = (0...Self.steps).map { step in
            let target = (1 - Double(step) / Double(Self.steps)) * limit
            while index + 1 < fine && gaps[index + 1] > target { index += 1 }
            let span = gaps[index] - gaps[index + 1]
            let t = span > 0 ? max(0, min(1, (gaps[index] - target) / span)) : 0
            let delta = deltas[index] + (deltas[index + 1] - deltas[index]) * t
            return (Float(delta), Float(-20 * log10(window.kernel(delta))))
        }
    }

    /// The tone's offset from bin k (−½…½ bin) and its level, from the dB levels `a`, `b`, `c` of bins k−1, k, k+1, k
    /// the loudest. Neighbours louder than `b` (not a peak) give no offset.
    package func peak(_ a: Float, _ b: Float, _ c: Float) -> (offset: Float, level: Float) {
        let right = c >= a
        let gap = max(0, b - (right ? c : a))
        guard gap < gapLimit else { return (0, b) }
        let position = (1 - gap / gapLimit) * Float(Self.steps)
        let index = min(Self.steps - 1, Int(position))
        let t = position - Float(index)
        let lower = table[index], upper = table[index + 1]
        let delta = lower.offset + (upper.offset - lower.offset) * t
        let gain = lower.gain + (upper.gain - lower.gain) * t
        return (right ? delta : -delta, b + gain)
    }
}
