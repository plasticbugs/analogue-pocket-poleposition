# Sound board

Pole Position's audio is four separate circuits summed into four cabinet
speakers:

| source | rate | what it is |
|---|---|---|
| Namco WSG (8 voices, 4 outputs) | 192 kHz internal, 48 kHz out | the music and jingles |
| engine sound generator | 24 kHz | 16 KB of engine waveforms, pitch and volume from two Z80 registers, through three op-amp filter sections |
| 54xx discrete (3 channels) | 48 kHz | R1 ladder DACs into multiple-feedback band-passes: tyre screech, crash |
| 52xx discrete (1 channel) | 48 kHz | R1 ladder DAC, 100 Hz high-pass, 1200 Hz low-pass, halved and clamped: the voice samples |

The four discrete channels (CHANL1..4) do not go to the speakers directly: a
4051 feeds the one a voice selects into that WSG voice, and they reach the
speakers through its volume controls.

Everything here reproduces **MAME 0.288**: `namco.cpp`'s `polepos_wsg_device`,
`polepos_a.cpp`'s `polepos_sound_device` and the `polepos_discrete` netlist,
including the parts of those that are models rather than circuits (the op-amp
rail clipping, the DAC ladder tables, the filter coefficient maths) -- with one
deliberate exception, the routing of the discrete channels, where MAME departs
from the board and the core follows the board (see *Mixing*). A `mame_mix`
input restores MAME's routing so every comparison against MAME still holds.

## Modules

| file | what it does |
|---|---|
| `rtl/pp_sound.sv` | rate generation, the three blocks, the four-channel mix, the stereo fold and DC blocker |
| `rtl/pp_wsg.sv` | 8 voices, the register file the Z80 reads back, the 32-tap decimation FIR |
| `rtl/pp_engine.sv` | engine ROM playback, MAME's integer phase-step arithmetic, three filter sections |
| `rtl/pp_discrete.sv` | the 54xx and 52xx DAC-plus-filter chains |
| `rtl/pp_biquad.sv` | one 32x32 multiplier walking a chain of biquad sections |
| `rtl/pp_snd_coeffs.svh` | every coefficient and table, generated |
| `tools/sound/gen_coeffs.py` | generates the above from MAME's formulas, plus the C++ header the reference model uses |

`wsg_rdata` is **combinational** (the register file is registers, not block
RAM), so a Z80 read needs no wait state. `audio_ce` pulses once per 48 kHz
output sample; `audio_l`/`audio_r` are signed 16-bit at MAME's scale, where
1.0 of a MAME stream sample = 32768.

## Rates

All derived from the 49.152 MHz system clock by one counter:

* 192 kHz (every 256 clocks) — WSG internal stream, exactly MAME's
  `m_namco_clock` of 4 x the chip's 48 kHz clock, with 17 fractional phase bits;
* 48 kHz (1024) — discrete circuits and the output sample rate;
* 24 kHz (2048) — engine, which is MAME's `OUTPUT_RATE` for that stream.

The WSG's 192 kHz sum is decimated with a 32-tap Hamming-windowed sinc (20 kHz
cutoff) rather than point-sampled, so nothing above 24 kHz folds back. The
engine's 24 kHz stream is linearly interpolated to 48 kHz. Both choices are
matched exactly in the reference model, so the RTL can be held to it sample by
sample.

## Fixed point

* filter and signal values: **signed Q26** volts in 32 bits (range +-32 V,
  resolution 1.5e-8 V);
* coefficients: **signed Q30** in 32 bits;
* products 64-bit, accumulated 67-bit, rounded back to Q26 once per section.

Coefficient precision turned out to be what matters, not state precision. The
54xx band-pass sections have poles at a radius of about 0.9975 (Q ~ 2 at 74 Hz),
which makes them extremely sensitive to coefficient quantisation:

| coefficient format | worst error vs the reference model, discrete path |
|---|---|
| Q24 | 4.5 mV |
| Q30 | 0.14 mV |

In output terms the Q30 figure is about 2 LSB of a 16-bit sample, and the whole
board (WSG + engine + discrete + mix) tracks the reference model to
**1.0-2.2 LSB peak, 0.3-0.5 LSB RMS**.

## The MAME engine-filter quirk

