-- Pure-Lua tests for the English Crystal Route Campaign controller.
-- No real BizHawk state, save, profile, or statistics file is touched.

package.path = "modules/?.lua;?.lua;" .. package.path

local hooks = {}
package.preload["data.memory"] = function()
    return {
        BankAddressToLinear = function(bank, address) return bank * 0x4000 + (address % 0x4000) end,
        SetRomBankAddress = function() end,
        RegisterROMHook = function(_, callback, name) hooks[name] = callback end,
    }
end

local values = {}
memory = {
    readbyte = function(address) return values[address] or 0 end,
}
ActiveModuleName = "campaign"

local Capture = require("campaign_capture")
local A = Capture.ADDR
local ENCOUNTER_HOOK = "Wild Engine campaign Encounter"
local MENU_HOOK = "Wild Engine campaign Battle Menu"

values[A.ROM_VERSION] = 0x54
values[A.ROM_REGION] = 0x45
local controller = Capture.new({activeModuleName = "campaign"})
assert(controller:init_rom())
assert(hooks[ENCOUNTER_HOOK] ~= nil)

-- The ROM hook only records intent. Encounter decoding happens in step() and
-- uses the same wTempWildMonSpecies sentinel as wild.lua.
values[A.ENEMY_DVS] = 0x2A
values[A.ENEMY_DVS + 1] = 0xAA
values[A.BATTLE_MODE] = 1
values[A.ENEMY_SPECIES] = 16
values[A.ENEMY_ITEM] = 0
hooks[ENCOUNTER_HOOK]()
controller:step()
local event = controller:poll_event()
assert(event.type == "encounter")
assert(event.encounter.species == 16)
assert(event.encounter.speciesName == "Pidgey")
assert(event.encounter.shiny == true)
assert(event.encounter.atk == 2 and event.encounter.def == 10)

-- Missing resources pause before any menu input and preserve the encounter.
values[A.NUM_BALLS] = 0
assert(controller:request_action("capture_master_ball"))
controller:step()
local no_ball = controller:poll_event()
assert(no_ball.type == "paused")
assert(no_ball.reason:find("No Master Ball", 1, true) ~= nil)
assert(controller.currentEncounter ~= nil and controller.battleActive)

values[A.NUM_BALLS] = 2
values[A.BALLS] = Capture.MASTER_BALL_ID
values[A.BALLS + 1] = 3
values[A.BALLS + 2] = 2
values[A.BALLS + 3] = 5
assert(Capture.master_ball_count() == 3)

-- Route Campaign deliberately rejects every localization except the English
-- USA/Europe header used by this implementation.
values[A.ROM_REGION] = 0x53
local unsupported = Capture.new({activeModuleName = "campaign"})
local ok = unsupported:init_rom()
assert(ok == false)
values[A.ROM_REGION] = 0x45

-- Overworld movement uses engine lifecycle plus a short stable-position
-- window. Transient D-bank species values cannot invent a battle.
values[A.BATTLE_MODE] = 0
values[A.ENEMY_SPECIES] = 0
values[A.MAP_GROUP] = 24
values[A.MAP_NUMBER] = 4
values[A.X_COORD] = 36
values[A.Y_COORD] = 8
local transition_controller = Capture.new({activeModuleName = "campaign"})
for _ = 1, 9 do assert(not transition_controller:is_overworld_ready()) end
assert(transition_controller:is_overworld_ready())

values[A.MAP_GROUP] = 0
values[A.MAP_NUMBER] = 0
values[A.X_COORD] = 0xFF
values[A.Y_COORD] = 0
for _ = 1, 20 do assert(not transition_controller:is_overworld_ready()) end

values[A.MAP_GROUP] = 24
values[A.MAP_NUMBER] = 4
values[A.X_COORD] = 36
values[A.Y_COORD] = 8
for _ = 1, 9 do assert(not transition_controller:is_overworld_ready()) end
assert(transition_controller:is_overworld_ready())
values[A.ENEMY_SPECIES] = 19
assert(transition_controller:is_overworld_ready())

