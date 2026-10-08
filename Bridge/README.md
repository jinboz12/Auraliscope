# Auraliscope LABS 1.3dev and Auraliscope Bridge (DAW integration prototype)

Auraliscope Bridge is an audio effect (VST3 and AUv2) that you insert on a DAW track, bus or master. It passes the
audio through unchanged and **measures it itself**, with Auraliscope's own analysis compiled into the plugin:
levels, true peak, loudness, spectrum, stereo image, spectrogram and waveform. **Auraliscope LABS**, the 1.3dev test
build of Auraliscope, shows those results; it receives no audio from the plugin. Labs still analyses microphones,
interfaces and system audio itself, with the same code. The DAW is the plugin host; nothing here hosts plugins.

Build 68 (build numbers continue after Auraliscope 1.2.2, build 62: 63–67 were earlier LABS test packages; builds 1 to 3 were
the earlier prototypes) is on the experimental branch `claude/bridge-plugin-analysis`, started from the build 2 prototype (`7f7e733`,
branch `claude/auraliscope-daw-bridge-187076`, which is left as it was), with Auraliscope 1.2.2 (build 62,
`10e35cd`) as the application baseline. It is not merged, tagged or released. See
[ARCHITECTURE.md](ARCHITECTURE.md) for how it works, [PROTOCOL.md](PROTOCOL.md) for the result protocol and
[VALIDATION.md](VALIDATION.md) for what was tested.

## Build 68 changes

**A new spectrogram, written from scratch.** Nothing of the earlier presentation remains, so the third-party credit
(AudioSpectrogram, MIT) is gone from About, the notices and the README. It looks and reads as before (same palette,
keyboard, axes and default −90…−12 dB colours), and it is more accurate:

- **Multi-resolution analysis** (`Sources/AnalysisCore/SpectrogramAnalyzer.swift`, compiled into the plugins too).
  Each row uses the shortest Hann window that still resolves pitch there (at least 64 × its bin width, a main lobe
  within about ±½ semitone): 8192 points in the bass, 4096, 2048, 1024 and 512 points up the axis, blended over half
  an octave at each change. The treble is up to 16 times sharper in time: hi-hats and onsets are thin strokes, not
  170 ms smears.
- **Time-aligned columns.** Every window is centred on the same instant, so a broadband hit lands in one column
  from bass to treble. Short windows are repeated across each 1/30 s column at 50 % overlap and averaged (Welch), so
  no transient falls between columns.
- **Calibrated rows.** A row stands for its slice of frequency and shows the loudest level in it, corrected for the
  Hann window's scalloping with an exact Hann peak estimator: a sine reads its level within 0.05 dB in every zone (it
  could read up to 1.4 dB low between bins before). The live spectrum's bands use the same reading.
- **Exact peak readout.** The peak badge and the lit notes use the same estimator (Grandke's, exact for a tone in a
  Hann window) instead of a fitted parabola: frequency within 0.3 cents and level within 0.02 dB at any position
  between bins (was up to 2.9 cents and 0.3 dB at 55 Hz).
- **Float history.** The display keeps every column in dBFS (no 8-bit steps), so the colour range and tilt can change
  without losing the history.
- **New in Settings › Panels:** *Color range* (Standard −90…−12, Deep −114…−24 for tails and noise floors, Hot −72…0
  for loud masters) and *Tilt* (flat, 3 or 4.5 dB/oct around 1 kHz) for the spectrum and spectrogram.
- **Inspector:** hover over the spectrogram to read the pitch, frequency, age and level of the cell under the pointer
  (over the live spectrum, the band's level). Pause to read a moment at leisure.

The Bridge protocol is unchanged (512 rows per column): build 67 plugins still work with build 68 LABS, but show the
old analysis until the build 68 plugins are installed.

## Build 67 changes

- A two-lane double-precision K-weighting kernel for mono/stereo avoids evaluating six unused lanes. Three or
  more channels retain the existing grouped kernel. Filter coefficients, recurrence and analysis rates are unchanged.
- The stereo band filter uses fixed SIMD element stores, removing runtime vector indexing while preserving the
  interleaved independent cascades and their output samples.
- Independent scalar-oracle kernel checks run as part of `scripts/test.sh`, including sanitizer builds.
- `Bridge/Tools/CompareResources.py` performs alternating-order paired measurements on two staged VST3 builds and
  requires bitwise audio passthrough on every run. See VALIDATION.md for measured results and limits.

All build-66 accuracy and state fixes below remain included.

## Build 66 changes

- True-peak startup/reset now fills its interpolation history from observed audio, just as at a stream break.
  It no longer holds an artificial onset overshoot when capture starts mid-waveform; sample peaks remain active
  during priming, and real bursts after observed silence retain their interpolated tails.
- Reset True Peak updates the plugin's published result immediately, including while paused or idle, without
  advancing measurement time or changing integrated loudness.
- Plugin compilation now tracks the version file, so an incremental build updates compiled version strings and
  Objective-C editor class names as well as bundle metadata.
- The launch button rejects missing/unexecutable and trashed LABS candidates, including the default returned by
  LaunchServices and external-volume `.Trashes` paths.
- AU end-to-end tests load the exact staged bundle in the test process; no installed plugin is substituted.

See [TESTING-zh.md](TESTING-zh.md) for the short Chinese installation and listening-test guide.

## What you get

| Item | Where | Identity |
|---|---|---|
| Auraliscope LABS.app | `experimental-dist/Auraliscope LABS 1.3dev build 68/` | `com.jinboz.SoundMeterJBZ.Labs`, beta icon, own preferences and logs (`~/Library/Logs/Auraliscope Labs`) |
| Auraliscope Bridge.vst3 | same folder | class `03A87F06-69544B23-B85B74F8-248F8E42`, vendor JINBOZ |
| Auraliscope Bridge.component | same folder | `aufx Abrg Jnbz`, "JINBOZ: Auraliscope Bridge" |

Labs installs beside Auraliscope and never touches its preferences, logs, privacy grants or release numbering
(`Resources/Info.plist` is unchanged on this branch; Labs builds from `Bridge/App/Info.plist`). Everything is ad hoc
signed, universal (arm64 + x86_64 for the plugins), and not notarized.

## Build

Xcode's command line tools are enough (no CMake). The SDKs are downloaded, pinned, into `Bridge/ThirdParty/` (ignored
by git) on first use.

