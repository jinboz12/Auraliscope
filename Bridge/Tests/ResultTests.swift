// Plugin-side analysis and result delivery, without a plugin: the Bridge's StreamAnalyzer against the desktop
// pipeline on identical audio, the RESULT encoding against its specification, and the display-side assembly
// (ordering, gaps, pacing, generations, mono, stereo and immersive buses).
//
// Built and run with the analysis checks: Bridge/scripts/test-analysis.sh

import Foundation

enum ResultChecks {
    private static var failures = 0
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
        print((condition ? "  ok   " : "  FAIL ") + message() + (condition ? "" : " (line \(line))"))
        if !condition { failures += 1 }
    }

    /// The test signal of the transport tests and the harness: channel c at 0.5/(c+1), 997 + 502c Hz (L 997 Hz at
    /// 0.5, R 1499 Hz at 0.25).
    private static func signal(_ channel: Int, _ n: Int, _ rate: Double) -> Float {
        Float(0.5 / Double(channel + 1) * sin(2 * .pi * (997 + 502 * Double(channel)) * Double(n) / rate))
    }

    /// The roles of a VST3 7.1.4 bus (L R C Lfe Ls Rs Sl Sr Tfl Tfr Trl Trr: Ls Rs rear, Sl Sr side).
    static let roles714 = [Role.left, Role.right, Role.center, Role.lfe, Role.leftRearSurround, Role.rightRearSurround,
                           Role.leftSurround, Role.rightSurround, Role.leftTopFront, Role.rightTopFront,
                           Role.leftTopRear, Role.rightTopRear]

    private static func interleaved(channels: Int, start: Int, count: Int, rate: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: channels * count)
        for i in 0..<count { for c in 0..<channels { samples[i * channels + c] = signal(c, start + i, rate) } }
        return samples
    }

    static func run() -> Int {
        equivalence()
        immersiveEquivalence()
        codec()
        immersiveCodec()
        assembly()
        immersiveAssembly()
        lifecycle()
        midStreamStart()
        resetHeldPeakWhileStopped()
        return failures
    }

    /// The Bridge analyses with exactly the desktop's pipeline: fed the same audio in any block sizes, every
    /// snapshot it publishes equals the one the pipeline publishes when fed one tick at a time, as the desktop's DSP
    /// queue is at a steady rate.
    private static func equivalence() {
        print("Plugin-side analysis equals the desktop analysis")
        for (rate, channels) in [(48_000.0, 2), (44_100.0, 1), (96_000.0, 2)] {
            let roles = channels == 1 ? [Role.left] : [Role.left, Role.right]
            let active = (0..<Role.count).map { roles.contains($0) }
            guard let bridge = StreamAnalyzer(sampleRate: rate, channels: channels, generation: 1, formatEpoch: 1),
                  let desktop = MeterPipeline(sampleRate: rate, activeRoles: active,
                                              detector: FormatDetector(initial: channels == 1 ? .mono : .stereo, canDetectSpatial: false),
                                              streamID: 1) else { return check(false, "analysers") }
            let seconds = 6.0
            let total = Int(rate * seconds)
            let audio = interleaved(channels: channels, start: 0, count: total, rate: rate)
            // Bridge: irregular host blocks, as DAWs deliver them.
            let blocks = [37, 512, 1024, 64, 4096, 333, 2048, 128]
            var offset = 0, index = 0
            var bridgeSnapshots: [[Float]] = []
            var lastTicks: UInt64 = 0
            while offset < total {
                let count = min(blocks[index % blocks.count], total - offset)
                audio.withUnsafeBufferPointer { bridge.consume($0.baseAddress! + offset * channels, frames: count, position: UInt64(offset), now: 0) }
                // Several ticks can close within one block; the analyser keeps the newest (what a display would see).
                if bridge.ticks != lastTicks { lastTicks = bridge.ticks; bridgeSnapshots.append(bridge.snapshot) }
                offset += count
                index += 1
            }
            // Desktop: one tick of audio per publish.
            var desktopValues = [Float](repeating: 0, count: SnapshotSlots.total)
            var tick = 0, position = 0, maxDelta: Float = 0, compared = 0, identical = 0
            var worstSlot = -1
            let finalBridge = bridge.snapshot
            while true {
                let end = Int((Double(tick + 1) * rate / MeterPipeline.tickRate).rounded())
                guard end <= total else { break }
                audio.withUnsafeBufferPointer {
                    desktop.consume(interleaved: $0.baseAddress! + position * channels, channels: channels, frames: end - position, roles: roles)
                }
                position = end
                tick += 1
                desktopValues.withUnsafeMutableBufferPointer { desktop.publish(into: $0.baseAddress!, now: Double(tick) / MeterPipeline.tickRate) }
            }
            // The final snapshots describe the same audio and the same number of ticks.
            for slot in 0..<SnapshotSlots.total where slot != SnapshotSlots.stream && slot != SnapshotSlots.sequence {
                let delta = abs(finalBridge[slot] - desktopValues[slot])
                if delta.isNaN || delta > maxDelta { maxDelta = delta.isNaN ? .infinity : delta; worstSlot = slot }
                if finalBridge[slot] == desktopValues[slot] { identical += 1 }
                compared += 1
            }
            // Bit-identical except where a sum is split differently by the host's blocks (the L/R correlation
            // integrator): float rounding only.
            check(bridge.ticks == UInt64(tick) && maxDelta <= 1e-6,
                  String(format: "%.0f Hz %d ch, irregular blocks: %d ticks each; %d of %d values bit-identical, largest difference %g (slot %d)",
                         rate, channels, tick, identical, compared, maxDelta, worstSlot))
            _ = bridgeSnapshots
        }
    }

    /// An immersive bus is analysed exactly as the desktop analyses a device routed to the same roles: every
    /// snapshot value, in Stereo (L and R spectrum) and with the spectrum summing every channel.
    private static func immersiveEquivalence() {
        print("Plugin-side immersive analysis equals the desktop analysis")
        for (rate, roles, spatial) in [(48_000.0, roles714, false), (48_000.0, roles714, true),
                                       (96_000.0, [Role.left, Role.right, Role.center, Role.lfe, Role.leftSurround, Role.rightSurround], true)] {
            let channels = roles.count
            let active = (0..<Role.count).map { roles.contains($0) }
            guard let bridge = StreamAnalyzer(sampleRate: rate, roles: roles, generation: 1, formatEpoch: 1),
                  let desktop = MeterPipeline(sampleRate: rate, activeRoles: active,
                                              detector: FormatDetector(initial: .spatial, canDetectSpatial: true),
                                              streamID: 1) else { return check(false, "analysers") }
            bridge.spatialSpectrum = spatial
            desktop.spatialSpectrum = spatial
            let total = Int(rate * 4)
            let audio = interleaved(channels: channels, start: 0, count: total, rate: rate)
            let blocks = [37, 512, 1024, 64, 4096, 333, 2048, 128]
            var offset = 0, index = 0
            while offset < total {
                let count = min(blocks[index % blocks.count], total - offset)
                audio.withUnsafeBufferPointer { bridge.consume($0.baseAddress! + offset * channels, frames: count, position: UInt64(offset), now: 0) }
                offset += count
                index += 1
            }
            var desktopValues = [Float](repeating: 0, count: SnapshotSlots.total)
            var tick = 0, position = 0
            while true {
                let end = Int((Double(tick + 1) * rate / MeterPipeline.tickRate).rounded())
                guard end <= total else { break }
                audio.withUnsafeBufferPointer {
                    desktop.consume(interleaved: $0.baseAddress! + position * channels, channels: channels, frames: end - position, roles: roles)
                }
                position = end
                tick += 1
                desktopValues.withUnsafeMutableBufferPointer { desktop.publish(into: $0.baseAddress!, now: Double(tick) / MeterPipeline.tickRate) }
            }
            let b = bridge.snapshot
            var maxDelta: Float = 0, worst = -1
            for slot in 0..<SnapshotSlots.total where slot != SnapshotSlots.stream && slot != SnapshotSlots.sequence {
                let delta = abs(b[slot] - desktopValues[slot])
                if delta.isNaN || delta > maxDelta { maxDelta = delta.isNaN ? .infinity : delta; worst = slot }
            }
            check(bridge.ticks == UInt64(tick) && maxDelta <= 1e-6,
                  String(format: "%.0f Hz, %d channels, spectrum of %@: %d ticks; largest difference %g (slot %d)",
                         rate, channels, spatial ? "every channel" : "L and R", tick, maxDelta, worst))
            // Each channel's level is on its role; the roles the bus lacks stay silent.
            let onRoles = roles.enumerated().allSatisfy { c, role in
                abs(b[SnapshotSlots.peaks + role] - Float(0.5 / Double(c + 1))) < 0.001
            }
            let others = (0..<Role.count).filter { !roles.contains($0) }.allSatisfy { b[SnapshotSlots.peaks + $0] == 0 }
            check(onRoles && others, "every channel's peak on its own role, nothing on the others")
            check(b[SnapshotSlots.format] == Float(ChannelFormat.spatial.rawValue),
                  "the format detector reads Immersive (programme on the positional channels)")
            if spatial {
                let banded = roles.allSatisfy { role in (0..<StereoBands.count).contains { b[SnapshotSlots.roleBandPower + role * StereoBands.count + $0] > 0 } }
                check(banded, "every channel's band energy for the immersive soundstage")
            }
        }
        // A bus whose programme is only L and R leaves Immersive (2.5 s of front-only programme), as a device does.
        guard let stereoOnly = StreamAnalyzer(sampleRate: 48_000, roles: roles714, generation: 1, formatEpoch: 1) else {
            return check(false, "analyser")
        }
        var audio = interleaved(channels: 12, start: 0, count: 48_000 * 4, rate: 48_000)
        for i in 0..<(48_000 * 4) { for c in 2..<12 { audio[i * 12 + c] = 0 } }
        audio.withUnsafeBufferPointer { stereoOnly.consume($0.baseAddress!, frames: 48_000 * 4, position: 0, now: 0) }
        check(stereoOnly.snapshot[SnapshotSlots.format] == Float(ChannelFormat.stereo.rawValue),
              "a 7.1.4 bus carrying only L and R reads Stereo after its release time")
        // Roles a bus cannot have are refused.
        check(StreamAnalyzer(sampleRate: 48_000, roles: [Role.left, Role.left, Role.center], generation: 1, formatEpoch: 1) == nil
                  && StreamAnalyzer(sampleRate: 48_000, roles: [Role.center], generation: 1, formatEpoch: 1) == nil
                  && StreamAnalyzer(sampleRate: 48_000, roles: [Role.leftSurround, Role.rightSurround], generation: 1, formatEpoch: 1) == nil
                  && StreamAnalyzer(sampleRate: 48_000, roles: [Role.left, Role.right, 16], generation: 1, formatEpoch: 1) == nil
                  && StreamAnalyzer(sampleRate: 48_000, roles: Array(0..<16), generation: 1, formatEpoch: 1) != nil,
              "repeated, unknown or L-less roles are refused; all 16 roles (9.1.6) are taken")
    }

    /// An immersive RESULT carries every channel on its role, and a display reads each channel back by role.
    private static func immersiveCodec() {
        print("Immersive RESULT encoding")
        guard let a = StreamAnalyzer(sampleRate: 48_000, roles: roles714, generation: 3, formatEpoch: 9) else { return check(false, "analyser") }
        a.spatialSpectrum = true
        let audio = interleaved(channels: 12, start: 0, count: 48_000 * 2, rate: 48_000)
        audio.withUnsafeBufferPointer { a.consume($0.baseAddress!, frames: 48_000 * 2, position: 0, now: 0) }
        // The plugin's mailbox (BridgeCore's kMailboxBytes): the largest Immersive result must fit it.
        var buffer = [UInt8](repeating: 0, count: 192 * 1024)
        let encoded = buffer.withUnsafeMutableBytes {
            a.encode(into: $0.baseAddress!, capacity: $0.count, subscription: 5, layout: 3, afterSpectrogram: 0, afterWaveform: 0)
        }
        let m = buffer.withUnsafeBytes { ResultMessage.decode(UnsafeRawBufferPointer(rebasing: $0[0..<encoded.bytes])) }
        let v = a.snapshot
        check(encoded.bytes > 0 && m.valid && m.rejectedFields == 0 && m.channels == 12 && m.layout == 3 && m.roles == roles714
                  && m.channelRoles == roles714,
              "12 channels, layout 3 (speakers), their roles: a \(encoded.bytes)-byte payload (24 spectrogram and 256 waveform columns)")
        check(m.peak == roles714.map { v[SnapshotSlots.peaks + $0] } && m.heldTruePeak == roles714.map { v[SnapshotSlots.heldTruePeaks + $0] }
                  && m.rms == roles714.map { v[SnapshotSlots.rms + $0] },
              "per-channel levels in the bus's order, each its role's value")
        check(m.waveformColumns == 256 && m.waveform.count == 256 * 12 * 2 && m.bandPower.count == 12 * StereoBands.count,
              "waveform columns and band energy for all 12 channels")
        check(m.spectrumChannels == 1 && m.detectedFormat == UInt32(ChannelFormat.spatial.rawValue),
              "the result says the spectrum sums every channel and the programme is Immersive")
        // A display reading roles that do not fit the channels shows nothing of it.
        var wrong = m
        wrong.roles = Array(roles714.prefix(11))
        check(!wrong.valid, "roles of another channel count: not shown")
        wrong = m
        wrong.roles[3] = Role.left
        check(!wrong.valid, "a repeated role: not shown")
        wrong = m
        wrong.roles = []
        check(!wrong.valid, "more than two channels without roles: not shown")
        var old = m
        old.channels = 2
        old.roles = []
        old.peak = [0.5, 0.25]; old.rms = old.peak; old.truePeak = old.peak; old.heldPeak = old.peak; old.heldTruePeak = old.peak
        old.waveform = []
        check(old.valid && old.channelRoles == [Role.left, Role.right], "a plugin before build 77 (no roles): stereo is L, R")
        // The spatial field (tag 53): the display's snapshot gets the plugin's field, within the wire's quantisation.
        let field = Array(v[SnapshotSlots.spatialField..<(SnapshotSlots.spatialField + SpatialField.floats)])
        check(field[SpatialField.status] == 1 && m.spatialField?.count == field.withUnsafeBufferPointer {
                  SpatialFieldWire.size($0.baseAddress!, channels: 12) },
              "an Immersive result carries the spatial field (\(m.spatialField?.count ?? 0) bytes for 12 channels)")
        let assembler = ResultAssembler()
        check(assembler.receive(m, source: 1) && assembler.publish(), "the result is assembled")
        // Signal health (tags 55–57): each channel's DC offset and infrasonic energy reach the display on its role.
        check(m.dcOffset == roles714.map { v[SnapshotSlots.dcOffset + $0] } && m.infrasonic == roles714.map { v[SnapshotSlots.infrasonic + $0] }
                  && roles714.allSatisfy { assembler.values[SnapshotSlots.dcOffset + $0] == v[SnapshotSlots.dcOffset + $0]
                                           && assembler.values[SnapshotSlots.infrasonic + $0] == v[SnapshotSlots.infrasonic + $0] }
                  && assembler.values[SnapshotSlots.healthStatus] == 1 && v[SnapshotSlots.healthStatus] == 1,
              "DC offset and infrasonic energy per channel, settled after 2 s, carried to the display")
        var before89 = m
        before89.dcOffset = []; before89.infrasonic = []
        let olderAssembler = ResultAssembler()
        check(olderAssembler.receive(before89, source: 1) && olderAssembler.publish()
                  && olderAssembler.values[SnapshotSlots.healthStatus] == 0,
              "a plugin before build 90 (no signal health): the display reads it as not measured")
        let shown = Array(assembler.values[SnapshotSlots.spatialField..<(SnapshotSlots.spatialField + SpatialField.floats)])
        var worstDB: Float = 0, worstPosition: Float = 0, missing = 0
        for band in 0..<SpatialField.bandCount {
            for role in roles714 {
                let sent = field[SpatialField.independent(band: band, role: role)], got = shown[SpatialField.independent(band: band, role: role)]
                if sent > 1e-12 { worstDB = max(worstDB, abs(10 * log10(got / sent))) } else if got > 1e-12 { missing += 1 }
            }
            for slot in 0..<SpatialField.coherentSlots {
                let o = SpatialField.component(band: band, slot: slot)
                guard field[o] > 1e-12 else { continue }
                worstDB = max(worstDB, abs(10 * log10(shown[o] / field[o])))
                for i in 1...3 { worstPosition = max(worstPosition, abs(shown[o + i] - field[o + i])) }
            }
        }
        check(shown[SpatialField.status] == 1 && worstDB <= 0.26 && worstPosition <= 0.005 && missing == 0,
              String(format: "every energy within %.2f dB and every image within %.4f radii of the plugin's", worstDB, worstPosition))
        // Its bins (tag 54): the display's snapshot gets the plugin's, within the wire's quantisation.
        let points = Array(v[SnapshotSlots.spatialPoints..<(SnapshotSlots.spatialPoints + SpatialPoints.floats)])
        let gotPoints = Array(assembler.values[SnapshotSlots.spatialPoints..<(SnapshotSlots.spatialPoints + SpatialPoints.floats)])
        var sentPoints = 0, worstPoint: Float = 0, worstPointDB: Float = 0, countsMatch = true
        for band in 0..<SpatialField.bandCount {
            // Points below the wire's floor (−127 dB) are left out.
            let kept = (0..<Int(points[SpatialPoints.count(band: band)])).map { SpatialPoints.point(band: band, index: $0) }
                .filter { SpatialFieldWire.energyCode(points[$0 + 3]) > 0 }
            countsMatch = countsMatch && Int(gotPoints[SpatialPoints.count(band: band)]) == kept.count
            sentPoints += kept.count
            for (index, o) in kept.enumerated() where countsMatch {
                let g = SpatialPoints.point(band: band, index: index)
                for i in 0..<3 { worstPoint = max(worstPoint, abs(gotPoints[g + i] - points[o + i])) }
                worstPointDB = max(worstPointDB, abs(10 * log10(gotPoints[g + 3] / points[o + 3])))
            }
        }
        check(points[SpatialPoints.status] == 1 && sentPoints > 0
                  && m.spatialPoints?.count == points.withUnsafeBufferPointer { SpatialPointsWire.size($0.baseAddress!) },
              "an Immersive result carries the bins (\(sentPoints) points, \(m.spatialPoints?.count ?? 0) bytes)")
        check(gotPoints[SpatialPoints.status] == 1 && countsMatch && worstPoint <= 0.0001 && worstPointDB <= 0.26,
              String(format: "every bin within %.5f radii and %.2f dB of the plugin's", worstPoint, worstPointDB))
        // A plugin before build 87 sends the field without its bins: the display draws from the field's statistics.
        var noBins = m
        noBins.spatialPoints = nil
        let statistics = ResultAssembler()
        _ = statistics.receive(noBins, source: 1)
        _ = statistics.publish()
        check(statistics.values[SnapshotSlots.spatialField + SpatialField.status] == 1
                  && statistics.values[SnapshotSlots.spatialPoints + SpatialPoints.status] == 0,
              "a result without the bins (a plugin before build 87) keeps its field and has no bins")
        // A plugin before build 80 sends no field while analysing every channel: the display is told so.
        var older = m
        older.spatialField = nil
        older.spatialPoints = nil
        let fallback = ResultAssembler()
        _ = fallback.receive(older, source: 1)
        _ = fallback.publish()
        check(fallback.values[SnapshotSlots.spatialField + SpatialField.status] == SpatialFieldWire.unsupported,
              "a result without the field (an older plugin) is marked so the display falls back to channel energy")
        // Without Immersive (only L and R analysed) nothing is sent.
        a.spatialSpectrum = false
        audio.withUnsafeBufferPointer { a.consume($0.baseAddress!, frames: 4_800, position: UInt64(48_000 * 2), now: 0) }
        let stereo = buffer.withUnsafeMutableBytes {
            a.encode(into: $0.baseAddress!, capacity: $0.count, subscription: 5, layout: 3, afterSpectrogram: 0, afterWaveform: 0)
        }
        let s = buffer.withUnsafeBytes { ResultMessage.decode(UnsafeRawBufferPointer(rebasing: $0[0..<stereo.bytes])) }
        check(s.valid && s.spatialField == nil && s.spatialPoints == nil, "a Stereo subscription carries no spatial field or bins")
    }

    /// A RESULT carries what its specification says, and a receiver reads it back without the sender's types.
    private static func codec() {
        print("RESULT encoding")
        guard let a = StreamAnalyzer(sampleRate: 48_000, channels: 2, generation: 7, formatEpoch: 3) else { return check(false, "analyser") }
        let audio = interleaved(channels: 2, start: 0, count: 48_000 * 4, rate: 48_000)
        audio.withUnsafeBufferPointer { a.consume($0.baseAddress!, frames: 48_000 * 4, position: 1000, now: 0) }
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        let encoded = buffer.withUnsafeMutableBytes {
            a.encode(into: $0.baseAddress!, capacity: $0.count, subscription: 42, layout: 2, afterSpectrogram: 0, afterWaveform: 0)
        }
        let m = buffer.withUnsafeBytes { ResultMessage.decode(UnsafeRawBufferPointer(rebasing: $0[0..<encoded.bytes])) }
        let v = a.snapshot
        check(encoded.bytes > 0 && encoded.bytes % 4 == 0 && m.valid && !m.malformed && m.rejectedFields == 0,
              "a \(encoded.bytes)-byte payload of whole, aligned fields decodes as valid")
        check(m.subscription == 42 && m.schema == 1 && m.generation == 7 && m.formatEpoch == 3 && m.sampleRate == 48_000
                  && m.channels == 2 && m.layout == 2 && m.tick == 240 && m.framesAnalysed == 192_000 && m.timelineEnd == 193_000,
              "identity and timing: subscription, schema, generation, epoch, rate, channels, 240 ticks, frames and timeline")
        check(m.peak == [v[SnapshotSlots.peaks], v[SnapshotSlots.peaks + 1]] && m.heldTruePeak == [v[SnapshotSlots.heldTruePeaks], v[SnapshotSlots.heldTruePeaks + 1]]
                  && m.integrated == v[SnapshotSlots.integrated] && m.momentary == v[SnapshotSlots.momentary]
                  && m.loudnessRange == v[SnapshotSlots.range],
              "levels and loudness equal the analyser's values exactly (integrated \(m.integrated) LUFS)")
        check(m.spectrum == Array(v[SnapshotSlots.spectrum..<(SnapshotSlots.spectrum + 64)])
                  && m.spectrumFine == Array(v[SnapshotSlots.spectrumFine..<(SnapshotSlots.spectrumFine + MeterSnapshot.fineBandCount)])
                  && m.bandPoints == Array(v[SnapshotSlots.bandPoints..<(SnapshotSlots.bandPoints + StereoBands.scopeFloats)])
                  && m.correlation == v[SnapshotSlots.correlation] && m.notes.count == 12,
              "spectrum, fine spectrum, stereometer points, correlation and notes carried in full")
        check(m.spectrogramFirst == m.spectrogramLatest - UInt64(StreamAnalyzer.spectrogramCapacity) + 1 && m.spectrogramColumns == 24
                  && m.waveformFirst == m.waveformLatest - UInt64(StreamAnalyzer.waveformCapacity) + 1 && m.waveformColumns == 256,
              "a new receiver starts from the oldest columns held (spectrogram \(m.spectrogramFirst) of \(m.spectrogramLatest), waveform \(m.waveformFirst) of \(m.waveformLatest)), at most 24 and 256 per result")
        check(m.spectrogramMode == SpectrogramMode.classic.rawValue, "the columns say which analysis made them (Classic by default)")
        // A display asking for Enhanced gets reassigned columns from then on, and the result says so.
        a.spectrogramMode = .enhanced
        let more = interleaved(channels: 2, start: 48_000 * 4, count: 4_800, rate: 48_000)
        more.withUnsafeBufferPointer { a.consume($0.baseAddress!, frames: 4_800, position: 1000 + 192_000, now: 4) }
        let enhanced = buffer.withUnsafeMutableBytes {
            a.encode(into: $0.baseAddress!, capacity: $0.count, subscription: 42, layout: 2, afterSpectrogram: m.spectrogramLatest, afterWaveform: 0)
        }
        let e = buffer.withUnsafeBytes { ResultMessage.decode(UnsafeRawBufferPointer(rebasing: $0[0..<enhanced.bytes])) }
        check(e.valid && e.spectrogramMode == SpectrogramMode.enhanced.rawValue && a.snapshot[SnapshotSlots.spectrogramMode] == 1,
              "Enhanced chosen: the new columns are reassigned, and tag 65 and the snapshot say so")
        a.spectrogramMode = .classic
        // The next result carries only what is new.
        audio.withUnsafeBufferPointer { a.consume($0.baseAddress!, frames: 800, position: 193_000, now: 0) }
        let next = buffer.withUnsafeMutableBytes {
            a.encode(into: $0.baseAddress!, capacity: $0.count, subscription: 42, layout: 2,
                     afterSpectrogram: encoded.spectrogramThrough, afterWaveform: encoded.waveformThrough)
        }
        let n = buffer.withUnsafeBytes { ResultMessage.decode(UnsafeRawBufferPointer(rebasing: $0[0..<next.bytes])) }
        check(n.waveformFirst == encoded.waveformThrough + 1 && n.spectrogramFirst == encoded.spectrogramThrough + 1
                  && n.spectrogramDropped == 0 && n.waveformDropped == 0,
              "the next result continues each series where the last one stopped (waveform from \(n.waveformFirst), spectrogram from \(n.spectrogramFirst))")

        // Robustness: unknown fields are skipped; malformed ones end the payload; wrong kinds are ignored.
        var extended = Array(buffer[0..<next.bytes])
        extended += [0xE7, 0x03, 2, 0, 1, 0, 0, 0, 9, 9, 9, 9]   // tag 999, u32 1: a later schema's field
        let withUnknown = extended.withUnsafeBytes { ResultMessage.decode($0) }
        check(withUnknown.valid && withUnknown.rejectedFields == 0, "an unknown field is skipped")
        var truncated = Array(buffer[0..<next.bytes])
        truncated += [0x14, 0, 5, 0, 200, 0, 0, 0, 1, 2, 3, 4]   // tag 20 claiming 200 floats with 4 bytes present
        let cut = truncated.withUnsafeBytes { ResultMessage.decode($0) }
        check(cut.malformed && !cut.valid, "a field that runs past the payload makes it malformed (not used)")
        var wrongKind = Array(buffer[0..<next.bytes])
        wrongKind += [0x20, 0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0]     // integrated (32) as u32: the wrong kind
        let kind = wrongKind.withUnsafeBytes { ResultMessage.decode($0) }
        check(kind.rejectedFields == 1 && kind.integrated == n.integrated, "a known field of the wrong kind is ignored")
        var other = n
        other.schema = 2
        check(!other.valid, "another analysis schema is not shown as this one")
        other = n
        other.peak = [0.5]
        check(!other.valid, "per-channel values must match the channel count")
    }

    private static func message(generation: UInt32 = 1, channels: Int = 2, spectrogram: [UInt64] = [], waveform: [UInt64] = [],
                                level: Float = 0.5) -> ResultMessage {
        var m = ResultMessage()
        m.schema = 1
        m.generation = generation
        m.sampleRate = 48_000
        m.channels = channels
        m.peak = [Float](repeating: level, count: channels)
        m.rms = m.peak
        m.truePeak = m.peak
        m.heldPeak = m.peak
        m.heldTruePeak = m.peak
        m.integrated = -10
        if let first = spectrogram.first {
            m.spectrogramFirst = first
            m.spectrogram = spectrogram.flatMap { serial in [Float](repeating: -Float(serial), count: ResultMessage.spectrogramRows) }
        }
        if let first = waveform.first {
            m.waveformFirst = first
            m.waveform = waveform.flatMap { serial in (0..<(channels * 2)).map { k in Float(serial) + Float(k) / 10 } }
        }
        return m
    }

    /// Results back into the snapshots the displays read.
    private static func assembly() {
        print("Display assembly")
        let a = ResultAssembler()
        check(a.receive(message(spectrogram: [1, 2, 3], waveform: [1, 2, 3, 4]), source: 1), "a result is taken")
        check(a.publish(), "…and published")
        var v = a.values
        let stream = v[SnapshotSlots.stream]
        check(v[SnapshotSlots.peaks] == 0.5 && v[SnapshotSlots.peaks + 1] == 0.5 && v[SnapshotSlots.peaks + 2] == 0
                  && v[SnapshotSlots.integrated] == -10,
              "stereo levels land on L and R, nothing on other roles")
        check(v[SnapshotSlots.spectrogramSerial] == 1 && v[SnapshotSlots.spectrogram] == -1, "one spectrogram column per tick (serial 1 first)")
        a.publish()
        a.publish()
        v = a.values
        check(v[SnapshotSlots.spectrogramSerial] == 3 && v[SnapshotSlots.spectrogram] == -3, "…in order, one per tick")
        check(a.publish() == false, "nothing new: nothing published")
        let wave = WaveformEnvelope.publishedColumns - 1
        check(v[SnapshotSlots.waveSerial] == 4 && v[SnapshotSlots.waveform + wave * WaveformEnvelope.valuesPerColumn] == 4
                  && v[SnapshotSlots.waveform + wave * WaveformEnvelope.valuesPerColumn + 3] == 4.3,
              "waveform columns enter the display window newest last, L (min, max) then R")
        // Replayed and older columns are ignored; a gap leaves blanks.
        a.receive(message(spectrogram: [2, 3]), source: 1)
        check(!a.hasPending || a.publish() && a.values[SnapshotSlots.spectrogramSerial] == 3, "columns already shown are not shown again")
        a.receive(message(spectrogram: [6], waveform: [7]), source: 1)
        a.publish()
        v = a.values
        check(v[SnapshotSlots.spectrogram] == -120 && a.spectrogramGaps == 2 && a.waveformGaps == 2,
              "a gap of 2 leaves 2 blank columns in each series")
        a.publish(); a.publish()
        check(a.values[SnapshotSlots.spectrogram] == -6, "…then the next real column")
        check(a.values[SnapshotSlots.stream] == stream, "the same generation stays one stream")
        // A backlog is skipped down to a short queue so the waterfall stays current.
        a.receive(message(spectrogram: Array(7...40)), source: 1)
        a.publish()
        check(a.spectrogramSkipped == UInt64(34 - ResultAssembler.spectrogramLag),
              "a burst of 34 columns keeps the newest \(ResultAssembler.spectrogramLag) (\(a.spectrogramSkipped) skipped for latency)")
        // Bounded while nobody publishes (a paused display): only what could still be shown is kept.
        let idle = ResultAssembler()
        for n in 0..<200 {
            idle.receive(message(spectrogram: [UInt64(n + 1)], waveform: (0..<8).map { UInt64(n * 8 + $0 + 1) }), source: 1)
        }
        check(idle.spectrogramSkipped == UInt64(200 - ResultAssembler.spectrogramLag)
                  && idle.waveformSkipped == UInt64(1600 - StreamAnalyzer.waveformCapacity),
              "with no display reading, the queues stay bounded (\(ResultAssembler.spectrogramLag) and \(StreamAnalyzer.waveformCapacity) columns)")
        // A new generation is a new stream: histories clear.
        a.receive(message(generation: 2, spectrogram: [1]), source: 1)
        a.publish()
        check(a.values[SnapshotSlots.stream] != stream && a.values[SnapshotSlots.spectrogramSerial] == 1,
              "a new generation starts a new stream for the displays")
        // Fine spectrum bands: taken as sent, or, from a plugin that sends only the 64 bands, each band's two halves.
        var fine = message()
        fine.spectrum = (0..<MeterSnapshot.bandCount).map { -Float($0) }
        let older = ResultAssembler()
        older.receive(fine, source: 1)
        older.publish()
        check((0..<MeterSnapshot.fineBandCount).allSatisfy { older.values[SnapshotSlots.spectrumFine + $0] == -Float($0 / 2) },
              "a result without fine bands shows each of the 64 bands across its two halves")
        fine.generation = 3
        fine.spectrumFine = (0..<MeterSnapshot.fineBandCount).map { -Float($0) / 4 }
        let newer = ResultAssembler()
        newer.receive(fine, source: 1)
        newer.publish()
        check((0..<MeterSnapshot.fineBandCount).allSatisfy { newer.values[SnapshotSlots.spectrumFine + $0] == -Float($0) / 4 },
              "fine bands are shown as sent")
        // Mono: channel 1 is L; R stays silent.
        let mono = ResultAssembler()
        mono.receive(message(channels: 1, waveform: [1]), source: 1)
        mono.publish()
        check(mono.values[SnapshotSlots.peaks] == 0.5 && mono.values[SnapshotSlots.peaks + 1] == 0
                  && mono.values[SnapshotSlots.waveform + wave * WaveformEnvelope.valuesPerColumn + 2] == 0,
              "mono lands on L only")
        // An invalid result changes nothing.
        var bad = message()
        bad.peak = [1, 1, 1]
        check(!mono.receive(bad, source: 1) && mono.rejected == 1, "an invalid result is rejected")
        // Silence after the source goes quiet keeps what was measured.
        mono.silenceTransients()
        mono.publish()
        check(mono.values[SnapshotSlots.peaks] == 0 && mono.values[SnapshotSlots.integrated] == -10,
              "going quiet silences the instantaneous readings and keeps integrated loudness")
    }

    /// Immersive results back into snapshots: each channel's levels, waveform and band energy on its own role, and
    /// the plugin's Stereo ↔ Immersive reading passed on to the display's Auto mode.
    private static func immersiveAssembly() {
        print("Immersive display assembly")
        var m = message(channels: 12, waveform: [1])
        m.roles = roles714
        m.peak = (0..<12).map { Float($0 + 1) / 100 }
        m.rms = m.peak; m.truePeak = m.peak; m.heldPeak = m.peak; m.heldTruePeak = m.peak
        m.bandPower = (0..<(12 * StereoBands.count)).map { Float($0) }
        m.detectedFormat = UInt32(ChannelFormat.spatial.rawValue)
        let a = ResultAssembler()
        check(a.receive(m, source: 1) && a.publish(), "a 12-channel result is taken and published")
        let v = a.values
        check(roles714.enumerated().allSatisfy { c, role in v[SnapshotSlots.peaks + role] == Float(c + 1) / 100 }
                  && v[SnapshotSlots.peaks + Role.leftWide] == 0 && v[SnapshotSlots.peaks + Role.leftTopMiddle] == 0,
              "levels land on their roles (side surrounds on Ls/Rs, rear on Lrs/Rrs, heights on Ltf/Rtf/Ltr/Rtr), nothing on the rest")
        let wave = (WaveformEnvelope.publishedColumns - 1) * WaveformEnvelope.valuesPerColumn
        check(roles714.enumerated().allSatisfy { c, role in
                  v[SnapshotSlots.waveform + wave + role * 2] == m.waveform[c * 2] && v[SnapshotSlots.waveform + wave + role * 2 + 1] == m.waveform[c * 2 + 1]
              },
              "waveform columns land on their roles")
        check(roles714.enumerated().allSatisfy { c, role in
                  (0..<StereoBands.count).allSatisfy { v[SnapshotSlots.roleBandPower + role * StereoBands.count + $0] == m.bandPower[c * StereoBands.count + $0] }
              },
              "band energy lands on its role (the immersive soundstage reads it)")
        check(v[SnapshotSlots.format] == Float(ChannelFormat.spatial.rawValue), "the plugin's Immersive reading reaches Auto")
        m.detectedFormat = UInt32(ChannelFormat.stereo.rawValue)
        a.receive(m, source: 1)
        a.publish()
        check(a.values[SnapshotSlots.format] == Float(ChannelFormat.stereo.rawValue), "…and its Stereo reading")
        a.silenceTransients()
        a.publish()
        check(roles714.allSatisfy { a.values[SnapshotSlots.peaks + $0] == 0 }, "going quiet silences every channel")
    }

    /// True peak of a stream that starts in the middle of a waveform (a reset, a capture started while playing):
    /// both pipelines must agree with the known analytic crest, not just with each other.
    private static func midStreamStart() {
        print("Stream starting mid-waveform")
        for start in [0, 12_345, 777] {
            guard let bridge = StreamAnalyzer(sampleRate: 48_000, channels: 2, generation: 1, formatEpoch: 1),
                  let desktop = MeterPipeline(sampleRate: 48_000, activeRoles: (0..<Role.count).map { $0 < 2 },
                                              detector: FormatDetector(), streamID: 1) else { return check(false, "analysers") }
            let audio = interleaved(channels: 2, start: start, count: 48_000 * 2, rate: 48_000)
            audio.withUnsafeBufferPointer { bridge.consume($0.baseAddress!, frames: 96_000, position: 0, now: 0) }
            var values = [Float](repeating: 0, count: SnapshotSlots.total)
            var position = 0
            for tick in 0..<120 {
                audio.withUnsafeBufferPointer {
                    desktop.consume(interleaved: $0.baseAddress! + position * 2, channels: 2, frames: 800, roles: [0, 1])
                }
                position += 800
                values.withUnsafeMutableBufferPointer { desktop.publish(into: $0.baseAddress!, now: Double(tick) / 60) }
            }
            let b = bridge.snapshot
            check(abs(b[SnapshotSlots.heldTruePeaks] - 0.5) < 0.0003
                      && abs(b[SnapshotSlots.heldTruePeaks + 1] - 0.25) < 0.00015,
                  "start at sample \(start): no synthetic onset overshoot")
            func db(_ v: Float) -> Double { 20 * log10(Double(v)) }
            print(String(format: "  info start %6d: held true peak L %.3f R %.3f dBTP (sample peaks -6.021, -12.041)",
                         start, db(b[SnapshotSlots.heldTruePeaks]), db(b[SnapshotSlots.heldTruePeaks + 1])))
            check(b[SnapshotSlots.heldTruePeaks] == values[SnapshotSlots.heldTruePeaks]
                      && b[SnapshotSlots.heldTruePeaks + 1] == values[SnapshotSlots.heldTruePeaks + 1],
                  "start at sample \(start): plugin and desktop hold the same true peak")
        }
    }

    private static func resetHeldPeakWhileStopped() {
        print("Reset true peak without a new audio tick")
        for paused in [false, true] {
            guard let a = StreamAnalyzer(sampleRate: 48_000, channels: 2, generation: 1, formatEpoch: 1) else {
                return check(false, "analyser")
            }
            let audio = interleaved(channels: 2, start: 777, count: 48_000, rate: 48_000)
            audio.withUnsafeBufferPointer { a.consume($0.baseAddress!, frames: 48_000, position: 0, now: 0) }
            if paused { a.setMeasuring(false) }
            else { for n in 1...60 { a.idle(now: Double(n) / 60) } }
            let before = a.snapshot, ticks = a.ticks, frames = a.framesAnalysed
            check(before[SnapshotSlots.heldTruePeaks] > 0.49, "a peak was held before reset")
            a.resetTruePeaks()
            var expected = before
            for role in 0..<Role.count { expected[SnapshotSlots.heldTruePeaks + role] = 0 }
            check(a.snapshot == expected && a.ticks == ticks && a.framesAnalysed == frames,
                  "reset while \(paused ? "paused" : "idle"): immediately clears only held true peaks")
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 131_072, alignment: 8)
            defer { buffer.deallocate() }
            let encoded = a.encode(into: buffer, capacity: 131_072, subscription: 1, layout: 2,
                                   afterSpectrogram: 0, afterWaveform: 0)
            let decoded = ResultMessage.decode(UnsafeRawBufferPointer(start: buffer, count: encoded.bytes))
            check(decoded.heldTruePeak == [0, 0], "the next wire result carries the reset without new audio")
        }
    }

    /// Measurement pause, breaks and idle ticks in the plugin's analyser.
    private static func lifecycle() {
        print("Measurement lifecycle")
        guard let a = StreamAnalyzer(sampleRate: 48_000, channels: 2, generation: 1, formatEpoch: 1) else { return check(false, "analyser") }
        let audio = interleaved(channels: 2, start: 0, count: 48_000 * 2, rate: 48_000)
        audio.withUnsafeBufferPointer { a.consume($0.baseAddress!, frames: 48_000, position: 0, now: 1) }
        let integrated = a.snapshot[SnapshotSlots.integrated]
        a.setMeasuring(false)
        audio.withUnsafeBufferPointer { a.consume($0.baseAddress! + 96_000, frames: 48_000, position: 48_000, now: 2) }
        check(a.framesAnalysed == 48_000 && a.timelineEnd == 96_000 && !a.idle(now: 5),
              "paused: nothing accumulates (the timeline still advances), and no idle ticks")
        a.setMeasuring(true)
        audio.withUnsafeBufferPointer { a.consume($0.baseAddress!, frames: 48_000, position: 96_000, now: 3) }
        check(a.framesAnalysed == 96_000 && a.snapshot[SnapshotSlots.breaks] == 0 && abs(a.snapshot[SnapshotSlots.integrated] - integrated) < 0.01,
              "resumed: carries on without a break (the release's Pause semantics)")
        a.interrupt(lostFrames: 4_800, idleMilliseconds: 0, reasons: UInt32(1 << 9))
        check(a.snapshot[SnapshotSlots.breaks] == 0, "a break takes effect with the next tick")
        audio.withUnsafeBufferPointer { a.consume($0.baseAddress!, frames: 800, position: 148_800, now: 3.1) }
        check(a.snapshot[SnapshotSlots.breaks] == 1 && abs(a.snapshot[SnapshotSlots.missing] - 0.1) < 0.001 && a.lastBreakReasons == 1 << 9,
              "…counted, with 0.1 s missing and its reasons")
        let ticks = a.ticks
        var idle = 0
        for step in 1...60 where a.idle(now: 3.1 + Double(step) / 60) { idle += 1 }
        check(idle == StreamAnalyzer.idleTicks && a.ticks == ticks + UInt64(idle) && a.snapshot[SnapshotSlots.peaks] == 0,
              "with no audio it ticks \(idle) times, the meters fall to silence, then it rests")
    }
}
