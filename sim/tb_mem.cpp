// Pocket memory gate: push an image through moomesa_mem's download port at the
// APF loader's rate, then read every region back through the core's ports
// and compare -- first one port at a time, then all five at once with random
// addresses, which is where an arbiter that routes a result to the wrong
// owner (METHODOLOGY 5.17) or a cache that answers from a stale line shows.
// Then the SRAM.
//
//   obj_mem/Vtb_mem_top [rom] [-gap N] [-hold N] [-quick]
//
// With no rom a pseudo-random image is used, which is a harder test than a
// real one (no runs of equal words to hide a dropped or merged write) and
// needs nothing the repo may not hold.
//
// -gap   clocks between download bytes.  The loader delivers one per 8;
//        smaller is harder.
// -hold  clocks the write strobe is held high.  The Pocket holds it for 4 with
//        address and data stable; anything that counts, sums or pushes on the
//        strobe's level rather than its edge fails here (METHODOLOGY 5.8).
//
// The layout constants must match target/pocket/moomesa_mem.sv, moomesa.mra
// and tools/verify_rom.py.
#include "Vtb_mem_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static Vtb_mem_top *dut;
static uint64_t clocks = 0;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); clocks++; }

// image byte offsets (moomesa.mra)
static const uint32_t SPR_B = 0x000000, SPR_LEN = 0x800000;
static const uint32_t TILE_B = 0x800000, TILE_LEN = 0x200000;
static const uint32_t PCM_B = 0xA00000, PCM_LEN = 0x200000;
static const uint32_t PROG_B = 0xC00000, PROG_LEN = 0x100000;
static const uint32_t SND_B = 0xD00000, SND_LEN = 0x040000;
static const uint32_t IMG = 0xD40080;

static std::vector<uint8_t> rom;
static uint16_t be16(uint32_t o) { return (uint16_t(rom[o]) << 8) | rom[o + 1]; }
static uint32_t be32(uint32_t o) { return (uint32_t(be16(o)) << 16) | be16(o + 2); }
static uint64_t be64(uint32_t o) { return (uint64_t(be32(o)) << 32) | be32(o + 4); }

static long bad = 0, checked = 0;
static void fail(const char *port, uint32_t idx, uint64_t got, uint64_t want) {
    if (bad < 16) printf("  %-5s [%06X] got %016llX want %016llX\n", port, idx,
                         (unsigned long long)got, (unsigned long long)want);
    bad++;
}

// One port's request/response machine, so all five can run in the same clock.
struct Port {
    const char *name;
    uint32_t range;            // number of addressable units
    bool busy = false;
    uint32_t addr = 0;
    int wait = 0, gap = 0;
    long done = 0, worst = 0;
};

