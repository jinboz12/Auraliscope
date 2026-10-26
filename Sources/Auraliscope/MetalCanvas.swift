import AnalysisCore
import AppKit
import AudioRing
import AudioToolbox
import Combine
import ImageIO
import MetalKit
import SwiftUI

enum CanvasKind: String {
    case spectrum, spectrogram, waveform, soundstage, levels
    var panel: MeterPanel {
        switch self {
        case .spectrum, .spectrogram: return .spectrum
        case .waveform: return .waveform
        case .soundstage: return .soundstage
        case .levels: return .levels
        }
    }
}

/// Everything a scene needs for one frame, read on the main thread.
struct CanvasFrame {
    var snapshot = MeterSnapshot()
    var sampleRate: Double = 48_000
    var running = false
    /// Paused with the picture held: scenes draw the last snapshot as if live, but take in nothing new and let no
    /// signal decay, fade or scroll. Layout transitions (format, bands) still animate.
    var frozen = false
    /// The signal is on display: capturing, or paused and held.
    var shown: Bool { running || frozen }
    /// Seconds for signal decays this frame: none while frozen.
    func signal(_ dt: Float) -> Float { frozen ? 0 : dt }
    var activeRoles = [Bool](repeating: true, count: Role.count)
    var epoch = 0
    /// Effective channel format; extended channels recede when `spatial` is false, and R too when `mono` is true.
    var spatial = true
    var mono = false
    /// The multichannel layout Spatial mode shows.
    var layout = SpeakerLayout.standard
    /// Requested width of the Spectrum card's live spectrum (`SpectrogramLayout`), 0 for automatic.
    var spectrumStrip: CGFloat = 0
    /// Changes when TRUE PEAK is reset on its own (see `MeterModel.resetTruePeak`).
    var truePeakEpoch = 0
    /// Band resolution of the Soundstage (stereometer, band map) and of the Channel Levels correlation bar.
    var stageBands = StereoBands.Resolution.five
    var levelsBands = StereoBands.Resolution.five
    /// How the Stereo stereometer draws its bands.
    var stageStyle = StageStyle.dots
    var options = DisplayOptions()
    /// Where the speakers are drawn and how Radiant maps observations (`SpatialGeometry`): the layout the model shows
    /// for this source (the user's, or the standard one for a plugin that computes with it). The nebula draws only
    /// observations computed with exactly this geometry (its hash).
    var geometry = SpatialGeometry.standard(roles: SpeakerLayout.standard.roles)
}

/// Critically damped format transition (Stereo ↔ Spatial, or Stereo ↔ Mono), matched to the SwiftUI `formatShift` spring (response
/// 0.55 s), so Metal scenes and their SwiftUI labels move as one.
struct PresenceSpring {
    static let omega: Float = 2 * .pi / 0.55
    /// 1 = full layout, 0 = stereo. Negative until the first frame, which snaps to the target.
    private(set) var value: Float = -1
    private var velocity: Float = 0
    /// The target of the last step.
    private var target: Float = -1

    mutating func step(target: Float, dt: Float) {
        guard value >= 0 else { value = target; self.target = target; return }
        // A new target starts moving on the frame that first draws it, as a SwiftUI animation starts with its
        // transaction: the time since the previous frame (a long one, while the change was being laid out) belongs to
        // the old target. Otherwise the canvas would start a step ahead of the labels animating beside it.
        let dt = target == self.target ? dt : 0
        self.target = target
        let displacement = value - target
        let factor = exp(-Self.omega * dt)
        let impulse = velocity + Self.omega * displacement
        value = min(1, max(0, target + (displacement + impulse * dt) * factor))
        velocity = (velocity - Self.omega * impulse * dt) * factor
        if abs(value - target) < 0.001 && abs(velocity) < 0.01 {
            value = target
            velocity = 0
        }
    }

    var settled: Bool { velocity == 0 }

    /// Starts a new transition from 0 (used by `BandTransition`, which always springs toward 1).
    mutating func restart() {
        value = 0
        velocity = 0
        target = -1
    }
}

/// A band switch (full band ↔ 3 ↔ 5) as a morph on the same critically damped 0.55 s spring as the format
/// transitions and the SwiftUI `formatShift`: the outgoing resolution fades out while the incoming one fades in,
/// and the correlation bar's height glides between their lane counts.
struct BandTransition {
    private(set) var from = StereoBands.Resolution.five
    private(set) var to = StereoBands.Resolution.five
    private var spring = PresenceSpring()
    private var started = false

    mutating func step(target: StereoBands.Resolution, dt: Float) {
        if !started {
            started = true
            from = target
            to = target
            spring.step(target: 1, dt: dt)
        } else if target != to {
            // A switch mid-transition starts from whichever set is showing more.
            from = progress < 0.5 ? from : to
            to = target
            spring.restart()
        }
        spring.step(target: 1, dt: dt)
    }

    /// 0 at the start of a switch, 1 once it has settled.
    var progress: Float { max(0, spring.value) }
    /// Lane count for the layout, between the two resolutions' counts.
    var lanes: CGFloat { CGFloat(from.count) + CGFloat(to.count - from.count) * CGFloat(progress) }
    /// The resolutions to draw and their opacity: one while settled, both during a switch.
    var layers: [(resolution: StereoBands.Resolution, weight: Float)] {
        progress >= 0.999 || from == to ? [(to, Float(1))] : [(from, (1 - progress) * (1 - progress)), (to, progress * progress)]
    }
}

/// A transparent MTKView that draws one scene at the display rate, driven by `CanvasDriver`. All text lives
/// in SwiftUI overlays.
struct MeterCanvas: NSViewRepresentable {
    let kind: CanvasKind
    let model: MeterModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model, kind: kind) }

    func makeNSView(context: Context) -> MTKView {
        let view = CanvasView(frame: .zero, device: nil)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.framebufferOnly = true
        // No display timer of its own: `CanvasDriver` draws every canvas from one display link.
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.layer?.isOpaque = false
        // The drawable follows the view's size and backing scale; during a divider drag the next display
        // tick redraws at the new size from the same layout math.
        view.autoResizeDrawable = true
        if let layer = view.layer as? CAMetalLayer { layer.displaySyncEnabled = true }
        do {
            let gpu = try MeterGPU.shared.get()
            view.device = gpu.device
            context.coordinator.renderer = try SceneStore.renderer(kind, gpu: gpu)
            CanvasDriver.shared.follow(model)
        } catch {
            let message = StatusMessage { L("Metal failed to start: %@", error.localizedDescription) }
            Task { @MainActor in model.reportRendererError(message) }
        }
        context.coordinator.panelContext = context.environment.panelContext
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.forceRedraw = true
        context.coordinator.held = context.environment.canvasesHeld
        context.coordinator.panelContext = context.environment.panelContext
        (view as? CanvasView)?.wake()
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        if let canvas = view as? CanvasView { CanvasDriver.shared.remove(canvas) }
        (view as? CanvasView)?.coordinator = nil
        view.delegate = nil
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let model: MeterModel
        let kind: CanvasKind
        var renderer: CanvasRenderer?
        var forceRedraw = true
        /// Holds its last picture without drawing (`EnvironmentValues.canvasesHeld`).
        var held = false
        var panelContext = PanelContext.grid
        private(set) var renderedFrames = 0
        /// The frame `CanvasDriver` read from the model for this display refresh, shared by every canvas.
        var nextFrame: CanvasFrame?
        /// The display refresh's command buffer, shared by every canvas and committed once by `CanvasDriver`.
        var sharedCommand: MTLCommandBuffer?
        private var callbackCount = 0
        private var commitCount = 0
        private var maximumVertexCount = 0
        private var counterStart = CFAbsoluteTimeGetCurrent()

        init(model: MeterModel, kind: CanvasKind) {
            self.model = model
            self.kind = kind
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            forceRedraw = true
            (view as? CanvasView)?.wake()
        }

        func draw(in view: MTKView) {
            // `CanvasDriver` calls this through `MTKView.draw()` on the main thread.
            MainActor.assumeIsolated {
                guard !held, (view as? CanvasView)?.wantsFrames == true else {
                    nextFrame = nil; sharedCommand = nil
                    return
                }
                let frame = nextFrame ?? model.canvasFrame()
                let command = sharedCommand
                nextFrame = nil
                sharedCommand = nil
                guard let renderer, view.bounds.width > 0, view.bounds.height > 0 else { return }
                let committed = renderer.draw(in: view, frame: frame, force: forceRedraw, command: command)
                // A busy GPU or an unavailable drawable must not consume a requested redraw.
                if committed {
                    forceRedraw = false; renderedFrames += 1
                    CanvasDriver.shared.noteCommit(kind)
                }
                // Paused capture whose damped bars and holds have come to rest: leave the driver's rounds until
                // SwiftUI, a resize or the window wakes the canvas again.
                if renderer.settled, !frame.running { (view as? CanvasView)?.rest() }
                if Diagnostics.enabled {
                    callbackCount += 1
                    if committed { commitCount += 1 }
                    maximumVertexCount = max(maximumVertexCount, renderer.lastVertexCount)
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - counterStart >= 1 {
                        Diagnostics.log("[\(kind.rawValue)] display callbacks: \(callbackCount) Hz, Metal commits: \(commitCount) Hz, max vertices: \(maximumVertexCount)")
                        callbackCount = 0
                        commitCount = 0
                        maximumVertexCount = 0
                        counterStart = now
                    }
                }
            }
        }
    }
}

