# AutoCrystal Agent Instructions

These instructions apply to the entire `autocrystal` repository. Read them before inspecting, changing, or running anything in this tree.

## Mandatory preflight

At the start of every task:

1. Read this file completely.
2. Inspect the worktree with `git status --short`. Existing modifications belong to the user; preserve them and do not reset, overwrite, or reformat unrelated files.
3. Read the relevant parts of `README.md`, then inspect `launcher.lua` and every module directly affected by the request. Treat the implementation as authoritative when documentation and code disagree.
4. Search sibling modules for duplicated behavior before changing shared encounter, movement, battle, reset, GUI, RNG, stats, or notification logic. A fix may need to remain consistent across multiple modules.
5. Keep the task scoped to this repository. The surrounding BizHawk installation, ROMs, saves, and logs are runtime assets, not project source.

If Git reports dubious repository ownership, use a per-command option such as `git -c safe.directory=<repo-path> ...`. Do not modify the user's global Git configuration.

## Project purpose and runtime

AutoCrystal is a Lua automation toolkit for Pokemon Gold, Silver, and Crystal running inside BizHawk. It automates shiny and DV hunting, encounters, gifts, egg handling, friendship grinding, battle actions, recovery, persistent statistics, and optional Discord notifications.

There is no standalone CLI or conventional test runner. `launcher.lua` is the only script users should load in BizHawk's Lua Console. BizHawk supplies the global APIs used throughout the project, including `emu`, `memory`, `event`, `joypad`, `forms`, `savestate`, `comm`, `client`, and `gameinfo` where applicable.

Do not attempt to make normal Lua execution outside BizHawk behave like the real runtime unless the task explicitly asks for a test harness or mocks.

## Repository map

- `launcher.lua`: module registry, persistent Forms window, shared HUD creation, Start/Stop coordination, active-module selection, and the one persistent main loop.
- `modules/gui_module.lua`: shared controls, counters, encounter/history display, option parsing, and per-module control reconfiguration.
- `modules/wild_engine.lua`: shared ROM configuration, hooks, movement primitives, battle-menu navigation, fleeing, and Campaign Master Ball capture used by Wild Encounters and Route Campaign.
- `modules/wild.lua`, `fishing.lua`, `headbutt.lua`: repeatable encounter modules. Wild consumes `wild_engine.lua`; Fishing and Headbutt retain their trigger-specific implementations.
- `modules/starters.lua`, `egg.lua`, `static.lua`, `gamecorner.lua`: save-state/reset or gift modules. They vary input timing to avoid deterministic results and inspect either party data or enemy data.
- `modules/friendship.lua`: movement-based friendship tracking and automatic escape from interruptions; it repurposes the shared HUD rather than recording encounters.
- `modules/campaign.lua` plus `campaign_gui.lua` and `campaign_store.lua`: English Crystal USA/Europe Route Campaign orchestration, integrated profile editor, semantic walking routes, and persistent progress. `campaign_capture.lua` is only a compatibility adapter to `wild_engine.lua`.
- `modules/diagnose_*.lua`, `modules/verify_movement_flag.lua`, `modules/list_memory_domains.lua`: standalone diagnostic tools. They are not launcher modules and may have task-specific usage instructions at the top of each file.
- `data/`: memory helpers, lookup tables, level-up data, launcher artwork, and a duplicate RNG helper.
- `modules/data/stats.lua`: the stats module actually resolved by `require("data.stats")` under the launcher's package path.
- `modules/data/rng_enabler.lua`: the RNG helper actually resolved by `require("data.rng_enabler")` under the launcher's package path.
- `discord_relay.ps1` and the batch launchers: optional localhost bridge needed because BizHawk cannot send Discord's required raw JSON directly.
- `user_data/`: ignored Route Campaign profiles, progress, temporary writes, and recovery backups. Treat every file here as user-owned runtime state.

