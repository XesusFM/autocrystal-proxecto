-- Regression coverage for Route Campaign battles that begin away from the
-- hunt anchor. No real BizHawk state, profile, progress, or statistics file is
-- touched; every dependency with runtime side effects is replaced below.

package.path = "modules/?.lua;?.lua;" .. package.path

local frame = 0
local position = {mapGroup = 1, mapNumber = 1, x = 10, y = 10}
local joypadReleased = false

memory = {
    readbyte = function(address)
        if address == 0xDCB5 then return position.mapGroup end
        if address == 0xDCB6 then return position.mapNumber end
        if address == 0xDCB7 then return position.y end
        if address == 0xDCB8 then return position.x end
        return 0
    end,
}
emu = {
    framecount = function() return frame end,
    frameadvance = function() frame = frame + 1 end,
}
joypad = {
    set = function(value) joypadReleased = next(value) == nil end,
    getimmediate = function() return {} end,
}
comm = {httpSetTimeout = function() end, httpPost = function() return "ok" end}
ActiveModuleName = "campaign"

forms = {
    setproperty = function() end,
}

local actions = {}
local gui_state = {mode = nil, status = nil}
local panel = {
    btnRecordRoute = 1,
    btnStopRecording = 2,
    btnDiscardRecording = 3,
}

package.preload["campaign_gui"] = function()
    return {
        create = function() return panel end,
        show = function() end,
        clear_actions = function() actions = {} end,
        poll_action = function()
            if #actions == 0 then return nil end
            return table.remove(actions, 1)
        end,
        selected_profile_id = function() return "test" end,
        selected_stage_id = function() return nil end,
        set_profiles = function() end,
        set_stages = function() end,
        edit_stage = function() end,
        set_progress_lines = function() end,
        set_mode = function(_, value) gui_state.mode = value end,
        set_status = function(_, value) gui_state.status = value end,
        set_run_state = function() end,
        set_editor_enabled = function() end,
        set_recording = function() end,
    }
end

local profile = {
    schema = 1,
    id = "test",
    name = "Recovery Test",
    stages = {
        {
            id = "stage-1",
            name = "First",
            targets = {16},
            anchor = {mapGroup = 1, mapNumber = 1, x = 10, y = 10},
            routeToNext = {
                {
                    direction = "Down",
                    from = {mapGroup = 1, mapNumber = 1, x = 10, y = 10},
                    to = {mapGroup = 1, mapNumber = 1, x = 10, y = 11},
                },
            },
        },
        {
            id = "stage-2",
            name = "Second",
            targets = {19},
            anchor = {mapGroup = 1, mapNumber = 1, x = 10, y = 11},
            routeToNext = {},
        },
    },
}
local progress = {
    schema = 1,
    profileId = "test",
    currentStage = 1,
    completed = {},
    extras = {},
    status = "idle",
    routeStep = 1,
}

package.preload["campaign_store"] = function()
    return {
        list_profiles = function() return {profile} end,
        load_profile = function() return profile end,
        load_progress = function() return progress end,
        validate_profile = function() return true end,
        save_profile = function() return true end,
        save_progress = function() return true end,
        has_progress = function() return false end,
    }
end

package.preload["gui_module"] = function()
    return {
        reconfigure = function() end,
        set_history_header = function() end,
        update_counts = function() end,
        clear_last_encounter = function() end,
        update_last_encounter = function() end,
        verbose_logging = function() return false end,
        discord_enabled = function() return false end,
    }
end

package.preload["data.stats"] = function()
    return {
        totalEncounters = 0,
        totalShinies = 0,
        encountersSinceShiny = 0,
        load = function() end,
        record_encounter = function() end,
        record_shiny = function() end,
    }
end

local controller
local requested_actions = {}
local WildEngine = {}
local next_step_result = nil
local blocked_steps = 0

function WildEngine.position()
    return {
        mapGroup = position.mapGroup,
        mapNumber = position.mapNumber,
        x = position.x,
        y = position.y,
    }
end

function WildEngine.find_safe_pair()
    return {out = "Right", back = "Left"}
end

function WildEngine.attempt_step(direction)
    if next_step_result ~= nil then
        local result = next_step_result
        next_step_result = nil
        return result, WildEngine.position()
    end
    if blocked_steps > 0 then
        blocked_steps = blocked_steps - 1
        return "blocked", WildEngine.position()
    end
    if direction == "Right" then position.x = position.x + 1 end
    if direction == "Left" then position.x = position.x - 1 end
    if direction == "Down" then position.y = position.y + 1 end
    if direction == "Up" then position.y = position.y - 1 end
    return "moved", WildEngine.position()
end

function WildEngine.new()
    controller = {
        events = {},
        battleActive = false,
        currentEncounter = nil,
        init = function() return true end,
        on_switch_to = function() end,
        on_resume = function(self)
            self.events = {}
            self.battleActive = false
            self.currentEncounter = nil
        end,
        set_hunting = function() end,
        is_in_battle = function(self) return self.battleActive end,
        can_move = function(self)
            return not self.battleActive, self.battleActive and "battle" or "ready"
        end,
        step = function() end,
        poll_event = function(self)
            if #self.events == 0 then return nil end
            return table.remove(self.events, 1)
        end,
        request_action = function(self, action)
            table.insert(requested_actions, action)
            return true
        end,
    }
    return controller
end

package.preload["wild_engine"] = function() return WildEngine end

local function queue_action(action)
    table.insert(actions, action)
end

