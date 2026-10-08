# Auraliscope Bridge / Auraliscope LABS 1.3dev: validation report

## Build 67 — 2026-10-05

This round starts from the delivered build 66 and retains its true-peak priming/reset fixes. It changes only two
shared DSP kernels plus tests, tooling and build metadata. Protocol 3, schema 1, measurement coefficients, tick
rates and history capacities are unchanged. Logs are in `.build/bridge/validation/build67/`.

### Implementation and numerical checks

- Mono/stereo K-weighting runs in one two-double vector instead of computing eight lanes including unused silence.
  Three or more weighted channels retain the previous grouped kernel. The recursive equations and energy
  accumulation order are unchanged, and no allocation or lock was added.
- Stereo-band output writes use constant SIMD lane indices, preserving the parallel cascades and avoiding runtime
  indexing of a vector array. A regrouped alternative measured slower and was discarded before packaging.
- `Tests/AnalysisKernelsChecks.c`, included in `scripts/test.sh`, compares both kernels with independent scalar
  recurrences: 0–16 weighted channels, 0–12 stored band lanes, empty and irregular buffers, carried states, energy
  accumulation, silence tails and unwritten output guards. K-weighting tolerance is 1e-10 (relative for large
  energies); band tolerance is 2e-6. These checks pass natively and under AddressSanitizer, and the x86_64 build
  also passes under Rosetta. Rosetta is not Intel hardware validation.
- A separate dynamic-library A/B harness loads the build-66 C kernels and the new kernels together. Its band
  outputs and states are bit-identical; weighted energies/states match within 1e-11 on that signal. Five
  alternating-order pairs, each processing 5.12 million frames, give these kernel-only medians:

| Kernel | Build 66 | Build 67 | Change in elapsed time |
|---|---:|---:|---:|
| K-weighting, mono | 0.041099 s | 0.028130 s | −31.6% |
| K-weighting, stereo | 0.041110 s | 0.028077 s | −31.7% |
| Stereo band filter, ten output lanes | 0.048576 s | 0.046692 s | −3.9% |

These are kernel costs on this Mac, **not percentages of DAW CPU saved**. The full-plugin comparison below includes
other analysis and host overhead.

### Paired full-plugin CPU comparison against build 66

`python3 Bridge/Tools/CompareResources.py <build66.vst3> <build67.vst3>` runs the same HostHarness with
no LABS receiver, a private socket, synthetic audio, 15 seconds per run, three alternating-order pairs per case.
Every one of the 18 runs passed bitwise audio passthrough and reported zero process errors. CPU includes child
process user + system time (including startup/teardown), divided by the configured audio duration; 100% means
one core. These are medians, not the best run. Raw observations: `build67/resources-vs66.log`.

| Scenario | Build 66 CPU | Build 67 CPU | Relative change |
|---|---:|---:|---:|
| 8 mono instances, 48 kHz, 256 frames | 13.160% | 12.635% | −4.0% |
| 32 stereo instances, 48 kHz, 256 frames | 34.188% | 33.419% | −2.2% |
| 8 stereo instances, 192 kHz, 1024 frames | 25.748% | 25.296% | −1.8% |

Run-to-run variation remains: for example, the 192 kHz baseline range was 23.254–26.753%, and the new range
19.861–25.885%. Three pairs do not establish statistical significance. These modest whole-process reductions
are observations on this Mac, not a guaranteed DAW improvement; they must not be confused with the 32%
K-weighting-only reduction above. LABS rendering CPU is not included in this comparison.

### Completed validation

| Check | Build 67 result |
|---|---|
| Core suite | 43/43, including dense multi-tone and 576 true-peak onset combinations |
| New scalar/SIMD kernel checks | pass, native arm64 and x86_64 under Rosetta |
| AddressSanitizer | core 43/43 and new kernel checks pass |
| Localization | 341 keys, en / zh-Hans / ko |
| Bridge analysis | 95/95 |
| Bridge transport | 95/95, also 95/95 with ThreadSanitizer (C/C++ instrumented; Swift core uninstrumented) |
| Steinberg VST3 validator | 537 passed, 0 failed |
| Plugin → ResultProbe | 12/12, exact build-67 VST3 and AU; bitwise audio passthrough |
| Plugin → LABS | 11/11: reconnect, mono, multiple instances, rate transition, states, restart, duplicate identities, hold, controls and analysis before app launch |
| Paired resource runs | 18/18, zero output mismatches and process errors |
| Installer payload | App + VST3 + AU identical to staged bundles; strict signatures, permissions, no AppleDouble entries, no relocation |
| Bundle versions | App 1.3 / build 67; plugins 0.67 / build 67; plugin internal version text 1.3dev build 67 |

