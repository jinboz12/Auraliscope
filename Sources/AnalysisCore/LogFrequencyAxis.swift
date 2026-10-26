import Foundation

/// The analysis' frequency axis: 20 Hz to 20 kHz (to Nyquist below a 40 kHz sample rate), logarithmic. Every
/// spectrum band, spectrogram row and Multi-FFT point is placed on it, and the panels, the exported image and the
/// reports draw and name frequencies on it, so it is defined once here.
///
/// Each function is the exact expression its callers used to write out, operation for operation, so moving a caller
/// onto it changes no result by a single bit (`BaselineChecks` pins the analysis output; `CoreTests` pins each
/// function against the expression it replaced). Keep it that way: a different but equivalent formula (`log2` for
/// `log`, a precomputed scale) rounds differently.
package enum LogFrequencyAxis {
    /// The bottom of the axis, in Hz.
    package static let lowest = 20.0

    /// The top of the axis at `sampleRate`: 20 kHz, or Nyquist below 40 kHz.
    package static func upper(sampleRate: Double) -> Double { min(20_000, sampleRate / 2) }

    /// The frequency at `position` along the axis (0 at 20 Hz, 1 at `upper`).
    package static func frequency(atPosition position: Double, upper: Double) -> Double {
        lowest * pow(upper / lowest, position)
    }

    /// The centre of band `index` of `count` bands of equal width (in octaves) from 20 Hz to `upper`.
    package static func centre(_ index: Int, of count: Int, upper: Double) -> Double {
        lowest * pow(upper / lowest, (Double(index) + 0.5) / Double(count))
    }

    /// The lower edge of band `index` of `count` (the upper edge of band `index − 1`); `count` gives `upper`.
    package static func edge(_ index: Int, of count: Int, upper: Double) -> Double {
        lowest * pow(upper / lowest, Double(index) / Double(count))
    }

    /// Where `frequency` lies along the axis: 0 at 20 Hz, 1 at `upper`, beyond either end outside them.
    package static func position(of frequency: Double, upper: Double) -> Double {
        log(frequency / lowest) / log(upper / lowest)
    }

    /// Octaves from 20 Hz to `upper`.
    package static func octaves(upper: Double) -> Double { log2(upper / lowest) }
}