The launcher's search path checks `modules/` before the repository root. Confirm which duplicate file `require(...)` resolves before editing files under `data/` or `modules/data/`; do not assume identically named files are both active.

## Launcher and module lifecycle

`launcher.lua` owns the only persistent window and outer loop. Modules are required and initialized lazily, then cached in `initializedModules`. The shared HUD is created once and reused across all modules.

Launcher modules expose this contract:

```lua
local M = {}

function M.init(sharedForm, yOffset, existingHud)
    -- One-time setup. Return false for an unsupported ROM or failed setup.
    return true
end

function M.on_switch_to()
    -- Optional. Re-register hooks and reconfigure/clear the shared HUD.
end

function M.on_resume()
    -- Optional. Reset per-run state whenever Start is clicked.
end

function M.on_switch_away()
    -- Optional. Hide module-specific controls before another module is activated.
end

function M.set_stop_checker(checker)
    -- Optional for modules with internal frame waits. Store the checker and
    -- return promptly with neutral input when it becomes true.
end

function M.on_stop()
    -- Optional cleanup, called by the launcher outside callback context.
end

function M.step()
    -- Called by the launcher while active.
    -- Return true when the module has finished; false/nil to continue.
end

return M
```

The lifecycle is:

1. A Forms callback records a start or stop request only.
2. The launcher's main loop calls `emu.frameadvance()`.
3. The loop consumes the request, lazily calls `require` and `init`, calls the previous module's optional `on_switch_away`, sets `ActiveModuleName`, then calls `on_switch_to` and `on_resume`.
4. While running, the loop calls the active module's `step()` once per outer-loop iteration.
5. A truthy completion result restores launcher controls and stops dispatching `step()`.

When adding a production module, add its name, require name, availability, and artwork to `MODULES` in `launcher.lua`; implement the lifecycle contract; reuse the existing form and HUD; and return a module table. Do not create a second persistent main loop or an independent main window.

## Critical runtime invariants

### Frame advancement and callbacks

BizHawk forbids `emu.frameadvance()` from Forms callbacks and memory/event callbacks. Never perform gameplay, waits, save-state work, or any operation that may advance frames from those callbacks.

- Forms callbacks may only record intent in flags or small values for later consumption.
- ROM/RAM hooks may capture memory state and set pending-work flags, but must remain short and non-blocking.
- Process pending work from `launcher.lua`'s loop or the active module's `step()`.
- A module may use bounded internal frame-advance sequences from `step()`, where BizHawk permits them. Avoid unbounded waits that prevent the outer loop and watchdogs from running.

### Persistent hooks and module switching

Event hooks can outlive the module run that registered them. Hook callbacks must guard against stale execution with `ActiveModuleName` when they can coexist or affect module state. Use stable, unique hook names and preserve the existing unregister/re-register behavior in `data/memory.lua`.

Every switch to a module, including returning to an already initialized module, must restore that module's state:

- Re-register its hooks when needed.
- Call `Gui.reconfigure(...)` with the correct disabled controls.
- Call `Gui.clear_last_encounter(...)` so data from the previous mode is not shown.
- Restore custom HUD labels after reconfiguration when a module repurposes the HUD, as friendship does.

`init` is one-time initialization. Per-run counters, flags, movement anchors, pending updates, watchdog timestamps, and reset state belong in `on_resume`, not only in `init`.

### Bounded automation and recovery

Preserve timeouts, settle-frame checks, progress tracking, and recovery paths. Phone calls, move-learning prompts, egg hatching, blocked tiles, dropped inputs, and unexpected dialogue can interrupt automation.

- Bound menu navigation, fleeing, mashing, and battle waits.
- Do not mark progress unless the expected RAM or position change actually occurred.
- Keep RAM-verified cursor and movement checks when changing navigation.
- Keep watchdog recovery reachable by returning control to `step()` regularly.
- Long Route Campaign waits must check the launcher's cooperative stop predicate after every advanced frame, release joypad input, and return without emitting a misleading pause/error event.
- A stop condition must leave a desired shiny, perfect-DV target, species, or held-item encounter intact rather than accidentally fighting, fleeing, or resetting it.

