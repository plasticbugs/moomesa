# The board

Konami GX151 (PWB353126), *Wild West C.O.W.-Boys of Moo Mesa*, 1992, set
`moomesa` (ver EAB). Written from MAME 0.288's driver and devices, fetched
verbatim into `ref/mame/` from tag `mame0288` (commit
`2c38dc6e555e17560bbf6f5531c3e86cf8570f54`), from the program ROM, and from
what the running game was measured to write into its chips
(`tools/probe_regs.lua`, `tools/probe_sound.lua`; 90 s of emulated time,
attract mode then one player in play). Where MAME and the ROM disagree, it says
so here and says which the core follows.

Files in `ref/mame/`: `moo.cpp` (driver); `k054156_k054157_k056832.*`,
`k053246_k053247_k055673.*`, `k053251.*`, `k054338.*`, `konami_helper.*`
(video); `k053252.*` (timing); `k054321.*`, `k054539.*`, `ymopm.*` (sound);
`eepromser.*`, `eeprom.*` (EEPROM); `k054000.*` (Bucky only, unused here);
`konamipt.h`, `m68000.h`; and MAME's core drawing code, which defines the
reference semantics of every pixel: `drawgfx.*`, `drawgfxt.ipp`, `tilemap.*`,
`dipalette.*`, `emupal.cpp`.

A second, independent source: Jose Tejada's (jotego) `jtcores`, which since
2026-09 holds an *incomplete* Moo Mesa core with KiCad schematics of this PCB
(`cores/moo/sch/moomesa`) and a decode taken from the 055373 PAL equations
(`jtmoo_main.v`). Cited below as "the schematic" where it settles something
MAME leaves open.

## 1. Parts and clocks

| part | type | clock | notes |
|---|---|---|---|
| main CPU | MC68000 | 16.000 MHz = 32 MHz / 2 | "verified" in MAME |
| sound CPU | Z80 | 8.000 MHz = 32 MHz / 4 | "verified" |
| FM | YM2151 | 4.000 MHz = 32 MHz / 8 | stereo, 0.30 each side |
| PCM | K054539 | 18.432 MHz crystal; sample rate 18.432 MHz / 384 = **48 000 Hz** | stereo, 0.50, **L and R swapped** in MAME's routing (ch0 -> right, ch1 -> left) |
| sound latch/volume | K054321 (inside 054986A) | — | three 8-bit latches, master volume, L/R mute |
| timing (CCU) | K053252 | 8 MHz dot clock | programmed by the game, see §7.1 |
| tilemaps | K054156 + K054157 (MAME models as K056832, 4 bpp) | 8 MHz dot | 4 layers |
| sprites | K053246 + K053247 | 8 MHz dot | 4 bpp, 16x16 cells, zoom |
| priority | K053251 | | |
| colour mixer | K054338 | | background colour, shadows, (alpha) |
| protection/DMA | K053990 | | "a + 2b" block operation, §2.2 |
| EEPROM | ER5911, 128 bytes, 8-bit mode | | default contents `moomesa.nv` in the romset |

**Video timing** (from the K053252 registers the game writes, §7.1): 8 MHz dot
clock, 512 dots x 264 lines, 384 x 224 visible. **59.185 Hz** (8 000 000 /
135 168 = 59.1856). The PCB notes in `moo.cpp` measure VSync at 59.1858 Hz,
which agrees; their HSync of 15.2036 kHz does not (8 MHz / 512 = 15.625 kHz,
and 15.625 kHz / 264 is the measured VSync), so that figure is taken as a
misreading. MAME itself runs the screen at a flat 60 Hz on a 512 x 256 raster;
the core follows the CCU.

**Audio pacing.** Music tempo is set by the Z80's program, which is driven by
interrupts from the main CPU (one `SNDIRQ` per sound command: 310 in 5327
frames) and by polling; the K054539's own timer
is never enabled (`0x22f` is only ever written 00, 01, 90; bit 5 never set).
The PCM chip runs from its own crystal at 48 kHz exactly. So the section 5.3 trap
(CPU rate = sample rate) does not apply, but the YM2151 and K054539 outputs
both cross into the Pocket's audio domain (section 5.4).

## 2. Memory map — main CPU (68000, 24-bit, 16-bit bus)

