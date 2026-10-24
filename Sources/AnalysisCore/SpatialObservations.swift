import Foundation

/// Radiant's input from build 98: the newest Spatial transform's frequencies, each placed as a spatial analyser places a
/// frequency, at the centre of gravity of the speakers weighted by its amplitude in each,
///
///     p(k) = Σᵢ |Xᵢ(k)| sᵢ / Σᵢ |Xᵢ(k)|,
///
/// sᵢ the speaker's unit direction (`SpatialMapping.directions`) or its position in meters (`.positions`), the LFE and
/// speakers left out of the picture taking no part. It describes how the feeds distribute each frequency's amplitude
/// between the speakers; for one signal panned with non-negative gains it is the gain-weighted centre of the speakers,
/// for anything else (delays, polarity, several sources, reverberation) it is that description and nothing more: not a
/// source position, not a localisation model, not a source separation.
///
/// One weighted reduction (`SpatialObservationBuilder`) turns a frame's bins into at most `detail` × `bandCount`
/// observations, without random sampling, and is the only reduction between the transform and the display:
/// 1. neighbouring bins of a band that sit at the same place (within 1/1000 of the layout's radius: a panned source, a
///    mono one) become one observation, exactly;
/// 2. a band whose places outnumber its budget keeps every place that carries at least one budget's share of its
///    energy as it is, and gathers the rest on a grid that coarsens until the band fits, so separate places stay
///    apart as long as the budget allows, and only the weakest energy moves, by a recorded distance;
/// 3. budgets go where the detail is: bands that need fewer observations than their share leave the rest to bands
///    that need more (the treble's wide bands).
/// Every observation keeps its energy (the bins' energies add up exactly), its energy-weighted position (so every
/// band's centre of gravity is the bins'), its energy-weighted frequency and the range of its bins, the spread of its
/// bins around it (their energy-weighted RMS distance, which the display draws as the particle's width), and the
/// time of its transform (`zone`).
///
/// Layout (floats, `SnapshotSlots.spatialObservations`): a header of `headerFloats`, the number of observations of
/// each band (`counts`), then the observations, band by band, `fields` floats each: x y z, energy (mean square),
/// frequency, lowest and highest bin frequency (Hz), spread (the mapping's units) and zone.
package enum SpatialObservations {
    package static let version: Float = 1
    package static let headerFloats = 28
    package static let fields = 9
    /// The most observations a frame holds (`SpatialGeometry.detailRange.upperBound` per band on average).
    package static let capacity = SpatialGeometry.detailRange.upperBound * SpatialField.bandCount
    /// The most one band may take of the frame's budget.
    package static let perBandLimit = 96
    package static let counts = headerFloats
    package static let first = headerFloats + SpatialField.bandCount
    package static let floats = first + capacity * fields

    /// Header fields.
    package enum Header {
        /// 1 while the observations describe the newest audio (a frame of measured silence has none), 0 none.
        package static let status = 0, version = 1, mapping = 2, source = 3
        /// The geometry's revision and hash, in 16-bit parts (low first; exact in a Float).
        package static let revision = 4, hash = 6
        /// Frames the analysis had taken when the newest transform's window ended, in 24-bit parts (low first).
        package static let windowEnd = 10
        package static let sampleRate = 13
        /// The longest zone's window, in samples.
        package static let windowLength = 14
        /// Frames observed since the analysis started (mod 2²⁴).
        package static let serial = 15
        package static let count = 16
        /// Bins placed, their total energy, and the largest and the energy-weighted mean distance any bin's energy was
        /// moved by the reduction (the mapping's units).
        package static let bins = 17, energy = 18, largestMove = 19, meanMove = 20
        package static let detail = 21
        /// Zones (1, or 3 for the multi-resolution window) and the window of zones 1…3, in samples.
        package static let zones = 22, zoneWindow = 23
        /// Energy of the bins left out as below the float transform's precision (`SpatialObservationBuilder.precision`).
        package static let belowPrecision = 26
    }

    /// Where the observations come from.
    package enum Source: Float {
        case none = 0
        /// The analysis, with the geometry whose hash the header carries.
        case measured = 1
        /// A Bridge plugin before build 98 (RESULT tag 54): bins placed with the standard layout's directions, at most
        /// 32 per band, without frequencies or spreads.
        case legacy = 2
    }

    package static func observation(_ index: Int) -> Int { first + index * fields }

    /// Writes a 64-bit value as four exact 16-bit parts, and reads it back.
    package static func store(_ value: UInt64, parts: Int, at offset: UnsafeMutablePointer<Float>, bits: Int = 16) {
        let mask = (UInt64(1) << UInt64(bits)) - 1
        for i in 0..<parts { offset[i] = Float((value >> UInt64(bits * i)) & mask) }
    }
    package static func load(_ offset: UnsafePointer<Float>, parts: Int, bits: Int = 16) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<parts { value |= UInt64(max(0, offset[i])) << UInt64(bits * i) }
        return value
    }
    package static func hash(_ v: UnsafePointer<Float>) -> UInt64 { load(v + Header.hash, parts: 4) }
    package static func revision(_ v: UnsafePointer<Float>) -> UInt32 { UInt32(truncatingIfNeeded: load(v + Header.revision, parts: 2)) }
    package static func windowEnd(_ v: UnsafePointer<Float>) -> UInt64 { load(v + Header.windowEnd, parts: 3, bits: 24) }

    /// The window (samples) of `zone` as the header gives it.
    package static func window(_ v: UnsafePointer<Float>, zone: Int) -> Float {
        zone <= 0 ? v[Header.windowLength] : v[Header.zoneWindow + min(2, zone - 1)]
    }

    /// Converts a Bridge plugin's bins (RESULT tag 54, `SpatialPoints` layout, the standard layout's directions) into
    /// observations of `Source.legacy`: no frequencies of their own (each takes its band's centre), no spread.
    package static func fromLegacy(points: UnsafePointer<Float>, into v: UnsafeMutablePointer<Float>) {
        v.update(repeating: 0, count: first)
        guard points[SpatialPoints.status] == 1 else { return }
        var index = 0
        var energy: Float = 0
        for band in 0..<SpatialField.bandCount {
            let stored = points[SpatialPoints.count(band: band)]
            let n = stored.isFinite ? max(0, min(SpatialPoints.perBand, Int(stored))) : 0
            var made = 0
            for i in 0..<n where index < capacity {
                let p = points + SpatialPoints.point(band: band, index: i)
                guard p[0].isFinite, p[1].isFinite, p[2].isFinite, p[3].isFinite, p[3] > 0 else { continue }
                let o = v + observation(index)
                o[0] = p[0]; o[1] = p[1]; o[2] = p[2]; o[3] = p[3]
                let hz = Float(SpatialField.centre(band))
                o[4] = hz; o[5] = Float(SpatialField.edge(band)); o[6] = Float(SpatialField.edge(band + 1)); o[7] = 0; o[8] = 0
                energy += p[3]
                index += 1
                made += 1
            }
            v[counts + band] = Float(made)
        }
        v[Header.status] = 1
        v[Header.version] = version
        v[Header.mapping] = Float(SpatialMapping.directions.rawValue)
        v[Header.source] = Source.legacy.rawValue
        v[Header.count] = Float(index)
        v[Header.bins] = Float(index)
        v[Header.energy] = energy
        v[Header.zones] = 1
    }
}

