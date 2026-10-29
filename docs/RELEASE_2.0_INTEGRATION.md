# Auraliscope 2.0 (macOS): integration and release-candidate record

Branch `codex/2.0-release`, worktree `/Volumes/Backup/VIBECODING/Auraliscope-release`, based on `5839ab3`
(2.0 rc 3, build 120). The changes are **uncommitted** (AGENTS.md: no commits unless asked). Version and build numbers
are unchanged (still 2.0 rc 3 · 120); nothing was packaged, installed, signed, pushed or tagged.

## 1. Where everything came from

### Phase 1–7 work: already inside build 120

The history from `main` to build 120 is one straight line, so build 120 already holds every committed phase. Nothing
from Phases 1–7 had to be merged again.

| Work | Commits (oldest → newest) | In build 120 |
|---|---|---|
| Build 119 (spectral tilt, Multi-FFT readout and settings, welcome rule) | `cc30ac1` | yes |
| Phase 1 audit | `docs/maintenance/CODE_AUDIT_2026-10.md` (docs only) | yes |
| Phase 2 baseline (golden digests, P0 characterisations) | `252f251` | yes |
| Phase 3 refactors (LogFrequencyAxis, AGENTS.md, check-all, file splits, layout checks) | `ce157df` … `f95bebb` | yes |
| Phase 4 hardening (capture break marks, shader check, CI workflow, model checks) | `3eeb89f` … `5584b9c` | yes |
| Phase 5 MeterModel decomposition (coordinator, RoutingStore, BridgeLink) | `f862be0` … `a69c30e` | yes |
| Phase 6 correctness (Bridge fixes A and B, transition checks, recovery proposal) | `c7a32eb` … `9333796` | yes |
| Phase 7 capture recovery (P0-1 bounded restarts) | `687b505` … `fed2426` | yes |
| Build 120 version bump and documents | `37407d4`, `5839ab3` | base |

How this was checked:

- `git merge-base --is-ancestor`: `maintenance/commit-series`, `maintenance/p0-baseline`, `codex/auraliscope-bridge`,
  `development` and `origin/main` are all ancestors of `5839ab3`. `origin/development` adds only the old 1.1 release
  (`152f251`). That is not relevant here.
- Primary checkout (`/Volumes/Backup/VIBECODING/Auraliscope`, `main` at `a11b325`): its 15 uncommitted tracked files are
  **byte-identical to `cc30ac1`** (build 119). They are duplicates and needed nothing. Its untracked files are older
  1.2.x test reports, an icon-concept sheet, a design folder and copies of maintenance logs. None of them is release
  source, so they were left where they are. The primary checkout was not modified.
- Maintenance worktree (`dist/2.0 ver/2.0 rc 3Phases/Auraliscope-maintenance`): 71 working files are identical to
  `5584b9c`. Only its phase logs and state files differ (records, not source).
- Phase 5, 6 and 7 worktrees: only their uncommitted `PHASE*_STATE.json` and `PHASE*_LOG.md` records.
- None of the moved worktrees was pruned or repaired. `git worktree list` still shows them as prunable at their old paths.

### Imported from the iPad checkout (`/Volumes/Backup/VIBECODING/Auraliscope-ipad`, `codex/ipad-display`)

Only shared code and Bridge plugin code was taken. The iPad app (`iPad/`) and the build-2 port of the macOS UI to
iPadOS (the `#if os(iOS)` seams, `PlatformViews.swift`, touch views) were left out. So were the iOS-only build guards
(`CaptureCallback` `TARGET_OS_OSX`, the `AURALISCOPE_ACCELERATE_NEW` CBLAS variant) and the iPad receiver's
`abr_server_adopt` and HELLO deadline. The Mac never adopts sockets.

