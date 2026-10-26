import CoreGraphics
import simd
import Foundation
import Darwin
import AudioRing
import AudioToolbox

final class CoreTests {
    func testDomeEnergyGeometry() {
        // Layout fit is independent of programme level; all shell samples stay inside each supported view.
        for view in DomeView.allCases {
            for size in [CGSize(width: 240, height: 160), CGSize(width: 380, height: 320), CGSize(width: 600, height: 540)] {
                for yaw in [-180.0, -37, 0, 123] {
                    let g = DomeGeometry(size: size, view: view, yaw: yaw)
                    for a in stride(from: 0.0, to: 360, by: 15) {
                        for e in stride(from: 0.0, through: 90, by: 15) {
                            let p = g.project(DomeGeometry.direction(azimuth: a, elevation: e))
                            checkTrue(p.x >= 0 && p.x <= size.width && p.y >= 0 && p.y < size.height - 20)
                        }
                    }
                }
            }
        }
        // Every camera height of the Dome view fits too, also in a cramped 720p well.
        for pitch in [DomeGeometry.pitchRange.lowerBound, 24, 45, DomeGeometry.pitchRange.upperBound, 200] {
            for size in [CGSize(width: 340, height: 90), CGSize(width: 380, height: 320)] {
                let g = DomeGeometry(size: size, view: .perspective, yaw: 30, pitch: pitch)
                checkTrue(DomeGeometry.pitchRange.contains(g.pitch))
                for a in stride(from: 0.0, to: 360, by: 15) {
                    for e in stride(from: 0.0, through: 90, by: 15) {
                        let p = g.project(DomeGeometry.direction(azimuth: a, elevation: e))
                        checkTrue(p.x >= 0 && p.x <= size.width && p.y >= 0 && p.y <= size.height)
                    }
                }
            }
        }
        // Zoom scales about the listener and is clamped; fixed views keep their own cameras.
        let plain = DomeGeometry(size: CGSize(width: 380, height: 320)), near = DomeGeometry(size: CGSize(width: 380, height: 320), zoom: 2)
        checkEqual(near.scale, plain.scale * 2, accuracy: 1e-9)
        checkEqual(near.origin, plain.origin)
        checkEqual(DomeGeometry(size: CGSize(width: 380, height: 320), zoom: 40).zoom, DomeGeometry.zoomRange.upperBound)
        checkEqual(DomeGeometry(size: CGSize(width: 380, height: 320), view: .front, yaw: 77).screenRightAzimuth, 90)
        checkEqual(DomeGeometry(size: CGSize(width: 380, height: 320), view: .side, yaw: 77).screenRightAzimuth, 0)
        checkEqual(DomeGeometry(size: CGSize(width: 380, height: 320), view: .top, yaw: 30).screenRightAzimuth, 60)
        // Band choices round-trip, read earlier builds' plain splits, and clamp a single band into its split.
        for choice in [BandChoice(.overall), BandChoice(.three), BandChoice(.five), BandChoice(.three, solo: 1), BandChoice(.five, solo: 4)] {
            checkEqual(BandChoice(rawValue: choice.rawValue), choice)
        }
        checkEqual(BandChoice(rawValue: "three"), BandChoice(.three))
        checkEqual(BandChoice(rawValue: "three.9")?.solo, 2)
        checkEqual(BandChoice(rawValue: "overall.2")?.solo, nil)
        checkTrue(BandChoice(rawValue: "bogus") == nil)
        checkEqual(BandChoice(.three, solo: 1).groups, [1])
        checkEqual(BandChoice(.five).groups, [0, 1, 2, 3, 4])
        checkEqual(BandChoice.range(.three, 1), "120 Hz–2 kHz")
        checkEqual(BandChoice.range(.three, 2), "2–20 kHz")
        checkEqual(BandChoice.range(.five, 0), "20–120 Hz")
        checkEqual(BandChoice(.overall).singles.count, StereoBands.count)
        let layout = SpeakerLayout.s714
        var powers = [Float](repeating: 0, count: Role.count)
        let active = [Bool](repeating: true, count: Role.count)
        powers[Role.center] = 0.25
        powers[Role.lfe] = 100
        let center = DomeGeometry.centroid(layout: layout, active: active, powers: powers)!
        checkEqual(center.x, 0, accuracy: 0.000001)
        checkEqual(center.y, 0, accuracy: 0.000001)
        checkEqual(center.z, 1, accuracy: 0.000001) // LFE must not move the centroid.
        powers[Role.leftTopFront] = 0.25
        let raised = DomeGeometry.centroid(layout: layout, active: active, powers: powers)!
        checkTrue(raised.y > 0 && raised.y < 0.71)
        // Speakers sit on the unit shell at the analysis' own positions (`SpeakerGeometry`), heights at 45°.
        for layout in SpeakerLayout.allCases {
            for speaker in layout.speakers where speaker.group != .lfe {
                let d = DomeGeometry.direction(speaker)!
                checkEqual(d.x*d.x + d.y*d.y + d.z*d.z, 1, accuracy: 0.000001)
                checkEqual(d.y, speaker.group == .height ? sqrt(0.5) : 0, accuracy: 0.000001)
                let f = SpeakerGeometry.direction(role: speaker.role, sidesAtNinety: layout.sidesAtNinety)!
                checkEqual(DomeGeometry.model(SIMD3(Float(f.x), Float(f.y), Float(f.z))).x, d.x, accuracy: 1e-6)
                checkEqual(DomeGeometry.model(SIMD3(Float(f.x), Float(f.y), Float(f.z))).y, d.y, accuracy: 1e-6)
                checkEqual(DomeGeometry.model(SIMD3(Float(f.x), Float(f.y), Float(f.z))).z, d.z, accuracy: 1e-6)
            }
        }
        checkEqual(SpeakerGeometry.azimuth(role: Role.leftSurround, sidesAtNinety: SpeakerLayout.s51.sidesAtNinety), -110)
        checkEqual(SpeakerGeometry.azimuth(role: Role.leftSurround, sidesAtNinety: SpeakerLayout.s714.sidesAtNinety), -90)
        var snapshot = MeterSnapshot()
        snapshot.channelRMS[Role.left] = 0.5
        snapshot.roleBandPower[Role.left * StereoBands.count + 2] = 0.01
        checkEqual(DomeGeometry.power(role: Role.left, band: -1, snapshot: snapshot), 0.25)
        checkEqual(DomeGeometry.power(role: Role.left, band: 2, snapshot: snapshot), 0.01)
        checkEqual(DomeGeometry.power(role: Role.left, band: 4, snapshot: snapshot), 0)
        checkTrue(DomeGeometry.centroid(layout: layout, active: [Bool](repeating: false, count: Role.count), powers: powers) == nil)
        // The body's quad covers the whole shell above the floor in every view, and never leaves the canvas.
        for view in DomeView.allCases {
            for zoom in [1.0, 2.5] {
                let size = CGSize(width: 380, height: 320)
                let g = DomeGeometry(size: size, view: view, yaw: 37, zoom: zoom)
                let u = g.bodyUniforms(opacity: 1, layers: 1, dark: true)
                checkTrue(u.minX >= 0 && u.minY >= 0 && Double(u.maxX) <= size.width && Double(u.maxY) <= size.height)
                for a in stride(from: 0.0, to: 360, by: 15) {
                    for e in stride(from: 0.0, through: 90, by: 15) {
                        let p = g.project(DomeGeometry.direction(azimuth: a, elevation: e))
                        guard p.x >= 0 && p.x <= size.width && p.y >= 0 && p.y <= size.height else { continue }
                        checkTrue(Float(p.x) >= u.minX - 0.01 && Float(p.x) <= u.maxX + 0.01 && Float(p.y) >= u.minY - 0.01
                                  && Float(p.y) <= u.maxY + 0.01)
                    }
                }
            }
        }
        // With a speaker below the ear plane the whole sphere fits the canvas and the body's quad, in every view.
        for view in DomeView.allCases {
            let size = CGSize(width: 380, height: 320)
            let g = DomeGeometry(size: size, view: view, yaw: 37, lower: true)
            let u = g.bodyUniforms(opacity: 1, layers: 1, dark: true)
            for a in stride(from: 0.0, to: 360, by: 15) {
                for e in stride(from: -90.0, through: 90, by: 15) {
                    let p = g.project(DomeGeometry.direction(azimuth: a, elevation: e))
                    checkTrue(p.x >= 0 && p.x <= size.width && p.y >= 0 && p.y <= size.height)
                    checkTrue(Float(p.y) >= u.minY - 0.01 && Float(p.y) <= u.maxY + 0.01)
                }
            }
        }
        checkEqual(MemoryLayout<BodyUniforms>.stride, 92)
        checkEqual(MemoryLayout<RadiantCamera>.stride, 96)
        checkEqual(MemoryLayout<RadiantLook>.stride, 56)
        // Radiant: the loudest band glows near white and the range's foot fades out; a quiet programme glows dimmer
        // and silence not at all; the level body alone has rings.
        checkTrue(Radiant.seen(0) > 0.9 && Radiant.seen(-1) < 0.05 && Radiant.seen(-0.5) > Radiant.seen(-1))
        checkTrue(Radiant.intensity(-2) == 0 && Radiant.intensity(0) == 1)
        checkTrue(Radiant.presence(peak: -70, floor: -60) == 0 && Radiant.presence(peak: -20, floor: -60) == 1
                  && Radiant.presence(peak: -45, floor: -60) < 1)
        var settings = NebulaSettings()
        checkTrue(settings.style == .radiant && settings.rings.isEmpty)
        settings.style = .level
        checkTrue(settings.rings == [-20, -40])
    }

