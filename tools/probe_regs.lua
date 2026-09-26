-- Record what moomesa programs into its custom chips, for docs/hardware.md.
--
--   OUT=probe.txt tools/mame.sh -seconds_to_run 90 -autoboot_script tools/probe_regs.lua
--
-- Coin at COIN, start at START, then holds right and fire a while so the run
-- reaches gameplay.  Writes, on stop: every register's distinct values and how
-- often each was written, which tile-RAM pages the CPU wrote, and a count of
-- protection triggers with their first parameters.

local mac = manager.machine
local sp  = mac.devices[":maincpu"].spaces["program"]
local out = os.getenv("OUT") or "probe.txt"
local COIN  = tonumber(os.getenv("COIN")  or "600")
local START = tonumber(os.getenv("START") or "700")

local frames = 0
local regs = {}          -- name -> offset -> {value -> count}
local function note(name, off, v)
  regs[name] = regs[name] or {}
  local r = regs[name]
  r[off] = r[off] or {}
  r[off][v] = (r[off][v] or 0) + 1
end

local k832 = {}          -- shadow of the K056832 registers, for the RAM bank
for i = 0, 31 do k832[i] = 0 end
local pages = {}         -- page -> writes
local prot = {n = 0, first = {}}
local ctl2 = {}

local function tap(name, lo, hi, fn)
  _G.KEEP[#_G.KEEP + 1] = sp:install_write_tap(lo, hi, name, function(offset, data, mask)
    fn(offset, data, mask)
  end)
end

_G.KEEP = {}
tap("k056832", 0x0c0000, 0x0c003f, function(o, d, m)
  local i = (o - 0x0c0000) >> 1
  k832[i] = (k832[i] & ~m) | (d & m)
  note("K056832", i * 2, k832[i])
end)
tap("k056832b", 0x0d8000, 0x0d8007, function(o, d, m) note("K056832b", o - 0x0d8000, d & m) end)
tap("k053246", 0x0c2000, 0x0c2007, function(o, d, m) note("K053246", o - 0x0c2000, string.format("%04x/%04x", d, m)) end)
tap("k054338", 0x0ca000, 0x0ca01f, function(o, d, m) note("K054338", o - 0x0ca000, string.format("%04x/%04x", d, m)) end)
tap("k053251", 0x0cc000, 0x0cc01f, function(o, d, m) note("K053251", (o - 0x0cc000) >> 1, d & 0x3f) end)
tap("k053252", 0x0d0000, 0x0d001f, function(o, d, m) note("K053252", (o - 0x0d0000) >> 1, d & 0xff) end)
tap("k054321", 0x0d6000, 0x0d601f, function(o, d, m) note("K054321", (o - 0x0d6000) >> 1, "w") end)
tap("sndirq", 0x0d4000, 0x0d4001, function(o, d, m) note("SNDIRQ", 0, "w") end)
tap("ctl2", 0x0de000, 0x0de001, function(o, d, m) note("CONTROL2", 0, string.format("%04x/%04x", d, m)) end)
tap("prot", 0x0ce000, 0x0ce01f, function(o, d, m)
  local i = (o - 0x0ce000) >> 1
  if i == 0xc then
    prot.n = prot.n + 1
    if #prot.first < 12 then
      local t = {}
      for k = 0, 15 do t[#t + 1] = string.format("%04x", sp:read_u16(0x0ce000 + k * 2)) end
      prot.first[#prot.first + 1] = string.format("f%d %s", frames, table.concat(t, " "))
    end
  end
end)
tap("vram", 0x1a0000, 0x1a3fff, function(o, d, m)
  local bank = k832[0x19]
  local page = ((bank >> 1) & 0xc) | (bank & 3)
  pages[page] = (pages[page] or 0) + 1
end)

local function press(port, field, on)
  mac.ioport.ports[port].fields[field]:set_value((on ~= (os.getenv("INPUTS_INVERTED") == "1")) and 1 or 0)  -- nonzero = pressed; see tools/bk2_inputs.lua
end

_G.KEEP.s = emu.add_machine_stop_notifier(function()
  local f = io.open(out, "w")
  f:write(string.format("frames %d\n", frames))
  local names = {}
  for n in pairs(regs) do names[#names + 1] = n end
  table.sort(names)
  for _, n in ipairs(names) do
    local offs = {}
    for o in pairs(regs[n]) do offs[#offs + 1] = o end
    table.sort(offs)
    for _, o in ipairs(offs) do
      local vals = {}
      for v, c in pairs(regs[n][o]) do
        vals[#vals + 1] = (type(v) == "number" and string.format("%04x", v) or v) .. "x" .. c
      end
      table.sort(vals)
      if #vals > 12 then vals = {#vals .. " distinct values, e.g. " .. vals[1] .. " " .. vals[#vals]} end
      f:write(string.format("%-9s %02x: %s\n", n, o, table.concat(vals, " ")))
    end
  end
  f:write("tile RAM pages written by the CPU:")
  for p = 0, 16 do if pages[p] then f:write(string.format(" %d(%d)", p, pages[p])) end end
  f:write(string.format("\nprotection triggers: %d\n", prot.n))
  for _, l in ipairs(prot.first) do f:write("  " .. l .. "\n") end
  f:close()
end)

_G.KEEP.n = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if frames == COIN       then press(":IN0", "Coin 1", true)  end
  if frames == COIN + 8   then press(":IN0", "Coin 1", false) end
  if frames == START      then press(":P1_P3", "1 Player Start", true)  end
  if frames == START + 8  then press(":P1_P3", "1 Player Start", false) end
  if frames > START + 300 then
    press(":P1_P3", "P1 Right", (frames // 120) % 2 == 0)
    press(":P1_P3", "P1 Button 1", (frames // 7) % 2 == 0)
  end
end)
