# Auraliscope Bridge / Auraliscope Labs 1.3dev: validation report

Prototype build: Auraliscope Labs 1.3dev build 1 with Auraliscope Bridge 1.3dev build 1 (VST3 and AUv2), branch
`claude/auraliscope-daw-bridge-187076` from `a004a5b`. Mac: Apple M1 Max, macOS 27.2, Xcode 27.0. All logs are in
`.build/bridge/validation/` (not committed). Tests used the deterministic signal L = 997 Hz at 0.5 (−6.021 dBFS),
R = 1499 Hz at 0.25 (−12.041 dBFS); a swapped, duplicated or scaled channel cannot pass.

The evidence is kept apart by kind: **build**, **automated validation**, **test host** (the real plugin binaries
loaded by `Bridge/Tools/HostHarness`, not a DAW), and **DAW runtime** (REAPER 7.80).

## Build

| Item | Result |
|---|---|
| VST3 bundle, universal arm64 + x86_64, exports only `GetPluginFactory`, `bundleEntry`, `bundleExit` | built, ad hoc signed, `codesign --verify --strict` passes |
| AU bundle, universal, exports only `BridgeAUFactory` | built, signed, verified |
| Auraliscope Labs.app (`com.jinboz.SoundMeterJBZ.Labs`, 1.3dev build 1, beta icon) | built, signed, identity checked in the binary |
| Existing app sources | still build; `Resources/Info.plist` and `scripts/` unchanged |

## Automated validation

| Check | Result |
|---|---|
| Steinberg VST3 validator, extensive (`-e`) | **537 passed, 0 failed** |
| `auval -v aufx Abrg Jnbz` and `auval -strict` | **AU VALIDATION SUCCEEDED** (both) |
| Transport tests (`test-transport.sh`: plugin core and receiver, private socket) | **37/37**, five consecutive runs |
| Existing core checks (`scripts/test.sh`) | **31/31** |
| Localization checker | **PASS**, 315 keys in en, zh-Hans, ko |

The transport tests cover: discovery and metadata of several instances; bit-exact stereo and mono; nothing sent before
subscription; worst `process()` 7.7–27 µs; a 1 s receiver stall (plugin dropped 21 056 frames, receiver counted exactly
21 056 lost in 1 gap, delivery recovered to real time, audio thread never waited); format change (audio of the new
epoch held back until re-attached, then exact at 96 kHz mono); bypass and offline (nothing sent, position frozen,
discontinuity flagged on resume); state save/restore; receiver restart and plugin reconnection; instance removal;
one-click focus; DNS-SD advertise, find, resolve (TXT keys) and removal.

## Test host (real binaries, no DAW)

`e2e-probe.sh`: the test host plays the built VST3 or installed AU; the standalone receiver compares every sample.

| Case | Plugin output | Received |
|---|---|---|
| VST3 stereo 48 kHz, block 256 | identical to input | ~287 k frames bit-exact, L 0.5000 / R 0.2500, 0 lost |
| VST3 mono 44.1 kHz, block 128 | identical | bit-exact, 1 ch |
| VST3 stereo 96 kHz, block 512 | identical | bit-exact |
| AU stereo 48 kHz / mono 48 kHz (block 64) / stereo 192 kHz (block 1024) | identical | bit-exact, 0 lost |
| 3 VST3 / 3 AU instances, receiver selects the 2nd / 3rd | identical | exactly that instance's level (½ / ¼) |
| VST3 and AU editor opened, captured, closed during streaming | identical | continuous, bit-exact |

`e2e-app.sh`: the same binaries into Auraliscope Labs, checked by its own analysis pipeline (`--bridge-selftest`).

