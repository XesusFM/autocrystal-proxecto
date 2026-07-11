-- Route Campaign: persistent multi-stage wild shiny hunting for the English
-- Pokemon Crystal Version (USA, Europe) ROM.
--
-- The launcher remains the only outer loop. This module owns an internal
-- state machine, a semantic walking-route recorder/player, and a dedicated
-- capture controller which never attacks a shiny.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. script_dir .. "../?.lua;" .. package.path

local Gui = require("gui_module")
local CampaignGui = require("campaign_gui")
local Store = require("campaign_store")
local WildEngine = require("wild_engine")
local PokemonNames = require("data.pokemon_names")
local Stats = require("data.stats")

local RUNTIME_REVISION = "campaign-r11"
local DISCORD_RELAY_URL = "http://127.0.0.1:5000/"
local MAP_GROUP_ADDR = 0xDCB5
local MAP_NUMBER_ADDR = 0xDCB6
local Y_COORD_ADDR = 0xDCB7
local X_COORD_ADDR = 0xDCB8
-- Match the original encounter modules: the English ROM addresses are read
-- directly through BizHawk's System Bus.
local read_byte = memory.readbyte

local DISABLED_FIELDS = {
    "chkStopPerfect", "chkStopNegative",
    "chkStopSpecies", "txtSpeciesId",
    "chkStopItem", "txtItemFilter",
    "chkKillMode", "txtKillFilter",
    "chkTrueRandomness",
}

local hud
local panel
local capture
local mode = "editor"
local resumeMode = nil
local pausedReason = nil
local profiles = {}
local profile = nil
local progress = nil
local selectedStageId = nil
local lastDropdownStageId = nil
local sessionEncounterCount = 0
local finishRequested = false
local pendingConfirmation = nil
local confirmationExpires = 0
local stopChecker = function() return false end

local safePair = nil
local home = nil
local movementFailures = 0
local routeRetries = 0
local recording = nil
local overworldSettleUntilFrame = 0
local lastMovementGateMessage = nil
local lastMovementGateLogFrame = 0

local function stop_requested()
    return stopChecker()
end

local NAME_TO_ID = {}
for id, name in ipairs(PokemonNames) do NAME_TO_ID[name:lower()] = id end

local function vprint(message)
    if hud and Gui.verbose_logging(hud) then print("[Campaign] " .. message) end
end

local function ensure_emulation_running()
    if client == nil or client.ispaused == nil or client.unpause == nil then return end
    local checked, paused = pcall(client.ispaused)
    if not checked or not paused then return end
    local resumed, err = pcall(client.unpause)
    if resumed then
        vprint("BizHawk was paused; requested one automatic unpause")
    else
        print("[Campaign] Could not unpause BizHawk: " .. tostring(err))
    end
end

local function send_discord_notification(message)
    if hud == nil or not Gui.discord_enabled(hud) then return end
    local safe = tostring(message):gsub('"', '\\"')
    local payload = string.format('{"content": "%s"}', safe)
    local ok, response = pcall(comm.httpPost, DISCORD_RELAY_URL, payload)
    if ok then
        vprint("Discord notification sent: " .. tostring(response))
    else
        print("Campaign Discord notification failed: " .. tostring(response))
    end
end

local function position()
    return WildEngine.position()
end

local function same_position(a, b)
    return a ~= nil and b ~= nil
        and a.mapGroup == b.mapGroup and a.mapNumber == b.mapNumber
        and a.x == b.x and a.y == b.y
end

local function position_text(value)
    if value == nil then return "-" end
    return string.format("map %d/%d X=%d Y=%d", value.mapGroup, value.mapNumber, value.x, value.y)
end

local function press_button(button)
    for _ = 1, 4 do
        if stop_requested() then
            joypad.set({})
            return false
        end
        joypad.set({[button] = true})
        emu.frameadvance()
    end
    joypad.set({})
    if stop_requested() then return false end
    emu.frameadvance()
    return not stop_requested()
end

