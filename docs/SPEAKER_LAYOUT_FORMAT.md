# Speaker layouts: file format and settings (build 98)

A speaker layout places the speaker roles of one channel format (5.1, 7.1.4, 9.1.6…) around the listening position,
for the Immersive dome and its spatial analysis. It never changes routing (which input feeds which role stays in
Settings ▸ Channels) or the channel format, and it never changes a level or loudness reading: every included or
excluded speaker's feed still counts there. Code: `SpeakerConfiguration`, `SpeakerLayoutDocument` and
`SpeakerLayoutStore` in `Sources/Auraliscope/SpeakerLayouts.swift`; the geometry the analysis uses is
`SpatialGeometry` in `Sources/AnalysisCore/SpatialGeometry.swift`.

## Where it is edited

Soundstage panel ▸ settings ▸ *Speaker layout* opens the Speaker Layout window: pick the channel format, then
*Standard <format>* or a saved layout. Editing any value of the standard layout saves a copy named *Custom <format>*
and selects it. *Duplicate*, *Rename…* and *Delete* act on the selected layout; *Mirror* copies one side's places to the
other (*Left to right*: each right speaker takes its left partner's place with the azimuth negated); *Import…* and
*Export…* read and write the file below. The preview draws the layout from the top, the front and the side.

## Coordinates

- Origin: the listening position. x to the right, y to the front, z up.
- **Azimuth**: degrees clockwise from the front, seen from above; left is negative (L at −30°). Stored wrapped into
  (−180°, 180°].
- **Elevation**: degrees up from the ear plane, −90° to 90°; negative below it.
- **Distance**: meters from the listening position, 0.1 to 100; unknown (null) is never taken for 1 m.
- A role's unit direction is u = (sin az · cos el, cos az · cos el, sin el).
- The LFE has no direction: whatever its placement says, it takes no part in the spatial picture.

## Mappings

| `mapping` | Radiant places each frequency at | Requires |
|---|---|---|
| `directions` (default) | the amplitude-weighted centre of gravity of the speakers' unit directions, Σ\|X_i\| u_i / Σ\|X_i\| (build 97's frame) | nothing |
| `positions` | the same centre of gravity of the speakers' positions, distance · u, in meters; the dome's scale is the farthest speaker | a distance for every included full-range speaker |

Both describe how the speaker feeds share the signal over the layout. Neither is a measurement of where a source is or
how far away it sounds. The Level body always uses the directions (its radius is a level, not a distance).

## The file (`.json`)

UTF-8 JSON. Export writes every field, keys sorted, an unknown distance as `null`:

```json
{
  "coordinates" : {
    "azimuth" : "degrees, clockwise from the front",
    "distance" : "meters from the listening position; null when not known",
    "elevation" : "degrees, up from the ear plane (negative below it)",
    "origin" : "listening position",
    "x" : "right",
    "y" : "front",
    "z" : "up"
  },
  "format" : "auraliscope.speaker-layout",
  "layout" : {
    "channelFormat" : "5.1",
    "id" : "8C2E43A0-5B7F-4E7B-9A4C-1F0D3E2B6A11",
    "mapping" : "positions",
    "name" : "Control room",
    "revision" : 4,
    "speakers" : [
      { "azimuth" : -28, "distance" : 2.1, "elevation" : 0, "included" : true, "role" : "L" },
      { "azimuth" : 28, "distance" : 2.1, "elevation" : 0, "included" : true, "role" : "R" },
      { "azimuth" : 0, "distance" : 2.2, "elevation" : 0, "included" : true, "role" : "C" },
      { "azimuth" : 0, "distance" : null, "elevation" : 0, "included" : true, "role" : "LFE" },
      { "azimuth" : -115, "distance" : 1.8, "elevation" : -5, "included" : true, "role" : "Ls" },
      { "azimuth" : 115, "distance" : 1.8, "elevation" : -5, "included" : true, "role" : "Rs" }
    ]
  },
  "schemaVersion" : 1
}
```

(Export prints each speaker over several lines; the layout is the same.)

