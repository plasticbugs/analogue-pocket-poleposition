# How this core is checked

Every gate compares against MAME 0.288, treated as a program to interrogate
rather than a reference to read. Cheapest first.

## 1. Reference renderer — `tools/render_model.py`

`tools/ppvideo.py` transcribes `polepos_v.cpp` together with the parts of
MAME's gfx decode, tilemap and indirect palette it depends on.
`tools/capture_states.sh` drives MAME to a spread of frames and dumps the four
video memories, the scroll registers and CHACL plus a snapshot of each.

Current status: **0 differing pixels on all 15 captured states** (8 attract,
7 gameplay).

Two MAME traps, both of which silently produce wrong captures:

* Lua tap handles and the `register_frame_done` subscription must be **global**
  variables. A collected handle removes its tap or callback, and MAME then runs
  on or exits early with status 0. The capture script therefore checks for the
  script's own completion line instead of the exit status.
* Snapshots need `-snapview native`; the default composites the cabinet's gear
  indicator artwork over the bottom right of the picture.

## 2. Frozen-state video bench — `sim/run_video.sh`

Loads the ROM image and a state dump into `rtl/pp_video.sv` in Verilator,
renders a frame and diffs it against MAME's snapshot.

Current status: **0 differing pixels on 70 states** (the 15 above plus 55
gameplay frames from a longer run). The bench fails if the line renderer ever
overruns; the heaviest line seen took 1792 of its 3072 clocks
(`tools/sprite_load.py` measures the load from dumps).

## 3. CPU cores in lockstep with MAME's own code

Both CPU cores are compared, instruction by instruction, against MAME's C++
compiled into the testbench through a small shim, each side with its own
memory. See `docs/z8002.md` and `docs/namco_customs.md` for commands.

| core | campaigns | result |
|---|---|---|
| Z8002 | every first word × random state; 12M+ random instructions with interrupts; both game ROMs 3M instructions each; PC sequence of the real machine followed for 584,431 instructions | 0 divergences |
| MB88xx | every opcode × 20k states; 100M random cycles; all four custom ROMs 9M cycles each; 16/16 planted faults caught | 0 mismatches |
| 06xx + customs | 39.6 s of MAME's recorded Z80↔06xx traffic replayed | NMI train identical edge for edge (77,550 edges); 10–14 of 69,790 reads differ, all at input edges within the log's input timing resolution |

## 4. Full-system bench — `sim/run_system.sh`, `tools/regress_system.sh`

Boots the game on the real CPUs with a scripted input schedule and compares
every memory the game state lives in — Z80 work RAM, NVRAM, the four shared
video memories, scroll registers, latch — plus the picture, against MAME at
the same frame (`tools/dumpsys.lua`, `tools/diff_state.py`).

### Frame alignment: measured, three times

Getting "frame N" to mean the same instant on both sides took three
measurements, each of which overturned an assumption:

1. **`frame_done` runs at N × 264 lines.** Logging `manager.machine.time` in
   the callback gives exactly 264, 528, 792 … lines.
2. **MAME's raster is at vpos 240 at time zero.** Logging the Z80's IRQ
   acknowledges gave 88.4 and 216.4 lines into each period — 24 lines after
   rows 64 and 192. With the core's raster starting at row 0, every
   raster-timed event (Z80 IRQ, Z8002 NVI, 128V) was 24 lines early relative
   to the CPUs; boot matched only because nothing raster-timed happens in the
   first seconds. `rtl/pp_video.sv` now leaves reset at row 240, and the bench
   dumps at the start of row 240, which is MAME's `frame_done` instant.
3. With both fixed the skew is **zero**: RTL frame N is MAME frame N. After
   the fix, the handshake events (Z80 releasing each Z8002, each Z8002
   clearing its ready flag, the Z80 noticing) land within 1 line of MAME's
   times, 71 frames of boot later, and the IRQ acknowledges within 0.07 lines.

### Two real bugs the comparison found

Both in the pedal ADC, both invisible in attract mode, both found only
because whole-machine state was compared against MAME rather than eyeballed.

1. **READY bit 3 polarity.** It is the ADC0804's active-low /INTR pin
   (`if (!intr_r()) ret ^= 0x08`); the core had it active high. The ROM at
   0x0206 waits for 0, so every pedal read ran into its 20-poll timeout. Found
   as a persistent GASEL difference in the latch at frame 246, traced to the
   routine.
2. **ADC clock at half rate.** The 384 kHz enable came from an 8-bit counter
   compared against 127, which wraps at 256: conversions took twice as long.
   The game still mostly worked — it polled 15 times instead of MAME's 7 — but
   whenever a conversion missed the 20-poll timeout the routine skipped its
   GASEL flip, the accelerator/brake pairing swapped, and at the start of the
   race the game read the brake floored and the car sat still for a second.
   Found as the scripted race diverging at frame 1130 (sprite RAM 0x004/0x005
   holding the pedals in swapped slots).

### Current status

Attract mode, no inputs:

| check | result |
|---|---|
| boot, frames 2–236 | every memory identical except single RAM-test words caught mid-write |
| frames 900 and 1500: picture | **0 differing pixels** |
| frames 900 and 1500: road / alpha / view RAM, NVRAM, latch, scroll | identical |
| frames 900 and 1500: Z80 work RAM | identical outside the stack page (0x82E0–0x82FF) |
| frames 900 and 1500: sprite RAM | 18 entries: Z8002 work variables and stack, see below |

