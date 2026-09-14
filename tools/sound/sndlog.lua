-- Log every Z80 write that reaches the sound hardware, with its emulated time,
-- so the RTL can be driven with exactly the same stimulus MAME had.
--
--   PP_OUT=build/sound/attract.log PP_SECONDS=20 PP_SCRIPT=play \
--   mame polepos -autoboot_script tools/sound/sndlog.lua ...
--
-- Format: one line per event, "<seconds> <kind> <a> <b>"
--   w <offset 0-3f> <data>   WSG register
--   l <data>                 engine lsb (0xa200)
--   m <data>                 engine msb (0xa300)
--   c <0|1>                  LS259 Q2 (CLSON)
local OUT     = os.getenv("PP_OUT") or "sndlog.txt"
local SECONDS = tonumber(os.getenv("PP_SECONDS") or "20")
local SCRIPT  = os.getenv("PP_SCRIPT") or "attract"

local mach = manager.machine
local z80  = mach.devices[":maincpu"].spaces["program"]
local ports = mach.ioport.ports
local f = assert(io.open(OUT, "w"))

local function now() return mach.time.seconds + mach.time.attoseconds / 1e18 end

-- Handles must be globals or the taps are garbage collected away.
tap_snd = z80:install_write_tap(0x8000, 0x8fff, "snd", function(offset, data, mask)
    -- 0x8000-0x83ff mirrored at 0x8c00; the sound registers are 0x83c0-0x83ff
    if (offset & 0xf3ff) >= 0x83c0 then
        f:write(string.format("%.9f w %02x %02x\n", now(), offset & 0x3f, data & 0xff))
    end
end)
tap_eng = z80:install_write_tap(0xa000, 0xafff, "eng", function(offset, data, mask)
    local sel = offset & 0x0f00
    if sel == 0x0200 then
        f:write(string.format("%.9f l %02x 00\n", now(), data & 0xff))
    elseif sel == 0x0300 then
        f:write(string.format("%.9f m %02x 00\n", now(), data & 0xff))
    elseif (offset & 0xf300) == 0xa000 and (offset & 7) == 2 then
        f:write(string.format("%.9f c %02x 00\n", now(), data & 1))
    end
end)

local coin  = ports[":IN0"] and ports[":IN0"].fields["Coin 1"]
local accel = ports[":ACCEL"] and ports[":ACCEL"].fields["P1 Pedal 1"]
local frame = 0
frame_sub = emu.register_frame_done(function()
    frame = frame + 1
    if SCRIPT == "play" then
        -- the boot self-test has to finish before a coin is taken
        if coin then coin:set_value((frame >= 600 and frame < 606) and 1 or 0) end
        if accel then accel:set_value(frame >= 700 and 0x90 or 0) end
    end
    if frame > SECONDS * 60.6 then
        f:close()
        print("[pp] sound log done at frame " .. frame)
        mach:exit()
    end
end)
print("[pp] sndlog armed, script " .. SCRIPT)
