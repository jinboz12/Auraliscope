import CoreGraphics
import Foundation
import Darwin
import AudioRing

final class CoreTests {
    func testLocalizerKeepsTermsAndUnitsTogether() {
        let nbsp = "\u{00A0}"
        checkEqual(Localizer.typeset("立体声与 Dolby Atmos 之间切换"), "立体声与 Dolby\(nbsp)Atmos 之间切换")
        checkEqual(Localizer.typeset("above −60 dBFS for 150 ms, back after 2.5 s"),
                   "above −60\(nbsp)dBFS for 150\(nbsp)ms, back after 2.5\(nbsp)s")
        checkEqual(Localizer.typeset("0 VU (%@ dBFS) · %d ch · True Peak"), "0\(nbsp)VU (%@\(nbsp)dBFS) · %d\(nbsp)ch · True\(nbsp)Peak")
        checkEqual(Localizer.typeset("最近 8 秒，最多 64 路输入"), "最近 8\(nbsp)秒，最多 64\(nbsp)路输入")
        // Words that merely begin like a unit keep an ordinary, breakable space.
        checkEqual(Localizer.typeset("8 seconds, 16 channels"), "8 seconds, 16 channels")
    }

    func testRingWrapAndOverflow() throws {
        let ring = try unwrap(audio_ring_create(4))
        defer { audio_ring_destroy(ring) }
        let input: [Float] = [1, -1, 2, -2, 3, -3, 4, -4, 5, -5]
        checkEqual(audio_ring_write(ring, input, 5, 2), 4)
        checkEqual(audio_ring_dropped(ring), 1)
        var output = [StereoFrame](repeating: StereoFrame(left: 0, right: 0), count: 4)
        checkEqual(audio_ring_read(ring, &output, 2), 2)
        checkEqual(output[0].left, 1)
        checkEqual(output[1].right, -2)
        checkEqual(audio_ring_write(ring, [6, -6, 7, -7], 2, 2), 2)
        checkEqual(audio_ring_read(ring, &output, 4), 4)
        checkEqual(output.map(\.left), [3, 4, 6, 7])
        checkEqual(output.map(\.right), [-3, -4, -6, -7])
        checkEqual(audio_ring_read(ring, &output, 1), 0)
    }

    func testMonoAndClear() throws {
        let ring = try unwrap(audio_ring_create(8))
        defer { audio_ring_destroy(ring) }
        checkEqual(audio_ring_write(ring, [0.2, -0.4], 2, 1), 2)
        var output = [StereoFrame](repeating: StereoFrame(left: 0, right: 0), count: 2)
        checkEqual(audio_ring_read(ring, &output, 2), 2)
        checkEqual(output[0].left, output[0].right)
        checkEqual(output[1].right, -0.4, accuracy: 0.000001)
        _ = audio_ring_write(ring, [1, 2], 2, 1)
        audio_ring_clear(ring)
        checkEqual(audio_ring_read(ring, &output, 2), 0)
    }

