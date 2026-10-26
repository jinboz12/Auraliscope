import AnalysisCore
import AppKit
import AudioRing
import BridgeTransport
import Foundation

/// `--test-model-lifecycle` (QA bundle only): what the model shows and does as capture starts, pauses, resumes, switches
/// source and fails, checked with no device and no DAW. The app's own model is built with stand-ins for everything
/// outside the process (`MeterModelDependencies`): two output devices that are never opened, a capture whose ring
/// nothing fills, a recording analysis per stream and a DAW plugin receiver. Launch, the window's start and the 10 Hz
/// readouts run as usual. Each step checks the model's state (status, live or paused, sample rate, drops, routing,
/// saved settings) and the order in which it stopped and started capture and analysis (`Journal`).
///
/// The QA preference domain is emptied before the model is built, so launch takes the first device, and restored at
/// the end, also after a failure. Exits 0 when every check passes.
enum ModelLifecycleSelfTest {
    static let requested = CommandLine.arguments.contains("--test-model-lifecycle")

    /// What the stand-ins were asked to do, in order.
    final class Journal {
        private(set) var events: [String] = []
        var mark: Int { events.count }
        func note(_ event: String) { events.append(event) }
        /// Capture and analysis events since `mark`.
        func lifecycle(since mark: Int) -> [String] {
            events[mark...].filter { $0.hasPrefix("capture.") || $0.hasPrefix("worker.") }
        }
    }

    /// A capture that opens nothing: its ring stays empty, so the analysis reads silence. A start can be made to fail
    /// or to find another sample rate, and a stop to report frames lost after the last callback. Its ring is kept as
    /// the real capture keeps it: a start or stop clears it, a restart does not. What its IO callback saw (`reading`)
    /// is set by the checks; opening or closing the IO clears it, as the real record is.
    final class Capture: CaptureBackend {
        let ring: OpaquePointer
        private(set) var sampleRate = 48_000.0
        private(set) var channels: UInt32 = 0
        var rateAtNextStart = 48_000.0
        var failNextStart = false
        var failNextRestart = false
        var dropsAtNextStop: UInt64 = 0
        var reading = CaptureHealthReading()
        private let journal: Journal

        init?(journal: Journal) {
            guard let ring = channel_ring_create(1024) else { return nil }
            self.ring = ring
            self.journal = journal
        }

        func start(device: InputDevice, sourceForRole: [Int32]) throws {
            journal.note("capture.start \(device.uid) \(ModelLifecycleSelfTest.routing(sourceForRole))")
            channel_ring_clear(ring)
            reading = CaptureHealthReading()
            if failNextStart {
                failNextStart = false
                throw Refusal()
            }
            sampleRate = rateAtNextStart
            channels = device.channels
        }

        func restart(device: InputDevice, sourceForRole: [Int32], minimumFrames: UInt32) throws {
            journal.note("capture.restart \(device.uid) \(ModelLifecycleSelfTest.routing(sourceForRole)) \(minimumFrames)")
            reading = CaptureHealthReading()
            if failNextRestart {
                failNextRestart = false
                throw Refusal()
            }
            sampleRate = rateAtNextStart
            channels = device.channels
        }

        func stop() -> UInt64 {
            journal.note("capture.stop")
            reading = CaptureHealthReading()
            defer { dropsAtNextStop = 0 }
            let dropped = channel_ring_dropped(ring) + dropsAtNextStop
            channel_ring_clear(ring)
            return dropped
        }

        func health() -> CaptureHealthReading { reading }
    }

    struct Refusal: LocalizedError {
        var errorDescription: String? { "QA capture refused" }
    }

    /// The analysis of one stream: records what the model asked of it.
    final class Worker: MeterWorker {
        let stream: UInt32
        private let journal: Journal
        private(set) var spatialSpectrum: [Bool] = []
        private(set) var spectrogramModes: [SpectrogramMode] = []
        private(set) var legacy: [LegacySTFT] = []
        /// Every Multi-FFT configuration it was given (nil: stop the engine).
        private(set) var multiFFTConfigurations: [MultiFFTConfiguration?] = []
        var multiFFTActive: Bool { (multiFFTConfigurations.last ?? nil) != nil }

        init(stream: UInt32, journal: Journal) {
            self.stream = stream
            self.journal = journal
            journal.note("worker.make \(stream)")
        }

        func latest() -> MeterSnapshot? { nil }
        func pause() { journal.note("worker.pause \(stream)") }
        func resume() { journal.note("worker.resume \(stream)") }
        func stop() { journal.note("worker.stop \(stream)") }
        func resetTruePeaks() { journal.note("worker.resetTruePeaks \(stream)") }
        func setSpatialSpectrum(_ spatial: Bool) { spatialSpectrum.append(spatial) }
        func setSpectrogramMode(_ mode: SpectrogramMode) { spectrogramModes.append(mode) }
        func setSpatialField(threshold: Float, geometry: SpatialGeometry) {}
        func setMultiFFT(_ configuration: MultiFFTConfiguration?) { multiFFTConfigurations.append(configuration) }
        func latestMultiFFT(frozen: Bool) -> MultiFFTSnapshot? { nil }
        func setLegacySTFT(_ choice: LegacySTFT) { legacy.append(choice) }
    }

    /// A DAW plugin receiver with the plugins the test lists; records selections, attachments and commands.
    final class Receiver: BridgeReceiving {
        var plugins: [AbrSourceInfo] = []
        private(set) var selected: [UInt8]?
        private(set) var commands: [Int32] = []
        /// Every command with its target: "<code> <session>".
        private(set) var sent: [String] = []
        private(set) var spectrogram: SpectrogramMode?
        private(set) var everyChannel: Bool?
        private(set) var coherence: Float?
        private(set) var spatialRevision: UInt32?
        private var commandID: UInt32 = 0
        private let journal: Journal

        init(journal: Journal) { self.journal = journal }

        func sources() -> [BridgeSource] { plugins.map(BridgeSource.init) }
        func select(_ session: [UInt8]?) {
            selected = session
            journal.note("bridge.select \(session.map(BridgeSource.hex) ?? "none")")
        }
        func setSpectrogram(_ mode: SpectrogramMode) { spectrogram = mode }
        func setSpectrum(everyChannel: Bool) { self.everyChannel = everyChannel }
        func setCoherence(_ threshold: Float) { coherence = threshold }
        func setSpatial(_ geometry: SpatialGeometry) { spatialRevision = geometry.revision }
        func attach(_ inbox: ResultInbox) { journal.note("bridge.attach") }
        func detach() { journal.note("bridge.detach") }
        func command(_ session: [UInt8], _ command: Int32, generation: UInt32) -> UInt32 {
            commandID += 1
            commands.append(command)
            sent.append("\(command) \(BridgeSource.hex(session))")
            journal.note("bridge.command \(command)")
            return commandID
        }
        func disconnect(_ session: [UInt8], refusingFor milliseconds: UInt32) { journal.note("bridge.disconnect") }
    }

    static let journal = Journal()
    static let capture = Capture(journal: journal)
    static let receiver = Receiver(journal: journal)
    static let outputA = InputDevice(device: 0x7A00_0001, name: "QA Output A", channels: 2, uid: "qa.lifecycle.a", output: true)
    static let outputB = InputDevice(device: 0x7A00_0002, name: "QA Output B", channels: 8, uid: "qa.lifecycle.b", output: true)
    /// The devices Core Audio would list.
    static var deviceList = [outputA, outputB]
    /// The model's clock: moved by the checks alone, so whatever waits on it is decided without waiting.
    static var clock: CFTimeInterval = 1_000
    static var failNextWorker = false
    /// Every analysis the model made, in order.
    static var workers: [Worker] = []
    private static var savedDomain: [String: Any]?
    private static var started = false

