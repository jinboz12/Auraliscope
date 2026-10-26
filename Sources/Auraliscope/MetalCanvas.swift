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

// MARK: - Spectrum: live curve of the monitored channels with per-band peak holds, beside the waterfall

/// Drawn in the Spectrum card's `SpectrogramLayout.spectrum` strip, on the waterfall's frequency axis: each point's
/// level reaches right from the floor, so the live spectrum continues the waterfall's newest column.
///
/// The curve is the 128 fine bands (`MeterSnapshot.spectrumFine`), about 1/13 octave, each standing for four
/// waterfall rows. They come from the spectrum's single long transform rather than the waterfall's multi-resolution
/// column, so broadband sound keeps one calibration across the axis (pink noise falls 3 dB per octave everywhere,
/// as on any FFT analyzer) and the curve and its average can be read for tonal balance; a sine reads its level in
/// both.
final class SpectrumScene: CanvasScene {
    /// Points of the curve: the fine bands.
    static let pointCount = MeterSnapshot.fineBandCount

    private var holds = [Float](repeating: -120, count: pointCount)
    private var holdTimers = [Float](repeating: 0, count: pointCount)
    private var velocity = [Float](repeating: 0, count: pointCount)
    private var curve: [CGPoint] = []
    private var epoch = -1
    private var stream: Float = 0
    /// The levels last drawn (damped, untilted), for the inspector.
    private(set) var shown = [Float](repeating: -120, count: pointCount)
    /// Long-term average spectrum since the last reset: each point's mean power over every snapshot that carried
    /// signal, the average engineers compare a mix's tonal balance with. Averaged in power, not dB, so loud passages
    /// weigh as they sound; silence (a stopped transport, a pause) is left out instead of dragging it down.
    private var averagePower = [Double](repeating: 0, count: pointCount)
    private(set) var averageCount = 0
    private var averagedSequence: Float = 0
    private var averagedStream: Float = 0
    private var averagedRate: Double = 0
    private var averagedSpatial = false
    /// Distinct received snapshots before the average is drawn; skipped display frames are not reconstructed.
    static let averageMinimum = 60
    /// The average in dBFS per point (untilted), once it rests on `averageMinimum` snapshots.
    var average: [Float]? {
        guard averageCount >= Self.averageMinimum else { return nil }
        return averagePower.map { Float(10 * log10(max($0 / Double(averageCount), 1e-12))) }
    }

    // Shapes only: no underlay quad is ever added, so the texture is never bound.
    var underlayKind: UnderlayKind { .waterfall }
    var underlayTexture: MTLTexture? { nil }
    var underlayState: UnderlayState { UnderlayState() }
    var usesDampedLevels: Bool { false }

    init() { curve.reserveCapacity(Self.pointCount * Self.subdivisions + 3) }

    /// A reset clears the peak holds, as it does the channel meters'.
    func prepare(frame: CanvasFrame) {
        let snapshot = frame.snapshot
        if frame.epoch != epoch || snapshot.streamID != averagedStream || frame.sampleRate != averagedRate || frame.spatial != averagedSpatial {
            epoch = frame.epoch
            holds = Array(repeating: -120, count: Self.pointCount)
            holdTimers = Array(repeating: 0, count: Self.pointCount)
            for i in averagePower.indices { averagePower[i] = 0 }
            averageCount = 0
            averagedStream = snapshot.streamID
            averagedRate = frame.sampleRate
            averagedSpatial = frame.spatial
            // The snapshot at a configuration change may still belong to the old analysis. Wait for a new one.
            averagedSequence = snapshot.sequence
        }
        // Each new snapshot with signal joins the average once.
        guard frame.running, snapshot.sequence != averagedSequence else { return }
        averagedSequence = snapshot.sequence
        guard let loudest = snapshot.spectrumFine.max(), loudest > -100 else { return }
        for (i, db) in snapshot.spectrumFine.enumerated() { averagePower[i] += pow(10, Double(db) / 10) }
        averageCount += 1
    }

    /// Curve segments drawn between neighbouring points.
    private static let subdivisions = 2


    /// The smoothing kernels, kept while the smoothing, the point count and the sample rate stay the same.
    private var kernelCache: (SpectrumSmoothing, Int, Double, [[Float]])?
    private func smoothingKernels(_ smoothing: SpectrumSmoothing, count: Int, upper: Double) -> [[Float]] {
        if let cache = kernelCache, cache.0 == smoothing, cache.1 == count, cache.2 == upper { return cache.3 }
        let kernels = smoothing.kernels(count: count, upper: upper)
        kernelCache = (smoothing, count, upper, kernels)
        return kernels
    }

    func build(_ b: inout ShapeBuilder, frame: CanvasFrame, display: MeterSnapshot, size: CGSize, dt: Float) {
        // In the horizontal strip the spectrum has a card of its own: the same drawing on its usual axes, turned a
        // quarter so frequency runs across (`SpectrumCardLayout`).
        let scale = frame.options.frequencyScale
        let card = frame.spectrumStrip == SpectrogramLayout.split ? SpectrumCardLayout(size: size, scale: scale) : nil
        let layout = card?.canonical
            ?? SpectrogramLayout(size: size, strip: frame.spectrumStrip, spectrumLeft: frame.options.spectrumSide == .left, scale: scale)
        func t(_ p: CGPoint) -> CGPoint { card?.point(p) ?? p }
        func t(_ r: CGRect) -> CGRect { card?.rect(r) ?? r }
        let strip = layout.spectrum
        let ink = Theme.inkRGB
        b.roundedRect(t(strip), radius: 3, ink.simd(0.025))
        for db in SpectrogramLayout.grid {
            let x = (layout.x(decibels: db) * 2).rounded() / 2
            b.rect(t(CGRect(x: max(strip.minX, min(strip.maxX - 0.5, x)), y: strip.minY, width: 0.5, height: strip.height)),
                   ink.simd(Float(db == 0 ? ChartInk.reference : ChartInk.major)))
            // A fainter line halfway to the next labelled level, so a level reads to 12 dB at a glance.
            let minor = (layout.x(decibels: db - 12) * 2).rounded() / 2
            if db - 12 > MeterScale.spectrumFloor {
                b.rect(t(CGRect(x: minor, y: strip.minY, width: 0.5, height: strip.height)), ink.simd(Float(ChartInk.minor) * 0.7))
            }
        }
        // A line under each frequency label, stronger at 100 Hz, 1 kHz and 10 kHz.
        for tick in card?.frequencyTicks(sampleRate: frame.sampleRate) ?? SpectrogramLayout.frequencyTicks(layout, sampleRate: frame.sampleRate) {
            let y = (layout.y(frequency: tick.0, sampleRate: frame.sampleRate) * 2).rounded() / 2
            guard y > strip.minY + 1, y < strip.maxY - 1 else { continue }
            let decade = scale.isMajor(tick.0)
            b.rect(t(CGRect(x: strip.minX, y: y, width: strip.width, height: 0.5)), ink.simd(Float(decade ? ChartInk.major * 1.3 : ChartInk.minor)))
        }

        // The newest bands, followed at the chosen response; held while frozen, and a new stream starts from its own.
        let target = frame.snapshot.spectrumFine
        if frame.snapshot.streamID != stream {
            stream = frame.snapshot.streamID
            shown = target
            velocity = Array(repeating: 0, count: Self.pointCount)
        } else {
            let step = max(0, min(0.1, frame.signal(dt)))
            let rate = frame.options.spectrumResponse.rate
            for i in 0..<Self.pointCount { Self.damp(&shown[i], &velocity[i], target[i], step, rate: rate) }
        }
        let count = Self.pointCount
        let upper = MeterScale.upperFrequency(sampleRate: frame.sampleRate)
        // Every line is smoothed alike across frequency (`SpectrumSmoothing`), so they compare point for point.
        let kernel = smoothingKernels(frame.options.spectrumSmoothing, count: count, upper: upper)
        let live = SpectrumSmoothing.apply(kernel, to: shown)
        // The display slope at each point's centre (`SpectrumTilt`); zero when flat.
        let tilt = (0..<count).map { frame.options.tilt.offset(frequency: LogFrequencyAxis.centre($0, of: count, upper: upper)) }
        // Each point at its band's centre on the well's axis: evenly spaced on the log one the bands are analysed on.
        let centres = (0..<count).map { layout.y(frequency: LogFrequencyAxis.centre($0, of: count, upper: upper), sampleRate: frame.sampleRate) }
        func y(_ index: Int) -> CGFloat { centres[index] }
        func line(_ levels: [Float]) -> [CGPoint] {
            Self.spline((0..<count).map { CGPoint(x: layout.x(decibels: levels[$0] + tilt[$0]), y: y($0)) },
                        clampX: strip.minX...strip.maxX, subdivisions: Self.subdivisions)
        }
        curve.removeAll(keepingCapacity: true)
        curve.append(CGPoint(x: layout.x(decibels: live[0] + tilt[0]), y: strip.maxY))
        curve.append(contentsOf: line(live))
        curve.append(CGPoint(x: layout.x(decibels: live[count - 1] + tilt[count - 1]), y: strip.minY))
        // One quiet tint under the curve, fading toward the floor: the shape reads at a glance and the lines on it
        // stay legible.
        let tint = Theme.sageRGB
        for (p, q) in zip(curve, curve.dropFirst()) {
            let pb = CGPoint(x: layout.floorX, y: p.y), qb = CGPoint(x: layout.floorX, y: q.y)
            b.triangle(t(p), t(q), t(qb), tint.simd(0.14), tint.simd(0.14), tint.simd(0.02))
            b.triangle(t(p), t(qb), t(pb), tint.simd(0.14), tint.simd(0.02), tint.simd(0.02))
        }
        // The waterfall's octave lines at every C continue faintly across the spectrum (where the linear axis crowds
        // the low ones together, only those with room).
        var lastOctaveY = CGFloat.infinity
        for octave in 0...9 {
            let y = (layout.y(midi: Double(12 * (octave + 1)), sampleRate: frame.sampleRate) * 2).rounded() / 2
            guard y > strip.minY + 1, y < strip.maxY - 1, lastOctaveY - y >= 6 else { continue }
            lastOctaveY = y
            b.rect(t(CGRect(x: strip.minX, y: y, width: strip.width, height: 0.5)), ink.simd(octave == 4 ? 0.10 : 0.045))
        }
        // Peak holds: one faint line over the curve, each point held 1.2 s and then falling. Held while frozen,
        // unless they are switched off meanwhile.
        let holdDt = frame.options.peakHolds ? frame.signal(dt) : dt
        let peaks = SpectrumSmoothing.apply(kernel, to: target)
        for index in 0..<count {
            let value = frame.running && frame.options.peakHolds ? peaks[index] : -120
            if value >= holds[index] {
                holds[index] = value
                holdTimers[index] = 1.2
            } else if holdTimers[index] > 0 {
                holdTimers[index] -= holdDt
            } else {
                holds[index] = max(-120, holds[index] - 18 * holdDt)
            }
        }
        // Segments resting on the floor are not drawn: silence leaves the strip empty instead of outlining its edge.
        func onFloor(_ p: CGPoint) -> Bool { abs(p.x - layout.floorX) < 0.5 }
        if holds.contains(where: { $0 > MeterScale.spectrumFloor + 1 }) {
            let held = line(holds.indices.map { max(holds[$0], live[$0]) })
            for (p, q) in zip(held, held.dropFirst()) where !(onFloor(p) && onFloor(q)) {
                b.line(t(p), t(q), width: 1, ink.simd(0.30))
            }
        }
        // The long-term average, in the second accent: a calm solid line, so it reads apart from the live curve
        // in any palette without dashes breaking up its shape.
        if frame.options.averageSpectrum, let average {
            let points = line(SpectrumSmoothing.apply(kernel, to: average))
            for (p, q) in zip(points, points.dropFirst()) where !(onFloor(p) && onFloor(q)) {
                b.line(t(p), t(q), width: 1.25, Theme.sandRGB.simd(0.85))
            }
        }
        for (p, q) in zip(curve, curve.dropFirst()) where !(onFloor(p) && onFloor(q)) {
            b.line(t(p), t(q), width: 1.5, Theme.sageRGB.simd())
        }
    }

