# Auraliscope Bridge / Auraliscope LABS 1.3dev: validation report

## Build 63 (early test package)

Build 63 is build 3's analysis and protocol, unchanged, with these changes (the rest of this report is build 3's):

- **Source type** in Settings ▸ Audio: *Audio devices* (inputs and outputs, analysed in the app) or *Host plugins*
  (Bridge inserts; one connected is chosen, several wait for a choice). The last device is remembered.
- The app is named **Auraliscope LABS** (bundle, menus, window title, wordmark); **Prototype experiment only** at the
  foot of the main window and the plugin window (plugin window 582 pt tall).
- The plugin's Open button launches the newest registered copy of LABS, preferring one in an Applications folder.
  Before, Launch Services picked an old build 3 copy from a dist folder with the same bundle ID; this was found in the
  leak check below.
- Plugin bundle and AU versions are 0.63 / 0.63.0, below any official release; the installer
  (`package-installer.sh`) installs app and plugins system-wide, not relocatable, without downgrading a newer plugin.

| Check (build 63 binaries) | Result |
|---|---|
| Transport tests, analysis checks, release core checks (42), localization (340 keys) | all pass |
| Steinberg validator `-e`; `auval -strict` | **537 passed, 0 failed**; **AU VALIDATION SUCCEEDED** |
| Test host, 11 app scenarios (`e2e-app.sh`) | 11/11 |
| REAPER 7.80, both formats (`e2e-reaper.sh`): live, reference, controls, offline render, identity, reopen | all pass |
| Leaks, plugins: 10 cycles × 4 instances (load, live, bypass, offline, idle, 96 kHz, mono, editor open/close, unload), `leaks --atExit` with malloc stack logging, VST3 and AU | **0 leaks**; after each unload the process holds 89–115 MB (stack logging included), 6–9 threads, 6 open files, with no growth over the 10 cycles; output identical to input |
| Leaks, app: LABS showing a plugin (launched by its button) for 150 s through bypass and a stereo → mono change | **0 leaks**; footprint 150 MB at 30 s and 149 MB at 140 s |
| Installer | payload identical to the dist bundles, signatures valid, nothing relocatable; `installer -pkginfo/-dominfo` read it; installing needs an administrator, so the actual installation was not run here |

In the app leak check, "not responding" appeared for 0.14 s: `leaks` suspends the process it inspects, so this is
expected. Only REAPER was rerun for build 63; the Logic and Cubase results below are build 3's.

## Build 3

Build: Auraliscope Labs 1.3dev build 3 with Auraliscope Bridge 1.3dev build 3 (VST3 and AUv2), protocol version 3,
analysis schema 1, branch `claude/bridge-plugin-analysis` (from the build 2 prototype `7f7e733`; application baseline
Auraliscope 1.2.2, `10e35cd`). Mac: Apple M1 Max, macOS 27.2, Xcode 27.0 (Swift 6.4). Logs in
`.build/bridge/validation/` (not committed).

Test signal throughout: L = 997 Hz at 0.5 (−6.021 dBFS), R = 1499 Hz at 0.25 (−12.041 dBFS); stereo integrated
loudness −7.76 LUFS, mono (L) −9.03 LUFS. A swapped, duplicated or scaled channel cannot pass.

Evidence is kept apart by kind: **automated** (unit and transport tests, official validators), **test host** (the real
plugin binaries in `Bridge/Tools/HostHarness`, not a DAW), **DAW runtime** (REAPER 7.80 scripted; Logic Pro 12.4 and
Cubase 15.0.30 driven through their user interface). Timing figures are measurements on this Mac; the guarantees are
structural and listed separately.

### Summary

