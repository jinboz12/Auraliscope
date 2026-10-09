// Run from the repository root: swiftc -module-cache-path /tmp/abr-metal-modules
// Bridge/Tools/CheckSpectrogramRendering.swift -o /tmp/abr-render-check && /tmp/abr-render-check
// Tests the actual Metal source extracted from MetalCanvas, not a second implementation of its reduction.
import Foundation
import Metal

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sources/Auraliscope/MetalCanvas.swift"
let source = try String(contentsOfFile: path, encoding: .utf8)
func section(_ begin: String, _ end: String) -> String {
    let a = source.range(of: begin)!.lowerBound
    let b = source.range(of: end, range: a..<source.endIndex)!.lowerBound
    return String(source[a..<b])
}
let structures = section("    struct WaterfallState", "    // SpectrogramTone")
    .replacingOccurrences(of: "\\(SpectrogramHistory.rows)", with: "512")
let axes = section("    struct WaterfallAxis", "    // The loudest tilted level")
let reduction = section("    float waterfallBlock", "    // local: pixels")
let shader = """
#include <metal_stdlib>
using namespace metal;
\(structures)
constant float waterfallEdge = 0.3; // only used by the optional build-69 baseline
\(axes)
\(reduction)
kernel void ranges(constant float2 *input [[buffer(0)]], device int2 *output [[buffer(1)]],
                   uint i [[thread_position_in_grid]]) {
    WaterfallAxis axis = waterfallAxis(input[i].x, input[i].y);
    output[i] = int2(axis.first[0], axis.last[0]);
}
kernel void edges(constant float2 *input [[buffer(0)]], device float *output [[buffer(1)]],
                  uint i [[thread_position_in_grid]]) {
    WaterfallAxis axis = waterfallAxis(input[i].x, input[i].y);
    output[i] = axis.weight[1];
}
kernel void check(texture2d<float, access::read> history [[texture(0)]],
                  constant WaterfallState &state [[buffer(0)]],
                  constant int4 *blocks [[buffer(1)]], device float *output [[buffer(2)]],
                  uint i [[thread_position_in_grid]]) {
    int4 b = blocks[i];
    output[i] = waterfallBlock(history, state, b.x, b.y, b.z, b.w);
}
"""
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    fatalError("Metal device unavailable")
}
let library = try device.makeLibrary(source: shader, options: nil)
let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "check")!)
let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 512, height: 512, mipmapped: false)
descriptor.storageMode = .shared
let texture = device.makeTexture(descriptor: descriptor)!
// Texture x is the ring slot, y is frequency. Test ring wrapping, clipped borders, wide footprints,
// and an isolated peak at every possible position (including positions skipped by six-tap sampling).
var pixels = [Float](repeating: -100, count: 512 * 512)
for row in 0..<512 {
    pixels[row * 512 + ((row * 73 + 19) % 512)] = -12
}
texture.replace(region: MTLRegionMake2D(0, 0, 512, 512), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: 512 * 4)
struct State {
    var head: UInt32 = 17, capacity: UInt32 = 512
    var phase: Float = 0, span: Float = 450
    var floor: Float = -90, range: Float = 78, tilt: Float = 0
    var floorOctave: Float = -5.643856, octaves: Float = 9.965784
}
var blocks: [SIMD4<Int32>] = []
for row in 0..<512 {
    let slot = (row * 73 + 19) % 512
    let age = (16 - slot + 512) % 512
    for width in [1, 3, 7, 13, 32] {
        blocks.append(SIMD4(Int32(age - width / 2), Int32(age + width / 2), Int32(row - width / 2), Int32(row + width / 2)))
    }
}
let input = device.makeBuffer(bytes: blocks, length: MemoryLayout<SIMD4<Int32>>.stride * blocks.count, options: .storageModeShared)!
let output = device.makeBuffer(length: blocks.count * 4, options: .storageModeShared)!
var errors = 0
for tilt: Float in [0, 3, 4.5] {
    var state = State(); state.tilt = tilt
    let command = queue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(texture, index: 0)
    encoder.setBytes(&state, length: MemoryLayout<State>.stride, index: 0)
    encoder.setBuffer(input, offset: 0, index: 1)
    encoder.setBuffer(output, offset: 0, index: 2)
    encoder.dispatchThreads(MTLSize(width: blocks.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    if let error = command.error { throw error }
    let values = output.contents().assumingMemoryBound(to: Float.self)
    for (i, b) in blocks.enumerated() {
        var expected: Float = -1000
        func clip(_ x: Int32) -> Int { max(0, min(511, Int(x))) }
        for age in clip(b.x)...clip(b.y) {
            for row in clip(b.z)...clip(b.w) {
                let slot = (16 - age + 512) % 512
                let octave = state.floorOctave + (Float(row) + 0.5) / 512 * state.octaves
                expected = max(expected, pixels[row * 512 + slot] + tilt * octave)
            }
        }
        if abs(values[i] - expected) > 0.0001 { errors += 1 }
    }
    print("tilt \(tilt): \(blocks.count) GPU footprint comparisons; GPU \(String(format: "%.3f", (command.gpuEndTime - command.gpuStartTime) * 1000)) ms")
}
let edgePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "edges")!)
var edgeInputs: [SIMD2<Float>] = []
for footprint: Float in [0.05, 0.1, 0.25, 0.5, 1] {
    for step in 0...100 { edgeInputs.append(SIMD2(Float(step) / 100, footprint)) }
}
let edgeBuffer = device.makeBuffer(bytes: edgeInputs, length: edgeInputs.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)!
let edgeOutput = device.makeBuffer(length: edgeInputs.count * 4, options: .storageModeShared)!
let edgeCommand = queue.makeCommandBuffer()!, edgeEncoder = edgeCommand.makeComputeCommandEncoder()!
edgeEncoder.setComputePipelineState(edgePipeline)
edgeEncoder.setBuffer(edgeBuffer, offset: 0, index: 0); edgeEncoder.setBuffer(edgeOutput, offset: 0, index: 1)
edgeEncoder.dispatchThreads(MTLSize(width: edgeInputs.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
edgeEncoder.endEncoding(); edgeCommand.commit(); edgeCommand.waitUntilCompleted()
if let error = edgeCommand.error { throw error }
let edgeValues = edgeOutput.contents().assumingMemoryBound(to: Float.self)
for (i, input) in edgeInputs.enumerated() {
    let expected = max(0, min(1, (input.x - floor(input.x) - 0.5) / input.y + 0.5))
    if abs(edgeValues[i] - expected) > 0.0001 { errors += 1 }
}
print("505 GPU edge comparisons at 1–20 device pixels per cell")
let rangePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "ranges")!)
var rangeInputs: [SIMD2<Float>] = []
for footprint: Float in [2, 4, 8, 16] {
    for step in -40...40 { rangeInputs.append(SIMD2(Float(step) / 4, footprint)) }
}
let rangeBuffer = device.makeBuffer(bytes: rangeInputs, length: rangeInputs.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)!
let rangeOutput = device.makeBuffer(length: rangeInputs.count * MemoryLayout<SIMD2<Int32>>.stride, options: .storageModeShared)!
let rangeCommand = queue.makeCommandBuffer()!, rangeEncoder = rangeCommand.makeComputeCommandEncoder()!
rangeEncoder.setComputePipelineState(rangePipeline)
rangeEncoder.setBuffer(rangeBuffer, offset: 0, index: 0); rangeEncoder.setBuffer(rangeOutput, offset: 0, index: 1)
rangeEncoder.dispatchThreads(MTLSize(width: rangeInputs.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
rangeEncoder.endEncoding(); rangeCommand.commit(); rangeCommand.waitUntilCompleted()
if let error = rangeCommand.error { throw error }
let rangeValues = rangeOutput.contents().assumingMemoryBound(to: SIMD2<Int32>.self)
for (i, input) in rangeInputs.enumerated() {
    let first = Int32(floor(input.x - input.y / 2 + 0.5))
    let last = Int32(ceil(input.x + input.y / 2 + 0.5)) - 1
    if rangeValues[i] != SIMD2(first, last) { errors += 1 }
}
print("324 GPU minification bounds comparisons; zero-area boundary contacts excluded")
guard errors == 0 else { print("FAIL: \(errors) footprint mismatches"); exit(1) }
print("PASS: 8509 GPU/CPU comparisons, isolated peaks, ring wrap, borders, tilt and one-pixel antialiasing")
