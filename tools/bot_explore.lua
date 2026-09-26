-- Run the bot (tools/bot_inputs.lua) and snapshot the screen every SNAP
-- frames, to find the frames of screens worth dumping.
--   SNAP=600 COIN=600 START=700 tools/mame.sh -seconds_to_run N \
--       -snapshot_directory DIR -autoboot_script tools/bot_explore.lua
-- Snapshots are numbered in order; frame = (index + 1) * SNAP.  run.txt in
-- the snapshot directory records the last frame reached.
local mac = manager.machine
local bot = dofile(os.getenv("BOT_LIB") or "tools/bot_inputs.lua")
local SNAP  = tonumber(os.getenv("SNAP")  or "600")
local COIN  = tonumber(os.getenv("COIN")  or "600")
local START = tonumber(os.getenv("START") or "700")
local out = os.getenv("OUT") or "bot_run.txt"
local frames = 0
_G.KEEP = {}
_G.KEEP.f = emu.register_frame_done(function()
  frames = frames + 1
  bot.apply(mac, frames, COIN, START)
  if frames % SNAP == 0 then mac.video:snapshot() end
end)
_G.KEEP.s = emu.add_machine_stop_notifier(function()
  local f = io.open(out, "w"); f:write(string.format("frames %d\n", frames)); f:close()
end)