From `moo_prot_state::moo_map`. Byte-wide chips sit on the low byte
(`umask16(0x00ff)`) unless noted.

| range | size | what | R/W | notes |
|---|---|---|---|---|
| 000000-07FFFF | 512 KB | program ROM (151b01 even / 151eab02 odd) | R | |
| 0C0000-0C003F | 32 words | K056832 (K054156) registers "VACSET" | W | §7.2 |
| 0C2000-0C2007 | 8 bytes | K053246 registers | W | byte-addressed, §7.4 |
| 0C4000-0C4001 | | K053246 sprite-ROM readback | R | only while CONTROL2 bit 8 (OBJCHA) is set; 0 otherwise |
| 0CA000-0CA01F | 16 words | K054338 registers | W | §7.5 |
| 0CC000-0CC01F | 16 bytes | K053251 registers (low byte, 6 bits) | W | §7.6 |
| 0CE000-0CE01F | 16 words | K053990 protection registers | W | §2.2 |
| 0D0000-0D001F | 16 bytes | K053252 CCU (low byte) | R/W | §7.1 |
| 0D4000-0D4001 | | sound CPU IRQ | W | any write: Z80 /INT (MAME `HOLD_LINE`) |
| 0D6000-0D601F | | K054321 main side (low byte) | R/W | §5 |
| 0D8000-0D8007 | 4 words | K056832 "VSCCS" second register bank | W | copies of 02-07 |
| 0DA000-0DA001 | | P1 (low byte) / P3 (high byte) | R | §3 |
| 0DA002-0DA003 | | P2 / P4 | R | |
| 0DC000-0DC001 | | IN0: coins, service | R | |
| 0DC002-0DC003 | | IN1: EEPROM, test, DIPs | R | |
| 0DE000-0DE001 | | CONTROL2 | R/W | §2.1 |
| 100000-17FFFF | 512 KB | data ROM (151a03 even / 151a04 odd) | R | |
| 180000-18FFFF | 64 KB | work RAM | R/W | SP = 180900 at reset |
| 190000-19FFFF | 64 KB | sprite RAM (CPU view) | R/W | the 053246 DMA reads every 0x80th word group, §7.4 |
| 1A0000-1A1FFF | 8 KB | K056832 tile RAM window (one page, 4096 words) | R/W | mirrored at 1A2000 |
| 1B0000-1B1FFF | 8 KB | tile-ROM readback window | R | bank from VACSET 0x34/0x36 |
| 1C0000-1C1FFF | 8 KB | palette RAM, 2048 x 32 bit | R/W | §7.7 |

Addresses not listed return open bus in MAME (0 in practice) and are never
touched by the program as far as the probes saw.

### 2.1 CONTROL2 (0DE000), from `control2_w` and the ROM

| bit | meaning | measured |
|---|---|---|
| 0 | EEPROM DI | toggled |
| 1 | EEPROM CS | toggled |
| 2 | EEPROM CLK | toggled |
| 3 | unknown | set in 0x09/0x29 writes |
| 5 | IRQ5 enable (object-DMA-end interrupt; the IRQ5 handler clears it) | 0x21, 0x29 |
| 8 | OBJCHA: sprite-ROM readback at 0C4000 | only in the boot ROM test |
| 10 | watchdog (MAME ignores it) | toggled in 0x0c0c |
| 11 | IRQ4 enable (MAME, "unconfirmed") | 0x0808, 0x0c0c |

The register reads back what was written (`control2_r`).

### 2.2 K053990 protection (0CE000)

A write to word 0x0C starts `length = reg[0x0F]` word operations:
`dst[i] = src1[i] + 2 * src2[i]`, with 24-bit addresses `src1 = reg1<<16|reg0`,
`src2 = reg3<<16|reg2`, `dst = reg5<<16|reg4` (high words masked to 8 bits),
through the CPU's own address space. MAME does it instantaneously.
**Measured: triggered twice in 90 s, both at boot (frames 8 and 25) with every
register zero, i.e. length 0.** The core implements it (it is small), but no
capture so far exercises a non-zero length — unverified until one does.

## 3. Inputs and DIP switches

All active low unless noted. Ports are `IN0`, `IN1`, `P1_P3`, `P2_P4` in MAME.

**IN0 (0DC000, low byte):** bit 0-3 coin 1-4, bit 4-7 service 1-4.

