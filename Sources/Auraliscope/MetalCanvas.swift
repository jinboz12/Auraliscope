import AnalysisCore
import AppKit
import AudioRing
import AudioToolbox
import Combine
import ImageIO
import MetalKit
import SwiftUI

enum CanvasKind: String { case spectrum, spectrogram, waveform, soundstage, levels }

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
}

/// Critically damped format transition (Stereo ↔ Spatial, or Stereo ↔ Mono), matched to the SwiftUI `formatShift` spring (response
/// 0.55 s), so Metal scenes and their SwiftUI labels move as one.
struct PresenceSpring {
    static let omega: Float = 2 * .pi / 0.55
    /// 1 = full layout, 0 = stereo. Negative until the first frame, which snaps to the target.
    private(set) var value: Float = -1
    private var velocity: Float = 0

    mutating func step(target: Float, dt: Float) {
        guard value >= 0 else { value = target; return }
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
            context.coordinator.renderer = try CanvasRenderer(kind: kind, gpu: gpu, shared: true)
            CanvasDriver.shared.follow(model)
        } catch {
            let message = StatusMessage { L("Metal failed to start: %@", error.localizedDescription) }
            Task { @MainActor in model.reportRendererError(message) }
        }
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.forceRedraw = true
        (view as? CanvasView)?.wake()
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        (view as? CanvasView)?.coordinator = nil
        view.delegate = nil
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let model: MeterModel
        let kind: CanvasKind
        var renderer: CanvasRenderer?
        var forceRedraw = true
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
                let frame = nextFrame ?? model.canvasFrame()
                let command = sharedCommand
                nextFrame = nil
                sharedCommand = nil
                guard let renderer, view.bounds.width > 0, view.bounds.height > 0 else { return }
                let committed = renderer.draw(in: view, frame: frame, force: forceRedraw, command: command)
                forceRedraw = false
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

    /// On screen, sized, and not at rest.
    var wantsFrames: Bool {
        !resting && coordinator != nil && bounds.width > 0 && bounds.height > 0
            && window?.occlusionState.contains(.visible) == true
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

/// Draws every canvas of the meter window from one display link. The model's frame is read once per display
/// refresh and shared by the canvases that want one; a display link per canvas instead multiplied the display
/// timing work and the model reads by the number of panels. With every canvas at rest or hidden, the link stops.
@MainActor
final class CanvasDriver: NSObject {
    static let shared = CanvasDriver()
    private let canvases = NSHashTable<CanvasView>.weakObjects()
    private var ticker: AnyObject?
    private var modelChanges: AnyCancellable?
    /// Display refreshes drawn so far (diagnostics check that paused canvases rest and resumed ones draw).
    private(set) var ticks = 0
    var running: Bool { ticker != nil }

    func add(_ view: CanvasView) { canvases.add(view) }
    func remove(_ view: CanvasView) { canvases.remove(view) }

    /// Every change the model publishes wakes the canvases. Resuming capture, a reset or an over cleared while
    /// paused must reach canvases that went to rest, and the panels around them re-render only when their own
    /// inputs change, which none of these do.
    func follow(_ model: MeterModel) {
        guard modelChanges == nil else { return }
        modelChanges = model.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.wakeAll() }
        }
    }

    private func wakeAll() {
        for view in canvases.allObjects { view.wake() }
    }

    /// Starts the display link if a canvas wants frames.
    func wake() {
        guard ticker == nil, let window = canvases.allObjects.first(where: \.wantsFrames)?.window else { return }
        if #available(macOS 14, *) {
            // Follows the window to whichever display it is on; 60 Hz even on a 120 Hz display, where meters gain
            // nothing visible from twice the frames.
            let link = window.displayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            ticker = link
        } else {
            let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
    }

    private func stop() {
        if #available(macOS 14, *), let link = ticker as? CADisplayLink { link.invalidate() }
        (ticker as? Timer)?.invalidate()
        ticker = nil
    }

