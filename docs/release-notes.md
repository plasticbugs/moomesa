Wild West C.O.W.-Boys of Moo Mesa (Konami, 1992) for the Analogue Pocket.

The whole board is in the gateware: the 68000, the Z80, the YM2151 and the
K054539 in stereo, the Konami tilemap, sprite and mixer chips, and the
protection DMA. The video is checked pixel for pixel against MAME.

**ROMs are not included.** Build the image from your own MAME `moomesa`
romset (ver EAB) with the files in this zip:

    python3 mra_build.py moomesa.mra moomesa.zip moomesa.rom

and copy `moomesa.rom` to `Assets/moomesa/common/` on the SD card. The image's
md5 is `0ebb990422cb6b7c9c067b11450fd638`. Then unzip this package onto the
card's root.

## New in 0.3.0: Analogizer support

The core now works with RndMnkIII's
[Analogizer](https://github.com/RndMnkIII/Analogizer) adapter: the board's own
15 kHz picture on a CRT, and native controllers through SNAC. Tested on a
Pocket with an Analogizer and a CRT.

- **Video out of the adapter's VGA port**: RGBS, RGsB, YPbPr, Y/C (NTSC or
  PAL), or scandoubled for a VGA monitor (plain, 25/50/75% scanlines, HQ2x).
  The signal is the board's: 384x224 visible, 15.625 kHz, 59.19 Hz.
- **Set up from the core's own menu**, like RndMnkIII's own cores: no
  `analogizer.bin` file needed. **Analogizer** (Off, On, or "On, Pocket off"
  to send the picture to the CRT only), **Analogizer Video**, **SNAC
  Adapter** and **SNAC Assignment**. Off by default, and with it off the
  core is exactly as before.
- **Analogizer H Position / V Position** move the picture on the CRT
  (up to 24 pixels left or right, 16 lines up or down) for a set whose
  picture sits off centre. They move the sync, not the picture, so nothing
  is cropped.
- **SNAC controllers**: DB15, NES, SNES, PC Engine (2- and 6-button,
  multitap), PlayStation (digital and analog). Moo Mesa is a four-player
  board: with a PC Engine multitap, "SNAC P1-P4" gives all four players
  pads. SNAC has not been tried with this core yet.

**With this core the Pocket powers the cartridge slot.** Take any game
cartridge out first. Set the adapter up as its
[How to use it](https://github.com/RndMnkIII/Analogizer/wiki/How-to-use-it%3F)
page says (SNAC switch on A, 5 V into its USB-C port, the audio cable into
the Pocket's headphone socket).

---

## New in 0.2.0

- **The final boss's fog now fades away and stays gone.** MAME, and this
  core until now, faded it and then drew it solid again for the whole fight.
  The game marks which tiles blend in each tile's colour; the core now reads
  that mark, as the arcade board does.
- **The intro's meteor lands on visible ground**, which the same fix
  restores.

## Controls

| Pocket | game |
|---|---|
| D-pad | move |
| B or X | shoot |
| A or Y | jump |
| Select | coin |
| Start | start |

Players 3 and 4 use a docked Pocket's third and fourth controllers (untested).

The core menu has the board's DIP switches, screen shape, scanlines, shadow
mask, and the service switch for the game's own settings menu. Those settings
are saved to the SD card.

If you tried an earlier build, delete `Settings/plasticbugs.moomesa/` on the
card: a button mapping the Pocket saved from it overrides this build's
defaults.

## Tested on hardware

Boot and RAM/ROM check, attract mode and the intro, every stage through the
final boss (its fog), sprite shadows (compared with arcade footage), and
settings kept across launches.

## Known limits

- Flip screen is not supported. If it is set in the service menu, the
  backgrounds disappear; set it back to off.
- Only the map screens and the final boss of the later stages are in the
  frame-by-frame comparison with MAME so far.

## Credits

MAME's `moo.cpp` (R. Belmont, Acho A. Tang, after Olivier Galibert) and its
Konami device models; fx68k (Jorge Cwik); tv80 (Guy Hutchison); jt51 and
jt5911 (Jose Tejada); the Pocket platform and build (Marcus Andrade,
OpenGateware). The full list is in `CREDITS.md`.