local function queue_encounter(species, shiny)
    local encounter = {
        species = species,
        speciesName = species == 16 and "Pidgey" or "Rattata",
        atk = 2,
        def = 10,
        spe = 10,
        spc = 10,
        shiny = shiny,
        itemName = "None",
    }
    controller.battleActive = true
    controller.currentEncounter = encounter
    table.insert(controller.events, {type = "encounter", encounter = encounter})
    return encounter
end

local function queue_battle_result(kind, encounter)
    controller.battleActive = false
    controller.currentEncounter = nil
    local event = {type = kind, encounter = encounter}
    if kind == "captured" then
        event.destination = "party"
        event.masterBallsRemaining = 9
    end
    table.insert(controller.events, event)
end

local Campaign = require("campaign")
assert(Campaign.init(1, 130, {}))
Campaign.on_resume()

queue_action("select_profile")
assert(Campaign.step() == false)
queue_action("run_campaign")
assert(Campaign.step() == false)
assert(gui_state.mode == "hunting")

-- Reproduce the reported ordering: position mismatch pauses first, then the
-- encounter event stabilizes. An automatic pause must still flee and recover.
position.x = 11
assert(Campaign.step() == false)
assert(gui_state.mode == "paused")
assert(gui_state.status:find("Hunt anchor mismatch", 1, true) ~= nil)

local non_shiny = queue_encounter(19, false)
assert(Campaign.step() == false)
assert(requested_actions[#requested_actions] == "flee")
assert(gui_state.mode == "hunting")
assert(gui_state.status ~= "PAUSED: encounter detected; Resume to resolve it safely")

queue_battle_result("fled", non_shiny)
assert(Campaign.step() == false)
frame = frame + 10
assert(Campaign.step() == false)
assert(position.x == 10 and position.y == 10)
assert(Campaign.step() == false)
assert(gui_state.mode == "hunting")

-- A manual pause remains authoritative and preserves the same encounter.
queue_action("pause_campaign")
assert(Campaign.step() == false)
local requests_before_manual_encounter = #requested_actions
queue_encounter(19, false)
assert(Campaign.step() == false)
assert(#requested_actions == requests_before_manual_encounter)
assert(gui_state.status == "PAUSED: encounter detected; Resume to resolve it safely")

queue_action("resume_campaign")
assert(Campaign.step() == false)
assert(requested_actions[#requested_actions] == "flee")
queue_battle_result("fled", controller.currentEncounter)
assert(Campaign.step() == false)
frame = frame + 10
assert(Campaign.step() == false)
assert(Campaign.step() == false)

-- Capturing the final target of a non-final stage returns to the old anchor
-- before route playback begins.
position.x = 11
assert(Campaign.step() == false)
assert(gui_state.mode == "paused")
local shiny = queue_encounter(16, true)
assert(Campaign.step() == false)
assert(requested_actions[#requested_actions] == "capture_master_ball")
queue_battle_result("captured", shiny)
assert(Campaign.step() == false)
assert(progress.completed["stage-1"]["16"] == true)
assert(progress.status == "traveling")

-- A second encounter can interrupt the pending anchor recovery. Because the
-- stage is already complete, its shiny is an extra captured during travel.
next_step_result = "encounter"
frame = frame + 10
assert(Campaign.step() == false)
local recovery_shiny = queue_encounter(19, true)
assert(Campaign.step() == false)
assert(requested_actions[#requested_actions] == "capture_master_ball")
queue_battle_result("captured", recovery_shiny)
assert(Campaign.step() == false)
assert(#progress.extras == 1 and progress.extras[1].duringTravel == true)
frame = frame + 10
assert(Campaign.step() == false)
assert(position.x == 10 and position.y == 10)
assert(Campaign.step() == false)

-- Route encounters resume the saved from/to checkpoint after battle.
local route_encounter = queue_encounter(19, false)
assert(Campaign.step() == false)
assert(requested_actions[#requested_actions] == "flee")
queue_battle_result("fled", route_encounter)
assert(Campaign.step() == false)
frame = frame + 10
assert(Campaign.step() == false)
assert(Campaign.step() == false)
assert(position.x == 10 and position.y == 11)
assert(Campaign.step() == false)
assert(progress.currentStage == 2)
assert(gui_state.mode == "hunting")

-- A drift larger than the two-tile safety limit resolves the battle first,
-- then pauses without trying to walk back blindly.
position.x = 13
assert(Campaign.step() == false)
assert(gui_state.mode == "paused")
local far_encounter = queue_encounter(19, false)
assert(Campaign.step() == false)
assert(requested_actions[#requested_actions] == "flee")
queue_battle_result("fled", far_encounter)
assert(Campaign.step() == false)
frame = frame + 10
assert(Campaign.step() == false)
assert(gui_state.mode == "paused")
assert(gui_state.status:find("maximum is 2", 1, true) ~= nil)

-- A nearby recovery never walks blindly through a persistent obstruction.
position.x = 11
queue_action("resume_campaign")
assert(Campaign.step() == false)
assert(gui_state.mode == "paused")
local blocked_encounter = queue_encounter(19, false)
assert(Campaign.step() == false)
queue_battle_result("fled", blocked_encounter)
assert(Campaign.step() == false)
frame = frame + 10
blocked_steps = 3
assert(Campaign.step() == false)
assert(Campaign.step() == false)
assert(Campaign.step() == false)
assert(gui_state.mode == "paused")
assert(gui_state.status:find("after 3 verified attempts", 1, true) ~= nil)

local stopped = true
Campaign.set_stop_checker(function() return stopped end)
local stopped_x, stopped_y = position.x, position.y
assert(Campaign.step() == false)
assert(position.x == stopped_x and position.y == stopped_y)
assert(joypadReleased)

print("campaign_recovery_test: OK")
