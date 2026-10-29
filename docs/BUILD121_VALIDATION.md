# Build 121 delivery validation

Version: 2.0 stable, build 121; Bridge 2.0.121. Source inherits Build 120 and the completed integration documented in RELEASE_2.0_INTEGRATION.md.

App and plugins: Developer ID Application: Jinbo Zhang (ZND35QTNDY), hardened runtime and secure timestamp. Installer: Developer ID Installer: Jinbo Zhang (ZND35QTNDY). The delivery runner verifies bundle signatures and installer payloads, and supplies SHA-256 hashes and corresponding source including pinned SDKs.

Apple notarization is deferred by the owner for this release. The published assets are Developer ID signed but not notarized; Gatekeeper may still require manual approval.

Prior integration checks: all nine check-all steps, model lifecycle, settings/presets, core golden references, Bridge analysis, transport under TSan, network loopback with VST3 and AU. Build 121 repeats release builds, version synchronization, update fixture checks, localization and package checks. Physical audio hardware, real DAWs and physical iPad/Wi-Fi acceptance remain outstanding. No installation or live-device configuration was performed.
