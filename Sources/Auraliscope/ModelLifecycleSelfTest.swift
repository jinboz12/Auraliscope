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
    /// or to find another sample rate, and a stop to report frames lost after the last callback.
    final class Capture: CaptureBackend {
        let ring: OpaquePointer
        private(set) var sampleRate = 48_000.0
        private(set) var channels: UInt32 = 0
        var rateAtNextStart = 48_000.0
        var failNextStart = false
        var dropsAtNextStop: UInt64 = 0
        private let journal: Journal

        init?(journal: Journal) {
            guard let ring = channel_ring_create(1024) else { return nil }
            self.ring = ring
            self.journal = journal
        }

        func start(device: InputDevice, sourceForRole: [Int32]) throws {
            journal.note("capture.start \(device.uid) \(ModelLifecycleSelfTest.routing(sourceForRole))")
            if failNextStart {
                failNextStart = false
                throw Refusal()
            }
            sampleRate = rateAtNextStart
            channels = device.channels
        }

        func stop() -> UInt64 {
            journal.note("capture.stop")
            defer { dropsAtNextStop = 0 }
            return dropsAtNextStop
        }
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
        private(set) var multiFFTActive = false

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
        func setMultiFFT(_ configuration: MultiFFTConfiguration?) { multiFFTActive = configuration != nil }
        func latestMultiFFT(frozen: Bool) -> MultiFFTSnapshot? { nil }
        func setLegacySTFT(_ choice: LegacySTFT) { legacy.append(choice) }
    }

    /// A DAW plugin receiver with the plugins the test lists; records selections, attachments and commands.
    final class Receiver: BridgeReceiving {
        var plugins: [AbrSourceInfo] = []
        private(set) var selected: [UInt8]?
        private(set) var commands: [Int32] = []
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
    static var failNextWorker = false
    /// Every analysis the model made, in order.
    static var workers: [Worker] = []
    private static var savedDomain: [String: Any]?
    private static var started = false

    /// "role>input" for each routed role, e.g. "0>0,1>1".
    static func routing(_ sourceForRole: [Int32]) -> String {
        sourceForRole.enumerated().filter { $0.element >= 0 }.map { "\($0.offset)>\($0.element)" }.joined(separator: ",")
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
            })
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
        model.multiFFTPanelVisible(false)
        placement.setShown(.multiFFT, false)

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

        restoreDomain()
        print("PASS: model lifecycle checks complete")
        fflush(stdout)
        exit(0)
    }
}
