# The Analogizer

[Analogizer](https://github.com/RndMnkIII/Analogizer) is RndMnkIII's adapter
for the Pocket's cartridge slot. It gives analog video out of a VGA connector
(RGBS, RGsB, YPbPr, Y/C, and a scandoubled RGBHV) and takes native controllers
through SNAC adapters. Its wiki is the authority on the adapter itself:
[specifications](https://github.com/RndMnkIII/Analogizer/wiki/Analogizer-Specifications),
[how to configure it](https://github.com/RndMnkIII/Analogizer/wiki/Supported-Cores-and-How-to-Configure-Them).

This page covers what this core does with it, for the person using it and for
whoever changes the core next.

## For the player

**Settings live in a file, not the Pocket's menu.** Generate `analogizer.bin`
with [Pupdate](https://github.com/mattpannella/pupdate) (*Pocket Setup →
Analogizer Config → Standard Analogizer Config*) or
[AnalogizerConfigurator](https://github.com/RndMnkIII/AnalogizerConfigurator),
and put it in `/Assets/analogizer/common/` on the SD card. Every
Analogizer core that uses the file (the "Analogizer File" kind in the wiki's
list) shares it. Turn **Analogizer enable** on in the tool. With no file, or
with it off, the core behaves exactly as it did without Analogizer support.

**Video.** The core sends the board's own signal: 384 × 224 visible, 15.625
kHz lines, 59.19 Hz, the timing a 15 kHz arcade monitor or a PVM expects.

| mode | SOG switch | notes |
|---|---|---|
| RGBS | off | VGA-to-SCART or VGA-to-BNC |
| RGsB | on | R2/R3 adapters only |
| YPbPr | on | R2/R3 adapters only |
| Y/C NTSC, Y/C PAL | off | needs an active Y/C adapter on the VGA port |
| SC 0% / 25% / 50% / 75% / HQ2x | off | scandoubled for a VGA monitor: 31.25 kHz |

"Blank the Pocket screen" in the tool turns the Pocket's own picture black
while the CRT keeps it.

**Controllers.** SNAC pads (DB15, NES, SNES, PC Engine 2/6-button and
multitap, PlayStation) replace the Pocket's controls according to the
assignment chosen in the tool:

| assignment | player 1 | player 2 | player 3 | player 4 |
|---|---|---|---|---|
| SNAC P1 → Pocket P1 | SNAC 1 | the Pocket's own controls | dock 3 | dock 4 |
| SNAC P1 → Pocket P2 | Pocket | SNAC 1 | dock 3 | dock 4 |
| SNAC P1,P2 → P1,P2 | SNAC 1 | SNAC 2 | dock 3 | dock 4 |
| SNAC P1,P2 → P2,P1 | SNAC 2 | SNAC 1 | dock 3 | dock 4 |
| SNAC P1,P2 → P3,P4 | Pocket | dock 2 | SNAC 1 | SNAC 2 |
| SNAC P1-P4 → P1-P4 | SNAC 1 | SNAC 2 | SNAC 3 | SNAC 4 |

Moo Mesa is a four-player board, so the last two rows are useful here. Four
SNAC players need the PC Engine multitap. The buttons map as they do on the
Pocket: B or X shoots, A or Y jumps, select is coin, start is start. A
PlayStation pad in analog mode steers with its left stick.

**Cart power is on for everyone.** `core.json` declares the cartridge adapter,
so the Pocket powers the slot whether or not an Analogizer is in it. Do not
leave a game cartridge in the slot while this core runs.

**Not verified on hardware by this core's maintainer**, who has no Analogizer
or CRT. What has been checked is listed under *What was measured* below. Send
problems with the adapter itself to the Analogizer project.

## For the developer

### The pieces

| file | what |
|---|---|
| `target/pocket/analogizer/` | RndMnkIII's `openFPGA_Pocket_Analogizer` and what it instantiates, **verbatim** (modules/VENDOR.md has the commit). Its `analogizer.qip` is ours: only what is used. |
| `target/pocket/pocket_analogizer.sv` | the wrapper: clock hand-over, Y/C constants, SNAC → controller words. Core-agnostic; the same file in the template. |
| `target/pocket/core_top.sv` | `USE_ANALOGIZER`, the instance (after the bring-up panel), `key1..key4` in place of `cont1..4_key`, the bridge read at `0xF7xxxxxx`, the Pocket-screen blank, and the cart pins' idle levels when it is off. |
| `core_pll` `outclk_4` | the Analogizer's 48 MHz, `clk_sys / 2` in phase; in the SDC's PLL group. |
| `pkg/.../core.json` | `"platform_ids": ["moomesa", "analogizer"]`, `"cartridge_adapter": 0` |
| `pkg/.../data.json` | slot 10, `analogizer.bin`, `0xF7000000`, `"parameters": "0x1000000"` (bits 25:24 = 1: the file is looked up under platform index 1, `analogizer`), not required, not nonvolatile |
| `sim/run_analogizer.sh` | the bench (below) |
| `tools/check_json.py` | fails if slot, platform id and cart power disagree |

### The settings word

What the Pocket writes to `0xF7000000` from `analogizer.bin` (little-endian in
the file; the adapter module swaps it for `bridge_endian_little = 0`):

| bits | field | values |
|---|---|---|
| 4:0 | SNAC type | 0 none, 1 DB15, 2 NES, 3 SNES, 4 PCE 2-button, 5 PCE 6-button, 6 PCE multitap, 9 DB15 fast, 0xB SNES A/B↔X/Y, 0xC–0xF PS/2 keyboard (+ pad), 0x11 PSX digital, 0x13 PSX analog, 0x14 JVS. 16 and up select the adapter's B wiring. |
| 5 | enable | 0: the port stays idle and nothing else applies |
| 9:6 | SNAC assignment | 0–5 as in the table above |
| 13:10 | video | 0 RGBS, 1 RGsB, 2 YPbPr, 3 Y/C NTSC, 4 Y/C PAL, 5–9 scandoubler 0/25/50/75%/HQ2x |
| 14 | blank the Pocket screen | |
| 15 | OSD on the Analogizer output | not used by this core |

The wiki's specification page shows an older scheme: the same fields at
`0xA0000000`, set from `interact.json`, with "Pocket OFF" folded into the
video value. Current adapter modules (1.4) read only the file. Those
`interact.json` values do nothing here.

### Clocks

`openFPGA_Pocket_Analogizer` runs its logic on `i_clk`, puts `video_clk` on the
cartridge pin that clocks the ADV7123, and assumes that is `i_clk` too. The
scandoubler halves the pixel period, so the clock has to be at least four
times the dot rate. The shipped Analogizer cores use 42.95–48 MHz. This core's
system clock is 96 MHz, which is more than the cart's level translators have
been asked to pass, so the PLL's spare output gives 48 MHz, in phase with
`clk_sys`. `pocket_analogizer` takes each pixel two system clocks after the dot
enable (`PIX_LAG`) into a holding register and hands it over with a toggle.
The Analogizer side picks it up two or three of its clocks later, well inside
the 12-clock dot.

The Y/C encoder's subcarrier step and colour-burst window are computed in
integers from `CLK_HZ`. The reals used elsewhere lose the bits past 32 in some
tools, and MSX2's hand-typed NTSC step is a few counts off.

### Using SNAC in the game's inputs

`pocket_analogizer` outputs `key1..key4`, the Pocket's controller words with
SNAC pads put in place by the assignment. SNAC's bit order is the Pocket's
(0 up, 1 down, 2 left, 3 right, 4 A, 5 B, 6 X, 7 Y, 8 L1, 9 R1, … 14 select,
15 start). They feed the `gamepad` helper and the direct player-3/4 reads in
place of `cont1..4_key`, so the game's input logic did not change.

### What was measured

- `sim/run_analogizer.sh`: the wrapper and the vendored module at this core's
  raster and clocks, read at the cartridge pins as the DAC reads them.
  - With no settings file, every pin sits as on a core without the adapter,
    and the controller words pass through.
  - RGBS: all 86,016 visible dots of a frame reach the DAC pins, in raster
    order, as their top six bits per channel, with 0 differing. Csync is one
    40-dot pulse a line.
  - Scandoubler: 528 lines per frame at 1536 clocks, half the core's 3072.
  - YPbPr and Y/C NTSC/PAL: no unknown on any pin for a frame.
  - All six SNAC assignments, the analog stick, and type "none" map as
    tabled.
  - The blank bit, and enable off again returning the port to idle.
- `sim/lint.sh`: the wrapper lints clean. The vendored files' warnings are
  dropped by path; their errors are not.
- Quartus 18.1: compiles, every SDC constraint applied, no negative slack
  at any corner (worst setup +0.354 ns slow 0C, worst hold +0.080 ns fast
  0C). The Analogizer costs 1,550 ALMs (9,089 → 10,639, 58%), 13 RAM blocks
  (265 → 278 of 308) and 2 DSP blocks.

**Not proven:** anything on hardware, and the SNAC serial protocols, which are
the adapter module's and are forced at its outputs in the bench rather than
driven over the pins. The Y/C and YPbPr encodings have no reference to compare
against, only a run without unknowns.

### Turning it off

Set `USE_ANALOGIZER = 0` in `core_top.sv`, remove `general[4]` from the PLL
group in the SDC (it would match nothing), and take the slot, the
`analogizer` platform id and `cartridge_adapter: 0` out of the JSON.
