#!/usr/bin/env python3
"""The reference renderer's gate: render every frozen state and diff each
against the picture MAME drew for it.

    tools/check_render.py moomesa.rom [state files or dirs ...] [-o artifacts/model]

With no states named, every sim/states/*/state_*.bin[.gz] is checked.  Prints
one line per state and exits non-zero unless every one has zero differing
pixels.  With -o, writes the renderer's picture and a diff image (differing
pixels red over a darkened MAME frame) for each state that differs, and a
contact sheet of MAME's frames for the whole set, so a person can see what
the set covers.
"""
import glob, os, sys
from multiprocessing import Pool
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import moo_state, moo_render, pngio

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
ROM = None


def _init(rom_path):
    global ROM
    ROM = open(rom_path, 'rb').read()


def _png(path, w, h, px):
    rgb = bytearray()
    for v in px:
        rgb += bytes(((v >> 16) & 255, (v >> 8) & 255, v & 255))
    pngio.write(path, w, h, rgb)


def check(args):
    path, outdir = args
    st = moo_state.load(path)
    try:
        out = moo_render.render(st, ROM)
    except NotImplementedError as e:
        return path, -1, str(e)
    bad = sum(1 for a, b in zip(out, st.pixels) if a != b)
    if outdir and bad:
        name = os.path.basename(os.path.dirname(path)) + '_' + os.path.basename(path).split('.')[0]
        _png(os.path.join(outdir, name + '_model.png'), st.width, st.height, out)
        _png(os.path.join(outdir, name + '_diff.png'), st.width, st.height,
             [0xff0000 if a != b else ((b >> 2) & 0x3f3f3f) for a, b in zip(out, st.pixels)])
    return path, bad, ''


def sheet(paths, out):
    W, H, cols = 384, 224, 4
    rows = (len(paths) + cols - 1) // cols
    img = bytearray(W * cols * H * rows * 3)
    for k, p in enumerate(paths):
        st = moo_state.load(p)
        cx, cy = (k % cols) * W, (k // cols) * H
        for y in range(H):
            o = ((cy + y) * W * cols + cx) * 3
            row = bytearray()
            for v in st.pixels[y * W:(y + 1) * W]:
                row += bytes(((v >> 16) & 255, (v >> 8) & 255, v & 255))
            img[o:o + W * 3] = row
    pngio.write(out, W * cols, H * rows, img)


def main():
    args = sys.argv[1:]
    outdir = None
    if '-o' in args:
        k = args.index('-o'); outdir = args[k + 1]; del args[k:k + 2]
        os.makedirs(outdir, exist_ok=True)
    if not args:
        sys.exit(__doc__)
    rom, targets = args[0], args[1:] or [os.path.join(ROOT, 'sim', 'states')]
    paths = []
    for t in targets:
        if os.path.isdir(t):
            paths += sorted(glob.glob(os.path.join(t, '**', 'state_*.bin*'), recursive=True))
        else:
            paths.append(t)
    with Pool(initializer=_init, initargs=(rom,)) as pool:
        results = pool.map(check, [(p, outdir) for p in paths])
    fails = 0
    for p, bad, why in results:
        rel = os.path.relpath(p, ROOT)
        if bad < 0:
            print(f'  {rel}: NOT MODELLED: {why}'); fails += 1
        else:
            print(f'  {rel}: {bad} pixels differ'); fails += bad > 0
    if outdir:
        sheet(paths, os.path.join(outdir, 'mame_sheet.png'))
    print(f'{len(paths)} states, {len(paths) - fails} pixel-identical to MAME')
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
