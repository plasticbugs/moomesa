"""Read a frozen machine state written by tools/dump_state.lua.

    st = moo_state.load('state_00900.bin')
    st.vram[...], st.k832[...], st.spr_list[...], st.pixels (list of 0xRRGGBB)

Everything is plain lists of ints; no numpy.
"""
import gzip, struct


class State:
    pass


def _u16(b, off, n):
    return list(struct.unpack_from('<%dH' % n, b, off)), off + 2 * n


def _u8(b, off, n):
    return list(b[off:off + n]), off + n


def load(path):
    b = (gzip.open if path.endswith('.gz') else open)(path, 'rb').read()
    if b[:4] != b'MOOS':
        raise ValueError(f'{path}: not a moomesa state')
    st = State()
    st.version, st.frame = struct.unpack_from('<II', b, 4)
    o = 12
    st.k832, o = _u16(b, o, 32)          # K056832 regs, word index
    st.k832b, o = _u16(b, o, 4)
    st.vram, o = _u16(b, o, 69632)       # MAME m_videoram: page p at p*0x1000 words
    st.k246, o = _u8(b, o, 8)
    st.k247r, o = _u16(b, o, 16)
    st.spr_list, o = _u16(b, o, 2048)    # K053247 internal list, 256 x 8 words
    st.k251, o = _u8(b, o, 16)
    st.k338, o = _u16(b, o, 32)
    st.pal, o = _u16(b, o, 4096)         # 2048 entries x 2 words
    st.sprram, o = _u16(b, o, 32768)     # CPU view of sprite RAM
    st.width, st.height = struct.unpack_from('<HH', b, o)
    o += 4
    n = st.width * st.height
    st.pixels = [v & 0xffffff for v in struct.unpack_from('<%dI' % n, b, o)]
    o += 4 * n
    if o != len(b):
        raise ValueError(f'{path}: {len(b) - o} trailing bytes')
    return st


def palette_rgb(st):
    """xRGB_888: word 0 low byte = R, word 1 = G:B."""
    return [((st.pal[2 * i] & 0xff) << 16) | st.pal[2 * i + 1] for i in range(2048)]