| Requirement | Evidence | Result |
|---|---|---|
| Both formats build and pass the validators | Steinberg validator `-e`; `auval -strict` | **537 passed, 0 failed**; **AU VALIDATION SUCCEEDED** |
| Plugin output identical to input | test host compares every output block; REAPER, Logic and Cubase offline renders against the source | identical in every run; renders equal the source (Logic: outside its own printed clicks) |
| Plugin measurements match the desktop analyser | unit test on identical audio; Labs `--compare-reference` in the test host, Logic and Cubase; `ResultProbe` | mono **bit-identical**; stereo identical except correlation rounding (≤ 2.2·10⁻¹⁰); in DAWs every value within 0.002 LU / 0.02 dB / 0.001 dB spectrum |
| Mono/stereo order, rates, levels, timeline | transport tests, 12 test-host cases (44.1–192 kHz, mono, stereo, blocks 64–4096) | pass |
| Visualisation panels get what they need | RESULT carries every snapshot field the canvases read; e2e checks ordered columns, no gaps | pass |
| Labs consumes results, analyses nothing | every self-test checks `showingBridgeResults`; no pipeline exists for a Bridge source | pass |
| Analysis continues with editors closed and Labs absent | transport tests; `before-labs` scenario (5 s before launch); Cubase (16 s measured before Labs connected); Labs away and back | pass |
| Reconnection reports a coherent state | transport "Labs away and back"; app `hold`, `held` | same generation, measurement continued, integrated unchanged |
| Controls on the intended instance, acknowledged | transport (incl. wrong session, obsolete generation), app `controls`, Logic, Cubase | pass |
| Overflow and a slow display stay bounded; the audio thread never waits | transport "Slow receiver" (3 s), "Analysis falling behind" (3.5 s) | pass; worst `process()` 7–46 µs |
| CPU and memory measured | `measure-resources.sh` against build 2 | table below |
| Desktop sources unchanged | release core checks; analysis moved without change | **42/42** |

### Automated

| Check | Result |
|---|---|
| Release core checks (`scripts/test.sh`: analysers, pipeline, scales, displays) | **42/42**, localization **333 keys** (en, zh-Hans, ko) |
| Analysis checks (`test-analysis.sh`) | **86/86**: build 2's 47 (break marks, analysers at breaks, restoration) plus plugin-side analysis: equivalence with the desktop pipeline at 48/44.1/96 kHz in irregular blocks, RESULT encoding (round trip, unknown / malformed / wrong-kind fields, schema, channel counts), display assembly (order, gaps, pacing, bounded queues, generations, mono), measurement lifecycle (pause, breaks, idle ticks), streams starting mid-waveform |
| Transport tests (`test-transport.sh`) | **94/94**, also under ThreadSanitizer (C and C++ instrumented; the Swift core is linked uninstrumented) |
| Link feasibility (`probe-analysis-link.sh`) | the VST3 and AU analysis libraries loaded and run together in one process: no Objective-C class clash; 0.42 % of a core per 48 kHz stereo stream (0.81 % at 192 kHz) in a tight loop |
| Steinberg VST3 validator `-e` | **537 passed, 0 failed** |
| `auval -v` and `auval -strict -v aufx Abrg Jnbz` | **AU VALIDATION SUCCEEDED** (both) |

The transport tests cover, with the real plugin core, analysis thread and receiver: 1,600 instances created and
destroyed on 8 threads (no deadlock; both threads stop with the last instance); discovery and HELLO fields; the insert
measuring before anyone subscribes (nothing sent; −6.021 / −12.041 dBFS, −7.76 LUFS); results to a subscriber (60 per
second, first result covering the audio measured before, columns in order, about 2 s of history for a new subscriber,
the unselected instance silent); mono; a 3 s receiver stall (nothing unanalysed, a few queued results then current
state within 13 ms of the audio, every skipped column reported); the analysis starved for 3.5 s (overflow counted, a
drop break with the time missing, integrated carried on, output untouched); a format change (new generation, no
mixed results); bypass and offline (nothing measured, one break each, integrated carried on); commands (pause,
resume without a break, reset true peak, reset to a new generation, obsolete generation refused, wrong session
refused, a display's pause lifted when its connection goes, the plugin window's pause kept); identity (copies,
restoration, saved state holds no live measurement); reactivation (restart break), a 120 ms stall (not a break), a
1 s stall (idle break, results fall to silence meanwhile), a timeline jump (counted, not a break); stale results
after a quick re-selection (never replayed); Labs away for 1.5 s and back (measured on, same generation); 8 more
inserts in real time; protocol versions 1 and 2 on either side; DNS-SD discovery.

### Test host (real binaries, no DAW)

