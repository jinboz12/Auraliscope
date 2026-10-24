import AppKit
import Foundation
import Darwin

extension Diagnostics {
    private static var panelDrawingStarted = false
    /// Run the actual native views/Metal driver with an isolated QA preference domain and --demo --diagnostic.
    /// No event synthesis, input device, DAW project or external application is involved.
    @MainActor
    static func testPanelDrawingIfRequested(model: MeterModel) {
        guard CommandLine.arguments.contains("--test-panel-drawing"), !panelDrawingStarted else { return }
        panelDrawingStarted = true
        Task { @MainActor in
            var failures = 0
            func check(_ value: Bool, _ message: String) {
                print("[panel-drawing] \(value ? "PASS" : "FAIL"): \(message)")
                fflush(stdout)
                if !value { failures += 1 }
            }
            func cpuSeconds() -> Double {
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                    + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)/1_000_000
            }
            func settle(_ seconds: Double = 0.8) async {
                try? await Task.sleep(nanoseconds: UInt64(seconds*1_000_000_000))
            }
            await settle(0.5)
            guard let main = MainWindow.window else { check(false,"main window unavailable"); exit(1) }
            let placement = PanelPlacement.shared
            let original = placement.hidden
            model.formatMode = .stereo
            // Keep QA visible if the tool UI regains focus; otherwise an occluded window is correctly asleep.
            model.floating = true
            main.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            placement.setHidden([.multiFFT])
            await settle(2)
            let driver = CanvasDriver.shared
            var counts = driver.drawingCounts()
            check(counts.activeCanvases >= 5 && counts.activeClients > 0,
                  "initial grid has Metal canvases and VU (\(counts.activeCanvases), \(counts.activeClients))")

            let visibleCPU = cpuSeconds(), visibleTime = ProcessInfo.processInfo.systemUptime
            await settle(1)
            let visiblePercent = (cpuSeconds()-visibleCPU)/(ProcessInfo.processInfo.systemUptime-visibleTime)*100
            placement.setHidden(Set(MeterPanel.allCases.filter { $0 != .loudness }))
            await settle(0.6)
            let hidden = driver.drawingCounts()
            let sequence = model.pollSnapshot().sequence
            let hiddenCPU = cpuSeconds(), hiddenTime = ProcessInfo.processInfo.systemUptime
            await settle(1)
            let hiddenPercent = (cpuSeconds()-hiddenCPU)/(ProcessInfo.processInfo.systemUptime-hiddenTime)*100
            print(String(format:"[panel-drawing] INFO: demo app CPU visible %.1f%%, hidden plots %.1f%% (one-second samples)",visiblePercent,hiddenPercent))
            counts = driver.drawingCounts()
            check(counts.activeCanvases == 0 && counts.activeClients == 0 && !driver.running,
                  "all native plots hidden: zero active clients and stopped display link")
            check(counts.commits == hidden.commits && counts.clientSteps == hidden.clientSteps,
                  "hidden panels submit zero Metal draws and zero VU steps over one second")
            check(model.running && model.pollSnapshot().sequence != sequence,
                  "analysis/readout clock continues while drawings are hidden")

            placement.setShown(.waveform,true)
            await settle(1)
            let revealed = driver.drawingCounts()
            print("[panel-drawing] INFO: reveal main visible=\(main.isVisible) occlusion=\(main.occlusionState.contains(.visible)) active=\(revealed.activeCanvases)")
            check(revealed.activeCanvases == 1 && (revealed.commits["waveform"] ?? 0) > (counts.commits["waveform"] ?? 0),
                  "revealed waveform resumes drawing without restarting capture")
            placement.setShown(.vu,true)
            await settle()
            let vu = driver.drawingCounts()
            check(vu.activeClients > 0,"revealed VU resumes its client")
            placement.setShown(.vu,false)
            await settle(0.6)
            let vuHidden = driver.drawingCounts()
            await settle(0.7)
            check(driver.drawingCounts().clientSteps == vuHidden.clientSteps,"hidden VU stops even while waveform keeps drawing")

            placement.requestWindow(.waveform)
            for _ in 0..<40 {
                placement.focusWindow(.waveform)
                NSApp.activate(ignoringOtherApps: true)
                if placement.hasVisiblePanelWindows { break }
                await settle(0.1)
            }
            await settle(0.5)
            print("[panel-drawing] INFO: detached=\(placement.detached.contains(.waveform)) pending=\(String(describing: placement.windowRequest)) windows=\(NSApp.windows.map { ($0.title,$0.isVisible,$0.occlusionState.contains(.visible)) })")
            check(placement.detached.contains(.waveform) && placement.hasVisiblePanelWindows,"waveform is in a visible independent window")
            let beforeDetached = driver.drawingCounts()
            main.miniaturize(nil)
            await settle(1)
            let detached = driver.drawingCounts()
            check(detached.activeCanvases == 1 && (detached.commits["waveform"] ?? 0) > (beforeDetached.commits["waveform"] ?? 0),
                  "visible detached waveform keeps drawing with main window minimized")
            placement.closeWindow(.waveform)
            await settle()
            check(driver.drawingCounts().activeCanvases == 0 && !driver.running,"closing detached window stops remaining drawings while main stays minimized")
            main.deminiaturize(nil)
            main.makeKeyAndOrderFront(nil)
            await settle(1)
            check(driver.drawingCounts().activeCanvases == 1,"restoring main window wakes the waveform")

            placement.setHidden(original)
            print("[panel-drawing] FINISHED: \(failures) failures")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }
}