-- Without the encounter hook, changing raw battle values never emits an
-- encounter. This is the regression from the real 19/41/76/96/255 trace.
local fallback_controller = Capture.new({activeModuleName = "campaign"})
values[A.BATTLE_MODE] = 1
values[A.ENEMY_DVS] = 0x34
values[A.ENEMY_DVS + 1] = 0x56
values[A.ENEMY_SPECIES] = 19
for index = 1, 60 do
    values[A.ENEMY_SPECIES] = ({19, 41, 76, 96, 255})[(index - 1) % 5 + 1]
    fallback_controller:step()
    assert(fallback_controller:poll_event() == nil)
end

-- A hook-owned battle survives arbitrary transition values and ends only
-- after ten consecutive stable overworld confirmations.
local exit_controller = Capture.new({activeModuleName = "campaign"})
exit_controller.battleActive = true
for index = 1, 20 do
    values[A.ENEMY_SPECIES] = ({19, 255, 0, 96})[(index - 1) % 4 + 1]
    values[A.BATTLE_MODE] = index % 3
    values[A.MAP_GROUP] = index % 2 == 0 and 0 or 24
    assert(not exit_controller:update_battle_exit())
end
values[A.ENEMY_SPECIES] = 0
values[A.BATTLE_MODE] = 0
values[A.MAP_GROUP] = 24
values[A.MAP_NUMBER] = 3
values[A.X_COORD] = 36
values[A.Y_COORD] = 9
for _ = 1, 9 do assert(not exit_controller:update_battle_exit()) end
assert(exit_controller:update_battle_exit())
assert(not exit_controller.battleActive)

local function copy_input(input)
    local result = {}
    for key, value in pairs(input) do result[key] = value end
    return result
end

-- BizHawk joypad.set applies to the next emulated frame. If a frame advances
-- without another set call, input is neutral; this makes wild.lua's final
-- buffer frame a real release edge.
local function install_input_simulator(on_rising_edge)
    local pending = nil
    local previous = {}
    joypad = {
        set = function(next_input)
            pending = copy_input(next_input or {})
        end,
    }
    emu = {
        frameadvance = function()
            local input = pending or {}
            pending = nil
            local edges = {}
            for key, value in pairs(input) do
                if value and not previous[key] then edges[key] = true end
            end
            on_rising_edge(edges)
            previous = input
        end,
    }
end

-- Complete Master Ball flow. Intro text needs two B edges before the real
-- LoadBattleMenu hook; no A may be pressed while those stale cursor bytes are
-- visible. PACK must confirm both its state and wCurItem before USE.
values[A.BATTLE_MODE] = 1
values[A.ENEMY_SPECIES] = 16
values[A.MAP_GROUP] = 0
values[A.MAP_NUMBER] = 0
values[A.X_COORD] = 0xFF
values[A.Y_COORD] = 0
values[A.PARTY_COUNT] = 1
values[A.MENU_CURSOR_Y] = 1
values[A.MENU_CURSOR_X] = 1
values[A.MENU_BORDER_TOP] = 0
values[A.MENU_BORDER_LEFT] = 0
values[A.NUM_BALLS] = 1
values[A.BALLS] = Capture.MASTER_BALL_ID
values[A.BALLS + 1] = 2
values[A.CUR_POCKET] = 0
values[A.JUMPTABLE_INDEX] = 0
values[A.PACK_STATE] = 0
values[A.MENU_SELECTION] = 5
values[A.CUR_ITEM] = 0
values[A.CAPTURED_WILD_MON] = 0

local capture_controller = Capture.new({activeModuleName = "campaign"})
assert(capture_controller:init_rom())
capture_controller.battleActive = true
capture_controller.currentEncounter = {
    species = 16, speciesName = "Pidgey", shiny = true,
    atk = 2, def = 10, spe = 10, spc = 10,
}

