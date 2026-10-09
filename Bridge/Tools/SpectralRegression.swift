// Compile with Sources/AnalysisCore/*.swift, AnalysisKernels.o and its include directory.
// Writes deterministic raw spectrum/spectrogram measurements for comparisons between builds.
import Foundation
import AnalysisKernels

@main struct SpectralRegression {
    static func main() throws {
        let destination = CommandLine.arguments[1]
        var output: [Float] = []
        var worstTone: Float = 0
        var columns = 0
        for rate in [44_100.0, 48_000, 96_000, 192_000] {
            let hop = Int((rate / 30).rounded())
            for kind in 0..<5 {
                for phase in [0.0, Double.pi / 2, Double.pi] {
                    let analyzer = SpectrumAnalyzer(sampleRate: rate)!
                    var samples = [StereoFrame](repeating: StereoFrame(left: 0, right: 0), count: hop)
                    var sweepPhase = 0.0
                    for column in 0..<60 {
                        for sample in 0..<hop {
                            let index = column * hop + sample, t = Double(index) / rate
                            let value: Double
                            switch kind {
                            case 0: value = 0.25 * sin(2 * .pi * 1000 * t + phase)
                            case 1: value = 0.125 * (sin(2 * .pi * 1000 * t) + sin(2 * .pi * 1060 * t + phase))
                            case 2: value = index % (hop * 7) == Int(phase / .pi * Double(hop / 2)) ? 0.8 : 0
                            case 3:
                                let frequency = 30 * pow(18000 / 30, t / 2)
                                sweepPhase += 2 * .pi * frequency / rate
                                value = 0.25 * sin(sweepPhase)
                            default:
                                // Tones straddling each resolution transition. Level stays safely below clipping.
                                value = [750.0, 1500, 3000, 6000, 12000].reduce(0) {
                                    $0 + 0.04 * sin(2 * .pi * $1 * t + phase)
                                }
                            }
                            samples[sample] = StereoFrame(left: Float(value), right: Float(value))
                        }
                        samples.withUnsafeBufferPointer { analyzer.consume($0) }
                        let snapshot = analyzer.snapshot()
                        if column >= 10 && kind == 0 {
                            worstTone = max(worstTone, abs(snapshot.peakLevel - Float(20 * log10(0.25))))
                        }
                        output.append(snapshot.peakFrequency); output.append(snapshot.peakLevel)
                        output.append(contentsOf: snapshot.spectrum); output.append(contentsOf: snapshot.spectrogram)
                        columns += 1
                    }
                }
            }
        }
        let data = output.withUnsafeBytes { Data($0) }
        try data.write(to: URL(fileURLWithPath: destination))
        print("\(columns) columns; \(output.count) float measurements; worst steady 1 kHz tone level error \(worstTone) dB")
    }
}
