-- Inputs from a BizHawk arcade movie (the "Input Log.txt" inside a .bk2,
-- recorded on BizHawk's MAME core), one log line per video frame (measured:
-- mapping lines by 1/60 s instead loses sync within minutes).  Each logged
-- button is set on the MAME field of the same name.  Used by
-- tools/bk2_replay.lua and tools/dump_state.lua (BK2_LOG=...).
--
-- MAME's ioport_field:set_value takes "pressed" for any nonzero value,
-- whatever the bit's polarity.
local M = {}
function M.new(mac, path, offset)
  local names, rows = {}, {}
  for line in io.lines(path) do
    if line:sub(1, 7) == "LogKey:" then
      for n in line:sub(8):gmatch("[^|#]+") do names[#names + 1] = n end
    elseif line:sub(1, 1) == "|" then
      rows[#rows + 1] = (line:gsub("|", ""))
    end
  end
  local fields = {}
  for i, n in ipairs(names) do
    for _, port in pairs(mac.ioport.ports) do
      if port.fields[n] then fields[i] = port.fields[n]; break end
    end
  end
  local o = {}
  -- call from the frame notifier with its count: sets the next frame's inputs
  function o.apply(frames)
    local r = rows[frames + 1 + (offset or 0)]
    if not r then return end
    for i = 1, #names do
      if fields[i] then fields[i]:set_value(r:sub(i, i) ~= "." and 1 or 0) end
    end
  end
  o.length = #rows
  return o
end
return M
--
-- The older tools (dump_state, census_sprites, the probes, bot_inputs) pressed
-- with set_value(0) until 2026-09-25, which MAME reads as RELEASED: in every
-- run before then press and release were swapped (the coin held down, "walk
-- right" never pressed).  The states in sim/states were captured that way and
-- stay valid -- each is what MAME drew -- but to reproduce one, run with
-- INPUTS_INVERTED=1.