local screen = "intro"
local intro_b_presses = 0
local capture_b_presses = 0
local premature_capture_a = false
local premature_submenu_a = false
local submenu_loading_frames = 0
local master_ball_accept_presses = 0
local use_accept_presses = 0
install_input_simulator(function(edges)
    if screen == "submenu_loading" then
        submenu_loading_frames = submenu_loading_frames + 1
        if submenu_loading_frames == 12 then
            screen = "submenu"
            values[A.MENU_BORDER_TOP] = 7
            values[A.MENU_BORDER_LEFT] = 13
            values[A.MENU_CURSOR_Y] = 1
        end
    end

    if edges.A and screen == "intro" then premature_capture_a = true end
    if edges.A and screen == "submenu_loading" then premature_submenu_a = true end

    if edges.B and screen == "intro" then
        intro_b_presses = intro_b_presses + 1
        if intro_b_presses == 2 then
            screen = "battle_menu"
            hooks[MENU_HOOK]()
        end
    elseif edges.Down and screen == "battle_menu" then
        values[A.MENU_CURSOR_Y] = 2
    elseif edges.A and screen == "battle_menu"
        and values[A.MENU_CURSOR_Y] == 2 and values[A.MENU_CURSOR_X] == 1 then
        screen = "pack"
        values[A.CUR_POCKET] = 0
        values[A.JUMPTABLE_INDEX] = 2
        values[A.PACK_STATE] = 2
    elseif edges.Right and screen == "pack" then
        values[A.CUR_POCKET] = 1
        values[A.JUMPTABLE_INDEX] = 4
        values[A.PACK_STATE] = 3
        values[A.MENU_SELECTION] = Capture.MASTER_BALL_ID
        values[A.CUR_ITEM] = Capture.MASTER_BALL_ID
        values[A.MENU_BORDER_TOP] = 1
        values[A.MENU_BORDER_LEFT] = 7
    elseif edges.A and screen == "pack" and values[A.MENU_SELECTION] == Capture.MASTER_BALL_ID then
        master_ball_accept_presses = master_ball_accept_presses + 1
        if master_ball_accept_presses == 2 then
            -- The first selection edge was deliberately dropped. The retry
            -- starts a real transition; no further A is allowed while loading.
            screen = "submenu_loading"
        end
    elseif edges.A and screen == "submenu" then
        use_accept_presses = use_accept_presses + 1
        if use_accept_presses == 2 then
            -- Deliberately drop the first USE edge as observed in BizHawk.
            screen = "capture_dialogue"
            values[A.MENU_BORDER_TOP] = 0
            values[A.MENU_BORDER_LEFT] = 0
            values[A.ITEM_EFFECT_SUCCEEDED] = 1
            values[A.BALLS + 1] = 1
            values[A.CAPTURED_WILD_MON] = 16
        end
    elseif edges.B and screen == "capture_dialogue" then
        capture_b_presses = capture_b_presses + 1
        if capture_b_presses == 3 then
            screen = "overworld"
            values[A.BATTLE_MODE] = 0
            values[A.ENEMY_SPECIES] = 0
            values[A.MAP_GROUP] = 24
            values[A.MAP_NUMBER] = 4
            values[A.X_COORD] = 36
            values[A.Y_COORD] = 8
        end
    end
end)

assert(capture_controller:request_action("capture_master_ball"))
capture_controller:step()
local captured = capture_controller:poll_event()
assert(captured.type == "captured")
assert(captured.encounter.species == 16)
assert(captured.destination == "party")
assert(captured.masterBallsRemaining == 1)
assert(intro_b_presses == 2)
assert(capture_b_presses == 3)
assert(master_ball_accept_presses == 2)
assert(use_accept_presses == 2)
assert(not premature_capture_a, "capture pressed A before LoadBattleMenu")
assert(not premature_submenu_a, "capture pressed A before the USE/QUIT submenu was ready")

-- RUN uses the exact wild.lua cursor-driven flow. The first attempt fails;
-- the menu returns without firing LoadBattleMenu again, and the second direct
-- cursor retry succeeds.
values[A.ENEMY_SPECIES] = 19
values[A.BATTLE_MODE] = 1
values[A.MAP_GROUP] = 0
values[A.MAP_NUMBER] = 0
values[A.X_COORD] = 0xFF
values[A.Y_COORD] = 0
values[A.MENU_CURSOR_Y] = 1
values[A.MENU_CURSOR_X] = 1
local flee_controller = Capture.new({activeModuleName = "campaign"})
assert(flee_controller:init_rom())
flee_controller.battleActive = true
flee_controller.currentEncounter = {species = 19, speciesName = "Rattata", shiny = false}

