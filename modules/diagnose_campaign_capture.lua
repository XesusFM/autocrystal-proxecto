-- Route Campaign capture-memory diagnostic (English Crystal USA/Europe only).
--
-- HOW TO USE:
-- 1. Back up your save and load Crystal in BizHawk.
-- 2. Load this file directly in the Lua Console (not through launcher.lua).
-- 3. Enter a disposable wild battle, open PACK, switch to the Balls pocket,
--    highlight a Master Ball, and complete one test capture manually.
-- 4. Confirm the console shows pocket=1, selection=1, the Master Ball count
--    decreases by one, wWildMon matches the species, and wTempWildMonSpecies
--    returns to zero when the battle ends.
--
-- This script never presses buttons and never writes memory or files.

local VERSION_ADDR = 0x0141
local REGION_ADDR = 0x0142
local function read_byte(address)
    return memory.readbyte(address)
end

local A = {
    battleMode = 0xD22D,
    enemySpecies = 0xD22E,
    battleCursorY = 0xCFA9,
    battleCursorX = 0xCFAA,
    packState = 0xCF64,
    pocket = 0xCF65,
    menuSelection = 0xCF74,
    numBalls = 0xD8D7,
    balls = 0xD8D8,
    partyCount = 0xDCD7,
    captureLatch = 0xC64E,
    mapGroup = 0xDCB5,
    mapNumber = 0xDCB6,
    y = 0xDCB7,
    x = 0xDCB8,
}

local version = read_byte(VERSION_ADDR)
local region = read_byte(REGION_ADDR)
if version ~= 0x54 or region ~= 0x45 then
    error(string.format("Unsupported ROM: expected English Crystal 0x54/0x45, got 0x%02X/0x%02X", version, region))
end

local function ball_summary()
    local count = read_byte(A.numBalls)
    if count > 12 then return "INVALID(" .. tostring(count) .. ")" end
    local entries = {}
    for index = 0, count - 1 do
        local item = read_byte(A.balls + index * 2)
        local quantity = read_byte(A.balls + index * 2 + 1)
        table.insert(entries, string.format("%d:%d", item, quantity))
    end
    return table.concat(entries, ",")
end

local previous = nil
while true do
    emu.frameadvance()
    local line = string.format(
        "battleMode=%d tempWildSpecies=%d cursor=%d/%d packInitState=%d pocket=%d selection=%d balls=[%s] party=%d wWildMon=%d map=%d/%d X=%d Y=%d",
        read_byte(A.battleMode), read_byte(A.enemySpecies),
        read_byte(A.battleCursorY), read_byte(A.battleCursorX),
        read_byte(A.packState), read_byte(A.pocket), read_byte(A.menuSelection),
        ball_summary(), read_byte(A.partyCount), read_byte(A.captureLatch),
        read_byte(A.mapGroup), read_byte(A.mapNumber),
        read_byte(A.x), read_byte(A.y))
    if line ~= previous then
        print(line)
        previous = line
    end
end
