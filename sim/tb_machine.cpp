// Fast whole-machine bench: rtl/moomesa_core.sv from reset against ideal
// memories (every ROM port answered from the image after a fixed latency),
// with inputs scripted the way tools/dump_state.lua drives MAME, frames
// written as PNGs and the sound as a WAV.  The real-memory bench is
// sim/run_system.sh; keep both (METHODOLOGY 5.16).
//
//   obj_machine/Vmoomesa_core moomesa.rom [-frames N] [-o DIR] [-snap a,b,..]
//        [-every N] [-coin F] [-start F] [-play F] [-lat N] [-wav file] [-service]
#include "Vmoomesa_core.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <vector>
#include <zlib.h>

static Vmoomesa_core *dut;
static std::vector<uint8_t> rom;
static int lat = 12;
static const uint32_t SPR_B = 0x000000, TILE_B = 0x800000, PCM_B = 0xA00000, PROG_B = 0xC00000, SND_B = 0xD00000;
static uint16_t be16(uint32_t o) { return (uint16_t(rom[o]) << 8) | rom[o + 1]; }
static uint32_t be32(uint32_t o) { return (uint32_t(be16(o)) << 16) | be16(o + 2); }
static uint64_t be64(uint32_t o) { return (uint64_t(be32(o)) << 32) | be32(o + 4); }

struct Port { int cnt = -1; bool served = false; };
static Port pm, ps, pp, pt, psp;
// a level request answered `lat` clocks later with a one-clock ack; counted
// once until it drops (the memory module's convention)
template <typename F> static bool serve(Port &p, bool req, F answer) {
    if (!req) { p.cnt = -1; p.served = false; return false; }
    if (p.served) return false;
    if (p.cnt < 0) p.cnt = lat;
    if (--p.cnt == 0) { answer(); p.served = true; return true; }
    return false;
}

