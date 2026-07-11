-- Shared Wild encounter engine.
--
-- Wild Encounters and Route Campaign consume the same movement, encounter,
-- battle-menu, fleeing, and Master Ball primitives from this module.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. script_dir .. "../?.lua;" .. package.path

local Mem = require("data.memory")
local PokemonNames = require("data.pokemon_names")
local ItemNames = require("data.item_names")

local Controller = {}
Controller.__index = Controller

-- These are the same English Crystal addresses used by wild.lua, plus the
-- documented pack variables required for the new capture path.
local ADDR = {
    ROM_VERSION = 0x0141,
    ROM_REGION = 0x0142,
    ENEMY_DVS = 0xD20C,              -- wEnemyMonDVs
    BATTLE_MODE = 0xD22D,            -- wBattleMode; 1 = wild battle
    ENEMY_SPECIES = 0xD22E,          -- wTempWildMonSpecies (wild.lua sentinel)
    ENEMY_ITEM = 0xD207,             -- wEnemyMonItem
    PARTY_COUNT = 0xDCD7,            -- wPartyCount
    MENU_BORDER_TOP = 0xCF82,        -- wMenuBorderTopCoord
    MENU_BORDER_LEFT = 0xCF83,       -- wMenuBorderLeftCoord
    MENU_CURSOR_Y = 0xCFA9,          -- wMenuCursorY
    MENU_CURSOR_X = 0xCFAA,          -- wMenuCursorX
    JUMPTABLE_INDEX = 0xCF63,        -- wJumptableIndex
    PACK_STATE = 0xCF64,             -- wPackJumptableIndex (pocket init state)
    CUR_POCKET = 0xCF65,             -- wCurPocket
    PACK_USED_ITEM = 0xCF66,         -- wPackUsedItem
    MENU_SELECTION = 0xCF74,         -- wMenuSelection (selected item id)
    ITEM_EFFECT_SUCCEEDED = 0xD0EC,  -- wItemEffectSucceeded
    CUR_ITEM = 0xD106,               -- wCurItem
    NUM_BALLS = 0xD8D7,              -- wNumBalls
    BALLS = 0xD8D8,                  -- wBalls
    CAPTURED_WILD_MON = 0xC64E,      -- wWildMon; species on successful catch
    MAP_GROUP = 0xDCB5,
    MAP_NUMBER = 0xDCB6,
    Y_COORD = 0xDCB7,
    X_COORD = 0xDCB8,
    MOVEMENT_FLAG = 0xD4DD,
}

local LOAD_BATTLE_MENU = Mem.BankAddressToLinear(0x9, 0x4EF2)
local ENEMY_WILDMON_INITIALIZED = Mem.BankAddressToLinear(0xF, 0x7648)
local ENGLISH_CRYSTAL_REGION = 0x45
local MASTER_BALL_ID = 1
local BALL_POCKET = 1
local MAX_BALL_TYPES = 12
local BALLS_MENU_TOP = 1
local BALLS_MENU_LEFT = 7
local ITEM_SUBMENU_TOP = 7
local ITEM_SUBMENU_LEFT = 13
local ITEM_SUBMENU_USE_CURSOR_Y = 1
local PACK_CURSOR = {y = 2, x = 1}
local RUN_CURSOR = {y = 2, x = 2}
local FIGHT_CURSOR = {y = 1, x = 1}
local REQUIRED_OVERWORLD_STABLE_FRAMES = 10
local MOVEMENT_IDLE_VALUE = 0xFF

function M.get_rom_config(version, region)
    local western = region == 0x44 or region == 0x45 or region == 0x46
        or region == 0x49 or region == 0x53
    if version == 0x54 then
        if western then
            return {
                enemyAddr = 0xD20C,
                loadBattleMenu = Mem.BankAddressToLinear(0x9, 0x4EF2),
                enemyInitialized = Mem.BankAddressToLinear(0xF, 0x7648),
                learnMove = Mem.BankAddressToLinear(0x10, 0x64C5),
                partyBase = 0xDCD7,
                romBankName = "Crystal",
            }
        elseif region == 0x4A then
            return {
                enemyAddr = 0xD23D,
                loadBattleMenu = Mem.BankAddressToLinear(0x9, 0x4EF2),
                enemyInitialized = Mem.BankAddressToLinear(0xF, 0x7648),
                learnMove = Mem.BankAddressToLinear(0x10, 0x64C5),
                partyBase = 0xDC9D,
                romBankName = "Crystal",
            }
        end
    elseif version == 0x55 or version == 0x58 then
        local enemy
        if western then enemy = 0xDA22
        elseif region == 0x4A then enemy = 0xD9E8
        elseif region == 0x4B then enemy = 0xDB1F end
        if enemy ~= nil then
            return {
                enemyAddr = enemy,
                loadBattleMenu = Mem.BankAddressToLinear(0x9, 0x4E62),
                enemyInitialized = Mem.BankAddressToLinear(0xF, 0x73C5),
                partyBase = enemy,
                romBankName = "Gold",
            }
        end
    end
    return nil
