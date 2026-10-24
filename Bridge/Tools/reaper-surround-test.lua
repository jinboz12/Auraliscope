-- REAPER immersive test for Auraliscope Bridge (run by Bridge/scripts/daw-reaper.sh vst3 surround, in a private
-- resource folder): a 12-channel track playing the 12-channel test WAV (ABR_WAV), with Auraliscope Bridge (ABR_FX)
-- inserted. Logs which binary REAPER loaded and the pins and channel configuration it negotiated with the plugin,
-- plays for ABR_SECONDS (default 20), then saves the scratch project in place (so REAPER quits without asking) and
-- quits.
local t0 = reaper.time_precise()
local function log(text)
  local file = io.open(os.getenv("ABR_LOG"), "a")
  file:write(string.format("%6.2f  %s\n", reaper.time_precise() - t0, text))
  file:close()
end

local channels = 12
reaper.InsertTrackAtIndex(0, true)
local track = reaper.GetTrack(0, 0)
reaper.GetSetMediaTrackInfo_String(track, "P_NAME", os.getenv("ABR_TRACK"), true)
reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", channels)
reaper.SetOnlyTrackSelected(track)
reaper.SetEditCurPos(0, false, false)
reaper.InsertMedia(os.getenv("ABR_WAV"), 0)
local item = reaper.GetTrackMediaItem(track, 0)
if item then
  -- Inserting moves the edit cursor to the item's end, where playback would stop at once: loop the item over
  -- 10 minutes and play from the start.
  reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 1)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", 600)
end
reaper.SetEditCurPos(0, false, false)
local fx = reaper.TrackFX_AddByName(track, os.getenv("ABR_FX"), false, -1)
local _, fxName = reaper.TrackFX_GetFXName(track, math.max(fx, 0), "")
log(string.format("inserted FX %d: %s on %d-channel track \"%s\" (item %s)", fx, fxName,
                  reaper.GetMediaTrackInfo_Value(track, "I_NCHAN"), os.getenv("ABR_TRACK"), tostring(item ~= nil)))
if fx < 0 then log("FAIL: plugin not found by REAPER"); reaper.Main_OnCommand(40004, 0); return end

local function describe(label)
  local _, ident = reaper.TrackFX_GetNamedConfigParm(track, fx, "fx_ident")
  local _, inputs, outputs = reaper.TrackFX_GetIOSize(track, fx)
  local hasConfig, config = reaper.TrackFX_GetNamedConfigParm(track, fx, "channel_config")
  log(string.format("%s: binary %s; pins %d in, %d out; channel_config %s", label, ident or "?", inputs or -1,
                    outputs or -1, hasConfig and config or "(not available)"))
  return inputs or 0
end
log(string.format("audio device: %s / %s, %s Hz, block %s", reaper.GetAudioDeviceInfo("IDENT_IN") and select(2, reaper.GetAudioDeviceInfo("IDENT_IN")) or "?",
                  select(2, reaper.GetAudioDeviceInfo("IDENT_OUT")) or "?", select(2, reaper.GetAudioDeviceInfo("SRATE")) or "?",
                  select(2, reaper.GetAudioDeviceInfo("BSIZE")) or "?"))
local inputs = describe("as inserted")
if inputs < channels then
  -- REAPER sets a VST3's speaker arrangement through channel_config: "<channels> <arrangement>" (7.1.4 = 0x2D63F).
  local set = reaper.TrackFX_SetNamedConfigParm(track, fx, "channel_config", channels .. " 185919")
  log("asked for 7.1.4 through channel_config: " .. tostring(set))
  inputs = describe("after asking for 7.1.4")
end
log(inputs >= channels and "the plugin takes all 12 channels" or "FAIL: the plugin did not take 12 channels")

local seconds = tonumber(os.getenv("ABR_SECONDS") or "") or 20
local function play()
  if reaper.GetPlayState() & 1 == 0 then reaper.OnPlayButton() end
end
local steps = {
  {1, "play", play},
  {2, "play (again if needed)", play},
  {3, "play (again if needed)", play},
  {4, "playing?", function()
    log(string.format("audio running %s, play state %d", tostring(reaper.Audio_IsRunning()), reaper.GetPlayState()))
    if reaper.GetPlayState() & 1 == 0 then log("FAIL: the transport is not playing") end
  end},
  {1 + seconds, "stop and quit", function()
    reaper.OnStopButton()
    describe("at the end")
    reaper.Main_SaveProject(0, false)  -- in place (ABR_PROJECT): nothing unsaved to ask about
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
