-- REAPER runtime test for Auraliscope Bridge (run by Bridge/scripts/daw-reaper.sh, in a private resource folder).
-- Builds a one-track project: the test WAV, then Auraliscope Bridge (ABR_FX: "VST3:Auraliscope Bridge" or
-- "AU:Auraliscope Bridge"); plays it and walks through editor open/close, bypass, stop and play, logging to ABR_LOG,
-- then saves the project (opened from ABR_PROJECT, kept for the offline render run) and quits.
local t0 = reaper.time_precise()
local function log(text)
  local file = io.open(os.getenv("ABR_LOG"), "a")
  file:write(string.format("%6.2f  %s\n", reaper.time_precise() - t0, text))
  file:close()
end

reaper.InsertTrackAtIndex(0, true)
local track = reaper.GetTrack(0, 0)
reaper.GetSetMediaTrackInfo_String(track, "P_NAME", os.getenv("ABR_TRACK"), true)
reaper.SetOnlyTrackSelected(track)
reaper.SetEditCurPos(0, false, false)
reaper.InsertMedia(os.getenv("ABR_WAV"), 0)
local item = reaper.GetTrackMediaItem(track, 0)
if item then
  -- Loop the 30 s file over 10 minutes, so the offline render lasts long enough to be seen.
  reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 1)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", 600)
end
local fx = reaper.TrackFX_AddByName(track, os.getenv("ABR_FX"), false, -1)
local _, fxName = reaper.TrackFX_GetFXName(track, math.max(fx, 0), "")
log(string.format("inserted FX %d: %s on track \"%s\" (item %s)", fx, fxName, os.getenv("ABR_TRACK"), tostring(item ~= nil)))
if fx < 0 then log("FAIL: plugin not found by REAPER"); reaper.Main_OnCommand(40004, 0); return end
reaper.GetSetProjectInfo_String(0, "RENDER_FILE", os.getenv("ABR_RENDER_DIR"), true)
reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "bridge-render", true)
reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 1, true)  -- entire project
reaper.GetSetProjectInfo(0, "RENDER_SRATE", 48000, true)    -- the project rate: no resampling in the check
reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", 2, true)

local steps = {
  {1, "play", function() reaper.OnPlayButton() end},
  {4, "open plugin window", function() reaper.TrackFX_Show(track, fx, 3) end},
  {7, "close plugin window", function() reaper.TrackFX_Show(track, fx, 2) end},
  {12, "bypass FX", function() reaper.TrackFX_SetEnabled(track, fx, false) end},
  {15, "enable FX", function() reaper.TrackFX_SetEnabled(track, fx, true) end},
  {18, "stop transport", function() reaper.OnStopButton() end},
  {21, "play", function() reaper.OnPlayButton() end},
  {25, "stop, save and quit", function()
    reaper.OnStopButton()
    reaper.Main_SaveProject(0, false)  -- in place (ABR_PROJECT), which also clears the unsaved state
    reaper.Main_OnCommand(40004, 0)  -- File: Quit REAPER
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
