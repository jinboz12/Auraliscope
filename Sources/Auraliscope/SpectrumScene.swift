import AnalysisCore
import MetalKit

// MARK: - Spectrum: live curve of the monitored channels with per-band peak holds, beside the waterfall

/// Drawn in the Spectrum card's `SpectrogramLayout.spectrum` strip, on the waterfall's frequency axis: each point's
/// level reaches right from the floor, so the live spectrum continues the waterfall's newest column.
///
/// The curve is the 128 fine bands (`MeterSnapshot.spectrumFine`), about 1/13 octave, each standing for four
/// waterfall rows. They come from the spectrum's single long transform rather than the waterfall's multi-resolution
/// column, so broadband sound keeps one calibration across the axis (pink noise falls 3 dB per octave everywhere,
/// as on any FFT analyzer) and the curve and its average can be read for tonal balance; a sine reads its level in
/// both.
final class SpectrumScene: CanvasScene {
    /// Points of the curve: the fine bands.
    static let pointCount = MeterSnapshot.fineBandCount

    private var holds = [Float](repeating: -120, count: pointCount)
    private var holdTimers = [Float](repeating: 0, count: pointCount)
    private var velocity = [Float](repeating: 0, count: pointCount)
    private var curve: [CGPoint] = []
    private var epoch = -1
    private var stream: Float = 0
    /// The levels last drawn (damped, untilted), for the inspector.
    private(set) var shown = [Float](repeating: -120, count: pointCount)
    /// Long-term average spectrum since the last reset: each point's mean power over every snapshot that carried
    /// signal, the average engineers compare a mix's tonal balance with. Averaged in power, not dB, so loud passages
    /// weigh as they sound; silence (a stopped transport, a pause) is left out instead of dragging it down.
    private var averagePower = [Double](repeating: 0, count: pointCount)
    private(set) var averageCount = 0
    private var averagedSequence: Float = 0
    private var averagedStream: Float = 0
    private var averagedRate: Double = 0
    private var averagedSpatial = false
    /// Distinct received snapshots before the average is drawn; skipped display frames are not reconstructed.
    static let averageMinimum = 60
    /// The average in dBFS per point (untilted), once it rests on `averageMinimum` snapshots.
    var average: [Float]? {
        guard averageCount >= Self.averageMinimum else { return nil }
        return averagePower.map { Float(10 * log10(max($0 / Double(averageCount), 1e-12))) }
    }

    // Shapes only: no underlay quad is ever added, so the texture is never bound.
    var underlayKind: UnderlayKind { .waterfall }
    var underlayTexture: MTLTexture? { nil }
    var underlayState: UnderlayState { UnderlayState() }
    var usesDampedLevels: Bool { false }

    init() { curve.reserveCapacity(Self.pointCount * Self.subdivisions + 3) }

    /// A reset clears the peak holds, as it does the channel meters'.
    func prepare(frame: CanvasFrame) {
        let snapshot = frame.snapshot
        if frame.epoch != epoch || snapshot.streamID != averagedStream || frame.sampleRate != averagedRate || frame.spatial != averagedSpatial {
            epoch = frame.epoch
            holds = Array(repeating: -120, count: Self.pointCount)
            holdTimers = Array(repeating: 0, count: Self.pointCount)
            for i in averagePower.indices { averagePower[i] = 0 }
            averageCount = 0
            averagedStream = snapshot.streamID
            averagedRate = frame.sampleRate
            averagedSpatial = frame.spatial
            // The snapshot at a configuration change may still belong to the old analysis. Wait for a new one.
            averagedSequence = snapshot.sequence
        }
        // Each new snapshot with signal joins the average once.
        guard frame.running, snapshot.sequence != averagedSequence else { return }
        averagedSequence = snapshot.sequence
        guard let loudest = snapshot.spectrumFine.max(), loudest > -100 else { return }
        for (i, db) in snapshot.spectrumFine.enumerated() { averagePower[i] += pow(10, Double(db) / 10) }
        averageCount += 1
    }

