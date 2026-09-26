// Fast whole-machine bench: rtl/moomesa_core.sv from reset against ideal
// memories (every ROM port answered from the image after a fixed latency),
// with inputs scripted the way tools/dump_state.lua drives MAME, frames
// written as PNGs and the sound as a WAV.  The real-memory bench is
// sim/run_system.sh; keep both (METHODOLOGY 5.16).
//
//   obj_machine/Vmoomesa_core moomesa.rom [-frames N] [-o DIR] [-snap a,b,..]
//        [-every N] [-coin F] [-start F] [-play F] [-lat N] [-wav file] [-service]
//        [-tas "Input Log.txt" [-tasoff N]]
#include "Vmoomesa_core.h"
#ifdef TRACE
#include "Vmoomesa_core___024root.h"
#endif
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <map>
#include <algorithm>
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
    // -tas: a BizHawk movie's "Input Log.txt", one line per frame, as
    // tools/bk2_inputs.lua gives it to MAME (columns: coins 1-4, services 1-4,
    // service mode, starts 1,3,2,4, then per player button 1, button 2, down,
    // left, right, up)
    std::string tas_path;
    int tas_off = 0;
    std::vector<std::string> tas;
    bool service = false;
    std::set<int> snaps;
    int trace_from = -1, trace_to = -1, dump_at = -1;
    std::string dump_path;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto nxt = [&]() { return std::string(i + 1 < argc ? argv[++i] : "0"); };
        if (a == "-frames") frames = atoi(nxt().c_str());
        else if (a == "-o") out = nxt();
        else if (a == "-every") every = atoi(nxt().c_str());
        else if (a == "-coin") coin = atoi(nxt().c_str());
        else if (a == "-start") start = atoi(nxt().c_str());
        else if (a == "-play") play = atoi(nxt().c_str());
        else if (a == "-tas") tas_path = nxt();
        else if (a == "-tasoff") tas_off = atoi(nxt().c_str());
        else if (a == "-lat") lat = atoi(nxt().c_str());
        else if (a == "-wav") wavp = nxt();
        else if (a == "-service") service = true;
        else if (a == "-dump") { std::string t = nxt(); dump_at = atoi(t.c_str()); dump_path = t.substr(t.find(':') + 1); }
        else if (a == "-trace") { std::string t = nxt(); trace_from = atoi(t.c_str()); trace_to = atoi(t.c_str() + t.find('-') + 1); }
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

    if (!tas_path.empty()) {
        FILE *tf = fopen(tas_path.c_str(), "r");
        if (!tf) { fprintf(stderr, "cannot read %s\n", tas_path.c_str()); return 2; }
        char line[256];
        while (fgets(line, sizeof line, tf)) {
            if (line[0] != '|') continue;
            std::string r;
            for (char *c = line; *c && *c != '\n'; c++) if (*c != '|') r += *c;
            tas.push_back(r);
        }
        fclose(tf);
        printf("tas: %zu frames\n", tas.size());
    }
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
        bool tsvc = false;
        if (!tas.empty()) {
            p1 = 0xff; in0 = 0xff;
            int k = frame + tas_off;
            if (k >= 0 && k < (int)tas.size()) {
                const std::string &r = tas[k];
                auto on = [&](int c) { return c < (int)r.size() && r[c] != '.'; };
                for (int c = 0; c < 4; c++) if (on(c)) in0 &= ~(1 << c);
                for (int c = 0; c < 4; c++) if (on(4 + c)) in0 &= ~(0x10 << c);
                tsvc = on(8);
                if (on(9)) p1 &= ~0x80;
                if (on(13)) p1 &= ~0x10;
                if (on(14)) p1 &= ~0x20;
                if (on(15)) p1 &= ~0x08;
                if (on(16)) p1 &= ~0x01;
                if (on(17)) p1 &= ~0x02;
                if (on(18)) p1 &= ~0x04;
            }
        }
        dut->p1 = p1; dut->in0 = in0; dut->test_n = !((service && frame < 400) || tsvc);
        tick(); clk++;
        statusor |= dut->dbg_status;