`polepos_sound_device::filter2_context::setup()` designs the three engine
filter sections with `machine().sample_rate()` — 48 kHz by default — while the
engine stream actually runs at `OUTPUT_RATE` = 24 kHz. Every corner frequency
therefore lands at **half** its design value in a real MAME run:

| section | designed | as MAME actually steps it |
|---|---|---|
| band-pass 1 | 150.4 Hz, d 0.543 | 75.2 Hz |
| band-pass 2 | 425.6 Hz, d 0.482 | 212.8 Hz |
| high-pass 3 | 950 Hz, d 1.414 | 475 Hz |

The core reproduces **MAME's behaviour**, not the circuit's intent: MAME is the
oracle everything else in this core is verified against, and a recording of a
real Pole Position cabinet to arbitrate with was not available. The choice is
one flag:

```sh
tools/sound/gen_coeffs.py --engine-rate 48000   # MAME-identical (default)
tools/sound/gen_coeffs.py --engine-rate 24000   # the circuit's intended corners
```

Regenerating changes only `rtl/pp_snd_coeffs.svh` and the model's header, so
the two stay consistent either way.

## Mixing and the stereo fold

The machine config routes each WSG output to one speaker channel at 0.80 and
the engine to **all four** channels at 0.90 x 0.77. Those two are unchanged.

### The discrete channels: the board, not MAME

`namco.cpp`'s header describes the board: *"a 4051 multiplexes wavetable sound
with four signals derived from the 52XX and 54XX, the selected signal is
distributed to four volume control sections, and finally the engine noise is
mixed into all four channels."* A voice whose register `ch*4+0x23` has bit 3
set plays CHANL(bits 1:0 + 1) in place of its waveform, at its four volumes.

MAME does not model that. It silences such a voice and routes all four
discrete outputs to every speaker at 0.90 x `DISCRETE_OUTPUT(node, 32767/2)`,
whatever the volumes say. Logging the WSG registers in MAME shows what the game
asks for: two voices sit on CHANL1 and CHANL2 at volume 15 on all four
speakers from boot, both switch to CHANL4 for "prepare to qualify" and back,
and CHANL3 is never selected. The service-mode sound test measures the result
(`tools/sound/sound_levels.py`, DC-removed RMS of the left output):

| test sound | MAME | core, MAME routing | core, board routing |
|---|---|---|---|
| 1-16 (WSG) | 27-1,183, peaks to 3,243 | 27-1,177 | identical |
| 17 (54xx) | 11,158, peak 28,811 | 11,115 | 1,097, peak 2,799 |
| 18 (54xx: tyre squeal) | 11,031, peak 32,187 | 11,452 | 1,118, peak 3,339 |
| 19, 20 (52xx: voice) | 4,143 / 3,384 | 3,744 / 3,232 | 612 / 631, peaks 3,546 / 3,272 |

MAME's routing puts the squeal about 20 dB above every other sound on the
board and 15 dB above the engine, which is what made it painful in play. With
the board's routing it lands level with the loudest WSG sounds, peak for peak.
In the scripted race (`tb_system -script play`) the same holds: the 54xx burst
at 5-7 s goes from 11,100 to 1,080 RMS, the voice at 15 s from 4,040 to 760,
and every second without them (music, engine) is unchanged.

To mix a volt of CHANL against WSG sample codes the core needs the waveform
DAC's scale. It is a 4.7K/2.2K/1K/470 ladder driven by an LS273, so its 15
codes span the latch's high level; that level is taken as the same unmeasured
4 V MAME assumes for the 54xx/52xx ladders, i.e. 3.75 codes per volt. One code
at one volume step is 1/1024 of a stream sample (`MIX_RES`), then the WSG's
0.80 route:

```
speaker k += CHANL_c x (sum of volume k of every voice selecting c) x 3.75 / 1024 x 0.80
```

`pp_wsg` reports the summed volume steps per speaker and channel
(`route_vol`, refreshed every 192 kHz tick, zero while the WSG is disabled);
`pp_sound`'s single multiplier walks the 16 products and four gains after the
WSG and engine terms. The constant is `GAIN_ROUTE` in `gen_coeffs.py`; if a
recording of a real board ever shows the level off, that one number moves.

### The fold

