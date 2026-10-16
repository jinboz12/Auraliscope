-- REAPER reopen test for Auraliscope Bridge (run by Bridge/scripts/daw-reaper.sh <format> reopen): the project the
-- identity run saved (the original "Vox" insert and its copy) opens again and plays for 12 s, then REAPER quits.
-- Auraliscope Labs, watching, must find the original insert by itself, not the copy. Logs to ABR_LOG.
local t0 = reaper.time_precise()
local function log(text)
  local file = io.open(os.getenv("ABR_LOG"), "a")
  file:write(string.format("%6.2f  %s\n", reaper.time_precise() - t0, text))
  file:close()
end
log(string.format("reopened: %d track(s)", reaper.CountTracks(0)))
local steps = {
  {1, "play", function() reaper.OnPlayButton() end},
  {13, "stop and quit", function() reaper.OnStopButton(); reaper.Main_OnCommand(40004, 0) end},
}
local next = 1
local function tick()
  local now = reaper.time_precise() - t0
  while next <= #steps and now >= steps[next][1] do
    log(steps[next][2])
    steps[next][3]()
    next = next + 1
  end
  if next <= #steps then reaper.defer(tick) end
end
reaper.defer(tick)