-- Returns "moved", "blocked", or "encounter" plus the final position.
local function attempt_step(direction, allow_map_transition)
    return WildEngine.attempt_step(direction, {
        allow_map_transition = allow_map_transition,
        battle_active = function() return capture:is_in_battle() end,
        should_cancel = stop_requested,
    })
end

local function find_stage_index(stage_id)
    if profile == nil then return nil end
    for index, stage in ipairs(profile.stages) do
        if stage.id == stage_id then return index end
    end
    return nil
end

local function current_stage()
    if profile == nil or progress == nil then return nil end
    return profile.stages[progress.currentStage]
end

local function selected_stage()
    local index = find_stage_index(selectedStageId)
    return index and profile.stages[index] or nil, index
end

local function stage_completion(stage)
    if stage == nil or progress == nil then return 0, 0 end
    local completed = progress.completed[stage.id] or {}
    local count = 0
    for _, id in ipairs(stage.targets) do
        if completed[tostring(id)] or completed[id] then count = count + 1 end
    end
    return count, #stage.targets
end

local function is_target(stage, species_id)
    if stage == nil then return false end
    for _, id in ipairs(stage.targets) do if id == species_id then return true end end
    return false
end

local function target_is_complete(stage, species_id)
    local values = progress.completed[stage.id] or {}
    return values[tostring(species_id)] == true or values[species_id] == true
end

local function stage_is_complete(stage)
    local complete, total = stage_completion(stage)
    return total > 0 and complete == total
end

local function save_profile()
    if profile == nil then return false end
    local ok, err = Store.save_profile(profile)
    if not ok then
        CampaignGui.set_status(panel, "SAVE ERROR: " .. tostring(err))
        return false
    end
    return true
end

local function save_progress()
    if progress == nil then return false end
    local ok, err = Store.save_progress(progress)
    if not ok then
        CampaignGui.set_status(panel, "PROGRESS ERROR: " .. tostring(err))
        return false
    end
    return true
end

