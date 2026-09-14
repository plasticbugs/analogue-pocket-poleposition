// Frozen-state video bench.
//
//   tb_video <polepos.rom> <state.txt> <out.ppm>
//
// Loads the ROM image through the download port, pokes the dumped video
// memories into the RAM models, runs two frames and writes the visible
// 256x224 of the second as a PPM. Fails if the line renderer ever overran.
#include "Vtb_video_top.h"
#include "Vtb_video_top__Dpi.h"
#include "verilated.h"
#include "svdpi.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

static Vtb_video_top *top;

static void tick() {
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: tb_video rom state out.ppm\n"); return 2; }
    Verilated::commandArgs(argc, argv);
    top = new Vtb_video_top;
    svSetScope(svGetScopeFromName("TOP.tb_video_top"));

    top->reset = 1;
    for (int i = 0; i < 8; i++) tick();

    // ROM through the download port
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    std::vector<unsigned char> rom;
    int c;
    while ((c = fgetc(f)) != EOF) rom.push_back((unsigned char)c);
    fclose(f);
    for (size_t a = 0; a < rom.size(); a++) {
        top->dl_addr = a; top->dl_data = rom[a]; top->dl_we = 1;
        tick();
    }
    top->dl_we = 0;

    // state dump: words per region
    std::ifstream in(argv[2]);
    if (!in) { perror(argv[2]); return 2; }
    std::string line;
    int region = -1, idx = 0;
    unsigned hscroll = 0, vscroll = 0, chacl = 1;
    while (std::getline(in, line)) {
        if (line.empty() || line == "END") continue;
        if (line.rfind("hscroll ", 0) == 0) { hscroll = strtoul(line.c_str() + 8, 0, 16); continue; }
        if (line.rfind("vscroll ", 0) == 0) { vscroll = strtoul(line.c_str() + 8, 0, 16); continue; }
        if (line.rfind("chacl ", 0) == 0)   { chacl = strtoul(line.c_str() + 6, 0, 10); continue; }
        if (line.rfind("frame", 0) == 0) continue;
        if (line == "VIEW")   { region = 0; idx = 0; continue; }
        if (line == "ALPHA")  { region = 1; idx = 0; continue; }
        if (line == "ROAD")   { region = 2; idx = 0; continue; }
        if (line == "SPRITE") { region = 3; idx = 0; continue; }
        for (size_t p = 0; p + 4 <= line.size(); p += 4) {
            int v = (int)strtoul(line.substr(p, 4).c_str(), 0, 16);
            tb_poke(region, idx++, v);
        }
    }
    top->hscroll = hscroll; top->vscroll = vscroll; top->chacl = chacl;

    top->reset = 1;
    for (int i = 0; i < 16; i++) tick();
    top->reset = 0;

    std::vector<unsigned char> img(256 * 224 * 3, 0);
    int frames_done = 0, row = -1, col = 0;
    int prev_v = 0;
    long guard = 0;
    while (frames_done < 2 && guard++ < 20000000) {
        bool was_cen = top->cen_pix;
        tick();
        if (!was_cen) continue;
        if (top->vcount == 0 && prev_v != 0) frames_done++;
        prev_v = top->vcount;
        if (frames_done == 1 && top->de) {
            // outputs lag the counters by one dot; count rows by de edges
            if (col == 0 && row < 0) row = 0;
            if (row >= 0 && row < 224) {
                int o = (row * 256 + col) * 3;
                img[o] = top->red; img[o + 1] = top->green; img[o + 2] = top->blue;
            }
            if (++col == 256) { col = 0; row++; }
        }
    }

    FILE *o = fopen(argv[3], "wb");
    fprintf(o, "P6\n256 224\n255\n");
    fwrite(img.data(), 1, img.size(), o);
    fclose(o);
    printf("rows %d, worst line %u clocks, overrun %d\n", row, top->dbg_line_clocks, top->dbg_overrun);
    int bad = (row != 224) || top->dbg_overrun;
    delete top;
    return bad;
}
