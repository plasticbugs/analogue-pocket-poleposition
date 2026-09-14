# Pole Position hardware

What the core reproduces, from MAME 0.288's `polepos.cpp` / `polepos_v.cpp` /
`polepos_a.cpp` (kept under `ref/mame/`, gitignored) and from measurement. The
MAME set is `polepos` (World), which uses the `poleposa` input definitions.

## 1. Clocks

| | |
|---|---|
| Crystal | 24.576 MHz |
| Dot clock | 6.144 MHz (÷4) |
| Z80, Z8002 ×2 | 3.072 MHz (÷8) |
| MB88xx MCUs | 1.536 MHz (÷16), 6 clocks per instruction → 256 kHz |
| 06xx base | 48 kHz (÷512) |
| ADC0804 | 384 kHz (÷64) |
| WSG | 48 kHz sample clock (÷512) |

The core runs one 49.152 MHz clock (2× crystal) and derives all of these as
clock enables, so every rate is exact (`docs/interfaces.md`).

## 2. Raster

384 × 264, visible x 0..255, y 16..239; 60.606 Hz. `vcount` in the core is
MAME's `vpos()` = bitmap row. Events keyed to it:

| row | event |
|---|---|
| 64, 192 | Z80 IRQ (64V) when IRQON (latch 0) is set; IRQON low clears it |
| 128 | READY bit 1 (128V) changes; palette bank for background/road vs sprites |
| 240 | Z8002 NVI to both CPUs when the shared NVI mask is set; vblank start (51xx TC, watchdog count) |
| 16 | vblank end |

## 3. Z80 memory map

| address | | |
|---|---|---|
| 0000-2FFF | ROM | pp3_9.6h, pp1_10b.5h |
| 3000-37FF (mirror 0800) | battery RAM, 2K | all ones from the factory |
| 4000-47FF | sprite RAM, low byte | shared with Z8002s |
| 4800-4BFF | road RAM, low byte | " |
| 4C00-4FFF | alpha RAM, low byte | " |
| 5000-57FF | view RAM, low byte | " |
| 8000-83BF (mirror 0C00) | sound work RAM | |
| 83C0-83FF (mirror 0C00) | WSG registers | |
| 9000 (mirror 0EFF) | 06xx data | |
| 9100 (mirror 0EFF) | 06xx control | |
| A000 read | READY | bit 0 +5V, 1 = !128V, 2 PWRUP (1), 3 ADC /INTR (0 = conversion done) |
| A000-A007 write (mirror 0CF8) | LS259 latch, bit = A[2:0], value = D0 | |
| A100 write | watchdog kick | 16 vblanks without one resets the board |
| A200 write | engine sound LSB | bit 0 enable, bits 5:1 pitch low |
| A300 write | engine sound MSB | bits 5:0 pitch high; bits 5:3 also choose sample bank and volume |
| I/O port 0 | ADC0804 | write starts a 74-clock conversion, read returns it and clears INTR |

Interrupt mode 1 (the ROM executes `IM 1`); the acknowledge cycle reads 0xFF.

### LS259 at 8E

| bit | name | |
|---|---|---|
| 0 | IRQON | Z80 IRQ enable and acknowledge |
| 1 | IOSEL | 1 = customs run, 0 = all four MCUs held in reset |
| 2 | CLSON | sound enable: WSG on, engine latches cleared when 0 |
| 3 | GASEL | ADC input: 1 accelerator, 0 brake |
| 4 | RESB | 1 = Z8002 #1 runs |
| 5 | RESA | 1 = Z8002 #2 runs |
| 6 | SB0 | start line: read back as IN0 bit 2 (verified in MAME: bit 2 = SB0) |
| 7 | CHACL | alpha layer uses full colour and the code MSB |

## 4. Z8002 memory map (both CPUs)