end

-- Campaign now follows the original modules and reads the English ROM's
-- System Bus addresses directly.  Do not add SVBK switching here: it created
-- a second memory model that disagreed with the working wild.lua flow.
local function read_byte(address)
    return memory.readbyte(address)
end

function M.configure_memory()
    return true, "hook-driven lifecycle with bounded stable System Bus confirmations"
end

M.read_byte = read_byte

local function pokemon_name(id)
    return PokemonNames[id] or ("Unknown #" .. tostring(id))
end

local function item_name(id)
    return ItemNames[id] or ("Unknown Item #" .. tostring(id))
end

local function is_shiny(atkdef, spespc)
    if spespc ~= 0xAA then return false end
    return atkdef == 0x2A or atkdef == 0x3A or atkdef == 0x6A or atkdef == 0x7A
        or atkdef == 0xAA or atkdef == 0xBA or atkdef == 0xEA or atkdef == 0xFA
end

-- Copied from wild.lua.  joypad.set applies to the next frame; the final
-- frameadvance is the neutral buffer that separates consecutive presses.
local function cancellation_requested(should_cancel)
    return should_cancel ~= nil and should_cancel()
end

local function press_button(button, should_cancel)
    local input = {[button] = true}
    for _ = 1, 4 do
        if cancellation_requested(should_cancel) then
            joypad.set({})
            return false
        end
        joypad.set(input)
        emu.frameadvance()
    end
    joypad.set({})
    if cancellation_requested(should_cancel) then return false end
    emu.frameadvance()
    return not cancellation_requested(should_cancel)
end

M.press_button = press_button

local function wait_frames(count, should_cancel)
    for _ = 1, count do
        if cancellation_requested(should_cancel) then
            joypad.set({})
            return false
        end
        emu.frameadvance()
    end
    return not cancellation_requested(should_cancel)
end

local function cursor_is_battle_menu()
    local y = read_byte(ADDR.MENU_CURSOR_Y)
    local x = read_byte(ADDR.MENU_CURSOR_X)
    return (y == 1 or y == 2) and (x == 1 or x == 2)
end

-- Copied from wild.lua: always derive the next direction from the actual
-- cursor rather than assuming its previous position.
local function navigate_to_menu_option(target)
    local y = read_byte(ADDR.MENU_CURSOR_Y)
    local x = read_byte(ADDR.MENU_CURSOR_X)
    if y == target.y and x == target.x then
        return "A"
    elseif y < target.y then
        return "Down"
    elseif y > target.y then
        return "Up"
    elseif x < target.x then
        return "Right"
    end
    return "Left"
end

M.navigate_to_menu_option = navigate_to_menu_option

local function press_and_wait_for_cursor_change(button, timeout, is_active)
    local previous_y = read_byte(ADDR.MENU_CURSOR_Y)
    local previous_x = read_byte(ADDR.MENU_CURSOR_X)
    if not press_button(button, function() return is_active ~= nil and not is_active() end) then
        return false
    end
    local frames = 0
    while read_byte(ADDR.MENU_CURSOR_Y) == previous_y
        and read_byte(ADDR.MENU_CURSOR_X) == previous_x
        and frames < timeout
        and (is_active == nil or is_active()) do
        emu.frameadvance()
        frames = frames + 1
    end
    return is_active == nil or is_active()
end

M.press_and_wait_for_cursor_change = press_and_wait_for_cursor_change

local function master_ball_count()
    local count = read_byte(ADDR.NUM_BALLS)
    if count > MAX_BALL_TYPES then
        return nil, "Balls pocket count is invalid: " .. tostring(count)
    end
    local total = 0
    for index = 0, count - 1 do
        local item = read_byte(ADDR.BALLS + index * 2)
        local quantity = read_byte(ADDR.BALLS + index * 2 + 1)
        if item == MASTER_BALL_ID then total = total + quantity end
    end
    return total
end

local function overworld_position()
    return {
        mapGroup = read_byte(ADDR.MAP_GROUP),
        mapNumber = read_byte(ADDR.MAP_NUMBER),
        x = read_byte(ADDR.X_COORD),
        y = read_byte(ADDR.Y_COORD),
    }
end

local function position_is_valid(value)
    return value.mapGroup ~= 0 and value.mapNumber ~= 0
        and value.x ~= 0xFF and value.y ~= 0xFF
end

M.position = overworld_position
M.position_is_valid = position_is_valid

