import Foundation

/// Multi-level (mipmap-style) min/max cache over a ring of L/R envelope columns.
///
/// Level 0 holds one texel per envelope column (1:1); level k holds the extrema of 4^k consecutive
/// columns (1:4, 1:16, 1:64). Each append touches exactly one texel per level, so the cache is maintained
/// in O(levels) per column and nothing is ever re-scanned per frame. The renderer mirrors `texels` into a
/// `capacity × levels` texture (row k = level k) and uploads only the dirty spans.
///
/// Buckets are aligned to absolute column indices (`index >> 2k`), and `capacity` is a power of two, so
/// ring slots stay consistent when the 32-bit column counter wraps. The newest bucket of each level is
/// partial and is rewritten as columns arrive, so the leading edge is always current at every level.
///
/// Texels are (min, max, min, max) of a pair of channels; `pairs` channel pairs share every bucket boundary,
/// so one append writes the same slot in every pair. Storage is level-major, then pair, then slot, which lets
/// the renderer upload a level's dirty span for all pairs as one region (`slots(level:)` texels per row).
struct MinMaxPyramid {
    static let levels = 4
    static let levelShift = 2  // factor 4 per level
    static let coarsestSpan = 1 << (levelShift * (levels - 1))

    let capacity: Int
    let pairs: Int
    /// All levels back to back: level k starts at `offset(k)` and holds `pairs` rows of `capacity >> 2k` texels.
    private(set) var texels: [SIMD4<Float>]
    /// Absolute index the next column will get; wraps at 2^32 without breaking bucket alignment.
    private(set) var nextIndex: UInt32 = 0
    private(set) var count = 0
    private var dirtyStart = [Int](repeating: 0, count: levels)
    private var dirtyCount = [Int](repeating: 0, count: levels)

    /// `firstIndex` must be a multiple of `coarsestSpan`; tests use it to exercise the 32-bit wrap.
    init(capacity: Int, pairs: Int = 1, firstIndex: UInt32 = 0) {
        precondition(capacity >= Self.coarsestSpan && capacity & (capacity - 1) == 0, "capacity must be a power of two ≥ 64")
        precondition(Int(firstIndex) % Self.coarsestSpan == 0, "firstIndex must align to the coarsest bucket")
        precondition(pairs >= 1)
        self.capacity = capacity
        self.pairs = pairs
        nextIndex = firstIndex
        texels = [SIMD4<Float>](repeating: .zero,
                                count: pairs * (0..<Self.levels).reduce(0) { $0 + (capacity >> (Self.levelShift * $1)) })
    }

    static func merge(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4(min(a.x, b.x), max(a.y, b.y), min(a.z, b.z), max(a.w, b.w))
    }

    func slots(level: Int) -> Int { capacity >> (Self.levelShift * level) }

    /// First texel of a level's first pair; pair p's row starts `p * slots(level:)` further on.
    func offset(level: Int, pair: Int = 0) -> Int { (0..<level).reduce(0) { $0 + slots(level: $1) * pairs } + pair * slots(level: level) }

    /// Newest column's absolute index; only meaningful once `count > 0`.
    var newestIndex: UInt32 { nextIndex &- 1 }

    mutating func reset() {
        for i in texels.indices { texels[i] = .zero }
        nextIndex = 0
        count = 0
        for level in 0..<Self.levels { dirtyStart[level] = 0; dirtyCount[level] = slots(level: level) }
    }

    mutating func append(_ column: SIMD4<Float>) { append { _ in column } }

    /// Appends one column to every pair; `column(p)` is pair p's (min, max, min, max).
    mutating func append(_ column: (Int) -> SIMD4<Float>) {
        let index = nextIndex
        for level in 0..<Self.levels {
            let shift = UInt32(Self.levelShift * level)
            let size = slots(level: level)
            let slot = Int((index >> shift) & UInt32(size - 1))
            // First column of a bucket replaces whatever the ring slot held a lap ago.
            let startsBucket = index & ((1 << shift) - 1) == 0
            var position = offset(level: level) + slot
            for pair in 0..<pairs {
                let value = column(pair)
                texels[position] = startsBucket ? value : Self.merge(texels[position], value)
                position += size
            }
            markDirty(level: level, slot: slot)
        }
        nextIndex = index &+ 1
        count = min(capacity, count + 1)
    }

    /// Slots appended since the last drain are contiguous in ring order; extend the span to cover `slot`.
    private mutating func markDirty(level: Int, slot: Int) {
        let size = slots(level: level)
        if dirtyCount[level] == 0 {
            dirtyStart[level] = slot
            dirtyCount[level] = 1
            return
        }
        let distance = (slot - dirtyStart[level] + size) % size
        if distance >= dirtyCount[level] { dirtyCount[level] = min(size, distance + 1) }
    }

    /// Visits every span changed since `markClean()`, as (level, first slot, slot count, all texels), split
    /// where the ring wraps. The same slots changed in every pair: texel `offset(level:pair:) + slot` is the
    /// first one to upload for pair p.
    func forEachDirtySpan(_ body: (_ level: Int, _ slot: Int, _ count: Int, _ texels: UnsafeBufferPointer<SIMD4<Float>>) -> Void) {
        texels.withUnsafeBufferPointer { buffer in
            for level in 0..<Self.levels where dirtyCount[level] > 0 {
                let first = min(dirtyCount[level], slots(level: level) - dirtyStart[level])
                body(level, dirtyStart[level], first, buffer)
                if first < dirtyCount[level] { body(level, 0, dirtyCount[level] - first, buffer) }
            }
        }
    }

    mutating func markClean() {
        for level in 0..<Self.levels { dirtyCount[level] = 0 }
    }

    /// Level to read for a footprint of `columnsPerPixel`: the coarsest whose buckets are no wider than a
    /// pixel, i.e. floor(log4(columns per pixel)), clamped. Mirrors `scopeLevel` in the Metal shader.
    static func level(columnsPerPixel: Float) -> Int {
        guard columnsPerPixel > 1 else { return 0 }
        return min(levels - 1, Int(log2(columnsPerPixel) / Float(levelShift)))
    }

    /// Extrema of the columns `newestAge ... oldestAge` before the newest, read at `level` over whole
    /// buckets (so the result may include a few neighbouring columns, never fewer). Mirrors the shader.
    func extrema(newestAge: Int, oldestAge: Int, level: Int, pair: Int = 0) -> SIMD4<Float> {
        let shift = UInt32(Self.levelShift * level)
        let first = (newestIndex &- UInt32(oldestAge)) >> shift
        let last = (newestIndex &- UInt32(newestAge)) >> shift
        let mask = UInt32(slots(level: level) - 1)
        var result = SIMD4<Float>(.infinity, -.infinity, .infinity, -.infinity)
        var bucket = first
        for _ in 0...Int(last &- first) {
            result = Self.merge(result, texels[offset(level: level, pair: pair) + Int(bucket & mask)])
            bucket &+= 1
        }
        return result
    }
}
