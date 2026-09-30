# Auraliscope Bridge / Auraliscope Labs 1.3dev: validation report

Build: Auraliscope Labs 1.3dev build 2 with Auraliscope Bridge 1.3dev build 2 (VST3 and AUv2), protocol version 2,
branch `claude/auraliscope-daw-bridge-187076` (started from `a004a5b`; Auraliscope 1.2.2, `10e35cd`, merged in).
Mac: Apple M1 Max, macOS 27.2, Xcode 27.0. Logs are in `.build/bridge/validation/` (not committed). Tests use the
deterministic signal L = 997 Hz at 0.5 (−6.021 dBFS), R = 1499 Hz at 0.25 (−12.041 dBFS); a swapped, duplicated or
scaled channel cannot pass.

The evidence is kept apart by kind: **automated** (unit and transport tests, validators), **test host** (the real
plugin binaries in `Bridge/Tools/HostHarness`, not a DAW), and **DAW runtime** (REAPER 7.80 scripted; Logic Pro 12.4
and Cubase 15.0.30 driven through their user interface). Timing figures are measurements on this Mac, not guarantees;
the guarantees are structural (what the audio thread does and does not do) and are listed separately.

## Host compatibility matrix

| Host (format) | Loads, names the insert | Live stream exact | Transport stop | Bypass | Deactivate | Offline render | Duplicate / copy | Project reopened | Unload / reload |
|---|---|---|---|---|---|---|---|---|---|
| REAPER 7.80 (VST3) | yes; track name and channel ID (`IInfoListener`) | yes, 0 lost | keeps processing: streaming silence | stops calling: "no audio" | — | offline, nothing sent live; bounce = source (≤ 7.5·10⁻⁸) | copy flagged; Labs stays on the original | original restored by itself | original found again (channel ID) |
| REAPER 7.80 (AU) | yes; track name (`ContextName`) | yes, 0 lost | same | same | — | same | same | same | original found again (known copy) |
| Logic Pro 12.4 (AU) | yes, after Logic's own AU validation; track name; runs in `AUHostingServiceXPC_arrow` | yes, 0 lost | stops calling: "no audio", one break on resume | stops calling: "no audio" | — | offline, nothing sent live; bounce = source outside Logic's own clicks | pasted insert flagged as copy | original restored by itself | not tested |
| Cubase 15.0.30 (VST3) | yes; track name | yes, 0 lost | keeps processing: streaming silence | **"bypassed"** (the plugin's bypass parameter) | "inactive", then streaming | offline, nothing sent live; export = source (≤ 7.5·10⁻⁸) | duplicated track flagged as copy | original restored by itself | not tested |
| Ableton Live 12.4.5 Lite (VST3) | not tested: a macOS Local Network permission prompt for Live blocks its window (see below) | | | | | | | | |
| FL Studio, GarageBand | not tested (GarageBand is sandboxed: see ARCHITECTURE.md) | | | | | | | | |

"Live stream exact" means peaks −6.021 / −12.041 dBFS and integrated loudness −7.76 LUFS measured by Labs' own
pipeline, with no frames lost. Every host passed the audio through unchanged.

## Automated validation

| Check | Result |
|---|---|
| Steinberg VST3 validator, extensive (`-e`) | **537 passed, 0 failed** |
| `auval -v aufx Abrg Jnbz` and `auval -strict` | **AU VALIDATION SUCCEEDED** (both) |
| Transport tests (`test-transport.sh`: plugin core and receiver, private socket) | **69/69**; clean under ThreadSanitizer (`ABR_SANITIZE=thread`) |
| Analysis tests (`test-analysis.sh`: break marks, each analyser at a break, restoration rules) | **47/47** |
| Release core checks (`scripts/test.sh`, unchanged from 1.2.2) | **42/42** |
| Localization checker | **PASS**, 331 keys in en, zh-Hans, ko |

The transport tests cover discovery and metadata of several instances; bit-exact stereo and mono; nothing sent before
subscription; subscription numbers (audio queued before an unsubscribe or an A → B → A re-selection is never
replayed); a one-second receiver stall (the plugin drops, the receiver counts exactly the frames lost, the audio
thread never waits); a host pause announced by a block that was itself discarded as late is still reported, with its
idle time; format changes held back until re-attached; bypass, offline, restart and idle breaks with their reasons;
a timeline jump counted but not a break; identity (restored, copied, reidentified); 1,600 instances created and
destroyed on 8 threads (the lifecycle deadlock); a receiver of another protocol version; one-click focus; DNS-SD.

The analysis tests compare each analyser across a break with the uninterrupted case: K-weighting, momentary and
short-term restart; integrated loudness and loudness range carry on; true peak is never measured across the cut; the
spectrum window never mixes both sides; the waveform notch; the snapshot's break count and missing time. The
restoration rules are tested case by case (same session, single holder, copies, known copies, two DAWs, channel ID,
saved-context tie-breaks, selections saved by build 1).

## Structural guarantees (audio thread)

`BridgeCore::process` reads atomics, compares the host transport with the previous block, and when the insert is live
and subscribed copies the block into a preallocated ring. It performs no allocation, takes no lock, makes no system
call and does no logging (the AudioUnitSDK's own logging is compiled out with `AUSDK_NO_LOGGING`). Everything else
runs on one sender thread per plugin binary. Measured worst `process()`: under 35 µs per 256-frame block in the
test host, and it does not grow during a one-second receiver stall.

## Test host (real binaries, no DAW)

`e2e-probe.sh`: **10/10**: VST3 and AU at 44.1, 48, 96 and 192 kHz, mono and stereo, blocks 64–1024, several
instances with the 2nd or 3rd selected, and the editor opened and closed while streaming. Plugin output identical to
input; received audio bit-exact; 0 lost.

`e2e-app.sh`: **9/9** scenarios through Labs' own analysis (`--bridge-selftest`): reconnection, mono AU, three
instances, rate change mid-stream, the five plugin states, Labs quit and relaunched during playback, a duplicated
insert (ambiguous until chosen, then the chosen copy is measured), the same live instance re-identifying (analysis
carries on, break counted), and the connection dropped for 1.5 s (measurement held, then carried on with integrated
loudness unchanged at −7.76 LUFS).

## DAW runtime

### REAPER 7.80 (evaluation), private profile, silent virtual device: `e2e-reaper.sh`, all passed

For each format: the live script (play, plugin window opened and closed, FX bypass, stop, play, quit), an offline
render, the identity script, and a reopen of the saved project.

- **Live:** peaks −6.021 / −12.041 dBFS at 48 kHz, 0 lost; states streaming → no audio (FX bypass) → streaming
  (stop keeps REAPER processing) → measurement held (REAPER quit).
- **Offline render:** reported offline, no audio delivered as live (REAPER creates the insert live and flags offline
  before rendering); the render equals the source within 7.5·10⁻⁸ (24-bit step 1.2·10⁻⁷).
- **Identity and transport:** the analysed track is duplicated while playing (the copy flagged, Labs stays on the
  original); a loop and a locate are counted as 6 timeline jumps and are not breaks; the project goes to 44.1 kHz and
  back (analysis rebuilt each time, one restart break each); the original insert is unloaded and reloaded: Labs holds
  the measurement, then finds the original again: VST3 by REAPER's channel ID, AU because the copy was seen being
  made. The saved project holds two distinct identities.
- **Reopen:** the project reopened, Labs found the original insert by itself (not the copy) and measured it.

### Logic Pro 12.4 (AU), a new project from the test AIFF, driven through its interface

Logic validated and listed the plugin (Audio FX ▸ Auraliscope Bridge ▸ Stereo / Dual Mono). Logic hosts it out of
process (`AUHostingServiceXPC_arrow`); the connection, the host name ("Logic Pro") and the track name all work from
there. Live: exact, 0 lost; stop and bypass both stop Logic calling the plugin ("no audio"), one break on resume.
Bounce (offline, Normalize off): reported offline throughout, nothing delivered as live. The bounced file differs
from the source only where Logic's metronome click and a start transient are printed into it; a bounce with the
Bridge bypassed has the same differences, and every sample outside them equals the source within 2 LSB at 24 bits.
(The new project also puts Mastering Assistant on the Stereo Out, which was bypassed for the comparison.) Copy: the
Bridge Option-dragged to the Stereo Out carries the original's state; it was flagged as a copy (both instances share
the XPC host process, so the plugin's registry sees both). Reopen: saved, Logic quit, reopened; Labs found the
original by itself.

### Cubase 15.0.30 (VST3), a new empty project in a test folder, driven through its interface

Listed under Analyzer. Live: exact, 0 lost. Stop: Cubase keeps processing (streaming silence). The bypass button uses
the plugin's bypass parameter, so Labs shows **bypassed**; the on/off button deactivates the plugin (**inactive**),
and reactivating resumes streaming. Audio Mixdown (not real time): reported offline, nothing delivered as live, and
the export equals the source within 7.5·10⁻⁸. Project ▸ Duplicate Tracks: the copy ("bridge-test-48k (D)") flagged,
Labs stays on the original. Reopen: saved, Cubase quit, reopened; Labs found the original by itself.

### Ableton Live 12.4.5 Lite: not tested

On launch, Live rescanned all plugins and macOS asked whether "Ableton Live 12 Lite" may find devices on local
networks. That prompt blocks input to Live, and answering it changes a privacy setting, which was left to the user.
The prompt was not caused by the Bridge: the Bridge browses the network only after its Scan button is clicked.

## Not verified here

- Ableton Live (above), FL Studio, GarageBand; unloading and reloading an insert in Logic or Cubase.
- Real iOS devices: there is no iOS app. Discovery was checked with a local-only DNS-SD beacon.
- The production transport with a team signature (`probe-sandbox-transport.sh` was run ad hoc signed only).
- Intel Macs: the plugins are universal but ran on arm64 only.
- The output-tap source in Labs (needs System Audio Recording permission for Labs itself).

## Known limitations

1. Labs is not sandboxed; the release is. See ARCHITECTURE.md, "Production transport", for the recommended carrier.
2. Mono and stereo only; other bus widths are refused.
3. Two DAWs (or two processes of one host) holding the same project cannot see each other's copies: Labs tells them
   apart by host and context, or says the choice is ambiguous.
4. One analysed insert at a time; the others send status only.
5. A host that never flags offline rendering would stream a bounce faster than real time; the drop policy protects
   the DAW, but Labs would meter it as live. REAPER, Logic and Cubase all flag it.
6. Hosts differ in how they express stop and bypass (see the matrix); Labs reports what reaches the insert.
7. The plugin window is English only; Labs is localized (en, zh-Hans, ko).
8. Ad hoc signed, not notarized.