private struct CanvasesHeldKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// The canvases below hold their last picture and draw nothing: the grid receding behind an enlarging panel
    /// (`PanelZoom`), which is gone a moment later, frees the display refreshes for the panel's own zoom.
    var canvasesHeld: Bool {
        get { self[CanvasesHeldKey.self] }
        set { self[CanvasesHeldKey.self] = newValue }
    }
}

/// MTKView that only asks for frames while it has something to show: the window is on screen (not minimised,
/// not covered by a full-screen DAW, not on another Space) and the picture is still moving. Hidden, the canvases
/// cost nothing; the DSP keeps measuring, so integrated loudness stays complete.
final class CanvasView: MTKView {
    weak var coordinator: MeterCanvas.Coordinator?
    private var occlusionObserver: NSObjectProtocol?
    private var resting = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                       object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wake() }
            }
            CanvasDriver.shared.add(self)
        } else {
            CanvasDriver.shared.remove(self)
        }
        wake()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { wake() }
    }

    /// On screen, sized, not at rest and not held.
    var wantsFrames: Bool {
        guard !resting, let coordinator, !coordinator.held, panelPhysicallyVisible else { return false }
        return PanelPlacement.shared.permitsDrawing(coordinator.kind.panel, context: coordinator.panelContext)
    }

    /// Over the Immersive soundstage the scroll wheel (or two fingers) zooms on the listener.
    override func scrollWheel(with event: NSEvent) {
        guard let coordinator, coordinator.kind == .soundstage, coordinator.model.format == .spatial else {
            return super.scrollWheel(with: event)
        }
        let delta = event.hasPreciseScrollingDeltas ? Double(event.scrollingDeltaY) * 0.004 : Double(event.scrollingDeltaY) * 0.06
        guard delta != 0 else { return }
        DomeCamera.shared.scroll(delta: delta, smooth: !event.hasPreciseScrollingDeltas)
        wake()
    }

    /// Back into the driver's rounds (which starts its display link if it had stopped).
    func wake() {
        resting = false
        CanvasDriver.shared.wake()
    }

    /// Out of the driver's rounds until the next `wake()`.
    func rest() { resting = true }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }
}

/// Something besides the canvases that moves at the display rate on the driver's link (the VU needle).
@MainActor
protocol DisplayFrameClient: AnyObject {
    var wantsFrames: Bool { get }
    var window: NSWindow? { get }
    func displayFrame()
}

/// Draws every canvas of the meter window from one display link. The model's frame is read once per display
/// refresh and shared by the canvases that want one; a display link per canvas instead multiplied the display
/// timing work and the model reads by the number of panels. With every canvas at rest or hidden, the link stops.
/// The VU needle steps on the same link (`DisplayFrameClient`), so it moves with the canvases in the same refresh.
/// The rate the meters' display link runs at, for the status bar: published apart from the driver, and only when it
/// changes, so starting the link inside a view update never publishes from it.
@MainActor
final class DisplayRateStatus: ObservableObject {
    static let shared = DisplayRateStatus()
    @Published private(set) var fps = 0

    func note(_ rate: Int) {
        guard rate != fps else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.fps = rate } }
    }
}

@MainActor
final class CanvasDriver: NSObject {
    static let shared = CanvasDriver()
    private let canvases = NSHashTable<CanvasView>.weakObjects()
    private let clients = NSHashTable<AnyObject>.weakObjects()
    private var ticker: AnyObject?
    private var modelChanges: AnyCancellable?
    private var placementChanges: AnyCancellable?
    private var placementWake: DispatchWorkItem?
    /// Display refreshes drawn so far (diagnostics check that paused canvases rest and resumed ones draw).
    private(set) var ticks = 0
    private var commitCounts: [String: Int] = [:]
    private var clientSteps = 0
    func noteCommit(_ kind: CanvasKind) {
        if Diagnostics.enabled { commitCounts[kind.rawValue, default: 0] += 1 }
    }
    /// With diagnostics on: the longest wait between two display refreshes since `resetGap()` (a dropped frame shows
    /// as a wait of two refreshes or more), and the work of the slowest refresh.
    private(set) var longestGap: CFTimeInterval = 0
    private(set) var slowestTick: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    func resetGap() { longestGap = 0; slowestTick = 0; lastTick = 0 }
    /// With diagnostics on, every wait between refreshes (seconds) and each refresh's own work while `recording`.
    var recording = false
    private(set) var intervals: [CFTimeInterval] = []
    private(set) var works: [CFTimeInterval] = []
    func startRecording() {
        intervals.removeAll(); works.removeAll(); lastTick = 0; recording = true
        SpectrogramScene.scrollTrace.removeAll(); SpectrogramScene.tracing = true
    }
    var running: Bool { ticker != nil }

    /// The meters' display rate: 60, 30, or 0 for automatic (30 in Low Power Mode, 60 otherwise). The scenes step
    /// by measured time, so every decay, scroll and spring runs at the same speed at either rate.
    nonisolated static let frameRateKey = "display.frameRate"
    private var powerObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    /// The rate the running link was started at.
    private var linkRate: Float = 0

    var frameRate: Int {
        switch UserDefaults.standard.integer(forKey: Self.frameRateKey) {
        case 30: return 30
        case 60: return 60
        case 120: return displayRate
        default: return ProcessInfo.processInfo.isLowPowerModeEnabled ? 30 : displayRate
        }
    }

    /// The fastest the display showing the meters refreshes, 60 to 120 (a ProMotion display's 120).
    private var displayRate: Int {
        let window = canvases.allObjects.first(where: \.wantsFrames)?.window ?? activeClients.first?.window
        let screen = window?.screen ?? NSScreen.main
        return max(60, min(120, screen?.maximumFramesPerSecond ?? 60))
    }

    /// When the frame being drawn reaches the screen: the display link's target time during a refresh, so every scene
    /// steps its motion by the same, even interval (the moment each draw happens to run varies by a millisecond or two,
    /// which shows as judder); the current time outside one. Set and read on the main thread only.
    nonisolated(unsafe) private static var frameTime: CFTimeInterval = 0
    nonisolated(unsafe) private static var inTick = false
    nonisolated static var now: CFTimeInterval { inTick ? frameTime : CACurrentMediaTime() }

    /// Picks up a new frame rate: the display link starts again at it.
    func restart() {
        stop()
        wake()
        NotificationCenter.default.post(name: Self.frameRateChanged, object: nil)
    }
    static let frameRateChanged = Notification.Name("AuraliscopeFrameRateChanged")

    func add(_ view: CanvasView) { canvases.add(view) }
    func remove(_ view: CanvasView) { canvases.remove(view); reconcile() }

    /// A client steps at every refresh while it wants frames; `wake()` starts the link for it.
    func add(client: DisplayFrameClient) {
        clients.add(client)
        wake()
    }
    func remove(client: DisplayFrameClient) { clients.remove(client); reconcile() }
    /// Stop the shared display link when its final visible native client leaves.
    private func reconcile() {
        if !canvases.allObjects.contains(where: \.wantsFrames) && activeClients.isEmpty { stop() }
    }
    struct DrawingCounts {
        let activeCanvases: Int
        let activeClients: Int
        let commits: [String: Int]
        let clientSteps: Int
    }
    func drawingCounts() -> DrawingCounts {
        DrawingCounts(activeCanvases: canvases.allObjects.filter(\.wantsFrames).count,
                      activeClients: activeClients.count, commits: commitCounts, clientSteps: clientSteps)
    }
    private var activeClients: [DisplayFrameClient] {
        clients.allObjects.compactMap { $0 as? DisplayFrameClient }.filter(\.wantsFrames)
    }

