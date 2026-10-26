// Writes the Enhanced (reassigned) spectrogram's columns for fixed test signals, one Float32 file per signal, so builds
// with different optimisation settings can be compared value by value. Run through Tests/Probes/enhanced-numerics.sh.
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: EnhancedNumerics <output directory>\n", stderr)
    exit(2)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

let sampleRate = 48_000.0
let span = SpectrumAnalyzer.fftSize
let hop = 1_600                       // one column per 1/30 s, as the display does
let columns = 60
let length = span + hop * columns
let rows = MeterSnapshot.spectrogramBandCount

// Deterministic noise: a 64-bit LCG, the same on every build.
var state: UInt64 = 0x9E37_79B9_7F4A_7C15
func noise() -> Float {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Float(state >> 40) / Float(1 << 24) * 2 - 1
}

func sine1k(_ index: Int) -> Float {
    let phase: Double = 2 * Double.pi * 1_000 * Double(index) / sampleRate
    return 0.1 * Float(sin(phase))
}

func sweep(_ index: Int) -> Float {
    let t: Double = Double(index) / sampleRate
    let duration: Double = Double(length) / sampleRate
    let phase: Double = 2 * Double.pi * (20 * t + (20_000 - 20) * t * t / (2 * duration))
    return 0.1 * Float(sin(phase))
}

func clicks(_ index: Int) -> Float {
    return index % 2_400 == 0 ? 0.5 : 0
}

func noiseSignal(_ index: Int) -> Float {
    return 0.05 * noise()
}

func mixed(_ index: Int) -> Float {
    let phase: Double = 2 * Double.pi * 440 * Double(index) / sampleRate
    let tone: Float = 0.08 * Float(sin(phase))
    let click: Float = index % 4_800 == 1_200 ? 0.4 : 0
    return tone + click + 0.01 * noise()
}

let signals: [(name: String, sample: (Int) -> Float)] = [
    ("sine1k", sine1k), ("sweep", sweep), ("clicks", clicks), ("noise", noiseSignal), ("mixed", mixed),
]

guard let analyzer = ReassignedSpectrogram(sampleRate: sampleRate, span: span) else {
    fputs("no reassigned spectrogram\n", stderr)
    exit(1)
}
print("rows \(rows) span \(span) columns \(columns) hop \(hop)")
for signal in signals {
    let samples = (0..<length).map(signal.sample)
    var output = [Float](repeating: 0, count: columns * rows)
    samples.withUnsafeBufferPointer { history in
        output.withUnsafeMutableBufferPointer { destination in
            for column in 0..<columns {
                // The ring holds the span's samples oldest first, so its cursor is 0.
                analyzer.column(rings: history.baseAddress! + column * hop, cursor: 0, roles: [0],
                                into: destination.baseAddress! + column * rows)
            }
        }
    }
    let data = output.withUnsafeBufferPointer { Data(buffer: $0) }
    try data.write(to: directory.appendingPathComponent("\(signal.name).f32"))
    print("wrote \(signal.name) \(output.count) values")
}
