# Auraliscope — update log from 1.2.2 (build 62) to 2.0 RC 2 (build 118)

Auraliscope 2.0 is the largest update since the first release. It adds a DAW plugin, immersive metering up to 9.1.6,
a rebuilt spectrogram, file analysis with a printable report, a new interface with flexible layouts, six languages and
settings presets. This log covers every build from 63 to 118, newest first, then the whole 2.0 picture in one list.

| Builds | Stage | In short |
| --- | --- | --- |
| 118 | 2.0 RC 2 | Multi-FFT matches the other panels; opt-in pre-release updates |
| 107–117 | 2.0 RC 1 | Stability, licensing, appearance fixes, welcome tutorial, settings presets, feedback links, Multi-FFT Beta |
| 92–106 | 2.0 beta | File analysis, new report, Dock mode, speaker layouts, Radiant body, routing, themes, languages |
| 91 | 2.0 | First 2.0 package: LABS work brought into the normal app |
| 89–90 | 2.0dev | Panel windows, layouts, strip, calibration, frame rate |
| 63–88 | 1.3dev (tested as "Auraliscope LABS") | Bridge plugin, immersive Soundstage, spectrogram rewrite, redesign |

---

## 2.0 RC 2

### Build 118 — Multi-FFT look and pre-release updates

- The Multi-FFT plot sits in the Spectrum card's inset well with its axis type, grid weights and label positions;
  curves use the Waveform's channel colours and the key moves into the title row. The footer readout (update rate,
  window delay and a running analyser clock) is removed: rate and delay are in the panel's settings.
- Settings ▸ General ▸ Updates ▸ **Include pre-releases** (off by default) checks GitHub's release list and offers the
  newest verifiable release of either kind; a final release outranks a pre-release of the same version and build.
  The stable channel is unchanged.

---

## 2.0 RC 1

### Build 117 — Multi-FFT engine and plot optimization

- Each FFT zone now separates, calibrates and converts to dB only the bins the fusion reads (about 2–8 % of all
  bins), windows with two vector multiplies instead of a modulo per sample and reuses its scratch. Calibration,
  fusion weights, smoothing, timing and settings are unchanged; a new check proves the read-range and exhaustive
  paths agree exactly. Engine cost falls about 7× (Standard 48 kHz 1.80 % → 0.25 % of one core).
- The plot keeps its grid and labels in a separate canvas redrawn only on axis changes or resizes; curves redraw
  once per engine frame. A short grace period keeps the engine and its history when the panel moves between the
  grid, the Dock and its own window; disabling or removing the panel still stops it.
- Preference changes during a divider drag no longer re-decode the Multi-FFT configuration.

### Build 116 — Multi-FFT resizing and Dock replacement

- Add a persisted, resettable height divider for Multi-FFT in the main grid; independent windows remain resizable.
- Resolve one saved Dock spectrum slot to Multi-FFT when enabled for Stereo local PCM, retaining order and width
  across disable/re-enable, resize and menu actions. Stop drawing the replaced legacy canvases.
- Compact narrow-card headers/readouts and keep flexible cards nonzero in very narrow Dock layouts.

### Build 115 — GitHub updates and hidden-panel rendering

- Add manual stable GitHub Releases checks in the app menu, About and General settings, with version/Build
  comparison and explicit network/unavailable/error states.
- Gate native Metal/VU drawing by panel placement and physical visibility, pause per-panel SwiftUI timelines,
  and stop/restart the shared display link as eligible views leave/return.
- Preserve visible detached-window drawing and all ongoing measurements.

## Build 114 — optional Multi-FFT Spectrum Beta

- Start from the delivered Build 113 source; preserve the original package.
- Add a hidden Stereo panel with three independent, sample-centred FFT windows, raised-cosine frequency fusion,
  tone/PSD calibration, five presets, priority policies and editable advanced settings, including optional M/S.
- Local Classic displays share a selectable 2048/4096/8192 Hann STFT (default 4096); original analysis remains an
  A/B option. Enhanced, Immersive and Bridge retain their original analysis.
