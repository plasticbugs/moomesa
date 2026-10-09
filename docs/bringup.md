# First flash: what to do and what to read

For the person holding the Pocket. Keep this exact — it is read from while
someone decodes squares off a screen.

## Before flashing

- `sim/lint.sh` clean; `sim/run_mem.sh` passes at `-gap 8 -hold 4`.
- The whole-machine bench on the real memory glue boots.
- **`tools/check_frames.py` passes on three CONSECUTIVE frames of a STILL
  picture** — snapshot the boot screen at, say, 2500, 2520 and 2540 ms and run
  it on the three. If neighbours differ while frames two apart are identical,
  the core is emitting alternating fields. The Pocket's panel is OLED and
  holds the difference between the two images — as retention that fades, and
  with enough hours as wear that does not. A core shipped this way and left a
  ghost on a user's screen; nothing else on this list touches their hardware.
  Do not flash until it passes (METHODOLOGY 5.23).
- `tools/check_json.py pkg/pocket --active <W>x<H>` clean — the firmware
  refuses a bad `interact.json` with nothing but "General Error", and a
  `video.json` that disagrees with the core comes out as three separate-looking
  picture faults.
- `./build-local.sh compile`: no negative slack in any corner
  (`projects/output_files/*.sta.summary`), no ignored constraints.
- The ROM image's md5 matches the MRA's.

## On the card

`release/pocket/` onto the card root, with `cp -X` from macOS. The ROM image
goes in `Assets/moomesa/common/moomesa.rom`. Verify the bitstream's md5 on the
card.

## A healthy boot

