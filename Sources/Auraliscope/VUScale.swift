import AnalysisCore
import Foundation
import QuartzCore

/// Scale and ballistics of the summary's VU meter.
///
/// The meter aggregates the whole programme: the power sum of every routed channel except LFE (which BS.1770
/// also leaves out), so a pair of equal channels reads 3 dB above either one. 0 VU sits at the loudness target of
/// the current monitoring mode, in dBFS RMS (−18 dBFS, the usual digital alignment, by default), so a programme
/// that meets its standard swings around 0 VU. Like an analogue VU the arc is linear in voltage, so the top of
/// the scale is spread out and −20 VU sits near the left stop.
enum VUScale {
    static let defaultReference: Float = -18
    /// Stored 0 VU level in dBFS; 0 follows the loudness target of the current mode.
    static let referenceKey = "vu.reference"
    static let referenceChoices: [Double] = [0, -14, -18, -20, -24]
    static let top: Float = 3
    static let marks: [Float] = [-20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3]
    /// Needle travel: ±48° either side of vertical.
    static let halfSweep = 48.0 * Double.pi / 180

    /// Aggregate programme level in dBFS: power sum over the routed roles, LFE excluded.
    static func aggregate(rms: [Float], roles: [Bool]) -> Float {
        var power: Float = 0
        for role in 0..<min(rms.count, roles.count) where roles[role] && role != Role.lfe { power += rms[role] * rms[role] }
        return MeterScale.decibels(sqrt(power))
    }

    static func vu(fromDecibels db: Float, reference: Float = defaultReference) -> Float { db - reference }

    /// 0 at the rest stop, 1 at +3 VU: linear in voltage relative to full deflection.
    static func fraction(vu: Float) -> Double {
        guard vu.isFinite else { return 0 }
        return Double(max(0, min(1.04, pow(10, (vu - top) / 20))))
    }
}

/// IEC 60268-17 VU ballistics: a second-order response (ωn 13.5 rad/s, ζ 0.81) that reaches 99 % of a
/// step in about 300 ms and overshoots by about 1.3 %. It runs on the linear needle fraction, as the
/// moving coil does.
final class VUBallistics: ObservableObject {
    static let omega = 13.5
    static let damping = 0.81

    private(set) var position = 0.0
    private var velocity = 0.0
    private var lastTime: CFTimeInterval?

    func step(toward target: Double, at time: CFTimeInterval) -> Double {
        let elapsed = min(0.1, max(0, time - (lastTime ?? time)))
        lastTime = time
        // Semi-implicit Euler in 1 ms substeps stays stable and accurate at any frame rate.
        let steps = max(1, Int((elapsed / 0.001).rounded(.up)))
        let dt = elapsed / Double(steps)
        for _ in 0..<steps {
            let acceleration = Self.omega * Self.omega * (target - position) - 2 * Self.damping * Self.omega * velocity
            velocity += acceleration * dt
            position += velocity * dt
        }
        position = max(0, min(1.08, position))
        return position
    }

    func rest() {
        position = 0
        velocity = 0
        lastTime = nil
    }

    /// Stops the needle where it is (a paused meter holds its picture); the next step starts from there.
    func hold() {
        velocity = 0
        lastTime = nil
    }
}