| What | Source | How |
|---|---|---|
| Portable display core (framing, display session, pairing, AnalysisFrame) and `DisplayCoreChecks` | commit `8455a4c` | applied without committing; includes the `BridgeDiscovery`/`BridgeProtocol.h` additions |
| Bridge network carrier: `BridgeNetLink`, `BridgeRemote`, `BridgeCore` exclusive carrier, plugin window, `NetworkPair`, `BridgeNetworkProbe`, `HostHarness --receiver` | commit `2d91ffd` | applied |
| Plugin window wording (network destination) | `4d1d3f1`, `Bridge/Plugin/Editor/BridgeEditor.mm` only | file taken |
| Network spec, test scripts, dev-plugin identity | `c2b0e5f`: `Bridge/BRIDGE_NETWORK.md`, `Bridge/PROTOCOL.md`, `build-dev-vst3.sh`, `build-plugins.sh`, `build-ipad-dev-plugin.sh`, `ipad-dev-version.sh`, `test-network.sh` | files taken |
| Pause → Resume splice fix: `MeterPipeline.splice()`, `StreamAnalyzer` resume tracking, `DSPWorker.resume` splice, `Bridge/Tests/PauseResumeTests.swift`, ResultProbe held-true-peak check | iPad working tree, uncommitted, 2026-10-28 | hunks applied; `DSPWorker` hunk re-applied by hand to `MeterModel.swift` |
| Network security review notes and pause semantics | iPad working tree: `BRIDGE_NETWORK.md`, `PROTOCOL.md` | applied |
| `BridgeAck` → `BridgeAckMessage` in the display core | iPad working tree | applied (keeps the two branches mergeable) |

A snapshot of the iPad working-tree diff at the time of import (HEAD `c2b0e5f`) was kept outside the repository. The
iPad checkout was only read, never modified.

## 2. What changed for the user

**Update check on every launch.** About 4 s after a normal launch, Auraliscope checks GitHub once, in the background,
on the channel chosen in Settings ▸ Updates (Include pre-releases). A "recently checked" interval never skips it.
When up to date, or when the check fails (offline, timeout, rate limit, malformed reply), nothing is shown; the
diagnostic log records the result. When a newer release exists, a banner at the foot of the window names it and offers
**View Release** and **Download Installer** (both open the browser) and **Later** (hides it until the next launch).
Nothing is downloaded or installed by the app. Check for Updates… works as before. A manual request during the
launch check joins that check and is answered like a manual check, failures included.

- No check is made by QA bundles, by any launch with a command-line flag other than `--bridge-launch` (self-tests,
  snapshots, previews, file analysis, capture checks, `--demo`), or when `AURALISCOPE_NO_UPDATE_CHECK` is set.
- A pre-release (version label containing rc, beta or alpha, such as "2.0 rc 3") is now offered its own final release:
  the same version, not a pre-release, with no build number or a build at least its own. Before this, an RC user on
  the stable channel was never offered a final "2.0" whose release name and installer carry no build number.
- There is no automatic-check preference, so there was nothing to reconcile. The Updates note now says the check runs
  at every launch. **Product decision left open:** whether to add an off switch.

**Status bar.** Each state gets a coloured dot. Live is the accent; paused is quiet; waiting, choosing and recovering
are ochre; failures that need action are ember, with ember text. Next to the text is one action where it helps:
**Resume** (paused), **Choose Source…** (no source, no device), **Choose Insert…** (Bridge waiting for a choice, several
matching inserts), **Open Privacy Settings** (microphone access refused) and **Try Again** (any failure, including
capture recovery having given up). Recovery in progress offers no action, because it is already acting and its retries
are bounded. The wording of every status is unchanged. VoiceOver reads it as "Status: …". "No sound from this output"
(digital silence) stays separate from device and plugin disconnection. Capture recovery semantics, retry bounds,
session-generation protection and dropped-frame accounting were not touched.

**File analysis and reports.**

- A cancelled analysis now says so ("Analysis cancelled", nothing measured) instead of going blank.
- A failure is labelled, keeps the system's message (selectable) and suggests the next step.
- PDF reports render page by page with a pause between pages, so the window keeps drawing. The panel shows
  "Saving…", disables the save buttons meanwhile, and then offers **Show in Finder**.
- Reports are written to a temporary file and moved into place when complete, so a failure never leaves a partial
  report or damages an existing one. Failures say which file kind could not be saved.
- The command line's `--analyze-report` prints the write time. Report content and units are unchanged.

**Windows and layout.**

- The main window's saved frame is checked against the screens present at launch.
- When displays are removed or rearranged, every visible titled window is brought back where its title bar can be
  reached. A reachable window is never moved, only shrunk to fit its screen.
- The rules are in `WindowFrames` and covered by tests.
- Saving a layout or a settings preset under an existing name now asks before replacing it.
- **Limitation:** detached panel windows still do not reopen at relaunch (they never did). That avoids restoring
  transient state, and per-display restoration of several windows was not attempted. Reset Layout (Settings ▸ General,
  or Layout ▸ Full Meter) remains the way back to the default.

