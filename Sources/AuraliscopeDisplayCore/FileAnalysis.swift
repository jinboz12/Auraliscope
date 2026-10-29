import AnalysisCore
import AVFoundation
import Foundation

/// A whole audio file measured offline, as the desktop's Analyze Audio File… measures it (Build 120,
/// `AudioFileAnalyzer` in Sources/Auraliscope/FileAnalysis.swift): the shared `StreamAnalyzer` at the file's own rate,
/// ticked by the audio, loudness read at 10 Hz, the peaks of every 60 Hz tick kept between readings. The desktop's
/// mastering statistics (spectral balance, silence, report pages) are not part of the iPad's first version.
public struct FileMeasurement: Sendable {
    public var name: String
    public var sampleRate: Double
    public var channels: Int
    public var roles: [Int]
    public var frames: Int64
    public var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
    public var codec: String
    public var integrated: Float
    public var range: Float
    /// dBTP and dBFS of the loudest held peaks (−120 for silence).
    public var truePeak: Float
    public var samplePeak: Float
    public var maxMomentary: Float
    public var maxShortTerm: Float
    /// Runs of 10 Hz readings whose true peak exceeded full scale.
    public var overs: Int
    /// 10 Hz readings, LUFS.
    public var momentary: [Float]
    public var shortTerm: [Float]
    /// The analysis' state at the end of the file, for the panels.
    public var finalFrame: AnalysisFrame?
    public var elapsed: Double
}

public enum FileAnalysisError: LocalizedError, Equatable {
    case unreadable
    case channels(Int)
    case empty
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "The file could not be read as audio. It may be damaged, protected, or in a format iPadOS does not decode."
        case .channels(let count): return "Files with \(count) channels are not supported. Mono, stereo and the multichannel layouts from 3.0 to 9.1.6 are."
        case .empty: return "The file holds no audio."
        case .cancelled: return "The analysis was cancelled."
        }
    }
}

public enum FileAnalyzer {
    public static let readingRate = 10.0

    /// Analyses the file at `url` on the calling thread (call it off the main thread). `progress` gets the fraction
    /// done now and then; returning false cancels.
    public static func analyse(_ url: URL, progress: (Double) -> Bool) throws -> FileMeasurement {
        let began = Date()
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw FileAnalysisError.unreadable }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard file.length > 0, format.sampleRate > 0 else { throw FileAnalysisError.empty }
        guard let roles = LocalAnalysisSession.roles(channels: channels) else { throw FileAnalysisError.channels(channels) }
        let rate = format.sampleRate
        guard let analyzer = StreamAnalyzer(sampleRate: rate, roles: roles, generation: 1, formatEpoch: 1) else {
            throw FileAnalysisError.unreadable
        }
        analyzer.spatialSpectrum = channels > 2
        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw FileAnalysisError.empty }
        var interleaved = [Float](repeating: 0, count: Int(chunk) * channels)

        var momentary: [Float] = [], shortTerm: [Float] = []
        var maxMomentary: Float = -100, maxShortTerm: Float = -100
        var overs = 0, overBefore = false
        var tickOverPeak: Float = 0
        var audioTicks = 0
        var fed: Int64 = 0
        let subTicks = Int(MeterPipeline.tickRate / readingRate)
        func tickEnd(_ n: Int) -> Int64 { Int64((Double(n) * rate / MeterPipeline.tickRate).rounded()) }

        func reading(_ v: [Float]) {
            momentary.append(v[SnapshotSlots.momentary])
            shortTerm.append(v[SnapshotSlots.shortTerm])
            maxMomentary = max(maxMomentary, v[SnapshotSlots.momentary])
            maxShortTerm = max(maxShortTerm, v[SnapshotSlots.shortTerm])
            let over = tickOverPeak > 1
            if over && !overBefore { overs += 1 }
            overBefore = over
            tickOverPeak = 0
        }
        func tick() {
            let v = analyzer.snapshot
            for role in roles { tickOverPeak = max(tickOverPeak, v[SnapshotSlots.truePeaks + role]) }
            if audioTicks % subTicks == 0 { reading(v) }
        }

        var lastReport = Date.distantPast
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: chunk) } catch { throw FileAnalysisError.unreadable }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let planes = buffer.floatChannelData else { break }
            for channel in 0..<channels {
                let plane = planes[channel]
                for frame in 0..<frames { interleaved[frame * channels + channel] = plane[frame] }
            }
            try interleaved.withUnsafeBufferPointer { samples in
                var offset = 0
                while offset < frames {
                    let count = min(frames - offset, Int(tickEnd(audioTicks + 1) - fed))
                    analyzer.consume(samples.baseAddress! + offset * channels, frames: count, position: UInt64(fed),
                                     now: Double(fed) / rate)
                    fed += Int64(count)
                    offset += count
                    if fed == tickEnd(audioTicks + 1) {
                        audioTicks += 1
                        tick()
                    }
                }
                if Date().timeIntervalSince(lastReport) > 0.05 {
                    lastReport = Date()
                    guard progress(Double(fed) / Double(file.length)) else { throw FileAnalysisError.cancelled }
                }
            }
        }
        guard audioTicks > 0 else { throw FileAnalysisError.empty }
        if audioTicks % subTicks != 0 { reading(analyzer.snapshot) }
        let v = analyzer.snapshot
        var heldPeak: Float = 0, heldTruePeak: Float = 0
        for role in roles {
            heldPeak = max(heldPeak, v[SnapshotSlots.heldPeaks + role])
            heldTruePeak = max(heldTruePeak, v[SnapshotSlots.heldTruePeaks + role], v[SnapshotSlots.heldPeaks + role])
        }
        var bytes = [UInt8](repeating: 0, count: 256 * 1024)
        let layout: UInt32 = channels == 1 ? 1 : channels == 2 ? 2 : 3
        let encoded = bytes.withUnsafeMutableBytes {
            analyzer.encode(into: $0.baseAddress!, capacity: $0.count, subscription: 1, layout: layout,
                            afterSpectrogram: analyzer.spectrogramLatest, afterWaveform: analyzer.waveformLatest)
        }
        _ = progress(1)
        return FileMeasurement(name: url.lastPathComponent, sampleRate: rate, channels: channels, roles: roles,
                               frames: file.length, codec: codecName(file.fileFormat, url: url),
                               integrated: v[SnapshotSlots.integrated], range: v[SnapshotSlots.range],
                               truePeak: decibels(heldTruePeak), samplePeak: decibels(heldPeak),
                               maxMomentary: maxMomentary, maxShortTerm: maxShortTerm, overs: overs,
                               momentary: momentary, shortTerm: shortTerm,
                               finalFrame: encoded.bytes > 0 ? AnalysisFrame.decode(Data(bytes[0..<encoded.bytes])) : nil,
                               elapsed: Date().timeIntervalSince(began))
    }

    static func codecName(_ format: AVAudioFormat, url: URL) -> String {
        switch format.streamDescription.pointee.mFormatID {
        case kAudioFormatLinearPCM:
            let ext = url.pathExtension.lowercased()
            return ["wav": "WAV", "wave": "WAV", "bwf": "BWF", "aif": "AIFF", "aiff": "AIFF", "aifc": "AIFF-C", "caf": "CAF"][ext]
                ?? (ext.isEmpty ? "PCM" : ext.uppercased())
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return "AAC"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatFLAC: return "FLAC"
        default: return url.pathExtension.uppercased()
        }
    }
}
