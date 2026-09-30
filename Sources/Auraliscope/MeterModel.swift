import AVFoundation
import AppKit
import AudioRing
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

    init?(ring: OpaquePointer, sampleRate: Double, streamID: UInt32, activeRoles: [Bool], detector: FormatDetector) {
        precondition(SnapshotSlots.total == Int(METER_SNAPSHOT_FLOATS), "snapshot layout and C buffer disagree")
        guard let pipeline = MeterPipeline(sampleRate: sampleRate, activeRoles: activeRoles, detector: detector, streamID: streamID),
              let exchange = meter_exchange_create() else { return nil }
        self.exchange = exchange
        let source = DispatchSource.makeTimerSource(queue: queue)
        var batch = [ChannelFrame](repeating: ChannelFrame(), count: 4096)
        var values = [Float](repeating: 0, count: Int(METER_SNAPSHOT_FLOATS))
        var receivedPCM = false
        var receivedSignal = false
        var truePeakResets: UInt32 = 0
        var mark = ChannelRingMark()
        var marked: Int32 = 0
        let clock = clock
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
            meter_exchange_publish(exchange, values)
        }
        timer = source
        source.resume()
    }

    /// Asks the DSP queue to clear its held true peaks before its next snapshot.
    func resetTruePeaks() { meter_exchange_reset_true_peaks(exchange) }

    /// Spatial monitoring: spectrum and waterfall sum every routed channel.
    func setSpatialSpectrum(_ spatial: Bool) { meter_exchange_set_mode(exchange, spatial ? 1 : 0) }

    func latest() -> MeterSnapshot? {
        guard meter_exchange_read(exchange, &readValues) != 0 else { return nil }
        return Self.decode(readValues)
    }

    static func decode(_ v: [Float]) -> MeterSnapshot {
        var s = MeterSnapshot()
        s.spectrum = Array(v[SnapshotSlots.spectrum..<(SnapshotSlots.spectrum + MeterSnapshot.bandCount)])
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
        // On the analysis queue, which owns the clock (and is idle while the timer is suspended).
        queue.sync { clock.paused += gap }
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
    private var watchedDevice: AudioDeviceID?
    private static let configurationSelectors: [AudioObjectPropertySelector] = [
        kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive
    ]

    init(devicesChanged: @escaping () -> Void, configurationChanged: @escaping () -> Void) {
        devicesBlock = { _, _ in devicesChanged() }
        configurationBlock = { _, _ in configurationChanged() }
        var address = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, devicesBlock)
    }

    func watch(_ device: AudioDeviceID?) {
        if let previous = watchedDevice {
            for selector in Self.configurationSelectors {
                var address = Self.address(selector)
                AudioObjectRemovePropertyListenerBlock(previous, &address, .main, configurationBlock)
            }
        }
        watchedDevice = device
        if let device {
            for selector in Self.configurationSelectors {
                var address = Self.address(selector)
                AudioObjectAddPropertyListenerBlock(device, &address, .main, configurationBlock)
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
            case .bypassed: return L("%@ · DAW plugin · bypassed in the DAW", name)
            case .offline: return L("%@ · DAW plugin · offline render, not metered", name)
            case .inactive: return L("%@ · DAW plugin · inactive in the DAW", name)
            case .unsupported: return L("%@ · DAW plugin · only mono and stereo are supported", name)
            case .notResponding: return L("%@ · DAW plugin · not responding", name)
            case .disconnected: return L("%@ · DAW plugin disconnected · waiting for it to return", name)
            case .disconnectedHeld:
                return L("%@ · DAW plugin disconnected · measurement held in case this plugin instance reconnects", name)
            case .connecting: return L("Waiting for the DAW plugin to connect…")
            case let .ambiguous(count):
                return L("%@ · %d connected inserts could be the saved one · choose one in Settings or click its plugin button", name, count)
            }
        case let .failure(message): return message.text
        }
    }

    /// The status for the diagnostic log, in English whatever the interface language (a failure keeps its text).
    var logDescription: String {
        switch self {
        case let .capturing(device, output, channels, layout):
            return "Capturing \(output ? "output" : "input") \"\(device)\" · \(channels) ch → \(layout)"
        case let .bridge(name, condition, channels, layout):
            return "DAW plugin \"\(name)\": \(condition) · \(channels) ch → \(layout)"
        case let .failure(message): return "Error: \(message.text)"
        default: return "Status: \(self)"
        }
    }
}

