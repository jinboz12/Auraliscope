import AnalysisCore
import AudioRing
import Foundation
import QuartzCore

/// What the model needs of whatever produces its snapshots: the local analysis of a device (`DSPWorker`) or the
/// results of a DAW plugin that analyses its own audio (`ResultWorker`).
protocol MeterWorker: AnyObject {
    func latest() -> MeterSnapshot?
    func pause()
    func resume()
    func stop()
    func resetTruePeaks()
    func setSpatialSpectrum(_ spatial: Bool)
    func setSpectrogramMode(_ mode: SpectrogramMode)
    /// The spatial field's coherence threshold and the shown layout's side surrounds.
    func setSpatialField(threshold: Float, geometry: SpatialGeometry)
}

extension DSPWorker: MeterWorker {}

/// Shows a DAW plugin's results: no audio and no analysis here. At the display rate it takes the next snapshot
/// the `ResultInbox` has assembled from what the plugin sent, and publishes it through the same triple buffer the
/// local analysis uses, so every canvas and readout works unchanged.
///
/// Pausing holds the display where it is (the plugin's own measurement is paused separately, by a command);
/// resetting the true peaks is the plugin's job too (`MeterModel` sends the command).
final class ResultWorker: MeterWorker {
    /// With no result for this long, the instantaneous readings fall to silence (loudness and histories stay).
    static let staleAfter = 0.3
    let inbox: ResultInbox
    private let queue = DispatchQueue(label: "Auraliscope.results", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let exchange: OpaquePointer
    private var readValues = [Float](repeating: 0, count: Int(METER_SNAPSHOT_FLOATS))
    private var suspended = false

    init?(inbox: ResultInbox) {
        precondition(SnapshotSlots.total == Int(METER_SNAPSHOT_FLOATS), "snapshot layout and C buffer disagree")
        guard let exchange = meter_exchange_create() else { return nil }
        self.inbox = inbox
        self.exchange = exchange
        let source = DispatchSource.makeTimerSource(queue: queue)
        var values = [Float](repeating: 0, count: Int(METER_SNAPSHOT_FLOATS))
        source.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / MeterPipeline.tickRate)),
                        leeway: .milliseconds(1))
        source.setEventHandler { [inbox, exchange] in
            if inbox.publish(into: &values, staleAfter: Self.staleAfter) { meter_exchange_publish(exchange, values) }
        }
        timer = source
        source.resume()
    }

    func latest() -> MeterSnapshot? {
        guard meter_exchange_read(exchange, &readValues) != 0 else { return nil }
        return DSPWorker.decode(readValues)
    }

    func pause() {
        guard !suspended, let timer else { return }
        timer.suspend()
        suspended = true
        queue.sync {}
    }

    func resume() {
        guard suspended, let timer else { return }
        suspended = false
        timer.resume()
    }

    func stop() {
        if suspended { resume() }
        timer?.cancel()
        timer = nil
        queue.sync {}
    }

    func resetTruePeaks() {}
    func setSpatialSpectrum(_ spatial: Bool) {}
    /// The plugin analyses: `BridgeReceiver.setSpectrogram` asks it.
    func setSpectrogramMode(_ mode: SpectrogramMode) {}
    /// The plugin analyses: its threshold travels in SUBSCRIBE (`BridgeSource.setCoherence`).
    func setSpatialField(threshold: Float, geometry: SpatialGeometry) {}

    deinit {
        stop()
        meter_exchange_destroy(exchange)
    }
}