| Scenario | Result |
|---|---|
| VST3 stereo 48 kHz; plugin removed, same insert returns (same project ID, new session) | peaks L −6.021, R −12.041 dBFS; "disconnected · waiting"; resumed by itself; same peaks; 0 dropped |
| AU mono 44.1 kHz | 1 ch, 44.1 kHz, L −6.021 dBFS, R silent |
| Three instances, "Multi 2" selected | L −12.041, R −18.062 dBFS |
| AU 48 kHz → 96 kHz mid-stream | analysis rebuilt at 96 kHz; peaks unchanged |
| Live, bypass, offline, host stops calling, live | streaming → bypassed → offline → no audio → streaming |
| Labs quit and relaunched during playback | host output bit-identical throughout; second launch streams again |
| One click in the plugin window with Labs not running | Labs launched from ~/Applications, connected, selected the insert; window read "Streaming to Auraliscope Labs", 325 k frames sent, 0 dropped |
| Scan card | "This Mac · Auraliscope Labs 1.3dev · connected"; simulated iPad (DNS-SD beacon, this Mac only) listed as "Auraliscope for iPadOS 1.4" |

Existing sources in the Labs build: input capture self-test on Pro Tools Audio Bridge 6 (scrambled routing) **PASS**;
synthetic input/output removal and return **6/6 PASS**. The output-tap self-test reads silence from this shell, and
so does the unmodified `a004a5b` build: System Audio Recording is not granted to this launch context. Not a
regression, but not verified here (see manual steps).

## DAW runtime: REAPER 7.80 (evaluation), private profile, silent virtual device

`e2e-reaper.sh`. REAPER discovered and loaded both formats (VST3 via its scan, AU via the system registry) and passed
the track name to the plugin (VST3 `IInfoListener`, AU `ContextName`).

| Format | Live (with Auraliscope Labs) | Offline render |
|---|---|---|
| VST3 | peaks −6.021 / −12.041 dBFS at 48 kHz, 0 lost; plugin window opened and closed without interruption; states streaming → no audio (FX bypass) → streaming (stop keeps REAPER processing) → disconnected (quit) | reported offline only, no audio delivered as live; bounce equals source within 7.5·10⁻⁸ (24-bit step 1.2·10⁻⁷) |
| AU | same as VST3 | same; REAPER creates the AU live and flags offline ~0.1 s later, before rendering |

REAPER's FX bypass stops calling the plugin instead of using its bypass parameter, so Labs shows "no audio: the DAW is
not processing it" rather than "bypassed" (the bypassed state was verified through the test host).

## Not verified here

- **Logic Pro, Cubase 15, Ableton Live 12 Lite, FL Studio:** installed but not driven. There is no command-line
  automation for them in this environment, and GUI automation was unavailable. Follow the manual steps in
  README.md. AU validation passing is what Logic's plug-in manager requires.
- **Real iOS devices:** there is no iOS app yet. Discovery was checked with a local-only DNS-SD beacon; browsing a real
  network and the Local Network permission prompt in each DAW were not exercised.
- **Output-tap source** in Labs (needs System Audio Recording permission for Labs itself).
- **Intel Macs:** the plugins are universal but ran on arm64 only.

## Known limitations and open issues

1. Labs is not sandboxed (see ARCHITECTURE.md, "Sandbox finding"); a sandboxed release needs a team-signed
   rendezvous (app group or XPC). Sandboxed hosts (GarageBand) cannot connect.
2. Mono and stereo only. Wider buses are refused by the plugin (VST3 arrangement, AU channel info); Labs shows other
   counts as "only mono and stereo are supported".
3. Copies of a track share the saved project ID; Labs lists each copy, but after a reload it resumes with the first
   copy to connect.
4. One analysed instance at a time; others are listed and idle (they send status, not audio).
5. A host that never flags offline rendering would stream a bounce faster than real time; the drop policy keeps the
   DAW safe, but Labs would meter it as live. REAPER flags it for both formats.
6. The 128 KB socket buffers and 150 ms queue bound latency. On a heavily loaded Mac, analysis may show gaps (counted
   in the status bar), never back-pressure into the DAW.
7. The plugin window is English only; Labs strings are localized (en, zh-Hans, ko).
8. Not notarized; first launch of Labs from Finder needs right-click ▸ Open. The plugins load in the tested hosts
   ad hoc signed.
9. Labs launched by a plugin may briefly show "Waiting for the DAW plugin to connect…" (under a second).
