# Refactoring log

One entry per batch, newest last. Each batch is one audit finding, behaviour-preserving, verified on its own.
Baseline and test procedure: [BASELINE_2026-10.md](BASELINE_2026-10.md). Findings: [CODE_AUDIT_2026-10.md](CODE_AUDIT_2026-10.md).

## Batch 3.1: one definition of the analysis frequency axis (audit P1-2, first part)

**Status:** done and verified (2026-10-24). Uncommitted in the maintenance worktree, on top of Build 119.

### Selection

| Candidate | Benefit | Risk | Tests available | Decision |
|---|---|---|---|---|
| P1-2 frequency axis | High: 35 copies in 12 files; Build 119 already had to thread a new scale through them; the exporter still lacks it | Medium in principle (DSP), low in practice: every copy is textually identical, and bit-exact golden digests now exist and were shown to catch a 1e-7 change | Golden digests, 61 core checks, Bridge equivalence, new bitwise helper test | **Chosen** |
| P1-6 `LaunchOptions` | Medium: 9 ad hoc flag checks | Low | App self-tests are manual | Next candidates |
| P2-3 settings keys | Medium: 14 keys duplicated as literals | Low | Needs a key-string test first | |
| P2-1 file splits | Medium | Low but large diffs over Build 119's files | Build only | Later, after Build 119 is committed |

### Scope

The analysis' log axis (20 Hz to min(20 kHz, Nyquist)) and its five recurring expressions, now defined once in
`AnalysisCore` as `LogFrequencyAxis`:

| Helper | Expression (unchanged, operation for operation) | Replaced copies |
|---|---|---|
| `upper(sampleRate:)` | `min(20_000, sampleRate / 2)` | 9 (8 in `AnalysisCore`; `MeterScale.upperFrequency` now delegates, so its 30-odd callers follow) |
| `frequency(atPosition:upper:)` | `20 * pow(upper / 20, position)` | 1 (`MeterScale.frequency(fraction:)`) |
| `centre(_:of:upper:)` | `20 * pow(upper / 20, (Double(index) + 0.5) / Double(count))` | 12 |
| `edge(_:of:upper:)` | `20 * pow(upper / 20, Double(index) / Double(count))` | 4 |
| `position(of:upper:)` | `log(frequency / 20) / log(upper / 20)` | 5 |
| `octaves(upper:)` | `log2(upper / 20)` | 4 |

Deliberately left alone: `ReassignedSpectrogram`'s row mapping (it multiplies by a precomputed `Float` scale, a
different rounding path), `DemoSignal`'s `20 * pow(1_000, x)` (a demo sweep, not the axis), and the build 119
linear-scale display code (it already goes through `MeterScale.frequencyFraction`).

### Must not change

Every analysis output bit for bit (golden digests), every drawn and reported frequency (each call site computes the
identical expression), plugin compatibility (the analysis library gains one file; no wire or layout change), stored
settings (none touched), localization (no strings).

### Changes