screen = "intro"
intro_b_presses = 0
local failed_escape_b_presses = 0
local run_attempts = 0
local premature_flee_a = false
install_input_simulator(function(edges)
    if edges.A and screen == "intro" then premature_flee_a = true end

    if edges.B and screen == "intro" then
        intro_b_presses = intro_b_presses + 1
        if intro_b_presses == 2 then
            screen = "battle_menu"
            -- Deliberately omit LoadBattleMenu. The shared Wild cursor
            -- fallback must still navigate and escape.
        end
    elseif edges.Down and screen == "battle_menu" then
        values[A.MENU_CURSOR_Y] = 2
    elseif edges.Right and screen == "battle_menu" then
        values[A.MENU_CURSOR_X] = 2
    elseif edges.A and screen == "battle_menu"
        and values[A.MENU_CURSOR_Y] == 2 and values[A.MENU_CURSOR_X] == 2 then
        run_attempts = run_attempts + 1
        if run_attempts == 1 then
            screen = "cant_escape"
        else
            screen = "overworld"
            values[A.BATTLE_MODE] = 0
            values[A.ENEMY_SPECIES] = 0
            values[A.MAP_GROUP] = 24
            values[A.MAP_NUMBER] = 4
            values[A.X_COORD] = 36
            values[A.Y_COORD] = 8
        end
    elseif edges.B and screen == "cant_escape" then
        failed_escape_b_presses = failed_escape_b_presses + 1
        if failed_escape_b_presses == 2 then screen = "battle_menu" end
    end
end)

assert(flee_controller:request_action("flee"))
flee_controller:step()
local fled = flee_controller:poll_event()
assert(fled.type == "fled")
assert(fled.attempts == 2)
assert(run_attempts == 2)
assert(intro_b_presses == 2)
assert(failed_escape_b_presses == 2)
assert(not premature_flee_a, "flee pressed A before LoadBattleMenu")

-- A launcher Stop request interrupts the battle wait on the next emulated
-- frame, preserves the encounter, and emits no misleading pause/error event.
values[A.ENEMY_SPECIES] = 19
values[A.BATTLE_MODE] = 1
values[A.MAP_GROUP] = 0
values[A.MAP_NUMBER] = 0
values[A.X_COORD] = 0xFF
values[A.Y_COORD] = 0
values[A.MENU_CURSOR_Y] = 0
values[A.MENU_CURSOR_X] = 0
local stop_requested = false
local stop_frames = 0
local stop_controller = Capture.new({
    activeModuleName = "campaign",
    should_cancel = function() return stop_requested end,
})
assert(stop_controller:init_rom())
stop_controller.battleActive = true
stop_controller.currentEncounter = {species = 19, speciesName = "Rattata", shiny = false}
install_input_simulator(function()
    stop_frames = stop_frames + 1
    if stop_frames == 3 then stop_requested = true end
end)
assert(stop_controller:request_action("flee"))
stop_controller:step()
assert(stop_frames <= 4, "Stop waited for the battle-menu watchdog")
assert(stop_controller:poll_event() == nil)
assert(stop_controller.currentEncounter ~= nil and stop_controller.battleActive)

-- The shared movement primitive also releases its direction immediately.
stop_requested = false
stop_frames = 0
local last_input = nil
joypad = {
    set = function(input) last_input = copy_input(input or {}) end,
}
emu = {
    frameadvance = function()
        stop_frames = stop_frames + 1
        if stop_frames == 3 then stop_requested = true end
    end,
}
local movement_result = Capture.attempt_step("Right", {
    should_cancel = function() return stop_requested end,
})
assert(movement_result == "cancelled")
assert(stop_frames == 3)
assert(next(last_input) == nil, "Stop left a direction held")

print("campaign_capture_test: OK")
