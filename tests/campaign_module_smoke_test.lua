-- Loads and initializes Route Campaign against minimal BizHawk API mocks.
-- No gameplay loop, stats file, profile, ROM, or save is modified.

package.path = "modules/?.lua;?.lua;" .. package.path

local values = {
    [0x0141] = 0x54,
    [0x0142] = 0x45,
    [0xDCB5] = 1,
    [0xDCB6] = 1,
    [0xDCB7] = 10,
    [0xDCB8] = 10,
}

memory = {
    readbyte = function(address)
        return values[address] or 0
    end,
}
local frame = 0
emu = {
    framecount = function() return frame end,
    frameadvance = function() frame = frame + 1 end,
}
joypad = {set = function() end, getimmediate = function() return {} end}
comm = {httpSetTimeout = function() end, httpPost = function() return "ok" end}
ActiveModuleName = "campaign"

local next_handle = 1
local texts = {}
local checked = {}
local function handle(text)
    local result = next_handle
    next_handle = next_handle + 1
    texts[result] = tostring(text or "")
    return result
end

forms = {
    label = function(_, text) return handle(text) end,
    button = function(_, text) return handle(text) end,
    textbox = function(_, text) return handle(text) end,
    dropdown = function(_, items) return handle(items[1] or "") end,
    setproperty = function() end,
    setsize = function() end,
    settext = function(h, text) texts[h] = tostring(text) end,
    gettext = function(h) return texts[h] or "" end,
    ischecked = function(h) return checked[h] or false end,
    setdropdownitems = function(h, items) texts[h] = items[1] or "" end,
}

package.preload["data.memory"] = function()
    return {
        BankAddressToLinear = function(bank, address) return bank * 0x4000 + (address % 0x4000) end,
        SetRomBankAddress = function() end,
        RegisterROMHook = function() end,
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

-- This smoke test covers launcher lifecycle only. Persistence has its own
-- filesystem test, so keep this one independent from the host Lua's io API.
package.preload["campaign_store"] = function()
    return {
        list_profiles = function() return {} end,
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

local Campaign = require("campaign")
assert(Campaign.init(1, 130, {}))
Campaign.on_switch_to()
Campaign.on_resume()
assert(Campaign.step() == false)
local stop_requested = true
Campaign.set_stop_checker(function() return stop_requested end)
local frame_before_stop = frame
assert(Campaign.step() == false)
assert(frame == frame_before_stop)
Campaign.on_stop()
stop_requested = false
Campaign.on_switch_away()

print("campaign_module_smoke_test: OK")
