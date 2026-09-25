#!/usr/bin/env python3
"""Check the moomesa.rom image the .mra builds against MAME's own loaded regions.

MAME is the oracle for the ROM path too: tools/dump_regions.lua writes out the
bytes MAME hands each chip (region by region, as MAME's Lua reads them), and
this compares them with the matching slice of the image.

    REGION_DIR=regions tools/mame.sh -seconds_to_run 1 -autoboot_script tools/dump_regions.lua
    tools/verify_rom.py moomesa.rom regions

The layout (moomesa.mra, target/pocket/moomesa_mem.sv, sim/tb_mem.cpp):
every region is MAME's region verbatim, except the 68000's, whose 512 KB hole
at 080000-0FFFFF is dropped so that data ROM (CPU 100000) follows program ROM.
"""
import sys

REGIONS = [  # name, image offset, length, MAME region file, offset in that file
    ('sprite ROM (K053246)',  0x000000, 0x800000, 'k053246',  0),
    ('tile ROM (K056832)',    0x800000, 0x200000, 'k056832',  0),
    ('PCM samples (K054539)', 0xA00000, 0x200000, 'k054539',  0),
    ('68000 program',         0xC00000, 0x080000, 'maincpu',  0x000000),
    ('68000 data',            0xC80000, 0x080000, 'maincpu',  0x100000),
    ('Z80 program',           0xD00000, 0x040000, 'soundcpu', 0),
    ('default EEPROM',        0xD40000, 0x000080, 'eeprom',   0),
]
IMAGE_LEN = 0xD40080


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    image = open(sys.argv[1], 'rb').read()
    d = sys.argv[2].rstrip('/')
    ok = True
    if len(image) != IMAGE_LEN:
        print(f'FAIL: image is {len(image)} bytes, expected {IMAGE_LEN}')
        ok = False
    for name, at, n, reg, roff in REGIONS:
        src = open(f'{d}/{reg}.bin', 'rb').read()[roff:roff + n]
        img = image[at:at + n]
        if len(src) != n:
            print(f'FAIL: {name}: MAME region {reg} has only {len(src)} bytes from 0x{roff:x}')
            ok = False
        elif img != src:
            i = next(k for k in range(n) if k >= len(img) or img[k] != src[k])
            print(f'FAIL: {name}: differs at image 0x{at + i:06x}: '
                  f'image {img[i:i+8].hex()} MAME {src[i:i+8].hex()}')
            ok = False
        else:
            print(f'  {name:24s} 0x{at:06x} {n:8d} bytes  identical to MAME')
    # the hole the image drops must be empty in MAME, or something is lost
    hole = open(f'{d}/maincpu.bin', 'rb').read()[0x080000:0x100000]
    if any(hole):
        print('FAIL: MAME has data in the maincpu hole 080000-0FFFFF the image drops')
        ok = False
    print('OK: the image carries exactly the bytes MAME loads' if ok else 'FAILED')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
