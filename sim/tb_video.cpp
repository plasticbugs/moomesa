// Frozen-state video bench: load a state from tools/dump_state.lua into
// rtl/moo_video.sv the way the 68000 would (register, tile RAM, palette
// writes over the CPU bus; the K053247 list through its bench back door),
// run a frame against the ROM image with SDRAM-like latency, and diff every
// pixel of the visible window against the picture MAME drew from the same
// state.  Zero differing pixels is the gate (METHODOLOGY section 1).
//
//   obj_video/Vmoo_video moomesa.rom state.bin [-lat N] [-png out.png]
//
// -lat   clocks from a ROM request to its answer (default 14: a 2-word
//        burst on the Pocket's SDRAM with nothing in the way).
// -slat  the same for the sprite port alone (default -lat + 2)
#include "Vmoo_video.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <zlib.h>

static Vmoo_video *dut;
static uint64_t clk = 0;
static int pixdiv = 0;
static std::vector<uint8_t> rom;
static int lat = 14, slat = -1;   // -slat: the sprite port's alone
static int t_cnt = -1, s_cnt = -1;
static long t_busy_run = 0, t_busy_worst = 0;

static const uint32_t SPR_B = 0x000000, TILE_B = 0x800000;
static uint16_t be16(uint32_t o) { return (uint16_t(rom[o]) << 8) | rom[o + 1]; }
static uint32_t be32(uint32_t o) { return (uint32_t(be16(o)) << 16) | be16(o + 2); }
static uint64_t be64(uint32_t o) { return (uint64_t(be32(o)) << 32) | be32(o + 4); }

static void tick() {
    dut->cen_pix = (pixdiv == 0);
    dut->clk = 0; dut->eval();
    // ROM model: a request is answered `lat` clocks after it is seen
    dut->tile_ack = 0; dut->spr_ack = 0;
    if (dut->tile_req) {
        if (t_cnt < 0) t_cnt = lat;
        else if (--t_cnt == 0) { dut->tile_ack = 1; dut->tile_q = be32(TILE_B + dut->tile_addr * 4); t_cnt = -2; }
    } else t_cnt = -1;
    if (t_cnt == -2 && !dut->tile_ack) {}
    if (dut->spr_req) {
        if (s_cnt < 0) s_cnt = (slat >= 0 ? slat : lat + 2);
        else if (--s_cnt == 0) { dut->spr_ack = 1; dut->spr_q = be64(SPR_B + dut->spr_addr * 8); s_cnt = -2; }
    } else s_cnt = -1;
    dut->clk = 1; dut->eval();
    // a request answered stays answered until it drops
    if (t_cnt == -2 && !dut->tile_req) t_cnt = -1;
    if (s_cnt == -2 && !dut->spr_req) s_cnt = -1;
    if (dut->tile_busy) { if (++t_busy_run > t_busy_worst) t_busy_worst = t_busy_run; } else t_busy_run = 0;
    pixdiv = (pixdiv + 1) % 12;
    clk++;
}

static void bus(bool rnw, uint32_t addr, uint16_t d, int be = 3) {
    dut->cpu_addr = addr >> 1; dut->cpu_rnw = rnw; dut->cpu_d = d; dut->cpu_be = be;
    dut->cpu_req = 1; tick(); dut->cpu_req = 0;
    int g = 0; while (!dut->cpu_ack && g++ < 100000) tick();
    if (g >= 100000) { fprintf(stderr, "bus timeout at %06x\n", addr); exit(2); }
    tick();
}

struct State {
    uint32_t frame;
    uint16_t k832[32], k832b[4], vram[69632];
    uint8_t k246[8]; uint16_t k247r[16], list[2048];
    uint8_t k251[16]; uint16_t k338[32], pal[4096], sprram[32768];
    uint16_t w, h; std::vector<uint32_t> px;
};