    @objc private func tick() {
        let views = canvases.allObjects.filter(\.wantsFrames)
        guard let model = views.first?.coordinator?.model else { return stop() }
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
    let waterfall: MTLRenderPipelineState
    let waveform: MTLRenderPipelineState

    private init(device existing: MTLDevice?, queue existingQueue: MTLCommandQueue?) throws {
        guard let device = existing ?? MTLCreateSystemDefaultDevice(),
              let queue = existingQueue ?? device.makeCommandQueue() else {
            throw MetalError.unavailable
        }
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
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
        descriptor.fragmentFunction = library.makeFunction(name: "waterfallFragment")
        waterfall = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "waveformFragment")
        waveform = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func pipeline(_ kind: UnderlayKind) -> MTLRenderPipelineState {
        switch kind {
        case .waterfall: return waterfall
        case .waveform: return waveform
        }
    }

    // Shape kinds: 0 solid, 1 rounded rect, 2 disk, 3 glow, 4 ring/arc/dashes, 5 antialiased line,
    // 6 rounded-rect hairline outline.
    private static var shaderSource: String { """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float2 position; float2 local; float4 color; float4 shape; };
    struct Raster { float4 position [[position]]; float2 local; float4 color; float4 shape; };

    vertex Raster shapeVertex(uint id [[vertex_id]], device const Vertex *vertices [[buffer(0)]],
                              constant float2 &viewport [[buffer(1)]]) {
        Vertex v = vertices[id];
        Raster out;
        out.position = float4(v.position.x / viewport.x * 2.0 - 1.0, 1.0 - v.position.y / viewport.y * 2.0, 0.0, 1.0);
        out.local = v.local;
        out.color = v.color;
        out.shape = v.shape;
        return out;
    }

    float roundedBox(float2 p, float2 halfSize, float radius) {
        float2 q = abs(p) - halfSize + radius;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    }

    fragment float4 shapeFragment(Raster in [[stage_in]]) {
        float kind = in.shape.x;
        float2 p = in.local;
        float alpha = in.color.a;
        if (kind > 0.5 && kind < 1.5) {
            alpha *= saturate(0.5 - roundedBox(p, in.shape.yz, in.shape.w));
        } else if (kind > 1.5 && kind < 2.5) {
            alpha *= saturate(in.shape.y + 0.5 - length(p));
        } else if (kind > 2.5 && kind < 3.5) {
            float t = saturate(length(p) / in.shape.y);
            alpha *= (1.0 - t) * (1.0 - t);
        } else if (kind > 3.5 && kind < 4.5) {
            alpha *= saturate(0.5 - (abs(length(p) - in.shape.y) - in.shape.z));
            float turn = fract(atan2(p.x, -p.y) / (2.0 * M_PI_F) + 1.0);
            if (in.shape.w > 0.0) {
                alpha *= step(0.5, fract(turn * in.shape.w));
            } else if (in.shape.w < 0.0) {
                alpha *= step(turn, -in.shape.w);
            }
        } else if (kind > 4.5 && kind < 5.5) {
            alpha *= saturate(in.shape.y + 0.5 - abs(p.y));
        } else if (kind > 5.5) {
            alpha *= saturate(1.0 - abs(roundedBox(p, in.shape.yz, in.shape.w) + 0.5));
        }
        return float4(in.color.rgb, alpha);
    }

    // The waterfall's colour map (`Theme.waterfallRamp`): `waterfallRampCount` colours from the empty well to the
    // loudest, run straight between. Every map moves away from the well's own lightness, so loudness reads the same in
    // every appearance.
    float3 rampMap(float x, constant float4 *stops) {
        float scaled = saturate(x) * float(\(Theme.waterfallRampCount - 1));
        uint index = min(uint(scaled), \(Theme.waterfallRampCount - 2)u);
        return mix(stops[index].rgb, stops[index + 1].rgb, scaled - float(index));
    }

    // The waterfall (SpectrogramScene). `history` holds dBFS levels: texel x is a ring slot of columns, y a row,
    // low frequencies first. `head` is the slot the next column goes to; `phase` (0–1) is how far the scroll has
    // moved toward the next column, so the image glides at the display rate between 30 Hz columns; `span` is the
    // columns across the quad.
    struct WaterfallState {
        uint head; uint capacity; float phase; float span;
        float floorDB; float rangeDB; float tilt; float floorOctave; float octaves;
    };

    constant int waterfallRows = \(SpectrogramHistory.rows);

    float waterfallTexel(texture2d<float, access::read> history, uint capacity, int slot, int row) {
        int wrapped = ((slot % int(capacity)) + int(capacity)) % int(capacity);
        return history.read(uint2(uint(wrapped), uint(clamp(row, 0, waterfallRows - 1)))).r;
    }

    // SpectrogramTone: linear over the range, a power curve for a dark floor, part of an S-curve for contrast.
    float waterfallTone(float db, constant WaterfallState &state) {
        float x = pow(saturate((db - state.floorDB) / state.rangeDB), \(SpectrogramTone.gamma));
        return mix(x, x * x * (3.0 - 2.0 * x), \(SpectrogramTone.contrast));
    }

    // The cells a pixel covers along one axis, as up to two ranges of cells and their weights. A cell stands for a
    // box (a column 1/30 s, a row its slice of frequency), centred on its index. Wider than the pixel, a cell is drawn
    // at its full value over the middle of its box and eases into its neighbour across `softness` of a cell around
    // their boundary (never less than one device pixel): a single loud column or row keeps its full brightness, while
    // enlarged cells no longer read as a mosaic of hard-edged blocks or a sweep as a staircase. Narrower, every cell
    // the pixel covers counts and the loudest is shown, so a click one column wide or a partial one row high is never
    // averaged away.
    struct WaterfallAxis { int first[2]; int last[2]; float weight[2]; int ranges; };

    WaterfallAxis waterfallAxis(float p, float footprint, float softness) {
        WaterfallAxis axis;
        if (footprint <= 1.0) {
            float k = floor(p);
            float ease = 0.5 * max(max(footprint, softness), 1e-6);
            float upper = smoothstep(0.5 - ease, 0.5 + ease, p - k);
            axis.first[0] = axis.last[0] = int(k);
            axis.first[1] = axis.last[1] = int(k) + 1;
            axis.weight[0] = 1.0 - upper;
            axis.weight[1] = upper;
            axis.ranges = 2;
        } else {
            axis.first[0] = int(floor(p - 0.5 * footprint + 0.5));
            axis.last[0] = int(ceil(p + 0.5 * footprint + 0.5)) - 1;
            axis.weight[0] = 1.0;
            axis.first[1] = axis.last[1] = 0;
            axis.weight[1] = 0.0;
            axis.ranges = 1;
        }
        return axis;
    }

    // The loudest tilted level in a block of cells, `age` columns before the newest and `row` up from 20 Hz, read at
    // every cell intersecting the pixel footprint.
    float waterfallBlock(texture2d<float, access::read> history, constant WaterfallState &state,
                         int firstAge, int lastAge, int firstRow, int lastRow) {
        // Clip the footprint once, then visit every covered cell. Sparse taps can miss an isolated
        // partial or transient when a small view fits more than six rows/columns in a pixel.
        firstAge = clamp(firstAge, 0, int(state.capacity) - 1);
        lastAge = clamp(lastAge, 0, int(state.capacity) - 1);
        firstRow = clamp(firstRow, 0, waterfallRows - 1);
        lastRow = clamp(lastRow, 0, waterfallRows - 1);
        float loudest = -1000.0;
        for (int age = firstAge; age <= lastAge; age++) {
            for (int row = firstRow; row <= lastRow; row++) {
                float level = waterfallTexel(history, state.capacity, int(state.head) - 1 - age, row);
                // The display slope, pivoting at 1 kHz: octaves from the pivot at this row's centre.
                float octave = state.floorOctave + (float(row) + 0.5) / float(waterfallRows) * state.octaves;
                loudest = max(loudest, level + state.tilt * octave);
            }
        }
        return loudest;
    }

    // local: pixels from the quad centre; shape.xy: half size; shape.zw: uv (u = 1 at "now").
    fragment float4 waterfallFragment(Raster in [[stage_in]],
                                      texture2d<float, access::read> history [[texture(0)]],
                                      constant WaterfallState &state [[buffer(0)]],
                                      constant float4 *ramp [[buffer(1)]]) {
        float2 uv = in.shape.zw;
        float row = (1.0 - uv.y) * float(waterfallRows) - 0.5;
        float age = (1.0 - uv.x) * state.span - state.phase;
        WaterfallAxis columns = waterfallAxis(age, fwidth(age), \(SpectrogramTone.columnSoftness));
        WaterfallAxis rows = waterfallAxis(row, fwidth(row), \(SpectrogramTone.rowSoftness));
        // Blended as tones, so an edge pixel is part way between the two colours on screen.
        float tone = 0.0;
        for (int i = 0; i < columns.ranges; i++) {
            for (int j = 0; j < rows.ranges; j++) {
                float weight = columns.weight[i] * rows.weight[j];
                if (weight <= 0.0) { continue; }
                float level = waterfallBlock(history, state, columns.first[i], columns.last[i], rows.first[j], rows.last[j]);
                tone += weight * waterfallTone(level, state);
            }
        }
        // A given level has the same colour at every age; only the selected range and tilt affect it.
        float mask = saturate(0.5 - roundedBox(in.local, in.shape.xy, 7.0));
        return float4(rampMap(tone, ramp), mask);
    }

    // Straight-alpha "over" so the scope can layer screen, fill, bloom and edge in one pass.
    float4 over(float4 dst, float3 rgb, float a) {
        float outA = a + dst.a * (1.0 - a);
        float3 outRGB = outA > 0.0 ? (rgb * a + dst.rgb * dst.a * (1.0 - a)) / outA : float3(0.0);
        return float4(outRGB, outA);
    }

    // Scope history as a min/max pyramid (MinMaxPyramid): row k of the texture holds level k, where each
    // texel is the extrema of 4^k envelope columns, ring-indexed by absolute column >> 2k.
    // `newest` is the newest column's absolute index; `phase` is how many columns the right edge trails it
    // (smooth 60 Hz scroll between 30 Hz bursts); `span` is the number of columns across the quad.
    struct ScopeState { uint newest; uint capacity; float phase; float span; };
    struct ScopeSample { float4 envelope; float4 peak; };

    float4 mergeExtrema(float4 a, float4 b) { return float4(min(a.x, b.x), max(a.y, b.y), min(a.z, b.z), max(a.w, b.w)); }

    // floor(log4(columns per pixel)), clamped; mirrors MinMaxPyramid.level(columnsPerPixel:).
    uint scopeLevel(float columnsPerPixel) {
        return columnsPerPixel > 1.0 ? min(\(MinMaxPyramid.levels - 1)u, uint(log2(columnsPerPixel) * 0.5)) : 0u;
    }

    // Level of detail follows the pixel footprint, like hardware mip selection: a pixel covering many
    // columns reads a few pre-aggregated buckets instead of every column, and never drops a peak.
    // Row of the pyramid texture holding `level` of channel pair `pair`: level-major, like MinMaxPyramid.
    uint scopeRow(uint level, uint pair) { return level * \(Role.count / 2)u + pair; }

    ScopeSample scopeEnvelope(texture2d<float, access::read> pyramid, constant ScopeState &state, float age, float footprint, uint pair) {
        // Stay clear of the oldest coarse buckets, which the ring is already overwriting.
        float maxAge = float(state.capacity - \(MinMaxPyramid.coarsestSpan + 2)u);
        ScopeSample sample;
        if (footprint <= 1.0) {
            // Magnified: interpolate neighbouring columns so the sub-column scroll stays smooth.
            float a = clamp(age, 0.0, maxAge);
            uint a0 = uint(a);
            uint mask = state.capacity - 1u;
            float4 n0 = pyramid.read(uint2((state.newest - a0) & mask, scopeRow(0, pair)));
            float4 n1 = pyramid.read(uint2((state.newest - a0 - 1u) & mask, scopeRow(0, pair)));
            sample.envelope = mix(n0, n1, fract(a));
            sample.peak = max(abs(n0), abs(n1));
            return sample;
        }
        uint level = scopeLevel(footprint);
        uint shift = 2u * level;
        float lo = clamp(age - 0.5 * footprint, 0.0, maxAge);
        float hi = clamp(age + 0.5 * footprint, 0.0, maxAge);
        uint first = (state.newest - uint(ceil(hi))) >> shift;
        uint last = (state.newest - uint(floor(lo))) >> shift;
        uint mask = (state.capacity >> shift) - 1u;
        float4 extrema = float4(INFINITY, -INFINITY, INFINITY, -INFINITY);
        uint buckets = min(last - first, 8u);
        for (uint n = 0; n <= buckets; n++) {
            extrema = mergeExtrema(extrema, pyramid.read(uint2((first + n) & mask, scopeRow(level, pair))));
        }
        sample.envelope = extrema;
        sample.peak = abs(extrema);
        return sample;
    }

    // The envelope as the eye needs it, not as the display could show it: detail is capped at about one step per
    // 1.6 points whatever the pixel density, and the extrema are tent-filtered across that window (five taps), so
    // the outline reads as a smooth shape instead of per-pixel spikes on dense or large screens. Clip flags keep
    // the loudest tap, so an over is never filtered away.
    ScopeSample scopeSoft(texture2d<float, access::read> pyramid, constant ScopeState &state, float age, float footprint,
                          float columnsPerPoint, uint pair) {
        float window = max(footprint, columnsPerPoint * 1.6);
        if (window <= 1.0) { return scopeEnvelope(pyramid, state, age, footprint, pair); }
        const float offsets[5] = { -0.5, -0.25, 0.0, 0.25, 0.5 };
        const float weights[5] = { 1.0 / 9.0, 2.0 / 9.0, 3.0 / 9.0, 2.0 / 9.0, 1.0 / 9.0 };
        ScopeSample result;
        result.envelope = float4(0.0);
        result.peak = float4(0.0);
        for (uint n = 0; n < 5u; n++) {
            ScopeSample tap = scopeEnvelope(pyramid, state, age + offsets[n] * window, 0.5 * window, pair);
            result.envelope += weights[n] * tap.envelope;
            result.peak = max(result.peak, tap.peak);
        }
        return result;
    }

    // One phosphor lane per quad. Envelopes are linear (min, max) per channel, two channels per texel;
    // |v| > 1 flags a clip. shape = (half size, u, role); color = lane ink, alpha = lane visibility.
    // Graticule: centre line, plus ±0.5 (−6 dBFS) once the lane is tall enough to read it.
    fragment float4 waveformFragment(Raster in [[stage_in]],
                                     texture2d<float, access::read> pyramid [[texture(0)]],
                                     constant ScopeState &state [[buffer(0)]]) {
        float2 halfSize = in.shape.xy;
        float u = in.shape.z;
        uint role = uint(in.shape.w + 0.5);
        float2 p = in.local;
        float laneHalf = max(0.5, halfSize.y);
        float mask = saturate(0.5 - roundedBox(p, halfSize, min(4.0, laneHalf)));
        float age = (1.0 - u) * state.span + state.phase;
        ScopeSample sample = scopeSoft(pyramid, state, age, abs(dfdx(age)), state.span / max(1.0, 2.0 * halfSize.x), role >> 1);
        bool odd = (role & 1u) != 0u;
        float2 band = odd ? sample.envelope.zw : sample.envelope.xy;
        float2 extreme = odd ? sample.peak.zw : sample.peak.xy;
        bool clip = max(extreme.x, extreme.y) > 1.001;
        float y = -p.y;
        float lo = clamp(band.x, -1.0, 1.0) * laneHalf - 0.5;
        float hi = clamp(band.y, -1.0, 1.0) * laneHalf + 0.5;

        // Graticule in the interface ink. The trace edge leans toward the same ink (cream on dark, slate on
        // light), so it always stands out from its own fill; on light a denser body keeps the lane's hue.
        const float3 grid = \(Theme.inkRGB.metal);
        const float body = \(Theme.dark ? "0.50" : "0.64");
        const float edgeInk = \(Theme.dark ? "0.30" : "0.14");
        const float fadeFloor = \(Theme.dark ? "0.40" : "0.52");
        float3 ink = clip ? \(Theme.emberRGB.metal) : in.color.rgb;
        // Older columns fade like phosphor persistence; the newest sit at full strength.
        float persistence = mix(fadeFloor, 1.0, pow(u, 1.3));
        float4 color = float4(grid, 0.025);
        color = over(color, grid, 0.10 * saturate(0.75 - abs(y)));
        color = over(color, grid, 0.05 * saturate(0.75 - abs(abs(y) - laneHalf * 0.5)) * saturate(laneHalf / 10.0 - 1.0));
        float coverage = saturate(min(y - lo, hi - y) + 0.5);
        float outside = max(max(lo - y, y - hi), 0.0);
        float edge = min(abs(y - lo), abs(y - hi));
        float depth = saturate(abs(y) / laneHalf);
        // Body fill, a one-pixel antialiasing skirt, then a crisp trace edge. No bloom: the edge carries it.
        color = over(color, ink, coverage * (body + 0.30 * depth) * persistence);
        color = over(color, ink, 0.16 * exp(-outside / 1.2) * (1.0 - coverage) * persistence);
        color = over(color, mix(ink, grid, edgeInk), saturate(1.0 - 0.8 * edge) * 0.8 * persistence);
        return float4(color.rgb, color.a * mask * in.color.a);
    }
    """ }
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

    init(reserving capacity: Int = 8192) {
        underlay.reserveCapacity(6 * Role.count)
        shapes.reserveCapacity(capacity)
    }

    mutating func reset() {
        underlay.removeAll(keepingCapacity: true)
        shapes.removeAll(keepingCapacity: true)
    }

    /// Scales the opacity of every shape added since `start` (a `shapes.count` taken before drawing them).
    mutating func fade(from start: Int, by amount: Float) {
        guard amount < 1 else { return }
        for index in start..<shapes.count { shapes[index].color.w *= amount }
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

    /// One-point hairline just inside a rounded rect: the "ghost" of a slot with nothing in it.
    mutating func roundedOutline(_ rect: CGRect, radius: CGFloat, _ color: SIMD4<Float>) {
        let shape = SIMD4<Float>(6, Float(rect.width / 2), Float(rect.height / 2), Float(min(radius, rect.width / 2, rect.height / 2)))
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

    /// Fill from the left of `bar` out to `db`, split at the level stops so colour follows the scale.
    mutating func levelFill(_ bar: CGRect, to db: Float, alpha: Float, saturation: Float = 1, x: (Float) -> CGFloat) {
        let top = min(db, 0)
        guard top > -70 else { return }
        var lower: Float = -70
        for stop in Theme.levelStops where lower < top {
            let upper = min(stop.db, top)
            let x0 = x(lower), x1 = x(upper)
            if x1 - x0 > 0.01 {
                var leftColor = Theme.desaturate(Theme.level(lower), saturation)
                var rightColor = Theme.desaturate(Theme.level(upper), saturation)
                leftColor.w = alpha
                rightColor.w = alpha
                quad(CGRect(x: x0, y: bar.minY, width: x1 - x0, height: bar.height), left: leftColor, right: rightColor)
            }
            lower = upper
        }
    }
}

/// Laid out like both Metal underlay states: `WaterfallState` (all eight fields) and `ScopeState` (the first four:
/// newest, capacity, phase, span), which ignores the rest.
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
}

enum UnderlayKind { case waterfall, waveform }

extension CanvasScene {
    var usesDampedLevels: Bool { true }
    var underlayRamp: [SIMD4<Float>] { [] }
}

protocol CanvasScene: AnyObject {
    /// Whether `build` reads the damped display levels; the waterfall and the scope draw from history instead.
    var usesDampedLevels: Bool { get }
    var underlayKind: UnderlayKind { get }
    var underlayTexture: MTLTexture? { get }
    var underlayState: UnderlayState { get }
    /// The waterfall's colour map (`Theme.waterfallRamp`), bound beside the state; empty for other underlays.
    var underlayRamp: [SIMD4<Float>] { get }
    func prepare(frame: CanvasFrame)
    func build(_ builder: inout ShapeBuilder, frame: CanvasFrame, display: MeterSnapshot, size: CGSize, dt: Float)
}

/// Scenes outlive their canvas. A palette or appearance change rebuilds the meter's views, and the new canvases
/// pick up the same scenes, so the waterfall, the scope history, peak holds and clip latches carry on instead of
/// starting blank. Only the pipelines, compiled with the new colours, change.
enum SceneStore {
    private static var scenes: [CanvasKind: CanvasScene] = [:]
    private static var dampings: [CanvasKind: DampedDisplayState] = [:]

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
        case .soundstage: return SoundstageScene(part: .room)
        case .levels: return SoundstageScene(part: .levels)
        }
    }
}