    /// Curve segments drawn between neighbouring points.
    private static let subdivisions = 2


    /// The smoothing kernels, kept while the smoothing, the point count and the sample rate stay the same.
    private var kernelCache: (SpectrumSmoothing, Int, Double, [[Float]])?
    private func smoothingKernels(_ smoothing: SpectrumSmoothing, count: Int, upper: Double) -> [[Float]] {
        if let cache = kernelCache, cache.0 == smoothing, cache.1 == count, cache.2 == upper { return cache.3 }
        let kernels = smoothing.kernels(count: count, upper: upper)
        kernelCache = (smoothing, count, upper, kernels)
        return kernels
    }

    func build(_ b: inout ShapeBuilder, frame: CanvasFrame, display: MeterSnapshot, size: CGSize, dt: Float) {
        // In the horizontal strip the spectrum has a card of its own: the same drawing on its usual axes, turned a
        // quarter so frequency runs across (`SpectrumCardLayout`).
        let scale = frame.options.frequencyScale
        let card = frame.spectrumStrip == SpectrogramLayout.split ? SpectrumCardLayout(size: size, scale: scale) : nil
        let layout = card?.canonical
            ?? SpectrogramLayout(size: size, strip: frame.spectrumStrip, spectrumLeft: frame.options.spectrumSide == .left, scale: scale)
        func t(_ p: CGPoint) -> CGPoint { card?.point(p) ?? p }
        func t(_ r: CGRect) -> CGRect { card?.rect(r) ?? r }
        let strip = layout.spectrum
        let ink = Theme.inkRGB
        b.roundedRect(t(strip), radius: 3, ink.simd(0.025))
        for db in SpectrogramLayout.grid {
            let x = (layout.x(decibels: db) * 2).rounded() / 2
            b.rect(t(CGRect(x: max(strip.minX, min(strip.maxX - 0.5, x)), y: strip.minY, width: 0.5, height: strip.height)),
                   ink.simd(Float(db == 0 ? ChartInk.reference : ChartInk.major)))
            // A fainter line halfway to the next labelled level, so a level reads to 12 dB at a glance.
            let minor = (layout.x(decibels: db - 12) * 2).rounded() / 2
            if db - 12 > MeterScale.spectrumFloor {
                b.rect(t(CGRect(x: minor, y: strip.minY, width: 0.5, height: strip.height)), ink.simd(Float(ChartInk.minor) * 0.7))
            }
        }
        // A line under each frequency label, stronger at 100 Hz, 1 kHz and 10 kHz.
        for tick in card?.frequencyTicks(sampleRate: frame.sampleRate) ?? SpectrogramLayout.frequencyTicks(layout, sampleRate: frame.sampleRate) {
            let y = (layout.y(frequency: tick.0, sampleRate: frame.sampleRate) * 2).rounded() / 2
            guard y > strip.minY + 1, y < strip.maxY - 1 else { continue }
            let decade = scale.isMajor(tick.0)
            b.rect(t(CGRect(x: strip.minX, y: y, width: strip.width, height: 0.5)), ink.simd(Float(decade ? ChartInk.major * 1.3 : ChartInk.minor)))
        }

        // The newest bands, followed at the chosen response; held while frozen, and a new stream starts from its own.
        let target = frame.snapshot.spectrumFine
        if frame.snapshot.streamID != stream {
            stream = frame.snapshot.streamID
            shown = target
            velocity = Array(repeating: 0, count: Self.pointCount)
        } else {
            let step = max(0, min(0.1, frame.signal(dt)))
            let rate = frame.options.spectrumResponse.rate
            for i in 0..<Self.pointCount { Self.damp(&shown[i], &velocity[i], target[i], step, rate: rate) }
        }
        let count = Self.pointCount
        let upper = MeterScale.upperFrequency(sampleRate: frame.sampleRate)
        // Every line is smoothed alike across frequency (`SpectrumSmoothing`), so they compare point for point.
        let kernel = smoothingKernels(frame.options.spectrumSmoothing, count: count, upper: upper)
        let live = SpectrumSmoothing.apply(kernel, to: shown)
        // The display slope at each point's centre (`SpectrumTilt`); zero when flat.
        let tilt = (0..<count).map { frame.options.tilt.offset(frequency: LogFrequencyAxis.centre($0, of: count, upper: upper)) }
        // Each point at its band's centre on the well's axis: evenly spaced on the log one the bands are analysed on.
        let centres = (0..<count).map { layout.y(frequency: LogFrequencyAxis.centre($0, of: count, upper: upper), sampleRate: frame.sampleRate) }
        func y(_ index: Int) -> CGFloat { centres[index] }
        func line(_ levels: [Float]) -> [CGPoint] {
            Self.spline((0..<count).map { CGPoint(x: layout.x(decibels: levels[$0] + tilt[$0]), y: y($0)) },
                        clampX: strip.minX...strip.maxX, subdivisions: Self.subdivisions)
        }
        curve.removeAll(keepingCapacity: true)
        curve.append(CGPoint(x: layout.x(decibels: live[0] + tilt[0]), y: strip.maxY))
        curve.append(contentsOf: line(live))
        curve.append(CGPoint(x: layout.x(decibels: live[count - 1] + tilt[count - 1]), y: strip.minY))
        // One quiet tint under the curve, fading toward the floor: the shape reads at a glance and the lines on it
        // stay legible.
        let tint = Theme.sageRGB
        for (p, q) in zip(curve, curve.dropFirst()) {
            let pb = CGPoint(x: layout.floorX, y: p.y), qb = CGPoint(x: layout.floorX, y: q.y)
            b.triangle(t(p), t(q), t(qb), tint.simd(0.14), tint.simd(0.14), tint.simd(0.02))
            b.triangle(t(p), t(qb), t(pb), tint.simd(0.14), tint.simd(0.02), tint.simd(0.02))
        }
        // The waterfall's octave lines at every C continue faintly across the spectrum (where the linear axis crowds
        // the low ones together, only those with room).
        var lastOctaveY = CGFloat.infinity
        for octave in 0...9 {
            let y = (layout.y(midi: Double(12 * (octave + 1)), sampleRate: frame.sampleRate) * 2).rounded() / 2
            guard y > strip.minY + 1, y < strip.maxY - 1, lastOctaveY - y >= 6 else { continue }
            lastOctaveY = y
            b.rect(t(CGRect(x: strip.minX, y: y, width: strip.width, height: 0.5)), ink.simd(octave == 4 ? 0.10 : 0.045))
        }
        // Peak holds: one faint line over the curve, each point held 1.2 s and then falling. Held while frozen,
        // unless they are switched off meanwhile.
        let holdDt = frame.options.peakHolds ? frame.signal(dt) : dt
        let peaks = SpectrumSmoothing.apply(kernel, to: target)
        for index in 0..<count {
            let value = frame.running && frame.options.peakHolds ? peaks[index] : -120
            if value >= holds[index] {
                holds[index] = value
                holdTimers[index] = 1.2
            } else if holdTimers[index] > 0 {
                holdTimers[index] -= holdDt
            } else {
                holds[index] = max(-120, holds[index] - 18 * holdDt)
            }
        }
        // Segments resting on the floor are not drawn: silence leaves the strip empty instead of outlining its edge.
        func onFloor(_ p: CGPoint) -> Bool { abs(p.x - layout.floorX) < 0.5 }
        if holds.contains(where: { $0 > MeterScale.spectrumFloor + 1 }) {
            let held = line(holds.indices.map { max(holds[$0], live[$0]) })
            for (p, q) in zip(held, held.dropFirst()) where !(onFloor(p) && onFloor(q)) {
                b.line(t(p), t(q), width: 1, ink.simd(0.30))
            }
        }
        // The long-term average, in the second accent: a calm solid line, so it reads apart from the live curve
        // in any palette without dashes breaking up its shape.
        if frame.options.averageSpectrum, let average {
            let points = line(SpectrumSmoothing.apply(kernel, to: average))
            for (p, q) in zip(points, points.dropFirst()) where !(onFloor(p) && onFloor(q)) {
                b.line(t(p), t(q), width: 1.25, Theme.sandRGB.simd(0.85))
            }
        }
        for (p, q) in zip(curve, curve.dropFirst()) where !(onFloor(p) && onFloor(q)) {
            b.line(t(p), t(q), width: 1.5, Theme.sageRGB.simd())
        }
    }

