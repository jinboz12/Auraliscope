# Enhanced spectrogram: numerical study (Phase 4, batch D)

Question: the post-refactor review found that the Enhanced (reassigned) spectrogram gives different numbers under
different optimisation settings. Is that acceptable numerical variation, or incorrect behaviour? Scope: measure first,
change nothing unless a defect is established.

## Method

- Probe: `Tests/Probes/EnhancedNumerics.swift`, built with the same analysis sources as `scripts/test.sh`
  (`Tests/Probes/enhanced-numerics.sh <name> <swift flag> <C flags>`). It runs `ReassignedSpectrogram` (span 8192,
  48 kHz, 512 rows) over 60 consecutive columns at the display's 1/30 s hop, for five fixed signals: a 1 kHz sine,
  a 20 Hz–20 kHz sweep, clicks every 50 ms, seeded white noise, and a mixed signal. Each signal is 30,720 values.
- Comparison: `Tests/Probes/compare-numerics.py` (absolute error in dB: maximum, mean, RMS; where the worst cell is; how
  many cells differ by more than 0.01, 0.1, 0.5 and 1 dB; relative error in power where the reference is above the
  −120 dB floor).
- Variants: Swift `-O` or `-Onone`, C kernels `-O2` or `-O0`, and `-ffp-contract=off`.
- Repeatability: the same `-O` binary run twice gives bit-identical output for all five signals.

## Results (`output/phase4/batchD-compare-O-vs-Onone.txt`, `batchD-pairs.txt`)

| Signal | Max dB | Mean dB | RMS dB | Cells > 0.1 dB | Cells > 1 dB | Max relative power (above floor) |
|---|---|---|---|---|---|---|
| clicks | 0 | 0 | 0 | 0 | 0 | 0 |
| sine 1 kHz | 0.046 | 1.0e-4 | 1.8e-3 | 0 | 0 | 1.1e-2 |
| sweep | 0.85 | 1.1e-4 | 6.3e-3 | 7 | 0 | 0.18 |
| mixed | 4.36 | 1.6e-3 | 0.044 | 50 | 5 | 0.57 |
| noise | 40.9 | 2.3e-3 | 0.24 | 28 | 5 | 0.86 |

Out of 30,720 cells per signal, at most 5 differ by more than 1 dB (0.016 %); 3,425 of noise's cells are at the floor in
both builds. The largest errors are in cells at the floor: one build holds exactly −120 dB, the other a small positive
value (for example −120 against −79 dB in noise, column 0). The relative power error is large only in those weak cells.

Pairs that isolate the cause (all bit-identical, so these settings are not the cause):
- `-O` with C `-O2` or `-O0`; `-O` with or without `-ffp-contract=off`; the same three with `-Onone`.
- So the C kernels and floating-point contraction make no difference. Only the Swift optimisation level does.

## Cause

`ReassignedSpectrogram.Zone.init` fills the Hann window and its slope in one loop:
`window[i] = 0.5 − 0.5·cos(φ)` and `slopeWindow[i] = π/N·sin(φ)`, with `φ = 2π·i/N`.

- At `-O`, LLVM fuses the `sin` and `cos` of the same argument into one `sincosf` call. Its results differ from separate
  `cosf` and `sinf` calls in the last bit for some `i`.
- Experiment, in a scratch copy (`output/phase4/batchD-split-vs-Onone.txt`): the same loop split in two, so the `cos` and
  `sin` are separate calls. The `-O` output is then bit-identical to `-Onone` for all five signals (30,720 of 30,720
  cells each, zero error).
- The same effect appears in the sanitiser build: `-O -sanitize=address` gives Enhanced output bit-identical to `-Onone`
  (all five signals, zero error; `output/phase4/batchD-asan-vs-Onone.txt`), and it reports no AddressSanitizer errors.
  That is why `scripts/test.sh address` fails the Enhanced golden digest, which is an optimised-build value (R2).
- The window values differ by at most one unit in the last place, and both builds sit within 2.4e-7 of a double-precision
  reference: both are accurate, they just round differently.

The 1-ulp window difference reaches the output through the reassignment's bin decisions and the floor test
(`energy[row] > 0 ? … : −120`): a weak deposit that lands in a row in one build can be absent in the other.

## Decision

- **Acceptable numerical variation, not incorrect behaviour.** The disagreement is at the last bit of the window
  coefficients. Its effect is confined to a handful of weak, floor-level cells per signal (≤ 0.02 %), and the optimised build
  (the release app) is stable across runs.
- **No change to the algorithm or to the golden digests.** Changing the window computation would change the `-O` output
  everywhere, so the golden fixture would have to be re-recorded with a reason; no defect justifies that. The optimised
  golden values stay as they are.
- **Test contract.** The golden digests are for optimised (`-O`) builds. A bitwise digest is not a contract across builds
  (debug, `-Onone`, sanitiser builds), so the Enhanced digest mismatch under `scripts/test.sh address` is expected. Checks
  across builds should use a tolerance instead: for example, mean error ≤ 0.01 dB and at most 0.1 % of cells more than
  1 dB apart, with floor cells (both at −120 dB) excluded. The numbers above satisfy this with a margin (mean ≤ 2.3e-3 dB;
  at most 5 of 30,720 cells above 1 dB).

## Not done (options, not required)

- Compute the sine and cosine in separate loops in the production code. This makes `-O` and `-Onone` agree bit for bit
  and costs one extra pass over 8192 samples at init. It changes the optimised output, so it needs a golden re-record and
  a reason in the commit; left for a decision.
- Replace the `energy > 0` floor test with a relative threshold, so a weak deposit cannot flip a cell by 40 dB. This is a
  visual robustness choice, not a defect; left for a decision.

## Limits

- arm64, Swift 6.x toolchain on this Mac, Accelerate vDSP. Other hardware may round differently.
- Measured on the analysis only, not on rendered pixels; the 1 dB threshold is a stated tolerance, not a visual test.
