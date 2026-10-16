# Auraliscope 2.0 — build 91

Released October 16, 2026.

Auraliscope 2.0 brings the Bridge, Soundstage and reporting work from LABS into the normal application. This release
builds on the supplied 2.0 development build 90, with production naming and installation paths, clearer measurement
claims, refreshed documentation and a new package.

## Since 1.2.2

- Auraliscope Bridge VST3 and Audio Unit plugins with independent insert measurements, app selection, pause/reset and
  local result transport. Named immersive VST3 layouts extend through 9.1.6; AU supports mono/stereo.
- Refined spectrum and spectrogram analysis, calibrated tone readings, hover inspection, average spectrum and image export.
- Stereo and immersive Soundstage, Radiant and Level body styles, frequency bands and camera controls.
- Detachable/enlarged/hidden panels, saved layouts, horizontal strip and lower display frame-rate options.
- PDF/CSV loudness and master reports, DC offset/infrasonic measurements, loudness reference checks, LU and EBU scales,
  longer history spans, peak-hold/release options and VU calibration.
- New 2.0 icon and refined Light/Dark controls, with English, Simplified Chinese and Korean localization.

## Refined from build 90

- Promoted to **Auraliscope 2.0, build 91**, bundle ID `com.jinboz.SoundMeterJBZ`. Removed LABS/prototype labels from
  the product interface, menus, installer and plugin editor; renamed the visible Indigo theme while retaining its saved ID.
- Bridge plugins now carry version **2.0.91**. Their existing VST3 class, AU subtype and bundle identifiers remain intact.
- The launch button chooses a compatible normal app. A separate public socket prevents LABS from receiving its results.
- Netflix's full-programme result is informational, never a dialogue-compliance PASS. ARIB is marked as a reference
  until its current tolerance/ceiling can be verified. Removed the unverified Amazon Music association with −14 LUFS.
- Report sections with no available measurements now show unavailable instead of OK.
- Corrected the streaming explanation for quiet material and removed the fixed “60 Hz” footer claim when display
  frame rate is configurable.
- Updated README, installation/upgrade guidance, copyright, SDK notices and reproducible release packaging.

## Installation

Use **Auraliscope 2.0 build 91.pkg** and select the app and plugin formats you use. Requires Apple silicon and macOS 13+.
Quit the app and DAW first. The installer updates the normal app and selected Bridge plugins; LABS remains separate.
See [installation](docs/INSTALLATION.md). The binaries are ad hoc signed; the installer is unsigned and not notarized.

## Known limits

- Dialogue gating is not implemented. Mastering report thresholds are guidance, not a certification.
- Streaming normalization depends on the service, playback settings and album/track handling.
- Immersive VST3 supports the named layouts mapped by the Bridge; Ambisonics, Auro and 22.2 are not supported.
- Offline renders are not metered. Remote/iOS receivers are not included.
- Detached panels and strip windows are not restored automatically at launch.
- Intel hardware, older macOS versions and a broad real-DAW music-session matrix have not been revalidated for build 91.

See [build validation](docs/2.0_BUILD91_VALIDATION.md) for exact checks and boundaries.
