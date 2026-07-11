-- Route Campaign controls drawn on the launcher's existing persistent form.
-- Callbacks only enqueue intent; campaign.step() performs all real work.

local M = {}

local PANEL_X = 465
local PANEL_WIDTH = 350
local EXPANDED_WIDTH = 830
local NORMAL_WIDTH = 460
local FORM_HEIGHT = 900

local function add_handle(w, handle)
    table.insert(w._handles, handle)
    return handle
end

local function label(w, text, x, y, width, height)
    return add_handle(w, forms.label(w.form, text, x, y, width, height or 18))
end

local function button(w, text, action, x, y, width)
    return add_handle(w, forms.button(w.form, text, function()
        table.insert(w._actions, action)
    end, x, y, width, 24))
end

local function textbox(w, text, x, y, width, height, multiline)
    return add_handle(w, forms.textbox(w.form, text or "", width, height or 20, nil, x, y, multiline or false, false,
        multiline and "Vertical" or nil))
end

local function dropdown(w, items, x, y, width)
    return add_handle(w, forms.dropdown(w.form, items, x, y, width, 20))
end

function M.create(form)
    local w = {
        form = form,
        _handles = {},
        _actions = {},
        _profileIds = {},
        _stageIds = {},
    }

    local x, y = PANEL_X, 10
    w.lblTitle = label(w, "ROUTE CAMPAIGN (Crystal USA/Europe)", x, y, PANEL_WIDTH, 20)
    y = y + 24
    w.lblMode = label(w, "MODE: editor", x, y, PANEL_WIDTH, 18)
    y = y + 23

    w.lblProfile = label(w, "Profile:", x, y, 80, 18)
    w.ddProfile = dropdown(w, {"-- no profiles --"}, x + 72, y - 2, 255)
    y = y + 28
    w.txtProfileName = textbox(w, "", x, y, 205, 20)
    w.btnCreateProfile = button(w, "Create", "create_profile", x + 212, y - 2, 65)
    w.btnDeleteProfile = button(w, "Delete", "delete_profile", x + 282, y - 2, 65)
    y = y + 31
    w.btnSelectProfile = button(w, "Load selected profile", "select_profile", x, y, 165)
    w.btnResetProgress = button(w, "Reset progress", "reset_progress", x + 172, y, 130)
    y = y + 34

    w.sep1 = label(w, string.rep("-", 50), x, y, PANEL_WIDTH, 16)
    y = y + 20
    w.lblStage = label(w, "Stage:", x, y, 60, 18)
    w.ddStage = dropdown(w, {"-- no stages --"}, x + 58, y - 2, 267)
    y = y + 27
    w.lblStageName = label(w, "Name:", x, y, 55, 18)
    w.txtStageName = textbox(w, "", x + 58, y - 2, 267, 20)
    y = y + 27
    w.lblTargets = label(w, "Targets (names or IDs, comma-separated):", x, y, PANEL_WIDTH, 18)
    y = y + 20
    w.txtTargets = textbox(w, "", x, y, 325, 46, true)
    y = y + 51
    w.btnAddStage = button(w, "Add stage", "add_stage", x, y, 100)
    w.btnSaveStage = button(w, "Save stage", "save_stage", x + 106, y, 100)
    w.btnDeleteStage = button(w, "Delete", "delete_stage", x + 212, y, 70)
    y = y + 30
    w.btnStageUp = button(w, "Move up", "stage_up", x, y, 95)
    w.btnStageDown = button(w, "Move down", "stage_down", x + 101, y, 95)
    w.btnSetAnchor = button(w, "Set current anchor", "set_anchor", x + 202, y, 135)
    y = y + 34

    w.lblAnchor = label(w, "Anchor: -", x, y, PANEL_WIDTH, 18)
    y = y + 23
    w.lblRoute = label(w, "Route to next: -", x, y, PANEL_WIDTH, 18)
    y = y + 23
    w.btnRecordRoute = button(w, "Record route", "record_route", x, y, 105)
    w.btnStopRecording = button(w, "Stop + save", "stop_recording", x + 111, y, 105)
    w.btnDiscardRecording = button(w, "Discard", "discard_recording", x + 222, y, 80)
    y = y + 34

    w.sep2 = label(w, string.rep("-", 50), x, y, PANEL_WIDTH, 16)
    y = y + 20
    w.btnRun = button(w, "Run campaign", "run_campaign", x, y, 110)
    w.btnPause = button(w, "Pause", "pause_campaign", x + 116, y, 80)
    w.btnResume = button(w, "Resume", "resume_campaign", x + 202, y, 90)
    y = y + 31
    w.btnRetry = button(w, "Retry checkpoint", "retry_checkpoint", x, y, 140)
    w.btnBackToEditor = button(w, "Back to editor", "back_to_editor", x + 146, y, 130)
    y = y + 34

    w.lblProgressHeader = label(w, "CAMPAIGN PROGRESS:", x, y, PANEL_WIDTH, 18)
    y = y + 21
    w.progressLines = {}
    for i = 1, 8 do
        w.progressLines[i] = label(w, "", x, y, PANEL_WIDTH, 17)
        y = y + 17
    end
    y = y + 6
    w.lblStatus = label(w, "Ready.", x, y, PANEL_WIDTH, 58)

    M.show(w, false)
    return w
