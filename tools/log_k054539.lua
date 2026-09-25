-- Log every Z80 write to the K054539 with the 48 kHz sample it lands in, so
-- sim/run_k539.sh can replay the same commands into rtl/k054539.sv.
--   OUT=k539.log [COIN=.. START=..] tools/mame.sh -seconds_to_run N -autoboot_script tools/log_k054539.lua
-- One line per write: sample offset data (hex).  Uses the same input script
-- as tools/dump_state.lua.
local mac = manager.machine
local sp  = mac.devices[":soundcpu"].spaces["program"]
local f   = io.open(os.getenv("OUT") or "k539.log", "w")
local COIN  = tonumber(os.getenv("COIN")  or "600")
local START = tonumber(os.getenv("START") or "700")
local PLAY  = tonumber(os.getenv("PLAY")  or "1000")
local frames = 0
_G.KEEP = {}
_G.KEEP[1] = sp:install_write_tap(0xe000, 0xe22f, "k539", function(o, d, m)
  local t = mac.time:as_double()
  f:write(string.format("%d %03x %02x\n", math.floor(t * 48000), o - 0xe000, d & 0xff))
end)
_G.KEEP.s = emu.add_machine_stop_notifier(function() f:close() end)
local function press(port, field, on) mac.ioport.ports[port].fields[field]:set_value(on and 0 or 1) end
_G.KEEP.n = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if COIN > 0 and frames == COIN then press(":IN0", "Coin 1", true) end
  if COIN > 0 and frames == COIN + 8 then press(":IN0", "Coin 1", false) end
  if START > 0 and frames == START then press(":P1_P3", "1 Player Start", true) end
  if START > 0 and frames == START + 8 then press(":P1_P3", "1 Player Start", false) end
  if START > 0 and frames > PLAY then
    press(":P1_P3", "P1 Right", (frames // 150) % 3 ~= 2)
    press(":P1_P3", "P1 Left", (frames // 150) % 3 == 2)
    press(":P1_P3", "P1 Button 1", (frames // 9) % 2 == 0)
    press(":P1_P3", "P1 Button 2", (frames // 61) % 7 == 0)
  end
end)
