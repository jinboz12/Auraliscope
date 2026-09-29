-- REAPER identity and transport test for Auraliscope Bridge (run by Bridge/scripts/daw-reaper.sh <format> identity,
-- in a private resource folder). One track "Vox" plays the test WAV through Auraliscope Bridge; then, while it
-- plays: the track is duplicated (the copy's item turned down 6 dB, so its insert is told apart by level), a loop
-- runs and the play position jumps, the project sample rate changes to 44.1 kHz and back (audio restarted each
-- time), and the original insert is taken offline and back online (REAPER unloads and reloads the plugin with its
-- state). The project is saved in place for the reopen run. Logs to ABR_LOG.
local t0 = reaper.time_precise()
local function log(text)
  local file = io.open(os.getenv("ABR_LOG"), "a")
  file:write(string.format("%6.2f  %s\n", reaper.time_precise() - t0, text))
  file:close()
end

reaper.InsertTrackAtIndex(0, true)
local track = reaper.GetTrack(0, 0)
reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "Vox", true)
reaper.SetOnlyTrackSelected(track)
reaper.SetEditCurPos(0, false, false)
reaper.InsertMedia(os.getenv("ABR_WAV"), 0)
local item = reaper.GetTrackMediaItem(track, 0)
if item then
  reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 1)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", 600)
end
local fx = reaper.TrackFX_AddByName(track, os.getenv("ABR_FX"), false, -1)
local _, fxName = reaper.TrackFX_GetFXName(track, math.max(fx, 0), "")
log(string.format("inserted FX %d: %s on track \"Vox\"", fx, fxName))
if fx < 0 then log("FAIL: plugin not found by REAPER"); reaper.Main_OnCommand(40004, 0); return end

local function rate(hz)
  reaper.GetSetProjectInfo(0, "PROJECT_SRATE", hz, true)
  reaper.GetSetProjectInfo(0, "PROJECT_SRATE_USE", 1, true)
  reaper.Audio_Quit()
  reaper.Audio_Init()
  local _, _, device = reaper.GetAudioDeviceInfo("SRATE", "")
  log(string.format("project rate %d; audio restarted (device rate %s)", hz, tostring(device)))
end

local steps = {
  {1, "play", function() reaper.OnPlayButton() end},
  {6, "duplicate track (the copy turned down 6 dB)", function()
    reaper.SetOnlyTrackSelected(track)
    reaper.Main_OnCommand(40062, 0)  -- Track: Duplicate tracks
    local copy = reaper.GetTrack(0, 1)
    local copyItem = copy and reaper.GetTrackMediaItem(copy, 0)
    if copyItem then reaper.SetMediaItemInfo_Value(copyItem, "D_VOL", 0.5) end
    log(string.format("tracks: %d; copy FX: %d", reaper.CountTracks(0), copy and reaper.TrackFX_GetCount(copy) or -1))
  end},
  {10, "loop 2-4 s, repeat on", function()
    reaper.GetSet_LoopTimeRange(true, true, 2, 4, false)
    reaper.GetSetRepeat(1)
    reaper.SetEditCurPos(2, false, true)
  end},
  {16, "repeat off; seek to 8 s", function()
    reaper.GetSetRepeat(0)
    reaper.SetEditCurPos(8, false, true)
  end},
  {19, "project rate 44.1 kHz", function() rate(44100) end},
  {25, "project rate 48 kHz", function() rate(48000) end},
  {30, "original insert offline (unloaded)", function() reaper.TrackFX_SetOffline(track, fx, true) end},
  {32, "original insert online (reloaded from its state)", function() reaper.TrackFX_SetOffline(track, fx, false) end},
  {50, "stop, save and quit", function()
    reaper.OnStopButton()
    reaper.Main_SaveProject(0, false)
    reaper.Main_OnCommand(40004, 0)
  end},
}
local next = 1
local function tick()
  local now = reaper.time_precise() - t0
  while next <= #steps and now >= steps[next][1] do
    log(steps[next][2] .. string.format(" (play state %d)", reaper.GetPlayState()))
    steps[next][3]()
    next = next + 1
  end
  if next <= #steps then reaper.defer(tick) end
end
reaper.defer(tick)
