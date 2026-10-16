# Loudness references in 2.0

Reviewed for build 91 on October 16, 2026. Presets are convenient measurement references. Delivery contracts and the
current specification take precedence; PASS only compares integrated loudness and true peak against the selected values.

- [Spotify's official normalization guidance](https://support.spotify.com/us/artists/article/loudness-normalization/)
  describes −14 LUFS Normal and −11 LUFS Loud, gain changes with peak headroom, and different playback settings.
  The generic streaming preset is an estimate, not a promise that all services use the same behavior. Spotify recommends
  additional peak headroom for masters above −14 LUFS; choose the ceiling appropriate to the delivery.
- [ARIB TR-B32 1.6 public sample](https://www.arib.or.jp/english/image/std_tr/sample/sample-tr-b32-1.6.pdf)
  identifies the current revision but omits the operative tolerance/ceiling pages. The retained −24 LUFS/−1 dBTP
  values are explicitly a reference; build 91 no longer awards ARIB delivery PASS on an unverified tolerance.
- Amazon Music's association with the shared −14 LUFS preset was not verified from a primary specification and was
  removed. Set a custom target if your delivery agreement specifies one.
- Netflix requires dialogue-specific measurement in relevant workflows. Auraliscope measures full-programme loudness;
  its Netflix preset returns REFERENCE (or CHECK for excess true peak), never dialogue-compliance PASS.

Other presets retain build 90 values. They have not all been independently re-audited against current service contracts.
Mastering checks for tonal balance, bandwidth and dynamics are heuristics; a NOTE is not a requirement to alter the mix.
