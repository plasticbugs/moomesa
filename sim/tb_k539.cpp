// Replay bench for rtl/k054539.sv: the Z80's writes to the chip, logged from
// MAME by tools/log_k054539.lua with the 48 kHz sample each landed in, applied
// to the RTL at the same sample, the sample ROM answered from the image after
// a fixed latency.  Writes the chip's own output (MAME's lval/rval before the
// board's routing) as a WAV, and reports the pass budget.
//
//   obj_k539/Vk054539 moomesa.rom k539.log [-secs S] [-wav out.wav] [-lat N]
#include "Vk054539.h"
#include "Vk054539___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::string romp, logp, wavp;
    double secs = 5; int lat = 12;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-secs") secs = atof(argv[++i]);
        else if (a == "-wav") wavp = argv[++i];
        else if (a == "-lat") lat = atoi(argv[++i]);
        else if (a[0] == '+') continue;
        else if (romp.empty()) romp = a; else logp = a;
    }
    std::vector<uint8_t> rom(0xD40080);
    FILE *rf = fopen(romp.c_str(), "rb");
    if (!rf || fread(rom.data(), 1, rom.size(), rf) != rom.size()) { fprintf(stderr, "cannot read %s\n", romp.c_str()); return 2; }
    fclose(rf);
    struct W { long s; int a, d; };
    std::vector<W> log;
    FILE *lf = fopen(logp.c_str(), "r");
    if (!lf) { fprintf(stderr, "cannot read %s\n", logp.c_str()); return 2; }
    long s; unsigned a, d;
    while (fscanf(lf, "%ld %x %x", &s, &a, &d) == 3) log.push_back({s, int(a), int(d)});
    fclose(lf);

    Vk054539 *dut = new Vk054539;
    int rcnt = -1; bool served = false;
    auto tick = [&]() {
        dut->clk = 0; dut->eval();
        dut->rom_ack = 0;
        if (!dut->rom_req) { rcnt = -1; served = false; }
        else if (!served) {
            if (rcnt < 0) rcnt = lat;
            if (--rcnt == 0) { dut->rom_ack = 1; dut->rom_q = rom[0xA00000 + (dut->rom_addr & 0x1fffff)]; served = true; }
        }
        dut->clk = 1; dut->eval();
    };
    dut->rst = 1; dut->cs = 0; dut->we = 0; dut->re = 0; dut->cen_snd = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->rst = 0;
    long nsamp = long(secs * 48000), li = 0;
    std::vector<int16_t> wav;
    long clip = 0;
    for (long smp = 0; smp < nsamp; smp++) {
        // this sample's writes, each between two passes as in MAME
        while (li < (long)log.size() && log[li].s <= smp) {
            while (dut->busy) tick();
            dut->cs = 1; dut->we = 1; dut->addr = log[li].a; dut->din = log[li].d; tick();
            dut->we = 0; dut->cs = 0; tick();
            li++;
        }
        dut->cen_snd = 1; tick(); dut->cen_snd = 0;
        for (int c = 1; c < 2000; c++) {
            tick();
            if (c == 1999 && dut->busy) {
                auto *r = dut->rootp;
                fprintf(stderr, "sample %ld: pass still running, state %d channel %d\n", smp,
                        r->k054539__DOT__ps, r->k054539__DOT__ch);
                delete dut; return 1;
            }
        }
        static unsigned lastw = 0;
        if (dut->worst != lastw) { fprintf(stderr, "sample %ld: worst pass now %u (reads %u)\n", smp, dut->worst, dut->worst_reads); lastw = dut->worst; }
        int l = dut->out_l, r = dut->out_r;
        l = (l << 14) >> 14; r = (r << 14) >> 14;                  // sign-extend 18 bits
        if (l > 32767 || l < -32768 || r > 32767 || r < -32768) clip++;
        wav.push_back(int16_t(l > 32767 ? 32767 : l < -32768 ? -32768 : l));
        wav.push_back(int16_t(r > 32767 ? 32767 : r < -32768 ? -32768 : r));
    }
    printf("%ld samples, %ld writes replayed, worst pass %u clocks (%u ROM reads), overrun %d, %ld samples beyond 16 bits\n",
           nsamp, li, dut->worst, dut->worst_reads, dut->overrun, clip);
    if (!wavp.empty()) {
        FILE *w = fopen(wavp.c_str(), "wb");
        uint32_t n = wav.size() * 2;
        auto u32 = [&](uint32_t v) { fwrite(&v, 4, 1, w); };
        auto u16 = [&](uint16_t v) { fwrite(&v, 2, 1, w); };
        fwrite("RIFF", 1, 4, w); u32(36 + n); fwrite("WAVEfmt ", 1, 8, w);
        u32(16); u16(1); u16(2); u32(48000); u32(48000 * 4); u16(4); u16(16);
        fwrite("data", 1, 4, w); u32(n); fwrite(wav.data(), 2, wav.size(), w); fclose(w);
    }
    delete dut;
    return 0;
}