    /// Every change the model publishes wakes the canvases. Resuming capture, a reset or an over cleared while
    /// paused must reach canvases that went to rest, and the panels around them re-render only when their own
    /// inputs change, which none of these do.
    func follow(_ model: MeterModel) {
        guard modelChanges == nil else { return }
        modelChanges = model.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.wakeAll() }
        }
        placementChanges = PanelPlacement.shared.objectWillChange.sink { [weak self] _ in
            // Published placement changes arrive before the new value. Reconcile next turn, and once more
            // after the panel's opacity transition: a newly attached view may initially have zero visible area.
            DispatchQueue.main.async { [weak self] in
                self?.reconcile(); self?.wakeAll(); self?.wake()
            }
            MainActor.assumeIsolated {
                self?.placementWake?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.wakeAll(); self?.wake() }
                }
                self?.placementWake = work
                DispatchQueue.main.asyncAfter(deadline: .now()+0.6, execute: work)
            }
        }
    }

    private func wakeAll() {
        for view in canvases.allObjects { view.wake() }
    }

    /// Starts the display link if a canvas wants frames.
    func wake() {
        guard ticker == nil,
              let window = canvases.allObjects.first(where: \.wantsFrames)?.window ?? activeClients.first?.window else { return }
        if powerObserver == nil {
            powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                                                   queue: .main) { _ in
                MainActor.assumeIsolated { CanvasDriver.shared.restart() }
            }
        }
        let rate = Float(frameRate)
        Diagnostics.log("[canvas] display link at \(Int(rate)) fps on \(window.screen?.localizedName ?? "no screen")")
        if screenObserver == nil {
            // A window moved to a display of another rate (a ProMotion laptop's and an external one): start again at it.
            screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil,
                                                                    queue: .main) { _ in
                MainActor.assumeIsolated {
                    let driver = CanvasDriver.shared
                    if driver.ticker != nil, Float(driver.frameRate) != driver.linkRate { driver.restart() }
                }
            }
        }
        linkRate = rate
        DisplayRateStatus.shared.note(Int(rate))
        if #available(macOS 14, *) {
            // Follows the window to whichever display it is on, at that display's own rate (Automatic) or the one chosen.
            let link = window.displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, rate), maximum: rate, preferred: rate)
            link.add(to: .main, forMode: .common)
            ticker = link
        } else {
            let timer = Timer(timeInterval: 1 / Double(rate), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick(nil) }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
    }

    private func stop() {
        if #available(macOS 14, *), let link = ticker as? CADisplayLink { link.invalidate() }
        (ticker as? Timer)?.invalidate()
        ticker = nil
        DisplayRateStatus.shared.note(0)
    }

    @objc private func tick(_ sender: AnyObject?) {
        let started = Diagnostics.enabled ? CACurrentMediaTime() : 0
        if #available(macOS 14, *), let link = sender as? CADisplayLink {
            Self.frameTime = link.targetTimestamp
        } else {
            Self.frameTime = CACurrentMediaTime()
        }
        Self.inTick = true
        defer { Self.inTick = false }
        if Diagnostics.enabled {
            if lastTick > 0 {
                longestGap = max(longestGap, started - lastTick)
                if recording { intervals.append(started - lastTick) }
            }
            lastTick = started
        }
        defer {
            if Diagnostics.enabled {
                let work = CACurrentMediaTime() - started
                slowestTick = max(slowestTick, work)
                if recording { works.append(work) }
            }
        }
        let views = canvases.allObjects.filter(\.wantsFrames)
        let stepping = activeClients
        for client in stepping {
            client.displayFrame()
            if Diagnostics.enabled { clientSteps += 1 }
        }
        guard let model = views.first?.coordinator?.model else {
            if stepping.isEmpty { stop() }
            return
        }
        let frame = model.canvasFrame()
        ticks += 1
        // One command buffer per refresh for every canvas: one submission to the GPU instead of one per panel.
        let command = (try? MeterGPU.shared.get())?.queue.makeCommandBuffer()
        for view in views {
            view.coordinator?.nextFrame = frame
            view.coordinator?.sharedCommand = command
            view.draw()
        }
        command?.commit()
    }
}

enum MetalError: LocalizedError {
    case unavailable
    case allocation
    var errorDescription: String? {
        switch self {
        case .unavailable: return L("Metal GPU unavailable")
        case .allocation: return L("Could not create Metal buffers or textures")
        }
    }
}

/// Device, queue and pipelines shared by every canvas. The shaders are compiled with the palette's colours,
/// so they are rebuilt when the palette or the appearance changes.
final class MeterGPU {
    private static var cached: (Theme.Palette, Bool, Result<MeterGPU, Error>)?
    static var shared: Result<MeterGPU, Error> {
        let palette = Theme.palette, dark = Theme.dark
        if let cached, cached.0 == palette, cached.1 == dark { return cached.2 }
        // Keep the device and queue, so textures of the scenes that carry over stay valid.
        let previous = try? cached?.2.get()
        let started = CACurrentMediaTime()
        let result = Result { try MeterGPU(device: previous?.device, queue: previous?.queue) }
        Diagnostics.log(String(format: "[gpu] pipelines built in %.1f ms", (CACurrentMediaTime() - started) * 1000))
        cached = (palette, dark, result)
        return result
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let shapes: MTLRenderPipelineState
    /// The same shapes as light: colour and coverage add (`ShapeBuilder.light`), so overlapping glows sum and burn
    /// toward white as the Immersive nebula's light does.
    let shapeLight: MTLRenderPipelineState
    let waterfall: MTLRenderPipelineState
    let waveform: MTLRenderPipelineState
    let surface: MTLRenderPipelineState
    /// The Immersive nebula's body (`NebulaScene`): ray-marched at half resolution into a texture of its own
    /// (`bodyOffscreen`, half-float, the bodies blended over each other), then laid into the canvas' pass by
    /// `bodyComposite`, under the dome's grid.
    let body: MTLRenderPipelineState
    let bodyOffscreen: MTLRenderPipelineState
    let bodyComposite: MTLRenderPipelineState
    /// Radiant: its particles added into the same half-resolution texture (`radiantParticleVertex`), then tone-mapped
    /// into the canvas (`radiantCompositeFragment`).
    let radiantParticles: MTLRenderPipelineState
    let radiantComposite: MTLRenderPipelineState
    /// Radiant's glow: its light averaged down to a quarter (and an eighth), then blurred across and down; and the
    /// meter that eases its exposure where the light is dense (`radiantMeterKernel`).
    let bloomDown: MTLRenderPipelineState
    let bloomBlur: MTLRenderPipelineState
    let radiantMeter: MTLComputePipelineState
    /// The Radiant body: its particles added into two volumes, each resolved and blurred, then ray-marched into the
    /// half-resolution texture as the level body is (`radiantBodyFragment`) and laid in by `bodyComposite`.
    /// The Radiant body's point lights on the dark well: Radiant's composite, its light added to the body's rather than
    /// laid over it (on the light well they are laid over it, as a wash).
    let radiantPoints: MTLRenderPipelineState
    let radiantSplat: MTLComputePipelineState
    let radiantResolve: MTLComputePipelineState
    let radiantBlur: MTLComputePipelineState
    let radiantBody: MTLRenderPipelineState

    private init(device existing: MTLDevice?, queue existingQueue: MTLCommandQueue?) throws {
        guard let device = existing ?? MTLCreateSystemDefaultDevice(),
              let queue = existingQueue ?? device.makeCommandQueue() else {
            throw MetalError.unavailable
        }
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: Self.shaderSource + Self.layoutChecks, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "shapeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "shapeFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        // Straight-alpha sources accumulate into a premultiplied, transparent drawable.
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        shapes = try device.makeRenderPipelineState(descriptor: descriptor)
        attachment.destinationRGBBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one
        shapeLight = try device.makeRenderPipelineState(descriptor: descriptor)
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.fragmentFunction = library.makeFunction(name: "waterfallFragment")
        waterfall = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "waveformFragment")
        waveform = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.vertexFunction = library.makeFunction(name: "surfaceVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "surfaceFragment")
        surface = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.vertexFunction = library.makeFunction(name: "bodyVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "bodyFragment")
        body = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "bodyCompositeFragment")
        bodyComposite = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "bodyFragment")
        attachment.pixelFormat = .rgba16Float
        bodyOffscreen = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "radiantBodyFragment")
        radiantBody = try device.makeRenderPipelineState(descriptor: descriptor)
        // Radiant's particles add light into the same half-float target, then are tone-mapped into the canvas.
        descriptor.vertexFunction = library.makeFunction(name: "radiantParticleVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "radiantParticleFragment")
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one
        radiantParticles = try device.makeRenderPipelineState(descriptor: descriptor)
        attachment.pixelFormat = .bgra8Unorm
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.vertexFunction = library.makeFunction(name: "bodyVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "radiantCompositeFragment")
        radiantComposite = try device.makeRenderPipelineState(descriptor: descriptor)
        // Light and coverage both add, so the canvas stays premultiplied (colour never exceeds coverage) where the
        // points lie over a part of the body that is not opaque, as in a style switch's captured picture.
        attachment.destinationRGBBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one
        radiantPoints = try device.makeRenderPipelineState(descriptor: descriptor)
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let bloom = MTLRenderPipelineDescriptor()
        bloom.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        bloom.fragmentFunction = library.makeFunction(name: "bloomDownFragment")
        bloom.colorAttachments[0].pixelFormat = .rgba16Float
        bloomDown = try device.makeRenderPipelineState(descriptor: bloom)
        bloom.fragmentFunction = library.makeFunction(name: "bloomBlurFragment")
        bloomBlur = try device.makeRenderPipelineState(descriptor: bloom)
        guard let meter = library.makeFunction(name: "radiantMeterKernel"), let splat = library.makeFunction(name: "radiantSplatKernel"),
              let resolve = library.makeFunction(name: "radiantResolveKernel"), let blur = library.makeFunction(name: "radiantBlurKernel") else {
            throw MetalError.unavailable
        }
        radiantMeter = try device.makeComputePipelineState(function: meter)
        radiantSplat = try device.makeComputePipelineState(function: splat)
        radiantResolve = try device.makeComputePipelineState(function: resolve)
        radiantBlur = try device.makeComputePipelineState(function: blur)
    }

    func pipeline(_ kind: UnderlayKind) -> MTLRenderPipelineState {
        switch kind {
        case .waterfall: return waterfall
        case .waveform: return waveform
        }
    }
}

// Swift and Metal agree on 48 bytes: float2, float2, float4 (16-aligned at 16), float4.
struct ShapeVertex {
    var position: SIMD2<Float>
    var local: SIMD2<Float>
    var color: SIMD4<Float>
    var shape: SIMD4<Float>
}

struct ShapeBuilder {
    var underlay: [ShapeVertex] = []
    var shapes: [ShapeVertex] = []
    /// Shapes from this index on are drawn after the scene's overlay (`CanvasScene.encodeOverlay`); nil: no overlay.
    var overlayStart: Int?
    /// Shapes in this range add their light instead of being laid over (`MeterGPU.shapeLight`).
    var light: Range<Int>?