end

function M.show(w, visible)
    for _, handle in ipairs(w._handles) do
        forms.setproperty(handle, "Visible", visible)
    end
    forms.setsize(w.form, visible and EXPANDED_WIDTH or NORMAL_WIDTH, FORM_HEIGHT)
end

function M.poll_action(w)
    if #w._actions == 0 then return nil end
    return table.remove(w._actions, 1)
end

function M.clear_actions(w)
    w._actions = {}
end

function M.get_profile_name(w)
    return forms.gettext(w.txtProfileName) or ""
end

function M.get_stage_name(w)
    return forms.gettext(w.txtStageName) or ""
end

function M.get_targets_text(w)
    return forms.gettext(w.txtTargets) or ""
end

function M.selected_profile_id(w)
    return w._profileIds[forms.gettext(w.ddProfile)]
end

function M.selected_stage_id(w)
    return w._stageIds[forms.gettext(w.ddStage)]
end

function M.set_profiles(w, profiles, selected_id)
    local items = {}
    w._profileIds = {}
    local selected_label = nil
    for _, profile in ipairs(profiles or {}) do
        local display = profile.name .. " [" .. profile.id .. "]"
        table.insert(items, display)
        w._profileIds[display] = profile.id
        if profile.id == selected_id then selected_label = display end
    end
    if #items == 0 then items = {"-- no profiles --"} end
    forms.setdropdownitems(w.ddProfile, items, false)
    if selected_label then forms.settext(w.ddProfile, selected_label) end
end

function M.set_stages(w, profile, selected_stage_id)
    local items = {}
    w._stageIds = {}
    local selected_label = nil
    for index, stage in ipairs((profile and profile.stages) or {}) do
        local display = string.format("%d. %s", index, stage.name)
        table.insert(items, display)
        w._stageIds[display] = stage.id
        if stage.id == selected_stage_id then selected_label = display end
    end
    if #items == 0 then items = {"-- no stages --"} end
    forms.setdropdownitems(w.ddStage, items, false)
    if selected_label then forms.settext(w.ddStage, selected_label) end
end

function M.edit_stage(w, stage, pokemon_names)
    if stage == nil then
        forms.settext(w.txtStageName, "")
        forms.settext(w.txtTargets, "")
        forms.settext(w.lblAnchor, "Anchor: -")
        forms.settext(w.lblRoute, "Route to next: -")
        return
    end
    forms.settext(w.txtStageName, stage.name)
    local names = {}
    for _, id in ipairs(stage.targets or {}) do table.insert(names, pokemon_names[id] or tostring(id)) end
    forms.settext(w.txtTargets, table.concat(names, ", "))
    if stage.anchor then
        forms.settext(w.lblAnchor, string.format("Anchor: map %d/%d, X=%d Y=%d",
            stage.anchor.mapGroup, stage.anchor.mapNumber, stage.anchor.x, stage.anchor.y))
    else
        forms.settext(w.lblAnchor, "Anchor: -")
    end
    local route_count = stage.routeToNext and #stage.routeToNext or 0
    forms.settext(w.lblRoute, string.format("Route to next: %d step(s)", route_count))
end

function M.set_mode(w, mode)
    forms.settext(w.lblMode, "MODE: " .. tostring(mode))
end

function M.set_status(w, text)
    forms.settext(w.lblStatus, tostring(text or ""))
end

function M.set_progress_lines(w, lines)
    for i = 1, #w.progressLines do
        forms.settext(w.progressLines[i], (lines and lines[i]) or "")
    end
end

function M.set_editor_enabled(w, enabled)
    local handles = {
        w.ddProfile, w.txtProfileName, w.btnCreateProfile, w.btnDeleteProfile,
        w.btnSelectProfile, w.btnResetProgress, w.ddStage, w.txtStageName,
        w.txtTargets, w.btnAddStage, w.btnSaveStage, w.btnDeleteStage,
        w.btnStageUp, w.btnStageDown, w.btnSetAnchor, w.btnRecordRoute,
    }
    for _, handle in ipairs(handles) do forms.setproperty(handle, "Enabled", enabled) end
end

function M.set_recording(w, recording)
    forms.setproperty(w.btnStopRecording, "Enabled", recording)
    forms.setproperty(w.btnDiscardRecording, "Enabled", recording)
    forms.setproperty(w.btnRecordRoute, "Enabled", not recording)
end

function M.set_run_state(w, state)
    local idle = state == "editor" or state == "paused" or state == "completed"
    forms.setproperty(w.btnRun, "Enabled", state == "editor")
    forms.setproperty(w.btnPause, "Enabled", not idle and state ~= "recording")
    forms.setproperty(w.btnResume, "Enabled", state == "paused")
    forms.setproperty(w.btnRetry, "Enabled", state == "paused")
    forms.setproperty(w.btnBackToEditor, "Enabled", state ~= "editor")
end

M.NORMAL_WIDTH = NORMAL_WIDTH
M.EXPANDED_WIDTH = EXPANDED_WIDTH

return M