- Stop/release the extra engine when the panel closes; keep FFT work off the audio callback and drawing path.
- Multi-FFT Bridge transport and real hardware/DAW validation remain follow-up work.

## Build 113
- **The status bar shows the live display frame rate** beside the analysis rate (for example "60 Hz analysis ·
  30 fps display"), so Settings ▸ General ▸ Display frame rate is visible at a glance. It used to read a fixed
  "60 Hz", the analysis rate, whatever the setting.

### Build 112
- **Feedback** in Settings ▸ General: links to jinbozmusic.com and the Auraliscope Discord, with a pointer to the
  diagnostic logs for bug reports.

### Build 111
- **Settings presets live as files.** Each preset is its own file in
  `~/Library/Application Support/Auraliscope/Settings Presets`, named after the preset, so it can be backed up or
  copied to another Mac. The folder is watched: a preset renamed, copied in or removed in the Finder shows at once.
  Presets saved in build 110 move there on first launch.
- **Duplicate** a preset ("<name> Copy", numbered if taken) and **Show in Finder** from each preset's ··· menu. A folder
  button beside Save Current Settings… and Auraliscope ▸ Settings Presets ▸ Show Presets in Finder open the folder.
- Deleting a preset now **moves it to the Trash**, so it can be recovered.

### Build 110
- **Welcome tutorial.** Three pages with Back / Next: what the app does (choose a source, pick a mode, read then
  report), the seven panels in a line each with how to enlarge, detach and dock them, then microphone and system audio
  access.
- **Glowing stereo Dots.** Each stereometer sample is a soft glow in its band's colour with a bright spark when new; on
  dark the light adds up and burns toward white where the programme gathers, like the Immersive view. The trail is
  capped so a band switch never overflows the drawing buffer.
- **Loudness panel** drops its inner plate; the readings sit on the card as in Dock mode.
- **Immersive defaults to 9.1.6** until a format is chosen. Existing choices are kept.
- **Settings presets** (new): save the current settings under a name, then load, update, rename or delete them, from
  Settings ▸ General ▸ Presets or the app menu. The source and its routing stay with your devices.

### Build 109
- Plain palette names in every language (Sakura Pink, Milk Frog); Studio Console separated by a menu divider.
- One full-window backdrop behind the content and the toolbar, in the window and in full screen (no odd-coloured strip
  at the top, no flat full-screen toolbar).
- Pearl's dark backdrop is less saturated; the light appearance and signal colours are unchanged.

### Build 108
- **Dock mode** no longer leaves an empty band at the top.
- **About** is shorter: brand, version, author, project link, diagnostic logs, copy version, and the licences.
- **Loudness presets use neutral names** (streaming loud, music streaming, music & podcasts, immersive music, online
  video, film & series dialogue) everywhere: menus, summary, file analysis, PDF and CSV. Targets, ceilings and saved
  choices are unchanged. Technical standards keep their names (ITU, EBU, ATSC, ARIB, OP-59, ASWG-R001).

### Build 107
- Smoother handover between the grid, an enlarged panel and Dock mode (renderers and their memory are reused).
- Safer GPU sharing during transitions and appearance changes; redraws retry after a busy GPU.
- Settled displays stop after two seconds at any refresh rate (less idle work at 120 fps).
- Speaker geometry is cached until a layout changes.
- Dock mode respects the screen's top safe area.
- **GPLv3 licensing** and third-party notices in the app, plugins, installer and source archive.

---

## 2.0 beta

### Build 106
- **Japanese, Traditional Chinese (Taiwan) and Spanish (Spain)**, beside English, Simplified Chinese and Korean, for the
  whole app, the panels' settings, file analysis and the PDF report.
- **Type the loudness target and true-peak ceiling** (for example −14, 14 or "−14.5 LUFS").
- **Panel settings in titled groups**, with the panel's name at the top.
- **Smoother motion:** Stereo ↔ Immersive hands over instead of double-exposing; enlarging grows a panel out of its
  place; Dock mode no longer stretches the content on the way in or out.
- A wider divider range between the analyzers and the Soundstage; titles in the wordmark's font; a quieter dome.
- Fixed: the stereo band legend overlapped BALANCE and WIDTH; long report notes ran off the page.

### Build 105
- **Pearl** becomes the default colour (blue, pearl white and rose), with its reference image as a quiet backdrop.
- A shorter palette list (11 choices); removed themes move to their nearest neighbour.
- **Milk Frog** becomes the playful theme, with the supplied frog photograph.

### Build 104
- New palettes: Icon Pearl, Sakura Pink, Milk Frog, Mist Lilac, Slate Blue.
- **Studio Console**, an optional hardware-style theme: machined modules, recessed bezels, raised keys and a warm
  backlit VU dial, with the same layout and meter behaviour as the other themes.

### Build 103
- **New look:** frosted glass over a deep, nearly colourless night (a grey haze on light), soft light and shade, round
  buttons that rise, sink and glow, gentle springs and symbol motion. Reduce Motion turns it all into short fades.
- **Colour themes:** Indigo, Sage and Starlight, joined by Cobalt, Glacier, Lagoon, Mint and Graphite.
- **Always on top starts off.** The horizontal strip is renamed **Dock mode** (⌥⌘S).
- Settings pages line up; SF Symbols on every text-only button.

### Build 102
- **Crisper Radiant body:** its light starts half as wide and swells less as it ages, with a firmer edge, so sources
  read as shapes rather than haze.
- Fixed: the Filled stereometer left dark wedges between the bands and the horizon.

### Build 101
- **Radiant body** becomes the default Immersive style: each frequency band sits where the speakers that carry it place
  it, drawn as one glowing volume in the frequencies' colours, with point lights on top (Soundstage settings ▸ Points).
- **Routing follows Audio MIDI Setup** (Configure Speakers) for any device not routed by hand, live while metering;
  virtual devices are read from their output side.
- **Channel Order menu:** Audio MIDI Setup, SMPTE / ITU, Film (Pro Tools) and VST3 (Nuendo, Cubase).
- Fixed: Pro Tools surround could appear at the front, and a 9.1.6 mix from Nuendo or Cubase misplaced ten of its
  sixteen channels (the host's order was read as SMPTE). The Bridge plugins were never affected.

### Build 100
- Radiant in the Level body's palette; a new app icon with dark, clear and tinted versions on macOS 26.
- **Smoother motion and ProMotion:** displays advance by the time each frame reaches the screen, so the spectrogram and
  waveform scroll evenly with large DAW buffers; Automatic frame rate runs at 120 fps on ProMotion displays.

### Build 99
- **Film Order** for surround sources whose surrounds arrive at the front.
- **Listener's head** in the dome, facing front, so direction reads at a glance (Soundstage settings ▸ Listener).

### Build 98
- **Your own speaker layout:** place each speaker by azimuth, elevation and distance, or leave one out; mirror, duplicate,
  rename, export and import as JSON. The dome and the spatial analysis (app and plugins) use it.
- **Radiant from one exact reduction:** a band's brightness and position no longer depend on the Particles setting,
  and the plugin and the app draw the same picture.
- **Spatial window: Standard or Fast**, and **Raw observations** for checking placement.

### Build 97
- In Dock mode, drag the gap between Spectrogram and Spectrum to share the width.

### Build 96
- **Show and hide panels** from a toolbar list with checkboxes; Show All Panels; return a detached panel from the list.
- **Resizable dock:** drag the gaps between its panels; double-click or Reset for the automatic split. **Minimize**
  the dock with its − button or ⌘M.
- Fixed: after switching Light / Dark, the toolbar title could keep the old appearance.
- **Smaller and lighter:** the app is 44 % smaller (11.4 → 6.3 MB), the plugins about 40 % smaller, about 9 % less
  main-thread work while metering. No reading changed.

### Build 95
- The PDF report's panels match the main window more closely; quieter headers and a status-light verdict.
- Light-mode toolbar with pale frosted tracks and dark selected keys.

### Build 94
- **File analysis in the main window** (toolbar button or ⌘O), with the file chooser as a sheet.
- **Redesigned PDF report** with the night header, rounded cards and capsule verdicts.
- New icons for going into and out of the strip.

### Build 93
- **Spectrogram and Spectrum side by side** in the horizontal strip, the spectrum running left to right with hover
  readings.
- Fixed: toolbar and title placement after resizing the strip; a half-second freeze going into the strip; the strip
  opening full-size.
- Moving, hiding and enlarging panels is smoother (panel rims drawn on the GPU).

### Build 92
- **Analyze Audio File… (⌘O):** measures a whole file (WAV, AIFF, CAF, MP3, AAC, ALAC, FLAC and more) with the live
  analysis, mono to 9.1.6, against any delivery standard; save the PDF or CSV. A five-minute file takes about two
  seconds.
- **Four-page loudness & master report** for live sessions (⌘E) and files.
- The LABS line becomes Auraliscope itself, installed as `/Applications/Auraliscope.app`; LABS settings carry over
  where Auraliscope had none. The Bridge plugins use the 2.0 connection.

---

## 2.0 (build 91)
- First 2.0 package: the Bridge, Soundstage and report work from LABS in the normal app, with production names.
- Report sections without measurements show "unavailable" instead of OK; streaming guidance corrected for quiet
  material; dialogue-gated loudness marked as not implemented.

## 2.0dev (builds 89–90)
- **Enlarge any panel** (⌘1–⌘7, Esc restores), **open it in its own window**, or **hide it**.
- **Horizontal strip** (⌥⌘S): a mini meter along the bottom of the screen, with the panels you choose.
- **Saved layouts** plus four built in. **VU calibration.** **Display frame rate** (Automatic, 60 or 30 fps).

## 1.3dev — tested as Auraliscope LABS (builds 63–88)
- **Auraliscope Bridge** VST3 and AU plugin (63 onward): insert it on a track or bus; it analyses its own audio and the
  app shows the result. Immersive VST3 buses from 3.0 to 9.1.6 (77). Pause and Reset act on the plugin too.
- **Spectrogram rewrite** (68–72): multi-resolution analysis, Enhanced (reassigned) mode, 3D landscape, colour maps
  and ranges, span, tilt, finer 128-band spectrum, response, smoothing, peak holds, average spectrum and a hover
  readout with note names.
- **Immersive Soundstage** (75–88): a dome you can orbit and zoom with Front, Top, Side and Iso views, the Level body,
  then the glowing Radiant view built from the analysis' own frequency bins.
- **Stereo stereometer** with Full, 3 or 5 bands as Dots, Outlines or Filled; balance, width and band correlation.
- **Loudness:** 14 delivery presets with verdicts, custom targets and ceilings, LU or LUFS, EBU +9 / +18 scales,
  history over 15 s to the whole session, peak hold and release options, an overs counter. Passes EBU Tech 3341
  (cases 1–6) and Tech 3342 (cases 1–4).
- **Waveform:** exact sample peaks, Linear or dB, 2 / 4 / 8 s, with a time ruler and readout. Redrawn VU meter.
- **New visual design** (73–76): frosted panels over a sky backdrop, round control docks, lit controls, per-panel
  settings, a new icon.

---

## Still not included
- Dialogue-gated loudness (the meter reads the full programme).
- Restoring detached panel windows and Dock mode at launch.
- Offline renders, Ambisonics, Auro and 22.2.

## Installing
Use `Auraliscope 2.0 rc 1 build 113.pkg` and choose the app, VST3 and/or Audio Unit. Install the app and the plugins
together. It replaces any 2.0 build in place and keeps your settings. The app runs on Apple silicon with macOS 13 or
later; the plugins are universal. The packages are ad hoc signed; the installer is unsigned and not notarized.