    init(reserving capacity: Int = 8192) {
        underlay.reserveCapacity(6 * Role.count)
        shapes.reserveCapacity(capacity)
    }

    mutating func reset() {
        underlay.removeAll(keepingCapacity: true)
        shapes.removeAll(keepingCapacity: true)
        overlayStart = nil
        light = nil
    }

    /// Scales the opacity of every shape added since `start` (a `shapes.count` taken before drawing them).
    mutating func fade(from start: Int, by amount: Float) {
        guard amount < 1 else { return }
        for index in start..<shapes.count { shapes[index].color.w *= amount }
    }

    /// Scales every shape added since `start` about `center`, line widths and all (a shape's own coordinates scale
    /// with its corners), for an element growing or settling as it comes and goes.
    mutating func scale(from start: Int, by factor: CGFloat, around center: CGPoint) {
        guard abs(factor - 1) > 0.0005 else { return }
        let f = Float(factor), c = SIMD2(Float(center.x), Float(center.y))
        for index in start..<shapes.count { shapes[index].position = c + (shapes[index].position - c) * f }
    }

    private static func vertex(_ x: CGFloat, _ y: CGFloat, local: SIMD2<Float>, color: SIMD4<Float>,
                               shape: SIMD4<Float>) -> ShapeVertex {
        ShapeVertex(position: SIMD2(Float(x), Float(y)), local: local, color: color, shape: shape)
    }

    /// Two triangles (a, b, c) and (c, b, d) without a temporary array per shape.
    private static func appendQuad(_ list: inout [ShapeVertex], _ a: ShapeVertex, _ b: ShapeVertex,
                                   _ c: ShapeVertex, _ d: ShapeVertex) {
        list.append(a); list.append(b); list.append(c)
        list.append(c); list.append(b); list.append(d)
    }

    /// Axis-aligned quad; `local` spans ± half size (padded by `pad` for antialiasing).
    mutating func quad(_ rect: CGRect, top: SIMD4<Float>, bottom: SIMD4<Float>,
                       shape: SIMD4<Float> = .zero, pad: CGFloat = 0, into target: WritableKeyPath<ShapeBuilder, [ShapeVertex]> = \.shapes) {
        let r = rect.insetBy(dx: -pad, dy: -pad)
        let hw = Float(r.width / 2), hh = Float(r.height / 2)
        let a = Self.vertex(r.minX, r.minY, local: SIMD2(-hw, -hh), color: top, shape: shape)
        let b = Self.vertex(r.maxX, r.minY, local: SIMD2(hw, -hh), color: top, shape: shape)
        let c = Self.vertex(r.minX, r.maxY, local: SIMD2(-hw, hh), color: bottom, shape: shape)
        let d = Self.vertex(r.maxX, r.maxY, local: SIMD2(hw, hh), color: bottom, shape: shape)
        Self.appendQuad(&self[keyPath: target], a, c, b, d)
    }

    /// Axis-aligned quad with a left-to-right gradient.
    mutating func quad(_ rect: CGRect, left: SIMD4<Float>, right: SIMD4<Float>) {
        let hw = Float(rect.width / 2), hh = Float(rect.height / 2)
        let a = Self.vertex(rect.minX, rect.minY, local: SIMD2(-hw, -hh), color: left, shape: .zero)
        let b = Self.vertex(rect.maxX, rect.minY, local: SIMD2(hw, -hh), color: right, shape: .zero)
        let c = Self.vertex(rect.minX, rect.maxY, local: SIMD2(-hw, hh), color: left, shape: .zero)
        let d = Self.vertex(rect.maxX, rect.maxY, local: SIMD2(hw, hh), color: right, shape: .zero)
        Self.appendQuad(&shapes, a, c, b, d)
    }

    mutating func rect(_ rect: CGRect, _ color: SIMD4<Float>) {
        quad(rect, top: color, bottom: color)
    }

    mutating func roundedRect(_ rect: CGRect, radius: CGFloat, _ color: SIMD4<Float>) {
        let shape = SIMD4<Float>(1, Float(rect.width / 2), Float(rect.height / 2), Float(min(radius, rect.width / 2, rect.height / 2)))
        quad(rect, top: color, bottom: color, shape: shape, pad: 1)
    }

    /// Full-rect quad for an underlay shader: local spans ± half size, shape = (half size, uv).
    /// `mirrored` runs u right to left, so the waterfall's newest column lands on the left edge.
    mutating func underlayQuad(_ rect: CGRect, mirrored: Bool = false) {
        let hw = Float(rect.width / 2), hh = Float(rect.height / 2)
        func corner(_ x: CGFloat, _ y: CGFloat, _ u: Float, _ v: Float) -> ShapeVertex {
            ShapeVertex(position: SIMD2(Float(x), Float(y)), local: SIMD2(u * 2 * hw - hw, v * 2 * hh - hh),
                        color: SIMD4(1, 1, 1, 1), shape: SIMD4(hw, hh, u, v))
        }
        let u0: Float = mirrored ? 1 : 0, u1: Float = mirrored ? 0 : 1
        let a = corner(rect.minX, rect.minY, u0, 0), c = corner(rect.maxX, rect.minY, u1, 0)
        let d = corner(rect.minX, rect.maxY, u0, 1), e = corner(rect.maxX, rect.maxY, u1, 1)
        underlay.append(a); underlay.append(d); underlay.append(c)
        underlay.append(c); underlay.append(d); underlay.append(e)
    }

    /// One waveform lane for the scope shader: local spans ± half size, shape = (half size, u, role).
    mutating func laneQuad(_ rect: CGRect, role: Int, color: SIMD4<Float>) {
        let hw = Float(rect.width / 2), hh = Float(rect.height / 2)
        func corner(_ x: CGFloat, _ y: CGFloat, _ u: Float, _ v: Float) -> ShapeVertex {
            ShapeVertex(position: SIMD2(Float(x), Float(y)), local: SIMD2(u * 2 * hw - hw, v * 2 * hh - hh),
                        color: color, shape: SIMD4(hw, hh, u, Float(role)))
        }
        let a = corner(rect.minX, rect.minY, 0, 0), c = corner(rect.maxX, rect.minY, 1, 0)
        let d = corner(rect.minX, rect.maxY, 0, 1), e = corner(rect.maxX, rect.maxY, 1, 1)
        underlay.append(a); underlay.append(d); underlay.append(c)
        underlay.append(c); underlay.append(d); underlay.append(e)
    }

    mutating func disk(_ center: CGPoint, radius: CGFloat, _ color: SIMD4<Float>) {
        let box = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        quad(box, top: color, bottom: color, shape: SIMD4(2, Float(radius), 0, 0), pad: 1)
    }