About six seconds of black (the game's own RAM tests), then a white
"VERSION EA / RAM ROM CHECK" page listing RAM and ROM checks, every one "OK",
with these checksums -- they are the same in MAME and in the RTL bench, so any
other number names a ROM region that arrived wrong:

    ROM F5 OK 151B     ROM W2 OK 0027
    ROM 05 OK 70F2     ROM 06 OK 8A86
    ROM T5 OK C5AD     ROM T6 OK 5689

Then the attract mode: the Konami logo, the story, the title, demo play.
Select inserts a coin, start starts; B or X shoots, A or Y jumps.

## The panel

The release menu no longer shows the bring-up switches; the RTL still honours
them.  To read the panel, add these back to `interact.json` (all `check`,
address `0xF2000000`, `defaultval` 0, `persist` false):

| id | name | value | mask | 0 (absent) means |
|---|---|---|---|---|
| 90 | Bring-up: panel | `0x00000008` | `0xFFFFFFF7` | panel off |
| 91 | SDRAM read late | `0x00000010` | `0xFFFFFFEF` | read late ON (the tested setting; the bit is inverted) |
| 92 | SDRAM slow bursts | `0x00000020` | `0xFFFFFFDF` | full-speed bursts (the tested setting) |

Menu → **Bring-up: panel**. Four rows of 32 squares along the bottom edge of
the picture (the *right* edge if the picture is rotated 270, read bottom to
top). Green is 1. Read each row from the end where row 0 shows `1010 1010`.

| row | squares | meaning | healthy |
|---|---|---|---|
| 0 | 1–8 | alignment marker | `1010 1010` — if not, stop: the reading is misaligned |
| 0 | 9–16 | frame counter | changing |
| 0 | 17 | PLL locked | 1 |
| 0 | 18 | memory ready | 1 |
| 0 | 19 | downloading | 0 |
| 0 | 20 | all slots complete | 1 |
| 0 | 21 | loaded | 1 |
| 0 | 22 | core in reset | 0 |
| 0 | 23 | CPU halted | 0 |
| 0 | 24 | watchdog has fired | 0 (expected 1 after the menu has been open a while) |
| 0 | 25 | IRQ5 (vblank) has been taken | 1 within a second |
| 0 | 26 | IRQ4 (after an object DMA) has been taken | 1 once the boot checks end, about 7 s in |
| 0 | 27 | (unused) | 0 |
| 0 | 28 | the K054539 missed a sample | 0 |
| 0 | 29 | (unused) | 0 |
| 0 | 30 | the game programmed a video mode the core does not model | 0 |
| 0 | 31 | a tilemap line was not finished in time | 0 |
| 0 | 32 | a sprite line was not finished in time | 0 |
| 1 | 1–8, 9–32 | first fault: vector, then the code address before it | all 0, or `08` / `04A392`: the boot ROM checksum reading address 8, which a healthy boot records too |
| 2 | 1–16, 17–24, 25–32 | first program ROM word, first sound ROM byte, first graphics byte | `0000 0000 0001 1000` (0018), `1110 1101` (ED), then any |
| 3 | 1–16, 17–32 | SRAM self-test | `1010 0101 0101 1010`, `0101 1010 1010 0101` |

Row 2 proves the path, not the image; `sim/run_mem.sh` proves the image.

## If it is wrong

| symptom | look at |
|---|---|
| black, counter running, row 2 right, watchdog 1 | the image in SDRAM — rerun `sim/run_mem.sh`; section 5.16 |
| row 3 not the pattern | the SRAM port (the game keeps nothing there; only its self-test) |
| row 2 wrong | the SDRAM switches (ids 91, 92 above); then the PLL phase (SDC, section 5.20) |
| garbled picture | ask for the service-mode test pattern first; section 5.18 |
| glitches only while playing, gone in the menu | something the CPU shares with the video; section 5.17 |
| menu restarts the game | `pause` has reached a reset; section 5.5 |
| black, IRQ5 1, IRQ4 0, unsupported video mode 1 | the EEPROM: the game has flipped the screen, which the core does not draw, and stopped on ROM W2 BAD.  A blank save (all 0xFF) does this |

## With an Analogizer

First run on hardware 2026-10-08 (the log): "looks good", the picture about
10 lines high on that CRT, which the position sliders below are for.
docs/analogizer.md says what the bench proved.  With a new build, in this
order -- each step's reading tells the next one where to look:

1. **Menu "Analogizer: Off"** (the default).  The core must play exactly as
   without the adapter, Pocket screen and controls.  If it does not, the
   cart port is not idle: stop there.
2. **Menu: Analogizer On, Video RGBS, SNAC Adapter None.**
   Expected: the same picture on the Pocket and on the CRT, 15.625 kHz /
   59.19 Hz (a PVM's info screen shows it).  The bring-up panel (menu,
   "Bring-up panel") shows on the CRT too, so it can be read there.
   No picture at all: say whether the CRT reports a signal (sync but no
   colour points at the DAC clock; nothing at all points at sync).
3. **Each other video mode in turn** (RGsB and YPbPr need the SOG switch on).
4. **SNAC**: one pad, assignment "SNAC P1 -> P1"; then the Pocket's
   own controls should be player 2.
5. **The menu's memory**: change Video, quit the core and load it again.
   The setting, and Analogizer On, should still be there.  Then change
   one entry and check the others did not move (the bench's read-back
   check, on the real firmware).
6. **Position**: "Analogizer V Position" +10 should move the picture
   about 10 lines down, + on "H Position" to the right, and both should
   be kept across a reload.  The slider showing a value other than the
   one set means the firmware is not reading 0xF7000004/8 back as written.
   A picture that rolls or tears at either end of a slider means the
   range is too wide for that set (say which end, and which mode).

## Log

Date, build md5, what was seen, what it ruled out. One line each. The theories
that died belong here as much as the one that lived.

- 2026-09-25, bitstream md5 7a4d7db59cce32203ef7dc640ca25c4d (compile 14):
  not yet flashed.  Fit 48% ALMs, 260/308 RAM blocks; setup slack +0.063 ns
  worst corner; no ignored constraints in moomesa_pocket.sdc; run_mem pass
  at holds 1/4/7; run_system to character select; check_frames pass;
  check_json pass.
- 2026-09-25, same bitstream, first flash: black after the load.  Panel:
  platform healthy, CPU running, IRQ5 1, IRQ4 0, unsupported video mode 1,
  first fault 08 @ 04A392, rows 2 and 3 correct.  The fault is the ROM
  checksum (the RTL bench records the same).  MAME with an all-0xFF EEPROM
  flips the screen, prints ROM W2 BAD and stops on the check page -- which
  the core reports as unsupported and leaves black, and which never reaches
  IRQ4.  Cause: the Pocket created the nonvolatile save blank and loaded it
  over the default EEPROM.  Rules out the SDRAM path, the PLL and the load.
- 2026-09-25, bitstream md5 0905d92371cf096c8d9bca5739d50c5d (compile 15,
  commit 1f3e0ea): on the card.  Saves/moomesa/common/moomesa.sav read
  from the card: 128 bytes of 0xFF, as diagnosed.  Left in place: the core
  now ignores a blank save.  Expected: check page all OK (ROM W2 0027),
  then attract; IRQ4 1 by about 7 s, unsupported 0.
- 2026-09-25, bitstream 0905d923 (blank-save fix): boots and plays, "nearly
  perfect".  Afterwards moomesa.sav on the card held real settings (0000 0300
  0301 ...), not 0xFF: the save write path works on hardware.  Reported: on
  stage 2 (trains), with a busy screen, sprites drawn on every other line
  only.  Cause: the sprite line engine overran its 6144 clocks and dropped
  the next line's start; reproduced on the video bench at -slat 120.
