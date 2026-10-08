import AnalysisCore
import AudioRing
import CoreAudio
import Darwin
import Foundation
import AppKit
import ImageIO
import Metal

enum Diagnostics {
    static let enabled = CommandLine.arguments.contains("--diagnostic")
    /// Synthetic programme instead of an audio device, for layout review and screenshots.
    /// Snapshots use it too, unless `--snapshot-live` asks for the selected source instead.
    static let demo = CommandLine.arguments.contains("--demo")
        || (snapshotRequested && !CommandLine.arguments.contains("--snapshot-live"))
    static let snapshotRequested = CommandLine.arguments.contains("--snapshot")
    static let showSettings = CommandLine.arguments.contains("--show-settings")
    /// `--settings-apply <language>`: with `--show-settings`, stages that language and Light appearance in Settings
    /// one second after it opens, presses Apply two seconds later (unless `--settings-stage-only`), then prints
    /// the outcome and the menu bar, so the Apply flow can be checked in a snapshot.
    static let settingsApply: AppLanguage? = CommandLine.arguments.firstIndex(of: "--settings-apply")
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? AppLanguage(rawValue: CommandLine.arguments[$0 + 1]) : nil }
    static let settingsStageOnly = CommandLine.arguments.contains("--settings-stage-only")
    /// `--settings-preview`: stages Light and the spectrum on the left, previews, then reverts, printing each state.
    static let settingsPreview = CommandLine.arguments.contains("--settings-preview")
    static let showWelcome = CommandLine.arguments.contains("--show-welcome")
    static let showAbout = CommandLine.arguments.contains("--show-about")
    /// Toggles the meter window into full screen and back, printing the result of each step, then quits.
    static let testFullScreen = CommandLine.arguments.contains("--test-full-screen")
    /// With `--snapshot`: enters full screen first, then captures the whole screen area of this app's windows
    /// (the full-screen toolbar is a window of its own), to review the full-screen arrangement.
    static let snapshotFullScreen = CommandLine.arguments.contains("--snapshot-full-screen")
    static var snapshotSize: CGSize? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot-size"), index + 1 < arguments.count else { return nil }
        let parts = arguments[index + 1].split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }
    /// `--preview-stereo` draws `--render-preview` in Stereo instead of the layout's Spatial view.
    static let previewStereo = CommandLine.arguments.contains("--preview-stereo")
    /// `--preview-layout 7.1.4` picks the layout drawn by `--render-preview`.
    static var previewLayout: SpeakerLayout {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--preview-layout"), index + 1 < arguments.count else { return .s916 }
        return SpeakerLayout(rawValue: arguments[index + 1]) ?? .s916
    }
    /// `--preview-audio <file>` fills `--render-preview`'s spectrum and waterfall from an audio file run through the
    /// real analysis (`PreviewAudio`) instead of the synthetic demo, drawn in Stereo; `--preview-output <png>` names
    /// the image (the temporary directory's Auraliscope-preview.png otherwise).
    static var previewAudio: URL? { argument("--preview-audio").map { URL(fileURLWithPath: $0) } }
    static var previewOutput: URL? { argument("--preview-output").map { URL(fileURLWithPath: $0) } }
    /// `--preview-image <png>`: also writes the spectrogram's exported image (`SpectrogramImage`).
    static var previewImage: URL? { argument("--preview-image").map { URL(fileURLWithPath: $0) } }
    private static func argument(_ name: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    /// `--snapshot-inspect x,y` holds the Spectrum well's inspector at that point of the well (points), so a
    /// snapshot shows its crosshair and readout without a pointer.
    static var inspectPoint: CGPoint? {
        let parts = argument("--snapshot-inspect")?.split(separator: ",").compactMap { Double($0) } ?? []
        return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
    }
    static var requestedDeviceID: UInt32? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--input-device"), index + 1 < arguments.count else { return nil }
        return UInt32(arguments[index + 1])
    }
    static func log(_ message: String) {
        if enabled {
            print(message)
            fflush(stdout)
        }
    }

    static func runIfRequested() {
        if CommandLine.arguments.contains("--test-peak-reset") {
            exit(SoundstageScene.checkPeakReset() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--render-preview") {
            do {
                let destination = previewOutput ?? FileManager.default.temporaryDirectory.appendingPathComponent("Auraliscope-preview.png")
                try CanvasRenderer.writePreview(to: destination)
                print(destination.path)
                exit(0)
            } catch {
                fputs("\(error)\n", stderr)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--list-inputs") {
            for device in AudioDevices.availableSources() {
                print("\(device.device)\t\(device.output ? "output" : "input ")\t\(device.channels) ch\t\(device.name)")
            }
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--capture-selftest"), index + 1 < CommandLine.arguments.count,
           let device = AudioDeviceID(CommandLine.arguments[index + 1]) {
            exit(CaptureSelfTest.run(deviceID: device, output: CommandLine.arguments.contains("--output")) ? 0 : 1)
        }
        if CommandLine.arguments.contains("--benchmark-dsp") {
            runDSPBenchmark()
            exit(0)
        }
    }

    /// `--probe-window`: reports what AppKit sees of the meter window a few seconds after launch.
    @MainActor
    static func probeWindowIfRequested(_ window: NSWindow) {
        guard CommandLine.arguments.contains("--probe-window") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak window] in
            guard let window else { return }
            let behavior = window.collectionBehavior
            let zoom = window.standardWindowButton(.zoomButton)
            print("level=\(window.level.rawValue) fullScreenPrimary=\(behavior.contains(.fullScreenPrimary)) fullScreenNone=\(behavior.contains(.fullScreenNone)) auxiliary=\(behavior.contains(.fullScreenAuxiliary)) zoomAction=\(zoom?.action.map(NSStringFromSelector) ?? "nil") zoomTarget=\(zoom?.target.map { String(describing: type(of: $0)) } ?? "nil")")
            fflush(stdout)
            guard CommandLine.arguments.contains("--press-green") else { exit(0) }
            // Click the green button as a user would, then leave full screen again.
            zoom?.performClick(nil)
            // `--hold-full-screen N` stays in full screen N seconds (for screenshots) before leaving.
            let hold = CommandLine.arguments.firstIndex(of: "--hold-full-screen").flatMap { index in
                index + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[index + 1]) : nil } ?? 2.5
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                print("after green: fullScreen=\(window.styleMask.contains(.fullScreen)) level=\(window.level.rawValue)")
                fflush(stdout)
                window.toggleFullScreen(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    print("after exit: fullScreen=\(window.styleMask.contains(.fullScreen)) level=\(window.level.rawValue)")
                    fflush(stdout)
                    exit(0)
                }
            }
        }
    }

    @MainActor
    static func testFullScreenIfRequested(_ window: NSWindow) {
        guard testFullScreen else { return }
        let start = Date()
        func report(_ step: String) {
            print(String(format: "%5.2f s %@: fullScreen=%@ level=%d", Date().timeIntervalSince(start), step,
                         window.styleMask.contains(.fullScreen) ? "yes" : "no", window.level.rawValue))
            fflush(stdout)
        }
        /// Polls every 0.25 s until the window reaches `target` or 10 s pass, then runs `next`.
        func waitFor(_ target: Bool, _ step: String, then next: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(10)
            func poll() {
                if window.styleMask.contains(.fullScreen) == target || Date() > deadline {
                    report(step)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { next() }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
                }
            }
            poll()
        }
        // After `--show-settings` has opened (2 s), so the request also covers a meter window that is not key.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            report(window.isKeyWindow ? "before (key)" : "before (not key)")
            MainWindow.toggleFullScreen()
            waitFor(true, "enter") {
                MainWindow.toggleFullScreen()
                waitFor(false, "exit") {
                    report("settled")
                    exit(0)
                }
            }
        }
    }

    private static var themeSwitchStarted = false

    /// `--test-theme-switch`: moves the meter window, switches Light/Dark twice and prints the window frame after
    /// each step; the frame must stay where it was moved. Restores the frame, then quits.
    @MainActor
    static func testThemeSwitchIfRequested(_ window: NSWindow) {
        guard CommandLine.arguments.contains("--test-theme-switch"), !themeSwitchStarted else { return }
        themeSwitchStarted = true
        let original = window.frame
        func report(_ step: String) {
            let frame = MainWindow.window?.frame ?? .zero
            print(String(format: "[%@] x=%.0f y=%.0f w=%.0f h=%.0f", step, frame.minX, frame.minY, frame.width, frame.height))
            fflush(stdout)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            window.setFrame(original.offsetBy(dx: 60, dy: -40), display: true)
            report("moved")
            ThemeSettings.shared.toggle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                report("after switch")
                ThemeSettings.shared.toggle()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    report("after switch back")
                    MainWindow.window?.setFrame(original, display: true)
                    exit(0)
                }
            }
        }
    }

    /// Captures this app's own window (no screen-recording permission needed) and exits.
    @MainActor
    static func captureWindowIfRequested(_ window: NSWindow) {
        guard snapshotRequested else { return }
        print("snapshot scheduled for window \(window.windowNumber)")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let size = snapshotSize { window.setContentSize(size) }
            if snapshotFullScreen { MainWindow.toggleFullScreen() }
        }
        // `--snapshot-band-switch`: switches both band settings 0.25 s before the capture, to catch the morph.
        if CommandLine.arguments.contains("--snapshot-band-switch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + (snapshotFullScreen ? 7.75 : 5.75)) {
                UserDefaults.standard.set(StereoBands.Resolution.overall.rawValue, forKey: "soundstage.bands")
                UserDefaults.standard.set(StereoBands.Resolution.three.rawValue, forKey: "levels.bands")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (snapshotFullScreen ? 8 : 6)) {
            print("capturing window \(window.windowNumber)")
            fflush(stdout)
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Auraliscope-window.png")
            // The welcome sheet has its own window; capture the screen area of the meter window to include it.
            let image: CGImage?
            if showWelcome || snapshotFullScreen, let screen = NSScreen.screens.first {
                let frame = window.frame
                let rect = CGRect(x: frame.minX, y: screen.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
                image = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
            } else {
                image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                [.boundsIgnoreFraming, .bestResolution])
            }
            guard let image,
                  let output = CGImageDestinationCreateWithURL(destination as CFURL, "public.png" as CFString, 1, nil) else {
                fputs("window capture failed\n", stderr)
                exit(1)
            }
            CGImageDestinationAddImage(output, image, nil)
            CGImageDestinationFinalize(output)
            print(destination.path)
            fflush(stdout)
            exit(0)
        }
    }

    /// `--test-language-switch`: while metering, switches the app language to Chinese, Korean, English and back
    /// to System, and after each switch prints the menu bar, window titles and status line together with the
    /// capture generation and the time since capture started, which must stay unchanged (no audio restart).
    /// Restores the saved language preferences, then quits.
    @MainActor
    static func testLanguageSwitchIfRequested(model: MeterModel) {
        guard CommandLine.arguments.contains("--test-language-switch") else { return }
        let defaults = UserDefaults.standard
        let saved = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        let keys = ["appLanguage", "AppleLanguages"]
        func report(_ step: String) {
            // SwiftUI refreshes a command menu when it opens; ask for that refresh as a click would.
            for item in NSApp.mainMenu?.items ?? [] {
                guard let menu = item.submenu else { continue }
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
            }
            let bar = NSApp.mainMenu?.items ?? []
            // The meter menu is the one holding ⌘K (Channel Routing…), whatever its title in this language.
            let meter = bar.first { $0.submenu?.items.contains { $0.keyEquivalent == "k" } == true }?.submenu?.items
            let values = model.readouts.values
            print(String(format: "[%@] code=%@ capture=%u running=%@ elapsed=%.1f s integrated=%.1f LUFS dropped=%llu", step,
                         Localizer.shared.code, model.captureGeneration, model.running ? "yes" : "no", values.elapsed,
                         values.integrated, model.droppedFrames))
            print("  menus:   " + bar.map(\.title).joined(separator: " | "))
            print("  meter:   " + (meter ?? []).filter { !$0.isSeparatorItem }.map(\.title).joined(separator: " | "))
            print("  windows: " + NSApp.windows.filter(\.isVisible).map(\.title).filter { !$0.isEmpty }.joined(separator: " | "))
            print("  status:  " + model.status.text)
            fflush(stdout)
        }
        let steps: [AppLanguage] = [.simplifiedChinese, .korean, .english, .system]
        func run(_ index: Int) {
            guard index < steps.count else {
                for key in keys {
                    if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
                }
                exit(0)
            }
            Localizer.shared.language = steps[index]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                report(steps[index].rawValue)
                run(index + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openSettings(.audio) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            report("start")
            run(0)
        }
    }

    private static var appearanceSwitchStarted = false
    private static var themeFadeStarted = false
    private static var systemAppearanceSwitchStarted = false
    private static var deviceSourceSelectionStarted = false
    private static var pauseResumeStarted = false

    /// `--test-pause-resume`: pauses and checks the window holds its picture (two captures 3 s apart are identical,
    /// and with `--demo` the panels still show the signal) while the canvases come to rest; resumes and checks the
    /// same analysis carries on from that point (same stream, histories kept, no jump in the programme); then
    /// pauses, resets and checks the reset lets go of the held picture and that resume then starts afresh. Without
    /// `--demo` it runs on the selected source (silence is fine).
    @MainActor
    static func testPauseResumeIfRequested(model: MeterModel) {
        guard CommandLine.arguments.contains("--test-pause-resume"), !pauseResumeStarted else { return }
        pauseResumeStarted = true
        let driver = CanvasDriver.shared
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            print("PASS: \(message)")
            fflush(stdout)
        }
        func later(_ delay: Double, _ body: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { body() } }
        }
        /// The meter window's pixels below the toolbar (whose glass controls re-render on their own), saved beside
        /// the snapshot for a look.
        func capture(_ name: String) -> Data? {
            guard let window = MainWindow.window,
                  let whole = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                      [.boundsIgnoreFraming, .bestResolution]) else { return nil }
            let toolbar = Int((window.frame.height - window.contentLayoutRect.maxY) * window.backingScaleFactor)
            guard let image = whole.cropping(to: CGRect(x: 0, y: toolbar, width: whole.width, height: whole.height - toolbar))
            else { return nil }
            // Drawn into a buffer of its own: a cropped image may still hand out its source's full data.
            var pixels = Data(count: image.width * image.height * 4)
            pixels.withUnsafeMutableBytes { raw in
                CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                          bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                    .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Auraliscope-\(name).png")
            if let output = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(output, image, nil)
                CGImageDestinationFinalize(output)
            }
            return pixels
        }
        later(2) {
            check(model.running && driver.running, "canvases draw while capturing")
            model.toggleCapture()
            later(0.3) {
                let held = model.canvasFrame().snapshot
                check(model.frozen && held.sequence > 0 && (!demo || held.spectrum.contains { $0 > MeterScale.spectrumFloor + 6 }),
                      "pausing holds the last snapshot")
                let generation = model.captureGeneration
                let history = model.readouts.values.shortHistory.count
                let first = capture("paused-first")
                // The canvases settle for 2 s after the last change, then leave the display link.
                later(3.2) {
                    check(!model.running && !driver.running, "paused canvases come to rest")
                    let second = capture("paused-later")
                    // Compositing can shift an antialiased edge by a level; anything that moves changes far more.
                    let same = first.flatMap { a in second.map { b in
                        a.count == b.count && zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 2 }
                    } } ?? false
                    check(same, "the paused window keeps its picture unchanged")
                    let paused = driver.ticks
                    model.toggleCapture()
                    later(1) {
                        check(model.running && !model.frozen && driver.running && driver.ticks - paused >= 20,
                              "resumed canvases draw live again")
                        let now = model.canvasFrame().snapshot
                        // One second on: the demo moves about 30 updates and the DSP about 60 snapshots. Starting
                        // over would reset the history and the DSP's count; skipping the pause would jump the demo.
                        check(model.captureGeneration == generation && model.readouts.values.shortHistory.count > history
                              && now.sequence > held.sequence && (!demo || now.sequence - held.sequence < 60),
                              "resume carries on from the paused point")
                        model.toggleCapture()
                        later(3.5) {
                            check(!driver.running, "paused again, the canvases rest")
                            let resting = driver.ticks
                            model.resetMeasurements()
                            later(0.5) {
                                check(!model.frozen && model.canvasFrame().snapshot.sequence == 0 && driver.ticks > resting,
                                      "a reset while paused lets go of the held picture and redraws")
                                model.toggleCapture()
                                later(1) {
                                    check(model.running && model.readouts.values.shortHistory.count <= 12
                                          && (demo || model.captureGeneration != generation),
                                          "after a reset, resume starts afresh")
                                    // Thirty quick toggles, 40 ms apart: capture and analysis stop and start
                                    // under each other without a crash, and the meter ends live and moving.
                                    @MainActor func toggle(_ left: Int) {
                                        guard left > 0 else {
                                            let before = model.canvasFrame().snapshot.sequence
                                            later(1) {
                                                check(model.running && !model.frozen && driver.running
                                                      && model.canvasFrame().snapshot.sequence > before,
                                                      "rapid pause and resume leave the meter live")
                                                exit(0)
                                            }
                                            return
                                        }
                                        model.toggleCapture()
                                        later(0.04) { toggle(left - 1) }
                                    }
                                    toggle(30)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static var sourceSwitchStarted = false
    private static var spaceShortcutStarted = false

    /// `--test-space-shortcut` (with `--demo`): Space is the capture item's shortcut while the meter window is key,
    /// and not while Settings is, so Space there reaches the focused control.
    @MainActor
    static func testSpaceShortcutIfRequested(model: MeterModel) {
        guard CommandLine.arguments.contains("--test-space-shortcut"), !spaceShortcutStarted else { return }
        spaceShortcutStarted = true
        func captureItem() -> NSMenuItem? {
            for item in NSApp.mainMenu?.items ?? [] {
                guard let menu = item.submenu else { continue }
                // SwiftUI refreshes a command menu when it opens; ask for that refresh as a click would.
                menu.delegate?.menuNeedsUpdate?(menu)
                if let found = menu.items.first(where: { $0.title == model.captureActionTitle }) { return found }
            }
            return nil
        }
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            print("PASS: \(message)")
            fflush(stdout)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                MainWindow.window?.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated {
                        check(MeterWindowFocus.shared.key && captureItem()?.keyEquivalent == " ",
                              "Space pauses while the meter window is focused")
                        model.showSettings = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            MainActor.assumeIsolated {
                                check(!MeterWindowFocus.shared.key && captureItem()?.keyEquivalent == "",
                                      "Space is left to the focused control in Settings")
                                exit(0)
                            }
                        }
                    }
                }
            }
        }
    }


    /// `--test-source-switch <input device id>`: on real hardware, switches from the launch source to that input,
    /// pauses, switches back to the launch source while paused, and checks that resume then starts a fresh
    /// analysis on it instead of carrying on the paused one. Restores the saved source.
    @MainActor
    static func testSourceSwitchIfRequested(model: MeterModel) {
        guard let index = CommandLine.arguments.firstIndex(of: "--test-source-switch"), !sourceSwitchStarted,
              index + 1 < CommandLine.arguments.count, let inputID = UInt32(CommandLine.arguments[index + 1]) else { return }
        sourceSwitchStarted = true
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: "inputDeviceUID"), defaults.object(forKey: "inputDeviceIsOutput"))
        func restore() {
            for (key, value) in [("inputDeviceUID", saved.0), ("inputDeviceIsOutput", saved.1)] {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAIL: \(message) (status: \(model.status.logDescription))\n", stderr); restore(); exit(1) }
            print("PASS: \(message)")
            fflush(stdout)
        }
        func later(_ delay: Double, _ body: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { body() } }
        }
        later(2) {
            let launch = model.selectedID
            guard let input = model.devices.first(where: { !$0.output && $0.device == inputID }) else {
                fputs("No input device \(inputID)\n", stderr); exit(1)
            }
            check(model.running, "the launch source is metering")
            model.select(input.id)
            later(1) {
                check(model.running && model.selectedID == input.id && model.canvasFrame().snapshot.sequence > 0,
                      "switching to the input meters it")
                model.toggleCapture()
                let paused = model.captureGeneration
                model.select(launch)
                check(!model.running && model.frozen, "choosing another source while paused keeps the pause")
                model.toggleCapture()
                later(1) {
                    check(model.running && model.selectedID == launch && model.captureGeneration != paused
                          && model.readouts.values.shortHistory.count <= 12,
                          "resume after a source change starts afresh on the new source")
                    restore()
                    exit(0)
                }
            }
        }
    }

    /// Exercises input and output removal and return with synthetic devices, without touching audio hardware.
    @MainActor
    static func testDeviceSourceSelectionIfRequested(model: MeterModel) {
        guard CommandLine.arguments.contains("--test-device-source-selection"), !deviceSourceSelectionStarted else { return }
        deviceSourceSelectionStarted = true
        guard demo else { fputs("Device source test requires --demo\n", stderr); exit(1) }
        let defaults = UserDefaults.standard
        let domain = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        func restore() {
            for key in ["inputDeviceUID", "inputDeviceIsOutput"] {
                if let value = domain[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAIL: \(message)\n", stderr); restore(); exit(1) }
            print("PASS: \(message)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard model.running else { fputs("Demo did not start\n", stderr); restore(); exit(1) }
            model.toggleCapture() // Pauses the demo so the injected list cannot start hardware capture.
            let input = InputDevice(device: 0xFFFF_FF01, name: "Test input", channels: 2, uid: "test.input")
            let output = InputDevice(device: 0xFFFF_FF02, name: "Test output", channels: 2, uid: "test.output", output: true)
            model.refreshDevices(using: [input, output])
            model.select(input.id)
            model.refreshDevices(using: [output])
            check(model.selectedID == .none && defaults.string(forKey: "inputDeviceUID") == input.uid,
                  "removed input waits at no input device")
            model.refreshDevices(using: [input, output])
            check(model.selectedID == input.id, "returned input is restored")
            model.select(.none)
            model.refreshDevices(using: [input, output])
            check(model.selectedID == .none && defaults.string(forKey: "inputDeviceUID") == "",
                  "manual no input device remains selected")
            model.select(output.id)
            model.refreshDevices(using: [input])
            check(model.selectedID == .noOutput && defaults.string(forKey: "inputDeviceUID") == output.uid,
                  "removed output waits at no output device")
            model.refreshDevices(using: [input, output])
            check(model.selectedID == output.id, "returned output is restored")
            model.select(.noOutput)
            model.refreshDevices(using: [input, output])
            check(model.selectedID == .noOutput && defaults.string(forKey: "inputDeviceUID") == "",
                  "manual no output device remains selected")
            restore()
            exit(0)
        }
    }

    /// Simulates a macOS appearance change without changing the user's system setting. In Auto mode the app
    /// appearance inherits macOS; changing it temporarily exercises the same effectiveAppearance observer.
    @MainActor
    static func testSystemAppearanceSwitchIfRequested() {
        guard CommandLine.arguments.contains("--test-system-appearance-switch"), !systemAppearanceSwitchStarted else { return }
        systemAppearanceSwitchStarted = true
        let theme = ThemeSettings.shared
        guard theme.mode == .system else {
            fputs("System appearance test requires Auto mode\n", stderr)
            exit(1)
        }
        let original = NSApp.appearance
        let originalDark = theme.dark
        func report(_ step: String, expectedDark: Bool) {
            let utilityWindows = NSApp.windows.filter {
                $0.isVisible && ($0.title == L("Settings") || $0.title == L("About Auraliscope LABS"))
            }
            print("[\(step)] mode=\(theme.mode.rawValue) dark=\(theme.dark) utilityWindows=\(utilityWindows.count)")
            fflush(stdout)
            guard theme.dark == expectedDark && utilityWindows.isEmpty else {
                NSApp.appearance = original
                exit(1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            report("before", expectedDark: originalDark)
            NSApp.appearance = NSAppearance(named: originalDark ? .aqua : .darkAqua)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                report("system changed", expectedDark: !originalDark)
                NSApp.appearance = original
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    report("system restored", expectedDark: originalDark)
                    exit(0)
                }
            }
        }
    }

    /// `--test-appearance-switch`: while metering, flips Light ↔ Dark from the toolbar's action, then back, and
    /// after each flip prints the appearance, the meter window's appearance, the capture generation and the time
    /// since capture started, which must keep running without a restart. Combined with `--snapshot`, the
    /// capture at 6 s shows the window after the first live switch. Restores the saved choice, then quits.
    @MainActor
    static func testAppearanceSwitchIfRequested(model: MeterModel) {
        // The meter view is rebuilt by each switch and appears again; schedule the run once.
        guard CommandLine.arguments.contains("--test-appearance-switch"), !appearanceSwitchStarted else { return }
        appearanceSwitchStarted = true
        let theme = ThemeSettings.shared
        let saved = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[ThemeSettings.modeKey]
        func report(_ step: String) {
            let window = MainWindow.window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "none"
            let utilityWindows = NSApp.windows.filter { $0.isVisible && ($0.identifier?.rawValue == "settings" || $0.identifier?.rawValue == "about"
                || $0.title == L("Settings") || $0.title == L("About Auraliscope LABS")) }
            print(String(format: "[%@] mode=%@ dark=%@ window=%@ capture=%u running=%@ elapsed=%.1f s utilityWindows=%d", step,
                         theme.mode.rawValue, theme.dark ? "yes" : "no", window, model.captureGeneration,
                         model.running ? "yes" : "no", model.readouts.values.elapsed, utilityWindows.count))
            if !utilityWindows.isEmpty {
                fputs("Unexpected utility window opened during appearance switch\n", stderr)
                restore()
                exit(1)
            }
            fflush(stdout)
        }
        func restore() {
            if let saved { UserDefaults.standard.set(saved, forKey: ThemeSettings.modeKey) }
            else { UserDefaults.standard.removeObject(forKey: ThemeSettings.modeKey) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            report("before")
            theme.toggle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                report("switched")
                // A snapshot run keeps the switched window on screen for its capture; the saved choice is put
                // back now, since the capture quits the app.
                guard !snapshotRequested else { return restore() }
                theme.toggle()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    report("back")
                    restore()
                    exit(0)
                }
            }
        }
    }

    /// `--test-theme-fade`: flips Light ↔ Dark from the toolbar's action, then captures the meter window at points
    /// through the cross-fade (`ThemeFade`) from a background queue, so the captures never hold up the rebuild they
    /// are watching. Writes `Auraliscope-fade-<ms>.png` to the temporary directory, restores the saved choice, quits.
    @MainActor
    static func testThemeFadeIfRequested() {
        guard CommandLine.arguments.contains("--test-theme-fade"), !themeFadeStarted else { return }
        themeFadeStarted = true
        let saved = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[ThemeSettings.modeKey]
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard let window = MainWindow.window else { exit(1) }
            let id = CGWindowID(window.windowNumber)
            let directory = FileManager.default.temporaryDirectory
            let offsets = [0, 100, 170, 240, 310, 380, 450, 700]
            let start = DispatchTime.now()
            // When the main thread next goes idle, the rebuild has been committed.
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, Int.max) { observer, _ in
                print(String(format: "main thread idle after %.1f ms", Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6))
                fflush(stdout)
                CFRunLoopObserverInvalidate(observer)
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            ThemeSettings.shared.toggle()
            let rebuilt = DispatchTime.now()
            print(String(format: "toggle returned after %.1f ms", Double(rebuilt.uptimeNanoseconds - start.uptimeNanoseconds) / 1e6))
            fflush(stdout)
            DispatchQueue.global(qos: .userInteractive).async {
                for offset in offsets {
                    let due = start + .milliseconds(offset)
                    while DispatchTime.now() < due { usleep(500) }
                    let taken = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
                    guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .nominalResolution]) else { continue }
                    let url = directory.appendingPathComponent(String(format: "Auraliscope-fade-%03d.png", offset))
                    if let output = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(output, image, nil)
                        CGImageDestinationFinalize(output)
                    }
                    print(String(format: "%@ (taken at %.0f ms)", url.path, taken))
                    fflush(stdout)
                }
                DispatchQueue.main.async {
                    if let saved { UserDefaults.standard.set(saved, forKey: ThemeSettings.modeKey) }
                    else { UserDefaults.standard.removeObject(forKey: ThemeSettings.modeKey) }
                    exit(0)
                }
            }
        }
    }

    /// `--benchmark-theme-switch`: flips Light ↔ Dark 20 times, 0.7 s apart, and prints how long the main thread
    /// was busy with each switch (from the toggle until it next goes idle), then the median. Restores the saved
    /// choice and quits.
    @MainActor
    static func benchmarkThemeSwitchIfRequested() {
        guard CommandLine.arguments.contains("--benchmark-theme-switch"), !themeSwitchBenchmarkStarted else { return }
        themeSwitchBenchmarkStarted = true
        let saved = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[ThemeSettings.modeKey]
        var busy: [Double] = []
        func run(_ remaining: Int) {
            guard remaining > 0 else {
                let sorted = busy.sorted()
                print(String(format: "theme switch: median %.1f ms, min %.1f ms, max %.1f ms over %d switches",
                             sorted[sorted.count / 2], sorted.first ?? 0, sorted.last ?? 0, sorted.count))
                fflush(stdout)
                if let saved { UserDefaults.standard.set(saved, forKey: ThemeSettings.modeKey) }
                else { UserDefaults.standard.removeObject(forKey: ThemeSettings.modeKey) }
                exit(0)
            }
            let start = CACurrentMediaTime()
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, Int.max) { observer, _ in
                busy.append((CACurrentMediaTime() - start) * 1000)
                CFRunLoopObserverInvalidate(observer)
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            ThemeSettings.shared.toggle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { run(remaining - 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { run(20) }
    }
    private static var themeSwitchBenchmarkStarted = false

    /// Prints the menu bar, so a diagnostic run can confirm what AppKit and SwiftUI merged into it.
    @MainActor
    static func logMenus() {
        func walk(_ menu: NSMenu, depth: Int) {
            for item in menu.items where !item.isSeparatorItem {
                let key = item.keyEquivalent.isEmpty ? "" : " [\(item.keyEquivalentModifierMask.rawValue):\(item.keyEquivalent)]"
                log(String(repeating: "  ", count: depth) + item.title + key)
                if let submenu = item.submenu { walk(submenu, depth: depth + 1) }
            }
        }
        if let menu = NSApp.mainMenu { walk(menu, depth: 0) }
    }

    private static func cpuTime() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    private static func runDSPBenchmark() {
        for spatial in [false, true] { runDSPBenchmark(spatialSpectrum: spatial) }
        print("This excludes CoreAudio, Metal, SwiftUI, WindowServer and audio driver CPU.")
    }

    private static func runDSPBenchmark(spatialSpectrum: Bool) {
        let layout = SpeakerLayout.s916
        let active = (0..<Role.count).map(layout.contains)
        let tickFrames = Int(48_000 / MeterPipeline.tickRate)
        guard let pipeline = MeterPipeline(sampleRate: 48_000, activeRoles: active, detector: FormatDetector(), streamID: 1) else { exit(1) }
        pipeline.spatialSpectrum = spatialSpectrum
        let multichannel = (0..<tickFrames).map { index -> ChannelFrame in
            let value = Float(sin(2 * Double.pi * 997 * Double(index) / 48_000)) * 0.4
            var result = ChannelFrame()
            withUnsafeMutableBytes(of: &result) { raw in
                let roles = raw.bindMemory(to: Float.self)
                for role in 0..<Role.count { roles[role] = (role % 2 == 0 ? value : value * 0.8) * (1 - Float(role) * 0.04) }
            }
            return result
        }
        var published = [Float](repeating: 0, count: Int(METER_SNAPSHOT_FLOATS))
        var tick = 0
        func update() -> Float {
            multichannel.withUnsafeBufferPointer { pipeline.consume($0) }
            tick += 1
            published.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: Double(tick) / MeterPipeline.tickRate) }
            return published[SnapshotSlots.rms] + published[SnapshotSlots.momentary] + published[SnapshotSlots.format]
                + published[SnapshotSlots.waveform] + published[SnapshotSlots.truePeaks]
        }
        let ticks = Int(100 * MeterPipeline.tickRate)
        for _ in 0..<60 { _ = update() }
        let start = cpuTime()
        var checksum: Float = 0
        for _ in 0..<ticks { checksum += update() }
        let elapsed = cpuTime() - start
        print(String(format: "Full 9.1.6 DSP pipeline, %@ spectrum (16 roles, 4× true peak, loudness range, waveform envelope, format detector, snapshot packing): 100 simulated audio seconds, 48 kHz, %d FFT, %.0f snapshots/s, %.0f waterfall columns/s\nCPU time: %.4f s\nEquivalent one-core CPU: %.3f%%\nChecksum: %.3f",
                     spatialSpectrum ? "Spatial (16-channel)" : "Stereo (L/R)", SpectrumAnalyzer.fftSize, MeterPipeline.tickRate,
                     MeterPipeline.tickRate / Double(MeterPipeline.windowTicks), elapsed, elapsed, checksum))
    }
}
