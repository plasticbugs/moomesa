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
Select inserts a coin, start starts; A or Y shoots, B or X jumps.

## The panel

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
| 0 | 25 | IRQ5 (object-DMA end) has been taken | 1 once the game runs |
| 0 | 26 | IRQ4 (vblank) has been taken | 1 once the game runs |
| 0 | 27 | (unused) | 0 |
| 0 | 28 | the K054539 missed a sample | 0 |
| 0 | 29 | (unused) | 0 |
| 0 | 30 | the game programmed a video mode the core does not model | 0 |
| 0 | 31 | a tilemap line was not finished in time | 0 |
| 0 | 32 | a sprite line was not finished in time | 0 |
| 1 | 1–8, 9–32 | first fault: vector, then the code address before it | all 0 |
| 2 | 1–16, 17–24, 25–32 | first program ROM word, first sound ROM byte, first graphics byte | `0000 0000 0001 1000` (0018), `1110 1101` (ED), then any |
| 3 | 1–16, 17–32 | SRAM self-test | `1010 0101 0101 1010`, `0101 1010 1010 0101` |

Row 2 proves the path, not the image; `sim/run_mem.sh` proves the image.

## If it is wrong

| symptom | look at |
|---|---|
| black, counter running, row 2 right, watchdog 1 | the image in SDRAM — rerun `sim/run_mem.sh`; section 5.16 |
| row 3 not the pattern | the SRAM port (the game keeps nothing there; only its self-test) |
| row 2 wrong | **Bring-up: SDRAM** switches; then the PLL phase (SDC, section 5.20) |
| garbled picture | ask for the service-mode test pattern first; section 5.18 |
| glitches only while playing, gone in the menu | something the CPU shares with the video; section 5.17 |
| menu restarts the game | `pause` has reached a reset; section 5.5 |

## Log

Date, build md5, what was seen, what it ruled out. One line each. The theories
that died belong here as much as the one that lived.

- 2026-09-25, bitstream md5 7a4d7db59cce32203ef7dc640ca25c4d (compile 14):
  not yet flashed.  Fit 48% ALMs, 260/308 RAM blocks; setup slack +0.063 ns
  worst corner; no ignored constraints in moomesa_pocket.sdc; run_mem pass
  at holds 1/4/7; run_system to character select; check_frames pass;
  check_json pass.