**Boundaries:** synthetic test-host runs are not DAW compatibility certification. This round does not install the
package as administrator, rescan an installed AU with auval, exercise real audio hardware, or rerun REAPER, Logic,
Cubase, Live, FL Studio or GarageBand. No Intel-hardware or older-macOS runtime test. No new app-window screenshot
was attempted in this round; the UI code is unchanged from build 66. App remains arm64/macOS 13+, plugin bundles
contain arm64 and x86_64. Ad hoc code signatures; no Developer ID installer signing or notarization.

## Build 66 — 2026-10-05

This is a new build of the build-65 experiment (`cee274c`), validated below on Apple M1 Max / macOS 27.2.
Protocol 3 and analysis schema 1 are unchanged. Older sections are historical evidence, not build-66 host claims.
Logs: `.build/bridge/validation/build66/`, plus the individual probe/app/harness logs in its parent directory.

### Changes and measured accuracy

- **True-peak startup/reset priming.** The old analyser treated unavailable history as silence. Baseline run:
  the right channel of the 1499 Hz / 0.25 test tone starting at sample 777 held **−11.012 dBTP**, although its
  analytic crest is **−12.041 dBTP**. Build 66 reads **−12.041 dBTP** (left: **−6.021 dBTP**).
  Startup now uses the same 65-sample history fill as a break. Sample peaks are retained from the first sample;
  interpolation near an unknown edge is intentionally omitted. This affects both device analysis in LABS and
  plugin analysis, and does not alter the production checkout.
- **Real tails at the priming boundary.** If a nonzero sample arrives during priming, later observed silence drains
  its filter tail even when a host buffer ends exactly at sample 65. This also fixes that boundary after a break.
- **True-peak reset while paused/idle.** Clears the published snapshot as well as pipeline state, so the next RESULT
  and plugin summary show zero without waiting for new audio; measurement time and other values stay unchanged.
- **Build identity.** C++ object dependencies include `prototype-version.sh`, updating compiled version strings and
  the editor's Objective-C class names when the build number changes. Both plugin binaries contain `1.3dev build 66`.
- **Launch selection.** Every candidate, including LaunchServices' default, must have an executable and must not be
  in `.Trash` or `.Trashes`. This is source-reviewed; no destructive manipulation of registered installed copies
  was used as a test.
- **Test isolation.** HostHarness `--format au --bundle …component` registers the exact staged factory only in its
  test process. AU tests no longer silently select an installed copy. App e2e uses a private Unix socket.

### Completed checks

| Check | Build 66 result |
|---|---|
| Core suite | **43/43**, also **43/43 under AddressSanitizer** |
| Localization | **341 keys**, en / zh-Hans / ko |
| Bridge analysis | **95/95** |
| Bridge transport | **95/95**, also **95/95 under ThreadSanitizer** (C/C++ instrumented; Swift library uninstrumented) |
| Steinberg VST3 validator `-e` | **537 passed, 0 failed**, build-66 staged VST3 |
| Plugin → ResultProbe (`e2e-probe.sh`) | **12/12**, exact build-66 VST3 and AU binaries; output identical to input |
| Plugin → LABS (`e2e-app.sh`) | **11/11**, including reconnect, mono, multiple instances, 96 kHz transition, bypass/offline/idle states, app restart, duplicate identities, held display, controls and analysis before app launch |
| AU and VST3 editors | Open/close tests pass; captured editor layouts inspected; AU log confirms staged build 66 |
| Installer extraction | Three payloads match staged bundles byte for byte, internal signatures valid, non-relocatable, readable by all users, no AppleDouble entries |

New core accuracy coverage: six rates (44.1, 48, 88.2, 96, 176.4 and 192 kHz), four frequencies (997, 1499, 15,000
and 20,000 Hz), eight initial phases, three buffer sizes (1, 7, 257): **576 onset cases**, each within **0.005 dB**
of the analytic crest and split-invariant within **1e-6 linear amplitude**. There are also 24 priming-boundary burst
cases, six one-sample captures, and the existing dense 20-tone, near-Nyquist and real-silence tail tests. The latter
now supplies observed preceding silence explicitly, instead of assuming silence before capture began.

### Resource spot check against build 65

Same HostHarness, no receiver, 10 seconds per run (one pair per case); process CPU is a percentage of **one core**.
This is a short scheduling-sensitive comparison, not a speedup claim. RSS difference was at most 0.1 MB.