## Game data and automation rules

### ROM and memory handling

The ROM header bytes at `0x141` and `0x142` select game/version and region. Current production modules recognize Crystal (`0x54`) and Gold/Silver (`0x55`/`0x58`) with region-specific WRAM addresses. ROM execution hooks use bank-aware linear addresses through `data/memory.lua` and must set the correct current-bank address.

When adding or changing memory logic:

- Detect and validate the ROM before using version-specific addresses; return `false` from `init` when unsupported.
- Keep Japanese, Korean, US, and European layouts distinct where the existing code does.
- Distinguish party-structure addresses from enemy-structure addresses. Gift Pokemon are normally read from the new party slot; encounters are read from enemy battle data.
- Use the existing bank conversion and hook registration helpers instead of inventing ad hoc ROM-bank calculations.
- Document the source or verification method for a new address and provide a diagnostic script when practical.
- Do not copy addresses between games, regions, or modules without verifying the underlying structure.

Gen II DVs are packed into two bytes: Attack/Defense in the first and Speed/Special in the second. Preserve the existing nibble extraction and Gen II shiny predicate. Perfect and perfect-negative checks operate on all four displayed DVs.

### Movement, battles, and menus

Wild, friendship, and egg movement uses RAM-confirmed tile changes, discovers a safe opposing direction pair, and maintains a home anchor to prevent drift. Battle automation uses cursor coordinates and battle-state memory rather than fixed delays alone. Keep these properties when refactoring.

`wild.lua`, `fishing.lua`, and `headbutt.lua` deliberately contain closely related battle code. Before changing one, compare all three and decide explicitly whether the change is trigger-specific or should be mirrored. Also compare movement changes across `wild.lua`, `egg.lua`, and `friendship.lua`.

### Save-state ownership

The current code is authoritative for save-state allocation:

- Slot 3: Starters
- Slot 4: Egg
- Slot 5: Static
- Slot 6: Game Corner

Do not reuse these slots for another module. `on_resume()` saves the user's current prepared position, and normal/reset recovery reloads the same module-owned slot. The README currently says slots 6-9 are free; that statement is stale because Game Corner uses slot 6. Do not propagate it, and update the README if a task changes or documents slot ownership.

### RNG timing

BizHawk save states are deterministic. Reset-based modules introduce randomized frame delays so identical input sequences do not reproduce the same result. The active helper exposes a small split range for fast empirical coverage and a full-coverage range for the slower True Randomness option.

Preserve random seeding, intentional split points separated by real game logic, and the distinction between normal and full-coverage modes. Do not remove delays as "unnecessary sleeps" or claim coverage properties without measurement. Be aware that a full-range delay repeated at several split points can be extremely slow; follow each module's established behavior and user-facing option semantics.

### Shared HUD and statistics

The HUD is shared across modules. A module must disable controls that do not apply, re-enable controls indirectly through `Gui.reconfigure`, clear stale encounter data, and update counts/history through `gui_module.lua` rather than creating overlapping controls.

Lifetime stats are shared across production modules and persisted by `modules/data/stats.lua` to `modules/data/wild_stats.txt`. That text file is runtime state, even though it is tracked. It may already contain the user's live counters. Never reset, normalize, fabricate, or overwrite it during source changes or tests. Avoid tests that call `Stats.save()` against the real file.

Route Campaign profile/progress files under `user_data/` are also runtime state. Use `campaign_store.lua` for schema validation and atomic writes; never hand-edit, commit, bulk-delete, or reuse those files as test fixtures. Campaign tests must redirect storage to an ignored temporary directory and clean it afterward.