| File | Change |
|---|---|
| `Sources/AnalysisCore/LogFrequencyAxis.swift` | **New.** `package enum LogFrequencyAxis` with the six helpers above; the doc comment states the bit-exactness rule |
| `Sources/AnalysisCore/MultiFFTAnalyzer.swift`, `MultiFFTConfiguration.swift`, `ReassignedSpectrogram.swift`, `SpectrogramAnalyzer.swift`, `SpectrumAnalyzer.swift` | 13 inline copies → helpers (8 upper bounds, 2 centres, 2 edges, 1 octave span) |
| `Sources/Auraliscope/MeterScale.swift` | `upperFrequency`, `frequencyFraction` (log), `frequency(fraction:)` (log) and the smoothing kernels' axis → helpers |
| `Sources/Auraliscope/Panels.swift`, `MetalCanvas.swift`, `SpectrogramImage.swift` | Inspector, spectrum curve, tilt, 3D depth, waterfall octaves, exported image → helpers |
| `Sources/Auraliscope/ReportPages.swift`, `LoudnessReport.swift`, `MasteringAnalysis.swift` | Report plot, CSV spectrum, master check → helpers; each gains `import AnalysisCore` |
| `scripts/test.sh`, `Bridge/scripts/test-analysis.sh`, `Bridge/scripts/check-spatial.sh` | The new source file in their explicit lists (the plugins' `build-analysis-lib.sh` and `build-tools.sh` glob `Sources/AnalysisCore/*.swift`) |
| `Tests/AuraliscopeTests/BaselineChecks.swift` | `logFrequencyAxisMatchesLegacyExpressions`: every helper equals the expression it replaced, bit for bit, at 11 sample rates (8–384 kHz) and 6 band counts |

Net: 35 expression copies removed, one 45-line definition added. No call site's arithmetic changed: each helper
performs the same operations in the same order on the same operands (`lowest` is the same `Double` 20 as the
literal).

### Why it is more maintainable

- One place defines where the analysis puts frequencies. A future axis change (a lower bottom, a different ceiling)
  or a new consumer (the spectrogram export's linear scale, still open from Build 119) starts here instead of in a
  dozen files, and the display can no longer drift from the analysis.
- The call sites now say what they compute (`centre(row, of: rows, …)`, `edge(band + 1, …)`, `position(of: f, …)`)
  instead of repeating a formula a reader must decode.
- The bit-exactness rule is written down at the definition and enforced by a test, so the next agent cannot
  "simplify" `log(a)/log(b)` into `log2` without a failing check.

### Verification (all executed, 2026-10-24, arm64, Swift 6.4)

| Check | Command | Result |
|---|---|---|
| Helper ≡ legacy expressions | `scripts/test.sh` (BaselineChecks) | pass, before and after migrating the callers |
| Golden pipeline digests (5 scenarios, every snapshot group, Multi-FFT curves) | `scripts/test.sh` | **bit-identical** to the digests recorded on `a11b325` |
| 61 core checks, kernel checks, localization (924 keys) | `scripts/test.sh` | pass |
| Debug and release builds | `swift build`, `swift build -c release` | pass (the first attempt failed: three app files lacked `import AnalysisCore`, hidden by the single-module test build; fixed) |
| StreamAnalyzer ≡ desktop pipeline, breaks, RESULT | `Bridge/scripts/test-analysis.sh` | pass |
| Spatial reductions report | `Bridge/scripts/check-spatial.sh` | pass; **output byte-identical** (145 lines) to the same script on the unrefactored Build 119 checkout |
| Plugins' analysis library and transport | `Bridge/scripts/test-transport.sh` (rebuilds the library from the glob) | pass |
| App feature checks | `scripts/check-app-features.sh` | pass |
| File analysis and reports (EBU tones, surround weight, AAC, unreadable file) | `scripts/check-file-analysis.sh` | pass |
| UI | `--demo --snapshot --snapshot-inspect 420,60`, Log and Linear, before (Build 119 checkout) and after | hover readouts identical (A4 −38¢ · 431 Hz · −58.4 dBFS; C#9 −5¢ · 8.84 kHz · −80.6 dBFS), same keyboard, labels and harmonic marks; frames differ only by scroll timing |
| Diff review | `diff -u` against the Build 119 checkout | 38 lines out, 41 in, all mechanical; no unrelated edits |

Not run: ThreadSanitizer on the core checks (Phase 2 limitation, unchanged), plugin builds and DAW runs (no VST3 SDK),
performance measurement. The helpers are called during setup and at most a few times per display frame, never per
sample, so no measurable cost is expected; this was not benchmarked.

### Remaining risks

- A different toolchain could, in principle, compile the helper and the inline expression differently (for
  example contracting operations). The helper test runs on every `scripts/test.sh`, so such a change would fail
  loudly rather than drift.
- `ReassignedSpectrogram`'s row mapping and `DemoSignal` still compute log positions their own way, deliberately
  (see Scope).

### Conventions established

Frequencies on the analysis axis go through `LogFrequencyAxis`; do not write `20 * pow(upper / 20, …)`,
`log(f / 20) / log(upper / 20)` or `min(20_000, sampleRate / 2)` again. Proposed for `AGENTS.md` (audit §5.3).

### Recommended next batch

**P1-6, narrowed:** route the nine ad hoc `CommandLine.arguments` checks outside `Diagnostics.swift` (in
`MeterModel` — two of them on every display frame — `MetalCanvas`, `SettingsView`, `AuraliscopeApp`, `CaptureSelfTest`,
`BridgeSelfTest`) through named flags in the existing `Diagnostics` registry: no new type, flag names unchanged.
It is small, low-risk, removes test-only branches from the model's hot path, and prepares P1-3.

Separately, and before further refactoring of the capture path, schedule the **P0-1 fix** as its own bug-fix batch
(plan in [BASELINE_2026-10.md](BASELINE_2026-10.md), section 6).

