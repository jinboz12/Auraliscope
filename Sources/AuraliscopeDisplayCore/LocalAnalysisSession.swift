import AnalysisCore
import Foundation

/// This device's own analysis of one audio stream (a microphone, an audio interface, a file): the Bridge plugins'
/// analysis (`StreamAnalyzer`, the shared core) run here, its results encoded as a plugin encodes a RESULT and decoded
/// as a display decodes one. Local and remote results therefore reach the panels through the same decoder, with the
/// same units, limits and meanings, and nothing of the analysis is reimplemented for the iPad.
///
/// Not thread-safe and never for a real-time thread: the owner calls it from one serial queue.
public final class LocalAnalysisSession {
    public let sampleRate: Double
    public let roles: [Int]
    public var channels: Int { roles.count }
    public let generation: UInt32
    private let analyzer: StreamAnalyzer
    private var buffer: [UInt8]
    private var sentSpectrogram: UInt64 = 0
    private var sentWaveform: UInt64 = 0
    private var publishedTicks: UInt64 = 0
    private var position: UInt64 = 0
    private static let subscription: UInt32 = 1

    /// `roles`: each channel's speaker role (`Role`), [L] for mono, [L, R] for stereo. nil for a layout the analysis
    /// cannot measure (it needs mono, or L and R among distinct roles) or a rate outside 8–384 kHz.
    public init?(sampleRate: Double, roles: [Int], generation: UInt32) {
        guard (8_000...384_000).contains(sampleRate),
              let analyzer = StreamAnalyzer(sampleRate: sampleRate, roles: roles, generation: generation, formatEpoch: generation)
        else { return nil }
        self.analyzer = analyzer
        self.sampleRate = sampleRate
        self.roles = roles
        self.generation = generation
        buffer = [UInt8](repeating: 0, count: 256 * 1024)
        // A multichannel source sums every channel in the spectrum, as the desktop's Immersive and file analysis do.
        analyzer.spatialSpectrum = roles.count > 2
    }

    /// Roles for `channels` input channels: mono, stereo, or the conventional SMPTE order the desktop's file analysis
    /// reads a multichannel file in. nil for a count it has no layout for.
    public static func roles(channels: Int) -> [Int]? {
        switch channels {
        case 1: return [Role.left]
        case 2: return [Role.left, Role.right]
        case 3: return [0, 1, 2]
        case 4: return [0, 1, 4, 5]
        case 5: return [0, 1, 2, 4, 5]
        case 6: return [0, 1, 2, 3, 4, 5]
        case 7: return [0, 1, 2, 4, 5, 8, 9]
        case 8: return [0, 1, 2, 3, 4, 5, 8, 9]
        case 10: return [0, 1, 2, 3, 4, 5, 8, 9, 6, 7]
        case 12: return [0, 1, 2, 3, 4, 5, 8, 9, 6, 7, 14, 15]
        case 14: return [0, 1, 2, 3, 4, 5, 8, 9, 6, 7, 12, 13, 14, 15]
        case 16: return [0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 6, 7, 12, 13, 14, 15]
        default: return nil
        }
    }

    /// Analyses `frames` interleaved frames. `now`: seconds on a monotonic clock (the analysis' idle timing only; the
    /// measurement is ticked by the audio itself, 60 times per second of audio).
    public func consume(_ samples: UnsafePointer<Float>, frames: Int, now: Double) {
        guard frames > 0 else { return }
        analyzer.consume(samples, frames: frames, position: position, now: now)
        position += UInt64(frames)
    }

    /// A break before the next audio (frames lost, the input interrupted): what must not span it restarts, as at a
    /// plugin's break; integrated loudness and the held peaks carry on.
    public func interrupt(lostFrames: UInt64, reasons: UInt32) {
        analyzer.interrupt(lostFrames: lostFrames, idleMilliseconds: 0, reasons: reasons)
        position += lostFrames
    }

    /// No audio arrived for a while: lets the meters fall as the plugins' do.
    public func idle(now: Double) { analyzer.idle(now: now) }

    public func setMeasuring(_ on: Bool) { analyzer.setMeasuring(on) }
    public func resetTruePeaks() { analyzer.resetTruePeaks() }
    public var measuring: Bool { analyzer.measuring }
    public var framesAnalysed: UInt64 { analyzer.framesAnalysed }

    /// The newest state with the spectrogram columns not yet taken, when anything was published since the last call.
    public func takeFrame() -> AnalysisFrame? {
        guard analyzer.ticks != publishedTicks else { return nil }
        publishedTicks = analyzer.ticks
        let layout: UInt32 = roles.count == 1 ? 1 : roles == [Role.left, Role.right] ? 2 : 3
        let capacity = buffer.count
        let encoded = buffer.withUnsafeMutableBytes { raw in
            analyzer.encode(into: raw.baseAddress!, capacity: capacity, subscription: Self.subscription, layout: layout,
                            afterSpectrogram: sentSpectrogram, afterWaveform: sentWaveform, maxSpectrogram: 64)
        }
        guard encoded.bytes > 0 else { return nil }
        sentSpectrogram = encoded.spectrogramThrough
        sentWaveform = encoded.waveformThrough
        return AnalysisFrame.decode(Data(buffer[0..<encoded.bytes]))
    }
}
