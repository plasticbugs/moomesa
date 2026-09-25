// MAME's K054539 (ref/mame/k054539.cpp, write() and sound_stream_update()),
// kept as close to verbatim as a standalone program allows, fed the command
// log tools/log_k054539.lua records.  It is the oracle for rtl/k054539.sv:
// the same log through both, compared sample by sample (sim/cmp_k539.py).
//
//   k539_ref moomesa.rom k539.log secs out.wav
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static std::vector<uint8_t> rom;
static uint8_t regs[0x230];
static uint8_t posreg_latch[8][3];
static uint8_t ram[0x8000];
static int reverb_pos = 0, cur_ptr = 0, rom_addr = 0;
static double voltab[256], pantab[0xf];
struct channel { uint32_t pos, pfrac; int32_t val, pval; } chans[8];
static uint8_t read_byte(uint32_t a) { return rom[0xA00000 + (a & 0x1fffff)]; }
static bool regupdate() { return !(regs[0x22f] & 0x80); }
static void keyon(int ch) { if (regupdate()) regs[0x22c] |= 1 << ch; }
static void keyoff(int ch) { if (regupdate()) regs[0x22c] &= ~(1 << ch); }

static void write(int offset, uint8_t data) {
    bool latch = (regs[0x22f] & 1);                      // UPDATE_AT_KEYON is MAME's default
    if (latch && offset < 0x100) {
        int offs = (offset & 0x1f) - 0xc, ch = offset >> 5;
        if (offs >= 0 && offs <= 2) { posreg_latch[ch][offs] = data; return; }
    } else {
        switch (offset) {
        case 0x214:
            for (int ch = 0; ch < 8; ch++) if (data & (1 << ch)) {
                if (latch) { uint8_t *r = regs + (ch << 5) + 0xc; r[0] = posreg_latch[ch][0]; r[1] = posreg_latch[ch][1]; r[2] = posreg_latch[ch][2]; }
                keyon(ch);
            }
            break;
        case 0x215: for (int ch = 0; ch < 8; ch++) if (data & (1 << ch)) keyoff(ch); break;
        case 0x22d:
            if (rom_addr == 0x80) ram[(cur_ptr & 0x3fff) | ((cur_ptr & 0x10000) >> 2)] = data;
            cur_ptr = (cur_ptr + 1) & 0x1ffff;
            break;
        case 0x22e: rom_addr = data; cur_ptr = 0; break;
        default: break;
        }
    }
    regs[offset] = data;
}

