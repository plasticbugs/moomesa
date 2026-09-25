#!/usr/bin/env python3
"""Reference renderer for Moo Mesa's video hardware: the executable spec.

Reads a frozen state from tools/dump_state.lua and the ROM image built from
moomesa.mra, and draws the frame MAME draws, following moo.cpp's
screen_update and MAME's device and core drawing code step for step
(docs/hardware.md section 7).  The goal is zero differing pixels against the
picture MAME stored in the same state file.

    tools/moo_render.py moomesa.rom state_00900.bin [out.png] [-diff diff.png]

Everything is done in MAME's 512 x 256 bitmap coordinates; the visible window
is x 40..423, y 16..239 (moo.cpp set_visarea).  Pure Python, no numpy.

The model also exposes the intermediate results the RTL is compared against
(render(..., want_index=True)): per pixel, the 11-bit palette index that
reached the screen and whether it was shadowed -- the RTL outputs indices,
so the frozen-state gate compares those, not only RGB.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import moo_state, pngio

BW, BH = 512, 256
CX0, CX1, CY0, CY1 = 40, 423, 16, 239          # cliprect, inclusive

TILE_BASE = 0x800000                             # image offsets (moomesa.mra)
SPR_BASE = 0x000000

# charlayout4 / spritelayout x offsets, in nibbles from the start of the row:
# pixel x reads nibble NIB[x] (MAME numbers bits from the MSB of byte 0, and
# plane 0 is the pixel's most significant bit, so a nibble is read high first)
TNIB = [2, 3, 0, 1, 6, 7, 4, 5]
SNIB = [2, 3, 0, 1, 6, 7, 4, 5, 10, 11, 8, 9, 14, 15, 12, 13]


def nib(rom, base, n):
    b = rom[base + (n >> 1)]
    return (b >> 4) if (n & 1) == 0 else (b & 15)


def tile_row(rom, code, py):
    base = TILE_BASE + (code & 0xffff) * 32 + py * 4
    return [nib(rom, base, TNIB[x]) for x in range(8)]


def sprite_cell(rom, code):
    """16 x 16 pens of one sprite cell, row-major."""
    base = SPR_BASE + (code & 0xffff) * 128
    out = []
    for y in range(16):
        rb = base + y * 8
        out.extend(nib(rom, rb, SNIB[x]) for x in range(16))
    return out


def alpha_blend(d, s, level):
    """MAME alpha_blend_r32(d, s, level)."""
    return ((((s & 0x0000ff) * level + (d & 0x0000ff) * (256 - level)) >> 8) |
            ((((s & 0x00ff00) * level + (d & 0x00ff00) * (256 - level)) >> 8) & 0x00ff00) |
            ((((s & 0xff0000) * level + (d & 0xff0000) * (256 - level)) >> 8) & 0xff0000))


def pal5bit(v):
    return (v << 3) | (v >> 2)


def clamp8(v):
    return 0 if v < 0 else 255 if v > 255 else v


class Frame:
    def __init__(self, bg):
        self.rgb = [bg] * (BW * BH)
        self.pri = [0] * (BW * BH)
        self.idx = [-1] * (BW * BH)      # palette index that set the pixel, -1 = background;
                                         # (under, index, alpha) where a layer was blended
        self.shd = [0] * (BW * BH)       # number of shadows applied over it


def shadow_rgb(rgb, delta, noclip):
    r = pal5bit((rgb >> 19) & 31) + delta[0]
    g = pal5bit((rgb >> 11) & 31) + delta[1]
    b = pal5bit((rgb >> 3) & 31) + delta[2]
    if noclip:
        r, g, b = r & 255, g & 255, b & 255
    else:
        r, g, b = clamp8(r), clamp8(g), clamp8(b)
    return (r << 16) | (g << 8) | b


def render(st, rom, want_index=False):
    regs = st.k832
    pens = moo_state.palette_rgb(st)

    # -------- K054338: shadows and background (update_all_shadows, fill_solid_bg)
    k338 = st.k338
    noclip = bool(k338[15] & 0x20)
    shd = []
    for i in range(9):
        d = k338[2 + i] & 0x1ff
        if d >= 0x100:
            d -= 0x200
        shd.append(max(-255, min(255, d)))
    shadow_tables = [shd[0:3], shd[3:6], shd[6:9]]
    bg = ((k338[0] & 0xff) << 16) | k338[1]
    fr = Frame(bg)

    # -------- K053251 (moo screen_update)
    k251 = st.k251
    ci_base = [32 * (k251[9] & 3), 32 * ((k251[9] >> 2) & 3), 32 * ((k251[9] >> 4) & 3),
               16 * (k251[10] & 7), 16 * ((k251[10] >> 3) & 7)]
    sprite_colorbase = ci_base[0]
    layer_colorbase = [0x70, ci_base[2], ci_base[3], ci_base[4]]
    layer = [1, 2, 3]
    layerpri = [k251[2], k251[3], k251[4]]
    # konami_sortlayers3: compare-and-swap (0,1), (0,2), (1,2), swapping when less
    for a, b in ((0, 1), (0, 2), (1, 2)):
        if layerpri[a] < layerpri[b]:
            layerpri[a], layerpri[b] = layerpri[b], layerpri[a]
            layer[a], layer[b] = layer[b], layer[a]

    # -------- K056832 configuration this model supports (docs/hardware.md 7.2)
    if regs[0] & 0x30:
        raise NotImplementedError('K056832 screen flip')
    fbits = (regs[3] >> 6) & 3
    FLIPS, PALM1, PALS2, PALM2 = [(6, 0x3f, 0, 0x00), (4, 0x0f, 2, 0x30),
                                  (2, 0x03, 2, 0x3c), (0, 0x00, 2, 0x3f)][fbits]
    layer_offs = [-2 + 1, 2 + 1, 4 + 1, 6 + 1]   # VIDEO_START(moo) set_layer_offs
    lx = [(regs[12 + L] >> 3) & 3 for L in range(4)]
    ly = [(regs[8 + L] >> 3) & 3 for L in range(4)]
    lw = [regs[12 + L] & 3 for L in range(4)]
    lh = [regs[8 + L] & 3 for L in range(4)]
    # layer association: the later layer wins a shared page
    assoc = [-1] * 16
    for L in range(4):
        for r in range(lh[L] + 1):
            for c in range(lw[L] + 1):
                assoc[(((ly[L] + r) & 3) << 2) + ((lx[L] + c) & 3)] = L

    def draw_layer(L, prio_code, alpha=255):
        if lw[L] or lh[L]:
            raise NotImplementedError('K056832 multi-page layer')
        page = (ly[L] << 2) + lx[L]
        if assoc[page] != L:
            return
        scrollmode = (regs[5] >> (L << 1)) & 3     # lsram_page[L][0] = L
        if scrollmode == 1:
            raise NotImplementedError('K056832 scroll mode 1')
        # tilemap_draw_common, rowspan = colspan = 1, no flip.  Scroll x for
        # screen line y: mode 3 the register; mode 0 the table entry of the
        # source line (y + dy); mode 2 the entry of the first line of its
        # 8-line group.  Table: page scrollbank, + L * 0x400 words, two words
        # an entry, the second the value; only its low 9 bits survive the
        # tilemap's wrap at 512.
        scrollbank = ((regs[0x18] >> 1) & 0xc) | (regs[0x18] & 3)
        table = (scrollbank << 12) + (L << 10)
        dy = regs[0x10 + L]
        if dy & 0x8000:
            dy -= 0x10000
        ay = dy & 0xff
        flipmask = (regs[1] >> (L << 1)) & 3
        base = page << 12
        for y in range(CY0, CY1 + 1):
            if scrollmode == 3:
                sx0 = regs[0x14 + L] & 0xffff
            else:
                e = (dy + y) if scrollmode == 0 else ((dy + y) & ~7)
                sx0 = st.vram[table + ((e * 2) & 0x3ff) + 1]
            dx = sx0 - layer_offs[L]
            sy = (y + ay) & 0xff
            row, py = sy >> 3, sy & 7
            cache = {}
            for x in range(CX0, CX1 + 1):
                sx = (x + dx) & 0x1ff
                col = sx >> 3
                t = cache.get(col)
                if t is None:
                    ti = row * 64 + col
                    attr = st.vram[base + ti * 2]
                    code = st.vram[base + ti * 2 + 1]
                    flip = flipmask & ((attr >> FLIPS) & 3)
                    color = (attr & PALM1) | ((attr >> PALS2) & PALM2)
                    color = layer_colorbase[L] | ((color >> 2) & 0x0f)      # tile_callback
                    ry = (7 - py) if (flip & 2) else py
                    pix = tile_row(rom, code, ry)
                    if flip & 1:
                        pix = pix[::-1]
                    t = (pix, (color % 128) * 16)
                    cache[col] = t
                pen = t[0][sx & 7]
                if pen == 0:
                    continue
                i = y * BW + x
                pidx = t[1] + pen
                if alpha >= 255:
                    fr.rgb[i] = pens[pidx]
                    fr.idx[i] = pidx
                    fr.shd[i] = 0
                else:                                   # scanline_draw_masked_rgb32_alpha
                    fr.rgb[i] = alpha_blend(fr.rgb[i], pens[pidx], alpha)
                    fr.idx[i] = (fr.idx[i], pidx, alpha)
                fr.pri[i] = (fr.pri[i] & 0xff) | prio_code

    if layerpri[0] < k251[1]:
        draw_layer(layer[0], 1)
    draw_layer(layer[1], 2)
    alpha = 255
    if k338[15] & 0x02:                      # MIXPRI: MAME's stand-in for "alpha on"
        # set_alpha_level(1): PBLEND register 13, shifted by (~1 << 3) & 8 = 0,
        # i.e. its LOW byte; 5 bits expanded to 8; the driver keeps & 0xff
        mixset = k338[13] & 0xff
        mixlv = mixset & 0x1f
        alpha = ((mixlv << 3) | (mixlv >> 2)) & 0xff
    if alpha > 0:
        draw_layer(layer[2], 4, alpha)

    draw_sprites(st, rom, fr, pens, layerpri, sprite_colorbase, shadow_tables, noclip)

    draw_layer(0, 0)

    out = [fr.rgb[y * BW + x] for y in range(CY0, CY1 + 1) for x in range(CX0, CX1 + 1)]
    if want_index:
        idx = [fr.idx[y * BW + x] for y in range(CY0, CY1 + 1) for x in range(CX0, CX1 + 1)]
        sh = [fr.shd[y * BW + x] for y in range(CY0, CY1 + 1) for x in range(CX0, CX1 + 1)]
        return out, idx, sh
    return out


XOFF = [0, 1, 4, 5, 16, 17, 20, 21]
YOFF = [0, 2, 8, 10, 32, 34, 40, 42]


def draw_sprites(st, rom, fr, pens, layerpri, sprite_colorbase, shadow_tables, noclip):
    ram = st.spr_list
    k246 = st.k246
    if st.k247r[0xc // 2] & 0x10:
        raise NotImplementedError('K053247 OPSET PRI (ascending sort)')
    flipscreenx, flipscreeny = k246[5] & 1, k246[5] & 2
    if flipscreenx or flipscreeny or (k246[5] & 8):
        raise NotImplementedError('K053246 flip screen / objset1 bit 3')

    # prebuild the list: every active entry (z rejection -1), then MAME's sort
    lst = [o for o in range(0, 0x800, 8) if ram[o] & 0x8000]
    w = len(lst)
    for y in range(w - 1):
        offs = lst[y]
        z = ram[offs] & 0xff
        for x in range(y + 1, w):
            temp = lst[x]
            code = ram[temp] & 0xff
            if z <= code:
                z = code
                lst[x] = offs
                lst[y] = offs = temp

    cells = {}

    def cell(c):
        v = cells.get(c)
        if v is None:
            v = cells[c] = sprite_cell(rom, c)
        return v

    for offs in reversed(lst):
        code = ram[offs + 1]
        color = ram[offs + 6]
        shadow = color
        # sprite_callback
        pri = (color & 0x03e0) >> 4
        if pri <= layerpri[2]:
            primask = 0
        elif pri <= layerpri[1]:
            primask = 0xf0
        elif pri <= layerpri[0]:
            primask = 0xf0 | 0xcc
        else:
            primask = 0xf0 | 0xcc | 0xaa
        color = sprite_colorbase | (color & 0x001f)

        # k053247_draw_single_sprite_gxcore, non-GX path
        xa = ya = 0
        if code & 0x01: xa += 1
        if code & 0x02: ya += 1
        if code & 0x04: xa += 2
        if code & 0x08: ya += 2
        if code & 0x10: xa += 4
        if code & 0x20: ya += 4
        code &= ~0x3f
        temp4 = ram[offs]
        oy = ram[offs + 2] & 0x3ff
        ox = ram[offs + 3] & 0x3ff
        scaley = zoomy = ram[offs + 4] & 0x3ff
        zoomy = (0x400000 + (zoomy >> 1)) // zoomy if zoomy else 0x800000
        if not (temp4 & 0x4000):
            scalex = zoomx = ram[offs + 5] & 0x3ff
            zoomx = (0x400000 + (zoomx >> 1)) // zoomx if zoomx else 0x800000
        else:
            zoomx, scalex = zoomy, scaley
        nozoom = (scalex == 0x40 and scaley == 0x40)
        flipx = bool(temp4 & 0x1000)
        flipy = bool(temp4 & 0x2000)
        t6 = ram[offs + 6]
        mirrorx = bool(t6 & 0x4000)
        if mirrorx:
            flipx = False
        mirrory = bool(t6 & 0x8000)
        if st.k247r[0xc // 2] & 0x40:
            wrapsize, xwraplim, ywraplim = 512, 512 - 64, 512 - 128
        else:
            wrapsize, xwraplim, ywraplim = 1024, 1024 - 384, 1024 - 512
        offx = (k246[0] << 8) | k246[1]
        offy = (k246[2] << 8) | k246[3]
        if offx & 0x8000: offx -= 0x10000
        if offy & 0x8000: offy -= 0x10000
        m = wrapsize - 1
        ox = (ox - offx) & m
        oy = (-oy - offy) & m
        if ox >= xwraplim: ox -= wrapsize
        if oy >= ywraplim: oy -= wrapsize
        t = (temp4 >> 8) & 0x0f
        width = 1 << (t & 3)
        height = 1 << ((t >> 2) & 3)
        ox += -48 + 1                       # set_config dx
        oy -= 23                            # set_config dy
        ox -= (zoomx * width) >> 13
        oy -= (zoomy * height) >> 13

        sh = (shadow >> 10) & 3             # shdmask 3: all shadows and highlights
        stab = shadow_tables[(sh - 1) & 3] if sh and (sh - 1) < 3 else None
        pen15_shadow = sh != 0

        for y in range(height):
            sy = oy + ((zoomy * y + (1 << 11)) >> 12)
            zh = (oy + ((zoomy * (y + 1) + (1 << 11)) >> 12)) - sy
            for x in range(width):
                sx = ox + ((zoomx * x + (1 << 11)) >> 12)
                zw = (ox + ((zoomx * (x + 1) + (1 << 11)) >> 12)) - sx
                tempcode = code
                if mirrorx:
                    if (not flipx) ^ ((x << 1) < width):
                        tempcode += XOFF[(width - 1 - x + xa) & 7]; fx = True
                    else:
                        tempcode += XOFF[(x + xa) & 7]; fx = False
                else:
                    tempcode += XOFF[((width - 1 - x + xa) if flipx else (x + xa)) & 7]
                    fx = flipx
                if mirrory:
                    if (not flipy) ^ ((y << 1) >= height):
                        tempcode += YOFF[(height - 1 - y + ya) & 7]; fy = True
                    else:
                        tempcode += YOFF[(y + ya) & 7]; fy = False
                else:
                    tempcode += YOFF[((height - 1 - y + ya) if flipy else (y + ya)) & 7]
                    fy = flipy
                blits = [(fx, fy)]
                if mirrory and height == 1:          # "Simpsons shadows": again, y-flipped
                    blits.append((fx, not fy))
                for bfx, bfy in blits:
                    if nozoom:
                        blit(fr, pens, cell(tempcode), color, bfx, bfy, sx, sy, 16, 16,
                             primask, pen15_shadow, stab, noclip)
                    else:
                        blit(fr, pens, cell(tempcode), color, bfx, bfy, sx, sy, zw, zh,
                             primask, pen15_shadow, stab, noclip)


def blit(fr, pens, src, color, flipx, flipy, destx, desty, dstw, dsth,
         primask, pen15_shadow, stab, noclip):
    """drawgfxzoom_core / drawgfx_core with PIXEL_OP_REMAP_TRANSTABLE32_PRIORITY."""
    if dstw < 1 or dsth < 1:
        return
    pmask = primask | (1 << 31)
    dx = (16 << 16) // dstw
    dy = (16 << 16) // dsth
    destendx = destx + dstw - 1
    if destx > CX1 or destendx < CX0:
        return
    srcx = 0
    if destx < CX0:
        srcx = (CX0 - destx) * dx
        destx = CX0
    if destendx > CX1:
        destendx = CX1
    destendy = desty + dsth - 1
    if desty > CY1 or destendy < CY0:
        return
    srcy = 0
    if desty < CY0:
        srcy = (CY0 - desty) * dy
        desty = CY0
    if destendy > CY1:
        destendy = CY1
    if flipx:
        srcx = (dstw - 1) * dx - srcx
        dx = -dx
    if flipy:
        srcy = (dsth - 1) * dy - srcy
        dy = -dy
    cbase = (color % 128) * 16
    for cury in range(desty, destendy + 1):
        row = (srcy >> 16) * 16
        srcy += dy
        cx = srcx
        i = cury * BW + destx
        for _ in range(destx, destendx + 1):
            pen = src[row + (cx >> 16)]
            cx += dx
            if pen != 0:
                pd = fr.pri[i]
                if pen != 15 or not pen15_shadow:            # DRAWMODE_SOURCE
                    if ((1 << (pd & 0x1f)) & pmask) == 0:
                        fr.rgb[i] = pens[cbase + pen]
                        fr.idx[i] = cbase + pen
                        fr.shd[i] = 0
                    fr.pri[i] = 31
                elif (pd & 0x80) == 0 and ((1 << (pd & 0x1f)) & pmask) == 0:   # DRAWMODE_SHADOW
                    fr.rgb[i] = shadow_rgb(fr.rgb[i], stab, noclip) if stab else fr.rgb[i]
                    fr.shd[i] += 1
                    fr.pri[i] = pd | 0x80
            i += 1


def main():
    args = [a for a in sys.argv[1:]]
    diff_out = None
    if '-diff' in args:
        k = args.index('-diff'); diff_out = args[k + 1]; del args[k:k + 2]
    if len(args) < 2:
        sys.exit(__doc__)
    rom = open(args[0], 'rb').read()
    st = moo_state.load(args[1])
    out = render(st, rom)
    w, h = st.width, st.height
    bad = sum(1 for a, b in zip(out, st.pixels) if a != b)
    print(f'{os.path.basename(args[1])}: {bad} of {w * h} pixels differ from MAME')
    def png(path, px):
        rgb = bytearray()
        for v in px:
            rgb += bytes(((v >> 16) & 255, (v >> 8) & 255, v & 255))
        pngio.write(path, w, h, rgb)
    if len(args) > 2:
        png(args[2], out)
    if diff_out:
        png(diff_out, [0xff0000 if a != b else ((b >> 2) & 0x3f3f3f) for a, b in zip(out, st.pixels)])
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