    mutating func glow(_ center: CGPoint, radius: CGFloat, _ color: SIMD4<Float>) {
        guard radius > 0.5, color.w > 0.002 else { return }
        let box = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        quad(box, top: color, bottom: color, shape: SIMD4(3, Float(radius), 0, 0))
    }

    /// `dashes > 0` draws a dashed ring; `sweep` in 0...1 draws a clockwise arc from 12 o'clock.
    mutating func ring(_ center: CGPoint, radius: CGFloat, width: CGFloat, _ color: SIMD4<Float>,
                       dashes: Float = 0, sweep: Float = 1) {
        let outer = radius + width / 2
        let box = CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2)
        let mode: Float = dashes > 0 ? dashes : (sweep < 1 ? -max(0.0001, sweep) : 0)
        quad(box, top: color, bottom: color, shape: SIMD4(4, Float(radius), Float(width / 2), mode), pad: 1)
    }

    mutating func line(_ from: CGPoint, _ to: CGPoint, width: CGFloat, _ color: SIMD4<Float>) {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max(0.0001, sqrt(dx * dx + dy * dy))
        let ux = dx / length, uy = dy / length
        let half = width / 2 + 1
        let extend: CGFloat = 0
        let nx = -uy * half, ny = ux * half
        let start = CGPoint(x: from.x - ux * extend, y: from.y - uy * extend)
        let end = CGPoint(x: to.x + ux * extend, y: to.y + uy * extend)
        let shape = SIMD4<Float>(5, Float(width / 2), 0, 0)
        let h = Float(half)
        let a = Self.vertex(start.x + nx, start.y + ny, local: SIMD2(0, h), color: color, shape: shape)
        let b = Self.vertex(start.x - nx, start.y - ny, local: SIMD2(0, -h), color: color, shape: shape)
        let c = Self.vertex(end.x + nx, end.y + ny, local: SIMD2(0, h), color: color, shape: shape)
        let d = Self.vertex(end.x - nx, end.y - ny, local: SIMD2(0, -h), color: color, shape: shape)
        Self.appendQuad(&shapes, a, b, c, d)
    }

    mutating func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint,
                           _ ca: SIMD4<Float>, _ cb: SIMD4<Float>, _ cc: SIMD4<Float>) {
        shapes.append(Self.vertex(a.x, a.y, local: .zero, color: ca, shape: .zero))
        shapes.append(Self.vertex(b.x, b.y, local: .zero, color: cb, shape: .zero))
        shapes.append(Self.vertex(c.x, c.y, local: .zero, color: cc, shape: .zero))
    }

}

/// Laid out like both Metal underlay states: `WaterfallState` (every field) and `ScopeState` (the first six: newest,
/// capacity, phase, span, an unused slot and the range), which ignores the rest. `MeterGPU.layoutChecks` checks both.
struct UnderlayState {
    var head: UInt32 = 0
    var rows: UInt32 = 1
    var phase: Float = 0
    var span: Float = 0
    /// Waterfall only: the colour range's floor and width in dB, the tilt in dB per octave, and the octaves the
    /// rows span below the pivot (`floorOctave`, from the bottom row's edge) and in all (`octaves`).
    var floor: Float = -90
    var range: Float = 78
    var tilt: Float = 0
    var floorOctave: Float = 0
    var octaves: Float = 10
    /// 1 when the well spaces frequency linearly from 0 Hz (`FrequencyScale.linear`): each pixel then reads the log
    /// row of its frequency.
    var linear: Float = 0
}

enum UnderlayKind { case waterfall, waveform }

/// `SurfaceState` in the shader: the waterfall's state, where the plot lies in the view, and the grid.
struct SurfaceState {
    var head: UInt32 = 0
    var capacity: UInt32 = 1
    var phase: Float = 0
    var span: Float = 0
    var floor: Float = -90
    var range: Float = 78
    var tilt: Float = 0
    var floorOctave: Float = 0
    var octaves: Float = 10
    var left: Float = 0
    var bottom: Float = 0
    var width: Float = 0
    var height: Float = 0
    var viewportWidth: Float = 1
    var viewportHeight: Float = 1
    var columns: UInt32 = 1
    var strips: UInt32 = 1
    var mirrored: UInt32 = 0
    var linear: Float = 0

    var vertexCount: Int { Int(columns) * Int(strips) * 6 }
}

/// How the 3D spectrogram maps time `u` (0–1 across, "now" at 1 unless mirrored), depth `d` (0 at 20 Hz in front, 1 at
/// the top of the range at the back) and a tone (0–1) into the plot: the front edge spans the plot's foot as the 2D
/// image does, so the time labels under it still apply, and the far edge recedes up and to the right, narrower.
/// The shader (`surfacePoint`) uses the same constants.
struct SurfaceProjection {
    static let narrowing = 0.42
    static let shift = 0.18
    static let depth = 0.72
    static let relief = 0.26

    let plot: CGRect

    func point(u: Double, d: Double, tone: Double = 0) -> CGPoint {
        let scale = 1 - Self.narrowing * d
        return CGPoint(x: plot.minX + Self.shift * plot.width * d + u * plot.width * scale,
                       y: plot.maxY - Self.depth * plot.height * d - tone * Self.relief * plot.height * (0.75 + 0.25 * scale))
    }

    /// The depth axis' marks: 100 Hz, 1 kHz and 10 kHz on the log axis; every 5 kHz on the linear one.
    static func marks(_ scale: FrequencyScale) -> [(Double, String)] {
        scale == .linear ? [(5_000, "5k"), (10_000, "10k"), (15_000, "15k")] : [(100, "100"), (1_000, "1k"), (10_000, "10k")]
    }

    /// Depth of `frequency` on the 20 Hz…`upper` log axis, or the 0…`upper` linear one.
    static func depth(frequency: Double, upper: Double, scale: FrequencyScale = .log) -> Double {
        scale == .linear ? frequency / upper : LogFrequencyAxis.position(of: frequency, upper: upper)
    }
}

extension CanvasScene {
    var usesDampedLevels: Bool { true }
    var underlayRamp: [SIMD4<Float>] { [] }
    var surface: SurfaceState? { nil }
    func encodeOverlay(_ encoder: MTLRenderCommandEncoder, gpu: MeterGPU) {}
    func encodeOffscreen(_ command: MTLCommandBuffer, gpu: MeterGPU, pixels: CGSize) {}
}

protocol CanvasScene: AnyObject {
    /// Whether `build` reads the damped display levels; the waterfall and the scope draw from history instead.
    var usesDampedLevels: Bool { get }
    var underlayKind: UnderlayKind { get }
    var underlayTexture: MTLTexture? { get }
    var underlayState: UnderlayState { get }
    /// The waterfall's colour map (`Theme.waterfallRamp`), bound beside the state; empty for other underlays.
    var underlayRamp: [SIMD4<Float>] { get }
    /// The 3D spectrogram, drawn after the shapes with `underlayTexture` and `underlayRamp`; nil for a flat scene.
    var surface: SurfaceState? { get }
    /// Drawn in the canvas' pass after the shapes before `ShapeBuilder.overlayStart` and before the rest (the
    /// Immersive nebula's body); it must leave vertex buffers 0 and 1, the shapes', bound.
    func encodeOverlay(_ encoder: MTLRenderCommandEncoder, gpu: MeterGPU)
    /// Passes of its own in the frame's command buffer, before the canvas' pass (the Immersive nebula's body, at half
    /// resolution); `pixels` is the canvas' drawable size.
    func encodeOffscreen(_ command: MTLCommandBuffer, gpu: MeterGPU, pixels: CGSize)
    func prepare(frame: CanvasFrame)
    func build(_ builder: inout ShapeBuilder, frame: CanvasFrame, display: MeterSnapshot, size: CGSize, dt: Float)
}

/// Scenes outlive their canvas. A palette or appearance change rebuilds the meter's views, and the new canvases
/// pick up the same scenes, so the waterfall, the scope history, peak holds and clip latches carry on instead of
/// starting blank. Only the pipelines, compiled with the new colours, change.
enum SceneStore {
    private static var scenes: [CanvasKind: CanvasScene] = [:]
    private static var dampings: [CanvasKind: DampedDisplayState] = [:]
    private static var permits: [CanvasKind: DispatchSemaphore] = [:]
    private static var renderers: [CanvasKind: CanvasRenderer] = [:]

    /// A panel handover changes its view, not its scene or vertex storage. Keep only the current palette's renderer
    /// per kind; an outgoing theme view retains its old renderer until its fade finishes.
    static func renderer(_ kind: CanvasKind, gpu: MeterGPU) throws -> CanvasRenderer {
        if let renderer = renderers[kind], renderer.gpu === gpu { return renderer }
        let renderer = try CanvasRenderer(kind: kind, gpu: gpu, shared: true)
        renderers[kind] = renderer
        return renderer
    }