-- Shared RAM-confirmed tile step used by Wild and Campaign. The caller owns
-- battle lifecycle; this primitive only stops early when that lifecycle says
-- an encounter has begun.
function M.attempt_step(direction, options)
    options = options or {}
    local before = overworld_position()
    local battle_active = options.battle_active or function() return false end
    local should_cancel = options.should_cancel

    if cancellation_requested(should_cancel) then
        joypad.set({})
        return "cancelled", before
    end

    for _ = 1, 4 do
        joypad.set({[direction] = true})
        emu.frameadvance()
        if cancellation_requested(should_cancel) then
            joypad.set({})
            return "cancelled", overworld_position()
        end
        if battle_active() then
            joypad.set({})
            return "encounter", overworld_position()
        end
    end
    joypad.set({[direction] = false})

    local frames = 0
    while read_byte(ADDR.MOVEMENT_FLAG) == MOVEMENT_IDLE_VALUE and frames < 20 do
        emu.frameadvance()
        frames = frames + 1
        if cancellation_requested(should_cancel) then
            joypad.set({})
            return "cancelled", overworld_position()
        end
        if battle_active() then return "encounter", overworld_position() end
        local current = overworld_position()
        if current.x ~= before.x or current.y ~= before.y
            or current.mapGroup ~= before.mapGroup or current.mapNumber ~= before.mapNumber then
            break
        end
    end

    frames = 0
    while read_byte(ADDR.MOVEMENT_FLAG) ~= MOVEMENT_IDLE_VALUE and frames < 90 do
        emu.frameadvance()
        frames = frames + 1
        if cancellation_requested(should_cancel) then
            joypad.set({})
            return "cancelled", overworld_position()
        end
        if battle_active() then return "encounter", overworld_position() end
    end

    local after = overworld_position()
    if options.allow_map_transition then
        frames = 0
        while after.mapGroup == before.mapGroup and after.mapNumber == before.mapNumber
            and after.x == before.x and after.y == before.y and frames < 180 do
            emu.frameadvance()
            frames = frames + 1
            if cancellation_requested(should_cancel) then
                joypad.set({})
                return "cancelled", overworld_position()
            end
            if battle_active() then return "encounter", overworld_position() end
            after = overworld_position()
        end
    end

    local unchanged = after.mapGroup == before.mapGroup and after.mapNumber == before.mapNumber
        and after.x == before.x and after.y == before.y
    return unchanged and "blocked" or "moved", after
end

function M.find_safe_pair(options)
    options = options or {}
    local anchor = overworld_position()
    local candidates = {
        {out = "Right", back = "Left"}, {out = "Left", back = "Right"},
        {out = "Down", back = "Up"}, {out = "Up", back = "Down"},
    }
    for _, pair in ipairs(candidates) do
        if cancellation_requested(options.should_cancel) then
            joypad.set({})
            return nil, "cancelled"
        end
        local result = M.attempt_step(pair.out, options)
        if result == "cancelled" then return nil, "cancelled" end
        if result == "encounter" then return nil, "encounter" end
        if result == "moved" then
            local back_result = M.attempt_step(pair.back, options)
            if back_result == "cancelled" then return nil, "cancelled" end
            if back_result == "encounter" then return nil, "encounter" end
            local here = overworld_position()
            if back_result == "moved" and here.mapGroup == anchor.mapGroup
                and here.mapNumber == anchor.mapNumber and here.x == anchor.x and here.y == anchor.y then
                return pair
            end
        end
    end
    return nil, "blocked"
end

-- Shared Wild battle-menu readiness. LoadBattleMenu is advisory, exactly as
-- in wild.lua: after the bounded hook wait, the live cursor is authoritative.
function M.wait_for_battle_menu(options, first_entry)
    local is_active = options.is_active
    local should_cancel = options.should_cancel
    local get_controls = options.get_controls
    local set_controls = options.set_controls
    local log = options.log or function() end

    if first_entry then
        local hook_wait = 0
        while not get_controls() and is_active()
            and not cancellation_requested(should_cancel) and hook_wait < 300 do
            emu.frameadvance()
            if cancellation_requested(should_cancel)
                or not press_button("B", should_cancel) then
                joypad.set({})
                return false, "cancelled"
            end
            hook_wait = hook_wait + 1
        end
        if cancellation_requested(should_cancel) then return false, "cancelled" end
        if get_controls() then
            log("LoadBattleMenu confirmed battle controls")
        else
            log("LoadBattleMenu hook missed; continuing with Wild cursor fallback")
        end
    end

    local cursor_wait = 0
    while is_active() and not cancellation_requested(should_cancel) and cursor_wait < 300 do
        if cursor_is_battle_menu() then
            set_controls(true)
            log(string.format("Battle menu ready at cursor Y=%d X=%d",
                read_byte(ADDR.MENU_CURSOR_Y), read_byte(ADDR.MENU_CURSOR_X)))
            return true
        end
        emu.frameadvance()
        if cancellation_requested(should_cancel)
            or not press_button("B", should_cancel) then
            joypad.set({})
            return false, "cancelled"
        end
        cursor_wait = cursor_wait + 1
    end
    if cancellation_requested(should_cancel) then return false, "cancelled" end
    return false, "battle cursor did not reach the four-option menu"
end

