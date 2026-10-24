# Auraliscope Bridge

A VST3 and Audio Unit (v2) plugin that lets Auraliscope meter a track, bus or master inside a DAW. The plugin analyses
its own audio with the same analysis code the app uses and sends only the results to Auraliscope over a local socket.
The audio passes through unchanged. The audio thread does no analysis, allocation or locking.

- Formats: mono, stereo and immersive beds from 3.0 to 9.1.6 (VST3), mapped to speaker roles from the host's speaker arrangement.
- Pause and Reset in the app reach every connected plugin. Several inserts can run at once; pick one as the source.
- Requirements: macOS 11 or later, Apple silicon and Intel. Install with the Auraliscope package.
- Multi-FFT Spectrum (Beta) needs local audio. With the Bridge, the app shows the original spectrum analysis.

## Layout

| Path | Contents |
| --- | --- |
| `Plugin/Core`, `Plugin/Analysis` | Pass-through processing, capture ring, analysis and sender threads |
| `Plugin/VST3`, `Plugin/AU`, `Plugin/Editor` | Format wrappers and the small plugin window |
| `../Sources/AnalysisCore`, `../Sources/AnalysisKernels` | Shared DSP (also used by the app) |
| `../Sources/BridgeTransport` | Socket transport and result decoding in the app |
| `Tools/`, `Tests/` | Host harness, probes, REAPER scripts and transport/result tests |
| `scripts/` | Fetch SDKs, build, test, package (`release-version.sh` sets the shared version) |

## Build and test

```sh
scripts/fetch-sdks.sh
scripts/build-plugins.sh
scripts/e2e-probe.sh stereo-48k   # VST3 and AU: output identical to input, results arrive
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the threads and data flow, [PROTOCOL.md](PROTOCOL.md) for the wire format
and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the SDK licences.
