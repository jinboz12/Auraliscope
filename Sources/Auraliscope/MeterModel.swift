import AVFoundation
import AnalysisCore
import AppKit
import AudioRing
import BridgeTransport
import Combine
import CoreAudio
import Foundation
import QuartzCore

// A private serial queue owns all DSP state. The UI only reads the triple buffer.
final class DSPWorker {
    private let queue = DispatchQueue(label: "Auraliscope.dsp", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let exchange: OpaquePointer
    private var readValues = [Float](repeating: 0, count: Int(METER_SNAPSHOT_FLOATS))
    /// The analysis clock leaves out time spent paused, so a resumed stream carries on as if uninterrupted.
    private final class Clock { var paused: CFTimeInterval = 0 }
    private let clock = Clock()
    private var pausedAt: CFTimeInterval?
    /// Owned by `queue`: only ever touched there.
    private let pipeline: MeterPipeline
    private var spectrogramMode = SpectrogramMode.classic
    private let multiFFTMailbox = MultiFFTMailbox()
    private var multiFFTConfiguration: MultiFFTConfiguration?
    private var legacyChoice: LegacySTFT?

    init?(ring: OpaquePointer, sampleRate: Double, streamID: UInt32, activeRoles: [Bool], detector: FormatDetector) {
        precondition(SnapshotSlots.total == Int(METER_SNAPSHOT_FLOATS), "snapshot layout and C buffer disagree")
        guard let pipeline = MeterPipeline(sampleRate: sampleRate, activeRoles: activeRoles, detector: detector, streamID: streamID),
              let exchange = meter_exchange_create() else { return nil }
        self.exchange = exchange
        self.pipeline = pipeline
        let source = DispatchSource.makeTimerSource(queue: queue)
        var batch = [ChannelFrame](repeating: ChannelFrame(), count: 4096)
        var values = [Float](repeating: 0, count: Int(METER_SNAPSHOT_FLOATS))
        var receivedPCM = false
        var receivedSignal = false
        var truePeakResets: UInt32 = 0
        var mark = ChannelRingMark()
        var marked: Int32 = 0
        let clock = clock
        let multiFFTMailbox = multiFFTMailbox
        source.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / MeterPipeline.tickRate)), leeway: .milliseconds(1))
        source.setEventHandler {
            batch.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                // Bounded work even if the producer remains active while draining.
                for _ in 0..<8 {
                    // Reads stop at a break in the audio, so the analysis learns of it between the right frames.
                    let count = channel_ring_read_marked(ring, base, UInt32(buffer.count), &mark, &marked)
                    if marked != 0 {
                        pipeline.interrupt(lostFrames: mark.lost_frames, idleMilliseconds: mark.idle_ms)
                        Diagnostics.log(String(format: "Audio break: reasons 0x%x, %llu frames lost, idle %u ms",
                                               mark.reasons, mark.lost_frames, mark.idle_ms))
                        continue
                    }
                    if count == 0 { break }
                    if !receivedPCM {
                        Diagnostics.log("Received PCM: \(count) multichannel frames on DSP queue")
                        receivedPCM = true
                    }
                    pipeline.consume(UnsafeBufferPointer(start: base, count: Int(count)))
                }
            }
            pipeline.spatialSpectrum = meter_exchange_mode(exchange) != 0
            let resets = meter_exchange_true_peak_resets(exchange)
            if resets != truePeakResets {
                truePeakResets = resets
                pipeline.resetTruePeaks()
            }
            values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: CACurrentMediaTime() - clock.paused) }
            if !receivedSignal && pipeline.newestPeak > 0.000001 {
                Diagnostics.log("Nonzero audio signal confirmed")
                receivedSignal = true
            }
            multiFFTMailbox.store(pipeline.multiFFT?.latest)
            meter_exchange_publish(exchange, values)
        }
        timer = source
        source.resume()
    }

    /// Asks the DSP queue to clear its held true peaks before its next snapshot.
    func resetTruePeaks() { meter_exchange_reset_true_peaks(exchange) }

    /// Spatial monitoring: spectrum and waterfall sum every routed channel.
    func setSpatialSpectrum(_ spatial: Bool) { meter_exchange_set_mode(exchange, spatial ? 1 : 0) }

    /// The spatial field's coherence threshold and the speaker geometry (`SpatialFieldAnalyzer`), applied on the DSP
    /// queue between transforms: the snapshots carry the geometry's hash from the next spatial transform on.
    func setSpatialField(threshold: Float, geometry: SpatialGeometry) {
        guard threshold != spatialThreshold || geometry != spatialGeometry else { return }
        spatialThreshold = threshold
        spatialGeometry = geometry
        queue.async { [pipeline] in
            pipeline.spatialCoherence = threshold
            pipeline.spatialGeometry = geometry
        }
    }
    private var spatialThreshold: Float = -1
    private var spatialGeometry: SpatialGeometry?

    /// The waterfall's analysis for the columns from now on.
    func setSpectrogramMode(_ mode: SpectrogramMode) {
        guard mode != spectrogramMode else { return }
        spectrogramMode = mode
        queue.async { [pipeline] in pipeline.spectrum.spectrogramMode = mode }
    }

    func setMultiFFT(_ configuration: MultiFFTConfiguration?) {
        guard configuration != multiFFTConfiguration else { return }
        multiFFTConfiguration = configuration
        let mailbox = multiFFTMailbox
        queue.async { [pipeline] in
            pipeline.multiFFT = configuration.flatMap { MultiFFTAnalyzer(sampleRate: pipeline.spectrum.sampleRate, configuration: $0) }
            mailbox.store(nil)
        }
    }

    func latestMultiFFT(frozen: Bool) -> MultiFFTSnapshot? { multiFFTMailbox.read(allowStale: frozen) }

    func setLegacySTFT(_ choice: LegacySTFT) {
        guard choice != legacyChoice else { return }
        legacyChoice = choice
        queue.async { [pipeline] in pipeline.configureLegacySTFT(choice) }
    }

    func latest() -> MeterSnapshot? {
        guard meter_exchange_read(exchange, &readValues) != 0 else { return nil }
        return Self.decode(readValues)
    }

    static func decode(_ v: [Float]) -> MeterSnapshot {
        var s = MeterSnapshot()
        s.spectrum = Array(v[SnapshotSlots.spectrum..<(SnapshotSlots.spectrum + MeterSnapshot.bandCount)])
        s.spectrumFine = Array(v[SnapshotSlots.spectrumFine..<(SnapshotSlots.spectrumFine + MeterSnapshot.fineBandCount)])
        s.spectrogramMode = v[SnapshotSlots.spectrogramMode]
        s.channelPeaks = Array(v[SnapshotSlots.peaks..<(SnapshotSlots.peaks + Role.count)])
        s.channelRMS = Array(v[SnapshotSlots.rms..<(SnapshotSlots.rms + Role.count)])
        s.channelTruePeaks = Array(v[SnapshotSlots.truePeaks..<(SnapshotSlots.truePeaks + Role.count)])
        s.heldPeaks = Array(v[SnapshotSlots.heldPeaks..<(SnapshotSlots.heldPeaks + Role.count)])
        s.heldTruePeaks = Array(v[SnapshotSlots.heldTruePeaks..<(SnapshotSlots.heldTruePeaks + Role.count)])
        s.leftPeak = s.channelPeaks[0]
        s.rightPeak = s.channelPeaks[1]
        s.leftRMS = s.channelRMS[0]
        s.rightRMS = s.channelRMS[1]
        s.momentaryLUFS = v[SnapshotSlots.momentary]
        s.shortLUFS = v[SnapshotSlots.shortTerm]
        s.integratedLUFS = v[SnapshotSlots.integrated]
        s.loudnessRange = v[SnapshotSlots.range]
        s.sequence = v[SnapshotSlots.sequence]
        s.spectrogramSerial = v[SnapshotSlots.spectrogramSerial]
        s.streamID = v[SnapshotSlots.stream]
        s.peakFrequency = v[SnapshotSlots.peakFrequency]
        s.peakLevel = v[SnapshotSlots.peakLevel]
        s.notes = Array(v[SnapshotSlots.notes..<(SnapshotSlots.notes + 2 * SpectrumAnalyzer.maxNotes)])
        s.detectedFormat = v[SnapshotSlots.format]
        s.correlation = v[SnapshotSlots.correlation]
        s.bandCorrelation = Array(v[SnapshotSlots.bandCorrelation..<(SnapshotSlots.bandCorrelation + StereoBands.groups.count)])
        s.bandWidth = Array(v[SnapshotSlots.bandWidth..<(SnapshotSlots.bandWidth + StereoBands.groups.count)])
        s.bandBalance = Array(v[SnapshotSlots.bandBalance..<(SnapshotSlots.bandBalance + StereoBands.groups.count)])
        s.bandLevel = Array(v[SnapshotSlots.bandLevel..<(SnapshotSlots.bandLevel + StereoBands.groups.count)])
        s.roleBandPower = Array(v[SnapshotSlots.roleBandPower..<(SnapshotSlots.roleBandPower + StereoBands.roleFloats)])
        s.bandPoints = Array(v[SnapshotSlots.bandPoints..<(SnapshotSlots.bandPoints + StereoBands.scopeFloats)])
        s.waveSerial = v[SnapshotSlots.waveSerial]
        s.spectrogram = Array(v[SnapshotSlots.spectrogram..<(SnapshotSlots.spectrogram + MeterSnapshot.spectrogramBandCount)])
        s.waveform = Array(v[SnapshotSlots.waveform..<SnapshotSlots.breaks])
        s.breaks = v[SnapshotSlots.breaks]
        s.missingSeconds = v[SnapshotSlots.missing]
        s.dcOffset = Array(v[SnapshotSlots.dcOffset..<SnapshotSlots.infrasonic])
        s.infrasonic = Array(v[SnapshotSlots.infrasonic..<SnapshotSlots.healthStatus])
        s.healthStatus = v[SnapshotSlots.healthStatus]
        s.spatialField = Array(v[SnapshotSlots.spatialField..<(SnapshotSlots.spatialField + SpatialField.floats)])
        s.spatialPoints = Array(v[SnapshotSlots.spatialPoints..<(SnapshotSlots.spatialPoints + SpatialPoints.floats)])
        // The observations as far as they go: the header, the band counts and the observations it holds.
        let o = SnapshotSlots.spatialObservations
        let held = max(0, min(SpatialObservations.capacity, Int(v[o + SpatialObservations.Header.count])))
        s.spatialObservations = Array(v[o..<(o + SpatialObservations.first + held * SpatialObservations.fields)])
        return s
    }

    /// Holds the analysis where it is while capture pauses: no ticks, so the last snapshot stays the latest.
    func pause() {
        guard pausedAt == nil, let timer else { return }
        timer.suspend()
        pausedAt = CACurrentMediaTime()
        // Let a tick in progress finish before capture clears the ring.
        queue.sync {}
    }

    /// Carries on from the paused state once capture delivers again.
    func resume() {
        guard let pausedAt, let timer else { return }
        let gap = CACurrentMediaTime() - pausedAt
        let clock = clock
        // On the analysis queue, which owns the clock and the pipeline (and is idle while the timer is suspended).
        // Capture restarts after a pause, so its first frames do not continue the last ones analysed: they are
        // spliced on (`MeterPipeline.splice`), never joined, while every cumulative measurement carries on.
        let pipeline = pipeline
        queue.sync {
            clock.paused += gap
            pipeline.splice()
        }
        self.pausedAt = nil
        timer.resume()
    }

    func stop() {
        // A suspended source can be neither cancelled nor released.
        if pausedAt != nil { resume() }
        timer?.cancel()
        timer = nil
        // Wait for the last consumer operation before capture can clear/free its ring.
        queue.sync {}
    }

    deinit {
        stop()
        meter_exchange_destroy(exchange)
    }
}

