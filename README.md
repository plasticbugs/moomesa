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
| YM2151 | jt51 (Jose Tejada) | — (level against MAME not yet compared) |
| K054539 | `rtl/k054539.sv`, from MAME's model | `sim/check_k539.sh`: MAME's own code fed the same 40 s of commands, max difference 4 LSB, 68.8 dB |
| K054156/7 tilemaps, K053246/7 sprites, K053251, K054338 | `rtl/moo_*.sv` | `sim/run_video.sh`: pixel-identical to MAME on 47 frozen states |
| video semantics | `tools/moo_render.py` (Python model) | pixel-identical to MAME on the same 47 states |
| ROM | Pocket SDRAM (`target/pocket/moomesa_mem.sv`) | `sim/run_mem.sh` at the loader's rate; `tools/verify_rom.py`: image byte-identical to MAME's regions |
| every RAM | block RAM | — |
| EEPROM (ER5911) | jt5911; default contents from the romset; saved to the SD card | — (save path untested) |

## Status

**Not yet run on a Pocket.**

Proven, and by what:
- the ROM image: identical to what MAME hands each chip (`tools/verify_rom.py`),
  and built identically by `tools/mra_build.py` and the standard `mra` tool;
- the memory path: every region read back through the core's ports after a
  download at the loader's rate, 0 wrong (`sim/run_mem.sh`);
- the video: 47 frozen states from boot, attract, the intro's alpha-blended
  fog, character select, play with up to 65 sprites, zoom, line scroll and
  service mode, 0 differing pixels in the Python model and in the RTL;
- the K054539 against MAME's own code, sample by sample;
- the whole machine from reset, on ideal memories and on the real memory glue,
  to the game's RAM/ROM check screen with every checksum matching MAME's.

Not proven:
- anything on hardware;
- gameplay frames of the running machine against MAME's, and the sound of the
  whole machine against MAME's recording;
- sprite shadows and mirroring (never seen in 20 minutes of MAME census), the
  protection DMA with a non-zero length (never triggered), flip screen (not
  modelled — flagged on the panel if the game asks for it);
- the EEPROM save round trip.

Known differences from MAME: the object DMA takes real time (about 30 us)
where MAME's is instant.  The interrupts follow MAME's order, which the game
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
sim/run_machine.sh moomesa.rom -frames 450 -every 50 -o out   # the machine, ideal memories
sim/run_system.sh moomesa.rom -frames 450                     # the machine, real memory glue
```

## Credits

`CREDITS.md` is the full list.  The machine is written from MAME's `moo.cpp`
(R. Belmont, Acho A. Tang, after Olivier Galibert) and its Konami device
models; the CPUs are Jorge Cwik's fx68k and Guy Hutchison's tv80; the YM2151
and EEPROM are Jose Tejada's jt51 and jt5911.  **Marcus Andrade**
([@boogermann](https://github.com/boogermann), OpenGateware / Raetro) wrote
everything between the arcade hardware and the Pocket (`platform/pocket/`, the
project files, the `core_top` template, the Docker build image).  Analogue for
the APF.