A scripted game (coin at frame 600, accelerator floored from 700, wheel swung
from 900 — `tools/dumpsys.lua` and `sim/tb_system.cpp` share the schedule),
compared every 10 frames through frame 1800:

| check | result |
|---|---|
| road position (RVP) through the race | within 4 units of MAME's at every sample |
| frame 1800 picture | 254 of 57,344 pixels: one score digit, a few pixels of road and billboard |
| Z80 RAM | one byte, 0x8104 (a value the Z80 fetches through the 06xx and copies to 0x4006), one count apart |

The race is the same race; the residual is the same one-step scheduling
difference as attract mode, now visible because the game state moves.

### What is not expected to match, and why

* **The Z80 stack page** below SP: stale call-depth leftovers that depend on
  exactly where inside an instruction each side stops.
* **Z8002 work variables one update step apart** (sprite RAM 0x088–0x094,
  0x37E, and the Z8002 stack at 0x760–0x77F). The three CPUs talk through
  shared RAM. MAME runs them in timeslices bounded by its next timer (about a
  scanline here), in device order — Z80, then Z8002 #1, then #2 — so a write
  by #2 is not seen by #1 until the next slice. On the board, and in the core,
  they run concurrently. A handshake the game polls (e.g. the Z80's timeout
  loop at 0x0EA4 waiting for a Z8002 through 0x4048) can therefore resolve a
  step differently. The picture and every other memory agree, which is the
  behavioural check that matters.
* **Z80 NMI acceptance one instruction apart.** tv80 needs /NMI about two CPU
  clocks before the end of an instruction; MAME accepts it up to the end (and
  its timeslices can overshoot the edge). Traced in the Z80's LDIR at 0x200B:
  identical instruction paths, NMI taken one iteration later.

## 5. Audio

See `docs/sound.md` for the sound board in isolation: the WSG and engine replay
MAME's recorded Z80 writes and match its recordings within 0.01 dB; the
52xx/54xx discrete paths match a transcription of MAME's DSP to about 2 LSB.

End to end, through the real 52xx/54xx MCUs: the scripted game above recorded
on both sides (`sim/tb_system.cpp -mamemix -wav`, MAME `-wavwrite` folded to
stereo by `tools/sound/fold4.py`), compared with `tools/sound/compare_audio.py`.
`-mamemix` gives the core MAME's routing of the discrete channels; the Pocket
build uses the board's, which MAME does not model (`docs/sound.md`, *Mixing*):

| window | playing | RTL / MAME RMS | bands 100 Hz – 5 kHz |
|---|---|---|---|
| 5–9.5 s | attract | −0.03 dB | 0.94–1.01 |
| 11–14 s | coin, start | +0.04 dB | 1.00–1.02 |
| 14–18.5 s | "prepare to qualify" voice, countdown | −0.94 dB | 1.00–1.01 |
| 19–23 s | engine, race | −0.08 dB | 0.98–1.04 |
| 23–27 s | engine, skid | 0.00 dB | 0.98–1.02 |
| 27–29.5 s | engine, crash | +0.12 dB | 0.98–1.02 |

The one −0.94 dB window is sub-audio: MAME's recording carries a DC step of
about 2,400 while the voice plays (the discrete stages' idle offset moving),
which the core's 3.7 Hz DC blocker removes on purpose. The 20–60 and 60–100 Hz
bands in that window match at 0.99 and 1.00; only 0.5–20 Hz differs.

## 6. Lint — `sim/lint.sh`

Verilator `-Wall` over `rtl/` and `target/pocket/core_top.sv`; findings in our
files fail the run, findings in vendored `modules/` and `platform/` do not.
Current status: clean.

## 7. Synthesis — `./build-local.sh`

Quartus 18.1, 5CEBA4F23C8, full compile of the Pocket core:

| resource | used | available |
|---|---|---|
| Logic (ALMs) | 17,908 | 18,480 (97%) |
| Registers | 10,709 | |
| Block memory | 1,894,308 bits | 3,153,920 (60%) |
| RAM blocks | 250 | 308 (81%) |
| DSP blocks | 33 | 66 (50%) |

Timing closes on every clock and corner: worst setup slack +0.562 ns on the
49.152 MHz system clock (slow 85C), worst hold +0.097 ns. The first compile
missed by 1.04 ns; the three Z8002 paths responsible and their fixes are in
`docs/z8002.md` §6, each re-verified in lockstep with MAME before recompiling.

The biggest consumers are the two Z8002s (~4,850 ALMs each), the sound board
(~2,860, of which the mixer's own logic is ~880 and the WSG ~740), the four
MCUs (~2,100) and the cabinet reverb (~350). Adding the reverb and the board's
routing of the discrete channels took the device from 92% to 97%. If headroom
is needed later: the MCUs run one instruction per 192 clocks and could share a
single datapath; the reverb's three combs could share one adder chain; and the
routed channels could replace the waveform sample inside the WSG's own voice
loop (which is what the 4051 does) instead of adding 20 steps to the mixer.

## 8. What still needs a Pocket

* Screen shape and the scaler's aspect handling (two presets in the menu).
* Artwork colour order (drawn in greys until confirmed).
* Controls feel: steering rate and pedal travel are synthesised from the pad.
* The watchdog and video overrun flags on real hardware.