    /// "role>input" for each routed role, e.g. "0>0,1>1".
    static func routing(_ sourceForRole: [Int32]) -> String {
        sourceForRole.enumerated().filter { $0.element >= 0 }.map { "\($0.offset)>\($0.element)" }.joined(separator: ",")
    }

    /// A connected DAW plugin insert as the receiver reports it: a live VST3 in REAPER, streaming, with every command
    /// and the speaker geometry. Its identities are 16 copies of one byte; stereo unless `roles` name each channel's
    /// speaker; a copy (`copyOf`) carries the identity its saved state had.
    static func plugin(session: UInt8, persistent: UInt8, name: String, copyOf: UInt8? = nil, roles: [Int] = [],
                       epoch: UInt32 = 1, compatible: Bool = true, focusRequests: UInt32 = 0, dropped: UInt64 = 0,
                       spatialAnswer: (revision: UInt32, outcome: UInt32)? = nil) -> AbrSourceInfo {
        func fill<T>(_ field: inout T, with byte: UInt8) {
            withUnsafeMutableBytes(of: &field) { raw in for index in raw.indices { raw[index] = byte } }
        }
        func write<T>(_ text: String, into field: inout T) {
            withUnsafeMutableBytes(of: &field) { raw in
                let bytes = Array(text.utf8.prefix(raw.count - 1))
                for (index, byte) in bytes.enumerated() { raw[index] = byte }
                raw[bytes.count] = 0
            }
        }
        var info = AbrSourceInfo()
        fill(&info.session_id, with: session)
        fill(&info.persistent_id, with: persistent)
        info.identity_flags = UInt32(ABR_IDENTITY_RESTORED)
        if let copyOf {
            fill(&info.restored_id, with: copyOf)
            info.identity_flags |= UInt32(ABR_IDENTITY_COPY)
        }
        info.protocol_version = UInt32(ABR_PROTOCOL_VERSION)
        info.compatible = compatible ? 1 : 0
        info.plugin_format = UInt32(ABR_FORMAT_VST3)
        info.capabilities = UInt32(ABR_CAPABILITY_RESULTS | ABR_CAPABILITY_RESET | ABR_CAPABILITY_RESET_TRUE_PEAK
                                   | ABR_CAPABILITY_PAUSE | ABR_CAPABILITY_SPATIAL_CONFIG)
        write("REAPER", into: &info.host_name)
        write("com.cockos.reaper", into: &info.host_bundle_id)
        write("2.0", into: &info.plugin_version)
        write(name, into: &info.source_name)
        info.state = UInt32(ABR_STATE_LIVE)
        info.format_epoch = epoch
        info.sample_rate = 48_000
        info.channels = roles.isEmpty ? 2 : UInt32(roles.count)
        info.role_count = UInt32(roles.count)
        withUnsafeMutableBytes(of: &info.roles) { raw in for (index, role) in roles.enumerated() { raw[index] = UInt8(role) } }
        write(roles.isEmpty ? "Stereo" : "\(roles.count) ch", into: &info.layout_name)
        info.generation = 1
        info.measurement = UInt32(ABR_MEASUREMENT_MEASURING)
        info.plugin_seconds_since_audio = 0.01
        info.seconds_since_message = 0.05
        info.seconds_since_result = -1
        info.focus_requests = focusRequests
        info.frames_dropped_by_plugin = dropped
        if let spatialAnswer {
            info.spatial_acks_received = 1
            info.spatial_ack_revision = spatialAnswer.revision
            info.spatial_ack_outcome = spatialAnswer.outcome
        }
        return info
    }

    /// The stand-ins the app builds its model with when the test is requested (nil otherwise). Empties the QA
    /// preference domain first, keeping it for the end.
    @MainActor
    static func dependencies() -> MeterModelDependencies? {
        guard requested, let domain = Bundle.main.bundleIdentifier, domain.hasSuffix(".QA") else { return nil }
        if savedDomain == nil {
            savedDomain = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
            UserDefaults.standard.setPersistentDomain([:], forName: domain)
        }
        return MeterModelDependencies(
            makeCapture: { capture },
            startReceiver: { .success(receiver) },
            availableSources: { deviceList },
            observesHardware: false,
            makeLocalWorker: { _, _, stream, _, _ in
                if failNextWorker {
                    failNextWorker = false
                    return nil
                }
                let worker = Worker(stream: stream, journal: journal)
                workers.append(worker)
                return worker
            },
            clock: { clock })
    }

    private static func restoreDomain() {
        guard let savedDomain, let domain = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.setPersistentDomain(savedDomain, forName: domain)
        UserDefaults.standard.synchronize()
    }

    /// Runs once, from the model built with the stand-ins, after the window has started it.
    @MainActor
    static func runIfRequested(model: MeterModel) {
        guard requested, savedDomain != nil, !started else { return }
        started = true
        Task { @MainActor in await run(model) }
    }