    func testExchangeKeepsLatestWithoutTearing() throws {
        let exchange = try unwrap(meter_exchange_create())
        defer { meter_exchange_destroy(exchange) }
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var values = [Float](repeating: 0, count: Int(METER_SNAPSHOT_FLOATS))
            for generation in 1...100_000 {
                for index in values.indices { values[index] = Float(generation) }
                meter_exchange_publish(exchange, values)
            }
            done.leave()
        }
        var result = [Float](repeating: 0, count: Int(METER_SNAPSHOT_FLOATS))
        var latest: Float = 0
        let deadline = Date().addingTimeInterval(10)
        while latest < 100_000 && Date() < deadline {
            if meter_exchange_read(exchange, &result) != 0 {
                checkGreaterOrEqual(result[0], latest)
                checkTrue(result.allSatisfy { $0 == result[0] })
                latest = result[0]
            }
        }
        done.wait()
        checkEqual(latest, 100_000)
        checkEqual(meter_exchange_read(exchange, &result), 0)
    }

    func testConcurrentAudioRingPreservesOrder() throws {
        let ring = try unwrap(audio_ring_create(1024))
        defer { audio_ring_destroy(ring) }
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var input = [Float](repeating: 0, count: 64)
            for block in 0..<10_000 {
                for i in 0..<32 {
                    input[i * 2] = Float(block * 32 + i + 1)
                    input[i * 2 + 1] = -input[i * 2]
                }
                _ = audio_ring_write(ring, input, 32, 2)
            }
            done.leave()
        }
        var batch = [StereoFrame](repeating: StereoFrame(left: 0, right: 0), count: 113)
        var previous: Float = 0
        var received: UInt64 = 0
        while true {
            let count = audio_ring_read(ring, &batch, 113)
            for i in 0..<Int(count) {
                checkGreater(batch[i].left, previous)
                checkEqual(batch[i].left, -batch[i].right)
                previous = batch[i].left
            }
            received += UInt64(count)
            if count == 0 && done.wait(timeout: .now()) == .success {
                // Read once more: producer may have published after the empty read.
                let remainder = audio_ring_read(ring, &batch, 113)
                received += UInt64(remainder)
                if remainder == 0 { break }
                previous = batch[Int(remainder) - 1].left
            }
        }
        checkGreater(received, 0)
        checkEqual(received + audio_ring_dropped(ring), 320_000)
    }

    func testChannelAssignmentAndOverflow() throws {
        let ring = try unwrap(channel_ring_create(4))
        defer { channel_ring_destroy(ring) }
        let input = (0..<80).map(Float.init)
        // Roles 0–7 keep their 5.1.2 meaning; 8–15 reach the 9.1.6 rear, wide and upper channels.
        let map: [Int32] = [7, 0, 2, 3, 6, 5, -1, 1, 8, 9, 10, 11, 12, 13, 14, 15]
        checkEqual(channel_ring_write(ring, input, 5, 16, map), 4)
        checkEqual(channel_ring_dropped(ring), 1)
        var frames = [ChannelFrame](repeating: ChannelFrame(), count: 4)
        checkEqual(channel_ring_read(ring, &frames, 4), 4)
        checkEqual(frames[0].left, 7)
        checkEqual(frames[0].right, 0)
        checkEqual(frames[1].center, 18)
        checkEqual(frames[3].rightTopFront, 49)
        checkEqual(frames[0].leftTopFront, 0)
        checkEqual(frames[2].leftRearSurround, 40)
        checkEqual(frames[3].rightTopRear, 63)
        checkEqual(MemoryLayout<ChannelFrame>.stride, Role.count * MemoryLayout<Float>.stride)
    }

    func testSummaryHeightAndStretch() {
        // The summary keeps its default until dragged, stays inside its limits, and leaves the panels their minimum.
        checkEqual(HeroLayout.height(0, tall: true, window: 1000), 192)
        checkEqual(HeroLayout.height(0, tall: false, window: 800), 182)
        checkEqual(HeroLayout.height(900, tall: true, window: 1400), HeroLayout.maxHeight)
        checkEqual(HeroLayout.height(50, tall: true, window: 1000), HeroLayout.minHeight)
        checkTrue(HeroLayout.height(400, tall: false, window: 760) <= 760 - HeroLayout.reservedBelow)
        // The loudness column only grows past the default height, and its readings stop at 1.8× (1.5× compact).
        checkEqual(HeroLayout.contentScale(height: 182, compact: true), 1)
        checkEqual(HeroLayout.contentScale(height: 192, compact: false), 1)
        checkEqual(HeroLayout.contentScale(height: 272, compact: false), 1.5)
        checkEqual(HeroLayout.contentScale(height: 420, compact: false), 1.8)
        checkEqual(HeroLayout.contentScale(height: 420, compact: true), 1.5)
        // A narrowed loudness column caps the growth: 1.8 needs the full 560 pt.
        checkEqual(HeroLayout.contentScale(height: 420, compact: false, loudnessWidth: 560), 1.8)
        checkEqual(HeroLayout.contentScale(height: 420, compact: false, loudnessWidth: 440), 440 / 560 * 1.8, accuracy: 0.001)
        checkEqual(HeroLayout.contentScale(height: 192, compact: false, loudnessWidth: 430), 1)
        // Summary row: unset, the loudness column grows to its maximum and the history takes the rest.
        let row: CGFloat = 1900
        let available = HeroLayout.available(width: row, compact: false)
        let automatic = HeroLayout.columns(width: row, compact: false, loudness: 0, vu: 0)
        checkEqual(automatic.loudness, 560)
        checkEqual(automatic.vu, 236)
        checkEqual(automatic.loudness + automatic.history + automatic.vu, available)
        // Dragged: each divider moves its own edge, and the history never drops below its minimum.
        let wideVU = HeroLayout.columns(width: row, compact: false, loudness: 560, vu: 500)
        checkEqual(wideVU.vu, 500)
        checkEqual(wideVU.history, available - 560 - 500)
        let squeezed = HeroLayout.columns(width: row, compact: false, loudness: 5_000, vu: 5_000)
        checkEqual(squeezed.vu, HeroLayout.maxVU)
        checkEqual(squeezed.history, HeroLayout.minHistory)
        checkEqual(HeroLayout.columns(width: row, compact: false, loudness: 10, vu: 10).vu, HeroLayout.minVU)
        checkEqual(HeroLayout.columns(width: row, compact: false, loudness: 10, vu: 10).loudness, 430)
    }

    func testChannelRingWrapsAndClearsUnroutedRoles() throws {
        let ring = try unwrap(channel_ring_create(5))
        defer { channel_ring_destroy(ring) }
        var frames = [ChannelFrame](repeating: ChannelFrame(), count: 8)
        // Fill the slots with every role routed, then wrap with only L and R routed: stale roles must read zero.
        let everything = (0..<Role.count).map { Int32($0) }
        let wide = (0..<(3 * 16)).map { Float($0 + 1) }
        checkEqual(channel_ring_write(ring, wide, 3, 16, everything), 3)
        checkEqual(channel_ring_read(ring, &frames, 8), 3)
        checkEqual(frames[2].rightTopRear, 48)
        var stereoMap = [Int32](repeating: -1, count: Role.count)
        stereoMap[Role.left] = 1
        stereoMap[Role.right] = 0
        let stereo: [Float] = [10, 11, 20, 21, 30, 31, 40, 41]
        checkEqual(channel_ring_write(ring, stereo, 4, 2, stereoMap), 4)
        checkEqual(channel_ring_read(ring, &frames, 8), 4)
        checkEqual(frames.prefix(4).map(\.left), [11, 21, 31, 41])
        checkEqual(frames.prefix(4).map(\.right), [10, 20, 30, 40])
        checkTrue(frames.prefix(4).allSatisfy { $0.center == 0 && $0.rightTopRear == 0 })
    }

    func testGatedIntegrationMatchesBlockScan() throws {
        // The former implementation: rescan every gated block.
        func reference(_ blocks: [Double]) -> Float {
            guard !blocks.isEmpty else { return -100 }
            let mean = blocks.reduce(0, +) / Double(blocks.count)
            let threshold = pow(10, (Double(LoudnessAnalyzer.loudness(mean)) - 10 + 0.691) / 10)
            let above = blocks.filter { $0 > threshold }
            return above.isEmpty ? -100 : LoudnessAnalyzer.loudness(above.reduce(0, +) / Double(above.count))
        }
        var generator = SystemRandomNumberGenerator()
        for trial in 0..<40 {
            var gated = GatedIntegration()
            var blocks: [Double] = []
            let count = trial < 20 ? Int.random(in: 1...400, using: &generator) : Int.random(in: 2_000...20_000, using: &generator)
            for index in 0..<count {
                // Quiet passages, loud passages and a cluster right at the relative gate.
                let lufs: Double
                switch index % 3 {
                case 0: lufs = Double.random(in: -69.9 ... -5, using: &generator)
                case 1: lufs = Double.random(in: -30 ... -12, using: &generator)
                default: lufs = trial % 2 == 0 ? -31.4 + Double.random(in: -0.05...0.05, using: &generator) : Double.random(in: -69 ... 3, using: &generator)
                }
                let energy = pow(10, (lufs + 0.691) / 10)
                gated.add(energy)
                blocks.append(energy)
                if index % 97 == 0 { checkEqual(gated.integrated(), reference(blocks), accuracy: 0.0001) }
            }
            checkEqual(gated.integrated(), reference(blocks), accuracy: 0.0001)
        }
        checkEqual(GatedIntegration().integrated(), -100)
    }

    func testPipelineWindowsPacingAndHolds() throws {
        let active = (0..<Role.count).map { $0 < 2 }
        func frames(_ count: Int, start: Int, amplitude: Float, spikeAt spike: Int? = nil) -> [ChannelFrame] {
            (0..<count).map { i in
                var frame = ChannelFrame()
                let t = Double(start + i)
                frame.left = amplitude * Float(sin(2 * Double.pi * 1_000 * t / 48_000))
                frame.right = frame.left * 0.5
                if spike == i { frame.left = 0.9 }
                return frame
            }
        }
        var values = [Float](repeating: 0, count: SnapshotSlots.total)
        // Small device buffers: 256 frames, 3–4 per 60 Hz tick. The published RMS spans the newest 1/30 s.
        let small = try unwrap(MeterPipeline(sampleRate: 48_000, activeRoles: active, detector: FormatDetector(), streamID: 1))
        var position = 0, delivered = 0
        var columns = Set<Float>()
        for tick in 1...120 {
            let due = tick * 800
            while delivered + 256 <= due {
                let block = frames(256, start: position, amplitude: 0.5)
                block.withUnsafeBufferPointer { small.consume($0) }
                position += 256
                delivered += 256
            }
            values.withUnsafeMutableBufferPointer { small.publish(into: $0.baseAddress!, now: Double(tick) / 60) }
            checkEqual(values[SnapshotSlots.sequence], Float(tick))
            columns.insert(values[SnapshotSlots.spectrogramSerial])
            if tick > 12 {
                checkEqual(values[SnapshotSlots.rms + Role.left], 0.5 / Float(2).squareRoot(), accuracy: 0.01)
                checkEqual(values[SnapshotSlots.rms + Role.right], 0.25 / Float(2).squareRoot(), accuracy: 0.005)
                checkEqual(values[SnapshotSlots.correlation], 1, accuracy: 0.0001)
                checkGreater(values[SnapshotSlots.spectrum..<(SnapshotSlots.spectrum + 64)].max()!, -30)
                checkEqual(values[SnapshotSlots.peakFrequency], 1_000, accuracy: 3)
            }
        }
        // 120 ticks at 60 Hz: 60 waterfall columns, i.e. still 30 per second.
        checkEqual(columns.subtracting([0]).count, 60)

        // A DAW at 2048 frames delivers every ~2.6 ticks: no tick in between may read silent.
        let large = try unwrap(MeterPipeline(sampleRate: 48_000, activeRoles: active, detector: FormatDetector(), streamID: 2))
        position = 0
        delivered = 0
        var spike: Int?
        for tick in 1...90 {
            let due = tick * 800
            if tick == 40 { spike = 17 }
            while delivered + 2048 <= due {
                let block = frames(2048, start: position, amplitude: 0.25, spikeAt: spike)
                spike = nil
                block.withUnsafeBufferPointer { large.consume($0) }
                position += 2048
                delivered += 2048
            }
            values.withUnsafeMutableBufferPointer { large.publish(into: $0.baseAddress!, now: Double(tick) / 60) }
            if tick > 4 {
                checkGreater(values[SnapshotSlots.rms + Role.left], 0.1)
            }
            // The spectrum needs one full 8192-sample window (four deliveries) first.
            if tick > 12 { checkGreater(values[SnapshotSlots.spectrum..<(SnapshotSlots.spectrum + 64)].max()!, -30) }
        }
        // The spike left the level window long ago, but the held peaks keep it for the readouts.
        checkTrue(values[SnapshotSlots.peaks + Role.left] < 0.3)
        checkEqual(values[SnapshotSlots.heldPeaks + Role.left], 0.9)
        checkGreaterOrEqual(values[SnapshotSlots.heldTruePeaks + Role.left], 0.9)
        // No audio for 100 ms reads as silence again.
        for tick in 91...(90 + MeterPipeline.staleTicks) {
            values.withUnsafeMutableBufferPointer { large.publish(into: $0.baseAddress!, now: Double(tick) / 60) }
        }
        checkEqual(values[SnapshotSlots.rms + Role.left], 0)
        checkEqual(values[SnapshotSlots.spectrum..<(SnapshotSlots.spectrum + 64)].max()!, -120)
        checkEqual(values[SnapshotSlots.correlation], MeterSnapshot.noCorrelation)
        checkEqual(values[SnapshotSlots.heldPeaks + Role.left], 0.9)
    }

    func testSpatialSpectrumSumsRoutedChannels() throws {
        // 5.1: L R C LFE Ls Rs routed. 440 Hz on L and R, 2 kHz on C only.
        let active = (0..<Role.count).map { $0 < 6 }
        let analyzer = try unwrap(SpectrumAnalyzer(sampleRate: 48_000, recording: active))
        analyzer.recordsSpatial = true
        let frames = (0..<SpectrumAnalyzer.fftSize).map { i -> ChannelFrame in
            var frame = ChannelFrame()
            let t = Double(i) / 48_000
            frame.left = Float(0.5 * sin(2 * .pi * 440 * t))
            frame.right = frame.left
            frame.center = Float(0.25 * sin(2 * .pi * 2_000 * t))
            return frame
        }
        frames.withUnsafeBufferPointer { analyzer.consume($0) }
        checkTrue(analyzer.spatialReady)
        var stereo = [Float](repeating: -120, count: MeterSnapshot.bandCount)
        var spatial = stereo
        let stereoPeak = analyzer.refreshSpectrum(into: &stereo)
        let spatialPeak = analyzer.refreshSpectrum(into: &spatial, roles: analyzer.spatialRoles)
        func band(_ frequency: Double) -> Int { Int(Double(MeterSnapshot.bandCount) * log(frequency / 20) / log(1_000)) }
        // L/R content reads the same in both modes (the sum is referenced to a stereo pair) …
        checkEqual(spatial[band(440)], stereo[band(440)], accuracy: 0.01)
        checkEqual(stereoPeak.frequency, 440, accuracy: 1)
        checkEqual(stereoPeak.level, 20 * log10(0.5), accuracy: 0.6)
        // … and only the Spatial spectrum sees the centre channel: half its power, i.e. 3 dB under its level.
        checkTrue(stereo[band(2_000)] < -90)
        checkEqual(spatial[band(2_000)], 20 * log10(0.25) - 3, accuracy: 0.8)
        checkEqual(spatialPeak.frequency, 440, accuracy: 1)
        // Each role's band energy (the Immersive room's band image): L's 440 Hz in 120–500 Hz at its mean square
        // (0.125), C's 2 kHz in the bands around 2 kHz, and nothing on the silent roles.
        let power = analyzer.roleBandPower
        func energy(_ role: Int, _ band: Int) -> Float { power[role * StereoBands.count + band] }
        checkEqual(energy(Role.left, 1), 0.125, accuracy: 0.01)
        checkEqual(energy(Role.center, 2) + energy(Role.center, 3), 0.03125, accuracy: 0.003)
        checkTrue(energy(Role.center, 1) < 1e-4 && energy(Role.left, 3) < 1e-4)
        checkTrue((0..<StereoBands.count).allSatisfy { energy(4, $0) < 1e-9 })
        // Turning Spatial off and on again waits for a fresh window.
        analyzer.recordsSpatial = false
        analyzer.recordsSpatial = true
        checkTrue(!analyzer.spatialReady)
    }

    func testLUFSReferenceAndLFEExclusion() throws {
        let reference = try unwrap(LoudnessAnalyzer(sampleRate: 48_000))
        let lfeOnly = try unwrap(LoudnessAnalyzer(sampleRate: 48_000))
        var front = [ChannelFrame](repeating: ChannelFrame(), count: 4800)
        var bass = [ChannelFrame](repeating: ChannelFrame(), count: 4800)
        for block in 0..<40 {
            for i in 0..<4800 {
                let value = Float(sin(2 * Double.pi * 997 * Double(block * 4800 + i) / 48_000))
                front[i].left = value
                bass[i].lfe = value
            }
            front.withUnsafeBufferPointer { reference.consume($0) }
            bass.withUnsafeBufferPointer { lfeOnly.consume($0) }
        }
        let result = reference.snapshot()
        checkEqual(result.momentary, -3.01, accuracy: 0.2)
        checkEqual(result.shortTerm, -3.01, accuracy: 0.2)
        checkEqual(result.integrated, -3.01, accuracy: 0.2)
        let lfe = lfeOnly.snapshot()
        checkTrue(lfe.peak[3] > 0.99)
        checkEqual(lfe.integrated, -100)
        checkEqual(lfe.momentary, -100)
    }

    func testSurroundAndHeightWeights() throws {
        // One analyzer per role, each fed the same 997 Hz tone on that role only.
        func integrated(role: Int) throws -> Float {
            let analyzer = try unwrap(LoudnessAnalyzer(sampleRate: 48_000))
            var frames = [ChannelFrame](repeating: ChannelFrame(), count: 4800)
            for block in 0..<10 {
                frames.withUnsafeMutableBytes { raw in
                    let samples = raw.bindMemory(to: Float.self)
                    for i in 0..<4800 {
                        samples[i * Role.count + role] = Float(sin(2 * Double.pi * 997 * Double(block * 4800 + i) / 48_000))
                    }
                }
                frames.withUnsafeBufferPointer { analyzer.consume($0) }
            }
            return analyzer.snapshot().integrated
        }
        let baseline = try integrated(role: Role.left)
        let boost = Float(10 * log10(1.41))
        // BS.1770-5: +1.5 dB for ear-level channels between 60° and 120° (side surrounds, wides); 1.0 elsewhere.
        checkEqual(try integrated(role: Role.leftSurround) - baseline, boost, accuracy: 0.05)
        checkEqual(try integrated(role: Role.rightWide) - baseline, boost, accuracy: 0.05)
        checkEqual(try integrated(role: Role.leftRearSurround), baseline, accuracy: 0.05)
        checkEqual(try integrated(role: Role.leftTopFront), baseline, accuracy: 0.05)
        checkEqual(try integrated(role: Role.rightTopRear), baseline, accuracy: 0.05)
        // An unrouted role costs nothing and reads silent even when it carries signal.
        var active = [Bool](repeating: false, count: Role.count)
        active[Role.left] = true
        let partial = try unwrap(LoudnessAnalyzer(sampleRate: 48_000, activeRoles: active))
        var frames = [ChannelFrame](repeating: ChannelFrame(), count: 4800)
        for i in 0..<4800 { frames[i].left = 0.5; frames[i].center = 0.5 }
        frames.withUnsafeBufferPointer { partial.consume($0) }
        let levels = partial.snapshot()
        checkEqual(levels.peak[Role.left], 0.5)
        checkEqual(levels.peak[Role.center], 0)
    }

    func testTruePeakAndLoudnessRange() throws {
        // A 12 kHz tone sampled 45° off its crests: every sample reads −3 dBFS, the waveform peaks at 0.
        let analyzer = try unwrap(LoudnessAnalyzer(sampleRate: 48_000))
        var frames = [ChannelFrame](repeating: ChannelFrame(), count: 4800)
        for i in 0..<4800 { frames[i].left = Float(sin(Double.pi / 2 * Double(i) + Double.pi / 4)) }
        frames.withUnsafeBufferPointer { analyzer.consume($0) }
        let levels = analyzer.snapshot()
        checkEqual(MeterScale.decibels(levels.peak[Role.left]), -3.01, accuracy: 0.02)
        checkEqual(MeterScale.decibels(levels.truePeak[Role.left]), 0, accuracy: 0.4)
        // A low tone is already sampled near its crest: true peak stays at the sample peak.
        let low = try unwrap(LoudnessAnalyzer(sampleRate: 48_000))
        for i in 0..<4800 { frames[i].left = Float(0.5 * sin(2 * Double.pi * 997 * Double(i) / 48_000)) }
        frames.withUnsafeBufferPointer { low.consume($0) }
        let quiet = low.snapshot()
        checkEqual(quiet.truePeak[Role.left], quiet.peak[Role.left], accuracy: 0.01)
        checkGreaterOrEqual(quiet.truePeak[Role.left], quiet.peak[Role.left])
        // Polyphase design: every phase has unity DC gain, and phase 0 passes the input through.
        for factor in [2, 4] {
            let phases = TruePeakDetector.design(factor: factor)
            checkEqual(phases.count, factor)
            for phase in phases { checkEqual(phase.reduce(0, +), 1, accuracy: 0.0001) }
            checkEqual(phases[0].filter { abs($0) > 0.0001 }.count, 1)
        }
        checkEqual(TruePeakDetector(sampleRate: 96_000, capacity: 16).factor, 2)
        checkEqual(TruePeakDetector(sampleRate: 192_000, capacity: 16).factor, 1)

        // EBU Tech 3342: 10 s at −20 LUFS and 10 s at −30 LUFS spread over a 10 LU range; a −80 LUFS
        // passage is below the absolute gate and a −45 LUFS one is under the relative gate.
        var range = LoudnessRange()
        checkTrue(range.value < 0)
        func energy(_ lufs: Double) -> Double { pow(10, (lufs + 0.691) / 10) }
        for _ in 0..<100 { range.add(energy(-20)) }
        for _ in 0..<100 { range.add(energy(-30)) }
        for _ in 0..<100 { range.add(energy(-80)) }
        for _ in 0..<5 { range.add(energy(-55)) }
        checkEqual(range.value, 10, accuracy: 0.15)
        var steady = LoudnessRange()
        for _ in 0..<50 { steady.add(energy(-23)) }
        checkEqual(steady.value, 0, accuracy: 0.01)
    }

    func testCorrelationAndPackedTransform() throws {
        // L and R share one complex FFT: a 440 Hz tone on L and a 3 kHz tone on R must stay apart.
        let analyzer = try unwrap(SpectrumAnalyzer(sampleRate: 48_000))
        let frames = (0..<SpectrumAnalyzer.fftSize).map { index -> StereoFrame in
            let t = Double(index) / 48_000
            return StereoFrame(left: Float(sin(2 * Double.pi * 440 * t)) * 0.5, right: Float(sin(2 * Double.pi * 3_000 * t)) * 0.5)
        }
        frames.withUnsafeBufferPointer { analyzer.consume($0) }
        let result = analyzer.snapshot()
        let band = { (hz: Double) in Int(log(hz / 20) / log(1_000.0) * Double(MeterSnapshot.spectrogramBandCount)) }
        // Each tone appears once, at half power (the mix averages L and R power), and nowhere else. Rows near
        // 440 Hz are about one bin wide, so the tone peaks in the row at or next to its nominal one.
        let rowPeak = { (hz: Double) in (band(hz) - 1...band(hz) + 1).map { result.spectrogram[$0] }.max()! }
        checkEqual(rowPeak(440), -9.03, accuracy: 1.5)
        checkEqual(rowPeak(3_000), -9.03, accuracy: 1.5)
        checkTrue(result.spectrogram[band(1_200)] < -60)
        checkTrue(abs(result.correlation) < 0.05)
        // Identical, inverted and silent channels.
        let same = try unwrap(SpectrumAnalyzer(sampleRate: 48_000))
        let inverted = try unwrap(SpectrumAnalyzer(sampleRate: 48_000))
        let tone = (0..<4_800).map { Float(sin(2 * Double.pi * 997 * Double($0) / 48_000)) }
        tone.map { StereoFrame(left: $0, right: $0 * 0.5) }.withUnsafeBufferPointer { same.consume($0) }
        tone.map { StereoFrame(left: $0, right: -$0) }.withUnsafeBufferPointer { inverted.consume($0) }
        checkEqual(same.snapshot().correlation, 1, accuracy: 0.0001)
        checkEqual(inverted.snapshot().correlation, -1, accuracy: 0.0001)
        checkEqual(same.snapshot().correlation, MeterSnapshot.noCorrelation)

        // Zones: −1 … −0.1 out of phase, … 0.3 wide, … 0.9 stereo, then mono; a reading near an edge keeps the
        // previous zone until it is 0.05 past it, and a jump across zones is taken at once.
        checkEqual(CorrelationZone(-0.6), .outOfPhase)
        checkEqual(CorrelationZone(0), .wide)
        checkEqual(CorrelationZone(0.62), .stereo)
        checkEqual(CorrelationZone(1), .mono)
        checkEqual(CorrelationZone(0.32, previous: .wide), .wide)
        checkEqual(CorrelationZone(0.36, previous: .wide), .stereo)
        checkEqual(CorrelationZone(0.27, previous: .stereo), .stereo)
        checkEqual(CorrelationZone(0.88, previous: .mono), .mono)
        checkEqual(CorrelationZone(-0.12, previous: .wide), .wide)
        checkEqual(CorrelationZone(0.95, previous: .outOfPhase), .mono)
        checkEqual(CorrelationZone(0.2, previous: .mono), .wide)
    }

    func testCorrelationIntegrator() throws {
        // 1 kHz on L; R is L times `gain` (1 in phase, −1 inverted), 800 frames per 60 Hz tick.
        let active = (0..<Role.count).map { $0 < 2 }
        let pipeline = try unwrap(MeterPipeline(sampleRate: 48_000, activeRoles: active, detector: FormatDetector(), streamID: 1))
        var values = [Float](repeating: 0, count: SnapshotSlots.total)
        var position = 0, tick = 0
        func run(ticks: Int, amplitude: Float, gain: Float) -> [Float] {
            (0..<ticks).map { _ in
                let block = (0..<800).map { i -> ChannelFrame in
                    var frame = ChannelFrame()
                    frame.left = amplitude * Float(sin(2 * Double.pi * 1_000 * Double(position + i) / 48_000))
                    frame.right = frame.left * gain
                    return frame
                }
                position += 800
                tick += 1
                block.withUnsafeBufferPointer { pipeline.consume($0) }
                values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: Double(tick) / 60) }
                return values[SnapshotSlots.correlation]
            }
        }
        checkEqual(run(ticks: 30, amplitude: 0.5, gain: 1).last!, 1, accuracy: 0.0001)
        // Turning R over moves the reading through 0 over a few hundred milliseconds instead of jumping: past
        // −0.95 within a second, and on to −1.
        let turning = run(ticks: 60, amplitude: 0.5, gain: -1)
        checkGreater(turning[0], 0.5)
        checkTrue(turning[10] < 0 && turning[10] > -0.9)
        checkTrue(turning.last! < -0.95)
        checkEqual(run(ticks: 60, amplitude: 0.5, gain: -1).last!, -1, accuracy: 0.002)
        // Energy-weighted: a passage 40 dB quieter barely moves a reading the loud one set.
        checkGreater(run(ticks: 90, amplitude: 0.5, gain: 1).last!, 0.99)
        checkGreater(run(ticks: 6, amplitude: 0.005, gain: -1).last!, 0.98)
        // Silence rests the meter and restarts the average: the next passage reads as itself at once.
        checkEqual(run(ticks: 3, amplitude: 0, gain: 1).last!, MeterSnapshot.noCorrelation)
        checkEqual(run(ticks: 1, amplitude: 0.5, gain: -1).last!, -1, accuracy: 0.0001)
    }

    func testStereoBands() throws {
        // 60 Hz identical on both sides, 1 kHz on L only, 4 kHz with R inverted; nothing in 120–500 Hz or 8 kHz+.
        checkEqual(StereoBands.label(0), "20 Hz")
        checkEqual(StereoBands.label(3), "2 kHz")
        let map = StereoBands.binBands(sampleRate: 48_000, fftSize: SpectrumAnalyzer.fftSize)
        let binWidth = 48_000.0 / Double(SpectrumAnalyzer.fftSize)
        checkEqual(map[Int(60 / binWidth)], 0)
        checkEqual(map[Int(1_000 / binWidth)], 2)
        checkEqual(map[Int(9_000 / binWidth)], 4)
        checkEqual(map[1], -1)
        let active = (0..<Role.count).map { $0 < 2 }
        let pipeline = try unwrap(MeterPipeline(sampleRate: 48_000, activeRoles: active, detector: FormatDetector(), streamID: 1))
        var values = [Float](repeating: 0, count: SnapshotSlots.total)
        var position = 0
        for tick in 1...60 {
            let block = (0..<800).map { i -> ChannelFrame in
                let t = Double(position + i) / 48_000
                let bass = 0.3 * Float(sin(2 * Double.pi * 60 * t))
                let mid = 0.2 * Float(sin(2 * Double.pi * 1_000 * t))
                let high = 0.1 * Float(sin(2 * Double.pi * 4_000 * t))
                var frame = ChannelFrame()
                frame.left = bass + mid + high
                frame.right = bass - high
                return frame
            }
            position += 800
            block.withUnsafeBufferPointer { pipeline.consume($0) }
            values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: Double(tick) / 60) }
        }
        func band(_ slot: Int, _ index: Int) -> Float { values[slot + index] }
        checkEqual(band(SnapshotSlots.bandCorrelation, 0), 1, accuracy: 0.01)
        checkEqual(band(SnapshotSlots.bandWidth, 0), 0, accuracy: 0.01)
        checkEqual(band(SnapshotSlots.bandBalance, 0), 0, accuracy: 0.01)
        // RMS of a 0.3 sine: −13.5 dBFS.
        checkEqual(band(SnapshotSlots.bandLevel, 0), Float(20 * log10(0.3 / 2.0.squareRoot())), accuracy: 0.5)
        checkEqual(band(SnapshotSlots.bandCorrelation, 1), MeterSnapshot.noCorrelation)
        // L only: no correlation to speak of (R is silent in that band), fully left, half side energy.
        checkEqual(band(SnapshotSlots.bandBalance, 2), -1, accuracy: 0.02)
        checkEqual(band(SnapshotSlots.bandWidth, 2), 0.5, accuracy: 0.02)
        checkEqual(band(SnapshotSlots.bandCorrelation, 3), -1, accuracy: 0.01)
        checkEqual(band(SnapshotSlots.bandWidth, 3), 1, accuracy: 0.01)
        checkEqual(band(SnapshotSlots.bandCorrelation, 4), MeterSnapshot.noCorrelation)
        // Merged groups: three bands (20 Hz, 120 Hz–2 kHz, 2 kHz up) and overall read from the five bands' sums.
        let three = StereoBands.Resolution.three.offset, overall = StereoBands.Resolution.overall.offset
        checkEqual(StereoBands.groups.count, 9)
        checkEqual(band(SnapshotSlots.bandCorrelation, three), band(SnapshotSlots.bandCorrelation, 0), accuracy: 1e-6)
        checkEqual(band(SnapshotSlots.bandBalance, three + 1), -1, accuracy: 0.02)
        checkEqual(band(SnapshotSlots.bandCorrelation, three + 2), -1, accuracy: 0.01)
        // Overall: energy-weighted, so the loud in-phase bass outweighs the inverted 4 kHz; L carries the 1 kHz extra.
        checkTrue(band(SnapshotSlots.bandCorrelation, overall) > 0.3 && band(SnapshotSlots.bandCorrelation, overall) < 0.9)
        checkTrue(band(SnapshotSlots.bandBalance, overall) < 0)
        checkGreater(band(SnapshotSlots.bandLevel, overall), band(SnapshotSlots.bandLevel, 0))
        // Stereometer points: each band carries only its own tone, with its own L/R relation.
        func points(_ band: Int) -> [(Float, Float)] {
            (0..<StereoBands.scopePoints).map { point in
                let index = SnapshotSlots.bandPoints + (band * StereoBands.scopePoints + point) * 2
                return (values[index], values[index + 1])
            }
        }
        checkGreater(points(0).map { abs($0.0) }.max()!, 0.2)
        checkTrue(points(0).allSatisfy { abs($0.0 - $0.1) < 1e-4 })
        checkTrue(points(2).allSatisfy { abs($0.1) < 0.01 })
        checkGreater(points(2).map { abs($0.0) }.max()!, 0.1)
        // The 1 kHz on L leaks about −24 dB through the 2 kHz crossover: L ≈ −R to within that.
        checkTrue(points(3).allSatisfy { abs($0.0 + $0.1) < 0.03 })
        checkGreater(points(3).map { abs($0.1) }.max()!, 0.05)
        checkTrue(points(4).allSatisfy { abs($0.0) < 0.02 })
        // Silence rests every band.
        for tick in 61...(60 + MeterPipeline.staleTicks) {
            values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: Double(tick) / 60) }
        }
        for index in 0..<StereoBands.groups.count { checkEqual(band(SnapshotSlots.bandCorrelation, index), MeterSnapshot.noCorrelation) }
    }

    func testSpeakerLayouts() throws {
        checkEqual(SpeakerLayout.s916.channelCount, 16)
        checkEqual(SpeakerLayout.s714.channelCount, 12)
        checkEqual(SpeakerLayout.s512.roles, [0, 1, 2, 3, 4, 5, 6, 7])
        checkEqual(SpeakerLayout.s70.hasLFE, false)
        for layout in SpeakerLayout.allCases {
            let roles = layout.roles
            checkEqual(Set(roles).count, roles.count)
            checkTrue(roles.allSatisfy { (0..<Role.count).contains($0) })
            checkTrue(roles.starts(with: [Role.left, Role.right]))
            // Display order groups front, LFE, surround, height, and covers every role once.
            checkEqual(Set(layout.speakers.map(\.role)), Set(roles))
            let order = layout.speakers.map { [SpeakerGroup.front, .lfe, .surround, .height].firstIndex(of: $0.group)! }
            checkEqual(order, order.sorted())
            checkEqual(layout.speakers[0].name, "L")
        }
        checkEqual(SpeakerLayout.s916.speakers.map(\.name),
                   ["L", "R", "C", "Lw", "Rw", "LFE", "Lss", "Rss", "Lrs", "Rrs", "Ltf", "Rtf", "Ltm", "Rtm", "Ltr", "Rtr"])
        checkEqual(SpeakerLayout.s51.name(of: Role.leftSurround), "Ls")
        checkEqual(Role.loudnessWeights.count, Role.count)
        checkEqual(Role.loudnessWeights[Role.lfe], 0)
    }

    func testFullRangeSpectrogramHistory() throws {
        let analyzer = try unwrap(SpectrumAnalyzer(sampleRate: 48_000))
        let frames = (0..<SpectrumAnalyzer.fftSize).map { index -> StereoFrame in
            let sample = Float(sin(2 * Double.pi * 440 * Double(index) / 48_000)) * 0.5
            return StereoFrame(left: sample, right: sample)
        }
        frames.withUnsafeBufferPointer { analyzer.consume($0) }
        let snapshot = analyzer.snapshot()
        let band = Int(log(440.0 / 20) / log(20_000.0 / 20) * Double(MeterSnapshot.bandCount))
        let detailedBand = Int(log(440.0 / 20) / log(20_000.0 / 20) * Double(MeterSnapshot.spectrogramBandCount))
        checkTrue(snapshot.spectrum[band] > -9)
        checkTrue(snapshot.spectrum[band] > snapshot.spectrum[0] + 15)
        checkEqual(snapshot.spectrogram.count, 512)
        checkTrue(snapshot.spectrogram[detailedBand] > -9)
        checkTrue(snapshot.spectrogram[detailedBand] > snapshot.spectrogram[0] + 15)
        let history = SpectrogramHistory()
        checkEqual(SpectrogramHistory.intensity(-120), 0)
        checkEqual(SpectrogramHistory.intensity(-60), 128)
        checkEqual(SpectrogramHistory.intensity(0), 255)
        for index in 0..<SpectrogramHistory.width + 3 {
            checkEqual(history.append(snapshot.spectrogram), index % SpectrogramHistory.width)
        }
        checkEqual(history.writeIndex, 3)
        checkEqual(history.columnsWritten, SpectrogramHistory.width)
        checkTrue(history.column[detailedBand] > 200)
        history.reset()
        checkEqual(history.writeIndex, 0)
        checkEqual(history.columnsWritten, 0)
        checkTrue(history.column.allSatisfy { $0 == 0 })
    }

    func testDampedDisplayConvergence() {
        let filter = DampedDisplayState()
        var source = MeterSnapshot()
        source.streamID = 1
        _ = filter.step(target: source, deltaTime: 1.0 / 60)
        source.spectrum[20] = -10
        source.shortLUFS = -20
        source.channelPeaks[0] = 0.8
        let first = filter.step(target: source, deltaTime: 1.0 / 60)
        checkTrue(first.spectrum[20] > -120 && first.spectrum[20] < -10)
        checkTrue(first.shortLUFS > -100 && first.shortLUFS < -20)
        checkTrue(first.channelPeaks[0] > 0 && first.channelPeaks[0] < 0.8)
        var final = first
        for _ in 0..<120 { final = filter.step(target: source, deltaTime: 1.0 / 60) }
        checkEqual(final.spectrum[20], -10, accuracy: 0.01)
        checkEqual(final.shortLUFS, -20, accuracy: 0.01)
        checkEqual(final.channelPeaks[0], 0.8, accuracy: 0.01)
        source.streamID = 2
        source.spectrum[20] = -70
        checkEqual(filter.step(target: source, deltaTime: 1.0 / 60).spectrum[20], -70)
    }

    func testCalibratedSineAndAntiphase() throws {
        let analyzer = try unwrap(SpectrumAnalyzer(sampleRate: 48_000))
        let size = SpectrumAnalyzer.fftSize
        let frames = (0..<size).map { index -> StereoFrame in
            let value = Float(sin(2 * Double.pi * 64 * Double(index) / Double(size))) * 0.5
            return StereoFrame(left: value, right: -value)
        }
        frames.withUnsafeBufferPointer { analyzer.consume($0) }
        let result = analyzer.snapshot()
        checkEqual(result.leftPeak, 0.5, accuracy: 0.00001)
        checkEqual(result.rightPeak, 0.5, accuracy: 0.00001)
        checkEqual(result.leftRMS, 0.5 / sqrt(2), accuracy: 0.00001)
        checkEqual(result.rightRMS, 0.5 / sqrt(2), accuracy: 0.00001)
        checkEqual(try unwrap(result.spectrum.max()), -6.0206, accuracy: 0.02)
        let empty = analyzer.snapshot()
        checkEqual(empty.leftPeak, 0)
        checkTrue(empty.spectrum.allSatisfy { $0 == -120 })
        checkTrue(empty.spectrogram.allSatisfy { $0 == -120 })
    }

    func testChunkBoundariesAndStereoEnergy() throws {
        let analyzer = try unwrap(SpectrumAnalyzer(sampleRate: 48_000))
        let size = SpectrumAnalyzer.fftSize
        let frames = (0..<(size * 3)).map { index -> StereoFrame in
            let value = Float(sin(2 * Double.pi * 64 * Double(index) / Double(size)))
            return StereoFrame(left: value, right: 0)
        }
        frames.withUnsafeBufferPointer { source in
            for start in stride(from: 0, to: frames.count, by: 257) {
                analyzer.consume(UnsafeBufferPointer(start: source.baseAddress! + start, count: min(257, frames.count - start)))
            }
        }
        let result = analyzer.snapshot()
        checkEqual(result.leftPeak, 1, accuracy: 0.00001)
        checkEqual(result.rightPeak, 0)
        checkEqual(result.leftRMS, 1 / sqrt(2), accuracy: 0.00001)
        checkEqual(try unwrap(result.spectrum.max()), -3.0103, accuracy: 0.02)
    }

    func testLowFrequencyRowsInterpolate() throws {
        let maps = SpectrumAnalyzer.bandMaps(count: MeterSnapshot.spectrogramBandCount, sampleRate: 48_000)
        let binWidth = 48_000.0 / Double(SpectrumAnalyzer.fftSize)
        checkTrue(maps[0].interpolated)
        checkTrue(!maps[maps.count - 1].interpolated)
        // Adjacent low rows must not collapse onto an identical bin as the old mapping did.
        let positions = maps.prefix(40).map { Double($0.first) + Double(max(0, $0.fraction)) }
        for (a, b) in zip(positions, positions.dropFirst()) { checkGreater(b, a) }
        checkEqual(positions[0] * binWidth, 20 * pow(1000, 0.5 / Double(MeterSnapshot.spectrogramBandCount)), accuracy: binWidth)
        let analyzer = try unwrap(SpectrumAnalyzer(sampleRate: 48_000))
        let frames = (0..<SpectrumAnalyzer.fftSize).map { index -> StereoFrame in
            let sample = Float(sin(2 * Double.pi * 40 * Double(index) / 48_000)) * 0.5
            return StereoFrame(left: sample, right: sample)
        }
        frames.withUnsafeBufferPointer { analyzer.consume($0) }
        let snapshot = analyzer.snapshot()
        let row = Int(log(40.0 / 20) / log(1000.0) * Double(MeterSnapshot.spectrogramBandCount))
        checkTrue(snapshot.spectrogram[row] > -12)
        checkTrue(snapshot.spectrogram[row] > snapshot.spectrogram[row + MeterSnapshot.spectrogramBandCount / 10] + 20)
    }

    func testPitchAndDominantPeak() throws {
        checkEqual(Pitch(frequency: 440)?.label, "A4")
        checkEqual(Pitch(frequency: 440)?.cents, 0)
        checkEqual(Pitch(frequency: 261.63)?.label, "C4")
        checkEqual(Pitch(frequency: 27.5)?.label, "A0")
        checkEqual(Pitch(frequency: 16.35)?.label, "C0")
        checkEqual(Pitch(frequency: 445)?.cents, 20)
        checkEqual(Pitch(frequency: 466.16)?.label, "A#4")
        checkEqual(Pitch(frequency: 440 * pow(2, 0.49 / 12))?.cents, 49)
        checkTrue((-50...49).contains(Pitch(frequency: 440 * pow(2, 0.5 / 12))!.cents))
        checkTrue(Pitch(frequency: 0) == nil)
        for frequency in [55.0, 98.0, 440.0, 3_520.0] {
            let analyzer = try unwrap(SpectrumAnalyzer(sampleRate: 48_000))
            let frames = (0..<SpectrumAnalyzer.fftSize).map { index -> StereoFrame in
                let sample = Float(sin(2 * Double.pi * frequency * Double(index) / 48_000)) * 0.25
                return StereoFrame(left: sample, right: sample)
            }
            frames.withUnsafeBufferPointer { analyzer.consume($0) }
            let snapshot = analyzer.snapshot()
            // Within 3 cents of the true pitch even where one bin is ~1.8 semitones wide (55 Hz).
            checkEqual(1200 * log2(Double(snapshot.peakFrequency) / frequency), 0, accuracy: 3)
            checkEqual(snapshot.peakLevel, 20 * log10(0.25), accuracy: 0.6)
        }
    }

    func testChordNotesAndHolds() throws {
        // A major triad (A3, C#4, E4), each with its 2nd and 3rd harmonics: three notes, no overtones.
        let analyzer = try unwrap(SpectrumAnalyzer(sampleRate: 48_000))
        let chord: [(Double, Float)] = [(220, 0.12), (277.18, 0.1), (329.63, 0.09)]
        let frames = (0..<SpectrumAnalyzer.fftSize).map { index -> StereoFrame in
            let t = Double(index) / 48_000
            var sample: Float = 0
            for (frequency, amplitude) in chord {
                for (harmonic, share) in [(1.0, Float(1)), (2, 0.5), (3, 0.3)] {
                    sample += amplitude * share * Float(sin(2 * Double.pi * frequency * harmonic * t))
                }
            }
            return StereoFrame(left: sample, right: sample)
        }
        frames.withUnsafeBufferPointer { analyzer.consume($0) }
        let snapshot = analyzer.snapshot()
        let midis = stride(from: 0, to: snapshot.notes.count, by: 2).compactMap { index -> Int? in
            snapshot.notes[index] > 0 ? Int((69 + 12 * log2(Double(snapshot.notes[index]) / 440)).rounded()) : nil
        }
        checkEqual(Set(midis), [57, 61, 64])

        var holds = NoteHolds()
        holds.update(snapshot.notes, deltaTime: 0.1)
        checkEqual(Set(holds.notes.map(\.midi)), [57, 61, 64])
        // A note missing from one readout stays lit through the hold, then goes out.
        holds.update([Float(220), -20] + [Float](repeating: 0, count: 10), deltaTime: 0.1)
        checkEqual(holds.notes.count, 3)
        for _ in 0..<4 { holds.update([Float(220), -20] + [Float](repeating: 0, count: 10), deltaTime: 0.1) }
        checkEqual(holds.notes.map(\.midi), [57])
        // Under the gate is not a note.
        holds.update([Float(440), -75] + [Float](repeating: 0, count: 10), deltaTime: 0.1)
        checkTrue(!holds.notes.contains { $0.midi == 69 })
    }

    func testBassNotesAcrossSampleRates() throws {
        // The old eight-bin margin excluded ordinary bass notes, especially at 96 kHz.
        for rate in [44_100.0, 48_000, 96_000] {
            for frequency in [32.7032, 41.2034, 55.0, 110.0] {
                let analyzer = try unwrap(SpectrumAnalyzer(sampleRate: rate))
                let frames = (0..<SpectrumAnalyzer.fftSize).map { index -> StereoFrame in
                    let value = Float(0.2 * sin(2 * Double.pi * frequency * Double(index) / rate))
                    return StereoFrame(left: value, right: value)
                }
                frames.withUnsafeBufferPointer { analyzer.consume($0) }
                let notes = analyzer.snapshot().notes
                let detected = stride(from: 0, to: notes.count, by: 2).compactMap { notes[$0] > 0 ? notes[$0] : nil }
                checkEqual(detected.count, 1)
                let peak = try unwrap(detected.first)
                checkEqual(1200 * log2(Double(peak) / frequency), 0, accuracy: 35)
                let silence = [StereoFrame](repeating: StereoFrame(left: 0, right: 0), count: SpectrumAnalyzer.fftSize)
                silence.withUnsafeBufferPointer { analyzer.consume($0) }
                let cleared = analyzer.snapshot().notes
                checkTrue(stride(from: 0, to: cleared.count, by: 2).allSatisfy { cleared[$0] == 0 })
            }
        }
    }

    func testPeakTrackerGateHoldAndAttack() throws {
        var tracker = PeakTracker()
        tracker.update(frequency: 440, level: -70, deltaTime: 0.1)
        checkTrue(!tracker.visible)
        tracker.update(frequency: 440, level: -20, deltaTime: 0.1)
        checkTrue(tracker.visible)
        checkEqual(tracker.frequency, 440)
        // A quieter peak elsewhere must persist through the hold before the readout moves.
        tracker.update(frequency: 1_000, level: -40, deltaTime: 0.1)
        checkEqual(tracker.frequency, 440)
        for _ in 0..<4 { tracker.update(frequency: 1_000, level: -40, deltaTime: 0.1) }
        checkEqual(tracker.frequency, 1_000)
        // A louder peak takes over immediately.
        tracker.update(frequency: 60, level: -10, deltaTime: 0.1)
        checkEqual(tracker.frequency, 60)
        // Silence hides the readout only after the hold.
        tracker.update(frequency: 60, level: -90, deltaTime: 0.1)
        checkTrue(tracker.visible)
        for _ in 0..<4 { tracker.update(frequency: 60, level: -90, deltaTime: 0.1) }
        checkTrue(!tracker.visible)
    }

    func testFormatDetectorHysteresis() throws {
        let tick: Float = 1.0 / 30
        func rms(front: Float = -20, center: Float = -120, lfe: Float = -120, surround: Float = -120, height: Float = -120) -> [Float] {
            let a = { (db: Float) -> Float in db <= -120 ? 0 : pow(10, db / 20) }
            return [a(front), a(front), a(center), a(lfe), a(surround), a(surround), a(height), a(height)]
        }
        func run(_ detector: inout FormatDetector, _ levels: [Float], seconds: Float) {
            for _ in 0..<Int((seconds / tick).rounded()) { detector.update(rms: levels, deltaTime: tick) }
        }
        var detector = FormatDetector()
        run(&detector, rms(), seconds: 20)
        checkEqual(detector.format, .stereo)
        // A single 33 ms click on the surrounds, then quiet: not enough to switch.
        detector.update(rms: rms(surround: -20), deltaTime: tick)
        run(&detector, rms(), seconds: 1)
        checkEqual(detector.format, .stereo)
        // LFE alone and bleed 43 dB under loud fronts are not surround evidence.
        run(&detector, rms(lfe: -10), seconds: 5)
        run(&detector, rms(front: -5, center: -48), seconds: 5)
        checkEqual(detector.format, .stereo)
        // 150 ms of height programme switches promptly.
        run(&detector, rms(height: -35), seconds: 0.1)
        checkEqual(detector.format, .stereo)
        run(&detector, rms(height: -35), seconds: 0.1)
        checkEqual(detector.format, .spatial)
        // Total silence freezes, and levels between the thresholds neither arm nor release.
        run(&detector, rms(front: -120), seconds: 60)
        run(&detector, rms(surround: -62), seconds: 60)
        checkEqual(detector.format, .spatial)
        // Front-only programme releases after the 2.5 s hold.
        run(&detector, rms(), seconds: 2.3)
        checkEqual(detector.format, .spatial)
        run(&detector, rms(), seconds: 0.4)
        checkEqual(detector.format, .stereo)
        // A click on the surrounds during the countdown does not restart it.
        run(&detector, rms(height: -35), seconds: 0.3)
        checkEqual(detector.format, .spatial)
        run(&detector, rms(), seconds: 2)
        detector.update(rms: rms(surround: -20), deltaTime: tick)
        run(&detector, rms(), seconds: 0.8)
        checkEqual(detector.format, .stereo)
        // Sustained spatial programme keeps it Spatial however long it runs.
        run(&detector, rms(height: -35), seconds: 0.3)
        run(&detector, rms(surround: -30), seconds: 30)
        checkEqual(detector.format, .spatial)
        // A new stream keeps the previous decision, unless nothing could ever carry surround.
        checkEqual(FormatDetector(initial: .spatial).format, .spatial)
        var unrouted = FormatDetector(initial: .spatial, canDetectSpatial: false)
        checkEqual(unrouted.format, .stereo)
        run(&unrouted, rms(surround: -10), seconds: 2)
        checkEqual(unrouted.format, .stereo)
        checkEqual(FormatMode.stereo.fixed, .stereo)
        checkEqual(FormatMode.auto.fixed, nil)
        checkEqual(FormatMode.mono.fixed, .mono)
        for format in ChannelFormat.allCases { checkEqual(FormatMode(format).fixed, format) }
        // The detector only ever decides Stereo ↔ Spatial; a Mono start is treated as Stereo.
        checkEqual(FormatDetector(initial: .mono).format, .stereo)
    }

    func testWaveformEnvelopeColumns() throws {
        let envelope = WaveformEnvelope(sampleRate: 48_000)
        checkEqual(envelope.framesPerColumn, 200)
        let frames = (0..<1_000).map { index -> ChannelFrame in
            let value = Float(index) / 1_000
            var frame = ChannelFrame()
            frame.left = value
            frame.right = -value
            frame.center = 5
            frame.rightTopRear = -2
            return frame
        }
        // Split mid-column: 700 + 300 frames make exactly five 200-frame columns.
        frames[0..<700].withUnsafeBufferPointer { envelope.consume($0) }
        frames[700...].withUnsafeBufferPointer { envelope.consume($0) }
        checkEqual(envelope.serial, 5)
        var published = [Float](repeating: -9, count: WaveformEnvelope.publishedFloats)
        published.withUnsafeMutableBufferPointer { envelope.write(into: $0.baseAddress!) }
        // Each column holds (min, max) per role; the newest two columns' L/R pairs, oldest first.
        let columns = WaveformEnvelope.valuesPerColumn
        let tail = Array(published.suffix(2 * columns))
        let newest = Array(tail[0..<4]) + Array(tail[columns..<(columns + 4)])
        checkEqual(tail[columns + 4], 5)
        checkEqual(tail[columns + 5], 5)
        checkEqual(tail[columns + 30], -2)
        checkEqual(tail[columns + 31], -2)
        // Column 4 spans frames 600–799 (straddling the two calls); column 5 spans 800–999.
        checkEqual(newest[0], 0.6, accuracy: 0.00001)
        checkEqual(newest[1], 0.799, accuracy: 0.00001)
        checkEqual(newest[2], -0.799, accuracy: 0.00001)
        checkEqual(newest[3], -0.6, accuracy: 0.00001)
        checkEqual(newest[4], 0.8, accuracy: 0.00001)
        checkEqual(newest[5], 0.999, accuracy: 0.00001)
        checkEqual(newest[6], -0.999, accuracy: 0.00001)
        checkEqual(newest[7], -0.8, accuracy: 0.00001)
        checkTrue(published.prefix(WaveformEnvelope.publishedFloats - 5 * columns).allSatisfy { $0 == 0 })
        checkEqual(WaveformEnvelope.newColumns(since: 999_998, latest: 2), 4)
        checkEqual(WaveformEnvelope.newColumns(since: 10, latest: 10), 0)
        checkEqual(WaveformEnvelope.newColumns(since: 0, latest: 500), WaveformEnvelope.publishedColumns)
    }

    func testMinMaxPyramid() throws {
        // Deterministic pseudo-random columns; a few exceed full scale like clipped envelope columns.
        var seed: UInt32 = 0x9E37_79B9
        func next() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 24) * 2.2 - 1.1
        }
        for firstIndex in [UInt32(0), UInt32.max - 191] {
            var pyramid = MinMaxPyramid(capacity: 256, firstIndex: firstIndex)
            var mirror = pyramid.texels
            var columns: [SIMD4<Float>] = []
            for step in 0..<1_000 {
                let a = next(), b = next(), c = next(), d = next()
                let column = SIMD4(min(a, b), max(a, b), min(c, d), max(c, d))
                columns.append(column)
                pyramid.append(column)
                // Upload in bursts like the 30 Hz snapshots; only dirty spans reach the mirror.
                if step % 7 == 6 || step == 999 {
                    pyramid.forEachDirtySpan { level, slot, count, texels in
                        let base = pyramid.offset(level: level) + slot
                        for i in 0..<count { mirror[base + i] = texels[base + i] }
                    }
                    pyramid.markClean()
                }
            }
            checkTrue(mirror == pyramid.texels)
            checkEqual(pyramid.count, 256)
            checkEqual(pyramid.newestIndex, firstIndex &+ 999)
            func brute(_ oldestAge: Int, _ newestAge: Int) -> SIMD4<Float> {
                columns[(columns.count - 1 - oldestAge)...(columns.count - 1 - newestAge)].reduce(
                    SIMD4(.infinity, -.infinity, .infinity, -.infinity), MinMaxPyramid.merge)
            }
            for level in 0..<MinMaxPyramid.levels {
                // Every bucket still in the ring equals the brute-force extrema of its columns, including
                // the newest, partly filled one; ring slots follow the absolute index through the wrap.
                let shift = UInt32(2 * level)
                let newestBucket = pyramid.newestIndex >> shift
                for back in 0..<UInt32(pyramid.slots(level: level) - 1) {
                    let bucket = newestBucket &- back
                    let start = bucket << shift
                    let end = back == 0 ? pyramid.newestIndex : start &+ UInt32((1 << shift) - 1)
                    let oldestAge = Int(pyramid.newestIndex &- start), newestAge = Int(pyramid.newestIndex &- end)
                    let texel = pyramid.texels[pyramid.offset(level: level) + Int(bucket & UInt32(pyramid.slots(level: level) - 1))]
                    checkTrue(texel == brute(oldestAge, newestAge))
                }
            }
            // A query at any level covers at least the exact range, never less.
            for (newest, oldest) in [(0, 0), (3, 40), (17, 200), (0, 180), (90, 91)] {
                let exact = brute(oldest, newest)
                for level in 0..<MinMaxPyramid.levels {
                    let cached = pyramid.extrema(newestAge: newest, oldestAge: oldest, level: level)
                    checkTrue(cached.x <= exact.x && cached.y >= exact.y && cached.z <= exact.z && cached.w >= exact.w)
                }
                checkTrue(pyramid.extrema(newestAge: newest, oldestAge: oldest, level: 0) == exact)
            }
        }
        // Several channel pairs share bucket boundaries; each pair's buckets match its own columns, and a
        // level's dirty span covers the same slots in every pair's row.
        var multi = MinMaxPyramid(capacity: 64, pairs: 3)
        var perPair = [[SIMD4<Float>]](repeating: [], count: 3)
        for step in 0..<150 {
            let values = (0..<3).map { pair in SIMD4<Float>(-Float(step % 7) - Float(pair), Float(step % 11) + Float(pair), -1, 1) }
            for pair in 0..<3 { perPair[pair].append(values[pair]) }
            multi.append { values[$0] }
        }
        for pair in 0..<3 {
            let exact = perPair[pair].suffix(10).reduce(SIMD4(.infinity, -.infinity, .infinity, -.infinity), MinMaxPyramid.merge)
            checkTrue(multi.extrema(newestAge: 0, oldestAge: 9, level: 0, pair: pair) == exact)
            checkEqual(multi.offset(level: 1, pair: pair), 3 * 64 + pair * 16)
        }
        checkEqual(multi.texels.count, 3 * (64 + 16 + 4 + 1))
        checkEqual(MinMaxPyramid.level(columnsPerPixel: 0.5), 0)
        checkEqual(MinMaxPyramid.level(columnsPerPixel: 3.9), 0)
        checkEqual(MinMaxPyramid.level(columnsPerPixel: 4), 1)
        checkEqual(MinMaxPyramid.level(columnsPerPixel: 16), 2)
        checkEqual(MinMaxPyramid.level(columnsPerPixel: 64), 3)
        checkEqual(MinMaxPyramid.level(columnsPerPixel: 5_000), 3)
    }

    func testMeterScaleAndLayouts() throws {
        checkEqual(MeterScale.position(decibels: 0), 1)
        checkEqual(MeterScale.position(decibels: -20), 0.5, accuracy: 0.0001)
        checkEqual(MeterScale.position(decibels: -80), 0)
        var previous: Float = -1
        for db in stride(from: Float(-75), through: 0, by: 0.5) {
            let position = MeterScale.position(decibels: db)
            checkGreaterOrEqual(position, previous)
            previous = position
        }
        checkEqual(MeterScale.tenths(-19.06), "−19.1")
        checkEqual(MeterScale.tenths(-120), "−∞")
        checkEqual(Double(MeterScale.frequencyFraction(20_000, sampleRate: 48_000)), 1, accuracy: 0.000001)
        // Drag-to-resize: the two panels always fill the column and keep their minimums.
        for height in [560, 700, 1_200] as [CGFloat] {
            for fraction in [-1, 0, 0.1, 0.3, 0.6, 0.95, .nan] as [CGFloat] {
                let panels = PanelLayout(height: height, spectrum: fraction)
                checkEqual(Double(panels.panels + PanelLayout.divider), Double(height), accuracy: 0.001)
                checkGreaterOrEqual(panels.spectrum, PanelLayout.minSpectrum)
                checkGreaterOrEqual(panels.waveform, PanelLayout.minWaveform)
            }
            let base = PanelLayout(height: height, spectrum: PanelLayout.defaultSpectrum)
            for target in [0, base.spectrum + 40, 5_000] as [CGFloat] {
                let after = PanelLayout(height: height, spectrum: base.draggingSpectrum(to: target))
                checkGreaterOrEqual(after.spectrum, PanelLayout.minSpectrum)
                checkGreaterOrEqual(after.waveform, PanelLayout.minWaveform)
            }
            let dragged = PanelLayout(height: height, spectrum: base.draggingSpectrum(to: base.spectrum + 40))
            checkEqual(Double(dragged.spectrum), Double(min(base.spectrum + 40, base.panels - PanelLayout.minWaveform)), accuracy: 1.001)
        }
        // The Soundstage column keeps its limits and always leaves the analyzers their minimum width.
        for total in [1_000, 1_400, 2_400] as [CGFloat] {
            for requested in [0, 200, 380, 900, .nan] as [CGFloat] {
                let stage = ColumnLayout.stageWidth(requested, total: total)
                checkGreaterOrEqual(stage, ColumnLayout.minStage)
                checkTrue(stage <= ColumnLayout.maxStage)
                checkGreaterOrEqual(total - stage - PanelLayout.divider, ColumnLayout.minAnalyzers - 0.001)
            }
        }
        // The right-hand column: the room's share is clamped so both panels keep their minimum.
        for total in [500, 800, 1_200] as [CGFloat] {
            for share in [0, 0.1, 0.42, 0.9, .nan] as [CGFloat] {
                let room = ColumnLayout.roomHeight(share: share, total: total)
                checkGreaterOrEqual(room, ColumnLayout.minRoom)
                checkTrue(room <= max(ColumnLayout.minRoom, total - PanelLayout.divider - ColumnLayout.minLevels))
            }
        }
        checkEqual(ColumnLayout.roomHeight(share: 0, total: 1_000), ColumnLayout.roomHeight(share: ColumnLayout.defaultRoomShare, total: 1_000))
        for size in [CGSize(width: 300, height: 300), CGSize(width: 380, height: 420), CGSize(width: 560, height: 800)] {
            for format in [SpeakerLayout.lcr, .s512, .s916] {
                let stage = SoundstageLayout(size: size, layout: format, part: .levels)
                let stereo = SoundstageLayout(size: size, presence: 0, layout: format, part: .levels)
                let halfway = SoundstageLayout(size: size, presence: 0.5, layout: format, part: .levels)
                for layout in [stage, halfway, stereo] {
                    checkEqual(layout.columns.count, format.channelCount)
                    // Columns sit side by side without overlapping, right of the dB scale, inside the meter block.
                    let slots = layout.columns.sorted { $0.minX < $1.minX }
                    for (left, right) in zip(slots, slots.dropFirst()) { checkTrue(left.maxX <= right.minX + 0.001) }
                    for column in layout.columns where column.width > 0 {
                        checkTrue(column.minX >= layout.scale.minX - 0.001 && column.maxX <= layout.block.maxX + 0.001)
                    }
                    for header in layout.headers where header.rect.width > 0 {
                        checkTrue(header.rect.maxY <= layout.scale.minY)
                    }
                    checkTrue(layout.stageWell.contains(layout.block))
                    checkTrue(layout.block.contains(layout.scale))
                    checkTrue(layout.axisMaxX < layout.scale.minX)
                    for index in layout.columns.indices where layout.columns[index].width > 0 {
                        checkTrue(layout.columns[index].insetBy(dx: -0.001, dy: -0.001).contains(layout.bar(index)))
                        checkTrue(layout.readoutPoint(index).y < layout.cap(index).minY)
                        checkTrue(layout.cap(index).maxY <= layout.scale.minY)
                        checkEqual(Double(layout.cap(index).midX), Double(layout.bar(index).midX), accuracy: 0.001)
                        checkEqual(layout.overTrack(index).minY, layout.bar(index).minY)
                        checkEqual(Double(layout.overTrack(index).maxY), Double(layout.y(decibels: 0)), accuracy: 0.001)
                        checkTrue(layout.namePoint(index).y > layout.scale.maxY)
                    }
                }
                // Correlation only in Stereo: the section folds away in Atmos and the meters take the height.
                checkEqual(stage.correlationWeight, 0)
                checkEqual(stereo.correlationWeight, 1)
                checkEqual(Double(halfway.correlationWeight), 0.5, accuracy: 1e-9)
                checkGreater(stage.block.height, stereo.block.height)
                checkTrue(stereo.block.maxY <= stereo.correlationArea.minY)
                checkTrue(stereo.stageWell.contains(stereo.correlationArea))
                checkTrue(stereo.correlationArea.contains(stereo.correlationTrack))
                // Bars read up from −70 dBFS at the foot, 0 dB below the over zone, +3 dB at the top.
                checkEqual(stage.y(decibels: -70), stage.scale.maxY)
                checkEqual(Double(stage.y(decibels: 3)), Double(stage.scale.minY), accuracy: 0.001)
                checkEqual(Double(stage.y(decibels: 9)), Double(stage.scale.minY), accuracy: 0.001)
                checkGreater(stage.y(decibels: 0), stage.y(decibels: 1))
                checkGreater(stage.y(decibels: -6), stage.y(decibels: 0))
                // Correlation reads left to right, −1 … 0 … +1, inside the track's rounded ends.
                let track = stereo.correlationTrack
                checkEqual(Double(stereo.correlationX(0)), Double(track.midX), accuracy: 0.001)
                checkEqual(Double(stereo.correlationX(-1)), Double(track.minX + SoundstageLayout.laneCap), accuracy: 0.001)
                checkEqual(Double(stereo.correlationX(1)), Double(track.maxX - SoundstageLayout.laneCap), accuracy: 0.001)
                // Five lanes, top band on top, inside the track and apart.
                checkEqual(stereo.correlationLane(StereoBands.count - 1, of: 5).minY, track.minY)
                checkEqual(Double(stereo.correlationLane(0, of: 5).maxY), Double(track.maxY), accuracy: 0.001)
                for band in 1..<StereoBands.count { checkTrue(stereo.correlationLane(band, of: 5).maxY < stereo.correlationLane(band - 1, of: 5).minY) }
                // One overall lane or three: the section shrinks and the meters take the height back.
                for resolution in StereoBands.Resolution.allCases {
                    let fewer = SoundstageLayout(size: size, presence: 0, layout: format, part: .levels, lanes: CGFloat(resolution.count))
                    checkTrue(fewer.correlationArea.contains(fewer.correlationTrack))
                    checkEqual(Double(fewer.correlationLane(0, of: resolution.count).maxY), Double(fewer.correlationTrack.maxY), accuracy: 0.001)
                    checkEqual(Double(fewer.correlationTrack.height), Double(SoundstageLayout.trackHeight(count: resolution.count)), accuracy: 0.001)
                    checkGreaterOrEqual(fewer.block.height, stereo.block.height)
                    checkTrue(fewer.stageWell.contains(fewer.correlationArea))
                }
                // Mid-switch the bar sits between the two heights, and both lane sets fit inside it.
                let between = SoundstageLayout(size: size, presence: 0, layout: format, part: .levels, lanes: 2)
                checkTrue(between.correlationTrack.height > SoundstageLayout.trackHeight(count: 1)
                          && between.correlationTrack.height < SoundstageLayout.trackHeight(count: 3))
                checkEqual(between.correlationLane(2, of: 3).minY, between.correlationTrack.minY)
                checkEqual(Double(stereo.correlationX(-3)), Double(stereo.correlationX(-1)))
                checkGreater(stereo.correlationX(0.5), stereo.correlationX(0.25))
                // Stereo: extended columns narrow to nothing, L and R widen.
                checkTrue(stereo.columns.enumerated().allSatisfy { stereo.speakers[$0.offset].role < 2 || $0.element.width == 0 })
                checkGreaterOrEqual(layout(stereo, "L").width, layout(stage, "L").width)
                // Room: the largest centred square; the stereo stage and its labels stay inside at every zoom.
                let room = SoundstageLayout(size: size, layout: format, part: .room)
                let stereoRoom = SoundstageLayout(size: size, presence: 0, layout: format, part: .room)
                for layout in [room, SoundstageLayout(size: size, presence: 0.5, layout: format, part: .room), stereoRoom] {
                    checkTrue(layout.stageWell.contains(layout.radar))
                    checkEqual(layout.radar.width, min(size.width - 24, size.height - 20))
                    for speaker in layout.speakers where speaker.role < 2 {
                        checkTrue(layout.stageWell.contains(layout.label(speaker)))
                    }
                }
                // Stereometer: the half disc, its rims and labels stay in the well, above the band legend.
                checkTrue(stereoRoom.stageWell.contains(stereoRoom.scopeLabel(angle: 0)))
                checkTrue(stereoRoom.stageWell.contains(stereoRoom.scopeLabel(angle: -45)))
                checkTrue(stereoRoom.stageWell.contains(stereoRoom.scopeLabel(angle: 45)))
                checkTrue(stereoRoom.scopeCenter.y < stereoRoom.scopeLegend.minY)
                checkTrue(stereoRoom.scopeCenter.x - stereoRoom.rimRadius(StereoBands.count - 1) >= stereoRoom.stageWell.minX)
                checkEqual(Double(stereoRoom.scopePoint(angle: 0, fraction: 1).y),
                           Double(stereoRoom.scopeCenter.y - stereoRoom.scopeRadius), accuracy: 0.001)
                for band in 1..<StereoBands.count { checkGreater(stereoRoom.rimRadius(band), stereoRoom.rimRadius(band - 1)) }
            }
        }
        // Immersive room, drawn flat: every speaker name, the floor ring and the axis stay inside the well; the
        // front of the room sits higher and smaller than the rear, the upper layer above the bed, and the fit holds
        // still through a mode change.
        for size in [CGSize(width: 360, height: 170), CGSize(width: 480, height: 240), CGSize(width: 300, height: 420)] {
            for format in SpeakerLayout.allCases {
                typealias P3 = SoundstageLayout.Point3
                let room = SoundstageLayout(size: size, layout: format, part: .room)
                for speaker in room.speakers {
                    checkTrue(room.stageWell.insetBy(dx: 4, dy: 2).contains(room.label(speaker)))
                }
                for azimuth in stride(from: 0.0, to: 360, by: 30) {
                    checkTrue(room.stageWell.contains(room.point(SoundstageLayout.roomPoint(azimuth: azimuth, height: false))))
                }
                checkTrue(room.stageWell.contains(room.point(P3(x: 0, y: SoundstageLayout.axisTop, z: 0))))
                let front = room.project(P3(x: 0, y: 0, z: 1)), rear = room.project(P3(x: 0, y: 0, z: -1))
                checkTrue(front.point.y < rear.point.y && front.scale < rear.scale)
                for speaker in room.speakers where speaker.group == .height {
                    let bed = room.point(SoundstageLayout.roomPoint(azimuth: speaker.azimuth!, height: false))
                    checkTrue(room.point(room.position(speaker)).y < bed.y)
                }
                let stereo = SoundstageLayout(size: size, presence: 0, layout: format, part: .room)
                checkEqual(stereo.stageScale, room.stageScale)
            }
        }
        // Columns widen for small layouts and settle at 30 pt from 14 channels up.
        checkEqual(SoundstageLayout.spatialPitch(channels: 3), 41)
        checkEqual(SoundstageLayout.spatialPitch(channels: 8), 36)
        checkEqual(SoundstageLayout.spatialPitch(channels: 16), 30)
        let roomy = CGSize(width: 900, height: 600)
        checkGreater(layout(SoundstageLayout(size: roomy, layout: .lcr, part: .levels), "L").width,
                     layout(SoundstageLayout(size: roomy, layout: .s916, part: .levels), "L").width)
        // Mono: L alone at full weight, R collapsed, L/R slide to front centre, no correlation section.
        for size in [CGSize(width: 300, height: 360), CGSize(width: 380, height: 480)] {
            for format in [SpeakerLayout.lcr, .s512, .s916] {
                let stereo = SoundstageLayout(size: size, presence: 0, layout: format, part: .levels)
                let mono = SoundstageLayout(size: size, presence: 0, mono: 1, layout: format, part: .levels)
                let monoRoom = SoundstageLayout(size: size, presence: 0, mono: 1, layout: format, part: .room)
                let left = format.speakers.firstIndex { $0.role == Role.left }!
                let right = format.speakers.firstIndex { $0.role == Role.right }!
                checkEqual(mono.columns[right].width, 0)
                checkTrue(mono.columns.enumerated().allSatisfy { $0.offset == left || $0.element.width == 0 })
                checkGreaterOrEqual(mono.columns[left].width, stereo.columns[left].width)
                checkEqual(mono.correlationWeight, 0)
                checkEqual(monoRoom.azimuth(format.speakers[left]), 0)
                checkTrue(monoRoom.stageWell.contains(monoRoom.label(format.speakers[left])))
                checkTrue(mono.stageWell.contains(mono.block))
                checkEqual(format.speakers[left].displayName(mono: 1), "M")
                checkEqual(format.speakers[left].displayName(mono: 0), "L")
            }
        }
        // Mono fold-down: identical sides keep their level, unrelated ones lose 3 dB, inverted ones cancel.
        checkEqual(Double(MeterScale.monoFoldDown(correlation: 1, left: 0.5, right: 0.5)!), 0, accuracy: 0.001)
        checkEqual(Double(MeterScale.monoFoldDown(correlation: 0, left: 0.5, right: 0.5)!), -3.01, accuracy: 0.01)
        checkEqual(Double(MeterScale.monoFoldDown(correlation: -1, left: 0.5, right: 0.5)!), -40, accuracy: 0.001)
        checkEqual(Double(MeterScale.monoFoldDown(correlation: 0, left: 0.5, right: 0)!), -3.01, accuracy: 0.01)
        checkTrue(MeterScale.monoFoldDown(correlation: 0.5, left: 0, right: 0) == nil)
        checkTrue(MeterScale.monoFoldDown(correlation: MeterSnapshot.noCorrelation, left: 0.5, right: 0.5) == nil)
        checkEqual(MeterScale.signedTenths(0.84), "+0.8")
        checkEqual(MeterScale.signedTenths(-0.84), "−0.8")
        checkEqual(MeterScale.signedTenths(0.02), "0.0")
        // VU: 0 VU at −18 dBFS, voltage-linear arc, power sum without LFE, IEC 300 ms ballistics.
        checkEqual(VUScale.vu(fromDecibels: -18), 0)
        checkEqual(VUScale.fraction(vu: 3), 1, accuracy: 1e-9)
        checkEqual(VUScale.fraction(vu: -3), 0.5012, accuracy: 0.001)
        let pair = [Float](repeating: 0.1, count: 2) + [Float](repeating: 0, count: 14)
        let withLFE = [Float(0.1), 0.1, 0, 0.5] + [Float](repeating: 0, count: 12)
        let routed = [Bool](repeating: true, count: Role.count)
        checkEqual(Double(VUScale.aggregate(rms: pair, roles: routed)), -16.99, accuracy: 0.02)
        checkEqual(Double(VUScale.aggregate(rms: withLFE, roles: routed)), -16.99, accuracy: 0.02)
        let ballistics = VUBallistics()
        var time = 0.0, overshoot = 0.0, at300 = 0.0
        _ = ballistics.step(toward: 0.5, at: time)
        while time < 1.5 {
            time += 1.0 / 60
            let position = ballistics.step(toward: 0.5, at: time)
            overshoot = max(overshoot, position / 0.5 - 1)
            if abs(time - 0.3) < 0.5 / 60 { at300 = position / 0.5 }
        }
        checkEqual(at300, 0.99, accuracy: 0.015)
        checkTrue(overshoot > 0.005 && overshoot < 0.02)
        let monoWave = WaveformLayout(size: CGSize(width: 900, height: 260), mono: 1)
        checkEqual(Double(monoWave.lanes[0].height), Double(monoWave.waveform.height), accuracy: 0.001)
        checkEqual(monoWave.lanes[1].height, 0)
        for size in [CGSize(width: 900, height: 260)] {
            // The Waveform well: lanes fill the scope at every presence, and extended lanes only borrow height
            // from L and R, so the panel itself never changes size.
            for height in [PanelLayout.minWaveform - 50, 120, 330] {
                for presence in [0, 0.4, 1] as [CGFloat] {
                    let wave = WaveformLayout(size: CGSize(width: size.width, height: height),
                                              speakers: SpeakerLayout.s916.speakers, presence: presence)
                    checkTrue(wave.well.contains(wave.waveform))
                    checkTrue(wave.waveform.width > size.width * 0.85)
                    checkEqual(Double(wave.lanes.last!.maxY), Double(wave.waveform.maxY), accuracy: 0.01)
                    checkEqual(Double(wave.lanes[0].minY), Double(wave.waveform.minY), accuracy: 0.01)
                    for (upper, lower) in zip(wave.lanes, wave.lanes.dropFirst()) { checkTrue(upper.maxY <= lower.minY + 0.001) }
                    checkTrue(wave.laneY(0, amplitude: 1) >= wave.waveform.minY - 0.001)
                    if presence == 0 { checkTrue(wave.lanes.dropFirst(2).allSatisfy { $0.height == 0 }) }
                }
            }
            let stereoWave = WaveformLayout(size: size)
            checkEqual(stereoWave.lanes.count, 2)
            checkEqual(Double(stereoWave.lanes[0].height), Double(stereoWave.lanes[1].height), accuracy: 0.001)
            // One well: the live spectrum continues the waterfall from "now" on the same frequency rows.
            let spectrogram = SpectrogramLayout(size: CGSize(width: size.width, height: 240))
            checkTrue(spectrogram.spectrum.minX > spectrogram.plot.maxX)
            checkEqual(spectrogram.spectrum.minY, spectrogram.plot.minY)
            checkEqual(spectrogram.spectrum.height, spectrogram.plot.height)
            checkTrue(spectrogram.spectrum.maxX <= size.width)
            checkEqual(spectrogram.x(decibels: MeterScale.spectrumFloor), spectrogram.spectrum.minX)
            checkEqual(spectrogram.x(decibels: 0), spectrogram.spectrum.maxX)
            // Horizontal spectrogram: newest at the right, 20 Hz at the bottom, keys on the plot's frequency axis.
            checkEqual(spectrogram.x(secondsAgo: 0), spectrogram.plot.maxX)
            checkEqual(Double(spectrogram.x(secondsAgo: spectrogram.seconds)), Double(spectrogram.plot.minX), accuracy: 0.001)
            // The span follows the waterfall's width: 8 s when wide, down to 3 s when the spectrum takes the room.
            checkTrue(spectrogram.seconds >= SpectrogramLayout.minSeconds && spectrogram.seconds <= SpectrogramLayout.maxSeconds)
            let wide = SpectrogramLayout(size: CGSize(width: 1_300, height: 300))
            let narrow = SpectrogramLayout(size: CGSize(width: 1_300, height: 300), strip: 5_000)
            checkEqual(wide.seconds, SpectrogramLayout.maxSeconds)
            checkEqual(SpectrogramLayout(size: CGSize(width: 400, height: 300)).seconds, SpectrogramLayout.minSeconds)
            checkTrue(narrow.seconds < wide.seconds)
            checkEqual(Double(spectrogram.y(frequency: 20, sampleRate: 48_000)), Double(spectrogram.plot.maxY), accuracy: 0.001)
            checkEqual(Double(spectrogram.y(midi: 69, sampleRate: 48_000)), Double(spectrogram.y(frequency: 440, sampleRate: 48_000)), accuracy: 0.001)
            checkTrue(spectrogram.keyboard.maxX < spectrogram.plot.minX && spectrogram.keyboard.minY == spectrogram.plot.minY)
            checkTrue(SpectrogramLayout.isBlack(61) && !SpectrogramLayout.isBlack(60) && !SpectrogramLayout.isBlack(64))
            checkEqual((0..<12).filter { SpectrogramLayout.isBlack($0) }, [1, 3, 6, 8, 10])
            checkTrue(SpectrogramLayout.isBlack(-11) && !SpectrogramLayout.isBlack(-12))
            let keysLayout = SpectrogramLayout(size: CGSize(width: 600, height: 300))
            for rate in [44_100.0, 48_000, 96_000] {
                let slope = keysLayout.semitoneHeight(sampleRate: rate)
                checkEqual(keysLayout.y(midi: 60, sampleRate: rate) - keysLayout.y(midi: 61, sampleRate: rate), slope, accuracy: 1e-9)
                checkEqual(keysLayout.y(midi: 30, sampleRate: rate) - keysLayout.y(midi: 120, sampleRate: rate), 90 * slope, accuracy: 1e-6)
            }
        }
    }
}

