-- Replay a BizHawk arcade movie in MAME (tools/bk2_inputs.lua), snapshotting
-- every SNAP frames, to find the frames of screens worth dumping.
--   BK2_LOG=".../Input Log.txt" [BK2_OFFSET=0] SNAP=60 tools/mame.sh \
--       -seconds_to_run N -snapshot_directory DIR -autoboot_script tools/bk2_replay.lua
-- Snapshot k (from 0) is frame (k + 1) * SNAP.  A run from an empty nvram
-- directory starts from the romset's default EEPROM; the Moo Mesa TAS
-- (ezgames69, BizHawk 2.9.1) then plays the whole game in sync, 58,304 frames.
local mac = manager.machine
local SNAP = tonumber(os.getenv("SNAP") or "0")
local lib = dofile(os.getenv("BK2_LIB") or "tools/bk2_inputs.lua")
local tas = lib.new(mac, os.getenv("BK2_LOG"), tonumber(os.getenv("BK2_OFFSET") or "0"))
local frames = 0
_G.KEEP = {}
_G.KEEP.f = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  tas.apply(frames)
  if SNAP > 0 and frames % SNAP == 0 then mac.video:snapshot() end
end)