    @MainActor
    private static func run(_ model: MeterModel) async {
        func check(_ condition: Bool, _ message: String) {
            guard condition else {
                fputs("FAIL: \(message)\n", stderr)
                fputs("status: \(model.status.logDescription)\njournal: \(journal.events.suffix(12).joined(separator: " | "))\n", stderr)
                restoreDomain()
                exit(1)
            }
            print("PASS: \(message)")
            fflush(stdout)
        }
        func settle(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func until(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while !condition() && Date() < end { await settle(0.05) }
            return condition()
        }
        func capturing(_ device: InputDevice) -> Bool {
            if case let .capturing(name, output, channels, _) = model.status {
                return name == device.name && output == device.output && channels == Int(device.channels)
            }
            return false
        }
        func stream() -> String { "\(model.captureGeneration)" }
        func start(_ device: InputDevice) -> String { "capture.start \(device.uid) \(routing(model.sourceForRole))" }
        guard let capture else { return check(false, "the stand-in capture has a ring") }

        // Launch: fresh settings take the first device, and the window starts it.
        let launched = await until(5) { model.running }
        check(launched && model.selectedID == outputA.id && capturing(outputA),
              "launch with fresh settings takes the first device and captures it")
        check(journal.lifecycle(since: 0) == ["capture.stop", start(outputA), "worker.make 1"],
              "launch stops any capture, then starts the device's capture before its analysis")
        model.pin(.stereo)

        // Pause holds the analysis and the picture; resume carries on with the same analysis.
        var mark = journal.mark
        capture.dropsAtNextStop = 7
        let generation = model.captureGeneration
        model.toggleCapture()
        check(!model.running && model.frozen && model.status == .paused, "pause holds the picture: not live, frozen, Paused")
        check(journal.lifecycle(since: mark) == ["worker.pause 1", "capture.stop"],
              "pause holds the analysis, then stops the capture")
        check(model.droppedFrames == 7, "frames the capture lost before it stopped are counted at the pause")
        check(model.captureActionTitle == L("Resume Capture"), "the capture button offers to resume the paused analysis")
        mark = journal.mark
        model.toggleCapture()
        check(model.running && !model.frozen && model.captureGeneration == generation && capturing(outputA),
              "resume carries on with the same analysis: live, no new stream")
        check(journal.lifecycle(since: mark) == [start(outputA), "worker.resume 1"],
              "resume starts the capture again, then lets the waiting analysis continue")
        await settle(0.35)
        check(model.droppedFrames == 7, "drops counted before the pause stay counted after resume")

        // A device whose rate changed while paused: the analysis starts afresh at the new rate.
        capture.dropsAtNextStop = 3
        model.toggleCapture()
        check(model.droppedFrames == 10, "a second pause adds the frames lost at its own stop")
        capture.rateAtNextStart = 44_100
        mark = journal.mark
        model.toggleCapture()
        check(model.running && model.captureGeneration == generation + 1 && model.sampleRate == 44_100,
              "resume after the device's rate changed starts a new analysis at the new rate")
        check(journal.lifecycle(since: mark) == [start(outputA), "capture.stop", "worker.stop 1", "capture.stop",
                                                 start(outputA), "worker.make 2"],
              "the capture that came back at another rate is stopped, then the old analysis, then a fresh start")
        await settle(0.35)
        check(model.droppedFrames == 0, "a new analysis counts its drops afresh")
        capture.rateAtNextStart = 48_000

        // Reset while paused lets go of the held picture; resume then starts afresh.
        model.toggleCapture()
        let epoch = model.epoch
        mark = journal.mark
        model.resetMeasurements()
        check(!model.running && !model.frozen && model.status == .standby && model.epoch == epoch + 1,
              "reset while paused lets go of the picture: standby, not frozen, measurements cleared")
        check(journal.lifecycle(since: mark) == ["worker.stop 2", "capture.stop"], "reset while paused stops the waiting analysis")
        check(model.captureActionTitle == L("Start Capture"), "after that reset the capture button starts afresh")
        mark = journal.mark
        model.toggleCapture()
        check(model.running && journal.lifecycle(since: mark) == ["capture.stop", start(outputA), "worker.make 3"],
              "start after a reset makes a fresh analysis")

        // Another source chosen while paused: nothing starts until resume, which starts afresh on it.
        model.toggleCapture()
        mark = journal.mark
        model.select(outputB.id)
        check(model.selectedID == outputB.id && model.status == .paused && journal.lifecycle(since: mark).isEmpty,
              "choosing another source while paused changes the selection only")
        check(UserDefaults.standard.string(forKey: MeterModel.inputDeviceUIDKey) == outputB.uid
              && UserDefaults.standard.bool(forKey: MeterModel.inputDeviceIsOutputKey),
              "the chosen source is saved")
        mark = journal.mark
        model.toggleCapture()
        check(model.running && capturing(outputB) && journal.lifecycle(since: mark) == ["worker.stop 3", "capture.stop",
                                                                                         start(outputB), "worker.make 4"],
              "resume on another source stops the paused analysis and starts afresh there")

        // Switching the running source.
        mark = journal.mark
        model.select(outputA.id)
        check(capturing(outputA) && journal.lifecycle(since: mark) == ["worker.stop 4", "capture.stop", start(outputA), "worker.make 5"],
              "switching the running source stops its analysis and capture before starting the new ones")

        // Routing and channel order: a routing applied in film order is captured, saved per device and format, and
        // found again after another device was measured.
        model.select(outputB.id)
        model.speakerLayout = .s51
        let film = model.filmAssignment, smpte = model.smpteAssignment
        check(film != smpte && model.sourceForRole == smpte, "a device with no saved routing takes SMPTE order")
        mark = journal.mark
        model.assign(routing: film)
        check(model.sourceForRole == film && journal.lifecycle(since: mark).contains(start(outputB))
              && journal.lifecycle(since: mark).last == "worker.make \(stream())",
              "a routing applied in film order restarts capture with that channel order")
        check((UserDefaults.standard.array(forKey: "assign.\(outputB.key).5.1") as? [Int]) == film.map(Int.init),
              "the routing is saved for this device and format")
        model.select(outputA.id)
        check(model.sourceForRole == model.smpteAssignment, "another device keeps its own routing")
        model.select(outputB.id)
        check(model.sourceForRole == film && journal.events.last(where: { $0.hasPrefix("capture.start") }) == start(outputB),
              "the saved channel order is found again and captured")

        // Routing by hand: a role outside the format and an input the device lacks are refused; a routing applied at
        // once keeps only the format's roles and the device's inputs; an unchanged one restarts nothing.
        let routedBefore = model.sourceForRole
        mark = journal.mark
        model.assign(role: Role.leftTopFront, source: 3)
        model.assign(role: Role.center, source: Int32(outputB.channels))
        check(model.sourceForRole == routedBefore && journal.lifecycle(since: mark).isEmpty,
              "a role outside the format and an input the device lacks are refused, with no restart")
        model.assign(role: Role.center, source: 7)
        check(model.sourceForRole[Role.center] == 7 && journal.lifecycle(since: mark).last == "worker.make \(stream())"
              && (UserDefaults.standard.array(forKey: "assign.\(outputB.key).5.1") as? [Int])?[Role.center] == 7,
              "a role routed by hand is saved and restarts capture")
        var applied = [Int32](repeating: -1, count: Role.count)
        applied[Role.left] = 0; applied[Role.right] = Int32(outputB.channels); applied[Role.leftTopFront] = 2; applied[Role.center] = 1
        model.assign(routing: applied)
        check(model.sourceForRole[Role.left] == 0 && model.sourceForRole[Role.right] == -1
              && model.sourceForRole[Role.leftTopFront] == -1 && model.sourceForRole[Role.center] == 1,
              "a routing applied at once keeps the format's roles and the device's inputs only")
        mark = journal.mark
        model.assign(routing: model.sourceForRole)
        check(journal.lifecycle(since: mark).isEmpty, "applying the routing already in use restarts nothing")
        model.assign(routing: film)

        // 5.1.2 also takes the eight-role routing 1.0 saved under the device alone, while nothing newer is saved; no
        // other format does.
        UserDefaults.standard.set([7, 6, 5, 4, 3, 2, 1, 0], forKey: "assign.\(outputB.key)")
        model.speakerLayout = .s512
        check(Array(model.sourceForRole[0..<8]) == [7, 6, 5, 4, 3, 2, 1, 0], "5.1.2 takes the routing 1.0 saved for the device")
        model.speakerLayout = .s514
        check(model.sourceForRole == model.smpteAssignment, "another format ignores 1.0's routing and takes SMPTE order")
        UserDefaults.standard.removeObject(forKey: "assign.\(outputB.key)")

        // VST3 order (Nuendo, Cubase), distinct from SMPTE and film order in 7.1.4, is captured as applied.
        model.speakerLayout = .s714
        let vst3 = model.vst3Assignment
        check(vst3 != model.smpteAssignment && vst3 != model.filmAssignment, "7.1.4's VST3 order differs from SMPTE and film order")
        model.assign(routing: vst3)
        check(model.sourceForRole == vst3 && journal.events.last(where: { $0.hasPrefix("capture.start") }) == start(outputB),
              "a routing applied in VST3 order is captured in that order")
        model.speakerLayout = .s51
        check(model.sourceForRole == film, "back in 5.1 the routing saved for 5.1 returns")
        model.monoEnabled = true
        mark = journal.mark
        model.pin(.mono)
        check(model.routedRoles == (0..<Role.count).map { $0 == Role.left && film[$0] >= 0 }
              && journal.lifecycle(since: mark).contains("capture.start \(outputB.uid) \(Role.left)>\(film[Role.left])"),
              "Mono restarts capture with the input routed to L alone")
        model.pin(.stereo)
        model.monoEnabled = false
        check(model.running && capturing(outputB), "leaving Mono measures the routed inputs again")

        // Settings reach a new analysis: at once whether the spectrum is spatial, and the spectrogram's at its first frame.
        UserDefaults.standard.set(SpectrogramAnalysis.enhanced.rawValue, forKey: SpectrogramAnalysis.key)
        await settle(0.3)
        model.select(outputA.id)
        guard let fresh = workers.last else { return check(false, "an analysis was made") }
        check(fresh.spatialSpectrum.first == false, "a new analysis is told at once that a stereo spectrum is not spatial")
        _ = model.canvasFrame()
        check(fresh.spectrogramModes.last == .enhanced && fresh.legacy.last == .legacy,
              "the next frame passes the chosen spectrogram analysis to the new analysis")
        UserDefaults.standard.removeObject(forKey: SpectrogramAnalysis.key)
        await settle(0.3)

        // Multi-FFT follows a restart, and stops after its delay when the format leaves stereo.
        let placement = PanelPlacement.shared
        placement.setShown(.multiFFT, true)
        model.multiFFTPanelVisible(true)
        model.select(outputB.id)
        guard let engine = workers.last else { return check(false, "an analysis was made") }
        check(engine.multiFFTActive, "a new analysis of a stereo device starts the Multi-FFT engine while its panel shows")
        model.pin(.spatial)
        await settle(MeterModel.multiFFTTeardownDelay + 0.4)
        check(!engine.multiFFTActive && model.running, "Immersive stops the Multi-FFT engine after its delay, capture continuing")
        model.pin(.stereo)
        _ = model.canvasFrame()
        check(engine.multiFFTActive, "back in stereo the same analysis starts the engine again")

        // Settings: a changed Multi-FFT configuration reaches the running engine; the shared STFT chosen in Settings
        // feeds a classic stereo spectrogram, and Immersive uses the reassigned analysis instead.
        MultiFFTPreferences.save(.make(.economy))
        await settle(0.3)
        _ = model.canvasFrame()
        check((engine.multiFFTConfigurations.last ?? nil) == MultiFFTPreferences.stored && MultiFFTPreferences.stored.preset == .economy,
              "a changed Multi-FFT setting reaches the running engine")
        UserDefaults.standard.set(LegacySTFT.shared8192.rawValue, forKey: MultiFFTPreferences.legacyKey)
        await settle(0.3)
        _ = model.canvasFrame()
        check(engine.legacy.last == .shared8192, "the shared STFT chosen in Settings feeds the classic stereo spectrogram")
        model.pin(.spatial)
        _ = model.canvasFrame()
        check(engine.legacy.last == .legacy, "Immersive uses the reassigned analysis rather than the shared STFT")
        model.pin(.stereo)
        UserDefaults.standard.removeObject(forKey: MultiFFTPreferences.legacyKey)
        UserDefaults.standard.removeObject(forKey: MultiFFTPreferences.key)
        await settle(0.3)

        // The delayed stop goes to the analysis running when it fires: the panel hidden, then a restart at once.
        placement.setShown(.multiFFT, false)
        model.multiFFTPanelVisible(false)
        _ = model.canvasFrame()
        let callsBefore = engine.multiFFTConfigurations.count
        model.select(outputA.id)
        guard let next = workers.last, next !== engine else { return check(false, "a new analysis was made") }
        check(next.multiFFTConfigurations.isEmpty, "a new analysis is not given an engine its panel no longer shows")
        await settle(MeterModel.multiFFTTeardownDelay + 0.4)
        check(engine.multiFFTConfigurations.count == callsBefore && next.multiFFTConfigurations.first == .some(nil)
              && !next.multiFFTActive,
              "the engine's delayed stop goes to the analysis running when it fires, never to the stopped one")
        model.select(outputB.id)

        // A device that disappears stops capture; the saved one coming back is measured again.
        let lost = stream()
        deviceList = [outputA]
        mark = journal.mark
        model.refreshDevices()
        check(!model.running && model.selectedID == .noOutput && model.status == .noDevice
              && journal.lifecycle(since: mark) == ["worker.stop \(lost)", "capture.stop"],
              "a measured device that disappears stops analysis and capture; the status says no device")
        deviceList = [outputA, outputB]
        model.refreshDevices()
        check(model.running && model.selectedID == outputB.id && capturing(outputB), "the saved device coming back is measured again")

        // Failures: a capture that cannot start, an analysis that cannot be made; each recovers on the next start.
        capture.failNextStart = true
        mark = journal.mark
        let failed = stream()
        model.select(outputA.id)
        if case let .failure(message) = model.status {
            check(message.text == "QA capture refused", "a capture that cannot start shows its error")
        } else {
            check(false, "a capture that cannot start shows its error")
        }
        check(!model.running && journal.lifecycle(since: mark) == ["worker.stop \(failed)", "capture.stop", start(outputA)],
              "no analysis is made for a capture that did not start")
        model.resume()
        check(model.running && capturing(outputA), "the next start after a capture failure measures again")
        failNextWorker = true
        mark = journal.mark
        let replaced = stream()
        model.select(outputB.id)
        check(model.status == .dspFailed && !model.running
              && journal.lifecycle(since: mark) == ["worker.stop \(replaced)", "capture.stop", start(outputB), "capture.stop"],
              "an analysis that cannot be made releases the capture just started and says so")
        model.resume()
        check(model.running && capturing(outputB), "the next start after an analyzer failure measures again")

        // Stop ends the analysis, then the capture; the next start is fresh.
        mark = journal.mark
        let stopped = stream()
        model.stop()
        check(!model.running && journal.lifecycle(since: mark) == ["worker.stop \(stopped)", "capture.stop"],
              "stop ends the analysis, then the capture")
        model.resume()
        check(model.running && stream() != stopped && capturing(outputB), "start after a stop makes a fresh analysis")

        await checkPlugins(model, check: check, until: until, settle: settle)
        await checkPluginPause(model, check: check, until: until, settle: settle)
        await checkTransitions(model, check: check, until: until, settle: settle)

        restoreDomain()
        print("PASS: model lifecycle checks complete")
        fflush(stdout)
        exit(0)
    }

    /// DAW plugin sources: waiting, connection, the plugin's own results, commands, format changes, disconnection and
    /// return, finding the saved insert again (and when that is ambiguous), focus requests, and back to a device.
    @MainActor
    private static func checkPlugins(_ model: MeterModel, check: (Bool, String) -> Void,
                                     until: (Double, () -> Bool) async -> Bool, settle: (Double) async -> Void) async {
        func key(_ info: AbrSourceInfo) -> String { BridgeSource(info).sessionKey }
        func device(_ info: AbrSourceInfo) -> InputDevice? { model.devices.first { $0.bridgeSession == key(info) } }
        func condition() -> BridgeCondition? {
            if case let .bridge(_, condition, _, _) = model.status { return condition }
            return nil
        }
        func command(_ code: Int) -> Int32 { Int32(code) }
        func subscriptions(since mark: Int) -> [String] {
            journal.events[mark...].filter { $0.hasPrefix("bridge.select") || $0 == "bridge.attach" || $0.hasPrefix("capture.start")
                || $0.hasPrefix("worker.make") }
        }

        // Host plugins chosen with nothing connected: the device's capture stops, and the model waits.
        var mark = journal.mark
        let local = model.captureGeneration
        model.select(.anyPlugin)
        check(!model.running && condition() == .connecting
              && journal.lifecycle(since: mark) == ["worker.stop \(local)", "capture.stop"],
              "Host plugins with no insert connected stops the device's capture and waits for one")
        check(UserDefaults.standard.string(forKey: MeterModel.inputDeviceUIDKey) == bridgeUIDPrefix,
              "Host plugins is saved as the source type")
        let bus = plugin(session: 0x11, persistent: 0xA1, name: "QA Bus")
        receiver.plugins = [bus]
        check(await until(1) { device(bus) != nil && condition() == .unchosen },
              "a plugin that connects is listed as a source, and the model waits for the person to choose it")
        check(model.preferredPluginSource() == device(bus)?.id, "the only connected insert is the one Host plugins offers")
        guard let busDevice = device(bus) else { return check(false, "the plugin is listed") }

        // Choosing it: the plugin analyses, the display shows its results.
        mark = journal.mark
        model.select(busDevice.id)
        let results = model.captureGeneration
        check(model.running && condition() == .streaming && model.showingBridgeResults && results == local + 1,
              "choosing the insert shows its own results: live, streaming, no local analysis")
        check(subscriptions(since: mark) == ["bridge.select \(key(bus))", "bridge.attach"],
              "the receiver subscribes to the insert, then its results are attached; no device capture starts")
        check(UserDefaults.standard.string(forKey: MeterModel.inputDeviceUIDKey) == bridgeUIDPrefix + BridgeSource(bus).persistentKey
              && BridgeSelection.load()?.persistent == BridgeSource(bus).persistentKey,
              "the insert is saved with its context, to be found again")

        // Each frame passes the display's settings to the plugin.
        _ = model.canvasFrame()
        check(receiver.spectrogram == .classic && receiver.everyChannel == false
              && receiver.coherence == model.displayOptions.nebula.threshold
              && receiver.spatialRevision == model.displayGeometry(for: model.shownLayout).revision,
              "each frame passes the spectrogram, the spectrum mode, the coherence and the speaker geometry to the plugin")
        model.pin(.spatial)
        _ = model.canvasFrame()
        check(receiver.everyChannel == true, "Immersive asks the plugin for every channel's spectrum")
        model.pin(.stereo)
        check(!PanelPlacement.shared.dockSupportsMultiFFT && model.multiFFTFrame() == nil,
              "a plugin source has no Multi-FFT: the Dock offers none and no frame is drawn")

        // Pause, resume and resets are the plugin's: commands, with the same results stream.
        model.toggleCapture()
        check(!model.running && model.frozen && model.status == .paused && receiver.commands.last == command(ABR_COMMAND_PAUSE),
              "pause sends the plugin a pause command and holds the picture")
        model.toggleCapture()
        check(model.running && condition() == .streaming && receiver.commands.last == command(ABR_COMMAND_RESUME)
              && model.captureGeneration == results,
              "resume sends a resume command and carries on with the same results stream")
        let epoch = model.epoch
        model.resetMeasurements()
        check(model.epoch == epoch + 1 && model.running && model.captureGeneration == results
              && receiver.commands.last == command(ABR_COMMAND_RESET),
              "reset asks the plugin to measure afresh, without restarting the stream here")
        let peaks = model.truePeakEpoch
        model.resetTruePeak()
        check(model.truePeakEpoch == peaks + 1 && receiver.commands.last == command(ABR_COMMAND_RESET_TRUE_PEAK),
              "a true-peak reset is sent to the plugin")

        // Frames the plugin's own analysis dropped count from the moment its results were attached.
        receiver.plugins = [plugin(session: 0x11, persistent: 0xA1, name: "QA Bus", dropped: 6)]
        check(await until(1) { model.droppedFrames == 6 } && model.captureGeneration == results,
              "frames the plugin's analysis dropped are counted, on the same results stream")

        // A plugin that refuses the user's speaker layout is sent the standard one, and the panel says so.
        let configured = SpeakerLayoutStore.shared.geometry(for: model.shownLayout, nebula: model.displayOptions.nebula)
        _ = model.canvasFrame()
        check(receiver.spatialRevision == configured.revision && model.geometryNotice == nil,
              "the plugin is sent the user's speaker layout")
        receiver.plugins = [plugin(session: 0x11, persistent: 0xA1, name: "QA Bus", dropped: 6,
                                   spatialAnswer: (configured.revision, SpatialConfigWire.Outcome.invalid.rawValue))]
        await settle(0.4)
        _ = model.canvasFrame()
        check(model.geometryNotice == .pluginRefused && receiver.spatialRevision == configured.revision ^ 0x8000_0000
              && model.displayGeometry(for: model.shownLayout).revision == configured.revision ^ 0x8000_0000,
              "a plugin that refuses the layout is sent the standard one, a revision apart, with a notice in the panel")

        // Diagnostics can break the bound insert's connection, as a failure would.
        let disconnects = journal.events.filter { $0 == "bridge.disconnect" }.count
        model.dropBridgeConnection()
        check(journal.events.filter { $0 == "bridge.disconnect" }.count == disconnects + 1,
              "a diagnostic disconnect reaches the receiver for the bound insert")

        // A format change restarts the results stream, its drops counted afresh; a disconnection holds it for the same
        // insert's return.
        let formatChanged = plugin(session: 0x11, persistent: 0xA1, name: "QA Bus", epoch: 2, dropped: 6)
        receiver.plugins = [formatChanged]
        check(await until(1) { model.captureGeneration == results + 1 } && model.running && condition() == .streaming,
              "a format change in the plugin restarts its results stream")
        check(await until(1) { model.droppedFrames == 0 }, "the plugin's earlier drops are not counted against the new stream")
        let held = model.captureGeneration
        receiver.plugins = []
        check(await until(1) { condition() == .disconnectedHeld } && model.running && model.captureGeneration == held,
              "an insert that disconnects holds its analysis for its return")
        receiver.plugins = [formatChanged]
        check(await until(1) { condition() == .streaming } && model.captureGeneration == held,
              "the same live insert returning carries on with the held analysis")

        // The saved insert reopened beside a copy of it: ambiguous until the person chooses.
        receiver.plugins = []
        _ = await until(1) { condition() == .disconnectedHeld }
        let reopened = plugin(session: 0x12, persistent: 0xA1, name: "QA Bus")
        let copy = plugin(session: 0x13, persistent: 0xA2, name: "QA Bus", copyOf: 0xA1)
        receiver.plugins = [reopened, copy]
        check(await until(1.5) { condition() == .ambiguous(2) } && !model.running && model.bridgeCandidates.count == 2
              && receiver.selected == nil,
              "the saved insert reopened beside a copy of it is ambiguous: nothing is analysed, nothing subscribed")
        await settle(0.6)
        check(condition() == .ambiguous(2) && !model.running, "it stays ambiguous while nothing changes")
        guard let chosen = device(copy) else { return check(false, "the copy is listed") }
        model.select(chosen.id)
        check(model.running && condition() == .streaming && model.bridgeCandidates.isEmpty && model.selectedID == chosen.id,
              "the person's choice ends the ambiguity and is measured")

        // The saved insert found again alone, as a new instance: bound after a moment, provisionally.
        receiver.plugins = []
        _ = await until(1) { condition() == .disconnectedHeld }
        let returned = plugin(session: 0x14, persistent: 0xA2, name: "QA Bus")
        receiver.plugins = [returned]
        await settle(0.5)
        check(condition() == .disconnectedHeld && model.selectedID.bridge != key(returned),
              "a new instance of the saved insert is not taken at once: restoration waits for others to load")
        check(await until(2) { model.selectedID.bridge == key(returned) && model.running && condition() == .streaming },
              "the saved insert found again as a new instance is measured after that moment")
        check(BridgeSelection.load()?.session == key(copy),
              "a provisional choice is not saved: the saved insert is still the one the person chose")
        let copyOfReturned = plugin(session: 0x15, persistent: 0xA3, name: "QA Bus", copyOf: 0xA2)
        receiver.plugins = [returned, copyOfReturned]
        check(await until(1) { condition() == .ambiguous(2) } && !model.running,
              "a copy appearing while that choice is provisional makes it ambiguous again")
        // Ambiguous until something tells the inserts apart: polls past the settle delay bind neither by themselves.
        await settle(1.6)
        check(condition() == .ambiguous(2) && !model.running && receiver.selected == nil
              && model.bridgeCandidates == [key(returned), key(copyOfReturned)]
              && BridgeSelection.load()?.session == key(copy),
              "the ambiguity holds: neither insert is bound again by itself, and the saved choice is unchanged")
        // The copy going away leaves one insert claiming the saved identity: found again, provisionally.
        receiver.plugins = [returned]
        check(await until(2.5) { model.selectedID.bridge == key(returned) && model.running && condition() == .streaming }
              && model.bridgeCandidates.isEmpty,
              "once the copy goes away, the only insert claiming the saved identity is found again")
        // Its connection dropping and coming back within the provisional span: the analysis carries on, and the choice
        // stays provisional (a copy appearing then still makes it ambiguous).
        let provisionalStream = model.captureGeneration
        receiver.plugins = []
        _ = await until(1) { condition() == .disconnectedHeld }
        receiver.plugins = [returned]
        check(await until(2.5) { condition() == .streaming } && model.running && model.captureGeneration == provisionalStream,
              "a provisional insert whose connection comes back carries on with its analysis")
        receiver.plugins = [returned, copyOfReturned]
        check(await until(1) { condition() == .ambiguous(2) } && !model.running,
              "its return does not make the choice final: a copy appearing then makes it ambiguous")
        // The person's choice ends it, for good: the copy is then known not to be it.
        guard let returnedDevice = device(returned) else { return check(false, "the found insert is listed") }
        model.select(returnedDevice.id)
        check(model.running && condition() == .streaming && model.bridgeCandidates.isEmpty
              && BridgeSelection.load()?.session == key(returned)
              && BridgeSelection.load()?.knownCopies == [BridgeSource(copyOfReturned).persistentKey],
              "choosing one of the ambiguous inserts measures it and saves it, the copy known not to be it")
        await settle(0.6)
        check(model.running && model.selectedID == returnedDevice.id, "the person's choice holds beside the copy")

        // A click in another plugin's window selects that insert, from a pause too.
        let other = plugin(session: 0x16, persistent: 0xA4, name: "QA Other")
        receiver.plugins = [returned, copyOfReturned, other]
        _ = await until(1) { device(other) != nil }
        model.toggleCapture()
        let pausedAt = receiver.sent.count
        check(receiver.commands.last == command(ABR_COMMAND_PAUSE), "the chosen insert's measurement is paused")
        receiver.plugins = [returned, copyOfReturned, plugin(session: 0x16, persistent: 0xA4, name: "QA Other", focusRequests: 1)]
        check(await until(1) { model.selectedID.bridge == key(other) && model.running && condition() == .streaming },
              "a click in a plugin's window selects that insert and measures it, even from a pause")
        check(Array(receiver.sent[pausedAt...]) == ["\(ABR_COMMAND_RESUME) \(key(returned))"],
              "leaving the paused insert for another resumes its measurement, once")

        // A plugin of another protocol version, and an immersive bus.
        let old = plugin(session: 0x17, persistent: 0xA5, name: "QA Old", compatible: false)
        let surround = plugin(session: 0x18, persistent: 0xA6, name: "QA 5.1",
                              roles: [Role.left, Role.center, Role.right, Role.leftSurround, Role.rightSurround, Role.lfe])
        receiver.plugins = [other, old, surround]
        check(await until(1) { model.incompatibleBridgePlugins.count == 1 && device(surround) != nil } && device(old) == nil,
              "a plugin of another protocol version is named as needing an update, never offered as a source")
        guard let surroundDevice = device(surround) else { return check(false, "the immersive insert is listed") }
        model.select(surroundDevice.id)
        let film = [Role.left, Role.center, Role.right, Role.leftSurround, Role.rightSurround, Role.lfe]
        check(model.running && model.layoutFromPlugin && model.shownLayout == .s51
              && film.enumerated().allSatisfy { model.sourceForRole[$0.element] == Int32($0.offset) },
              "an immersive bus is drawn in its own format, each channel routed to the speaker it reports, in the bus's order")

        // A copy appearing while its original is bound is known not to be it: when the original returns as a new
        // instance beside that copy, it is found again (after the settle delay), not ambiguous. Once the provisional span
        // has passed, a new copy no longer makes that choice ambiguous either.
        let keeper = plugin(session: 0x21, persistent: 0xB1, name: "QA Keep")
        receiver.plugins = [keeper]
        _ = await until(1) { device(keeper) != nil }
        guard let keeperDevice = device(keeper) else { return check(false, "the insert is listed") }
        model.select(keeperDevice.id)
        let duplicate = plugin(session: 0x22, persistent: 0xB2, name: "QA Keep", copyOf: 0xB1)
        receiver.plugins = [keeper, duplicate]
        check(await until(1) { BridgeSelection.load()?.knownCopies == [BridgeSource(duplicate).persistentKey] }
              && model.running && model.selectedID == keeperDevice.id,
              "a copy appearing while its original is bound is remembered as not being it")
        receiver.plugins = [duplicate]
        _ = await until(1) { condition() == .disconnectedHeld }
        let reloaded = plugin(session: 0x23, persistent: 0xB1, name: "QA Keep")
        receiver.plugins = [reloaded, duplicate]
        check(await until(2.5) { model.selectedID.bridge == key(reloaded) && model.running } && model.bridgeCandidates.isEmpty
              && BridgeSelection.load()?.session == key(keeper),
              "the saved insert returning beside a known copy is found again, not ambiguous (provisionally, not yet saved)")
        await settle(5.3)
        let later = plugin(session: 0x24, persistent: 0xB3, name: "QA Keep", copyOf: 0xB1)
        receiver.plugins = [reloaded, duplicate, later]
        await settle(0.8)
        check(model.selectedID.bridge == key(reloaded) && model.running && model.bridgeCandidates.isEmpty
              && BridgeSelection.load()?.session == key(reloaded)
              && BridgeSelection.load()?.knownCopies?.contains(BridgeSource(later).persistentKey) == true,
              "after the provisional span the found insert is saved, and a new copy no longer makes it ambiguous but is remembered")

        // Back to Audio devices: the device chosen last, captured locally, the plugin unsubscribed.
        let back = model.preferredDeviceSource()
        mark = journal.mark
        model.select(back)
        check(back == outputB.id && model.running && receiver.selected == nil && !model.showingBridgeResults
              && journal.events[mark...].contains("bridge.select none")
              && journal.lifecycle(since: mark).suffix(2) == ["capture.start \(outputB.uid) \(routing(model.sourceForRole))",
                                                              "worker.make \(model.captureGeneration)"],
              "Audio devices takes the device chosen last: the plugin is unsubscribed and the device captured")
        receiver.plugins = []
    }

    /// A DAW plugin's measurement paused from here is this display's to resume: on the same insert when its paused
    /// analysis carries on, or once when that paused analysis is let go (another source, a fresh start, stop), and
    /// only when the pause reached the plugin. Commands and their order are read from the receiver.
    @MainActor
    private static func checkPluginPause(_ model: MeterModel, check: (Bool, String) -> Void,
                                         until: (Double, () -> Bool) async -> Bool, settle: (Double) async -> Void) async {
        func key(_ info: AbrSourceInfo) -> String { BridgeSource(info).sessionKey }
        func device(_ info: AbrSourceInfo) -> InputDevice? { model.devices.first { $0.bridgeSession == key(info) } }
        func condition() -> BridgeCondition? {
            if case let .bridge(_, condition, _, _) = model.status { return condition }
            return nil
        }
        func pause(_ info: AbrSourceInfo) -> String { "\(ABR_COMMAND_PAUSE) \(key(info))" }
        func resume(_ info: AbrSourceInfo) -> String { "\(ABR_COMMAND_RESUME) \(key(info))" }
        /// Whether the journal has `first` before `then` since `mark`.
        func ordered(since mark: Int, _ first: String, _ then: String) -> Bool {
            let events = Array(journal.events[mark...])
            guard let a = events.firstIndex(of: first), let b = events.firstIndex(of: then) else { return false }
            return a < b
        }

        let first = plugin(session: 0x31, persistent: 0xC1, name: "QA Pause A")
        let second = plugin(session: 0x32, persistent: 0xC2, name: "QA Pause B")
        receiver.plugins = [first, second]
        guard await until(1, { device(first) != nil && device(second) != nil }), let firstDevice = device(first),
              let secondDevice = device(second) else { return check(false, "the inserts are listed") }
        model.select(firstDevice.id)
        check(model.running && condition() == .streaming, "an insert chosen for the pause checks is measured")

        // The same insert: one pause, then one resume, on the same results stream.
        var mark = receiver.sent.count
        let stream = model.captureGeneration
        model.toggleCapture()
        model.toggleCapture()
        check(Array(receiver.sent[mark...]) == [pause(first), resume(first)] && model.running
              && model.captureGeneration == stream,
              "pause and resume on one insert send it one pause and one resume, on the same results stream")

        // Another insert chosen while paused: nothing is sent until capture starts there; then the paused insert is
        // resumed once, before the receiver subscribes to the other one.
        mark = receiver.sent.count
        var events = journal.mark
        model.toggleCapture()
        model.select(secondDevice.id)
        check(!model.running && Array(receiver.sent[mark...]) == [pause(first)],
              "choosing another insert while paused sends nothing more until capture starts")
        model.toggleCapture()
        check(model.running && condition() == .streaming && model.selectedID == secondDevice.id
              && Array(receiver.sent[mark...]) == [pause(first), resume(first)]
              && ordered(since: events, "bridge.command \(ABR_COMMAND_RESUME)", "bridge.select \(key(second))"),
              "starting on the other insert resumes the paused one once, before subscribing to the other")

        // Stop while paused resumes the insert once; a second stop sends nothing; the next start is fresh.
        mark = receiver.sent.count
        model.toggleCapture()
        model.stop()
        check(Array(receiver.sent[mark...]) == [pause(second), resume(second)] && !model.running,
              "stop while paused resumes the paused insert")
        model.stop()
        let fresh = model.captureGeneration
        model.resume()
        check(Array(receiver.sent[mark...]) == [pause(second), resume(second)] && model.running
              && model.captureGeneration == fresh + 1,
              "a second stop and the fresh start after it send no further resume")

        // The plugin's format changed while paused: resume starts afresh on it, and its measurement is resumed first.
        mark = receiver.sent.count
        events = journal.mark
        model.toggleCapture()
        let changed = plugin(session: 0x32, persistent: 0xC2, name: "QA Pause B", epoch: 2)
        receiver.plugins = [first, changed]
        await settle(0.4)
        let before = model.captureGeneration
        model.toggleCapture()
        check(model.running && condition() == .streaming && model.captureGeneration == before + 1
              && Array(receiver.sent[mark...]) == [pause(second), resume(second)]
              && ordered(since: events, "bridge.command \(ABR_COMMAND_RESUME)", "bridge.attach"),
              "resume after the plugin's format changed resumes its measurement, then starts a new results stream")

        // The paused insert's connection broke (the plugin resumes by itself): leaving it sends it nothing.
        mark = receiver.sent.count
        model.toggleCapture()
        receiver.plugins = [first]
        check(await until(1) { device(changed) == nil }, "the paused insert's connection is gone")
        model.select(firstDevice.id)
        model.toggleCapture()
        check(model.running && condition() == .streaming && model.selectedID == firstDevice.id
              && Array(receiver.sent[mark...]) == [pause(changed)],
              "a paused insert whose connection broke is sent nothing when it is left; the next source starts")

        // A pause that never reached the plugin (it was disconnected, its analysis held) is not undone by a resume
        // when the insert is left after it returns.
        receiver.plugins = []
        _ = await until(1) { condition() == .disconnectedHeld }
        mark = receiver.sent.count
        model.toggleCapture()
        check(!model.running && receiver.sent.count == mark, "pausing a disconnected insert sends it nothing")
        receiver.plugins = [first, changed]
        _ = await until(1) { device(first) != nil && device(changed) != nil }
        guard let changedDevice = device(changed) else { return check(false, "the insert is listed again") }
        model.select(changedDevice.id)
        model.toggleCapture()
        check(model.running && model.selectedID == changedDevice.id && receiver.sent.count == mark,
              "an insert whose pause never reached it is not sent a resume when it is left")

        model.select(outputB.id)
        receiver.plugins = []
        check(model.running && !model.showingBridgeResults, "back on the device after the pause checks")
    }

    /// Transitions back to back, as quick clicks or a host reloading make them: every analysis and capture started is
    /// stopped exactly once, nothing is subscribed or sent twice, and the model ends in the last state asked for.
    @MainActor
    private static func checkTransitions(_ model: MeterModel, check: (Bool, String) -> Void,
                                         until: (Double, () -> Bool) async -> Bool, settle: (Double) async -> Void) async {
        func key(_ info: AbrSourceInfo) -> String { BridgeSource(info).sessionKey }
        func device(_ info: AbrSourceInfo) -> InputDevice? { model.devices.first { $0.bridgeSession == key(info) } }
        func condition() -> BridgeCondition? {
            if case let .bridge(_, condition, _, _) = model.status { return condition }
            return nil
        }
        func capturing(_ device: InputDevice) -> Bool {
            if case let .capturing(name, output, channels, _) = model.status {
                return name == device.name && output == device.output && channels == Int(device.channels)
            }
            return false
        }
        func start(_ device: InputDevice) -> String { "capture.start \(device.uid) \(routing(model.sourceForRole))" }
        func count(_ prefix: String, since mark: Int) -> Int { journal.events[mark...].filter { $0.hasPrefix(prefix) }.count }
        /// The streams of the stand-in analyses made ("worker.make ") or stopped ("worker.stop ") since `mark`.
        func streams(_ prefix: String, since mark: Int) -> [UInt32] {
            journal.events[mark...].compactMap { $0.hasPrefix(prefix) ? UInt32($0.dropFirst(prefix.count)) : nil }
        }
        guard let capture else { return check(false, "the stand-in capture has a ring") }

        // Twenty quick switches between devices: each replaced analysis and capture is stopped once, before the next.
        model.select(outputB.id)
        var mark = journal.mark
        let first = model.captureGeneration
        for _ in 0..<10 {
            model.select(outputA.id)
            model.select(outputB.id)
        }
        var made = streams("worker.make ", since: mark)
        check(model.running && capturing(outputB) && made.count == 20 && made.last == model.captureGeneration
              && streams("worker.stop ", since: mark) == [first] + made.dropLast()
              && count("capture.start", since: mark) == 20 && count("capture.stop", since: mark) == 20,
              "twenty quick device switches stop each replaced analysis and capture once, and measure the last")

        // Ten pauses and resumes: the same analysis throughout, capture stopped and started once each time.
        mark = journal.mark
        let held = model.captureGeneration
        let dropped = model.droppedFrames
        for _ in 0..<10 {
            model.toggleCapture()
            model.toggleCapture()
        }
        let cycle = ["worker.pause \(held)", "capture.stop", start(outputB), "worker.resume \(held)"]
        check(model.running && capturing(outputB) && model.captureGeneration == held && model.droppedFrames == dropped
              && journal.lifecycle(since: mark) == Array((0..<10).map { _ in cycle }.joined()),
              "ten pauses and resumes carry on with one analysis, stopping and starting capture once each time")

        // Quick switches between a plugin and a device end on the last one, with no command sent to the plugin.
        let bus = plugin(session: 0x51, persistent: 0xE1, name: "QA Switch")
        receiver.plugins = [bus]
        guard await until(1, { device(bus) != nil }), let busDevice = device(bus) else {
            return check(false, "the insert is listed")
        }
        mark = journal.mark
        var sent = receiver.sent.count
        let deviceStream = model.captureGeneration
        for _ in 0..<5 {
            model.select(busDevice.id)
            model.select(outputA.id)
        }
        model.select(busDevice.id)
        made = streams("worker.make ", since: mark)
        check(model.running && condition() == .streaming && model.showingBridgeResults
              && receiver.selected.map(BridgeSource.hex) == key(bus) && made.count == 5
              && streams("worker.stop ", since: mark) == [deviceStream] + made
              && count("bridge.attach", since: mark) == 6 && count("capture.start", since: mark) == 5
              && receiver.sent.count == sent,
              "quick switches between a plugin and a device stop each device analysis once and end on the plugin")

        // Ten pauses and resumes of the plugin: one pause and one resume each, in order, on one results stream.
        mark = journal.mark
        sent = receiver.sent.count
        let results = model.captureGeneration
        for _ in 0..<10 {
            model.toggleCapture()
            model.toggleCapture()
        }
        let commands = ["\(ABR_COMMAND_PAUSE) \(key(bus))", "\(ABR_COMMAND_RESUME) \(key(bus))"]
        check(model.running && condition() == .streaming && model.captureGeneration == results
              && Array(receiver.sent[sent...]) == Array((0..<10).map { _ in commands }.joined())
              && count("bridge.select", since: mark) == 0 && count("bridge.attach", since: mark) == 0,
              "ten pauses and resumes of a plugin send one pause and one resume each, in order, on one results stream")

        // The insert's connection lost and back five times: the held analysis carries on, nothing subscribed or sent.
        mark = journal.mark
        sent = receiver.sent.count
        var cycles = 0
        for _ in 0..<5 {
            receiver.plugins = []
            let lost = await until(1) { condition() == .disconnectedHeld }
            receiver.plugins = [bus]
            let back = await until(1) { condition() == .streaming }
            if lost && back { cycles += 1 }
        }
        check(cycles == 5 && model.running && model.captureGeneration == results && receiver.sent.count == sent
              && count("bridge.select", since: mark) == 0 && count("bridge.attach", since: mark) == 0,
              "an insert lost and back five times carries on with its held analysis, with nothing subscribed or sent")

        // The project opened twice (two holders of the saved identity, no copy): ambiguous, and polls change nothing;
        // the saved live insert coming back ends it, as the same insert.
        receiver.plugins = []
        _ = await until(1) { condition() == .disconnectedHeld }
        let twinA = plugin(session: 0x52, persistent: 0xE1, name: "QA Switch")
        let twinB = plugin(session: 0x53, persistent: 0xE1, name: "QA Switch")
        receiver.plugins = [twinA, twinB]
        check(await until(1.5) { condition() == .ambiguous(2) } && !model.running && receiver.selected == nil
              && model.bridgeCandidates == [key(twinA), key(twinB)],
              "two holders of the saved identity are ambiguous: nothing analysed, nothing subscribed")
        mark = journal.mark
        sent = receiver.sent.count
        await settle(1.2)
        check(condition() == .ambiguous(2) && journal.mark == mark && receiver.sent.count == sent,
              "polls while ambiguous change nothing and ask nothing of the receiver")
        receiver.plugins = [twinA, twinB, bus]
        check(await until(1) { model.selectedID.bridge == key(bus) && model.running && condition() == .streaming }
              && model.bridgeCandidates.isEmpty && BridgeSelection.load()?.session == key(bus),
              "the saved live insert coming back ends the ambiguity: the same insert is measured again")

        // Starts that fail three times in a row, then one that works: nothing is left from the failures.
        mark = journal.mark
        capture.failNextStart = true
        model.select(outputA.id)
        for _ in 0..<2 {
            capture.failNextStart = true
            model.resume()
        }
        let failedThrice = !model.running
        model.resume()
        let attempt = ["capture.stop", start(outputA)]
        check(failedThrice && model.running && capturing(outputA)
              && journal.lifecycle(since: mark) == Array((0..<4).map { _ in attempt }.joined()) + ["worker.make \(model.captureGeneration)"],
              "three failed starts leave no analysis behind; the fourth measures with one new analysis")

        // Multi-FFT across quick switches: each new stereo analysis gets the engine while its panel shows; a plugin
        // gets none; the hidden panel's delayed stop goes only to the analysis running when it fires.
        let placement = PanelPlacement.shared
        placement.setShown(.multiFFT, true)
        model.multiFFTPanelVisible(true)
        model.select(outputB.id)
        model.select(outputA.id)
        model.select(outputB.id)
        let engines = Array(workers.suffix(3))
        let given = engines.map(\.multiFFTConfigurations.count)
        check(engines.allSatisfy(\.multiFFTActive) && Set(engines.map(\.stream)).count == 3,
              "each analysis made by quick switches is given the Multi-FFT engine while its panel shows")
        await settle(0.5)
        check(engines.prefix(2).map(\.multiFFTConfigurations.count) == Array(given.prefix(2)),
              "an analysis replaced by a switch is given nothing more")
        model.select(busDevice.id)
        check(model.running && model.multiFFTFrame() == nil, "a plugin source gets no Multi-FFT")
        model.select(outputA.id)
        guard let live = workers.last else { return check(false, "an analysis was made") }
        check(live.multiFFTActive, "back on a device after a plugin, the new analysis gets the engine again")
        placement.setShown(.multiFFT, false)
        model.multiFFTPanelVisible(false)
        model.select(outputB.id)
        model.select(outputA.id)
        let between = workers[workers.count - 2], last = workers[workers.count - 1]
        let liveCalls = live.multiFFTConfigurations.count
        await settle(MeterModel.multiFFTTeardownDelay + 0.4)
        check(live.multiFFTConfigurations.count == liveCalls && between.multiFFTConfigurations.isEmpty
              && !last.multiFFTConfigurations.isEmpty && last.multiFFTConfigurations.allSatisfy { $0 == nil },
              "after two quick switches the hidden panel's delayed stop reaches only the analysis running when it fires")

        receiver.plugins = []
        check(model.running && capturing(outputA), "the transitions end on the device last chosen")
    }
}