    /// Critically damped step toward `target` (`DampedDisplayState`'s filter) at `rate` (`SpectrumResponse`).
    private static func damp(_ position: inout Float, _ velocity: inout Float, _ target: Float, _ dt: Float, rate: Float) {
        let displacement = position - target
        let factor = exp(-rate * dt)
        let impulse = velocity + rate * displacement
        position = target + (displacement + impulse * dt) * factor
        velocity = (velocity - rate * impulse * dt) * factor
    }

    /// Exercise the actual scene's average lifecycle without creating a window or touching an audio device.
    static func checkAverageLifecycle() -> Bool {
        let scene = SpectrumScene()
        var frame = CanvasFrame(running: true)
        frame.snapshot.streamID = 1
        frame.snapshot.sequence = 1
        frame.snapshot.spectrumFine = Array(repeating: -20, count: MeterSnapshot.fineBandCount)
        scene.prepare(frame: frame)
        for sequence in 2...61 {
            frame.snapshot.sequence = Float(sequence)
            scene.prepare(frame: frame)
            scene.prepare(frame: frame) // repeated rendering must not double-count
        }
        guard scene.averageCount == 60, let average = scene.average,
              average.allSatisfy({ abs($0 + 20) < 0.0001 }) else { return false }
        frame.running = false
        frame.snapshot.sequence += 1
        scene.prepare(frame: frame)
        guard scene.averageCount == 60 else { return false }
        frame.running = true
        frame.sampleRate = 96_000
        scene.prepare(frame: frame)
        guard scene.averageCount == 0 else { return false }
        frame.snapshot.sequence += 1
        scene.prepare(frame: frame)
        guard scene.averageCount == 1 else { return false }
        frame.spatial.toggle()
        scene.prepare(frame: frame)
        guard scene.averageCount == 0 else { return false }
        frame.snapshot.sequence += 1
        scene.prepare(frame: frame)
        frame.epoch += 1
        scene.prepare(frame: frame)
        guard scene.averageCount == 0 else { return false }
        frame.snapshot.streamID = 2
        frame.snapshot.sequence = 1
        scene.prepare(frame: frame)
        frame.snapshot.spectrumFine = Array(repeating: -120, count: MeterSnapshot.fineBandCount)
        frame.snapshot.sequence += 1
        scene.prepare(frame: frame)
        guard scene.averageCount == 0 else { return false }
        print("PASS: spectrum average deduplicates frames, holds on pause, gates silence, resets on source/rate/mode/Reset")
        return true
    }

    /// Shape-preserving interpolation: smooth joins without inventing peaks between measured points.
    static func spline(_ points: [CGPoint], clampX: ClosedRange<CGFloat>, subdivisions: Int = 4) -> [CGPoint] {
        guard points.count > 1 else { return points }
        var result: [CGPoint] = []
        result.reserveCapacity(points.count * subdivisions)
        func at(_ i: Int) -> CGFloat { points[max(0, min(points.count - 1, i))].x }
        for index in 0..<(points.count - 1) {
            for sub in 0..<subdivisions {
                let t = CGFloat(sub) / CGFloat(subdivisions)
                let x = SpectrumInterpolation.value(at(index - 1), at(index), at(index + 1), at(index + 2), fraction: t)
                result.append(CGPoint(x: min(clampX.upperBound, max(clampX.lowerBound, x)),
                                      y: points[index].y + t * (points[index + 1].y - points[index].y)))
            }
        }
        result.append(points[points.count - 1])
        return result
    }
}

/// A scroll fed in bursts and drawn at an even speed: `lag` is how many columns the drawn edge trails the newest one.
/// Each arrival adds its columns; each refresh drains them at the column rate, sped up or slowed a little by how far the
/// lag's recent average (not the lag itself, which saw-tooths with every arrival and would make the speed wobble) sits
/// from `target`, so the scroll locks onto however the columns come (an audio device's buffers, a DAW's blocks).
struct ScrollDrain {
    private(set) var lag: Float = 0
    private var average: Float = 0
    /// Seconds over which the average follows, and how much faster (or slower) the drain runs per `unit` columns the
    /// average is off target.
    private static let settle: Float = 0.4
    private static let gain: Float = 0.25

    mutating func reset() { lag = 0; average = 0 }
    mutating func arrived(_ columns: Float) { lag += columns }

    /// One refresh `dt` seconds on: drains at `rate` columns a second toward `target`; past `limit` (a stall, or the
    /// first columns after a gap) it lands on the target at once rather than racing.
    mutating func step(dt: Float, rate: Float, target: Float, unit: Float, limit: Float) {
        average += (lag - average) * (1 - Foundation.exp(-dt / Self.settle))
        let speed = max(0, rate * (1 + (average - target) / max(1, unit) * Self.gain))
        lag = max(0, lag - dt * speed)
        if lag > limit { lag = target; average = target }
    }
}

// MARK: - Spectrogram: scrolling history beside the live spectrum, on its frequency axis

/// The waterfall: `SpectrogramHistory` drawn by `waterfallFragment`, with the octave and seconds grid over it. One
/// column arrives per analysis serial (30 Hz); between them the image glides by `phase`. Paused, it holds still, and
/// the inspector (`SpectrogramInspector`) reads the very values on screen through `level(atU:row:)`.
final class SpectrogramScene: CanvasScene {
    private let texture: MTLTexture
    let history = SpectrogramHistory()
    private var previousColumn: Float = 0
    private var previousStream: Float = 0
    private var previousRate: Double = 0
    /// Columns the right edge trails the newest column (`ScrollDrain`), so columns that arrive unevenly (a DAW's large
    /// blocks, an audio device's buffers) still scroll at an even speed; and when the scroll last stepped.
    private var drain = ScrollDrain()
    private var lastStep: CFTimeInterval = 0
    /// How far the scroll has moved toward the next column, 1 − (lag − cushion), at most 1: the shader's `phase`.
    private(set) var phase: Float = 0
    private var appended = 0
    private var arrived: CFTimeInterval = 0
    /// Diagnostics (`--test-frame-pacing`), main thread only.
    nonisolated(unsafe) static var tracing = false
    nonisolated(unsafe) static var scrollTrace: [(Double, Double)] = []
    /// Slack in columns beyond the half column the drain trails on average, so columns that come late or two at once (a
    /// DAW's 2048-sample blocks are 43 ms) never stall it: 0.8 keeps every refresh's step within about 1 % of the next.
    private static let cushion: Float = 0.8
    /// Columns the waterfall spans at its current width (`SpectrogramLayout.seconds`).
    private(set) var span = SpectrogramLayout.maxSeconds * SpectrogramLayout.analysisRate
    private var options = DisplayOptions()
    private var sampleRate = 48_000.0
    /// The colour map the shader reads, rebuilt when the map, the palette or the appearance changes.
    private(set) var underlayRamp: [SIMD4<Float>] = []
    private var rampKey: (SpectrogramColors, Theme.Palette, Bool)?
    /// The 3D view's state, set by `build` while `SpectrogramView.surface` is chosen.
    private(set) var surface: SurfaceState?
    /// Depth strips of the 3D view: four rows each.
    static let surfaceStrips = SpectrogramHistory.rows / 4

    var usesDampedLevels: Bool { false }
    var underlayKind: UnderlayKind { .waterfall }
    var underlayTexture: MTLTexture? { texture }
    var underlayState: UnderlayState {
        let upper = MeterScale.upperFrequency(sampleRate: sampleRate)
        return UnderlayState(head: UInt32(history.head), rows: UInt32(SpectrogramHistory.capacity), phase: phase,
                             span: Float(span), floor: options.spectrogramRange.floor,
                             range: options.spectrogramRange.ceiling - options.spectrogramRange.floor,
                             tilt: options.tilt.decibelsPerOctave, floorOctave: Float(log2(20 / SpectrumTilt.pivot)),
                             octaves: Float(LogFrequencyAxis.octaves(upper: upper)), linear: options.frequencyScale == .linear ? 1 : 0)
    }

