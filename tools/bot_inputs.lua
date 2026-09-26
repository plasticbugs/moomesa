-- A player that gets through the game by persistence, for reaching screens
-- random input never does (the map between stages).  Shared by
-- tools/bot_explore.lua and tools/dump_state.lua (BOT=1), so a frame found
-- while exploring is the same frame when its state is dumped: MAME is
-- deterministic for identical input.
--
-- From frame START on: hold right, fire every other frame, jump for 6 frames
-- in every 90, and every 240 frames drop a coin and press start (a continue
-- when dead; ignored while playing).  Before START only the first coin at
-- COIN and the start at START.
local M = {}
function M.apply(mac, frames, COIN, START)
  local function press(port, field, on)
    mac.ioport.ports[port].fields[field]:set_value((on ~= (os.getenv("INPUTS_INVERTED") == "1")) and 1 or 0)  -- nonzero = pressed; see tools/bk2_inputs.lua
  end
  if frames == COIN then press(":IN0", "Coin 1", true) end
  if frames == COIN + 8 then press(":IN0", "Coin 1", false) end
  if frames == START then press(":P1_P3", "1 Player Start", true) end
  if frames == START + 8 then press(":P1_P3", "1 Player Start", false) end
  if frames > START + 8 then
    press(":P1_P3", "P1 Right", true)
    press(":P1_P3", "P1 Button 1", frames % 2 == 0)
    press(":P1_P3", "P1 Button 2", frames % 90 < 6)
    local c = frames % 240
    press(":IN0", "Coin 1", c < 6)
    press(":P1_P3", "1 Player Start", c >= 20 and c < 26)
  end
end
return M
