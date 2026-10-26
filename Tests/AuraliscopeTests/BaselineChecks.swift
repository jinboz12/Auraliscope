import Foundation
import AudioRing
import AudioToolbox

/// Regression baseline for maintenance work (docs/maintenance/BASELINE_2026-10.md). These checks change no
/// production code; they pin what the analysis and the capture path do today, so a refactor can prove it changed
/// nothing.
///
/// 1. **Golden pipeline digests.** Five deterministic scenarios (stereo at 48 and 96 kHz, the app's shared 4096
///    STFT with Multi-FFT, the reassigned spectrogram, a break, and 7.1.4 routed through the capture ring with the
///    spatial field on) run through `MeterPipeline` tick by tick. Every published snapshot is hashed bit for bit per
///    `SnapshotSlots` group and compared with `Tests/Fixtures/pipeline-golden.json`. Bit-exact digests hold for one
///    architecture and toolchain: a compiler or SDK change may legitimately alter rounding. Re-record only after the
///    portable checks below pass: `AURALISCOPE_RECORD_GOLDEN=1 scripts/test.sh`.
/// 2. **Portable checks** of the same runs, independent of rounding: each role's published peak is exactly the
///    largest sample of the newest 1/30 s, RMS matches to 1e-5, unrouted roles stay silent, a pure tone's dominant
///    peak is where it should be, and a break is counted with its missing time.
/// 3. **Snapshot layout:** the slot groups tile `METER_SNAPSHOT_FLOATS` exactly, in order, with the sizes their
///    producers use.
/// 4. **Known issues (characterization).** The capture defects confirmed in Phase 2 are pinned as they behave
///    today, so the run stays green and any change in that behaviour is noticed. The fix for each must turn its
///    check around to assert the intended behaviour.
enum BaselineChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    static func run() throws {
        try snapshotLayout()
        print("PASS: baseline: snapshot slot groups tile METER_SNAPSHOT_FLOATS in order, with their producers' sizes")
        try snapshotContractDocument()
        print("PASS: baseline: \(contractDocument) lists every slot group at its offset and size")
        try logFrequencyAxisMatchesLegacyExpressions()
        print("PASS: baseline: LogFrequencyAxis equals, bit for bit, every expression it replaced, at 11 rates and 6 band counts")
        try goldenPipeline()
        try knownIssueCaptureRejectsSilently()
        try knownIssueTapTruncatesSilently()
    }

    // MARK: - Snapshot layout

    /// The named slot groups in snapshot order; each runs to the next one's offset, the last to `total`.
    static let groups: [(name: String, offset: Int)] = [
        ("spectrum", SnapshotSlots.spectrum), ("peaks", SnapshotSlots.peaks), ("rms", SnapshotSlots.rms),
        ("truePeaks", SnapshotSlots.truePeaks), ("heldPeaks", SnapshotSlots.heldPeaks),
        ("heldTruePeaks", SnapshotSlots.heldTruePeaks), ("scalars", SnapshotSlots.momentary),
        ("spectrogram", SnapshotSlots.spectrogram), ("bandReadings", SnapshotSlots.bandCorrelation),
        ("bandPoints", SnapshotSlots.bandPoints), ("roleBandPower", SnapshotSlots.roleBandPower),
        ("notes", SnapshotSlots.notes), ("waveform", SnapshotSlots.waveform), ("continuity", SnapshotSlots.breaks),
        ("spectrumFine", SnapshotSlots.spectrumFine), ("spectrogramMode", SnapshotSlots.spectrogramMode),
        ("spatialField", SnapshotSlots.spatialField), ("spatialPoints", SnapshotSlots.spatialPoints),
        ("signalHealth", SnapshotSlots.signalHealth), ("spatialObservations", SnapshotSlots.spatialObservations),
    ]
    static func range(_ index: Int) -> Range<Int> {
        groups[index].offset..<(index + 1 < groups.count ? groups[index + 1].offset : SnapshotSlots.total)
    }

    static func snapshotLayout() throws {
        try require(SnapshotSlots.total == Int(METER_SNAPSHOT_FLOATS),
                    "SnapshotSlots.total \(SnapshotSlots.total) != METER_SNAPSHOT_FLOATS \(METER_SNAPSHOT_FLOATS)")
        try require(groups.first?.offset == 0, "the snapshot starts with the spectrum")
        for i in groups.indices { try require(!range(i).isEmpty, "slot group \(groups[i].name) is empty or out of order") }
        let sizes: [String: Int] = [
            "spectrum": SnapshotSlots.peaks - SnapshotSlots.spectrum, "peaks": Role.count, "rms": Role.count,
            "truePeaks": Role.count, "heldPeaks": Role.count, "heldTruePeaks": Role.count, "scalars": 12,
            "spectrogram": MeterSnapshot.spectrogramBandCount, "bandReadings": 4 * StereoBands.groups.count,
            "bandPoints": StereoBands.scopeFloats, "roleBandPower": StereoBands.roleFloats,
            "notes": 2 * SpectrumAnalyzer.maxNotes, "waveform": WaveformEnvelope.publishedFloats, "continuity": 2,
            "spectrumFine": MeterSnapshot.fineBandCount, "spectrogramMode": 1, "spatialField": SpatialField.floats,
            "spatialPoints": SpatialPoints.floats, "signalHealth": 2 * Role.count + 1,
            "spatialObservations": SpatialObservations.floats,
        ]
        for i in groups.indices {
            try require(range(i).count == sizes[groups[i].name], "slot group \(groups[i].name) holds \(range(i).count) floats, its producer writes \(sizes[groups[i].name]!)")
        }
        try require(SnapshotSlots.peaks - SnapshotSlots.spectrum == MeterSnapshot.bandCount, "64 spectrum bands")
    }

    /// The snapshot's layout is documented for people and agents changing it; the table there must match the code.
    static let contractDocument = "docs/SNAPSHOT_CONTRACT.md"
    static func snapshotContractDocument() throws {
        let rows = groups.indices.map { "| `\(groups[$0].name)` | \(range($0).lowerBound) | \(range($0).count) |" }
        if ProcessInfo.processInfo.environment["AURALISCOPE_PRINT_SNAPSHOT_TABLE"] == "1" { print(rows.joined(separator: "\n")) }
        let text = (try? String(contentsOfFile: contractDocument, encoding: .utf8)) ?? ""
        for row in rows {
            try require(text.contains(row), "\(contractDocument) is out of date: no row starting \(row)")
        }
        try require(text.contains("`METER_SNAPSHOT_FLOATS` = \(SnapshotSlots.total)"),
                    "\(contractDocument) does not state the total, \(SnapshotSlots.total) floats")
    }

    // MARK: - Frequency axis (refactoring batch 3.1)

    /// `LogFrequencyAxis` replaced expressions that were written out in 31 places. Each function must equal, bit for
    /// bit, the expression as those callers wrote it (literal 20, the same operation order), so moving a caller onto it
    /// cannot change a band, a row, a drawn line or a reported frequency.
    static func logFrequencyAxisMatchesLegacyExpressions() throws {
        let rates: [Double] = [8_000, 11_025, 22_050, 32_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 384_000]
        let counts = [7, 64, 96, 128, 512, MultiFFTAnalyzer.points]
        func same(_ a: Double, _ b: Double, _ what: @autoclosure () -> String) throws {
            try require(a.bitPattern == b.bitPattern, "LogFrequencyAxis.\(what()): \(a) != legacy \(b)")
        }
        for rate in rates {
            let upper = min(20_000, rate / 2)
            try same(LogFrequencyAxis.upper(sampleRate: rate), upper, "upper(\(rate))")
            try same(LogFrequencyAxis.octaves(upper: upper), log2(upper / 20), "octaves(\(upper))")
            for count in counts {
                for index in 0...count {
                    try same(LogFrequencyAxis.edge(index, of: count, upper: upper),
                             20 * pow(upper / 20, Double(index) / Double(count)), "edge(\(index), \(count), \(upper))")
                    guard index < count else { continue }
                    try same(LogFrequencyAxis.centre(index, of: count, upper: upper),
                             20 * pow(upper / 20, (Double(index) + 0.5) / Double(count)), "centre(\(index), \(count), \(upper))")
                }
            }
            for step in 0...400 {
                let position = Double(step) / 400 * 1.2 - 0.1
                try same(LogFrequencyAxis.frequency(atPosition: position, upper: upper), 20 * pow(upper / 20, position),
                         "frequency(atPosition: \(position), \(upper))")
                let frequency = 5 * pow(2, Double(step) / 400 * 13)
                try same(LogFrequencyAxis.position(of: frequency, upper: upper), log(frequency / 20) / log(upper / 20),
                         "position(of: \(frequency), \(upper))")
            }
        }
    }

    // MARK: - Golden pipeline

    struct Scenario {
        let name: String
        let rate: Double
        let seconds: Double
        /// Roles given audio (and routed); every other role is unrouted.
        let roles: [Int]
        var spatial = false
        var legacy = LegacySTFT.legacy
        var enhanced = false
        var multiFFT = false
        /// Through the capture ring with a scrambled channel map, as a device delivers.
        var throughRing = false
        /// A break (frames lost) before this tick.
        var breakAtTick: Int? = nil
        var lostFrames: UInt64 = 0
        /// One sample of `role` at frame `n`.
        let sample: (Int, Int) -> Float
    }

    /// Deterministic pseudo-noise in −1…1 (a 32-bit LCG per role and frame), identical on every machine.
    static func noise(_ role: Int, _ n: Int) -> Float {
        var x = UInt32(truncatingIfNeeded: n &* 1_103_515_245 &+ role &* 12_345 &+ 0x9E37_79B9)
        x ^= x >> 15; x = x &* 0x2C1B_3C6D; x ^= x >> 12; x = x &* 0x297A_2D39; x ^= x >> 15
        return Float(Int32(bitPattern: x)) / Float(Int32.max)
    }

    static func tone(_ frequency: Double, _ n: Int, _ rate: Double, phase: Double = 0) -> Float {
        Float(sin(2 * .pi * frequency * Double(n) / rate + phase))
    }

    static let music: (Double) -> (Int, Int) -> Float = { rate in { role, n in
        // Bass, a 997 Hz partial, a treble partial and noise; R panned and phase-shifted so correlation is not 1.
        let pan: Float = role == Role.left ? 1 : 0.7
        return pan * (0.30 * tone(63, n, rate, phase: Double(role)) + 0.18 * tone(997, n, rate)
            + 0.08 * tone(4_000, n, rate, phase: 0.5 * Double(role)) + 0.03 * noise(role, n))
    } }

    static var scenarios: [Scenario] {
        let s714 = SpeakerLayout.s714.roles
        return [
            Scenario(name: "stereo48-legacy", rate: 48_000, seconds: 3, roles: [Role.left, Role.right], sample: music(48_000)),
            Scenario(name: "stereo48-shared4096-multifft", rate: 48_000, seconds: 3, roles: [Role.left, Role.right],
                     legacy: .shared4096, multiFFT: true, sample: music(48_000)),
            Scenario(name: "stereo48-enhanced", rate: 48_000, seconds: 3, roles: [Role.left, Role.right], enhanced: true,
                     sample: music(48_000)),
            Scenario(name: "stereo96-break", rate: 96_000, seconds: 3, roles: [Role.left, Role.right], breakAtTick: 90,
                     lostFrames: 4_800, sample: music(96_000)),
            Scenario(name: "s714-spatial48-ring", rate: 48_000, seconds: 3, roles: s714, spatial: true, throughRing: true,
                     sample: { role, n in
                         // Each speaker its own tone and level; L, R and C share a coherent phantom; LFE only bass.
                         let index = s714.firstIndex(of: role) ?? 0
                         if role == Role.lfe { return 0.25 * tone(45, n, 48_000) }
                         let own = (0.04 + 0.015 * Float(index)) * tone(150 * Double(index + 2), n, 48_000)
                         let phantom: Float = [Role.left, Role.right, Role.center].contains(role) ? 0.2 * tone(1_250, n, 48_000) : 0
                         return own + phantom + 0.01 * noise(role, n)
                     }),
        ]
    }

    /// FNV-1a over 32-bit words.
    struct Digest {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        mutating func add(_ word: UInt32) { value = (value ^ UInt64(word)) &* 0x0000_0100_0000_01B3 }
        mutating func add(_ floats: UnsafeBufferPointer<Float>) { for f in floats { add(f.bitPattern) } }
        var hex: String { String(format: "%016llx", value) }
    }

    static func frame(_ values: (Int) -> Float) -> ChannelFrame {
        var f = ChannelFrame()
        withUnsafeMutableBytes(of: &f) { raw in
            let p = raw.bindMemory(to: Float.self)
            for role in 0..<Role.count { p[role] = values(role) }
        }
        return f
    }
    static func value(_ f: ChannelFrame, _ role: Int) -> Float {
        withUnsafeBytes(of: f) { $0.bindMemory(to: Float.self)[role] }
    }

    /// Runs one scenario and returns each slot group's digest (plus Multi-FFT's), checking the portable expectations
    /// on the way.
    static func run(_ s: Scenario) throws -> [String: String] {
        let active = (0..<Role.count).map { s.roles.contains($0) || $0 == Role.left || $0 == Role.right }
        guard let pipeline = MeterPipeline(sampleRate: s.rate, activeRoles: active, detector: FormatDetector(), streamID: 7) else {
            throw Failure(description: "\(s.name): no pipeline")
        }
        if s.spatial {
            pipeline.spatialGeometry = SpatialGeometry.standard(roles: s.roles)
            pipeline.spatialSpectrum = true
        }
        pipeline.configureLegacySTFT(s.legacy)
        if s.enhanced { pipeline.spectrum.spectrogramMode = .enhanced }
        if s.multiFFT { pipeline.multiFFT = MultiFFTAnalyzer(sampleRate: s.rate, configuration: .make(.standard, priority: .balanced)) }

        // The scrambled capture routing: the source's channels in reverse order (role r reads channel k − 1 − i).
        let channels = s.roles.count
        var sourceForRole = [Int32](repeating: -1, count: Role.count)
        for (i, role) in s.roles.enumerated() { sourceForRole[role] = Int32(channels - 1 - i) }
        let ring = s.throughRing ? channel_ring_create(1 << 15) : nil
        defer { if let ring { channel_ring_destroy(ring) } }

        var digests = [Digest](repeating: Digest(), count: groups.count)
        var values = [Float](repeating: 0, count: SnapshotSlots.total)
        let perTick = Int((s.rate / MeterPipeline.tickRate).rounded())
        let ticks = Int(s.seconds * MeterPipeline.tickRate)
        // Each tick's audio arrives in two or three blocks of uneven size.
        let splits: [[Double]] = [[0.31, 1], [0.5, 0.77, 1], [1], [0.13, 1]]
        var position = 0
        var tickPeaks: [[Float]] = []
        var tickSquares: [[Double]] = []
        var buffer = [ChannelFrame](repeating: ChannelFrame(), count: perTick)
        var interleaved = [Float](repeating: 0, count: perTick * max(1, channels))
        var dominant: [Float] = []

        for tick in 1...ticks {
            if tick == s.breakAtTick {
                position += Int(s.lostFrames)
                pipeline.interrupt(lostFrames: s.lostFrames, idleMilliseconds: 0)
            }
            var peaks = [Float](repeating: 0, count: Role.count)
            var squares = [Double](repeating: 0, count: Role.count)
            var start = 0
            for edge in splits[tick % splits.count] {
                let end = Int((Double(perTick) * edge).rounded())
                let count = end - start
                guard count > 0 else { continue }
                for i in 0..<count {
                    let n = position + start + i
                    let f = frame { s.roles.contains($0) ? s.sample($0, n) : 0 }
                    buffer[i] = f
                    for role in 0..<Role.count {
                        let v = value(f, role)
                        peaks[role] = max(peaks[role], abs(v))
                        squares[role] += Double(v) * Double(v)
                    }
                }
                if let ring {
                    // Interleave in the source's channel order, then through the ring as the IO callback writes it.
                    for i in 0..<count {
                        for (index, role) in s.roles.enumerated() { interleaved[i * channels + (channels - 1 - index)] = value(buffer[i], role) }
                    }
                    try require(channel_ring_write(ring, interleaved, UInt32(count), UInt32(channels), sourceForRole) == UInt32(count), "\(s.name): ring full")
                    var read = [ChannelFrame](repeating: ChannelFrame(), count: count)
                    try require(channel_ring_read(ring, &read, UInt32(count)) == UInt32(count), "\(s.name): ring short")
                    for i in 0..<count {
                        for role in 0..<Role.count {
                            try require(value(read[i], role).bitPattern == value(buffer[i], role).bitPattern,
                                        "\(s.name): ring routing changed role \(role) at frame \(i)")
                        }
                    }
                    read.withUnsafeBufferPointer { pipeline.consume($0) }
                } else {
                    buffer.withUnsafeBufferPointer { pipeline.consume(UnsafeBufferPointer(rebasing: $0[0..<count])) }
                }
                start = end
            }
            position += perTick
            tickPeaks.append(peaks)
            tickSquares.append(squares)
            values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: Double(tick) / MeterPipeline.tickRate) }
            values.withUnsafeBufferPointer { all in
                for i in groups.indices { digests[i].add(UnsafeBufferPointer(rebasing: all[range(i)])) }
            }
            dominant.append(values[SnapshotSlots.peakFrequency])

            // Portable: the level window is the newest two ticks (1/30 s), every one of them full here.
            let afterBreak = s.breakAtTick.map { tick >= $0 && tick < $0 + 2 } ?? false
            if tick >= 2 && !afterBreak {
                for role in 0..<Role.count {
                    let expected = max(tickPeaks[tick - 1][role], tickPeaks[tick - 2][role])
                    try require(values[SnapshotSlots.peaks + role] == expected,
                                "\(s.name) tick \(tick): role \(role) peak \(values[SnapshotSlots.peaks + role]) != newest 1/30 s maximum \(expected)")
                    let rms = Float(((tickSquares[tick - 1][role] + tickSquares[tick - 2][role]) / Double(2 * perTick)).squareRoot())
                    try require(abs(values[SnapshotSlots.rms + role] - rms) <= 1e-5 * max(1, rms),
                                "\(s.name) tick \(tick): role \(role) RMS \(values[SnapshotSlots.rms + role]) != \(rms)")
                    if !s.roles.contains(role) {
                        try require(values[SnapshotSlots.peaks + role] == 0 && values[SnapshotSlots.truePeaks + role] == 0,
                                    "\(s.name): unrouted role \(role) is not silent")
                    }
                }
            }
        }
        // Portable: the continuity counters.
        if let breakAt = s.breakAtTick {
            _ = breakAt
            try require(values[SnapshotSlots.breaks] == 1, "\(s.name): one break counted")
            try require(abs(Double(values[SnapshotSlots.missing]) - Double(s.lostFrames) / s.rate) < 1e-6, "\(s.name): missing time")
        } else {
            try require(values[SnapshotSlots.breaks] == 0, "\(s.name): no break")
        }
        // Portable: in stereo music the dominant peak settles on the 63 Hz partial (the loudest).
        if !s.spatial {
            let settled = dominant.suffix(60)
            try require(settled.allSatisfy { abs($0 - 63) < 1.5 }, "\(s.name): dominant peak \(settled.min()!)…\(settled.max()!) Hz, expected 63 Hz")
        }
        var result: [String: String] = [:]
        for i in groups.indices { result[groups[i].name] = digests[i].hex }
        if let multi = pipeline.multiFFT?.latest {
            var d = Digest()
            for curve in multi.curves { curve.withUnsafeBufferPointer { d.add($0) } }
            result["multiFFT"] = d.hex
            try require(multi.curves.count >= 2, "\(s.name): Multi-FFT published L and R")
        } else if s.multiFFT {
            throw Failure(description: "\(s.name): Multi-FFT published nothing")
        }
        return result
    }

    static let fixture = "Tests/Fixtures/pipeline-golden.json"
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static func goldenPipeline() throws {
        var measured: [String: [String: String]] = [:]
        for scenario in scenarios {
            measured[scenario.name] = try run(scenario)
            print("PASS: baseline: \(scenario.name): peaks exact per 1/30 s, RMS, unrouted silence, continuity, dominant peak")
        }
        let url = URL(fileURLWithPath: fixture)
        var file = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        if ProcessInfo.processInfo.environment["AURALISCOPE_RECORD_GOLDEN"] == "1" {
            file[architecture] = measured
            file["note"] = "Bit-exact MeterPipeline digests per SnapshotSlots group (BaselineChecks). Recorded per architecture with the toolchain named here; re-record only after the portable checks pass."
            file["toolchain.\(architecture)"] = toolchain()
            let data = try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            print("RECORDED: baseline golden digests for \(architecture) in \(fixture)")
            return
        }
        guard let golden = file[architecture] as? [String: [String: String]] else {
            print("SKIPPED: baseline golden digests: none recorded for \(architecture) (AURALISCOPE_RECORD_GOLDEN=1 scripts/test.sh)")
            return
        }
        var differences: [String] = []
        for (scenario, groups) in measured.sorted(by: { $0.key < $1.key }) {
            for (group, digest) in groups.sorted(by: { $0.key < $1.key }) where golden[scenario]?[group] != digest {
                differences.append("\(scenario).\(group): \(golden[scenario]?[group] ?? "missing") → \(digest)")
            }
        }
        try require(differences.isEmpty, "golden pipeline digests changed (recorded with \(file["toolchain.\(architecture)"] ?? "?")):\n  " + differences.joined(separator: "\n  "))
        print("PASS: baseline: \(measured.count) golden pipeline scenarios bit-identical in every snapshot group")
    }

    static func toolchain() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swiftc", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "unknown" }
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").first.map(String.init) ?? "unknown"
    }

    // MARK: - Known issues (Phase 2 P0 validation)

    static func knownIssue(_ id: String, _ text: String) { print("KNOWN ISSUE \(id): \(text)") }

    static func emptyRing(_ ring: OpaquePointer) -> (frames: UInt32, marks: Int) {
        var out = [ChannelFrame](repeating: ChannelFrame(), count: 64)
        var mark = ChannelRingMark()
        var has: Int32 = 0
        var frames: UInt32 = 0, marks = 0
        while true {
            let n = channel_ring_read_marked(ring, &out, 64, &mark, &has)
            if has != 0 { marks += 1; continue }
            if n == 0 { return (frames, marks) }
            frames += n
        }
    }

    /// P0-1 (confirmed). A slice the input callback cannot take, too long for its storage or one that
    /// `AudioUnitRender` refuses (as every slice is while the device's rate differs from the capture format's, the
    /// moment after a device rate change), is dropped with no break mark and no dropped-frame count: the analysis
    /// sees a stall, not a break, and the status bar shows nothing. Intended: each lost slice marks the ring and counts.
    static func knownIssueCaptureRejectsSilently() throws {
        guard let ring = channel_ring_create(1_024) else { throw Failure(description: "ring") }
        defer { channel_ring_destroy(ring) }
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 256)
        defer { storage.deallocate() }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        var unit: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &unit) == noErr, let unit else {
            throw Failure(description: "P0-1 check: no HAL output unit")
        }
        // Never initialised and never started: no audio device is opened, and AudioUnitRender refuses every slice.
        defer { AudioComponentInstanceDispose(unit) }
        var context = CaptureContext()
        context.unit = unit
        context.ring = ring
        context.storage = storage
        context.max_frames = 256
        context.channels = 2
        withUnsafeMutableBytes(of: &context.source_for_role) { raw in
            let roles = raw.bindMemory(to: Int32.self)
            for role in 0..<Role.count { roles[role] = role < 2 ? Int32(role) : -1 }
        }
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        // Too long for the storage.
        let oversize = withUnsafeMutablePointer(to: &context) { capture_input_proc($0, &flags, &time, 1, 512, nil) }
        try require(oversize == kAudioUnitErr_TooManyFramesToProcess, "P0-1: oversize slice status \(oversize)")
        var after = emptyRing(ring)
        try require(after.frames == 0 && after.marks == 0 && channel_ring_dropped(ring) == 0,
                    "P0-1 behaviour changed (oversize): \(after.frames) frames, \(after.marks) marks, \(channel_ring_dropped(ring)) dropped. If this is the fix, assert a mark and a count here and update the maintenance notes.")
        // Refused by AudioUnitRender.
        let refused = withUnsafeMutablePointer(to: &context) { capture_input_proc($0, &flags, &time, 1, 128, nil) }
        try require(refused != noErr, "P0-1: an uninitialised unit rendered")
        after = emptyRing(ring)
        try require(after.frames == 0 && after.marks == 0 && channel_ring_dropped(ring) == 0,
                    "P0-1 behaviour changed (render refused): \(after.frames) frames, \(after.marks) marks, \(channel_ring_dropped(ring)) dropped. If this is the fix, assert a mark and a count here and update the maintenance notes.")
        knownIssue("P0-1", "a capture slice that is too long or that AudioUnitRender refuses (OSStatus \(refused)) is lost with no break mark and no dropped count")
    }

    /// P0-2 (confirmed at unit level; not reachable with this machine's devices, whose IO buffers stop at 4096 frames,
    /// the storage's minimum). In the output tap's multi-stream path, frames beyond the storage are cut off with no
    /// break mark and no count. Intended: the cut is marked and counted, or the storage is sized so it cannot happen.
    static func knownIssueTapTruncatesSilently() throws {
        guard let ring = channel_ring_create(64) else { throw Failure(description: "ring") }
        defer { channel_ring_destroy(ring) }
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 8 * 4)
        defer { storage.deallocate() }
        var context = CaptureContext()
        context.ring = ring
        context.storage = storage
        context.max_frames = 8
        context.channels = 4
        withUnsafeMutableBytes(of: &context.source_for_role) { raw in
            let roles = raw.bindMemory(to: Int32.self)
            for role in 0..<Role.count { roles[role] = role < 4 ? Int32(role) : -1 }
        }
        // Two 2-channel streams of 12 frames each: the multi-stream path, 4 frames more than the storage holds.
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        var a = [Float](repeating: 0.25, count: 24), b = [Float](repeating: 0.5, count: 24)
        try a.withUnsafeMutableBytes { ra in try b.withUnsafeMutableBytes { rb in
            list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 96, mData: ra.baseAddress)
            list[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 96, mData: rb.baseAddress)
            var time = AudioTimeStamp()
            var output = AudioBufferList()
            let status = withUnsafeMutablePointer(to: &context) {
                capture_tap_io_proc(0, &time, list.unsafePointer, &time, &output, &time, UnsafeMutableRawPointer($0))
            }
            try require(status == noErr, "P0-2: tap status \(status)")
        } }
        let after = emptyRing(ring)
        try require(after.frames == 8 && after.marks == 0 && channel_ring_dropped(ring) == 0,
                    "P0-2 behaviour changed: \(after.frames) frames, \(after.marks) marks, \(channel_ring_dropped(ring)) dropped of 12 delivered. If this is the fix, assert a mark and a count here and update the maintenance notes.")
        knownIssue("P0-2", "an output-tap delivery longer than the storage keeps 8 of 12 frames with no break mark and no dropped count")
    }
}
