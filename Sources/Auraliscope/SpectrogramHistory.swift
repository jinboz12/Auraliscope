import AnalysisCore
import Foundation

// A fixed 512 × 512 image. The GPU receives only the newest 512-byte column per analysis tick.
final class SpectrogramHistory {
    static let width = 512
    static let height = MeterSnapshot.spectrogramBandCount
    private(set) var writeIndex = 0
    private(set) var columnsWritten = 0
    private(set) var column = [UInt8](repeating: 0, count: height)

    static func intensity(_ decibels: Float) -> UInt8 {
        let normalized = max(0, min(1, (decibels + 120) / 120))
        return UInt8((normalized * 255).rounded())
    }

    @discardableResult
    func append(_ bands: [Float]) -> Int {
        precondition(bands.count == Self.height)
        let index = writeIndex
        for row in 0..<Self.height { column[row] = Self.intensity(bands[row]) }
        writeIndex = (index + 1) % Self.width
        columnsWritten = min(Self.width, columnsWritten + 1)
        return index
    }

    func reset() {
        writeIndex = 0
        columnsWritten = 0
        for index in column.indices { column[index] = 0 }
    }
}