The cabinet has four speakers (front pair, rear pair) and the Pocket has two,
so the fold is the average of front and rear on each side:

```
L = (front_left + rear_left) / 2      R = (front_right + rear_right) / 2
```

That preserves the level of the engine (identical on all four) and averages
the pans. `dbg_spk0..3` expose the four pre-fold channels, which is what the
bench compares against MAME.

A one-pole DC blocker at ~3.7 Hz sits on each output. The discrete circuits sit
at a rail when idle (DAC code 0 is -2 V through an inverting stage), so without
it the standing offset would eat about 0.9 of full scale and thump on mute.
MAME's `-wavwrite` is taken **before** its speaker effect chain (`output_push`
copies the speaker's input stream into the record buffer), so its recordings
keep that offset; every comparison below is DC-removed.

### Cabinet reverb and speaker box (Pocket option)

`rtl/pp_reverb.sv`, after the fold, is not the board: Punch-Out!!'s three
damped comb filters (29.7, 37.1, 41.1 ms) fed the mid signal, with one wet tail
under both channels so the stereo image is kept. Off by default; Light,
Medium and Heavy in the Interact menu. `sim/tb_reverb.cpp` checks the dry path
is untouched with it off, the first echo lands on the 1,426th sample, the tail
is identical left and right and a full-scale square stays bounded.

Each reverb level also closes the output down, the way the speakers in a
wooden cabinet lose the top end. That reuses the Pocket framework's own output
IIR (`platform/pocket/audio`), whose preset table was compiled in but unused:
`core_top.sv` selects its second-order "8k", "6k" and "4k" low-passes for
Light, Medium and Heavy and the framework default for Off. The presets were
designed for a 7.056 MHz filter rate but run at 6.144 MHz on the Pocket, so
their real corners are lower than their names. `sim/run_cabfilter.sh` measures
them on the framework RTL at the Pocket's audio clock (dB relative to 1 kHz):

| level | 3 kHz | 5 kHz | 8 kHz | 10 kHz | level at 1 kHz |
|---|---|---|---|---|---|
| Off | -0.1 | -0.2 | -0.5 | -0.8 | -0.24 dB |
| Light | -0.2 | -1.2 | -4.9 | -8.0 | -1.69 dB |
| Medium | -0.5 | -2.9 | -8.7 | -12.5 | -1.59 dB |
| Heavy | -2.1 | -7.5 | -15.2 | -19.3 | -1.54 dB |

The presets lose about 1.4 dB of level against Off, which the reverb's wet
signal roughly makes back.

## How MAME records this machine

`-wavwrite` produces a **4-channel** 48 kHz wav: `sound_manager::start_recording`
opens it with `m_outputs_count` channels, and polepos has two 2-channel speakers
(`speaker` front, `rspeaker` rear). Channels are in speaker order: front L,
front R, rear L, rear R. No speaker effects are applied to it, although MAME's
default effect chain does include a 20 Hz high-pass for what it plays.

## Verification

### 1. Against a C++ transcription of MAME's DSP

`sim/sound/pp_snd_ref.h` is MAME's own arithmetic in double precision: the WSG
voice loop with its counter-freeze rule, `polepos_sound_device`'s stream update
with the three clipped sections, and the discrete nodes with the op-amp
band-pass state rule. The benches drive it and the RTL with identical stimulus
and compare every 48 kHz sample.

```sh
sim/run_sound.sh 40000                 # whole board, pseudo-random stimulus, board routing
build/sim_sound/tb_sound build/polepos.rom 40000 --mame-mix    # the same, MAME's routing
build/sim_engine/tb_engine build/polepos.rom 8000 0x2a 0x15    # engine alone
build/sim_disc/tb_disc 20000 60                                # discrete alone
```

| bench | result |
|---|---|
| whole board, 40,000 samples, nibbles changing every ~60 samples, board routing | max 1.18 LSB, RMS 0.30 LSB |
| the same, nibbles every ~5 | max 2.17 LSB, RMS 0.30 LSB |
| the same, MAME routing | max 1.59 LSB, RMS 0.29 LSB |
| RTL in one routing, model in the other (mutation check) | max 45,312 LSB: the bench sees the routing |
| whole board, nibbles every ~400 | max 1.03 LSB, RMS 0.31 LSB |
| whole board, nibbles every ~4000 | max 2.21 LSB, RMS 0.50 LSB |
| engine alone, several msb/lsb settings, 8000 samples | max 1.0e-6 V (0.02 LSB) |
| discrete alone, 20,000 samples, nibbles every ~60 | max 1.4e-4 V (2 LSB) |

