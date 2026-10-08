# Wild West C.O.W.-Boys of Moo Mesa — Analogue Pocket core (openFPGA)

Konami, 1992, board GX151: a 68000 at 16 MHz, a Z80 at 8 MHz, a YM2151 and a
K054539 PCM chip in stereo, the K054156/K054157 tilemaps, K053246/K053247
sprites with zoom, the K053251 and K054338 mixers, and a K053990 protection
DMA.  All of it is in the gateware; the machine is described in
[`docs/hardware.md`](docs/hardware.md) and its mapping onto the Pocket in
[`docs/core-design.md`](docs/core-design.md).

> **ROMs are not included and never will be.** You supply your own MAME
> `moomesa` romset (ver EAB); the core reads one image built from it.

| board part | implementation | verified by |
|---|---|---|
| 68000 @ 16 MHz | fx68k (Jorge Cwik) | boots and runs the game's own RAM/ROM check on both benches |
| Z80 @ 8 MHz | tv80 (Guy Hutchison) via `rtl/z80_cen.sv` | reports the sound ROM checksum MAME shows (151B) |
| YM2151 | jt51 (Jose Tejada) | only as part of the whole mix against MAME's recording (below) |
| K054539 | `rtl/k054539.sv`, from MAME's model | `sim/check_k539.sh`: MAME's own code fed the same 40 s of commands, max difference 4 LSB, 68.8 dB |
| K054156/7 tilemaps, K053246/7 sprites, K053251, K054338 | `rtl/moo_*.sv` | `sim/run_video.sh`: 64 frozen states, 61 pixel-identical to MAME and 3 to the board's mixing rule where MAME is wrong |
| video semantics | `tools/moo_render.py` (Python model) | pixel-identical to MAME on all 64 (MAME's rule), and the board's rule on the 3 |
| ROM | Pocket SDRAM (`target/pocket/moomesa_mem.sv`) | `sim/run_mem.sh` at the loader's rate; `tools/verify_rom.py`: image byte-identical to MAME's regions |
| every RAM | block RAM | — |
| EEPROM (ER5911) | jt5911; default contents from the romset; saved to the SD card | round trip on hardware (settings kept across launches); a blank save is ignored (`sim/run_system.sh -save ff`) |

## Status

**Runs on the Pocket**: boots, passes its RAM/ROM check, and plays through
stage 1 and into stage 2.  The build fits (58% of the ALMs, 278 of 308 RAM
blocks, with the Analogizer) and meets timing at every corner (worst setup
slack +0.354 ns at 96 MHz).  `docs/bringup.md` logs every hardware run.

## Controls and menu

| Pocket | game |
|---|---|
| D-pad | move |
| B or X | shoot |
| A or Y | jump |
| Select | coin |
| Start | start |

Players 3 and 4 come from a docked Pocket's third and fourth controllers.
The core menu has the board's DIP switches (sound output, coin slots,
cabinet players), the screen shape, scanlines and shadow mask, and the
service switch, which opens the game's own test and settings menu
(difficulty, lives and so on).  Those settings live in the game's EEPROM and
are saved to the SD card.  On a first launch the Pocket creates that save
file blank; the core ignores a blank save and starts from the romset's
defaults.

## Analogizer

The core supports RndMnkIII's [Analogizer](https://github.com/RndMnkIII/Analogizer)
adapter: the board's native 15 kHz picture out of the VGA port (RGBS, RGsB,
YPbPr, Y/C, or scandoubled for a VGA monitor), and up to four SNAC
controllers.  It is set up from `analogizer.bin` in
`/Assets/analogizer/common/`, the file Pupdate and AnalogizerConfigurator
write and every Analogizer core shares; without it the core is unchanged.
Because the core declares a cartridge adapter, the Pocket powers the slot:
take any game cartridge out first.  `docs/analogizer.md` has the modes, the
controller assignments, and what has and has not been checked (the path is
proven in simulation; no Analogizer has been tried with this core yet).

## What is proven, and by what

- the ROM image: identical to what MAME hands each chip (`tools/verify_rom.py`),
  and built identically by `tools/mra_build.py` and the standard `mra` tool;
- the memory path: every region read back through the core's ports after a
  download at the loader's rate, 0 wrong, also with all five ports at once
  (`sim/run_mem.sh`);
