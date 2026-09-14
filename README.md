# Pole Position for Analogue Pocket

An openFPGA core for **Pole Position** (Namco, 1982), reimplementing the arcade
hardware: a Z80 and two Zilog Z8002s, four Fujitsu MB88xx custom MCUs running
their original programs (the Namco 51xx, 52xx, 53xx and 54xx), the road
generator, 64 zoomed sprites, the 8-voice wave synthesiser, the engine sample
player and the analogue filters behind the noise and voice chips.

The whole 188 KB romset fits in block RAM, so there is no SDRAM in the design —
every access is single cycle and deterministic.

> **ROMs are not included and never will be.** You supply your own MAME
> `polepos` romset; the core reads one image built from it.

## Installing

1. Copy `Cores/`, `Platforms/` and `Assets/` from the release zip onto the root
   of the Pocket's SD card.
2. Build the ROM image from your own romset and copy it to
   `Assets/poleposition/common/polepos.rom`:

   ```sh
   python3 mra_build.py polepos.mra polepos.zip
   ```

   The builder needs nothing but Python 3. It reads the MAME zip (or a
   directory of loose files) directly, checks every ROM's CRC32, and verifies
   the finished image against a known md5, so a wrong or bad romset is
   reported rather than silently built into something that half works.

   The four custom MCU programs (`51xx.bin` … `54xx.bin`) are MAME *device*
   ROMs. A merged or non-merged `polepos.zip` normally carries them; a split set
   keeps them in `namco51.zip` … `namco54.zip`, in which case name those too:

   ```sh
   python3 mra_build.py polepos.mra polepos.zip namco51.zip namco52.zip namco53.zip namco54.zip
   ```

   Already using `pupdate` or the standard `mra` tool? Point it at
   `polepos.mra`; it is an ordinary MRA file.

## Controls

The cabinet has a steering wheel, two pedals and a two-position gear lever.
There is no start button: insert a coin and press the accelerator.

| | |
|---|---|
| Steer | D-pad left / right, or a dock controller's analog stick |
| Accelerate | A (or R) |
| Brake | B (or L) |
| Gear | X or Y toggles; D-pad up = HI, down = LO |
| Insert coin | Select or Start |

The cabinet's wheel is an optical encoder — the game responds to how fast it
turns — so the D-pad turns it at a steady rate that doubles after half a second
held, and an analog stick turns it faster the further it is pushed.
**Steering Sensitivity** (Low, Medium, High) scales both; Medium is the
default.

DIP switches — game time, laps, coinage, practice and extended rank, mph or
km/h, demo sounds — and service mode are in the Pocket's Interact menu, along
with the screen shape, cabinet reverb and steering sensitivity.

## The screen

256×224 at 60.606 Hz, horizontal. **Screen Shape** offers the cabinet's 4:3
(default) or **Fill Screen**, which stretches the picture to the whole panel,
edge to edge and top to bottom.

## Sound

All four cabinet speaker channels are generated and folded to stereo (front
and rear of each side averaged). The tyre squeal, crash and voice are mixed the
way the board mixes them — through the wave synthesiser's volume controls —
rather than the way MAME does, which plays them about 20 dB too loud; see
`docs/sound.md`.

**Cabinet Reverb** (Off, Light, Medium, Heavy) puts the sound back in a
cabinet: a short, dark room around the whole mix, and a low-pass that closes in
with each step (−3 dB at 7 kHz, 5.2 kHz, 3.5 kHz) for the boxed-in speakers.
It is not part of the original hardware, and is off by default.

## How it is verified

Everything is checked against MAME, treated as a program to interrogate rather
than a reference to read — see `docs/verification.md` for the gates and their
current results, and `docs/hardware.md` for what the core reproduces.

## Building

`./build-local.sh map` runs Quartus analysis and synthesis in Docker (a couple
of minutes; catches what Verilator cannot); `./build-local.sh` does the full
compile and packages `release/pocket/`. CI does the same on every push.

## Credits

* Built on the [OpenGateware](https://github.com/opengateware) Pocket
  platform framework.
* Z80: [tv80](https://github.com/hutch31/tv80) (MIT).
* Hardware knowledge: the MAME `polepos` driver by Ernesto Corvi, Juergen
  Buchmueller, Alex Pasadyn, Aaron Giles and Nicola Salmoria, and the Namco
  custom MCU work by Aaron Giles and Mike Harris.

Pole Position is a trademark of its owners. This project is not affiliated
with Namco or Bandai Namco.