/// The one reduction from a frame's bins to its observations (`SpatialObservations`). Owned by the analysis thread;
/// allocates only when created.
package final class SpatialObservationBuilder {
    /// Bins closer than this share of the layout's radius, next to each other in frequency, are one place.
    package static let sameplace: Float = 1e-3
    /// The finest cell of the grid that gathers a band's weaker places, as a share of the layout's radius (doubled
    /// until the band fits its budget).
    package static let finestCell: Float = 0.01
    /// Places of bins more than 140 dB under the frame's strongest are the float transform's rounding (its precision is
    /// about 7 decimal digits of the strongest component, which leaks into every other bin of its transform): such
    /// bins are left out, and their energy is recorded in the header, never passed off as silence.
    package static let precision: Float = 1e-14

    private let capacity: Int
    // Runs: neighbouring bins of one band at one place. Structure of arrays, `capacity` each.
    private let runBand: UnsafeMutablePointer<Int32>
    private let runX: UnsafeMutablePointer<Float>, runY: UnsafeMutablePointer<Float>, runZ: UnsafeMutablePointer<Float>
    private let runEnergy: UnsafeMutablePointer<Float>
    private let runFrequency: UnsafeMutablePointer<Float>    // Σ e·f
    private let runLow: UnsafeMutablePointer<Float>, runHigh: UnsafeMutablePointer<Float>
    private let runScatter: UnsafeMutablePointer<Float>      // Σ e·|p − P|² (weighted Welford)
    private let runZone: UnsafeMutablePointer<Int32>
    /// Per run: its observation's index in the band's output (or the cell it went into), and whether it is kept as is.
    private let runCell: UnsafeMutablePointer<Int32>
    private let runStrong: UnsafeMutablePointer<Bool>
    private var runCount = 0
    // Per band: its first run and how many, and its budget.
    private let bandFirst: UnsafeMutablePointer<Int32>
    private let bandRuns: UnsafeMutablePointer<Int32>
    private let bandBudget: UnsafeMutablePointer<Int32>
    private let order: UnsafeMutablePointer<Int32>
    // The grid's cells for one band: open addressing over `tableSize` slots, stamped with a generation so it is never
    // cleared; and the cells' sums.
    private static let tableSize = 1024
    private let tableKey: UnsafeMutablePointer<UInt32>
    private let tableStamp: UnsafeMutablePointer<UInt32>
    private let tableCell: UnsafeMutablePointer<Int32>
    private var stamp: UInt32 = 0
    private let cellEnergy: UnsafeMutablePointer<Float>
    private let cellX: UnsafeMutablePointer<Float>, cellY: UnsafeMutablePointer<Float>, cellZ: UnsafeMutablePointer<Float>
    private let cellFrequency: UnsafeMutablePointer<Float>
    private let cellLow: UnsafeMutablePointer<Float>, cellHigh: UnsafeMutablePointer<Float>
    private let cellScatter: UnsafeMutablePointer<Float>
    private let cellMove: UnsafeMutablePointer<Float>
    private let cellZone: UnsafeMutablePointer<Int32>
    private let cellWritten: UnsafeMutablePointer<Bool>
    // The frame's statistics.
    private var binsPlaced = 0
    private var energyIn: Double = 0

    /// `bins`: the most bins a frame can add (every band's bins, edge bins counted in both bands).
    package init(bins: Int) {
        capacity = max(16, bins + 2 * SpatialField.bandCount)
        func make<T>(_ count: Int, _ value: T) -> UnsafeMutablePointer<T> {
            let p = UnsafeMutablePointer<T>.allocate(capacity: count)
            p.initialize(repeating: value, count: count)
            return p
        }
        runBand = make(capacity, 0); runX = make(capacity, 0); runY = make(capacity, 0); runZ = make(capacity, 0)
        runEnergy = make(capacity, 0); runFrequency = make(capacity, 0); runLow = make(capacity, 0); runHigh = make(capacity, 0)
        runScatter = make(capacity, 0); runZone = make(capacity, 0); runCell = make(capacity, -1); runStrong = make(capacity, false)
        bandFirst = make(SpatialField.bandCount, 0); bandRuns = make(SpatialField.bandCount, 0)
        bandBudget = make(SpatialField.bandCount, 0); order = make(SpatialField.bandCount, 0)
        tableKey = make(Self.tableSize, 0); tableStamp = make(Self.tableSize, 0); tableCell = make(Self.tableSize, 0)
        cellEnergy = make(capacity, 0); cellX = make(capacity, 0); cellY = make(capacity, 0); cellZ = make(capacity, 0)
        cellFrequency = make(capacity, 0); cellLow = make(capacity, 0); cellHigh = make(capacity, 0)
        cellScatter = make(capacity, 0); cellMove = make(capacity, 0); cellZone = make(capacity, 0); cellWritten = make(capacity, false)
    }

    deinit {
        for p in [runX, runY, runZ, runEnergy, runFrequency, runLow, runHigh, runScatter, cellEnergy, cellX, cellY, cellZ,
                  cellFrequency, cellLow, cellHigh, cellScatter, cellMove] { p.deallocate() }
        for p in [runBand, runZone, runCell, bandFirst, bandRuns, bandBudget, order, tableCell, cellZone] { p.deallocate() }
        runStrong.deallocate(); cellWritten.deallocate(); tableKey.deallocate(); tableStamp.deallocate()
    }

    /// A new frame; bands must then be added in order, each band's bins in rising frequency.
    package func begin() {
        runCount = 0
        binsPlaced = 0
        energyIn = 0
        for band in 0..<SpatialField.bandCount { bandFirst[band] = 0; bandRuns[band] = 0 }
    }

    private var currentBand = -1
    private var tolerance2: Float = 0

    /// Starts band `band`; `extent` is the layout's radius in the mapping's units.
    package func startBand(_ band: Int, extent: Float) {
        currentBand = band
        bandFirst[band] = Int32(runCount)
        bandRuns[band] = 0
        let tolerance = Self.sameplace * max(extent, 1e-3)
        tolerance2 = tolerance * tolerance
    }

    /// One bin of the current band: its place, energy (mean square, > 0) and frequency (Hz), from transform `zone`.
    @inline(__always)
    package func add(x: Float, y: Float, z: Float, energy e: Float, frequency f: Float, zone: Int32) {
        guard e > 0, e.isFinite, x.isFinite, y.isFinite, z.isFinite else { return }
        binsPlaced += 1
        energyIn += Double(e)
        let band = currentBand
        let r = runCount - 1
        if bandRuns[band] > 0, runZone[r] == zone {
            // The same place as the run so far (within the tolerance of its centre): one place, merged exactly.
            let dx = x - runX[r], dy = y - runY[r], dz = z - runZ[r]
            if dx * dx + dy * dy + dz * dz <= tolerance2 {
                let total = runEnergy[r] + e
                let share = e / total
                // Weighted Welford: the centre moves by share·d, the scatter grows by e·d·(p − new centre).
                let nx = runX[r] + dx * share, ny = runY[r] + dy * share, nz = runZ[r] + dz * share
                runScatter[r] += e * (dx * (x - nx) + dy * (y - ny) + dz * (z - nz))
                runX[r] = nx; runY[r] = ny; runZ[r] = nz
                runEnergy[r] = total
                runFrequency[r] += e * f
                runHigh[r] = f
                return
            }
        }
        guard runCount < capacity else { return }
        let n = runCount
        runBand[n] = Int32(band)
        runX[n] = x; runY[n] = y; runZ[n] = z
        runEnergy[n] = e
        runFrequency[n] = e * f
        runLow[n] = f; runHigh[n] = f
        runScatter[n] = 0
        runZone[n] = zone
        runStrong[n] = true
        runCell[n] = -1
        runCount += 1
        bandRuns[band] += 1
    }

    /// Splits the frame's budget (`detail` per band on average) among the bands by need, reduces every band to its
    /// budget, and writes the observations (header fields after `count` included; the caller writes the rest).
    /// `extent` is the layout's radius in the mapping's units.
    package func finish(detail: Int, extent: Float, into v: UnsafeMutablePointer<Float>) {
        let bands = SpatialField.bandCount
        let total = min(SpatialObservations.capacity, max(1, detail) * bands)
        // Below the transform's precision: left out before the budget is shared (they would only take budget).
        var strongest: Float = 0
        for r in 0..<runCount { strongest = max(strongest, runEnergy[r]) }
        let floor = strongest * Self.precision
        var dropped: Double = 0
        for band in 0..<bands {
            let first = Int(bandFirst[band]), runs = Int(bandRuns[band])
            var kept = first
            for r in first..<(first + runs) {
                if runEnergy[r] < floor { dropped += Double(runEnergy[r]); continue }
                if kept != r { move(r, to: kept) }
                kept += 1
            }
            bandRuns[band] = Int32(kept - first)
        }
        allocate(total: total)
        var index = 0
        var largestMove: Float = 0
        var moved: Double = 0
        for band in 0..<bands {
            let first = Int(bandFirst[band]), runs = Int(bandRuns[band])
            var made = 0
            if runs > 0 {
                let budget = max(1, Int(bandBudget[band]))
                if runs > budget { gather(first: first, runs: runs, budget: budget, extent: extent) }
                else { for r in first..<(first + runs) { runStrong[r] = true } }
                // Out in frequency order of each observation's first run.
                for r in first..<(first + runs) where index < SpatialObservations.capacity {
                    let o = v + SpatialObservations.observation(index)
                    if runStrong[r] {
                        let e = runEnergy[r]
                        o[0] = runX[r]; o[1] = runY[r]; o[2] = runZ[r]; o[3] = e
                        o[4] = runFrequency[r] / e; o[5] = runLow[r]; o[6] = runHigh[r]
                        o[7] = (max(0, runScatter[r]) / e).squareRoot()
                        o[8] = Float(runZone[r])
                    } else {
                        let c = Int(runCell[r])
                        guard c >= 0, !cellWritten[c] else { continue }
                        cellWritten[c] = true
                        let e = cellEnergy[c]
                        o[0] = cellX[c]; o[1] = cellY[c]; o[2] = cellZ[c]; o[3] = e
                        o[4] = cellFrequency[c] / e; o[5] = cellLow[c]; o[6] = cellHigh[c]
                        o[7] = (max(0, cellScatter[c]) / e).squareRoot()
                        o[8] = Float(cellZone[c])
                        largestMove = max(largestMove, cellMove[c])
                    }
                    index += 1
                    made += 1
                }
                // The moves, energy-weighted: each gathered run's distance to its cell's centre.
                for r in first..<(first + runs) where !runStrong[r] {
                    let c = Int(runCell[r])
                    guard c >= 0 else { continue }
                    let dx = runX[r] - cellX[c], dy = runY[r] - cellY[c], dz = runZ[r] - cellZ[c]
                    moved += Double(runEnergy[r]) * Double((dx * dx + dy * dy + dz * dz).squareRoot())
                }
            }
            v[SpatialObservations.counts + band] = Float(made)
        }
        v[SpatialObservations.Header.count] = Float(index)
        v[SpatialObservations.Header.bins] = Float(binsPlaced)
        v[SpatialObservations.Header.energy] = Float(energyIn)
        v[SpatialObservations.Header.belowPrecision] = Float(dropped)
        v[SpatialObservations.Header.largestMove] = largestMove
        v[SpatialObservations.Header.meanMove] = energyIn > 0 ? Float(moved / energyIn) : 0
        v[SpatialObservations.Header.detail] = Float(detail)
    }

    /// Run `r` copied to slot `to` (an earlier one of the same band).
    private func move(_ r: Int, to: Int) {
        runBand[to] = runBand[r]; runX[to] = runX[r]; runY[to] = runY[r]; runZ[to] = runZ[r]
        runEnergy[to] = runEnergy[r]; runFrequency[to] = runFrequency[r]; runLow[to] = runLow[r]; runHigh[to] = runHigh[r]
        runScatter[to] = runScatter[r]; runZone[to] = runZone[r]; runStrong[to] = runStrong[r]; runCell[to] = runCell[r]
    }

    /// Water-filling: bands in order of need; each takes what it needs up to an equal share of what is left, so what the
    /// simple bands do not use goes to the detailed ones.
    private func allocate(total: Int) {
        let bands = SpatialField.bandCount
        var open = 0
        for band in 0..<bands {
            bandBudget[band] = 0
            if bandRuns[band] > 0 { order[open] = Int32(band); open += 1 }
        }
        // Insertion sort by need (≤ 96 bands).
        if open > 1 {
            for i in 1..<open {
                let item = order[i]
                var j = i - 1
                while j >= 0 && bandRuns[Int(order[j])] > bandRuns[Int(item)] { order[j + 1] = order[j]; j -= 1 }
                order[j + 1] = item
            }
        }
        var remaining = total
        for i in 0..<open {
            let band = Int(order[i])
            let share = max(1, remaining / (open - i))
            let give = min(Int(bandRuns[band]), share, SpatialObservations.perBandLimit)
            bandBudget[band] = Int32(give)
            remaining = max(0, remaining - give)
        }
    }

    /// Reduces one band's `runs` (from `first`) to `budget` observations: runs carrying at least 1/`budget` of the band's
    /// energy stay as they are; the rest gather in grid cells, the grid coarsening until they fit.
    private func gather(first: Int, runs: Int, budget: Int, extent: Float) {
        var bandEnergy: Float = 0
        for r in first..<(first + runs) { bandEnergy += runEnergy[r] }
        let threshold = bandEnergy / Float(budget)
        var strong = 0
        for r in first..<(first + runs) {
            runStrong[r] = runEnergy[r] >= threshold
            if runStrong[r] { strong += 1 }
        }
        // At most budget − 1 kept as they are, the strongest (only exactly equal energies can reach budget).
        while strong > budget - 1 {
            var weakest = -1
            for r in first..<(first + runs) where runStrong[r] && (weakest < 0 || runEnergy[r] < runEnergy[weakest]) { weakest = r }
            runStrong[weakest] = false
            strong -= 1
        }
        let room = max(1, budget - strong)
        let radius = max(extent, 1e-3)
        var cell = Self.finestCell * radius
        var cells = 0
        while true {
            stamp &+= 1
            if stamp == 0 { tableStamp.update(repeating: 0, count: Self.tableSize); stamp = 1 }
            cells = 0
            let inverse = 1 / cell
            for r in first..<(first + runs) where !runStrong[r] {
                // Integer cell coordinates over the layout's cube (positions never leave the speakers' hull).
                let ix = UInt32(max(0, min(1023, Int(((runX[r] + radius) * inverse).rounded(.down)))))
                let iy = UInt32(max(0, min(1023, Int(((runY[r] + radius) * inverse).rounded(.down)))))
                let iz = UInt32(max(0, min(1023, Int(((runZ[r] + radius) * inverse).rounded(.down)))))
                let key = ix | iy << 10 | iz << 20
                var slot = Int((key &* 0x9E37_79B1) >> 22) & (Self.tableSize - 1)
                while tableStamp[slot] == stamp && tableKey[slot] != key { slot = (slot + 1) & (Self.tableSize - 1) }
                if tableStamp[slot] != stamp {
                    tableStamp[slot] = stamp
                    tableKey[slot] = key
                    tableCell[slot] = Int32(cells)
                    cells += 1
                }
                runCell[r] = tableCell[slot]
            }
            if cells <= room || cell > 4 * radius { break }
            cell *= 2
        }
        // The cells' sums, then (second pass, about their final centres) their scatter and the largest move.
        for c in 0..<cells {
            cellEnergy[c] = 0; cellX[c] = 0; cellY[c] = 0; cellZ[c] = 0; cellFrequency[c] = 0
            cellLow[c] = .greatestFiniteMagnitude; cellHigh[c] = 0; cellScatter[c] = 0; cellMove[c] = 0; cellWritten[c] = false
        }
        for r in first..<(first + runs) where !runStrong[r] {
            let c = Int(runCell[r]), e = runEnergy[r]
            cellEnergy[c] += e
            cellX[c] += e * runX[r]; cellY[c] += e * runY[r]; cellZ[c] += e * runZ[r]
            cellFrequency[c] += runFrequency[r]
            cellLow[c] = min(cellLow[c], runLow[r]); cellHigh[c] = max(cellHigh[c], runHigh[r])
            cellZone[c] = runZone[r]
        }
        for c in 0..<cells where cellEnergy[c] > 0 {
            cellX[c] /= cellEnergy[c]; cellY[c] /= cellEnergy[c]; cellZ[c] /= cellEnergy[c]
        }
        for r in first..<(first + runs) where !runStrong[r] {
            let c = Int(runCell[r])
            let dx = runX[r] - cellX[c], dy = runY[r] - cellY[c], dz = runZ[r] - cellZ[c]
            let d2 = dx * dx + dy * dy + dz * dz
            cellScatter[c] += runEnergy[r] * d2 + max(0, runScatter[r])
            cellMove[c] = max(cellMove[c], d2.squareRoot())
        }
    }
}

