import AVFoundation
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
        source.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / MeterPipeline.tickRate)), leeway: .milliseconds(1))
        source.setEventHandler {
            batch.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                // Bounded work even if the producer remains active while draining.
                for _ in 0..<8 {
                    let count = channel_ring_read(ring, base, UInt32(buffer.count))
                    if count == 0 { break }
                    if !receivedPCM {
                        Diagnostics.log("Received PCM: \(count) multichannel frames on DSP queue")
                        receivedPCM = true
                    }
                    pipeline.consume(UnsafeBufferPointer(start: base, count: Int(count)))
                }
            }
            pipeline.spatialSpectrum = meter_exchange_mode(exchange) != 0
            values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: CACurrentMediaTime()) }
            if !receivedSignal && pipeline.newestPeak > 0.000001 {
                Diagnostics.log("Nonzero audio signal confirmed")
                receivedSignal = true
            }
            meter_exchange_publish(exchange, values)
        }
        timer = source
        source.resume()
    }

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
        s.detectedFormat = v[SnapshotSlots.format]
        s.correlation = v[SnapshotSlots.correlation]
        s.waveSerial = v[SnapshotSlots.waveSerial]
        s.spectrogram = Array(v[SnapshotSlots.spectrogram..<(SnapshotSlots.spectrogram + MeterSnapshot.spectrogramBandCount)])
        s.waveform = Array(v[SnapshotSlots.waveform..<SnapshotSlots.total])
        return s
    }

    func stop() {
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
    case chooseInput, waitingForPermission, permissionDenied, paused, ringFailed, noDevice, noSelection, dspFailed, demo
    case capturing(device: String, output: Bool, channels: Int, layout: String)
    case failure(StatusMessage)

    /// Rendered on demand so a language switch also updates the current message.
    var text: String {
        switch self {
        case .chooseInput: return L("Choose an input device")
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
        case let .failure(message): return message.text
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
    @Published private(set) var status = MeterStatus.chooseInput
    @Published private(set) var running = false
    @Published private(set) var sampleRate: Double = 48_000
    @Published private(set) var droppedFrames: UInt64 = 0
    /// Bumped by "reset": clears peak holds, clip latches and (via restart) integrated loudness.
    @Published private(set) var epoch = 0
    /// Auto follows the routing and the DSP-side detector; Mono / Stereo / Spatial pin the display.
    @Published var formatMode: FormatMode {
        didSet {
            UserDefaults.standard.set(formatMode.rawValue, forKey: "formatMode")
            // Mono measures a single input, so entering or leaving it restarts the stream (like a routing change).
            let wasMono = (oldValue.fixed ?? automaticFormat) == .mono
            if wasMono != (format == .mono) && wantsCapture && running && demoStart == nil { restart() }
        }
    }
    @Published private(set) var detectedFormat = ChannelFormat.stereo
    var format: ChannelFormat { formatMode.fixed ?? automaticFormat }

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

    /// Auto: a lone routed input (L on, R and every positional channel off) is Mono; otherwise the detector decides.
    var automaticFormat: ChannelFormat {
        let lone = demoStart == nil && sourceForRole[Role.left] >= 0 && sourceForRole[Role.right] < 0
            && !Role.evidence.contains { sourceForRole[$0] >= 0 }
        return lone ? .mono : detectedFormat
    }

    /// Clicking a mode pins it; the AUTO toggle hands control back to the detector.
    func pin(_ format: ChannelFormat) { formatMode = FormatMode(format) }
    func toggleAuto() { formatMode = formatMode == .auto ? FormatMode(format) : .auto }
    private(set) var captureStarted: Date?
    private(set) var captureChannels = 0
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

    deinit {
        worker?.stop()
        capture?.stop()
    }

    init() {
        speakerLayout = UserDefaults.standard.string(forKey: "speakerLayout").flatMap(SpeakerLayout.init(rawValue:)) ?? .standard
        let savedMode = UserDefaults.standard.string(forKey: "formatMode")
        // 2.0 stored the pinned multichannel mode as "surround".
        formatMode = savedMode == "surround" ? .spatial : FormatMode(rawValue: savedMode ?? "") ?? .auto
        devices = AudioDevices.availableSources()
        let defaultID = AudioDevices.defaultInputID()
        let savedUID = UserDefaults.standard.string(forKey: "inputDeviceUID")
        let savedOutput = UserDefaults.standard.bool(forKey: "inputDeviceIsOutput")
        let requested = devices.first { !$0.output && $0.device == Diagnostics.requestedDeviceID }
        let saved = devices.first { !$0.uid.isEmpty && $0.uid == savedUID && $0.output == savedOutput }
        let systemDefault = devices.first { !$0.output && $0.device == defaultID }
        if let requested {
            selectedID = requested.id
        } else if savedUID != nil {
            // An explicit empty UID means "no device". A missing saved device waits for that same source
            // to return instead of silently switching the meter to another input or output.
            selectedID = saved?.id ?? (savedOutput ? .noOutput : .none)
        } else {
            selectedID = (systemDefault ?? devices.first)?.id ?? .none
        }
        loadAssignment()
        readouts.attach(to: self)
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
        return CanvasFrame(snapshot: pollSnapshot(), sampleRate: sampleRate, running: running,
                    activeRoles: routedRoles, epoch: epoch, spatial: format == .spatial, mono: format == .mono,
                    layout: speakerLayout)
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
        Diagnostics.log("Detected format: \(detected == .spatial ? "spatial" : "stereo")")
    }

    /// Carries the current decision into a new stream so a restart does not replay the transition.
    private func makeDetector() -> FormatDetector {
        FormatDetector(initial: detectedFormat,
                       canDetectSpatial: FormatDetector.evidenceRoles.contains { sourceForRole[$0] >= 0 })
    }

    /// Called at the readout rate rather than per frame.
    func refreshDroppedFrames() {
        let dropped = capture.map { channel_ring_dropped($0.ring) } ?? 0
        if dropped != droppedFrames { droppedFrames = dropped }
    }

    func resetMeasurements() {
        if running && demoStart == nil { restart(); return }
        clearMeasurements()
        if running { captureStarted = Date() }
    }

    private func clearMeasurements() {
        epoch += 1
        readouts.reset()
    }

    var formatSummary: String {
        guard running else { return "\(Int(sampleRate / 1000)) kHz" }
        let rate = sampleRate.truncatingRemainder(dividingBy: 1000) == 0
            ? "\(Int(sampleRate / 1000))" : String(format: "%.1f", sampleRate / 1000)
        return "\(rate) kHz · \(captureChannels) ch · \(format == .spatial ? speakerLayout.name : (format == .mono ? "1.0" : "2.0"))"
    }

    func reportRendererError(_ message: StatusMessage) {
        stop()
        status = .failure(message)
    }

    func refreshDevices() {
        refreshDevices(using: AudioDevices.availableSources())
    }

    /// Accepts an injected list so a disappearing input or output can be checked without unplugging hardware.
    func refreshDevices(using available: [InputDevice]) {
        devices = available
        let savedUID = UserDefaults.standard.string(forKey: "inputDeviceUID")
        let savedOutput = UserDefaults.standard.bool(forKey: "inputDeviceIsOutput")
        let restored = savedUID.flatMap { uid in
            uid.isEmpty ? nil : devices.first { !$0.uid.isEmpty && $0.uid == uid && $0.output == savedOutput }
        }
        if !selectedID.isNone && !devices.contains(where: { $0.id == selectedID }) {
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
            startDemo()
            return
        }
        requestPermissionAndStart()
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
        if running {
            wantsCapture = false
            stop()
            snapshot = MeterSnapshot()
            status = .paused
        } else { resume() }
    }

    func stop() {
        demoStart = nil
        hardwareObserver?.watch(nil)
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
            status = UserDefaults.standard.string(forKey: "inputDeviceUID") == "" ? .noSelection : .noDevice
            return
        }
        // Core Audio taps ask for System Audio Recording when the output aggregate begins capture.
        // Microphone authorization is only needed for a physical or virtual input source.
        if selectedDevice.output { restart(); return }
        guard !permissionPending else { return }
        Diagnostics.log("Microphone authorization: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: restart()
        case .notDetermined:
            permissionPending = true
            status = .waitingForPermission
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.permissionPending = false
                    if granted && self.wantsCapture { self.restart() }
                    else { self.status = .permissionDenied }
                }
            }
        default:
            stop()
            status = .permissionDenied
        }
    }

    private func restart() {
        guard selectedDevice?.output == true || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        stop()
        snapshot = MeterSnapshot()
        clearMeasurements()
        guard let capture else { status = .ringFailed; return }
        guard let device = devices.first(where: { $0.id == selectedID }) else { status = .noDevice; return }
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
            status = .capturing(device: device.name, output: device.output, channels: Int(capture.channels),
                                layout: speakerLayout.name)
            Diagnostics.log("Capture started: \(status.text)")
        } catch {
            status = .failure(StatusMessage { error.localizedDescription })
            Diagnostics.log("Capture error: \(status.text)")
        }
    }
}