    init(device: MTLDevice) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: SpectrogramHistory.capacity,
                                                                  height: SpectrogramHistory.rows, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw MetalError.allocation }
        self.texture = texture
        clear()
    }

    private func clear() {
        history.reset()
        drain.reset()
        lastStep = 0
        phase = 0
        for slot in 0..<SpectrogramHistory.capacity { upload(slot) }
    }

    private func upload(_ slot: Int) {
        history.withColumn(slot) { column in
            texture.replace(region: MTLRegionMake2D(slot, 0, 1, SpectrogramHistory.rows), mipmapLevel: 0,
                            withBytes: column.baseAddress!, bytesPerRow: MemoryLayout<Float>.stride)
        }
    }

    func prepare(frame: CanvasFrame) {
        let snapshot = frame.snapshot
        options = frame.options
        sampleRate = frame.sampleRate
        if rampKey.map({ $0 != (options.spectrogramColors, Theme.palette, Theme.dark) }) ?? true {
            underlayRamp = Theme.waterfallRamp(options.spectrogramColors)
            rampKey = (options.spectrogramColors, Theme.palette, Theme.dark)
        }
        let streamChanged = snapshot.streamID > 0 && snapshot.streamID != previousStream
        if streamChanged || (previousRate > 0 && frame.sampleRate != previousRate) { clear() }
        // One column per analysis serial (30 Hz), however often snapshots arrive.
        if frame.running && snapshot.spectrogramSerial > 0 && (streamChanged || snapshot.spectrogramSerial != previousColumn) {
            upload(history.append(snapshot.spectrogram))
            drain.arrived(1)
            if Self.tracing { appended += 1; arrived = CanvasDriver.now }
        }
        // Held while paused; otherwise drained at the column rate, a little faster when behind, slower when short.
        let now = CanvasDriver.now
        if frame.running && lastStep > 0 {
            drain.step(dt: Float(max(0, min(0.1, now - lastStep))), rate: Float(SpectrogramLayout.analysisRate),
                       target: 0.5 + Self.cushion, unit: 1, limit: 6)
            phase = min(1, 1 + Self.cushion - drain.lag)
        }
        lastStep = frame.running ? now : 0
        if Self.tracing && frame.running && arrived > 0 {
            // Diagnostics: where the scroll stands (columns), and where build 99's (the time since the newest column,
            // held at a whole column) would.
            Self.scrollTrace.append((Double(appended) - Double(drain.lag), Double(appended) - 1 + min(1, (now - arrived) * SpectrogramLayout.analysisRate)))
        }
        if snapshot.streamID > 0 { previousStream = snapshot.streamID }
        previousColumn = snapshot.spectrogramSerial
        previousRate = frame.sampleRate
    }

    /// The level drawn at `u` across the waterfall (0 its oldest edge, 1 "now") and fractional `row`, and how many
    /// seconds before the newest column that is; nil where nothing has been written.
    func level(atU u: Double, row: Double) -> (level: Float, secondsAgo: Double)? {
        let age = (1 - u) * span - Double(phase)
        guard let level = history.level(age: max(0, age), row: row) else { return nil }
        return (level, (max(0, age).rounded() + Double(phase)) / SpectrogramLayout.analysisRate)
    }

    func build(_ b: inout ShapeBuilder, frame: CanvasFrame, display: MeterSnapshot, size: CGSize, dt: Float) {
        let layout = SpectrogramLayout(size: size, strip: frame.spectrumStrip, spectrumLeft: frame.options.spectrumSide == .left,
                                       span: frame.options.spectrogramSpan.seconds, scale: frame.options.frequencyScale)
        let plot = layout.plot
        span = Double(layout.visibleColumns)
        let ink = Theme.inkRGB
        guard frame.options.spectrogramView == .flat else {
            buildSurface(&b, layout: layout, size: size, sampleRate: frame.sampleRate)
            return
        }
        surface = nil
        b.underlayQuad(plot, mirrored: layout.mirrored)
        // Octave lines at every C, continuing the keyboard's C keys across the plot; middle C a little firmer. The
        // linear axis crowds the low ones together: only those with room are drawn.
        var lastOctaveY = CGFloat.infinity
        for octave in 0...9 {
            let y = (layout.y(midi: Double(12 * (octave + 1)), sampleRate: frame.sampleRate) * 2).rounded() / 2
            guard y > plot.minY + 1, y < plot.maxY - 1, lastOctaveY - y >= 6 else { continue }
            lastOctaveY = y
            b.rect(CGRect(x: plot.minX, y: y, width: plot.width, height: 0.5), ink.simd(Float(octave == 4 ? ChartInk.major * 1.3 : ChartInk.minor)))
        }
        // A hairline each second, and a short tick at the foot of each so the time labels have something to name.
        for seconds in stride(from: 1.0, to: layout.seconds, by: 1) {
            let x = (layout.x(secondsAgo: seconds) * 2).rounded() / 2
            b.rect(CGRect(x: x, y: plot.minY, width: 0.5, height: plot.height), ink.simd(Float(ChartInk.minor)))
            b.rect(CGRect(x: x, y: plot.maxY - 4, width: 0.5, height: 4), ink.simd(Float(ChartInk.tick)))
        }
    }

    /// The 3D view: a floor grid (its outline, a line along each decade of frequency and across at each second) under
    /// the surface the shader draws from the same history.
    private func buildSurface(_ b: inout ShapeBuilder, layout: SpectrogramLayout, size: CGSize, sampleRate: Double) {
        let plot = layout.plot
        let projection = SurfaceProjection(plot: plot)
        let ink = Theme.inkRGB
        let upper = MeterScale.upperFrequency(sampleRate: sampleRate)
        func u(_ t: Double) -> Double { layout.mirrored ? 1 - t : t }
        func floorLine(_ from: (u: Double, d: Double), _ to: (u: Double, d: Double), _ alpha: Float) {
            b.line(projection.point(u: from.u, d: from.d), projection.point(u: to.u, d: to.d), width: 1, ink.simd(alpha))
        }
        floorLine((0, 0), (1, 0), 0.16)
        floorLine((0, 1), (1, 1), 0.08)
        floorLine((0, 0), (0, 1), 0.10)
        floorLine((1, 0), (1, 1), 0.10)
        for frequency in SurfaceProjection.marks(layout.scale).map(\.0) where frequency < upper {
            let d = SurfaceProjection.depth(frequency: frequency, upper: upper, scale: layout.scale)
            floorLine((0, d), (1, d), 0.10)
        }
        for seconds in stride(from: 1.0, to: layout.seconds, by: 1) {
            let t = 1 - seconds / layout.seconds
            floorLine((u(t), 0), (u(t), 1), 0.05)
        }
        let flat = underlayState
        surface = SurfaceState(head: flat.head, capacity: flat.rows, phase: flat.phase, span: flat.span,
                               floor: flat.floor, range: flat.range, tilt: flat.tilt, floorOctave: flat.floorOctave,
                               octaves: flat.octaves, left: Float(plot.minX), bottom: Float(plot.maxY),
                               width: Float(plot.width), height: Float(plot.height),
                               viewportWidth: Float(max(1, size.width)), viewportHeight: Float(max(1, size.height)),
                               columns: UInt32(max(1, layout.visibleColumns)), strips: UInt32(Self.surfaceStrips),
                               mirrored: layout.mirrored ? 1 : 0, linear: flat.linear)
    }
}

// MARK: - Waveform: one phosphor lane per channel, drawn from the min/max pyramid

final class WaveformScene: CanvasScene {
    /// 4096 envelope columns (~17 s at 240 columns/s) per pyramid level 0; the lanes show the chosen span (2, 4 or
    /// 8 s, `DisplayOptions.waveSeconds`) with room to spare for the scroll lag and the coarsest buckets.
    static let traceCapacity = 4096
    private var visibleColumns: Float = 960
    static let pairs = Role.count / 2

    private let trace: MTLTexture
    private var pyramid = MinMaxPyramid(capacity: traceCapacity, pairs: pairs)
    private var lastSerial = -1
    private var lastStream: Float = 0
    /// Columns the right edge trails the newest column (`ScrollDrain`), for a smooth scroll.
    private var drain = ScrollDrain()
    private var lag: Float { drain.lag }
    /// Recent arrival size in columns: about 4 per 60 Hz DSP tick, 8 per 30 Hz demo update, more when a DAW
    /// runs the device with long buffers. Jumps up at once and relaxes slowly.
    private var burst: Float = 8
    /// The right edge trails the newest column by 1.5 arrivals: enough that the scroll never runs dry, and no
    /// more, so the waveform is as current as its delivery allows (about 30 ms behind at 60 Hz, was 50 ms).
    private var cushion: Float { min(40, max(6, burst * 1.5)) }
    private var presence = PresenceSpring()
    private var mono = PresenceSpring()
    private var scale = WaveScale.linear

    var usesDampedLevels: Bool { false }
    var underlayKind: UnderlayKind { .waveform }
    var underlayTexture: MTLTexture? { trace }
    var underlayState: UnderlayState {
        UnderlayState(head: pyramid.newestIndex, rows: UInt32(Self.traceCapacity), phase: lag, span: visibleColumns,
                      floor: 0, range: scale.shaderRange)
    }

    init(device: MTLDevice) throws {
        // Row (level × pairs + pair) holds one pyramid level of one channel pair; coarser levels use only
        // their first texels.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: Self.traceCapacity,
                                                                  height: MinMaxPyramid.levels * Self.pairs, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let trace = device.makeTexture(descriptor: descriptor) else { throw MetalError.allocation }
        self.trace = trace
        clearTrace()
    }

    private func clearTrace() {
        pyramid.reset()
        uploadDirtyTrace()
        lastSerial = -1
        drain.reset()
    }

