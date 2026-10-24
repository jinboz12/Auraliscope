import Foundation

/// DC offset and infrasonic energy per role, for the master check: what the loudness meter's K-weighting and the
/// spectrum (which starts at 20 Hz) cannot show.
///
/// - DC offset: each role's mean, integrated with a 1 s time constant. A converter or plug-in that adds a constant
///   shows here as a steady value; music averages to almost nothing.
/// - Infrasonic energy: the role with its drift removed (a 0.1 s mean subtracted, a first-order high-pass near
///   1.6 Hz, so an offset switching on clears within a few tenths of a second) through a fourth-order Butterworth
///   low-pass at 20 Hz, its mean square integrated over 1 s. It covers what lies between DC and the audible band:
///   rumble, wind, handling noise, a subsonic oscillation. At 40 Hz the low-pass is 24 dB down, so a strong bass
///   leaks a little into the reading.
///
/// The filters run in double precision: a 20 Hz corner at 192 kHz sits at 0.0001 of the sample rate, where single
/// precision coefficients and state misplace it. Only routed roles are analysed.
package final class SignalHealthMeter {
    package static let cutoff = 20.0
    package static let timeConstant = 1.0
    /// The infrasonic path's drift remover.
    package static let driftTimeConstant = 0.1

    private let roles: [Int]
    /// Per-sample weight of the 1 s integrators.
    private let alpha: Double
    private let driftAlpha: Double
    /// Two biquads (Butterworth Q 0.5412 and 1.3066), coefficients b0, b1, b2, a1, a2 each.
    private let sections: [(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double)]
    /// Per role: the running mean, the low-pass state (four values per section) and the mean square.
    private var mean = [Double](repeating: 0, count: Role.count)
    private var drift = [Double](repeating: 0, count: Role.count)
    private var state = [Double](repeating: 0, count: Role.count * 8)
    private var meanSquare = [Double](repeating: 0, count: Role.count)
    /// Samples analysed per role since the start or the last break, so the first second is not read as settled.
    private var settled = [Int](repeating: 0, count: Role.count)
    private let settleSamples: Int

    package init(sampleRate: Double, activeRoles: [Bool]) {
        roles = (0..<Role.count).filter { $0 < activeRoles.count && activeRoles[$0] }
        alpha = 1 - exp(-1 / (sampleRate * Self.timeConstant))
        driftAlpha = 1 - exp(-1 / (sampleRate * Self.driftTimeConstant))
        settleSamples = Int(sampleRate * Self.timeConstant)
        // Bilinear transform of the analog Butterworth sections, prewarped to the corner.
        let k = tan(.pi * Self.cutoff / sampleRate)
        sections = [0.541_196_100_146_197, 1.306_562_964_876_377].map { q in
            let norm = 1 / (1 + k / q + k * k)
            let b0 = k * k * norm
            return (b0, 2 * b0, b0, 2 * (k * k - 1) * norm, (1 - k / q + k * k) * norm)
        }
    }

    package func consume(_ block: PlanarBlock) {
        let alpha = self.alpha, driftAlpha = self.driftAlpha
        let s0 = sections[0], s1 = sections[1]
        mean.withUnsafeMutableBufferPointer { mean in
            state.withUnsafeMutableBufferPointer { state in
                meanSquare.withUnsafeMutableBufferPointer { meanSquare in
                    for role in roles {
                        let input = block.channel(role)
                        var m = mean[role], d = drift[role], ms = meanSquare[role]
                        let z = state.baseAddress! + role * 8
                        var x1 = z[0], x2 = z[1], y1 = z[2], y2 = z[3]
                        var u1 = z[4], u2 = z[5], v1 = z[6], v2 = z[7]
                        for i in 0..<block.count {
                            let x = Double(input[i])
                            m += alpha * (x - m)
                            d += driftAlpha * (x - d)
                            let a = x - d
                            let y = s0.b0 * a + s0.b1 * x1 + s0.b2 * x2 - s0.a1 * y1 - s0.a2 * y2
                            x2 = x1; x1 = a; y2 = y1; y1 = y
                            let v = s1.b0 * y + s1.b1 * u1 + s1.b2 * u2 - s1.a1 * v1 - s1.a2 * v2
                            u2 = u1; u1 = y; v2 = v1; v1 = v
                            ms += alpha * (v * v - ms)
                        }
                        // Denormals in a long silence would slow the loop; they mean nothing here.
                        func flush(_ value: Double) -> Double { abs(value) < 1e-30 ? 0 : value }
                        z[0] = flush(x1); z[1] = flush(x2); z[2] = flush(y1); z[3] = flush(y2)
                        z[4] = flush(u1); z[5] = flush(u2); z[6] = flush(v1); z[7] = flush(v2)
                        mean[role] = flush(m)
                        drift[role] = flush(d)
                        meanSquare[role] = flush(ms)
                        settled[role] = min(settleSamples, settled[role] + block.count)
                    }
                }
            }
        }
    }

    /// A break in the audio: the filters start again; the integrators keep their values but must settle anew.
    package func interrupt() {
        for i in state.indices { state[i] = 0 }
        for role in roles { settled[role] = 0 }
    }

    /// Whether every analysed role has run a full time constant.
    package var ready: Bool { roles.allSatisfy { settled[$0] >= settleSamples } }

    /// Writes `Role.count` DC offsets (linear, signed) and `Role.count` infrasonic mean squares (linear), then the
    /// status (1 measured and settled, 0.5 settling).
    package func write(into v: UnsafeMutablePointer<Float>) {
        for role in 0..<Role.count {
            v[role] = Float(mean[role])
            v[Role.count + role] = Float(meanSquare[role])
        }
        v[2 * Role.count] = ready ? 1 : 0.5
    }
}