static void sample(double &lout, double &rout) {
    static const int16_t dpcm[16] = {
        0 * 0x100, 1 * 0x100, 2 * 0x100, 4 * 0x100, 8 * 0x100, 16 * 0x100, 32 * 0x100, 64 * 0x100,
        0 * 0x100, -64 * 0x100, -32 * 0x100, -16 * 0x100, -8 * 0x100, -4 * 0x100, -2 * 0x100, -1 * 0x100 };
    static constexpr double VOL_CAP = 1.80;
    int16_t *rbase = (int16_t *)ram;
    lout = rout = 0;
    if (!(regs[0x22f] & 1)) return;
    double lval, rval;
    lval = rval = rbase[reverb_pos];
    rbase[reverb_pos] = 0;
    for (int ch = 0; ch < 8; ch++) {
        if (!(regs[0x22c] & (1 << ch))) continue;
        unsigned char *base1 = regs + 0x20 * ch, *base2 = regs + 0x200 + 0x2 * ch;
        channel *chan = chans + ch;
        int delta = base1[0] | (base1[1] << 8) | (base1[2] << 16);
        int vol = base1[3];
        int bval = vol + base1[4]; if (bval > 255) bval = 255;
        int pan = base1[5];
        if (pan >= 0x81 && pan <= 0x8f) pan -= 0x81;
        else if (pan >= 0x11 && pan <= 0x1f) pan -= 0x11;
        else pan = 0x18 - 0x11;
        double lvol = voltab[vol] * pantab[pan]; if (lvol > VOL_CAP) lvol = VOL_CAP;
        double rvol = voltab[vol] * pantab[0xe - pan]; if (rvol > VOL_CAP) rvol = VOL_CAP;
        double rbvol = voltab[bval] / 2; if (rbvol > VOL_CAP) rbvol = VOL_CAP;
        int rdelta = (base1[6] | (base1[7] << 8)) >> 3;
        rdelta = (rdelta + reverb_pos) & 0x3fff;
        int cur_pos = (base1[0x0c] | (base1[0x0d] << 8) | (base1[0x0e] << 16));
        int fdelta, pdelta;
        if (base2[0] & 0x20) { delta = -delta; fdelta = +0x10000; pdelta = -1; }
        else { fdelta = -0x10000; pdelta = +1; }
        int cur_pfrac, cur_val, cur_pval;
        if (cur_pos != (int)chan->pos) { chan->pos = cur_pos; cur_pfrac = 0; cur_val = 0; cur_pval = 0; }
        else { cur_pfrac = chan->pfrac; cur_val = chan->val; cur_pval = chan->pval; }
        switch (base2[0] & 0xc) {
        case 0x0:
            cur_pfrac += delta;
            while (cur_pfrac & ~0xffff) {
                cur_pfrac += fdelta; cur_pos += pdelta;
                cur_pval = cur_val; cur_val = (int16_t)(read_byte(cur_pos) << 8);
                if (cur_val == (int16_t)0x8000 && (base2[1] & 1)) {
                    cur_pos = (base1[0x08] | (base1[0x09] << 8) | (base1[0x0a] << 16));
                    cur_val = (int16_t)(read_byte(cur_pos) << 8);
                }
                if (cur_val == (int16_t)0x8000) { keyoff(ch); cur_val = 0; break; }
            }
            break;
        case 0x4:
            pdelta <<= 1;
            cur_pfrac += delta;
            while (cur_pfrac & ~0xffff) {
                cur_pfrac += fdelta; cur_pos += pdelta;
                cur_pval = cur_val; cur_val = (int16_t)(read_byte(cur_pos) | read_byte(cur_pos + 1) << 8);
                if (cur_val == (int16_t)0x8000 && (base2[1] & 1)) {
                    cur_pos = (base1[0x08] | (base1[0x09] << 8) | (base1[0x0a] << 16));
                    cur_val = (int16_t)(read_byte(cur_pos) | read_byte(cur_pos + 1) << 8);
                }
                if (cur_val == (int16_t)0x8000) { keyoff(ch); cur_val = 0; break; }
            }
            break;
        case 0x8:
            cur_pos <<= 1; cur_pfrac <<= 1;
            if (cur_pfrac & 0x10000) { cur_pfrac &= 0xffff; cur_pos |= 1; }
            cur_pfrac += delta;
            while (cur_pfrac & ~0xffff) {
                cur_pfrac += fdelta; cur_pos += pdelta;
                cur_pval = cur_val; cur_val = read_byte(cur_pos >> 1);
                if (cur_val == 0x88 && (base2[1] & 1)) {
                    cur_pos = (base1[0x08] | (base1[0x09] << 8) | (base1[0x0a] << 16)) << 1;
                    cur_val = read_byte(cur_pos >> 1);
                }
                if (cur_val == 0x88) { keyoff(ch); cur_val = 0; break; }
                if (cur_pos & 1) cur_val >>= 4; else cur_val &= 15;
                cur_val = cur_pval + dpcm[cur_val];
                if (cur_val < -32768) cur_val = -32768; else if (cur_val > 32767) cur_val = 32767;
            }
            cur_pfrac >>= 1;
            if (cur_pos & 1) cur_pfrac |= 0x8000;
            cur_pos >>= 1;
            break;
        default: break;
        }
        lval += cur_val * lvol;
        rval += cur_val * rvol;
        rbase[(rdelta + reverb_pos) & 0x1fff] += int16_t(cur_val * rbvol);
        chan->pos = cur_pos; chan->pfrac = cur_pfrac; chan->pval = cur_pval; chan->val = cur_val;
        if (regupdate()) { base1[0x0c] = cur_pos & 0xff; base1[0x0d] = cur_pos >> 8 & 0xff; base1[0x0e] = cur_pos >> 16 & 0xff; }
    }
    reverb_pos = (reverb_pos + 1) & 0x1fff;
    lout = lval; rout = rval;
}

int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "usage: k539_ref rom log secs out.wav\n"); return 2; }
    rom.resize(0xD40080);
    FILE *rf = fopen(argv[1], "rb"); if (!rf || fread(rom.data(), 1, rom.size(), rf) != rom.size()) return 2; fclose(rf);
    for (int i = 0; i < 256; i++) voltab[i] = pow(10.0, (-36.0 * (double)i / (double)0x40) / 20.0) / 4.0;
    for (int i = 0; i < 0xf; i++) pantab[i] = sqrt((double)i) / sqrt((double)0xe);
    regs[0x22c] = 0; regs[0x22f] = 0;
    FILE *lf = fopen(argv[2], "r");
    long s; unsigned a, d; long ns = long(atof(argv[3]) * 48000);
    std::vector<int16_t> out;
    bool have = fscanf(lf, "%ld %x %x", &s, &a, &d) == 3;
    for (long smp = 0; smp < ns; smp++) {
        while (have && s <= smp) { write(a, d); have = fscanf(lf, "%ld %x %x", &s, &a, &d) == 3; }
        double l, r; sample(l, r);
        auto c = [](double v) { long x = lrint(floor(v)); return int16_t(x > 32767 ? 32767 : x < -32768 ? -32768 : x); };
        out.push_back(c(l)); out.push_back(c(r));
    }
    FILE *w = fopen(argv[4], "wb");
    uint32_t n = out.size() * 2;
    auto u32 = [&](uint32_t v) { fwrite(&v, 4, 1, w); };
    auto u16 = [&](uint16_t v) { fwrite(&v, 2, 1, w); };
    fwrite("RIFF", 1, 4, w); u32(36 + n); fwrite("WAVEfmt ", 1, 8, w);
    u32(16); u16(1); u16(2); u32(48000); u32(48000 * 4); u16(4); u16(16);
    fwrite("data", 1, 4, w); u32(n); fwrite(out.data(), 2, out.size(), w); fclose(w);
    return 0;
}