static bool load_state(const char *path, State &s) {
    gzFile f = gzopen(path, "rb");
    if (!f) return false;
    std::vector<uint8_t> b; uint8_t buf[65536]; int n;
    while ((n = gzread(f, buf, sizeof buf)) > 0) b.insert(b.end(), buf, buf + n);
    gzclose(f);
    if (b.size() < 12 || memcmp(b.data(), "MOOS", 4)) return false;
    size_t o = 8;
    auto u32 = [&]() { uint32_t v; memcpy(&v, &b[o], 4); o += 4; return v; };
    auto u16s = [&](uint16_t *d, int k) { memcpy(d, &b[o], 2 * k); o += 2 * k; };
    auto u8s = [&](uint8_t *d, int k) { memcpy(d, &b[o], k); o += k; };
    s.frame = u32();
    u16s(s.k832, 32); u16s(s.k832b, 4); u16s(s.vram, 69632);
    u8s(s.k246, 8); u16s(s.k247r, 16); u16s(s.list, 2048);
    u8s(s.k251, 16); u16s(s.k338, 32); u16s(s.pal, 4096); u16s(s.sprram, 32768);
    u16s(&s.w, 1); u16s(&s.h, 1);
    s.px.resize(size_t(s.w) * s.h);
    memcpy(s.px.data(), &b[o], 4 * s.px.size()); o += 4 * s.px.size();
    return o == b.size();
}

