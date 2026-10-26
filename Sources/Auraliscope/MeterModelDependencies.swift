import AnalysisCore
import AudioRing
import Foundation

/// What the model needs of the capture of a device (`AudioCapture`): start it for a routing, stop it, and the ring it
/// fills.
protocol CaptureBackend: AnyObject {
    var ring: OpaquePointer { get }
    var sampleRate: Double { get }
    var channels: UInt32 { get }
    func start(device: InputDevice, sourceForRole: [Int32]) throws
    /// Returns drops from this capture after the last callback, before clearing its ring for reuse.
    @discardableResult func stop() -> UInt64
}

extension AudioCapture: CaptureBackend {}

/// What the model needs of the DAW plugin receiver (`BridgeReceiver`).
protocol BridgeReceiving: AnyObject {
    func sources() -> [BridgeSource]
    func select(_ session: [UInt8]?)
    func setSpectrogram(_ mode: SpectrogramMode)
    func setSpectrum(everyChannel: Bool)
    func setCoherence(_ threshold: Float)
    func setSpatial(_ geometry: SpatialGeometry)
    func attach(_ inbox: ResultInbox)
    func detach()
    func command(_ session: [UInt8], _ command: Int32, generation: UInt32) -> UInt32
    func disconnect(_ session: [UInt8], refusingFor milliseconds: UInt32)
}

extension BridgeReceiving {
    /// A command for whichever analysis generation is current.
    func command(_ session: [UInt8], _ command: Int32) -> UInt32 { self.command(session, command, generation: 0) }
}

extension BridgeReceiver: BridgeReceiving {}

/// Everything `MeterModel` reaches outside the process through: the capture of a device, the DAW plugin receiver, the
/// list of audio devices and its change notifications, and the analysis of a device's audio. The app uses the real ones
/// (`live`); `--test-model-lifecycle` stands in for them, so source switching, capture, pause and resume and the DAW
/// plugin states can be checked with no device and no DAW.
struct MeterModelDependencies {
    /// The capture of a device, created once; nil when its ring cannot be allocated.
    var makeCapture: @MainActor () -> CaptureBackend?
    var startReceiver: @MainActor () -> Result<BridgeReceiving, BridgeReceiverError>
    var availableSources: @MainActor () -> [InputDevice]
    /// Whether Core Audio's device, configuration and speaker changes are followed (`HardwareObserver`).
    var observesHardware: Bool
    /// The analysis of a device's audio as it fills `ring`.
    var makeLocalWorker: @MainActor (_ ring: OpaquePointer, _ sampleRate: Double, _ streamID: UInt32, _ activeRoles: [Bool],
                                     _ detector: FormatDetector) -> MeterWorker?

    static let live = MeterModelDependencies(
        makeCapture: { AudioCapture() },
        startReceiver: { BridgeReceiver.start().map { $0 } },
        availableSources: { AudioDevices.availableSources() },
        observesHardware: true,
        makeLocalWorker: { DSPWorker(ring: $0, sampleRate: $1, streamID: $2, activeRoles: $3, detector: $4) })
}