    /// The spec's controlled signals through the real pipeline (Spatial, 7.1.4 or 9.1.6), read back from the
    /// snapshot's spatial field: where each band's energy goes, whether shared energy forms an image, its stability.
    func testSpatialField() {
        let layout714 = SpeakerLayout.s714.roles, layout916 = SpeakerLayout.s916.roles
        struct Gaussian {
            var state: UInt64
            mutating func next() -> Float {
                func uniform() -> Double {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    return Double(state >> 11) / Double(1 << 53)
                }
                return Float((-2 * log(max(1e-12, uniform()))).squareRoot() * cos(2 * .pi * uniform()) * 0.1)
            }
        }
        func field(_ roles: [Int], seconds: Double = 2, threshold: Float = SpatialField.defaultThreshold,
                   _ sample: (Int, Int) -> Float) -> [Float] {
            let pipeline = MeterPipeline(sampleRate: 48_000, activeRoles: (0..<Role.count).map { roles.contains($0) },
                                         detector: FormatDetector(initial: .spatial, canDetectSpatial: true), streamID: 1)!
            pipeline.spatialSpectrum = true
            pipeline.spatialCoherence = threshold
            var buffer = [Float](repeating: 0, count: 800 * roles.count)
            var values = [Float](repeating: 0, count: SnapshotSlots.total)
            var frame = 0
            for tick in 0..<Int(seconds * 60) {
                for i in 0..<800 { for c in 0..<roles.count { buffer[i * roles.count + c] = sample(frame + i, c) } }
                frame += 800
                buffer.withUnsafeBufferPointer { pipeline.consume(interleaved: $0.baseAddress!, channels: roles.count, frames: 800, roles: roles) }
                values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: Double(tick) / 60) }
            }
            return Array(values[SnapshotSlots.spatialField..<(SnapshotSlots.spatialField + SpatialField.floats)])
        }
        func band(_ hz: Double) -> Int { Int(log(hz / 20) / log(1_000) * Double(SpatialField.bandCount)) }
        func images(_ f: [Float], _ b: Int) -> [(energy: Float, position: SIMD3<Float>, stability: Float, spread: Float, xx: Float)] {
            (0..<SpatialField.coherentSlots).compactMap { slot in
                let o = SpatialField.component(band: b, slot: slot)
                guard f[o] > 0 else { return nil }
                return (f[o], SIMD3(f[o + 1], f[o + 2], f[o + 3]), f[o + 10], f[o + 4] + f[o + 7] + f[o + 9], f[o + 4])
            }
        }
        func length(_ p: SIMD3<Float>) -> Float { (p * p).sum().squareRoot() }
        func azimuth(_ p: SIMD3<Float>) -> Double { atan2(Double(p.x), Double(p.y)) * 180 / .pi }
        func independent(_ f: [Float], _ b: Int, _ role: Int) -> Float { f[SpatialField.independent(band: b, role: role)] }
        func total(_ f: [Float], _ b: Int) -> Float {
            (0..<Role.count).reduce(0) { $0 + independent(f, b, $1) } + images(f, b).reduce(0) { $0 + $1.energy }
        }
        func coherentShare(_ f: [Float]) -> Float {
            var shared: Float = 0, all: Float = 0
            for b in 0..<SpatialField.bandCount { shared += images(f, b).reduce(0) { $0 + $1.energy }; all += total(f, b) }
            return all > 0 ? shared / all : 0
        }
        func sine(_ hz: Double, _ n: Int) -> Float { Float(0.5 * sin(2 * .pi * hz * Double(n) / 48_000)) }
        let l = layout714.firstIndex(of: Role.left)!, r = layout714.firstIndex(of: Role.right)!
        let c = layout714.firstIndex(of: Role.center)!, ltf = layout714.firstIndex(of: Role.leftTopFront)!
        let rtf = layout714.firstIndex(of: Role.rightTopFront)!
        let k = band(1_000)
        // 1: 1 kHz in front-left only: all of it independent at L (a 0.5 sine is −9 dBFS mean square), no image.
        let one = field(layout714) { n, ch in ch == l ? sine(1_000, n) : 0 }
        checkEqual(one[SpatialField.status], 1)
        checkEqual(10 * log10(independent(one, k, Role.left)), -9.03, accuracy: 0.3)
        checkTrue(images(one, k).isEmpty)
        // 2: identical noise in L and R: one in-phase image at the phantom centre, nothing left at the speakers.
        var g = Gaussian(state: 1)
        var shared = [Float](repeating: 0, count: 48_000 * 3)
        for i in shared.indices { shared[i] = g.next() }
        let two = field(layout714) { n, ch in ch == l || ch == r ? shared[n] : 0 }
        for b in [band(100), k, band(10_000)] {
            let found = images(two, b)
            checkEqual(found.count, 1)
            checkEqual(found[0].position.x, 0, accuracy: 0.02)
            checkEqual(found[0].position.y, Float(cos(Double.pi / 6)), accuracy: 0.02)
            checkTrue(found[0].stability > 0.97)
            checkTrue(independent(two, b, Role.left) + independent(two, b, Role.right) < 0.05 * total(two, b))
        }
        // 3: uncorrelated noise in L and R: no image (chance coherence is corrected for), energy at both speakers.
        var a = Gaussian(state: 2), bNoise = Gaussian(state: 3)
        var left = [Float](repeating: 0, count: 48_000 * 3), right = left
        for i in left.indices { left[i] = a.next(); right[i] = bNoise.next() }
        let three = field(layout714) { n, ch in ch == l ? left[n] : (ch == r ? right[n] : 0) }
        checkTrue(coherentShare(three) < 0.02)
        checkTrue(independent(three, k, Role.left) > 0 && independent(three, k, Role.right) > 0)
        // 4: 200 Hz in L and 4 kHz in R: each band at its own speaker.
        let four = field(layout714) { n, ch in ch == l ? sine(200, n) : (ch == r ? sine(4_000, n) : 0) }
        checkTrue(independent(four, band(200), Role.left) > 100 * independent(four, band(200), Role.right))
        checkTrue(independent(four, band(4_000), Role.right) > 100 * independent(four, band(4_000), Role.left))
        // 5: overhead: a lone Ltf stays at Ltf; coherent Ltf = Rtf images overhead, ahead, at the chord between them.
        let five = field(layout714) { n, ch in ch == ltf ? shared[n] : 0 }
        checkTrue(independent(five, k, Role.leftTopFront) > 0 && images(five, k).isEmpty)
        let raisedPair = field(layout714) { n, ch in ch == ltf || ch == rtf ? shared[n] : 0 }
        let overhead = images(raisedPair, k)
        checkEqual(overhead.count, 1)
        checkEqual(overhead[0].position.x, 0, accuracy: 0.02)
        checkEqual(overhead[0].position.z, Float(sqrt(0.5)), accuracy: 0.02)
        // 6: silence: nothing anywhere.
        let six = field(layout714) { _, _ in 0 }
        checkTrue((0..<SpatialField.bandCount).allSatisfy { total(six, $0) == 0 })
        // 7: independent noise in all 16 channels of 9.1.6: every speaker keeps its own, chance images stay rare.
        var noises = (0..<16).map { Gaussian(state: UInt64(100 + $0)) }
        var each = [[Float]](repeating: [Float](repeating: 0, count: 48_000 * 3), count: 16)
        for ch in 0..<16 { for i in each[ch].indices { each[ch][i] = noises[ch].next() } }
        let seven = field(layout916) { n, ch in each[ch][n] }
        checkTrue(coherentShare(seven) < 0.03)
        for role in layout916 where role != Role.lfe { checkTrue(independent(seven, k, role) > 0) }
        // 8: in phase and anti-phase differ. In phase, a stable phantom at the centre as wide as Frank's regression
        // of perceived width on the energy vector predicts for a pair 60° apart (186.4°·(1 − cos 30°) + 10.7° = 35.7°);
        // anti-phase, no stable centre: wider, and drawn toward the listener.
        let inPhase = images(field(layout714) { n, ch in ch == l || ch == r ? sine(1_000, n) : 0 }, k)
        let antiPhase = images(field(layout714) { n, ch in ch == l ? sine(1_000, n) : (ch == r ? -sine(1_000, n) : 0) }, k)
        checkEqual(inPhase.count, 1)
        checkEqual(antiPhase.count, 1)
        checkTrue(inPhase[0].stability > 0.97 && antiPhase[0].stability < 0.03)
        checkEqual(SpatialField.width(position: inPhase[0].position, spread: inPhase[0].xx), 35.7, accuracy: 1.5)
        checkEqual(length(inPhase[0].position), Float(cos(Double.pi / 6)), accuracy: 0.02)
        checkTrue(antiPhase[0].spread > 2.5 * inPhase[0].spread)
        checkTrue(length(antiPhase[0].position) < 0.6)
        // One speaker's own image is 10.7° wide in the same model.
        checkEqual(SpatialField.width(position: SIMD3(0, 1, 0), spread: 0), 10.7, accuracy: 0.1)
        // A pair panned in phase, L at twice R's amplitude: in the bass the image follows the velocity vector (the
        // tangent law: −10.9°), in the treble the energy vector (−19.1°).
        let panned = field(layout714) { n, ch in ch == l ? shared[n] : (ch == r ? 0.5 * shared[n] : 0) }
        let panLow = images(panned, band(200)), panHigh = images(panned, band(4_000))
        checkEqual(panLow.count, 1)
        checkEqual(panHigh.count, 1)
        checkEqual(azimuth(panLow[0].position), -10.9, accuracy: 1.5)
        checkEqual(azimuth(panHigh[0].position), -19.1, accuracy: 1.5)
        // Two independent phantoms sharing the centre speaker stay two images, either side of it.
        var x = Gaussian(state: 4), y = Gaussian(state: 5)
        var xs = [Float](repeating: 0, count: 48_000 * 3), ys = xs
        for i in xs.indices { xs[i] = x.next(); ys[i] = y.next() }
        let pair = images(field(layout714) { n, ch in ch == l ? xs[n] : (ch == c ? xs[n] + ys[n] : (ch == r ? ys[n] : 0)) }, k)
        checkEqual(pair.count, 2)
        let azimuths = pair.map { azimuth($0.position) }.sorted()
        checkEqual(azimuths[0], -15, accuracy: 5)
        checkEqual(azimuths[1], 15, accuracy: 5)
        // Energy is never counted twice: independent and shared parts add up to the speakers' band energy.
        let speakersOnly = field(layout714) { n, ch in ch == l ? xs[n] + 0.5 * ys[n] : (ch == r ? ys[n] : (ch == c ? 0.3 * xs[n] : 0)) }
        let pipeline = field(layout714, threshold: 0.95) { n, ch in ch == l ? xs[n] + 0.5 * ys[n] : (ch == r ? ys[n] : (ch == c ? 0.3 * xs[n] : 0)) }
        for b in [band(300), k, band(6_000)] { checkEqual(total(speakersOnly, b), total(pipeline, b), accuracy: total(pipeline, b) * 0.002) }
        // The wire form (RESULT tag 53) carries the field within its quantisation.
        let roles = layout714
        var bytes = [UInt8](repeating: 0, count: SpatialFieldWire.size(speakersOnly, channels: roles.count))
        speakersOnly.withUnsafeBufferPointer { f in bytes.withUnsafeMutableBytes { _ = SpatialFieldWire.encode(f.baseAddress!, roles: roles, into: $0.baseAddress!) } }
        var decoded = [Float](repeating: 0, count: SpatialField.floats)
        let ok = bytes.withUnsafeBytes { raw in decoded.withUnsafeMutableBufferPointer { SpatialFieldWire.decode(raw, roles: roles, into: $0.baseAddress!) } }
        checkTrue(ok)
        checkEqual(decoded[SpatialField.status], 1)
        for b in 0..<SpatialField.bandCount {
            for role in roles {
                let sent = independent(speakersOnly, b, role), got = independent(decoded, b, role)
                if sent > 1e-12 { checkEqual(10 * log10(got), 10 * log10(sent), accuracy: 0.26) } else { checkTrue(got < 1e-12) }
            }
            for slot in 0..<SpatialField.coherentSlots {
                let o = SpatialField.component(band: b, slot: slot)
                guard speakersOnly[o] > 1e-12 else { continue }
                checkEqual(10 * log10(decoded[o]), 10 * log10(speakersOnly[o]), accuracy: 0.26)
                for i in 1...3 { checkEqual(decoded[o + i], speakersOnly[o + i], accuracy: 0.005) }
                for i in 4...9 { checkEqual(decoded[o + i], speakersOnly[o + i], accuracy: 0.0001) }
                checkEqual(decoded[o + 10], speakersOnly[o + 10], accuracy: 0.003)
            }
        }
        // Another channel count, or a truncated field, is refused (status 0), never misread.
        let refused = bytes.withUnsafeBytes { raw in decoded.withUnsafeMutableBufferPointer { SpatialFieldWire.decode(raw, roles: [Role.left, Role.right], into: $0.baseAddress!) } }
        checkTrue(!refused && decoded[SpatialField.status] == 0)
    }

    /// The bins (`SpatialPoints`): each at its amplitude-weighted centre of gravity of the speakers, as a spatial
    /// analyser places it, through the real pipeline (7.1.4): a lone speaker's bins sit on it, an amplitude-panned
    /// source exactly where its gains put it at every frequency, two sources sharing a band each at its own place,
    /// uncorrelated L and R spread along the line between them; the bins' energies add up to the band's; the LFE takes
    /// no part; silence leaves none; the wire form (RESULT tag 54) carries them within its quantisation.
    func testSpatialPoints() {
        let roles = SpeakerLayout.s714.roles
        func run(seconds: Double = 1, _ sample: (Int, Int) -> Float) -> (field: [Float], points: [Float]) {
            let pipeline = MeterPipeline(sampleRate: 48_000, activeRoles: (0..<Role.count).map { roles.contains($0) },
                                         detector: FormatDetector(initial: .spatial, canDetectSpatial: true), streamID: 1)!
            pipeline.spatialSpectrum = true
            // The Build 87–97 form, which a Bridge plugin still sends to a display before build 98.
            pipeline.spatialLegacyPoints = true
            var buffer = [Float](repeating: 0, count: 800 * roles.count)
            var values = [Float](repeating: 0, count: SnapshotSlots.total)
            var frame = 0
            for tick in 0..<Int(seconds * 60) {
                for i in 0..<800 { for c in 0..<roles.count { buffer[i * roles.count + c] = sample(frame + i, c) } }
                frame += 800
                buffer.withUnsafeBufferPointer { pipeline.consume(interleaved: $0.baseAddress!, channels: roles.count, frames: 800, roles: roles) }
                values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: Double(tick) / 60) }
            }
            return (Array(values[SnapshotSlots.spatialField..<(SnapshotSlots.spatialField + SpatialField.floats)]),
                    Array(values[SnapshotSlots.spatialPoints..<(SnapshotSlots.spatialPoints + SpatialPoints.floats)]))
        }
        func band(_ hz: Double) -> Int { Int(log(hz / 20) / log(1_000) * Double(SpatialField.bandCount)) }
        func points(_ p: [Float], _ b: Int) -> [(position: SIMD3<Float>, energy: Float)] {
            (0..<Int(p[SpatialPoints.count(band: b)])).map { i in
                let o = SpatialPoints.point(band: b, index: i)
                return (SIMD3(p[o], p[o + 1], p[o + 2]), p[o + 3])
            }
        }
        func bandEnergy(_ f: [Float], _ b: Int) -> Float {
            var total: Float = 0
            for role in 0..<Role.count where role != Role.lfe { total += f[SpatialField.independent(band: b, role: role)] }
            for slot in 0..<SpatialField.coherentSlots { total += f[SpatialField.component(band: b, slot: slot)] }
            return total
        }
        func direction(_ role: Int) -> SIMD3<Float> {
            let d = SpeakerGeometry.direction(role: role, sidesAtNinety: true)!
            return SIMD3(Float(d.x), Float(d.y), Float(d.z))
        }
        struct Noise {
            var state: UInt64
            mutating func next() -> Float {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return (Float(state >> 40) / Float(1 << 24) - 0.5) * 0.4
            }
        }
        func sine(_ hz: Double, _ n: Int) -> Float { Float(0.5 * sin(2 * .pi * hz * Double(n) / 48_000)) }
        let l = roles.firstIndex(of: Role.left)!, r = roles.firstIndex(of: Role.right)!, lfe = roles.firstIndex(of: Role.lfe)!
        let left = direction(Role.left), right = direction(Role.right)
        let k = band(1_000)
        // A lone speaker: every bin on it, carrying the band's energy (a 0.5 sine is −9 dBFS mean square).
        let lone = run { n, ch in ch == l ? sine(1_000, n) : 0 }
        checkEqual(lone.points[SpatialPoints.status], 1)
        let at = points(lone.points, k)
        checkTrue(!at.isEmpty && at.allSatisfy { simd_distance($0.position, left) < 1e-4 })
        checkEqual(10 * log10(at.reduce(0) { $0 + $1.energy }), -9.03, accuracy: 0.3)
        // Amplitude panning, L at twice R's amplitude: every bin at (2 u_L + u_R) / 3, in the bass and the treble alike.
        var g = Noise(state: 7)
        var shared = [Float](repeating: 0, count: 48_000 * 2)
        for i in shared.indices { shared[i] = g.next() }
        let panned = run { n, ch in ch == l ? shared[n] : (ch == r ? 0.5 * shared[n] : 0) }
        let expected = (2 * left + right) / 3
        for b in [band(200), k, band(4_000), band(12_000)] {
            let found = points(panned.points, b)
            checkTrue(!found.isEmpty && found.allSatisfy { simd_distance($0.position, expected) < 2e-3 })
            // Their energies add up to the band's (a wide band's are drawn in proportion to their energy).
            checkEqual(found.reduce(0) { $0 + $1.energy }, bandEnergy(panned.field, b), accuracy: bandEnergy(panned.field, b) * 0.01)
        }
        checkTrue(points(panned.points, band(12_000)).count <= SpatialPoints.perBand)
        // Two sources in one band, a quarter and three quarters of the way through it: one in L only, one equally in L
        // and R. Each keeps its own place: bins at L and bins at the phantom centre, little between.
        let low = SpatialField.edge(k), high = SpatialField.edge(k + 1)
        let f1 = low + 0.2 * (high - low), f2 = low + 0.8 * (high - low)
        let two = points(run { n, ch in ch == l ? sine(f1, n) + sine(f2, n) : (ch == r ? sine(f2, n) : 0) }.points, k)
        let centre = (left + right) / 2
        let all = two.reduce(0) { $0 + $1.energy }
        let atLeft = two.filter { simd_distance($0.position, left) < 0.03 }.reduce(0) { $0 + $1.energy }
        let atCentre = two.filter { simd_distance($0.position, centre) < 0.03 }.reduce(0) { $0 + $1.energy }
        checkTrue(atLeft > 0.25 * all && atCentre > 0.4 * all && atLeft + atCentre > 0.9 * all)
        // Uncorrelated L and R: bins spread along the line between them, on both sides of the centre.
        var a = Noise(state: 8), bNoise = Noise(state: 9)
        var ln = [Float](repeating: 0, count: 48_000 * 2), rn = ln
        for i in ln.indices { ln[i] = a.next(); rn[i] = bNoise.next() }
        let wide = points(run { n, ch in ch == l ? ln[n] : (ch == r ? rn[n] : 0) }.points, band(3_000))
        checkTrue(wide.count > 8)
        checkTrue(wide.allSatisfy { abs($0.position.y - left.y) < 1e-3 && abs($0.position.z) < 1e-4 })
        checkTrue(wide.contains { $0.position.x < -0.15 } && wide.contains { $0.position.x > 0.15 })
        // The LFE has no direction: alone, it leaves no bins.
        let bass = run { n, ch in ch == lfe ? sine(60, n) : 0 }
        checkTrue((0..<SpatialField.bandCount).allSatisfy { points(bass.points, $0).isEmpty })
        // Silence: valid, and empty.
        let quiet = run { _, _ in 0 }
        checkEqual(quiet.points[SpatialPoints.status], 1)
        checkTrue((0..<SpatialField.bandCount).allSatisfy { points(quiet.points, $0).isEmpty })
        // The wire form (RESULT tag 54).
        let sent = panned.points
        var bytes = [UInt8](repeating: 0, count: sent.withUnsafeBufferPointer { SpatialPointsWire.size($0.baseAddress!) })
        sent.withUnsafeBufferPointer { p in bytes.withUnsafeMutableBytes { _ = SpatialPointsWire.encode(p.baseAddress!, into: $0.baseAddress!) } }
        checkTrue(bytes.count <= SpatialPointsWire.largest)
        var decoded = [Float](repeating: 0, count: SpatialPoints.floats)
        checkTrue(bytes.withUnsafeBytes { raw in decoded.withUnsafeMutableBufferPointer { SpatialPointsWire.decode(raw, into: $0.baseAddress!) } })
        checkEqual(decoded[SpatialPoints.status], 1)
        for b in 0..<SpatialField.bandCount {
            // Points below the code's floor (−127 dB) are left out.
            let x = points(sent, b).filter { SpatialFieldWire.energyCode($0.energy) > 0 }, y = points(decoded, b)
            checkEqual(x.count, y.count)
            for (u, v) in zip(x, y) {
                checkTrue(simd_distance(u.position, v.position) < 1e-4)
                checkEqual(10 * log10(v.energy), 10 * log10(u.energy), accuracy: 0.26)
            }
        }
        // A truncated set is refused (status 0), never misread.
        let short = Array(bytes.dropLast())
        checkTrue(!short.withUnsafeBytes { raw in decoded.withUnsafeMutableBufferPointer { SpatialPointsWire.decode(raw, into: $0.baseAddress!) } })
        checkEqual(decoded[SpatialPoints.status], 0)
    }

    /// Radiant's observations (`SpatialObservations`, build 98) through the real pipeline (7.1.4, 48 kHz): every
    /// frequency at the amplitude-weighted centre of gravity of the speakers in the geometry's mapping, one weighted
    /// reduction that keeps energy, each band's centre of gravity and its spread (second moment) exactly whatever the
    /// detail, custom and below-ear placements, meters, mirror and rotation, speakers left out, the LFE, silence, the
    /// header (geometry hash, window time) and the wire form (RESULT tag 58).
    func testSpatialObservations() {
        let roles = SpeakerLayout.s714.roles
        let standard = SpatialGeometry.standard(roles: roles)
        typealias O = (position: SIMD3<Float>, energy: Float, frequency: Float, low: Float, high: Float, spread: Float)
        func run(_ geometry: SpatialGeometry = standard, seconds: Double = 1, _ sample: (Int, Int) -> Float) -> (field: [Float], observations: [Float], frames: Int) {
            let pipeline = MeterPipeline(sampleRate: 48_000, activeRoles: (0..<Role.count).map { roles.contains($0) },
                                         detector: FormatDetector(initial: .spatial, canDetectSpatial: true), streamID: 1)!
            pipeline.spatialSpectrum = true
            pipeline.spatialGeometry = geometry
            var buffer = [Float](repeating: 0, count: 800 * roles.count)
            var values = [Float](repeating: 0, count: SnapshotSlots.total)
            var frame = 0
            for tick in 0..<Int(seconds * 60) {
                for i in 0..<800 { for c in 0..<roles.count { buffer[i * roles.count + c] = sample(frame + i, c) } }
                frame += 800
                buffer.withUnsafeBufferPointer { pipeline.consume(interleaved: $0.baseAddress!, channels: roles.count, frames: 800, roles: roles) }
                values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: Double(tick) / 60) }
            }
            return (Array(values[SnapshotSlots.spatialField..<(SnapshotSlots.spatialField + SpatialField.floats)]),
                    Array(values[SnapshotSlots.spatialObservations..<(SnapshotSlots.spatialObservations + SpatialObservations.floats)]), frame)
        }
        func band(_ hz: Double) -> Int { Int(log(hz / 20) / log(1_000) * Double(SpatialField.bandCount)) }
        func list(_ v: [Float], _ b: Int) -> [O] {
            var start = 0
            for k in 0..<b { start += Int(v[SpatialObservations.counts + k]) }
            return (0..<Int(v[SpatialObservations.counts + b])).map { i in
                let o = SpatialObservations.observation(start + i)
                return (SIMD3(v[o], v[o + 1], v[o + 2]), v[o + 3], v[o + 4], v[o + 5], v[o + 6], v[o + 7])
            }
        }
        func all(_ v: [Float]) -> [O] { (0..<SpatialField.bandCount).flatMap { list(v, $0) } }
        func energy(_ o: [O]) -> Float { o.reduce(0) { $0 + $1.energy } }
        func centroid(_ o: [O]) -> SIMD3<Float> { o.reduce(SIMD3<Float>.zero) { $0 + $1.position * $1.energy } / max(1e-30, energy(o)) }
        /// The energy-weighted second moment about the centre of gravity, each observation's own spread included.
        func moment(_ o: [O]) -> Float {
            let c = centroid(o)
            return o.reduce(0) { $0 + $1.energy * (simd_length_squared($1.position - c) + $1.spread * $1.spread) } / max(1e-30, energy(o))
        }
        func bandEnergy(_ f: [Float], _ b: Int) -> Float {
            var total: Float = 0
            for role in 0..<Role.count where role != Role.lfe { total += f[SpatialField.independent(band: b, role: role)] }
            for slot in 0..<SpatialField.coherentSlots { total += f[SpatialField.component(band: b, slot: slot)] }
            return total
        }
        func unit(_ g: SpatialGeometry, _ role: Int) -> SIMD3<Float> { let d = g.position(role: role)!; return SIMD3(Float(d.x), Float(d.y), Float(d.z)) }
        struct Noise {
            var state: UInt64
            mutating func next() -> Float {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return (Float(state >> 40) / Float(1 << 24) - 0.5) * 0.4
            }
        }
        func sine(_ hz: Double, _ n: Int) -> Float { Float(0.5 * sin(2 * .pi * hz * Double(n) / 48_000)) }
        let l = roles.firstIndex(of: Role.left)!, r = roles.firstIndex(of: Role.right)!, c = roles.firstIndex(of: Role.center)!
        let lfe = roles.firstIndex(of: Role.lfe)!, ls = roles.firstIndex(of: Role.leftSurround)!
        let left = unit(standard, Role.left), right = unit(standard, Role.right)
        var g = Noise(state: 7)
        var shared = [Float](repeating: 0, count: 48_000 * 2)
        for i in shared.indices { shared[i] = g.next() }

        // A lone speaker: every observation of every band on it, one per band (its bins merged exactly), carrying the
        // tone's energy (a 0.5 sine is −9.03 dBFS mean square); the header names the geometry and the window's time.
        let lone = run { n, ch in ch == l ? sine(1_000, n) : 0 }
        checkEqual(lone.observations[SpatialObservations.Header.status], 1)
        checkEqual(lone.observations[SpatialObservations.Header.source], SpatialObservations.Source.measured.rawValue)
        let loneAll = all(lone.observations)
        // Every bin on L, even 180 dB under the tone: the silent R that shares L's packed transform is zero, not L's
        // float rounding.
        checkTrue(!loneAll.isEmpty && loneAll.allSatisfy { simd_distance($0.position, left) < 1e-5 })
        checkEqual(list(lone.observations, band(1_000)).count, 1)
        checkEqual(10 * log10(energy(loneAll)), -9.03, accuracy: 0.1)
        lone.observations.withUnsafeBufferPointer { v in
            checkEqual(SpatialObservations.hash(v.baseAddress!), standard.hash)
            let end = SpatialObservations.windowEnd(v.baseAddress!)
            checkTrue(end <= UInt64(lone.frames) && end + 1_600 >= UInt64(lone.frames) && end % 800 == 0)
            checkEqual(v[SpatialObservations.Header.windowLength], Float(SpectrumAnalyzer.fftSize))
        }
        // Amplitude panning, L at twice R's amplitude: every observation at (2 u_L + u_R) / 3 at every frequency, one per
        // band, their energies the band's.
        let panned = run { n, ch in ch == l ? shared[n] : (ch == r ? 0.5 * shared[n] : 0) }
        let expected = (2 * left + right) / 3
        checkTrue(all(panned.observations).allSatisfy { simd_distance($0.position, expected) < 1e-4 })
        for b in 1..<SpatialField.bandCount where bandEnergy(panned.field, b) > 0 {
            checkEqual(list(panned.observations, b).count, 1)
            checkEqual(energy(list(panned.observations, b)), bandEnergy(panned.field, b), accuracy: bandEnergy(panned.field, b) * 1e-4)
        }
        // Each keeps its frequency: the 12 kHz band's observation is inside its band and spans its bins.
        let treble = list(panned.observations, band(12_000))[0]
        checkTrue(treble.low < treble.frequency && treble.frequency < treble.high
                  && Double(treble.low) >= SpatialField.edge(band(12_000)) - 6 && Double(treble.high) <= SpatialField.edge(band(12_000) + 1) + 6)
        // Two sources in one band, one in L only and one equally in L and R: each at its own place, little between.
        let k = band(1_000)
        let low = SpatialField.edge(k), high = SpatialField.edge(k + 1)
        let f1 = low + 0.2 * (high - low), f2 = low + 0.8 * (high - low)
        let two = list(run { n, ch in ch == l ? sine(f1, n) + sine(f2, n) : (ch == r ? sine(f2, n) : 0) }.observations, k)
        let centre = (left + right) / 2
        let atLeft = energy(two.filter { simd_distance($0.position, left) < 0.03 })
        let atCentre = energy(two.filter { simd_distance($0.position, centre) < 0.03 })
        checkTrue(atLeft > 0.25 * energy(two) && atCentre > 0.4 * energy(two) && atLeft + atCentre > 0.9 * energy(two))
        // Uncorrelated L and R: observations along the line between them on both sides of the centre. Whatever the
        // detail, every band keeps its energy, its centre of gravity and its second moment (spread included).
        var a = Noise(state: 8), bNoise = Noise(state: 9)
        var ln = [Float](repeating: 0, count: 48_000 * 2), rn = ln
        for i in ln.indices { ln[i] = a.next(); rn[i] = bNoise.next() }
        func wide(_ detail: Int) -> [Float] {
            run(SpatialGeometry(placements: standard.placements, detail: detail, roles: roles)) { n, ch in ch == l ? ln[n] : (ch == r ? rn[n] : 0) }.observations
        }
        let fine = wide(32), coarse = wide(2)
        let line = list(fine, band(3_000))
        checkTrue(line.count > 8 && line.allSatisfy { abs($0.position.y - left.y) < 1e-3 && abs($0.position.z) < 1e-4 })
        checkTrue(line.contains { $0.position.x < -0.15 } && line.contains { $0.position.x > 0.15 })
        checkTrue(all(coarse).count < all(fine).count && all(coarse).count <= 2 * SpatialField.bandCount)
        for b in 0..<SpatialField.bandCount where energy(list(fine, b)) > 0 {
            let x = list(fine, b), y = list(coarse, b)
            checkEqual(energy(y), energy(x), accuracy: energy(x) * 1e-4)
            checkTrue(simd_distance(centroid(y), centroid(x)) < 1e-4)
            checkEqual(moment(y), moment(x), accuracy: max(1e-7, moment(x) * 0.01))
        }
        // The reduction is recorded: coarse detail moved energy, by at most the layout's diameter.
        checkTrue(coarse[SpatialObservations.Header.largestMove] > 0 && coarse[SpatialObservations.Header.largestMove] <= 2.0001
                  && coarse[SpatialObservations.Header.meanMove] <= coarse[SpatialObservations.Header.largestMove])

        // A custom layout with L and R below the ear plane (−20°) at ±45°: the phantom between them lies below the
        // floor, never raised onto it.
        var placements = standard.placements
        placements[Role.left] = SpeakerPlacement(azimuth: -45, elevation: -20)
        placements[Role.right] = SpeakerPlacement(azimuth: 45, elevation: -20)
        let low20 = SpatialGeometry(placements: placements, roles: roles)
        checkTrue(low20.hash != standard.hash && low20.reachesBelow(roles: roles))
        let below = run(low20) { n, ch in ch == l || ch == r ? shared[n] : 0 }
        let under = SIMD3<Float>(0, Float(cos(45 * Double.pi / 180) * cos(20 * Double.pi / 180)), Float(sin(-20 * Double.pi / 180)))
        checkTrue(!all(below.observations).isEmpty && all(below.observations).allSatisfy { simd_distance($0.position, under) < 1e-4 })
        below.observations.withUnsafeBufferPointer { checkEqual(SpatialObservations.hash($0.baseAddress!), low20.hash) }
        // Meters: L 2 m and R 3 m at ±30°, every other speaker 2.5 m; the phantom of equal gains at (s_L + s_R) / 2.
        var metric = standard.placements
        for role in roles { metric[role].distance = 2.5 }
        metric[Role.left].distance = 2
        metric[Role.right].distance = 3
        let meters = SpatialGeometry(placements: metric, mapping: .positions, roles: roles)
        checkEqual(meters.mapping, .positions)
        checkEqual(meters.extent(roles: roles), 3, accuracy: 1e-6)
        let inMeters = run(meters) { n, ch in ch == l || ch == r ? shared[n] : 0 }
        let midpoint = (unit(meters, Role.left) + unit(meters, Role.right)) / 2
        checkTrue(simd_distance(midpoint, SIMD3(0.25, Float(2.5 * cos(Double.pi / 6)), 0)) < 1e-5)
        checkTrue(all(inMeters.observations).allSatisfy { simd_distance($0.position, midpoint) < 1e-4 })
        checkEqual(inMeters.observations[SpatialObservations.Header.mapping], 1)
        // Without every distance the positions mapping is not used: an unknown distance is never taken for 1 m.
        var partial = metric
        partial[Role.center].distance = nil
        checkEqual(SpatialGeometry(placements: partial, mapping: .positions, roles: roles).mapping, .directions)
        // Mirror and rotation: the same signal with the layout mirrored puts every band's centre of gravity at −x; with
        // the layout turned by 30°, turned by 30° about the vertical.
        var odd = standard.placements
        odd[Role.left] = SpeakerPlacement(azimuth: -40, elevation: 5)
        odd[Role.right] = SpeakerPlacement(azimuth: 25, elevation: -10)
        let base = SpatialGeometry(placements: odd, roles: roles)
        func mix(_ n: Int, _ ch: Int) -> Float { ch == l ? shared[n] : (ch == r ? 0.3 * shared[n] : (ch == ls ? 0.5 * ln[n] : 0)) }
        let original = run(base, mix).observations, mirrored = run(base.mirrored(), mix).observations
        let turned = run(base.rotated(by: 30), mix).observations
        let cosT = Float(cos(Double.pi / 6)), sinT = Float(sin(Double.pi / 6))
        for b in 0..<SpatialField.bandCount where energy(list(original, b)) > 1e-12 {
            let p = centroid(list(original, b)), m = centroid(list(mirrored, b)), t = centroid(list(turned, b))
            checkTrue(simd_distance(m, SIMD3(-p.x, p.y, p.z)) < 1e-4)
            checkTrue(simd_distance(t, SIMD3(p.x * cosT + p.y * sinT, -p.x * sinT + p.y * cosT, p.z)) < 1e-4)
        }
        // A speaker left out takes no part: C alone leaves nothing; L with C coherent sits on L.
        var noCentre = standard.placements
        noCentre[Role.center].included = false
        let without = SpatialGeometry(placements: noCentre, roles: roles)
        checkTrue(all(run(without) { n, ch in ch == c ? shared[n] : 0 }.observations).isEmpty)
        checkTrue(all(run(without) { n, ch in ch == c || ch == l ? shared[n] : 0 }.observations).allSatisfy { simd_distance($0.position, left) < 1e-5 })
        // The LFE has no direction; silence is a frame with nothing in it.
        checkTrue(all(run { n, ch in ch == lfe ? sine(60, n) : 0 }.observations).isEmpty)
        let quiet = run { _, _ in 0 }.observations
        checkEqual(quiet[SpatialObservations.Header.status], 1)
        checkEqual(quiet[SpatialObservations.Header.count], 0)

        // The multi-resolution window: bands from 1 kHz on a quarter of the transform, from 4 kHz on an eighth, each
        // ending at the newest sample; the same places for a steady pan, calibrated energy, each observation's zone.
        let fast = SpatialGeometry(placements: standard.placements, window: .multiResolution, roles: roles)
        let quick = run(fast) { n, ch in ch == l ? shared[n] : (ch == r ? 0.5 * shared[n] : 0) }.observations
        checkEqual(quick[SpatialObservations.Header.zones], 3)
        checkEqual(quick[SpatialObservations.Header.zoneWindow], Float(SpectrumAnalyzer.fftSize / 4))
        checkEqual(quick[SpatialObservations.Header.zoneWindow + 1], Float(SpectrumAnalyzer.fftSize / 8))
        checkTrue(all(quick).allSatisfy { simd_distance($0.position, expected) < 1e-4 })
        func zone(_ v: [Float], _ b: Int) -> [Float] {
            var start = 0
            for k in 0..<b { start += Int(v[SpatialObservations.counts + k]) }
            return (0..<Int(v[SpatialObservations.counts + b])).map { v[SpatialObservations.observation(start + $0) + 8] }
        }
        checkTrue(zone(quick, band(500)).allSatisfy { $0 == 0 } && zone(quick, band(2_000)).allSatisfy { $0 == 1 }
                  && zone(quick, band(8_000)).allSatisfy { $0 == 2 } && zone(panned.observations, band(8_000)).allSatisfy { $0 == 0 })
        let toneFast = all(run(fast) { n, ch in ch == l ? sine(5_000, n) : 0 }.observations)
        checkEqual(10 * log10(energy(toneFast)), -9.03, accuracy: 0.1)
        checkTrue(toneFast.allSatisfy { simd_distance($0.position, left) < 1e-5 })

        // The wire form (RESULT tag 58): positions, energies and spreads as sent (f32), frequencies to 1/4096 octave,
        // the geometry's hash and revision and the window's time; a truncated set is refused.
        for frame in [panned.observations, fine, inMeters.observations] {
            var bytes = [UInt8](repeating: 0, count: frame.withUnsafeBufferPointer { SpatialObservationsWire.size($0.baseAddress!) })
            frame.withUnsafeBufferPointer { v in bytes.withUnsafeMutableBytes { _ = SpatialObservationsWire.encode(v.baseAddress!, into: $0.baseAddress!) } }
            checkTrue(bytes.count <= SpatialObservationsWire.largest)
            var decoded = [Float](repeating: 0, count: SpatialObservations.floats)
            checkTrue(bytes.withUnsafeBytes { raw in decoded.withUnsafeMutableBufferPointer { SpatialObservationsWire.decode(raw, sampleRate: 48_000, into: $0.baseAddress!) } })
            for h in [SpatialObservations.Header.status, SpatialObservations.Header.mapping, SpatialObservations.Header.count] {
                checkEqual(decoded[h], frame[h])
            }
            frame.withUnsafeBufferPointer { v in
                decoded.withUnsafeBufferPointer { d in
                    checkEqual(SpatialObservations.hash(d.baseAddress!), SpatialObservations.hash(v.baseAddress!))
                    checkEqual(SpatialObservations.windowEnd(d.baseAddress!), SpatialObservations.windowEnd(v.baseAddress!))
                }
            }
            let x = all(frame), y = all(decoded)
            checkEqual(x.count, y.count)
            for (u, w) in zip(x, y) {
                checkTrue(u.position == w.position && u.energy == w.energy && u.spread == w.spread)
                checkEqual(log2(w.frequency / u.frequency), 0, accuracy: 1.0 / 4096)
            }
            let short = Array(bytes.dropLast())
            checkTrue(!short.withUnsafeBytes { raw in decoded.withUnsafeMutableBufferPointer { SpatialObservationsWire.decode(raw, sampleRate: 48_000, into: $0.baseAddress!) } })
            checkEqual(decoded[SpatialObservations.Header.status], 0)
        }
    }

    /// The Immersive body (`SpatialBody`): a lobe reaches its own level in its own direction; a coherent image points
    /// between its speakers as one lobe, while the same energy uncorrelated stays two lobes with a dip between; energy
    /// out of phase spreads wide and reads out of phase; images recurring across bands merge; layers, the plugin
    /// fallback, hidden speakers and the LFE.
    func testSpatialBody() {
        let layout = SpeakerLayout.s714
        let all = SpatialBody.Layer(bands: 0...(SpatialField.bandCount - 1), fiveBands: Array(0..<StereoBands.count))
        let body = SpatialBody()
        var shown = [Bool](repeating: true, count: Role.count)
        func evaluate(_ field: [Float], layers: [SpatialBody.Layer] = [all], settings: SpatialBody.Settings = .init(),
                      power: [Float] = []) {
            field.withUnsafeBufferPointer {
                body.evaluate(field: $0, roleBandPower: power, layout: layout, shown: shown, layers: layers, settings: settings, floor: -60)
            }
        }
        func level(_ azimuth: Double, _ elevation: Double = 0, layer: Int = 0) -> Float {
            body.level(layer: layer, azimuth: azimuth, elevation: elevation)
        }
        func empty() -> [Float] {
            var field = [Float](repeating: 0, count: SpatialField.floats)
            field[SpatialField.status] = 1
            return field
        }
        // A coherent component of `roles` (equal gains, these phases) as the analysis writes it (`SpatialField.image`).
        func image(_ field: inout [Float], band: Int, slot: Int = 0, energy: Float, roles: [Int], phases: [Float]) {
            let o = SpatialField.component(band: band, slot: slot)
            var directions = roles.map { role -> SIMD3<Float> in
                let d = SpeakerGeometry.direction(role: role, sidesAtNinety: layout.sidesAtNinety)!
                return SIMD3(Float(d.x), Float(d.y), Float(d.z))
            }
            var energies = [Float](repeating: 1, count: roles.count)
            var cosines = phases.map { cos($0) }, sines = phases.map { sin($0) }
            field.withUnsafeMutableBufferPointer { f in
                SpatialField.image(count: roles.count, directions: &directions, energies: &energies, cosines: &cosines, sines: &sines,
                                   velocityWeight: SpatialField.velocityWeight(hz: SpatialField.centre(band)), into: f.baseAddress! + o)
            }
            field[o + SpatialField.Component.energy] = energy
            field[o + SpatialField.Component.coherence] = 1
        }
        // How far either side of `azimuth` the layer stays within 10 dB of its level there.
        func halfWidth(_ azimuth: Double) -> Double {
            let peak = level(azimuth)
            var offset = 0.0
            while offset < 180, level(azimuth + offset + 3) > peak - 10 { offset += 3 }
            return offset
        }
        let k = 54 // about 1 kHz
        // One speaker at −20 dBFS: −20 toward it, 10 dB lower 30° away, nothing behind.
        var one = empty()
        one[SpatialField.independent(band: k, role: Role.left)] = 0.01
        evaluate(one)
        checkEqual(level(-30), -20, accuracy: 0.01)
        checkTrue(level(0) < level(-30) - 9)
        checkTrue(level(150) < -100)
        checkEqual(body.lobes[0].count, 1)
        checkEqual(body.lobes[0][0].width, 10.7, accuracy: 0.1)
        // The same energy shared coherently by L and R, in phase: one lobe at the centre at its level, higher there
        // than toward either speaker; uncorrelated instead: two lobes at −23 dBFS with at least 6 dB less between.
        var coherent = empty()
        image(&coherent, band: k, energy: 0.01, roles: [Role.left, Role.right], phases: [0, 0])
        evaluate(coherent)
        checkEqual(level(0), -20, accuracy: 0.05)
        checkTrue(level(0) > level(-30) + 3 && level(0) > level(30) + 3)
        checkEqual(Double(body.lobes[0][0].width), 35.7, accuracy: 1.5)
        checkTrue(body.unstable[SpatialBody.nearest(SIMD3(0, 1, 0))] < 1e-6)
        let inPhaseWidth = halfWidth(0)
        var apart = empty()
        apart[SpatialField.independent(band: k, role: Role.left)] = 0.005
        apart[SpatialField.independent(band: k, role: Role.right)] = 0.005
        evaluate(apart)
        checkEqual(level(-30), -23, accuracy: 0.1)
        checkEqual(level(30), -23, accuracy: 0.1)
        checkTrue(level(0) < level(-30) - 6)
        // Less smoothing deepens the dip, more fills it.
        evaluate(apart, settings: .init(smoothing: 10))
        let sharp = level(-30) - level(0)
        evaluate(apart, settings: .init(smoothing: 60))
        checkTrue(sharp > 15 && level(-30) - level(0) < 3)
        // Anti-phase: one lobe toward the front, at least twice as wide as the in-phase one, almost all out of phase.
        var anti = empty()
        image(&anti, band: k, energy: 0.01, roles: [Role.left, Role.right], phases: [0, .pi])
        evaluate(anti)
        let i = SpatialBody.nearest(SIMD3(0, 1, 0))
        checkTrue(halfWidth(0) > 2 * inPhaseWidth)
        checkTrue(body.unstable[i] / body.energy[i] > 0.95)
        checkTrue(body.lobes[0][0].width > 2.5 * 35.7)
        // One image recurring in 31 bands is one lobe with their energy; two images either side of C stay two.
        var recurring = empty()
        for band in 30...60 { image(&recurring, band: band, energy: 0.001, roles: [Role.left, Role.right], phases: [0, 0]) }
        evaluate(recurring)
        checkEqual(body.lobes[0].count, 1)
        checkEqual(level(0), 10 * log10(Float(0.031)), accuracy: 0.05)
        var pair = empty()
        image(&pair, band: k, slot: 0, energy: 0.01, roles: [Role.left, Role.center], phases: [0, 0])
        image(&pair, band: k, slot: 1, energy: 0.01, roles: [Role.center, Role.right], phases: [0, 0])
        evaluate(pair)
        checkEqual(body.lobes[0].count, 2)
        checkTrue(level(-15) > level(-45) + 3 && level(15) > level(45) + 3)
        // Layers: 87 Hz at L in the lower one, 6.5 kHz at R in the upper one, each alone.
        var split = empty()
        split[SpatialField.independent(band: 20, role: Role.left)] = 0.01
        split[SpatialField.independent(band: 80, role: Role.right)] = 0.01
        evaluate(split, layers: [SpatialBody.Layer(bands: 0...47, fiveBands: [0, 1]), SpatialBody.Layer(bands: 48...95, fiveBands: [2, 3, 4])])
        checkEqual(body.layerCount, 2)
        checkEqual(level(-30, layer: 0), -20, accuracy: 0.01)
        checkTrue(level(30, layer: 0) < -50)
        checkEqual(level(30, layer: 1), -20, accuracy: 0.01)
        checkTrue(level(-30, layer: 1) < -50)
        // Colour by frequency: per direction, the five analysis bands' energies add up to the level's, the 87 Hz at L
        // lands in the lowest band and the 6.5 kHz at R in the 2–8 kHz band, and an image keeps its bands across a merge.
        evaluate(split)
        let left = SpatialBody.nearest(SIMD3(Float(-0.5), Float(0.866), 0)), right = SpatialBody.nearest(SIMD3(Float(0.5), Float(0.866), 0))
        let leftFives = body.fives(layer: 0, index: left), rightFives = body.fives(layer: 0, index: right)
        checkEqual(leftFives.sum(), body.energy[left], accuracy: body.energy[left] * 1e-4)
        checkEqual(rightFives.sum(), body.energy[right], accuracy: body.energy[right] * 1e-4)
        checkTrue(leftFives[0] > 0.99 * leftFives.sum() && rightFives[3] > 0.99 * rightFives.sum())
        checkEqual(Double(body.lobes[0].first { $0.kind == .speaker(Role.left) }?.centroid ?? 0), SpatialField.centre(20), accuracy: 1)
        evaluate(recurring)
        let centre = SpatialBody.nearest(SIMD3(0, 1, 0)), merged = body.fives(layer: 0, index: centre)
        checkEqual(merged.sum(), body.energy[centre], accuracy: body.energy[centre] * 1e-4)
        checkTrue(merged[1] > 0 && merged[2] > 0 && merged[0] == 0 && merged[4] == 0)
        // The spectral scale: the band hues at their centres, red at the bottom to violet at the top.
        checkTrue(SpectralHue.at(hz: 20) == SpectralHue.bands[0] && SpectralHue.at(hz: 20_000) == SpectralHue.bands[4])
        checkTrue(simd_distance(SpectralHue.at(hz: 1_000), SpectralHue.bands[2]) < 0.01)
        // A plugin without a field: each channel's band power at its speaker.
        var fallback = [Float](repeating: 0, count: SpatialField.floats)
        fallback[SpatialField.status] = SpatialFieldWire.unsupported
        var power = [Float](repeating: 0, count: Role.count * StereoBands.count)
        power[Role.leftTopFront * StereoBands.count + 2] = 0.01
        evaluate(fallback, power: power)
        checkEqual(level(-45, 45), -20, accuracy: 0.01)
        // A hidden speaker draws nothing; the LFE never shapes the body but is measured.
        shown[Role.left] = false
        evaluate(one)
        checkTrue(body.lobes[0].isEmpty && level(-30) < -100)
        shown[Role.left] = true
        var lfe = empty()
        lfe[SpatialField.independent(band: 10, role: Role.lfe)] = 0.01
        evaluate(lfe)
        checkEqual(body.lfe, 0.01, accuracy: 1e-6)
        checkTrue(body.energy.prefix(body.layerCount * SpatialBody.count).allSatisfy { $0 == 0 })
        // No field, nothing.
        evaluate([Float](repeating: 0, count: SpatialField.floats))
        checkTrue(body.lobes[0].isEmpty && body.energy.prefix(body.layerCount * SpatialBody.count).allSatisfy { $0 == 0 })
        // The fast exponential and logarithm the body runs on.
        for x in stride(from: Float(-80), through: 0, by: 0.37) { checkEqual(SpatialBody.exp(x) / exp(x), 1, accuracy: 2e-5) }
        for x in [Float(1e-12), 3.7e-7, 0.001, 0.5, 1, 7.3, 1_234] { checkEqual(SpatialBody.log10(x), log10(x), accuracy: 1e-4) }
        // The level body's radius scale and its rings.
        var scale = NebulaSettings()
        scale.style = .level
        checkEqual(scale.radius(decibels: -20), Float(2.0 / 3), accuracy: 1e-6)
        checkEqual(scale.radius(decibels: -70), 0)
        checkEqual(scale.radius(decibels: 3), 1)
        checkEqual(scale.rings, [-20, -40])
        var deep = scale
        deep.floor = -90
        checkEqual(deep.rings, [-20, -40, -60, -80])
    }

    func testLocalizerKeepsTermsAndUnitsTogether() {
        let nbsp = "\u{00A0}"
        checkEqual(Localizer.typeset("采用 ITU-R BS.1770-5 测量"), "采用 ITU-R\(nbsp)BS.1770-5 测量")
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
        // Instrumented producers may still be publishing when the timed read loop ends.
        // Drain their final publication before checking the latest generation.
        if meter_exchange_read(exchange, &result) != 0 {
            checkGreaterOrEqual(result[0], latest)
            checkTrue(result.allSatisfy { $0 == result[0] })
            latest = result[0]
        }
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
        // A 720p screen: the summary starts at its minimum and the columns below keep their short minimums.
        checkEqual(HeroLayout.height(0, tall: false, window: 652), HeroLayout.minHeight)
        checkTrue(!HeroLayout.showsGauge(height: HeroLayout.minHeight))
        checkTrue(HeroLayout.showsGauge(height: HeroLayout.defaultHeight(tall: false)))
        checkTrue(628 - HeroLayout.minHeight - HeroLayout.reservedBelow >= 0)
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

    /// The output-tap IOProc: one interleaved stream goes straight to the ring through the role map; several
    /// streams (or more channels than are kept) are interleaved first, a stream without data reading as silence.
    func testTapIOProcRoutesStreams() throws {
        let ring = try unwrap(channel_ring_create(64))
        defer { channel_ring_destroy(ring) }
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 64 * 4)
        defer { storage.deallocate() }
        var context = CaptureContext()
        context.ring = ring
        context.storage = storage
        context.max_frames = 64
        context.channels = 4
        withUnsafeMutableBytes(of: &context.source_for_role) { raw in
            let roles = raw.bindMemory(to: Int32.self)
            for role in 0..<Role.count { roles[role] = -1 }
            roles[Role.left] = 3
            roles[Role.right] = 0
            roles[Role.center] = 2
        }
        var time = AudioTimeStamp()
        var output = AudioBufferList()
        var frames = [ChannelFrame](repeating: ChannelFrame(), count: 8)
        func run(_ buffers: [(channels: UInt32, samples: [Float]?)]) -> UInt32 {
            let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
            defer { free(list.unsafeMutablePointer) }
            var storage: [UnsafeMutablePointer<Float>] = []
            defer { storage.forEach { $0.deallocate() } }
            for (index, buffer) in buffers.enumerated() {
                var data: UnsafeMutableRawPointer?
                let count = buffer.samples?.count ?? 0
                if let samples = buffer.samples {
                    let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
                    pointer.initialize(from: samples, count: count)
                    storage.append(pointer)
                    data = UnsafeMutableRawPointer(pointer)
                }
                list[index] = AudioBuffer(mNumberChannels: buffer.channels, mDataByteSize: UInt32(count * 4), mData: data)
            }
            _ = withUnsafeMutablePointer(to: &context) { pointer in
                capture_tap_io_proc(0, &time, list.unsafePointer, &time, &output, &time, UnsafeMutableRawPointer(pointer))
            }
            return channel_ring_read(ring, &frames, 8)
        }
        // One interleaved 4-channel stream, two frames.
        checkEqual(run([(4, [1, 2, 3, 4, 11, 12, 13, 14])]), 2)
        checkEqual(frames.prefix(2).map(\.left), [4, 14])
        checkEqual(frames.prefix(2).map(\.right), [1, 11])
        checkEqual(frames.prefix(2).map(\.center), [3, 13])
        checkTrue(frames.prefix(2).allSatisfy { $0.lfe == 0 })
        // Two 2-channel streams read as channels 0–1 and 2–3.
        checkEqual(run([(2, [1, 2, 11, 12]), (2, [3, 4, 13, 14])]), 2)
        checkEqual(frames.prefix(2).map(\.left), [4, 14])
        checkEqual(frames.prefix(2).map(\.right), [1, 11])
        checkEqual(frames.prefix(2).map(\.center), [3, 13])
        // A stream without data is silence; the frame count comes from the one that has it.
        checkEqual(run([(2, nil), (2, [3, 4, 13, 14])]), 2)
        checkEqual(frames.prefix(2).map(\.right), [0, 0])
        checkEqual(frames.prefix(2).map(\.left), [4, 14])
        // A wider stream than is kept: only the first four channels count.
        checkEqual(run([(6, [1, 2, 3, 4, 5, 6])]), 1)
        checkEqual(frames[0].left, 4)
        checkEqual(frames[0].right, 1)
    }

    func testGatedIntegrationMatchesBlockScan() throws {
        // The former implementation: rescan every gated block.
        func reference(_ blocks: [Double]) -> Float {
            guard !blocks.isEmpty else { return -100 }
            let mean = blocks.reduce(0, +) / Double(blocks.count)
            let threshold = mean * 0.1 // −10 LU is one tenth of the mean energy.
            let above = blocks.filter { $0 > threshold }
            return above.isEmpty ? -100 : LoudnessAnalyzer.loudness(above.reduce(0, +) / Double(above.count))
        }
        var generator = RegressionGenerator()
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

        // Silent roles are left out of the transforms: 7.1.4 carrying stereo reads exactly like Stereo, and
        // silence everywhere reads the floor.
        let immersive = try unwrap(SpectrumAnalyzer(sampleRate: 48_000, recording: [Bool](repeating: true, count: 12) + [Bool](repeating: false, count: 4)))
        immersive.recordsSpatial = true
        let music = (0..<SpectrumAnalyzer.fftSize).map { i -> ChannelFrame in
            var frame = ChannelFrame()
            frame.left = Float(0.3 * sin(2 * .pi * 1_000 * Double(i) / 48_000))
            frame.right = Float(0.2 * sin(2 * .pi * 3_000 * Double(i) / 48_000))
            return frame
        }
        music.withUnsafeBufferPointer { immersive.consume($0) }
        var pair = [Float](repeating: -120, count: MeterSnapshot.bandCount)
        var room = pair
        _ = immersive.refreshSpectrum(into: &pair)
        _ = immersive.refreshSpectrum(into: &room, roles: immersive.spatialRoles)
        for index in pair.indices { checkEqual(room[index], pair[index], accuracy: 0.0001) }
        let quiet = [ChannelFrame](repeating: ChannelFrame(), count: SpectrumAnalyzer.fftSize)
        quiet.withUnsafeBufferPointer { immersive.consume($0) }
        _ = immersive.refreshSpectrum(into: &room, roles: immersive.spatialRoles)
        checkTrue(room.allSatisfy { $0 <= -119.9 })
        checkTrue(immersive.roleBandPower.allSatisfy { $0 == 0 })
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

    func testKWeightingAcrossSampleRates() throws {
        // The K-weighting is defined at 48 kHz; other rates carry the same analog response, within 0.006 dB up
        // to 20 kHz. Single-precision filtering missed that by up to 0.24 dB at 20 Hz (384 kHz).
        func integrated(_ frequency: Double, _ rate: Double) throws -> Float {
            let analyzer = try unwrap(LoudnessAnalyzer(sampleRate: rate))
            var frames = [ChannelFrame](repeating: ChannelFrame(), count: 4096)
            var position = 0
            let total = Int(rate * 3)
            while position < total {
                let count = min(frames.count, total - position)
                for i in 0..<count {
                    frames[i].left = Float(0.5 * sin(2 * Double.pi * frequency * Double(position + i) / rate + 0.3))
                }
                frames.withUnsafeBufferPointer { analyzer.consume(UnsafeBufferPointer(rebasing: $0[0..<count])) }
                position += count
            }
            return analyzer.snapshot().integrated
        }
        for frequency in [20.0, 40, 100, 1_000, 10_000] {
            let reference = try integrated(frequency, 48_000)
            for rate in [44_100.0, 96_000, 192_000, 384_000] {
                checkEqual(try integrated(frequency, rate), reference, accuracy: 0.01)
            }
        }
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

    func testTruePeakAtSilenceBoundaries() throws {
        // A two-sample burst rings above the sample peak after the input has already gone silent.
        // The result must not depend on where Core Audio splits its buffers, including one-frame buffers.
        // The silence outlasts the fine window (63 samples), which completes the burst's segment.
        // Known preceding silence makes this a physical onset, unlike capture beginning mid-waveform.
        let samples: [Float] = Array(repeating: 0, count: 128) + [1, 1] + Array(repeating: 0, count: 126)
        let active = (0..<Role.count).map { $0 == Role.left }
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000] {
            let factor = rate < 96_000 ? 4 : 2
            // Reference: the fine interpolator evaluated at every fine step of every sample (a 16× or 8× meter).
            let padded = Array(repeating: Float(0), count: TruePeakDetector.fineTaps - 1) + samples
            var expected: Float = 1
            for phase in TruePeakDetector.design(factor: factor * TruePeakDetector.refinement, taps: TruePeakDetector.fineTaps,
                                                 beta: TruePeakDetector.fineBeta) {
                for index in 0...(padded.count - phase.count) {
                    var value = 0.0
                    for tap in phase.indices { value += Double(padded[index + tap]) * Double(phase[tap]) }
                    expected = max(expected, Float(abs(value)))
                }
            }
            checkGreater(expected, 1.1)
            // The parabola between fine steps can only add to that, by the same amount for every split.
            var reference: Float?
            for chunk in [128, 64, 1, 2, 3, 7] {
                let analyzer = try unwrap(LoudnessAnalyzer(sampleRate: rate, activeRoles: active))
                let frames = samples.map { value -> ChannelFrame in
                    var frame = ChannelFrame(); frame.left = value; return frame
                }
                for offset in stride(from: 0, to: frames.count, by: chunk) {
                    frames.withUnsafeBufferPointer { buffer in
                        analyzer.consume(UnsafeBufferPointer(start: buffer.baseAddress! + offset,
                                                             count: min(chunk, frames.count - offset)))
                    }
                }
                let reading = analyzer.snapshot().truePeak[Role.left]
                checkGreaterOrEqual(reading, expected - 0.000001)
                checkTrue(reading <= expected * 1.002)
                checkEqual(reading, reference ?? reading, accuracy: 0.000001)
                reference = reference ?? reading
            }
        }
    }

    func testTruePeakStartsWithoutSyntheticHistory() {
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000] {
            for frequency in [997.0, 1499, 15_000, 20_000] {
                for phase in 0..<8 {
                    let samples = (0..<2048).map {
                        Float(0.5 * sin(2 * Double.pi * (frequency * Double($0) / rate + Double(phase) / 8)))
                    }
                    var reference: Float?
                    for chunk in [1, 7, 257] {
                        let detector = TruePeakDetector(sampleRate: rate, capacity: chunk)
                        samples.withUnsafeBufferPointer { input in
                            for offset in stride(from: 0, to: samples.count, by: chunk) {
                                let count = min(chunk, samples.count - offset)
                                let peak = samples[offset..<(offset + count)].map { abs($0) }.max()!
                                detector.process(role: Role.left, signal: input.baseAddress! + offset,
                                                 count: count, samplePeak: peak)
                            }
                        }
                        let peak = detector.take(role: Role.left)
                        checkEqual(MeterScale.decibels(peak), -6.0206, accuracy: 0.005)
                        checkEqual(peak, reference ?? peak, accuracy: 0.000001)
                        reference = peak
                    }
                }
            }
            // Nonzero history at the end of priming must drain into real, observed silence.
            let samples: [Float] = Array(repeating: 0, count: 63) + [1, 1] + Array(repeating: 0, count: 128)
            var reference: Float?
            for chunk in [1, 7, 65, 193] {
                let detector = TruePeakDetector(sampleRate: rate, capacity: chunk)
                samples.withUnsafeBufferPointer { input in
                    for offset in stride(from: 0, to: samples.count, by: chunk) {
                        let count = min(chunk, samples.count - offset)
                        detector.process(role: Role.left, signal: input.baseAddress! + offset, count: count,
                                         samplePeak: samples[offset..<(offset + count)].map { abs($0) }.max()!)
                    }
                }
                let peak = detector.take(role: Role.left)
                checkGreater(peak, 1.1)
                checkEqual(peak, reference ?? peak, accuracy: 0.000001)
                reference = peak
            }
            // Even a capture shorter than the warm-up retains its sample maximum.
            let detector = TruePeakDetector(sampleRate: rate, capacity: 1)
            var one: Float = 0.9
            detector.process(role: Role.left, signal: &one, count: 1, samplePeak: one)
            checkEqual(detector.take(role: Role.left), 0.9)
        }
    }

    func testTruePeakNearNyquist() {
        // Inter-sample peaks matter most for bright content: the interpolation must not droop and a crest between
        // the 4× points must still be found. Full-scale tones from 15 kHz to 20 kHz, at sixteen phases each, read
        // within 0.005 dB of the waveform's crest at every rate from 44.1 kHz. (A 12-tap 4× meter read 18 kHz at
        // 48 kHz 0.38 dB low; 1.2.2dev build 59 read 0.054 dB low, and 1.7 dB low at 20 kHz at 44.1 kHz.)
        for rate in [44_100.0, 48_000, 88_200, 96_000, 192_000] {
            var worst: Float = 0, highest: Float = -1
            for frequency in stride(from: 15_000.0, through: 20_000, by: 250) {
                for step in 0..<16 {
                    let phase = Double(step) * Double.pi / 16
                    let signal = (0..<1_024).map { Float(sin(2 * Double.pi * frequency * Double($0) / rate + phase)) }
                    let detector = TruePeakDetector(sampleRate: rate, capacity: 1_024)
                    signal.withUnsafeBufferPointer { buffer in
                        // The onset (a sine switched on at full scale rings) is excluded: its segment is refined
                        // once a point of the next one has both neighbours, within the warm-up.
                        let warmUp = TruePeakDetector.segmentLength + 2
                        detector.process(role: 0, signal: buffer.baseAddress!, count: warmUp, samplePeak: 1)
                        _ = detector.take(role: 0)
                        let peak = buffer[warmUp...].map(abs).max() ?? 0
                        detector.process(role: 0, signal: buffer.baseAddress! + warmUp, count: buffer.count - warmUp, samplePeak: peak)
                    }
                    let reading = MeterScale.decibels(detector.take(role: 0))
                    worst = min(worst, reading)
                    highest = max(highest, reading)
                }
            }
            if worst < -0.005 || highest > 0.005 { print("True peak near Nyquist: rate=\(rate) worst=\(worst) highest=\(highest)") }
            checkGreaterOrEqual(worst, -0.005)
            checkTrue(highest <= 0.005)
        }
    }

    func testTruePeakOfDenseMixtures() {
        // Twenty tones between 20 Hz and 20 kHz with random levels and phases: the exact crest of their sum is known
        // analytically, so a candidate chosen at the wrong crest shows up. The meter reads within 0.005 dB of it.
        var generator = SystemRandomNumberGenerator()
        for rate in [44_100.0, 48_000, 96_000, 192_000] {
            for _ in 0..<6 {
                let tones = (0..<20).map { _ in
                    (frequency: Double.random(in: 20...20_000, using: &generator), level: Double.random(in: 0.02...0.1, using: &generator),
                     phase: Double.random(in: 0...(2 * Double.pi), using: &generator))
                }
                func value(_ t: Double) -> Double {
                    tones.reduce(0) { $0 + $1.level * sin(2 * Double.pi * $1.frequency * t / rate + $1.phase) }
                }
                let count = 4_096
                let signal = (0..<count).map { Float(value(Double($0))) }
                let detector = TruePeakDetector(sampleRate: rate, capacity: count)
                // Output i reads the signal at sample i − 33 + p / factor: the segments refined after the warm-up
                // cover samples 223 to 3999, and the sample peaks passed in reach the end of the signal.
                let warmUp = 4 * TruePeakDetector.segmentLength + 2
                signal.withUnsafeBufferPointer { buffer in
                    detector.process(role: 0, signal: buffer.baseAddress!, count: warmUp, samplePeak: 1)
                    _ = detector.take(role: 0)
                    let peak = buffer[warmUp...].map(abs).max() ?? 0
                    detector.process(role: 0, signal: buffer.baseAddress! + warmUp, count: count - warmUp, samplePeak: peak)
                }
                let reading = Double(detector.take(role: 0))
                // The exact crest: every 1/16 sample, then 1/4096 around the five loudest local maxima.
                func crest(from first: Double, to last: Double) -> Double {
                    let grid = stride(from: first, to: last, by: 1.0 / 16).map { (t: $0, v: abs(value($0))) }
                    let maxima = grid.indices.dropFirst().dropLast()
                        .filter { grid[$0].v >= grid[$0 - 1].v && grid[$0].v >= grid[$0 + 1].v }
                        .sorted { grid[$0].v > grid[$1].v }.prefix(5)
                    var result = grid.map(\.v).max() ?? 0
                    for index in maxima {
                        for step in -256...256 { result = max(result, abs(value(grid[index].t + Double(step) / 4_096))) }
                    }
                    return result
                }
                let refined = crest(from: 223, to: 3_999), whole = crest(from: 223, to: Double(count))
                let under = 20 * log10(reading / refined), over = 20 * log10(reading / whole)
                if under < -0.005 || over > 0.005 { print("Dense mixture true peak: rate=\(rate) \(under) dB, \(over) dB") }
                checkTrue(under >= -0.005 && over <= 0.005)
                // Crests close together exercise the runner-up candidates: any split of the buffers reads the same.
                var reference: Float?
                for chunk in [4_096, 1, 7, 64, 333] {
                    let split = TruePeakDetector(sampleRate: rate, capacity: 4_096)
                    signal.withUnsafeBufferPointer { buffer in
                        for offset in stride(from: 0, to: count, by: chunk) {
                            let length = min(chunk, count - offset)
                            let peak = buffer[offset..<(offset + length)].map(abs).max() ?? 0
                            split.process(role: 0, signal: buffer.baseAddress! + offset, count: length, samplePeak: peak)
                        }
                    }
                    let reading = split.take(role: 0)
                    checkEqual(reading, reference ?? reading, accuracy: 0.000001)
                    reference = reference ?? reading
                }
            }
        }
    }

    func testScopeSampleProjection() {
        checkTrue(SoundstageLayout.scopeSample(left: 0, right: 0) == nil)
        checkTrue(SoundstageLayout.scopeSample(left: .infinity, right: 0) == nil)
        checkTrue(SoundstageLayout.scopeSample(left: .nan, right: 0) == nil)
        for l in -20...20 {
            for r in -20...20 where l != 0 || r != 0 {
                let left = Float(l) / 20, right = Float(r) / 20
                let point = SoundstageLayout.scopeSample(left: left, right: right)!
                var mid = (left + right) * 0.70710677, side = (right - left) * 0.70710677
                if mid < 0 { mid = -mid; side = -side }
                let angle = Double(atan2(side, mid))
                let radius = SoundstageLayout.scopeFraction(decibels: 20 * log10((left * left + right * right).squareRoot()))
                checkEqual(point.x, sin(angle) * radius, accuracy: 0.000001)
                checkEqual(point.y, -cos(angle) * radius, accuracy: 0.000001)
                checkTrue(point.y <= 0 && hypot(point.x, point.y) <= 1.000001)
            }
        }
    }

    func testLoudnessSilencePartitioning() throws {
        let active = (0..<Role.count).map { $0 == Role.left }
        for rate in [8_000.0, 44_100, 48_000, 96_000, 192_000] {
            // Short bursts separated by silence exercise both K-weighting tails and restarting from silence.
            let frames = (0..<Int(rate)).map { index -> ChannelFrame in
                var frame = ChannelFrame()
                if index % Int(rate / 10) < 32 { frame.left = 0.8 }
                return frame
            }
            func measure(chunk: Int) throws -> MultichannelLevels {
                let analyzer = try unwrap(LoudnessAnalyzer(sampleRate: rate, activeRoles: active))
                for offset in stride(from: 0, to: frames.count, by: chunk) {
                    frames.withUnsafeBufferPointer { buffer in
                        analyzer.consume(UnsafeBufferPointer(start: buffer.baseAddress! + offset,
                                                             count: min(chunk, frames.count - offset)))
                    }
                }
                return analyzer.snapshot()
            }
            let reference = try measure(chunk: 4096)
            for chunk in [1, 7, 127, 511] {
                let result = try measure(chunk: chunk)
                if abs(result.integrated - reference.integrated) > 0.005 {
                    print("Loudness partition: rate=\(rate) chunk=\(chunk) integrated=\(result.integrated) reference=\(reference.integrated)")
                }
                // vDSP's vector and one-sample paths accumulate Float roundoff differently, especially in
                // the high-pass section at high sample rates. This is well below the 0.1 LU readout step.
                checkEqual(result.integrated, reference.integrated, accuracy: 0.005)
                checkEqual(result.momentary, reference.momentary, accuracy: 0.005)
                checkEqual(result.rms[Role.left], reference.rms[Role.left], accuracy: 0.000001)
            }
        }
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
        checkEqual(TruePeakDetector(sampleRate: 192_000, capacity: 16).factor, 2)

        // EBU Tech 3342: 10 s at −20 LUFS and 10 s at −30 LUFS spread over a 10 LU range; a −80 LUFS
        // passage is below the absolute gate and a −45 LUFS one is under the relative gate.
        var range = LoudnessRange()
        checkTrue(range.value < 0)
        func energy(_ lufs: Double) -> Double { pow(10, (lufs + 0.691) / 10) }
        for _ in 0..<100 { range.add(energy(-20)) }
        for _ in 0..<100 { range.add(energy(-30)) }
        for _ in 0..<100 { range.add(energy(-80)) }
        for _ in 0..<5 { range.add(energy(-55)) }
        checkEqual(range.value, 10, accuracy: 0.0001)
        var steady = LoudnessRange()
        for _ in 0..<50 { steady.add(energy(-23)) }
        checkEqual(steady.value, 0, accuracy: 0.0001)
        // Exact against sorting everything, Tech 3342's way: gates, then sorted index round((n − 1) · p).
        var generator = SystemRandomNumberGenerator()
        for trial in 0..<20 {
            var exact = LoudnessRange()
            var values: [Double] = []
            for _ in 0..<(50 + trial * 97) {
                let lufs = Double.random(in: -80 ... -5, using: &generator)
                values.append(energy(lufs))
                exact.add(values.last!)
            }
            let absolute = values.filter { $0 > energy(-70) }
            let gate = absolute.reduce(0, +) / Double(absolute.count) * 0.01
            let gated = absolute.filter { $0 >= gate }.sorted()
            func at(_ p: Double) -> Double { gated[Int((Double(gated.count - 1) * p).rounded())] }
            checkEqual(exact.value, Float(10 * log10(at(0.95) / at(0.10))), accuracy: 0.0001)
        }
    }

    /// The synthetic cases of EBU Tech 3341 (loudness metering, "EBU mode") and EBU Tech 3342 (loudness range):
    /// 1 kHz sines at the stated peak levels in dBFS, at 48 kHz, through the full analyser. Tech 3341 allows ±0.1 LU,
    /// Tech 3342 ±1 LU. `MeterConformance` names the same cases for the About window.
    func testEBUConformance() throws {
        struct Part { let seconds: Double; let levels: [Int: Double] }
        func stereo(_ seconds: Double, _ dBFS: Double) -> Part { Part(seconds: seconds, levels: [Role.left: dBFS, Role.right: dBFS]) }
        func run(_ parts: [Part]) throws -> MultichannelLevels {
            let rate = 48_000.0
            let analyzer = try unwrap(LoudnessAnalyzer(sampleRate: rate))
            var frames = [ChannelFrame](repeating: ChannelFrame(), count: 4800)
            var position = 0
            for part in parts {
                let total = Int((part.seconds * rate).rounded())
                var done = 0
                let amplitudes = part.levels.mapValues { Float(pow(10, $0 / 20)) }
                while done < total {
                    let count = min(frames.count, total - done)
                    for i in 0..<count {
                        let value = Float(sin(2 * Double.pi * 1000 * Double(position + i) / rate))
                        var frame = ChannelFrame()
                        for (role, amplitude) in amplitudes {
                            switch role {
                            case Role.left: frame.left = amplitude * value
                            case Role.right: frame.right = amplitude * value
                            case Role.center: frame.center = amplitude * value
                            case Role.leftSurround: frame.leftSurround = amplitude * value
                            case Role.rightSurround: frame.rightSurround = amplitude * value
                            default: break
                            }
                        }
                        frames[i] = frame
                    }
                    frames.withUnsafeBufferPointer { analyzer.consume(UnsafeBufferPointer(rebasing: $0[0..<count])) }
                    done += count
                    position += count
                }
            }
            return analyzer.snapshot()
        }
        // Tech 3341 case 1 and 2: steady stereo sines; momentary, short-term and integrated all read the level.
        let one = try run([stereo(20, -23)])
        checkEqual(one.momentary, -23, accuracy: 0.1)
        checkEqual(one.shortTerm, -23, accuracy: 0.1)
        checkEqual(one.integrated, -23, accuracy: 0.1)
        let two = try run([stereo(20, -33)])
        checkEqual(two.momentary, -33, accuracy: 0.1)
        checkEqual(two.shortTerm, -33, accuracy: 0.1)
        checkEqual(two.integrated, -33, accuracy: 0.1)
        // Cases 3 and 4: the relative gate leaves the quiet passages out; case 4's −72 dBFS also falls to the absolute gate.
        checkEqual(try run([stereo(10, -36), stereo(60, -23), stereo(10, -36)]).integrated, -23, accuracy: 0.1)
        checkEqual(try run([stereo(10, -72), stereo(10, -36), stereo(60, -23), stereo(10, -36), stereo(10, -72)]).integrated,
                   -23, accuracy: 0.1)
        // Case 5: the energy mean of three passages.
        checkEqual(try run([stereo(20, -26), stereo(20.1, -20), stereo(20, -26)]).integrated, -23, accuracy: 0.1)
        // Case 6: five channels with the surrounds weighted +1.5 dB.
        let five = try run([Part(seconds: 20, levels: [Role.left: -28, Role.right: -28, Role.center: -24,
                                                        Role.leftSurround: -30, Role.rightSurround: -30])])
        checkEqual(five.integrated, -23, accuracy: 0.1)
        // Tech 3342 cases 1 to 4: loudness range of stepped stereo sines.
        checkEqual(try run([stereo(20, -20), stereo(20, -30)]).range, 10, accuracy: 1)
        checkEqual(try run([stereo(20, -20), stereo(20, -15)]).range, 5, accuracy: 1)
        checkEqual(try run([stereo(20, -40), stereo(20, -20)]).range, 20, accuracy: 1)
        checkEqual(try run([stereo(20, -50), stereo(20, -35), stereo(20, -20), stereo(20, -35), stereo(20, -50)]).range,
                   15, accuracy: 1)
    }

    func testSignalHealth() throws {
        // Seconds of a tone of `frequency` at `amplitude` plus `offset` on L, through the meter; returns DC and the
        // infrasonic mean square in dB (re full-scale sine power, 0.5).
        func measure(rate: Double, frequency: Double, amplitude: Double, offset: Double, seconds: Double = 6)
            -> (dc: Float, infrasonic: Float, status: Float) {
            let meter = SignalHealthMeter(sampleRate: rate, activeRoles: [true, true] + [Bool](repeating: false, count: Role.count - 2))
            let capacity = 4096
            var storage = [Float](repeating: 0, count: Role.count * capacity)
            var position = 0
            let total = Int(rate * seconds)
            while position < total {
                let count = min(capacity, total - position)
                for i in 0..<count {
                    storage[i] = Float(offset + amplitude * sin(2 * Double.pi * frequency * Double(position + i) / rate))
                }
                storage.withUnsafeBufferPointer { meter.consume(PlanarBlock(base: $0.baseAddress!, stride: capacity, count: count)) }
                position += count
            }
            var out = [Float](repeating: 0, count: 2 * Role.count + 1)
            out.withUnsafeMutableBufferPointer { meter.write(into: $0.baseAddress!) }
            return (out[0], 10 * log10(max(out[Role.count], 1e-20) / 0.5), out[2 * Role.count])
        }
        // A constant offset reads as itself; a 1 kHz tone leaves nothing below 20 Hz.
        let offset = measure(rate: 48_000, frequency: 1_000, amplitude: 0.5, offset: 0.01)
        checkEqual(offset.dc, 0.01, accuracy: 0.0002)
        // The offset switching on at the start is itself a step: its 1 s settling tail is all that remains after 6 s.
        checkTrue(offset.infrasonic < -70)
        checkEqual(offset.status, 1)
        checkTrue(measure(rate: 48_000, frequency: 1_000, amplitude: 0.5, offset: 0).infrasonic < -80)
        // 10 Hz is in the pass band (−0.0 dB at 48 and 192 kHz, where single precision would misplace the corner),
        // 40 Hz is about 24 dB down, and the DC itself never counts.
        for rate in [48_000.0, 192_000.0] {
            checkEqual(measure(rate: rate, frequency: 10, amplitude: 1, offset: 0.05, seconds: 8).infrasonic, -0.1, accuracy: 0.3)
            checkEqual(measure(rate: rate, frequency: 40, amplitude: 1, offset: 0, seconds: 8).infrasonic, -24.1, accuracy: 0.6)
        }
        checkEqual(measure(rate: 48_000, frequency: 20, amplitude: 1, offset: 0, seconds: 8).infrasonic, -3, accuracy: 0.3)
        // Cost: 60 s of stereo at 48 kHz.
        let start = Date()
        _ = measure(rate: 48_000, frequency: 100, amplitude: 0.5, offset: 0, seconds: 60)
        print(String(format: "signal health: 60 s of stereo at 48 kHz in %.1f ms (%.3f %% of real time)",
                     Date().timeIntervalSince(start) * 1000, Date().timeIntervalSince(start) / 60 * 100))
        // Settling: under a second of audio is reported as settling.
        checkEqual(measure(rate: 48_000, frequency: 1_000, amplitude: 0.5, offset: 0, seconds: 0.5).status, 0.5)
    }

    func testMasteringMeasures() throws {
        // A session of one steady spectrum falling 4.5 dB per octave from 1 kHz, with a narrow +9 dB peak near 3 kHz and,
        // in a second session, nothing above 16 kHz (as an encoder's low-pass leaves).
        func session(resonance: Bool, lowPass: Bool) -> SessionStatistics {
            var statistics = SessionStatistics()
            let upper = 20_000.0
            var spectrum = [Float](repeating: -120, count: SessionStatistics.bands)
            for band in spectrum.indices {
                let f = 20 * pow(upper / 20, (Double(band) + 0.5) / Double(spectrum.count))
                spectrum[band] = Float(-30 - 4.5 * log2(f / 1_000))
                if resonance, abs(log2(f / 3_000)) < 0.04 { spectrum[band] += 9 }
                if lowPass, f > 16_000 { spectrum[band] = -110 }
            }
            for tick in 0..<200 {
                let loud: Float = tick % 20 < 10 ? -14 : -18
                statistics.add(SessionSample(momentary: loud, shortTerm: loud + 1, truePeak: loud + 9, samplePeak: loud + 8,
                                             programme: loud - 1, spectrum: spectrum, upper: upper,
                                             bandCorrelation: [Float](repeating: 0.8, count: 9), bandWidth: [Float](repeating: 0.1, count: 9),
                                             bandBalance: [Float](repeating: 0, count: 9), bandLevel: [Float](repeating: -20, count: 9),
                                             leftRMS: 0.1, rightRMS: 0.1))
            }
            return statistics
        }
        let plain = session(resonance: false, lowPass: false)
        let spectrum = plain.averageSpectrum
        checkEqual(try unwrap(MasteringCheck.tilt(spectrum, statistics: plain)), -4.5, accuracy: 0.05)
        checkTrue(MasteringCheck.resonances(spectrum, statistics: plain).isEmpty)
        checkTrue(MasteringCheck.cutoff(spectrum, statistics: plain) == nil)
        checkEqual(try unwrap(MasteringCheck.presence(spectrum, statistics: plain)), 0, accuracy: 0.6)
        let peaked = session(resonance: true, lowPass: false)
        let found = MasteringCheck.resonances(peaked.averageSpectrum, statistics: peaked)
        checkEqual(found.count, 1)
        checkEqual(try unwrap(found.first).frequency, 3_000, accuracy: 150)
        let cut = session(resonance: false, lowPass: true)
        checkEqual(try unwrap(MasteringCheck.cutoff(cut.averageSpectrum, statistics: cut)), 16_000, accuracy: 900)
        // Dynamics: the 3 s window always holds a loud tick's peak (−5 dBTP), so PSR is 8 LU over loud short-term
        // readings and 12 over quiet ones; the median is one of the two. Crest is over the mean programme power.
        let psr = try unwrap(MasteringCheck.peakToShortTerm(peaks: plain.truePeaks, shortTerms: plain.shortTerms))
        checkTrue(abs(psr - 8) < 0.01 || abs(psr - 12) < 0.01)
        checkEqual(try unwrap(MasteringCheck.crestFactor(peaks: plain.truePeaks, programme: plain.programme)), 11.55, accuracy: 0.05)
        checkEqual(MasteringCheck.monoChange(correlation: 1), 0, accuracy: 0.001)
        checkEqual(MasteringCheck.monoChange(correlation: 0), -3.01, accuracy: 0.01)
        // The whole check: sections in order, no CHECK for a clean session.
        let check = MasteringCheck(statistics: plain, integrated: -15.5, range: 4, truePeak: -5, samplePeak: -6, overs: 0, breaks: 0,
                                   missingSeconds: 0, dropped: 0, ceiling: -1, stereo: true)
        checkEqual(check.sections.count, 6)
        checkTrue(check.sections.allSatisfy { $0.worst != .check })
        // Signal health from the analysis: a 1 % DC offset on R and infrasonic energy 20 dB under the programme.
        var health = SessionStatistics()
        var routed = [Bool](repeating: false, count: 16)
        routed[0] = true; routed[1] = true
        var dc = [Float](repeating: 0, count: 16), infra = [Float](repeating: 0, count: 16)
        dc[1] = 0.01
        infra[0] = 0.5e-2 * 0.5; infra[1] = 0.5e-2 * 0.5   // programme power 0.5 (−3 dB): infrasonic total 0.005, −20 dB
        for _ in 0..<50 {
            health.add(SessionSample(momentary: -14, shortTerm: -14, truePeak: -2, samplePeak: -3, programme: -3.0103,
                                     spectrum: spectrum, upper: 20_000, bandCorrelation: [Float](repeating: 0.8, count: 9),
                                     bandWidth: [Float](repeating: 0.1, count: 9), bandBalance: [Float](repeating: 0, count: 9),
                                     bandLevel: [Float](repeating: -20, count: 9), leftRMS: 0.5, rightRMS: 0.5,
                                     dcOffset: dc, infrasonic: infra, healthStatus: 1, routed: routed))
        }
        checkEqual(try unwrap(health.meanDC?.first { $0.role == 1 }).offset, 0.01, accuracy: 1e-6)
        checkEqual(try unwrap(health.infrasonicRatio), -20, accuracy: 0.01)
        let healthCheck = MasteringCheck(statistics: health, integrated: -14, range: 4, truePeak: -2, samplePeak: -3, overs: 0, breaks: 0,
                                         missingSeconds: 0, dropped: 0, ceiling: -1, stereo: true)
        let integrity = try unwrap(healthCheck.sections.last)
        checkEqual(try unwrap(integrity.items.first { $0.name == L("DC offset") }).status, .check)
        checkEqual(try unwrap(integrity.items.first { $0.name == L("Below 20 Hz") }).status, .note)
        // Without the analysis' readings (a plugin before build 90) both say so instead of guessing.
        let older = MasteringCheck(statistics: plain, integrated: -14, range: 4, truePeak: -2, samplePeak: -3, overs: 0, breaks: 0,
                                   missingSeconds: 0, dropped: 0, ceiling: -1, stereo: true)
        checkEqual(try unwrap(older.sections.last?.items.first { $0.name == L("DC offset") }).status, .unavailable)
    }

    @MainActor
    func testComplianceVerdicts() throws {
        let r128 = try unwrap(LoudnessStandard.with(id: "r128"))
        func verdict(_ standard: LoudnessStandard?, _ integrated: Float, _ peak: Float, seconds: Double = 60) -> ComplianceResult.State {
            ComplianceResult.evaluate(standard: standard, target: standard?.target ?? -20, ceiling: standard?.ceiling ?? -1,
                                      integrated: integrated, truePeak: peak, elapsed: seconds).state
        }
        // EBU R128: ±0.5 LU, judged on the reading as shown (to a tenth); a true peak above −1 dBTP fails it.
        checkEqual(verdict(r128, -23.0, -3), .pass)
        checkEqual(verdict(r128, -22.5, -3), .pass)
        checkEqual(verdict(r128, -23.54, -3), .pass)   // shown as −23.5: on the edge, inside
        checkEqual(verdict(r128, -23.56, -3), .check)  // shown as −23.6
        checkEqual(verdict(r128, -23.46, -3), .pass)
        checkEqual(verdict(r128, -23.0, -0.9), .check)
        checkEqual(verdict(r128, -23.0, -1.04), .pass)
        // Too short, or silence: no verdict yet.
        checkEqual(verdict(r128, -23, -3, seconds: 5), .measuring)
        checkEqual(verdict(r128, -100, -120), .measuring)
        // A maximum: below passes, above does not.
        let atmos = try unwrap(LoudnessStandard.with(id: "atmos-music"))
        checkEqual(verdict(atmos, -20, -3), .pass)
        checkEqual(verdict(atmos, -17.9, -3), .check)
        // Streaming normalizes: louder plays quieter (information, not a failure) unless the peak is over its ceiling.
        let streaming = try unwrap(LoudnessStandard.with(id: "streaming"))
        checkEqual(verdict(streaming, -9, -1.5), .info)
        checkEqual(verdict(streaming, -9, -0.5), .check)
        // Custom targets are judged within ±1 LU.
        checkEqual(verdict(nil, -20.9, -3), .pass)
        checkEqual(verdict(nil, -21.2, -3), .check)
        // Every standard has its own identity; the old targets still find one.
        checkEqual(Set(LoudnessStandard.all.map(\.id)).count, LoudnessStandard.all.count)
        checkEqual(LoudnessStandard.matching(target: -24, ceiling: -2)?.id, "atsc")
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

    func testOneSidedBandReadings() throws {
        for side in [Role.left, Role.right] {
            let pipeline = try unwrap(MeterPipeline(sampleRate: 48_000, activeRoles: (0..<Role.count).map { $0 < 2 },
                                                   detector: FormatDetector(), streamID: 1))
            var values = [Float](repeating: 0, count: SnapshotSlots.total)
            for tick in 0..<120 {
                let frames = (0..<800).map { index -> ChannelFrame in
                    let tone = Float(0.5 * sin(2 * Double.pi * 997 * Double(tick * 800 + index) / 48_000))
                    var frame = ChannelFrame()
                    if side == Role.left { frame.left = tone } else { frame.right = tone }
                    return frame
                }
                frames.withUnsafeBufferPointer { pipeline.consume($0) }
                values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: Double(tick) / 60) }
            }
            let band = 2 // 500 Hz–2 kHz
            checkEqual(values[SnapshotSlots.bandCorrelation + band], MeterSnapshot.noCorrelation)
            checkEqual(values[SnapshotSlots.bandBalance + band], side == Role.left ? -1 : 1, accuracy: 0.00001)
            checkEqual(values[SnapshotSlots.bandWidth + band], 0.5, accuracy: 0.00001)
            checkEqual(values[SnapshotSlots.bandLevel + band], -12.0412, accuracy: 0.1)
        }
    }

    func testUnavailableBandsAreSilent() throws {
        for rate in [8_000.0, 16_000] {
            let analyzer = try unwrap(SpectrumAnalyzer(sampleRate: rate, recording: [Bool](repeating: true, count: Role.count)))
            analyzer.recordsSpatial = true
            // Bin 1 has energy but lies below the lowest displayed band. It must never stand in for 8 kHz.
            let frames = (0..<SpectrumAnalyzer.fftSize).map { i -> ChannelFrame in
                var frame = ChannelFrame()
                frame.left = Float(sin(2 * Double.pi * Double(i) / Double(SpectrumAnalyzer.fftSize)))
                frame.center = frame.left
                return frame
            }
            frames.withUnsafeBufferPointer { analyzer.consume($0) }
            var bands = [Float](repeating: 0, count: MeterSnapshot.bandCount)
            _ = analyzer.refreshSpectrum(into: &bands, roles: analyzer.spatialRoles)
            for role in 0..<Role.count { checkEqual(analyzer.roleBandPower[role * StereoBands.count + 4], 0) }
            let splitter = try unwrap(StereoBandSplitter(sampleRate: rate))
            let nearNyquist = (0..<4096).flatMap { i -> [Float] in
                let sample = Float(sin(2 * Double.pi * 0.45 * Double(i)))
                return [sample, sample]
            }
            nearNyquist.withUnsafeBufferPointer { splitter.consume($0.baseAddress!, stride: 2, count: 4096) }
            var points = [Float](repeating: 1, count: StereoBands.scopeFloats)
            points.withUnsafeMutableBufferPointer { splitter.writePoints(into: $0.baseAddress!, silent: false) }
            checkTrue(points.suffix(StereoBands.scopePoints * 2).allSatisfy { $0 == 0 })
        }
    }

    func testInvalidAudioSamplesAreIsolated() throws {
        let ring = try unwrap(channel_ring_create(8))
        defer { channel_ring_destroy(ring) }
        var routing = [Int32](repeating: -1, count: Role.count)
        routing[Role.left] = 0; routing[Role.right] = 1
        let samples: [Float] = [.nan, 0.25, .infinity, -0.5, -.infinity, 2, 0.75, -2]
        checkEqual(channel_ring_write(ring, samples, 4, 2, routing), 4)
        var frames = [ChannelFrame](repeating: ChannelFrame(), count: 4)
        checkEqual(channel_ring_read(ring, &frames, 4), 4)
        checkEqual(frames.map(\.left), [0, 0, 0, 0.75])
        checkEqual(frames.map(\.right), [0.25, -0.5, 2, -2])
    }

    func testBandEnergyCalibrationAcrossRates() throws {
        for rate in [8_000.0, 44_100, 48_000, 96_000, 192_000] {
            let analyzer = try unwrap(SpectrumAnalyzer(sampleRate: rate))
            let n = analyzer.historyLength
            var frames = [StereoFrame](repeating: StereoFrame(left: 0, right: 0), count: n)
            var expected = [(left: Double, right: Double, cross: Double)](repeating: (0, 0, 0), count: StereoBands.count)
            for band in 0..<StereoBands.count {
                let lower = StereoBands.edges[band]
                let upper = min(band + 1 < StereoBands.count ? StereoBands.edges[band + 1] : 20_000, rate / 2)
                guard upper > lower else { continue }
                let bin = ((lower * upper).squareRoot() * Double(n) / rate).rounded()
                let left = 0.1 + 0.02 * Double(band), right = 0.07 + 0.01 * Double(band)
                let phase = Double(band) * .pi / 4
                for index in 0..<n {
                    let angle = 2 * Double.pi * bin * Double(index) / Double(n)
                    frames[index].left += Float(left * sin(angle))
                    frames[index].right += Float(right * sin(angle + phase))
                }
                expected[band] = (left * left / 2, right * right / 2, left * right * cos(phase) / 2)
            }
            frames.withUnsafeBufferPointer { analyzer.consume($0) }
            var spectrum = [Float](repeating: 0, count: MeterSnapshot.bandCount)
            _ = analyzer.refreshSpectrum(into: &spectrum)
            for band in 0..<StereoBands.count {
                let measured = analyzer.bandSums[band], scale = analyzer.bandPowerScale
                checkEqual(measured.left * scale, expected[band].left, accuracy: 0.000002)
                checkEqual(measured.right * scale, expected[band].right, accuracy: 0.000002)
                checkEqual(measured.cross * scale, expected[band].cross, accuracy: 0.000002)
            }
        }
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
        // Film order (Pro Tools): L C R, surrounds, LFE, heights; every role once.
        checkEqual(SpeakerLayout.s51.filmRoles, [Role.left, Role.center, Role.right, Role.leftSurround, Role.rightSurround, Role.lfe])
        checkEqual(SpeakerLayout.s714.filmRoles, [Role.left, Role.center, Role.right, Role.leftSurround, Role.rightSurround,
                                                  Role.leftRearSurround, Role.rightRearSurround, Role.lfe, Role.leftTopFront,
                                                  Role.rightTopFront, Role.leftTopRear, Role.rightTopRear])
        for layout in SpeakerLayout.allCases { checkEqual(Set(layout.filmRoles), Set(layout.roles)); checkEqual(layout.filmRoles.count, layout.roles.count) }
        checkEqual(Role.loudnessWeights.count, Role.count)
        checkEqual(Role.loudnessWeights[Role.lfe], 0)
    }

    /// Channel labels to roles: Audio MIDI Setup's 9.1.6 and 5.1.2 (as this Mac's Pro Tools Audio Bridge reports them),
    /// a driver's placeholder labels, a WAV-style 7.1, Core Audio's Atmos tags, a repeated label; the routing a
    /// configuration gives a format; and the VST3 order a Bridge plugin's 9.1.6 bus arrives in.
    func testChannelLabels() throws {
        let unknown = kAudioChannelLabel_Unknown
        let ams916: [AudioChannelLabel] = [1, 2, 3, 4, 5, 6, 33, 34, 35, 36, 13, 15, 49, 51, 52, 54]
        let map916 = try unwrap(SpeakerMap(labels: ams916))
        checkEqual(map916.roles.compactMap { $0 }, SpeakerLayout.s916.roles)
        checkTrue(map916.complete && map916.configured)
        checkEqual(map916.layout, .s916)
        checkEqual(map916.name, "9.1.6")
        checkEqual(map916.routing(for: .s916, channels: 16), (0..<16).map { Int32(SpeakerLayout.s916.roles.firstIndex(of: $0) ?? -1) })
        // 5.1.2 on a 16-channel device: the lone top-middle pair is the x.x.2 pair; a larger format leaves the rest off.
        let map512 = try unwrap(SpeakerMap(labels: [1, 2, 3, 4, 5, 6, 49, 51] + [AudioChannelLabel](repeating: unknown, count: 8)))
        checkEqual(map512.roles.prefix(8).compactMap { $0 }, SpeakerLayout.s512.roles)
        checkTrue(map512.configured && !map512.complete)
        checkEqual(map512.layout, .s512)
        let routed = map512.routing(for: .s916, channels: 16)
        checkEqual(routed[Role.leftTopFront], 6)
        checkEqual(routed[Role.rightTopFront], 7)
        checkEqual(routed[Role.leftWide], -1)
        checkEqual(routed[Role.leftTopMiddle], -1)
        checkEqual(map512.routing(for: .s512, channels: 6)[Role.leftTopFront], -1)
        // A placeholder (label n on channel n) is no configuration; up to six channels it is a real 5.1.
        checkTrue(SpeakerMap(labels: (1...16).map { AudioChannelLabel($0) }) == nil)
        checkEqual(try unwrap(SpeakerMap(labels: [1, 2, 3, 4, 5, 6])).layout, .s51)
        // Stereo is no speaker configuration.
        checkTrue(!(try unwrap(SpeakerMap(labels: [1, 2]))).configured)
        // A WAV-style 7.1 (back L/R, then side L/R): Left surround is the rear pair beside a side pair.
        checkEqual(ChannelLabels.roles([1, 2, 3, 4, 5, 6, 10, 11]).compactMap { $0 },
                   [Role.left, Role.right, Role.center, Role.lfe, Role.leftRearSurround, Role.rightRearSurround,
                    Role.leftSurround, Role.rightSurround])
        // Core Audio's Atmos layout tags, expanded: SMPTE order.
        for (tag, layout) in [(kAudioChannelLayoutTag_Atmos_7_1_4, SpeakerLayout.s714), (kAudioChannelLayoutTag_Atmos_9_1_6, .s916),
                              (kAudioChannelLayoutTag_Atmos_5_1_2, .s512), (kAudioChannelLayoutTag_Atmos_5_1_4, .s514)] {
            var layoutTag = AudioChannelLayout()
            layoutTag.mChannelLayoutTag = tag
            let labels = withUnsafePointer(to: &layoutTag) { ChannelLabels.labels($0, size: MemoryLayout<AudioChannelLayout>.size) }
            checkEqual(ChannelLabels.roles(labels).compactMap { $0 }, layout.roles)
        }
        // A role only once; labels without a role are skipped.
        checkEqual(ChannelLabels.roles([1, 1, 2, 7, 9]), [Role.left, nil, Role.right, nil, nil])
        // VST3 order: the Bridge plugin's 9.1.6 bus (Bridge/scripts/e2e-probe.sh) and the beds.
        checkEqual(SpeakerLayout.s916.vst3Roles, [0, 1, 2, 3, 8, 9, 4, 5, 6, 7, 14, 15, 12, 13, 10, 11])
        checkEqual(SpeakerLayout.s714.vst3Roles, [Role.left, Role.right, Role.center, Role.lfe, Role.leftRearSurround,
                                                  Role.rightRearSurround, Role.leftSurround, Role.rightSurround, Role.leftTopFront,
                                                  Role.rightTopFront, Role.leftTopRear, Role.rightTopRear])
        checkEqual(SpeakerLayout.s512.vst3Roles, SpeakerLayout.s512.roles)
        checkEqual(SpeakerLayout.s514.vst3Roles, SpeakerLayout.s514.roles)
        for layout in SpeakerLayout.allCases { checkEqual(Set(layout.vst3Roles), Set(layout.roles)) }
    }

    /// The speaker layout file (docs/SPEAKER_LAYOUT_FORMAT.md): written in full with unknown distances as null, read back
    /// exactly; a minimal hand-written file completed; other formats' roles left out, missing ones standard; bad
    /// values, foreign and newer files refused; the geometry it gives.
    func testSpeakerLayoutFile() throws {
        var c = SpeakerConfiguration.standard(.s714)
        c.name = "Studio"
        let lower = try unwrap(c.speakers.firstIndex { $0.role == "Ltr" })
        c.speakers[lower].elevation = -20
        c.speakers[lower].included = false
        let data = try SpeakerLayoutDocument.encode(c)
        let text = String(decoding: data, as: UTF8.self)
        checkTrue(text.contains("\"format\" : \"auraliscope.speaker-layout\"") && text.contains("\"schemaVersion\" : 1"))
        checkTrue(text.contains("\"distance\" : null") && text.contains("\"included\" : false"))
        let read = try SpeakerLayoutDocument.decode(data)
        checkTrue(read.notes.isEmpty)
        var same = read.configuration
        same.id = c.id
        checkEqual(same, c)
        let g = SpeakerLayoutStore.geometry(for: .s714, configuration: read.configuration, revision: 3, nebula: NebulaSettings())
        checkTrue(g.reachesBelow(roles: SpeakerLayout.s714.roles) == false)  // the lower speaker is left out
        checkTrue(g.direction(role: Role.leftTopRear) == nil)
        // Its revision names this content: the same layout gives the same one, another channel format, Particles or
        // window another (so a plugin is sent it again and its answer is matched), and it is never 0.
        let again = SpeakerLayoutStore.geometry(for: .s714, configuration: read.configuration, revision: 3, nebula: NebulaSettings())
        var fewer = NebulaSettings()
        fewer.particles = 8
        let other = SpeakerLayoutStore.geometry(for: .s714, configuration: read.configuration, revision: 3, nebula: fewer)
        let standard = SpeakerLayoutStore.geometry(for: .s916, configuration: nil, revision: 3, nebula: NebulaSettings())
        checkTrue(g.revision == again.revision && g.revision != 0 && other.hash != g.hash && other.revision != g.revision
                  && standard.revision != g.revision && g.revision == SpeakerLayoutStore.revision(3, hash: g.hash))
        // By hand: the format, its version, the channel format and each speaker's role and angles are enough.
        let minimal = Data("""
        {"format": "auraliscope.speaker-layout", "schemaVersion": 1, "layout": {"channelFormat": "5.1",
         "speakers": [{"role": "L", "azimuth": -25, "elevation": 0}, {"role": "R", "azimuth": 25, "elevation": 0, "distance": 2.5},
                      {"role": "Ltf", "azimuth": -45, "elevation": 40}]}}
        """.utf8)
        let hand = try SpeakerLayoutDocument.decode(minimal)
        checkEqual(hand.configuration.mapping, .directions)
        checkEqual(hand.configuration.speaker(Role.left)?.azimuth, -25)
        checkEqual(hand.configuration.speaker(Role.left)?.distance, nil)
        checkEqual(hand.configuration.speaker(Role.right)?.distance, 2.5)
        checkTrue(hand.configuration.speaker(Role.left)?.included == true)
        checkEqual(hand.notes.count, 2)  // Ltf is not in 5.1; C, LFE, Ls and Rs keep the standard places
        checkTrue(hand.configuration.speaker(Role.leftTopFront) == nil && hand.configuration.speaker(Role.center) != nil)
        checkEqual(Set(hand.configuration.speakers.map(\.role)), Set(SpeakerLayout.s51.roles.map { SpatialGeometry.roleNames[$0] }))
        func refused(_ json: String) -> Bool { (try? SpeakerLayoutDocument.decode(Data(json.utf8))) == nil }
        let head = "{\"format\": \"auraliscope.speaker-layout\", \"schemaVersion\": 1, \"layout\": {\"channelFormat\": \"5.1\", \"speakers\": "
        checkTrue(refused(head + "[{\"role\": \"L\", \"azimuth\": -30, \"elevation\": 95}]}}"))
        checkTrue(refused(head + "[{\"role\": \"L\", \"azimuth\": -30, \"elevation\": 0, \"distance\": 0.05}]}}"))
        checkTrue(refused(head + "[{\"role\": \"L\", \"azimuth\": -30, \"elevation\": 0}, {\"role\": \"L\", \"azimuth\": 0, \"elevation\": 0}]}}"))
        checkTrue(refused(head + "[{\"role\": \"L\", \"azimuth\": -30, \"elevation\": 0}], \"mapping\": \"positions\"}}"))
        checkTrue(refused("{\"format\": \"something else\", \"schemaVersion\": 1, \"layout\": {\"channelFormat\": \"5.1\", \"speakers\": []}}"))
        checkTrue(refused("{\"format\": \"auraliscope.speaker-layout\", \"schemaVersion\": 2, \"layout\": {\"channelFormat\": \"5.1\", \"speakers\": []}}"))
        checkTrue(refused("{\"format\": \"auraliscope.speaker-layout\", \"schemaVersion\": 1, \"layout\": {\"channelFormat\": \"6.1\", \"speakers\": []}}"))
        // Mirroring takes one side's places to the other.
        var left = SpeakerConfiguration.standard(.s51)
        left.speakers[0].azimuth = -40
        checkEqual(left.mirrored(from: true).speaker(Role.right)?.azimuth, 40)
    }

    func testSpectrogramResolutionMetadata() throws {
        for rate in [44_100.0, 48_000, 96_000, 192_000] {
            let span = SpectrumAnalyzer.historyLength(sampleRate: rate)
            let analyzer = try unwrap(SpectrogramAnalyzer(sampleRate: rate, span: span))
            let rows = SpectrogramAnalyzer.rowResolutions(sampleRate: rate, span: span)
            checkEqual(rows.count, MeterSnapshot.spectrogramBandCount)
            var blends = 0
            for (index, row) in rows.enumerated() {
                checkEqual(row.length, analyzer.length(ofRow: index))
                checkTrue(row.window == analyzer.window(ofRow: index))
                checkTrue(row.blend >= 0 && row.blend <= 1)
                if let previous = row.previousLength {
                    blends += 1
                    checkTrue(previous >= row.length && row.previousWindow != nil)
                }
            }
            checkTrue(blends > 0)
        }
        checkTrue(SpectrogramAnalyzer.rowResolutions(sampleRate: .nan, span: 8192).isEmpty)
    }

    func testSpectrumInterpolationPreservesMeasurements() {
        let cases: [[CGFloat]] = [[-96, -12, -12, -96], [-96, -96, -12, -96], [-12, -96, -96, -12],
                                  [-96, -40, -20, 0], [0, -20, -40, -96], [-20, -20, -20, -20]]
        for values in cases {
            let a = values[0], b = values[1], c = values[2], d = values[3]
            for step in 0...100 {
                let t = CGFloat(step) / 100
                let value = SpectrumInterpolation.value(a, b, c, d, fraction: t)
                checkTrue(value >= min(b, c) - 1e-9 && value <= max(b, c) + 1e-9)
                checkEqual(Double(value), -Double(SpectrumInterpolation.value(-a, -b, -c, -d, fraction: t)), accuracy: 1e-9)
            }
            checkEqual(Double(SpectrumInterpolation.value(a, b, c, d, fraction: 0)), Double(b))
            checkEqual(Double(SpectrumInterpolation.value(a, b, c, d, fraction: 1)), Double(c))
        }
    }

    /// The live spectrum's 128 fine bands: a sine reads its level in the band that holds it at every rate, as the
    /// 64 bands do, and each pair of fine bands agrees with the band it halves.
    func testFineSpectrumBands() throws {
        for rate in [44_100.0, 48_000, 96_000] {
            for frequency in [55.0, 440, 1_000.7, 5_000, 12_345] {
                let analyzer = try unwrap(SpectrumAnalyzer(sampleRate: rate))
                let frames = (0..<analyzer.historyLength).map { index -> StereoFrame in
                    let sample = Float(sin(2 * Double.pi * frequency * Double(index) / rate)) * 0.5
                    return StereoFrame(left: sample, right: sample)
                }
                frames.withUnsafeBufferPointer { analyzer.consume($0) }
                let snapshot = analyzer.snapshot()
                checkEqual(snapshot.spectrumFine.count, MeterSnapshot.fineBandCount)
                let upper = min(20_000, rate / 2)
                let fraction = log(frequency / 20) / log(upper / 20)
                let fine = Int(fraction * Double(MeterSnapshot.fineBandCount))
                let coarse = Int(fraction * Double(MeterSnapshot.bandCount))
                checkEqual(Double(snapshot.spectrumFine[fine]), -6.02, accuracy: 0.1)
                checkEqual(Double(max(snapshot.spectrumFine[2 * coarse], snapshot.spectrumFine[2 * coarse + 1])),
                           Double(snapshot.spectrum[coarse]), accuracy: 0.1)
                // Away from the tone the fine bands fall well below it.
                checkTrue(snapshot.spectrumFine[max(0, fine - 12)] < -40 || frequency < 100)
            }
        }
    }

    func testReassignedSpectrogram() throws {
        let rows = MeterSnapshot.spectrogramBandCount
        func row(_ hz: Double, upper: Double = 20_000) -> Int { Int(log(hz / 20) / log(upper / 20) * Double(rows)) }
        func power(_ db: Float) -> Double { pow(10, Double(db) / 10) }
        let zones = try unwrap(ReassignedSpectrogram(sampleRate: 48_000, span: 8192)).resolutions
        checkEqual(zones.map(\.length), [8192, 4096, 2048, 1024, 512])
        checkEqual(zones.map { Int($0.low) }, [0, 375, 750, 1500, 3000])
        func column(rate: Double, _ sample: (Int) -> Float) throws -> [Float] {
            let analyzer = try unwrap(SpectrumAnalyzer(sampleRate: rate))
            analyzer.spectrogramMode = .enhanced
            let frames = (0..<analyzer.historyLength).map { index -> StereoFrame in
                let value = sample(index)
                return StereoFrame(left: value, right: value)
            }
            frames.withUnsafeBufferPointer { analyzer.consume($0) }
            return analyzer.snapshot().spectrogram
        }
        // A sine of amplitude ½ collapses onto its own rows at −6.02 dBFS in every zone and at any bin offset, and a
        // semitone and a half away nothing is left within any colour range (in the bass, where that is still within
        // a bin and a half, nothing above the Standard range's floor; at 55 Hz a semitone and a half is under a bin).
        for (rate, hz) in [(48_000.0, 55.0), (48_000, 130.8), (48_000, 440), (48_000, 1_000.7), (48_000, 2_600),
                           (48_000, 5_000.3), (48_000, 12_345), (44_100, 997), (96_000, 440), (96_000, 6_000)] {
            let values = try column(rate: rate) { Float(sin(2 * Double.pi * hz * Double($0) / rate)) * 0.5 }
            let upper = min(20_000, rate / 2)
            // Its energy covers one bin's width: in the bass, several of the narrow rows there.
            let total = (row(hz / 1.06, upper: upper)...row(hz * 1.06, upper: upper)).reduce(0.0) { $0 + power(values[$1]) }
            checkEqual(10 * log10(total), -6.02, accuracy: 0.3)
            for offset in [-1.5, 1.5] {
                let away = row(hz * pow(2, offset / 12), upper: upper)
                let bin = rate / Double(SpectrumAnalyzer.historyLength(sampleRate: rate))
                let gap = hz * (1 - pow(2, -1.5 / 12))
                if away < rows && gap > bin { checkTrue(values[away] < (gap < 3 * bin ? -80 : -100)) }
            }
        }
        // A click lands in the column of its own instant: at the column's centre it lights the mid and treble rows;
        // 40 ms later (the next column but one) this column keeps almost none of it. A click has no pitch, so its
        // energy stays on the bins' own frequencies, which in a zone's lower rows are wider apart than the rows:
        // read a third of an octave.
        let centre = SpectrumAnalyzer.historyLength(sampleRate: 48_000) / 2
        let now = try column(rate: 48_000) { $0 == centre ? 1 : 0 }
        let later = try column(rate: 48_000) { $0 == centre + 1_920 ? 1 : 0 }
        func third(_ values: [Float], _ hz: Double) -> Double {
            10 * log10((row(hz / 1.12)...row(hz * 1.12)).reduce(1e-30) { $0 + power(values[$1]) })
        }
        for hz in [1_000.0, 4_000, 10_000] {
            checkTrue(third(now, hz) > -50)
            checkTrue(third(later, hz) < third(now, hz) - 30)
        }
        // Broadband noise reads the power in each row's slice of frequency, so the zones join without a step
        // (averaged over 32 noise columns: a single one is grainy by design).
        var seed: UInt64 = 0x2545F4914F6CDD1D
        var noise = [Double](repeating: 0, count: rows)
        for _ in 0..<32 {
            let values = try column(rate: 48_000) { _ in
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Float(Int64(bitPattern: seed >> 11) % 1_000_000) / 2_000_000
            }
            for index in 0..<rows { noise[index] += power(values[index]) }
        }
        for boundary in [375.0, 750, 1_500, 3_000] {
            let below = (row(boundary / 1.5)..<row(boundary)).reduce(0.0) { $0 + noise[$1] }
            let above = (row(boundary)..<row(boundary * 1.5)).reduce(0.0) { $0 + noise[$1] }
            // White noise's power grows with each slice's width: 1.5 times as many hertz above as below.
            checkEqual(10 * log10(above / below), 10 * log10(1.5), accuracy: 1)
        }
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
        // The display history keeps dBFS as analysed: no 8-bit step, and each cell is read as the waterfall draws
        // it, flat over its box with no interpolation between analysis values.
        let history = SpectrogramHistory()
        let rows = SpectrogramHistory.rows
        checkTrue(history.level(age: 0, row: 0) == nil)
        var column = [Float](repeating: -100, count: rows)
        column[10] = -20
        for index in 0..<SpectrogramHistory.capacity + 3 {
            checkEqual(history.append(column), index % SpectrogramHistory.capacity)
        }
        checkEqual(history.head, 3)
        checkEqual(history.count, SpectrogramHistory.capacity)
        checkEqual(try unwrap(history.level(age: 0, row: 10)), -20, accuracy: 0.0001)
        checkEqual(try unwrap(history.level(age: 0, row: 10.49)), -20, accuracy: 0.0001)
        checkEqual(try unwrap(history.level(age: 0, row: 10.51)), -100, accuracy: 0.0001)
        checkEqual(try unwrap(history.level(age: 0, row: 9.6)), -20, accuracy: 0.0001)
        history.append([Float](repeating: -40, count: rows))
        checkEqual(try unwrap(history.level(age: 0.49, row: 0)), -40, accuracy: 0.0001)
        checkEqual(try unwrap(history.level(age: 0.51, row: 0)), -100, accuracy: 0.0001)
        checkEqual(try unwrap(history.level(age: 1, row: 10)), -20, accuracy: 0.0001)
        history.append(snapshot.spectrogram)
        checkTrue(try unwrap(history.level(age: 0, row: Double(detailedBand))) > -9)
        // Missing and non-finite levels are silence.
        history.append([Float.nan])
        checkEqual(try unwrap(history.level(age: 0, row: 0)), SpectrogramHistory.silence)
        checkEqual(try unwrap(history.level(age: 0, row: 300)), SpectrogramHistory.silence)
        history.reset()
        checkEqual(history.head, 0)
        checkEqual(history.count, 0)
        checkTrue(history.level(age: 0, row: 0) == nil)
        checkTrue(history.levels.allSatisfy { $0 == SpectrogramHistory.silence })
        // One tone curve for the shader, the spectrum fill and the legend: dark at the floor, brightest at the
        // ceiling, rising throughout; and a tilt that pivots at 1 kHz.
        for range in SpectrogramRange.allCases {
            checkEqual(SpectrogramTone.position(range.floor, range: range), 0)
            checkEqual(SpectrogramTone.position(range.ceiling, range: range), 1, accuracy: 0.0001)
            checkEqual(SpectrogramTone.position(range.floor - 30, range: range), 0)
            var previous: Float = -1
            for db in stride(from: range.floor, through: range.ceiling, by: 1) {
                let x = SpectrogramTone.position(db, range: range)
                checkGreaterOrEqual(x, previous)
                previous = x
            }
        }
        checkEqual(SpectrumTilt.flat.offset(frequency: 8_000), 0)
        checkEqual(SpectrumTilt(decibelsPerOctave: 3).offset(frequency: 1_000), 0, accuracy: 0.0001)
        checkEqual(SpectrumTilt(decibelsPerOctave: 3).offset(frequency: 4_000), 6, accuracy: 0.0001)
        checkEqual(SpectrumTilt(decibelsPerOctave: 4.5).offset(frequency: 500), -4.5, accuracy: 0.0001)
        checkEqual(SpectrumTilt(stored: 2.3).decibelsPerOctave, 2.5)
        checkEqual(SpectrumTilt(stored: 40).decibelsPerOctave, 6)
        checkEqual(SpectrumTilt(stored: .nan).decibelsPerOctave, 0)
        let legacy = UserDefaults(suiteName: "tilt-migration-\(UUID().uuidString)")!
        legacy.set("fourAndHalf", forKey: SpectrumTilt.legacyKey)
        SpectrumTilt.migrateLegacy(legacy)
        checkEqual(legacy.double(forKey: SpectrumTilt.key), 4.5)
        checkTrue(legacy.object(forKey: SpectrumTilt.legacyKey) == nil)
    }

    /// The waterfall's analysis (`SpectrogramAnalyzer`): the window lengths it chooses, sine calibration in every
    /// zone and across the blends between them, and the treble's time resolution.
    func testMultiResolutionSpectrogram() throws {
        let rows = MeterSnapshot.spectrogramBandCount
        func row(_ hz: Double, upper: Double = 20_000) -> Int { Int(log(hz / 20) / log(upper / 20) * Double(rows)) }
        let analysis = try unwrap(SpectrogramAnalyzer(sampleRate: 48_000))
        // The span's Hann transform (the spectrum's own) for the bass, then Blackman–Harris from the span down.
        checkEqual(analysis.resolutions.map(\.length), [8192, 8192, 4096, 2048, 1024, 512])
        checkTrue(analysis.resolutions.map(\.window) == [.hann] + Array(repeating: SpectralWindow.blackmanHarris, count: 5))
        // Short windows repeat across the 1/30 s column until every instant weighs within 1 dB, between columns too.
        checkEqual(analysis.resolutions.map(\.frames), [1, 1, 2, 3, 6, 12])
        checkEqual(analysis.length(ofRow: row(100)), 8192)
        checkTrue(analysis.window(ofRow: row(100)) == .hann)
        checkTrue(analysis.window(ofRow: row(700)) == .hann)
        checkTrue(analysis.window(ofRow: row(1_000)) == .blackmanHarris)
        checkEqual(analysis.length(ofRow: row(1_000)), 8192)
        checkEqual(analysis.length(ofRow: row(4_500)), 2048)
        checkEqual(analysis.length(ofRow: row(15_000)), 512)
        // Every row keeps its window's main-lobe half-width within 1/32 of its frequency (about ±½ semitone), except
        // the bass, which no window of the span resolves that finely.
        for index in 0..<rows {
            let centre = 20 * pow(1_000, (Double(index) + 0.5) / Double(rows))
            let window = analysis.window(ofRow: index), length = analysis.length(ofRow: index)
            let lobe = window.mainLobe * 48_000 / Double(length)
            checkTrue(length == 8192 && centre < 375 || centre / lobe >= SpectrogramAnalyzer.resolvingPower * 0.999)
        }
        // Rates change the zones, not the rule: 96 kHz needs twice the window for the same resolution.
        let fast = try unwrap(SpectrogramAnalyzer(sampleRate: 96_000))
        checkEqual(fast.length(ofRow: row(5_000)), 4096)
        checkEqual(fast.length(ofRow: row(5_000)), analysis.length(ofRow: row(5_000)) * 2)

        // The history holds the same ~170 ms at every rate, so the waterfall resolves the same Hz at 192 kHz as at 48.
        checkEqual([44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000].map { SpectrumAnalyzer.historyLength(sampleRate: $0) },
                   [8192, 8192, 16_384, 16_384, 32_768, 32_768])
        let high = try unwrap(SpectrogramAnalyzer(sampleRate: 192_000, span: 32_768))
        for hz in [100.0, 700, 1_000, 3_000, 9_000] {
            checkEqual(Double(high.length(ofRow: row(hz))) / 192_000, Double(analysis.length(ofRow: row(hz))) / 48_000)
        }

        // A sine of amplitude ½ in L and R reads −6.02 dBFS in its row, in every zone and inside every blend.
        for (rate, hz) in [(48_000.0, 50.0), (48_000, 440), (48_000, 800), (48_000, 1_100), (48_000, 1_700), (48_000, 2_600),
                           (48_000, 3_500), (48_000, 4_500), (48_000, 7_000), (48_000, 12_345), (48_000, 18_000),
                           (44_100, 997), (44_100, 9_000), (96_000, 440), (96_000, 6_000), (96_000, 15_000), (192_000, 900),
                           (192_000, 5_000)] {
            let analyzer = try unwrap(SpectrumAnalyzer(sampleRate: rate))
            let frames = (0..<analyzer.historyLength).map { index -> StereoFrame in
                let sample = Float(sin(2 * Double.pi * hz * Double(index) / rate)) * 0.5
                return StereoFrame(left: sample, right: sample)
            }
            frames.withUnsafeBufferPointer { analyzer.consume($0) }
            let column = analyzer.snapshot().spectrogram
            let upper = min(20_000, rate / 2)
            let centre = row(hz, upper: upper)
            let peak = (centre - 2...min(rows - 1, centre + 2)).map { column[$0] }.max()!
            checkEqual(peak, -6.02, accuracy: 0.05)
            // Where the resolving rule holds (above the bass, which even 8192 points cannot resolve that finely), the
            // whole main lobe lies within ±½ semitone: a semitone and a half away the row is more than 85 dB down,
            // below every colour range (Hann's sidelobes left it only ~45 dB down), with no smear from a blend.
            guard hz >= 4 * SpectrogramAnalyzer.resolvingPower * rate / Double(analyzer.historyLength) * 1.5 else { continue }
            let above = row(hz * pow(2, 1.5 / 12), upper: upper)
            if above < rows { checkTrue(column[above] < -6 - 85) }
            checkTrue(column[row(hz * pow(2, -1.5 / 12), upper: upper)] < -6 - 85)
        }

        // Time: a 4 ms burst at 8 kHz in the middle of the analysed audio lights the treble rows; the same burst
        // 75 ms earlier belongs to an earlier column and is gone from them, though the 8192-point window still
        // holds it (it reads in the spectrum).
        func burst(at middle: Int) -> SpectrumAnalyzer {
            let analyzer = try! unwrap(SpectrumAnalyzer(sampleRate: 48_000))
            let frames = (0..<SpectrumAnalyzer.fftSize).map { index -> StereoFrame in
                let t = Double(index - middle) / 96
                let envelope = abs(t) < 1 ? 0.5 + 0.5 * cos(Double.pi * t) : 0
                let sample = Float(envelope * sin(2 * Double.pi * 8_000 * Double(index) / 48_000)) * 0.5
                return StereoFrame(left: sample, right: sample)
            }
            frames.withUnsafeBufferPointer { analyzer.consume($0) }
            return analyzer
        }
        let near = burst(at: SpectrumAnalyzer.fftSize / 2).snapshot()
        let early = burst(at: SpectrumAnalyzer.fftSize / 2 - 3_600).snapshot()
        let treble = row(8_000)
        checkTrue(near.spectrogram[treble] > -40)
        checkTrue(early.spectrogram[treble] < near.spectrogram[treble] - 40)
        checkTrue(early.spectrum.max()! > -80)
    }

    func testDisplayIdleAcrossRates() {
        for rate in [30, 60, 120] {
            var idle = DisplayIdle()
            idle.update(changed: true, at: 10)
            for tick in 1..<(2 * rate) {
                idle.update(changed: false, at: 10 + Double(tick) / Double(rate))
                checkTrue(!idle.settled)
            }
            idle.update(changed: false, at: 12)
            checkTrue(idle.settled)
            // A reset or UI change wakes a fully settled scene for another two seconds.
            idle.update(changed: true, at: 20)
            checkTrue(!idle.settled)
            idle.update(changed: false, at: 21.99)
            checkTrue(!idle.settled)
            idle.update(changed: false, at: 22)
            checkTrue(idle.settled)
        }
        // Dropped frames and a window hidden for a while do not extend the timeout by counting drawn frames.
        var idle = DisplayIdle()
        idle.update(changed: true, at: 0)
        idle.update(changed: false, at: 3)
        checkTrue(idle.settled)
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

    /// The peak readout's frequency and level (`SpectrumAnalyzer.hannPeak`) at every fraction of a bin, in the bass
    /// where a bin is wider than a semitone and higher up, at three rates.
    func testHannPeakEstimate() throws {
        for (rate, base) in [(48_000.0, 41.2), (48_000, 55), (48_000, 440), (44_100, 98), (96_000, 3_000), (192_000, 55)] {
            let length = SpectrumAnalyzer.historyLength(sampleRate: rate)
            let bin = rate / Double(length)
            var worstCents = 0.0
            var worstLevel: Float = 0
            for step in 0..<20 {
                let hz = base + bin * Double(step) / 20
                let analyzer = try unwrap(SpectrumAnalyzer(sampleRate: rate))
                let frames = (0..<length).map { index -> StereoFrame in
                    let sample = Float(sin(2 * Double.pi * hz * Double(index) / rate + 0.3)) * 0.5
                    return StereoFrame(left: sample, right: sample)
                }
                frames.withUnsafeBufferPointer { analyzer.consume($0) }
                let snapshot = analyzer.snapshot()
                worstCents = max(worstCents, abs(1200 * log2(Double(snapshot.peakFrequency) / hz)))
                worstLevel = max(worstLevel, abs(snapshot.peakLevel + 6.0206))
            }
            checkTrue(worstCents < 0.3)
            checkTrue(worstLevel < 0.02)
        }
        // A peak exactly on a bin, and one half-way between two, from the estimator alone.
        checkEqual(SpectrumAnalyzer.hannPeak(-6.0206, 0, -6.0206).offset, 0, accuracy: 0.0001)
        checkEqual(SpectrumAnalyzer.hannPeak(-6.0206, 0, -6.0206).level, 0, accuracy: 0.0001)
        let half = SpectrumAnalyzer.hannPeak(-30, 0, 0)
        checkEqual(half.offset, 0.5, accuracy: 0.0001)
        checkEqual(half.level, 20 * log10(Float.pi * 0.5 * 0.75), accuracy: 0.0001)
        // The same estimator derived from a window's kernel: for Hann it is Grandke's, and for the spectrogram's
        // Blackman–Harris window it recovers a tone anywhere between two bins of a real 1024-point transform.
        checkEqual(PeakEstimator.hann.peak(-30, 0, 0).offset, 0.5, accuracy: 0.0005)
        checkEqual(PeakEstimator.blackmanHarris.gapLimit, 3.35, accuracy: 0.01)
        let length = 1024
        let window = SpectralWindow.blackmanHarris.samples(length).map(Double.init)
        let gain = window.reduce(0, +) / 2
        for step in -10...10 {
            let position = 100 + Double(step) / 20
            let samples = (0..<length).map { window[$0] * 0.5 * sin(2 * Double.pi * position * Double($0) / Double(length) + 0.7) }
            func decibels(_ bin: Int) -> Float {
                var re = 0.0, im = 0.0
                for (n, x) in samples.enumerated() {
                    re += x * cos(2 * Double.pi * Double(bin * n) / Double(length))
                    im -= x * sin(2 * Double.pi * Double(bin * n) / Double(length))
                }
                return Float(20 * log10((re * re + im * im).squareRoot() / gain))
            }
            let k = Int(position.rounded())
            let peak = PeakEstimator.blackmanHarris.peak(decibels(k - 1), decibels(k), decibels(k + 1))
            checkEqual(Double(k) + Double(peak.offset), position, accuracy: 0.003)
            checkEqual(peak.level, -6.0206, accuracy: 0.01)
        }
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
        for rate in [44_100.0, 48_000, 96_000, 192_000] {
            for frequency in [32.7032, 41.2034, 55.0, 110.0] {
                let analyzer = try unwrap(SpectrumAnalyzer(sampleRate: rate))
                let frames = (0..<analyzer.historyLength).map { index -> StereoFrame in
                    let value = Float(0.2 * sin(2 * Double.pi * frequency * Double(index) / rate))
                    return StereoFrame(left: value, right: value)
                }
                frames.withUnsafeBufferPointer { analyzer.consume($0) }
                let notes = analyzer.snapshot().notes
                let detected = stride(from: 0, to: notes.count, by: 2).compactMap { notes[$0] > 0 ? notes[$0] : nil }
                checkEqual(detected.count, 1)
                let peak = try unwrap(detected.first)
                checkEqual(1200 * log2(Double(peak) / frequency), 0, accuracy: 35)
                let silence = [StereoFrame](repeating: StereoFrame(left: 0, right: 0), count: analyzer.historyLength)
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
        // The Soundstage column keeps its minimum and always leaves the analyzers theirs; between them the divider
        // moves freely, so a wide window can give either side most of its width.
        for total in [980, 1_000, 1_400, 2_400] as [CGFloat] {
            for requested in [0, 200, 380, 900, 1_800, .nan] as [CGFloat] {
                let stage = ColumnLayout.stageWidth(requested, total: total)
                checkGreaterOrEqual(stage, ColumnLayout.minStage)
                checkGreaterOrEqual(total - stage - PanelLayout.divider, ColumnLayout.minAnalyzers - 0.001)
            }
        }
        checkEqual(Double(ColumnLayout.stageWidth(2_200, total: 2_400)), Double(2_400 - PanelLayout.divider - ColumnLayout.minAnalyzers))
        checkEqual(Double(ColumnLayout.stageWidth(1_800, total: 2_400)), 1_800)
        checkEqual(Double(ColumnLayout.stageWidth(900, total: 1_400)), Double(1_400 - PanelLayout.divider - ColumnLayout.minAnalyzers))
        // The right-hand column: the room's share is clamped so both panels keep their minimum.
        // The minimums close in continuously from the full ones to the short ones as the column shortens.
        checkTrue(ColumnLayout.minimums(total: 524) == (200, 310))
        checkTrue(ColumnLayout.minimums(total: ColumnLayout.minColumn) == (ColumnLayout.shortRoom, ColumnLayout.shortLevels))
        var shorter = ColumnLayout.minimums(total: 400)
        for total in stride(from: CGFloat(401), through: 600, by: 1) {
            let next = ColumnLayout.minimums(total: total)
            checkTrue(next.room >= shorter.room && next.room - shorter.room <= 1.001
                      && next.levels >= shorter.levels && next.levels - shorter.levels <= 1.001)
            shorter = next
        }
        for total in [416, 450, 500, 800, 1_200] as [CGFloat] {
            for share in [0, 0.1, 0.42, 0.9, .nan] as [CGFloat] {
                let room = ColumnLayout.roomHeight(share: share, total: total)
                let least = ColumnLayout.minimums(total: total)
                checkGreaterOrEqual(room, least.room)
                checkTrue(room <= max(least.room, total - PanelLayout.divider - least.levels))
                if total >= ColumnLayout.minColumn {
                    checkTrue(total - PanelLayout.divider - room >= ColumnLayout.shortLevels - 0.001)
                }
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
            // The time ruler: now at the right edge, the span at the left, and back again.
            checkEqual(Double(stereoWave.x(secondsAgo: 0, seconds: 4)), Double(stereoWave.waveform.maxX), accuracy: 0.001)
            checkEqual(Double(stereoWave.x(secondsAgo: 4, seconds: 4)), Double(stereoWave.waveform.minX), accuracy: 0.001)
            checkEqual(stereoWave.secondsAgo(x: stereoWave.x(secondsAgo: 1.25, seconds: 4), seconds: 4), 1.25, accuracy: 0.0001)
            // Level scales: linear keeps the amplitude; dB puts full scale at the edge, −24 dBFS half way, −48 on the
            // centre line, keeps the sign, and orders the envelope as the samples are ordered.
            checkEqual(WaveScale.linear.deflection(-0.5), -0.5)
            checkEqual(WaveScale.decibels.deflection(decibels: 0), 1, accuracy: 0.0001)
            checkEqual(WaveScale.decibels.deflection(decibels: -24), 0.5, accuracy: 0.0001)
            checkEqual(WaveScale.decibels.deflection(decibels: -60), 0)
            checkEqual(WaveScale.decibels.deflection(-0.5), -WaveScale.decibels.deflection(0.5))
            checkTrue(WaveScale.decibels.deflection(-0.9) < WaveScale.decibels.deflection(-0.1))
            checkEqual(WaveScale.linear.labelled(laneHeight: 34), [-6])
            for scale in WaveScale.allCases {
                for height in [34.0, 60, 120, 300] as [CGFloat] {
                    let ys = scale.labelled(laneHeight: height).map { CGFloat(scale.deflection(decibels: $0)) * height / 2 }
                    for (i, a) in ys.enumerated() { for b in ys.dropFirst(i + 1) { checkTrue(abs(a - b) >= 11) } }
                }
            }
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
            // A fixed span holds at any width and always fits the display history.
            for span in SpectrogramSpan.allCases where span != .auto {
                let fixed = SpectrogramLayout(size: CGSize(width: 400, height: 300), span: span.seconds)
                checkEqual(fixed.seconds, span.seconds)
                checkTrue(fixed.visibleColumns < SpectrogramHistory.capacity)
            }
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
private struct RegressionGenerator: RandomNumberGenerator {
    private var state: UInt64 = 0x416572616C697363
    mutating func next() -> UInt64 {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return state &* 2685821657736338717
    }
}
private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw TestError.unexpectedNil }
    return value
}

@main
struct TestRunner {
    static func main() throws {
        setbuf(stdout, nil)
        try MultiFFTChecks.run()
        try BaselineChecks.run()
        if CommandLine.arguments.contains("--benchmark-gate") {
            var gate = GatedIntegration()
            var checksum: Float = 0
            let start = Date()
            for index in 0..<36_000 {
                gate.add(index.isMultiple(of: 2) ? 1 : 19)
                checksum += gate.integrated()
            }
            print(String(format: "36,000 gated updates: %.4f s, checksum %.4f", Date().timeIntervalSince(start), checksum))
            return
        }
        if CommandLine.arguments.contains("--benchmark-layout") {
            var sum: CGFloat = 0
            let start = Date()
            for index in 0..<100_000 {
                let layout = SoundstageLayout(size: CGSize(width: 400 + index % 2, height: 300),
                                              presence: 1, layout: .s916, part: index % 2 == 0 ? .room : .levels)
                sum += layout.stageScale + layout.columns[0].width
            }
            print(String(format: "100,000 soundstage layouts: %.4f s, checksum %.4f", Date().timeIntervalSince(start), Double(sum)))
            return
        }
        let suite = CoreTests()
        let checks: [(String, () throws -> Void)] = [
            ("dome camera, views and zoom, speaker positions shared with the analysis, the body's quad", suite.testDomeEnergyGeometry),
            ("spatial body: lobes at their levels, one coherent lobe against two uncorrelated, anti-phase wide and out of phase, merging, layers, fallback, LFE", suite.testSpatialBody),
            ("spatial field: the spec's eight cases, Frank's image widths, velocity- and energy-vector directions, two phantoms sharing a speaker, energy kept, wire form", suite.testSpatialField),
            ("spatial bins: amplitude-weighted centres of gravity, panning at every frequency, two sources in one band, energy kept, LFE, silence, wire form", suite.testSpatialPoints),
            ("spatial observations: centres of gravity in the geometry's mapping, one exact reduction (energy, centre, second moment at any detail), below-ear and metric layouts, mirror, rotation, speakers left out, LFE, silence, header, tag 58", suite.testSpatialObservations),
            ("ring wrap and overflow", suite.testRingWrapAndOverflow),
            ("mono duplication and clear", suite.testMonoAndClear),
            ("100,000 concurrent snapshot publications", suite.testExchangeKeepsLatestWithoutTearing),
            ("320,000 concurrent audio frames", suite.testConcurrentAudioRingPreservesOrder),
            ("calibrated sine, RMS and antiphase", suite.testCalibratedSineAndAntiphase),
            ("16-role manual channel assignment", suite.testChannelAssignmentAndOverflow),
            ("BS.1770-5 997 Hz reference and LFE exclusion", suite.testLUFSReferenceAndLFEExclusion),
            ("BS.1770-5 channel weights up to 9.1.6 and unrouted roles", suite.testSurroundAndHeightWeights),
            ("K-weighting matches the 48 kHz response within 0.01 dB from 44.1 to 384 kHz", suite.testKWeightingAcrossSampleRates),
            ("true peak startup has no fabricated onset and preserves priming tails", suite.testTruePeakStartsWithoutSyntheticHistory),
            ("true peak and exact EBU Tech 3342 loudness range", suite.testTruePeakAndLoudnessRange),
            ("EBU Tech 3341 cases 1–6 within 0.1 LU and Tech 3342 cases 1–4 within 1 LU", suite.testEBUConformance),
            ("compliance verdicts: tolerances as shown, maxima, normalization, custom, measuring", suite.testComplianceVerdicts),
            ("master check: tilt, presence, resonances, low-pass cutoff, PSR, crest, mono change", suite.testMasteringMeasures),
            ("signal health: DC offset, infrasonic energy below 20 Hz at 48 and 192 kHz, 40 Hz rejection, settling", suite.testSignalHealth),
            ("true peak preserves the tail into silence across buffer sizes and sample rates", suite.testTruePeakAtSilenceBoundaries),
            ("true peak reads 15–20 kHz inter-sample peaks within 0.005 dB from 44.1 to 192 kHz", suite.testTruePeakNearNyquist),
            ("true peak of 20-tone mixtures within 0.005 dB of the analytic crest, for any buffer split", suite.testTruePeakOfDenseMixtures),
            ("stereometer Cartesian projection matches its polar reference", suite.testScopeSampleProjection),
            ("K-weighting silence tails are independent of audio buffer size", suite.testLoudnessSilencePartitioning),
            ("packed L/R FFT, phase correlation and its zones", suite.testCorrelationAndPackedTransform),
            ("energy-weighted correlation integrator with silence reset", suite.testCorrelationIntegrator),
            ("five stereo bands: correlation, width, balance and level from the L/R cross spectrum", suite.testStereoBands),
            ("one-sided audio retains band level, width and balance", suite.testOneSidedBandReadings),
            ("bands above Nyquist do not borrow low-frequency energy", suite.testUnavailableBandsAreSilent),
            ("invalid audio samples are isolated without clipping valid overs", suite.testInvalidAudioSamplesAreIsolated),
            ("band powers and cross spectrum match calibrated tones at five sample rates", suite.testBandEnergyCalibrationAcrossRates),
            ("speaker layouts 3.0 to 9.1.6", suite.testSpeakerLayouts),
            ("speaker layout files: written in full, read back exactly, minimal files completed, bad values refused", suite.testSpeakerLayoutFile),
            ("channel labels: Audio MIDI Setup's 9.1.6 and 5.1.2, placeholders, WAV 7.1, Atmos tags, routing, VST3 order", suite.testChannelLabels),
            ("chunk boundaries and stereo energy", suite.testChunkBoundariesAndStereoEnergy),
            ("Lightweight resolution metadata matches analysis and describes transitions", suite.testSpectrogramResolutionMetadata),
            ("Spectrum curve preserves measured extrema and mirrored geometry", suite.testSpectrumInterpolationPreservesMeasurements),
            ("8192 FFT, 512-row float spectrogram history, tone curve and tilt", suite.testFullRangeSpectrogramHistory),
            ("128 fine spectrum bands: sine calibration at three rates and agreement with the 64", suite.testFineSpectrumBands),
            ("multi-resolution spectrogram: window choice, calibration across zones and blends, treble timing", suite.testMultiResolutionSpectrogram),
            ("enhanced (reassigned) spectrogram: zones, sine calibration and sharpness, click timing, zone joins", suite.testReassignedSpectrogram),
            ("display idle: two seconds at 30, 60 and 120 Hz, dropped frames and wake after reset", suite.testDisplayIdleAcrossRates),
            ("critically damped 60 Hz display convergence", suite.testDampedDisplayConvergence),
            ("IEC meter scale and shared panel layouts", suite.testMeterScaleAndLayouts),
            ("stereo ↔ spatial detector attack, hold and silence freeze", suite.testFormatDetectorHysteresis),
            ("stereo waveform envelope columns and serial wrap", suite.testWaveformEnvelopeColumns),
            ("multi-level min/max waveform pyramid, dirty uploads and 32-bit wrap", suite.testMinMaxPyramid),
            ("interpolated low-frequency spectrogram rows", suite.testLowFrequencyRowsInterpolate),
            ("pitch naming and interpolated dominant peak", suite.testPitchAndDominantPeak),
            ("peak frequency within 0.3 cents and level within 0.02 dB at any bin offset (Hann estimator)", suite.testHannPeakEstimate),
            ("chord notes without overtones, and their keyboard holds", suite.testChordNotesAndHolds),
            ("bass notes at 44.1, 48 and 96 kHz, and silence clearing", suite.testBassNotesAcrossSampleRates),
            ("peak readout gate, hold and attack", suite.testPeakTrackerGateHoldAndAttack),
            ("channel ring wrap and unrouted roles", suite.testChannelRingWrapsAndClearsUnroutedRoles),
            ("output tap IOProc: interleaved and split streams through the role map", suite.testTapIOProcRoutesStreams),
            ("resizable loudness summary and its stretching column", suite.testSummaryHeightAndStretch),
            ("binned gated integration matches the block scan", suite.testGatedIntegrationMatchesBlockScan),
            ("60 Hz pipeline: 1/30 s windows, 30 Hz columns, long buffers, held peaks", suite.testPipelineWindowsPacingAndHolds),
            ("Spatial spectrum sums every routed channel and skips silent ones, Stereo reads L/R", suite.testSpatialSpectrumSumsRoutedChannels),
            ("localized text keeps instrument terms and units on one line", suite.testLocalizerKeepsTermsAndUnitsTogether)
        ]
        for (name, run) in checks { try run(); print("PASS: \(name)") }
        print("All \(checks.count) core checks passed.")
    }
}