local function refresh_progress_display()
    local lines = {}
    if profile == nil then
        table.insert(lines, "No profile loaded.")
    else
        for index, stage in ipairs(profile.stages) do
            local complete, total = stage_completion(stage)
            local marker = progress and index == progress.currentStage and ">" or " "
            table.insert(lines, string.format("%s %d. %s  [%d/%d]", marker, index, stage.name, complete, total))
            if #lines >= 7 then break end
        end
        table.insert(lines, string.format("Extras captured: %d", progress and #(progress.extras or {}) or 0))
    end
    CampaignGui.set_progress_lines(panel, lines)
end

local function refresh_stage_editor(stage_id)
    selectedStageId = stage_id
    lastDropdownStageId = stage_id
    CampaignGui.set_stages(panel, profile, stage_id)
    CampaignGui.edit_stage(panel, selected_stage(), PokemonNames)
    refresh_progress_display()
end

local function refresh_profiles(selected_id)
    local loaded, warning = Store.list_profiles()
    if loaded == nil then
        profiles = {}
        CampaignGui.set_status(panel, "Could not load campaign index: " .. tostring(warning))
    else
        profiles = loaded
        if warning then CampaignGui.set_status(panel, "Some profiles were skipped: " .. warning) end
    end
    CampaignGui.set_profiles(panel, profiles, selected_id)
end

local function load_profile(id)
    local loaded, err = Store.load_profile(id)
    if loaded == nil then
        CampaignGui.set_status(panel, "Could not load profile: " .. tostring(err))
        return false
    end
    local loaded_progress, progress_error = Store.load_progress(loaded)
    if loaded_progress == nil then
        CampaignGui.set_status(panel, "Could not load progress: " .. tostring(progress_error))
        return false
    end
    profile = loaded
    progress = loaded_progress
    local stage = profile.stages[progress.currentStage] or profile.stages[1]
    refresh_profiles(profile.id)
    refresh_stage_editor(stage and stage.id or nil)
    CampaignGui.set_status(panel, "Loaded profile " .. profile.name)
    return true
end

local function parse_targets(raw)
    local values, seen = {}, {}
    raw = tostring(raw or "")
    for token in raw:gmatch("[^,\r\n]+") do
        local trimmed = token:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            local id = tonumber(trimmed)
            if id ~= nil then
                if id % 1 ~= 0 or id < 1 or id > 251 then return nil, "Species IDs must be 1-251" end
            else
                id = NAME_TO_ID[trimmed:lower()]
                if id == nil then return nil, "Unknown species: " .. trimmed end
            end
            if not seen[id] then
                seen[id] = true
                table.insert(values, id)
            end
        end
    end
    if #values == 0 then return nil, "At least one target species is required" end
    return values
end

local function structural_edit_allowed()
    if profile == nil or progress == nil then return false, "Load a profile first" end
    if Store.has_progress(progress) then return false, "Reset progress before changing stages or targets" end
    return true
end

local function confirm(action, message)
    local now = emu.framecount()
    if pendingConfirmation == action and now <= confirmationExpires then
        pendingConfirmation = nil
        confirmationExpires = 0
        return true
    end
    pendingConfirmation = action
    confirmationExpires = now + 300
    CampaignGui.set_status(panel, message .. " Click the same button again to confirm.")
    return false
end

local function set_mode(next_mode, status)
    mode = next_mode
    if capture ~= nil then
        local stage = current_stage()
        capture:set_hunting(mode == "hunting", stage and stage.anchor or nil)
    end
    CampaignGui.set_mode(panel, mode)
    CampaignGui.set_run_state(panel, mode)
    CampaignGui.set_editor_enabled(panel, mode == "editor")
    CampaignGui.set_recording(panel, mode == "recording")
    if mode ~= "editor" and mode ~= "recording" then
        forms.setproperty(panel.btnRecordRoute, "Enabled", false)
        forms.setproperty(panel.btnStopRecording, "Enabled", false)
        forms.setproperty(panel.btnDiscardRecording, "Enabled", false)
    end
    if status then CampaignGui.set_status(panel, status) end
end

local function pause(reason, return_mode)
    resumeMode = return_mode or mode
    pausedReason = reason
    set_mode("paused", "PAUSED: " .. tostring(reason))
    send_discord_notification("Route Campaign paused: " .. tostring(reason))
end

local function reset_movement(stage)
    safePair = nil
    movementFailures = 0
    routeRetries = 0
    home = stage and stage.anchor or nil
end

local function find_safe_pair()
    return WildEngine.find_safe_pair({
        battle_active = function() return capture:is_in_battle() end,
        should_cancel = stop_requested,
    })
end

local function hunt_step()
    local stage = current_stage()
    if stage == nil then return pause("Current stage is missing", "editor") end
    if home == nil then home = stage.anchor end
    local here = position()
    if not same_position(here, home) then
        pause("Hunt anchor mismatch. Expected " .. position_text(home) .. ", got " .. position_text(here), "hunting")
        return
    end

    if safePair == nil then
        local pair, reason = find_safe_pair()
        if reason == "cancelled" then return end
        if reason == "encounter" then return end
        safePair = pair
        if safePair == nil then
            movementFailures = movementFailures + 1
            if movementFailures >= 20 then
                pause("No safe zero-drift walking pair exists at this anchor", "hunting")
            end
            return
        end
        movementFailures = 0
        vprint("Safe hunt pair: " .. safePair.out .. "/" .. safePair.back)
        return
    end

    local out_result = attempt_step(safePair.out, false)
    if out_result == "cancelled" then return end
    if out_result == "encounter" then return end
    local back_result = attempt_step(safePair.back, false)
    if back_result == "cancelled" then return end
    if back_result == "encounter" then return end
    if out_result ~= "moved" or back_result ~= "moved" or not same_position(position(), home) then
        safePair = nil
        movementFailures = movementFailures + 1
        if movementFailures >= 10 then
            for _ = 1, 6 do if not press_button("B") then return end end
            movementFailures = 0
        end
    else
        movementFailures = 0
    end
end

local function route_step()
    local stage = current_stage()
    if stage == nil then return pause("Travel stage is missing", "traveling") end
    local route = stage.routeToNext or {}
    local index = progress.routeStep or 1
    if index > #route then
        progress.currentStage = progress.currentStage + 1
        progress.routeStep = 1
        progress.status = "hunting"
        local next_stage = current_stage()
        if next_stage == nil then return pause("Next stage is missing", "editor") end
        if not same_position(position(), next_stage.anchor) then
            return pause("Route ended away from the next anchor", "traveling")
        end
        if not save_progress() then return pause("Could not save stage transition", "traveling") end
        reset_movement(next_stage)
        refresh_progress_display()
        set_mode("hunting", "Arrived at " .. next_stage.name .. ". Hunting...")
        return
    end

    local step = route[index]
    local here = position()
    if same_position(here, step.to) then
        progress.routeStep = index + 1
        save_progress()
        return
    end
    if not same_position(here, step.from) then
        pause(string.format("Route checkpoint %d mismatch. Expected %s, got %s",
            index, position_text(step.from), position_text(here)), "traveling")
        return
    end

    local result, after = attempt_step(step.direction, true)
    if result == "cancelled" then return end
    if result == "encounter" then return end
    if result == "moved" and same_position(after, step.to) then
        routeRetries = 0
        progress.routeStep = index + 1
        save_progress()
        CampaignGui.set_status(panel, string.format("Traveling: step %d/%d", index, #route))
        return
    end

    routeRetries = routeRetries + 1
    if routeRetries >= 3 then
        for _ = 1, 6 do if not press_button("B") then return end end
        routeRetries = 0
        if not same_position(position(), step.from) then
            pause("Route diverged while recovering checkpoint " .. tostring(index), "traveling")
        else
            pause("Route step remained blocked after 3 attempts", "traveling")
        end
    end
end

local function begin_recording()
    local stage, index = selected_stage()
    if stage == nil then return CampaignGui.set_status(panel, "Select a stage first") end
    if index >= #profile.stages then return CampaignGui.set_status(panel, "Add the next stage before recording this transition") end
    if Store.has_progress(progress) and index < progress.currentStage then
        return CampaignGui.set_status(panel, "Completed routes are locked; reset progress before replacing this route")
    end
    if stage.anchor == nil then return CampaignGui.set_status(panel, "Set this stage's anchor first") end
    if not same_position(position(), stage.anchor) then
        return CampaignGui.set_status(panel, "Stand on the selected stage anchor before recording")
    end
    if capture:is_in_battle() then
        return CampaignGui.set_status(panel, "Finish the current battle before recording")
    end
    recording = {stageIndex = index, steps = {}, last = position(), pendingDirection = nil}
    set_mode("recording", "Recording walking inputs. Stop at the next hunt anchor.")
end

local function recorder_step()
    if recording == nil then return pause("Recorder state was lost", "editor") end
    if capture:is_in_battle() then
        CampaignGui.set_status(panel, "Recording paused during battle; resolve it manually.")
        return
    end

    local input = joypad.getimmediate() or {}
    if input.A or input.B or input.Start or input.Select then
        CampaignGui.set_status(panel, "A/B/Start/Select are not supported and were not recorded.")
    end
    for _, direction in ipairs({"Up", "Down", "Left", "Right"}) do
        if input[direction] then recording.pendingDirection = direction end
    end

    local here = position()
    if not same_position(here, recording.last) then
        if recording.pendingDirection == nil then
            pause("Position changed without a recorded walking direction", "recording")
            return
        end
        table.insert(recording.steps, {
            direction = recording.pendingDirection,
            from = recording.last,
            to = here,
        })
        recording.last = here
        recording.pendingDirection = nil
        CampaignGui.set_status(panel, string.format("Recording: %d step(s), now %s", #recording.steps, position_text(here)))
    end
end

local function stop_recording()
    if recording == nil then return CampaignGui.set_status(panel, "No route is being recorded") end
    if capture:is_in_battle() then return CampaignGui.set_status(panel, "Finish the battle first") end
    if #recording.steps == 0 then return CampaignGui.set_status(panel, "The route contains no walking steps") end
    local stage = profile.stages[recording.stageIndex]
    local next_stage = profile.stages[recording.stageIndex + 1]
    stage.routeToNext = recording.steps
    next_stage.anchor = position()
    recording = nil
    if not save_profile() then return end
    refresh_stage_editor(stage.id)
    set_mode("editor", "Route saved; next anchor is " .. position_text(next_stage.anchor))
end

local function discard_recording()
    recording = nil
    set_mode("editor", "Recorded route discarded")
end

local function begin_campaign()
    if profile == nil then return CampaignGui.set_status(panel, "Load a profile first") end
    local valid, err = Store.validate_profile(profile, true)
    if not valid then return CampaignGui.set_status(panel, "Profile is not runnable: " .. tostring(err)) end
    if progress.status == "completed" then
        set_mode("completed", "Campaign already complete. Reset progress to run it again.")
        return
    end

    local next_mode = progress.status == "traveling" and "traveling" or "hunting"
    local expected
    if next_mode == "traveling" then
        local stage = current_stage()
        local step = stage and stage.routeToNext and stage.routeToNext[progress.routeStep or 1]
        expected = step and step.from or (profile.stages[progress.currentStage + 1] and profile.stages[progress.currentStage + 1].anchor)
    else
        expected = current_stage().anchor
        progress.status = "hunting"
    end
    if expected ~= nil and not same_position(position(), expected) then
        return pause("Move to the saved checkpoint before starting. Expected " .. position_text(expected), next_mode)
    end
    reset_movement(current_stage())
    save_progress()
    ensure_emulation_running()
    set_mode(next_mode, next_mode == "traveling" and "Resuming saved route..." or "Hunting at " .. current_stage().name)
end

local function record_capture(event)
    local encounter = event.encounter
    local stage = current_stage()
    local completes_target = mode == "hunting" and stage ~= nil
        and is_target(stage, encounter.species) and not target_is_complete(stage, encounter.species)

    if completes_target then
        progress.completed[stage.id] = progress.completed[stage.id] or {}
        progress.completed[stage.id][tostring(encounter.species)] = true
    else
        table.insert(progress.extras, {
            species = encounter.species,
            stageId = stage and stage.id or "unknown",
            mapGroup = read_byte(MAP_GROUP_ADDR),
            mapNumber = read_byte(MAP_NUMBER_ADDR),
            caughtAt = os.time(),
            duringTravel = mode == "traveling",
        })
    end

    local message = string.format("Captured shiny %s with Master Ball (%s, %d remaining)",
        encounter.speciesName, event.destination, event.masterBallsRemaining)
    if completes_target then message = message .. " - stage target completed" else message = message .. " - logged as extra" end

    if completes_target and stage_is_complete(stage) then
        if progress.currentStage >= #profile.stages then
            progress.status = "completed"
            save_progress()
            refresh_progress_display()
            send_discord_notification("Route Campaign complete! " .. profile.name)
            set_mode("completed", "CAMPAIGN COMPLETE: " .. profile.name)
            finishRequested = true
            return
        end
        progress.status = "traveling"
        progress.routeStep = 1
        save_progress()
        refresh_progress_display()
        reset_movement(stage)
        set_mode("traveling", message .. ". Starting route to next stage.")
        return
    end

    if mode == "traveling" then
        progress.status = "traveling"
    elseif mode == "hunting" then
        progress.status = "hunting"
    end
    save_progress()
    refresh_progress_display()
    safePair = nil
    CampaignGui.set_status(panel, message)
end

local function handle_capture_event(event)
    if event.type == "encounter" then
        local e = event.encounter
        sessionEncounterCount = sessionEncounterCount + 1
        Stats.record_encounter()
        Gui.update_last_encounter(hud, sessionEncounterCount, e.species, e.speciesName,
            e.atk, e.def, e.spe, e.spc, e.shiny, e.itemName)
        if mode == "editor" or mode == "completed" then
            if e.shiny then Stats.record_shiny() end
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny,
                sessionEncounterCount, "Encounter preserved while editor is active")
            pause("Encounter detected while the campaign editor is active; Resume to resolve it", mode)
            return
        elseif mode == "paused" then
            if e.shiny then Stats.record_shiny() end
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny,
                sessionEncounterCount, "Encounter preserved while campaign is paused")
            CampaignGui.set_status(panel, "PAUSED: encounter detected; Resume to resolve it safely")
            return
        end
        if e.shiny then
            Stats.record_shiny()
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny,
                sessionEncounterCount, "Shiny found - preparing Master Ball...")
            send_discord_notification(string.format("Campaign shiny found: %s (#%d), capturing with Master Ball", e.speciesName, e.species))
            local ok, err = capture:request_action("capture_master_ball")
            if not ok then pause(err, mode) end
        else
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny,
                sessionEncounterCount, "Non-shiny - fleeing...")
            local ok, err = capture:request_action("flee")
            if not ok then pause(err, mode) end
        end
    elseif event.type == "fled" then
        safePair = nil
        overworldSettleUntilFrame = emu.framecount() + 10
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny,
            sessionEncounterCount, mode == "traveling" and "Route resumed" or "Hunting resumed")
    elseif event.type == "captured" then
        overworldSettleUntilFrame = emu.framecount() + 10
        record_capture(event)
    elseif event.type == "paused" or event.type == "error" then
        pause(event.reason or event.type, mode)
    end
end

local function handle_action(action)
    if action == "create_profile" then
        local created, err = Store.create_profile(CampaignGui.get_profile_name(panel))
        if created == nil then return CampaignGui.set_status(panel, "Create failed: " .. tostring(err)) end
        load_profile(created.id)
        CampaignGui.set_status(panel, "Created profile " .. created.name)

    elseif action == "select_profile" then
        local id = CampaignGui.selected_profile_id(panel)
        if id == nil then return CampaignGui.set_status(panel, "Select a profile") end
        load_profile(id)

    elseif action == "delete_profile" then
        if profile == nil then return CampaignGui.set_status(panel, "Load a profile first") end
        if not confirm("delete_profile", "This deletes the selected profile and progress.") then return end
        local id = profile.id
        local ok, err = Store.delete_profile(id)
        if not ok then return CampaignGui.set_status(panel, "Delete failed: " .. tostring(err)) end
        profile, progress, selectedStageId = nil, nil, nil
        refresh_profiles(nil)
        CampaignGui.set_stages(panel, nil, nil)
        CampaignGui.edit_stage(panel, nil, PokemonNames)
        refresh_progress_display()
        CampaignGui.set_status(panel, "Deleted profile " .. id)

    elseif action == "reset_progress" then
        if profile == nil then return CampaignGui.set_status(panel, "Load a profile first") end
        if not confirm("reset_progress", "This clears all captured targets and extras.") then return end
        local reset, err = Store.reset_progress(profile)
        if reset == nil then return CampaignGui.set_status(panel, "Reset failed: " .. tostring(err)) end
        progress = reset
        refresh_progress_display()
        CampaignGui.set_status(panel, "Progress reset")

    elseif action == "add_stage" then
        local allowed, reason = structural_edit_allowed()
        if not allowed then return CampaignGui.set_status(panel, reason) end
        local name = CampaignGui.get_stage_name(panel):match("^%s*(.-)%s*$")
        local targets, err = parse_targets(CampaignGui.get_targets_text(panel))
        if name == "" then return CampaignGui.set_status(panel, "Stage name is required") end
        if targets == nil then return CampaignGui.set_status(panel, err) end
        local stage = {id = Store.make_stage_id(profile), name = name, targets = targets, routeToNext = {}}
        table.insert(profile.stages, stage)
        if not save_profile() then return end
        refresh_stage_editor(stage.id)
        CampaignGui.set_status(panel, "Stage added; set its anchor or record the preceding route")

    elseif action == "save_stage" then
        local allowed, reason = structural_edit_allowed()
        if not allowed then return CampaignGui.set_status(panel, reason) end
        local stage = selected_stage()
        if stage == nil then return CampaignGui.set_status(panel, "Select a stage") end
        local name = CampaignGui.get_stage_name(panel):match("^%s*(.-)%s*$")
        local targets, err = parse_targets(CampaignGui.get_targets_text(panel))
        if name == "" then return CampaignGui.set_status(panel, "Stage name is required") end
        if targets == nil then return CampaignGui.set_status(panel, err) end
        stage.name, stage.targets = name, targets
        if save_profile() then refresh_stage_editor(stage.id) end

    elseif action == "delete_stage" then
        local allowed, reason = structural_edit_allowed()
        if not allowed then return CampaignGui.set_status(panel, reason) end
        local stage, index = selected_stage()
        if stage == nil then return CampaignGui.set_status(panel, "Select a stage") end
        if not confirm("delete_stage", "Delete stage " .. stage.name .. "?") then return end
        table.remove(profile.stages, index)
        -- The route from the previous stage no longer has a trustworthy destination.
        if index > 1 and profile.stages[index - 1] then profile.stages[index - 1].routeToNext = {} end
        if save_profile() then
            local replacement = profile.stages[math.min(index, #profile.stages)]
            refresh_stage_editor(replacement and replacement.id or nil)
        end

    elseif action == "stage_up" or action == "stage_down" then
        local allowed, reason = structural_edit_allowed()
        if not allowed then return CampaignGui.set_status(panel, reason) end
        local stage, index = selected_stage()
        if stage == nil then return CampaignGui.set_status(panel, "Select a stage") end
        local other = action == "stage_up" and index - 1 or index + 1
        if other < 1 or other > #profile.stages then return end
        profile.stages[index], profile.stages[other] = profile.stages[other], profile.stages[index]
        -- Recorded transitions belong to ordering, so invalidate affected routes.
        for i = math.max(1, math.min(index, other) - 1), math.min(#profile.stages, math.max(index, other)) do
            profile.stages[i].routeToNext = {}
        end
        if save_profile() then refresh_stage_editor(stage.id) end

    elseif action == "set_anchor" then
        local allowed, reason = structural_edit_allowed()
        if not allowed then return CampaignGui.set_status(panel, reason) end
        local stage = selected_stage()
        if stage == nil then return CampaignGui.set_status(panel, "Select a stage") end
        if capture:is_in_battle() then return CampaignGui.set_status(panel, "Finish the battle first") end
        stage.anchor = position()
        if save_profile() then refresh_stage_editor(stage.id) end

    elseif action == "record_route" then
        begin_recording()
    elseif action == "stop_recording" then
        stop_recording()
    elseif action == "discard_recording" then
        discard_recording()
    elseif action == "run_campaign" then
        begin_campaign()
    elseif action == "pause_campaign" then
        pause("Paused by user", mode)
    elseif action == "resume_campaign" or action == "retry_checkpoint" then
        if mode ~= "paused" then return end
        local next_mode = resumeMode or (progress and progress.status) or "hunting"
        ensure_emulation_running()
        set_mode(next_mode, "Retrying " .. next_mode .. "...")
        if capture:is_in_battle() and capture.currentEncounter then
            local requested, err = capture:request_action(
                capture.currentEncounter.shiny and "capture_master_ball" or "flee")
            if not requested then pause(err, next_mode) end
        end
    elseif action == "back_to_editor" then
        recording = nil
        set_mode("editor", "Editor ready. Current game position was not changed.")
    end
end

function M.init(sharedForm, yOffset, existingHud)
    print("[Campaign] Loaded " .. RUNTIME_REVISION .. " (shared Wild Engine)")
    pcall(function() comm.httpSetTimeout(3000) end)
    Stats.load()
    hud = existingHud
    capture = WildEngine.new({
        activeModuleName = "campaign",
        verbose = function() return hud and Gui.verbose_logging(hud) end,
        should_cancel = stop_requested,
    })
    local ok, err = capture:init()
    if not ok then
        print(err)
        return false
    end
    panel = CampaignGui.create(sharedForm)
    refresh_profiles(nil)
    Gui.reconfigure(hud, DISABLED_FIELDS)
    Gui.set_history_header(hud, "CAMPAIGN CAPTURES:")
    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny,
        sessionEncounterCount, "Route Campaign editor ready")
    return true
end

M.RUNTIME_REVISION = RUNTIME_REVISION

function M.set_stop_checker(checker)
    stopChecker = type(checker) == "function" and checker or function() return false end
end

function M.on_switch_to()
    capture:on_switch_to("campaign")
    CampaignGui.show(panel, true)
    Gui.reconfigure(hud, DISABLED_FIELDS)
    Gui.set_history_header(hud, "CAMPAIGN CAPTURES:")
    Gui.clear_last_encounter(hud)
    refresh_profiles(profile and profile.id or nil)
    refresh_progress_display()
end

function M.on_switch_away()
    CampaignGui.show(panel, false)
    CampaignGui.clear_actions(panel)
end

function M.on_stop()
    joypad.set({})
    if capture ~= nil then capture:set_hunting(false) end
end

function M.on_resume()
    capture:on_resume({hunting = false})
    sessionEncounterCount = 0
    finishRequested = false
    recording = nil
    pendingConfirmation = nil
    overworldSettleUntilFrame = 0
    lastMovementGateMessage = nil
    lastMovementGateLogFrame = 0
    reset_movement(current_stage())
    set_mode("editor", "Select or create a profile, then edit or run it.")
end

function M.step()
    if stop_requested() then
        joypad.set({})
        return false
    end
    capture:step()
    if stop_requested() then
        joypad.set({})
        return false
    end
    while true do
        local event = capture:poll_event()
        if event == nil then break end
        handle_capture_event(event)
        if stop_requested() then
            joypad.set({})
            return false
        end
    end

    local action = CampaignGui.poll_action(panel)
    if action then handle_action(action) end
    if stop_requested() then
        joypad.set({})
        return false
    end

    local movement_mode = mode == "hunting" or mode == "traveling"
    local overworld_ready, gate_message = false, nil
    if movement_mode then
        overworld_ready, gate_message = capture:can_move()
        local frame = emu.framecount()
        if overworld_ready then
            if lastMovementGateMessage ~= nil then
                vprint("Movement ready: " .. tostring(gate_message))
                local stage = current_stage()
                CampaignGui.set_status(panel, mode == "hunting"
                    and ("Hunting at " .. (stage and stage.name or "current stage"))
                    or "Traveling to the next stage")
            end
            lastMovementGateMessage = nil
        elseif gate_message ~= lastMovementGateMessage or frame - lastMovementGateLogFrame >= 120 then
            lastMovementGateMessage = gate_message
            lastMovementGateLogFrame = frame
            vprint("Movement waiting: " .. tostring(gate_message))
            CampaignGui.set_status(panel, "WAITING: " .. tostring(gate_message))
        end
    else
        lastMovementGateMessage = nil
    end

    if mode == "editor" then
        local dropdown_stage = CampaignGui.selected_stage_id(panel)
        if dropdown_stage ~= nil and dropdown_stage ~= lastDropdownStageId then
            refresh_stage_editor(dropdown_stage)
        end
    elseif mode == "recording" then
        recorder_step()
    elseif mode == "hunting" and overworld_ready and emu.framecount() >= overworldSettleUntilFrame then
        hunt_step()
    elseif mode == "traveling" and overworld_ready and emu.framecount() >= overworldSettleUntilFrame then
        route_step()
    end

    if stop_requested() then
        joypad.set({})
        return false
    end

    if finishRequested then
        finishRequested = false
        return true
    end
    return false
end

return M
