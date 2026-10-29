import AppKit
import Foundation
import Darwin

extension Diagnostics {
    private static var multiFFTLayoutStarted = false
    /// Actual view/divider callbacks, preferences and renderer lifecycle, with diagnostic PCM and a QA domain.
    @MainActor
    static func testMultiFFTLayoutIfRequested(model: MeterModel) {
        guard CommandLine.arguments.contains("--test-multifft-layout"), !multiFFTLayoutStarted else { return }
        multiFFTLayoutStarted = true
        Task { @MainActor in
            var failures = 0
            func check(_ value: Bool, _ message: String) {
                print("[multifft-layout] \(value ? "PASS" : "FAIL"): \(message)"); fflush(stdout)
                if !value { failures += 1 }
            }
            func settle(_ seconds: Double = 0.9) async {
                try? await Task.sleep(nanoseconds: UInt64(seconds*1_000_000_000))
            }
            @MainActor func dividers(_ view: NSView?) -> [PanelDividerView] {
                guard let view else { return [] }
                if let divider = view as? PanelDividerView { return [divider] }
                return view.subviews.flatMap { dividers($0) }
            }
            @MainActor func split(_ main: NSWindow) -> PanelDividerView? {
                dividers(main.contentView).first { $0.identifier?.rawValue == "multifft.split" }
            }
            await settle(0.5)
            guard let main = MainWindow.window else { check(false,"main window unavailable"); exit(1) }
            let placement = PanelPlacement.shared
            if !model.running { model.resume() }
            check(model.running, "model runs the diagnostic demo (no launch sheet holds it)")
            model.floating = true
            model.formatMode = .stereo
            UserDefaults.standard.set(0.5,forKey:MultiFFTStackLayout.shareKey)
            placement.setShown(.multiFFT,true)
            placement.setHidden([])
            // The default window size: room for the divider to move both ways while the panels below keep their minima.
            main.setContentSize(NSSize(width:1400,height:1060))
            // Launched from a shell the app may not be allowed to activate; a floating level and an unconditional
            // order-front keep the QA window unoccluded by other applications, which the drawing checks need.
            @MainActor func surface() {
                guard let main = MainWindow.window else { return }
                if main.level.rawValue < NSWindow.Level.floating.rawValue { main.level = .floating }
                // The screen under this window may be showing another Space (a full-screen app); join every Space.
                main.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
                main.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps:true)
            }
            surface()
            await settle(1.5)
            if !main.occlusionState.contains(.visible), let other = NSScreen.screens.first(where: { $0 != main.screen }) {
                var frame = main.frame
                frame.origin = CGPoint(x: other.visibleFrame.midX - frame.width / 2, y: other.visibleFrame.midY - frame.height / 2)
                main.setFrame(frame, display: true)
                surface()
                await settle(1.5)
            }
            check(main.occlusionState.contains(.visible), "QA main window is visible to the window server")
            for width in [CGFloat(720),1024,1400,1920] {
                let old = StripLayout.widths(PanelPlacement.defaultStrip,width:width,height:232,spatial:false,channels:2)
                let panels = PanelPlacement.defaultStrip.map { $0 == .spectrum ? MeterPanel.multiFFT : $0 }
                let new = StripLayout.widths(panels,width:width,height:232,spatial:false,channels:2)
                check(old == new && new.allSatisfy { $0 > 0 }
                      && abs(new.reduce(0,+)+CGFloat(panels.count-1)*StripLayout.gap-width) <= CGFloat(panels.count),
                      "automatic Dock sizing preserves spectrum width and nonzero cards at \(Int(width)) pt")
            }
            let serial = model.multiFFTFrame()?.serial
            check(serial != nil,"real diagnostic PCM produces Multi-FFT frames in grid")
            if let divider = split(main) {
                let original = divider.leading
                divider.onResize(original+24)
                await settle()
                check((split(main)?.leading ?? 0) > original+10,"native grid divider resizes Multi-FFT height")
                check(UserDefaults.standard.double(forKey:MultiFFTStackLayout.shareKey) > 0.5,"grid resize share persists")
                check(model.multiFFTFrame()?.serial != serial,"analysis keeps advancing while resizing")
                split(main)?.onReset()
                await settle()
                check(abs(UserDefaults.standard.double(forKey:MultiFFTStackLayout.shareKey)-0.5) < 0.001,"grid divider double-click callback resets share")
            } else { check(false,"native grid divider missing") }
            placement.setShown(.spectrum,false); placement.setShown(.waveform,false)
            await settle()
            check(split(main) == nil && model.multiFFTFrame() != nil,"Multi-FFT alone fills analysis area without redundant splitter")
            placement.setShown(.spectrum,true); placement.setShown(.waveform,true)
            placement.setStripPanels([.spectrum,.waveform])
            placement.setStripWidths([.spectrum:600,.waveform:400],room:1000)
            placement.toggleStrip()
            await settle(2)
            surface()
            await settle(0.5)
            check(placement.strip && placement.displayedStripPanels == [.multiFFT,.waveform],"Dock substitutes Multi-FFT exactly once in original spectrum slot")
            check(abs((placement.displayedStripShares[.multiFFT] ?? 0)-0.6) < 0.001,"Dock inherits spectrum width")
            check(!placement.splitsSpectrum,"legacy split-spectrum presentation disabled under Multi-FFT")
            let driver = CanvasDriver.shared
            let before = driver.drawingCounts()
            await settle(1)
            let after = driver.drawingCounts()
            print("[multifft-layout] INFO: Dock commits \(before.commits) -> \(after.commits)"); fflush(stdout)
            check((after.commits["spectrum"] ?? 0) == (before.commits["spectrum"] ?? 0)
                  && (after.commits["spectrogram"] ?? 0) == (before.commits["spectrogram"] ?? 0),
                  "replaced legacy spectrum/spectrogram submit no Metal draws")
            check((after.commits["waveform"] ?? 0) > (before.commits["waveform"] ?? 0),"other Dock panel remains live")
            if let gap = dividers(main.contentView).first(where:{ $0.identifier?.rawValue == "strip.gap" }) {
                let original = gap.leading
                gap.onResize(original+36)
                await settle()
                let resized = dividers(main.contentView).first(where:{ $0.identifier?.rawValue == "strip.gap" })?.leading ?? 0
                check(resized > original+20,"native Dock divider changes Multi-FFT width")
                check(placement.stripShares[.spectrum] != nil && placement.stripShares[.multiFFT] == nil,
                      "Dock resize persists to canonical spectrum width")
                let storedShare = placement.stripShares[.spectrum]
                placement.setShown(.multiFFT,false)
                await settle(1.2)
                let restored = dividers(main.contentView).first(where:{ $0.identifier?.rawValue == "strip.gap" })?.leading ?? 0
                check(placement.displayedStripPanels == [.spectrum,.waveform] && abs(restored-resized) < 2,
                      "disabling Beta restores legacy Spectrum at the resized width")
                check(model.multiFFTFrame() == nil,"disabling Beta stops diagnostic Multi-FFT analysis")
                placement.setShown(.multiFFT,true)
                await settle(1.2)
                check(placement.displayedStripPanels == [.multiFFT,.waveform] && placement.stripShares[.spectrum] == storedShare
                      && model.multiFFTFrame() != nil,"reenabling Beta resumes FFT and preserves Dock width")
            } else { check(false,"native Dock divider missing") }
            model.formatMode = .spatial
            model.configureSpectrumArchitecture()
            await settle()
            check(placement.displayedStripPanels == [.spectrum,.waveform],"Immersive mode retains supported legacy Spectrum")
            model.formatMode = .stereo
            model.configureSpectrumArchitecture()
            await settle(1.2)
            check(placement.displayedStripPanels == [.multiFFT,.waveform] && model.multiFFTFrame() != nil,"returning to Stereo restores Multi-FFT")
            placement.moveStripPanel(.multiFFT,by:1)
            check(placement.stripPanels == [.waveform,.spectrum] && placement.displayedStripPanels == [.waveform,.multiFFT],"Dock reorder targets the shared spectrum slot")
            placement.toggleStripPanel(.multiFFT)
            await settle(1.2)
            check(placement.displayedStripPanels == [.waveform] && model.multiFFTFrame() == nil,"removing Beta from Dock stops Multi-FFT analysis")
            placement.toggleStripPanel(.multiFFT)
            await settle(1.2)
            check(placement.displayedStripPanels == [.waveform,.multiFFT] && model.multiFFTFrame() != nil,"Dock menu can restore the shared slot")
            // Render economy: at the Economy preset the engine publishes about 10 frames/s while the panel's
            // timeline ticks at 30 Hz. The curves should render once per new frame, not once per tick, and the
            // static grid/labels should not be redrawn with every frame.
            MultiFFTPreferences.save(.make(.economy))
            await settle(1.5)
            surface()
            let renders0 = MultiFFTRenderCounter.shared.counts, serial0 = model.multiFFTFrame()?.serial ?? 0
            await settle(2)
            let renders1 = MultiFFTRenderCounter.shared.counts, serial1 = model.multiFFTFrame()?.serial ?? 0
            let frames = Int(serial1) - Int(serial0), curveRenders = renders1.curves - renders0.curves, gridRenders = renders1.grid - renders0.grid
            print("[multifft-layout] INFO: Economy 2 s sample: \(frames) engine frames, \(curveRenders) curve renders, \(gridRenders) grid renders"); fflush(stdout)
            check(frames >= 12 && frames <= 28, "Economy preset publishes about 10 frames/s in the Dock (\(frames) in 2 s)")
            check(curveRenders >= frames / 2, "the Dock plot renders while visible (\(curveRenders) renders for \(frames) frames)")
            check(curveRenders <= frames + 4, "curves render once per engine frame, not per 30 Hz tick")
            check(gridRenders <= 2, "static grid and labels are not redrawn per frame")
            MultiFFTPreferences.save(.make(.standard))
            await settle(1.5)
            let beforeWindow = model.multiFFTFrame()?.serial ?? 0
            placement.requestWindow(.multiFFT)
            for _ in 0..<40 {
                placement.focusWindow(.multiFFT)
                if placement.hasVisiblePanelWindows { break }
                await settle(0.1)
            }
            await settle()
            check(placement.detached.contains(.multiFFT) && placement.hasVisiblePanelWindows && model.multiFFTFrame() != nil,
                  "Multi-FFT remains live in independent resizable window")
            if let window = NSApp.windows.first(where: { $0 !== main && $0.isVisible && $0.title.contains("Multi-FFT") }) {
                window.setContentSize(NSSize(width:560,height:300))
                await settle()
                check(abs((window.contentView?.bounds.width ?? 0)-560) < 2
                      && abs((window.contentView?.bounds.height ?? 0)-300) < 2 && model.multiFFTFrame() != nil,
                      "independent Multi-FFT window resizes to 560 x 300 while analysis stays live")
            } else { check(false,"independent Multi-FFT window unavailable for resize") }
            let inWindow = model.multiFFTFrame()?.serial ?? 0
            check(inWindow > beforeWindow, "analysis continues without an engine restart when the panel moves to its own window (serial \(beforeWindow) -> \(inWindow))")
            placement.closeWindow(.multiFFT)
            await settle(1.2)
            check(!placement.detached.contains(.multiFFT) && model.multiFFTFrame() != nil,"closing independent window returns live Multi-FFT to Dock")
            let backInDock = model.multiFFTFrame()?.serial ?? 0
            check(backInDock > inWindow, "analysis continues without an engine restart when the window closes back to the Dock (serial \(inWindow) -> \(backInDock))")
            placement.setStripPanels([.spectrum,.waveform])
            print("[multifft-layout] FINISHED: \(failures) failures"); fflush(stdout)
            if CommandLine.arguments.contains("--hold-multifft-layout") { await settle(30) }
            exit(failures == 0 ? 0 : 1)
        }
    }
}
