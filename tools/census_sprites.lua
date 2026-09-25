-- Find frames where the sprite list uses each feature, so frozen states can
-- be captured where they happen (METHODOLOGY 5.10: a capture proves only what
-- it reaches).
--   OUT=census.txt [COIN=.. START=.. PLAY=..] tools/mame.sh -seconds_to_run N -autoboot_script tools/census_sprites.lua
local mac = manager.machine
local out = os.getenv("OUT") or "census.txt"
local COIN  = tonumber(os.getenv("COIN")  or "600")
local START = tonumber(os.getenv("START") or "700")
local PLAY  = tonumber(os.getenv("PLAY")  or "1000")
local list = nil
for i = 3, 2000 do
  local ok, it = pcall(emu.item, i)
  if ok and it and it.size == 2 and it.count == 2048 then
    local a, b = emu.item(i - 3), emu.item(i - 2)
    if a and b and a.size == 1 and a.count == 8 and b.size == 2 and b.count == 16 then list = it; break end
  end
end
local i338 = emu.item(mac.devices[":k054338"].items["0/m_regs"])
local frames, seen, first, maxspr, maxframe = 0, {}, {}, 0, 0
local function note(k)
  seen[k] = (seen[k] or 0) + 1
  first[k] = first[k] or {}
  if #first[k] < 12 and (#first[k] == 0 or frames - first[k][#first[k]] > 120) then first[k][#first[k] + 1] = frames end
end
local function press(port, field, on) mac.ioport.ports[port].fields[field]:set_value(on and 0 or 1) end
_G.KEEP = {}
_G.KEEP.s = emu.add_machine_stop_notifier(function()
  local f = io.open(out, "w")
  f:write(string.format("frames %d, most sprites %d at frame %d\n", frames, maxspr, maxframe))
  local ks = {}
  for k in pairs(seen) do ks[#ks + 1] = k end
  table.sort(ks)
  for _, k in ipairs(ks) do f:write(string.format("%-10s %6d frames, e.g. %s\n", k, seen[k], table.concat(first[k], ","))) end
  f:close()
end)
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
    -- keep the game going: a credit and a continue every so often
    if frames % 1800 == 0 then press(":IN0", "Coin 1", true) end
    if frames % 1800 == 8 then press(":IN0", "Coin 1", false) end
    if frames % 1800 == 30 then press(":P1_P3", "1 Player Start", true) end
    if frames % 1800 == 38 then press(":P1_P3", "1 Player Start", false) end
  end
  if not list then return end
  local n, f = 0, {}
  for o = 0, 0x7f8, 8 do
    local w0 = list:read(o)
    if w0 & 0x8000 ~= 0 then
      n = n + 1
      local w4, w5, w6 = list:read(o + 4) & 0x3ff, list:read(o + 5) & 0x3ff, list:read(o + 6)
      if w4 ~= 0x40 or ((w0 & 0x4000) == 0 and w5 ~= 0x40) then f.zoom = true end
      if (w6 >> 10) & 3 ~= 0 then f.shadow = true end
      if w6 & 0x4000 ~= 0 then f.mirrorx = true end
      if w6 & 0x8000 ~= 0 then f.mirrory = true end
      if w0 & 0x2000 ~= 0 then f.flipy = true end
      if w0 & 0x4000 ~= 0 then f.aspect = true end
      if (w6 & 0x3000) ~= 0 then f.reserved = true end
      if w4 == 0 then f.zoom0 = true end
    end
  end
  for k in pairs(f) do note(k) end
  if n > maxspr then maxspr, maxframe = n, frames end
  if i338:read(15) & 2 ~= 0 then note("mixpri") end
  if i338:read(15) & 1 == 0 then note("videooff") end
end)