function M.navigate_battle_menu(target, options)
    local attempts = 0
    local log = options.log or function() end
    while options.get_controls() and options.is_active()
        and not cancellation_requested(options.should_cancel) and attempts < 12 do
        local y = read_byte(ADDR.MENU_CURSOR_Y)
        local x = read_byte(ADDR.MENU_CURSOR_X)
        if y == target.y and x == target.x then return true end
        local next_input = navigate_to_menu_option(target)
        log(string.format("Battle cursor Y=%d X=%d -> %s", y, x, next_input))
        if not press_and_wait_for_cursor_change(next_input, 30, function()
            return options.is_active() and not cancellation_requested(options.should_cancel)
        end) then
            joypad.set({})
            return false
        end
        attempts = attempts + 1
    end
    return false
end

function M.flee_battle(options)
    local ready, ready_error = M.wait_for_battle_menu(options, options.first_entry ~= false)
    if not ready then return false, 0, ready_error end

    local attempts = 0
    while options.is_active() and not cancellation_requested(options.should_cancel) and attempts < 5 do
        attempts = attempts + 1
        if options.log then options.log("Escape attempt " .. tostring(attempts)) end
        if attempts > 1 then
            ready, ready_error = M.wait_for_battle_menu(options, false)
            if not ready then return false, attempts, ready_error end
        end

        if not M.navigate_battle_menu(RUN_CURSOR, options) then
            if cancellation_requested(options.should_cancel) then
                joypad.set({})
                return false, attempts, "cancelled"
            end
            press_button("B", options.should_cancel)
            options.set_controls(false)
        else
            if options.log then options.log("RUN selected; waiting for overworld") end
            if not press_button("A", options.should_cancel) then
                joypad.set({})
                return false, attempts, "cancelled"
            end
            if options.wait_for_exit(180) then
                options.set_controls(false)
                return true, attempts
            end
            options.set_controls(false)
            if options.log then options.log("Escape attempt did not end the battle; retrying") end
        end
    end
    if cancellation_requested(options.should_cancel) then
        joypad.set({})
        return false, attempts, "cancelled"
    end
    return false, attempts, "could not escape after 5 attempts"
end

function M.register_encounter_hooks(options)
    Mem.RegisterROMHook(options.load_battle_menu, function()
        if ActiveModuleName ~= options.owner then return end
        options.on_battle_menu()
    end, (options.hook_prefix or "Wild Engine") .. " Battle Menu")

    Mem.RegisterROMHook(options.enemy_initialized, function()
        if ActiveModuleName ~= options.owner then return end
        options.on_encounter()
    end, (options.hook_prefix or "Wild Engine") .. " Encounter")
end

function M.new(options)
    options = options or {}
    return setmetatable({
        activeModuleName = options.activeModuleName or "campaign",
        verbose = options.verbose or function() return false end,
        shouldCancel = options.should_cancel or function() return false end,
        events = {},
        currentEncounter = nil,
        pendingEncounter = nil,
        haveBattleControls = false,
        command = nil,
        initialized = false,
        regionName = nil,
        battleActive = false,
        battleExitStableFrames = 0,
        overworldStableFrames = 0,
        romEncounterPending = false,
        romEncounterWaitFrames = 0,
        huntingEnabled = false,
        huntingAnchor = nil,
    }, Controller)
end

function Controller:log(message)
    if self.verbose() then print("[Wild Engine] " .. message) end
end

function Controller:emit(kind, values)
    values = values or {}
    values.type = kind
    table.insert(self.events, values)
end

function Controller:poll_event()
    if #self.events == 0 then return nil end
    return table.remove(self.events, 1)
end

function Controller:is_cancelled()
    return self.shouldCancel()
end

function Controller:press(button)
    return press_button(button, function() return self:is_cancelled() end)
end

function Controller:wait_frames(count)
    return wait_frames(count, function() return self:is_cancelled() end)
end

function Controller:is_in_battle()
    return self.battleActive
end

-- Battle lifecycle is hook-owned. Raw D-bank values are sampled only as a
-- ten-frame post-action confirmation, never as a source of new encounters.
function Controller:update_battle_exit()
    if not self.battleActive then return true end
    local here = overworld_position()
    if read_byte(ADDR.ENEMY_SPECIES) == 0 and read_byte(ADDR.BATTLE_MODE) == 0
        and position_is_valid(here) then
        self.battleExitStableFrames = self.battleExitStableFrames + 1
    else
        self.battleExitStableFrames = 0
    end
    if self.battleExitStableFrames >= REQUIRED_OVERWORLD_STABLE_FRAMES then
        self.battleActive = false
        self.battleExitStableFrames = 0
        self.haveBattleControls = false
        return true
    end
    return false
end

