import AnalysisCore
import Foundation

/// The spectrum engines behind the analysis panels, for whatever analysis the model runs: the Multi-FFT engine, which
/// runs while its panel is shown on a stereo source and stops a moment after the panel goes, and which shared STFT feeds
/// the spectrum and spectrogram (`LegacySTFT`). Keeps the stored settings of both and tells the current worker. Owned
/// by `MeterModel`, which decides when to configure (each frame, each restart, a format or panel change); main thread.
@MainActor
final class SpectrumEngineCoordinator {
    /// What the engines depend on, read from the model at each configuration.
    struct Inputs {
        var format: ChannelFormat
        var sourceIsBridge: Bool
        var enhancedSpectrogram: Bool
    }

    /// A panel that moves between the grid, the Dock and a window of its own disappears before it reappears; the engine
    /// and its history survive that moment instead of refilling.
    static let teardownDelay = 0.4

    /// The analysis running now (the model's worker); the delayed stop applies to the one running when it fires.
    private let worker: @MainActor () -> MeterWorker?
    private let preview = MultiFFTPreviewSource()
    private var panelUsers = 0
    private var loggedState = ""
    /// A pending stop of the engine.
    private var teardown: DispatchWorkItem?
    private var settingsData = MultiFFTPreferences.storedData
    private var settings = MultiFFTPreferences.stored
    private var legacySettings = MultiFFTPreferences.legacySTFT

    init(worker: @escaping @MainActor () -> MeterWorker?) {
        self.worker = worker
    }

    /// A Multi-FFT panel appeared (true) or disappeared (false).
    func panelVisible(_ visible: Bool) {
        panelUsers = max(0, panelUsers + (visible ? 1 : -1))
    }

    /// Takes up the stored settings after a defaults change. Every defaults write lands here, including each step of a
    /// divider drag: the Multi-FFT configuration is decoded only when its value changed.
    func reloadSettings() {
        let data = MultiFFTPreferences.storedData
        if data != settingsData {
            settingsData = data
            settings = MultiFFTPreferences.decode(data)
        }
        legacySettings = MultiFFTPreferences.legacySTFT
    }

    /// Starts the Multi-FFT engine while its panel is shown on a stereo source, or stops it after `teardownDelay`, and
    /// picks the shared STFT: the reassigned analysis in Immersive and for the Enhanced spectrogram, else the stored one.
    func configure(_ inputs: Inputs) {
        let placement = PanelPlacement.shared
        placement.setDockSupportsMultiFFT(inputs.format == .stereo && !inputs.sourceIsBridge)
        let visible = panelUsers > 0 && (placement.isShown(.multiFFT) || placement.detached.contains(.multiFFT) || (placement.strip && placement.displayedStripPanels.contains(.multiFFT)))
        let wanted = visible && inputs.format == .stereo ? settings : nil
        if Diagnostics.enabled {
            let state = "users \(panelUsers), shown \(placement.isShown(.multiFFT)), detached \(placement.detached.contains(.multiFFT)), dock \(placement.strip && placement.displayedStripPanels.contains(.multiFFT)), format \(inputs.format), bridge \(inputs.sourceIsBridge), wants \(wanted == nil ? "no engine" : wanted!.preset.rawValue)"
            if state != loggedState { loggedState = state; Diagnostics.log("[multifft] \(state)") }
        }
        if wanted != nil {
            teardown?.cancel(); teardown = nil
            apply(wanted, sourceIsBridge: inputs.sourceIsBridge)
        } else if teardown == nil {
            let pending = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.teardown = nil
                self.apply(nil, sourceIsBridge: inputs.sourceIsBridge)
            }
            teardown = pending
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.teardownDelay, execute: pending)
        }
        let choice: LegacySTFT = inputs.format == .spatial || inputs.enhancedSpectrogram ? .legacy : legacySettings
        worker()?.setLegacySTFT(choice)
    }

    /// The newest Multi-FFT frame while a stereo source runs (a held one while `frozen`); nil otherwise.
    func frame(_ inputs: Inputs, running: Bool, frozen: Bool) -> MultiFFTSnapshot? {
        guard inputs.format == .stereo, running else { return nil }
        if Diagnostics.demo, Diagnostics.multiFFTTestTone { return preview.latest() }
        return worker()?.latestMultiFFT(frozen: frozen)
    }

    private func apply(_ wanted: MultiFFTConfiguration?, sourceIsBridge: Bool) {
        if Diagnostics.demo, Diagnostics.multiFFTTestTone { preview.configure(wanted) }
        worker()?.setMultiFFT(!sourceIsBridge ? wanted : nil)
    }
}
