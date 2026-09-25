# The core on the Pocket

How the board in `docs/hardware.md` maps onto the Pocket, and the budgets that
mapping has to meet. Decided on paper first (METHODOLOGY 5.2); the measured
columns are filled in as the benches exist.

## 1. Clocks

System clock 96.000 MHz (`clk_sys`). Every board clock but the K054539's is an
exact divider of it (`rtl/clk_enables.sv`):

| enable | ratio | frequency | board | error |
|---|---|---|---|---|
| 68000 phases (fx68k) | 96/6, two phases | 16.000 MHz | 16 MHz | 0 |
| Z80 | 96/12 | 8.000 MHz | 8 MHz | 0 |
| YM2151 | 96/24 | 4.000 MHz | 4 MHz | 0 |
| dot | 96/12, pinned to `clk_vid` | 8.000 MHz | 8 MHz | 0 |
| K054539 | 96 x 24/125 (fractional) | 18.432 MHz average | 18.432 MHz | 0 on average |

`clk_vid` is 8.000 MHz from the core PLL (was 6.857 in the template), with its
90-degree twin at 31 250 ps. Raster 512 x 264, 384 x 224 visible:
**59.185 Hz**, the board's rate (docs/hardware.md 1). The Pocket accepts it; the
CCU registers the game writes are stored but the raster is fixed to the
values it always writes (hardware.md 7.1), so the picture is stable from
power-on, before the game has programmed anything.

## 2. Where each memory lives

Every RAM on the board is block RAM; the SDRAM holds the ROM image only; the
SRAM is used for nothing but its power-on self-test.

| memory | size | resource | access |
|---|---|---|---|
| 68000 work RAM | 64 KB | BRAM, 32K x 16, byte enables | 68000 only |
| sprite RAM (CPU view) | 64 KB | BRAM, 32K x 16 | 68000; object DMA in vblank (second port) |
| K053247 sprite list | 256 x 8 words | BRAM | DMA writes; sort and line engine read |
| tile RAM | 4 pages x 2048 tiles x 32 bits | BRAM, 8K x 32 | 68000 (one page window) / tile engine |
| palette | 2048 x 24 bits | BRAM, true dual port | 68000 / mixer |
| line buffers | tiles 4 x 2 x 512, sprites 2 x 512 | BRAM | engines write line N+1, mixer reads N |
| Z80 RAM | 8 KB | BRAM | Z80 |
| K054539 reverb RAM | 16 KB | BRAM | K054539 |
| EEPROM | 128 B | BRAM | serial EEPROM model; save slot |
| ROM image | 13.25 MB | SDRAM | `moomesa_mem.sv`, section 4 |

Tile RAM: MAME allocates 16 pages of 4096 words; the board has three 8 KB
chips, i.e. 8192 entries of 24 bits = four pages, and the game uses only pages
0, 1, 4 and 5 (measured). The core stores four physical pages, selected by
page-row bit 0 and page-column bit 0, so pages 0/1/4/5 are distinct and every
other page aliases one of them, as the board's address decode would. Entries
keep 32 bits (MAME keeps the attribute word's high byte, which the board
cannot; a CPU read of it matches MAME rather than the board).

M10K estimate: work 64 + sprite 64 + tile 32 + palette 6 + list 4 + line
buffers ~10 + Z80 8 + reverb 16 + 68000 cache 5 + fx68k ~6 + EEPROM 1 = ~216
of 308.

## 3. The ROM image

`moomesa.mra` (byte offsets; SDRAM word address = offset / 2):

| offset | size | region |
|---|---|---|
| 0x000000 | 8 MB | sprites, 64-bit rows (151a10/11/12/13) |
| 0x800000 | 2 MB | tiles, 32-bit rows (151a05/06) |
| 0xA00000 | 2 MB | K054539 samples |
| 0xC00000 | 1 MB | 68000: program (CPU 000000) then data (CPU 100000) |
| 0xD00000 | 256 KB | Z80 |
| 0xD40000 | 128 B | default EEPROM |

Same constants in `target/pocket/moomesa_mem.sv`, `sim/tb_mem.cpp`,
`tools/verify_rom.py`.

## 4. SDRAM clients and the arbiter

`moomesa_mem.sv`. Random single-word clients, round robin: the download
(cannot stall; 64-word FIFO), the Z80, the K054539. The burst port, owner
latched at grant, priority 68000 cache line (4 words) > tile row (2 words) >
sprite row (4 words). Each port counts a request once (`served` flag) so a
held `req` after its `ack` is never a second request.

## 5. Budgets

A line is 512 dots x 12 = **6144 system clocks**. The tile and sprite engines
build line N+1 while line N is shown; both must finish inside 6144.

| stage | budget | estimate | ideal-memory bench | real-memory bench | hardware |
|---|---|---|---|---|---|
| tile fetch, 4 layers x 49 rows x ~14 clocks | 6144 | ~2750 | | | |
| sprite cells, measured worst 65 sprites | 6144 | ~1500 (100 cell rows) | | | |
| 68000 cache misses | shares the above | | | | |
| vblank: DMA + sort (256 entries, O(n^2)) | 40 lines = 245 760 | ~100 000 | | | |

Every engine with a deadline latches a "missed" flag for the bring-up panel
and a worst-case count that saturates (METHODOLOGY 5.19).

## 6. Video, as built

The mixer reproduces MAME's composition per pixel rather than drawing layer
by layer (docs/hardware.md 7.3, `tools/moo_render.py`):

1. Background colour.
2. The three sorted layers B/C/D; the priority tag of a pixel is the OR of
   1, 2, 4 for each opaque one (the back one only if its priority is below
   CI1's). The front one is alpha-blended when K054338 MIXPRI is set.
3. Sprites: the sprite engine draws nearest first into a line buffer where
   the first opaque pen claims the pixel whether or not it will show, and a
   shadow pen marks the pixel only while it is unclaimed and unshadowed. The
   mixer shows the claiming sprite if its priority class allows the pixel's
   tag, else applies the recorded shadow if its class allows the tag.
4. Layer A on top.

The sprite sort is MAME's exchange sort, done literally in vblank: tie order
between equal z-codes is part of what the pictures depend on.

## 7. What is not cycle-exact, and why that is acceptable

- IRQ order follows the ROM (IRQ4 at vblank, IRQ5 at DMA end), not MAME.
- The frame is rendered a line at a time; MAME renders it all at vblank end.
  A register the CPU changes during the visible frame takes effect on the next
  line here and on the next frame in MAME. The game writes its video
  registers in the IRQ4 handler, in vblank.
- Shadows follow MAME's lossy 5-bit table, not the board's (unknown).