`e2e-probe.sh` (`ResultProbe`, which checks each result against Auraliscope's own analysis of the signal): **12/12**:
VST3 48 kHz stereo, 44.1 kHz mono, 96 kHz stereo; AU 48 kHz stereo, 48 kHz mono, 192 kHz stereo; three instances of
each format (the 2nd or 3rd checked); subscribing 3 s after the insert started; controls (AU); plugin window opened
and closed (both formats). Output identical to input; results at 60 per second; peaks, true peaks, momentary and
integrated loudness, dominant frequency and spectrum equal the reference (spectrum within 0.001 dB); columns in
order; nothing unanalysed.

`e2e-app.sh` (Labs' own `--bridge-selftest`): **11/11**: reconnection of the same insert under a new session (with
the reference comparison), AU mono (with comparison), three instances, a rate change to 96 kHz mid-stream (new
generation), the five states (streaming, bypassed, offline, no audio, streaming; integrated carried across), Labs
quit and relaunched during playback, a duplicated insert (ambiguous until chosen), the same insert re-identifying
(same generation, measurement continued), the connection dropped (display held; plugin measured on: 3.2 s → 5.9 s),
controls from Labs (pause holds 3.25 s → 3.25 s; reset starts generation 2), and an insert measuring 5 s before Labs
was launched (the first results cover it; comparison within 0.002 LU).

### DAW runtime

#### Host compatibility matrix (build 3)

| Host (format) | Loads, names | Live results = reference | Controls from Labs | Stop | Offline render | Duplicate / copy | Reopen |
|---|---|---|---|---|---|---|---|
| REAPER 7.80 (VST3) | yes | yes | — (not scripted) | keeps processing; FX bypass → "no audio" | offline, **nothing measured**; render = source (≤ 7.5·10⁻⁸) | copy flagged; Labs stays on the original | original found |
| REAPER 7.80 (AU) | yes | yes | — | same | same | same | original found |
| Logic Pro 12.4 (AU, out of process) | yes | **yes** (Δ ≤ 0.002 LU) | **pause, resume, reset TP, reset: acknowledged** | "no audio", back to streaming on play | offline 3 s, **nothing measured**; bounce = source outside Logic's own printed clicks (same deviation as with the Bridge bypassed) | the Stereo Out copy flagged (from build 2's project) | original restored by itself |
| Cubase 15.0.30 (VST3) | yes | **yes** (Δ ≤ 0.002 LU) | **acknowledged** | keeps processing | offline, **nothing measured**; export = source (≤ 7.5·10⁻⁸) | "(D)" copy flagged | original restored by itself |
| Ableton Live 12 Lite | not tested: the macOS Local Network prompt for Live (from the build 2 session) is left for you | | | | | | |
| FL Studio, GarageBand | not tested | | | | | | |

#### REAPER 7.80 (private profile, silent device): `e2e-reaper.sh`, all passed

For each format: live (play, plugin window open and closed, FX bypass, stop, play, quit: streaming → no audio →
streaming → held); an offline render traced by `ResultProbe` (reported offline, 0 frames measured while offline,
render equal to the source within 7.45·10⁻⁸); identity and transport (track duplicated while playing, loop, locates,
44.1 kHz and back — a new generation each time —, unload and reload: Labs back on the original; saved project holds
distinct identities); reopen (Labs finds the original by itself).

#### Logic Pro 12.4 (AU), a copy of build 2's test project

Logic re-validated and loaded build 3 in `AUHostingServiceXPC_arrow`. Live: exact, with Labs' comparison against its own
analysis passing on every value; controls acknowledged (pause: nothing accumulated; reset: generation 2). Stop and
play: "no audio" then streaming. Bounce (offline, normalize off): the insert reported offline for the 3 s Logic took,
and measured nothing; the bounce differs from the source in the same 285,960 samples as build 2's bounces (Logic's
metronome clicks and start transient; a bounce with the Bridge bypassed differs likewise); every other sample within
2 LSB. Reopen: Labs found the original insert by itself.

#### Cubase 15.0.30 (VST3), a copy of build 2's test project

Live: the insert had measured 16 s before Labs connected (Cubase processes from project load); comparison passes;
controls acknowledged. The plugin window showed its own measurement (I −7.8 LUFS, true-peak maximum, LRA, time
measured, generation). Audio Mixdown (not real time): both inserts reported offline and measured nothing; with the
leftover duplicate track muted, the export equals the source within 7.45·10⁻⁸ (unmuted, it is the sum of both tracks,
as expected). Reopen: Labs restored the original, not "(D)".

Not rerun on build 3 in Logic and Cubase: bypass and deactivate (the plugin's state machine is unchanged from build 2,
where they were checked, and is covered by the test host and REAPER).

### Resources

