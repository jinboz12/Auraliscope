import AnalysisCore
import Foundation

/// The canvases' Metal shaders, compiled from this source when `MeterGPU` builds its pipelines (`MetalCanvas.swift`),
/// with the layout checks that keep each shader struct the size of its Swift counterpart.
extension MeterGPU {
    /// Every struct a shader reads from a Swift buffer is declared twice, in Swift and in `shaderSource`, and nothing
    /// links the two: a field added on one side only shifts every field after it, silently. These checks make the
    /// library fail to compile instead (in the build that changed it, on first launch) unless each shader struct is
    /// exactly as large as its Swift counterpart's stride. `ScopeState` reads only the start of `UnderlayState`.
    static var layoutChecks: String {
        let pairs: [(shader: String, swift: Int)] = [
            ("Vertex", MemoryLayout<ShapeVertex>.stride), ("WaterfallState", MemoryLayout<UnderlayState>.stride),
            ("SurfaceState", MemoryLayout<SurfaceState>.stride), ("BodyUniforms", MemoryLayout<BodyUniforms>.stride),
            ("RadiantParticle", MemoryLayout<RadiantParticles.Particle>.stride),
            ("RadiantCamera", MemoryLayout<RadiantCamera>.stride), ("RadiantLook", MemoryLayout<RadiantLook>.stride),
            ("VolumeSplat", MemoryLayout<VolumeSplat>.stride), ("VolumeBlur", MemoryLayout<VolumeBlur>.stride),
            ("RadiantBodyLook", MemoryLayout<RadiantBodyLook>.stride),
        ]
        return "\n" + pairs.map { "static_assert(sizeof(\($0.shader)) == \($0.swift), \"\($0.shader) is not laid out like its Swift declaration\");" }
            .joined(separator: "\n") + "\nstatic_assert(sizeof(ScopeState) <= \(MemoryLayout<UnderlayState>.stride), \"ScopeState reads past UnderlayState\");\n"
    }