**IN1 (0DC002, low byte):**

| bit | meaning |
|---|---|
| 0 | EEPROM DO (active high) |
| 1 | EEPROM ready (active high) |
| 2 | unknown (active high; MAME `IPT_UNKNOWN`) |
| 3 | service / test switch (active low) |
| 4 | DIP SW1:1 Sound Output: 1 = mono, **0 = stereo (default)** |
| 5 | DIP SW1:2 Coin Mechanism: **1 = common (default)**, 0 = independent |
| 6-7 | DIP SW1:3-4 Players: 11 = 2, 01 = 3, **10 = 4 (default)** |

**P1_P3 (0DA000):** low byte player 1, high byte player 3; P2_P4 the same for
players 2 and 4 (`KONAMI16_LSB/MSB`, `konamipt.h`): bit 0 left, 1 right, 2 up,
3 down, 4 button 1, 5 button 2, 6 unused (button 3 on Bucky), 7 start.

All other settings (difficulty, lives, credits) live in the EEPROM and are set
in the game's service menu.

## 4. Interrupts

Only autovectored levels 4 and 5 are used; every other vector points at an
`rte`-style stub at 0x1000.

| level | vector | handler does | raised (MAME, and the core) |
|---|---|---|---|
| 5 | 0x2482 | clears K053246 reg 5 bit 4 (DMA enable), CONTROL2 bit 5 (its own enable), and the flag `$18004A` | at the first line of vblank, while CONTROL2 bit 5 is set |
| 4 | 0x24B0 | acks the K053252 (reg 0x0E, `$D001D`) and K056832 reg 06; spins until `$18004A` is 0; sets it to 1; the frame's work; re-enables DMA and IRQ5 | 100 us after vblank, on frames whose vblank ran an object DMA, if CONTROL2 bit 11 is set then |

Both are held until acknowledged (MAME's `HOLD_LINE`).

**The order is not a detail.** Outside any interrupt, the main program waits
for a vblank at 0x20C8 and 0x210E: it sets `$18004A`, turns IRQ5 on (writes
0x20 to CONTROL2, without enabling DMA) and spins until the flag reads 0.
Only IRQ5 clears it, and IRQ4's handler sets it back to 1 as soon as it has
passed its own wait -- so the main program sees the 0 only in the window
between IRQ5 and IRQ4.

*Corrected, 2026-09-25.* An earlier version of this section read the IRQ4
handler's wait as "IRQ5 must come after IRQ4" and had the core raise IRQ4 at
vblank and IRQ5 at the end of the DMA, calling that the ROM's order and
MAME's the reverse.  The whole-machine bench then ran into the game's first
screen change after a coin and stayed black: the 68000 spent every frame in
IRQ4's handler, the main program's vblank wait never saw the flag at 0, and
the title's palette was never loaded (fetch histogram: all but a few
thousand fetches per frame at 0x2550-0x256F; the model drew the RTL's state
as black too, palette all zero).  MAME's model -- IRQ5 first, IRQ4 100 us
later -- is what the program needs, and is what the core now does.  The
CCU's INT1 line and the board's true DMA duration are still unmeasured; the
100 us is MAME's.

**A cycle-by-cycle CPU trace against MAME still diverges** (the DMA takes
real time here; MAME copies instantly), so comparisons against MAME are at
the level of frame contents.

## 5. Main CPU to sound CPU (K054321)

Main side (0D6000 + 2n, low byte): n=0 L/R enable (bit 1 left, bit 0 right),
n=2 volume reset, n=3 volume +1 (range 0-64, 40 = unity; gain
2^((v-40)/10)), n=4 dummy (0x4A), **n=6 latch 0 write, n=7 latch 1 write**,
n=8 busy read (always 0 in MAME), **n=0xA latch 2 read**.

Sound side (F000-F003): F000 write latch 2, F002 read latch 0, F003 read
latch 1.

Measured over 90 s: latch 0 written 310 times, latch 1 six times; volume
reset 5 times and incremented 121 times in all, i.e. the game resets the
counter and pulses it up to its setting rather than writing a value.

## 6. Sound board

Z80 map (`sound_map`):