/// What a selected DAW plugin source is doing, as the status line reports it.
enum BridgeCondition: Equatable {
    case streaming, noAudio, bypassed, offline, inactive, unsupported, notResponding, disconnected
    /// Disconnected while its analysis waits: the same live insert coming back continues it (with a break).
    case disconnectedHeld
    /// Launched by a plugin, before it has connected.
    case connecting
    /// Several connected inserts claim the saved one and nothing tells them apart: nothing is analysed until the
    /// person chooses.
    case ambiguous(Int)

    /// Live audio older than this reads as "no audio" (the DAW stopped calling the plugin).
    static let staleAudio = 0.5
    /// A connection silent for this long (no status either) reads as "not responding".
    static let staleMessages = 2.0

    init(_ source: BridgeSource) {
        if source.secondsSinceMessage > Self.staleMessages { self = .notResponding; return }
        switch source.state {
        case .bypassed: self = .bypassed
        case .offline: self = .offline
        case .inactive: self = .inactive
        case .live:
            if !source.hasUsableFormat { self = .unsupported }
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
    @Published var floating = true
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
            UserDefaults.standard.set(speakerLayout.rawValue, forKey: "speakerLayout")
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
            UserDefaults.standard.set(formatMode.rawValue, forKey: "formatMode")
            if formatMode != oldValue { DiagnosticLog.event("Monitoring mode: \(formatMode.rawValue)") }
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
            UserDefaults.standard.set(monoEnabled, forKey: "showMonoMode")
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

    private static func stored(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.double(forKey: key)
    }

    /// Picks a standard for one mode; a known standard brings its own true-peak ceiling.
    func setTarget(_ target: Double, spatial: Bool) {
        let ceiling = LoudnessStandard.standard(target: target)?.ceiling
        if spatial {
            spatialTarget = target
            if let ceiling { spatialCeiling = ceiling }
        } else {
            stereoTarget = target
            if let ceiling { stereoCeiling = ceiling }
        }
        saveLoudness()
    }

    func setCeiling(_ ceiling: Double, spatial: Bool) {
        if spatial { spatialCeiling = ceiling } else { stereoCeiling = ceiling }
        saveLoudness()
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
    var spectrumStrip = CGFloat(UserDefaults.standard.double(forKey: "layout.spectrumStrip"))
    /// Band resolution chosen on the Soundstage and Channel Levels panels (their switchers write it together with
    /// their own `@AppStorage`); plain, read by the canvases every frame.
    var stageBands = MeterModel.storedBands("soundstage.bands")
    var levelsBands = MeterModel.storedBands("levels.bands")
    /// The stereometer's style, chosen on the Soundstage header; plain, like the band resolutions.
    var stageStyle = StageStyle.stored
    /// Spectrum side, peak holds and waveform span, chosen in Settings › Panels.
    var displayOptions = DisplayOptions.stored
    static func storedBands(_ key: String) -> StereoBands.Resolution {
        StereoBands.Resolution(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .five
    }
    private var bandsObserver: NSObjectProtocol?
    private(set) var captureStarted: Date?
    private(set) var captureChannels = 0
    private var lastDropLog = Date.distantPast
    /// Frames dropped before the last resume: capture restarts clear the ring's own count.
    private var droppedBefore: UInt64 = 0
    let readouts = Readouts()

    private let capture = AudioCapture()
    private var worker: DSPWorker?
    private var demoStart: CFTimeInterval?
    private var demoDetector = FormatDetector()
    private var streamID: UInt32 = 0
    /// Changes whenever capture (re)starts; diagnostics use it to prove an operation left the audio path alone.
    var captureGeneration: UInt32 { streamID }
    private var hardwareObserver: HardwareObserver?
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
    }
    private var paused: PausedSession?

    // DAW Bridge: plugin instances are listed with the devices and selected like one.
    private let bridge: BridgeReceiver?
    /// The insert chosen last, saved with its context so the same insert can be found again (BridgeRestoration).
    private var bridgeSaved: BridgeSelection?
    /// The inserts that could be the saved one while that is ambiguous (their sessions); empty otherwise.
    @Published private(set) var bridgeCandidates: [String] = []
    /// Chosen by restoration rather than by the person: until then another insert claiming the saved identity
    /// makes the choice ambiguous again, and analysis stops.
    private var bridgeProvisionalUntil: Date?
    /// When an insert claiming the saved identity first appeared: restoration waits a moment for the others of a
    /// project that is still loading.
    private var bridgeClaimSeen: Date?
    private static let restorationSettle: TimeInterval = 1.0
    private static let provisionalSpan: TimeInterval = 5.0
    /// Breaks in the current analysis and the seconds known missing at them (from the snapshot), for the status bar.
    @Published private(set) var measurementBreaks = 0
    @Published private(set) var missingSeconds = 0.0
    /// Why the receiver could not start (nil while it runs).
    let bridgeError: String?
    /// Newest report of every connected plugin instance (polled, not published: counters change constantly).
    private(set) var bridgeSources: [BridgeSource] = []
    /// The instance and format the ring is attached to, while a DAW source runs.
    private var attachedBridge: (session: String, epoch: UInt32, channels: Int)?
    /// Frames lost before the current attachment, so the status bar counts this stream only.
    private var bridgeLostBase: UInt64 = 0
    private var bridgeTimer: Timer?
    /// Focus requests already acted on, per session.
    private var focusHandled: [String: UInt32] = [:]
    /// Breaks of the bound insert already written to the diagnostic log (session, count).
    private var breaksLogged: (session: String, count: UInt64)?
    /// When the ring was attached: the first audio needs a moment to arrive before "no audio" is shown.
    private var bridgeAttachedAt = Date.distantPast
    private static let bridgeNameKey = "bridgeSourceName"

    deinit {
        worker?.stop()
        capture?.stop()
    }

    init() {
        speakerLayout = UserDefaults.standard.string(forKey: "speakerLayout").flatMap(SpeakerLayout.init(rawValue:)) ?? .standard
        let savedMode = UserDefaults.standard.string(forKey: "formatMode")
        let showMono = UserDefaults.standard.bool(forKey: "showMonoMode")
        monoEnabled = showMono
        // 2.0 stored the pinned multichannel mode as "surround". A pinned Mono needs Mono enabled.
        let mode = savedMode == "surround" ? .spatial : FormatMode(rawValue: savedMode ?? "") ?? .auto
        formatMode = mode == .mono && !showMono ? .stereo : mode
        switch BridgeReceiver.start() {
        case let .success(receiver): bridge = receiver; bridgeError = nil
        case let .failure(error): bridge = nil; bridgeError = error.reason
        }
        devices = AudioDevices.availableSources()
        let savedUID = UserDefaults.standard.string(forKey: "inputDeviceUID")
        let savedOutput = UserDefaults.standard.bool(forKey: "inputDeviceIsOutput")
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
        } else if let savedUID, savedUID.hasPrefix(bridgeUIDPrefix) {
            // A DAW plugin chosen last time: wait for that insert to connect rather than fall back to a device.
            let persistent = String(savedUID.dropFirst(bridgeUIDPrefix.count))
            selectedID = SourceID(device: 0, bridge: SourceID.waitingPrefix + persistent)
            bridgeSaved = BridgeSelection.load().flatMap { $0.persistent == persistent ? $0 : nil }
                ?? BridgeSelection(persistent: persistent, name: UserDefaults.standard.string(forKey: Self.bridgeNameKey) ?? "")
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
        // The band switches write user defaults; follow them so every writer (the switches, a defaults change)
        // reaches the canvases.
        bandsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let stage = Self.storedBands("soundstage.bands"), levels = Self.storedBands("levels.bands")
                if stage != self.stageBands { self.stageBands = stage }
                if levels != self.levelsBands { self.levelsBands = levels }
                let style = StageStyle.stored
                if style != self.stageStyle { self.stageStyle = style }
                let options = DisplayOptions.stored
                if options != self.displayOptions { self.displayOptions = options }
            }
        }
        hardwareObserver = HardwareObserver(devicesChanged: { [weak self] in
            Task { @MainActor in self?.refreshDevices() }
        }, configurationChanged: { [weak self] in
            Task { @MainActor in
                guard let self, self.wantsCapture else { return }
                let previousID = self.selectedID
                let wasRunning = self.running
                self.refreshDevices()
                if wasRunning && self.selectedID == previousID && self.selectedDevice != nil { self.restart() }
            }
        })
        if bridge != nil {
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
        }
    }

    /// Latest analysis; canvases and readouts share it, so polling from either is idempotent.
    func pollSnapshot() -> MeterSnapshot {
        if let demoStart, running {
            let elapsed = CACurrentMediaTime() - demoStart
            let sequence = Int(elapsed * DemoSignal.updateRate)
            if Float(sequence % 1_000_000 + 1) != snapshot.sequence {
                snapshot = DemoSignal.snapshot(at: Double(sequence) / DemoSignal.updateRate, sequence: sequence)
                let format = demoDetector.update(rms: snapshot.channelRMS, deltaTime: Float(1 / DemoSignal.updateRate))
                snapshot.detectedFormat = Float(format.rawValue)
            }
        } else if let next = worker?.latest() {
            snapshot = next
        }
        return snapshot
    }

    func canvasFrame() -> CanvasFrame {
        worker?.setSpatialSpectrum(format == .spatial)
        return CanvasFrame(snapshot: pollSnapshot(), sampleRate: sampleRate, running: running, frozen: frozen,
                    activeRoles: routedRoles, epoch: epoch, spatial: format == .spatial, mono: format == .mono,
                    layout: speakerLayout, spectrumStrip: spectrumStrip, truePeakEpoch: truePeakEpoch,
                    stageBands: stageBands, levelsBands: levelsBands, stageStyle: stageStyle,
                    options: displayOptions)
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
            // Audio a DAW plugin could not deliver (receiver or sender overload), counted from stream positions.
            dropped += source.framesLost &- bridgeLostBase
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
                (format == .spatial ? speakerLayout.name : (format == .mono ? "1.0" : "2.0"), "")]
    }