private func layout(_ layout: SoundstageLayout, _ name: String) -> CGRect {
    layout.columns[layout.speakers.firstIndex { $0.name == name }!]
}
private func checkTrue(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !condition { fputs("FAILED \(file):\(line)\n", stderr); exit(1) }
}
private func checkEqual<T: Equatable>(_ left: T, _ right: T, file: StaticString = #filePath, line: UInt = #line) {
    checkTrue(left == right, file: file, line: line)
}
private func checkEqual<T: BinaryFloatingPoint>(_ left: T, _ right: T, accuracy: T, file: StaticString = #filePath, line: UInt = #line) {
    checkTrue(abs(left - right) <= accuracy, file: file, line: line)
}
private func checkGreater<T: Comparable>(_ left: T, _ right: T, file: StaticString = #filePath, line: UInt = #line) {
    checkTrue(left > right, file: file, line: line)
}
private func checkGreaterOrEqual<T: Comparable>(_ left: T, _ right: T, file: StaticString = #filePath, line: UInt = #line) {
    checkTrue(left >= right, file: file, line: line)
}
private enum TestError: Error { case unexpectedNil }
private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw TestError.unexpectedNil }
    return value
}

@main
struct TestRunner {
    static func main() throws {
        let suite = CoreTests()
        let checks: [(String, () throws -> Void)] = [
            ("ring wrap and overflow", suite.testRingWrapAndOverflow),
            ("mono duplication and clear", suite.testMonoAndClear),
            ("100,000 concurrent snapshot publications", suite.testExchangeKeepsLatestWithoutTearing),
            ("320,000 concurrent audio frames", suite.testConcurrentAudioRingPreservesOrder),
            ("calibrated sine, RMS and antiphase", suite.testCalibratedSineAndAntiphase),
            ("16-role manual channel assignment", suite.testChannelAssignmentAndOverflow),
            ("BS.1770-5 997 Hz reference and LFE exclusion", suite.testLUFSReferenceAndLFEExclusion),
            ("BS.1770-5 channel weights up to 9.1.6 and unrouted roles", suite.testSurroundAndHeightWeights),
            ("4× true peak and EBU loudness range", suite.testTruePeakAndLoudnessRange),
            ("packed L/R FFT, phase correlation and its zones", suite.testCorrelationAndPackedTransform),
            ("energy-weighted correlation integrator with silence reset", suite.testCorrelationIntegrator),
            ("five stereo bands: correlation, width, balance and level from the L/R cross spectrum", suite.testStereoBands),
            ("speaker layouts 3.0 to 9.1.6", suite.testSpeakerLayouts),
            ("chunk boundaries and stereo energy", suite.testChunkBoundariesAndStereoEnergy),
            ("8192 FFT and 512-row fixed spectrogram history", suite.testFullRangeSpectrogramHistory),
            ("critically damped 60 Hz display convergence", suite.testDampedDisplayConvergence),
            ("IEC meter scale and shared panel layouts", suite.testMeterScaleAndLayouts),
            ("stereo ↔ spatial detector attack, hold and silence freeze", suite.testFormatDetectorHysteresis),
            ("stereo waveform envelope columns and serial wrap", suite.testWaveformEnvelopeColumns),
            ("multi-level min/max waveform pyramid, dirty uploads and 32-bit wrap", suite.testMinMaxPyramid),
            ("interpolated low-frequency spectrogram rows", suite.testLowFrequencyRowsInterpolate),
            ("pitch naming and interpolated dominant peak", suite.testPitchAndDominantPeak),
            ("chord notes without overtones, and their keyboard holds", suite.testChordNotesAndHolds),
            ("bass notes at 44.1, 48 and 96 kHz, and silence clearing", suite.testBassNotesAcrossSampleRates),
            ("peak readout gate, hold and attack", suite.testPeakTrackerGateHoldAndAttack),
            ("channel ring wrap and unrouted roles", suite.testChannelRingWrapsAndClearsUnroutedRoles),
            ("resizable loudness summary and its stretching column", suite.testSummaryHeightAndStretch),
            ("constant-cost gated integration matches the block scan", suite.testGatedIntegrationMatchesBlockScan),
            ("60 Hz pipeline: 1/30 s windows, 30 Hz columns, long buffers, held peaks", suite.testPipelineWindowsPacingAndHolds),
            ("Spatial spectrum sums every routed channel, Stereo reads L/R", suite.testSpatialSpectrumSumsRoutedChannels),
            ("localized text keeps instrument terms and units on one line", suite.testLocalizerKeepsTermsAndUnitsTogether)
        ]
        for (name, run) in checks { try run(); print("PASS: \(name)") }
        print("All \(checks.count) core checks passed.")
    }
}