    /// Copies only the texels the pyramid changed since the last upload: one region per level covering
    /// every channel pair, a few texels wide.
    private func uploadDirtyTrace() {
        let stride = MemoryLayout<SIMD4<Float>>.stride
        pyramid.forEachDirtySpan { level, slot, count, texels in
            trace.replace(region: MTLRegionMake2D(slot, level * Self.pairs, count, Self.pairs), mipmapLevel: 0,
                          withBytes: texels.baseAddress! + pyramid.offset(level: level) + slot,
                          bytesPerRow: pyramid.slots(level: level) * stride)
        }
        pyramid.markClean()
    }

    /// The sample peak of `role` (linear, 1 = full scale; above 1 an over) over the history `window` seconds wide
    /// centred `secondsAgo` before the lanes' right edge, read from the same columns the lanes draw. nil where the
    /// history holds nothing yet.
    func peak(role: Int, secondsAgo: Double, window: Double) -> Float? {
        guard pyramid.count > 0, (0..<Role.count).contains(role) else { return nil }
        let rate = WaveformEnvelope.columnRate
        let centre = secondsAgo * rate + Double(lag)
        let half = max(0.5, window * rate / 2)
        let newest = max(0, Int((centre - half).rounded(.down)))
        let oldest = Int((centre + half).rounded(.up))
        guard oldest < pyramid.count, newest <= oldest else { return nil }
        let e = pyramid.extrema(newestAge: newest, oldestAge: oldest, level: 0, pair: role / 2)
        let low = role % 2 == 0 ? e.x : e.z, high = role % 2 == 0 ? e.y : e.w
        guard low.isFinite, high.isFinite else { return nil }
        return max(abs(low), abs(high))
    }

    /// Linear amplitude, so transients read as they do in a DAW; full scale and beyond is flagged past 1.
    static func deflection(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return abs(value) >= 1 ? (value < 0 ? -1.02 : 1.02) : value
    }

    func prepare(frame: CanvasFrame) {
        let snapshot = frame.snapshot
        if snapshot.streamID > 0 && snapshot.streamID != lastStream {
            lastStream = snapshot.streamID
            clearTrace()
        }
        guard frame.running, snapshot.sequence > 0 else { return }
        let serial = Int(snapshot.waveSerial)
        let count = lastSerial < 0 ? WaveformEnvelope.publishedColumns
            : WaveformEnvelope.newColumns(since: lastSerial, latest: serial)
        guard count > 0 else { return }
        snapshot.waveform.withUnsafeBufferPointer { w in
            for column in (WaveformEnvelope.publishedColumns - count)..<WaveformEnvelope.publishedColumns {
                let base = column * WaveformEnvelope.valuesPerColumn
                pyramid.append { pair in
                    let i = base + pair * 4
                    return SIMD4(Self.deflection(w[i]), Self.deflection(w[i + 1]), Self.deflection(w[i + 2]), Self.deflection(w[i + 3]))
                }
            }
        }
        uploadDirtyTrace()
        drain.arrived(Float(count))
        if lastSerial >= 0 { burst = max(Float(count), burst + (Float(count) - burst) * 0.05) }
        lastSerial = serial
    }

    /// Lanes are rebuilt from the current size and presence every frame, and the shader picks its pyramid
    /// level from the pixel footprint, so any panel size renders at native resolution without resampling.
    func build(_ b: inout ShapeBuilder, frame: CanvasFrame, display: MeterSnapshot, size: CGSize, dt: Float) {
        if frame.running {
            // Drained at the column rate, locked onto the arrivals, so bursts scroll evenly at any refresh rate.
            drain.step(dt: dt, rate: Float(WaveformEnvelope.columnRate), target: cushion, unit: burst, limit: 80)
        }
        visibleColumns = Float(Double(frame.options.waveSeconds) * WaveformEnvelope.columnRate)
        scale = frame.options.waveScale
        presence.step(target: frame.spatial ? 1 : 0, dt: dt)
        mono.step(target: frame.mono ? 1 : 0, dt: dt)
        let layout = WaveformLayout(size: size, speakers: frame.layout.speakers, presence: CGFloat(presence.value),
                                    mono: CGFloat(mono.value))
        for (index, speaker) in layout.speakers.enumerated() {
            let lane = layout.lanes[index]
            let weight = Float(layout.weight(index))
            guard lane.height > 0.5, weight > 0.002 else { continue }
            let active = frame.activeRoles[speaker.role]
            b.laneQuad(lane, role: speaker.role, color: Theme.laneRGB(speaker).simd(weight * weight * (active ? 1 : 0.35)))
        }
    }
}

// MARK: - Soundstage: the top-down room, and the Channel Levels panel (vertical meters and correlation)

/// One class for both wells of the right-hand column, so they share the presence springs, peak holds and over
/// latches' logic; `part` picks what it draws.
final class SoundstageScene: CanvasScene {
    let part: SoundstageLayout.Part
    init(part: SoundstageLayout.Part, device: MTLDevice? = nil) {
        self.part = part
        dome = DomeScene(device: part == .room ? device : nil)
    }

    private let dome: DomeScene
    private var holds = [Float](repeating: -120, count: Role.count)
    private var holdTimers = [Float](repeating: 0, count: Role.count)
    private var clipped = [Bool](repeating: false, count: Role.count)
    /// Highest true peak per role since the last reset, linear: above 1 it is an over, drawn in the over zone.
    private var overPeaks = [Float](repeating: 0, count: Role.count)
    private var peakDb = [Float](repeating: -120, count: Role.count)
    private var rmsDb = [Float](repeating: -120, count: Role.count)
    private var epoch = -1
    private var truePeakEpoch = 0
    /// Frames left in which the snapshot's held true peaks may still predate a true-peak reset.
    private var truePeakGrace = 0
    private var peakSequence: Float = -1
    private var peakStream: Float = -1
    /// The DSP's held sample peaks when the overs were last cleared: a held peak re-lights a clip light only
    /// once it rises past this, so clearing the lights (a click on one, or on TRUE PEAK) sticks until a new over.
    private var heldBaseline = [Float](repeating: 0, count: Role.count)
    private var spring = PresenceSpring()
    private var presence: Float { spring.value }
    private var monoSpring = PresenceSpring()
    /// The band switch of this well: the Soundstage's resolution for the room, the correlation bar's for levels.
    private var bands = BandTransition()
    private var mono: Float { monoSpring.value }
    /// Bed and height speakers of the current layout, clockwise from centre front, for the image polygons.
    private var cachedLayout: SpeakerLayout?
    private var bed: [Speaker] = []
    private var heights: [Speaker] = []
    /// Lowest recent correlation (nil in silence): held 2 s, then it follows the reading back up.
    private var correlationLow: Float?
    private var correlationLowTimer: Float = 0
    /// The stereometer's newest clouds (`MeterSnapshot.bandPoints`) with the time each arrived, newest first, and
    /// the snapshot the newest came from.
    private var clouds: [(points: [Float], time: CFTimeInterval)] = []
    private var cloudSequence: Float = -1
    /// The time the clouds age against: the last live frame's.
    private var cloudClock: CFTimeInterval = 0
    /// A dot's opacity halves about every 50 ms, so a sample glows briefly and trails off like phosphor.
    private static let cloudDecay: CFTimeInterval = 0.07
    private static let cloudLife: CFTimeInterval = 0.16
    /// At most this many clouds are drawn, whatever the snapshot rate: each is a glow per sample and band group, and
    /// six keep a band switch's two groupings (up to eight groups) well inside the vertex buffer.
    private static let cloudGenerations = 6
    /// Outline and Filled styles: per published band group (`StereoBands.groups`), how far its samples reach at
    /// each of `envelopeBins` directions across the half disc, as a scope fraction. Rises at once, falls over
    /// about a quarter second, so the shape holds still enough to read.
    private static let envelopeBins = 48
    private var envelopes = [[Float]](repeating: [Float](repeating: 0, count: 48), count: StereoBands.groups.count)
    private var envelopeStyle = StageStyle.dots

    // No underlay: the Immersive nebula's body is the room's overlay (`NebulaScene`), drawn under the dome's grid and
    // speakers; the Channel Levels well draws shapes only.
    var underlayKind: UnderlayKind { .waterfall }
    var underlayTexture: MTLTexture? { nil }
    var underlayState: UnderlayState { UnderlayState() }
    /// Whether the dome (and so the nebula) was drawn this frame.
    private var domeDrawn = false
    /// What the pointer finds in the Immersive nebula (`DomeScene.probe`).
    func domeProbe(at point: CGPoint, layout: SpeakerLayout) -> DomeProbe? {
        part == .room ? dome.probe(at: point, layout: layout) : nil
    }
    func encodeOverlay(_ encoder: MTLRenderCommandEncoder, gpu: MeterGPU) {
        guard part == .room, domeDrawn else { return }
        dome.nebula.encode(encoder, gpu: gpu)
    }
    func encodeOffscreen(_ command: MTLCommandBuffer, gpu: MeterGPU, pixels: CGSize) {
        guard part == .room, domeDrawn else { return }
        dome.nebula.encodeOffscreen(command, gpu: gpu, pixels: pixels)
    }