function Controller:wait_for_battle_exit(limit)
    local frames = 0
    while self.battleActive and not self:is_cancelled() and frames < limit do
        if self:update_battle_exit() then return true end
        emu.frameadvance()
        if self:is_cancelled() or not self:press("B") then
            joypad.set({})
            return false, "cancelled"
        end
        frames = frames + 1
    end
    if self:is_cancelled() then return false, "cancelled" end
    return not self.battleActive
end

function Controller:is_overworld_ready()
    local here = overworld_position()
    if self.battleActive or self.currentEncounter ~= nil
        or self.pendingEncounter ~= nil or self.command ~= nil then
        self.overworldStableFrames = 0
        return false, "Wild Engine is resolving an encounter"
    end
    if not position_is_valid(here) then
        self.overworldStableFrames = 0
        return false, string.format("transition map %d/%d X=%d Y=%d",
            here.mapGroup, here.mapNumber, here.x, here.y)
    end
    self.overworldStableFrames = math.min(
        self.overworldStableFrames + 1, REQUIRED_OVERWORLD_STABLE_FRAMES)
    if self.overworldStableFrames < REQUIRED_OVERWORLD_STABLE_FRAMES then
        return false, string.format("settling overworld %d/%d at map %d/%d X=%d Y=%d",
            self.overworldStableFrames, REQUIRED_OVERWORLD_STABLE_FRAMES,
            here.mapGroup, here.mapNumber, here.x, here.y)
    end
    return true, string.format("map %d/%d X=%d Y=%d",
        here.mapGroup, here.mapNumber, here.x, here.y)
end

function Controller:queue_current_encounter(source)
    if self.currentEncounter ~= nil or self.pendingEncounter ~= nil then return false end
    local species = read_byte(ADDR.ENEMY_SPECIES)
    if read_byte(ADDR.BATTLE_MODE) ~= 1 or species < 1 or species > 251 then return false end

    local atkdef = read_byte(ADDR.ENEMY_DVS)
    local spespc = read_byte(ADDR.ENEMY_DVS + 1)
    local item = read_byte(ADDR.ENEMY_ITEM)
    local encounter = {
        species = species,
        speciesName = pokemon_name(species),
        item = item,
        itemName = item_name(item),
        atkdef = atkdef,
        spespc = spespc,
        atk = math.floor(atkdef / 16),
        def = atkdef % 16,
        spe = math.floor(spespc / 16),
        spc = spespc % 16,
        shiny = is_shiny(atkdef, spespc),
        source = source,
    }
    self.pendingEncounter = encounter
    self.currentEncounter = encounter
    self.command = nil
    self.overworldStableFrames = 0
    self:log(string.format("Encounter detected via %s: %s (#%d)",
        source, encounter.speciesName, species))
    return true
end

function Controller:init_rom()
    local version = read_byte(ADDR.ROM_VERSION)
    local region = read_byte(ADDR.ROM_REGION)
    if version ~= 0x54 or region ~= ENGLISH_CRYSTAL_REGION then
        return false, string.format(
            "Route Campaign supports Pokemon Crystal Version (USA, Europe) only (expected version=0x54 region=0x45, got 0x%02X/0x%02X)",
            version, region)
    end

    self.regionName = "English USA/Europe"
    Mem.SetRomBankAddress("Crystal")
    self.initialized = true
    self:register_hooks()
    print("[Wild Engine] English Crystal shared encounter engine ready")
    return true
end

Controller.init = Controller.init_rom

function Controller:register_hooks()
    if not self.initialized then return end
    local owner = self
    M.register_encounter_hooks({
        owner = owner.activeModuleName,
        hook_prefix = "Wild Engine " .. owner.activeModuleName,
        load_battle_menu = LOAD_BATTLE_MENU,
        enemy_initialized = ENEMY_WILDMON_INITIALIZED,
        on_battle_menu = function()
            owner.haveBattleControls = true
        end,
        on_encounter = function()
            -- Hooks only set flags. Decoding and all frame advancement happen
            -- later in step(), outside BizHawk's callback context.
            owner.battleActive = true
            owner.battleExitStableFrames = 0
            owner.haveBattleControls = false
            owner.romEncounterPending = true
            owner.romEncounterWaitFrames = 0
        end,
    })
end

function Controller:reset()
    self.events = {}
    self.currentEncounter = nil
    self.pendingEncounter = nil
    self.haveBattleControls = false
    self.command = nil
    self.battleActive = false
    self.battleExitStableFrames = 0
    self.overworldStableFrames = 0
    self.romEncounterPending = false
    self.romEncounterWaitFrames = 0
end

function Controller:request(action)
    if action == "capture_master_ball" then action = "capture" end
    if action ~= "flee" and action ~= "capture" and action ~= "preserve"
        and action ~= "fight_first_move" then
        return false, "unknown encounter action"
    end
    if self.currentEncounter == nil or not self:is_in_battle() then return false, "no active encounter" end
    if self.command ~= nil then return false, "encounter action already pending" end
    self.command = action
    return true
end

Controller.request_action = Controller.request

