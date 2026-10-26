import AnalysisCore
import AppKit
import AudioRing
import AudioToolbox
import Combine
import ImageIO
import MetalKit
import SwiftUI

/// A scroll fed in bursts and drawn at an even speed: `lag` is how many columns the drawn edge trails the newest one.
/// Each arrival adds its columns; each refresh drains them at the column rate, sped up or slowed a little by how far the
/// lag's recent average (not the lag itself, which saw-tooths with every arrival and would make the speed wobble) sits
/// from `target`, so the scroll locks onto however the columns come (an audio device's buffers, a DAW's blocks).
struct ScrollDrain {
    private(set) var lag: Float = 0
    private var average: Float = 0
    /// Seconds over which the average follows, and how much faster (or slower) the drain runs per `unit` columns the
    /// average is off target.
    private static let settle: Float = 0.4
    private static let gain: Float = 0.25

    mutating func reset() { lag = 0; average = 0 }
    mutating func arrived(_ columns: Float) { lag += columns }

    /// One refresh `dt` seconds on: drains at `rate` columns a second toward `target`; past `limit` (a stall, or the
    /// first columns after a gap) it lands on the target at once rather than racing.
    mutating func step(dt: Float, rate: Float, target: Float, unit: Float, limit: Float) {
        average += (lag - average) * (1 - Foundation.exp(-dt / Self.settle))
        let speed = max(0, rate * (1 + (average - target) / max(1, unit) * Self.gain))
        lag = max(0, lag - dt * speed)
        if lag > limit { lag = target; average = target }
    }
}

// MARK: - Spectrogram: scrolling history beside the live spectrum, on its frequency axis

/// The waterfall: `SpectrogramHistory` drawn by `waterfallFragment`, with the octave and seconds grid over it. One
/// column arrives per analysis serial (30 Hz); between them the image glides by `phase`. Paused, it holds still, and
/// the inspector (`SpectrogramInspector`) reads the very values on screen through `level(atU:row:)`.
final class SpectrogramScene: CanvasScene {
    private let texture: MTLTexture
    let history = SpectrogramHistory()
    private var previousColumn: Float = 0
    private var previousStream: Float = 0
    private var previousRate: Double = 0
    /// Columns the right edge trails the newest column (`ScrollDrain`), so columns that arrive unevenly (a DAW's large
    /// blocks, an audio device's buffers) still scroll at an even speed; and when the scroll last stepped.
    private var drain = ScrollDrain()
    private var lastStep: CFTimeInterval = 0
    /// How far the scroll has moved toward the next column, 1 − (lag − cushion), at most 1: the shader's `phase`.
    private(set) var phase: Float = 0
    private var appended = 0
    private var arrived: CFTimeInterval = 0
    /// Diagnostics (`--test-frame-pacing`), main thread only.
    nonisolated(unsafe) static var tracing = false
    nonisolated(unsafe) static var scrollTrace: [(Double, Double)] = []
    /// Slack in columns beyond the half column the drain trails on average, so columns that come late or two at once (a
    /// DAW's 2048-sample blocks are 43 ms) never stall it: 0.8 keeps every refresh's step within about 1 % of the next.
    private static let cushion: Float = 0.8
    /// Columns the waterfall spans at its current width (`SpectrogramLayout.seconds`).
    private(set) var span = SpectrogramLayout.maxSeconds * SpectrogramLayout.analysisRate
    private var options = DisplayOptions()
    private var sampleRate = 48_000.0
    /// The colour map the shader reads, rebuilt when the map, the palette or the appearance changes.
    private(set) var underlayRamp: [SIMD4<Float>] = []
    private var rampKey: (SpectrogramColors, Theme.Palette, Bool)?
    /// The 3D view's state, set by `build` while `SpectrogramView.surface` is chosen.
    private(set) var surface: SurfaceState?
    /// Depth strips of the 3D view: four rows each.
    static let surfaceStrips = SpectrogramHistory.rows / 4

