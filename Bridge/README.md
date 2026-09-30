# Auraliscope Labs 1.3dev and Auraliscope Bridge (DAW integration prototype)

Auraliscope Bridge is an audio effect (VST3 and AUv2) that you insert on a DAW track, bus or master. It passes the
audio through unchanged and **measures it itself**, with Auraliscope's own analysis compiled into the plugin:
levels, true peak, loudness, spectrum, stereo image, spectrogram and waveform. **Auraliscope Labs**, the 1.3dev test
build of Auraliscope, shows those results; it receives no audio from the plugin. Labs still analyses microphones,
interfaces and system audio itself, with the same code. The DAW is the plugin host; nothing here hosts plugins.

Build 3 is on the experimental branch `claude/bridge-plugin-analysis`, started from the build 2 prototype (`7f7e733`,
branch `claude/auraliscope-daw-bridge-187076`, which is left as it was), with Auraliscope 1.2.2 (build 62,
`10e35cd`) as the application baseline. It is not merged, tagged or released. See
[ARCHITECTURE.md](ARCHITECTURE.md) for how it works, [PROTOCOL.md](PROTOCOL.md) for the result protocol and
[VALIDATION.md](VALIDATION.md) for what was tested.

## What you get

| Item | Where | Identity |
|---|---|---|
| Auraliscope Labs.app | `experimental-dist/Auraliscope Labs 1.3dev build 3/` | `com.jinboz.SoundMeterJBZ.Labs`, beta icon, own preferences and logs (`~/Library/Logs/Auraliscope Labs`) |
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

1. Insert **Auraliscope Bridge** on a mono or stereo track, bus or the master.
2. Open the plugin window and click **Open Auraliscope Labs** (or **Show in Auraliscope Labs** when it is already
   running). That one click launches Labs if needed, connects, and makes this insert the active source.
   Without clicking, every insert still connects by itself whenever Labs is open, and appears in Labs under
   Settings ▸ Audio ▸ Source ▸ *DAW plugins · Auraliscope Bridge*.
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
.build/bridge/validator/validator -e "experimental-dist/Auraliscope Labs 1.3dev build 3/Auraliscope Bridge.vst3"
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

REAPER is scripted (`e2e-reaper.sh`). Logic Pro (AU) and Cubase 15 (VST3) were checked by hand on build 2; the steps
and results are in [VALIDATION.md](VALIDATION.md), with the host compatibility matrix. To repeat them, or to check
Ableton Live or FL Studio:

1. Use a new, disposable project. Import `bridge-test-48k.aiff` (make one with
   `python3 Bridge/Tools/make-test-wav.py out.wav 48000 120`, then `afconvert -f AIFF -d BEI24@48000 out.wav
   bridge-test-48k.aiff`): L 997 Hz at −6.02 dBFS, R 1499 Hz at −12.04 dBFS.
2. Insert **Auraliscope Bridge** on that track and run
   `"experimental-dist/Auraliscope Labs 1.3dev build 3/Auraliscope Labs.app/Contents/MacOS/Auraliscope" --diagnostic
   --bridge-selftest bridge-test-48k --expect-peak-db -6.02,-12.04 --watch 40 --log-sources` while playing: it
   measures, then prints every state the insert goes through (stop, bypass, deactivate) and the plugin list.
3. Bounce or export offline while `.build/bridge/tools/ResultProbe --seconds 30 --trace` runs (Labs closed): the
   insert must report offline with nothing analysed while it is (`frames analysed while offline: 0`), and `python3 Bridge/Tools/check-render.py <file.wav>` must pass (turn off
   normalization and anything on the master bus).
4. Duplicate the track while step 2 watches: the copy is listed as "copy of #…", and Labs stays on the original.
5. Save, quit the DAW, reopen, and run step 2 with `--restore` instead of the track name: Labs must find the original.