    // Shape kinds: 0 solid, 1 rounded rect, 2 disk, 3 glow, 4 ring/arc/dashes, 5 antialiased line,
    // 6 rounded-rect hairline outline.
    static var shaderSource: String { """
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

    // The Immersive nebula's body (`NebulaScene`): how loud the speaker feeds are heard from each direction, and what
    // frequencies. `field` holds, per direction and layer, the radius with its afterglow (r: 0–1 from the floor level to
    // 0 dBFS), the share of the energy out of phase times its weight (g), that weight (b), so the share stays right where
    // it is interpolated toward an empty direction, and the live radius (a); coloured by frequency, `bands` holds each
    // of the five analysis bands' radius on the same scale (two slices per layer: bands 0–3, then band 4 and the largest
    // of them): x the azimuth clockwise from the front, y the elevation from the floor, `SpatialBody.step` degrees apart.
    // The camera is `DomeGeometry.project`'s orthographic one, drawn at half resolution (`NebulaScene.encodeOffscreen`).
    // Each ray through the occupied hemisphere is marched front to back through glowing gas: the live body emits more
    // toward the listener and the louder it is, the afterglow is a faint, softer haze, and the near side dims what lies
    // behind it a little. On dark the light adds up channel by channel and saturates, so deep, loud parts burn toward
    // white and their fringes keep their hues, as overlapping light does; on light the same depth lays a wash that
    // deepens toward ink. Coloured by frequency, a point wears the hues of the bands that reach at least that far in its
    // direction, weighted by how far they reach (`NebulaScene.spectralColor`): every audible band near the listener,
    // only the loudest at the edge. `colors` holds each layer's own colour, then the core's tint, the out-of-phase tint,
    // the ground and the five band hues.
    struct BodyUniforms {
        float minX; float minY; float maxX; float maxY; float viewportX; float viewportY;
        float originX; float originY; float scale; float sinEl; float cosEl; float sinYaw; float cosYaw;
        float opacity; float dark; uint layers; float bound; float spectral; float grain; float style;
        float gain; float spare; float lower;
    };
    struct BodyRaster { float4 position [[position]]; float2 local; };

    // The dome's outline as a quad, in canvas points.
    vertex BodyRaster bodyVertex(uint vid [[vertex_id]], constant BodyUniforms &s [[buffer(2)]]) {
        const float2 corners[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(0, 1), float2(1, 0), float2(1, 1) };
        float2 k = corners[vid % 6];
        float2 p = float2(mix(s.minX, s.maxX, k.x), mix(s.minY, s.maxY, k.y));
        BodyRaster out;
        out.position = float4(p.x / s.viewportX * 2.0 - 1.0, 1.0 - p.y / s.viewportY * 2.0, 0.0, 1.0);
        out.local = p;
        return out;
    }

    constant float bodyColumns = \(SpatialBody.azimuthSteps).0;
    constant float bodyRows = \(SpatialBody.rows).0;
    constant float bodyUpper = \(SpatialBody.elevationSteps).0;
    constant float bodyLower = \(SpatialBody.lowerSteps).0;

    // A unit direction (model coordinates: x right, y up, z ahead) as texture coordinates; texel centres sit on the
    // grid's directions.
    float2 bodyUV(float3 d) {
        return float2(atan2(d.x, d.z) * (0.5 / M_PI_F) + 0.5 / bodyColumns,
                      (asin(clamp(d.y, -1.0, 1.0)) * (2.0 / M_PI_F) * bodyUpper + bodyLower + 0.5) / bodyRows);
    }

    fragment float4 bodyFragment(BodyRaster in [[stage_in]], texture2d_array<float> field [[texture(0)]],
                                 texture2d_array<float> bands [[texture(1)]], texture3d<float> grain [[texture(2)]],
                                 constant BodyUniforms &s [[buffer(0)]], constant float4 *colors [[buffer(1)]]) {
        constexpr sampler bilinear(filter::linear, s_address::repeat, t_address::clamp_to_edge);
        constexpr sampler tiled(filter::linear, address::repeat);
        float X = (in.local.x - s.originX) / s.scale;
        float Y = (s.originY - in.local.y) / s.scale;
        float rr = X * X + Y * Y;
        if (rr >= s.bound * s.bound || s.opacity <= 0.0) { return float4(0.0); }
        float chordHalf = sqrt(s.bound * s.bound - rr);
        float tNear = chordHalf, tFar = -chordHalf;
        // Above the floor only, unless a speaker of the layout sits below the ear plane.
        if (s.lower < 0.5) {
            if (s.sinEl > 0.001) { tFar = max(tFar, -Y * s.cosEl / s.sinEl); } else if (Y < 0.0) { return float4(0.0); }
        }
        if (tNear <= tFar) { return float4(0.0); }
        // World-space sampling, so the picture holds still as the signal changes; work bounded to the occupied region.
        float chord = tNear - tFar;
        int steps = clamp(int(ceil(chord / 0.022)), 4, 96);
        float dt = chord / float(steps);
        float jitter = fract(52.9829189 * fract(dot(in.position.xy, float2(0.06711056, 0.00583715))));
        float3 core = colors[\(SpatialBody.maxLayers)].rgb;
        float3 ochre = colors[\(SpatialBody.maxLayers + 1)].rgb;
        float3 light = float3(0.0);
        float depth = 0.0, through = 1.0;
        for (int i = 0; i < steps && through > 0.02; i++) {
            float t = tNear - (float(i) + jitter) * dt;
            // q: the model turned by the yaw (x right, y up, z ahead); p: the model's own coordinates.
            float3 q = float3(X, Y * s.cosEl + t * s.sinEl, Y * s.sinEl - t * s.cosEl);
            float3 p = float3(q.x * s.cosYaw - q.z * s.sinYaw, q.y, q.x * s.sinYaw + q.z * s.cosYaw);
            float rho = length(p);
            if (rho < 0.0005) { continue; }
            float3 d = p / rho;
            float2 uv = bodyUV(d);
            float3 emit = float3(0.0);
            float density = 0.0;
            for (uint l = 0; l < s.layers; l++) {
                float4 v = field.sample(bilinear, uv, l);
                float R = v.r;
                if (R < 0.004) { continue; }
                // A finite feather instead of a hard shell; the afterglow's is wider, so older energy reads softer.
                float feather = clamp(R * 0.12, 0.02, 0.06);
                if (rho > R + feather * 1.6) { continue; }
                float liveR = min(R, v.a);
                float live = (1.0 - smoothstep(liveR - feather, liveR + feather, rho)) * smoothstep(0.004, 0.06, liveR);
                float envelope = (1.0 - smoothstep(R - feather * 1.6, R + feather * 1.6, rho)) * smoothstep(0.004, 0.06, R);
                float trail = max(0.0, envelope - live);
                float inside = saturate(1.0 - rho / max(liveR, 0.004));
                float3 hue = colors[l].rgb;
                if (s.spectral > 0.5) {
                    float4 A = bands.sample(bilinear, uv, 2 * l), B = bands.sample(bilinear, uv, 2 * l + 1);
                    float widest = max(B.g, 0.002), from = saturate(rho / max(liveR, 0.004)) - 0.2;
                    float radii[5] = { A.r, A.g, A.b, A.a, B.r };
                    float3 sum = float3(0.0);
                    float total = 0.0;
                    for (int b = 0; b < 5; b++) {
                        float x = saturate((radii[b] / widest - from) / 0.24);
                        float w = x * x * (3.0 - 2.0 * x) * (0.1 + radii[b]);
                        sum += colors[\(SpatialBody.maxLayers + 3) + b].rgb * w;
                        total += w;
                    }
                    hue = total > 0.0001 ? sum / total : core;
                    // A little more chroma than the plain mix, so warm and cool read apart; white stays white.
                    hue /= max(0.05, max(max(hue.r, hue.g), hue.b));
                    float luma = dot(hue, float3(0.2126, 0.7152, 0.0722));
                    hue = saturate(luma + (hue - luma) * 1.3);
                }
                hue = mix(hue, ochre, 0.8 * smoothstep(0.25, 0.85, v.b > 0.002 ? saturate(v.g / v.b) : 0.0));
                // The live body glows more toward the listener and the louder its direction (its radius); the afterglow
                // is a faint haze around it.
                float loud = 0.3 + 0.95 * liveR;
                float k = live * loud * (0.3 + 3.2 * inside * inside) + trail * 0.16;
                emit += hue * k;
                density += live * (0.45 + 0.8 * inside) + trail * 0.08;
            }
            if (density <= 0.0) { continue; }
            if (s.grain > 0.5) {
                // Static grain in the model's own space: it moves only as the body does, never by itself.
                float g = grain.sample(tiled, p * 1.9 + 0.5).r;
                float m = 0.72 + 0.56 * g;
                emit *= m;
                density *= m;
            }
            float w = dt * through;
            light += emit * w;
            depth += density * w;
            through *= exp(-density * dt * 0.55);
        }
        float gain = s.opacity * 3.6;
        if (s.dark > 0.5) {
            // Light adds up channel by channel and saturates: deep, loud parts burn toward white.
            float3 c = 1.0 - exp(-light * gain);
            float a = max(max(c.r, c.g), c.b);
            if (a < 0.0008) { return float4(0.0); }
            return float4(c / a, a);
        }
        // Light: a wash in the body's hues, deepening toward ink where it is deep.
        float a = 1.0 - exp(-depth * gain * 0.7);
        if (a < 0.0008) { return float4(0.0); }
        float3 hue = light / max(1e-5, max(max(light.r, light.g), light.b));
        float3 c = mix(hue * 0.78, core, 0.28 * smoothstep(0.4, 1.0, a));
        return float4(c, min(0.94, a));
    }

    // Radiant (`NebulaStyle.radiant`): the particles of `RadiantParticles`, one instance each, added as light in two
    // passes, like a display that draws each frame's particles small and sharp and then blurs and dims what it has
    // drawn before. The haze pass (`pass` 0) goes into a half-float target at half resolution (the one the level body
    // uses): a particle is a round Gaussian of σ `size` radii when born whose variance grows
    // by `blur`² radii² a second as it ages, as repeated blurring grows it, its peak dimmed as it grows so its light only
    // spreads, and fading by e^(−age/`fade`); after `lifetime` it is gone. The spark pass (`pass` 1) goes into a
    // full-resolution target: the same particle as a sparkle of σ `sparkSize` radii, `sparkGain` times as bright at its
    // peak, gone in a few frames (e^(−age/`sparkFade`)). So the newest particles glint and older ones smoke into glow,
    // in model space, so the camera can turn at any time. Energy out of phase is tinted ochre; the far side of the dome
    // is a little dimmer. The camera is `DomeGeometry.project`'s.
    struct RadiantParticle { float4 position; float4 color; float4 extra; };
    struct RadiantCamera {
        float originX; float originY; float scale; float sinEl; float cosEl; float sinYaw; float cosYaw;
        float viewportX; float viewportY; float pixels; float clock; float fade; float lifetime; float size; float blur;
        float minimum; float depthFade; float ochreR; float ochreG; float ochreB;
        float pass; float sparkSize; float sparkFade; float sparkGain;
    };
    struct RadiantRaster { float4 position [[position]]; float2 offset; float sigma; float3 color; float weight; };

    vertex RadiantRaster radiantParticleVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                               device const RadiantParticle *particles [[buffer(0)]],
                                               constant RadiantCamera &c [[buffer(1)]]) {
        RadiantParticle p = particles[iid];
        RadiantRaster out;
        float age = c.clock - p.position.w;
        bool spark = c.pass > 0.5;
        float lifetime = spark ? min(c.lifetime, 4.0 * c.sparkFade) : c.lifetime;
        if (age < -0.001 || age > lifetime || p.color.w <= 0.0) {
            out.position = float4(-2.0, -2.0, 0.0, 1.0);
            out.offset = float2(0.0); out.sigma = 1.0; out.color = float3(0.0); out.weight = 0.0;
            return out;
        }
        age = max(0.0, age);
        float3 m = p.position.xyz;
        float3 q = float3(m.x * c.cosYaw + m.z * c.sinYaw, m.y, m.z * c.cosYaw - m.x * c.sinYaw);
        float2 centre = float2(c.originX, c.originY) + float2(q.x, -(q.z * c.sinEl + q.y * c.cosEl)) * c.scale;
        float depth = q.y * c.sinEl - q.z * c.cosEl;  // larger is nearer the camera
        float sigma, gain;
        if (spark) {
            sigma = max(c.minimum, c.sparkSize * c.scale * c.pixels);
            gain = c.sparkGain * exp(-age / max(0.005, c.sparkFade));
        } else {
            float born = max(c.minimum, c.size * c.scale * c.pixels);
            float grown = c.blur * c.scale * c.pixels;
            sigma = sqrt(born * born + grown * grown * age);
            gain = exp(-age / max(0.005, c.fade)) * (born * born) / (sigma * sigma);
        }
        float shade = 1.0 - c.depthFade * (1.0 - saturate((depth + 1.0) * 0.5));
        float3 hue = p.color.rgb;
        float tint = 0.8 * smoothstep(0.25, 0.85, p.extra.x);
        hue = mix(hue, float3(c.ochreR, c.ochreG, c.ochreB), tint);
        float light = p.color.w * gain * shade;
        // Light this faint no longer shows, even where many particles overlap: old, smeared particles cover the most
        // pixels for the least light, so they are left out.
        if (light < 0.0005) {
            out.position = float4(-2.0, -2.0, 0.0, 1.0);
            out.offset = float2(0.0); out.sigma = 1.0; out.color = float3(0.0); out.weight = 0.0;
            return out;
        }
        const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(-1, 1), float2(1, -1), float2(1, 1) };
        float2 k = corners[vid % 6];
        float2 offset = k * 3.0 * sigma;
        float2 point = centre + offset / c.pixels;
        out.position = float4(point.x / c.viewportX * 2.0 - 1.0, 1.0 - point.y / c.viewportY * 2.0, 0.0, 1.0);
        out.offset = offset;
        out.sigma = sigma;
        out.color = hue * light;
        out.weight = light;
        return out;
    }

    // Added, never blended over: light from overlapping particles sums whatever order they come in.
    fragment float4 radiantParticleFragment(RadiantRaster in [[stage_in]]) {
        float r2 = dot(in.offset, in.offset) / (in.sigma * in.sigma);
        if (r2 > 9.0) { discard_fragment(); }
        float g = exp(-0.5 * r2);
        return float4(in.color * g, in.weight * g);
    }

    // Radiant's glow: its light averaged down to a quarter of the target (four bilinear taps, so a small particle is not
    // missed), then a 9-tap Gaussian (five linear fetches) across and down, twice.
    struct Fullscreen { float4 position [[position]]; float2 uv; };
    vertex Fullscreen fullscreenVertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        Fullscreen out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }
    fragment float4 bloomDownFragment(Fullscreen in [[stage_in]], texture2d<float> source [[texture(0)]]) {
        constexpr sampler linear(filter::linear, address::clamp_to_edge);
        float2 texel = 1.0 / float2(source.get_width(), source.get_height());
        return 0.25 * (source.sample(linear, in.uv + texel * float2(-1.0, -1.0)) + source.sample(linear, in.uv + texel * float2(1.0, -1.0))
                       + source.sample(linear, in.uv + texel * float2(-1.0, 1.0)) + source.sample(linear, in.uv + texel * float2(1.0, 1.0)));
    }
    fragment float4 bloomBlurFragment(Fullscreen in [[stage_in]], texture2d<float> source [[texture(0)]],
                                      constant float2 &step [[buffer(0)]]) {
        constexpr sampler linear(filter::linear, address::clamp_to_edge);
        float4 c = source.sample(linear, in.uv) * 0.2270270270;
        c += (source.sample(linear, in.uv + step * 1.3846153846) + source.sample(linear, in.uv - step * 1.3846153846)) * 0.3162162162;
        c += (source.sample(linear, in.uv + step * 3.2307692308) + source.sample(linear, in.uv - step * 3.2307692308)) * 0.0702702703;
        return c;
    }

    // Radiant's exposure meter: the brightest point of the wide glow (its 4-norm), so how dense the light is over a
    // broad patch, not at one bead; and that held, risen at once and fallen back by `rate` of the way each time it is
    // measured. One threadgroup of 256 threads.
    kernel void radiantMeterKernel(texture2d<float> glow [[texture(0)]], device float *meter [[buffer(0)]],
                                   constant float &rate [[buffer(1)]], uint tid [[thread_index_in_threadgroup]],
                                   uint threads [[threads_per_threadgroup]]) {
        threadgroup float partial[256];
        uint w = glow.get_width(), h = glow.get_height();
        float peak = 0.0;
        for (uint i = tid; i < w * h; i += threads) {
            float3 c = glow.read(uint2(i % w, i / w)).rgb;
            float3 c2 = c * c;
            peak = max(peak, sqrt(sqrt(dot(c2, c2))));
        }
        partial[tid] = peak;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint s = threads / 2; s > 0; s >>= 1) {
            if (tid < s) { partial[tid] = max(partial[tid], partial[tid + s]); }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (tid == 0) {
            float now = partial[0], held = meter[1];
            meter[0] = now;
            meter[1] = now > held ? now : held + (now - held) * rate;
        }
    }

    // Radiant's light laid into the canvas, straight alpha: the haze, the sparks (`sparkle` of them) and the glow, near
    // and wide (`spare` of it). `gain` is the exposure at the loudest band's level, eased where the light is dense over
    // a broad patch (the meter's held reading past `limit`, by `ease`: 0 not at all, 1 down to the limit), so a dense
    // programme keeps its colours while a bright bead still burns.
    // With the level body's palette (`palette` 1, the default) the light is coloured and exposed as `bodyFragment`
    // colours its glow: a point's hue moves `blend` of the way toward the hues heard around it (the wide glow's), as the
    // body mixes the hues of every band that reaches a place; it gets the body's extra chroma (`chroma`) and its static
    // grain (`grain` deep, fixed to the canvas and scaled with the dome); then on the dark well each channel saturates on
    // its own, so dense light burns toward cream-white while its fringes keep their hues, and on the light well it is a
    // wash deepening toward ink (`core`). Without it (the bare observations), the light keeps its own hue, exposed on
    // its 4-norm, only the densest (from `hotFrom` to `hotTo` of exposure) burning toward white.
    struct RadiantLook {
        float sparkle; float glowNear; float glowFar; float chroma; float hotFrom; float hotTo; float limit; float ease;
        float blend; float grain; float coreR; float coreG; float coreB; float palette;
    };

    // A smooth stand-in for the strongest channel: its 4-norm, so no crease or seam shows where one colour takes over
    // from another.
    float norm4(float3 c) {
        float3 c2 = c * c;
        return sqrt(sqrt(dot(c2, c2)));
    }

    fragment float4 radiantCompositeFragment(BodyRaster in [[stage_in]], texture2d<float> light [[texture(0)]],
                                             texture2d<float> glow [[texture(1)]], texture2d<float> wide [[texture(2)]],
                                             texture2d<float> sparks [[texture(3)]], texture3d<float> grain [[texture(4)]],
                                             constant BodyUniforms &s [[buffer(0)]],
                                             constant RadiantLook &look [[buffer(1)]], constant float *meter [[buffer(2)]],
                                             constant float &transitionAlpha [[buffer(3)]]) {
        constexpr sampler smooth(filter::linear, address::clamp_to_edge);
        constexpr sampler tiled(filter::linear, address::repeat);
        float2 uv = in.local / float2(s.viewportX, s.viewportY);
        float4 around = wide.sample(smooth, uv);
        float4 h = light.sample(smooth, uv) + (glow.sample(smooth, uv) * look.glowNear + around * look.glowFar) * s.spare;
        if (look.sparkle > 0.0) { h += sparks.sample(smooth, uv) * look.sparkle; }
        float3 c = h.rgb;
        float dense = meter[1] * s.gain;
        float gain = s.gain * (dense > look.limit ? pow(look.limit / dense, look.ease) : 1.0);
        if (look.palette < 0.5) {
            float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
            c = max(0.0, luma + (c - luma) * look.chroma);
            if (s.dark > 0.5) {
                float norm = norm4(c);
                float x = norm * gain;
                if (x < 0.0008) { return float4(0.0); }
                float hot = smoothstep(look.hotFrom, look.hotTo, x);
                float3 lit = mix(c / norm, float3(1.0), hot * hot) * (1.0 - exp(-x));
                float a = max(max(lit.r, lit.g), lit.b);
                if (a < 0.0008) { return float4(0.0); }
                return float4(lit / a, a * transitionAlpha);
            }
            float norm = max(norm4(c), 1e-5);
            float a = 1.0 - exp(-norm * gain * 0.8);
            if (a < 0.0008) { return float4(0.0); }
            return float4(min(1.0, c / norm * 0.78), min(0.94, a) * transitionAlpha);
        }
        // The level body's palette.
        float amount = norm4(c);
        if (amount * gain < 0.0008) { return float4(0.0); }
        float3 hue = c / amount;
        float spread = norm4(around.rgb);
        if (look.blend > 0.0 && spread > 1e-6) { hue = mix(hue, around.rgb / spread, look.blend); }
        hue /= max(0.05, max(max(hue.r, hue.g), hue.b));
        float luma = dot(hue, float3(0.2126, 0.7152, 0.0722));
        hue = saturate(luma + (hue - luma) * look.chroma);
        if (look.grain > 0.0 && s.grain > 0.5) {
            float2 g = (in.local - float2(s.originX, s.originY)) / max(1.0, s.scale);
            amount *= 1.0 + look.grain * (grain.sample(tiled, float3(g * 5.0, 0.37)).r - 0.5) * 2.0;
        }
        float3 core = float3(look.coreR, look.coreG, look.coreB);
        if (s.dark > 0.5) {
            float3 lit = 1.0 - exp(-hue / max(1e-5, norm4(hue)) * amount * gain);
            float a = min(1.0, norm4(lit));
            if (a < 0.0008) { return float4(0.0); }
            return float4(lit / a, a * transitionAlpha);
        }
        float a = 1.0 - exp(-amount * gain * 0.8);
        if (a < 0.0008) { return float4(0.0); }
        // Particles pack their light tighter than the body's gas, so their wash deepens toward ink later and less.
        float3 wash = mix(hue * 0.8, core, 0.2 * smoothstep(0.6, 1.0, a));
        return float4(wash, min(0.88, a) * transitionAlpha);
    }

    // Radiant body (`NebulaStyle.radiant`, build 101): Radiant's particles (`RadiantParticles`, where each band's
    // frequencies are heard) gathered into a volume and drawn as the level body draws its gas. Each frame every live
    // particle is added into two grids over the cube reaching `RadiantBody.reach` from around the listener
    // (`radiantSplatKernel`, trilinear, in 32-bit fixed point so the sum is exact whatever order the threads add in):
    // light and light × hue, faded by e^(−age/`fade`) as Radiant fades it. A particle's light is shared between a
    // fine grid, blurred by its birth size, and a coarse one, blurred by the size it reaches at the end of its life, in
    // proportion to how far its variance has grown from the one to the other (σ² = born² + `blur`·age, as Radiant's
    // smear grows), so new light is compact and older light swells into haze. Each grid is resolved and blurred with a
    // separable Gaussian (`radiantResolveKernel` along x out of the fixed-point sums, `radiantBlurKernel` along y, then
    // z). `radiantBodyFragment` then marches each ray front to back through both, as `bodyFragment` marches the body.
    struct VolumeSplat {
        float clock; float lifetime; float fade; float bornVariance; float blurRate; float coarseVariance;
        float ochreR; float ochreG; float ochreB; float reach; float fixedScale; float least;
        uint first; uint count; uint fineSize; uint coarseSize;
    };

    void splatInto(device atomic_uint *grid, uint n, float reach, float3 p, float4 value, float fixedScale) {
        float h = 2.0 * reach / float(n);
        float3 g = (p + reach) / h - 0.5;
        float3 base = floor(g);
        float3 f = g - base;
        int3 i0 = int3(base);
        for (int c = 0; c < 8; c++) {
            int3 o = int3(c & 1, (c >> 1) & 1, (c >> 2) & 1);
            int3 i = i0 + o;
            if (any(i < 0) || any(i >= int(n))) { continue; }
            float3 w3 = mix(1.0 - f, f, float3(o));
            float w = w3.x * w3.y * w3.z;
            if (w <= 0.0) { continue; }
            uint index = ((uint(i.z) * n + uint(i.y)) * n + uint(i.x)) * 4;
            float4 add = value * (w * fixedScale);
            atomic_fetch_add_explicit(&grid[index], uint(add.x + 0.5), memory_order_relaxed);
            atomic_fetch_add_explicit(&grid[index + 1], uint(add.y + 0.5), memory_order_relaxed);
            atomic_fetch_add_explicit(&grid[index + 2], uint(add.z + 0.5), memory_order_relaxed);
            atomic_fetch_add_explicit(&grid[index + 3], uint(add.w + 0.5), memory_order_relaxed);
        }
    }

    kernel void radiantSplatKernel(device const RadiantParticle *particles [[buffer(0)]], constant VolumeSplat &s [[buffer(1)]],
                                   device atomic_uint *fine [[buffer(2)]], device atomic_uint *coarse [[buffer(3)]],
                                   uint id [[thread_position_in_grid]]) {
        if (id >= s.count) { return; }
        RadiantParticle p = particles[s.first + id];
        float age = s.clock - p.position.w;
        if (age < -0.001 || age > s.lifetime || p.color.w <= 0.0) { return; }
        age = max(0.0, age);
        float light = p.color.w * exp(-age / max(0.005, s.fade));
        if (light < s.least) { return; }
        float3 hue = mix(p.color.rgb, float3(s.ochreR, s.ochreG, s.ochreB), 0.8 * smoothstep(0.25, 0.85, p.extra.x));
        float4 value = float4(hue * light, light);
        float older = saturate(s.blurRate * age / max(1e-9, s.coarseVariance - s.bornVariance));
        if (older < 0.999) { splatInto(fine, s.fineSize, s.reach, p.position.xyz, value * (1.0 - older), s.fixedScale); }
        if (older > 0.001) { splatInto(coarse, s.coarseSize, s.reach, p.position.xyz, value * older, s.fixedScale); }
    }

    struct VolumeBlur { uint size; uint firstRow; int radius; float sigma; float unit; uint axis; };

    float volumeWeight(int k, float sigma) { return exp(-0.5 * float(k * k) / max(1e-6, sigma * sigma)); }
    float volumeNorm(constant VolumeBlur &b) {
        float sum = 0.0;
        for (int k = -b.radius; k <= b.radius; k++) { sum += volumeWeight(k, b.sigma); }
        return 1.0 / sum;
    }

    // The fixed-point sums, blurred along x. Light leaving the cube is lost (the cube reaches past the speakers).
    kernel void radiantResolveKernel(device const uint *grid [[buffer(0)]], constant VolumeBlur &b [[buffer(1)]],
                                     texture3d<half, access::write> out [[texture(0)]], uint3 gid [[thread_position_in_grid]]) {
        uint n = b.size;
        uint3 v = uint3(gid.x, gid.y + b.firstRow, gid.z);
        if (v.x >= n || v.y >= n || v.z >= n) { return; }
        float4 sum = float4(0.0);
        for (int k = -b.radius; k <= b.radius; k++) {
            int x = int(v.x) + k;
            if (x < 0 || x >= int(n)) { continue; }
            uint index = ((v.z * n + v.y) * n + uint(x)) * 4;
            sum += float4(float(grid[index]), float(grid[index + 1]), float(grid[index + 2]), float(grid[index + 3]))
                * volumeWeight(k, b.sigma);
        }
        out.write(half4(sum * (volumeNorm(b) * b.unit)), v);
    }

    // One grid blurred along y (`axis` 1) or z (2).
    kernel void radiantBlurKernel(texture3d<half, access::read> in [[texture(0)]], texture3d<half, access::write> out [[texture(1)]],
                                  constant VolumeBlur &b [[buffer(0)]], uint3 gid [[thread_position_in_grid]]) {
        uint n = b.size;
        uint3 v = uint3(gid.x, gid.y + b.firstRow, gid.z);
        if (v.x >= n || v.y >= n || v.z >= n) { return; }
        int3 step = b.axis == 1 ? int3(0, 1, 0) : int3(0, 0, 1);
        float4 sum = float4(0.0);
        for (int k = -b.radius; k <= b.radius; k++) {
            int3 q = int3(v) + step * k;
            // Rows under the first are not worked on this frame: they hold nothing.
            if (any(q < 0) || any(q >= int(n)) || q.y < int(b.firstRow)) { continue; }
            sum += float4(in.read(uint3(q))) * volumeWeight(k, b.sigma);
        }
        out.write(half4(sum * volumeNorm(b)), v);
    }

    // The look of the Radiant body: `density` turns the grids' light per voxel into the gas' density; where it passes
    // from `edgeFrom` to `edgeTo` the body fills in, so it has a soft edge rather than a glow fading forever; inside,
    // `base` of glow plus its density, so loud places burn toward white; `absorb` dims what lies behind. It fades out
    // from `shellFrom` to the bound (the speakers' shell); on the light well its depth lays a wash `wash` deep. `glow` is
    // its light's gain on the dark well (lower under point lights, so they carry the brightest light).
    struct RadiantBodyLook {
        float reach; float density; float edgeFrom; float edgeTo; float base; float absorb; float chroma; float shellFrom;
        float wash; float glow;
    };

    fragment float4 radiantBodyFragment(BodyRaster in [[stage_in]], texture3d<float> fine [[texture(0)]],
                                        texture3d<float> coarse [[texture(1)]], texture3d<float> grain [[texture(2)]],
                                        constant BodyUniforms &s [[buffer(0)]], constant float4 *colors [[buffer(1)]],
                                        constant RadiantBodyLook &look [[buffer(2)]]) {
        constexpr sampler volume(filter::linear, address::clamp_to_zero);
        constexpr sampler tiled(filter::linear, address::repeat);
        float X = (in.local.x - s.originX) / s.scale;
        float Y = (s.originY - in.local.y) / s.scale;
        float rr = X * X + Y * Y;
        if (rr >= s.bound * s.bound || s.opacity <= 0.0) { return float4(0.0); }
        float chordHalf = sqrt(s.bound * s.bound - rr);
        float tNear = chordHalf, tFar = -chordHalf;
        if (s.lower < 0.5) {
            if (s.sinEl > 0.001) { tFar = max(tFar, -Y * s.cosEl / s.sinEl); } else if (Y < 0.0) { return float4(0.0); }
        }
        if (tNear <= tFar) { return float4(0.0); }
        float chord = tNear - tFar;
        int steps = clamp(int(ceil(chord / 0.028)), 4, 80);
        float dt = chord / float(steps);
        float jitter = fract(52.9829189 * fract(dot(in.position.xy, float2(0.06711056, 0.00583715))));
        float3 core = colors[\(SpatialBody.maxLayers)].rgb;
        float3 light = float3(0.0);
        float depth = 0.0, through = 1.0;
        for (int i = 0; i < steps && through > 0.02; i++) {
            float t = tNear - (float(i) + jitter) * dt;
            float3 q = float3(X, Y * s.cosEl + t * s.sinEl, Y * s.sinEl - t * s.cosEl);
            float3 p = float3(q.x * s.cosYaw - q.z * s.sinYaw, q.y, q.x * s.sinYaw + q.z * s.cosYaw);
            float3 uvw = (p + look.reach) / (2.0 * look.reach);
            // The body stays inside the speakers' shell, as the level body does: light blurred past it fades out there.
            float shell = 1.0 - smoothstep(look.shellFrom, s.bound, length(p));
            float4 v = (fine.sample(volume, uvw) + coarse.sample(volume, uvw)) * shell;
            float L = v.a * look.density;
            if (L < 0.0005) { continue; }
            float3 hue = v.rgb / max(v.a, 1e-12);
            hue /= max(0.05, max(max(hue.r, hue.g), hue.b));
            float luma = dot(hue, float3(0.2126, 0.7152, 0.0722));
            hue = saturate(luma + (hue - luma) * look.chroma);
            float fill = smoothstep(look.edgeFrom, look.edgeTo, L);
            float k = fill * look.base + L;
            float density = fill * 0.45 + L * 0.35;
            if (s.grain > 0.5) {
                float g = grain.sample(tiled, p * 1.9 + 0.5).r;
                float m = 0.72 + 0.56 * g;
                k *= m;
                density *= m;
            }
            float w = dt * through;
            light += hue * k * w;
            depth += density * w;
            through *= exp(-fill * dt * look.absorb);
        }
        float gain = s.opacity * 3.6 * look.glow;
        if (s.dark > 0.5) {
            float3 c = 1.0 - exp(-light * gain);
            float a = max(max(c.r, c.g), c.b);
            if (a < 0.0008) { return float4(0.0); }
            return float4(c / a, a);
        }
        float a = 1.0 - exp(-depth * gain * look.wash);
        if (a < 0.0008) { return float4(0.0); }
        float3 hue = light / max(1e-5, max(max(light.r, light.g), light.b));
        float3 c = mix(hue * 0.78, core, 0.28 * smoothstep(0.4, 1.0, a));
        return float4(c, min(0.94, a));
    }

    // The half-resolution body (`NebulaScene.encodeOffscreen`, premultiplied) laid into the canvas, straight alpha.
    fragment float4 bodyCompositeFragment(BodyRaster in [[stage_in]], texture2d<float> body [[texture(0)]],
                                          constant BodyUniforms &s [[buffer(0)]], constant float &transitionAlpha [[buffer(3)]]) {
        constexpr sampler smooth(filter::linear, address::clamp_to_edge);
        float4 c = body.sample(smooth, in.local / float2(s.viewportX, s.viewportY));
        if (c.a <= 0.0005) { return float4(0.0); }
        return float4(c.rgb / c.a, c.a * transitionAlpha);
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
        float floorDB; float rangeDB; float tilt; float floorOctave; float octaves; float linear;
    };

    constant int waterfallRows = \(SpectrogramHistory.rows);

    float waterfallTexel(texture2d<float, access::read> history, uint capacity, int slot, int row) {
        int wrapped = ((slot % int(capacity)) + int(capacity)) % int(capacity);
        return history.read(uint2(uint(wrapped), uint(clamp(row, 0, waterfallRows - 1)))).r;
    }

    // The fractional row (0 the bottom row's lower edge, waterfallRows the top's upper edge) at `fraction` up the axis:
    // the same on the log axis the rows are analysed on; on the linear one, the log position of that fraction's
    // frequency (`octaves` above 20 Hz at the top), the 0–20 Hz sliver below the first row reading it.
    float rowEdge(float fraction, float octaves, float linear) {
        if (linear == 0.0) { return fraction * float(waterfallRows); }
        float hz = max(fraction * 20.0 * exp2(octaves), 20.0);
        return log2(hz / 20.0) / octaves * float(waterfallRows);
    }

    // SpectrogramTone: linear over the range, a power curve for a dark floor, part of an S-curve for contrast.
    float toneOf(float db, float floorDB, float rangeDB) {
        float x = pow(saturate((db - floorDB) / rangeDB), \(SpectrogramTone.gamma));
        return mix(x, x * x * (3.0 - 2.0 * x), \(SpectrogramTone.contrast));
    }

    float waterfallTone(float db, constant WaterfallState &state) { return toneOf(db, state.floorDB, state.rangeDB); }

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
        float row = rowEdge(1.0 - uv.y, state.octaves, state.linear) - 0.5;
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

    // The 3D spectrogram (SpectrogramScene, `SpectrogramView.surface`): the same history as a height field, time across,
    // frequency into the distance, the tone as height, projected as `SurfaceProjection` does. The grid is `columns`
    // cells across and `strips` deep; strips are drawn farthest first, so nearer ridges cover farther ones.
    struct SurfaceState {
        uint head; uint capacity; float phase; float span;
        float floorDB; float rangeDB; float tilt; float floorOctave; float octaves;
        float left; float bottom; float width; float height; float viewportWidth; float viewportHeight;
        uint columns; uint strips; uint mirrored; float linear;
    };
    struct SurfaceRaster { float4 position [[position]]; float tone; float shade; float depth; };

    // The tone at grid point `i` across (0 the oldest column shown, `columns` now) and `j` deep (0 at 20 Hz, `strips`
    // at the top): the loudest tilted level of the rows the point stands for, in its column.
    float surfaceTone(texture2d<float, access::read> history, constant SurfaceState &s, int i, int j) {
        float age = (1.0 - float(i) / float(s.columns)) * s.span - s.phase;
        int column = clamp(int(round(age)), 0, int(s.capacity) - 1);
        // The rows half a strip either side of the point; on the linear axis a strip spans few rows in the treble and
        // many in the bass, so its edges come from `rowEdge`.
        float halfStrip = 0.5 / float(s.strips);
        float d = float(j) / float(s.strips);
        int first = int(floor(rowEdge(saturate(d - halfStrip), s.octaves, s.linear)));
        int last = max(first, int(ceil(rowEdge(saturate(d + halfStrip), s.octaves, s.linear))) - 1);
        float loudest = -1000.0;
        for (int row = max(0, first); row <= min(waterfallRows - 1, last); row++) {
            float level = waterfallTexel(history, s.capacity, int(s.head) - 1 - column, row);
            float octave = s.floorOctave + (float(row) + 0.5) / float(waterfallRows) * s.octaves;
            loudest = max(loudest, level + s.tilt * octave);
        }
        return toneOf(loudest, s.floorDB, s.rangeDB);
    }

    // `SurfaceProjection.point`: the front edge spans the plot's foot, the far edge recedes up and to the right.
    float2 surfacePoint(constant SurfaceState &s, float u, float d, float tone) {
        float scale = 1.0 - \(SurfaceProjection.narrowing) * d;
        return float2(s.left + \(SurfaceProjection.shift) * s.width * d + u * s.width * scale,
                      s.bottom - \(SurfaceProjection.depth) * s.height * d
                          - tone * \(SurfaceProjection.relief) * s.height * (0.75 + 0.25 * scale));
    }

    vertex SurfaceRaster surfaceVertex(uint id [[vertex_id]], texture2d<float, access::read> history [[texture(0)]],
                                       constant SurfaceState &s [[buffer(0)]]) {
        // Six corners per cell: two triangles between a nearer (y = 0) and a farther (y = 1) depth point.
        const uint2 corners[6] = { uint2(0, 0), uint2(0, 1), uint2(1, 1), uint2(0, 0), uint2(1, 1), uint2(1, 0) };
        uint cell = id / 6u;
        uint2 corner = corners[id % 6u];
        int i = int(cell % s.columns + corner.x);
        int j = int(s.strips - 1u - cell / s.columns + corner.y);
        float tone = surfaceTone(history, s, i, j);
        float t = float(i) / float(s.columns);
        float d = float(j) / float(s.strips);
        float2 p = surfacePoint(s, s.mirrored != 0u ? 1.0 - t : t, d, tone);
        // Lit from above the viewer: a face rising away from the viewer catches the light, one falling away is shaded,
        // so ridges read as shapes and not only as colour.
        float farther = surfaceTone(history, s, i, min(j + 1, int(s.strips)));
        float later = surfaceTone(history, s, min(i + 1, int(s.columns)), j);
        SurfaceRaster out;
        out.position = float4(p.x / s.viewportWidth * 2.0 - 1.0, 1.0 - p.y / s.viewportHeight * 2.0, 0.0, 1.0);
        out.tone = tone;
        out.shade = clamp(0.86 + 2.4 * (farther - tone) - 0.6 * abs(later - tone), 0.55, 1.12);
        out.depth = d;
        return out;
    }

    // Silence stays transparent, so the floor grid shows through where nothing sounds; the far distance hazes toward
    // the well, for depth.
    fragment float4 surfaceFragment(SurfaceRaster in [[stage_in]], constant float4 *ramp [[buffer(0)]]) {
        float3 color = mix(rampMap(in.tone, ramp) * in.shade, ramp[0].rgb, 0.30 * in.depth);
        return float4(color, smoothstep(0.0, 0.06, in.tone));
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
    struct ScopeState { uint newest; uint capacity; float phase; float span; float unused; float rangeDB; };
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

    // The envelope as measured: the lowest minimum and highest maximum of every column under the pixel, read over
    // at least one point (whatever the pixel density), so a peak is never averaged down or skipped between pixels.
    // The window's slight overlap between neighbouring pixels widens a one-column transient to a visible stroke
    // without changing its height.
    ScopeSample scopeSoft(texture2d<float, access::read> pyramid, constant ScopeState &state, float age, float footprint,
                          float columnsPerPoint, uint pair) {
        return scopeEnvelope(pyramid, state, age, max(footprint, columnsPerPoint), pair);
    }

    // The lane's vertical scale (`WaveScale.deflection`): linear, or decibels with the centre line at −rangeDB.
    // An over keeps its flag past full scale.
    float scaled(float v, float rangeDB) {
        if (rangeDB <= 0.0) { return v; }
        float a = abs(v);
        if (a > 1.001) { return sign(v) * 1.02; }
        float y = a > 0.0 ? saturate(1.0 + 20.0 * log10(a) / rangeDB) : 0.0;
        return sign(v) * y;
    }

    // One lane per quad. Envelopes are linear (min, max) per channel, two channels per texel, drawn on the lane's
    // scale; |v| > 1 flags a clip. shape = (half size, u, role); color = lane ink, alpha = lane visibility.
    // Graticule: the centre line, full scale at the lane's edges, the −6 / −12 / −24 dBFS levels where they stand
    // apart (the same marks `WaveScale.labelled` names), and a line at every whole second back from now.
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
        float lo = clamp(scaled(band.x, state.rangeDB), -1.0, 1.0) * laneHalf - 0.5;
        float hi = clamp(scaled(band.y, state.rangeDB), -1.0, 1.0) * laneHalf + 0.5;

        // Graticule in the interface ink. The trace edge leans toward the same ink (cream on dark, slate on
        // light), so it always stands out from its own fill; on light a denser body keeps the lane's hue. On dark the
        // lane's hue is lifted and the body denser, so the trace glows on the black plate instead of sinking into it.
        const float3 grid = \(Theme.inkRGB.metal);
        const float body = \(Theme.dark ? "0.36" : "0.38");
        const float edgeInk = \(Theme.dark ? "0.18" : "0.06");
        const float fadeFloor = \(Theme.dark ? "0.55" : "0.52");
        const float lift = \(Theme.dark ? "0.28" : "0.0");
        float3 hue = min(float3(1.0), in.color.rgb * (1.0 + lift) + lift * 0.18);
        float3 ink = clip ? \(Theme.emberRGB.metal) : hue;
        // Older columns fade like phosphor persistence; the newest sit at full strength.
        float persistence = mix(fadeFloor, 1.0, pow(u, 1.3));
        // No fill of its own: the lane is drawn straight on the panel, its extent set by the graticule's hairlines.
        float4 color = float4(grid, 0.0);
        color = over(color, grid, 0.12 * saturate(0.75 - abs(y)));
        // Full scale: a hairline just inside each edge of the lane.
        color = over(color, grid, 0.10 * saturate(0.75 - abs(abs(y) - (laneHalf - 1.0))) * saturate(laneHalf / 8.0 - 1.0));
        // Level marks, each drawn only while it stands at least 8 pt from the one above it.
        float previous = laneHalf;
        const float marks[3] = { -6.0, -12.0, -24.0 };
        for (uint m = 0; m < 3u; m++) {
            float at = scaled(pow(10.0, marks[m] / 20.0), state.rangeDB) * laneHalf;
            if (previous - at < 8.0 || at < 6.0) { continue; }
            color = over(color, grid, (m == 0u ? 0.06 : 0.04) * saturate(0.75 - abs(abs(y) - at)));
            previous = at;
        }
        // Whole seconds back from now, fixed on the ruler while the trace scrolls under them.
        float seconds = state.span / \(WaveformEnvelope.columnRate);
        float back = (1.0 - u) * seconds;
        float pointsPerSecond = 2.0 * halfSize.x / max(0.001, seconds);
        float fromSecond = abs(fract(back + 0.5) - 0.5) * pointsPerSecond;
        if (back > 0.5) { color = over(color, grid, 0.05 * saturate(0.75 - fromSecond)); }
        float coverage = saturate(min(y - lo, hi - y) + 0.5);
        float outside = max(max(lo - y, y - hi), 0.0);
        float edge = min(abs(y - lo), abs(y - hi));
        float depth = saturate(abs(y) / laneHalf);
        // Body fill, a one-pixel antialiasing skirt, then a crisp trace edge. No bloom: the edge carries it.
        color = over(color, ink, coverage * (body + 0.16 * depth) * persistence);
        color = over(color, ink, 0.12 * exp(-outside / 1.2) * (1.0 - coverage) * persistence);
        color = over(color, mix(ink, grid, edgeInk), saturate(1.0 - 0.9 * edge) * 0.95 * persistence);
        return float4(color.rgb, color.a * mask * in.color.a);
    }
    """ }
}