- the video: 64 frozen states from boot, attract, the intro's alpha-blended
  fog, character select, play with up to 65 sprites, zoom, line scroll,
  service mode, every map screen of a full playthrough and the final boss,
  0 differing pixels in the Python model and in the RTL (against MAME, or
  on 3 frames against the board's mixing rule -- below);
- the sprite engine under overload: when a line cannot be finished in time
  it loses its farthest sprites, never a whole line (`sim/run_video.sh
  -slat N`; pictures in `artifacts/sprite_overload/`);
- the K054539 against MAME's own code, sample by sample (max 4 LSB over 40 s);
- the whole machine from reset: RAM/ROM check with MAME's checksums, title
  with the credit, character select, stage 1 (`sim/run_machine.sh`); on the
  real memory glue into stage 1, 2400 frames, with the queued sprite engine
  (`sim/run_system.sh`);
- its sound against MAME's recording with the same inputs: per-second level
  within about 10%, same band profile, starting in the same second;
- three consecutive frames of a still screen identical (no OLED-marking
  alternation, `tools/check_frames.py`);
- on hardware: the final boss's fog fading and staying gone, and the
  intro's ground, with the per-tile mixing rule; the boot, stage 1, stage 2's train scene without the striped
  sprites the first sprite engine gave it, and service-menu settings kept
  across launches (the save written to the card and read back).

Not proven:
- long play beyond the frames captured: a TAS of the whole game
  (`tools/bk2_inputs.lua`) now reaches every stage in MAME, but only the map
  screens and the final boss are in the gate so far;
- sprite shadows pixel for pixel (no captured frame has one; on hardware
  they match arcade footage by eye), sprite mirroring (never seen in 20
  minutes of MAME census), the protection DMA with a non-zero length (never
  triggered);
- players 3 and 4 (wired from a docked Pocket's controllers, untested).

Not modelled: flip screen.  Set in the game's service menu, it makes the
tilemaps disappear (the panel's "unsupported video mode" square lights).

Known differences from MAME:
- **Alpha mixing is per tile, as on the board.** MAME blends the front layer
  whenever a K054338 bit (MIXPRI) is set; the board uses a mix code in each
  tile's colour.  So here the final boss's fog fades away and stays gone
  (MAME fades it, then draws it solid again for the whole fight), and the
  intro's meteor lands on visible ground.  `docs/hardware.md` 7.3 has the
  register trace it was worked out from.
- The object DMA takes real time (about 30 us) where MAME's is instant.  The interrupts follow MAME's order, which the game
depends on -- see `docs/hardware.md` section 4 for the black screen an earlier
order produced.

## Building the ROM image

```sh
python3 tools/mra_build.py moomesa.mra moomesa.zip moomesa.rom
```

Needs only Python 3.  It checks every ROM's CRC32 and the finished image's md5
(`0ebb990422cb6b7c9c067b11450fd638`).  Copy the result to
`Assets/moomesa/common/moomesa.rom` on the SD card.

## Building the core

`./build-local.sh` compiles with Quartus 18.1 in Docker and leaves the SD-card
package in `release/pocket/`.  `./build-local.sh map` runs analysis and
synthesis only.

## Checking it

```sh
sim/lint.sh                        # every module on its own
sim/run_mem.sh moomesa.rom         # the Pocket's memory path, at the loader's rate
python3 tools/check_render.py moomesa.rom   # the Python model against MAME, 47 states
sim/run_video.sh moomesa.rom       # the video RTL against MAME, 47 states
sim/check_k539.sh moomesa.rom      # the K054539 against MAME's own code
sim/run_analogizer.sh              # the Analogizer path, read at the cartridge pins
sim/run_machine.sh moomesa.rom -frames 450 -every 50 -o out   # the machine, ideal memories
sim/run_system.sh moomesa.rom -frames 450                     # the machine, real memory glue
```

## Credits

`CREDITS.md` is the full list.

- **RndMnkIII** -- the Analogizer adapter and its module, with Mike
  Simone's Y/C encoder and MiSTer's scandoubler inside it.
- **MAME** -- the machine is written from `moo.cpp` (driver by R. Belmont and
  Acho A. Tang, based on Olivier Galibert's `xexex.cpp`; protection
  information from ElSemi and Olivier Galibert) and its Konami device models
  by David Haywood, Olivier Galibert, Fabio Priuli, Acho A. Tang, R. Belmont
  and Angelo Salese, with MAME's `drawgfx` (Nicola Salmoria, Aaron Giles) and
  `tilemap` (Aaron Giles) for how each pixel is drawn.
- **Jorge Cwik** -- fx68k, the 68000.
- **Guy Hutchison** -- tv80, the Z80.
- **Jose Tejada (jotego)** -- jt51 (the YM2151) and jt5911 (the EEPROM), and
  the `jtcores` Moo Mesa schematics, a second source for the board's wiring.
- **Marcus Andrade** ([@boogermann](https://github.com/boogermann),
  OpenGateware / Raetro) -- everything between the arcade hardware and the
  Pocket: `platform/pocket/`, the project files, the `core_top` template and
  the Docker image the build runs in.
- **Analogue** -- the Analogue Pocket Framework.