    func prepare(frame: CanvasFrame) {
        if frame.epoch != epoch {
            epoch = frame.epoch
            holds = Array(repeating: -120, count: Role.count)
            clipped = Array(repeating: false, count: Role.count)
            overPeaks = Array(repeating: 0, count: Role.count)
            heldBaseline = Array(repeating: 0, count: Role.count)
            correlationLow = nil
            peakSequence = -1
            peakStream = -1
        }
        if frame.truePeakEpoch != truePeakEpoch {
            truePeakEpoch = frame.truePeakEpoch
            overPeaks = Array(repeating: 0, count: Role.count)
            clipped = Array(repeating: false, count: Role.count)
            heldBaseline = frame.snapshot.heldPeaks
            truePeakGrace = 12
            peakSequence = frame.snapshot.sequence
            peakStream = frame.snapshot.streamID
        }
        // The DSP-held peaks catch an over even in a snapshot this canvas never drew. A true peak above 0 dBTP is
        // an over, like a sample at full scale. Right after a true-peak reset the held values in flight are skipped.
        let snapshot = frame.snapshot
        // A reset while paused clears the frozen frame too. Only new audio may light the warning again;
        // drawing the same snapshot repeatedly is not a new peak or progress through the grace period.
        guard frame.running, snapshot.sequence != peakSequence || snapshot.streamID != peakStream else { return }
        peakSequence = snapshot.sequence
        peakStream = snapshot.streamID
        let held = truePeakGrace == 0
        if truePeakGrace > 0 { truePeakGrace -= 1 }
        for role in 0..<Role.count {
            overPeaks[role] = max(overPeaks[role], snapshot.channelTruePeaks[role], held ? snapshot.heldTruePeaks[role] : 0)
            let heldPeak = snapshot.heldPeaks[role] > heldBaseline[role] ? snapshot.heldPeaks[role] : 0
            if max(snapshot.channelPeaks[role], heldPeak, overPeaks[role]) >= 1 { clipped[role] = true }
        }
    }

    private static func clockwise(_ speakers: [Speaker]) -> [Speaker] {
        speakers.sorted { (($0.azimuth ?? 0) + 360).truncatingRemainder(dividingBy: 360) < (($1.azimuth ?? 0) + 360).truncatingRemainder(dividingBy: 360) }
    }

    func build(_ b: inout ShapeBuilder, frame: CanvasFrame, display: MeterSnapshot, size: CGSize, dt: Float) {
        if cachedLayout != frame.layout {
            cachedLayout = frame.layout
            bed = Self.clockwise(frame.layout.speakers.filter { $0.group == .front || $0.group == .surround })
            heights = Self.clockwise(frame.layout.speakers.filter { $0.group == .height })
        }
        spring.step(target: frame.spatial ? 1 : 0, dt: dt)
        monoSpring.step(target: frame.mono ? 1 : 0, dt: dt)
        bands.step(target: part == .room ? frame.stageBands : frame.levelsBands, dt: dt)
        let layout = SoundstageLayout(size: size, presence: CGFloat(presence), mono: CGFloat(mono), layout: frame.layout, part: part,
                                      lanes: part == .levels ? bands.lanes : CGFloat(StereoBands.count))

        // The springs above move the layout even while frozen; holds, trails and envelopes below do not.
        let signalDt = frame.signal(dt)
        for role in 0..<Role.count {
            peakDb[role] = MeterScale.decibels(display.channelPeaks[role])
            rmsDb[role] = MeterScale.decibels(display.channelRMS[role])
            if peakDb[role] >= holds[role] {
                holds[role] = peakDb[role]
                holdTimers[role] = frame.options.levelsHold.seconds ?? .infinity
            } else if holdTimers[role] > 0 {
                holdTimers[role] -= signalDt
            } else {
                holds[role] = max(-120, holds[role] - frame.options.levelsRelease.decibelsPerSecond * signalDt)
            }
        }
        domeDrawn = false
        switch part {
        case .room:
            // Stereo and Mono show the stereometer, Immersive the dome: one hands over to the other (`FormatMix.relay`),
            // the stereometer swelling a little as it leaves, the dome settling in from a little farther away.
            let relay = FormatMix.relay(CGFloat(presence))
            if relay.dome > 0.001 {
                dome.draw(&b, frame: frame, size: size, dt: signalDt, displayDt: dt, opacity: Float(relay.dome), zoom: relay.domeZoom)
                domeDrawn = true
            }
            updateCloud(frame)
            if relay.stereo > 0.001 {
                let start = b.shapes.count
                drawStereometer(&b, layout: layout, display: display, running: frame.shown, style: frame.stageStyle, dt: signalDt,
                                layers: shownLayers(frame), focus: focusGroup(frame))
                b.fade(from: start, by: Float(relay.stereo))
                b.scale(from: start, by: relay.stereoScale, around: layout.scopeCenter)
            }
        case .levels:
            drawMeters(&b, layout: layout, frame: frame)
            drawCorrelation(&b, layout: layout, display: display, running: frame.shown, dt: signalDt, layers: bands.layers)
        }
    }

    /// L always reads at full strength, R recedes in Mono, every other role follows the Spatial presence.
    private func visibility(_ role: Int) -> Float {
        role == Role.left ? 1 : (role == Role.right ? presence + (1 - presence) * (1 - mono) : presence)
    }


    /// The stereometer's band layers, each with the groups it draws: all of them, or the single band chosen on the
    /// BANDS menu. A single band applies to its own split; an outgoing split keeps all its bands while it fades.
    private func shownLayers(_ frame: CanvasFrame) -> [(resolution: StereoBands.Resolution, weight: Float, groups: [Int])] {
        bands.layers.map { layer in
            let all = Array(0..<layer.resolution.count)
            guard let solo = frame.options.stageSolo, layer.resolution == frame.stageBands, solo < layer.resolution.count else {
                return (layer.resolution, layer.weight, all)
            }
            return (layer.resolution, layer.weight, [solo])
        }
    }

    /// The published band group the focal point follows: the band shown alone, or the whole programme.
    private func focusGroup(_ frame: CanvasFrame) -> Int {
        guard let solo = frame.options.stageSolo, solo < frame.stageBands.count else { return StereoBands.Resolution.overall.offset }
        return frame.stageBands.offset + solo
    }

    /// A stereometer sample in Mono: R follows L as the mode folds, so the programme stands on M.
    private func folded(_ left: Float, _ right: Float) -> Float { right + (left - right) * mono }

    /// Keeps the clouds of the last `cloudLife` seconds; each fades with its age, frame by frame. Frozen, the
    /// clouds and their clock stand still, so the trail holds as it was.
    private func updateCloud(_ frame: CanvasFrame) {
        guard frame.shown else {
            clouds.removeAll()
            return
        }
        guard frame.running else { return }
        let now = CanvasDriver.now
        cloudClock = now
        let snapshot = frame.snapshot
        if snapshot.sequence != cloudSequence {
            cloudSequence = snapshot.sequence
            clouds.insert((snapshot.bandPoints, now), at: 0)
        }
        clouds.removeAll { now - $0.time > Self.cloudLife }
        if clouds.count > Self.cloudGenerations { clouds.removeLast(clouds.count - Self.cloudGenerations) }
    }

    /// Stereometer, in Stereo: a polar sample plot in a half disc, like a hardware goniometer turned into polar
    /// form. Every sample of the newest 1/30 s is a dot at its angle between L and R (mid straight up, side
    /// sideways, out of phase along the horizon) and at its level from the centre (−60 dBFS) to the rim (0 dBFS),
    /// coloured by its `StereoBands` band: a narrow, centred bass reads as a warm spike toward M, a wide top end as
    /// a cool fan. Around the rim, one arc per band sums the band up: centred where its energy sits between L and
    /// R, spread by its decorrelation (a point for mono or panned, the L–R span for unrelated sides, on toward the
    /// horizon as it goes out of phase), bright with its level.
    private func drawStereometer(_ b: inout ShapeBuilder, layout: SoundstageLayout, display: MeterSnapshot, running: Bool,
                                 style: StageStyle, dt: Float,
                                 layers: [(resolution: StereoBands.Resolution, weight: Float, groups: [Int])], focus: Int) {
        let ink = Theme.inkRGB
        let c = layout.scopeCenter
        func arc(from: Double, to: Double, fraction: CGFloat, width: CGFloat, _ color: SIMD4<Float>) {
            let steps = max(2, Int(abs(to - from) / 4))
            var previous = layout.scopePoint(angle: from, fraction: fraction)
            for step in 1...steps {
                let point = layout.scopePoint(angle: from + (to - from) * Double(step) / Double(steps), fraction: fraction)
                b.line(previous, point, width: width, color)
                previous = point
            }
        }
        // Field: the plate itself, no toned screen. Level rings every 12 dB as concentric hairlines, brightest
        // nearest the listener and fading outward, the full-scale rim held a touch firmer; L, M and R as faint
        // spokes, so the rings and the signal carry the picture.
        let dark = Theme.dark
        let rings: [Float] = [-48, -36, -24, -12]
        for (index, db) in rings.enumerated() {
            arc(from: -90, to: 90, fraction: SoundstageLayout.scopeFraction(decibels: db), width: 0.75,
                ink.simd((dark ? 0.30 : 0.26) - Float(index) * (dark ? 0.045 : 0.04)))
        }
        arc(from: -90, to: 90, fraction: 1, width: 0.9, ink.simd(dark ? 0.24 : 0.22))
        b.line(layout.scopePoint(angle: -90, fraction: 1), layout.scopePoint(angle: 90, fraction: 1), width: 0.75, ink.simd(0.14))
        for angle in [-45.0, 0, 45] {
            b.line(c, layout.scopePoint(angle: angle, fraction: 1), width: 0.75, ink.simd(angle == 0 ? 0.12 : 0.07))
        }

        // Rims: a hairline track per band group of the chosen resolution, then its arc. During a band switch the
        // outgoing and incoming sets cross-fade.
        for (resolution, weight, shown) in layers {
        let rimStart = b.shapes.count
        for group in shown {
            let fraction = layout.rimRadius(group) / max(1, layout.scopeRadius)
            let hue = Theme.bandRGB(resolution, group)
            let band = resolution.offset + group
            arc(from: -90, to: 90, fraction: fraction, width: 0.75, hue.simd(dark ? 0.12 : 0.14))
            guard running, display.bandLevel[band] > -80 else { continue }
            // Mono has one channel: the band stands on M, as narrow as a mono source.
            let m = Double(mono)
            let r = Double(max(-1, min(1, display.bandCorrelation[band]))) * (1 - m) + m
            let balance = Double(max(-1, min(1, display.bandBalance[band]))) * (1 - m)
            let spread = min(90, r >= 0 ? 45 * (1 - r) : 45 + 45 * -r) * (1 - pow(abs(balance), 3))
            let centre = 45 * balance
            let half = max(2, spread)
            let level = MeterScale.position(decibels: display.bandLevel[band] + 12)
            let alpha = 0.35 + 0.65 * level
            arc(from: max(-90, centre - half), to: min(90, centre + half), fraction: fraction, width: 2.25, hue.simd(alpha))
        }
        b.fade(from: rimStart, by: weight)
        }

        // Shapes only update while shown: start them afresh on a style change instead of flashing old ones.
        if style != envelopeStyle {
            envelopeStyle = style
            for index in envelopes.indices { envelopes[index] = [Float](repeating: 0, count: Self.envelopeBins) }
        }
        switch style {
        case .dots: drawCloud(&b, layout: layout, layers: layers)
        case .outline, .filled: drawEnvelopes(&b, layout: layout, running: running, dt: dt, filled: style == .filled, layers: layers)
        }
        b.disk(c, radius: 1.6, ink.simd(0.35))
        drawFocus(&b, layout: layout, display: display, running: running, dt: dt, group: focus)
    }