    func reportRendererError(_ message: StatusMessage) {
        stop()
        status = .failure(message)
    }

    func refreshDevices() {
        refreshDevices(using: AudioDevices.availableSources() + bridgeDevices)
    }

    /// Connected DAW plugin instances as sources, in connection order. One of another protocol version is left
    /// out (Settings names it as needing an update).
    private var bridgeDevices: [InputDevice] {
        let compatible = bridgeSources.filter(\.compatible)
        return compatible.map { source in
            InputDevice(device: 0, name: source.displayName, channels: UInt32(max(source.channels, 0)),
                        uid: bridgeUIDPrefix + source.persistentKey, bridgeSession: source.sessionKey,
                        detail: source.label(among: compatible))
        }
    }

    /// Plugins of another protocol version, by host: named in Settings as needing an update.
    var incompatibleBridgePlugins: [BridgeSource] { bridgeSources.filter { !$0.compatible } }

    /// Accepts an injected list so a disappearing input or output can be checked without unplugging hardware.
    func refreshDevices(using available: [InputDevice]) {
        if available.map(\.id) != devices.map(\.id) {
            DiagnosticLog.event("Devices: \(available.filter { !$0.output }.count) inputs, \(available.filter(\.output).count) outputs")
        }
        devices = available
        let savedUID = UserDefaults.standard.string(forKey: "inputDeviceUID")
        let savedOutput = UserDefaults.standard.bool(forKey: "inputDeviceIsOutput")
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
        } else if !running && wantsCapture {
            requestPermissionAndStart()
        }
    }

    func select(_ id: SourceID) {
        if id.isNone {
            UserDefaults.standard.set("", forKey: "inputDeviceUID")
            UserDefaults.standard.set(id.output, forKey: "inputDeviceIsOutput")
        }
        if selectedID == id {
            if id.isNone { status = .noSelection }
            return
        }
        guard id.isNone || devices.contains(where: { $0.id == id }) else { return }
        selectedID = id
        if let device = devices.first(where: { $0.id == id }), !device.uid.isEmpty {
            UserDefaults.standard.set(device.uid, forKey: "inputDeviceUID")
            UserDefaults.standard.set(device.output, forKey: "inputDeviceIsOutput")
            if device.isBridge { UserDefaults.standard.set(device.name, forKey: Self.bridgeNameKey) }
        }
        // The person's choice: remembered with its context, and final (no longer provisional or ambiguous).
        bridgeProvisionalUntil = nil
        bridgeClaimSeen = nil
        bridgeCandidates = []
        if let session = id.bridge, let source = bridgeSources.first(where: { $0.sessionKey == session }) {
            remember(source)
        } else if id.bridge == nil {
            bridgeSaved = nil
        }
        loadAssignment()
        if wantsCapture { requestPermissionAndStart() }
    }

    func assign(role: Int, source: Int32) {
        guard speakerLayout.contains(role),
              source == -1 || (source >= 0 && source < Int32(min(selectedDevice?.channels ?? 0, 64))) else { return }
        sourceForRole[role] = source
        activeRoles[role] = source >= 0
        saveAssignment()
        if wantsCapture { restart() }
    }

    var selectedDevice: InputDevice? { devices.first(where: { $0.id == selectedID }) }

    private var deviceKey: String { selectedDevice?.key ?? (selectedID.output ? "none.output" : "none.input") }
    private func assignmentKey() -> String { "assign.\(deviceKey).\(speakerLayout.rawValue)" }

    /// Restores this device's routing for the current layout. Without one, input n feeds the layout's n-th
    /// role in SMPTE order; 5.1.2 also accepts the eight-role routing saved by 1.0.
    private func loadAssignment() {
        let count = Int(min(selectedDevice?.channels ?? 0, 64))
        var routing = [Int32](repeating: -1, count: Role.count)
        for (index, role) in speakerLayout.roles.enumerated() where index < count { routing[role] = Int32(index) }
        let legacy = speakerLayout == .s512 ? UserDefaults.standard.array(forKey: "assign.\(deviceKey)") as? [Int] : nil
        if let saved = UserDefaults.standard.array(forKey: assignmentKey()) as? [Int] ?? legacy {
            for (role, source) in saved.enumerated() where role < Role.count {
                routing[role] = source >= 0 && source < count ? Int32(source) : -1
            }
        }
        for role in 0..<Role.count where !speakerLayout.contains(role) { routing[role] = -1 }
        sourceForRole = routing
        activeRoles = routing.map { $0 >= 0 }
    }

    private func saveAssignment() { UserDefaults.standard.set(sourceForRole.map(Int.init), forKey: assignmentKey()) }

    /// The routing `resetAssignment` restores for the current device and layout: input n to the n-th role.
    var defaultAssignment: [Int32] {
        let count = Int(min(selectedDevice?.channels ?? 0, 64))
        var routing = [Int32](repeating: -1, count: Role.count)
        for (index, role) in speakerLayout.roles.enumerated() where index < count { routing[role] = Int32(index) }
        return routing
    }

    /// Routes every role of the current layout at once (Settings ▸ Apply): one save and one capture restart,
    /// where `assign(role:source:)` restarts per role. Sources the device does not have, and roles outside the
    /// layout, are switched off.
    func assign(routing: [Int32]) {
        let count = Int32(min(selectedDevice?.channels ?? 0, 64))
        var next = [Int32](repeating: -1, count: Role.count)
        for role in 0..<min(Role.count, routing.count) where speakerLayout.contains(role) {
            next[role] = routing[role] >= 0 && routing[role] < count ? routing[role] : -1
        }
        guard next != sourceForRole else { return }
        sourceForRole = next
        activeRoles = next.map { $0 >= 0 }
        saveAssignment()
        if wantsCapture { restart() }
    }

    /// Puts the current layout back to input n → n-th role.
    func resetAssignment() {
        UserDefaults.standard.removeObject(forKey: assignmentKey())
        if speakerLayout == .s512 { UserDefaults.standard.removeObject(forKey: "assign.\(deviceKey)") }
        loadAssignment()
        if wantsCapture && running && demoStart == nil { restart() }
    }

    func resume() {
        wantsCapture = true
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
        // A DAW plugin's receiver writes into the same ring as a device: it stops first, and the plugin stops
        // sending while paused. Its lost frames so far stay in the count.
        let pausedBridge = attachedBridge
        if let session = attachedBridge?.session, let source = bridgeSources.first(where: { $0.sessionKey == session }) {
            droppedBefore += source.framesLost &- bridgeLostBase
        }
        bridge?.detach()
        attachedBridge = nil
        bridge?.select(nil)
        // Capture stops before its final counter is read and the ring is cleared. The 10 Hz readout can
        // lag behind the last callback, so carrying its displayed count would lose recent drops.
        droppedBefore += capture?.stop() ?? 0
        droppedFrames = droppedBefore
        paused = PausedSession(source: selectedID, sources: capturedSources, roles: routedRoles, time: CACurrentMediaTime(),
                               bridge: pausedBridge)
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
                            layout: speakerLayout.name)
        Diagnostics.log("Capture resumed: \(status.text)")
        return true
    }

    /// The DAW plugin counterpart: the same live insert, in the same format and routing, subscribes again and its
    /// audio flows into the waiting analysis. As with a device, the time paused is left out and nothing is reset.
    private func continuePausedBridge() -> Bool {
        guard let session = paused, let format = session.bridge, let worker, let capture, let bridge,
              let device = selectedDevice, device.id == session.source, capturedSources == session.sources,
              routedRoles == session.roles,
              let source = bridgeSources.first(where: { $0.sessionKey == format.session && $0.compatible }),
              source.formatEpoch == format.epoch, source.channels == format.channels, source.sampleRate == sampleRate
        else { return false }
        bridge.select(source.session)
        bridge.attach(epoch: format.epoch, ring: capture.ring, sourceForRole: capturedSources, markStart: false)
        attachedBridge = format
        bridgeAttachedAt = Date()
        bridgeLostBase = source.framesLost
        worker.resume()
        captureChannels = format.channels
        carryOn(after: CACurrentMediaTime() - session.time)
        status = .bridge(name: source.label(among: bridgeSources), condition: shownCondition(source),
                         channels: source.channels, layout: speakerLayout.name)
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
        frozen = false
        silentOutput = false
        droppedBefore = 0
        paused = nil
        demoStart = nil
        hardwareObserver?.watch(nil)
        // The ring's producer goes first (the bridge thread or the device), then its consumer.
        bridge?.detach()
        attachedBridge = nil
        worker?.stop()
        worker = nil
        capture?.stop()
        running = false
    }

    private func requestPermissionAndStart() {
        guard let selectedDevice else {
            stop()
            snapshot = MeterSnapshot()
            clearMeasurements()
            if selectedID.bridge != nil {
                // A DAW plugin that is not connected (yet): `pollBridge` starts it when it appears.
                status = .bridge(name: waitingBridgeName, condition: waitingForLaunch ? .connecting : .disconnected,
                             channels: 0, layout: speakerLayout.name)
                return
            }
            bridge?.select(nil)
            status = UserDefaults.standard.string(forKey: "inputDeviceUID") == "" ? .noSelection : .noDevice
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
        bridge?.select(nil)
        do {
            try capture.start(device: device, sourceForRole: capturedSources)
            streamID = streamID == 1_000_000 ? 1 : streamID + 1
            guard let worker = DSPWorker(ring: capture.ring, sampleRate: capture.sampleRate, streamID: streamID,
                                         activeRoles: routedRoles, detector: makeDetector()) else {
                capture.stop()
                status = .dspFailed
                return
            }
            worker.setSpatialSpectrum(format == .spatial)
            self.worker = worker
            sampleRate = capture.sampleRate
            captureChannels = Int(capture.channels)
            captureStarted = Date()
            droppedFrames = 0
            running = true
            if !device.uid.isEmpty {
                UserDefaults.standard.set(device.uid, forKey: "inputDeviceUID")
                UserDefaults.standard.set(device.output, forKey: "inputDeviceIsOutput")
            }
            hardwareObserver?.watch(device.device)
            DiagnosticLog.event(String(format: "Stream: %.0f Hz, %d ch", capture.sampleRate, Int(capture.channels)))
            status = .capturing(device: device.name, output: device.output, channels: Int(capture.channels),
                                layout: speakerLayout.name)
            Diagnostics.log("Capture started: \(status.text)")
        } catch {
            status = .failure(StatusMessage { error.localizedDescription })
            Diagnostics.log("Capture error: \(status.text)")
        }
    }

    // MARK: DAW Bridge

    /// Name shown while the selected DAW plugin is away: the name it had when chosen.
    private var waitingBridgeName: String {
        [bridgeSaved?.name, UserDefaults.standard.string(forKey: Self.bridgeNameKey)].compactMap { $0 }
            .first { !$0.isEmpty } ?? L("DAW plugin")
    }

    /// Launched by a plugin and still waiting for it (no insert known yet).
    private var waitingForLaunch: Bool { selectedID.bridge == SourceID.waitingPrefix }

    /// Diagnostics: breaks the selected insert's connection, as a failure would; the plugin reconnects by itself.
    func dropBridgeConnection() {
        guard let session = selectedID.bridge, let source = bridgeSources.first(where: { $0.sessionKey == session }) else { return }
        bridge?.disconnect(source.session, refusingFor: 1_500)
    }

    /// Remembers `source` as the chosen insert, with its current context (kept up to date while it is bound).
    private func remember(_ source: BridgeSource) {
        var selection = BridgeSelection(source.candidate,
                                        knownCopies: bridgeSaved?.persistent == source.persistentKey ? bridgeSaved?.knownCopies : nil)
        if selection.noteCopies(among: bridgeSources.filter(\.compatible).map(\.candidate)) {
            DiagnosticLog.event("DAW plugin \"\(source.displayName)\" was copied; the copy is known not to be it")
        }
        guard selection != bridgeSaved else { return }
        bridgeSaved = selection
        selection.save()
        UserDefaults.standard.set(bridgeUIDPrefix + source.persistentKey, forKey: "inputDeviceUID")
        UserDefaults.standard.set(false, forKey: "inputDeviceIsOutput")
        UserDefaults.standard.set(source.displayName, forKey: Self.bridgeNameKey)
    }

    /// One click in a plugin window ("Show in / Open Auraliscope Labs"): select that insert, resume if paused, and
    /// bring the meter window forward. It is the person's choice, as in the source list.
    private func followFocusRequests() {
        for source in bridgeSources where source.compatible && source.focusRequests > focusHandled[source.sessionKey, default: 0] {
            focusHandled[source.sessionKey] = source.focusRequests
            DiagnosticLog.event("DAW plugin \"\(source.displayName)\" asked to be shown")
            let id = SourceID(device: 0, bridge: source.sessionKey)
            if !wantsCapture { wantsCapture = true }
            if selectedID != id { select(id) } else if !running { restart() }
            NSApp.activate(ignoringOtherApps: true)
            MainWindow.window?.makeKeyAndOrderFront(nil)
        }
        let live = Set(bridgeSources.map(\.sessionKey))
        focusHandled = focusHandled.filter { live.contains($0.key) }
    }

    /// The condition for the status line; just after attaching, a live source counts as streaming until its first
    /// audio has had time to arrive.
    private func shownCondition(_ source: BridgeSource) -> BridgeCondition {
        let condition = BridgeCondition(source)
        let settling = Date().timeIntervalSince(bridgeAttachedAt) < BridgeCondition.staleAudio
        return condition == .noAudio && settling && source.secondsSinceAudio == nil ? .streaming : condition
    }

    /// Starts analysis of a DAW plugin instance: a new pipeline at the plugin's own sample rate, then the
    /// receiver writes that instance's audio into the ring. Every format change comes back through here, so the
    /// analyzers are always configured for exactly the audio they receive.
    private func startBridge(_ device: InputDevice, capture: AudioCapture) {
        guard let bridge else {
            status = .failure(StatusMessage { L("DAW plugin receiver unavailable: %@", self.bridgeError ?? "") })
            return
        }
        guard let source = bridgeSources.first(where: { $0.sessionKey == device.bridgeSession && $0.compatible }) else {
            status = .bridge(name: device.name, condition: .disconnected, channels: 0, layout: speakerLayout.name)
            return
        }
        bridge.select(source.session)
        guard source.hasUsableFormat else {
            // Subscribed, so it streams as soon as it has a format; `pollBridge` restarts then.
            status = .bridge(name: source.label(among: bridgeSources), condition: BridgeCondition(source),
                             channels: source.channels, layout: speakerLayout.name)
            return
        }
        streamID = streamID == 1_000_000 ? 1 : streamID + 1
        guard let worker = DSPWorker(ring: capture.ring, sampleRate: source.sampleRate, streamID: streamID,
                                     activeRoles: routedRoles, detector: makeDetector()) else {
            status = .dspFailed
            return
        }
        worker.setSpatialSpectrum(format == .spatial)
        self.worker = worker
        channel_ring_clear(capture.ring)
        // A fresh analysis: nothing before its first block to break from.
        bridge.attach(epoch: source.formatEpoch, ring: capture.ring, sourceForRole: capturedSources, markStart: false)
        attachedBridge = (source.sessionKey, source.formatEpoch, source.channels)
        bridgeAttachedAt = Date()
        bridgeLostBase = source.framesLost
        sampleRate = source.sampleRate
        captureChannels = source.channels
        captureStarted = Date()
        droppedFrames = 0
        running = true
        remember(source)
        DiagnosticLog.event(String(format: "DAW plugin stream: %.0f Hz, %d ch, %@ %@ in %@", source.sampleRate,
                                   source.channels, source.plugin, source.pluginVersion, source.hostName))
        status = .bridge(name: source.label(among: bridgeSources), condition: shownCondition(source),
                         channels: source.channels, layout: speakerLayout.name)
        Diagnostics.log("DAW plugin capture started: \(status.text)")
    }

    /// Five times a second: picks up plugin instances that came or went, follows the selected one through
    /// format changes, disconnection and return, finds the saved insert again, and keeps the status current.
    private func pollBridge() {
        guard let bridge else { return }
        bridgeSources = bridge.sources()
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
        if let until = bridgeProvisionalUntil {
            if Date() > until {
                bridgeProvisionalUntil = nil
            } else if let saved = bridgeSaved {
                let decision = BridgeRestoration.decide(for: saved, among: bridgeSources.filter(\.compatible).map(\.candidate),
                                                        matchingSession: false)
                if case let .ambiguous(sessions) = decision {
                    // Another insert claiming the saved one arrived after the automatic choice: it no longer holds.
                    DiagnosticLog.event("DAW plugin choice became ambiguous: \(sessions.count) inserts claim \"\(saved.name)\"")
                    becomeAmbiguous(sessions, saved: saved)
                    return
                }
            }
        }
        if bridgeProvisionalUntil == nil { remember(source) }
        logBreaks(source)
        if let attached = attachedBridge {
            // Reconfigure whenever the audio the receiver would deliver no longer matches the pipeline.
            if attached.session != source.sessionKey || attached.epoch != source.formatEpoch || attached.channels != source.channels {
                DiagnosticLog.event(String(format: "DAW plugin format changed: %.0f Hz, %d ch; analysis restarted",
                                           source.sampleRate, source.channels))
                if attached.channels != source.channels { loadAssignment() }
                restart()
                return
            }
        } else if source.hasUsableFormat {
            if selectedDevice?.channels != UInt32(source.channels) { loadAssignment() }
            restart()
            return
        }
        let next = MeterStatus.bridge(name: source.label(among: bridgeSources), condition: shownCondition(source),
                                      channels: source.channels, layout: speakerLayout.name)
        if status != next { status = next }
    }

    /// Writes each new break in the bound insert's delivered audio to the diagnostic log, with its reasons (only the
    /// newest is known when several arrive between two refreshes).
    private func logBreaks(_ source: BridgeSource) {
        guard let logged = breaksLogged, logged.session == source.sessionKey else {
            breaksLogged = (source.sessionKey, source.discontinuities)
            return
        }
        guard source.discontinuities > logged.count else { return }
        DiagnosticLog.event(String(format: "DAW plugin \"%@\": %llu break(s) (newest: %@; %llu frames missing; idle %u ms; timeline jumps %u)",
                                   source.displayName, source.discontinuities - logged.count, source.lastBreakReasonNames,
                                   source.lastBreakLostFrames, source.lastBreakIdleMs, source.transportJumps))
        breaksLogged = (source.sessionKey, source.discontinuities)
    }

    /// Nothing bound is connected: the bound insert went away (its analysis waits for the same live insert), or
    /// the saved one has yet to appear, or several could be it. See `BridgeRestoration` for the rules.
    private func findSaved() {
        let waiting = MeterStatus.bridge(name: waitingBridgeName,
                                         condition: waitingForLaunch ? .connecting : attachedBridge != nil ? .disconnectedHeld : .disconnected,
                                         channels: 0, layout: speakerLayout.name)
        // Launched by a plugin's button: its request selects the insert; the saved one is not restored meanwhile.
        guard !waitingForLaunch, let saved = bridgeSaved else {
            if status != waiting { status = waiting }
            return
        }
        let candidates = bridgeSources.filter(\.compatible)
        switch BridgeRestoration.decide(for: saved, among: candidates.map(\.candidate)) {
        case let .bind(session):
            guard let source = candidates.first(where: { $0.sessionKey == session }) else { return }
            if session == saved.session {
                // The same live insert: Auraliscope Labs restarted, or its connection came back.
                bind(source, provisional: false)
                return
            }
            // A new instance of the saved insert (the project reopened, the plugin reloaded). A project still
            // loading may bring more claimants, so the choice waits a moment, and stays provisional after that.
            let now = Date()
            if bridgeClaimSeen == nil { bridgeClaimSeen = now }
            if now.timeIntervalSince(bridgeClaimSeen!) < Self.restorationSettle {
                if status != waiting { status = waiting }
                return
            }
            bind(source, provisional: true)
        case .wait:
            bridgeClaimSeen = nil
            if !bridgeCandidates.isEmpty { bridgeCandidates = [] }
            if status != waiting { status = waiting }
        case let .ambiguous(sessions):
            bridgeClaimSeen = nil
            if sessions != bridgeCandidates || attachedBridge != nil { becomeAmbiguous(sessions, saved: saved) }
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
        bridgeClaimSeen = nil
        bridgeProvisionalUntil = provisional ? Date().addingTimeInterval(Self.provisionalSpan) : nil
        if !provisional { remember(source) }
        if continuing {
            status = .bridge(name: source.label(among: bridgeSources), condition: shownCondition(source),
                             channels: source.channels, layout: speakerLayout.name)
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
        bridge?.select(nil)
        bridgeProvisionalUntil = nil
        bridgeCandidates = sessions
        selectedID = SourceID(device: 0, bridge: SourceID.waitingPrefix + saved.persistent)
        status = .bridge(name: waitingBridgeName, condition: .ambiguous(sessions.count), channels: 0,
                         layout: speakerLayout.name)
    }
}