function Controller:set_hunting(enabled, anchor)
    self.huntingEnabled = enabled == true
    self.huntingAnchor = anchor
end

function Controller:can_move()
    return self:is_overworld_ready()
end

function Controller:on_switch_to(owner)
    if owner ~= nil then self.activeModuleName = owner end
    self:register_hooks()
end

function Controller:on_resume(options)
    self:reset()
    options = options or {}
    self:set_hunting(options.hunting, options.anchor)
    self:register_hooks()
end

-- First entry follows wild.lua's hook-driven wait.  Retries after a failed
-- escape use the live cursor because LoadBattleMenu may not execute again.
function Controller:wait_for_battle_menu(first_entry)
    return M.wait_for_battle_menu({
        is_active = function() return self.battleActive and not self:is_cancelled() end,
        should_cancel = function() return self:is_cancelled() end,
        get_controls = function() return self.haveBattleControls end,
        set_controls = function(value) self.haveBattleControls = value end,
        log = function(message) self:log(message) end,
    }, first_entry)
end

function Controller:navigate_battle_menu(target)
    return M.navigate_battle_menu(target, {
        is_active = function() return self.battleActive and not self:is_cancelled() end,
        should_cancel = function() return self:is_cancelled() end,
        get_controls = function() return self.haveBattleControls end,
        set_controls = function(value) self.haveBattleControls = value end,
        log = function(message) self:log(message) end,
    })
end

function Controller:flee()
    local encounter = self.currentEncounter
    local fled, attempts, flee_error = M.flee_battle({
        is_active = function() return self.battleActive and not self:is_cancelled() end,
        should_cancel = function() return self:is_cancelled() end,
        get_controls = function() return self.haveBattleControls end,
        set_controls = function(value) self.haveBattleControls = value end,
        wait_for_exit = function(limit) return self:wait_for_battle_exit(limit) end,
        log = function(message) self:log(message) end,
    })
    joypad.set({})

    if self:is_cancelled() or flee_error == "cancelled" then return end

    if fled then
        self:log("Escape confirmed by stable overworld")
        self.currentEncounter = nil
        self.pendingEncounter = nil
        self:emit("fled", {encounter = encounter, attempts = attempts})
    else
        self:emit("paused", {
            reason = flee_error or "Could not escape after 5 Wild Engine attempts",
            encounter = encounter,
        })
    end
end

function Controller:select_pack()
    if self:is_cancelled() then return false, "cancelled" end
    local available, menu_error = self:wait_for_battle_menu(true)
    if not available then return false, menu_error end
    if not self:navigate_battle_menu(PACK_CURSOR) then
        return false, "could not navigate to PACK"
    end
    if not self:press("A") then return false, "cancelled" end
    self:log("PACK selected from the battle menu")
    return true
end

function Controller:fight_first_move()
    local available, menu_error = self:wait_for_battle_menu(true)
    if not available then
        if self:is_cancelled() or menu_error == "cancelled" then return end
        self:emit("error", {reason = menu_error, encounter = self.currentEncounter})
        return
    end
    if not self:navigate_battle_menu(FIGHT_CURSOR) then
        if self:is_cancelled() then return end
        self:emit("error", {reason = "could not navigate to FIGHT", encounter = self.currentEncounter})
        return
    end
    if not self:press("A") then return end
    if not self:wait_frames(30) then return end
    if not self:press("A") then return end
    self.haveBattleControls = false
end

