-- What the sound program asks of the K054539, the YM2151 and the bank latch.
--   OUT=probe_sound.txt tools/mame.sh -seconds_to_run 90 -autoboot_script tools/probe_sound.lua
local mac = manager.machine
local sp  = mac.devices[":soundcpu"].spaces["program"]
local mp  = mac.devices[":maincpu"].spaces["program"]
local out = os.getenv("OUT") or "probe_sound.txt"
local frames, seen = 0, {}
local function note(k) seen[k] = (seen[k] or 0) + 1 end
_G.KEEP = {}
_G.KEEP[1] = sp:install_write_tap(0xe000, 0xe22f, "k539", function(o, d, m)
  local r = o - 0xe000
  if r >= 0x200 and r < 0x210 then note(string.format("539 %03x(ch%d %s)=%02x", r, (r-0x200)>>1, (r&1)==0 and "type" or "loop", d)) end
  if r >= 0x100 and r < 0x200 then note(string.format("539 %03x=%02x", r, d)) end
  if r >= 0x210 then note(string.format("539 %03x=%02x", r, r==0x214 or r==0x215 or r==0x22d and 0 or d)) end
  if r < 0x100 and ((r & 0x1f) == 6 or (r & 0x1f) == 7 or (r & 0x1f) == 4) then note(string.format("539 ch reg %02x nonzero=%s", r & 0x1f, d ~= 0 and "yes" or "no")) end
  if r < 0x100 and (r & 0x1f) == 5 then note(string.format("539 pan=%02x", d)) end
end)
_G.KEEP[2] = sp:install_write_tap(0xf800, 0xf800, "bank", function(o, d, m) note(string.format("bank=%02x", d)) end)
_G.KEEP[3] = sp:install_write_tap(0xec00, 0xec01, "ym", function(o, d, m) note("ym write") end)
_G.KEEP[4] = sp:install_read_tap(0xe000, 0xe22f, "k539r", function(o, d, m) note(string.format("539 read %03x", o - 0xe000)) end)
_G.KEEP[5] = mp:install_write_tap(0x0de000, 0x0de001, "ctl2", function(o, d, m) note(string.format("ctl2 %04x/%04x", d, m)) end)
_G.KEEP[6] = mp:install_read_tap(0x0c4000, 0x0c4001, "objrom", function(o, d, m) note("objcha read") end)
_G.KEEP[7] = mp:install_read_tap(0x1b0000, 0x1b1fff, "tilerom", function(o, d, m) note("tile rom read") end)
_G.KEEP.s = emu.add_machine_stop_notifier(function()
  local f = io.open(out, "w")
  f:write(string.format("frames %d\n", frames))
  local ks = {}
  for k in pairs(seen) do ks[#ks + 1] = k end
  table.sort(ks)
  for _, k in ipairs(ks) do f:write(string.format("%-40s %d\n", k, seen[k])) end
  f:close()
end)
local function press(port, field, on) mac.ioport.ports[port].fields[field]:set_value(on and 0 or 1) end
_G.KEEP.n = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if frames == 600 then press(":IN0", "Coin 1", true) end
  if frames == 608 then press(":IN0", "Coin 1", false) end
  if frames == 700 then press(":P1_P3", "1 Player Start", true) end
  if frames == 708 then press(":P1_P3", "1 Player Start", false) end
  if frames > 1000 then
    press(":P1_P3", "P1 Right", (frames // 120) % 2 == 0)
    press(":P1_P3", "P1 Button 1", (frames // 7) % 2 == 0)
  end
end)