static uint32_t rng = 0x12345678;
static uint32_t rnd() { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    int gap = 8, hold = 4; bool quick = false; std::string path;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-gap" && i + 1 < argc) gap = atoi(argv[++i]);
        else if (a == "-hold" && i + 1 < argc) hold = atoi(argv[++i]);
        else if (a == "-quick") quick = true;
        else if (a[0] != '+' && a[0] != '-') path = a;
    }
    if (hold >= gap) hold = gap - 1;
    if (hold < 1) hold = 1;

    rom.resize(IMG);
    if (!path.empty()) {
        FILE *f = fopen(path.c_str(), "rb");
        if (!f || fread(rom.data(), 1, IMG, f) != IMG) { fprintf(stderr, "cannot read %u bytes from %s\n", IMG, path.c_str()); return 2; }
        fclose(f);
    } else {
        uint32_t x = 0x2545F491;
        for (auto &b : rom) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; b = uint8_t(x >> 11); }
    }

    dut = new Vtb_mem_top;
    dut->init = 1; dut->rd_late = 1; dut->burst_slow = 0;
    dut->dl_we = 0; dut->dl_active = 1;
    dut->mrom_req = dut->srom_req = dut->pcm_req = dut->tile_req = dut->spr_req = dut->vram_req = 0;
    for (int i = 0; i < 16; i++) tick();
    dut->init = 0;
    long t = 0; while (!dut->ready && t++ < 200000) tick();
    printf("sdram ready after %ld clocks\n", t);
    if (!dut->ready) { printf("FAIL  the controller never came ready\n"); return 1; }

    // quick: download only the regions' first and last 64 KB and the gaps
    // between are left as they were -- the read-back then checks only those
    auto in_quick = [&](uint32_t a) {
        const uint32_t starts[] = {SPR_B, TILE_B, PCM_B, PROG_B, SND_B, IMG};
        for (int r = 0; r < 5; r++) {
            if (a >= starts[r] && a < starts[r] + 0x10000) return true;
            if (a < starts[r + 1] && a >= starts[r + 1] - 0x10000) return true;
        }
        return a >= IMG - 0x80;
    };
    printf("downloading %s%u bytes, one per %d clocks, strobe held %d...\n",
           quick ? "(quick: 64 KB at each end of each region of) " : "", IMG, gap, hold);
    for (uint32_t a = 0; a < IMG; a++) {
        if (quick && !in_quick(a)) continue;
        dut->dl_addr = a; dut->dl_data = rom[a]; dut->dl_we = 1;
        for (int i = 0; i < hold; i++) tick();
        dut->dl_we = 0;
        for (int i = hold; i < gap; i++) tick();
    }
    for (int i = 0; i < 400; i++) tick();
    dut->dl_active = 0;
    for (int i = 0; i < 4; i++) tick();

    // ---------------------------------------------------- one port at a time
    auto want_ok = [&](uint32_t off) { return !quick || in_quick(off); };
    auto req = [&](auto set, auto ack) {
        set(1); int g = 0; while (!ack() && g++ < 4000) tick();
        set(0); tick(); return g < 4000;
    };
    for (uint32_t w = 0; w < PROG_LEN / 2; w++) {
        if (!want_ok(PROG_B + w * 2)) continue;
        dut->mrom_addr = w;
        if (!req([&](int v) { dut->mrom_req = v; }, [&] { return dut->mrom_ack; })) { fail("prog", w, 0, 1); continue; }
        checked++; if (dut->mrom_q != be16(PROG_B + w * 2)) fail("prog", w, dut->mrom_q, be16(PROG_B + w * 2));
    }
    printf("68000: %u cache misses on a straight read of %s\n", dut->mrom_misses, quick ? "the quick ranges" : "1 MB");
    for (uint32_t b = 0; b < SND_LEN; b++) {
        if (!want_ok(SND_B + b)) continue;
        dut->srom_addr = b;
        if (!req([&](int v) { dut->srom_req = v; }, [&] { return dut->srom_ack; })) { fail("snd", b, 0, 1); continue; }
        checked++; if (dut->srom_q != rom[SND_B + b]) fail("snd", b, dut->srom_q, rom[SND_B + b]);
    }
    for (uint32_t b = 0; b < PCM_LEN; b += quick ? 1 : 7) {
        if (!want_ok(PCM_B + b)) continue;
        dut->pcm_addr = b;
        if (!req([&](int v) { dut->pcm_req = v; }, [&] { return dut->pcm_ack; })) { fail("pcm", b, 0, 1); continue; }
        checked++; if (dut->pcm_q != rom[PCM_B + b]) fail("pcm", b, dut->pcm_q, rom[PCM_B + b]);
    }
    for (uint32_t r = 0; r < TILE_LEN / 4; r++) {
        if (!want_ok(TILE_B + r * 4)) continue;
        dut->tile_addr = r;
        if (!req([&](int v) { dut->tile_req = v; }, [&] { return dut->tile_ack; })) { fail("tile", r, 0, 1); continue; }
        checked++; if (dut->tile_q != be32(TILE_B + r * 4)) fail("tile", r, dut->tile_q, be32(TILE_B + r * 4));
    }
    for (uint32_t r = 0; r < SPR_LEN / 8; r++) {
        if (!want_ok(SPR_B + r * 8)) continue;
        dut->spr_addr = r;
        if (!req([&](int v) { dut->spr_req = v; }, [&] { return dut->spr_ack; })) { fail("spr", r, 0, 1); continue; }
        checked++; if (dut->spr_q != be64(SPR_B + r * 8)) fail("spr", r, dut->spr_q, be64(SPR_B + r * 8));
    }
    printf("sequential: %ld reads checked, %ld wrong\n", checked, bad);

    // ------------------------------------------------------ all five at once
    // Random addresses (restricted to what was downloaded), random gaps, every
    // port independently.  The 68000 port keeps to a 16 KB window so that it
    // both hits and evicts.
    auto pick = [&](Port &p) -> uint32_t {
        for (;;) {
            uint32_t a = rnd() % p.range, off;
            if (p.name[0] == 'p' && p.name[1] == 'r') { a = (rnd() % 8192); off = PROG_B + a * 2; }
            else if (p.name[0] == 's' && p.name[1] == 'n') off = SND_B + a;
            else if (p.name[0] == 'p') off = PCM_B + a;
            else if (p.name[0] == 't') off = TILE_B + a * 4;
            else off = SPR_B + a * 8;
            if (want_ok(off)) return a;
        }
    };
    Port ports[5] = {{"prog", PROG_LEN / 2}, {"snd", SND_LEN}, {"pcm", PCM_LEN},
                     {"tile", TILE_LEN / 4}, {"spr", SPR_LEN / 8}};
    long mixed_bad0 = bad, mixed = 0;
    const long MIXCLK = quick ? 300000 : 2000000;
    for (long c = 0; c < MIXCLK; c++) {
        // drive requests
        for (int i = 0; i < 5; i++) {
            Port &p = ports[i];
            if (!p.busy) {
                if (p.gap > 0) { p.gap--; continue; }
                p.addr = pick(p); p.busy = true; p.wait = 0;
            }
        }
        dut->mrom_req = ports[0].busy; dut->mrom_addr = ports[0].addr;
        dut->srom_req = ports[1].busy; dut->srom_addr = ports[1].addr;
        dut->pcm_req  = ports[2].busy; dut->pcm_addr  = ports[2].addr;
        dut->tile_req = ports[3].busy; dut->tile_addr = ports[3].addr;
        dut->spr_req  = ports[4].busy; dut->spr_addr  = ports[4].addr;
        tick();
        const bool acks[5] = {bool(dut->mrom_ack), bool(dut->srom_ack), bool(dut->pcm_ack),
                              bool(dut->tile_ack), bool(dut->spr_ack)};
        for (int i = 0; i < 5; i++) {
            Port &p = ports[i];
            if (!p.busy) continue;
            p.wait++;
            if (p.wait > 20000) { fail(p.name, p.addr, 0, 1); p.busy = false; continue; }
            if (!acks[i]) continue;
            uint64_t got = 0, want = 0;
            switch (i) {
                case 0: got = dut->mrom_q; want = be16(PROG_B + p.addr * 2); break;
                case 1: got = dut->srom_q; want = rom[SND_B + p.addr]; break;
                case 2: got = dut->pcm_q;  want = rom[PCM_B + p.addr]; break;
                case 3: got = dut->tile_q; want = be32(TILE_B + p.addr * 4); break;
                default: got = dut->spr_q; want = be64(SPR_B + p.addr * 8); break;
            }
            checked++; mixed++;
            if (got != want) fail(p.name, p.addr, got, want);
            if (p.wait > p.worst) p.worst = p.wait;
            p.done++; p.busy = false; p.gap = 1 + rnd() % 24;
        }
    }
    dut->mrom_req = dut->srom_req = dut->pcm_req = dut->tile_req = dut->spr_req = 0;
    for (int i = 0; i < 64; i++) tick();
    printf("mixed, %ld clocks, all ports at once: %ld reads, %ld wrong; worst wait (clocks):",
           MIXCLK, mixed, bad - mixed_bad0);
    for (auto &p : ports) printf(" %s %ld", p.name, p.worst);
    printf("\n");
    printf("SDRAM: %ld reads checked through the core's ports, %ld wrong\n", checked, bad);

    // ---- SRAM: write a pattern with byte enables, read it back
    long sbad = 0;
    const uint32_t step = quick ? 61 : 1;
    auto vram = [&](bool we, uint32_t a, uint16_t d, int ben) {
        dut->vram_we = we; dut->vram_addr = a; dut->vram_din = d; dut->vram_ben = ben; dut->vram_req = 1;
        int g = 0; while (!dut->vram_ack && g++ < 4000) tick();
        dut->vram_req = 0; tick();
        return (uint16_t)dut->vram_q;
    };
    for (uint32_t a = 0; a < 32768; a += step) vram(true, a, uint16_t(a * 0x9E37 + 0x1234), 3);
    for (uint32_t a = 0; a < 32768; a += step) if (vram(false, a, 0, 3) != uint16_t(a * 0x9E37 + 0x1234)) sbad++;
    vram(true, 5, 0xFFFF, 3); vram(true, 5, 0x00AB, 1);            // low byte only
    if (vram(false, 5, 0, 3) != 0xFFAB) { sbad++; printf("  sram byte enables: got %04X want FFAB\n", dut->vram_q); }
    printf("SRAM:  %ld wrong\n", sbad);

    delete dut;
    if (bad || sbad) { printf("FAIL  what came back is not what was sent\n"); return 1; }
    printf("PASS  every region reads back byte-for-byte\n");
    return 0;
}