#ifdef TRACE
        static std::map<uint32_t, long> pchist;
        if (frame >= trace_from && frame <= trace_to) {
            auto *rr = dut->rootp;
            // instruction fetches (function code x10), bucketed by 16 bytes
            if (!rr->moomesa_core__DOT__ASn && rr->moomesa_core__DOT__FC1 && !rr->moomesa_core__DOT__FC0 && !rr->moomesa_core__DOT__as_d)
                pchist[(dut->dbg_addr * 2) & ~0xf]++;
        }
        if (frame == trace_to + 1 && !pchist.empty()) {
            std::vector<std::pair<long, uint32_t>> v;
            for (auto &kv : pchist) v.push_back({kv.second, kv.first});
            std::sort(v.rbegin(), v.rend());
            printf("fetch histogram, frames %d-%d:\n", trace_from, trace_to);
            for (size_t i = 0; i < v.size() && i < 25; i++) printf("  %06x  %ld\n", v[i].second, v[i].first);
            pchist.clear();
        }
        if (frame >= trace_from && frame <= trace_to && getenv("TRACE_EVENTS")) {
            // bus events on the shared slave bus, and the interrupt lines
            auto *r = dut->rootp;
            static int i4 = 0, i5 = 0;
            int n4 = r->moomesa_core__DOT__irq4, n5 = r->moomesa_core__DOT__irq5;
            if (n4 != i4 || n5 != i5) printf("f%d c%llu line %d: irq4 %d irq5 %d  pc~%06x\n", frame, (unsigned long long)clk,
                                             r->moomesa_core__DOT__u_video__DOT__vpos, n4, n5, dut->dbg_addr * 2);
            i4 = n4; i5 = n5;
            if (r->moomesa_core__DOT__s_req && !r->moomesa_core__DOT__s_rnw) {
                uint32_t a = r->moomesa_core__DOT__s_addr * 2;
                if (a == 0x0de000 || a == 0x18004a || a == 0x0c2004 || a == 0x0d0018)
                    printf("f%d c%llu line %d: write %06x = %04x be %d\n", frame, (unsigned long long)clk,
                           r->moomesa_core__DOT__u_video__DOT__vpos, a, r->moomesa_core__DOT__s_d, r->moomesa_core__DOT__s_be);
            }
            if (r->moomesa_core__DOT__u_video__DOT__dma_done) printf("f%d c%llu: dma_done (ctl2 %04x)\n", frame, (unsigned long long)clk, r->moomesa_core__DOT__ctl2);
        }
#endif
        if (dut->pix_ce) {
            if (dut->de) { if (px < 384 && py < 224) fb[py * 384 + px] = dut->rgb; px++; }
            if (dut->hblank && !hb_d) { if (px > 0) py++; px = 0; }
            hb_d = dut->hblank;
            if (dut->vblank && !vb_d) {
                frame++;
                bool keep = snaps.count(frame) || (every && frame % every == 0);
#ifdef TRACE
                if (frame == dump_at) {
                    // the video state as tools/dump_state.lua writes MAME's (MOOS v1),
                    // with this frame's picture, so tools/moo_render.py can draw it
                    auto *r = dut->rootp;
                    FILE *d = fopen(dump_path.c_str(), "wb");
                    auto u16 = [&](uint16_t v) { fwrite(&v, 2, 1, d); };
                    auto u32 = [&](uint32_t v) { fwrite(&v, 4, 1, d); };
                    fwrite("MOOS", 1, 4, d); u32(1); u32(frame);
                    for (int i = 0; i < 32; i++) u16(r->moomesa_core__DOT__u_video__DOT__vac[i]);
                    for (int i = 0; i < 4; i++) u16(r->moomesa_core__DOT__u_video__DOT__vsc[i]);
                    std::vector<uint16_t> vr(69632, 0);
                    const int mp[4] = {0, 1, 4, 5};
                    for (int e = 0; e < 8192; e++) {
                        uint32_t v = r->moomesa_core__DOT__u_video__DOT__vram[e];
                        int base = mp[e >> 11] * 4096 + 2 * (e & 0x7ff);
                        vr[base] = v >> 16; vr[base + 1] = v & 0xffff;
                    }
                    fwrite(vr.data(), 2, vr.size(), d);
                    for (int i = 0; i < 8; i++) { uint8_t b = r->moomesa_core__DOT__u_video__DOT__u_spr__DOT__k246[i]; fwrite(&b, 1, 1, d); }
                    for (int i = 0; i < 16; i++) u16(0);
                    for (int i = 0; i < 2048; i++) u16(r->moomesa_core__DOT__u_video__DOT__u_spr__DOT__lst[i & 7][i >> 3]);
                    for (int i = 0; i < 16; i++) { uint8_t b = r->moomesa_core__DOT__u_video__DOT__u_mix__DOT__r251[i]; fwrite(&b, 1, 1, d); }
                    for (int i = 0; i < 32; i++) u16(i < 16 ? r->moomesa_core__DOT__u_video__DOT__u_mix__DOT__r338[i] : 0);
                    for (int i = 0; i < 2048; i++) { uint32_t v = r->moomesa_core__DOT__u_video__DOT__u_mix__DOT__pal[i]; u16(v & 0xffff); u16(v >> 16); }
                    for (int i = 0; i < 32768; i++) u16(r->moomesa_core__DOT__u_video__DOT__sram[i]);
                    u16(384); u16(224);
                    for (auto v : fb) u32(v);
                    fclose(d);
                    fprintf(stderr, "dumped the video state at frame %d to %s\n", frame, dump_path.c_str());
                }
#endif
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
