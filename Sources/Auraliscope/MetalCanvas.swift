import AppKit
import ImageIO
import MetalKit
import SwiftUI

enum CanvasKind: String { case spectrum, spectrogram, waveform, soundstage }

/// Everything a scene needs for one frame, read on the main thread.
struct CanvasFrame {
    var snapshot = MeterSnapshot()
    var sampleRate: Double = 48_000
    var running = false
    var activeRoles = [Bool](repeating: true, count: Role.count)
    var epoch = 0
    /// Effective channel format; extended channels recede when `spatial` is false, and R too when `mono` is true.
    var spatial = true
    var mono = false
    /// The multichannel layout Spatial mode shows.
    var layout = SpeakerLayout.standard
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
}

/// A transparent MTKView that draws one scene at the display rate. All text lives in SwiftUI overlays.
struct MeterCanvas: NSViewRepresentable {
    let kind: CanvasKind
    let model: MeterModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model, kind: kind) }

    func makeNSView(context: Context) -> MTKView {
        let view = CanvasView(frame: .zero, device: nil)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.layer?.isOpaque = false
        // The drawable follows the view's size and backing scale; during a divider drag the next display
        // tick redraws at the new size from the same layout math.
        view.autoResizeDrawable = true
        if let layer = view.layer as? CAMetalLayer { layer.displaySyncEnabled = true }
        do {
            let gpu = try MeterGPU.shared.get()
            view.device = gpu.device
            context.coordinator.renderer = try CanvasRenderer(kind: kind, gpu: gpu, shared: true)
        } catch {
            let message = StatusMessage { L("Metal failed to start: %@", error.localizedDescription) }
            Task { @MainActor in model.reportRendererError(message) }
        }
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.forceRedraw = true
        (view as? CanvasView)?.wake()
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let model: MeterModel
        let kind: CanvasKind
        var renderer: CanvasRenderer?
        var forceRedraw = true
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
            // MTKView's display timer calls this on the main thread.
            MainActor.assumeIsolated {
                guard let renderer, view.bounds.width > 0, view.bounds.height > 0 else { return }
                let frame = model.canvasFrame()
                let committed = renderer.draw(in: view, frame: frame, force: forceRedraw)
                forceRedraw = false
                // Paused capture whose damped bars and holds have come to rest: stop the display timer until
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

/// MTKView that only runs its display timer while it has something to show: the window is on screen (not
/// minimised, not covered by a full-screen DAW, not on another Space) and the picture is still moving.
/// Hidden, the four canvases cost nothing; the DSP keeps measuring, so integrated loudness stays complete.
final class CanvasView: MTKView {
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
        }
        wake()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { wake() }
    }

    private var onScreen: Bool { window?.occlusionState.contains(.visible) == true }

    /// Runs the display timer again if the window is visible. `isPaused` is only written when it changes:
    /// setting it restarts MTKView's display link and asks for layout, which would otherwise feed back into
    /// SwiftUI's own layout pass.
    func wake() {
        resting = false
        let paused = !onScreen
        if isPaused != paused { isPaused = paused }
    }

    /// Stops the display timer until the next `wake()`.
    func rest() {
        guard !resting else { return }
        resting = true
        if !isPaused { isPaused = true }
    }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
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
        let result = Result { try MeterGPU(device: previous?.device, queue: previous?.queue) }
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

    // Theme.rampStops: obsidian → accent → cream on dark, paper → accent → ink on light. Lightness moves
    // monotonically away from the well, so loudness reads the same in every hue and appearance.
    float3 rampMap(float x) {
        x = saturate(x);
        const float3 stops[6] = { \(Theme.rampStops.map(\.metal).joined(separator: ", ")) };
        float scaled = x * 5.0;
        uint index = min(uint(scaled), 4u);
        float t = scaled - float(index);
        return mix(stops[index], stops[index + 1], t * t * (3.0 - 2.0 * t));
    }

    struct WaterfallState { uint head; uint rows; float phase; float span; };

    constant float waterfallBands = \(Float(SpectrogramHistory.height));

    float historyAt(texture2d<float, access::read> history, constant WaterfallState &state, float age, float band) {
        float clampedAge = clamp(age, 0.0, float(state.rows) - 1.001);
        uint a0 = uint(clampedAge);
        uint b0 = uint(band);
        uint b1 = min(b0 + 1, uint(waterfallBands) - 1u);
        uint c0 = (state.head + state.rows - 1 - a0) % state.rows;
        uint c1 = (state.head + state.rows - 2 - a0) % state.rows;
        float fb = fract(band), fa = fract(clampedAge);
        float newer = mix(history.read(uint2(c0, b0)).r, history.read(uint2(c0, b1)).r, fb);
        float older = mix(history.read(uint2(c1, b0)).r, history.read(uint2(c1, b1)).r, fb);
        return mix(newer, older, fa);
    }

    // local: pixels from the quad centre; shape.xy: half size; shape.zw: uv.
    // `phase` (0–1) slides the history between 30 Hz analysis columns so scrolling is continuous at 60 Hz.
    fragment float4 waterfallFragment(Raster in [[stage_in]],
                                      texture2d<float, access::read> history [[texture(0)]],
                                      constant WaterfallState &state [[buffer(0)]]) {
        float2 uv = in.shape.zw;
        // Horizontal: frequency rises bottom to top, time runs left to right with the newest column at the right.
        float band = clamp((1.0 - uv.y) * waterfallBands - 0.5, 0.0, waterfallBands - 1.0);
        // `span` columns across the quad: the newest slice of the ring, not all of it.
        float level = historyAt(history, state, (1.0 - uv.x) * state.span - state.phase, band);
        // Stored 0–1 covers −120…0 dB; show −96…−12 dB. The deeper floor and steeper curve keep the noise
        // floor black so partials stand out; older columns dim only slightly, so the history stays legible.
        float db = level * 120.0 - 120.0;
        float x = pow(saturate((db + 96.0) / 84.0), 1.45);
        float mask = saturate(0.5 - roundedBox(in.local, in.shape.xy, 7.0));
        // Older columns recede toward the empty well colour: darker on dark, paler on light.
        float fade = 0.86 + 0.14 * uv.x;
        return float4(mix(rampMap(0.0), rampMap(x), fade), mask);
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
        ScopeSample sample = scopeEnvelope(pyramid, state, age, abs(dfdx(age)), role >> 1);
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
        color = over(color, mix(ink, grid, edgeInk), saturate(1.1 - edge) * 0.92 * persistence);
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
    mutating func underlayQuad(_ rect: CGRect) {
        let hw = Float(rect.width / 2), hh = Float(rect.height / 2)
        func corner(_ x: CGFloat, _ y: CGFloat, _ u: Float, _ v: Float) -> ShapeVertex {
            ShapeVertex(position: SIMD2(Float(x), Float(y)), local: SIMD2(u * 2 * hw - hw, v * 2 * hh - hh),
                        color: SIMD4(1, 1, 1, 1), shape: SIMD4(hw, hh, u, v))
        }
        let a = corner(rect.minX, rect.minY, 0, 0), c = corner(rect.maxX, rect.minY, 1, 0)
        let d = corner(rect.minX, rect.maxY, 0, 1), e = corner(rect.maxX, rect.maxY, 1, 1)
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

/// 16 bytes, laid out like both Metal underlay states: `WaterfallState` (head, rows, phase, span) and
/// `ScopeState` (newest, capacity, phase, span).
struct UnderlayState {
    var head: UInt32 = 0
    var rows: UInt32 = 1
    var phase: Float = 0
    var span: Float = 0
}

enum UnderlayKind { case waterfall, waveform }

extension CanvasScene {
    var usesDampedLevels: Bool { true }
}

protocol CanvasScene: AnyObject {
    /// Whether `build` reads the damped display levels; the waterfall and the scope draw from history instead.
    var usesDampedLevels: Bool { get }
    var underlayKind: UnderlayKind { get }
    var underlayTexture: MTLTexture? { get }
    var underlayState: UnderlayState { get }
    func prepare(frame: CanvasFrame)
    func build(_ builder: inout ShapeBuilder, frame: CanvasFrame, display: MeterSnapshot, size: CGSize, dt: Float)
}

/// Scenes outlive their canvas. A palette or appearance change rebuilds the meter's views, and the new canvases
/// pick up the same scenes, so the waterfall, the scope history, peak holds and clip latches carry on instead of
/// starting blank. Only the pipelines, compiled with the new colours, change.
enum SceneStore {
    private static var scenes: [CanvasKind: CanvasScene] = [:]

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
        case .soundstage: return SoundstageScene()
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
    private let damping = DampedDisplayState()
    private var lastDrawTime: CFTimeInterval = 0
    private var previous: MeterSnapshot?
    private var previousSize = CGSize.zero
    private var previousEpoch = -1
    private var previousSpatial = true
    private var previousMono = false
    private var previousLayout = SpeakerLayout.standard
    private var settleFrames = 0

    /// `shared`: take the window's long-lived scene for `kind` (see `SceneStore`); the offscreen preview makes its own.
    init(kind: CanvasKind, gpu: MeterGPU, shared: Bool = false) throws {
        self.gpu = gpu
        // Measured demo peaks are about 3,230 / 80 / 6 / 800 vertices respectively. Keep ample
        // headroom for both formats and window sizes without reserving 24,000 for every canvas.
        switch kind {
        case .spectrum: vertexCapacity = 8_192
        case .spectrogram, .waveform: vertexCapacity = 1_024
        case .soundstage: vertexCapacity = 8_192
        }
        builder = ShapeBuilder(reserving: vertexCapacity)
        scene = shared ? try SceneStore.scene(kind, device: gpu.device) : try SceneStore.make(kind, device: gpu.device)
        // inFlight permits one GPU submission at a time, so one shared vertex buffer is enough.
        guard let buffer = gpu.device.makeBuffer(length: vertexCapacity * MemoryLayout<ShapeVertex>.stride,
                                                 options: .storageModeShared) else { throw MetalError.allocation }
        self.buffer = buffer
    }

    @discardableResult
    func draw(in view: MTKView, frame: CanvasFrame, force: Bool) -> Bool {
        let size = view.bounds.size
        let changed = force || frame.running || previous != frame.snapshot || size != previousSize || frame.epoch != previousEpoch
            || frame.spatial != previousSpatial || frame.mono != previousMono || frame.layout != previousLayout
        // Keep drawing briefly after the signal stops so damped bars and holds settle instead of freezing.
        settleFrames = changed ? 0 : settleFrames + 1
        guard settleFrames < 120 else { return false }
        // Never block the main thread on the GPU: if the previous frame is still being drawn, skip this one.
        guard inFlight.wait(timeout: .now()) == .success else { return false }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = gpu.queue.makeCommandBuffer(),
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
        command.commit()
        previous = frame.snapshot
        previousSize = size
        previousEpoch = frame.epoch
        previousSpatial = frame.spatial
        previousMono = frame.mono
        previousLayout = frame.layout
        return true
    }

    fileprivate func render(frame: CanvasFrame, size: CGSize, dt: Float, encoder: MTLRenderCommandEncoder, buffer: MTLBuffer) {
        scene.prepare(frame: frame)
        let display = scene.usesDampedLevels ? damping.step(target: frame.snapshot, deltaTime: dt) : frame.snapshot
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
        let scale = 2
        // The window's arrangement: Spectrum, Spectrogram and Waveform stacked on the left, the tall
        // Soundstage column on the right.
        let spectrumSize = CGSize(width: 900, height: 200)
        let spectrogramSize = CGSize(width: 900, height: 226)
        let waveSize = CGSize(width: 900, height: 300)
        let stageSize = CGSize(width: 380, height: 766)
        let gap = 20.0
        let width = Int(spectrumSize.width + gap + stageSize.width) * scale
        let height = Int(stageSize.height) * scale
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
        // Spatial part of the demo cycle, so the preview shows every lane and channel of the layout.
        let steps = SpectrogramHistory.width
        frame.spatial = true
        // Fill the waterfall history, then settle holds and damping on the final frame.
        for step in 0..<steps {
            frame.snapshot = DemoSignal.snapshot(at: Double(step % 400) / DemoSignal.updateRate, sequence: step)
            spectrum.scene.prepare(frame: frame)
            spectrogram.scene.prepare(frame: frame)
            waveform.scene.prepare(frame: frame)
            soundstage.scene.prepare(frame: frame)
        }
        frame.snapshot.channelPeaks[1] = 1.02
        for _ in 0..<40 {
            _ = spectrum.damping.step(target: frame.snapshot, deltaTime: 1.0 / 60)
            _ = soundstage.damping.step(target: frame.snapshot, deltaTime: 1.0 / 60)
        }
        func viewport(x: Double, y: Double, size: CGSize) {
            encoder.setViewport(MTLViewport(originX: x * Double(scale), originY: y * Double(scale),
                                            width: size.width * Double(scale), height: size.height * Double(scale), znear: 0, zfar: 1))
        }
        viewport(x: 0, y: 0, size: spectrumSize)
        spectrum.render(frame: frame, size: spectrumSize, dt: 1.0 / 60, encoder: encoder, buffer: spectrum.buffer)
        viewport(x: 0, y: spectrumSize.height + gap, size: spectrogramSize)
        spectrogram.render(frame: frame, size: spectrogramSize, dt: 1.0 / 60, encoder: encoder, buffer: spectrogram.buffer)
        viewport(x: 0, y: spectrumSize.height + spectrogramSize.height + 2 * gap, size: waveSize)
        waveform.render(frame: frame, size: waveSize, dt: 1.0 / 60, encoder: encoder, buffer: waveform.buffer)
        viewport(x: spectrumSize.width + gap, y: 0, size: stageSize)
        soundstage.render(frame: frame, size: stageSize, dt: 1.0 / 60, encoder: encoder, buffer: soundstage.buffer)
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

// MARK: - Spectrum: live curve of the monitored channels with per-band peak holds

final class SpectrumScene: CanvasScene {
    private var holds = [Float](repeating: -120, count: MeterSnapshot.bandCount)
    private var holdTimers = [Float](repeating: 0, count: MeterSnapshot.bandCount)
    private var curve: [CGPoint] = []

    // Shapes only: no underlay quad is ever added, so the texture is never bound.
    var underlayKind: UnderlayKind { .waterfall }
    var underlayTexture: MTLTexture? { nil }
    var underlayState: UnderlayState { UnderlayState() }

    init() { curve.reserveCapacity(MeterSnapshot.bandCount * 4 + 2) }

    func prepare(frame: CanvasFrame) {}

    func build(_ b: inout ShapeBuilder, frame: CanvasFrame, display: MeterSnapshot, size: CGSize, dt: Float) {
        let layout = SpectrumLayout(size: size)
        let plot = layout.plot
        let grid = Theme.inkRGB.simd(0.075)
        for db in SpectrumLayout.grid {
            let y = (layout.y(decibels: db) * 2).rounded() / 2
            b.rect(CGRect(x: plot.minX, y: y, width: plot.width, height: 0.5), grid)
        }
        let upper = MeterScale.upperFrequency(sampleRate: frame.sampleRate)
        for frequency in [50.0, 200, 500, 2_000, 5_000] where frequency < upper {
            let x = (layout.x(frequency: frequency, sampleRate: frame.sampleRate) * 2).rounded() / 2
            b.rect(CGRect(x: x, y: plot.minY, width: 0.5, height: plot.height), Theme.inkRGB.simd(0.045))
        }
        for frequency in [100.0, 1_000, 10_000] where frequency < upper {
            let x = (layout.x(frequency: frequency, sampleRate: frame.sampleRate) * 2).rounded() / 2
            b.rect(CGRect(x: x, y: plot.minY, width: 0.5, height: plot.height), grid)
        }

        // Spectrum: Catmull-Rom curve with a height-anchored fill and per-band peak dashes.
        let bands = display.spectrum
        let count = bands.count
        let step = plot.width / CGFloat(count)
        func point(_ index: Int) -> CGPoint {
            let i = max(0, min(count - 1, index))
            return CGPoint(x: plot.minX + (CGFloat(i) + 0.5) * step, y: layout.y(decibels: bands[i]))
        }
        curve.removeAll(keepingCapacity: true)
        curve.append(CGPoint(x: plot.minX, y: point(0).y))
        for index in 0..<(count - 1) {
            let p0 = point(index - 1), p1 = point(index), p2 = point(index + 1), p3 = point(index + 2)
            for sub in 0..<4 {
                let t = CGFloat(sub) / 4, t2 = t * t, t3 = t2 * t
                func spline(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                let y = min(plot.maxY, max(plot.minY, spline(p0.y, p1.y, p2.y, p3.y)))
                curve.append(CGPoint(x: spline(p0.x, p1.x, p2.x, p3.x), y: y))
            }
        }
        curve.append(point(count - 1))
        curve.append(CGPoint(x: plot.maxX, y: point(count - 1).y))
        let lime = Theme.sageRGB
        let floor = SIMD4<Float>(lime.r, lime.g, lime.b, 0.02)
        for (p, q) in zip(curve, curve.dropFirst()) {
            func top(_ point: CGPoint) -> SIMD4<Float> {
                SIMD4(lime.r, lime.g, lime.b, 0.05 + 0.30 * Float((plot.maxY - point.y) / max(1, plot.height)))
            }
            let pb = CGPoint(x: p.x, y: plot.maxY), qb = CGPoint(x: q.x, y: plot.maxY)
            b.triangle(p, q, qb, top(p), top(q), floor)
            b.triangle(p, qb, pb, top(p), floor, floor)
        }
        for (p, q) in zip(curve, curve.dropFirst()) { b.line(p, q, width: 1.75, lime.simd()) }
        for index in 0..<count {
            let value = frame.running ? frame.snapshot.spectrum[index] : -120
            if value >= holds[index] {
                holds[index] = value
                holdTimers[index] = 1.2
            } else if holdTimers[index] > 0 {
                holdTimers[index] -= dt
            } else {
                holds[index] = max(-120, holds[index] - 18 * dt)
            }
            // Only show a hold where it floats clearly above the live curve.
            guard holds[index] > MeterScale.spectrumFloor + 1, holds[index] - bands[index] > 2 else { continue }
            let y = layout.y(decibels: holds[index])
            let x = plot.minX + CGFloat(index) * step
            b.rect(CGRect(x: x + step * 0.2, y: y - 0.5, width: step * 0.6, height: 1), Theme.inkRGB.simd(0.42))
        }
    }
}

// MARK: - Spectrogram: scrolling history, newest at the top, on the Spectrum's frequency axis

final class SpectrogramScene: CanvasScene {
    private let texture: MTLTexture
    private let history = SpectrogramHistory()
    private var previousColumn: Float = 0
    private var previousStream: Float = 0
    private var previousRate: Double = 0
    private var lastUpload: CFTimeInterval = 0
    private var phase: Float = 0

    var usesDampedLevels: Bool { false }
    var underlayKind: UnderlayKind { .waterfall }
    var underlayTexture: MTLTexture? { texture }
    var underlayState: UnderlayState {
        UnderlayState(head: UInt32(history.writeIndex), rows: UInt32(SpectrogramHistory.width), phase: phase,
                      span: Float(SpectrogramLayout.visibleColumns))
    }

    init(device: MTLDevice) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: SpectrogramHistory.width,
                                                                  height: SpectrogramHistory.height, mipmapped: false)
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
        let blank = [UInt8](repeating: 0, count: SpectrogramHistory.width * SpectrogramHistory.height)
        texture.replace(region: MTLRegionMake2D(0, 0, SpectrogramHistory.width, SpectrogramHistory.height),
                        mipmapLevel: 0, withBytes: blank, bytesPerRow: SpectrogramHistory.width)
    }

    func prepare(frame: CanvasFrame) {
        let snapshot = frame.snapshot
        let streamChanged = snapshot.streamID > 0 && snapshot.streamID != previousStream
        if streamChanged || (previousRate > 0 && frame.sampleRate != previousRate) { clear() }
        // One column per waterfall serial (30 Hz), however often snapshots arrive.
        if frame.running && snapshot.spectrogramSerial > 0 && (streamChanged || snapshot.spectrogramSerial != previousColumn) {
            let index = history.append(snapshot.spectrogram)
            history.column.withUnsafeBytes { bytes in
                texture.replace(region: MTLRegionMake2D(index, 0, 1, SpectrogramHistory.height),
                                mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: 1)
            }
            lastUpload = CACurrentMediaTime()
        }
        // Freeze in place while paused; otherwise advance within the current analysis interval.
        if frame.running && lastUpload > 0 {
            phase = Float(min(1, (CACurrentMediaTime() - lastUpload) * SpectrogramLayout.analysisRate))
        }
        if snapshot.streamID > 0 { previousStream = snapshot.streamID }
        previousColumn = snapshot.spectrogramSerial
        previousRate = frame.sampleRate
    }

    func build(_ b: inout ShapeBuilder, frame: CanvasFrame, display: MeterSnapshot, size: CGSize, dt: Float) {
        let layout = SpectrogramLayout(size: size)
        let plot = layout.plot
        b.underlayQuad(plot)
        // Octave lines at every C, continuing the keyboard's C keys across the plot.
        for octave in 0...9 {
            let y = (layout.y(midi: Double(12 * (octave + 1)), sampleRate: frame.sampleRate) * 2).rounded() / 2
            guard y > plot.minY + 1, y < plot.maxY - 1 else { continue }
            b.rect(CGRect(x: plot.minX, y: y, width: plot.width, height: 0.5), Theme.inkRGB.simd(octave == 4 ? 0.12 : 0.06))
        }
        for seconds in stride(from: 2.0, to: SpectrogramLayout.historySeconds, by: 2) {
            let x = (layout.x(secondsAgo: seconds) * 2).rounded() / 2
            b.rect(CGRect(x: x, y: plot.minY, width: 0.5, height: plot.height), Theme.inkRGB.simd(0.06))
        }
    }
}

// MARK: - Waveform: one phosphor lane per channel, drawn from the min/max pyramid

final class WaveformScene: CanvasScene {
    /// 2048 envelope columns (~8.5 s at 240 columns/s) per pyramid level 0; the lanes show `visibleColumns` (4 s).
    static let traceCapacity = 2048
    static let visibleColumns = 960
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
        UnderlayState(head: pyramid.newestIndex, rows: UInt32(Self.traceCapacity), phase: lag, span: Float(Self.visibleColumns))
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

// MARK: - Soundstage: a top-down room above per-channel meters and the correlation meter

final class SoundstageScene: CanvasScene {
    private var holds = [Float](repeating: -120, count: Role.count)
    private var holdTimers = [Float](repeating: 0, count: Role.count)
    private var clipped = [Bool](repeating: false, count: Role.count)
    private var peakDb = [Float](repeating: -120, count: Role.count)
    private var rmsDb = [Float](repeating: -120, count: Role.count)
    private var epoch = -1
    private var spring = PresenceSpring()
    private var presence: Float { spring.value }
    private var monoSpring = PresenceSpring()
    private var mono: Float { monoSpring.value }
    /// Bed and height speakers of the current layout, clockwise from centre front, for the image polygons.
    private var cachedLayout: SpeakerLayout?
    private var bed: [Speaker] = []
    private var heights: [Speaker] = []

    // Shapes only: no underlay quad is ever added, so the texture is never bound.
    var underlayKind: UnderlayKind { .waveform }
    var underlayTexture: MTLTexture? { nil }
    var underlayState: UnderlayState { UnderlayState() }

    func prepare(frame: CanvasFrame) {
        if frame.epoch != epoch {
            epoch = frame.epoch
            holds = Array(repeating: -120, count: Role.count)
            clipped = Array(repeating: false, count: Role.count)
        }
        // The DSP-held peak catches a clip even in a snapshot this canvas never drew.
        for role in 0..<Role.count where max(frame.snapshot.channelPeaks[role], frame.snapshot.heldPeaks[role]) >= 1 {
            clipped[role] = true
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
        let layout = SoundstageLayout(size: size, presence: CGFloat(presence), mono: CGFloat(mono), layout: frame.layout)

        for role in 0..<Role.count {
            peakDb[role] = MeterScale.decibels(display.channelPeaks[role])
            rmsDb[role] = MeterScale.decibels(display.channelRMS[role])
            if peakDb[role] >= holds[role] {
                holds[role] = peakDb[role]
                holdTimers[role] = 1.5
            } else if holdTimers[role] > 0 {
                holdTimers[role] -= dt
            } else {
                holds[role] = max(-120, holds[role] - 20 * dt)
            }
        }
        drawRoom(&b, layout: layout, frame: frame)
        drawMeters(&b, layout: layout, frame: frame)
        drawCorrelation(&b, layout: layout, value: display.correlation, running: frame.running)
    }

    /// L always reads at full strength, R recedes in Mono, every other role follows the Spatial presence.
    private func visibility(_ role: Int) -> Float {
        role == Role.left ? 1 : (role == Role.right ? presence + (1 - presence) * (1 - mono) : presence)
    }

    /// Room furniture (rings, crosshair) is gone before the zoom takes it past the square's edge.
    private var roomVisibility: Float { smoothstep(0.55, 1, presence) }

    private func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    private func drawRoom(_ b: inout ShapeBuilder, layout: SoundstageLayout, frame: CanvasFrame) {
        let c = layout.center
        let r = layout.bedRadius
        let side = layout.radar.width
        let p = presence
        let room = roomVisibility
        let ink = Theme.inkRGB
        if room > 0.002 {
            b.line(CGPoint(x: c.x - r, y: c.y), CGPoint(x: c.x + r, y: c.y), width: 0.5, ink.simd(0.07 * room))
            b.line(CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x, y: c.y + r), width: 0.5, ink.simd(0.07 * room))
            b.ring(c, radius: r, width: 1, ink.simd(0.13 * room))
            b.ring(c, radius: r * 0.5, width: 0.75, ink.simd(0.06 * room))
            if !heights.isEmpty {
                b.ring(c, radius: layout.heightRadius, width: 1, Theme.heatherRGB.simd(0.30 * room), dashes: 40)
            }
        }

        // Stereo stage: the ±30° arc between L and R lights up as the room dissolves, and closes to a point
        // as L and R merge into the front-centre mono source.
        let sage = Theme.sageRGB
        let stage = 1 - p
        let spread = 30 * Double(1 - mono)
        if stage > 0.005 {
            var previous: CGPoint?
            for step in 0...16 {
                let direction = SoundstageLayout.direction(-spread + 2 * spread * Double(step) / 16)
                let point = CGPoint(x: c.x + direction.dx * r, y: c.y + direction.dy * r)
                if let previous {
                    b.line(previous, point, width: 1.5, sage.simd(0.65 * stage))
                }
                previous = point
            }
            // Sight lines from the listener to each speaker complete the equilateral stage.
            for speaker in layout.speakers where speaker.role < 2 {
                b.line(c, layout.node(speaker), width: 0.75, ink.simd(0.10 * stage * visibility(speaker.role)))
            }
        }

        // LFE radiates from the listener position: it has no direction, only energy.
        if frame.layout.hasLFE {
            let lfe = MeterScale.position(decibels: rmsDb[Role.lfe])
            if frame.activeRoles[Role.lfe] && p > 0.002 {
                b.glow(c, radius: layout.nodeRadius * 2 + side * 0.12 * CGFloat(lfe), Theme.clayRGB.simd((0.05 + 0.25 * lfe) * p))
            }
            if p > 0.002 {
                b.ring(c, radius: layout.nodeRadius * 1.5, width: 1,
                       Theme.clayRGB.simd((frame.activeRoles[Role.lfe] ? 0.45 : 0.15) * p), dashes: 0, sweep: 1)
            }
        }
        b.disk(c, radius: 2.5, ink.simd(0.5))

        // Bed image: radar polygon of RMS, clockwise from centre front. Extended vertices fold into the
        // listener as they dissolve, so the polygon morphs into the L–R stereo image.
        if bed.count >= 2 {
            let polygon = bed.map { speaker -> CGPoint in
                let level = frame.activeRoles[speaker.role] ? CGFloat(MeterScale.position(decibels: rmsDb[speaker.role])) : 0
                let direction = layout.direction(speaker)
                let radius = r * (0.08 + 0.92 * level) * CGFloat(visibility(speaker.role))
                return CGPoint(x: c.x + direction.dx * radius, y: c.y + direction.dy * radius)
            }
            for (p, q) in zip(polygon, polygon.dropFirst() + [polygon[0]]) {
                b.triangle(c, p, q, sage.simd(0.16), sage.simd(0.08), sage.simd(0.08))
            }
            for (p, q) in zip(polygon, polygon.dropFirst() + [polygon[0]]) { b.line(p, q, width: 1.25, sage.simd(0.85)) }
        }

        // Upper layer drawn as its own heather shape so ceiling energy never reads as bed energy: a wedge
        // from the listener for a height pair, a closed polygon for four or six heights.
        if p > 0.005 && heights.count >= 2 {
            let points = heights.map { speaker -> CGPoint in
                let level = frame.activeRoles[speaker.role] ? CGFloat(MeterScale.position(decibels: rmsDb[speaker.role])) : 0
                let direction = SoundstageLayout.direction(speaker.azimuth ?? 0)
                let radius = layout.heightRadius * (0.15 + 0.85 * level)
                return CGPoint(x: c.x + direction.dx * radius, y: c.y + direction.dy * radius)
            }
            let heather = Theme.heatherRGB
            let outline = points.count == 2 ? [c, points[0], points[1]] : points
            for (a, z) in zip(outline, outline.dropFirst() + [outline[0]]) {
                b.triangle(c, a, z, heather.simd(0.14 * p), heather.simd(0.08 * p), heather.simd(0.08 * p))
                b.line(a, z, width: 1, heather.simd(0.55 * p))
            }
        }

        // Energy centroid of the bed: where the mix image "points". Dissolving channels weigh less.
        var vx: CGFloat = 0, vy: CGFloat = 0, total: CGFloat = 0
        for speaker in bed where frame.activeRoles[speaker.role] {
            let energy = CGFloat(pow(10, rmsDb[speaker.role] / 10) * visibility(speaker.role))
            let direction = layout.direction(speaker)
            vx += direction.dx * energy
            vy += direction.dy * energy
            total += energy
        }
        if total > 1e-6 {
            let point = CGPoint(x: c.x + vx / total * r, y: c.y + vy / total * r)
            b.disk(point, radius: 3.2, ink.simd())
        }

        for speaker in layout.speakers where speaker.group != .lfe {
            let v = visibility(speaker.role)
            guard v > 0.002 else { continue }
            let point = layout.node(speaker)
            let color = Theme.groupRGB(speaker.group)
            // Dissolve: receding nodes shrink a little as they fade, like a layer blurring away.
            let n = layout.nodeRadius * CGFloat(0.6 + 0.4 * v)
            guard frame.activeRoles[speaker.role] else {
                b.ring(point, radius: n, width: 1, ink.simd(0.16 * v))
                continue
            }
            let rms = MeterScale.position(decibels: rmsDb[speaker.role])
            let peak = MeterScale.position(decibels: peakDb[speaker.role])
            b.disk(point, radius: n, Theme.displayRGB.simd(0.92 * v))
            b.disk(point, radius: n - 1.5, color.simd((0.26 + 0.74 * rms) * v))
            b.ring(point, radius: n + 3, width: 1.5, ink.simd(0.10 * v))
            let arcColor = clipped[speaker.role] ? Theme.emberRGB.simd(v) : Theme.inkRGB.simd(0.85 * v)
            if peak > 0.005 { b.ring(point, radius: n + 3, width: 1.5, arcColor, sweep: peak) }
        }
    }

    private func drawMeters(_ b: inout ShapeBuilder, layout: SoundstageLayout, frame: CanvasFrame) {
        let block = layout.block
        let ink = Theme.inkRGB
        // dB graticule: vertical ticks through every row, 0 dBFS in ember.
        for db in SoundstageLayout.scaleTicks {
            let x = (layout.x(decibels: db) * 2).rounded() / 2
            let color = db == 0 ? Theme.emberRGB.simd(0.55) : ink.simd(0.09)
            b.rect(CGRect(x: x, y: block.minY + SoundstageLayout.headerHeight - 3, width: 0.5,
                          height: max(0, block.height - SoundstageLayout.headerHeight + 6)), color)
        }
        // Group rules under each header, in the group's colour.
        for header in layout.headers {
            let weight = Float(layout.headerWeight(header.group))
            guard header.rect.height > 1 else { continue }
            let y = (header.rect.maxY - 4).rounded()
            b.rect(CGRect(x: header.rect.minX, y: y, width: header.rect.width, height: 0.5),
                   Theme.groupRGB(header.group).simd(0.35 * weight * weight))
        }
        for (index, speaker) in layout.speakers.enumerated() {
            let role = speaker.role
            let v = visibility(role)
            guard v > 0.002 else { continue }
            let bar = layout.bar(index)
            let active = frame.activeRoles[role]
            let radius = min(3, bar.height / 2)
            b.roundedRect(bar, radius: radius, ink.simd((active ? 0.09 : 0.04) * v))
            let led = CGPoint(x: layout.clipX, y: bar.midY)
            let ledRadius = min(2.5, bar.height / 2 + 0.5)
            b.disk(led, radius: ledRadius, clipped[role] ? Theme.emberRGB.simd(v) : ink.simd(0.10 * v))
            if clipped[role] { b.glow(led, radius: 7, Theme.emberRGB.simd(0.35 * v)) }
            guard active else { continue }
            let inner = bar.insetBy(dx: 1, dy: min(1, bar.height / 4))
            // Dynamic range: the peak-to-RMS crest as an ink veil; colour is reserved for RMS and the hold.
            if peakDb[role] > -70 {
                let right = layout.x(decibels: min(0, peakDb[role]))
                b.rect(CGRect(x: inner.minX, y: inner.minY, width: max(0, right - inner.minX), height: inner.height),
                       ink.simd((Theme.dark ? 0.15 : 0.11) * v))
            }
            b.levelFill(inner, to: rmsDb[role], alpha: v) { layout.x(decibels: $0) }
            if holds[role] > -60 {
                // Peak hold: a solid tick in the level colour, pulled toward the ink so it reads against the fill.
                let x = layout.x(decibels: holds[role])
                var hold = Theme.level(holds[role]) * 0.6 + ink.simd() * 0.4
                hold.w = v
                b.rect(CGRect(x: x - 1, y: bar.minY - 1, width: 2, height: bar.height + 2), hold)
            }
        }
    }

    /// Mirrored signed correlation: −1 at either edge, +1 at the centre. At 0 the markers sit halfway
    /// along each side; the signed numeric readout stays unchanged.
    private func drawCorrelation(_ b: inout ShapeBuilder, layout: SoundstageLayout, value: Float, running: Bool) {
        // Mono has no L/R pair: the meter dissolves as its footer folds away.
        let fade = (1 - mono) * (1 - mono)
        guard fade > 0.002 else { return }
        let track = layout.correlationTrack
        let ink = Theme.inkRGB
        b.roundedRect(track, radius: track.height / 2, ink.simd(0.09 * fade))
        for fraction: CGFloat in [0.25, 0.5, 0.75] {
            let x = ((track.minX + track.width * fraction) * 2).rounded() / 2
            let center = fraction == 0.5
            b.rect(CGRect(x: x, y: track.minY - (center ? 3 : 1), width: 0.5,
                          height: track.height + (center ? 6 : 2)),
                   ink.simd((center ? 0.35 : 0.14) * fade))
        }
        guard running, value != MeterSnapshot.noCorrelation else { return }
        let inset = layout.correlationInset(value)
        let color = value >= 0.3 ? Theme.sageRGB : (value >= 0 ? Theme.ochreRGB : Theme.emberRGB)
        if inset > 0.5 {
            let height = track.height - 2
            let radius = min(height / 2, inset / 2)
            b.roundedRect(CGRect(x: track.minX + 1, y: track.minY + 1, width: inset, height: height),
                          radius: radius, color.simd(0.72 * fade))
            b.roundedRect(CGRect(x: track.maxX - inset - 1, y: track.minY + 1, width: inset, height: height),
                          radius: radius, color.simd(0.72 * fade))
        }
        for x in [track.minX + inset, track.maxX - inset] {
            b.roundedRect(CGRect(x: x - 1.5, y: track.minY - 3, width: 3, height: track.height + 6),
                          radius: 1.5, (value < 0 ? color : ink).simd(0.95 * fade))
        }
    }
}
