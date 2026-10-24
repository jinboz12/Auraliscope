# 2.0 RC licensing update — 2026-10-21

The earlier license conflict recorded below is resolved in the RC source: original code and project documentation
now use GPL-3.0-only. README, COPYRIGHT.md, the app About panel and package scripts use the same policy.
Official compiled packages may be sold; downstream GPL use, modification and redistribution remain permitted.
See SOURCE_DISTRIBUTION.md and ASSET_RIGHTS.md. Pearl public redistribution is confirmed by JINBOZ, and Milk Frog is identified by JINBOZ as public-domain material. Third-party SDK MIT and Apache-2.0 notices are retained.

The review below is historical (Build 55), not a review of the current feature set or proof of current ownership.

---

# Intellectual property and third-party rights review (1.2)

Reviewed for Auraliscope 1.2 rc 1 (build 55), 2026-09-27. This is an engineering review of where the code and
materials come from, their licenses, the trademarks the app names and the platform terms it relies on. It is
**not a legal opinion and not a patent freedom-to-operate search**. No one can certify from the code alone that a
product infringes no patent anywhere; before commercial distribution, have an IP attorney run a
freedom-to-operate search in the markets you ship to.

## Code and materials

| Item | Origin | Status |
| --- | --- | --- |
| Swift, C and Metal sources | Written for this project | No copied third-party code found. No `Package.swift` dependencies; only Apple system frameworks are linked. |
| Spectrogram | Written for this project (rewritten in 1.3dev build 68: multi-resolution analysis, float history, own color scale, axes and inspector) | Own work. The earlier credit to AudioSpectrogram (MIT) for design cues was removed with the rewrite; nothing of it remains. |
| App icon | `SoundmeterIcon/` (the project's own artwork) | Own work. |
| Brand mark | Two hexagons drawn in code (`Brand.swift`) | Own work; no SF Symbol or font glyph in the logo or icon. |
| Interface icons | SF Symbols, through SwiftUI | Used as interface symbols, which Apple's SF Symbols terms allow; never in the app icon or logo. |
| Fonts | macOS system fonts, not bundled | No font license needed. |

## Platform terms

- **Documented APIs only.** 1.2dev build 52 read the System Audio Recording permission through a private TCC
  function. Apple's developer agreement allows documented APIs only, so it was removed for 1.2 rc 1; the Settings
  row offers the System Settings shortcut instead. A scan finds no other `dlopen`, `dlsym`, selector-by-name or
  private-framework use.
- **Output capture** uses Apple's documented Core Audio process tap API (macOS 14.2+) and a plain device IOProc,
  the pattern Apple documents for taps. The permission behaviour (a HAL input unit on a tap counts as microphone
  use) was confirmed from public write-ups (lurar, Klang-audio) and on this Mac; no code was taken from them.

## Trademarks

The loudness target menu names Spotify, YouTube, Tidal, Apple Music, Dolby Atmos Music and Netflix, only to
identify the loudness numbers those services publish (nominative use). 1.2 adds a notice in About, the README (all
three languages) and `THIRD_PARTY_NOTICES.md` that these are their owners' trademarks and that Auraliscope is not
affiliated with, sponsored by or endorsed by them. The multichannel mode is called "Immersive", not "Atmos", and
the README states that it does not encode, decode or certify Dolby Atmos. "Pro Tools" and other device names appear
only as macOS reports them.

## Standards and algorithms

- Loudness, loudness range and true peak follow the published ITU-R BS.1770-5, EBU R128 / Tech 3342 and ATSC A/85
  texts; the VU needle follows IEC 60268-17 ballistics. These documents are freely available; implementing a
  standard does not by itself grant or require a patent license, and no search of the ITU patent-statement
  database or national patent registers was made here. Checking the ITU-R patent statements for BS.1770 is a cheap
  first step for the attorney.
- Everything else is long-established signal processing and graphics: FFT spectra and spectrograms (Apple
  Accelerate), min/max waveform envelopes, goniometer-style stereo display, phase correlation, spectral-peak pitch
  estimation, Catmull-Rom curves and critically damped display smoothing.

## Open points for the owner

1. **Patents:** no freedom-to-operate search has been made (see above).
2. **License wording disagrees:** `README.md` says unmodified copies may be shared non-commercially under
   CC BY-NC-ND 4.0, while `COPYRIGHT.md` says there is no project-level license and access grants no right to copy
   or redistribute. Decide which applies and make the two agree.
3. **Netflix target:** Netflix specifies −27 LKFS *dialogue-gated*; Auraliscope measures programme loudness. The menu
   names the number Netflix publishes; it should not be presented as a compliance check.
4. **Distribution:** builds are ad hoc signed and not notarized; this concerns Apple's distribution requirements,
   not third-party rights.