| Field | Required | Meaning |
|---|---|---|
| `format` | yes | `"auraliscope.speaker-layout"`; any other value: not a layout |
| `schemaVersion` | yes | 1. A larger number (a newer Auraliscope's file) is refused, never half-read |
| `coordinates` | no | a description for people; ignored when read |
| `layout.channelFormat` | yes | one of `3.0 4.0 5.0 5.1 5.1.2 5.1.4 7.0 7.1 7.1.2 7.1.4 7.1.6 9.1.4 9.1.6` |
| `layout.speakers[]` | yes | one entry per role (below); `role`, `azimuth` and `elevation` required |
| `…distance` | no | meters, 0.1–100; absent or `null`: unknown |
| `…included` | no | `false` leaves the speaker out of the spatial picture; default `true` |
| `layout.mapping` | no | `directions` (default) or `positions` |
| `layout.name` | no | default: the channel format |
| `layout.id`, `layout.revision` | no | written by Auraliscope; an imported file always gets a new identity |

Role names: `L R C LFE Ls Rs Ltf Rtf Lrs Rrs Lw Rw Ltm Rtm Ltr Rtr` (`SpatialGeometry.roleNames`). `Ls Rs` are the
surrounds of a 5.x bed and the side surrounds of a 7.x or 9.x bed, whose rear surrounds are `Lrs Rrs`; a .2 bed's
one height pair is `Ltf Rtf`. The roles of each format are those of `SpeakerLayout.roles`
(`Sources/Auraliscope/SpeakerLayout.swift`), e.g. 7.1.4: `L R C LFE Ls Rs Lrs Rrs Ltf Rtf Ltr Rtr`.

### Reading a file

1. `format` and `schemaVersion` are checked first, then the channel format.
2. Speakers of roles the channel format does not have are left out, with a note naming them.
3. Roles of the format the file does not list keep their standard places, with a note naming them.
4. Every value is then checked; any problem refuses the whole file and names it: a role listed twice, an unknown
   role, an angle that is not a number, an elevation outside ±90°, a distance outside 0.1–100 m, or the `positions`
   mapping without every included speaker's distance.
5. The layout is stored with a new identity and selected for its channel format.

A layout stored with problems (only possible by editing the defaults by hand) is never used: the analysis and the
dome fall back to the standard layout of that format.

## Standard placements (build 97 and earlier, and the default)

Ear layer at 0° elevation: L −30°, R 30°, C 0°, Lw −60°, Rw 60°, Ls/Rs ±110° in 4.0 and 5.x (±90° when the layout has
rear surrounds: 7.x, 9.x), Lrs/Rrs ±150°. Heights at 45° elevation: Ltf/Rtf ±45°, Ltm/Rtm ±90°, Ltr/Rtr ±135°. No
distances (`directions` mapping).

## What reaches the analysis

The selected layout of the channel format shown, with the nebula's *Particles* (detail, 2–32, default 20) and *Spatial
window* (Standard or Fast), makes one `SpatialGeometry`. Its values are rounded to 32-bit floats and identified by a
64-bit content hash (mapping, detail, window and every role's azimuth, elevation, distance and inclusion; FNV-1a, see
Bridge/PROTOCOL.md). The local analysis computes with it; a Bridge plugin of build 98 or later receives it
(SPATIAL_CONFIG), acknowledges it and stamps its observations with the hash. The dome draws observations only when
their hash is the one of the geometry it draws the speakers with, so speakers and sound are never drawn from two
different layouts. A plugin before build 98 computes with the standard layout: the dome then draws the standard
layout for it and says so in the panel's settings.

## Settings keys (user defaults, build 98)

| Key | Type | |
|---|---|---|
| `soundstage.speakerLayouts` | data (JSON array of `layout` objects as above) | every saved layout |
| `soundstage.speakerLayout.active` | dictionary, channel format → layout UUID string | the layout each format uses; absent: standard |
| `soundstage.speakerLayout.revision` | integer | counts changes of a geometry in use (diagnostics, SPATIAL_CONFIG revision); not part of the hash |
| `soundstage.nebula.spatialWindow` | string `standard` or `fast` | Spatial window; absent: standard |
| `soundstage.nebula.rawPoints` | boolean | Raw observations (diagnostic drawing); absent: off |
| `soundstage.nebula.particles` | number | Particles (the geometry's detail), as before |

Builds before 98 ignore these keys; returning to build 97 keeps them untouched for a later return to build 98.