/// RESULT tag 58 (Bridge/PROTOCOL.md): a frame's observations (`SpatialObservations`). Little-endian bytes:
///
///   header (48): version 1 · status (1 observations, 0 none) · mapping (0 directions, 1 meters) · zones ·
///                revision u32 · hash u64 · window end u64 (frames analysed in this generation) · window u32 (samples,
///                zone 0) · serial u32 · bands u16 (96) · observations u16 · bins energy f32 · largest move f32 ·
///                detail u16 · algorithm u8 (1) · 0 u8 · energy left out below the transform's precision f32
///   then zones − 1 × u32: the window of zones 1…;
///   then bands × u16: each band's number of observations;
///   then observations × 28: x y z f32 (the mapping's units: unit directions, or meters) · energy f32 (mean square) ·
///                spread f32 (the same units) · frequency u16 · lowest u16 · highest u16 (`frequencyCode`) · zone u8 · 0 u8
package enum SpatialObservationsWire {
    package static let version: UInt8 = 1
    package static let algorithm: UInt8 = 1
    package static let headerBytes = 52
    package static let observationBytes = 28
    package static let maxZones = 4
    package static let largest = headerBytes + 4 * (maxZones - 1) + 2 * SpatialField.bandCount
        + SpatialObservations.capacity * observationBytes

    /// Frequencies as 1/4096 octave steps above 10 Hz (10 Hz … 655 kHz, 0.3 cent steps).
    package static func frequencyCode(_ hz: Float) -> UInt16 {
        guard hz.isFinite, hz > 10 else { return 0 }
        return UInt16(max(0, min(65_535, (log2(hz / 10) * 4096).rounded())))
    }
    package static func frequency(_ code: UInt16) -> Float { 10 * exp2(Float(code) / 4096) }

    private static func zones(_ v: UnsafePointer<Float>) -> Int { max(1, min(maxZones, Int(v[SpatialObservations.Header.zones]))) }
    private static func count(_ v: UnsafePointer<Float>) -> Int {
        max(0, min(SpatialObservations.capacity, Int(v[SpatialObservations.Header.count])))
    }

    /// Bytes `encode` writes for `v`.
    package static func size(_ v: UnsafePointer<Float>) -> Int {
        guard v[SpatialObservations.Header.status] == 1 else { return headerBytes }
        return headerBytes + 4 * (zones(v) - 1) + 2 * SpatialField.bandCount + count(v) * observationBytes
    }

    @discardableResult
    package static func encode(_ v: UnsafePointer<Float>, into out: UnsafeMutableRawPointer) -> Int {
        typealias H = SpatialObservations.Header
        let valid = v[H.status] == 1
        let n = valid ? count(v) : 0, z = zones(v)
        out.initializeMemory(as: UInt8.self, repeating: 0, count: headerBytes)
        out.storeBytes(of: version, toByteOffset: 0, as: UInt8.self)
        out.storeBytes(of: UInt8(valid ? 1 : 0), toByteOffset: 1, as: UInt8.self)
        out.storeBytes(of: UInt8(max(0, min(1, v[H.mapping]))), toByteOffset: 2, as: UInt8.self)
        out.storeBytes(of: UInt8(z), toByteOffset: 3, as: UInt8.self)
        out.storeBytes(of: SpatialObservations.revision(v).littleEndian, toByteOffset: 4, as: UInt32.self)
        out.storeBytes(of: SpatialObservations.hash(v).littleEndian, toByteOffset: 8, as: UInt64.self)
        out.storeBytes(of: SpatialObservations.windowEnd(v).littleEndian, toByteOffset: 16, as: UInt64.self)
        out.storeBytes(of: UInt32(max(0, v[H.windowLength])).littleEndian, toByteOffset: 24, as: UInt32.self)
        out.storeBytes(of: UInt32(max(0, v[H.serial])).littleEndian, toByteOffset: 28, as: UInt32.self)
        out.storeBytes(of: UInt16(SpatialField.bandCount).littleEndian, toByteOffset: 32, as: UInt16.self)
        out.storeBytes(of: UInt16(n).littleEndian, toByteOffset: 34, as: UInt16.self)
        out.storeBytes(of: v[H.energy].bitPattern.littleEndian, toByteOffset: 36, as: UInt32.self)
        out.storeBytes(of: v[H.largestMove].bitPattern.littleEndian, toByteOffset: 40, as: UInt32.self)
        out.storeBytes(of: UInt16(max(0, v[H.detail])).littleEndian, toByteOffset: 44, as: UInt16.self)
        out.storeBytes(of: algorithm, toByteOffset: 46, as: UInt8.self)
        out.storeBytes(of: v[H.belowPrecision].bitPattern.littleEndian, toByteOffset: 48, as: UInt32.self)
        guard valid else { return headerBytes }
        var at = headerBytes
        for zone in 1..<z {
            out.storeBytes(of: UInt32(max(0, SpatialObservations.window(v, zone: zone))).littleEndian, toByteOffset: at, as: UInt32.self)
            at += 4
        }
        for band in 0..<SpatialField.bandCount {
            out.storeBytes(of: UInt16(max(0, v[SpatialObservations.counts + band])).littleEndian, toByteOffset: at, as: UInt16.self)
            at += 2
        }
        for i in 0..<n {
            let o = v + SpatialObservations.observation(i)
            for k in 0..<4 { out.storeBytes(of: o[k].bitPattern.littleEndian, toByteOffset: at + 4 * k, as: UInt32.self) }
            out.storeBytes(of: o[7].bitPattern.littleEndian, toByteOffset: at + 16, as: UInt32.self)
            out.storeBytes(of: frequencyCode(o[4]).littleEndian, toByteOffset: at + 20, as: UInt16.self)
            out.storeBytes(of: frequencyCode(o[5]).littleEndian, toByteOffset: at + 22, as: UInt16.self)
            out.storeBytes(of: frequencyCode(o[6]).littleEndian, toByteOffset: at + 24, as: UInt16.self)
            out.storeBytes(of: UInt8(max(0, min(255, o[8]))), toByteOffset: at + 26, as: UInt8.self)
            out.storeBytes(of: UInt8(0), toByteOffset: at + 27, as: UInt8.self)
            at += observationBytes
        }
        return at
    }

    /// Expands received observations into `v` (`SpatialObservations` layout) for a stream at `sampleRate`. Returns false,
    /// leaving status 0, when the bytes are not a valid set.
    @discardableResult
    package static func decode(_ bytes: UnsafeRawBufferPointer, sampleRate: Double, into v: UnsafeMutablePointer<Float>) -> Bool {
        typealias H = SpatialObservations.Header
        v.update(repeating: 0, count: SpatialObservations.first)
        guard bytes.count >= headerBytes, bytes[0] == version else { return false }
        let mapping = bytes[2], z = Int(bytes[3])
        guard mapping <= 1, (1...maxZones).contains(z),
              Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 32, as: UInt16.self))) == SpatialField.bandCount else { return false }
        let n = Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 34, as: UInt16.self)))
        let revision = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        let hash = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        let windowEnd = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
        func float(_ offset: Int) -> Float { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
        func header() {
            v[H.version] = SpatialObservations.version
            v[H.mapping] = Float(mapping)
            v[H.source] = SpatialObservations.Source.measured.rawValue
            SpatialObservations.store(UInt64(revision), parts: 2, at: v + H.revision)
            SpatialObservations.store(hash, parts: 4, at: v + H.hash)
            SpatialObservations.store(windowEnd, parts: 3, at: v + H.windowEnd, bits: 24)
            v[H.sampleRate] = Float(sampleRate)
            v[H.windowLength] = Float(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 24, as: UInt32.self)))
            v[H.serial] = Float(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 28, as: UInt32.self)) % (1 << 24))
            v[H.energy] = float(36)
            v[H.largestMove] = float(40)
            v[H.detail] = Float(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 44, as: UInt16.self)))
            v[H.zones] = Float(z)
            v[H.belowPrecision] = float(48)
        }
        guard bytes[1] == 1 else {
            guard bytes.count == headerBytes else { return false }
            header()
            return true
        }
        let tables = headerBytes + 4 * (z - 1)
        guard n <= SpatialObservations.capacity,
              bytes.count == tables + 2 * SpatialField.bandCount + n * observationBytes else { return false }
        var sum = 0
        for band in 0..<SpatialField.bandCount {
            let count = Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: tables + 2 * band, as: UInt16.self)))
            guard count <= SpatialObservations.perBandLimit else { return false }
            sum += count
        }
        guard sum == n else { return false }
        var at = tables + 2 * SpatialField.bandCount
        for i in 0..<n {
            let o = v + SpatialObservations.observation(i)
            let x = float(at), y = float(at + 4), zz = float(at + 8), e = float(at + 12), spread = float(at + 16)
            guard x.isFinite, y.isFinite, zz.isFinite, e.isFinite, e >= 0, spread.isFinite, spread >= 0 else {
                v.update(repeating: 0, count: SpatialObservations.first)
                return false
            }
            o[0] = x; o[1] = y; o[2] = zz; o[3] = e
            o[4] = frequency(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: at + 20, as: UInt16.self)))
            o[5] = frequency(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: at + 22, as: UInt16.self)))
            o[6] = frequency(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: at + 24, as: UInt16.self)))
            o[7] = spread
            o[8] = Float(min(Int(bytes[at + 26]), z - 1))
            at += observationBytes
        }
        header()
        for zone in 1..<z {
            v[H.zoneWindow + zone - 1] = Float(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: headerBytes + 4 * (zone - 1), as: UInt32.self)))
        }
        for band in 0..<SpatialField.bandCount {
            v[SpatialObservations.counts + band] = Float(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: tables + 2 * band, as: UInt16.self)))
        }
        v[H.count] = Float(n)
        v[H.bins] = Float(n)
        v[H.status] = 1
        return true
    }
}