| address | | |
|---|---|---|
| 0000-3FFF | ROM, 8K words | #1: pp3_2.8l even bytes, pp3_1.8m odd; #2: pp3_6.4l, pp3_5.4m |
| 4000-7FFF | reads 0 (MAME's ERASE00 region) | |
| 6000-7FFF write | NVI enable, bit 0 | one mask shared by both CPUs; writing 0 clears the writer's NVI line |
| 8000-8FFF | sprite RAM | 0x380-0x3FF position words, 0x780-0x7FF size/code words |
| 9000-97FF | road RAM | 0x000-0x1FF palette per line, 0x380-0x3FF x offset per line |
| 9800-9FFF | alpha RAM | 32×32 words |
| A000-AFFF | view RAM | 64×16 words used |
| C000 (mirror 38FE) write | VHP background x scroll | |
| C100 (mirror 38FE) write | RVP road vertical position | |

Words are big-endian: the even address holds the high byte. The Z80 sees the
low byte of each shared word only.

## 5. Video (`rtl/pp_video.sv`, spec `tools/ppvideo.py`)

Layer order: background tiles (rows < 128), road (rows ≥ 128), 64 sprites in
table order, alpha text on top where its colour PROM entry is not 15.

* **Background**: 64×16 tiles, column-major, 8×8 2bpp from pp1_29; word =
  `{-, code8, color[5:0], code[7:0]}`; x scroll mod 512. Colour PROM pp1-11.
* **Road**: for each row y ≥ 128: `yoffs = ((vpos_prom[y] + RVP) >> 3) & 0x1ff`
  indexes road RAM for the 4-bit palette; road RAM 0x380 + (y & 0x7f) gives a
  10-bit x offset; the road ROMs (pp1_30 control/start value, pp1_31 and pp1_32
  step bits) are walked in 8-pixel chunks accumulating a 6-bit value; bit 9 of
  the offset blanks a chunk to value 0. Colour PROM pp1-12.
* **Sprites**: position words `{Y[8:0]}` and `{X[9:0]}`; size words
  `{big, -, sizey[5:0], flipx, code[6:0]}` and `{-, -, sizex[5:0], -, -, color[5:0]}`.
  sx = X − 60, sy = 513 − Y (one line late: MAME's "buffered" comment). Vertical
  zoom through pp1_27 (`scale[(y << 6) + sizey] & 0x1f`, halved for 16×16),
  horizontal zoom by a 6-bit accumulator advancing x when it passes 64. Only
  rows 16..239 drawn; colour PROM pp3-6, pen 15 transparent; color bit 6 set
  below row 128 selects the lower palette bank (identical colours).
* **Alpha**: 32×32, row-major, 8×8 2bpp from pp3_28; colour PROM pp2-10; rows
  ≥ 128 use bank 0x60 (identical to 0x20); pen 15 transparent.
* **Palette**: 128 colours through pp1-7/8/9, 2.2k/1k/470/220 Ω ladder
  (weights 0x0e, 0x1f, 0x43, 0x8f).

Line budget: 3072 clocks per line; the heaviest line in 70 captured states
took 1792 (attract-mode grid of 27 sprites). `dbg_overrun` latches if a line
ever fails to finish.

## 6. Inputs

IN0 (active low): 7 service mode, 6 service credit, 5 coin 2, 4 coin 1,
2 start (= SB0), 1 gear (0 = HI), 0 unused. Read by the 51xx as two nibbles.

DSWA (World, factory 0xFF): 7:5 coin A, 4:3 coin B, 2:1 game time, 0 laps.
DSWB (factory 0x74): 7:5 practice rank, 4:2 extended rank, 1 speed unit
(0 = mph), 0 demo sounds (0 = on). DSWA is read by the 53xx, DSWB by the 51xx.

Steering: the 53xx polls two lines through `steering_changed_r` /
`steering_delta_r`: each poll consumes one count of accumulated wheel movement
(twice the 8-bit position delta) and reports direction. Pedals: ADC0804 reads
0x00..0x90 from the selected pedal.

## 7. Sound

See `docs/sound.md`. Sources: the 8-voice, 4-output WSG (waveforms in
pp1-5.3b), the engine sample player (pp1_15/16, pitch from A200/A300), the
54xx's three 4-bit noise outputs and the 52xx's 4-bit voice DAC, each through
the discrete filters of `polepos_a.cpp`.

## 8. Customs

See `docs/namco_customs.md`. 06xx at 48 kHz base clock with the Z80's NMI as
its handshake; 51xx (coins, credits, IN0/DSWB), 52xx (voice samples from
pp2_11/12/13 — the fourth socket is empty and reads 0), 53xx (steering, DSWA),
54xx (explosion / screech noise). All four are MB8843/MB8844 MCUs running
their real 1K programs (`51xx.bin` … `54xx.bin`).
