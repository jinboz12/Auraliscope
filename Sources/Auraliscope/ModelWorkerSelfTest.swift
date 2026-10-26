import AnalysisCore
import Foundation

/// `--test-model-worker`: the model's calls to its meter worker, checked with a recording worker in place of the
/// analysis, so no device is needed. Covers what each display frame passes to the worker (the display's settings), the
/// Multi-FFT engine's start and teardown, the true-peak reset, stopping, and worker replacement; and that the model
/// still draws a frame with no worker. Source switching, capture start and pause/resume need a running capture, so
/// they are not covered here.
enum ModelWorkerSelfTest {
    /// Counts what the model asked of it.
    final class Recording: MeterWorker {
        var spatialSpectrum: [Bool] = []
        var spectrogramModes: [SpectrogramMode] = []
        var legacy: [LegacySTFT] = []
        var thresholds: [Float] = []
        var multiFFTActive = false
        var multiFFTCalls = 0
        var truePeakResets = 0
        var stops = 0
        var calls: Int { spatialSpectrum.count + spectrogramModes.count + legacy.count + thresholds.count + multiFFTCalls + truePeakResets + stops }

        func latest() -> MeterSnapshot? { nil }
        func pause() {}
        func resume() {}
        func stop() { stops += 1 }
        func resetTruePeaks() { truePeakResets += 1 }
        func setSpatialSpectrum(_ spatial: Bool) { spatialSpectrum.append(spatial) }
        func setSpectrogramMode(_ mode: SpectrogramMode) { spectrogramModes.append(mode) }
        func setSpatialField(threshold: Float, geometry: SpatialGeometry) { thresholds.append(threshold) }
        func setMultiFFT(_ configuration: MultiFFTConfiguration?) {
            multiFFTActive = configuration != nil
            multiFFTCalls += 1
        }
        func latestMultiFFT(frozen: Bool) -> MultiFFTSnapshot? { nil }
        func setLegacySTFT(_ choice: LegacySTFT) { legacy.append(choice) }
    }

    /// Runs the checks once, when the flag is present, after the model has finished starting (its launch work would
    /// otherwise replace the recording worker); exits with 0 when all pass, 1 otherwise.
    @MainActor
    static func runIfRequested(model: MeterModel) {
        guard CommandLine.arguments.contains("--test-model-worker") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated { run(model: model) }
        }
    }

    @MainActor
    private static func run(model: MeterModel) {
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            print("PASS: \(message)")
            fflush(stdout)
        }
        let placement = PanelPlacement.shared
        let wasShown = placement.isShown(.multiFFT)
        let first = Recording(), second = Recording()
        model.setWorkerForTesting(first)
        model.pin(.stereo)

        // Each display frame passes the display's settings to the worker.
        model.displayOptions.spectrogramAnalysis = .enhanced
        _ = model.canvasFrame()
        check(first.spectrogramModes.last == .enhanced, "the enhanced spectrogram is passed to the worker")
        check(first.legacy.last == .legacy, "the enhanced spectrogram uses the reassigned analysis, not the shared STFT")
        check(first.spatialSpectrum.last == false, "a stereo source is not analysed as a spatial spectrum")
        model.displayOptions.spectrogramAnalysis = .classic
        _ = model.canvasFrame()
        check(first.spectrogramModes.last == .classic, "the classic spectrogram is passed back to the worker")

        model.pin(.spatial)
        _ = model.canvasFrame()
        check(first.spatialSpectrum.last == true, "an immersive source is analysed as a spatial spectrum")
        model.pin(.stereo)
        let threshold = model.displayOptions.nebula.threshold
        _ = model.canvasFrame()
        check(first.thresholds.last == threshold, "the nebula's coherence threshold is passed to the worker")

        // The true-peak reset reaches the analysis once per request.
        let resets = first.truePeakResets
        model.resetTruePeak()
        check(first.truePeakResets == resets + 1, "a true-peak reset is passed to the worker once")

        // Multi-FFT: started while its panel is shown, stopped after the panel is hidden (after the teardown delay).
        placement.setShown(.multiFFT, true)
        model.multiFFTPanelVisible(true)
        _ = model.canvasFrame()
        check(first.multiFFTActive, "the Multi-FFT engine starts when its panel is shown on a stereo source")
        placement.setShown(.multiFFT, false)
        model.multiFFTPanelVisible(false)
        _ = model.canvasFrame()
        let teardown = Double(MeterModel.multiFFTTeardownDelay) + 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + teardown) {
            MainActor.assumeIsolated {
                check(!first.multiFFTActive, "the Multi-FFT engine stops once its panel has been hidden")
                // Stopping: the model releases the worker and asks it to stop, and then passes it nothing more.
                model.stop()
                check(first.stops == 1, "stopping the model stops its worker once")
                let before = first.calls
                _ = model.canvasFrame()
                check(first.calls == before, "after a stop the old worker receives no further calls")
                // Replacement: a new worker takes over the frames.
                model.setWorkerForTesting(second)
                _ = model.canvasFrame()
                check(second.calls > 0 && first.calls == before, "a replacement worker receives the frames, the old one none")
                // No worker at all: the model still builds a frame.
                model.setWorkerForTesting(nil)
                let frame = model.canvasFrame()
                check(frame.snapshot.sequence >= 0, "with no worker the model still builds a frame")
                placement.setShown(.multiFFT, wasShown)
                print("PASS: model worker checks complete")
                exit(0)
            }
        }
    }
}
