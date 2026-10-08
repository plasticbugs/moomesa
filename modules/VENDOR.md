# Vendored modules

Third-party HDL cores copied into the tree — no submodules, so the build is
self-contained and reproducible. Each keeps its own LICENSE alongside.
`tools/vendor.sh <name>` fetches one from its upstream at a pinned commit,
with its licence; run it with no arguments to see what it knows about, or give
it a url and ref for anything else. `tools/gen_qip.sh` then lists everything
under `modules/` for Quartus.

| module | what it is | upstream | commit | licence |
|---|---|---|---|---|
| cpu-fx68k | 68000, cycle-accurate (Jorge Cwik) | https://github.com/ijor/fx68k | 0602ee4627b10f301298f2673d826cdd6baa9327 | GPL-3.0 |
| cpu-tv80 | Z80 core (Guy Hutchison); `rtl/core` only, less `tv80n.v` and the SD-card helpers | https://github.com/hutch31/tv80 | 66a131c38d05ef58b3d8c4f1507a72e6e4aa5d65 | MIT |
| sound-jt51 | YM2151 (Jose Tejada) | https://github.com/jotego/jt51 | 985a573dcfc1ff135553a39f7eae21d18ba57cbe | GPL-3.0 |
| eeprom-jteeprom | `jt5911`, ER5911 serial EEPROM (Jose Tejada); the 93C46 models removed | https://github.com/jotego/jteeprom | 9c68ce841f4ec560ca6f228c8af6301129fd95fa | GPL-3.0 |
| `target/pocket/analogizer/` | RndMnkIII's Analogizer adapter module (`openFPGA_Pocket_Analogizer` 1.4) and the 14 files it instantiates, verbatim; `analogizer.qip` is ours | https://github.com/RndMnkIII/MiraxPocket, `src/fpga/analogizer/` | 9dfdd2b9bec79fe5ea10e154a0613a0c9d4fe37f | GPL-3.0-or-later (the host core's); `hq2x.sv`, `scandoubler_2.v`, `yc_out_legacy.sv` carry their own GPL headers |

The Analogizer module lives under `target/pocket/` rather than `modules/`
because it is the Pocket's cartridge port, not the machine, and so that
`tools/gen_qip.sh` and the per-module lint do not sweep it in: `core.qip`
includes its own `analogizer.qip`, and `sim/lint.sh` lints it behind
`target/pocket/pocket_analogizer.sv` with a stand-in for its one VHDL file
(`sim/ps2_keyboard_stub.v`).  The copy is from MiraxPocket, RndMnkIII's
newest arcade core (2026-09); his main Analogizer repository's
`analogizer/` folder is the older 1.2 and has no settings-file support.
Left out: `scandoubler.v`, `scanlines.v`, `yc_out.sv`, `psPAD_top.v`,
`psx_control.v`, `csync.v`, `sync_fix.v` (also defined inside the top file),
`two_button_press_detector.v`, `uart_tx.v` and `sine_lut.mem` -- nothing
instantiates them.  In this copy the SNAC module declares PS/2 mouse outputs
that it does not yet drive; the wrapper leaves them unconnected.

fx68k reads `microrom.mem` and `nanorom.mem` from the working directory; the
simulation scripts link them into `sim/`.  tv80's `tv80s` wrapper ties the
core's clock enable high, so the core is used through `rtl/z80_cen.sv`, which
is tv80s with the enable brought out.  The template's `cpu-tv80` URL
(hoglet67/tv80) no longer exists; hutch31/tv80 is the original.

For each module record what it is, its upstream repository and the exact
commit, its licence, and anything it needs that is not obvious — jt12's
`hdl/` has to be taken whole, for instance, because `jt12_top` instantiates
its ADPCM files outside a generate guard, so they must exist even when ADPCM
is disabled.

Written here rather than vendored: list the custom chips reimplemented from
MAME's device models, and where their behaviour is documented.

| module | chip | written from | checked by |
|---|---|---|---|
| `rtl/moo_tiles.sv` | K054156/K054157 tilemaps | MAME `k054156_k054157_k056832.cpp` | `sim/run_video.sh`, 47 frozen states |
| `rtl/moo_sprites.sv` | K053246/K053247 sprites, DMA | MAME `k053246_k053247_k055673.*`, `moo.cpp` object_dma | same |
| `rtl/moo_mixer.sv` | K053251 priority, K054338 mixer, palette | MAME `k053251.cpp`, `k054338.cpp`, `moo.cpp` screen_update, `drawgfxt.ipp` | same |
| `rtl/k054539.sv` | K054539 PCM | MAME `k054539.cpp` | `sim/check_k539.sh` against MAME's own code (`sim/k539_ref.cpp`) |

Not used, and why: jotego's `jtcores` has an incomplete Moo Mesa core (2026-09)
whose chip modules were read for reference.  Its tilemap module `jt05415x` is
unproven (added with that core); its `jt539` (K054539) is not public.
furrtek's silicon-derived K054539 (`github.com/furrtek/SiliconRE`,
`Konami/054539/hdl`, GPL-2.0) is a pin-level model that expects sample ROM on
the chip's own fixed schedule; MAME's behaviour, the oracle here, was a
smaller port.

To update one: re-copy from upstream at the new commit and record it here.
