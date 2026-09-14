-- MAME side of the full-system comparison: run the same input schedule as
-- sim/tb_system.cpp and, at the end of the given frame, dump every memory the
-- game state lives in plus the snapshot, in the format tools/diff_state.py
-- compares.
--
--   PP_FRAME=1200 PP_SCRIPT=play PP_OUT=build/sys mame polepos -autoboot_script tools/dumpsys.lua ...

local OUT    = os.getenv("PP_OUT") or "build/sys"
local SCRIPT = os.getenv("PP_SCRIPT") or "attract"
local frames, TARGET = {}, 0
for f in string.gmatch(os.getenv("PP_FRAMES") or os.getenv("PP_FRAME") or "600", "%d+") do
    frames[tonumber(f)] = true
    if tonumber(f) > TARGET then TARGET = tonumber(f) end
end

local mach  = manager.machine
local sub1  = mach.devices[":sub1"].spaces["program"]
local z80   = mach.devices[":maincpu"].spaces["program"]
local ports = mach.ioport.ports

local hscroll, vscroll, latch = 0, 0, 0
local function scroll_tap(offset, data, mask)
    if (offset & 0xc000) == 0xc000 then
        local sel = (offset >> 8) & 7
        if sel == 0 then hscroll = (hscroll & ~mask) | (data & mask)
        elseif sel == 1 then vscroll = (vscroll & ~mask) | (data & mask) end
    end
end
-- globals: a collected tap handle is a removed tap
tap_hs1 = sub1:install_write_tap(0xc000, 0xffff, "hs1", scroll_tap)
tap_hs2 = mach.devices[":sub2"].spaces["program"]:install_write_tap(0xc000, 0xffff, "hs2", scroll_tap)
tap_latch = z80:install_write_tap(0xa000, 0xafff, "latch", function(offset, data, mask)
    if (offset & 0xf300) == 0xa000 then
        local bit = offset & 7
        if (data & 1) == 1 then latch = latch | (1 << bit) else latch = latch & ~(1 << bit) end
    end
end)

local function field(port, name) local p = ports[port]; return p and p.fields[name] or nil end
local coin  = field(":IN0", "Coin 1")
local accel = field(":ACCEL", "P1 Pedal 1")
local steer = field(":STEER", "Dial")
local function hold(f, v) if f then f:set_value(v) end end

local function schedule(frame)
    if SCRIPT == "play" then
        hold(coin, (frame >= 600 and frame < 606) and 1 or 0)
        hold(accel, frame >= 700 and 0x90 or 0)
        if frame >= 900 then
            local phase = (frame // 90) % 4
            hold(steer, ((phase == 1) and (frame * 3) or ((phase == 3) and (-frame * 3)) or 0) & 0xff)
        end
    end
end

local frame = 0
local function dump()
    local f = assert(io.open(string.format("%s/mame_%s%05d.txt", OUT, SCRIPT:sub(1, 1), frame), "w"))
    f:write(string.format("frame %d\nhscroll %04x\nvscroll %04x\nlatch %02x\n", frame, hscroll, vscroll, latch))
    local function region16(name, base, words)
        f:write(name, "\n")
        local line = {}
        for i = 0, words - 1 do
            line[#line + 1] = string.format("%04x", sub1:read_u16(base + 2 * i))
            if #line == 16 then f:write(table.concat(line), "\n"); line = {} end
        end
    end
    local function region8(name, base, n)
        f:write(name, "\n")
        local line = {}
        for i = 0, n - 1 do
            line[#line + 1] = string.format("%02x", z80:read_u8(base + i))
            if #line == 32 then f:write(table.concat(line), "\n"); line = {} end
        end
    end
    region16("SPRITE", 0x8000, 0x800)
    region16("ROAD",   0x9000, 0x400)
    region16("ALPHA",  0x9800, 0x400)
    region16("VIEW",   0xa000, 0x800)
    region8("Z80RAM", 0x8000, 0x400)
    region8("NVRAM",  0x3000, 0x800)
    f:write("END\n")
    f:close()
    if frame == TARGET then mach.video:snapshot() end
    print(string.format("[pp] dumped frame %d", frame))
end

frame_sub = emu.register_frame_done(function()
    frame = frame + 1
    schedule(frame)
    if frames[frame] then dump() end
    if frame > TARGET then print("[pp] done at frame " .. frame); mach:exit() end
end)