static void write_png(const char *path, int w, int h, const std::vector<uint32_t> &px) {
    std::vector<uint8_t> raw;
    for (int y = 0; y < h; y++) {
        raw.push_back(0);
        for (int x = 0; x < w; x++) { uint32_t v = px[y * w + x]; raw.push_back(v >> 16); raw.push_back(v >> 8); raw.push_back(v); }
    }
    uLongf zl = compressBound(raw.size()); std::vector<uint8_t> z(zl);
    compress2(z.data(), &zl, raw.data(), raw.size(), 6); z.resize(zl);
    FILE *f = fopen(path, "wb"); if (!f) return;
    auto chunk = [&](const char *t, const std::vector<uint8_t> &d) {
        uint8_t l[4] = {uint8_t(d.size() >> 24), uint8_t(d.size() >> 16), uint8_t(d.size() >> 8), uint8_t(d.size())};
        fwrite(l, 1, 4, f);
        std::vector<uint8_t> td(t, t + 4); td.insert(td.end(), d.begin(), d.end());
        fwrite(td.data(), 1, td.size(), f);
        uint32_t c = crc32(0, td.data(), td.size());
        uint8_t cb[4] = {uint8_t(c >> 24), uint8_t(c >> 16), uint8_t(c >> 8), uint8_t(c)};
        fwrite(cb, 1, 4, f);
    };
    fwrite("\x89PNG\r\n\x1a\n", 1, 8, f);
    std::vector<uint8_t> ih = {uint8_t(w >> 24), uint8_t(w >> 16), uint8_t(w >> 8), uint8_t(w),
                               uint8_t(h >> 24), uint8_t(h >> 16), uint8_t(h >> 8), uint8_t(h), 8, 2, 0, 0, 0};
    chunk("IHDR", ih); chunk("IDAT", z); chunk("IEND", {});
    fclose(f);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::string romp, statep, png;
    bool perturb = false;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-lat" && i + 1 < argc) lat = atoi(argv[++i]);
        if (a == "-slat" && i + 1 < argc) slat = atoi(argv[++i]);
        else if (a == "-png" && i + 1 < argc) png = argv[++i];
        else if (a == "-perturb") perturb = true;   // negative control: the gate must fail
        else if (a[0] == '+') continue;
        else if (romp.empty()) romp = a; else statep = a;
    }
    FILE *rf = fopen(romp.c_str(), "rb");
    if (!rf) { fprintf(stderr, "cannot open %s\n", romp.c_str()); return 2; }
    rom.resize(0xD40080); if (fread(rom.data(), 1, rom.size(), rf) != rom.size()) { fprintf(stderr, "short rom\n"); return 2; }
    fclose(rf);
    static State s;
    if (!load_state(statep.c_str(), s)) { fprintf(stderr, "cannot read state %s\n", statep.c_str()); return 2; }

    dut = new Vmoo_video;
    dut->rst = 1; dut->objcha = 0; dut->dl_we = 0; dut->cpu_req = 0; dut->dbg_list_we = 0; dut->dbg_sort = 0;
    for (int i = 0; i < 24; i++) tick();
    dut->rst = 0;
    // the tile region through the download port, as the Pocket sends it
    // (the blank-tile table is built from it)
    for (uint32_t a = TILE_B; a < TILE_B + 0x200000; a++) {
        dut->dl_we = 1; dut->dl_addr = a; dut->dl_data = rom[a]; tick();
    }
    dut->dl_we = 0;

    // tile RAM: MAME pages 0, 1, 4, 5 are the board's four; anything else
    // would alias one of them, so refuse a state that has it
    for (int p = 0; p < 17; p++) {
        if (p == 0 || p == 1 || p == 4 || p == 5) continue;
        for (int w = 0; w < 4096; w++)
            if (p * 4096 + w < 69632 && s.vram[p * 4096 + w]) { fprintf(stderr, "state uses tile page %d, which the board aliases\n", p); return 3; }
    }
    const int pages[4] = {0, 1, 4, 5}, banks[4] = {0, 1, 8, 9};
    for (int k = 0; k < 4; k++) {
        bus(false, 0x0c0032, banks[k]);
        for (int w = 0; w < 4096; w++) bus(false, 0x1a0000 + 2 * w, s.vram[pages[k] * 4096 + w]);
    }
    for (int i = 0; i < 32; i++) bus(false, 0x0c0000 + 2 * i, s.k832[i]);
    for (int i = 0; i < 4; i++) bus(false, 0x0d8000 + 2 * i, s.k832b[i]);
    // K053246, a byte at a time; DMA held off so the loaded list stands
    for (int i = 0; i < 8; i++) {
        uint8_t v = (i == 5) ? (s.k246[i] & ~0x10) : s.k246[i];
        bus(false, 0x0c2000 + (i & ~1), (i & 1) ? v : (v << 8), (i & 1) ? 1 : 2);
    }
    for (int i = 0; i < 16; i++) bus(false, 0x0cc000 + 2 * i, s.k251[i], 1);
    for (int i = 0; i < 16; i++) bus(false, 0x0ca000 + 2 * i, s.k338[i]);
    if (perturb) for (int i = 0; i < 4096; i += 2) s.pal[i + 1] ^= 0x0100;   // one green bit, every colour
    for (int i = 0; i < 4096; i++) bus(false, 0x1c0000 + 2 * i, s.pal[i]);
    for (int i = 0; i < 2048; i++) {
        dut->dbg_list_we = 1; dut->dbg_list_addr = ((i >> 3) << 3) | (i & 7); dut->dbg_list_d = s.list[i]; tick();
    }
    dut->dbg_list_we = 0;
    // wait for the next frame's first line, then sort there (it would be
    // done at vblank; this is the same list, sorted once)
    while (!(dut->vpos == 0 && dut->hpos == 0)) tick();
    dut->dbg_sort = 1; tick(); dut->dbg_sort = 0;
    // run until line 240 of this frame, recording the picture
    std::vector<uint32_t> out(size_t(s.w) * s.h, 0);
    std::vector<int> idx(size_t(s.w) * s.h, 0);
    long worst_t = 0;
    int maxf = 0, maxs = 0;
    t_busy_worst = 0;
    while (!(dut->vpos == 241)) {
        tick();
        if (!dut->tile_busy && dut->tile_fetches > maxf) { maxf = dut->tile_fetches; maxs = dut->tile_skips; }
        if (pixdiv == 1) {                      // just after a dot enable
            int x = (int(dut->hpos) - 2) & 511, y = dut->vpos;
            if (x >= 40 && x <= 423 && y >= 16 && y <= 239) {
                out[(y - 16) * s.w + (x - 40)] = dut->rgb;
                idx[(y - 16) * s.w + (x - 40)] = dut->dbg_index;
            }
        }
    }
    worst_t = t_busy_worst;
    long bad = 0; int fx = -1, fy = -1;
    for (size_t i = 0; i < out.size(); i++)
        if ((out[i] & 0xffffff) != (s.px[i] & 0xffffff)) { if (!bad) { fx = i % s.w; fy = i / s.w; } bad++; }
    printf("%s: %ld of %zu pixels differ", statep.c_str(), bad, out.size());
    if (bad) printf(" (first at x=%d y=%d: rtl %06x mame %06x index %03x)", fx, fy,
                    out[fy * s.w + fx] & 0xffffff, s.px[fy * s.w + fx] & 0xffffff, idx[fy * s.w + fx]);
    printf("; worst line: tiles %ld, sprites %u clocks of 6144; most tile fetches in a line %d (skipped %d)%s%s%s\n", worst_t, dut->spr_worst, maxf, maxs,
           dut->tile_missed ? ", TILES MISSED" : "", dut->spr_missed ? ", SPRITES MISSED" : "",
           dut->unsupported ? ", UNSUPPORTED MODE" : "");
    if (!png.empty()) write_png(png.c_str(), s.w, s.h, out);
    delete dut;
    return bad ? 1 : 0;
}