```bash
Bridge/scripts/build-plugins.sh
```
```bash
Bridge/scripts/build-labs-app.sh
```

`build-plugins.sh` also builds the shared analysis core into each plugin (`build-analysis-lib.sh`: Swift and C, one
static library per format; the Swift runtime is the system's). Other scripts: `fetch-sdks.sh` (VST3 SDK 3.8.0 build 66, MIT; AudioUnitSDK 1.4.0, Apache-2.0), `build-validator.sh`
(Steinberg's VST3 validator), `build-tools.sh` (test host, probe, discovery beacon), `Bridge/App/Icon/make-labs-icon.sh`
(regenerates the Labs icon from the release icon export).

## Install

**Testers: the installer.** `Auraliscope LABS 1.3dev build 68.pkg` installs, for every user of the Mac, the app
into `/Applications` and both plugins into `/Library/Audio/Plug-Ins/{VST3,Components}` (three choices, all selected).
The app stays independent of Auraliscope. The plugins use the paths, names and bundle IDs an official Auraliscope
Bridge would use, with bundle versions below any release (0.68; the plugin window and hosts show "1.3dev build 68"),
so an official installer replaces them, and this package never replaces a newer plugin. Nothing is relocated to
another copy. The package is not signed: open it with Control-click ▸ Open, or System Settings ▸ Privacy & Security ▸
Open Anyway. Apple silicon, macOS 13 or later. Build it with:

```bash
Bridge/scripts/package-installer.sh
```

Remove earlier test builds first (`install-plugins.sh --uninstall`, `install-labs-app.sh --uninstall`), so hosts and
macOS see one copy. The plugin's **Open Auraliscope LABS** button launches the newest registered copy, preferring one
in an Applications folder.

**Development: per-user copies.**

```bash
Bridge/scripts/install-plugins.sh
```
```bash
Bridge/scripts/install-labs-app.sh
```

The plugins go to `~/Library/Audio/Plug-Ins/{VST3,Components}` (this user only); Labs goes to `~/Applications`
(`--system` for `/Applications`). Both scripts take `--uninstall`. Rescan plugins in your DAW if it does not pick
them up (REAPER: Preferences ▸ Plug-ins ▸ Re-scan; Logic: Plug-in Manager).

## Use

Auraliscope LABS keeps both ways of working. In Settings ▸ Audio, **Source type** chooses:

- **Audio devices**: an input, or what apps play to an output, analysed in the app, as in Auraliscope.
- **Host plugins**: the Auraliscope Bridge inserts in your DAW, each measuring its own audio; LABS shows the results.
  With one insert connected it is chosen; with several, none is until you choose one (or click its plugin button).

Switching back to Audio devices returns to the device last chosen there (else the macOS default output). The plugin
button selects its insert whatever the source type. The main window and the plugin window both say **Prototype
experiment only** at the bottom.

1. Insert **Auraliscope Bridge** on a mono or stereo track, bus or the master.
2. Open the plugin window and click **Open Auraliscope LABS** (or **Show in Auraliscope LABS** when it is already
   running). That one click launches Labs if needed, connects, and makes this insert the active source.
   Without clicking, every insert still connects by itself whenever Labs is open, and appears in Labs under
   Settings ▸ Audio ▸ Source type ▸ *Host plugins*.
3. The name you type in the plugin window (saved with the DAW project) is what Labs lists; left empty, the host's
   track name is used when the host provides it (REAPER does).
4. The plugin window says whether **this insert** is the one Labs shows (and why not, with one click to make it so),
   whether fresh audio is arriving, and **its own measurement**: integrated, momentary and short-term loudness, peaks,
   true-peak maximum, loudness range, time measured and breaks, with **Pause** and **Reset**. Every insert measures
   from the moment the DAW plays audio through it, whether or not Labs or the plugin window is open.
5. **Network · Preview**, collapsed at the bottom of the plugin window, scans the local network only when you click
   **Scan**. It lists Auraliscope receivers it finds, but iPhone and iPad receivers cannot receive analysis yet.
   macOS may then ask to let the DAW find devices on the local network.

The Labs status line says what the selected insert is doing: streaming, no audio (the DAW stopped calling the
plugin: transport stopped in some hosts, FX bypassed in REAPER), bypassed, offline render (not metered), inactive,
measurement paused in the plugin, results delayed, disconnected with the measurement held (the plugin measures on;
Labs carries on when the same instance reconnects), or waiting for the saved insert to return (also after the
project is reopened). If several inserts could be the saved one (a duplicated track, the project open twice) Labs
says so and shows none until you choose. Breaks in the audio (the analysis falling behind, the DAW not processing,
bypass, render, restart) restart momentary and short-term loudness and the spectrum, keep integrated loudness,
loudness range and held peaks, and show in the status bar as "Interrupted N×". A dropped connection is not a break:
the plugin measured throughout.

**Controls.** In Labs, **Pause Capture** on a DAW source pauses the insert's measurement (nothing accumulates; resume
carries on without a break, as Auraliscope's pause does) and holds Labs' picture; the pause lasts while Labs is
connected. **Reset** starts the insert's measurement afresh; clicking **TRUE PEAK** clears its held true peak. The
plugin window's Pause and Reset act on the same measurement.

## Verify

All from the worktree root; logs go to `.build/bridge/validation/`.

```bash
Bridge/scripts/test-transport.sh
```
```bash
Bridge/scripts/test-analysis.sh
```
```bash
scripts/test.sh
```
```bash
.build/bridge/validator/validator -e "experimental-dist/Auraliscope LABS 1.3dev build 68/Auraliscope Bridge.vst3"
```
```bash
auval -strict -v aufx Abrg Jnbz
```
```bash
Bridge/scripts/e2e-probe.sh
```
```bash
Bridge/scripts/e2e-app.sh
```
```bash
Bridge/scripts/e2e-reaper.sh
```

`test-transport.sh` takes `ABR_SANITIZE=thread` (or `address`). `probe-analysis-link.sh` is the feasibility check for
linking the analysis core into both formats; `measure-resources.sh <baseline.vst3>` measures the analysis' CPU and
memory against a plugin without it (build 2); `probe-sandbox-transport.sh` is the production transport feasibility
test (ARCHITECTURE.md, "Production transport").

`e2e-probe.sh` uses a private socket and can run beside Labs. `e2e-app.sh` and `e2e-reaper.sh` need Labs and REAPER
to be closed (they run their own copy of Labs). `e2e-reaper.sh`
uses a private REAPER profile in `.build/bridge/reaper-profile` and the silent "Pro Tools Audio Bridge 2-A" device, so
your REAPER settings and speakers are untouched.

### Checks in other DAWs

REAPER is scripted (`e2e-reaper.sh`). Logic Pro (AU) and Cubase 15 (VST3) were checked through their interfaces on
build 3 (`labs-selftest.sh` runs Labs' self-test for such checks); the steps
and results are in [VALIDATION.md](VALIDATION.md), with the host compatibility matrix. To repeat them, or to check
Ableton Live or FL Studio:

1. Use a new, disposable project. Import `bridge-test-48k.aiff` (make one with
   `python3 Bridge/Tools/make-test-wav.py out.wav 48000 120`, then `afconvert -f AIFF -d BEI24@48000 out.wav
   bridge-test-48k.aiff`): L 997 Hz at −6.02 dBFS, R 1499 Hz at −12.04 dBFS.
2. Insert **Auraliscope Bridge** on that track and, while playing, run
   `Bridge/scripts/labs-selftest.sh --bridge-selftest bridge-test-48k --expect-peak-db -6.02,-12.04 --compare-reference
   --then-controls`: it checks the plugin's results against Labs' own analysis of the signal and drives Pause, Resume,
   Reset true peak and Reset. With `--no-measure --watch 20 --log-sources` instead it prints every state the insert
   goes through (stop, bypass, deactivate).
3. Bounce or export offline while `.build/bridge/tools/ResultProbe --seconds 30 --trace` runs (Labs closed): the
   insert must report offline with nothing analysed while it is (`frames analysed while offline: 0`), and `python3 Bridge/Tools/check-render.py <file.wav>` must pass (turn off
   normalization and anything on the master bus).
4. Duplicate the track while step 2 watches: the copy is listed as "copy of #…", and Labs stays on the original.
5. Save, quit the DAW, reopen, and run `labs-selftest.sh --bridge-selftest --restore --expect-peak-db -6.02,-12.04`:
   Labs must find the original by itself.
