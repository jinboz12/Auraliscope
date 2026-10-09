import AnalysisCore
import Foundation

/// The waterfall's memory on the display side: the newest `capacity` columns exactly as analysed, in dBFS. Nothing
/// is quantised or pre-coloured here, so the range, the tilt and the palette can change while the history stays.
/// The GPU reads the same values as a 32-bit float texture (texel x = column slot, y = row, low frequencies first),
/// and the inspector reads them here.
///
/// Columns are stored column-major, each `rows` floats, so a new one is a single contiguous upload.
final class SpectrogramHistory {
    /// 512 columns: 17 s at 30 columns per second, twice the longest span the waterfall shows.
    static let capacity = 512
    static let rows = MeterSnapshot.spectrogramBandCount
    /// The level of a column that holds nothing (before the first one, after a reset).
    static let silence: Float = -120

    /// Slot the next column goes to; the newest is the one before it.
    private(set) var head = 0
    /// Columns written since the last reset, at most `capacity`.
    private(set) var count = 0
    private(set) var levels: [Float]

    init() {
        levels = [Float](repeating: Self.silence, count: Self.capacity * Self.rows)
    }

    /// Stores `column` (`rows` levels, missing or non-finite ones read as silence) and returns its slot.
    @discardableResult
    func append(_ column: [Float]) -> Int {
        let slot = head
        let base = slot * Self.rows
        for row in 0..<Self.rows {
            let value = row < column.count ? column[row] : Self.silence
            levels[base + row] = value.isFinite ? max(Self.silence, min(24, value)) : Self.silence
        }
        head = (slot + 1) % Self.capacity
        count = min(Self.capacity, count + 1)
        return slot
    }

    /// The levels of one slot, for its upload.
    func withColumn<R>(_ slot: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R {
        levels.withUnsafeBufferPointer { body(UnsafeBufferPointer(rebasing: $0[(slot * Self.rows)..<((slot + 1) * Self.rows)])) }
    }

    /// The level of the cell drawn at `age` columns before the newest (0 the newest) and `row`: the column and row
    /// whose boxes contain them (each centred on its index), exactly as analysed and as the waterfall draws it; nil
    /// where nothing has been written.
    func level(age: Double, row: Double) -> Float? {
        guard count > 0, age.isFinite, row.isFinite, age >= 0, age < Double(count) - 0.5 else { return nil }
        let column = Int(age.rounded())
        let r = max(0, min(Self.rows - 1, Int(row.rounded())))
        return levels[((head - 1 - column + 2 * Self.capacity) % Self.capacity) * Self.rows + r]
    }

    func reset() {
        head = 0
        count = 0
        levels.withUnsafeMutableBufferPointer { $0.update(repeating: Self.silence) }
    }
}