static void write_png(const std::string &path, int w, int h, const std::vector<uint32_t> &px) {
    std::vector<uint8_t> raw;
    for (int y = 0; y < h; y++) {
        raw.push_back(0);
        for (int x = 0; x < w; x++) { uint32_t v = px[y * w + x]; raw.push_back(v >> 16); raw.push_back(v >> 8); raw.push_back(v); }
    }
    uLongf zl = compressBound(raw.size()); std::vector<uint8_t> z(zl);
    compress2(z.data(), &zl, raw.data(), raw.size(), 6); z.resize(zl);
    FILE *f = fopen(path.c_str(), "wb"); if (!f) return;
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
    std::string romp, out = ".", wavp;
    int frames = 60, every = 0, coin = 600, start = 700, play = 1000;
    bool service = false;
    std::set<int> snaps;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto nxt = [&]() { return std::string(i + 1 < argc ? argv[++i] : "0"); };
        if (a == "-frames") frames = atoi(nxt().c_str());
        else if (a == "-o") out = nxt();
        else if (a == "-every") every = atoi(nxt().c_str());
        else if (a == "-coin") coin = atoi(nxt().c_str());
        else if (a == "-start") start = atoi(nxt().c_str());
        else if (a == "-play") play = atoi(nxt().c_str());
        else if (a == "-lat") lat = atoi(nxt().c_str());
        else if (a == "-wav") wavp = nxt();
        else if (a == "-service") service = true;
        else if (a == "-snap") { std::string s = nxt(); size_t p = 0; while (p < s.size()) { snaps.insert(atoi(s.c_str() + p)); p = s.find(',', p); if (p == std::string::npos) break; p++; } }
        else if (a[0] != '+') romp = a;
    }
    FILE *rf = fopen(romp.c_str(), "rb");
    if (!rf) { fprintf(stderr, "cannot open %s\n", romp.c_str()); return 2; }
    rom.resize(0xD40080);
    if (fread(rom.data(), 1, rom.size(), rf) != rom.size()) { fprintf(stderr, "short rom\n"); return 2; }
    fclose(rf);

    dut = new Vmoomesa_core;
    dut->rst = 1; dut->pause = 0; dut->pix_sync = 0; dut->dl_we = 0; dut->nv_we = 0;
    dut->p1 = dut->p2 = dut->p3 = dut->p4 = 0xff; dut->in0 = 0xff; dut->test_n = 1;
    dut->dsw = 0xA;                         // stereo, common coin, 4 players (IN1 0x20|0x80 >> 4)
    auto tick = [&]() {
        dut->clk = 0; dut->eval();
        dut->mrom_ack = dut->srom_ack = dut->pcm_ack = dut->tile_ack = dut->spr_ack = 0;
        serve(pm, dut->mrom_req, [&] { dut->mrom_ack = 1; dut->mrom_q = be16(PROG_B + dut->mrom_addr * 2); });
        serve(ps, dut->srom_req, [&] { dut->srom_ack = 1; dut->srom_q = rom[SND_B + dut->srom_addr]; });
        serve(pp, dut->pcm_req,  [&] { dut->pcm_ack = 1;  dut->pcm_q = rom[PCM_B + dut->pcm_addr]; });
        serve(pt, dut->tile_req, [&] { dut->tile_ack = 1; dut->tile_q = be32(TILE_B + dut->tile_addr * 4); });
        serve(psp, dut->spr_req, [&] { dut->spr_ack = 1;  dut->spr_q = be64(SPR_B + dut->spr_addr * 8); });
        dut->clk = 1; dut->eval();
    };
    // the parts of the image the core itself takes off the download: the
    // tile region (blank-tile table) and the default EEPROM
    for (int i = 0; i < 16; i++) tick();
    for (uint32_t a = TILE_B; a < TILE_B + 0x200000; a++) { dut->dl_we = 1; dut->dl_addr = a; dut->dl_data = rom[a]; tick(); }
    for (uint32_t a = 0xD40000; a < 0xD40080; a++) { dut->dl_we = 1; dut->dl_addr = a; dut->dl_data = rom[a]; tick(); }
    dut->dl_we = 0;
    for (int i = 0; i < 16; i++) tick();
    dut->rst = 0;

    std::vector<int16_t> wav;
    std::vector<uint32_t> fb(384 * 224, 0);
    int frame = 0, px = 0, py = 0;
    bool vb_d = true, hb_d = true;
    uint64_t clk = 0;
    int statusor = 0;
    while (frame < frames) {
        // inputs, as tools/dump_state.lua drives MAME
        uint8_t p1 = 0xff, in0 = 0xff;
        if (coin > 0 && frame >= coin && frame < coin + 8) in0 &= ~0x01;
        if (start > 0 && frame >= start && frame < start + 8) p1 &= ~0x80;
        if (start > 0 && frame > play) {
            if ((frame / 150) % 3 != 2) p1 &= ~0x02; else p1 &= ~0x01;
            if ((frame / 9) % 2 == 0) p1 &= ~0x10;
            if ((frame / 61) % 7 == 0) p1 &= ~0x20;
        }
        dut->p1 = p1; dut->in0 = in0; dut->test_n = !(service && frame < 400);
        tick(); clk++;
        statusor |= dut->dbg_status;
        if (dut->pix_ce) {
            if (dut->de) { if (px < 384 && py < 224) fb[py * 384 + px] = dut->rgb; px++; }
            if (dut->hblank && !hb_d) { if (px > 0) py++; px = 0; }
            hb_d = dut->hblank;
            if (dut->vblank && !vb_d) {
                frame++;
                bool keep = snaps.count(frame) || (every && frame % every == 0);
                if (keep) {
                    char n[512]; snprintf(n, sizeof n, "%s/frame_%05d.png", out.c_str(), frame);
                    write_png(n, 384, 224, fb);
                }
                if (frame % 60 == 0) {
                    fprintf(stderr, "frame %d  clk %llu  pc %06x  status %02x  k054539 worst pass %u clocks, %u reads\n", frame,
                            (unsigned long long)clk, dut->dbg_addr * 2, statusor, dut->dbg_snd_worst, dut->dbg_snd_reads);
                }
                py = 0; px = 0;
            }
            vb_d = dut->vblank;
        }
        // 48 kHz sound, sampled every 2000 clocks
        if (!wavp.empty() && clk % 2000 == 0) { wav.push_back(dut->snd_l); wav.push_back(dut->snd_r); }
    }
    if (!wavp.empty()) {
        FILE *w = fopen(wavp.c_str(), "wb");
        uint32_t n = wav.size() * 2, r = 48000, br = 48000 * 4;
        auto u32 = [&](uint32_t v) { fwrite(&v, 4, 1, w); };
        auto u16 = [&](uint16_t v) { fwrite(&v, 2, 1, w); };
        fwrite("RIFF", 1, 4, w); u32(36 + n); fwrite("WAVEfmt ", 1, 8, w);
        u32(16); u16(1); u16(2); u32(r); u32(br); u16(4); u16(16);
        fwrite("data", 1, 4, w); u32(n); fwrite(wav.data(), 2, wav.size(), w); fclose(w);
    }
    printf("%d frames, %llu clocks, halted %d, status %02x\n", frame, (unsigned long long)clk, dut->dbg_halted, statusor);
    delete dut;
    return 0;
}
