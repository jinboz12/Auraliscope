import BridgeAnalysis
import Foundation

// The C entry points of BridgeAnalysis.h, compiled into the same Swift module as the analysis core
// (Sources/AnalysisCore) inside each plugin binary. An `AbrAnalyzer *` is a retained `StreamAnalyzer`.

private func analyzer(_ pointer: OpaquePointer) -> StreamAnalyzer {
    Unmanaged<StreamAnalyzer>.fromOpaque(UnsafeRawPointer(pointer)).takeUnretainedValue()
}

@_cdecl("abr_analyzer_create")
func abrAnalyzerCreate(_ sampleRate: Double, _ channels: UInt32, _ roles: UnsafePointer<UInt8>?, _ generation: UInt32,
                       _ formatEpoch: UInt32) -> OpaquePointer? {
    guard (1...UInt32(Role.count)).contains(channels) else { return nil }
    let channelRoles = roles.map { pointer in (0..<Int(channels)).map { Int(pointer[$0]) } }
        ?? (channels == 1 ? [Role.left] : [Role.left, Role.right])
    guard let analyzer = StreamAnalyzer(sampleRate: sampleRate, roles: channelRoles, generation: generation,
                                        formatEpoch: formatEpoch) else { return nil }
    return OpaquePointer(Unmanaged.passRetained(analyzer).toOpaque())
}

@_cdecl("abr_analyzer_destroy")
func abrAnalyzerDestroy(_ pointer: OpaquePointer?) {
    guard let pointer else { return }
    Unmanaged<StreamAnalyzer>.fromOpaque(UnsafeRawPointer(pointer)).release()
}

@_cdecl("abr_analyzer_consume")
func abrAnalyzerConsume(_ pointer: OpaquePointer, _ samples: UnsafePointer<Float>, _ frames: UInt32, _ position: UInt64,
                        _ now: Double) {
    analyzer(pointer).consume(samples, frames: Int(frames), position: position, now: now)
}

@_cdecl("abr_analyzer_interrupt")
func abrAnalyzerInterrupt(_ pointer: OpaquePointer, _ lostFrames: UInt64, _ idleMilliseconds: UInt32, _ reasons: UInt32) {
    analyzer(pointer).interrupt(lostFrames: lostFrames, idleMilliseconds: idleMilliseconds, reasons: reasons)
}

@_cdecl("abr_analyzer_idle")
func abrAnalyzerIdle(_ pointer: OpaquePointer, _ now: Double) -> Int32 {
    analyzer(pointer).idle(now: now) ? 1 : 0
}

@_cdecl("abr_analyzer_set_measuring")
func abrAnalyzerSetMeasuring(_ pointer: OpaquePointer, _ measuring: Int32) {
    analyzer(pointer).setMeasuring(measuring != 0)
}

@_cdecl("abr_analyzer_reset_true_peaks")
func abrAnalyzerResetTruePeaks(_ pointer: OpaquePointer) {
    analyzer(pointer).resetTruePeaks()
}

@_cdecl("abr_analyzer_set_spectrogram_mode")
func abrAnalyzerSetSpectrogramMode(_ pointer: OpaquePointer, _ mode: UInt32) {
    analyzer(pointer).spectrogramMode = SpectrogramMode(rawValue: mode) ?? .classic
}

@_cdecl("abr_analyzer_set_spectrum_channels")
func abrAnalyzerSetSpectrumChannels(_ pointer: OpaquePointer, _ channels: UInt32) {
    analyzer(pointer).spatialSpectrum = channels == 1
}

@_cdecl("abr_analyzer_set_spatial_coherence")
func abrAnalyzerSetSpatialCoherence(_ pointer: OpaquePointer, _ thousandths: UInt32) {
    analyzer(pointer).spatialCoherence = thousandths == 0 ? SpatialField.defaultThreshold : Float(thousandths) / 1000
}

@_cdecl("abr_analyzer_ticks")
func abrAnalyzerTicks(_ pointer: OpaquePointer) -> UInt64 {
    analyzer(pointer).ticks
}

@_cdecl("abr_analyzer_encode")
func abrAnalyzerEncode(_ pointer: OpaquePointer, _ buffer: UnsafeMutableRawPointer, _ capacity: UInt32,
                       _ subscription: UInt32, _ layout: UInt32, _ afterSpectrogram: UInt64, _ afterWaveform: UInt64,
                       _ spectrogramThrough: UnsafeMutablePointer<UInt64>?,
                       _ waveformThrough: UnsafeMutablePointer<UInt64>?) -> UInt32 {
    let encoded = analyzer(pointer).encode(into: buffer, capacity: Int(capacity), subscription: subscription, layout: layout,
                                           afterSpectrogram: afterSpectrogram, afterWaveform: afterWaveform)
    spectrogramThrough?.pointee = encoded.spectrogramThrough
    waveformThrough?.pointee = encoded.waveformThrough
    return UInt32(encoded.bytes)
}

@_cdecl("abr_analyzer_summary")
func abrAnalyzerSummary(_ pointer: OpaquePointer, _ summary: UnsafeMutablePointer<AbrAnalysisSummary>) {
    let a = analyzer(pointer)
    let v = a.snapshot
    var s = AbrAnalysisSummary()
    s.generation = a.generation
    s.measuring = a.measuring ? 1 : 0
    s.channels = UInt32(a.channels)
    s.breaks = UInt32(v[SnapshotSlots.breaks])
    s.ticks = a.ticks
    s.frames_analysed = a.framesAnalysed
    s.seconds_analysed = Double(a.framesAnalysed) / a.sampleRate
    s.peak = (v[SnapshotSlots.peaks + Role.left], a.channels > 1 ? v[SnapshotSlots.peaks + Role.right] : 0)
    s.held_true_peak = (v[SnapshotSlots.heldTruePeaks + Role.left], a.channels > 1 ? v[SnapshotSlots.heldTruePeaks + Role.right] : 0)
    // The loudest channel, for a bus whose channels the window cannot list one by one.
    let loudestPeak = a.roles.max { v[SnapshotSlots.peaks + $0] < v[SnapshotSlots.peaks + $1] } ?? Role.left
    let loudestTruePeak = a.roles.max { v[SnapshotSlots.heldTruePeaks + $0] < v[SnapshotSlots.heldTruePeaks + $1] } ?? Role.left
    s.loudest_peak = v[SnapshotSlots.peaks + loudestPeak]
    s.loudest_peak_role = UInt32(loudestPeak)
    s.loudest_held_true_peak = v[SnapshotSlots.heldTruePeaks + loudestTruePeak]
    s.loudest_held_true_peak_role = UInt32(loudestTruePeak)
    s.momentary = v[SnapshotSlots.momentary]
    s.short_term = v[SnapshotSlots.shortTerm]
    s.integrated = v[SnapshotSlots.integrated]
    s.loudness_range = v[SnapshotSlots.range]
    summary.pointee = s
}