| Instances / format | Build 65 CPU | Build 66 CPU | Build 66 worst audio process call |
|---|---:|---:|---:|
| 1 × 48 kHz stereo | 3.3% | 2.9% | 17.2 µs |
| 8 × 48 kHz stereo | 11.9% | 12.1% | 18.5 µs |
| 32 × 48 kHz stereo | 31.0% | 34.6% | 27.8 µs |
| 8 × 44.1 kHz mono | 11.8% | 13.7% | 25.6 µs |
| 8 × 96 kHz stereo | 21.4% | 20.3% | 22.7 µs |
| 8 × 192 kHz stereo | 26.1% | 30.3% | 34.7 µs |
| 8 × 48 kHz stereo, 4096-frame blocks | 10.6% | 10.9% | 47.5 µs |

Follow-up: three alternating-order pairs for the two largest differences gave median one-core CPU **34.84% →
35.25%** for 32 × 48 kHz stereo, and **26.40% → 27.12%** for 8 × 192 kHz stereo. All 12 repeated harness runs
reported zero output mismatches and process errors. These small increases and run-to-run spread do not establish
an improvement or exact equivalence; this remains an accuracy/reset update, not a CPU optimization claim.

### App launch and rendering smoke check

The app extracted from the final installer passes strict/deep signature verification and its Metal offscreen
preview renders successfully (visually inspected). LaunchServices with external `--stdout/--stderr` destinations
returned `-10810`; without those options it launched successfully. The saved no-window state required a subsequent
normal Open event, after which the build-66 diagnostic log entered demo mode. A full-window screenshot was not
obtained. The offscreen preview is not a substitute for an installed interactive UI test.

**Boundaries:** no administrator installation was performed. AU was loaded directly by the test host, not rescanned
or validated by `auval` as an installed build. No build-66 DAW compatibility run was performed in REAPER, Logic,
Cubase, Ableton Live, FL Studio or GarageBand; historical results below do not substitute for one. No Intel or
older-macOS runtime testing, Developer ID signing or notarization. This is an accuracy/state correctness update;
no general CPU speedup is claimed. Startup's 65-sample priming is about 1.47 ms at 44.1 kHz (sample peaks still count).

## Build 65

- **App name fix.** Build 64 installed as `/Applications/Auraliscope LABS.app`, but Finder, the Dock and the privacy
  prompts showed "Auraliscope". The release's localized `InfoPlist.strings` (en, zh-Hans, ko) set
  `CFBundleDisplayName` to "Auraliscope", and the localized name wins over `Info.plist`. `build-labs-app.sh` now
  rewrites each copy in the LABS bundle to "Auraliscope LABS" (name, display name and privacy descriptions), and
  fails if one does not. The release's files are unchanged. The privacy descriptions in `Bridge/App/Info.plist` say
  Auraliscope LABS too.
- Checked: the display name resolved per localization, as Finder does, is "Auraliscope LABS" in en, zh-Hans and ko
  (installed build 64: "Auraliscope" in all three). Plugins 0.65; plugin code unchanged.

## Build 64

- **Installer fix.** Build 63's package installed every bundle as `drwx------ root wheel`, so the app could not be
  opened and the plugins could not be read by a DAW. The external volume reports every folder as owner-only, and the
  package kept that. Its payload also carried AppleDouble `._` entries: `pkgbuild` stores each extended attribute as
  one, and macOS attaches `com.apple.provenance` to files written here, which cannot be removed; inside a bundle these
  break its sealed signature. `package-installer.sh` now sets modes to owner-writable and readable by all users, and
  replaces `pkgbuild`'s payload with one written by `payload-cpio.py`: root:wheel, the files' own modes, no attributes.
  The file list is rebuilt to match. Its self-check fails the build if any payload item is unreadable by other users
  or is a `._` file. The zips get the same permissions.
- **LABS Indigo theme**, `#6B7E97`, the slate indigo of the LABS icon's body, with a cool cream. It is the default,
  listed first. A theme saved by an earlier LABS build switches to it once on first launch; a theme chosen after that
  is kept.
- Plugins 0.64, so they replace build 63's.

Checked: release core checks (42), localization (341 keys), the installer's self-check, and an offscreen render in
the new theme. The build 64 installer was not installed here (installing needs an administrator). The analysis,
transport and plugin code are build 63's, whose results follow.

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

### Known limitations and unresolved issues (historical build 3)

The onset issue in item 1 below is fixed in build 66; see the current section above.

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
