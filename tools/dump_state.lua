-- Dump moomesa's whole video state at chosen frames, with MAME's own picture
-- of the same frame, so tools/moo_render.py can be checked against it pixel
-- for pixel and the RTL frozen-state bench can load it.
--
--   DUMPFRAMES=900,1500 DUMP_DIR=... tools/mame.sh -seconds_to_run 40 \
--       -autoboot_script tools/dump_state.lua
--
-- Inputs: coin at COIN, start at START (0 = never), then from PLAY on the
-- joystick walks right and fire is tapped, which reaches gameplay.
-- CONTINUE=1 adds a credit and a start every 30 s (tools/census_sprites.lua
-- does the same, so its frame numbers can be captured here).
-- SERVICE=1 holds the test switch from power-on (service mode), and
-- SVC_STEP=n taps player 1's button 1 every n frames to walk its menus.
--
-- One file per frame, state_NNNNN.bin, little-endian:
--   "MOOS" u32 version=1 u32 frame
--   u16 k056832_regs[32]   u16 k056832_regsb[4]
--   u16 k056832_vram[69632]              (MAME's whole m_videoram)
--   u8  k053246_regs[8]    u16 k053247_regs[16]   u16 k053247_ram[2048]
--   u8  k053251_regs[16]   u16 k054338_regs[32]
--   u16 palette[4096]                     (CPU 1C0000-1C1FFF)
--   u16 spriteram[32768]                  (CPU 190000-19FFFF)
--   u16 width  u16 height  u32 pixels[height][width]  (screen:pixels())
--
-- The picture is taken at the NEXT frame notifier, not this one: measured,
-- the state read at notifier N is exactly what MAME draws into the bitmap
-- that screen:pixels() returns at notifier N+1 (0 differing pixels on four
-- consecutive frames of play), while the bitmap at N differed by up to 1611
-- pixels where the CPU had changed tile RAM in between.  So each file is
-- written in two halves, a frame apart.
--
-- The K053247's list is not in the device's `items` (MAME's Lua does not
-- list it), so it is found among the numbered save items by its shape: the
-- K053246 registers (8 x u8) and K053247 registers (16 x u16) just before a
-- 2048 x u16 table.  The dump refuses to run if that shape is not found.

local mac = manager.machine
local sp  = mac.devices[":maincpu"].spaces["program"]
local dir = os.getenv("DUMP_DIR") or "."
local want = {}
local last = 0
for n in string.gmatch(os.getenv("DUMPFRAMES") or "900", "%d+") do
  want[tonumber(n)] = true
  if tonumber(n) > last then last = tonumber(n) end
end
local COIN  = tonumber(os.getenv("COIN")  or "600")
local START = tonumber(os.getenv("START") or "700")
local PLAY  = tonumber(os.getenv("PLAY")  or "1000")

local function item(dev, name) return emu.item(mac.devices[dev].items["0/" .. name]) end
local i832r, i832b, i832v = item(":k056832", "m_regs"), item(":k056832", "m_regsb"), item(":k056832", "m_videoram")
local i251, i338 = item(":k053251", "m_ram"), item(":k054338", "m_regs")
local i246, i247r, i247 = nil, nil, nil
for i = 3, 2000 do
  local ok, it = pcall(emu.item, i)
  if ok and it and it.size == 2 and it.count == 2048 then
    local a, b = emu.item(i - 3), emu.item(i - 2)
    if a and b and a.size == 1 and a.count == 8 and b.size == 2 and b.count == 16 then
      i246, i247r, i247 = a, b, it
      break
    end
  end
end

local frames = 0
local log = io.open(dir .. "/run.txt", "w")
if not i246 then log:write("FATAL: K053247 sprite list not found among the save items\n"); log:close() end

local function u8s(f, it, n)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.char(it:read(i) & 0xff) end
  f:write(table.concat(t))
end
local function u16s(f, it, n)
  local t = {}
  for i = 0, n - 1 do
    local v = it:read(i)
    t[#t + 1] = string.char(v & 0xff, (v >> 8) & 0xff)
    if #t == 8192 then f:write(table.concat(t)); t = {} end
  end
  f:write(table.concat(t))
end
local function mem16(f, base, n)
  local t = {}
  for i = 0, n - 1 do
    local v = sp:read_u16(base + i * 2)
    t[#t + 1] = string.char(v & 0xff, (v >> 8) & 0xff)
    if #t == 8192 then f:write(table.concat(t)); t = {} end
  end
  f:write(table.concat(t))
end
local function u32(f, v) f:write(string.char(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff)) end
local function u16(f, v) f:write(string.char(v & 0xff, (v >> 8) & 0xff)) end

local pending = nil      -- the file waiting for next frame's picture

local function dump(n)
  local f = io.open(string.format("%s/state_%05d.bin", dir, n), "wb")
  pending = {f = f, n = n}
  f:write("MOOS"); u32(f, 1); u32(f, n)
  u16s(f, i832r, 32); u16s(f, i832b, 4); u16s(f, i832v, 69632)
  u8s(f, i246, 8); u16s(f, i247r, 16); u16s(f, i247, 2048)
  u8s(f, i251, 16); u16s(f, i338, 32)
  mem16(f, 0x1c0000, 4096)
  mem16(f, 0x190000, 32768)
end

local function finish()
  -- pixels() returns the bitmap and then its width and height; f:write would
  -- print those two numbers as text after it, so take them apart
  local px, w, h = mac.screens[":screen"]:pixels()
  local f = pending.f
  u16(f, w); u16(f, h)
  f:write(px)
  f:close()
  log:write(string.format("dumped %d\n", pending.n)); log:flush()
  pending = nil
end

local function press(port, field, on)
  mac.ioport.ports[port].fields[field]:set_value(on and 0 or 1)  -- ACTIVE_LOW
end

_G.KEEP = {}
local SERVICE = os.getenv("SERVICE") == "1"
local CONTINUE = os.getenv("CONTINUE") == "1"
local SVC_STEP = tonumber(os.getenv("SVC_STEP") or "0")

_G.KEEP.s = emu.add_machine_stop_notifier(function()
  log:write(string.format("frames %d\n", frames))
  for n in pairs(want) do
    local h = io.open(string.format("%s/state_%05d.bin", dir, n), "rb")
    local ok = h and h:seek("end") > 500000
    log:write(string.format("want %d %s\n", n, ok and "ok" or "MISSING"))
    if h then h:close() end
  end
  log:close()
end)
_G.KEEP.n = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if not i246 then return end
  if SERVICE then
    press(":IN1", "Service Mode", frames < 400)
    if SVC_STEP > 0 and frames > 400 then press(":P1_P3", "P1 Button 1", (frames % SVC_STEP) < 4) end
  end
  if COIN > 0 and frames == COIN then press(":IN0", "Coin 1", true) end
  if COIN > 0 and frames == COIN + 8 then press(":IN0", "Coin 1", false) end
  if START > 0 and frames == START then press(":P1_P3", "1 Player Start", true) end
  if START > 0 and frames == START + 8 then press(":P1_P3", "1 Player Start", false) end
  if START > 0 and frames > PLAY then
    press(":P1_P3", "P1 Right", (frames // 150) % 3 ~= 2)
    press(":P1_P3", "P1 Left", (frames // 150) % 3 == 2)
    press(":P1_P3", "P1 Button 1", (frames // 9) % 2 == 0)
    press(":P1_P3", "P1 Button 2", (frames // 61) % 7 == 0)
    if CONTINUE then  -- a credit and a start every 30 s, to keep the game going
      if frames % 1800 == 0 then press(":IN0", "Coin 1", true) end
      if frames % 1800 == 8 then press(":IN0", "Coin 1", false) end
      if frames % 1800 == 30 then press(":P1_P3", "1 Player Start", true) end
      if frames % 1800 == 38 then press(":P1_P3", "1 Player Start", false) end
    end
  end
  if pending then finish() end
  if want[frames] then dump(frames) end
end)