    /// Eased position of the stereometer's focal point: its direction (°) and scope fraction.
    private var focusAngle: Double = 0
    private var focusFraction: CGFloat = 0
    private var focusShown: Float = 0

    /// The focal point: one bright dot where the programme (or the band shown alone) sits, from its measured
    /// balance (toward L or R, as a sample on one side alone points at ±45°; on M in Mono) and its level from the
    /// centre (−60 dBFS) to the rim. It eases over about 0.1 s so it reads as a position, not a flicker, and
    /// fades out in silence.
    private func drawFocus(_ b: inout ShapeBuilder, layout: SoundstageLayout, display: MeterSnapshot, running: Bool,
                           dt: Float, group: Int) {
        let level = display.bandLevel[group]
        let live = running && level > -80
        let ease = dt > 0 ? CGFloat(1 - exp(-dt / 0.1)) : 1
        if live {
            let angle = 45 * Double(max(-1, min(1, display.bandBalance[group]))) * Double(1 - mono)
            let fraction = SoundstageLayout.scopeFraction(decibels: level)
            focusAngle += (angle - focusAngle) * Double(ease)
            focusFraction += (fraction - focusFraction) * ease
        }
        focusShown += ((live ? 1 : 0) - focusShown) * Float(ease)
        guard focusShown > 0.01, focusFraction > 0.01 else { return }
        let at = layout.scopePoint(angle: focusAngle, fraction: focusFraction)
        let lit = Theme.dark ? Theme.creamRGB : Theme.inkRGB
        b.glow(at, radius: 12, lit.simd(0.22 * focusShown))
        b.disk(at, radius: 5, Theme.displayRGB.simd(0.85 * focusShown))
        b.disk(at, radius: 3.6, lit.simd(focusShown))
    }

    /// Dots style: every sample of the recent clouds as a point of light, in the Immersive nebula's manner. Each
    /// sample is a soft glow in its band's hue; the newest 1/30 s also carries a small bright spark, and older
    /// samples spread and fade as they age, so the trail diffuses into a haze. On dark the glows add up as light
    /// (`ShapeBuilder.light`): where the programme gathers they burn toward white and the fringes keep their hues;
    /// on light they lay a tinted wash with the sparks crisp on top. Bands are interleaved point by point, so no
    /// band always covers another. During a band switch the dots re-colour by cross-fading the two groupings.
    private func drawCloud(_ b: inout ShapeBuilder, layout: SoundstageLayout,
                           layers: [(resolution: StereoBands.Resolution, weight: Float, groups: [Int])]) {
        let dark = Theme.dark
        let points = StereoBands.scopePoints
        let now = cloudClock
        let center = layout.scopeCenter, radius = layout.scopeRadius
        // Glow and spark sizes follow the scope, so a small panel is not smothered and an enlarged one not sparse.
        let size = max(0.75, min(1.4, radius / 220))
        let lightStart = b.shapes.count
        for (resolution, weight, shown) in layers {
        let cloudStart = b.shapes.count
        let groups = resolution.groups
        let hues = (0..<resolution.count).map { Theme.bandRGB(resolution, $0) }
        let sparks = hues.map { dark ? $0.mixed(with: Theme.RGB(r: 1, g: 1, b: 1), amount: 0.55) : $0 }
        // Fewer groups overlap less: keep the summed light about as bright whatever the band setting.
        let share = Float(1 / Double(max(1, shown.count)).squareRoot())
        for (generation, cloud) in clouds.enumerated().reversed() where cloud.points.count == StereoBands.scopeFloats {
            let newest = generation == 0
            let age = Float((now - cloud.time) / Self.cloudDecay)
            let opacity = newest ? 1 : Float(exp(-Double(age)))
            guard opacity > 0.06 else { continue }
            let glowRadius = size * (8 + 3 * CGFloat(min(age, 3)))
            let glowAlpha = (dark ? 0.3 : 0.17) * share * opacity * (newest ? 1 : 0.8)
            for point in 0..<points {
                for (group, members) in groups.enumerated() where shown.contains(group) {
                    // A group's samples are the sum of its bands' (the crossovers sum back to the programme).
                    var left: Float = 0, right: Float = 0
                    for band in members {
                        left += cloud.points[(band * points + point) * 2]
                        right += cloud.points[(band * points + point) * 2 + 1]
                    }
                    guard let offset = SoundstageLayout.scopeSample(left: left, right: folded(left, right)) else { continue }
                    let position = CGPoint(x: center.x + offset.x * radius, y: center.y + offset.y * radius)
                    b.glow(position, radius: glowRadius, hues[group].simd(glowAlpha))
                    if newest { b.disk(position, radius: 1.15 * size, sparks[group].simd(dark ? 0.75 : 0.9)) }
                }
            }
        }
        b.fade(from: cloudStart, by: weight)
        }
        if dark { b.light = lightStart..<b.shapes.count }
    }

    /// Where a sample of the cloud lands on the half disc: its direction (−90 L … 0 M … 90 R) and scope fraction.
    private static func polar(left: Float, right: Float) -> (angle: Double, fraction: CGFloat)? {
        var mid = (left + right) * 0.70710677, side = (right - left) * 0.70710677
        let amplitude = (left * left + right * right).squareRoot()
        guard amplitude > 0.001, amplitude.isFinite else { return nil }
        if mid < 0 { mid = -mid; side = -side }
        let fraction = SoundstageLayout.scopeFraction(decibels: 20 * log10(amplitude))
        guard fraction > 0 else { return nil }
        return (Double(atan2(side, mid)) * 180 / .pi, fraction)
    }

    /// Outline and Filled styles: each band as the shape its samples fill, the outline of how far they reach in
    /// every direction. A narrow, centred bass is a tall spike toward M; a wide top end a low, broad fan.
    ///
    /// Filled shapes overlap wherever bands share a direction, so they are layered to stay readable: the largest
    /// shape is laid down first and the smaller ones over it, every fill is a light tint (overlaps mix rather than
    /// cover), and all the outlines are drawn after all the fills, each on a backing stroke in the screen colour,
    /// so every band's edge stays whole and crisp on top of any fill.
    private func drawEnvelopes(_ b: inout ShapeBuilder, layout: SoundstageLayout, running: Bool, dt: Float, filled: Bool,
                               layers: [(resolution: StereoBands.Resolution, weight: Float, groups: [Int])]) {
        let bins = Self.envelopeBins
        let points = StereoBands.scopePoints
        let fall = exp(-dt / 0.25)
        let c = layout.scopeCenter
        for (resolution, weight, shown) in layers {
            // Reach per direction of each group, from the clouds in view.
            for (group, members) in resolution.groups.enumerated() {
                var reach = [Float](repeating: 0, count: bins)
                var count = [Float](repeating: 0, count: bins)
                if running {
                    for cloud in clouds where cloud.points.count == StereoBands.scopeFloats {
                        for point in 0..<points {
                            var left: Float = 0, right: Float = 0
                            for band in members {
                                left += cloud.points[(band * points + point) * 2]
                                right += cloud.points[(band * points + point) * 2 + 1]
                            }
                            guard let sample = Self.polar(left: left, right: folded(left, right)) else { continue }
                            let bin = min(bins - 1, max(0, Int((sample.angle + 90) / 180 * Double(bins))))
                            reach[bin] = max(reach[bin], Float(sample.fraction))
                            count[bin] += 1
                        }
                    }
                }
                // A direction only a few stray samples reach is drawn short: the shape follows where the band's
                // samples gather, not the farthest outlier, so a focused band reads narrow and a diffuse one wide.
                let total = count.reduce(0, +)
                if total > 0 {
                    let even = total / Float(bins)
                    for bin in 0..<bins { reach[bin] *= min(1, (count[bin] / (0.6 * even)).squareRoot()) }
                }
                // Close gaps between sparse samples (the reach of a bin carries to its neighbours, tapering), then
                // soften the edge so the outline reads as a shape rather than a comb.
                var spread = reach
                for bin in 0..<bins {
                    for offset in 1...2 {
                        let taper: Float = offset == 1 ? 0.92 : 0.8
                        if bin >= offset { spread[bin] = max(spread[bin], reach[bin - offset] * taper) }
                        if bin + offset < bins { spread[bin] = max(spread[bin], reach[bin + offset] * taper) }
                    }
                }
                let index = resolution.offset + group
                for _ in 0..<2 {
                    let pass = spread
                    for bin in 0..<bins { spread[bin] = 0.25 * pass[max(0, bin - 1)] + 0.5 * pass[bin] + 0.25 * pass[min(bins - 1, bin + 1)] }
                }
                for bin in 0..<bins {
                    let target = spread[bin]
                    let value = envelopes[index][bin]
                    envelopes[index][bin] = target > value ? value + (target - value) * 0.6 : max(target, value * fall)
                }
            }

            // The outline of each group: out along its reach, from the L horizon through M to the R horizon.
            let shapes: [(group: Int, outline: [CGPoint], area: Float)] = shown.compactMap { group in
                let reach = envelopes[resolution.offset + group]
                let area = reach.reduce(0) { $0 + $1 * $1 }
                guard area > 0.0005 else { return nil }
                let outline = (0...bins).map { edge -> CGPoint in
                    // Bin edges; the reach at an edge is its two bins' mean. The ends keep their bin's reach, so a band
                    // that reaches out to the horizon closes along it instead of pinching back to the centre there,
                    // which left dark wedges between the shapes and the horizon (Filled).
                    let before = edge > 0 ? reach[edge - 1] : reach[0], after = edge < bins ? reach[edge] : reach[bins - 1]
                    let fraction = CGFloat((before + after) / 2)
                    return layout.scopePoint(angle: -90 + 180 * Double(edge) / Double(bins), fraction: fraction)
                }
                return (group, outline, area)
            }
            let start = b.shapes.count
            if filled {
                // Filled: each band as a body of light, like the Immersive dome's volume (`bodyFragment`).
                for shape in shapes.sorted(by: { $0.area > $1.area }) {
                    drawBody(&b, center: c, outline: shape.outline, hue: Theme.bandRGB(resolution, shape.group))
                }
            } else {
                // Outlines skip the closing spokes along the horizon, which only close the shape.
                for shape in shapes.sorted(by: { $0.area > $1.area }) {
                    let hue = Theme.bandRGB(resolution, shape.group)
                    let edge = shape.outline.dropFirst().dropLast()
                    for (p, q) in zip(edge, edge.dropFirst()) { b.line(p, q, width: 3.5, Theme.displayRGB.simd(0.7)) }
                    for (p, q) in zip(edge, edge.dropFirst()) { b.line(p, q, width: 1.6, hue.simd(0.95)) }
                }
            }
            b.fade(from: start, by: weight)
        }
    }

