-- Record everything the Z80 does to and sees from the Namco 06xx, with exact
-- emulated time, so the RTL 06xx + customs can be replayed against it
-- (sim/namco/tb_replay.cpp).
--
--   mame polepos -rompath <dir> -video none -sound none -nothrottle \
--        -skip_gameinfo -cfg_directory <tmp> -nvram_directory <tmp> \
--        -autoboot_script sim/namco/capture.lua
--
-- env: NC_OUT (log file), NC_FRAMES (frames to run)
--
-- Log format, one event per line, time as sys clock ticks at 49.152 MHz
-- (floor(t * 49152000), exact from MAME's attotime):
--   W <tick> D|C <byte>      Z80 write to the 06xx data / control port
--   R <tick> D|C <byte>      Z80 read, with the value MAME returned
--   L <tick> <bit> <d>       LS259 latch write (bit 1 = IOSEL)
--   N <tick>                 Z80 fetched 0x0066 (NMI entry)
--   I <tick> <in0> <dswa> <dswb> <steer>   input ports (logged on change)
--   F <tick> <frame>         frame done
local OUT    = os.getenv("NC_OUT") or "build/namco/capture.txt"
local FRAMES = tonumber(os.getenv("NC_FRAMES") or "2400")

local m    = manager.machine
local cpu  = m.devices[":maincpu"]
local sp   = cpu.spaces["program"]
local P    = m.ioport.ports
local log  = assert(io.open(OUT, "w"))
local function tick() return m.time:as_ticks(49152000) end

local last_in = ""
local function log_inputs()
    local s = string.format("%d %d %d %d", P[":IN0"]:read(), P[":DSWA"]:read(), P[":DSWB"]:read(), P[":STEER"]:read())
    if s ~= last_in then
        log:write(string.format("I %d %s\n", tick(), s))
        last_in = s
    end
end

-- tap handles must stay referenced or the garbage collector removes the taps
TAPS = {}
TAPS[#TAPS + 1] = sp:install_write_tap(0x9000, 0x9fff, "nc_w", function(offset, data, mask)
    log:write(string.format("W %d %s %d\n", tick(), ((offset & 0x100) ~= 0) and "C" or "D", data & 0xff))
end)
TAPS[#TAPS + 1] = sp:install_read_tap(0x9000, 0x9fff, "nc_r", function(offset, data, mask)
    log_inputs()
    log:write(string.format("R %d %s %d\n", tick(), ((offset & 0x100) ~= 0) and "C" or "D", data & 0xff))
    return data
end)
TAPS[#TAPS + 1] = sp:install_write_tap(0xa000, 0xafff, "nc_l", function(offset, data, mask)
    if (offset & 0x0300) == 0 then
        log:write(string.format("L %d %d %d\n", tick(), offset & 7, data & 1))
        log_inputs()
    end
end)
TAPS[#TAPS + 1] = sp:install_read_tap(0x0066, 0x0066, "nc_nmi", function(offset, data, mask)
    local pc = cpu.state["PC"].value
    if pc == 0x66 or pc == 0x67 then log:write(string.format("N %d\n", tick())) end
    return data
end)

local coin  = P[":IN0"].fields["Coin 1"]
local gear  = P[":IN0"].fields["Gear Change"]
local accel = P[":ACCEL"].fields["P1 Pedal 1"]
local steer = P[":STEER"].fields["Dial"]
local frame = 0
local steer_pos = 0

-- NC_SCENARIO=fast (default) exercises the inputs hard: a short coin pulse and a
-- wheel that moves every frame. NC_SCENARIO=slow holds every input steady for
-- whole seconds at a time, so that the replay does not depend on the few
-- milliseconds of resolution the log has on when an input actually changed.
local SLOW = os.getenv("NC_SCENARIO") == "slow"

emu.register_frame_done(function()
    frame = frame + 1
    -- scripted play: coin, accelerate (the game starts itself from the pedal),
    -- then drive with the wheel swinging back and forth and a gear change
    if SLOW then
        coin:set_value((frame >= 600 and frame < 700) and 1 or 0)
        accel:set_value((frame >= 800) and 0x90 or 0)
        if frame >= 1000 and frame % 120 == 0 then
            steer_pos = (steer_pos + 8) & 0xff
            steer:set_value(steer_pos)
        end
        gear:set_value((frame >= 1200 and frame < 1500) and 1 or 0)
    else
    coin:set_value((frame >= 600 and frame < 606) and 1 or 0)
    accel:set_value((frame >= 700) and 0x90 or 0)
    if frame >= 800 then
        local phase = (frame // 90) % 4
        local d = (phase == 0) and 3 or (phase == 2) and -3 or ((phase == 1) and 1 or -1)
        steer_pos = (steer_pos + d) & 0xff
        steer:set_value(steer_pos)
    end
    gear:set_value((frame >= 1200 and frame < 1500) and 1 or 0)
    end
    log_inputs()
    log:write(string.format("F %d %d\n", tick(), frame))
    if frame >= FRAMES then
        log:close()
        m:exit()
    end
end)
