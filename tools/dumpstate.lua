-- Dump Pole Position machine states plus MAME's snapshot of each, at a list
-- of frames, from one MAME run.
--
-- No freeze is needed here, unlike Time Pilot: polepos never forces a partial
-- screen update, so MAME renders the whole frame once at vblank from whatever
-- the video memories hold at that instant, and register_frame_done runs at that
-- same instant before any CPU executes again. The memories read in the
-- callback are therefore exactly the ones the snapshot was drawn from.
--
-- The scroll registers and CHACL are write-only, so they are tracked with
-- write taps from power-on.
--
-- usage:
--   PP_FRAMES="300 900" PP_OUT=artifacts PP_SCRIPT=attract \
--     mame polepos -autoboot_script tools/dumpstate.lua ...
--
-- PP_SCRIPT selects the input schedule (see schedule() below).

local OUT    = os.getenv("PP_OUT") or "artifacts"
local SCRIPT = os.getenv("PP_SCRIPT") or "attract"
local frames = {}
local last = 0
for f in string.gmatch(os.getenv("PP_FRAMES") or "600", "%d+") do
    frames[tonumber(f)] = true
    if tonumber(f) > last then last = tonumber(f) end
end

local mach  = manager.machine
local sub1  = mach.devices[":sub1"].spaces["program"]
local sub2  = mach.devices[":sub2"].spaces["program"]
local z80   = mach.devices[":maincpu"].spaces["program"]
local ports = mach.ioport.ports

local hscroll, vscroll, chacl = 0, 0, 0
local latch = 0

-- Z8002 map: 0xc000-0xc001 mirror 0x38fe -> hscroll, 0xc100 mirror -> vscroll.
-- Both CPUs can write them; MAME's COMBINE_DATA honours the mask.
local function scroll_tap(offset, data, mask)
    if (offset & 0xc000) == 0xc000 then
        local sel = (offset >> 8) & 7
        if sel == 0 then
            hscroll = (hscroll & ~mask) | (data & mask)
        elseif sel == 1 then
            vscroll = (vscroll & ~mask) | (data & mask)
        end
    end
end
-- Tap handles are globals on purpose: a handle that is garbage collected is a
-- tap that is silently removed.
tap_hs1 = sub1:install_write_tap(0xc000, 0xffff, "hs1", scroll_tap)
tap_hs2 = sub2:install_write_tap(0xc000, 0xffff, "hs2", scroll_tap)
-- LS259 at 0xa000-0xa007 mirror 0x0cf8: bit n of the latch = data bit 0
tap_latch = z80:install_write_tap(0xa000, 0xafff, "latch", function(offset, data, mask)
    if (offset & 0xf300) == 0xa000 then
        local bit = offset & 7
        if (data & 1) == 1 then latch = latch | (1 << bit) else latch = latch & ~(1 << bit) end
        chacl = (latch >> 7) & 1
    end
end)

local function field(port, name)
    local p = ports[port]
    return p and p.fields[name] or nil
end
local coin  = field(":IN0", "Coin 1")
local gear  = field(":IN0", "Gear Change")
local accel = field(":ACCEL", "P1 Pedal 1")
local brake = field(":BRAKE", "P1 Pedal 2")
local steer = field(":STEER", "Dial")

local function hold(f, v) if f then f:set_value(v) end end

-- Input schedules. Frames are MAME frames counted from power-on.
local function schedule(frame)
    if SCRIPT == "attract" then
        return
    elseif SCRIPT == "play" then
        hold(coin, (frame >= 600 and frame < 606) and 1 or 0)
        -- accelerator down from 700, with the wheel swung back and forth
        hold(accel, frame >= 700 and 0x90 or 0)
        if frame >= 900 then
            local phase = (frame // 90) % 4
            hold(steer, ((phase == 1) and (frame * 3) or ((phase == 3) and (-frame * 3)) or 0) & 0xff)
        end
    end
end

local frame = 0

local function dump(tag)
    local f = assert(io.open(string.format("%s/state_%s.txt", OUT, tag), "w"))
    f:write(string.format("frame %d\n", frame))
    f:write(string.format("hscroll %04x\nvscroll %04x\nchacl %d\n", hscroll, vscroll, chacl))
    local function region(name, base, words)
        f:write(name, "\n")
        local line = {}
        for i = 0, words - 1 do
            line[#line + 1] = string.format("%04x", sub1:read_u16(base + 2 * i))
            if #line == 16 then f:write(table.concat(line), "\n"); line = {} end
        end
        if #line > 0 then f:write(table.concat(line), "\n") end
    end
    region("SPRITE", 0x8000, 0x800)
    region("ROAD",   0x9000, 0x400)
    region("ALPHA",  0x9800, 0x400)
    region("VIEW",   0xa000, 0x800)
    f:write("END\n")
    f:close()
    mach.video:snapshot()
    print(string.format("[pp] dumped %s (frame %d)", tag, frame))
end

-- global for the same reason as the taps: a collected subscription stops firing
frame_sub = emu.register_frame_done(function()
    frame = frame + 1
    schedule(frame)
    if frames[frame] then dump(string.format("%s%05d", SCRIPT:sub(1, 1), frame)) end
    -- the snapshot is written on the following frame, so run one more
    if frame > last then print("[pp] done at frame " .. frame); mach:exit() end
end)

print("[pp] dumpstate.lua armed, script " .. SCRIPT)
