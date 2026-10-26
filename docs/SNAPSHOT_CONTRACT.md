# The meter snapshot

Every reading the app draws travels as one flat array of `Float`s: the **snapshot**. It is the contract between the
analysis (local or in a DAW plugin) and every canvas and readout, and it crosses the real-time boundary through a
lock-free C triple buffer, which is why it is a fixed-size float array rather than a Swift structure.

`METER_SNAPSHOT_FLOATS` = 49441 (`Sources/AudioRing/include/AudioRing.h`), equal to `SnapshotSlots.total`
(`Sources/AnalysisCore/MeterPipeline.swift`). `Tests/AuraliscopeTests/BaselineChecks.swift` checks that the groups
below tile the snapshot exactly and that this table matches the code.

## Who writes and reads it

| Step | Where |
|---|---|
| Layout (offsets) | `SnapshotSlots` in `Sources/AnalysisCore/MeterPipeline.swift` |
| Written by the local analysis, once per 60 Hz tick | `MeterPipeline.publish(into:now:)` (DSP queue, `DSPWorker`) |
| Written from a DAW plugin's results | `ResultAssembler` (`Sources/AnalysisCore/ResultAssembler.swift`) through `ResultInbox`/`ResultWorker`; the plugin's `StreamAnalyzer` encodes its own pipeline's snapshot as RESULT fields (`Sources/AnalysisCore/ResultProtocol.swift`) |
| Handed to the main thread | `MeterExchange` triple buffer (`Sources/AudioRing/AudioRing.c`); one producer, one consumer (the main thread) |
| Read into Swift | `DSPWorker.decode` (`Sources/Auraliscope/MeterModel.swift`) → `MeterSnapshot` (`Sources/AnalysisCore/SpectrumAnalyzer.swift`) |
| Drawn | the canvas scenes (`SpectrumScene`, `SpectrogramScene`, `WaveformScene`, `SoundstageScene`, `NebulaScene`) and `Readouts` |

## Layout

Offsets and sizes in floats. The RESULT column names the protocol fields a plugin sends for the group (tag numbers in
`ResultField`); "assembler" means `ResultAssembler` derives it.

| Group | Offset | Floats | Contents | RESULT |
|---|---|---|---|---|
| `spectrum` | 0 | 64 | dBFS per display band (L and R, or every channel in Immersive) | 40 |
| `peaks` | 64 | 16 | sample peak per role, newest 1/30 s (linear) | 20 |
| `rms` | 80 | 16 | RMS per role, newest 1/30 s (linear) | 21 |
| `truePeaks` | 96 | 16 | true peak per role, newest 1/30 s (linear) | 22 |
| `heldPeaks` | 112 | 16 | held sample peak per role since reset | 23 |
| `heldTruePeaks` | 128 | 16 | held true peak per role since reset | 24 |
| `scalars` | 144 | 12 | momentary, short-term, integrated LUFS, loudness range; sequence; stream; dominant peak (Hz, dBFS); detected format; waveform serial; L/R correlation; spectrogram serial | 30–33, 41, 43, 50; serials and stream: assembler |
| `spectrogram` | 156 | 512 | newest waterfall column, dBFS per row on the `LogFrequencyAxis` | 60–64 (columns) |
| `bandReadings` | 668 | 36 | per band group (5 bands, 3, overall): correlation, width, balance, level | 44–47 |
| `bandPoints` | 704 | 1280 | 5 stereo bands × 128 stereometer points (L, R) | 48 |
| `roleBandPower` | 1984 | 80 | 16 roles × 5 bands, mean square | 49 |
| `notes` | 2064 | 12 | up to six (Hz, dBFS) sounding notes; 0 Hz = none | 42 |
| `waveform` | 2076 | 2048 | 64 columns × 16 roles × (min, max) | 70–74 |
| `continuity` | 4124 | 2 | breaks counted, seconds known missing | 15, 16 |
| `spectrumFine` | 4126 | 128 | dBFS per fine band (each display band halved) | 51 |
| `spectrogramMode` | 4254 | 1 | analysis of the newest column (`SpectrogramMode`) | 65 |
| `spatialField` | 4255 | 4996 | spatial field: 4 header floats, 96 bands × (16 energies + 3 coherent components × 12) | 53 |
| `spatialPoints` | 9251 | 12385 | builds 87–97 bin form: status, 96 bands × (count + 32 × (x, y, z, energy)) | 54 |
| `signalHealth` | 21636 | 33 | DC offset per role, infrasonic mean square per role, status | 55–57 |
| `spatialObservations` | 21669 | 27772 | spatial observations: 28 header floats, 96 band counts, 3072 × 9 observation floats | 58 |

Counters that must stay exact in a `Float` wrap well below 2²⁴ on purpose: `sequence` and `spectrogramSerial` at
999,999 (pipeline and assembler), the stream identity at 999,999 (assembler) or 1,000,000 (`MeterModel`).
Hashes and revisions inside the spatial groups are split across several floats (`SpatialObservations.load(parts:)`).

## Changing it

One change touches all of these, in one commit:

1. `SnapshotSlots` (offsets) and the producer that writes the group (`MeterPipeline.publish`).
2. `METER_SNAPSHOT_FLOATS` and its comment in `AudioRing.h` (the runtime `precondition` in `DSPWorker` and
   `ResultWorker` stops a mismatch at launch).
3. `DSPWorker.decode` and the `MeterSnapshot` field.
4. `ResultAssembler` and, if a plugin should send it, a `ResultField` tag, `StreamAnalyzer`'s encoder and
   `Bridge/PROTOCOL.md`. Older plugins will not send a new tag: the assembler must leave a defined value (and the UI
   may say the plugin is older, as it does for the spatial groups).
5. `BaselineChecks.snapshotLayout` (sizes), this table, and, since the analysis output changes, a re-recorded golden
   fixture (`AURALISCOPE_RECORD_GOLDEN=1 scripts/test.sh`) with the reason in the commit.