Route Campaign v1 is deliberately narrower than the regular Wild module: English Pokemon Crystal Version (USA, Europe), header `0x54/0x45`, wild encounters only, Master Ball capture only, and directional walking routes only. Preserve its fail-closed behavior. A missing Ball, unverified menu selection, unconfirmed capture, full storage, route mismatch, or unsupported interaction must pause while preserving the encounter/checkpoint; it must never fall through to FIGHT or guess an input.

The pack's `wCurItem` changes while the Master Ball is merely highlighted; it does not prove that the item submenu can accept input. Before the second `A`, wait for the RAM-confirmed `USE/QUIT` menu header (`wMenuBorderTopCoord=7`, `wMenuBorderLeftCoord=13`) and its default `USE` cursor. After pressing `A`, verify that this submenu closes before advancing capture dialogue. A single retry is permitted only while RAM proves that the unchanged Balls list still selects Master Ball or that the unchanged submenu still selects `USE`; never send an unconditional extra `A` after a menu transition. Keep all waits bounded and fail closed if a transition never stabilizes.

Wild Encounters and Route Campaign must share `wild_engine.lua`; do not reintroduce a separate Campaign combat controller. New encounters are created only from `EnemyWildmonInitialized`. `LoadBattleMenu` is advisory: after its bounded wait, the live cursor fallback remains available. Raw switchable-WRAM values may confirm a stable ten-frame battle exit but must not create encounters or independently change Campaign lifecycle. Hooks only record flags/snapshots; all frame advancement remains in `step()`.

### Discord relay

Lua modules post form-encoded JSON to `http://127.0.0.1:5000/`. `discord_relay.ps1` decodes the payload and forwards raw JSON to the user-configured Discord webhook.

- Keep the listener bound to localhost unless the user explicitly requests and understands a networking change.
- Never commit a real webhook URL, token, or notification payload containing private information.
- Preserve the bounded `comm.httpSetTimeout(3000)` setup wrapped in `pcall`; BizHawk shares an HttpClient whose timeout cannot be changed after its first request.
- Discord is optional. Missing relay service must not freeze or break core automation.

## Change discipline

- Make the smallest coherent change and preserve unrelated worktree modifications.
- Do not edit the surrounding BizHawk binaries/configuration, ROMs, save files, logs, or user webhook while working on this repository.
- Do not run destructive Git commands or globally reconfigure the user's tools.
- Match the existing Lua style: local module table, local helpers/state where possible, four-space indentation, descriptive comments for BizHawk or game-mechanics constraints, and explicit boolean completion behavior.
- Treat seemingly defensive code as intentional until its BizHawk constraint has been checked. Comments often record failures observed in the emulator.
- Update `README.md` whenever user setup, supported games, controls, stop behavior, module positioning, save-state allocation, relay setup, or other visible behavior changes.
- Keep diagnostic scripts standalone unless explicitly integrating them into the launcher.
- Do not commit generated stats, ROM-derived data, secrets, screenshots, or emulator artifacts as part of an unrelated task.

## Validation checklist

Before handing off a change:

1. Run `git status --short` and inspect the complete diff. Confirm only intended source/documentation files changed and pre-existing user changes remain intact.
2. Re-read every changed path and compare any shared behavior with its sibling modules.
3. Run a Lua syntax check only if a compatible interpreter/tool is already available and the check cannot write project state. Standard Lua alone cannot validate BizHawk globals or runtime behavior.
4. For changes to memory addresses, hooks, movement, battles, RNG, Forms, save states, or Discord, provide a focused manual BizHawk test scenario covering the supported game/region affected, normal completion, stop conditions, module switching, and interruption/recovery behavior.
5. Do not launch BizHawk automatically. GUI/emulator testing requires the user's ROM, save position, and observation unless the user explicitly authorizes and supplies an appropriate test setup.
6. Confirm no real webhook, ROM content, personal path, save data, or runtime counter was introduced into the diff.
7. If runtime validation was not possible, state that clearly and distinguish static verification from behavior verified inside BizHawk.
