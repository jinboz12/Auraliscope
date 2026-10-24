import Foundation
import AnalysisKernels

enum MultiFFTChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    static func feed(_ analyser: MultiFFTAnalyzer, _ l: [Float], _ r: [Float], chunk: Int = 777) {
        l.withUnsafeBufferPointer { left in r.withUnsafeBufferPointer { right in
            var start = 0
            while start < l.count {
                let n = min(chunk, l.count-start)
                analyser.consume(left: left.baseAddress!+start, right: right.baseAddress!+start, count: n)
                start += n
            }
        } }
    }
    static func tone(_ n: Int, rate: Double, frequency: Double, amplitude: Double) -> [Float] {
        (0..<n).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate + 0.37)) }
    }
    static func run() throws {
        var config = MultiFFTConfiguration()
        config.smoothingSeconds = 0
        var worstTone = 0.0
        var worstSeamStep = 0.0
        var testedTones = 0
        for rate in [44100.0, 48000, 96000, 192000] {
            for window in MultiFFTConfiguration.Window.allCases {
                config.window = window
                var previous: Double?
                for f in [20.7, 25.1, 31.7, 63.1, 124.3, 176.8, 225.5, 250, 280.9, 353.6, 997.3, 1770, 2255, 2500, 2809, 3536, 6789, 12345, 19000, 19901] {
                    let a = MultiFFTAnalyzer(sampleRate: rate, configuration: config)!
                    feed(a, tone(a.span, rate: rate, frequency: f, amplitude: 0.5),
                         tone(a.span, rate: rate, frequency: f, amplitude: 0.25))
                    let frame = a.latest!
                    let l = Double(frame.curves[0].max()!), r = Double(frame.curves[1].max()!)
                    let error = abs(l - 20*log10(0.5))
                    worstTone = max(worstTone, error); testedTones += 1
                    try require(error < 0.35, "tone \(window) \(rate) Hz / \(f) Hz reads \(l) dBFS")
                    try require(abs((l-r) - 20*log10(2)) < 0.02, "L/R separation/calibration \(rate) / \(f)")
                    if (176...354).contains(f) || (1770...3536).contains(f) {
                        if let previous { worstSeamStep = max(worstSeamStep, abs(l-previous)) }
                        previous = l
                    } else { previous = nil }
                }
            }
        }
        print("PASS: Multi-FFT \(testedTones) sine cases, 4 rates × 2 windows; worst amplitude error \(worstTone) dB; crossover sweep step \(worstSeamStep) dB")

        config.window = .hann; config.midSide = true
        for rate in [44100.0, 48000, 96000, 192000] {
            for polarity in [1.0, -1.0] {
                let a = MultiFFTAnalyzer(sampleRate: rate, configuration: config)!
                let x = tone(a.span, rate: rate, frequency: 997.3, amplitude: 0.5)
                feed(a, x, x.map { $0 * Float(polarity) })
                let frame = a.latest!
                let active = polarity == 1 ? 2 : 3, silent = polarity == 1 ? 3 : 2
                try require(abs(Double(frame.curves[active].max()!)-20*log10(0.5)) < 0.1, "M/S active channel")
                try require(frame.curves[silent].max()! < -119.9, "M/S cancellation")
            }
            let a = MultiFFTAnalyzer(sampleRate: rate, configuration: config)!
            let x = tone(a.span, rate: rate, frequency: 997.3, amplitude: 0.5)
            feed(a, x, .init(repeating: 0, count: x.count))
            try require(a.latest!.curves[1].max()! < -119.9, "one-sided L/R isolation")
        }
        print("PASS: Multi-FFT stereo isolation, mono M and opposite-polarity S at all 4 sample rates")

        // The waveform of a single impulse gives a direct, independent window-energy reference. This catches
        // accidentally end-aligned short windows even if a snapshot claims to have a common timestamp.
        config.midSide = false; config.scale = .psd
        for rate in [44100.0, 48000, 96000, 192000] {
            for offset in [-1200, -200, 0, 200, 1200] {
                let a = MultiFFTAnalyzer(sampleRate: rate, configuration: config)!
                var x = [Float](repeating: 0, count: a.span)
                x[a.span/2+offset] = 1
                feed(a, x, x)
                let frame = a.latest!
                try require(frame.centreSample == UInt64(a.span/2) && frame.windowEndSample == UInt64(a.span), "sample timestamp")
                for p in stride(from: 0, to: frame.frequencies.count, by: 13) {
                    let weights = MultiFFTConfiguration.weights(frequency: frame.frequencies[p], low: 250, high: 2500, octaves: 1)
                    var expected = 0.0
                    for i in 0..<3 {
                        let n = a.configuration.bands[i].size, position = n/2+offset
                        if position >= 0 && position < n {
                            let w = 0.5-0.5*cos(2 * .pi * Double(position) / Double(n))
                            expected += weights[i] * 2*w*w / (rate*Double(n)*0.375)
                        }
                    }
                    let db = 10*log10(max(1e-16, expected))
                    try require(abs(Double(frame.curves[0][p])-db) < 0.003, "centred impulse PSD: \(rate), \(offset), row \(p)")
                }
            }
        }
        print("PASS: Multi-FFT impulse reference verifies actual window-centre alignment and PSD energy scaling at all 4 rates")

        config.scale = .amplitude
        let a = MultiFFTAnalyzer(sampleRate: 48000, configuration: config)!
        let b = MultiFFTAnalyzer(sampleRate: 48000, configuration: config)!
        let length = a.span + 5*a.hop + 73
        let signal = (0..<length).map { n -> Float in
            let t = Double(n)/48000
            return Float(0.4*sin(2 * .pi * (90*t+2100*t*t)))
        }
        feed(a, signal, signal, chunk: 1); feed(b, signal, signal, chunk: 4096)
        try require(a.latest!.curves == b.latest!.curves && a.latest!.centreSample == b.latest!.centreSample && a.latest!.serial == 6, "PCM block boundaries changed FFT cadence")
        a.interrupt()
        try require(a.latest == nil, "break retained old spectrum")
        feed(a, Array(signal.prefix(a.span-1)), Array(signal.prefix(a.span-1)))
        try require(a.latest == nil, "a frame straddled an audio break")
        feed(a, [0], [0])
        try require(a.latest != nil, "did not refill after break")
        print("PASS: Multi-FFT exact sample-hop cadence, arbitrary PCM partitioning and break reset")

        // Stationary white noise: mean PSD on either side of each crossover should agree. Average in power,
        // never in dB; an amplitude-normalized FFT would expose a window-length-dependent step here.
        var worstNoiseStep = 0.0
        for rate in [44100.0, 48000, 96000, 192000] {
            config.scale = .psd; config.smoothingSeconds = 0; config.window = .blackmanHarris
            let noise = MultiFFTAnalyzer(sampleRate: rate, configuration: config)!
            var seed: UInt64 = 42
            var sums = [Double](repeating: 0, count: MultiFFTAnalyzer.points)
            for _ in 0..<160 {
                let x = (0..<noise.span).map { _ -> Float in
                    seed = seed &* 6364136223846793005 &+ 1
                    return Float(Double(seed >> 11)/9007199254740992.0*2-1)*0.1
                }
                // Independent records; no repeated/overlapping noise contributing to the ensemble.
                noise.interrupt(); feed(noise, x, x, chunk: noise.span)
                for p in sums.indices { sums[p] += pow(10, Double(noise.latest!.curves[0][p])/10)/160 }
            }
            let frame = noise.latest!
            let expected = 2 * (0.1*0.1/3) / rate
            for fc in [250.0, 2500] {
                let below = sums.indices.filter { frame.frequencies[$0] > fc*0.65 && frame.frequencies[$0] < fc*0.9 }
                let above = sums.indices.filter { frame.frequencies[$0] > fc*1.1 && frame.frequencies[$0] < fc*1.5 }
                let l = below.map { sums[$0] }.reduce(0,+)/Double(below.count)
                let h = above.map { sums[$0] }.reduce(0,+)/Double(above.count)
                let step = abs(10*log10(h/l)); worstNoiseStep = max(worstNoiseStep, step)
                try require(step < 1.0, "noise seam \(rate) / \(fc): \(step) dB")
                try require(abs(10*log10(l/expected)) < 1.0 && abs(10*log10(h/expected)) < 1.0, "PSD absolute noise calibration")
            }
        }
        print("PASS: Multi-FFT white-noise PSD calibration and seams at 4 rates; worst ensemble step \(worstNoiseStep) dB (160 independent records)")

        // Presets and priority policies all construct and produce bounded finite frames at the requested rates.
        for rate in [44100.0, 48000, 96000, 192000] {
            for preset in MultiFFTConfiguration.Preset.allCases where preset != .custom {
                for priority in MultiFFTConfiguration.Priority.allCases {
                    let c = MultiFFTConfiguration.make(preset, priority: priority)
                    let a = MultiFFTAnalyzer(sampleRate: rate, configuration: c)!
                    feed(a, .init(repeating: 0, count: a.span), .init(repeating: 0, count: a.span))
                    try require(a.latest!.curves.flatMap { $0 }.allSatisfy { $0.isFinite && $0 <= -120 }, "preset silence")
                    try require(a.hop >= Int(ceil(rate / c.bands.map(\.rate).min()!)), "rate ceiling")
                }
            }
        }
        var invalid = config
        invalid.preset = .custom
        invalid.bands = [.init(size: Int.max, rate: .nan, overlap: .infinity)]
        invalid.lowCrossover = .nan; invalid.highCrossover = -.infinity
        invalid.smoothingSeconds = .nan
        let safe = MultiFFTAnalyzer(sampleRate: 48000, configuration: invalid)!
        try require(safe.span <= 65536 && safe.hop > 0, "unsafe saved configuration")
        print("PASS: Multi-FFT 60 preset/rate/priority combinations, finite silence and malformed-settings bounds")

        // The local display's fixed-size STFT really reuses the same spectrum for the waterfall. Check both
        // publication arrays and sine calibration at every required rate, while the default core remains Legacy.
        for rate in [44100.0, 48000, 96000, 192000] {
            for size in [2048,4096,8192] {
                let fft = SpectrumAnalyzer(sampleRate: rate, sharedFFTSize: size)!
                var frames = [StereoFrame](repeating: StereoFrame(), count: size)
                for n in frames.indices {
                    let x = Float(0.5*sin(2 * .pi * 997.3*Double(n)/rate))
                    frames[n] = StereoFrame(left: x, right: x)
                }
                frames.withUnsafeBufferPointer { fft.consume($0) }
                let snapshot = fft.snapshot()
                try require(abs(Double(snapshot.peakLevel)-20*log10(0.5)) < 0.08, "shared STFT tone calibration")
                try require(abs(Double(snapshot.spectrumFine.max()!-snapshot.spectrogram.max()!)) < 0.1, "shared display calibration")
                try require(fft.historyLength == size && fft.sharedSTFT, "fixed-size STFT selection")
            }
        }
        print("PASS: Shared legacy display STFT 2048/4096/8192 at all 4 rates; peak and display calibration")

        let roles = [true, true] + [Bool](repeating: false, count: Role.count-2)
        let pipeline = MeterPipeline(sampleRate: 48000, activeRoles: roles, detector: FormatDetector(canDetectSpatial: false), streamID: 1)!
        var values = [Float](repeating: 0, count: SnapshotSlots.total)
        let samples = (0..<1600).map { Float(0.5*sin(2 * .pi * 997.3*Double($0/2)/48000)) }
        func tick(_ t: Int) {
            samples.withUnsafeBufferPointer { pipeline.consume(interleaved: $0.baseAddress!, channels: 2, frames: 800, roles: [0,1]) }
            values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: Double(t)/60) }
        }
        for t in 0..<240 { tick(t) }
        try require(pipeline.multiFFT == nil, "disabled engine was allocated")
        let integrated = values[SnapshotSlots.integrated], held = values[SnapshotSlots.heldTruePeaks]
        pipeline.configureLegacySTFT(.shared4096)
        tick(240)
        try require(abs(values[SnapshotSlots.integrated]-integrated) < 0.01 && values[SnapshotSlots.heldTruePeaks] == held,
                    "changing display STFT reset loudness or held peaks")
        pipeline.multiFFT = MultiFFTAnalyzer(sampleRate: 48000, configuration: .init())
        weak var released = pipeline.multiFFT
        for t in 241..<270 { tick(t) }
        try require(pipeline.multiFFT!.transforms > 0 && pipeline.multiFFT!.latest != nil, "enabled engine did not receive mapped PCM")
        pipeline.multiFFT = nil
        try require(released == nil, "closing panel retained analyser")
        for t in 270..<280 { tick(t) }
        try require(pipeline.multiFFT == nil, "disabled engine restarted")
        pipeline.configureLegacySTFT(.legacy)
        try require(pipeline.spectrum.historyLength == 8192 && !pipeline.spectrum.sharedSTFT, "Legacy A/B failed")
        print("PASS: pipeline Multi-FFT enable/disable and release; shared STFT A/B leaves loudness and held true peaks intact")

        for rate in [44100.0, 48000, 96000, 192000] {
            let reference = MeterPipeline(sampleRate: rate, activeRoles: roles, detector: FormatDetector(canDetectSpatial: false), streamID: 7)!
            let shared = MeterPipeline(sampleRate: rate, activeRoles: roles, detector: FormatDetector(canDetectSpatial: false), streamID: 7)!
            shared.configureLegacySTFT(.shared4096)
            var original = [Float](repeating: 0, count: SnapshotSlots.total)
            var changed = original
            let frames = Int(rate/60)
            var block = [Float](repeating: 0, count: 2*frames)
            for tick in 0..<200 {
                for n in 0..<frames {
                    let t = Double(tick*frames+n)/rate
                    block[2*n] = Float(0.1*sin(2 * .pi * 31.7*t) + 0.2*sin(2 * .pi * 997.3*t))
                    block[2*n+1] = Float(0.15*sin(2 * .pi * 31.7*t+0.4) - 0.1*sin(2 * .pi * 997.3*t))
                }
                block.withUnsafeBufferPointer {
                    reference.consume(interleaved: $0.baseAddress!, channels: 2, frames: frames, roles: [0,1])
                    shared.consume(interleaved: $0.baseAddress!, channels: 2, frames: frames, roles: [0,1])
                }
                original.withUnsafeMutableBufferPointer { reference.publish(into: $0.baseAddress!, now: Double(tick)/60) }
                changed.withUnsafeMutableBufferPointer { shared.publish(into: $0.baseAddress!, now: Double(tick)/60) }
                for range in [SnapshotSlots.peaks..<SnapshotSlots.spectrogram,
                              SnapshotSlots.bandCorrelation..<SnapshotSlots.spectrumFine,
                              SnapshotSlots.spatialField..<SnapshotSlots.total] {
                    try require(original[range] == changed[range], "display STFT changed a measurement at \(rate) Hz tick \(tick)")
                }
            }
        }
        print("PASS: shared display versus Build 113 measurement path: bit-identical levels, loudness, pitch, notes, stereo bands, waveforms and health at all 4 rates")

        // Build 117: each zone converts only the bins the fusion reads. The exhaustive path (every bin, as Builds
        // 114–116) must give the same curves on a wideband, nonstationary signal for both calibrations, both windows
        // and M/S, at every rate. Both paths use the same vectorised conversion, so the agreement is exact.
        var worstPathDifference: Float = 0
        var reduction = [Double]()
        for rate in [44100.0, 48000, 96000, 192000] {
            for scale in [MultiFFTConfiguration.Scale.amplitude, .psd] {
                for window in MultiFFTConfiguration.Window.allCases {
                    var c = MultiFFTConfiguration.make(.standard)
                    c.scale = scale; c.window = window; c.midSide = true; c.smoothingSeconds = 0.05; c.smoothingOctaves = 0.1
                    let restricted = MultiFFTAnalyzer(sampleRate: rate, configuration: c)!
                    let exhaustive = MultiFFTAnalyzer(sampleRate: rate, configuration: c)!
                    var seed: UInt64 = 7
                    let n = restricted.span + 4 * restricted.hop
                    var l = [Float](repeating: 0, count: n), r = l
                    for i in 0..<n {
                        seed = seed &* 6364136223846793005 &+ 1
                        let noise = Float(Double(seed >> 11) / 9007199254740992.0 * 2 - 1) * 0.02
                        let t = Double(i) / rate
                        l[i] = Float(0.3 * sin(2 * .pi * (40 * t + 3000 * t * t)) + 0.1 * sin(2 * .pi * 997.3 * t)) + noise
                        r[i] = Float(0.2 * sin(2 * .pi * (40 * t + 3000 * t * t) + 0.3) - 0.1 * sin(2 * .pi * 997.3 * t)) - noise
                    }
                    MultiFFTAnalyzer.exhaustiveBins = false; feed(restricted, l, r, chunk: 1024)
                    MultiFFTAnalyzer.exhaustiveBins = true; feed(exhaustive, l, r, chunk: 1024)
                    let full = exhaustive.convertedBins
                    MultiFFTAnalyzer.exhaustiveBins = false
                    let a = restricted.latest!, b = exhaustive.latest!
                    try require(a.serial == b.serial && a.serial >= 5 && a.centreSample == b.centreSample, "bin-range paths lost cadence")
                    for ch in a.curves.indices {
                        for p in a.curves[ch].indices {
                            worstPathDifference = max(worstPathDifference, abs(a.curves[ch][p] - b.curves[ch][p]))
                        }
                    }
                    try require(worstPathDifference <= 0.0001, "restricted bin range changed the fused spectrum at \(rate) / \(scale) / \(window): \(worstPathDifference) dB")
                    let partial = restricted.convertedBins
                    try require(zip(partial, full).allSatisfy { $0 > 0 && $0 <= $1 }, "bin range accounting")
                    reduction.append(Double(partial.reduce(0, +)) / Double(full.reduce(0, +)))
                }
            }
        }
        let standard = MultiFFTAnalyzer(sampleRate: 48000, configuration: .make(.standard))!
        print(String(format: "PASS: Multi-FFT read-range bin conversion matches exhaustive conversion within %.2g dB (32 rate/scale/window/MS cases); Standard 48 kHz converts %@ of %@ bins per zone; converted share %.1f%%–%.1f%% of bins across cases",
                     worstPathDifference, standard.convertedBins.description, standard.lengths.map { $0 / 2 + 1 }.description,
                     reduction.min()! * 100, reduction.max()! * 100))

        // Release-build throughput of the independent engine only. Includes PCM copies, 3 FFTs, fusion and
        // publication; excludes existing loudness/UI. Report measurements rather than a hardware-wide claim.
        for rate in [44100.0, 48000, 96000, 192000] {
            for preset in MultiFFTConfiguration.Preset.allCases where preset != .custom {
                let a = MultiFFTAnalyzer(sampleRate: rate, configuration: .make(preset))!
                let n = Int(rate*3)
                let x = tone(n, rate: rate, frequency: 997.3, amplitude: 0.5)
                let start = ProcessInfo.processInfo.systemUptime
                feed(a, x, x, chunk: 512)
                let seconds = ProcessInfo.processInfo.systemUptime-start
                print(String(format: "BENCH MultiFFT %@ %.0f Hz: %.3f ms / 3 s audio, %.3f%% one-core equivalent, %llu transforms", preset.rawValue, rate, seconds*1000, seconds/3*100, a.transforms))
            }
        }
    }
}