**Multi-FFT (Beta).** With Spectrogram & Spectrum and Waveform both under it, the Multi-FFT split now leaves them their
minimum heights. At 1280×720 the Waveform had shrunk to its title row. Its DAW-plugin notice now reads in plain
words ("needs audio captured on this Mac") instead of "requires local PCM". It is still labelled Beta, with the same
source limits.

**Settings presets.** A preset file that cannot be read is now named in the Presets section instead of silently
disappearing. A preset that fails to save says so and points to the folder. Preference keys and the preset format are
unchanged.

**Pause → Resume** (app and plugin). After a resume, the first audio is spliced on, not joined to the audio before the
pause. That removes a false true-peak overshoot (+0.05 dB on the test signal) and a spectrogram click. Integrated
loudness, loudness range, held peaks and histories carry on. A pause is not counted as a break or as missing time.

**Bridge plugin: network display (VST3; AU shares the code).** As implemented in the iPad branch:

- The plugin window can scan for Auraliscope iPad displays (Bonjour `_auraliscope._tcp`) and pair with an 8-character
  code that the display shows and approves.
- It then sends the analysis results to the chosen display over TLS 1.2 PSK. Audio is never sent.
- **Use this Mac** returns that insert to the local socket.
- There is one destination per insert, saved with the project (`receiver=`), and the Mac stays the default.
- The send queues are bounded, there is backpressure, and the connection reconnects. Nothing new runs in `process()`.
- Known security limits are documented in `Bridge/BRIDGE_NETWORK.md`: no forward secrecy, the PSK identity is not yet
  bound to the HELLO device ID, and display names are visible on the LAN.

**Test isolation.** `scripts/qa-env.sh` stages a QA-identity bundle and a private plugin socket.

- `check-all.sh`, `check-model.sh` and `check-file-analysis.sh` now go through it.
- File analysis and the model worker run on `--demo`, so no device is opened.
- QA bundles keep their settings presets in a temporary folder (`Auraliscope-QA-Presets`), as they already did for
  logs and preferences.
- `scripts/check-selftests.sh` runs the app's self-tests the same way.

## 3. Verification

All runs were on this Mac, on this branch, with no audio device opened, no DAW, no install, and the user's
preferences, logs, presets and Bridge socket untouched (QA identity and private socket; the real presets folder was
last modified 26 Oct).

**Automated, deterministic**

| Check | Result |
|---|---|
| `scripts/check-all.sh`: debug and release builds, shaders, 61 core checks, app features, file analysis (QA + demo), plugin-side analysis, spatial report, plugin transport | 9/9 pass |
| Golden pipeline digests (5 scenarios), including the splice change | bit-identical |
| Pause → Resume regression (`PauseResumeTests`): splice vs join, held true peak, spectrogram, integrated/LRA carry-on, no break counted | pass. The join without the fix reads −5.97 dBTP and −60 dB top bands; spliced, it reads −6.02 dBTP and −120 dB |
| Update checks: RC → final with and without a build number, older build, itself, both channels; launch policy; once per launch; quiet failures (rate limit, malformed, unavailable, timeout, offline); joined requests; pre-release preference | pass (injected fetch, no network) |
| Window frames (kept, removed display, above screen, oversized); Multi-FFT stack minima | pass |
| Localization: 951 keys × 6 languages, placeholders, glossary | pass |
| `swift run DisplayCoreChecks` | pass |
| Plugin transport under ThreadSanitizer (`ABR_SANITIZE=thread`, network link included) | pass, 0 reports |
| `scripts/check-model.sh` (worker on demo, lifecycle 164 checks) | pass |
| `scripts/check-selftests.sh`: shaders, model worker, lifecycle, settings draft, settings presets (now in the QA temp folder), Multi-FFT layout, pause, spectrum average, peak reset, nebula GPU, spatial projection | 11/11 pass |

**Local loopback (not Wi-Fi, not a device)**

| Check | Result |
|---|---|
| `Bridge/scripts/test-network.sh` (dev VST3 in HostHarness ↔ BridgeNetworkProbe over TLS-PSK on this Mac) | pairing (0600 key file; wrong code refused), results 659 at 47/s, stall 8 s with column gaps exactly equal to those reported by the sender, drop and reconnect, refused after the display forgets the Mac. Audio identical in every phase; worst `process()` 20.6 µs |
| Release-build **AU** paired and streamed to the probe | 0 invalid results, 0 column gaps, audio identical, worst `process()` 7.1 µs |
| Release VST3 and AU built (`build-plugins.sh` into `.build/bridge/rc-dist`, never the release dist) and run in HostHarness | audio identical, 0 process errors |