- 2026-09-25, bitstream a65555687d0fce880c9a219bcde4f3fc (compile 17): the
  queued sprite engine and the button swap.  On the card.  Expected: no
  striped sprites on the trains; square 32 (sprite line missed) 0 -- if 1
  and nothing visibly wrong, the abandoned tail held only far sprites.
- 2026-09-25, bitstream a65555687d0fce880c9a219bcde4f3fc: stage 2 (trains)
  clean -- no striped sprites.  The queued sprite engine fixed the overrun
  seen on hardware.  Package without the bring-up menu entries copied (same
  bitstream).
- 2026-09-25, same bitstream: a service-menu setting changed, core quit and
  relaunched -- the setting persisted.  The save round trip (write, then
  load into bank 1 over the default) works on hardware.
- 2026-09-25, same bitstream: sprite shadows compared by eye with arcade
  footage on YouTube -- they match.  (No frozen state has a shadow in it; this
  is a visual check, not a pixel comparison.)
- 2026-09-25, same bitstream, card reset to stock: moomesa.sav and
  Settings/plasticbugs.moomesa/ deleted at the user's request.  Found there
  first: Input/_core/input_persist.json held the FIRST build's mapping
  (Jump id 200 -> button 5 = B, Shoot id 201 -> 4 = A).  A saved mapping
  overrides input.json's defaults, so after the button swap the Pocket
  probably went on routing the buttons the old way -- the likely cause of
  "B should be shoot".  After changing button defaults, delete the core's
  Settings/<core>/Input folder (or remap in Controls) before judging them.
- 2026-09-25, same bitstream: on the map between stages only one trophy
  showed, though several stages were cleared (all showed on the final map).
  MAME, played by tools/bot_inputs.lua (three stages cleared: town, trains,
  plant), shows the same: one trophy (Niagara Desert), flags elsewhere, not
  blinking over the frames captured.  The RTL draws those six map frames
  pixel-identical to MAME (sim/states/map).  The game's own behaviour.
- 2026-09-25: final boss's fog stays solid gray -- as in MAME.  Traced with
  the ezgames69 TAS (tools/bk2_inputs.lua): the game fades PBLEND 1F..01 then
  clears MIXPRI; MAME ties blending to MIXPRI and redraws the fog solid.  The
  board mixes per tile (colour low bits, docs/hardware.md 7.3).  Bitstream
  7974346f29057c1a1b30df40c9479c3f (compile 18) has the per-tile rule.
  Quick check on hardware: the attract intro's meteor should land on visible
  ground (artifacts/fog/intro_1200_*).
- 2026-09-25, bitstream 7974346f29057c1a1b30df40c9479c3f on hardware:
  "It's perfect."  The final boss's fog fades and stays gone; the intro's
  meteor lands on visible ground.  The per-tile mixing rule confirmed on the
  Pocket against the arcade's behaviour.
- 2026-10-08, bitstream 76f07c6ea87c211d43a3fc4e7c1c8d87 (Analogizer, menu
  settings) copied to the card, not yet run.  With "Analogizer: Off" it
  should play exactly as 7974346f did; the first reading is that, then the
  menu entries appear under the game's own.  (The file-settings build
  98d985e0 went on the card earlier the same day and was replaced unrun.)
- 2026-10-08, 76f07c6e on hardware with an Analogizer and a CRT: "looks
  good"; the picture sits about 10 px too high, all of it visible with the
  set's overscan on.  The menu, the adapter, the video path and the
  defaults all work on the real firmware.  Led to the position sliders.
- 2026-10-08, bitstream 2fb58c1a5ef5aa60f501b7ce536129c8 (Analogizer H/V
  Position sliders): not yet run.  At 0 it should look exactly as 76f07c6e
  did; "Analogizer V Position" +10 should centre the picture on that CRT.
- 2026-10-08, 2fb58c1a on hardware with the Analogizer: "works great";
  released as v0.3.0 from this bitstream.
