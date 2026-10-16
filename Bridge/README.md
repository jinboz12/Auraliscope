# Auraliscope Bridge 2.0.91

The VST3 and Audio Unit companions to Auraliscope 2.0 build 91. Each insert analyzes audio on its own worker and sends
measurement results to the app over a same-user local Unix socket. Processing passes audio through unchanged.

VST3 supports named mono, stereo, surround and height layouts through 9.1.6. AU supports mono/stereo. Formats outside
the supported role map are declined. Plugin IDs remain compatible with earlier LABS inserts; install the matching
public app and plugins together. LABS and public 2.0 use separate sockets.

See the [main README](../README.md), [installation guide](../docs/INSTALLATION.md) and
[build 91 validation](../docs/2.0_BUILD91_VALIDATION.md). Historical BUILDxx notes describe their respective test builds,
not validation of this release. ARCHITECTURE.md and PROTOCOL.md contain implementation details; older prototype
terminology in those documents is historical.

```sh
Bridge/scripts/build-app.sh
Bridge/scripts/build-plugins.sh
Bridge/scripts/package-installer.sh
Bridge/scripts/package-dist.sh
```

Build tools: full Xcode, Swift 6, Python 3 and zsh. SDK dependencies are pinned by `fetch-sdks.sh`.

```sh
Bridge/scripts/test-transport.sh
Bridge/scripts/test-analysis.sh
Bridge/scripts/build-tools.sh
Bridge/scripts/e2e-probe.sh
```

The probe tests load the exact staged VST3/AU, use a private socket and verify results and unchanged audio output.
They do not install plugins or establish compatibility with every DAW. GUI end-to-end tests require a dedicated app
instance; close the normal app before running them. Optional network discovery is a preview, not remote audio analysis.

SDK licenses are in [third-party notices](THIRD_PARTY_NOTICES.md). Copyright © 2026 JINBOZ. All rights reserved.