`measure-resources.sh` (real VST3 in the test host, 20 s per case, no receiver: every insert analysing on its own;
baseline: build 2's plugin, which does not analyse):

| Case | CPU, build 2 | CPU, build 3 | Extra CPU (analysis) | Extra memory | Worst `process()` |
|---|---|---|---|---|---|
| 1 × 48 kHz stereo | 2.0 % | 5.3 % | 3.3 % of a core | 3.1 MB | 21 µs |
| 8 × 48 kHz stereo | 4.6 % | 16.5 % | 11.9 % (1.5 % each) | 23.3 MB (2.9 MB each) | 34 µs |
| 32 × 48 kHz stereo | 13.0 % | 38.7 % | 25.7 % (0.8 % each) | 92.2 MB (2.9 MB each) | 47 µs |
| 8 × 44.1 kHz mono | 3.0 % | 17.8 % | 14.8 % | 23.4 MB | 30 µs |
| 8 × 96 kHz stereo | 7.4 % | 24.8 % | 17.3 % | 23.0 MB | 36 µs |
| 8 × 192 kHz stereo | 12.8 % | 33.0 % | 20.2 % | 23.0 MB | 67 µs |
| 8 × 48 kHz, 4096-frame blocks | 3.8 % | 12.8 % | 9.0 % | 23.4 MB | 81 µs |

CPU is process CPU time over wall time, as a share of one core. The analysis thread runs at the user-initiated QoS,
where macOS may use efficiency cores; the same work measured on a performance core in a tight loop is 0.42 % per
48 kHz stereo insert (`probe-analysis-link.sh`), so these figures are the upper, as-scheduled cost. A profile of the
8-insert case shows the time in the analysis itself (true peak, K-weighting, FFT), not in scheduling or encoding. Memory
per insert: the 1 MB capture ring, the pipeline's FFT and history buffers, the result mailbox and output buffer.
In return, Labs no longer analyses a Bridge source at all.

### Structural guarantees

- The host's audio thread only copies into the insert's preallocated ring: no allocation, lock, system call, logging,
  Swift or analysis (`BridgeCore::process`).
- Analysis runs on one thread per plugin binary, below real-time priority, with per-instance (50 ms of audio) and
  per-pass (8 ms) bounds and rotating order; if it falls behind by more than the ring, the analysis (not the output)
  loses audio, counted and marked as a break.
- Every buffer between the analysis and a display is fixed: a one-slot mailbox, column queues of 64 and 512, a 256 KB
  output buffer (16 KB high-water mark), 32 KB socket buffers; Labs keeps 8 spectrogram and 512 waveform columns.
- A display never receives a result of an earlier subscription, a column twice, or results of two formats in one
  generation.

### Known limitations and unresolved issues

1. **True-peak onset overshoot (finding in the shared analyser, not changed).** When a measurement starts in the middle
   of a waveform (capture started while audio plays, or a Reset while the DAW plays), the release true-peak detector
   can hold up to ~+1 dB above the signal's true peak from the first samples (reproduced in `test-analysis.sh`,
   "Stream starting mid-waveform"; the plugin and the desktop hold the identical value). Changing it would change the
   release's validated algorithm; a warm-up of the interpolator's length after a (re)start would remove it.
2. **Offline renders are not measured**, by design (a bounce is not live audio). Measuring a bounce as its own,
   labelled measurement would be a later feature.
3. **History after reconnecting:** about 2 s of waveform is recovered; the waterfall resumes from now (at most 8
   columns are replayed, so it never lags). Nothing older than the plugin's queues is kept.
4. **Labs' routing and Mono option do not apply to a Bridge source:** the plugin analyses its own channels (mono as
   L; stereo as L, R). Spatial detection does not apply (mono and stereo only).
5. **One display per insert connection.** The protocol separates shared measurement from display state, and
   commands carry their target and generation, but several displays at once (and a display-only pause control) are
   not implemented.
6. **CPU:** about 1–3 % of a core per insert as scheduled (above). Sessions with very many inserts may want a lighter
   mode (levels and loudness without the spectrum and stereo image when no display is subscribed); not implemented.
7. Plugins target macOS 11 and use the system's Swift runtime. Like build 2 (which already contained Objective-C), a
   plugin binary is not unloaded from a host process after use; its threads stop with the last instance.
8. Not verified: Ableton Live (prompt pending), FL Studio, GarageBand; Intel Macs; Logic and Cubase bypass/deactivate on
   build 3; the production transport with a team signature. Labs is not sandboxed, the builds are ad hoc signed and
   not notarized. The plugin window is English only.
9. The Swift part of the plugin is not covered by ThreadSanitizer (its threading is one thread per analyser, entered
   only from the analysis thread; the C++ hand-over is).
