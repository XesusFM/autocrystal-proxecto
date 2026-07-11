-- Pure-Lua Route Campaign persistence/schema smoke test.
-- This never imports Stats and writes only below ignored tests/tmp.

package.path = "modules/?.lua;" .. package.path

local Store = require("campaign_store")
local test_dir = "tests/tmp/"
Store._set_base_dir_for_tests(test_dir)

local function assert_ok(value, err)
    assert(value, tostring(err))
    return value
end

for _, name in ipairs({
    "campaign_index.lua", "campaign_index.lua.bak", "campaign_index.lua.tmp",
    "campaign_test-profile.lua", "campaign_test-profile.lua.bak", "campaign_test-profile.lua.tmp",
    "progress_test-profile.lua", "progress_test-profile.lua.bak", "progress_test-profile.lua.tmp",
}) do
    os.remove(test_dir .. name)
end

local profile = assert_ok(Store.create_profile("Test Profile"))
assert(profile.id == "test-profile")
profile.stages = {
    {
        id = "stage-1",
        name = "Route 29",
        targets = {16, 19},
        anchor = {mapGroup = 1, mapNumber = 1, x = 10, y = 12},
        routeToNext = {
            {
                direction = "Right",
                from = {mapGroup = 1, mapNumber = 1, x = 10, y = 12},
                to = {mapGroup = 1, mapNumber = 1, x = 11, y = 12},
            },
        },
    },
    {
        id = "stage-2",
        name = "Route 30",
        targets = {163},
        anchor = {mapGroup = 1, mapNumber = 1, x = 11, y = 12},
        routeToNext = {},
    },
}
assert(assert_ok(Store.validate_profile(profile, true)))
assert(assert_ok(Store.save_profile(profile)))

local loaded = assert_ok(Store.load_profile(profile.id))
assert(loaded.name == profile.name)
assert(#loaded.stages == 2)
assert(loaded.stages[1].targets[2] == 19)
assert(loaded.stages[1].routeToNext[1].direction == "Right")

local progress = assert_ok(Store.load_progress(loaded))
progress.completed["stage-1"] = {["16"] = true}
progress.extras[1] = {species = 25, stageId = "stage-1", caughtAt = 1}
assert(assert_ok(Store.save_progress(progress)))
local reloaded_progress = assert_ok(Store.load_progress(loaded))
assert(reloaded_progress.completed["stage-1"]["16"] == true)
assert(reloaded_progress.extras[1].species == 25)
assert(Store.has_progress(reloaded_progress))

local invalid = {
    schema = Store.SCHEMA_VERSION,
    id = "bad",
    name = "Bad",
    stages = {{id = "stage-1", name = "Bad", targets = {0, 1}}},
}
local valid = Store.validate_profile(invalid, false)
assert(valid == false)

assert(assert_ok(Store.delete_profile(profile.id)))
os.remove(test_dir .. "campaign_index.lua")
os.remove(test_dir .. "campaign_index.lua.bak")
os.remove(test_dir .. "campaign_index.lua.tmp")
print("campaign_store_test: OK")