    /// Renderers handing a scene between grid, enlarged and Dock views share its mutable textures too. One permit
    /// per scene protects texture uploads until the last GPU read completes, including across view replacement.
    static func permit(_ kind: CanvasKind) -> DispatchSemaphore {
        if let permit = permits[kind] { return permit }
        let permit = DispatchSemaphore(value: 1)
        permits[kind] = permit
        return permit
    }

    /// The display smoothing carries over with its scene, so a rebuilt canvas (a palette or appearance change, even
    /// while paused) continues from the levels on screen instead of jumping to the raw ones.
    static func damping(_ kind: CanvasKind) -> DampedDisplayState {
        if let damping = dampings[kind] { return damping }
        let damping = DampedDisplayState()
        dampings[kind] = damping
        return damping
    }

    /// The window's scene for `kind` if one has been made (read by overlays such as the inspector).
    static func existing(_ kind: CanvasKind) -> CanvasScene? { scenes[kind] }

    static func scene(_ kind: CanvasKind, device: MTLDevice) throws -> CanvasScene {
        if let scene = scenes[kind] { return scene }
        let scene = try make(kind, device: device)
        scenes[kind] = scene
        return scene
    }

    static func make(_ kind: CanvasKind, device: MTLDevice) throws -> CanvasScene {
        switch kind {
        case .spectrum: return SpectrumScene()
        case .spectrogram: return try SpectrogramScene(device: device)
        case .waveform: return try WaveformScene(device: device)
        case .soundstage: return SoundstageScene(part: .room, device: device)
        case .levels: return SoundstageScene(part: .levels)
        }
    }
}

final class CanvasRenderer {
    private(set) var lastVertexCount = 0
    /// Nothing has changed for two seconds, so the last frame is final.
    var settled: Bool { idle.settled }
    fileprivate let gpu: MeterGPU
    private let scene: CanvasScene
    private let vertexCapacity: Int
    private let buffer: MTLBuffer
    // A scene's texture upload must wait until the previous GPU read of it completes.
    private let inFlight: DispatchSemaphore
    private var builder: ShapeBuilder
    private let damping: DampedDisplayState
    private var lastDrawTime: CFTimeInterval = 0
    private var previous: MeterSnapshot?
    private var previousSize = CGSize.zero
    private var previousEpoch = -1
    private var previousTruePeakEpoch = -1
    private var previousSpatial = true
    private var previousMono = false
    private var previousLayout = SpeakerLayout.standard
    private var previousStrip: CGFloat = 0
    private var previousStageBands = StereoBands.Resolution.five
    private var previousStageStyle = StageStyle.dots
    private var previousOptions = DisplayOptions()
    private var previousLevelsBands = StereoBands.Resolution.five
    private var idle = DisplayIdle()

    /// `shared`: take the window's long-lived scene for `kind` (see `SceneStore`); the offscreen preview makes its own.
    init(kind: CanvasKind, gpu: MeterGPU, shared: Bool = false) throws {
        self.gpu = gpu
        // Measured demo peaks are about 3,230 / 80 / 6 / 800 vertices respectively. Keep ample
        // headroom for both formats and window sizes without reserving 24,000 for every canvas.
        switch kind {
        case .spectrum: vertexCapacity = 16_384
        case .spectrogram, .waveform: vertexCapacity = 1_024
        // The Stereo stereometer draws up to six generations of its cloud (3,840 dots) and halos, twice while a
        // band switch cross-fades.
        case .soundstage: vertexCapacity = 65_536
        case .levels: vertexCapacity = 8_192
        }
        builder = ShapeBuilder(reserving: vertexCapacity)
        scene = shared ? try SceneStore.scene(kind, device: gpu.device) : try SceneStore.make(kind, device: gpu.device)
        damping = shared ? SceneStore.damping(kind) : DampedDisplayState()
        inFlight = shared ? SceneStore.permit(kind) : DispatchSemaphore(value: 1)
        // inFlight permits one GPU submission at a time, so one shared vertex buffer is enough.
        guard let buffer = gpu.device.makeBuffer(length: vertexCapacity * MemoryLayout<ShapeVertex>.stride,
                                                 options: .storageModeShared) else { throw MetalError.allocation }
        self.buffer = buffer
    }