function Controller:select_master_ball()
    -- Let BattlePack initialize before trusting its union-backed variables.
    if not self:wait_frames(45) then return false, "cancelled" end
    local ready = 0
    while ready < 360 do
        if self:is_cancelled() then return false, "cancelled" end
        local pocket = read_byte(ADDR.CUR_POCKET)
        local state = read_byte(ADDR.JUMPTABLE_INDEX)
        if pocket >= 0 and pocket <= 3 and state >= 0 and state <= 8 then break end
        emu.frameadvance()
        ready = ready + 1
    end

    local pocket_attempts = 0
    while read_byte(ADDR.CUR_POCKET) ~= BALL_POCKET and pocket_attempts < 6 do
        local previous = read_byte(ADDR.CUR_POCKET)
        if not self:press("Right") then return false, "cancelled" end
        local wait = 0
        while read_byte(ADDR.CUR_POCKET) == previous and wait < 90 do
            if self:is_cancelled() then return false, "cancelled" end
            emu.frameadvance()
            wait = wait + 1
        end
        pocket_attempts = pocket_attempts + 1
        self:log(string.format("PACK pocket changed %d -> %d",
            previous, read_byte(ADDR.CUR_POCKET)))
    end
    if read_byte(ADDR.CUR_POCKET) ~= BALL_POCKET then
        return false, "could not switch to the Balls pocket"
    end

    local menu_wait = 0
    -- BattlePack keeps wPackJumptableIndex at the pocket's INIT state (3)
    -- while wJumptableIndex advances to BALLSPOCKETMENU (4).
    while (read_byte(ADDR.JUMPTABLE_INDEX) ~= 4 or read_byte(ADDR.PACK_STATE) ~= 3)
        and menu_wait < 180 do
        if self:is_cancelled() then return false, "cancelled" end
        emu.frameadvance()
        menu_wait = menu_wait + 1
    end
    if read_byte(ADDR.JUMPTABLE_INDEX) ~= 4 or read_byte(ADDR.PACK_STATE) ~= 3 then
        return false, "Balls pocket menu did not reach PACKSTATE_BALLSPOCKETMENU"
    end

    local ball_types = read_byte(ADDR.NUM_BALLS)
    if ball_types == 0 or ball_types > MAX_BALL_TYPES then
        return false, "Balls pocket is empty or invalid"
    end
    for _ = 1, ball_types + 2 do
        if self:is_cancelled() then return false, "cancelled" end
        local selected = read_byte(ADDR.MENU_SELECTION)
        if selected == MASTER_BALL_ID then
            self:log("Master Ball highlighted; opening USE submenu")
            if not self:press("A") then return false, "cancelled" end

            -- wCurItem is populated as soon as the scrolling list highlights
            -- an item, so it cannot prove that ItemSubmenu has finished
            -- opening.  Wait for the USE/QUIT menu header and its default USE
            -- cursor instead.  Without this gate the second A is lost during
            -- menu construction and the later dialogue B backs out of PACK.
            local function item_submenu_is_ready()
                return read_byte(ADDR.MENU_BORDER_TOP) == ITEM_SUBMENU_TOP
                    and read_byte(ADDR.MENU_BORDER_LEFT) == ITEM_SUBMENU_LEFT
                    and read_byte(ADDR.MENU_CURSOR_Y) == ITEM_SUBMENU_USE_CURSOR_Y
                    and read_byte(ADDR.CUR_ITEM) == MASTER_BALL_ID
            end
            local function wait_for_item_submenu(limit)
                local stable_frames = 0
                for _ = 1, limit do
                    if self:is_cancelled() then return false, "cancelled" end
                    if item_submenu_is_ready() then
                        stable_frames = stable_frames + 1
                        if stable_frames >= 2 then return true end
                    else
                        stable_frames = 0
                    end
                    emu.frameadvance()
                end
                return false
            end

            local submenu_ready, submenu_error = wait_for_item_submenu(45)
            if not submenu_ready and submenu_error == "cancelled" then
                return false, submenu_error
            end
            if not submenu_ready
                and read_byte(ADDR.JUMPTABLE_INDEX) == 4
                and read_byte(ADDR.PACK_STATE) == 3
                and read_byte(ADDR.MENU_SELECTION) == MASTER_BALL_ID
                and read_byte(ADDR.MENU_BORDER_TOP) == BALLS_MENU_TOP
                and read_byte(ADDR.MENU_BORDER_LEFT) == BALLS_MENU_LEFT then
                -- BizHawk can occasionally drop the first edge while the
                -- scrolling Balls menu is settling. Retry only while RAM
                -- proves that Master Ball is still the selected list item.
                self:log("Master Ball list confirmation did not advance; retrying A once")
                if not self:press("A") then return false, "cancelled" end
                submenu_ready, submenu_error = wait_for_item_submenu(180)
            end
            if not submenu_ready then
                if submenu_error == "cancelled" then return false, submenu_error end
                return false, "Master Ball USE/QUIT submenu did not become ready"
            end
            if not self:press("A") then return false, "cancelled" end -- USE is the default option.

            local function item_submenu_is_open()
                return read_byte(ADDR.MENU_BORDER_TOP) == ITEM_SUBMENU_TOP
                    and read_byte(ADDR.MENU_BORDER_LEFT) == ITEM_SUBMENU_LEFT
            end
            local function wait_for_item_submenu_close(limit)
                local stable_frames = 0
                for _ = 1, limit do
                    if self:is_cancelled() then return false, "cancelled" end
                    if item_submenu_is_open() then
                        stable_frames = 0
                    else
                        stable_frames = stable_frames + 1
                        if stable_frames >= 2 then return true end
                    end
                    emu.frameadvance()
                end
                return false
            end

            local use_accepted, use_error = wait_for_item_submenu_close(45)
            if not use_accepted and use_error == "cancelled" then return false, use_error end
            if not use_accepted and item_submenu_is_ready() then
                -- The first USE edge was dropped. A retry is safe only while
                -- the exact USE/QUIT header and default USE cursor remain.
                self:log("Master Ball USE confirmation did not advance; retrying A once")
                if not self:press("A") then return false, "cancelled" end
                use_accepted, use_error = wait_for_item_submenu_close(180)
            end
            if not use_accepted then
                if use_error == "cancelled" then return false, use_error end
                return false, "Master Ball USE selection was not accepted"
            end
            self:log("Master Ball USE selected")
            return true
        end

        local previous = selected
        if not self:press("Down") then return false, "cancelled" end
        local selection_wait = 0
        while read_byte(ADDR.MENU_SELECTION) == previous and selection_wait < 45 do
            if self:is_cancelled() then return false, "cancelled" end
            emu.frameadvance()
            selection_wait = selection_wait + 1
        end
    end
    return false, "Master Ball exists in RAM but could not be selected in PACK"
