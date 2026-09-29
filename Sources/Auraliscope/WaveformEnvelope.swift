import Accelerate
import AudioRing
import Foundation

/// Min/max envelope of every speaker role at a fixed 240 columns per second, owned by the DSP queue.
///
/// Each snapshot carries a running column serial plus the newest 64 columns (~270 ms), so the display can
/// append exactly what it has not seen even when it misses several 60 Hz snapshots in a row. A column holds
/// (min, max) per role in role order, so roles 2p and 2p+1 form one (min, max, min, max) texel for the
/// display's min/max pyramid. Roles that are not routed stay at zero and cost nothing.
final class WaveformEnvelope {
    static let columnRate = 240.0
    static let publishedColumns = 64
    static let valuesPerColumn = Role.count * 2
    static let publishedFloats = publishedColumns * valuesPerColumn
    /// Serials wrap here so they stay exact as Float (< 2^24).
    static let serialModulus = 1_000_000

    let framesPerColumn: Int
    private let activeRoles: [Int]
    private(set) var serial = 0
    private var filled = 0
    private var column = [Float](repeating: 0, count: valuesPerColumn)
    private var recent = [Float](repeating: 0, count: publishedFloats)
    private var head = 0

    init(sampleRate: Double, activeRoles: [Bool] = [Bool](repeating: true, count: Role.count)) {
        framesPerColumn = max(1, Int((sampleRate / Self.columnRate).rounded()))
        self.activeRoles = (0..<Role.count).filter { $0 < activeRoles.count && activeRoles[$0] }
    }

    func consume(_ frames: UnsafeBufferPointer<ChannelFrame>) {
        guard let base = frames.baseAddress, !frames.isEmpty else { return }
        base.withMemoryRebound(to: Float.self, capacity: frames.count * Role.count) { samples in
            consume(count: frames.count, stride: Role.count) { samples + $0 }
        }
    }

    /// Already de-interleaved audio (see `MeterPipeline`): contiguous channels.
    func consume(_ block: PlanarBlock) {
        consume(count: block.count, stride: 1) { block.channel($0) }
    }

    /// `channel(role)` is the role's first sample; its samples lie `stride` floats apart.
    private func consume(count total: Int, stride: Int, channel: (Int) -> UnsafePointer<Float>) {
        guard total > 0 else { return }
        var offset = 0
        while offset < total {
            let count = min(framesPerColumn - filled, total - offset)
            for role in activeRoles {
                let first = channel(role) + offset * stride
                var low: Float = 0, high: Float = 0
                vDSP_minv(first, stride, &low, vDSP_Length(count))
                vDSP_maxv(first, stride, &high, vDSP_Length(count))
                if filled == 0 {
                    column[role * 2] = low
                    column[role * 2 + 1] = high
                } else {
                    column[role * 2] = min(column[role * 2], low)
                    column[role * 2 + 1] = max(column[role * 2 + 1], high)
                }
            }
            filled += count
            offset += count
            if filled == framesPerColumn { emit() }
        }
    }

    /// Columns of the notch that marks a break (see `interrupt`): at least 50 ms, and no more than one snapshot
    /// carries alongside fresh audio.
    static let notchColumns = 12...48

    /// A break in the audio: the column in progress closes, and a flat notch stands for the time known missing
    /// (`missingFrames`, within `notchColumns`), so the history shows where one stretch of audio ends and the next
    /// begins. The notch marks the break; it is not measured silence.
    func interrupt(missingFrames: Int) {
        if filled > 0 { emit() }
        for i in column.indices { column[i] = 0 }
        let columns = min(Self.notchColumns.upperBound, max(Self.notchColumns.lowerBound, missingFrames / framesPerColumn))
        for _ in 0..<columns { emit() }
    }

    /// Newest columns oldest-first, each `valuesPerColumn` floats of (min, max) per role.
    func write(into destination: UnsafeMutablePointer<Float>) {
        let tail = Self.publishedFloats - head
        recent.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            destination.update(from: base + head, count: tail)
            (destination + tail).update(from: base, count: head)
        }
    }

    private func emit() {
        recent.withUnsafeMutableBufferPointer { buffer in
            column.withUnsafeBufferPointer { (buffer.baseAddress! + head).update(from: $0.baseAddress!, count: Self.valuesPerColumn) }
        }
        head = (head + Self.valuesPerColumn) % Self.publishedFloats
        serial = (serial + 1) % Self.serialModulus
        filled = 0
    }

    /// Columns published after `previous`, given the latest serial; capped at what one snapshot holds.
    static func newColumns(since previous: Int, latest: Int) -> Int {
        let delta = (latest - previous + serialModulus) % serialModulus
        return min(delta, publishedColumns)
    }
}