    /// One band of the Filled stereometer drawn as the Immersive dome draws its volume, flattened: a haze that
    /// thickens toward the listener and turns toward cream (ink on a light well) at the core, a soft skin where the
    /// band's reach ends, lit from the upper left like the dome's, and a faint glow beyond it. No hard outline:
    /// overlapping bands show through one another as the dome's lobes do.
    private func drawBody(_ b: inout ShapeBuilder, center c: CGPoint, outline: [CGPoint], hue: Theme.RGB) {
        guard outline.count >= 2 else { return }
        let dark = Theme.dark
        let core = dark ? Theme.creamRGB : Theme.inkRGB
        // Fractions of the reach, denser toward the skin, then out into the glow.
        let rings: [CGFloat] = [0, 0.25, 0.45, 0.62, 0.76, 0.86, 0.93, 0.97, 1, 1.04, 1.1, 1.17]
        let light = SIMD2<Float>(-0.47, -0.88) // screen space: up and to the left
        let haze: Float = dark ? 0.62 : 0.42, skinStrength: Float = dark ? 0.5 : 0.42
        func color(_ f: CGFloat, lit: Float) -> SIMD4<Float> {
            let x = Float(f)
            let inside = max(0, 1 - x)
            let body = inside * inside * 0.8 + inside * 0.35
            let skin = exp(-(x - 1) * (x - 1) / (0.085 * 0.085))
            let tint = min(1, inside * inside * 0.75)
            let deep = SIMD3<Float>(hue.r * 0.85 + (core.r - hue.r * 0.85) * tint, hue.g * 0.85 + (core.g - hue.g * 0.85) * tint,
                                    hue.b * 0.85 + (core.b - hue.b * 0.85) * tint)
            let shine = SIMD3<Float>(hue.r, hue.g, hue.b) * (0.7 + 0.65 * lit)
            let s = min(1, skin * 1.5)
            let rgb = deep + (shine - deep) * s
            let alpha = min(0.94, body * haze + skin * skinStrength * (0.65 + 0.35 * lit))
            return SIMD4<Float>(min(1, rgb.x), min(1, rgb.y), min(1, rgb.z), alpha)
        }
        // How lit each point of the outline is: its direction from the listener against the light.
        let lit: [Float] = outline.map { point in
            let dx = Float(point.x - c.x), dy = Float(point.y - c.y)
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0.5 else { return 0.55 }
            return 0.55 + 0.45 * max(0, (dx * light.x + dy * light.y) / length)
        }
        func at(_ index: Int, _ f: CGFloat) -> CGPoint {
            CGPoint(x: c.x + (outline[index].x - c.x) * f, y: c.y + (outline[index].y - c.y) * f)
        }
        // Each ring's colour at each outline point, once: neighbouring quads share their corners.
        let count = outline.count
        var colors = [SIMD4<Float>](repeating: .zero, count: rings.count * count)
        for (ring, f) in rings.enumerated() {
            for index in 0..<count { colors[ring * count + index] = color(f, lit: lit[index]) }
        }
        for ring in 0..<(rings.count - 1) {
            let inner = rings[ring], outer = rings[ring + 1]
            let innerRow = ring * count, outerRow = innerRow + count
            for index in 0..<(count - 1) {
                let next = index + 1
                let a = at(index, inner), d = at(next, inner), p = at(index, outer), q = at(next, outer)
                let ca = colors[innerRow + index], cd = colors[innerRow + next]
                let cp = colors[outerRow + index], cq = colors[outerRow + next]
                if inner == 0 {
                    b.triangle(a, p, q, ca, cp, cq)
                } else {
                    b.triangle(a, p, q, ca, cp, cq)
                    b.triangle(a, q, d, ca, cq, cd)
                }
            }
        }
    }

    /// Immersive band image: where each `StereoBands` band sits in the room, in the stereometer's band colours.
    /// Each orb is the band's energy centroid in 3D over every routed speaker but LFE, so its direction says where
    /// the band comes from, its distance from the listener how focused it is and its height how much the upper
    /// layer carries it: a bass anchored in the front and air thrown into the surrounds and ceiling read apart at
    /// a glance. It follows the Immersive presence, so it is gone in Stereo (the stereometer's band view) and Mono.
    private func drawBandImage(_ b: inout ShapeBuilder, layout: SoundstageLayout, frame: CanvasFrame,
                               resolution: StereoBands.Resolution) {
        typealias P3 = SoundstageLayout.Point3
        let p = presence
        guard p > 0.002, frame.shown else { return }
        let power = frame.snapshot.roleBandPower
        guard power.count == StereoBands.roleFloats else { return }
        for (group, members) in resolution.groups.enumerated() {
            var centroid = P3(x: 0, y: 0, z: 0)
            var total: CGFloat = 0
            for speaker in layout.speakers where speaker.group != .lfe && frame.activeRoles[speaker.role] {
                let energy = CGFloat(members.reduce(Float(0)) { $0 + max(0, power[speaker.role * StereoBands.count + $1]) })
                centroid = centroid + layout.position(speaker) * energy
                total += energy
            }
            // Below −80 dBFS the band has nothing to point with.
            guard total > 1e-8 else { continue }
            centroid = centroid * (0.92 / total)
            let hue = Theme.bandRGB(resolution, group)
            let at = layout.project(centroid)
            let level = MeterScale.position(decibels: 10 * log10(Float(total)) + 12)
            let alpha = (0.45 + 0.55 * level) * p
            if centroid.y > 0.005 {
                b.line(layout.point(P3(x: centroid.x, y: 0, z: centroid.z)), at.point, width: 1, hue.simd(0.35 * alpha))
            }
            b.glow(at.point, radius: (9 + 8 * CGFloat(level)) * at.scale, hue.simd(0.40 * alpha))
            b.disk(at.point, radius: 4.75 * at.scale, Theme.displayRGB.simd(0.9 * p))
            b.disk(at.point, radius: 3.5 * at.scale, hue.simd(alpha))
        }
    }