    @discardableResult
    /// Encodes one frame into `shared` when given (committed by the caller), else into a buffer of its own.
    func draw(in view: MTKView, frame: CanvasFrame, force: Bool, command shared: MTLCommandBuffer? = nil) -> Bool {
        let size = view.bounds.size
        let changed = force || frame.running || previous != frame.snapshot || size != previousSize || frame.epoch != previousEpoch
            || frame.truePeakEpoch != previousTruePeakEpoch
            || frame.spatial != previousSpatial || frame.mono != previousMono || frame.layout != previousLayout
            || frame.spectrumStrip != previousStrip || frame.stageBands != previousStageBands
            || frame.levelsBands != previousLevelsBands || frame.stageStyle != previousStageStyle
            || frame.options != previousOptions
        // Keep drawing briefly after the signal stops so damped bars and holds settle instead of freezing.
        let now = CanvasDriver.now
        idle.update(changed: changed, at: now)
        guard !idle.settled else { return false }
        // Never block the main thread on the GPU: if the previous frame is still being drawn, skip this one.
        guard inFlight.wait(timeout: .now()) == .success else { return false }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = shared ?? gpu.queue.makeCommandBuffer() else {
            inFlight.signal()
            return false
        }
        let dt = lastDrawTime == 0 ? Float(1.0 / 60) : Float(max(0, min(0.1, now - lastDrawTime)))
        lastDrawTime = now
        let prepared = prepare(frame: frame, size: size, dt: dt)
        // From here the buffer is the GPU's until the command buffer completes.
        command.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        scene.encodeOffscreen(command, gpu: gpu, pixels: view.drawableSize)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            if shared == nil { command.commit() }
            return false
        }
        encode(prepared, size: size, encoder: encoder)
        encoder.endEncoding()
        command.present(drawable)
        if shared == nil { command.commit() }
        previous = frame.snapshot
        previousSize = size
        previousEpoch = frame.epoch
        previousTruePeakEpoch = frame.truePeakEpoch
        previousSpatial = frame.spatial
        previousMono = frame.mono
        previousLayout = frame.layout
        previousStrip = frame.spectrumStrip
        previousStageBands = frame.stageBands
        previousLevelsBands = frame.levelsBands
        previousStageStyle = frame.stageStyle
        previousOptions = frame.options
        return true
    }

    /// What one frame's CPU work left in the vertex buffer for `encode`.
    fileprivate struct Prepared {
        var underlay = 0
        var shapes = 0
        var overlayStart: Int?
        var light: Range<Int>?
    }

    /// The scene's CPU work for one frame: its shapes and underlay into the vertex buffer (and whatever it keeps for
    /// its own passes).
    fileprivate func prepare(frame: CanvasFrame, size: CGSize, dt: Float) -> Prepared {
        scene.prepare(frame: frame)
        let display = scene.usesDampedLevels ? damping.step(target: frame.snapshot, deltaTime: frame.signal(dt)) : frame.snapshot
        builder.reset()
        scene.build(&builder, frame: frame, display: display, size: size, dt: dt)
        let underlayCount = min(builder.underlay.count, vertexCapacity)
        let shapeCount = min(builder.shapes.count, vertexCapacity - underlayCount)
        lastVertexCount = builder.underlay.count + builder.shapes.count
        if lastVertexCount > vertexCapacity {
            Diagnostics.log("[render] vertex capacity exceeded: \(lastVertexCount) > \(vertexCapacity)")
        }
        let stride = MemoryLayout<ShapeVertex>.stride
        builder.underlay.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { buffer.contents().copyMemory(from: base, byteCount: underlayCount * stride) }
        }
        builder.shapes.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                (buffer.contents() + underlayCount * stride).copyMemory(from: base, byteCount: shapeCount * stride)
            }
        }
        return Prepared(underlay: underlayCount, shapes: shapeCount, overlayStart: builder.overlayStart.map { min($0, shapeCount) },
                        light: builder.light.map { $0.clamped(to: 0..<shapeCount) })
    }

    /// Draws a prepared frame in `encoder`'s pass: the underlay, the shapes (around the scene's overlay), the 3D
    /// surface.
    fileprivate func encode(_ prepared: Prepared, size: CGSize, encoder: MTLRenderCommandEncoder) {
        var viewport = SIMD2<Float>(Float(size.width), Float(size.height))
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        let underlayCount = prepared.underlay, shapeCount = prepared.shapes
        if underlayCount > 0, let texture = scene.underlayTexture {
            encoder.setRenderPipelineState(gpu.pipeline(scene.underlayKind))
            encoder.setFragmentTexture(texture, index: 0)
            var state = scene.underlayState
            encoder.setFragmentBytes(&state, length: MemoryLayout<UnderlayState>.stride, index: 0)
            let ramp = scene.underlayRamp
            if !ramp.isEmpty { encoder.setFragmentBytes(ramp, length: ramp.count * MemoryLayout<SIMD4<Float>>.stride, index: 1) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: underlayCount)
        }
        // Shapes in `range`, the light among them added.
        func drawShapes(_ range: Range<Int>) {
            let light = prepared.light?.clamped(to: range) ?? range.upperBound..<range.upperBound
            for (part, pipeline) in [(range.lowerBound..<light.lowerBound, gpu.shapes), (light, gpu.shapeLight),
                                     (light.upperBound..<range.upperBound, gpu.shapes)] where !part.isEmpty {
                encoder.setRenderPipelineState(pipeline)
                encoder.drawPrimitives(type: .triangle, vertexStart: underlayCount + part.lowerBound, vertexCount: part.count)
            }
        }
        let split = prepared.overlayStart ?? shapeCount
        drawShapes(0..<split)
        if prepared.overlayStart != nil {
            scene.encodeOverlay(encoder, gpu: gpu)
            drawShapes(split..<shapeCount)
        }
        if var surface = scene.surface, surface.vertexCount > 0, let texture = scene.underlayTexture {
            let ramp = scene.underlayRamp
            encoder.setRenderPipelineState(gpu.surface)
            encoder.setVertexTexture(texture, index: 0)
            encoder.setVertexBytes(&surface, length: MemoryLayout<SurfaceState>.stride, index: 0)
            if !ramp.isEmpty { encoder.setFragmentBytes(ramp, length: ramp.count * MemoryLayout<SIMD4<Float>>.stride, index: 0) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: surface.vertexCount)
        }
    }

    /// `--preview-stage-size`: the Soundstage alone, following every snapshot of the demo or the audio file in turn
    /// (30 per second) as the window would, then drawn once.
    static func writeStagePreview(to destination: URL, size: CGSize) throws {
        let gpu = try MeterGPU.shared.get()
        let soundstage = try CanvasRenderer(kind: .soundstage, gpu: gpu)
        let scale = 2
        let width = Int(size.width) * scale, height = Int(size.height) * scale
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        guard let texture = gpu.device.makeTexture(descriptor: descriptor), let command = gpu.queue.makeCommandBuffer() else {
            throw MetalError.allocation
        }
        var frame = CanvasFrame(running: true)
        frame.layout = Diagnostics.previewLayout
        frame.options = DisplayOptions.stored
        // The geometry `PreviewAudio` analyses with, as `MeterModel` gives the window the one its analysis uses.
        frame.geometry = SpeakerLayoutStore.storedGeometry(for: frame.layout, nebula: frame.options.nebula)
        frame.spatial = !Diagnostics.previewStereo
        let audio = try Diagnostics.previewAudio.map { try PreviewAudio.snapshots($0, layout: frame.layout) }
        if let audio { frame.sampleRate = audio.sampleRate }
        let steps = audio?.snapshots.count ?? 150
        for step in 0..<steps {
            frame.snapshot = audio?.snapshots[step] ?? DemoSignal.snapshot(at: Double(step) / DemoSignal.updateRate, sequence: step)
            _ = soundstage.prepare(frame: frame, size: size, dt: 1 / Float(DemoSignal.updateRate))
        }
        let prepared = soundstage.prepare(frame: frame, size: size, dt: 0)
        soundstage.scene.encodeOffscreen(command, gpu: gpu, pixels: CGSize(width: width, height: height))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(Double(Theme.displayRGB.r), Double(Theme.displayRGB.g),
                                                                  Double(Theme.displayRGB.b), 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw MetalError.allocation }
        soundstage.encode(prepared, size: size, encoder: encoder)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        if Diagnostics.benchmarkStage {
            var cpu: [Double] = [], gpuTimes: [Double] = []
            // 30 Hz snapshots displayed at 60 Hz; no audio capture or wall-clock sleeps.
            for tick in 0..<140 {
                if tick % 2 == 0 {
                    let step = tick / 2
                    frame.snapshot = audio?.snapshots[min(step, steps - 1)]
                        ?? DemoSignal.snapshot(at: Double(step) / DemoSignal.updateRate, sequence: step)
                }
                let start = CACurrentMediaTime()
                let next = soundstage.prepare(frame: frame, size: size, dt: 1.0 / 60)
                let elapsed = CACurrentMediaTime() - start
                guard let buffer = gpu.queue.makeCommandBuffer() else { throw MetalError.allocation }
                soundstage.scene.encodeOffscreen(buffer, gpu: gpu, pixels: CGSize(width: width, height: height))
                guard let render = buffer.makeRenderCommandEncoder(descriptor: pass) else { throw MetalError.allocation }
                soundstage.encode(next, size: size, encoder: render)
                render.endEncoding()
                buffer.commit()
                buffer.waitUntilCompleted()
                if let error = buffer.error { throw error }
                if tick >= 20 {
                    cpu.append(elapsed * 1000)
                    gpuTimes.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
                }
            }
            cpu.sort(); gpuTimes.sort()
            print(String(format: "STAGE %@ %dx%d pixels CPU p50 %.3f p95 %.3f ms GPU p50 %.3f p95 %.3f ms (120 frames)",
                         frame.layout.rawValue, width, height, cpu[60], cpu[114], gpuTimes[60], gpuTimes[114]))
        }
        try writePNG(texture, width: width, height: height, to: destination)
    }

    private static func writePNG(_ texture: MTLTexture, width: Int, height: Int, to destination: URL) throws {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { data in
            texture.getBytes(data.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            guard let context = CGContext(data: data.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  let image = context.makeImage(),
                  let output = CGImageDestinationCreateWithURL(destination as CFURL, "public.png" as CFString, 1, nil) else {
                throw MetalError.allocation
            }
            CGImageDestinationAddImage(output, image, nil)
            guard CGImageDestinationFinalize(output) else { throw MetalError.allocation }
        }
    }

    /// Offscreen check of both production scenes with the synthetic demo programme.
    static func writePreview(to destination: URL) throws {
        if let stage = Diagnostics.previewStageSize { return try writeStagePreview(to: destination, size: stage) }
        let gpu = try MeterGPU.shared.get()
        let spectrum = try CanvasRenderer(kind: .spectrum, gpu: gpu)
        let spectrogram = try CanvasRenderer(kind: .spectrogram, gpu: gpu)
        let waveform = try CanvasRenderer(kind: .waveform, gpu: gpu)
        let soundstage = try CanvasRenderer(kind: .soundstage, gpu: gpu)
        let levels = try CanvasRenderer(kind: .levels, gpu: gpu)
        let scale = 2
        // The window's arrangement: the Spectrum card (waterfall and live spectrum in one well) above the Waveform
        // on the left, the Soundstage room above Channel Levels on the right.
        let gap = 20.0
        let spectrumSize = CGSize(width: 900, height: 426 + gap)
        let spectrogramSize = spectrumSize
        let waveSize = CGSize(width: 900, height: 300)
        let stageSize = CGSize(width: 380, height: 320)
        let levelsSize = CGSize(width: 380, height: 426)
        let width = Int(spectrumSize.width + gap + stageSize.width) * scale
        let height = Int(stageSize.height + gap + levelsSize.height) * scale
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        guard let texture = gpu.device.makeTexture(descriptor: descriptor), let command = gpu.queue.makeCommandBuffer() else {
            throw MetalError.allocation
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(Double(Theme.displayRGB.r), Double(Theme.displayRGB.g),
                                                                  Double(Theme.displayRGB.b), 1)
        var frame = CanvasFrame(running: true)
        frame.layout = Diagnostics.previewLayout
        frame.options = DisplayOptions.stored
        frame.geometry = SpeakerLayoutStore.storedGeometry(for: frame.layout, nebula: frame.options.nebula)
        // Spatial part of the demo cycle, so the preview shows every lane and channel of the layout; or the columns
        // of an audio file, through the real analysis.
        let audio = try Diagnostics.previewAudio.map { try PreviewAudio.snapshots($0, layout: frame.layout) }
        let steps = audio?.snapshots.count ?? SpectrogramHistory.capacity
        frame.spatial = (audio == nil || audio?.spatial == true) && !Diagnostics.previewStereo
        if let audio { frame.sampleRate = audio.sampleRate }
        // Fill the waterfall history, then settle holds and damping on the final frame. The soundstage follows the
        // last two seconds as it would live (its nebula eases from one snapshot to the next).
        for step in 0..<steps {
            frame.snapshot = audio?.snapshots[step] ?? DemoSignal.snapshot(at: Double(step % 400) / DemoSignal.updateRate, sequence: step)
            spectrum.scene.prepare(frame: frame)
            spectrogram.scene.prepare(frame: frame)
            waveform.scene.prepare(frame: frame)
            levels.scene.prepare(frame: frame)
            if step >= steps - 60 {
                _ = soundstage.prepare(frame: frame, size: stageSize, dt: 1 / Float(DemoSignal.updateRate))
            } else {
                soundstage.scene.prepare(frame: frame)
            }
        }
        frame.snapshot.channelPeaks[1] = 1.02
        for _ in 0..<40 {
            _ = spectrum.damping.step(target: frame.snapshot, deltaTime: 1.0 / 60)
            _ = soundstage.damping.step(target: frame.snapshot, deltaTime: 1.0 / 60)
            _ = levels.damping.step(target: frame.snapshot, deltaTime: 1.0 / 60)
        }
        // Every panel's CPU work, then one pass for the whole image.
        let spectrumFrame = spectrum.prepare(frame: frame, size: spectrumSize, dt: 1.0 / 60)
        let spectrogramFrame = spectrogram.prepare(frame: frame, size: spectrogramSize, dt: 1.0 / 60)
        let waveFrame = waveform.prepare(frame: frame, size: waveSize, dt: 1.0 / 60)
        let stageFrame = soundstage.prepare(frame: frame, size: stageSize, dt: 1.0 / 60)
        let levelsFrame = levels.prepare(frame: frame, size: levelsSize, dt: 1.0 / 60)
        soundstage.scene.encodeOffscreen(command, gpu: gpu, pixels: CGSize(width: stageSize.width * Double(scale),
                                                                             height: stageSize.height * Double(scale)))
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw MetalError.allocation }
        func viewport(x: Double, y: Double, size: CGSize) {
            encoder.setViewport(MTLViewport(originX: x * Double(scale), originY: y * Double(scale),
                                            width: size.width * Double(scale), height: size.height * Double(scale), znear: 0, zfar: 1))
        }
        func place(_ renderer: CanvasRenderer, _ prepared: Prepared, x: Double, y: Double, size: CGSize) {
            viewport(x: x, y: y, size: size)
            renderer.encode(prepared, size: size, encoder: encoder)
        }
        place(spectrum, spectrumFrame, x: 0, y: 0, size: spectrumSize)
        place(spectrogram, spectrogramFrame, x: 0, y: 0, size: spectrogramSize)
        // `--preview-image`: the context menu's exported image of the same waterfall.
        if let url = Diagnostics.previewImage, let scene = spectrogram.scene as? SpectrogramScene,
           let image = SpectrogramImage.make(history: scene.history, columns: Int(scene.span), sampleRate: frame.sampleRate,
                                             options: frame.options, caption: SpectrogramImage.caption(source: "L+R", sampleRate: frame.sampleRate, options: frame.options)),
           let output = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(output, image, nil)
            CGImageDestinationFinalize(output)
        }
        place(waveform, waveFrame, x: 0, y: spectrumSize.height + gap, size: waveSize)
        place(soundstage, stageFrame, x: spectrumSize.width + gap, y: 0, size: stageSize)
        place(levels, levelsFrame, x: spectrumSize.width + gap, y: stageSize.height + gap, size: levelsSize)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { data in
            texture.getBytes(data.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            guard let context = CGContext(data: data.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  let image = context.makeImage(),
                  let output = CGImageDestinationCreateWithURL(destination as CFURL, "public.png" as CFString, 1, nil) else {
                throw MetalError.allocation
            }
            CGImageDestinationAddImage(output, image, nil)
            guard CGImageDestinationFinalize(output) else { throw MetalError.allocation }
        }
    }
}

/// `--preview-audio`: an audio file's snapshots as the analysis makes them, one per waterfall column (1/30 s), for
/// the offscreen preview. Up to the waterfall's capacity of columns from the start of the file. A mono or stereo file
/// feeds L and R (a mono file both); a file of more channels feeds the layout's roles in order (input 1 the first
/// role…) through the whole Spatial pipeline, spatial field included, as a device routed to that layout would.
enum PreviewAudio {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func snapshots(_ url: URL, layout: SpeakerLayout = .s916) throws -> (sampleRate: Double, snapshots: [MeterSnapshot], spatial: Bool) {
        var file: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let file else { throw Failure(description: "cannot open \(url.path)") }
        defer { ExtAudioFileDispose(file) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format)
        let rate = format.mSampleRate
        let channels = Int(format.mChannelsPerFrame)
        if channels > 2 { return try spatial(file, rate: rate, channels: channels, layout: layout) }
        var client = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                 mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard let analyzer = SpectrumAnalyzer(sampleRate: rate) else { throw Failure(description: "unsupported rate \(rate)") }
        analyzer.spectrogramMode = DisplayOptions.stored.spectrogramAnalysis == .enhanced ? .enhanced : .classic
        let hop = Int((rate / SpectrogramLayout.analysisRate).rounded())
        var buffer = [StereoFrame](repeating: StereoFrame(left: 0, right: 0), count: hop)
        var result: [MeterSnapshot] = []
        while result.count < SpectrogramHistory.capacity {
            var frames = UInt32(hop)
            let status = buffer.withUnsafeMutableBytes { bytes -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                return ExtAudioFileRead(file, &frames, &list)
            }
            guard status == noErr, frames > 0 else { break }
            buffer.withUnsafeBufferPointer { analyzer.consume(UnsafeBufferPointer(rebasing: $0[0..<Int(frames)])) }
            var snapshot = analyzer.snapshot()
            snapshot.streamID = 1
            snapshot.sequence = Float(result.count + 1)
            snapshot.spectrogramSerial = Float(result.count + 1)
            result.append(snapshot)
        }
        guard !result.isEmpty else { throw Failure(description: "no audio in \(url.path)") }
        return (rate, result, false)
    }

    /// Every channel on the layout's roles in order, through `MeterPipeline` in Spatial monitoring, one snapshot kept
    /// per two 1/60 s ticks.
    private static func spatial(_ file: ExtAudioFileRef, rate: Double, channels: Int, layout: SpeakerLayout) throws
        -> (sampleRate: Double, snapshots: [MeterSnapshot], spatial: Bool) {
        let roles = Array(layout.roles.prefix(channels))
        guard !roles.isEmpty else { throw Failure(description: "the layout has no roles") }
        var client = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
                                                 mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
                                                 mBitsPerChannel: 32, mReserved: 0)
        ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        let active = (0..<Role.count).map { roles.contains($0) }
        guard let pipeline = MeterPipeline(sampleRate: rate, activeRoles: active,
                                           detector: FormatDetector(initial: .spatial, canDetectSpatial: true), streamID: 1) else {
            throw Failure(description: "unsupported rate \(rate)")
        }
        pipeline.spatialSpectrum = true
        pipeline.spatialGeometry = SpeakerLayoutStore.storedGeometry(for: layout, nebula: DisplayOptions.stored.nebula)
        pipeline.spatialCoherence = DisplayOptions.stored.nebula.threshold
        pipeline.spectrum.spectrogramMode = DisplayOptions.stored.spectrogramAnalysis == .enhanced ? .enhanced : .classic
        let tick = Int((rate / MeterPipeline.tickRate).rounded())
        var buffer = [Float](repeating: 0, count: tick * channels)
        var values = [Float](repeating: 0, count: SnapshotSlots.total)
        var result: [MeterSnapshot] = []
        var ticks = 0
        // The file's roles beyond the first `roles.count` channels are dropped.
        let used = roles.count
        var planar = [Float](repeating: 0, count: tick * used)
        while result.count < SpectrogramHistory.capacity {
            var frames = UInt32(tick)
            let status = buffer.withUnsafeMutableBytes { bytes -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
                                                                                  mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                return ExtAudioFileRead(file, &frames, &list)
            }
            guard status == noErr, frames > 0 else { break }
            let count = Int(frames)
            for i in 0..<count { for c in 0..<used { planar[i * used + c] = buffer[i * channels + c] } }
            planar.withUnsafeBufferPointer { pipeline.consume(interleaved: $0.baseAddress!, channels: used, frames: count, roles: roles) }
            ticks += 1
            values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: Double(ticks) / MeterPipeline.tickRate) }
            guard ticks % 2 == 0 else { continue }
            var snapshot = DSPWorker.decode(values)
            snapshot.streamID = 1
            snapshot.sequence = Float(result.count + 1)
            snapshot.spectrogramSerial = Float(result.count + 1)
            result.append(snapshot)
        }
        guard !result.isEmpty else { throw Failure(description: "no audio") }
        return (rate, result, true)
    }
}