final class CanvasRenderer {
    private(set) var lastVertexCount = 0
    /// Nothing has changed for two seconds, so the last frame is final.
    var settled: Bool { settleFrames >= 120 }
    private let gpu: MeterGPU
    private let scene: CanvasScene
    private let vertexCapacity: Int
    private let buffer: MTLBuffer
    // A scene's texture upload must wait until the previous GPU read of it completes.
    private let inFlight = DispatchSemaphore(value: 1)
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
    private var settleFrames = 0

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
        settleFrames = changed ? 0 : settleFrames + 1
        guard settleFrames < 120 else { return false }
        // Never block the main thread on the GPU: if the previous frame is still being drawn, skip this one.
        guard inFlight.wait(timeout: .now()) == .success else { return false }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = shared ?? gpu.queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal()
            return false
        }
        let now = CACurrentMediaTime()
        let dt = lastDrawTime == 0 ? Float(1.0 / 60) : Float(min(0.1, now - lastDrawTime))
        lastDrawTime = now
        render(frame: frame, size: size, dt: dt, encoder: encoder, buffer: buffer)
        encoder.endEncoding()
        command.addCompletedHandler { [inFlight] _ in inFlight.signal() }
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

    fileprivate func render(frame: CanvasFrame, size: CGSize, dt: Float, encoder: MTLRenderCommandEncoder, buffer: MTLBuffer) {
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
        var viewport = SIMD2<Float>(Float(size.width), Float(size.height))
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        if underlayCount > 0, let texture = scene.underlayTexture {
            var state = scene.underlayState
            encoder.setRenderPipelineState(gpu.pipeline(scene.underlayKind))
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentBytes(&state, length: MemoryLayout<UnderlayState>.stride, index: 0)
            let ramp = scene.underlayRamp
            if !ramp.isEmpty { encoder.setFragmentBytes(ramp, length: ramp.count * MemoryLayout<SIMD4<Float>>.stride, index: 1) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: underlayCount)
        }
        if shapeCount > 0 {
            encoder.setRenderPipelineState(gpu.shapes)
            encoder.drawPrimitives(type: .triangle, vertexStart: underlayCount, vertexCount: shapeCount)
        }
    }

    /// Offscreen check of both production scenes with the synthetic demo programme.
    static func writePreview(to destination: URL) throws {
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
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw MetalError.allocation }
        var frame = CanvasFrame(running: true)
        frame.layout = Diagnostics.previewLayout
        frame.options = DisplayOptions.stored
        // Spatial part of the demo cycle, so the preview shows every lane and channel of the layout; or the columns
        // of an audio file, through the real analysis.
        let audio = try Diagnostics.previewAudio.map { try PreviewAudio.snapshots($0) }
        let steps = audio?.snapshots.count ?? SpectrogramHistory.capacity
        frame.spatial = audio == nil && !Diagnostics.previewStereo
        if let audio { frame.sampleRate = audio.sampleRate }
        // Fill the waterfall history, then settle holds and damping on the final frame.
        for step in 0..<steps {
            frame.snapshot = audio?.snapshots[step] ?? DemoSignal.snapshot(at: Double(step % 400) / DemoSignal.updateRate, sequence: step)
            spectrum.scene.prepare(frame: frame)
            spectrogram.scene.prepare(frame: frame)
            waveform.scene.prepare(frame: frame)
            soundstage.scene.prepare(frame: frame)
            levels.scene.prepare(frame: frame)
        }
        frame.snapshot.channelPeaks[1] = 1.02
        for _ in 0..<40 {
            _ = spectrum.damping.step(target: frame.snapshot, deltaTime: 1.0 / 60)
            _ = soundstage.damping.step(target: frame.snapshot, deltaTime: 1.0 / 60)
            _ = levels.damping.step(target: frame.snapshot, deltaTime: 1.0 / 60)
        }
        func viewport(x: Double, y: Double, size: CGSize) {
            encoder.setViewport(MTLViewport(originX: x * Double(scale), originY: y * Double(scale),
                                            width: size.width * Double(scale), height: size.height * Double(scale), znear: 0, zfar: 1))
        }
        viewport(x: 0, y: 0, size: spectrumSize)
        spectrum.render(frame: frame, size: spectrumSize, dt: 1.0 / 60, encoder: encoder, buffer: spectrum.buffer)
        spectrogram.render(frame: frame, size: spectrogramSize, dt: 1.0 / 60, encoder: encoder, buffer: spectrogram.buffer)
        // `--preview-image`: the context menu's exported image of the same waterfall.
        if let url = Diagnostics.previewImage, let scene = spectrogram.scene as? SpectrogramScene,
           let image = SpectrogramImage.make(history: scene.history, columns: Int(scene.span), sampleRate: frame.sampleRate,
                                             options: frame.options, caption: SpectrogramImage.caption(source: "L+R", sampleRate: frame.sampleRate, options: frame.options)),
           let output = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(output, image, nil)
            CGImageDestinationFinalize(output)
        }
        viewport(x: 0, y: spectrumSize.height + gap, size: waveSize)
        waveform.render(frame: frame, size: waveSize, dt: 1.0 / 60, encoder: encoder, buffer: waveform.buffer)
        viewport(x: spectrumSize.width + gap, y: 0, size: stageSize)
        soundstage.render(frame: frame, size: stageSize, dt: 1.0 / 60, encoder: encoder, buffer: soundstage.buffer)
        viewport(x: spectrumSize.width + gap, y: stageSize.height + gap, size: levelsSize)
        levels.render(frame: frame, size: levelsSize, dt: 1.0 / 60, encoder: encoder, buffer: levels.buffer)
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

    func build(_ b: inout ShapeBuilder, frame: CanvasFrame, display: MeterSnapshot, size: CGSize, dt: Float) {
        let layout = SpectrogramLayout(size: size, strip: frame.spectrumStrip, spectrumLeft: frame.options.spectrumSide == .left)
        let strip = layout.spectrum
        let ink = Theme.inkRGB
        b.roundedRect(strip, radius: 3, ink.simd(0.025))
        for db in SpectrogramLayout.grid {
            let x = (layout.x(decibels: db) * 2).rounded() / 2
            b.rect(CGRect(x: max(strip.minX, min(strip.maxX - 0.5, x)), y: strip.minY, width: 0.5, height: strip.height), ink.simd(db == 0 ? 0.10 : 0.06))
            // A fainter line halfway to the next labelled level, so a level reads to 12 dB at a glance.
            let minor = (layout.x(decibels: db - 12) * 2).rounded() / 2
            if db - 12 > MeterScale.spectrumFloor {
                b.rect(CGRect(x: minor, y: strip.minY, width: 0.5, height: strip.height), ink.simd(0.03))
            }
        }
        // A line under each frequency label, stronger at 100 Hz, 1 kHz and 10 kHz.
        for tick in SpectrogramLayout.frequencyTicks(layout, sampleRate: frame.sampleRate) {
            let y = (layout.y(frequency: tick.0, sampleRate: frame.sampleRate) * 2).rounded() / 2
            guard y > strip.minY + 1, y < strip.maxY - 1 else { continue }
            let decade = [100.0, 1_000, 10_000].contains(tick.0)
            b.rect(CGRect(x: strip.minX, y: y, width: strip.width, height: 0.5), ink.simd(decade ? 0.12 : 0.06))
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
        let kernel = frame.options.spectrumSmoothing.kernel(pointsPerOctave: Double(count) / log2(upper / 20))
        let live = SpectrumSmoothing.apply(kernel, to: shown)
        // The display slope at each point's centre (`SpectrumTilt`); zero when flat.
        let tilt = (0..<count).map { frame.options.tilt.offset(frequency: 20 * pow(upper / 20, (Double($0) + 0.5) / Double(count))) }
        let step = strip.height / CGFloat(count)
        func y(_ index: Int) -> CGFloat { strip.maxY - (CGFloat(index) + 0.5) * step }
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
            b.triangle(p, q, qb, tint.simd(0.24), tint.simd(0.24), tint.simd(0.03))
            b.triangle(p, qb, pb, tint.simd(0.24), tint.simd(0.03), tint.simd(0.03))
        }
        // The waterfall's octave lines at every C continue faintly across the spectrum.
        for octave in 0...9 {
            let y = (layout.y(midi: Double(12 * (octave + 1)), sampleRate: frame.sampleRate) * 2).rounded() / 2
            guard y > strip.minY + 1, y < strip.maxY - 1 else { continue }
            b.rect(CGRect(x: strip.minX, y: y, width: strip.width, height: 0.5), ink.simd(octave == 4 ? 0.10 : 0.045))
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
                b.line(p, q, width: 1, ink.simd(0.30))
            }
        }
        // The long-term average, in the second accent: a calm solid line, so it reads apart from the live curve
        // in any palette without dashes breaking up its shape.
        if frame.options.averageSpectrum, let average {
            let points = line(SpectrumSmoothing.apply(kernel, to: average))
            for (p, q) in zip(points, points.dropFirst()) where !(onFloor(p) && onFloor(q)) {
                b.line(p, q, width: 1.25, Theme.sandRGB.simd(0.85))
            }
        }
        for (p, q) in zip(curve, curve.dropFirst()) where !(onFloor(p) && onFloor(q)) {
            b.line(p, q, width: 1.5, Theme.sageRGB.simd())
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
    private var lastUpload: CFTimeInterval = 0
    private(set) var phase: Float = 0
    /// Columns the waterfall spans at its current width (`SpectrogramLayout.seconds`).
    private(set) var span = SpectrogramLayout.maxSeconds * SpectrogramLayout.analysisRate
    private var options = DisplayOptions()
    private var sampleRate = 48_000.0
    /// The colour map the shader reads, rebuilt when the map, the palette or the appearance changes.
    private(set) var underlayRamp: [SIMD4<Float>] = []
    private var rampKey: (SpectrogramColors, Theme.Palette, Bool)?

    var usesDampedLevels: Bool { false }
    var underlayKind: UnderlayKind { .waterfall }
    var underlayTexture: MTLTexture? { texture }
    var underlayState: UnderlayState {
        let upper = MeterScale.upperFrequency(sampleRate: sampleRate)
        return UnderlayState(head: UInt32(history.head), rows: UInt32(SpectrogramHistory.capacity), phase: phase,
                             span: Float(span), floor: options.spectrogramRange.floor,
                             range: options.spectrogramRange.ceiling - options.spectrogramRange.floor,
                             tilt: options.tilt.decibelsPerOctave, floorOctave: Float(log2(20 / SpectrumTilt.pivot)),
                             octaves: Float(log2(upper / 20)))
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
        lastUpload = 0
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
            lastUpload = CACurrentMediaTime()
        }
        // Held while paused; otherwise the scroll advances within the current column interval.
        if frame.running && lastUpload > 0 {
            phase = Float(min(1, (CACurrentMediaTime() - lastUpload) * SpectrogramLayout.analysisRate))
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
                                       span: frame.options.spectrogramSpan.seconds)
        let plot = layout.plot
        b.underlayQuad(plot, mirrored: layout.mirrored)
        span = Double(layout.visibleColumns)
        let ink = Theme.inkRGB
        // Octave lines at every C, continuing the keyboard's C keys across the plot; middle C a little firmer.
        for octave in 0...9 {
            let y = (layout.y(midi: Double(12 * (octave + 1)), sampleRate: frame.sampleRate) * 2).rounded() / 2
            guard y > plot.minY + 1, y < plot.maxY - 1 else { continue }
            b.rect(CGRect(x: plot.minX, y: y, width: plot.width, height: 0.5), ink.simd(octave == 4 ? 0.12 : 0.06))
        }
        // A hairline each second, and a short tick at the foot of each so the time labels have something to name.
        for seconds in stride(from: 1.0, to: layout.seconds, by: 1) {
            let x = (layout.x(secondsAgo: seconds) * 2).rounded() / 2
            b.rect(CGRect(x: x, y: plot.minY, width: 0.5, height: plot.height), ink.simd(0.06))
            b.rect(CGRect(x: x, y: plot.maxY - 4, width: 0.5, height: 4), ink.simd(0.22))
        }
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
    /// Columns the right edge trails the newest column; drained at the column rate for a smooth scroll.
    private var lag: Float = 0
    /// Recent arrival size in columns: about 4 per 60 Hz DSP tick, 8 per 30 Hz demo update, more when a DAW
    /// runs the device with long buffers. Jumps up at once and relaxes slowly.
    private var burst: Float = 8
    /// The right edge trails the newest column by 1.5 arrivals: enough that the scroll never runs dry, and no
    /// more, so the waveform is as current as its delivery allows (about 30 ms behind at 60 Hz, was 50 ms).
    private var cushion: Float { min(40, max(6, burst * 1.5)) }
    private var presence = PresenceSpring()
    private var mono = PresenceSpring()

    var usesDampedLevels: Bool { false }
    var underlayKind: UnderlayKind { .waveform }
    var underlayTexture: MTLTexture? { trace }
    var underlayState: UnderlayState {
        UnderlayState(head: pyramid.newestIndex, rows: UInt32(Self.traceCapacity), phase: lag, span: visibleColumns)
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
        lag = 0
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
        lag += Float(count)
        if lastSerial >= 0 { burst = max(Float(count), burst + (Float(count) - burst) * 0.05) }
        lastSerial = serial
    }

    /// Lanes are rebuilt from the current size and presence every frame, and the shader picks its pyramid
    /// level from the pixel footprint, so any panel size renders at native resolution without resampling.
    func build(_ b: inout ShapeBuilder, frame: CanvasFrame, display: MeterSnapshot, size: CGSize, dt: Float) {
        if frame.running {
            // Drain at the column rate, a little faster when behind, so bursty arrivals scroll evenly at 60 Hz.
            let rate = max(0, Float(WaveformEnvelope.columnRate) + (lag - cushion) * 20)
            lag = max(0, lag - dt * rate)
            if lag > 80 { lag = cushion }
        }
        visibleColumns = Float(Double(frame.options.waveSeconds) * WaveformEnvelope.columnRate)
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
    init(part: SoundstageLayout.Part) { self.part = part }

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
    /// A dot's opacity halves about every 35 ms, so a sample glows briefly and trails off like phosphor.
    private static let cloudDecay: CFTimeInterval = 0.05
    private static let cloudLife: CFTimeInterval = 0.11
    /// Outline and Filled styles: per published band group (`StereoBands.groups`), how far its samples reach at
    /// each of `envelopeBins` directions across the half disc, as a scope fraction. Rises at once, falls over
    /// about a quarter second, so the shape holds still enough to read.
    private static let envelopeBins = 48
    private var envelopes = [[Float]](repeating: [Float](repeating: 0, count: 48), count: StereoBands.groups.count)
    private var envelopeStyle = StageStyle.dots

    // Shapes only: no underlay quad is ever added, so the texture is never bound.
    var underlayKind: UnderlayKind { .waveform }
    var underlayTexture: MTLTexture? { nil }
    var underlayState: UnderlayState { UnderlayState() }

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
                holdTimers[role] = 1.5
            } else if holdTimers[role] > 0 {
                holdTimers[role] -= signalDt
            } else {
                holds[role] = max(-120, holds[role] - 20 * signalDt)
            }
        }
        switch part {
        case .room:
            // Stereo shows the stereometer instead of the room; the two cross-fade with the mode.
            let stereo = stereoImageWeight
            if stereo < 0.999 {
                let start = b.shapes.count
                drawRoom(&b, layout: layout, frame: frame)
                b.fade(from: start, by: (1 - stereo) * (1 - stereo))
            }
            updateCloud(frame)
            if stereo > 0.001 {
                let start = b.shapes.count
                drawStereometer(&b, layout: layout, display: display, running: frame.shown, style: frame.stageStyle, dt: signalDt,
                                layers: bands.layers)
                b.fade(from: start, by: stereo * stereo)
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

    /// What the room's static layers were built for; they are rebuilt only when one of these changes.
    private struct RoomKey: Equatable {
        let size: CGSize
        let layout: SpeakerLayout
        let ink: Theme.RGB
        let heather: Theme.RGB
        let dark: Bool
    }
    private var roomKey: RoomKey?
    /// The floor (disc, distance rings, azimuth ticks, cross and axis) and the upper layer (its rings and the
    /// posts to the floor), as finished vertices: each frame copies them in instead of rebuilding them.
    private var floorLayer: [ShapeVertex] = []
    private var upperLayer: [ShapeVertex] = []

    /// A room circle: an ellipse on screen, as a polyline.
    private static func ellipse(_ b: inout ShapeBuilder, layout: SoundstageLayout, radius: CGFloat, y: CGFloat = 0,
                                width: CGFloat, _ color: SIMD4<Float>, dashed: Bool = false) {
        guard color.w > 0.002 else { return }
        let steps = 72
        var previous = layout.point(SoundstageLayout.Point3(x: 0, y: y, z: radius))
        for step in 1...steps {
            let radians = CGFloat(step) * 2 * .pi / CGFloat(steps)
            let point = layout.point(SoundstageLayout.Point3(x: sin(radians) * radius, y: y, z: cos(radians) * radius))
            if !dashed || step % 2 == 0 { b.line(previous, point, width: width, color) }
            previous = point
        }
    }

    private func buildRoomLayers(layout: SoundstageLayout, key: RoomKey) {
        typealias P3 = SoundstageLayout.Point3
        let ink = key.ink, dark = key.dark
        var b = ShapeBuilder(reserving: 4096)
        func plane(_ azimuth: Double, _ radius: CGFloat) -> P3 {
            let radians = azimuth * .pi / 180
            return P3(x: CGFloat(sin(radians)) * radius, y: 0, z: CGFloat(cos(radians)) * radius)
        }
        let o = layout.point(P3(x: 0, y: 0, z: 0))
        // Floor: a toned disc, brighter toward the listener, then distance rings every quarter of the bed radius.
        let rim = (0...72).map { layout.point(plane(Double($0) * 5, 1)) }
        let inner = dark ? SIMD4<Float>(0, 0, 0, 0.30) : ink.simd(0.05)
        let outer = dark ? SIMD4<Float>(0, 0, 0, 0.12) : ink.simd(0.02)
        for (q, r) in zip(rim, rim.dropFirst()) { b.triangle(o, q, r, inner, outer, outer) }
        for (index, radius) in [CGFloat(0.25), 0.5, 0.75].enumerated() {
            Self.ellipse(&b, layout: layout, radius: radius, width: 0.75, ink.simd((dark ? 0.07 : 0.06) + 0.015 * Float(index)))
        }
        Self.ellipse(&b, layout: layout, radius: 1, width: 1.1, ink.simd(dark ? 0.26 : 0.24))
        for step in 0..<24 {
            let major = step % 6 == 0, mid = step % 2 == 0
            let reach: CGFloat = major ? 1.09 : (mid ? 1.05 : 1.03)
            b.line(layout.point(plane(Double(step) * 15, 1)), layout.point(plane(Double(step) * 15, reach)),
                   width: major ? 1.1 : 0.75, ink.simd(major ? 0.34 : (mid ? 0.20 : 0.12)))
        }
        b.line(layout.point(plane(180, 1)), layout.point(plane(0, 1)), width: 0.75, ink.simd(0.10))
        b.line(layout.point(plane(-90, 1)), layout.point(plane(90, 1)), width: 0.75, ink.simd(0.10))
        b.line(o, layout.point(P3(x: 0, y: SoundstageLayout.axisTop, z: 0)), width: 0.75, ink.simd(0.14))
        floorLayer = b.shapes

        // Upper layer: its dashed ring, its footprint on the floor, and a post from each upper speaker down to it.
        b.reset()
        if !heights.isEmpty {
            let heather = key.heather
            Self.ellipse(&b, layout: layout, radius: SoundstageLayout.heightReach, y: SoundstageLayout.heightLift,
                         width: 0.9, heather.simd(0.34), dashed: true)
            Self.ellipse(&b, layout: layout, radius: SoundstageLayout.heightReach, width: 0.75, heather.simd(0.10), dashed: true)
            for speaker in heights {
                let top = layout.position(speaker)
                let foot = layout.point(P3(x: top.x, y: 0, z: top.z))
                b.line(foot, layout.point(top), width: 0.75, heather.simd(0.18))
                b.disk(foot, radius: 1.5, heather.simd(0.3))
            }
        }
        upperLayer = b.shapes
    }

    /// The room in Immersive, drawn flat: the floor is the ear-level plane seen at a slant, with distance rings,
    /// azimuth ticks and a cross through the listener, and one energy field for the whole programme (RMS per
    /// speaker along its direction, bed and upper layer alike) spread on it. The upper layer floats above on its
    /// own dashed ring, with a post from each upper speaker down to the floor, so ceiling energy reads as height. Every speaker is a
    /// round marker lit by its level and wrapped in a level ring (RMS arc, peak dot, ember halo once clipped). The
    /// mix's image hangs where its energy centres, a stem down to its footprint on the floor, and a ring there as
    /// wide as the image is diffuse; each frequency band is an orb in the band colours. Static layers are cached;
    /// markers are drawn top to bottom so near sits over far, and all of it follows the presence springs, so
    /// Stereo and Mono morph instead of cutting.
    private func drawRoom(_ b: inout ShapeBuilder, layout: SoundstageLayout, frame: CanvasFrame) {
        typealias P3 = SoundstageLayout.Point3
        let p = presence
        let ink = Theme.inkRGB
        let sage = Theme.sageRGB
        let origin = P3(x: 0, y: 0, z: 0)
        func plane(_ azimuth: Double, _ radius: CGFloat, y: CGFloat = 0) -> P3 {
            let radians = azimuth * .pi / 180
            return P3(x: CGFloat(sin(radians)) * radius, y: y, z: CGFloat(cos(radians)) * radius)
        }
        let key = RoomKey(size: layout.stageWell.size, layout: frame.layout, ink: ink, heather: Theme.heatherRGB, dark: Theme.dark)
        if key != roomKey {
            roomKey = key
            buildRoomLayers(layout: layout, key: key)
        }
        let o = layout.point(origin)
        b.shapes.append(contentsOf: floorLayer)

        // Stereo stage: the ±30° arc of the floor ring between L and R lights up toward Stereo and closes to a
        // point as L and R merge into the front-centre mono source.
        let stage = 1 - p
        let spread = 30 * Double(1 - mono)
        if stage > 0.005 {
            var previous = layout.point(plane(-spread, 1))
            for step in 1...16 {
                let point = layout.point(plane(-spread + 2 * spread * Double(step) / 16, 1))
                b.line(previous, point, width: 1.5, sage.simd(0.65 * stage))
                previous = point
            }
        }
        if p > 0.002 && !upperLayer.isEmpty {
            let start = b.shapes.count
            b.shapes.append(contentsOf: upperLayer)
            b.fade(from: start, by: p)
        }

        // LFE: a pool of light on the floor under the listener, as wide as it is loud; it has no direction.
        if frame.layout.hasLFE && p > 0.002 {
            let active = frame.activeRoles[Role.lfe]
            let lfe = active ? CGFloat(MeterScale.position(decibels: rmsDb[Role.lfe])) : 0
            let clay = Theme.clayRGB
            let radius = 0.08 + 0.34 * lfe
            if lfe > 0.001 {
                let pool = (0...36).map { layout.point(plane(Double($0) * 10, radius)) }
                for (q, r) in zip(pool, pool.dropFirst()) {
                    b.triangle(o, q, r, clay.simd(Float(0.10 + 0.30 * lfe) * p), clay.simd(0.03 * p), clay.simd(0.03 * p))
                }
            }
            Self.ellipse(&b, layout: layout, radius: radius, width: 1, clay.simd((active ? 0.5 : 0.18) * p))
        }

        // One field for the whole programme, bed and upper layer alike. In each direction it reaches as far as
        // the level of the energy arriving from around it (each speaker counting less the further it is, about
        // ±35°), and rises toward the upper layer with the share of that energy the upper layer carries: a bed-only
        // mix lies on the floor, tops on one side bend that side up, a ceiling-heavy mix floats as a canopy. Its
        // colour follows the lift, the bed's at the floor to the upper layer's at the top; a faint shadow on the
        // floor keeps its direction and width readable, and the gap to it shows the height.
        let directional = bed + (p > 0.005 ? heights : [])
        var sources: [(azimuth: CGFloat, energy: CGFloat, upper: Bool)] = []
        for speaker in directional where frame.activeRoles[speaker.role] {
            let v = visibility(speaker.role)
            guard v > 0.002 else { continue }
            sources.append((CGFloat((layout.azimuth(speaker) ?? 0) * .pi / 180),
                            CGFloat(pow(10, rmsDb[speaker.role] / 10) * v), speaker.group == .height))
        }
        do {
            let steps = 64
            let heather = Theme.heatherRGB
            var room: [P3] = [], shares: [CGFloat] = []
            for step in 0..<steps {
                let theta = CGFloat(step) * 2 * .pi / CGFloat(steps)
                var total: CGFloat = 0, upper: CGFloat = 0
                for source in sources {
                    var delta = abs(theta - source.azimuth).truncatingRemainder(dividingBy: 2 * .pi)
                    if delta > .pi { delta = 2 * .pi - delta }
                    let energy = source.energy * exp(-(delta * delta) / 0.38)
                    total += energy
                    if source.upper { upper += energy }
                }
                let level = CGFloat(MeterScale.position(decibels: Float(10 * log10(max(1e-12, total)))))
                room.append(P3(x: sin(theta), y: 0, z: cos(theta)) * (0.08 + 0.92 * level))
                shares.append(total > 1e-12 ? upper / total : 0)
            }
            // The lift is eased round the outline (about ±30°), so the field bends up smoothly; rising, it draws in
            // toward the upper ring, as the upper layer sits inside the bed ring.
            let window = 5
            shares = (0..<steps).map { index in
                (-window...window).reduce(CGFloat(0)) { $0 + shares[(index + $1 + steps) % steps] } / CGFloat(2 * window + 1) * CGFloat(p)
            }
            for index in 0..<steps {
                let share = shares[index]
                let pull = 1 - share * (1 - SoundstageLayout.heightReach)
                room[index] = P3(x: room[index].x * pull, y: share * SoundstageLayout.heightLift, z: room[index].z * pull)
            }
            // Half the energy from above already reads fully as the upper layer's colour.
            func color(_ share: CGFloat) -> Theme.RGB {
                let t = Float(min(1, share * 2))
                return Theme.RGB(r: sage.r + (heather.r - sage.r) * t, g: sage.g + (heather.g - sage.g) * t,
                                 b: sage.b + (heather.b - sage.b) * t)
            }
            // The footprint on the floor: a faint fill and edge, where the whole field lies in a bed-only mix.
            let origin2 = layout.point(origin)
            let footprint = room.map { layout.point(P3(x: $0.x, y: 0, z: $0.z)) }
            let outline = room.map { layout.point($0) }
            for index in 0..<steps {
                let next = (index + 1) % steps
                b.triangle(origin2, footprint[index], footprint[next], sage.simd(0.14), sage.simd(0.05), sage.simd(0.05))
            }
            // The wall from the footprint up to the rim, brightest at the rim: it shows how high each direction has
            // risen and keeps a lifted field legible where its rim crosses itself on screen.
            for index in 0..<steps {
                let next = (index + 1) % steps
                guard shares[index] + shares[next] > 0.01 else { continue }
                let top0 = color(shares[index]).simd(0.20), top1 = color(shares[next]).simd(0.20)
                let foot = sage.simd(0.02)
                b.triangle(footprint[index], footprint[next], outline[next], foot, foot, top1)
                b.triangle(footprint[index], outline[next], outline[index], foot, top1, top0)
            }
            for index in 0..<steps {
                let next = (index + 1) % steps
                let risen = shares[index] + shares[next] > 0.01
                b.line(footprint[index], footprint[next], width: 1, sage.simd(risen ? 0.35 : 0))
                b.line(outline[index], outline[next], width: 1.25, color((shares[index] + shares[next]) / 2).simd(0.85))
            }
            // Posts every 45°, so the lift reads as height.
            for index in stride(from: 0, to: steps, by: steps / 8) where shares[index] > 0.02 {
                b.line(footprint[index], outline[index], width: 0.75, color(shares[index]).simd(0.35))
            }
        }

        // Sight lines from the listener, brighter with level.
        for speaker in layout.speakers where speaker.group != .lfe {
            let v = visibility(speaker.role)
            guard v > 0.002 else { continue }
            let level = frame.activeRoles[speaker.role] ? MeterScale.position(decibels: rmsDb[speaker.role]) : 0
            b.line(o, layout.point(layout.position(speaker)), width: 0.75, ink.simd((0.05 + 0.20 * level) * v))
        }

        // The image: the energy centroid of every directional speaker. Its distance from the listener says how
        // focused the mix is, its height how much the upper layer carries.
        var image = origin
        var total: CGFloat = 0
        for speaker in layout.speakers where speaker.group != .lfe && frame.activeRoles[speaker.role] {
            let energy = CGFloat(pow(10, rmsDb[speaker.role] / 10) * visibility(speaker.role))
            image = image + layout.position(speaker) * energy
            total += energy
        }
        let hasImage = total > 1e-6 && frame.shown
        if hasImage { image = image * (1 / total) }
        let imageY = layout.point(image).y

        // Markers top to bottom (far to near), the image among them where it stands.
        let markers = layout.speakers.filter { $0.group != .lfe && visibility($0.role) > 0.002 }
            .map { ($0, layout.point(layout.position($0)).y) }
            .sorted { $0.1 < $1.1 }
        var imageDrawn = false
        for (speaker, y) in markers {
            if !imageDrawn && y > imageY {
                drawImage(&b, layout: layout, frame: frame, image: hasImage ? image : nil)
                imageDrawn = true
            }
            drawMarker(&b, layout: layout, speaker: speaker, active: frame.activeRoles[speaker.role])
        }
        if !imageDrawn { drawImage(&b, layout: layout, frame: frame, image: hasImage ? image : nil) }
    }

    /// The mix's image and the band orbs (cross-fading through a band switch), with the listener.
    private func drawImage(_ b: inout ShapeBuilder, layout: SoundstageLayout, frame: CanvasFrame,
                           image: SoundstageLayout.Point3?) {
        typealias P3 = SoundstageLayout.Point3
        let ink = Theme.inkRGB
        let o = layout.point(P3(x: 0, y: 0, z: 0))
        b.disk(o, radius: 3, Theme.displayRGB.simd(0.9))
        b.disk(o, radius: 2.25, ink.simd(0.6))
        guard let image else { return }
        let footprint = P3(x: image.x, y: 0, z: image.z)
        let at = layout.project(image)
        let foot = layout.point(footprint)
        // Diffuseness: 0 when the image sits on a speaker, 1 when it surrounds the listener evenly.
        let focus = min(1, (image.x * image.x + image.z * image.z).squareRoot() + image.y * 0.6)
        let spread = 0.06 + 0.5 * (1 - focus)
        let ring = (0...48).map { step -> CGPoint in
            let radians = CGFloat(step) * 7.5 * .pi / 180
            return layout.point(P3(x: footprint.x + sin(radians) * spread, y: 0, z: footprint.z + cos(radians) * spread))
        }
        for (q, r) in zip(ring, ring.dropFirst()) {
            b.triangle(foot, q, r, ink.simd(0.10), ink.simd(0.02), ink.simd(0.02))
            b.line(q, r, width: 1, ink.simd(0.32))
        }
        b.line(o, foot, width: 1, ink.simd(0.30))
        if image.y > 0.005 { b.line(foot, at.point, width: 1, ink.simd(0.45)) }
        for layer in bands.layers where frame.options.bandMarkers {
            let start = b.shapes.count
            drawBandImage(&b, layout: layout, frame: frame, resolution: layer.resolution)
            b.fade(from: start, by: layer.weight)
        }
        let size = at.scale
        b.glow(at.point, radius: 10 * size, ink.simd(0.22))
        b.disk(at.point, radius: 4.25 * size, Theme.displayRGB.simd(0.95))
        b.disk(at.point, radius: 3.25 * size, ink.simd())
    }

    /// A speaker marker: a disc lit in its group colour by RMS and glowing with it, wrapped in a level ring
    /// that sweeps clockwise from 12 o'clock with RMS, a dot on the ring at the peak, and an ember halo once the
    /// channel has clipped. Nearer markers are a little larger; a receding speaker shrinks and fades.
    private func drawMarker(_ b: inout ShapeBuilder, layout: SoundstageLayout, speaker: Speaker, active: Bool) {
        let v = visibility(speaker.role)
        let ink = Theme.inkRGB
        let color = Theme.groupRGB(speaker.group)
        let at = layout.position(speaker)
        let point = layout.point(at)
        let n = layout.markerRadius(at) * CGFloat(0.6 + 0.4 * v)
        let ring = n + (layout.compactRoom ? 2 : 3.5)
        guard active else {
            b.disk(point, radius: n, Theme.displayRGB.simd(0.9 * v))
            b.ring(point, radius: n, width: 1, ink.simd(0.22 * v))
            return
        }
        let rms = MeterScale.position(decibels: rmsDb[speaker.role])
        let peak = MeterScale.position(decibels: peakDb[speaker.role])
        b.glow(point, radius: ring * 1.6 + layout.stageScale * 0.12 * CGFloat(rms), color.simd((0.10 + 0.40 * rms) * v))
        b.disk(point, radius: ring + 1.5, Theme.displayRGB.simd(0.85 * v))
        b.ring(point, radius: ring, width: 2, ink.simd(0.14 * v))
        if rms > 0.004 { b.ring(point, radius: ring, width: 2, color.simd(v), sweep: rms) }
        let angle = CGFloat(peak) * 2 * .pi
        b.disk(CGPoint(x: point.x + sin(angle) * ring, y: point.y - cos(angle) * ring), radius: 1.6, ink.simd(0.85 * v))
        b.disk(point, radius: n, color.simd((0.30 + 0.70 * rms) * v))
        b.ring(point, radius: n, width: 1, ink.simd((0.20 + 0.30 * peak) * v))
        if clipped[speaker.role] { b.ring(point, radius: ring + 3, width: 1.25, Theme.emberRGB.simd(v)) }
    }

    /// 1 in Stereo, folding to 0 toward Multi Channel and toward Mono, like the correlation section.
    private var stereoImageWeight: Float { (1 - presence) * (1 - mono) }

    /// Keeps the clouds of the last `cloudLife` seconds; each fades with its age, frame by frame. Frozen, the
    /// clouds and their clock stand still, so the trail holds as it was.
    private func updateCloud(_ frame: CanvasFrame) {
        guard frame.shown else {
            clouds.removeAll()
            return
        }
        guard frame.running else { return }
        let now = CACurrentMediaTime()
        cloudClock = now
        let snapshot = frame.snapshot
        if snapshot.sequence != cloudSequence {
            cloudSequence = snapshot.sequence
            clouds.insert((snapshot.bandPoints, now), at: 0)
        }
        clouds.removeAll { now - $0.time > Self.cloudLife }
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
                                 layers: [(resolution: StereoBands.Resolution, weight: Float)]) {
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
        // Screen: the half disc set a step darker than the well (lighter paper stays paper, but toned), so the
        // coloured dots sit on a quiet field in every theme; then level arcs every 12 dB and the L, M, R lines.
        let dark = Theme.dark
        let screen = dark ? SIMD4<Float>(0, 0, 0, 0.32) : ink.simd(0.055)
        let disc = (0...36).map { layout.scopePoint(angle: -90 + 5 * Double($0), fraction: 1) }
        for (p, q) in zip(disc, disc.dropFirst()) { b.triangle(c, p, q, screen, screen, screen) }
        arc(from: -90, to: 90, fraction: 1, width: 1.25, ink.simd(dark ? 0.34 : 0.30))
        for db: Float in [-12, -24, -36, -48] {
            arc(from: -90, to: 90, fraction: SoundstageLayout.scopeFraction(decibels: db), width: 0.75, ink.simd(dark ? 0.12 : 0.10))
        }
        b.line(layout.scopePoint(angle: -90, fraction: 1), layout.scopePoint(angle: 90, fraction: 1), width: 1, ink.simd(0.26))
        for angle in [-45.0, 0, 45] {
            b.line(c, layout.scopePoint(angle: angle, fraction: 1), width: angle == 0 ? 1 : 0.75, ink.simd(angle == 0 ? 0.26 : 0.18))
        }
        for angle in [-67.5, -22.5, 22.5, 67.5] {
            b.line(layout.scopePoint(angle: angle, fraction: 0.94), layout.scopePoint(angle: angle, fraction: 1), width: 0.75, ink.simd(0.26))
        }

        // Rims: a faint track per band group of the chosen resolution, then its arc. During a band switch the
        // outgoing and incoming sets cross-fade.
        for (resolution, weight) in layers {
        let rimStart = b.shapes.count
        for group in 0..<resolution.count {
            let fraction = layout.rimRadius(group) / max(1, layout.scopeRadius)
            let hue = Theme.bandRGB(resolution, group)
            let band = resolution.offset + group
            arc(from: -90, to: 90, fraction: fraction, width: 1, hue.simd(dark ? 0.16 : 0.18))
            guard running, display.bandLevel[band] > -80 else { continue }
            let r = Double(max(-1, min(1, display.bandCorrelation[band])))
            let balance = Double(max(-1, min(1, display.bandBalance[band])))
            let spread = min(90, r >= 0 ? 45 * (1 - r) : 45 + 45 * -r) * (1 - pow(abs(balance), 3))
            let centre = 45 * balance
            let half = max(2, spread)
            let level = MeterScale.position(decibels: display.bandLevel[band] + 12)
            let alpha = 0.35 + 0.65 * level
            // A backing stroke in the well colour keeps each arc crisp over its neighbours in every theme.
            arc(from: max(-90, centre - half), to: min(90, centre + half), fraction: fraction, width: 5.5,
                Theme.displayRGB.simd(0.9))
            arc(from: max(-90, centre - half), to: min(90, centre + half), fraction: fraction, width: 3.5, hue.simd(alpha))
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
        b.disk(c, radius: 2, ink.simd(0.5))
    }

    /// Dots style: every sample of the recent clouds as a dot.
    private func drawCloud(_ b: inout ShapeBuilder, layout: SoundstageLayout,
                           layers: [(resolution: StereoBands.Resolution, weight: Float)]) {
        let dark = Theme.dark
        // The cloud: oldest first so the newest dots sit on top. The trail is small and dim; the newest 1/30 s is
        // larger and full strength, each dot set on a small backing in the screen colour, so the live image reads
        // as separate dots over its trail instead of a mat. Bands are interleaved point by point, so no band
        // always covers another. During a band switch the dots re-colour by cross-fading the two groupings.
        let points = StereoBands.scopePoints
        let now = cloudClock
        let backing = Theme.displayRGB
        let center = layout.scopeCenter, radius = layout.scopeRadius
        for (resolution, weight) in layers {
        let cloudStart = b.shapes.count
        let groups = resolution.groups
        let hues = (0..<resolution.count).map { Theme.bandRGB(resolution, $0) }
        for (generation, cloud) in clouds.enumerated().reversed() where cloud.points.count == StereoBands.scopeFloats {
            let newest = generation == 0
            let age = Float((now - cloud.time) / Self.cloudDecay)
            let opacity = newest ? 1 : Float(0.5 * exp(-Double(age)))
            guard opacity > 0.04 else { continue }
            for point in 0..<points {
                for (group, members) in groups.enumerated() {
                    // A group's samples are the sum of its bands' (the crossovers sum back to the programme).
                    var left: Float = 0, right: Float = 0
                    for band in members {
                        left += cloud.points[(band * points + point) * 2]
                        right += cloud.points[(band * points + point) * 2 + 1]
                    }
                    guard let offset = SoundstageLayout.scopeSample(left: left, right: right) else { continue }
                    let position = CGPoint(x: center.x + offset.x * radius, y: center.y + offset.y * radius)
                    if newest {
                        b.disk(position, radius: 2.5, backing.simd(dark ? 0.6 : 0.5))
                        b.disk(position, radius: 1.6, hues[group].simd(0.95))
                    } else {
                        b.disk(position, radius: 1.1, hues[group].simd(opacity))
                    }
                }
            }
        }
        b.fade(from: cloudStart, by: weight)
        }
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
                               layers: [(resolution: StereoBands.Resolution, weight: Float)]) {
        let bins = Self.envelopeBins
        let points = StereoBands.scopePoints
        let fall = exp(-dt / 0.25)
        let c = layout.scopeCenter
        let dark = Theme.dark
        for (resolution, weight) in layers {
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
                            guard let sample = Self.polar(left: left, right: right) else { continue }
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
            let shapes: [(group: Int, outline: [CGPoint], area: Float)] = (0..<resolution.count).compactMap { group in
                let reach = envelopes[resolution.offset + group]
                let area = reach.reduce(0) { $0 + $1 * $1 }
                guard area > 0.0005 else { return nil }
                let outline = (0...bins).map { edge -> CGPoint in
                    // Bin edges; the reach at an edge is its two bins' mean, the ends meet the centre.
                    let before = edge > 0 ? reach[edge - 1] : 0, after = edge < bins ? reach[edge] : 0
                    let fraction = edge == 0 || edge == bins ? 0 : CGFloat((before + after) / 2)
                    return layout.scopePoint(angle: -90 + 180 * Double(edge) / Double(bins), fraction: fraction)
                }
                return (group, outline, area)
            }
            let start = b.shapes.count
            if filled {
                for shape in shapes.sorted(by: { $0.area > $1.area }) {
                    let tint = Theme.bandRGB(resolution, shape.group).simd(dark ? 0.2 : 0.18)
                    for (p, q) in zip(shape.outline, shape.outline.dropFirst()) { b.triangle(c, p, q, tint, tint, tint) }
                }
            }
            // Outlines skip the closing spokes along the horizon, which only close the fill.
            for shape in shapes.sorted(by: { $0.area > $1.area }) {
                let hue = Theme.bandRGB(resolution, shape.group)
                let edge = shape.outline.dropFirst().dropLast()
                for (p, q) in zip(edge, edge.dropFirst()) { b.line(p, q, width: 3.5, Theme.displayRGB.simd(filled ? 0.55 : 0.7)) }
                for (p, q) in zip(edge, edge.dropFirst()) { b.line(p, q, width: 1.6, hue.simd(0.95)) }
            }
            b.fade(from: start, by: weight)
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

    /// A closed field fanned from `center`: brighter at the centre, fading toward the edge, with a line along it.
    private func drawField(_ b: inout ShapeBuilder, center: CGPoint, points: [CGPoint], color: Theme.RGB, fill: Float, edge: Float) {
        guard points.count >= 2 else { return }
        for (p, q) in zip(points, points.dropFirst() + [points[0]]) {
            b.triangle(center, p, q, color.simd(fill), color.simd(fill * 0.35), color.simd(fill * 0.35))
        }
        for (p, q) in zip(points, points.dropFirst() + [points[0]]) { b.line(p, q, width: 1.25, color.simd(edge)) }
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

    /// Channel meters drawn like the loudness gauge on the summary, stood on end: a slim capsule track with a
    /// hairline edge, one solid capsule fill whose colour follows the current level only (the accent, ochre while
    /// the channel peaks within 3 dB of full scale), the peak as the same colour translucent behind it, and the peak
    /// hold as a thin ink mark across the bar, like the gauge's target mark. An over never recolours the bar: above
    /// 0 dB the track is tinted ember and fills to the highest true-peak over, and a dot over the bar stays lit
    /// until the next reset.
    private func drawMeters(_ b: inout ShapeBuilder, layout: SoundstageLayout, frame: CanvasFrame) {
        guard layout.scale.height > 8 else { return }
        let ink = Theme.inkRGB
        let ember = Theme.emberRGB
        if let first = layout.columns.first(where: { $0.width > 0.5 }), let last = layout.columns.last(where: { $0.width > 0.5 }) {
            let zero = layout.y(decibels: 0).rounded()
            b.rect(CGRect(x: first.minX, y: zero - 0.25, width: last.maxX - first.minX, height: 0.5), ink.simd(0.10))
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
            // Track: the gauge's faint fill and hairline edge, tinted ember above 0 dB.
            b.roundedRect(bar, radius: radius, ink.simd((active ? 0.08 : 0.04) * v))
            b.roundedOutline(bar, radius: radius, ink.simd(0.06 * v))
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
                    b.roundedRect(CGRect(x: bar.minX - 3, y: y - 1, width: bar.width + 6, height: 2), radius: 1, ink.simd(v))
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
/// the offscreen preview. Up to the waterfall's capacity of columns from the start of the file, L and R (a mono file
/// feeds both).
enum PreviewAudio {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func snapshots(_ url: URL) throws -> (sampleRate: Double, snapshots: [MeterSnapshot]) {
        var file: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let file else { throw Failure(description: "cannot open \(url.path)") }
        defer { ExtAudioFileDispose(file) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format)
        let rate = format.mSampleRate
        var client = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                 mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard let analyzer = SpectrumAnalyzer(sampleRate: rate) else { throw Failure(description: "unsupported rate \(rate)") }
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
        return (rate, result)
    }
}