final class HardwareObserver {
    private let devicesBlock: AudioObjectPropertyListenerBlock
    private let configurationBlock: AudioObjectPropertyListenerBlock
    private let speakersBlock: AudioObjectPropertyListenerBlock
    private var watchedDevice: AudioDeviceID?
    private static let configurationSelectors: [AudioObjectPropertySelector] = [
        kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive
    ]
    /// The speaker configuration (Audio MIDI Setup ▸ Configure Speakers), on either side of the device.
    private static let speakerAddresses = [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput].map { scope in
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyPreferredChannelLayout, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    init(devicesChanged: @escaping () -> Void, configurationChanged: @escaping () -> Void,
         speakersChanged: @escaping () -> Void = {}) {
        devicesBlock = { _, _ in devicesChanged() }
        configurationBlock = { _, _ in configurationChanged() }
        speakersBlock = { _, _ in speakersChanged() }
        var address = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, devicesBlock)
    }

    func watch(_ device: AudioDeviceID?) {
        if let previous = watchedDevice {
            for selector in Self.configurationSelectors {
                var address = Self.address(selector)
                AudioObjectRemovePropertyListenerBlock(previous, &address, .main, configurationBlock)
            }
            for var address in Self.speakerAddresses {
                AudioObjectRemovePropertyListenerBlock(previous, &address, .main, speakersBlock)
            }
        }
        watchedDevice = device
        if let device {
            for selector in Self.configurationSelectors {
                var address = Self.address(selector)
                AudioObjectAddPropertyListenerBlock(device, &address, .main, configurationBlock)
            }
            for var address in Self.speakerAddresses {
                AudioObjectAddPropertyListenerBlock(device, &address, .main, speakersBlock)
            }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    deinit {
        watch(nil)
        var address = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, devicesBlock)
    }
}

enum MeterStatus: Equatable {
    case chooseInput, standby, waitingForPermission, permissionDenied, paused, ringFailed, noDevice, noSelection, dspFailed, demo
    case capturing(device: String, output: Bool, channels: Int, layout: String)
    /// A DAW plugin source: its name and what it is doing.
    case bridge(name: String, condition: BridgeCondition, channels: Int, layout: String)
    /// A device capture that keeps failing, being restarted (`CaptureRecoveryPolicy`).
    case recovering(StatusMessage)
    case failure(StatusMessage)

    /// Rendered on demand so a language switch also updates the current message.
    var text: String {
        switch self {
        case .chooseInput: return L("Choose an input device")
        case .standby: return L("Standby")
        case .waitingForPermission: return L("Waiting for microphone access…")
        case .permissionDenied: return L("Microphone access is off. Allow it in System Settings → Privacy & Security → Microphone.")
        case .paused: return L("Paused")
        case .ringFailed: return L("Could not allocate the audio ring buffer")
        case .noDevice: return L("No audio device available")
        case .noSelection: return L("No audio device selected")
        case .dspFailed: return L("Could not create the vDSP analyzer")
        case .demo: return L("Demo signal · no audio device open")
        case let .capturing(device, output, channels, layout):
            return "\(output ? L("%@ (output)", device) : device) · \(channels) ch → \(layout)"
        case let .bridge(name, condition, channels, layout):
            switch condition {
            case .streaming: return L("%@ · DAW plugin · %d ch → %@", name, channels, layout)
            case .noAudio: return L("%@ · DAW plugin · no audio: the DAW is not processing it", name)
            case .measurementPaused: return L("%@ · DAW plugin · measurement paused in the plugin", name)
            case .stale: return L("%@ · DAW plugin · results delayed", name)
            case .bypassed: return L("%@ · DAW plugin · bypassed in the DAW", name)
            case .offline: return L("%@ · DAW plugin · offline render, not metered", name)
            case .inactive: return L("%@ · DAW plugin · inactive in the DAW", name)
            case .unsupported: return L("%@ · DAW plugin · only mono and stereo are supported", name)
            case .notResponding: return L("%@ · DAW plugin · not responding", name)
            case .disconnected: return L("%@ · DAW plugin disconnected · waiting for it to return", name)
            case .disconnectedHeld:
                return L("%@ · DAW plugin disconnected · measurement held in case this plugin instance reconnects", name)
            case .connecting: return L("Waiting for the DAW plugin to connect…")
            case .unchosen: return L("Host plugins · choose an insert in Settings → Audio, or click the button in its plugin window")
            case let .ambiguous(count):
                return L("%@ · %d connected inserts could be the saved one · choose one in Settings or click its plugin button", name, count)
            }
        case let .recovering(message), let .failure(message): return message.text
        }
    }

    /// The status for the diagnostic log, in English whatever the interface language (a failure keeps its text).
    var logDescription: String {
        switch self {
        case let .capturing(device, output, channels, layout):
            return "Capturing \(output ? "output" : "input") \"\(device)\" · \(channels) ch → \(layout)"
        case let .bridge(name, condition, channels, layout):
            return "DAW plugin \"\(name)\": \(condition) · \(channels) ch → \(layout)"
        case let .recovering(message): return "Recovering: \(message.text)"
        case let .failure(message): return "Error: \(message.text)"
        default: return "Status: \(self)"
        }
    }
}

/// What a selected DAW plugin source is doing, as the status line reports it.
enum BridgeCondition: Equatable {
    case streaming, noAudio, bypassed, offline, inactive, unsupported, notResponding, disconnected
    /// Live, but the plugin's measurement is paused (by Labs' Pause or the plugin window's): nothing accumulates.
    case measurementPaused
    /// Live audio reaches the plugin, but its results have stopped arriving here (its analysis is behind, or the
    /// connection is congested): what is shown is older than it looks.
    case stale
    /// Disconnected while its analysis waits: the same live insert coming back continues it (with a break).
    case disconnectedHeld
    /// Launched by a plugin, before it has connected; or Host plugins chosen with none connected.
    case connecting
    /// Host plugins chosen, inserts connected, none chosen yet.
    case unchosen
    /// Several connected inserts claim the saved one and nothing tells them apart: nothing is analysed until the
    /// person chooses.
    case ambiguous(Int)

    /// Live audio older than this reads as "no audio" (the DAW stopped calling the plugin).
    static let staleAudio = 0.5
    /// A connection silent for this long (no status either) reads as "not responding".
    static let staleMessages = 2.0
    /// The plugin has measured this much more than the newest result shown here: "results delayed".
    static let staleResults = 1.0