end

function Controller:capture()
    if self:is_cancelled() then
        joypad.set({})
        return
    end
    local encounter = self.currentEncounter
    if encounter == nil or not encounter.shiny then
        self:emit("error", {reason = "capture was requested for a non-shiny encounter", encounter = encounter})
        return
    end

    local before_count, count_error = master_ball_count()
    if before_count == nil then
        self:emit("paused", {reason = count_error, encounter = encounter})
        return
    end
    if before_count < 1 then
        self:emit("paused", {reason = "No Master Ball is available; shiny battle preserved", encounter = encounter})
        return
    end

    local party_before = read_byte(ADDR.PARTY_COUNT)
    if party_before > 6 then
        self:emit("paused", {reason = "Party count RAM value is invalid", encounter = encounter})
        return
    end

    local opened, open_error = self:select_pack()
    if not opened then
        if self:is_cancelled() or open_error == "cancelled" then return end
        self:emit("paused", {reason = open_error, encounter = encounter})
        return
    end
    local selected, selection_error = self:select_master_ball()
    if not selected then
        if self:is_cancelled() or selection_error == "cancelled" then return end
        for _ = 1, 8 do
            if not self:press("B") then return end
        end
        self:emit("paused", {reason = selection_error, encounter = encounter})
        return
    end
    self:log("Waiting for wWildMon, Ball consumption, and battle exit")

    local saw_capture_latch = false
    local frames = 0
    while frames < 3000 and not self:is_cancelled() do
        if read_byte(ADDR.CAPTURED_WILD_MON) == encounter.species then
            saw_capture_latch = true
        end
        if saw_capture_latch and self:update_battle_exit() then break end
        -- Fresh B presses advance catch/Pokedex text and answer No to the
        -- nickname prompt without ever risking FIGHT.
        if not self:press("B") then
            joypad.set({})
            return
        end
        frames = frames + 5
    end
    joypad.set({})

    if self:is_cancelled() then return end

    if not self:wait_frames(10) then return end
    local after_count, after_error = master_ball_count()
    if after_count == nil then
        self:emit("paused", {reason = after_error, encounter = encounter})
        return
    end

    local consumed = after_count == before_count - 1
    local battle_ended = not self.battleActive
    if saw_capture_latch and consumed and battle_ended then
        self:log(string.format("Capture verified: species=%d, Master Balls %d -> %d",
            encounter.species, before_count, after_count))
        self.currentEncounter = nil
        self.pendingEncounter = nil
        self:emit("captured", {
            encounter = encounter,
            destination = party_before < 6 and "party" or "box",
            masterBallsRemaining = after_count,
        })
        return
    end

    local reasons = {}
    if not saw_capture_latch then table.insert(reasons, "wWildMon did not confirm the captured species") end
    if not consumed then table.insert(reasons, "Master Ball was not consumed (party/current box may be full)") end
    if not battle_ended then table.insert(reasons, "battle did not end") end
    self:emit("paused", {reason = table.concat(reasons, "; "), encounter = encounter})
end

function Controller:step()
    if self:is_cancelled() then
        joypad.set({})
        return
    end
    if self.romEncounterPending and self.currentEncounter == nil and self.pendingEncounter == nil then
        if self:queue_current_encounter("ROM hook") then
            self.romEncounterPending = false
            self.romEncounterWaitFrames = 0
        else
            self.romEncounterWaitFrames = self.romEncounterWaitFrames + 1
            if self.romEncounterWaitFrames > 120 then
                self.romEncounterPending = false
                self.romEncounterWaitFrames = 0
                self:emit("error", {
                    reason = "Encounter hook fired but English Crystal encounter data did not stabilize",
                })
            end
        end
    end

    if self.pendingEncounter ~= nil then
        local encounter = self.pendingEncounter
        self.pendingEncounter = nil
        self:emit("encounter", {encounter = encounter})
    end

    if self:is_cancelled() then
        joypad.set({})
        return
    end

    if self.command == "flee" then
        self.command = nil
        self:flee()
    elseif self.command == "capture" then
        self.command = nil
        self:capture()
    elseif self.command == "fight_first_move" then
        self.command = nil
        self:fight_first_move()
    elseif self.command == "preserve" then
        self.command = nil
        self:emit("preserved", {encounter = self.currentEncounter})
    end
end

M.ADDR = ADDR
M.MASTER_BALL_ID = MASTER_BALL_ID
M.ENGLISH_CRYSTAL_REGION = ENGLISH_CRYSTAL_REGION
M.master_ball_count = master_ball_count

return M