    var usesDampedLevels: Bool { false }
    var underlayKind: UnderlayKind { .waterfall }
    var underlayTexture: MTLTexture? { texture }
    var underlayState: UnderlayState {
        let upper = MeterScale.upperFrequency(sampleRate: sampleRate)
        return UnderlayState(head: UInt32(history.head), rows: UInt32(SpectrogramHistory.capacity), phase: phase,
                             span: Float(span), floor: options.spectrogramRange.floor,
                             range: options.spectrogramRange.ceiling - options.spectrogramRange.floor,
                             tilt: options.tilt.decibelsPerOctave, floorOctave: Float(log2(20 / SpectrumTilt.pivot)),
                             octaves: Float(LogFrequencyAxis.octaves(upper: upper)), linear: options.frequencyScale == .linear ? 1 : 0)
    }

    init(device: MTLDevice) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: SpectrogramHistory.capacity,
                                                                  height: SpectrogramHistory.rows, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw MetalError.allocation }
        self.texture = texture
        clear()
    }

    private func clear() {
        history.reset()
        drain.reset()
        lastStep = 0
        phase = 0
        for slot in 0..<SpectrogramHistory.capacity { upload(slot) }
    }

    private func upload(_ slot: Int) {
        history.withColumn(slot) { column in
            texture.replace(region: MTLRegionMake2D(slot, 0, 1, SpectrogramHistory.rows), mipmapLevel: 0,
                            withBytes: column.baseAddress!, bytesPerRow: MemoryLayout<Float>.stride)
        }
    }

    func prepare(frame: CanvasFrame) {
        let snapshot = frame.snapshot
        options = frame.options
        sampleRate = frame.sampleRate
        if rampKey.map({ $0 != (options.spectrogramColors, Theme.palette, Theme.dark) }) ?? true {
            underlayRamp = Theme.waterfallRamp(options.spectrogramColors)
            rampKey = (options.spectrogramColors, Theme.palette, Theme.dark)
        }
        let streamChanged = snapshot.streamID > 0 && snapshot.streamID != previousStream
        if streamChanged || (previousRate > 0 && frame.sampleRate != previousRate) { clear() }
        // One column per analysis serial (30 Hz), however often snapshots arrive.
        if frame.running && snapshot.spectrogramSerial > 0 && (streamChanged || snapshot.spectrogramSerial != previousColumn) {
            upload(history.append(snapshot.spectrogram))
            drain.arrived(1)
            if Self.tracing { appended += 1; arrived = CanvasDriver.now }
        }
        // Held while paused; otherwise drained at the column rate, a little faster when behind, slower when short.
        let now = CanvasDriver.now
        if frame.running && lastStep > 0 {
            drain.step(dt: Float(max(0, min(0.1, now - lastStep))), rate: Float(SpectrogramLayout.analysisRate),
                       target: 0.5 + Self.cushion, unit: 1, limit: 6)
            phase = min(1, 1 + Self.cushion - drain.lag)
        }
        lastStep = frame.running ? now : 0
        if Self.tracing && frame.running && arrived > 0 {
            // Diagnostics: where the scroll stands (columns), and where build 99's (the time since the newest column,
            // held at a whole column) would.
            Self.scrollTrace.append((Double(appended) - Double(drain.lag), Double(appended) - 1 + min(1, (now - arrived) * SpectrogramLayout.analysisRate)))
        }
        if snapshot.streamID > 0 { previousStream = snapshot.streamID }
        previousColumn = snapshot.spectrogramSerial
        previousRate = frame.sampleRate
    }

    /// The level drawn at `u` across the waterfall (0 its oldest edge, 1 "now") and fractional `row`, and how many
    /// seconds before the newest column that is; nil where nothing has been written.
    func level(atU u: Double, row: Double) -> (level: Float, secondsAgo: Double)? {
        let age = (1 - u) * span - Double(phase)
        guard let level = history.level(age: max(0, age), row: row) else { return nil }
        return (level, (max(0, age).rounded() + Double(phase)) / SpectrogramLayout.analysisRate)
    }

    func build(_ b: inout ShapeBuilder, frame: CanvasFrame, display: MeterSnapshot, size: CGSize, dt: Float) {
        let layout = SpectrogramLayout(size: size, strip: frame.spectrumStrip, spectrumLeft: frame.options.spectrumSide == .left,
                                       span: frame.options.spectrogramSpan.seconds, scale: frame.options.frequencyScale)
        let plot = layout.plot
        span = Double(layout.visibleColumns)
        let ink = Theme.inkRGB
        guard frame.options.spectrogramView == .flat else {
            buildSurface(&b, layout: layout, size: size, sampleRate: frame.sampleRate)
            return
        }
        surface = nil
        b.underlayQuad(plot, mirrored: layout.mirrored)
        // Octave lines at every C, continuing the keyboard's C keys across the plot; middle C a little firmer. The
        // linear axis crowds the low ones together: only those with room are drawn.
        var lastOctaveY = CGFloat.infinity
        for octave in 0...9 {
            let y = (layout.y(midi: Double(12 * (octave + 1)), sampleRate: frame.sampleRate) * 2).rounded() / 2
            guard y > plot.minY + 1, y < plot.maxY - 1, lastOctaveY - y >= 6 else { continue }
            lastOctaveY = y
            b.rect(CGRect(x: plot.minX, y: y, width: plot.width, height: 0.5), ink.simd(Float(octave == 4 ? ChartInk.major * 1.3 : ChartInk.minor)))
        }
        // A hairline each second, and a short tick at the foot of each so the time labels have something to name.
        for seconds in stride(from: 1.0, to: layout.seconds, by: 1) {
            let x = (layout.x(secondsAgo: seconds) * 2).rounded() / 2
            b.rect(CGRect(x: x, y: plot.minY, width: 0.5, height: plot.height), ink.simd(Float(ChartInk.minor)))
            b.rect(CGRect(x: x, y: plot.maxY - 4, width: 0.5, height: 4), ink.simd(Float(ChartInk.tick)))
        }
    }

    /// The 3D view: a floor grid (its outline, a line along each decade of frequency and across at each second) under
    /// the surface the shader draws from the same history.
    private func buildSurface(_ b: inout ShapeBuilder, layout: SpectrogramLayout, size: CGSize, sampleRate: Double) {
        let plot = layout.plot
        let projection = SurfaceProjection(plot: plot)
        let ink = Theme.inkRGB
        let upper = MeterScale.upperFrequency(sampleRate: sampleRate)
        func u(_ t: Double) -> Double { layout.mirrored ? 1 - t : t }
        func floorLine(_ from: (u: Double, d: Double), _ to: (u: Double, d: Double), _ alpha: Float) {
            b.line(projection.point(u: from.u, d: from.d), projection.point(u: to.u, d: to.d), width: 1, ink.simd(alpha))
        }
        floorLine((0, 0), (1, 0), 0.16)
        floorLine((0, 1), (1, 1), 0.08)
        floorLine((0, 0), (0, 1), 0.10)
        floorLine((1, 0), (1, 1), 0.10)
        for frequency in SurfaceProjection.marks(layout.scale).map(\.0) where frequency < upper {
            let d = SurfaceProjection.depth(frequency: frequency, upper: upper, scale: layout.scale)
            floorLine((0, d), (1, d), 0.10)
        }
        for seconds in stride(from: 1.0, to: layout.seconds, by: 1) {
            let t = 1 - seconds / layout.seconds
            floorLine((u(t), 0), (u(t), 1), 0.05)
        }
        let flat = underlayState
        surface = SurfaceState(head: flat.head, capacity: flat.rows, phase: flat.phase, span: flat.span,
                               floor: flat.floor, range: flat.range, tilt: flat.tilt, floorOctave: flat.floorOctave,
                               octaves: flat.octaves, left: Float(plot.minX), bottom: Float(plot.maxY),
                               width: Float(plot.width), height: Float(plot.height),
                               viewportWidth: Float(max(1, size.width)), viewportHeight: Float(max(1, size.height)),
                               columns: UInt32(max(1, layout.visibleColumns)), strips: UInt32(Self.surfaceStrips),
                               mirrored: layout.mirrored ? 1 : 0, linear: flat.linear)
    }
}