    /// A closed polygon with each edge bent toward a Catmull-Rom curve through the vertices by `amount` (0 keeps
    /// the straight edges, 1 is the full curve), so the field can morph between the two.
    private static func smoothed(_ points: [CGPoint], amount: CGFloat, steps: Int = 6) -> [CGPoint] {
        guard points.count >= 3, amount > 0.001 else { return points }
        let n = points.count
        var result: [CGPoint] = []
        result.reserveCapacity(n * steps)
        for i in 0..<n {
            let p0 = points[(i + n - 1) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps), t2 = t * t, t3 = t2 * t
                func curve(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                let straight = CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t)
                let bent = CGPoint(x: curve(p0.x, p1.x, p2.x, p3.x), y: curve(p0.y, p1.y, p2.y, p3.y))
                result.append(CGPoint(x: straight.x + (bent.x - straight.x) * amount, y: straight.y + (bent.y - straight.y) * amount))
            }
        }
        return result
    }

    /// Channel meters: each bar runs in a recessed slot its full width, so the scale reads down the whole height even
    /// when the channel is quiet. One fill whose colour follows the current level only (the accent, ochre while the
    /// channel peaks within 3 dB of full scale), the peak as the same colour translucent behind it, and the peak hold as
    /// a 2 pt mark across the slot, ink (ochre within 3 dB of full scale). An over never recolours the bar: above 0 dB
    /// the slot is tinted ember and fills to the highest true-peak over, and a dot over the bar stays lit until the
    /// next reset.
    private func drawMeters(_ b: inout ShapeBuilder, layout: SoundstageLayout, frame: CanvasFrame) {
        guard layout.scale.height > 8 else { return }
        let ink = Theme.inkRGB
        let ember = Theme.emberRGB
        if let first = layout.columns.first(where: { $0.width > 0.5 }), let last = layout.columns.last(where: { $0.width > 0.5 }) {
            let zero = layout.y(decibels: 0).rounded()
            b.rect(CGRect(x: first.minX, y: zero - 0.25, width: last.maxX - first.minX, height: 0.5), ink.simd(Float(ChartInk.reference)))
        }
        // Group rules under each header, in the group's colour.
        for header in layout.headers {
            let weight = Float(layout.headerWeight(header.group))
            guard header.rect.width > 1 else { continue }
            b.roundedRect(CGRect(x: header.rect.minX + 2, y: (header.rect.maxY - 3).rounded(), width: header.rect.width - 4, height: 1.5),
                          radius: 0.75, Theme.groupRGB(header.group).simd(0.5 * weight * weight))
        }
        for (index, speaker) in layout.speakers.enumerated() {
            let role = speaker.role
            let v = visibility(role)
            guard v > 0.002 else { continue }
            let bar = layout.bar(index)
            guard bar.width > 1 else { continue }
            let active = frame.activeRoles[role]
            let radius = bar.width / 2
            // Track: a recessed slot the bar's full width, so its scale runs the whole height even when quiet, tinted
            // ember above 0 dB.
            b.roundedRect(bar, radius: radius, ink.simd((active ? 0.075 : 0.04) * v))
            let overTrack = layout.overTrack(index)
            b.roundedRect(overTrack, radius: min(radius, overTrack.height / 2), ember.simd(0.10 * v))
            if active {
                let over = MeterScale.decibels(overPeaks[role])
                let status = peakDb[role] >= -3 ? Theme.ochreRGB : Theme.sageRGB
                if peakDb[role] > -70 {
                    let top = layout.y(decibels: min(0, peakDb[role]))
                    b.roundedRect(CGRect(x: bar.minX, y: top, width: bar.width, height: max(bar.width, bar.maxY - top)),
                                  radius: radius, status.simd(0.35 * v))
                }
                if rmsDb[role] > -70 {
                    let top = layout.y(decibels: min(0, rmsDb[role]))
                    b.roundedRect(CGRect(x: bar.minX, y: top, width: bar.width, height: max(bar.width, bar.maxY - top)),
                                  radius: radius, status.simd(v))
                }
                if over > 0 && overTrack.height > 1 {
                    let top = max(overTrack.minY, min(overTrack.maxY - 2, layout.y(decibels: over)))
                    let fill = CGRect(x: overTrack.minX, y: top, width: overTrack.width, height: overTrack.maxY - top)
                    b.roundedRect(fill, radius: min(radius, fill.height / 2), ember.simd(v))
                }
                if holds[role] > -60 {
                    // Peak hold: the gauge's target mark, a thin ink bar across the track.
                    let y = layout.y(decibels: min(0, holds[role]))
                    b.roundedRect(CGRect(x: bar.minX - 2, y: y - 1, width: bar.width + 4, height: 2), radius: 1,
                                  (holds[role] >= -3 ? Theme.ochreRGB : ink).simd(v))
                }
            }
            // Clip light, like the LIVE dot: faint while clear, ember once an over or a full-scale sample has
            // latched it, until the next reset.
            let cap = layout.cap(index)
            b.disk(CGPoint(x: cap.midX, y: cap.midY), radius: cap.width / 2,
                   clipped[role] ? ember.simd(v) : ink.simd((active ? 0.16 : 0.07) * v))
        }
    }

    /// Correlation on the conventional scale, −1 at the left, 0 at the centre, +1 at the right, over coloured
    /// zones that say what each range means for the listener: out of phase (cancels in mono), wide, healthy
    /// stereo, mono. The bar is split into one lane per `StereoBands` band (the top band on top), so a bass that
    /// is mono-safe and a top end that cancels read apart: each lane fills from 0 to its band's reading and marks
    /// it with a short needle in its zone colour. The full-band needle crosses every lane, and a hold tick marks
    /// the lowest recent full-band reading, so a brief dip toward cancellation stays visible after it moved on.
    private func drawCorrelation(_ b: inout ShapeBuilder, layout: SoundstageLayout, display: MeterSnapshot, running: Bool, dt: Float,
                                 layers: [(resolution: StereoBands.Resolution, weight: Float)]) {
        let value = display.correlation
        let live = running && value != MeterSnapshot.noCorrelation
        updateCorrelationHold(live ? value : nil, dt: dt)
        // Shown in Stereo only: the section dissolves as it folds away toward Mono or Multi Channel.
        let fade = Float(layout.correlationWeight * layout.correlationWeight)
        guard fade > 0.002 else { return }
        let track = layout.correlationTrack
        let ink = Theme.inkRGB
        let edges: [Float] = [-1] + CorrelationZone.edges + [1]
        // Zone tints behind every lane, the lit zone stronger.
        for (from, to) in zip(edges, edges.dropFirst()) {
            let x0 = layout.correlationX(from), x1 = layout.correlationX(to)
            var tint = Theme.correlation((from + to) / 2)
            tint.w = (live && CorrelationZone(value) == CorrelationZone((from + to) / 2) ? 0.16 : 0.08) * fade
            b.rect(CGRect(x: x0, y: track.minY, width: x1 - x0, height: track.height), tint)
        }
        // Lane tracks of each resolution showing; during a band switch the two sets cross-fade in the gliding bar.
        for (resolution, weight) in layers {
            for lane in 0..<resolution.count {
                let rect = layout.correlationLane(lane, of: resolution.count)
                b.roundedRect(rect, radius: rect.height / 2, ink.simd(0.06 * fade * weight))
            }
        }
        for edge in CorrelationZone.edges + [0] {
            let x = (layout.correlationX(edge) * 2).rounded() / 2
            let center = edge == 0
            b.rect(CGRect(x: x, y: track.minY - (center ? 3 : 1), width: 0.5, height: track.height + (center ? 6 : 2)),
                   ink.simd((center ? 0.35 : 0.18) * fade))
        }
        guard running else { return }
        // Each lane: a fill from 0 to its reading, split at the colour stops so its colour follows the scale, and
        // a short needle. Quiet bands fade back, so the lanes that carry the mix lead. Overall is the single
        // classic bar: the full-band reading, marked by the full-band needle alone.
        for (resolution, weight) in layers {
        let laneStart = b.shapes.count
        let overall = resolution == .overall
        for group in 0..<resolution.count {
            let band = resolution.offset + group
            let reading = overall ? display.correlation : display.bandCorrelation[band]
            guard reading != MeterSnapshot.noCorrelation else { continue }
            let lane = layout.correlationLane(group, of: resolution.count).insetBy(dx: 0, dy: 1)
            let presence = 0.45 + 0.55 * MeterScale.position(decibels: display.bandLevel[band] + 12)
            let lower = min(0, reading), upper = max(0, reading)
            var from = lower
            for stop in Theme.correlationStops where stop.value > from && from < upper {
                let to = min(stop.value, upper)
                let x0 = layout.correlationX(from), x1 = layout.correlationX(to)
                if x1 - x0 > 0.01 {
                    var left = Theme.correlation(from), right = Theme.correlation(to)
                    left.w = 0.7 * presence * fade
                    right.w = 0.7 * presence * fade
                    b.quad(CGRect(x: x0, y: lane.minY, width: x1 - x0, height: lane.height), left: left, right: right)
                }
                from = to
            }
            guard !overall else { continue }
            let x = layout.correlationX(reading)
            var needle = Theme.correlation(reading)
            needle.w = presence * fade
            b.roundedRect(CGRect(x: x - 1.5, y: lane.minY - 1, width: 3, height: lane.height + 2), radius: 1.5, needle)
        }
        b.fade(from: laneStart, by: weight)
        }
        guard live else { return }
        if let low = correlationLow, low < value - 0.02 {
            var hold = Theme.correlation(low) * 0.6 + ink.simd() * 0.4
            hold.w = fade
            b.rect(CGRect(x: layout.correlationX(low) - 1, y: track.minY - 3, width: 2, height: track.height + 6), hold)
        }
        let x = layout.correlationX(value)
        let needle = value < CorrelationZone.edges[0] ? Theme.emberRGB : ink
        b.glow(CGPoint(x: x, y: track.minY - 4), radius: 8, Theme.correlation(value) * SIMD4(1, 1, 1, 0) + SIMD4(0, 0, 0, 0.30 * fade))
        b.roundedRect(CGRect(x: x - 1, y: track.minY - 5, width: 2, height: track.height + 10), radius: 1, needle.simd(0.85 * fade))
        b.triangle(CGPoint(x: x - 4, y: track.minY - 8), CGPoint(x: x + 4, y: track.minY - 8), CGPoint(x: x, y: track.minY - 3),
                   needle.simd(0.95 * fade), needle.simd(0.95 * fade), needle.simd(0.95 * fade))
    }

    private func updateCorrelationHold(_ value: Float?, dt: Float) {
        guard let value else {
            correlationLow = nil
            return
        }
        if let low = correlationLow, low < value {
            if correlationLowTimer > 0 {
                correlationLowTimer -= dt
            } else {
                correlationLow = min(value, low + 0.5 * dt)
            }
        } else {
            correlationLow = value
            correlationLowTimer = 2
        }
    }
}

extension SoundstageScene {
    /// Regression for a latched over, paused reset, stale snapshots, and a new genuine over.
    static func checkPeakReset() -> Bool {
        let scene = SoundstageScene(part: .levels)
        var frame = CanvasFrame(running: true)
        frame.snapshot.sequence = 1
        frame.snapshot.channelTruePeaks[Role.left] = 1.1
        frame.snapshot.heldTruePeaks[Role.left] = 1.2
        scene.prepare(frame: frame)
        guard scene.clipped[Role.left] else { return false }
        frame.running = false
        frame.truePeakEpoch += 1
        for _ in 0..<180 { scene.prepare(frame: frame) }
        guard !scene.clipped[Role.left], scene.overPeaks[Role.left] == 0 else { return false }
        frame.running = true
        scene.prepare(frame: frame)
        guard !scene.clipped[Role.left] else { return false }
        frame.snapshot.sequence = 2
        frame.snapshot.channelTruePeaks[Role.left] = 0.5
        for _ in 0..<180 { scene.prepare(frame: frame) }
        guard !scene.clipped[Role.left] else { return false }
        frame.snapshot.sequence = 3
        frame.snapshot.channelTruePeaks[Role.left] = 1.1
        scene.prepare(frame: frame)
        guard scene.clipped[Role.left] else { return false }
        frame.running = false
        frame.epoch += 1
        scene.prepare(frame: frame)
        guard !scene.clipped[Role.left] else { return false }
        print("PASS: peak warnings clear while paused, ignore stale frames and relight for new overs")
        return true
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