    init(_ source: BridgeSource) {
        if source.secondsSinceMessage > Self.staleMessages { self = .notResponding; return }
        switch source.state {
        case .bypassed: self = .bypassed
        case .offline: self = .offline
        case .inactive: self = .inactive
        case .live:
            if !source.hasUsableFormat { self = .unsupported }
            else if source.measurementPaused { self = .measurementPaused }
            else if let age = source.secondsSinceAudio, age < Self.staleAudio { self = .streaming }
            else { self = .noAudio }
        }
    }
}

/// A failure reported in the status line, rendered on demand in the current language.
struct StatusMessage: Equatable {
    private let id = UUID()
    private let render: () -> String
    init(_ render: @escaping () -> String) { self.render = render }
    var text: String { render() }
    static func == (lhs: StatusMessage, rhs: StatusMessage) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class MeterModel: ObservableObject {
    /// Always on top: the meter window and its panel windows float above other apps' windows. Off until turned on
    /// (the toolbar's pin, Settings ▸ General), then kept. A key of its own: builds before 103 floated at every launch.
    nonisolated static let floatingKey = "window.alwaysOnTop"
    /// Stored settings the model owns. The names are permanent: users' settings, presets and the LABS migration use them.
    nonisolated static let inputDeviceUIDKey = "inputDeviceUID"
    nonisolated static let inputDeviceIsOutputKey = "inputDeviceIsOutput"
    nonisolated static let formatModeKey = "formatMode"
    nonisolated static let speakerLayoutKey = "speakerLayout"
    nonisolated static let showMonoModeKey = "showMonoMode"
    nonisolated static let loudnessStandardKey = "loudnessStandard"
    nonisolated static let spatialLoudnessStandardKey = "loudnessStandard.spatial"
    nonisolated static let spectrumStripKey = "layout.spectrumStrip"
    @Published var floating = UserDefaults.standard.bool(forKey: MeterModel.floatingKey) {
        didSet {
            guard floating != oldValue else { return }
            UserDefaults.standard.set(floating, forKey: Self.floatingKey)
            DiagnosticLog.event("Always on top: \(floating ? "on" : "off")")
        }
    }
    /// Set to open the Settings window (on the pane saved under `SettingsPane.defaultsKey`); the main window consumes it.
    @Published var showSettings = false
    /// Set to open the About window.
    @Published var showAbout = false
    /// Routing of the current layout: device input per role, −1 when a role is off or not in the layout.
    @Published private(set) var sourceForRole = [Int32](repeating: -1, count: Role.count)
    private var activeRoles = [Bool](repeating: false, count: Role.count)
    /// Multichannel format shown in Spatial mode; each layout keeps its own routing per device.
    @Published var speakerLayout: SpeakerLayout {
        didSet {
            guard speakerLayout != oldValue else { return }
            UserDefaults.standard.set(speakerLayout.rawValue, forKey: Self.speakerLayoutKey)
            DiagnosticLog.event("Speaker layout: \(speakerLayout.name)")
            loadAssignment()
            if demoStart != nil {
                activeRoles = (0..<Role.count).map(speakerLayout.contains)
                captureChannels = speakerLayout.channelCount
            } else if wantsCapture && running {
                restart()
            }
        }
    }
    /// The Immersive format of a DAW plugin's own bus (an immersive VST3 insert), which the panels draw instead of the
    /// one chosen in Settings while that insert is the source (kept while it is away); nil for any other source.
    @Published private(set) var pluginLayout: SpeakerLayout?
    /// That bus's name as the plugin gives it: a 7.0.4 bus is named 7.0.4 and drawn in 7.1.4 with LFE off.
    @Published private(set) var pluginLayoutName: String?
    /// The Immersive format the panels draw, and its name.
    var shownLayout: SpeakerLayout { pluginLayout ?? speakerLayout }
    var shownLayoutName: String { pluginLayout == nil ? speakerLayout.name : pluginLayoutName ?? shownLayout.name }
    @Published private(set) var devices: [InputDevice] = []
    @Published private(set) var selectedID = SourceID.none
    private var snapshot = MeterSnapshot()
    @Published private(set) var status = MeterStatus.chooseInput {
        didSet {
            if status != oldValue { DiagnosticLog.event(status.logDescription) }
            if status != .paused && frozen { frozen = false }
        }
    }
    @Published private(set) var running = false
    /// Paused by the person: every panel holds the picture it showed at that moment (the last snapshot, with no
    /// decay or scrolling) until capture resumes. Reset while paused, and any other stop, clear it as before.
    @Published private(set) var frozen = false
    @Published private(set) var sampleRate: Double = 48_000
    @Published private(set) var droppedFrames: UInt64 = 0
    /// An output source has delivered nothing but digital silence for a while: nothing is playing to it, or macOS
    /// is withholding it (without System Audio Recording a tap reads as silence). The status bar says so.
    @Published private(set) var silentOutput = false
    /// Bumped by "reset": clears peak holds, clip latches and (via restart) integrated loudness.
    @Published private(set) var epoch = 0
    /// Auto follows the routing and the DSP-side detector; Mono / Stereo / Spatial pin the display.
    @Published var formatMode: FormatMode {
        didSet {
            UserDefaults.standard.set(formatMode.rawValue, forKey: Self.formatModeKey)
            if formatMode != oldValue { DiagnosticLog.event("Monitoring mode: \(formatMode.rawValue)") }
            configureSpectrumArchitecture()
            // Mono measures a single input, so entering or leaving it restarts the stream (like a routing change).
            let wasMono = (oldValue.fixed ?? automaticFormat) == .mono
            if wasMono != (format == .mono) && wantsCapture && running && demoStart == nil { restart() }
        }
    }
    @Published private(set) var detectedFormat = ChannelFormat.stereo
    var format: ChannelFormat { formatMode.fixed ?? automaticFormat }

    /// Mono is rarely needed, so it is off until turned on in Settings ▸ Channels: while off it is left out of the
    /// mode selector, the menus and Auto, and a pinned Mono falls back to Stereo.
    @Published var monoEnabled: Bool {
        didSet {
            guard monoEnabled != oldValue else { return }
            UserDefaults.standard.set(monoEnabled, forKey: Self.showMonoModeKey)
            DiagnosticLog.event("Show Mono mode: \(monoEnabled ? "on" : "off")")
            if !monoEnabled && formatMode == .mono {
                formatMode = .stereo
            } else if formatMode == .auto && loneInput && wantsCapture && running {
                // Auto on a lone input switches between Mono and Stereo, which measure different inputs.
                restart()
            }
        }
    }
    /// The monitoring modes offered, in selector order.
    var availableModes: [FormatMode] { FormatMode.allCases.filter { monoEnabled || $0 != .mono } }
    var selectorFormats: [ChannelFormat] { ChannelFormat.selectorOrder.filter { monoEnabled || $0 != .mono } }

    /// Loudness standard of Stereo (and Mono) and of Spatial. Every loudness reference (gauge, delta, history
    /// band, VU alignment, true-peak ceiling) follows the one for the current format, so switching format,
    /// by hand or by the detector, switches standard too.
    @Published private(set) var stereoTarget = MeterModel.stored("loudnessTarget", -18)
    @Published private(set) var stereoCeiling = MeterModel.stored("truePeakCeiling", -1)
    @Published private(set) var spatialTarget = MeterModel.stored("loudnessTarget.spatial", -18)
    @Published private(set) var spatialCeiling = MeterModel.stored("truePeakCeiling.spatial", -1)
    var loudnessTarget: Double { format == .spatial ? spatialTarget : stereoTarget }
    var truePeakCeiling: Double { format == .spatial ? spatialCeiling : stereoCeiling }
    /// The standard chosen for each mode (`LoudnessStandard.id`). Settings from before standards had identities take
    /// the first standard with their target and ceiling.
    @Published private(set) var stereoStandardID = UserDefaults.standard.string(forKey: MeterModel.loudnessStandardKey)
    @Published private(set) var spatialStandardID = UserDefaults.standard.string(forKey: MeterModel.spatialLoudnessStandardKey)

    /// The standard in use for a mode, or nil when its target or ceiling was set by hand (Custom).
    func standard(spatial: Bool) -> LoudnessStandard? {
        let target = spatial ? spatialTarget : stereoTarget, ceiling = spatial ? spatialCeiling : stereoCeiling
        if let chosen = LoudnessStandard.with(id: spatial ? spatialStandardID : stereoStandardID) {
            return chosen.target == target && chosen.ceiling == ceiling ? chosen : nil
        }
        return LoudnessStandard.matching(target: target, ceiling: ceiling)
    }
    var loudnessStandard: LoudnessStandard? { standard(spatial: format == .spatial) }

    private static func stored(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.double(forKey: key)
    }

    /// Sets one mode's loudness target alone (the panel's stepper); its ceiling stays.
    func setTarget(_ target: Double, spatial: Bool) {
        if spatial { spatialTarget = target } else { stereoTarget = target }
        saveLoudness()
    }

    /// Picks a published standard for one mode: its target, its true-peak ceiling and how it judges.
    func setStandard(_ standard: LoudnessStandard, spatial: Bool) {
        if spatial {
            spatialTarget = standard.target
            spatialCeiling = standard.ceiling
            spatialStandardID = standard.id
        } else {
            stereoTarget = standard.target
            stereoCeiling = standard.ceiling
            stereoStandardID = standard.id
        }
        UserDefaults.standard.set(standard.id, forKey: spatial ? Self.spatialLoudnessStandardKey : Self.loudnessStandardKey)
        saveLoudness()
    }

    func setCeiling(_ ceiling: Double, spatial: Bool) {
        if spatial { spatialCeiling = ceiling } else { stereoCeiling = ceiling }
        saveLoudness()
    }

    /// Takes up the settings the model keeps a copy of from user defaults again, after a settings preset has rewritten
    /// them (`SettingsPresets`): the format, Mono, the mode, Always on top and both modes' loudness standards.
    func reloadStoredSettings() {
        let defaults = UserDefaults.standard
        speakerLayout = defaults.string(forKey: Self.speakerLayoutKey).flatMap(SpeakerLayout.init(rawValue:)) ?? .standard
        monoEnabled = defaults.bool(forKey: Self.showMonoModeKey)
        if let mode = defaults.string(forKey: Self.formatModeKey).flatMap(FormatMode.init(rawValue:)), availableModes.contains(mode) {
            formatMode = mode
        }
        floating = defaults.bool(forKey: Self.floatingKey)
        stereoTarget = Self.stored("loudnessTarget", -18)
        stereoCeiling = Self.stored("truePeakCeiling", -1)
        spatialTarget = Self.stored("loudnessTarget.spatial", -18)
        spatialCeiling = Self.stored("truePeakCeiling.spatial", -1)
        stereoStandardID = defaults.string(forKey: Self.loudnessStandardKey)
        spatialStandardID = defaults.string(forKey: Self.spatialLoudnessStandardKey)
        spectrumStrip = CGFloat(defaults.double(forKey: Self.spectrumStripKey))
    }

    private func saveLoudness() {
        let defaults = UserDefaults.standard
        defaults.set(stereoTarget, forKey: "loudnessTarget")
        defaults.set(stereoCeiling, forKey: "truePeakCeiling")
        defaults.set(spatialTarget, forKey: "loudnessTarget.spatial")
        defaults.set(spatialCeiling, forKey: "truePeakCeiling.spatial")
    }

    /// Auto: a lone routed input (L on, R and every positional channel off) is Mono when Mono is enabled;
    /// otherwise the detector decides.
    var automaticFormat: ChannelFormat { monoEnabled && loneInput ? .mono : detectedFormat }

    /// L routed with R and every positional channel off (never in the demo).
    private var loneInput: Bool {
        demoStart == nil && sourceForRole[Role.left] >= 0 && sourceForRole[Role.right] < 0
            && !Role.evidence.contains { sourceForRole[$0] >= 0 }
    }

    /// Clicking a mode pins it; the AUTO toggle hands control back to the detector.
    func pin(_ format: ChannelFormat) { formatMode = FormatMode(format) }
    func toggleAuto() { formatMode = formatMode == .auto ? FormatMode(format) : .auto }
    /// Width of the Spectrum card's live spectrum, dragged by its divider; 0 is automatic. Plain (not published):
    /// the card's own `@AppStorage` redraws its labels, and the canvases read it every frame.
    var spectrumStrip = CGFloat(UserDefaults.standard.double(forKey: MeterModel.spectrumStripKey))
    /// Band resolution chosen on the Soundstage and Channel Levels panels (their switchers write it together with
    /// their own `@AppStorage`); plain, read by the canvases every frame.
    var stageBands = MeterModel.storedBands(DisplayOptions.stageBandsKey)
    var levelsBands = MeterModel.storedBands(DisplayOptions.levelsBandsKey)
    /// The stereometer's style, chosen on the Soundstage header; plain, like the band resolutions.
    var stageStyle = StageStyle.stored
    /// The Multi-FFT engine and the shared STFT of the current analysis.
    private lazy var spectrumEngines = SpectrumEngineCoordinator { [weak self] in self?.worker }
    static let multiFFTTeardownDelay = SpectrumEngineCoordinator.teardownDelay

    func multiFFTPanelVisible(_ visible: Bool) {
        spectrumEngines.panelVisible(visible)
        configureSpectrumArchitecture()
    }

    func configureSpectrumArchitecture() {
        spectrumEngines.configure(spectrumInputs)
    }

    func multiFFTFrame() -> MultiFFTSnapshot? {
        spectrumEngines.frame(spectrumInputs, running: running, frozen: frozen)
    }

    private var spectrumInputs: SpectrumEngineCoordinator.Inputs {
        .init(format: format, sourceIsBridge: sourceIsBridge, enhancedSpectrogram: displayOptions.spectrogramAnalysis == .enhanced)
    }

    /// The panels' display choices, made on each panel (`PanelSettingsButton`).
    var displayOptions = DisplayOptions.stored
    /// `SpectrogramMode` of the newest column shown (plain: the panel settings read it when they open).
    private(set) var lastSpectrogramMode: Float = 0
    /// The newest snapshot's spatial field status (`SpatialField.status`; −1 a plugin that sends none).
    private(set) var lastSpatialFieldStatus: Float = 0
    /// Whether the newest snapshot carried the analysis' own bins (`SpatialPoints`): 1 yes, 0 none (a Bridge plugin
    /// before build 87 sends its field without them).
    private(set) var lastSpatialPointsStatus: Float = 0
    /// Whether the source is a DAW plugin, which analyses (and so chooses the spectrogram's analysis) itself.
    var sourceIsBridge: Bool { selectedID.bridge != nil }
    /// The newest snapshot's observations: status, source and the hash of the geometry they were computed with.
    private(set) var lastObservations: (status: Float, source: SpatialObservations.Source, hash: UInt64) = (0, .none, 0)
    static func storedBands(_ key: String) -> StereoBands.Resolution {
        // The Soundstage's key may also name a single band ("five.2"; `BandChoice`).
        BandChoice(rawValue: UserDefaults.standard.string(forKey: key) ?? "")?.resolution ?? .five
    }
    private var bandsObserver: NSObjectProtocol?
    private(set) var captureStarted: Date?
    private(set) var captureChannels = 0
    private var lastDropLog = Date.distantPast
    /// Frames dropped before the last resume: capture restarts clear the ring's own count.
    private var droppedBefore: UInt64 = 0
    let readouts = Readouts()

    private let dependencies: MeterModelDependencies
    private let capture: CaptureBackend?
    private var worker: MeterWorker?

    /// Tests only (`--test-model-worker`): capture stays off, and the given worker stands in for the analysis.
    func setWorkerForTesting(_ worker: MeterWorker?) {
        wantsCapture = false
        stop()
        self.worker = worker
    }
    /// A DAW plugin source: where its results arrive (the plugin analyses; nothing is analysed here).
    private var resultInbox: ResultInbox?
    private var demoStart: CFTimeInterval?
    private var demoDetector = FormatDetector()
    private var streamID: UInt32 = 0
    /// Changes whenever capture (re)starts; diagnostics use it to prove an operation left the audio path alone.
    var captureGeneration: UInt32 { streamID }
    private var hardwareObserver: HardwareObserver?
    /// Restarts of a device capture that keeps failing (`superviseCapture`).
    private var recovery = CaptureRecoveryPolicy()
    /// Changes whenever capture stops for any reason (and so before every start), except recovery's own restarts: a
    /// recovery decision then never reaches a capture other than the one it was made for.
    private var captureSession: UInt64 = 0
    /// The source whose capture recovery gave up on: nothing restarts it by itself (a device-list change, for one)
    /// until the person starts capture or the source changes.
    private var recoveryHalted: SourceID?
    private var permissionPending = false
    private var wantsCapture = true
    /// What a pause left waiting in place: the source and routing the analysis was measuring, and when it paused.
    /// Resume carries on with that analysis while they still hold (see `continuePaused`).
    private struct PausedSession {
        let source: SourceID
        let sources: [Int32]
        let roles: [Bool]
        let time: CFTimeInterval
        /// A DAW plugin source: the insert and format the paused analysis was measuring.
        var bridge: (session: String, epoch: UInt32, channels: Int)? = nil
        /// Whether the pause reached that plugin: its measurement is then this display's to resume, here or when the
        /// paused analysis is let go (`stop`).
        var pluginPaused = false
    }
    private var paused: PausedSession?

    // DAW Bridge: plugin instances are listed with the devices and selected like one.
    /// The receiver, the plugins it reports, commands, and what plugins answered (`BridgeLink`).
    private let link: BridgeLink
    /// The inserts that could be the saved one while that is ambiguous (their sessions); empty otherwise.
    @Published private(set) var bridgeCandidates: [String] = []
    /// Breaks in the current analysis and the seconds known missing at them (from the snapshot), for the status bar.
    @Published private(set) var measurementBreaks = 0
    @Published private(set) var missingSeconds = 0.0
    /// Why the receiver could not start (nil while it runs).
    var bridgeError: String? { link.error }
    /// Newest report of every connected plugin instance (polled, not published: counters change constantly).
    var bridgeSources: [BridgeSource] { link.sources }
    /// The instance and format the ring is attached to, while a DAW source runs.
    private var attachedBridge: (session: String, epoch: UInt32, channels: Int)?
    /// Frames lost before the current attachment, so the status bar counts this stream only.
    private var bridgeLostBase: UInt64 = 0
    private var bridgeTimer: Timer?

    deinit {
        worker?.stop()
        capture?.stop()
    }

    /// The app's model, for diagnostics that act outside the views (`--snapshot-report`).
    static weak var diagnosticInstance: MeterModel?

    init(dependencies: MeterModelDependencies = .live) {
        self.dependencies = dependencies
        capture = dependencies.makeCapture()
        speakerLayout = UserDefaults.standard.string(forKey: Self.speakerLayoutKey).flatMap(SpeakerLayout.init(rawValue:)) ?? .standard
        let savedMode = UserDefaults.standard.string(forKey: Self.formatModeKey)
        let showMono = UserDefaults.standard.bool(forKey: Self.showMonoModeKey)
        monoEnabled = showMono
        // 2.0 stored the pinned multichannel mode as "surround". A pinned Mono needs Mono enabled.
        let mode = savedMode == "surround" ? .spatial : FormatMode(rawValue: savedMode ?? "") ?? .auto
        formatMode = mode == .mono && !showMono ? .stereo : mode
        link = BridgeLink(dependencies.startReceiver())
        devices = dependencies.availableSources()
        let savedUID = UserDefaults.standard.string(forKey: Self.inputDeviceUIDKey)
        let savedOutput = UserDefaults.standard.bool(forKey: Self.inputDeviceIsOutputKey)
        let requested = devices.first { !$0.output && $0.device == Diagnostics.requestedDeviceID }
        // Launch meters the current macOS default output, what the Mac is playing. Before macOS 14.2 (no output
        // capture) it takes the default input instead; the saved device is the fallback when there is no default.
        let outputID = AudioDevices.defaultDeviceID(output: true)
        let inputID = AudioDevices.defaultDeviceID(output: false)
        let systemDefault = devices.first { $0.output && $0.device == outputID }
            ?? devices.first { !$0.output && $0.device == inputID }
        let saved = devices.first { !$0.uid.isEmpty && $0.uid == savedUID && $0.output == savedOutput }
        if let requested {
            selectedID = requested.id
        } else if launchedByBridge {
            // A plugin's button launched the app: it connects and asks to be shown within a moment.
            selectedID = SourceID(device: 0, bridge: SourceID.waitingPrefix)
        } else if savedUID == bridgeUIDPrefix {
            // Host plugins chosen as the source type, no insert chosen: wait for the person to choose one.
            selectedID = .anyPlugin
        } else if let savedUID, savedUID.hasPrefix(bridgeUIDPrefix) {
            // A DAW plugin chosen last time: wait for that insert to connect rather than fall back to a device.
            let persistent = String(savedUID.dropFirst(bridgeUIDPrefix.count))
            selectedID = SourceID(device: 0, bridge: SourceID.waitingPrefix + persistent)
            link.restoreSaved(persistent: persistent)
        } else if savedUID == "" {
            // An explicit empty UID means the person chose "no device"; that choice is kept.
            selectedID = savedOutput ? .noOutput : .none
        } else {
            selectedID = (systemDefault ?? saved ?? devices.first)?.id ?? .none
        }
        loadAssignment()
        // A source is chosen but nothing started yet (the welcome may be showing): not a missing input.
        if selectedDevice != nil { status = .standby }
        readouts.attach(to: self)
        Self.diagnosticInstance = self
        // The band switches write user defaults; follow them so every writer (the switches, a defaults change)
        // reaches the canvases.
        bandsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let stage = Self.storedBands(DisplayOptions.stageBandsKey), levels = Self.storedBands(DisplayOptions.levelsBandsKey)
                if stage != self.stageBands { self.stageBands = stage }
                if levels != self.levelsBands { self.levelsBands = levels }
                let style = StageStyle.stored
                if style != self.stageStyle { self.stageStyle = style }
                let options = DisplayOptions.stored
                if options != self.displayOptions { self.displayOptions = options }
                self.spectrumEngines.reloadSettings()
                self.configureSpectrumArchitecture()
            }
        }
        if dependencies.observesHardware {
            hardwareObserver = HardwareObserver(devicesChanged: { [weak self] in
                Task { @MainActor in self?.refreshDevices() }
            }, configurationChanged: { [weak self] in
                Task { @MainActor in self?.deviceConfigurationChanged() }
            }, speakersChanged: { [weak self] in
                Task { @MainActor in self?.deviceSpeakersChanged() }
            })
        }
        if link.receiver != nil {
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollBridge() }
            }
            RunLoop.main.add(timer, forMode: .common)
            bridgeTimer = timer
        }
        // From the model rather than a view: it must run even when no window is built (a release binary launched
        // from a shell).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if let self { BridgeSelfTest.runIfRequested(model: self) } }
            MainActor.assumeIsolated { if let self { ModelWorkerSelfTest.runIfRequested(model: self) } }
            MainActor.assumeIsolated { if let self { ModelLifecycleSelfTest.runIfRequested(model: self) } }
        }
    }

    /// Latest analysis; canvases and readouts share it, so polling from either is idempotent.
    func pollSnapshot() -> MeterSnapshot {
        if let demoStart, running {
            let elapsed = CACurrentMediaTime() - demoStart
            let sequence = Int(elapsed * DemoSignal.updateRate)
            if Float(sequence % 1_000_000 + 1) != snapshot.sequence {
                snapshot = DemoSignal.snapshot(at: Double(sequence) / DemoSignal.updateRate, sequence: sequence, layout: shownLayout)
                let format = demoDetector.update(rms: snapshot.channelRMS, deltaTime: Float(1 / DemoSignal.updateRate))
                snapshot.detectedFormat = Float(format.rawValue)
            }
        } else if let next = worker?.latest() {
            snapshot = next
        }
        return snapshot
    }

    func canvasFrame() -> CanvasFrame {
        configureSpectrumArchitecture()
        worker?.setSpatialSpectrum(format == .spatial)
        // A DAW plugin sums every channel of its bus in the spectrum (and keeps each one's band energy for the
        // immersive soundstage) while Immersive is shown, as the local analysis does.
        link.receiver?.setSpectrum(everyChannel: format == .spatial)
        // Which speakers share an image (the nebula's coherence setting), for the local analysis and the plugin's; and
        // the speaker geometry both analyses and the dome use.
        noteSpatialAnswer()
        let geometry = displayGeometry(for: shownLayout)
        worker?.setSpatialField(threshold: displayOptions.nebula.threshold, geometry: geometry)
        link.receiver?.setCoherence(displayOptions.nebula.threshold)
        link.receiver?.setSpatial(geometry)
        let mode: SpectrogramMode = displayOptions.spectrogramAnalysis == .enhanced ? .enhanced : .classic
        worker?.setSpectrogramMode(mode)
        link.receiver?.setSpectrogram(mode)
        let snapshot = pollSnapshot()
        lastSpectrogramMode = snapshot.spectrogramMode
        if let status = snapshot.spatialField.first { lastSpatialFieldStatus = status }
        if let status = snapshot.spatialPoints.first { lastSpatialPointsStatus = status }
        lastObservations = snapshot.spatialObservations.count >= SpatialObservations.first
            ? (snapshot.spatialObservations[SpatialObservations.Header.status],
               SpatialObservations.Source(rawValue: snapshot.spatialObservations[SpatialObservations.Header.source]) ?? .none,
               snapshot.spatialObservations.withUnsafeBufferPointer { SpatialObservations.hash($0.baseAddress!) })
            : (0, .none, 0)
        // The dome's camera lives with `DomeCamera`, which saves it to the defaults only when an interaction ends.
        var options = displayOptions
        DomeCamera.shared.apply(to: &options)
        return CanvasFrame(snapshot: snapshot, sampleRate: sampleRate, running: running, frozen: frozen,
                    activeRoles: routedRoles, epoch: epoch, spatial: format == .spatial, mono: format == .mono,
                    layout: shownLayout,
                    spectrumStrip: PanelPlacement.shared.splitsSpectrum ? SpectrogramLayout.split : spectrumStrip,
                    truePeakEpoch: truePeakEpoch,
                    stageBands: stageBands, levelsBands: levelsBands, stageStyle: stageStyle,
                    options: options, geometry: geometry)
    }

    /// The speaker geometry the dome draws and the analysis uses for `layout`: the user's layout for that format, or
    /// the standard one where the source computes with it (a DAW plugin before build 98, or one that refused the
    /// layout), so the speakers are always drawn with the geometry the observations were computed with.
    func displayGeometry(for layout: SpeakerLayout) -> SpatialGeometry {
        let configured = SpeakerLayoutStore.shared.geometry(for: layout, nebula: displayOptions.nebula)
        guard let source = selectedBridgeSource,
              !source.takesSpatialGeometry || link.refused(configured, by: source)
        else { return configured }
        var standard = SpatialGeometry.standard(roles: layout.roles, detail: configured.detail, window: configured.window)
        // Another revision, so its acknowledgement is not taken for the refused one's.
        standard.revision = configured.revision ^ 0x8000_0000
        return standard
    }

    /// Why the dome shows the standard layout instead of the user's (a note in the panel's settings), or nil.
    enum GeometryNotice { case pluginTooOld, pluginRefused, applying }
    var geometryNotice: GeometryNotice? {
        let configured = SpeakerLayoutStore.shared.geometry(for: shownLayout, nebula: displayOptions.nebula)
        if let source = selectedBridgeSource {
            if !configured.isStandard(roles: shownLayout.roles) && !source.takesSpatialGeometry { return .pluginTooOld }
            if link.refused(configured, by: source) { return .pluginRefused }
        }
        // Observations of another geometry than the one drawn: on their way (a change just made), never drawn.
        if lastObservations.status == 1, lastObservations.source == .measured, lastObservations.hash != displayGeometry(for: shownLayout).hash {
            return .applying
        }
        return nil
    }

    /// A plugin's answer to the geometry it was sent: a refusal of the user's layout makes the dome (and the plugin)
    /// use the standard one, with a note, until the layout changes.
    private func noteSpatialAnswer() {
        guard let source = selectedBridgeSource, source.spatialAck != nil else { return }
        link.noteSpatialAnswer(of: source, to: SpeakerLayoutStore.shared.geometry(for: shownLayout, nebula: displayOptions.nebula))
    }

    /// Roles that carry signal: routed and part of the current layout. Mono keeps only the input routed to L.
    var routedRoles: [Bool] {
        format == .mono ? (0..<Role.count).map { $0 == Role.left && activeRoles[$0] } : activeRoles
    }

    /// The routing handed to capture: in Mono every role but L is off, so R never reaches the analyzers.
    private var capturedSources: [Int32] {
        format == .mono ? sourceForRole.enumerated().map { $0.offset == Role.left ? $0.element : -1 } : sourceForRole
    }

    /// Called at the readout rate; publishes only on a transition so SwiftUI rarely re-renders.
    func refreshFormat(from snapshot: MeterSnapshot) {
        let detected = ChannelFormat(rawValue: Int(snapshot.detectedFormat)) ?? .stereo
        guard detected != detectedFormat else { return }
        detectedFormat = detected
        DiagnosticLog.event("Detected format: \(detected == .spatial ? "Immersive" : "Stereo")")
        Diagnostics.log("Detected format: \(detected == .spatial ? "spatial" : "stereo")")
    }

    /// Carries the current decision into a new stream so a restart does not replay the transition.
    private func makeDetector() -> FormatDetector {
        FormatDetector(initial: detectedFormat,
                       canDetectSpatial: FormatDetector.evidenceRoles.contains { sourceForRole[$0] >= 0 })
    }

    /// Called at the readout rate with whether any sample above silence has arrived since the last reset.
    func refreshSilence(heardSignal: Bool) {
        var capturingOutput = false
        if case let .capturing(_, output, _, _) = status { capturingOutput = output }
        // With nothing routed nothing is measured, so silence would prove nothing.
        let silent = capturingOutput && running && !heardSignal && routedRoles.contains(true)
            && (captureStarted.map { Date().timeIntervalSince($0) > 5 } ?? false)
        guard silent != silentOutput else { return }
        silentOutput = silent
        if silent { DiagnosticLog.event("Output has delivered only digital silence for 5 s") }
    }

    /// Called at the readout rate rather than per frame.
    func refreshDroppedFrames() {
        var dropped = droppedBefore + (capture.map { channel_ring_dropped($0.ring) } ?? 0)
        if let session = attachedBridge?.session, let source = bridgeSources.first(where: { $0.sessionKey == session }) {
            // Audio the DAW plugin's own analysis could not keep up with (it still passed through the insert).
            dropped += source.framesDroppedByPlugin &- bridgeLostBase
        }
        if dropped != droppedFrames {
            droppedFrames = dropped
            // At most one line every 10 s, however often the count grows.
            let now = Date()
            if dropped > 0 && now.timeIntervalSince(lastDropLog) >= 10 {
                lastDropLog = now
                DiagnosticLog.event("Dropped audio frames: \(dropped) since capture started")
            }
        }
    }

    /// Called at the readout rate: breaks in the analysed audio, for the status bar.
    func refreshContinuity(from snapshot: MeterSnapshot) {
        let breaks = Int(snapshot.breaks), missing = Double(snapshot.missingSeconds)
        if breaks != measurementBreaks { measurementBreaks = breaks }
        if abs(missing - missingSeconds) >= 0.05 || (missing == 0) != (missingSeconds == 0) { missingSeconds = missing }
    }

    func resetMeasurements() {
        // A DAW plugin owns its measurement: it starts afresh there (a new generation), for every display.
        if let attached = attachedBridge, link.send(ABR_COMMAND_RESET, name: "reset", to: attached.session) {
            clearMeasurements()
            if running { captureStarted = Date() }
            return
        }
        if running && demoStart == nil { restart(); return }
        // Paused, a reset lets go of the held picture and of the paused analysis, so resume starts afresh.
        if paused != nil {
            stop()
            snapshot = MeterSnapshot()
            status = .standby
        }
        clearMeasurements()
        if running { captureStarted = Date() }
    }

    /// Clicking a red or amber TRUE PEAK: clears the held true peaks alone (the summary reading, each channel's
    /// over readout and over fill), keeping integrated loudness, held sample peaks and the stream running.
    func resetTruePeak() {
        worker?.resetTruePeaks()
        if let attached = attachedBridge {
            link.send(ABR_COMMAND_RESET_TRUE_PEAK, name: "reset true peak", to: attached.session)
        }
        readouts.resetTruePeak()
        truePeakEpoch += 1
        DiagnosticLog.event("True peak reset")
    }

    /// Bumped by a TRUE PEAK reset; the Channel Levels canvas clears its over fills on a change.
    @Published private(set) var truePeakEpoch = 0

    private func clearMeasurements() {
        epoch += 1
        readouts.reset()
    }

    var formatSummary: String {
        streamParts.map { $0.unit.isEmpty ? $0.value : "\($0.value) \($0.unit)" }.joined(separator: " · ")
    }

    /// The stream as value–unit pairs for the heading: sample rate, captured channels and the monitored layout.
    var streamParts: [(value: String, unit: String)] {
        let rate = sampleRate.truncatingRemainder(dividingBy: 1000) == 0
            ? "\(Int(sampleRate / 1000))" : String(format: "%.1f", sampleRate / 1000)
        guard running || frozen else { return [(rate, "kHz")] }
        return [(rate, "kHz"), ("\(captureChannels)", "ch"),
                (format == .spatial ? shownLayoutName : (format == .mono ? "1.0" : "2.0"), "")]
    }

    func reportRendererError(_ message: StatusMessage) {
        stop()
        status = .failure(message)
    }

    func refreshDevices() {
        refreshDevices(using: dependencies.availableSources() + bridgeDevices)
    }

    /// The captured device's sample rate changed, or it came or went (`HardwareObserver`): the device list is read
    /// again, and the same source, still there, starts afresh with the device's new configuration.
    func deviceConfigurationChanged() {
        guard wantsCapture else { return }
        if Diagnostics.ignoreConfigurationChanges {
            DiagnosticLog.event("Device configuration change ignored (--ignore-configuration-changes)")
            return
        }
        let previousID = selectedID
        let wasRunning = running
        refreshDevices()
        if wasRunning && selectedID == previousID && selectedDevice != nil { restart() }
    }

    /// Connected DAW plugin instances as sources, in connection order. One of another protocol version is left
    /// out (Settings names it as needing an update).
    private var bridgeDevices: [InputDevice] { link.devices }

    /// Plugins of another protocol version, by host: named in Settings as needing an update.
    var incompatibleBridgePlugins: [BridgeSource] { link.incompatible }

    /// Accepts an injected list so a disappearing input or output can be checked without unplugging hardware.
    func refreshDevices(using available: [InputDevice]) {
        if available.map(\.id) != devices.map(\.id) {
            DiagnosticLog.event("Devices: \(available.filter { !$0.output }.count) inputs, \(available.filter(\.output).count) outputs")
        }
        devices = available
        let savedUID = UserDefaults.standard.string(forKey: Self.inputDeviceUIDKey)
        let savedOutput = UserDefaults.standard.bool(forKey: Self.inputDeviceIsOutputKey)
        let restored = savedUID.flatMap { uid in
            uid.isEmpty ? nil : devices.first { !$0.uid.isEmpty && $0.uid == uid && $0.output == savedOutput }
        }
        // A DAW plugin that went away stays selected: `pollBridge` waits for it to return.
        if !selectedID.isNone && selectedID.bridge == nil && !devices.contains(where: { $0.id == selectedID }) {
            selectedID = selectedID.output ? .noOutput : .none
            loadAssignment()
            if wantsCapture { requestPermissionAndStart() }
        } else if selectedID.isNone, let restored {
            selectedID = restored.id
            loadAssignment()
            if wantsCapture { requestPermissionAndStart() }
        } else if !running && wantsCapture && !recovery.isActive && recoveryHalted != selectedID {
            requestPermissionAndStart()
        }
    }

    func select(_ id: SourceID) {
        if id.isNone {
            UserDefaults.standard.set("", forKey: Self.inputDeviceUIDKey)
            UserDefaults.standard.set(id.output, forKey: Self.inputDeviceIsOutputKey)
        }
        if selectedID == id {
            if id.isNone { status = .noSelection }
            return
        }
        guard id.isNone || id == .anyPlugin || devices.contains(where: { $0.id == id }) else { return }
        selectedID = id
        if id == .anyPlugin {
            UserDefaults.standard.set(bridgeUIDPrefix, forKey: Self.inputDeviceUIDKey)
            UserDefaults.standard.set(false, forKey: Self.inputDeviceIsOutputKey)
        }
        if let device = devices.first(where: { $0.id == id }), !device.uid.isEmpty {
            UserDefaults.standard.set(device.uid, forKey: Self.inputDeviceUIDKey)
            UserDefaults.standard.set(device.output, forKey: Self.inputDeviceIsOutputKey)
            if device.isBridge {
                UserDefaults.standard.set(device.name, forKey: BridgeLink.nameKey)
            } else {
                UserDefaults.standard.set(device.uid, forKey: Self.lastDeviceKey)
                UserDefaults.standard.set(device.output, forKey: Self.lastDeviceOutputKey)
            }
        }
        // The person's choice: remembered with its context, and final (no longer provisional or ambiguous).
        recoveryHalted = nil
        bridgeCandidates = []
        link.choose(id)
        loadAssignment()
        if wantsCapture { requestPermissionAndStart() }
    }

    private static let lastDeviceKey = "lastAudioDeviceUID"
    private static let lastDeviceOutputKey = "lastAudioDeviceIsOutput"

    /// Settings' source type switched to Audio devices: the device last chosen there, else what launch would take
    /// (the macOS default output, else the default input), else the first one.
    func preferredDeviceSource() -> SourceID {
        let hardware = devices.filter { !$0.isBridge }
        let lastUID = UserDefaults.standard.string(forKey: Self.lastDeviceKey)
        let lastOutput = UserDefaults.standard.bool(forKey: Self.lastDeviceOutputKey)
        if let last = hardware.first(where: { !$0.uid.isEmpty && $0.uid == lastUID && $0.output == lastOutput }) { return last.id }
        let outputID = AudioDevices.defaultDeviceID(output: true), inputID = AudioDevices.defaultDeviceID(output: false)
        let choice = hardware.first { $0.output && $0.device == outputID }
            ?? hardware.first { !$0.output && $0.device == inputID } ?? hardware.first
        return choice?.id ?? .noOutput
    }

    /// Settings' source type switched to Host plugins: the only connected insert, else none until the person
    /// chooses one (several are never chosen between by chance).
    func preferredPluginSource() -> SourceID {
        let plugins = devices.filter { device in
            device.isBridge && bridgeSources.contains { $0.sessionKey == device.bridgeSession && $0.compatible }
        }
        return plugins.count == 1 ? plugins[0].id : .anyPlugin
    }

    /// The status of Host plugins with no insert chosen: waiting for one to connect, or for the person to choose.
    private var unchosenPluginCondition: BridgeCondition {
        bridgeSources.contains(where: \.compatible) ? .unchosen : .connecting
    }

    func assign(role: Int, source: Int32) {
        guard RoutingStore.accepts(role: role, source: source, for: speakerLayout, channels: deviceChannels) else { return }
        sourceForRole[role] = source
        activeRoles[role] = source >= 0
        saveAssignment()
        if wantsCapture { restart() }
    }

    var selectedDevice: InputDevice? { devices.first(where: { $0.id == selectedID }) }

    private var deviceKey: String { selectedDevice?.key ?? (selectedID.output ? "none.output" : "none.input") }
    /// The selected device's inputs a routing may use (at most 64).
    private var deviceChannels: Int { Int(min(selectedDevice?.channels ?? 0, 64)) }
    /// Where routings are kept, and their rules.
    private let routes = RoutingStore()

    /// The selected DAW plugin, while it is connected.
    var selectedBridgeSource: BridgeSource? {
        selectedID.bridge.flatMap { session in bridgeSources.first { $0.sessionKey == session && $0.compatible } }
    }

    /// Whether the routing and the Immersive format come from a DAW plugin's own immersive bus rather than Settings.
    var layoutFromPlugin: Bool { pluginLayout != nil }

    /// Follows the selected source: a DAW plugin's immersive bus (kept while that insert is away and its layout is
    /// unknown), and nothing for mono and stereo plugins or any other source.
    private func refreshPluginLayout() {
        let layout: SpeakerLayout?, name: String?
        if selectedID.bridge == nil {
            (layout, name) = (nil, nil)
        } else if let source = selectedBridgeSource, source.roles != nil {
            (layout, name) = (source.immersiveLayout, source.layoutName.isEmpty ? nil : source.layoutName)
        } else {
            return
        }
        if layout != pluginLayout || name != pluginLayoutName {
            pluginLayout = layout
            pluginLayoutName = layout == nil ? nil : name
            if let layout { DiagnosticLog.event("DAW plugin bus: \(name ?? layout.name), drawn in \(layout.name)") }
        }
    }

    /// Restores this device's routing for the current layout. Without one, the device's speaker configuration in Audio
    /// MIDI Setup routes it (`deviceAssignment`), or, without that, input n feeds the layout's n-th role in SMPTE
    /// order; 5.1.2 also accepts the eight-role routing saved by 1.0. A DAW plugin's immersive bus routes itself: each
    /// channel feeds its own speaker role.
    private func loadAssignment() {
        refreshPluginLayout()
        if pluginLayout != nil, let roles = selectedBridgeSource?.roles {
            let routing = RoutingStore.routing(busRoles: roles)
            sourceForRole = routing
            activeRoles = routing.map { $0 >= 0 }
            return
        }
        let routing = routes.routing(for: speakerLayout, device: deviceKey, channels: deviceChannels, speakers: deviceSpeakers)
        sourceForRole = routing
        activeRoles = routing.map { $0 >= 0 }
    }

    private func saveAssignment() { routes.save(sourceForRole, for: speakerLayout, device: deviceKey) }

    /// The routing saved for this device and layout (5.1.2 also the eight-role routing saved by 1.0), if any.
    private var savedAssignment: [Int]? { routes.saved(for: speakerLayout, device: deviceKey) }

    /// The selected device's speaker configuration in Audio MIDI Setup (`AudioDevices.speakerMap`), read when asked.
    var deviceSpeakers: SpeakerMap? { selectedDevice.flatMap(AudioDevices.speakerMap) }

    /// The routing Settings' reset stages, and a device without a saved routing gets: the device's speaker
    /// configuration in Audio MIDI Setup, or input n to the n-th role in SMPTE order.
    var defaultAssignment: [Int32] { RoutingStore.defaultRouting(for: speakerLayout, channels: deviceChannels, speakers: deviceSpeakers) }
    /// Each role from the channel the device's speaker configuration gives it (roles it does not describe stay
    /// unrouted); nil without a configuration.
    var deviceAssignment: [Int32]? { deviceSpeakers.map { $0.routing(for: speakerLayout, channels: deviceChannels) } }
    /// Input n to the n-th role in SMPTE / ITU order (`SpeakerLayout.roles`).
    var smpteAssignment: [Int32] { RoutingStore.routing(inOrder: speakerLayout.roles, channels: deviceChannels) }
    /// Input n to the n-th role in film order (`SpeakerLayout.filmRoles`), for Pro Tools and other film-order sources.
    var filmAssignment: [Int32] { RoutingStore.routing(inOrder: speakerLayout.filmRoles, channels: deviceChannels) }
    /// Input n to the n-th role in VST3 order (`SpeakerLayout.vst3Roles`), for Nuendo, Cubase and other VST3 hosts.
    var vst3Assignment: [Int32] { RoutingStore.routing(inOrder: speakerLayout.vst3Roles, channels: deviceChannels) }

    /// Where the current routing comes from, for the diagnostic log.
    private var routingSource: String {
        if pluginLayout != nil { return "from the DAW plugin's bus" }
        if savedAssignment != nil { return "saved for this device and format" }
        if let speakers = deviceSpeakers { return "from Audio MIDI Setup (\(speakers.name))" }
        return "in SMPTE order"
    }

    /// Each routed role and its input (1-based), in the layout's display order: "L 1 · R 2 · C 3 …".
    private var routingSummary: String { RoutingStore.summary(sourceForRole, for: speakerLayout) }

    /// The device's speaker configuration changed in Audio MIDI Setup: a routing that follows it (none saved) follows
    /// the change at once.
    private func deviceSpeakersChanged() {
        objectWillChange.send()
        guard pluginLayout == nil, selectedDevice != nil, savedAssignment == nil else { return }
        let before = sourceForRole
        loadAssignment()
        guard sourceForRole != before else { return }
        DiagnosticLog.event("Speaker configuration changed in Audio MIDI Setup: \(deviceSpeakers?.name ?? "none")")
        if wantsCapture { restart() }
    }

    /// Routes every role of the current layout at once (Settings ▸ Apply): one save and one capture restart,
    /// where `assign(role:source:)` restarts per role. Sources the device does not have, and roles outside the
    /// layout, are switched off.
    func assign(routing: [Int32]) {
        let next = RoutingStore.validated(routing, for: speakerLayout, channels: deviceChannels)
        guard next != sourceForRole else { return }
        sourceForRole = next
        activeRoles = next.map { $0 >= 0 }
        saveAssignment()
        if wantsCapture { restart() }
    }

    func resume() {
        wantsCapture = true
        recoveryHalted = nil
        if Diagnostics.demo {
            if !continueDemo() { startDemo() }
            return
        }
        requestPermissionAndStart()
    }

    /// The demo carries on from the moment it paused.
    private func continueDemo() -> Bool {
        guard let session = paused, let demoStart else { return false }
        let gap = CACurrentMediaTime() - session.time
        self.demoStart = demoStart + gap
        carryOn(after: gap)
        status = .demo
        return true
    }

    private func startDemo() {
        stop()
        clearMeasurements()
        demoStart = CACurrentMediaTime()
        demoDetector = FormatDetector(initial: detectedFormat)
        sampleRate = 48_000
        captureChannels = speakerLayout.channelCount
        activeRoles = (0..<Role.count).map(speakerLayout.contains)
        captureStarted = Date()
        running = true
        status = .demo
    }

    func toggleCapture() {
        if running { pause() } else { resume() }
    }

    /// Pause holds everything where it is: capture stops, the analysis waits in place, and every panel keeps what it
    /// showed (see `frozen`). Resume carries on from that point rather than starting over.
    private func pause() {
        wantsCapture = false
        worker?.pause()
        silentOutput = false
        // The newest snapshot (the demo's included) is the one the panels hold.
        _ = pollSnapshot()
        // A DAW plugin measures its own audio: its measurement pauses there (for every display), and this display
        // holds its picture. The subscription stays, so the plugin's state keeps arriving.
        let pausedBridge = attachedBridge
        let pluginPaused = attachedBridge.map { link.send(ABR_COMMAND_PAUSE, name: "pause measurement", to: $0.session) } ?? false
        // Capture stops before its final counter is read and the ring is cleared. The 10 Hz readout can
        // lag behind the last callback, so carrying its displayed count would lose recent drops.
        droppedBefore += capture?.stop() ?? 0
        captureSession &+= 1
        droppedFrames = droppedBefore
        paused = PausedSession(source: selectedID, sources: capturedSources, roles: routedRoles, time: CACurrentMediaTime(),
                               bridge: pausedBridge, pluginPaused: pluginPaused)
        running = false
        status = .paused
        frozen = true
    }

    /// Resumes the paused analysis when capture can pick up exactly where it stopped: the same source and routing,
    /// at the same sample rate. Integrated loudness, held peaks, the histories and the scrolling displays then
    /// continue; anything else starts afresh (`restart`).
    private func continuePaused() -> Bool {
        if selectedDevice?.isBridge == true { return continuePausedBridge() }
        guard let session = paused, let worker, let capture, let device = selectedDevice, !device.isBridge,
              device.id == session.source, capturedSources == session.sources, routedRoles == session.roles else { return false }
        do { try capture.start(device: device, sourceForRole: capturedSources) } catch { return false }
        guard capture.sampleRate == sampleRate else {
            capture.stop()
            return false
        }
        worker.resume()
        captureChannels = Int(capture.channels)
        carryOn(after: CACurrentMediaTime() - session.time)
        status = .capturing(device: device.name, output: device.output, channels: Int(capture.channels),
                            layout: shownLayoutName)
        Diagnostics.log("Capture resumed: \(status.text)")
        return true
    }

    /// The DAW plugin counterpart: the same live insert, in the same format and routing, subscribes again and its
    /// audio flows into the waiting analysis. As with a device, the time paused is left out and nothing is reset.
    private func continuePausedBridge() -> Bool {
        guard let session = paused, let format = session.bridge, let worker, attachedBridge != nil,
              let device = selectedDevice, device.id == session.source,
              let source = bridgeSources.first(where: { $0.sessionKey == format.session && $0.compatible }),
              source.formatEpoch == format.epoch, source.channels == format.channels, source.sampleRate == sampleRate
        else { return false }
        link.send(ABR_COMMAND_RESUME, name: "resume measurement", to: format.session)
        worker.resume()
        captureChannels = format.channels
        carryOn(after: CACurrentMediaTime() - session.time)
        status = .bridge(name: source.label(among: bridgeSources), condition: shownCondition(source),
                         channels: source.channels, layout: shownLayoutName)
        Diagnostics.log("DAW plugin capture resumed: \(status.text)")
        return true
    }

    /// Live again after a pause of `gap` seconds, which the elapsed time leaves out.
    private func carryOn(after gap: CFTimeInterval) {
        paused = nil
        captureStarted = captureStarted?.addingTimeInterval(gap)
        running = true
        DiagnosticLog.event("Resumed")
    }

    /// The capture state in a word, for the Settings sidebar: live, paused (holding the picture), or standby (not
    /// started, or stopped). The summary chip words the same three states in capitals of its own.
    var captureStateTitle: String { running ? L("Live") : (frozen ? L("Paused") : L("Standby")) }

    /// What the capture button does now: pause, resume a paused analysis, or start one.
    var captureActionTitle: String {
        running ? L("Pause Capture") : (paused != nil ? L("Resume Capture") : L("Start Capture"))
    }

    /// Capture for the selected source: the paused analysis when it can carry on, otherwise a fresh one.
    private func startCapture() {
        if !continuePaused() { restart() }
    }

    func stop() {
        // A DAW insert this display paused, left without resuming it here: read before the paused session goes.
        let pausedPlugin = paused?.pluginPaused == true ? paused?.bridge?.session : nil
        frozen = false
        silentOutput = false
        droppedBefore = 0
        paused = nil
        demoStart = nil
        hardwareObserver?.watch(nil)
        // The ring's producer goes first (the bridge thread or the device), then its consumer.
        link.receiver?.detach()
        if let pausedPlugin {
            // Its measurement must not stay paused for nobody. Sent before any other insert is subscribed; if the
            // connection is already gone, the plugin has resumed by itself.
            link.send(ABR_COMMAND_RESUME, name: "resume measurement", to: pausedPlugin)
        }
        attachedBridge = nil
        resultInbox = nil
        worker?.stop()
        worker = nil
        capture?.stop()
        captureSession &+= 1
        running = false
    }

    private func requestPermissionAndStart() {
        guard let selectedDevice else {
            stop()
            snapshot = MeterSnapshot()
            clearMeasurements()
            if selectedID.bridge != nil {
                // A DAW plugin that is not connected (yet): `pollBridge` starts it when it appears.
                status = .bridge(name: waitingBridgeName, condition: waitingForLaunch ? unchosenPluginCondition : .disconnected,
                             channels: 0, layout: shownLayoutName)
                return
            }
            link.receiver?.select(nil)
            status = UserDefaults.standard.string(forKey: Self.inputDeviceUIDKey) == "" ? .noSelection : .noDevice
            return
        }
        // Core Audio taps ask for System Audio Recording when the output aggregate begins capture. A DAW plugin
        // needs no permission at all. Microphone authorization is only needed for a physical or virtual input.
        if selectedDevice.output || selectedDevice.isBridge { startCapture(); return }
        guard !permissionPending else { return }
        Diagnostics.log("Microphone authorization: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: startCapture()
        case .notDetermined:
            permissionPending = true
            status = .waitingForPermission
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.permissionPending = false
                    AudioPermission.shared.refresh()
                    if granted && self.wantsCapture { self.startCapture() }
                    else { self.status = .permissionDenied }
                }
            }
        default:
            stop()
            status = .permissionDenied
        }
    }

    private func restart() {
        guard selectedDevice?.output == true || selectedDevice?.isBridge == true
                || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        stop()
        snapshot = MeterSnapshot()
        clearMeasurements()
        guard let capture else { status = .ringFailed; return }
        guard let device = devices.first(where: { $0.id == selectedID }) else { status = .noDevice; return }
        if device.isBridge { startBridge(device, capture: capture); return }
        link.receiver?.select(nil)
        do {
            try capture.start(device: device, sourceForRole: capturedSources)
            streamID = streamID == 1_000_000 ? 1 : streamID + 1
            guard let worker = dependencies.makeLocalWorker(capture.ring, capture.sampleRate, streamID, routedRoles,
                                                            makeDetector()) else {
                capture.stop()
                status = .dspFailed
                return
            }
            worker.setSpatialSpectrum(format == .spatial)
            self.worker = worker
            configureSpectrumArchitecture()
            sampleRate = capture.sampleRate
            captureChannels = Int(capture.channels)
            captureStarted = Date()
            droppedFrames = 0
            running = true
            if !device.uid.isEmpty {
                UserDefaults.standard.set(device.uid, forKey: Self.inputDeviceUIDKey)
                UserDefaults.standard.set(device.output, forKey: Self.inputDeviceIsOutputKey)
            }
            hardwareObserver?.watch(device.device)
            recoveryHalted = nil
            DiagnosticLog.event(String(format: "Stream: %.0f Hz, %d ch", capture.sampleRate, Int(capture.channels)))
            DiagnosticLog.event("Routing \(routingSource): \(routingSummary)")
            status = .capturing(device: device.name, output: device.output, channels: Int(capture.channels),
                                layout: shownLayoutName)
            Diagnostics.log("Capture started: \(status.text)")
        } catch {
            status = .failure(StatusMessage { error.localizedDescription })
            Diagnostics.log("Capture error: \(status.text)")
        }
    }

    // MARK: Capture recovery

    /// Called at the readout rate, whether or not a window shows: watches the selected device's capture for a failure
    /// that lasts, restarts it a bounded number of times, and gives up visibly (`CaptureRecoveryPolicy`). Only a device
    /// capture the person wants running is watched: never a paused or stopped one, the demo, or a DAW plugin (whose own
    /// paths follow its connection and format).
    func superviseCapture() {
        guard let capture, wantsCapture, demoStart == nil, let device = selectedDevice, !device.isBridge,
              running || recovery.isActive else {
            recovery.reset()
            return
        }
        // A phase kept from another capture session is over (`observe` forgets it).
        let before = recovery.session == captureSession ? recovery.phase : .watching
        let decision = recovery.observe(capture.health(), sampleRate: sampleRate, session: captureSession,
                                        now: dependencies.clock())
        switch decision {
        case let .restart(attempt, failure)?: recoverCapture(device, attempt: attempt, failure: failure, from: before)
        case let .giveUp(attempts, failure)?: giveUpCapture(device, attempts: attempts, failure: failure)
        case nil: showRecovery(device, from: before)
        }
    }

    /// Restart number `attempt` of the selected device's capture. Opened again at its rate, the device's IO carries on
    /// into the same analysis: the ring keeps its count of lost frames, and they make one break where the new IO writes
    /// first. At another rate, or with no analysis left (an earlier restart could not open the device), capture starts
    /// afresh, as a rate notification would have it.
    private func recoverCapture(_ chosen: InputDevice, attempt: Int, failure: CaptureRecoveryPolicy.Failure,
                                from before: CaptureRecoveryPolicy.Phase) {
        showRecovery(chosen, from: before)
        // The latest device list first: a device gone by now is the device list's to follow (no device, then its return).
        let session = captureSession
        refreshDevices()
        guard captureSession == session, let capture, let device = selectedDevice, device.id == chosen.id else { return }
        DiagnosticLog.event("Capture recovery: restart \(attempt) of \(recovery.thresholds.backoff.count)")
        /// Capture afresh (`restart`): opened when it made a new session that runs.
        func startAfresh() -> Bool {
            let previous = captureSession
            restart()
            recovery.adopt(session: captureSession)
            return captureSession != previous && running
        }
        var opened = true
        if worker != nil && running {
            do {
                try capture.restart(device: device, sourceForRole: capturedSources, minimumFrames: failure.minimumFrames)
                if capture.sampleRate != sampleRate {
                    DiagnosticLog.event(String(format: "Capture recovery: the device runs at %.0f Hz now; the analysis starts afresh",
                                               capture.sampleRate))
                    // Never into the analysis made for the old rate, even if a fresh start cannot follow.
                    capture.stop()
                    opened = startAfresh()
                }
            } catch {
                DiagnosticLog.event("Capture recovery: restart \(attempt) could not open the device: \(error.localizedDescription)")
                opened = false
            }
        } else {
            opened = startAfresh()
        }
        if opened {
            showRecovering(device, attempt: attempt, of: recovery.thresholds.backoff.count)
        } else if case let .giveUp(attempts, failure)? = recovery.restartFailed(now: dependencies.clock()) {
            giveUpCapture(device, attempts: attempts, failure: failure)
        } else if case let .waiting(next, due, _, _) = recovery.phase {
            DiagnosticLog.event(String(format: "Capture recovery: restart %d in %.1f s", next, max(0, due - dependencies.clock())))
            showRecovering(device, attempt: next, of: recovery.thresholds.backoff.count)
        }
    }

    /// The episode's restarts are spent: capture stops, releasing the device rather than keeping it failing, and the
    /// status says why. Start Capture, or choosing a source, tries again.
    private func giveUpCapture(_ device: InputDevice, attempts: Int, failure: CaptureRecoveryPolicy.Failure) {
        DiagnosticLog.event("Capture recovery gave up after \(attempts) restarts (\(failure.logDescription)), "
                            + "\(droppedFrames) frames dropped: capture stopped")
        stop()
        recovery.reset()
        recoveryHalted = selectedID
        let name = device.output ? L("%@ (output)", device.name) : device.name
        status = .failure(StatusMessage {
            L("%@ · capture kept failing after %d restarts: %@ · choose Start Capture to try again", name, attempts, failure.text)
        })
    }

    /// The status while recovery holds the capture (a restart pending or being verified) and once it lets go, with a
    /// line in the diagnostic log for each step; `before` is the phase the step started from.
    private func showRecovery(_ device: InputDevice, from before: CaptureRecoveryPolicy.Phase) {
        let phase = recovery.phase
        guard phase != before else { return }
        let total = recovery.thresholds.backoff.count
        let detected: Bool
        switch before {
        case .watching, .recovered: detected = true
        case .waiting, .verifying: detected = false
        }
        switch phase {
        case let .waiting(attempt, due, failure, _):
            let wait = String(format: "%.1f s", max(0, due - dependencies.clock()))
            if detected {
                DiagnosticLog.event("Capture keeps failing (\(failure.logDescription)), \(droppedFrames) frames dropped: "
                                    + "restart \(attempt) of \(total) in \(wait)")
            } else if case .verifying = before {
                DiagnosticLog.event("Capture recovery: restart \(attempt - 1) did not bring audio back; restart \(attempt) in \(wait)")
            }
            showRecovering(device, attempt: attempt, of: total)
        case let .verifying(attempt, _, failure):
            if detected { DiagnosticLog.event("Capture keeps failing (\(failure.logDescription)), \(droppedFrames) frames dropped") }
            showRecovering(device, attempt: attempt, of: total)
        case let .recovered(attempts, _):
            if case .verifying = before { DiagnosticLog.event("Capture recovered after restart \(attempts): audio delivered again") }
            if case .waiting = before { DiagnosticLog.event("Capture came back by itself before restart \(attempts + 1)") }
            showCapturing(device)
        case .watching:
            if case .recovered = before { DiagnosticLog.event("Capture healthy since it recovered: every restart available again") }
            showCapturing(device)
        }
    }

    private func showRecovering(_ device: InputDevice, attempt: Int, of total: Int) {
        let name = device.output ? L("%@ (output)", device.name) : device.name
        let text = { L("%@ · capture keeps failing · restarting it (attempt %d of %d)", name, attempt, total) }
        if case let .recovering(shown) = status, shown.text == text() { return }
        status = .recovering(StatusMessage(text))
    }

    private func showCapturing(_ device: InputDevice) {
        guard case .recovering = status, running, let capture else { return }
        status = .capturing(device: device.name, output: device.output, channels: Int(capture.channels), layout: shownLayoutName)
    }

    // MARK: DAW Bridge

    /// Name shown while the selected DAW plugin is away: the name it had when chosen.
    private var waitingBridgeName: String {
        [link.saved?.name, UserDefaults.standard.string(forKey: BridgeLink.nameKey)].compactMap { $0 }
            .first { !$0.isEmpty } ?? L("DAW plugin")
    }

    /// Launched by a plugin and still waiting for it (no insert known yet).
    private var waitingForLaunch: Bool { selectedID.bridge == SourceID.waitingPrefix }

    /// Diagnostics: breaks the selected insert's connection, as a failure would; the plugin reconnects by itself.
    func dropBridgeConnection() {
        guard let session = selectedID.bridge, let source = bridgeSources.first(where: { $0.sessionKey == session }) else { return }
        link.receiver?.disconnect(source.session, refusingFor: 1_500)
    }

    /// One click in a plugin window ("Show in / Open Auraliscope Labs"): select that insert, resume if paused, and
    /// bring the meter window forward. It is the person's choice, as in the source list.
    private func followFocusRequests() {
        for source in link.takeFocusRequests() {
            DiagnosticLog.event("DAW plugin \"\(source.displayName)\" asked to be shown")
            let id = SourceID(device: 0, bridge: source.sessionKey)
            if !wantsCapture { wantsCapture = true }
            if selectedID != id { select(id) } else if !running { restart() }
            NSApp.activate(ignoringOtherApps: true)
            MainWindow.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// The condition for the status line. The plugin reports how long ago its host last gave it audio, whatever
    /// Labs is showing, so no grace period is needed after attaching: "streaming" means audio is being measured.
    private func shownCondition(_ source: BridgeSource) -> BridgeCondition {
        let condition = BridgeCondition(source)
        // Delayed: the plugin reports audio measured that no result shown here covers (its STATUS runs ahead of the
        // results). A pause in the results while the host was stopped is not a delay.
        if condition == .streaming, let result = resultInbox?.latest, result.generation == source.generation,
           Double(source.framesAnalysed) - Double(result.framesAnalysed) > BridgeCondition.staleResults * max(1, source.sampleRate) {
            return .stale
        }
        return condition
    }

    /// Starts analysis of a DAW plugin instance: a new pipeline at the plugin's own sample rate, then the
    /// receiver writes that instance's audio into the ring. Every format change comes back through here, so the
    /// analyzers are always configured for exactly the audio they receive.
    private func startBridge(_ device: InputDevice, capture: CaptureBackend) {
        guard let receiver = link.receiver else {
            status = .failure(StatusMessage { L("DAW plugin receiver unavailable: %@", self.bridgeError ?? "") })
            return
        }
        guard let source = bridgeSources.first(where: { $0.sessionKey == device.bridgeSession && $0.compatible }) else {
            status = .bridge(name: device.name, condition: .disconnected, channels: 0, layout: shownLayoutName)
            return
        }
        receiver.select(source.session)
        guard source.hasUsableFormat else {
            // Subscribed, so it streams as soon as it has a format; `pollBridge` restarts then.
            status = .bridge(name: source.label(among: bridgeSources), condition: BridgeCondition(source),
                             channels: source.channels, layout: shownLayoutName)
            return
        }
        // The plugin analyses its own audio; this only shows its results (no pipeline, no audio here). Its bus's
        // layout sets the routing and, for an immersive bus, the Immersive format drawn.
        loadAssignment()
        streamID = streamID == 1_000_000 ? 1 : streamID + 1
        let inbox = ResultInbox(streamSeed: streamID * 1000)
        guard let worker = ResultWorker(inbox: inbox) else {
            status = .dspFailed
            return
        }
        self.worker = worker
        resultInbox = inbox
        receiver.attach(inbox)
        attachedBridge = (source.sessionKey, source.formatEpoch, source.channels)
        bridgeLostBase = source.framesDroppedByPlugin
        sampleRate = source.sampleRate
        captureChannels = source.channels
        captureStarted = Date()
        droppedFrames = 0
        running = true
        link.attached(source)
        DiagnosticLog.event(String(format: "DAW plugin results: %.0f Hz, %d ch %@, %@ %@ in %@, analysis generation %u",
                                   source.sampleRate, source.channels, source.layoutName, source.plugin, source.pluginVersion,
                                   source.hostName, source.generation))
        status = .bridge(name: source.label(among: bridgeSources), condition: shownCondition(source),
                         channels: source.channels, layout: shownLayoutName)
        Diagnostics.log("DAW plugin capture started: \(status.text)")
    }

    /// Five times a second: picks up plugin instances that came or went, follows the selected one through
    /// format changes, disconnection and return, finds the saved insert again, and keeps the status current.
    private func pollBridge() {
        guard link.receiver != nil else { return }
        link.refresh()
        let listed = devices.filter(\.isBridge)
        if listed != bridgeDevices {
            if listed.map(\.id) != bridgeDevices.map(\.id) {
                DiagnosticLog.event("DAW plugins: \(bridgeSources.map { "\($0.displayName) (\($0.hostName) \($0.plugin)\($0.compatible ? "" : ", protocol \($0.protocolVersion)"))" }.joined(separator: ", "))")
            }
            devices = devices.filter { !$0.isBridge } + bridgeDevices
        }
        followFocusRequests()
        guard let selected = selectedID.bridge, wantsCapture, demoStart == nil else { return }
        if let source = bridgeSources.first(where: { $0.sessionKey == selected && $0.compatible }) {
            followBound(source)
        } else {
            findSaved()
        }
    }

    /// The bound insert is connected: re-check a provisional choice, follow its format, and keep its status and
    /// saved context current.
    private func followBound(_ source: BridgeSource) {
        if let sessions = link.checkBound(source), let saved = link.saved {
            // Another insert claiming the saved one arrived after the automatic choice: it no longer holds.
            DiagnosticLog.event("DAW plugin choice became ambiguous: \(sessions.count) inserts claim \"\(saved.name)\"")
            becomeAmbiguous(sessions, saved: saved)
            return
        }
        link.logBreaks(source)
        if let attached = attachedBridge {
            // Reconfigure whenever the audio the receiver would deliver no longer matches the pipeline.
            if attached.session != source.sessionKey || attached.epoch != source.formatEpoch || attached.channels != source.channels {
                DiagnosticLog.event(String(format: "DAW plugin format changed: %.0f Hz, %d ch %@; analysis restarted",
                                           source.sampleRate, source.channels, source.layoutName))
                // The routing follows the new layout (startBridge loads it again once restarted).
                restart()
                return
            }
        } else if source.hasUsableFormat {
            restart()
            return
        }
        let next = MeterStatus.bridge(name: source.label(among: bridgeSources), condition: shownCondition(source),
                                      channels: source.channels, layout: shownLayoutName)
        if status != next { status = next }
    }

    /// The bound plugin's results as they arrive (tests and diagnostics).
    var latestBridgeResult: ResultMessage? { resultInbox?.latest }
    var bridgeResultCounters: (received: Int, rejected: Int, spectrogramGaps: UInt64, spectrogramSkipped: UInt64, waveformGaps: UInt64)? {
        resultInbox?.counters
    }
    /// Whether the display shows a DAW plugin's own results (no local analysis of that source).
    var showingBridgeResults: Bool { worker is ResultWorker }

    /// Nothing bound is connected: the bound insert went away (its analysis waits for the same live insert), or
    /// the saved one has yet to appear, or several could be it. See `BridgeRestoration` for the rules.
    private func findSaved() {
        let waiting = MeterStatus.bridge(name: waitingBridgeName,
                                         condition: waitingForLaunch ? unchosenPluginCondition : attachedBridge != nil ? .disconnectedHeld : .disconnected,
                                         channels: 0, layout: shownLayoutName)
        // Launched by a plugin's button: its request selects the insert; the saved one is not restored meanwhile.
        guard !waitingForLaunch, let restoration = link.findSaved(), let saved = link.saved else {
            if status != waiting { status = waiting }
            return
        }
        switch restoration {
        case let .bind(source, provisional):
            bind(source, provisional: provisional)
        case .settling:
            if status != waiting { status = waiting }
        case .wait:
            if !bridgeCandidates.isEmpty { bridgeCandidates = [] }
            if status != waiting { status = waiting }
        case let .ambiguous(sessions):
            if sessions != bridgeCandidates || attachedBridge != nil { becomeAmbiguous(sessions, saved: saved) }
        case .unchanged:
            break
        }
    }

    /// Binds the saved insert, found again. A held analysis of the same live insert carries on (the receiver marks
    /// the break); anything else starts afresh.
    private func bind(_ source: BridgeSource, provisional: Bool) {
        let continuing = attachedBridge.map { $0.session == source.sessionKey && $0.epoch == source.formatEpoch
            && $0.channels == source.channels } ?? false
        DiagnosticLog.event("DAW plugin \"\(source.displayName)\" (\(source.hostName) \(source.plugin)) \(continuing ? "returned; analysis continues" : provisional ? "found again; analysis starts (provisional)" : "found again; analysis starts")")
        selectedID = SourceID(device: 0, bridge: source.sessionKey)
        bridgeCandidates = []
        link.bound(source, provisional: provisional)
        if continuing {
            status = .bridge(name: source.label(among: bridgeSources), condition: shownCondition(source),
                             channels: source.channels, layout: shownLayoutName)
            return
        }
        loadAssignment()
        restart()
    }

    /// Several inserts could be the saved one: analysis stops, and the status and the source list say so until
    /// the person chooses one.
    private func becomeAmbiguous(_ sessions: [String], saved: BridgeSelection) {
        if running || attachedBridge != nil {
            stop()
            snapshot = MeterSnapshot()
            clearMeasurements()
        }
        link.receiver?.select(nil)
        link.becameAmbiguous()
        bridgeCandidates = sessions
        selectedID = SourceID(device: 0, bridge: SourceID.waitingPrefix + saved.persistent)
        status = .bridge(name: waitingBridgeName, condition: .ambiguous(sessions.count), channels: 0,
                         layout: shownLayoutName)
    }
}
