-- Static/runtime smoke test proving Wild Encounters consumes wild_engine.
-- No real statistics, save, ROM, or BizHawk state is touched.

package.path = "modules/?.lua;?.lua;" .. package.path

local hooks = {}
package.preload["data.memory"] = function()
    return {
        BankAddressToLinear = function(bank, address) return bank * 0x4000 + (address % 0x4000) end,
        SetRomBankAddress = function() end,
        RegisterROMHook = function(_, callback, name) hooks[name] = callback end,
    }
end

package.preload["data.stats"] = function()
    return {
        totalEncounters = 0, totalShinies = 0, encountersSinceShiny = 0,
        load = function() end, record_encounter = function() end,
        record_shiny = function() end,
    }
end

package.preload["data.level_up_moves"] = function() return {} end
package.preload["gui_module"] = function()
    return {
        reconfigure = function() end, clear_last_encounter = function() end,
        update_counts = function() end, update_last_encounter = function() end,
        verbose_logging = function() return false end,
        discord_enabled = function() return false end,
        stop_on_species = function() return false, nil end,
        stop_on_item = function() return false, nil end,
        stop_on_perfect = function() return false end,
        stop_on_perfect_negative = function() return false end,
        kill_species_filter = function() return nil end,
        kill_non_shiny = function() return false end,
    }
end

local values = {
    [0x0141] = 0x54, [0x0142] = 0x45,
    [0xDCB5] = 24, [0xDCB6] = 3, [0xDCB7] = 9, [0xDCB8] = 36,
}
memory = {
    readbyte = function(address) return values[address] or 0 end,
    read_u16_be = function() return 1 end,
}
emu = {framecount = function() return 0 end, frameadvance = function() end}
joypad = {set = function() end}
comm = {httpSetTimeout = function() end, httpPost = function() return "ok" end}
ActiveModuleName = "wild"

local Engine = require("wild_engine")
local config = Engine.get_rom_config(0x54, 0x45)
assert(config.enemyAddr == 0xD20C)
assert(config.partyBase == 0xDCD7)

local Wild = require("wild")
assert(Wild.init(1, 130, {}))
Wild.on_switch_to()
Wild.on_resume()

assert(package.loaded["wild_engine"] == Engine)
assert(hooks["Wild Shared Engine Battle Menu"] ~= nil)
assert(hooks["Wild Shared Engine Encounter"] ~= nil)

print("wild_shared_engine_test: OK")
