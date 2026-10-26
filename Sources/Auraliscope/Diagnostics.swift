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
    /// A native self-test (`--test-panel-drawing`, `--test-multifft-layout`) drives the model itself; the launch
    /// welcome would otherwise hold the demo until dismissed. Only a QA bundle identifier reaches these tests.
    static let selfTestRequested = CommandLine.arguments.contains(where: { ["--test-panel-drawing", "--test-multifft-layout"].contains($0) })
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
    /// `--welcome-page <n>` opens the welcome on that page (0–2), for snapshots of each.
    static var welcomePage: Int? { argument("--welcome-page").flatMap(Int.init) }
    static let showAbout = CommandLine.arguments.contains("--show-about")
    /// Toggles the meter window into full screen and back, printing the result of each step, then quits.
    static let testFullScreen = CommandLine.arguments.contains("--test-full-screen")
    /// With `--snapshot`: enters full screen first, then captures the whole screen area of this app's windows
    /// (the full-screen toolbar is a window of its own), to review the full-screen arrangement.
    static let snapshotFullScreen = CommandLine.arguments.contains("--snapshot-full-screen")
    /// With `--snapshot`: opens a panel's settings popover (`--snapshot-panel-settings [soundstage]`, the Spectrum
    /// panel's by default) and captures the window's screen area with it.
    static let snapshotPanelSettings = CommandLine.arguments.contains("--snapshot-panel-settings")
    /// With `--snapshot-panel-settings soundstage`: the nebula's Analysis and motion section open.
    static let snapshotPanelAdvanced = CommandLine.arguments.contains("--snapshot-panel-advanced")
    static var snapshotPanelSettingsPanel: String {
        let value = argument("--snapshot-panel-settings") ?? ""
        return value.hasPrefix("-") || value.isEmpty ? "spectrum" : value
    }
    /// With `--snapshot`: opens the toolbar's window panels popover and captures the window's screen area with it.
    static let snapshotWindowPanels = CommandLine.arguments.contains("--snapshot-window-panels")
    /// With `--snapshot`: pauses 1.5 s before the capture, to review the paused state.
    static let snapshotPaused = CommandLine.arguments.contains("--snapshot-paused")
    /// With `--snapshot`: drives the demo 10 dB hot, so true-peak overs and the loudness warnings show.
    static let snapshotHot = CommandLine.arguments.contains("--snapshot-hot")
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
    /// `--preview-stage-size WxH`: `--render-preview` draws only the Soundstage, at that size in points (2× pixels),
    /// following the demo or `--preview-audio` as it would live; for checking the Immersive nebula.
    static var previewStageSize: CGSize? {
        let parts = argument("--preview-stage-size")?.split(separator: "x").compactMap { Double($0) } ?? []
        return parts.count == 2 && parts[0] >= 100 && parts[1] >= 100 ? CGSize(width: parts[0], height: parts[1]) : nil
    }
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
    /// `--snapshot-dome-probe x,y` holds the Immersive dome's pointer readout at that point of the well (points).
    static var domeProbePoint: CGPoint? {
        let parts = argument("--snapshot-dome-probe")?.split(separator: ",").compactMap { Double($0) } ?? []
        return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
    }
    /// `--snapshot-multifft-probe x,y` holds the Multi-FFT Spectrum's hover readout at that point of its plot (points).
    static var multiFFTProbePoint: CGPoint? {
        let parts = argument("--snapshot-multifft-probe")?.split(separator: ",").compactMap { Double($0) } ?? []
        return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
    }
    /// `--snapshot-wave-probe x,y` holds the Waveform's pointer cursor and readout at that point of the well.
    static var waveProbePoint: CGPoint? {
        let parts = argument("--snapshot-wave-probe")?.split(separator: ",").compactMap { Double($0) } ?? []
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
        if CommandLine.arguments.contains("--test-nebula-gpu") {
            exit(NebulaScene.checkGPUTransitions() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--test-spatial-projection") {
            exit(NebulaScene.checkProjection() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--test-nebula") {
            exit(NebulaScene.checkLifecycle() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--test-spectrum-average") {
            exit(SpectrumScene.checkAverageLifecycle() ? 0 : 1)
        }
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
        // `--render-controls <png>`: every state of the round buttons and tracks, on a panel and in the toolbar, dark
        // above light, for checking their light and shade without a pointer.
        if let path = argument("--render-controls") {
            exit(MainActor.assumeIsolated { ControlStateSheet.write(to: URL(fileURLWithPath: path)) } ? 0 : 1)
        }
        if CommandLine.arguments.contains("--list-inputs") {
            // Each source and, after it, the speakers Audio MIDI Setup sets its channels up as (the default routing).
            for device in AudioDevices.availableSources() {
                let speakers = AudioDevices.speakerMap(device).map { map in
                    "\tspeakers \(map.name): " + map.roles.map { $0.map { SpatialGeometry.roleNames[$0] } ?? "-" }.joined(separator: " ")
                } ?? ""
                print("\(device.device)\t\(device.output ? "output" : "input ")\t\(device.channels) ch\t\(device.name)\(speakers)")
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

    /// The process' CPU time so far, in seconds (user and system).
    static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    private static var stripReturnStarted = false
    /// `--test-strip-return [rounds]` (with `--diagnostic`): enlarges and restores a panel, hides and shows one, then goes
    /// into the strip and back `rounds` times (default 2). It prints the process CPU in the full window and in the strip,
    /// the longest wait between display refreshes and the slowest refresh during each transition, and whether the toolbar came back clear of the window controls
    /// (`FAIL` if its leading item sits under them or it stays hidden); then quits. `--strip-hold <s>` stays in the
    /// strip that long (default 4 s), e.g. to resize it by hand; `--strip-capture <folder>` saves the window in the
    /// strip and after each return. `--chrome-log` instead prints the title bar's state every second.
    @MainActor
    static func testStripReturnIfRequested(_ window: NSWindow) {
        guard !stripReturnStarted else { return }
        if CommandLine.arguments.contains("--chrome-log") {
            stripReturnStarted = true
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { print("chrome strip=\(PanelPlacement.shared.strip) \(chrome(window))"); fflush(stdout) }
            }
            return
        }
        if CommandLine.arguments.contains("--test-strip-widths") {
            stripReturnStarted = true
            return testStripWidths(window)
        }
        guard let index = CommandLine.arguments.firstIndex(of: "--test-strip-return") else { return }
        stripReturnStarted = true
        let rounds = index + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[index + 1]) ?? 2 : 2
        let hold = argument("--strip-hold").flatMap(Double.init) ?? 4
        var failed = false
        func capture(_ name: String) {
            guard let folder = argument("--strip-capture"),
                  let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                      [.boundsIgnoreFraming, .bestResolution]),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
        /// Runs `change`, then after `seconds` prints the transition's refresh gaps and the CPU over the rest of the wait.
        func measure(_ step: String, seconds: Double, _ change: () -> Void, then next: @escaping () -> Void) {
            CanvasDriver.shared.resetGap()
            change()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let gap = CanvasDriver.shared.longestGap, slowest = CanvasDriver.shared.slowestTick
                let cpu = processCPU(), wall = CACurrentMediaTime()
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds - 1) {
                    print(String(format: "[strip] %@: longest refresh gap %.1f ms, slowest refresh %.1f ms; then CPU %.1f%% of one core",
                                 step, gap * 1000, slowest * 1000, (processCPU() - cpu) / (CACurrentMediaTime() - wall) * 100))
                    fflush(stdout)
                    next()
                }
            }
        }
        func round(_ n: Int) {
            guard n < rounds else { print(failed ? "[strip] FAIL" : "[strip] PASS"); fflush(stdout); exit(failed ? 1 : 0) }
            measure("into the strip \(n + 1)", seconds: hold, { PanelPlacement.shared.enterStrip() }) {
                capture("strip-\(n + 1)")
                let contentHeight = window.contentView?.bounds.height ?? 0
                let stripHeight = PanelPlacement.shared.stripContentSize.height
                let fillsHeight = contentHeight > 0 && abs(stripHeight - contentHeight) <= 1
                failed = failed || !fillsHeight
                print("[strip] dock fills window: \(fillsHeight ? "ok" : "FAIL") (content=\(contentHeight), row=\(stripHeight))")
                measure("back \(n + 1)", seconds: 3, { PanelPlacement.shared.leaveStrip() }) {
                    capture("back-\(n + 1)")
                    let clear = toolbarClear(window)
                    failed = failed || !clear
                    print("[strip] back \(n + 1): toolbar \(clear ? "clear of" : "UNDER") the window controls (\(chrome(window)))")
                    round(n + 1)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            let placement = PanelPlacement.shared
            measure("full window", seconds: 3, {}) {
                // The other panel transitions, for comparison: enlarge and restore, hide and show.
                measure("enlarge Spectrum", seconds: 1.5, { placement.toggleEnlarged(.spectrum) }) {
                    measure("restore", seconds: 1.5, { placement.restore() }) {
                        measure("hide Waveform", seconds: 1.5, { placement.setShown(.waveform, false) }) {
                            measure("show Waveform", seconds: 1.5, { placement.setShown(.waveform, true) }) { round(0) }
                        }
                    }
                }
            }
        }
    }

    /// `--test-strip-widths` (with `--diagnostic`): goes into the strip, drags the divider after its first panel 120 pt
    /// right with mouse events sent to the divider itself, checks that the panel grew and its neighbour shrank by as much,
    /// double-clicks the divider back to automatic widths; does the same with the gap between the Spectrum panel's
    /// spectrogram and spectrum cards (80 pt left); minimizes the strip with its button and with ⌘M, then the full
    /// window with ⌘M, and quits (`PASS`/`FAIL`). The stored strip widths and split are put back as they were.
    /// `--strip-capture <folder>` saves the strip before and after each drag.
    @MainActor
    private static func testStripWidths(_ window: NSWindow) {
        let placement = PanelPlacement.shared
        let saved = UserDefaults.standard.string(forKey: PanelPlacement.stripWidthsKey)
        let savedSplit = UserDefaults.standard.object(forKey: SpectrumPanel.stripShareKey)
        var failed = false
        func check(_ ok: Bool, _ text: String) {
            failed = failed || !ok
            print("[strip widths] \(ok ? "ok" : "FAIL"): \(text)"); fflush(stdout)
        }
        func finish() {
            if let saved { UserDefaults.standard.set(saved, forKey: PanelPlacement.stripWidthsKey) }
            else { UserDefaults.standard.removeObject(forKey: PanelPlacement.stripWidthsKey) }
            if let savedSplit { UserDefaults.standard.set(savedSplit, forKey: SpectrumPanel.stripShareKey) }
            else { UserDefaults.standard.removeObject(forKey: SpectrumPanel.stripShareKey) }
            print(failed ? "[strip widths] FAIL" : "[strip widths] PASS"); fflush(stdout)
            exit(failed ? 1 : 0)
        }
        func capture(_ name: String) {
            guard let folder = argument("--strip-capture"),
                  let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                      [.boundsIgnoreFraming, .bestResolution]),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
        func dividers(_ view: NSView) -> [PanelDividerView] {
            (view as? PanelDividerView).map { [$0] } ?? view.subviews.flatMap(dividers)
        }
        /// The strip's dividers named `identifier` (`strip.gap` between panels, `strip.spectrumSplit` between the
        /// spectrogram and spectrum cards), left to right.
        func stripDividers(_ identifier: String = "strip.gap") -> [PanelDividerView] {
            guard let content = window.contentView else { return [] }
            return dividers(content).filter { $0.window != nil && $0.identifier?.rawValue == identifier }
                .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        }
        func send(_ type: NSEvent.EventType, to view: NSView, x: CGFloat, clicks: Int = 1) {
            let frame = view.convert(view.bounds, to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: frame.midX + x, y: frame.midY),
                                                 modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: clicks, pressure: 1) else { return }
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
        let after: (Double, @escaping () -> Void) -> Void = { seconds, next in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(next) }
        }
        /// The gap after the first panel: 120 pt to the right, then a double-click back to the automatic widths.
        func testPanels(then next: @escaping () -> Void) {
            capture("widths-automatic")
            let found = stripDividers()
            check(found.count == max(0, placement.stripPanels.count - 1),
                  "\(found.count) dividers for \(placement.stripPanels.count) strip panels")
            guard let divider = found.first, let neighbour = found.dropFirst().first else { return finish() }
            let before = (divider.leading, neighbour.leading)
            send(.leftMouseDown, to: divider, x: 0)
            for step in 1...12 { send(.leftMouseDragged, to: divider, x: CGFloat(step) * 10) }
            send(.leftMouseUp, to: divider, x: 120)
            after(0.6) {
                capture("widths-dragged")
                let grew = divider.leading - before.0, shrank = before.1 - neighbour.leading
                check(abs(grew - 120) <= 2, String(format: "first panel %.0f → %.0f pt", before.0, divider.leading))
                check(abs(shrank - grew) <= 2, String(format: "second panel %.0f → %.0f pt", before.1, neighbour.leading))
                check(UserDefaults.standard.string(forKey: PanelPlacement.stripWidthsKey) != nil, "widths stored")
                send(.leftMouseDown, to: divider, x: 0, clicks: 2)
                after(0.8) {
                    check(abs(divider.leading - before.0) <= 2 && placement.stripShares.isEmpty,
                          String(format: "double-click: first panel back to %.0f pt", divider.leading))
                    next()
                }
            }
        }
        /// The gap between the strip's spectrogram and spectrum cards: 80 pt to the left widens the spectrum card.
        func testSplit(then next: @escaping () -> Void) {
            guard placement.stripPanels.contains(.spectrum) else {
                print("[strip widths] no Spectrum panel in the strip: split not tested")
                return next()
            }
            let found = stripDividers("strip.spectrumSplit")
            check(found.count == 1, "one gap between the spectrogram and spectrum cards")
            guard let split = found.first else { return next() }
            let before = split.leading
            send(.leftMouseDown, to: split, x: 0)
            for step in 1...8 { send(.leftMouseDragged, to: split, x: -CGFloat(step) * 10) }
            send(.leftMouseUp, to: split, x: -80)
            after(0.6) {
                capture("widths-split")
                let share = UserDefaults.standard.double(forKey: SpectrumPanel.stripShareKey)
                check(abs(before - split.leading - 80) <= 2, String(format: "spectrogram card %.0f → %.0f pt", before, split.leading))
                check(share > Double(SpectrumPanel.stripSpectrumShare), String(format: "spectrum card's share stored: %.3f", share))
                send(.leftMouseDown, to: split, x: 0, clicks: 2)
                after(0.6) {
                    check(abs(split.leading - before) <= 2 && UserDefaults.standard.double(forKey: SpectrumPanel.stripShareKey) == 0,
                          String(format: "double-click: spectrogram card back to %.0f pt", split.leading))
                    next()
                }
            }
        }
        /// ⌘M as the keyboard sends it, through the menu bar.
        func commandM() -> Bool {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            NSApp.mainMenu?.update()
            print("[strip widths] command focus: active=\(NSApp.isActive) key=\(NSApp.keyWindow === window) main=\(NSApp.mainWindow === window)")
            guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, characters: "m", charactersIgnoringModifiers: "m",
                                             isARepeat: false, keyCode: 46) else { return false }
            return NSApp.mainMenu?.performKeyEquivalent(with: key) == true
        }
        /// The strip's − button, then ⌘M in the strip, then ⌘M in the full window.
        func testMinimize(then next: @escaping () -> Void) {
            placement.minimizeStrip()
            after(1.2) {
                check(window.isMiniaturized, "strip button minimizes")
                window.deminiaturize(nil)
                after(1.2) {
                    check(!window.isMiniaturized && placement.strip, "back from the Dock, still the strip")
                    window.makeKeyAndOrderFront(nil)
                    check(commandM(), "⌘M found in the menu")
                    after(1.2) {
                        check(window.isMiniaturized, "Minimize (⌘M) minimizes the strip")
                        window.deminiaturize(nil)
                        after(1.2) {
                            placement.leaveStrip()
                            after(1.5) {
                                window.makeKeyAndOrderFront(nil)
                                _ = commandM()
                                after(1.2) {
                                    check(window.isMiniaturized && !placement.strip, "⌘M still minimizes the full window")
                                    window.deminiaturize(nil)
                                    after(1.2) { next() }
                                }
                            }
                        }
                    }
                }
            }
        }
        after(3) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            placement.resetStripWidths()
            UserDefaults.standard.removeObject(forKey: SpectrumPanel.stripShareKey)
            placement.enterStrip()
            after(2) { testPanels { testSplit { testMinimize { finish() } } } }
        }
    }

    /// Whether the toolbar shows and its leading item starts right of the window controls.
    @MainActor
    private static func toolbarClear(_ window: NSWindow) -> Bool {
        guard window.toolbar?.isVisible == true,
              let zoom = window.standardWindowButton(.zoomButton),
              let leading = window.toolbar?.items.compactMap({ $0.view }).filter({ $0.window != nil })
                  .map({ $0.convert($0.bounds, to: nil).minX }).min() else { return false }
        return leading >= zoom.convert(zoom.bounds, to: nil).maxX
    }

    @MainActor
    private static func chrome(_ window: NSWindow) -> String {
        let zoom = window.standardWindowButton(.zoomButton)
        let items = (window.toolbar?.items ?? []).compactMap { $0.view }.filter { $0.window != nil }
            .map { String(format: "%.0f", $0.convert($0.bounds, to: nil).minX) }
        return "toolbar=\(window.toolbar?.isVisible == true ? "shown" : "hidden") controls=\(zoom.map { $0.alphaValue > 0 ? "shown" : "hidden" } ?? "none")"
            + " controlsMaxX=\(zoom.map { String(format: "%.0f", $0.convert($0.bounds, to: nil).maxX) } ?? "-") itemsMinX=\(items)"
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

    /// `--test-dome-orbit`: from 4 s after launch, turns and tilts the Immersive dome for 5 s the way a drag does (one
    /// camera change per display frame, `DomeOrbit.step`), then prints the process CPU over those seconds, the canvases'
    /// frame rate and the longest gap between frames, and quits.
    @MainActor
    static func testDomeOrbitIfRequested(model: MeterModel) {
        guard CommandLine.arguments.contains("--test-dome-orbit") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let cpu = processCPU(), wall = CACurrentMediaTime(), ticks = CanvasDriver.shared.ticks
            var step = 0, last = CACurrentMediaTime(), longest = 0.0
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let now = CACurrentMediaTime()
                    longest = max(longest, now - last)
                    last = now
                    step += 1
                    DomeOrbit.step(model: model, yaw: Double(step) * 1.2, pitch: 40 + 20 * sin(Double(step) / 40))
                    guard step >= 300 else { return }
                    timer.invalidate()
                    let seconds = CACurrentMediaTime() - wall
                    print(String(format: "[orbit] CPU %.1f%% of one core over %.1f s, canvases %.1f fps, longest timer gap %.1f ms",
                                 (processCPU() - cpu) / seconds * 100, seconds,
                                 Double(CanvasDriver.shared.ticks - ticks) / seconds, longest * 1000))
                    fflush(stdout)
                    exit(0)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private static var rcStateStarted = false

    /// Isolated QA: cache invalidation, a held VU needle, and live readouts in a detached window with the main one hidden.
    @MainActor
    static func testRCStateIfRequested(model: MeterModel) {
        guard CommandLine.arguments.contains("--test-rc-state"), !rcStateStarted else { return }
        rcStateStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            var failures = 0
            func check(_ pass: Bool, _ name: String) {
                print("[rc-state] \(pass ? "PASS" : "FAIL"): \(name)")
                if !pass { failures += 1 }
            }
            let store = SpeakerLayoutStore.shared
            let layout = SpeakerLayout.s714
            let originalID = store.configuration(for: layout)?.id
            let settings = NebulaSettings()
            let original = store.geometry(for: layout, nebula: settings)
            check(original == store.geometry(for: layout, nebula: settings), "cached geometry preserves hash and revision")
            var custom = SpeakerConfiguration.standard(layout)
            custom.speakers[0].azimuth -= 15
            store.save(custom)
            store.select(custom.id, for: layout)
            let edited = store.geometry(for: layout, nebula: settings)
            check(edited.hash != original.hash && edited.revision != original.revision, "saving and selecting invalidates geometry")
            var detail = settings
            detail.particles += 1
            check(store.geometry(for: layout, nebula: detail).hash != edited.hash, "detail participates in cache key")
            detail = settings
            detail.window = settings.window == .standard ? .multiResolution : .standard
            check(store.geometry(for: layout, nebula: detail).hash != edited.hash, "analysis window participates in cache key")
            store.reload()
            check(store.geometry(for: layout, nebula: settings) == edited, "reload rebuilds the current geometry")
            store.delete(custom.id)
            store.select(originalID, for: layout)
            check(store.geometry(for: layout, nebula: settings).hash == original.hash, "delete and restore invalidate geometry")

            guard let main = MainWindow.window else { check(false, "main window exists"); exit(1) }
            let needle = VUNeedleView(model: model)
            main.contentView?.addSubview(needle)
            needle.update(running: true, frozen: false, held: false)
            check(needle.wantsFrames, "visible VU wants frames")
            needle.update(running: true, frozen: false, held: true)
            check(!needle.wantsFrames, "hidden VU holds without display callbacks")
            needle.update(running: true, frozen: false, held: false)
            check(needle.wantsFrames, "VU wakes after handover")
            needle.shutDown()
            needle.removeFromSuperview()

            let panel = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 240),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            PanelPlacement.shared.attached(.loudness, window: panel)
            panel.makeKeyAndOrderFront(nil)
            main.orderOut(nil)
            let elapsed = model.readouts.values.elapsed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                check(!main.occlusionState.contains(.visible) && PanelPlacement.shared.hasVisiblePanelWindows,
                      "detached panel remains visible with main window hidden")
                check(model.running && model.readouts.values.elapsed > elapsed, "detached panel receives live readouts")
                panel.close()
                PanelPlacement.shared.returned(.loudness)
                main.makeKeyAndOrderFront(nil)
                fflush(stdout)
                exit(failures == 0 ? 0 : 1)
            }
        }
    }

    /// `--test-frame-pacing <scenario>` (with `--diagnostic`): from 4 s after launch, records every wait between the
    /// canvases' display refreshes for 8 s while the scenario runs (`idle`; `orbit`, the dome turned as a drag turns it;
    /// `switch`, Stereo ↔ Immersive every 2 s), then prints the refresh rate, the wait's median, 99th percentile and
    /// longest, the share of refreshes that came late (a wait past 1.5 of the link's interval: a dropped frame), and the
    /// refreshes' own work; quits.
    @MainActor
    static func testFramePacingIfRequested(model: MeterModel) {
        guard let index = CommandLine.arguments.firstIndex(of: "--test-frame-pacing") else { return }
        let scenario = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : "idle"
        let saved = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["formatMode"]
        // `--test-screen <n>`: the meter window moved to display n first (the canvases follow it to that display's rate).
        if let screenIndex = CommandLine.arguments.firstIndex(of: "--test-screen").flatMap({ $0 + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[$0 + 1]) : nil }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard screenIndex < NSScreen.screens.count,
                      let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
                let area = NSScreen.screens[screenIndex].visibleFrame
                window.setFrame(NSRect(x: area.minX + 40, y: area.minY + 40, width: min(window.frame.width, area.width - 80),
                                       height: min(window.frame.height, area.height - 80)), display: true)
                print("[pacing] window on \(NSScreen.screens[screenIndex].localizedName)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let driver = CanvasDriver.shared
            let cpu = processCPU(), wall = CACurrentMediaTime()
            driver.startRecording()
            var step = 0
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
                MainActor.assumeIsolated {
                    step += 1
                    if scenario == "orbit" {
                        DomeOrbit.step(model: model, yaw: Double(step) * 1.2, pitch: 40 + 20 * sin(Double(step) / 40))
                    } else if scenario == "switch", step % 120 == 0 {
                        model.pin(step % 240 == 0 ? .stereo : .spatial)
                    }
                    guard step >= 480 else { return }
                    timer.invalidate()
                    driver.recording = false
                    SpectrogramScene.tracing = false
                    let seconds = CACurrentMediaTime() - wall
                    let waits = driver.intervals.sorted(), works = driver.works.sorted()
                    guard !waits.isEmpty else { print("[pacing] no refreshes"); exit(1) }
                    let interval = 1.0 / Double(driver.frameRate)
                    let late = waits.filter { $0 > interval * 1.5 }.count
                    func at(_ list: [CFTimeInterval], _ q: Double) -> Double { list[min(list.count - 1, Int(Double(list.count) * q))] * 1000 }
                    print(String(format: "[pacing] %@: %.1f refreshes/s, wait p50 %.2f ms p99 %.2f ms max %.1f ms, late %d of %d (%.1f%%), work p50 %.2f ms p99 %.2f ms max %.1f ms, CPU %.1f%%",
                                 scenario, Double(waits.count) / seconds, at(waits, 0.5), at(waits, 0.99), waits.last! * 1000,
                                 late, waits.count, Double(late) / Double(waits.count) * 100,
                                 at(works, 0.5), at(works, 0.99), (works.last ?? 0) * 1000, (processCPU() - cpu) / seconds * 100))
                    let trace = SpectrogramScene.scrollTrace
                    if trace.count > 10 {
                        // How evenly the spectrogram scrolls: each refresh's step (columns) against the mean step.
                        func evenness(_ values: [Double]) -> String {
                            let steps = zip(values.dropFirst(), values).map { $0 - $1 }
                            let mean = steps.reduce(0, +) / Double(steps.count)
                            let deviation = (steps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(steps.count)).squareRoot()
                            let stalls = steps.filter { $0 < mean * 0.25 }.count, jumps = steps.filter { $0 > mean * 1.75 }.count
                            return String(format: "step %.3f ± %.3f columns, %d stalls, %d jumps", mean, deviation, stalls, jumps)
                        }
                        print("[pacing] spectrogram scroll: now " + evenness(trace.map(\.0)) + "; build 99 " + evenness(trace.map(\.1)))
                    }
                    fflush(stdout)
                    if scenario == "switch" {
                        if let saved { UserDefaults.standard.set(saved, forKey: "formatMode") } else { UserDefaults.standard.removeObject(forKey: "formatMode") }
                        UserDefaults.standard.synchronize()
                    }
                    exit(0)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// `--test-mode-switch` (with `--diagnostic`): from 4 s after launch, switches Stereo ↔ Immersive every 1.5 s, six
    /// times, and after each switch prints the longest wait between display refreshes during its transition and the
    /// slowest refresh's own work; restores the saved mode, then quits.
    @MainActor
    static func testModeSwitchIfRequested(model: MeterModel) {
        guard CommandLine.arguments.contains("--test-mode-switch") else { return }
        let saved = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["formatMode"]
        func step(_ index: Int) {
            guard index < 6 else {
                if let saved { UserDefaults.standard.set(saved, forKey: "formatMode") } else { UserDefaults.standard.removeObject(forKey: "formatMode") }
                UserDefaults.standard.synchronize()
                exit(0)
            }
            CanvasDriver.shared.resetGap()
            let target: ChannelFormat = index % 2 == 0 ? .stereo : .spatial
            model.pin(target)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                print(String(format: "[mode] to %@: longest refresh gap %.1f ms, slowest refresh %.1f ms",
                             target == .spatial ? "Immersive" : "Stereo",
                             CanvasDriver.shared.longestGap * 1000, CanvasDriver.shared.slowestTick * 1000))
                fflush(stdout)
                step(index + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { step(0) }
    }

    /// `--test-settings-presets`: saves a preset of chosen values, changes them, loads the preset and checks each value
    /// is in effect again (in the model, the theme and the canvases), then loads the settings the run started with,
    /// deletes both presets and quits.
    @MainActor
    static func testSettingsPresetsIfRequested(model: MeterModel) {
        guard CommandLine.arguments.contains("--test-settings-presets") else { return }
        let presets = SettingsPresets.shared
        let defaults = UserDefaults.standard
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL"): \(what)")
        }
        func set(_ layout: SpeakerLayout, _ mode: AppearanceMode, target: Double, style: StageStyle, hidden: String) {
            model.speakerLayout = layout
            ThemeSettings.shared.mode = mode
            model.setTarget(target, spatial: false)
            defaults.set(style.rawValue, forKey: StageStyle.key)
            PanelPlacement.shared.setHidden(Set(hidden.split(separator: ",").compactMap { MeterPanel(rawValue: String($0)) }))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                presets.save(as: "QA original")
                set(.s714, .light, target: -23, style: .outline, hidden: "vu")
                presets.save(as: "QA preset")
                set(.s51, .dark, target: -14, style: .dots, hidden: "")
                guard let preset = presets.saved.first(where: { $0.name == "QA preset" }),
                      let original = presets.saved.first(where: { $0.name == "QA original" }) else { exit(1) }
                check(preset.values["inputDeviceUID"] == nil && !preset.values.keys.contains { $0.hasPrefix("NSWindow") },
                      "the source and window frames stay out of a preset")
                check(FileManager.default.fileExists(atPath: preset.url.path), "saved as a file: \(preset.url.lastPathComponent)")
                if let copy = presets.duplicate(preset) {
                    check(copy.name != preset.name && NSDictionary(dictionary: copy.values).isEqual(to: preset.values),
                          "duplicated as “\(copy.name)” with the same settings")
                    presets.delete(copy, permanently: true)
                } else {
                    check(false, "duplicate")
                }
                // A preset copied into the folder from outside (the Finder) shows without the app touching it.
                let outside = SettingsPresets.folder.appendingPathComponent("QA from Finder.plist")
                try? FileManager.default.copyItem(at: preset.url, to: outside)
                presets.load(preset, model: model)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated {
                        if let found = presets.saved.first(where: { $0.url.lastPathComponent == outside.lastPathComponent }) {
                            check(true, "a file added in the Finder shows as “\(found.name)”")
                            presets.delete(found, permanently: true)
                        } else {
                            check(false, "a file added in the Finder shows")
                            try? FileManager.default.removeItem(at: outside)
                        }
                        check(model.speakerLayout == .s714, "Immersive format: \(model.speakerLayout.name)")
                        check(ThemeSettings.shared.mode == .light, "appearance: \(ThemeSettings.shared.mode.rawValue)")
                        check(model.stereoTarget == -23, "Stereo target: \(model.stereoTarget)")
                        check(model.stageStyle == .outline, "Soundstage style on the canvases: \(model.stageStyle.rawValue)")
                        check(PanelPlacement.shared.hidden == [.vu], "hidden panels: \(PanelPlacement.shared.hidden.map(\.rawValue))")
                        presets.load(original, model: model)
                        presets.delete(preset, permanently: true)
                        presets.delete(original, permanently: true)
                        check(!presets.saved.contains { $0.name.hasPrefix("QA ") }, "test presets removed")
                        defaults.synchronize()
                        print(failures == 0 ? "settings presets: all checks passed" : "settings presets: \(failures) failed")
                        fflush(stdout)
                        exit(failures == 0 ? 0 : 1)
                    }
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

    /// `--analyze-file <audio>` opens the analysis window on that file; with `--analyze-report <path.pdf|path.csv>` it
    /// writes the report once the analysis is done and exits.
    @MainActor
    static func analyseFileIfRequested() {
        guard let path = argument("--analyze-file") else { return }
        let controller = FileAnalysisController.shared
        controller.analyse(URL(fileURLWithPath: path))
        // `--analyze-standard <id>` judges against that standard (`LoudnessStandard.id`).
        let standard = argument("--analyze-standard")
        var judged = standard == nil
        // `--analyze-window <path.png>`: captures the main window with the analysis panel once it is done, then exits.
        if let png = argument("--analyze-window") {
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
                MainActor.assumeIsolated {
                    guard case .done = controller.state, controller.shown, let window = MainWindow.window else { return }
                    timer.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                               [.boundsIgnoreFraming, .bestResolution]),
                           let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                            try? data.write(to: URL(fileURLWithPath: png))
                            print("analysis window: \(png)")
                        }
                        fflush(stdout)
                        exit(0)
                    }
                }
            }
            return
        }
        guard let output = argument("--analyze-report") else { return }
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            MainActor.assumeIsolated {
                switch controller.state {
                case .done(let data):
                    if !judged { judged = true; controller.standardID = standard; return }
                    timer.invalidate()
                    let url = URL(fileURLWithPath: output)
                    if output.hasSuffix(".csv") { try? data.csv.write(to: url, atomically: true, encoding: .utf8) }
                    else { try? LoudnessReportExport.writePDF(data, to: url) }
                    print("analysis report: \(output) · \(data.result.headline) · \(MeterScale.tenths(data.integrated)) LUFS · "
                          + "\(MeterScale.tenths(data.truePeak)) dBTP · LRA \(MeterScale.tenths(data.range))")
                    fflush(stdout)
                    if !snapshotRequested { exit(0) }
                case .failed(_, let message):
                    timer.invalidate()
                    print("analysis failed: \(message)")
                    fflush(stdout)
                    if !snapshotRequested { exit(1) }
                default: break
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
            if snapshotFullScreen && !window.styleMask.contains(.fullScreen) { MainWindow.toggleFullScreen() }
        }
        // `--snapshot-enlarge <panel>` enlarges a panel, `--snapshot-strip` turns the window into the strip,
        // `--snapshot-detach <panel>` opens a panel in a window of its own; `-layout.hiddenPanels a,b` hides panels for
        // the run only (the argument domain), so none of these touch the stored layout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let panel = argument("--snapshot-enlarge").flatMap(MeterPanel.init(rawValue:)) { PanelPlacement.shared.toggleEnlarged(panel) }
            if CommandLine.arguments.contains("--snapshot-strip") || CommandLine.arguments.contains("--snapshot-strip-return") {
                PanelPlacement.shared.enterStrip()
            }
            // `--snapshot-strip-return`: into the strip and back out before the capture.
            if CommandLine.arguments.contains("--snapshot-strip-return") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { PanelPlacement.shared.leaveStrip() }
            }
            if let panel = argument("--snapshot-detach").flatMap(MeterPanel.init(rawValue:)) { PanelPlacement.shared.requestWindow(panel) }
            // `--snapshot-speaker-layout <format>`: opens the Speaker Layout window on that channel format and captures it
            // instead of the meter window.
            if let format = argument("--snapshot-speaker-layout").flatMap(SpeakerLayout.init(rawValue:)) {
                SpeakerLayoutStore.shared.openEditor(for: format)
            }
        }
        // `--snapshot-report <path.pdf|path.csv>`: writes the loudness report just before the capture.
        if let path = argument("--snapshot-report") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
                guard let model = MeterModel.diagnosticInstance else { return }
                let data = LoudnessReportData.gather(model: model)
                let url = URL(fileURLWithPath: path)
                if path.hasSuffix(".csv") { try? data.csv.write(to: url, atomically: true, encoding: .utf8) }
                else { try? LoudnessReportExport.writePDF(data, to: url) }
                print("report: \(path)")
            }
        }
        // `--snapshot-view-switch <view>`: glides the Immersive dome to that view 0.2 s before the capture, to catch the
        // labels and the picture mid-glide.
        if let view = argument("--snapshot-view-switch").flatMap(DomeView.init(rawValue:)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + (snapshotFullScreen ? 7.8 : 5.8)) { DomeCamera.shared.select(view) }
        }
        // `--snapshot-band-switch`: switches both band settings 0.25 s before the capture, to catch the morph.
        if CommandLine.arguments.contains("--snapshot-band-switch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + (snapshotFullScreen ? 7.75 : 5.75)) {
                UserDefaults.standard.set(StereoBands.Resolution.overall.rawValue, forKey: "soundstage.bands")
                UserDefaults.standard.set(StereoBands.Resolution.three.rawValue, forKey: "levels.bands")
            }
        }
        if let transition = argument("--capture-transition") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { captureTransition(transition, window: window) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (snapshotFullScreen ? 8 : 6)) {
            print("capturing window \(window.windowNumber)")
            fflush(stdout)
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Auraliscope-window.png")
            // The welcome sheet has its own window; capture the screen area of the meter window to include it.
            let image: CGImage?
            if argument("--snapshot-speaker-layout") != nil,
               let editor = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(SpeakerLayoutEditor.windowID) == true && $0.isVisible }) {
                image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(editor.windowNumber),
                                                [.boundsIgnoreFraming, .bestResolution])
            } else if showWelcome || snapshotFullScreen || snapshotPanelSettings || snapshotWindowPanels, let screen = NSScreen.screens.first {
                // A popover reaching past the window is captured whole.
                let frame = NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
                    .reduce(window.frame) { $0.union($1.frame) }
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

    /// `--capture-transition <mode|enlarge:<panel>|strip>` (with `--snapshot`): starts that transition (Stereo ↔
    /// Immersive, a panel enlarging or restoring, into or out of Dock mode) and saves the window every display frame
    /// for 1.2 s as frame-NN.png in `--capture-folder` (the temporary directory otherwise), with each frame's time
    /// after the change in frames.txt, to review the motion frame by frame; then quits. Captured at 1×, kept in memory
    /// until the end, so the capture costs the transition as little as possible.
    @MainActor
    private static func captureTransition(_ transition: String, window: NSWindow) {
        let folder = URL(fileURLWithPath: argument("--capture-folder") ?? FileManager.default.temporaryDirectory.path)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var frames: [(time: Double, image: CGImage)] = []
        let start = CACurrentMediaTime()
        // `--capture-frames no`: no pictures, only the display's pacing through the transition.
        let grabs = argument("--capture-frames") != "no"
        CanvasDriver.shared.resetGap()
        CanvasDriver.shared.startRecording()
        func grab() {
            guard grabs else { return }
            if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                   [.boundsIgnoreFraming, .nominalResolution]) {
                frames.append((CACurrentMediaTime() - start, image))
            }
        }
        grab()
        switch transition {
        case "mode":
            if let model = MeterModel.diagnosticInstance { model.pin(model.format == .spatial ? .stereo : .spatial) }
        case "strip":
            PanelPlacement.shared.toggleStrip()
        default:
            if transition.hasPrefix("enlarge:"), let panel = MeterPanel(rawValue: String(transition.dropFirst(8))) {
                PanelPlacement.shared.toggleEnlarged(panel)
            }
            // `zoom-loop:<panel>`: enlarges and restores the panel every 0.6 s for 10 s (no pictures), for a profiler.
            if transition.hasPrefix("zoom-loop:"), let panel = MeterPanel(rawValue: String(transition.dropFirst(10))) {
                for step in 0..<16 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 * Double(step)) { PanelPlacement.shared.toggleEnlarged(panel) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    let driver = CanvasDriver.shared
                    let late = driver.intervals.filter { $0 > 1.5 / Double(driver.frameRate) }
                    print(String(format: "zoom loop: %d refreshes, %d late, longest %.1f ms", driver.intervals.count, late.count,
                                 driver.longestGap * 1000))
                    fflush(stdout)
                    exit(0)
                }
                return
            }
        }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
            MainActor.assumeIsolated {
                grab()
                guard CACurrentMediaTime() - start > 1.2 else { return }
                timer.invalidate()
                var times = ""
                for (index, frame) in frames.enumerated() {
                    let url = folder.appendingPathComponent(String(format: "frame-%02d.png", index))
                    if let output = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(output, frame.image, nil)
                        CGImageDestinationFinalize(output)
                    }
                    times += String(format: "%02d %.0f ms %dx%d\n", index, frame.time * 1000, frame.image.width, frame.image.height)
                }
                try? times.write(to: folder.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
                let driver = CanvasDriver.shared
                driver.recording = false
                let late = driver.intervals.filter { $0 > 1.5 / Double(driver.frameRate) }
                print(String(format: "captured %d frames to %@; %d refreshes, %d late (longest %.1f ms), slowest refresh %.1f ms",
                             frames.count, folder.path, driver.intervals.count, late.count, driver.longestGap * 1000,
                             driver.slowestTick * 1000))
                var elapsed = 0.0
                print("late refreshes: " + driver.intervals.compactMap { interval -> String? in
                    elapsed += interval
                    return interval > 1.5 / Double(driver.frameRate) ? String(format: "%.0f ms at %.0f ms", interval * 1000, elapsed * 1000) : nil
                }.joined(separator: ", "))
                fflush(stdout)
                exit(0)
            }
        }
    }

    /// `--test-language-switch`: while metering, switches the app language through every table, English and back
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
        let steps: [AppLanguage] = [.simplifiedChinese, .traditionalChinese, .japanese, .korean, .spanish, .english, .system]
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
        if snapshotRequested && snapshotPaused {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { model.toggleCapture() } }
        }
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

    /// `--test-theme-fade`: flips Light ↔ Dark from the toolbar's action, then captures the meter window at points
    /// through the cross-fade (`ThemeFade`) (or at `--fade-offsets`) from a background queue, so the captures never hold up the rebuild they
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
            // `--fade-offsets a,b,…` (ms) replaces the default points, e.g. to watch for anything that changes late.
            let offsets = argument("--fade-offsets")?.split(separator: ",").compactMap { Int($0) }
                ?? [0, 100, 170, 240, 310, 380, 450, 700]
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
        runDSPBenchmark(spatialSpectrum: false)
        runDSPBenchmark(spatialSpectrum: true, field: false)
        runDSPBenchmark(spatialSpectrum: true)
        runDSPBenchmark(spatialSpectrum: true, window: .multiResolution)
        print("This excludes CoreAudio, Metal, SwiftUI, WindowServer and audio driver CPU.")
    }

    /// `field`: whether Spatial analysis also builds the Immersive nebula's spatial field (it does in the app);
    /// `window`: the spatial observations' window (`SpatialGeometry.Window`).
    private static func runDSPBenchmark(spatialSpectrum: Bool, field: Bool = true, window: SpatialGeometry.Window = .standard) {
        let layout = SpeakerLayout.s916
        let active = (0..<Role.count).map(layout.contains)
        let tickFrames = Int(48_000 / MeterPipeline.tickRate)
        guard let pipeline = MeterPipeline(sampleRate: 48_000, activeRoles: active, detector: FormatDetector(), streamID: 1) else { exit(1) }
        pipeline.spatialSpectrum = spatialSpectrum
        pipeline.spectrum.buildsSpatialField = spatialSpectrum && field
        pipeline.spatialGeometry = SpatialGeometry.standard(roles: layout.roles, window: window)
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
                     spatialSpectrum ? (field ? (window == .multiResolution ? "Spatial (16-channel, spatial field built, multi-resolution observations)"
                                                      : "Spatial (16-channel, spatial field built)") : "Spatial (16-channel, no spatial field)") : "Stereo (L/R)",
                     SpectrumAnalyzer.historyLength(sampleRate: 48_000), MeterPipeline.tickRate,
                     MeterPipeline.tickRate / Double(MeterPipeline.windowTicks), elapsed, elapsed, checksum))
    }
}

/// The camera changes `--test-dome-orbit` makes, as the Soundstage's drag makes them (never saved: the test leaves the
/// person's camera as it was).
@MainActor
enum DomeOrbit {
    static func step(model: MeterModel, yaw: Double, pitch: Double) { DomeCamera.shared.orbit(yaw: yaw, pitch: pitch) }
}
