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
    static let demo = CommandLine.arguments.contains("--demo") || snapshotRequested
    static let snapshotRequested = CommandLine.arguments.contains("--snapshot")
    static let showSettings = CommandLine.arguments.contains("--show-settings")
    static let showWelcome = CommandLine.arguments.contains("--show-welcome")
    static let showAbout = CommandLine.arguments.contains("--show-about")
    /// Toggles the meter window into full screen and back, printing the result of each step, then quits.
    static let testFullScreen = CommandLine.arguments.contains("--test-full-screen")
    static var snapshotSize: CGSize? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot-size"), index + 1 < arguments.count else { return nil }
        let parts = arguments[index + 1].split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }
    /// `--preview-layout 7.1.4` picks the layout drawn by `--render-preview`.
    static var previewLayout: SpeakerLayout {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--preview-layout"), index + 1 < arguments.count else { return .s916 }
        return SpeakerLayout(rawValue: arguments[index + 1]) ?? .s916
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
        if CommandLine.arguments.contains("--render-preview") {
            do {
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Auraliscope-preview.png")
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: next)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
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

    /// Captures this app's own window (no screen-recording permission needed) and exits.
    @MainActor
    static func captureWindowIfRequested(_ window: NSWindow) {
        guard snapshotRequested else { return }
        print("snapshot scheduled for window \(window.windowNumber)")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let size = snapshotSize { window.setContentSize(size) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            print("capturing window \(window.windowNumber)")
            fflush(stdout)
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Auraliscope-window.png")
            // The welcome sheet has its own window; capture the screen area of the meter window to include it.
            let image: CGImage?
            if showWelcome, let screen = NSScreen.screens.first {
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
    private static var systemAppearanceSwitchStarted = false
    private static var deviceSourceSelectionStarted = false

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
                $0.isVisible && ($0.title == L("Settings") || $0.title == L("About Auraliscope"))
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
                || $0.title == L("Settings") || $0.title == L("About Auraliscope")) }
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
