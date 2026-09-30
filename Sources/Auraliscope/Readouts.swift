import AnalysisCore
import Foundation

/// Numbers people read, published at 10 Hz as one value so only the small text views that
/// observe it re-render. Canvases keep drawing bars at the display rate independently.
@MainActor
final class Readouts: ObservableObject {
    struct Values: Equatable {
        var momentary: Float = -100
        var shortTerm: Float = -100
        var integrated: Float = -100
        /// EBU loudness range in LU; negative until measurable.
        var range: Float = -1
        /// Highest sample peak per role since the last reset, linear.
        var heldPeaks = [Float](repeating: 0, count: Role.count)
        /// Highest true peak (any role) since the last reset, linear.
        var heldTruePeak: Float = 0
        /// Highest true peak per role since the last reset, linear: above 1 the channel went over 0 dBTP.
        var heldTruePeaks = [Float](repeating: 0, count: Role.count)
        /// L/R correlation, smoothed for reading; `MeterSnapshot.noCorrelation` in silence.
        var correlation: Float = MeterSnapshot.noCorrelation
        /// Per `StereoBands` band, smoothed the same way; `noCorrelation` while a band is silent.
        var bandCorrelation = [Float](repeating: MeterSnapshot.noCorrelation, count: StereoBands.groups.count)
        /// What the correlation means (with hysteresis, so the name holds steady); nil in silence.
        var correlationZone: CorrelationZone?
        /// Level change of L+R summed to mono, dB (`MeterScale.monoFoldDown`), smoothed; nil in silence.
        var monoFoldDown: Float?
        /// Power sum of every routed role except LFE, dBFS: the VU readout's number.
        var programmeLevel: Float = -120
        var elapsed: TimeInterval = 0
        /// Short-term and momentary loudness, oldest first, one entry per tick.
        var shortHistory: [Float] = []
        var momentaryHistory: [Float] = []
        var peak = PeakTracker()
        /// Every note the keyboard lights (the dominant one is `peak`).
        var notes = NoteHolds()

        var maxPeak: Float { heldPeaks.max() ?? 0 }
        var truePeakDecibels: Float { MeterScale.decibels(heldTruePeak) }
    }

    static let rate = 10.0
    /// The loudness history in the summary covers the last 15 s.
    static let historySeconds = 15.0
    static let historyLength = Int(historySeconds * rate)

    @Published private(set) var values = Values()
    /// Kept current at 10 Hz even while the meter window is hidden (so peaks and the 15 s history stay
    /// complete); only published to SwiftUI while the window is on screen.
    private var latest = Values()
    private weak var model: MeterModel?
    private var timer: Timer?

    func attach(to model: MeterModel) {
        self.model = model
        timer?.invalidate()
        let timer = Timer(timeInterval: 1 / Self.rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func reset() {
        latest = Values()
        values = latest
        truePeakGrace = 0
    }

    /// Ticks left in which a snapshot's held true peaks may predate a true-peak reset (the DSP clears its own
    /// within a tick).
    private var truePeakGrace = 0

    /// Clears the held true peaks alone: the TRUE PEAK reading and every channel's over.
    func resetTruePeak() {
        latest.heldTruePeak = 0
        latest.heldTruePeaks = Array(repeating: 0, count: Role.count)
        truePeakGrace = 2
        values = latest
    }

    /// Hidden, minimised or covered by a full-screen app: re-rendering the readouts would be wasted work.
    private var onScreen: Bool { MainWindow.window?.occlusionState.contains(.visible) ?? true }

    private func publish() {
        if onScreen && latest != values { values = latest }
    }

    private func tick() {
        guard let model else { return }
        model.refreshDroppedFrames()
        guard model.running else {
            // Paused, the readings hold as they were; stopped, the peak badge and the lit keys go out.
            if !model.frozen {
                if latest.peak.visible { latest.peak.reset() }
                if !latest.notes.notes.isEmpty { latest.notes.reset() }
            }
            publish()
            return
        }
        let snapshot = model.pollSnapshot()
        model.refreshFormat(from: snapshot)
        model.refreshContinuity(from: snapshot)
        var next = latest
        next.momentary = snapshot.momentaryLUFS
        next.shortTerm = snapshot.shortLUFS
        next.integrated = snapshot.integratedLUFS
        next.range = snapshot.loudnessRange
        let routed = model.routedRoles
        // The DSP keeps the maxima since the stream started, so peaks in snapshots this 10 Hz tick never
        // sampled still count.
        // The DSP's held true peak already includes the sample peaks, so a true-peak reset is not undone by the
        // held sample peak.
        let held = truePeakGrace == 0
        if truePeakGrace > 0 { truePeakGrace -= 1 }
        for role in 0..<Role.count where routed[role] {
            next.heldPeaks[role] = max(next.heldPeaks[role], snapshot.channelPeaks[role], snapshot.heldPeaks[role])
            next.heldTruePeaks[role] = max(next.heldTruePeaks[role], snapshot.channelTruePeaks[role], snapshot.channelPeaks[role],
                                           held ? snapshot.heldTruePeaks[role] : 0)
            next.heldTruePeak = max(next.heldTruePeak, next.heldTruePeaks[role])
        }
        // The DSP integrates correlation already; this only steadies the hundredths between 10 Hz samples.
        if snapshot.correlation == MeterSnapshot.noCorrelation || next.correlation == MeterSnapshot.noCorrelation {
            next.correlation = snapshot.correlation
        } else {
            next.correlation += (snapshot.correlation - next.correlation) * 0.5
        }
        for band in 0..<StereoBands.groups.count {
            let target = snapshot.bandCorrelation[band]
            if target == MeterSnapshot.noCorrelation || next.bandCorrelation[band] == MeterSnapshot.noCorrelation {
                next.bandCorrelation[band] = target
            } else {
                next.bandCorrelation[band] += (target - next.bandCorrelation[band]) * 0.5
            }
        }
        next.correlationZone = next.correlation == MeterSnapshot.noCorrelation ? nil
            : CorrelationZone(next.correlation, previous: next.correlationZone)
        let foldDown = MeterScale.monoFoldDown(correlation: next.correlation, left: snapshot.channelRMS[Role.left],
                                               right: snapshot.channelRMS[Role.right])
        if let foldDown, let previous = next.monoFoldDown {
            next.monoFoldDown = previous + (foldDown - previous) * 0.5
        } else {
            next.monoFoldDown = foldDown
        }
        next.programmeLevel = VUScale.aggregate(rms: snapshot.channelRMS, roles: routed)
        next.elapsed = model.captureStarted.map { Date().timeIntervalSince($0) } ?? 0
        next.peak.update(frequency: snapshot.peakFrequency, level: snapshot.peakLevel, deltaTime: 1 / Self.rate)
        next.notes.update(snapshot.notes, deltaTime: 1 / Self.rate)
        next.shortHistory.append(snapshot.shortLUFS)
        next.momentaryHistory.append(snapshot.momentaryLUFS)
        if next.shortHistory.count > Self.historyLength {
            next.shortHistory.removeFirst(next.shortHistory.count - Self.historyLength)
            next.momentaryHistory.removeFirst(next.momentaryHistory.count - Self.historyLength)
        }
        model.refreshSilence(heardSignal: next.maxPeak > 0)
        latest = next
        publish()
    }
}