| range | what |
|---|---|
| 0000-7FFF | ROM 151a07, first 32 KB |
| 8000-BFFF | ROM bank, 16 x 16 KB of 151a07, selected by F800 bits 0-3 (banks 0-7 seen) |
| C000-DFFF | RAM 8 KB |
| E000-E22F | K054539 registers |
| EC00-EC01 | YM2151 address / data |
| F000-F003 | K054321 sound side |
| F800 | bank select (write) |

Z80 interrupts: /INT from the main CPU's write to 0D4000. No NMI, and the
K054539 timer is not connected in MAME and never enabled by the program.

**K054539 as used** (`probe_sound.lua`): all three sample formats — 8-bit PCM
(type 0), 16-bit PCM (4), 4-bit DPCM (8); loop bit used; reverb used (send
level reg 4 non-zero on most notes, delay regs 6-7 non-zero on 16 notes); pans
in the 0x81-0x8F range; `0x22F` = 0x01 (PCM on, no timer, no readback) after
a boot-time RAM test through 0x22D/0x22E with 0x80 (reverb RAM) selected.
Sample ROM 151a08, 2 MB. Reverb RAM 32 KB (MAME allocates 0x8000 and uses the
first 0x4000 bytes as 0x2000 16-bit words).

Mixing in MAME: YM2151 0.30 per side, K054539 0.50 per side with its outputs
crossed, both through the K054321's volume and per-side enable, into a stereo
speaker. DIP "Sound Output: mono" changes what the program writes, not the
routing.

## 7. Video

### 7.1 K053252 CCU — as programmed (written once at boot)

`00 01 | 01 FF | 02 00 | 03 21 | 04 00 | 05 37 | 08 01 | 09 07 | 0A 11 | 0B 0E | 0C 74`

HC = 0x1FF+1 = 512, HFP = 0x21 = 33, HBP = 0x37 = 55, HSW = 4+1 = 5 (x8 = 40);
512 - 33 - 55 - 40 = **384**. VC = 0x107+1 = 264, VFP = 0x11 = 17, VBP =
0x0E+1 = 15, VSW = 7+1 = 8; 264 - 17 - 15 - 8 = **224**. INT1EN (06), INT2EN
(07) and INT-TIME (0D) are never written. INT1ACK (0E) is written about
twice a frame.

MAME's visible area is x 40..423, y 16..239 of a 512 x 256 bitmap; the core's
frame comparisons use MAME's 384 x 224 window.

### 7.2 Tilemaps (K054156/K054157, MAME `k056832_device`, `K056832_BPP_4`)

Four layers A-D (MAME layers 0-3). Each is built from 64 x 32-tile pages
(512 x 256 pixels, 8 x 8 tiles) in a 4 x 4 page grid.

**As programmed** (all written once at boot):

| reg | value | meaning |
|---|---|---|
| 00 | 0x44 | no flip; bit 1 (external linescroll) clear |
| 06 | 0x00D0 | FBIT = 3: flip bits are attr bits 0-1, colour = attr >> 2 |
| 08 | 0xFF | tile mode 8x8 on all layers |
| 0A | 0xFF | scroll mode 3 (plain x/y scroll) on **every** layer — no line or row scroll |
| 10-16 | 0, 0, 8, 8 | layer Y page 0,0,1,1, height 1 page |
| 18-1E | 0, 8, 0, 8 | layer X page 0,1,0,1, width 1 page |
| 30 | 0x10 | linescroll bank (unused: mode 3) |
| 32 | 0, 1, 8, 9 | CPU RAM bank = page 0, 1, 4, 5 |
| 3A/3C | 0DCF / 0700 | flip correction offsets (flip never set) |

So **layer A = page 0, B = page 1, C = page 4, D = page 5**, one page each,
and the CPU only ever writes those four pages (probe: 0, 1, 4, 5, no other).
That matches the PCB's tile RAM, three 8 KB x 8 chips = 8192 x 24 bits =
four pages of 2048 tiles; MAME allocates sixteen.

Tile entry, two words in MAME (`get_tile_info`): word 0 attr, word 1 code.
With FBIT = 3: attr bits 0-1 = flip x/y (masked by VACSET 02 per layer —
0xFF here, so all allowed), attr bits 2-7 = colour; then `tile_callback`:
**palette = layer_colorbase[layer] | (attr >> 4 & 0xF)** (16-colour units).
Code is the full 16 bits (2 MB of 4 bpp tiles = 65 536 tiles).