**Visual inspection** (QA bundle snapshots at 1280×720, dark theme, demo signal): live status, and paused status with
its Resume link. That pass found the Waveform squeezed to its title row under a visible Multi-FFT, and the fix was
re-inspected afterwards. **Not inspected visually:** the update banner (it needs a release to offer), the other
status states, light theme, the other five languages (the app takes its language from its own setting, not
`-AppleLanguages`), Dock mode and detached windows after these changes. Those were checked only by geometry tests,
the localization check and compiling.

**Not run:** any real audio device, sample-rate change, unplugging, sleep and wake, a DAW (REAPER, Nuendo, Logic),
a physical iPad, Wi-Fi, signing or notarization.

## 4. Remaining release blockers

1. **Hardware and DAW acceptance** (section 5): none of it has run on this branch.
2. **Physical iPad over Wi-Fi:** only loopback on this Mac has been tested. The receiving iPad app lives in the iPad
   branch, which has no signing identity or device yet.
3. **Signing:** Developer ID for the app, both plugins and the installer, plus notarization and stapling. Without
   them, users go through Privacy & Security ▸ Open Anyway, and macOS asks again for audio access with every build.
4. **Version identity:** the label, build number and release notes for the final 2.0 (a separate request), then
   packaging with the usual scripts. Decide whether the stable release's name or installer carries the build number.
   The updater handles both.
5. **Commit and review** of this branch (uncommitted by rule), then CI on it.
6. **Product decisions:** an off switch for the launch check, and whether the network display ships in 2.0 or stays
   hidden until the iPad app ships. The plugin offers **Scan** today.

## 5. Hardware, DAW and network acceptance checklist

Run with this branch built and packaged as an internal QA build, on your own machine.

1. **Update banner:** with a test release (or a QA build labelled rc) visible on GitHub, launch normally. Expect the
   banner within about 5 s, and nothing when up to date. With Wi-Fi off: no banner, and no alert.
   Check for Updates… while offline: the connection message.
2. **Output capture:** 5 min with programme, then 5 min idle. Live, then silent. "No sound from this output" appears
   only for digital silence, never "disconnected". Dropped frames stay at 0.
3. **Interface input** (UltraLite-mk5), 10 min with and without programme.
4. **Pause → Resume:** with a steady sine, pause for 10 s and resume. The held true peak does not rise, and the
   spectrogram shows no click column. Integrated loudness carries on.
5. **Rate change** 48 → 44.1 kHz, then four changes in 10 s. No "capture keeps failing". If recovery runs, the status
   is ochre without an action. If it gives up, the status is ember with **Try Again**, and Try Again works.
6. **Unplug and replug** the interface: "No audio device available" with **Choose Source…**, then it measures again.
7. **Sleep and wake** while capturing; **hidden** or **minimised** for 5 min: still live.
8. **Microphone access refused** (System Settings): ember status with **Open Privacy Settings**, which opens the right
   pane.
9. **Displays:** put the window on an external display, quit, unplug the display, and relaunch: the window opens on the
   laptop screen. Unplug it while running: the window comes back. Do the same with a detached panel window.
10. **DAW, VST3 (REAPER and Nuendo), build-120 projects:** stereo, 7.1.4 and 9.1.6 inserts stream. Pause in the plugin,
    then resume. Repeat the Phase 6 A and B checks (`INTERNAL_QA_README.md` items 9a–9c).
11. **DAW, AU (Logic or REAPER AU):** same as 10 for stereo. The plugin window's network section shows the same states.
12. **iPad over Wi-Fi** (needs the iPad build signed onto a device):
    1. Scan, then pair with the code, then choose the display: the iPad shows the insert. The Mac app sees it leave.
    2. **Use this Mac:** it comes back to the Mac app.
    3. Save and reopen the project: it reconnects to the iPad.
    4. Wrong code: refused.
    5. Forget the Mac on the iPad: the plugin says it is refused and does not fall back silently.
    6. Turn Wi-Fi off and on: it reconnects.
    7. Audio stays glitch-free throughout (no dropouts, DAW CPU unchanged).
13. **File analysis:** a 1-hour file. Cancel at 50 %: "Analysis cancelled". Run it again and save the PDF: "Saving…",
    the window keeps drawing, then Show in Finder. Try saving to a read-only folder: a clear error, and the old file is
    untouched.
14. **Six languages:** the status actions, update banner and file-analysis states fit at 1280×720 in Japanese and
    Spanish.
