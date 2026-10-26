import AnalysisCore
import AppKit
import AudioRing
import AudioToolbox
import Combine
import ImageIO
import MetalKit
import SwiftUI

// MARK: - Waveform: one phosphor lane per channel, drawn from the min/max pyramid

final class WaveformScene: CanvasScene {
    /// 4096 envelope columns (~17 s at 240 columns/s) per pyramid level 0; the lanes show the chosen span (2, 4 or
    /// 8 s, `DisplayOptions.waveSeconds`) with room to spare for the scroll lag and the coarsest buckets.
    static let traceCapacity = 4096
    private var visibleColumns: Float = 960
    static let pairs = Role.count / 2

    private let trace: MTLTexture
    private var pyramid = MinMaxPyramid(capacity: traceCapacity, pairs: pairs)
    private var lastSerial = -1
    private var lastStream: Float = 0
    /// Columns the right edge trails the newest column (`ScrollDrain`), for a smooth scroll.
    private var drain = ScrollDrain()
    private var lag: Float { drain.lag }
    /// Recent arrival size in columns: about 4 per 60 Hz DSP tick, 8 per 30 Hz demo update, more when a DAW
    /// runs the device with long buffers. Jumps up at once and relaxes slowly.
    private var burst: Float = 8
    /// The right edge trails the newest column by 1.5 arrivals: enough that the scroll never runs dry, and no
    /// more, so the waveform is as current as its delivery allows (about 30 ms behind at 60 Hz, was 50 ms).
    private var cushion: Float { min(40, max(6, burst * 1.5)) }
    private var presence = PresenceSpring()
    private var mono = PresenceSpring()
    private var scale = WaveScale.linear

    var usesDampedLevels: Bool { false }
    var underlayKind: UnderlayKind { .waveform }
    var underlayTexture: MTLTexture? { trace }
    var underlayState: UnderlayState {
        UnderlayState(head: pyramid.newestIndex, rows: UInt32(Self.traceCapacity), phase: lag, span: visibleColumns,
                      floor: 0, range: scale.shaderRange)
    }

    init(device: MTLDevice) throws {
        // Row (level × pairs + pair) holds one pyramid level of one channel pair; coarser levels use only
        // their first texels.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: Self.traceCapacity,
                                                                  height: MinMaxPyramid.levels * Self.pairs, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let trace = device.makeTexture(descriptor: descriptor) else { throw MetalError.allocation }
        self.trace = trace
        clearTrace()
    }

    private func clearTrace() {
        pyramid.reset()
        uploadDirtyTrace()
        lastSerial = -1
        drain.reset()
    }

    /// Copies only the texels the pyramid changed since the last upload: one region per level covering
    /// every channel pair, a few texels wide.
    private func uploadDirtyTrace() {
        let stride = MemoryLayout<SIMD4<Float>>.stride
        pyramid.forEachDirtySpan { level, slot, count, texels in
            trace.replace(region: MTLRegionMake2D(slot, level * Self.pairs, count, Self.pairs), mipmapLevel: 0,
                          withBytes: texels.baseAddress! + pyramid.offset(level: level) + slot,
                          bytesPerRow: pyramid.slots(level: level) * stride)
        }
        pyramid.markClean()
    }

    /// The sample peak of `role` (linear, 1 = full scale; above 1 an over) over the history `window` seconds wide
    /// centred `secondsAgo` before the lanes' right edge, read from the same columns the lanes draw. nil where the
    /// history holds nothing yet.
    func peak(role: Int, secondsAgo: Double, window: Double) -> Float? {
        guard pyramid.count > 0, (0..<Role.count).contains(role) else { return nil }
        let rate = WaveformEnvelope.columnRate
        let centre = secondsAgo * rate + Double(lag)
        let half = max(0.5, window * rate / 2)
        let newest = max(0, Int((centre - half).rounded(.down)))
        let oldest = Int((centre + half).rounded(.up))
        guard oldest < pyramid.count, newest <= oldest else { return nil }
        let e = pyramid.extrema(newestAge: newest, oldestAge: oldest, level: 0, pair: role / 2)
        let low = role % 2 == 0 ? e.x : e.z, high = role % 2 == 0 ? e.y : e.w
        guard low.isFinite, high.isFinite else { return nil }
        return max(abs(low), abs(high))
    }

    /// Linear amplitude, so transients read as they do in a DAW; full scale and beyond is flagged past 1.
    static func deflection(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return abs(value) >= 1 ? (value < 0 ? -1.02 : 1.02) : value
    }

    func prepare(frame: CanvasFrame) {
        let snapshot = frame.snapshot
        if snapshot.streamID > 0 && snapshot.streamID != lastStream {
            lastStream = snapshot.streamID
            clearTrace()
        }
        guard frame.running, snapshot.sequence > 0 else { return }
        let serial = Int(snapshot.waveSerial)
        let count = lastSerial < 0 ? WaveformEnvelope.publishedColumns
            : WaveformEnvelope.newColumns(since: lastSerial, latest: serial)
        guard count > 0 else { return }
        snapshot.waveform.withUnsafeBufferPointer { w in
            for column in (WaveformEnvelope.publishedColumns - count)..<WaveformEnvelope.publishedColumns {
                let base = column * WaveformEnvelope.valuesPerColumn
                pyramid.append { pair in
                    let i = base + pair * 4
                    return SIMD4(Self.deflection(w[i]), Self.deflection(w[i + 1]), Self.deflection(w[i + 2]), Self.deflection(w[i + 3]))
                }
            }
        }
        uploadDirtyTrace()
        drain.arrived(Float(count))
        if lastSerial >= 0 { burst = max(Float(count), burst + (Float(count) - burst) * 0.05) }
        lastSerial = serial
    }

    /// Lanes are rebuilt from the current size and presence every frame, and the shader picks its pyramid
    /// level from the pixel footprint, so any panel size renders at native resolution without resampling.
    func build(_ b: inout ShapeBuilder, frame: CanvasFrame, display: MeterSnapshot, size: CGSize, dt: Float) {
        if frame.running {
            // Drained at the column rate, locked onto the arrivals, so bursts scroll evenly at any refresh rate.
            drain.step(dt: dt, rate: Float(WaveformEnvelope.columnRate), target: cushion, unit: burst, limit: 80)
        }
        visibleColumns = Float(Double(frame.options.waveSeconds) * WaveformEnvelope.columnRate)
        scale = frame.options.waveScale
        presence.step(target: frame.spatial ? 1 : 0, dt: dt)
        mono.step(target: frame.mono ? 1 : 0, dt: dt)
        let layout = WaveformLayout(size: size, speakers: frame.layout.speakers, presence: CGFloat(presence.value),
                                    mono: CGFloat(mono.value))
        for (index, speaker) in layout.speakers.enumerated() {
            let lane = layout.lanes[index]
            let weight = Float(layout.weight(index))
            guard lane.height > 0.5, weight > 0.002 else { continue }
            let active = frame.activeRoles[speaker.role]
            b.laneQuad(lane, role: speaker.role, color: Theme.laneRGB(speaker).simd(weight * weight * (active ? 1 : 0.35)))
        }
    }
}