The discrete residue is dominated by op-amp rail clipping: when the 54xx
sections saturate, a difference of one quantisation step decides whether a
given sample clips, and the resulting state difference decays over the
section's ~8 ms time constant. The error tracks the number of clipped samples
(139 clipped samples -> 0.37 mV, 4 clipped -> 0.04 mV), which is inherent to
matching a hard nonlinearity in different arithmetic, not a modelling
difference.

### 2. Against MAME itself

`tools/sound/sndlog.lua` logs every Z80 write that reaches the sound hardware
with its emulated time, while MAME records its own audio:

```sh
cd build/sound
PP_OUT=attract.log PP_SECONDS=20 PP_SCRIPT=attract \
  mame polepos -rompath ../.. -video none -nothrottle -skip_gameinfo \
    -samplerate 48000 -wavwrite attract.wav -autoboot_script ../../tools/sound/sndlog.lua
cd ../.. && sim/run_replay.sh build/sound/attract.log build/sound/attract.wav 20
python3 tools/sound/compare_audio.py build/sound/rtl.wav build/sound/attract.wav 10.2 13.8
```

`tb_replay` places each write on the 49.152 MHz clock its timestamp falls on,
so the stimulus is sample-accurate rather than quantised to output samples. It
runs the core with `mame_mix` set, since it is compared with MAME.

| window | what is playing | RTL / MAME RMS | band ratios (100-300, 300-800, 0.8-2k, 2-5k, 5-8k Hz) |
|---|---|---|---|
| attract 10.2-13.8 s | WSG only (4 voices) | 1.002 (+0.01 dB) | 1.00 1.00 1.00 1.01 0.93 |
| play 20-23 s | engine | 0.999 (-0.01 dB) | 1.00 1.00 0.99 0.96 1.28 |
| play 27-30 s | engine | 0.999 (-0.01 dB) | 1.00 1.00 0.99 0.97 1.76 |
| play 36-39 s | engine | 0.999 (-0.01 dB) | 1.00 1.00 0.99 0.98 0.44 |

The 5-8 kHz column is noise: the engine sound has almost no energy there, so
the ratio of two tiny numbers swings wildly. Everything that carries energy
matches within 1-4%.

The 52xx and 54xx nibble streams come from the MCUs, and MAME offers no way to
tap a device's internal port writes from Lua, so this replay cannot drive
those paths. They are covered end to end instead by the whole-machine
comparison in `docs/verification.md` §5: the full core running a scripted game
through the real custom MCU programs, recorded against MAME's own recording of
the same game, including the voice and the skid and crash noise.

Also not covered: MAME's own resampler. Its 192 kHz -> 48 kHz and
24 kHz -> 48 kHz conversions are a windowed-sinc polyphase resampler; this core
uses a 32-tap FIR and linear interpolation. That is the likely source of the
few-percent differences in the top band.

### 3. Lint and synthesis

```sh
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PROCASSINIT \
  -Wno-UNUSEDPARAM +incdir+rtl rtl/pp_ram.sv rtl/pp_biquad.sv rtl/pp_wsg.sv \
  rtl/pp_engine.sv rtl/pp_discrete.sv rtl/pp_sound.sv --top-module pp_sound
docker run --rm --platform linux/amd64 -v "$PWD":/build -w /build/build/sound/quartus \
  raetro/quartus:pocket quartus_map --read_settings_files=on snd.qpf -c snd
```

Lint is clean. Quartus 18.1, 5CEBA4F23C8, synthesis only:

| resource | used |
|---|---|
| registers | 3,419 |
| block memory | 133,888 bits (engine ROM 16 KB, waveform PROM, FIR history) |
| DSP blocks | 19 of 66 |

The DSP count is driven by the 32x32 multiplies. If integration needs them
back, dropping the coefficients to Q26 (27 bits) halves the multiplier width at
the cost of about 8x the discrete-path error (1.1 mV, ~16 LSB peak) — one
parameter in `gen_coeffs.py`.