Tile pixel format (`charlayout4`): 32 bytes per tile, one 32-bit row per
line, 4 bpp packed, planes at bit offsets 0-3 of each pixel's nibble. MAME
numbers bits from the MSB of byte 0, and the x offsets are
`{2,3,0,1,6,7,4,5} * 4`: pixel 0 is the third nibble of the row, pixel 1 the
fourth, pixel 2 the first. The tile ROM image interleaves 151a05 and 151a06
16 bits at a time (`ROM_LOAD32_WORD`), so a row is an a05 word followed by an
a06 word. The reference renderer (step 4) pins this against MAME's output;
do not implement it from this paragraph.

Scroll: per layer 16-bit signed X at VACSET 0x28+2n and Y at 0x20+2n, plus a
fixed per-layer offset from `VIDEO_START(moo)`: `set_layer_offs(n, dx, 0)`
with dx = -1, +3, +5, +7 for A-D (MAME: "other than the intro showing one
blank line alignment is good"). In `tilemap_draw_common` the source x is
`scrollx - layer_offs` and source y is `scrolly`, wrapped to the 512 x 256 page.
Pen 0 is transparent.

Layer palette bases (`screen_update`): layer A **fixed at 0x70**, layers B, C,
D from the K053251's CI2, CI3, CI4 bases (§7.6).

### 7.3 Draw order (MAME `screen_update`), as a specification

1. Fill with the K054338 background colour (regs 0/1; black here).
2. Clear the priority bitmap.
3. Sort layers B, C, D by K053251 priority (CI2, CI3, CI4 registers),
   largest value first (`konami_sortlayers3`). As programmed:
   D (0x30), C (0x24), B (0x18).
4. Draw the first (back) layer with priority tag 1 — only if its priority is
   below CI1's (0x3F here, so always).
5. Draw the second with tag 2.
6. Draw the third with tag 4.  MAME: blended at PBLEND level 1 while K054338
   CONTROL.MIXPRI is set, and not drawn at all when that level is 0; the
   driver calls this a stand-in ("DUMMY ... probably a control bit
   somewhere").  **The board, and the core: per tile**, below.
7. Draw every sprite, §7.4.
8. Draw layer A on top of everything, tag 0.

**Mixing per tile (the board's rule, not MAME's).** The two low bits of a
tile's colour -- which MAME's `tile_callback` drops with `>> 2` -- are a mix
code: 0 solid; 1, 2, 3 blended at the K054338 level `set_alpha_level(m)`
reads (PBLEND word 13 low byte, word 14 high byte, word 14 low byte; 5 bits
expanded to 8), and left out where that level is 0.  MIXPRI plays no part.
Measured on the TAS (tools/bk2_inputs.lua), final boss:

| frame | CONTROL | PBLEND | front layer (B) tiles by mix code |
|---|---|---|---|
| 54000, before | 01 | 00 | 2048 x 0 |
| 55601, fog up | 03 | 1F | 512 x 0, 1536 x 1 (the fog) |
| 55841-55870 | 03 | 1E .. 01, one a frame | the same |
| 55871 on | 01 | 00 | the same |

After 55871 the registers are those of ordinary play, so only the tiles can
say the fog is gone: MAME, which ties blending to MIXPRI, draws it solid
again and keeps it for the whole fight (reported against the arcade from the
Pocket, and seen in MAME).  In ordinary play every tile's code is 0.  The
same rule shows the ground in the intro's meteor scene (attract 1200, CONTROL
03, PBLEND 00: 1344 tiles code 0, 704 code 1), which MAME's rule hides -- the
"other things disappear" of MAME's own comment.  Over the 64 frozen states
the rule differs from MAME on exactly those three frames; the gate holds them
to the rule (`sim/states/*/*.board.png`, `MOO_MIX=board` in
`tools/moo_render.py`) and the other 61 to MAME.  Still MAME's, unverified
on the board: only the front layer is mixed, and PBLEND's additive bit is
ignored.

### 7.4 Sprites (K053246 + K053247)

**DMA.** When K053246 reg 5 bit 4 is set, at vblank the chip copies sprite
RAM into its own 256 x 8-word list: it walks 256 entries at a stride of 0x80
words (one every 256 bytes) from 190000, copies each whose word 0 has bit 15
set, packs them to the front, and zeroes word 0 of the rest (`object_dma`;
MAME's `m_zmask` is 0xFFFF for Moo, so any active entry is copied). The IRQ5
handler turns the DMA bit off again; the IRQ4 handler turns it on after
writing the global offsets.

**Entry** (`k053247_sprites_draw_common`, `draw_single_sprite_gxcore`):
w0: bit 15 active, 14 keep aspect (zoom y used for x), 13 flip y, 12 flip x,
11-8 size (w = 1 << bits 8-9, h = 1 << bits 10-11 cells), 7-0 zcode;
w1 code; w2 y (10 bits); w3 x (10 bits); w4 zoom y, w5 zoom x (10 bits, 0x40
= 1:1); w6: 15 mirror y, 14 mirror x, 11-10 shadow, 9-0 colour/priority.

**Order.** Active sprites (bit 15), optionally minus a rejected zcode (MAME:
none, -1), sorted so the largest zcode is first; then drawn from the **last**
(smallest zcode, closest) to the first. Each pixel drawn marks the priority
bitmap 31, which **blocks every later sprite** there, even where the pixel
itself was hidden by a layer. So: per pixel, the nearest opaque sprite pixel
owns it; that owner is then shown or hidden against the layers by its own
priority mask. (K053247 OPSET reg 0x0C bit 4 would reverse the sort; the
game never writes K053247 registers.)

**Colour and priority** (`sprite_callback`): pri = (w6 & 0x3E0) >> 4;
mask = 0 if pri <= layerpri[2] (in front of all), 0xF0 if <= layerpri[1]
(behind the front sorted layer), 0xF0|0xCC if <= layerpri[0], else
0xF0|0xCC|0xAA (behind all three sorted layers). Palette = sprite_colorbase
(K053251 CI0 base) | (w6 & 0x1F), 16-colour units. A pixel is drawn when
`(mask >> tag) & 1 == 0`, tag being the priority value of the layer beneath.

**Shadow.** If (w6 >> 10) & 3 is non-zero, pen 15 of that sprite is a shadow:
it darkens what is below with shadow preset ((w6>>10&3) - 1), provided the
mask passes and the pixel has not already been shadowed (priority bit 7);
it does not claim the pixel (no 31). Pen 0 is transparent.

**Geometry.** 4 bpp 16 x 16 cells, 128 bytes each, from the 8 MB ROM
(151a10/a11/a12/a13 interleaved 16 bits each, `ROM_LOAD64_WORD`). Cell layout
(`spritelayout`): 8 bytes per row; pixel x at nibble offset
`{2,3,0,1,6,7,4,5,10,11,8,9,14,15,12,13}[x]`. Multi-cell sprites step the code by
`xoffset {0,1,4,5,16,17,20,21}` and `yoffset {0,2,8,10,32,34,40,42}`, with
the low six code bits giving the starting cell. Position is the sprite's centre;
`ox = (x - offx) & 0x3FF`, `oy = (-y - offy) & 0x3FF`, wrapped at 1024-384 and
1024-512, then `ox += -48+1`, `oy -= 23` (`set_config(NORMAL_PLANE_ORDER,
-48+1, 23)`), then shifted left/up by half the zoomed size. Zoom: `zoom =
(0x400000 + z/2) / z`, cell n at `o + ((zoom*n + 0x800) >> 12)`. The K053246
offsets offx/offy are regs 0-1 and 2-3 (measured 0x00E0 and 0x01E1).
Mirror and flip rules are in `k053247_draw_yxloop_gx`. Every one of these
details is to be pinned by the reference renderer, not by reading.

### 7.5 K054338 as programmed

BG colour 0 (black). All nine shadow registers 0x1C0 = -64 (9-bit signed):
every shadow preset subtracts 64 from R, G and B, clipped at 0 (CONTROL.CLIPSL
clear). CONTROL = 0x01 in ordinary play: video on, MIXPRI/SHDPRI/BRTPRI off,
PBLEND 0.  (An early probe said the game never sets MIXPRI; it does, in the
intro and for the final boss's fog -- §7.3.)
Registers 0x16/0x18 (brightness) were written 0x00FF/0xFFFF once.

MAME's shadow on a 32-bit bitmap is lossy: `shadow_table[rgb15]` — the
colour is truncated to 5 bits a channel, re-expanded (`pal5bit`), then the
delta added and clipped. The reference renderer reproduces that exactly; the
core may do the same (it is cheaper) or keep 8 bits (it is what the board
does); decide in `docs/core-design.md` and say which the gate compares.

### 7.6 K053251 as programmed (written once at boot)

Priorities: CI0 0x00, CI1 0x3F, CI2 0x18, CI3 0x24, CI4 0x30.
Palette bases: reg 9 = 0x0E → CI0 = 2*32 = **64** (sprites), CI1 = 96,
CI2 = 0 (layer B); reg 10 = 0x1A → CI3 = 2*16 = **32** (layer C),
CI4 = 3*16 = **48** (layer D). Layer A fixed at **0x70**.

In palette entries (x16): layer B 0-255, layer C 512-767, layer D 768-1023,
sprites 1024-1535, layer A 1792-2047.

### 7.7 Palette

2048 entries x 32 bits at 1C0000, `xRGB_888`: word 0 low byte = R, word 1 =
G (high byte), B (low byte). No alpha, no PROMs.

## 8. ROMs

| file | CRC32 | size | region | layout |
|---|---|---|---|---|
| 151b01.q5 | fb2fa298 | 256 KB | maincpu 000000 | even bytes |
| 151eab02.q6 | 37b30c01 | 256 KB | maincpu 000001 | odd bytes |
| 151a03.t5 | c896d3ea | 256 KB | maincpu 100000 | even bytes |
| 151a04.t6 | 3b24706a | 256 KB | maincpu 100001 | odd bytes |
| 151a07.f5 | cde247fc | 256 KB | soundcpu | linear |
| 151a05.t8 | bc616249 | 1 MB | k056832 +0 | 16-bit words, 32-bit stride |
| 151a06.t10 | 38dbcac1 | 1 MB | k056832 +2 | 16-bit words, 32-bit stride |
| 151a10.b8 | 376c64f1 | 2 MB | k053246 +0 | 16-bit words, 64-bit stride |
| 151a11.a8 | e7f49225 | 2 MB | k053246 +2 | 16-bit words, 64-bit stride |
| 151a12.b10 | 4978555f | 2 MB | k053246 +4 | 16-bit words, 64-bit stride |
| 151a13.a10 | 4771f525 | 2 MB | k053246 +6 | 16-bit words, 64-bit stride |
| 151a08.b6 | 962251d7 | 2 MB | k054539 | linear |
| moomesa.nv | 7bd904a8 | 128 B | eeprom | default EEPROM contents |

13.25 MB in all: SDRAM, no question (METHODOLOGY section 6).

## 9. What the program actually uses

- Tilemaps: four single-page layers, plain x/y scroll, no line/row scroll, no
  flip, no tile banking, no 5-8 bpp. Only four VRAM pages. Tile-ROM readback
  window: no reads seen outside the boot test.
- Sprites: DMA every frame; zoom, shadows (measure how often in step 4);
  K053247 registers never written; flip screen never set.
- K053251 and K054338: written once, static. Alpha blending never enabled.
- K053990 protection: two zero-length triggers at boot, nothing else in 90 s.
- K054539: all three sample types, loop, reverb, pan; no timer, no DJ Main
  0x81-0x8F pan quirk other than the pans themselves being in that range.
- CONTROL2 bit 8 (sprite-ROM readback): boot test only.

What the core does not build must be written into `docs/core-design.md` with
the reason; nothing above is dropped yet.

## 10. Open questions

- Line on which the frame interrupt (CCU INT1) fires, and how long the object
  DMA takes on the board (sets when IRQ5 arrives). MAME's 100 µs is a
  scheduling convenience. Proposed: INT1 at the first line of vblank, DMA
  length as jotego's `jt053246_dma` models it; the game only needs DMA to end
  before it next writes the K053246 offsets.
- CONTROL2 bit 3 and IN1 bit 2: unknown, not modelled.
- The MAME note "enemies coming out of the jail cells in the last stage have
  wrong priority" — reachable only deep into the game; out of the capture set
  for now.
- Whether the K054338's shadow on the board keeps 8 bits a channel (MAME
  truncates to 5); only a photograph of a shadow on real hardware could say.