    /// Critically damped step toward `target` (`DampedDisplayState`'s filter) at `rate` (`SpectrumResponse`).
    private static func damp(_ position: inout Float, _ velocity: inout Float, _ target: Float, _ dt: Float, rate: Float) {
        let displacement = position - target
        let factor = exp(-rate * dt)
        let impulse = velocity + rate * displacement
        position = target + (displacement + impulse * dt) * factor
        velocity = (velocity - rate * impulse * dt) * factor
    }

    /// Exercise the actual scene's average lifecycle without creating a window or touching an audio device.
    static func checkAverageLifecycle() -> Bool {
        let scene = SpectrumScene()
        var frame = CanvasFrame(running: true)
        frame.snapshot.streamID = 1
        frame.snapshot.sequence = 1
        frame.snapshot.spectrumFine = Array(repeating: -20, count: MeterSnapshot.fineBandCount)
        scene.prepare(frame: frame)
        for sequence in 2...61 {
            frame.snapshot.sequence = Float(sequence)
            scene.prepare(frame: frame)
            scene.prepare(frame: frame) // repeated rendering must not double-count
        }
        guard scene.averageCount == 60, let average = scene.average,
              average.allSatisfy({ abs($0 + 20) < 0.0001 }) else { return false }
        frame.running = false
        frame.snapshot.sequence += 1
        scene.prepare(frame: frame)
        guard scene.averageCount == 60 else { return false }
        frame.running = true
        frame.sampleRate = 96_000
        scene.prepare(frame: frame)
        guard scene.averageCount == 0 else { return false }
        frame.snapshot.sequence += 1
        scene.prepare(frame: frame)
        guard scene.averageCount == 1 else { return false }
        frame.spatial.toggle()
        scene.prepare(frame: frame)
        guard scene.averageCount == 0 else { return false }
        frame.snapshot.sequence += 1
        scene.prepare(frame: frame)
        frame.epoch += 1
        scene.prepare(frame: frame)
        guard scene.averageCount == 0 else { return false }
        frame.snapshot.streamID = 2
        frame.snapshot.sequence = 1
        scene.prepare(frame: frame)
        frame.snapshot.spectrumFine = Array(repeating: -120, count: MeterSnapshot.fineBandCount)
        frame.snapshot.sequence += 1
        scene.prepare(frame: frame)
        guard scene.averageCount == 0 else { return false }
        print("PASS: spectrum average deduplicates frames, holds on pause, gates silence, resets on source/rate/mode/Reset")
        return true
    }

    /// Shape-preserving interpolation: smooth joins without inventing peaks between measured points.
    static func spline(_ points: [CGPoint], clampX: ClosedRange<CGFloat>, subdivisions: Int = 4) -> [CGPoint] {
        guard points.count > 1 else { return points }
        var result: [CGPoint] = []
        result.reserveCapacity(points.count * subdivisions)
        func at(_ i: Int) -> CGFloat { points[max(0, min(points.count - 1, i))].x }
        for index in 0..<(points.count - 1) {
            for sub in 0..<subdivisions {
                let t = CGFloat(sub) / CGFloat(subdivisions)
                let x = SpectrumInterpolation.value(at(index - 1), at(index), at(index + 1), at(index + 2), fraction: t)
                result.append(CGPoint(x: min(clampX.upperBound, max(clampX.lowerBound, x)),
                                      y: points[index].y + t * (points[index + 1].y - points[index].y)))
            }
        }
        result.append(points[points.count - 1])
        return result
    }
}
