-- Run from repo root: lua tests/equipment_search_test.lua
-- Real EquipmentSearch entry point in the modelled UE4SS process (game-thread
-- UObject access only; LoopAsync and ExecuteInGameThread forbidden). It does not
-- prove UE4SS ABI behavior, real dispatch threads or rendering.
package.path = "tests/support/?.lua;" .. package.path
local W = require("remnant_world")
local mock = require("ue4ss_mock")

local world = W.new()
local engine = world.engine
engine.loadMod("EquipmentSearch", "EquipmentSearch/Scripts")
assert(next(engine.hooks) == nil and #engine.listeners == 1)
assert(engine.logCount("Native widget listener started") == 1)

-- Unrelated, invalid and template objects do not register hooks.
engine.load(W.LIST); engine.load(W.FILTER)
world.userWidget("unrelated", "OtherWidget_C")
world.userWidget("dead", "Widget_InventoryList_C", {dead = true})
world.userWidget("archetype", "Widget_InventoryList_C", {flags = 0x20})
world.userWidget("cdo", "Widget_InventoryList_C", {flags = 0x10})
world.userWidget("/Game/Pkg.Default__Widget_InventoryList_C", "Widget_InventoryList_C")
assert(next(engine.hooks) == nil and #engine.listeners == 1)

-- A list opened before any HUD exists: hooks register at its construction,
-- the bar is enabled in its Construct, and no deferred work is queued.
local early = world.openList("MainMenu")
assert(#engine.listeners == 0, "listener cancelled once hooks exist")
local hookCount = 0
for _ in pairs(engine.hooks) do hookCount = hookCount + 1 end
assert(hookCount == 7, "Construct, Update, Build, text, clear and focus in/out")
assert(engine.logCount("Search bar enabled on " .. early.__raw.fullName) == 1)
assert(engine.hookCount(W.HUD .. ":ReceiveTick") == 0)

world.enterWorld()
local equipment = world.openList("Equipment")
assert(engine.hookCount(W.HUD .. ":ReceiveTick") == 1, "first in-world list event registers the HUD tick")
local filter = equipment.__raw.Widget_InventorySearchFilter
assert(filter.__raw.Visibility == 0 and filter.__raw.SearchFilterText.__raw.Visibility == 0)
assert(filter.__raw.ComboBoxKey_58.__raw.Visibility == 1)
world.buildList(equipment)

-- Construct again for the same instance: re-show the bar, never re-enable.
filter.__raw.Visibility = 1
equipment.__raw.built = false
world.build(equipment)
assert(filter.__raw.Visibility == 0 and engine.logCount("Search bar enabled on " .. equipment.__raw.fullName) == 1)

-- Delayed re-application outlasts vanilla's construction-time binding.
filter.__raw.Visibility = 1
world.frame(100, 5)
assert(filter.__raw.Visibility == 0)

-- Delayed availability: a missing text box is retried on the next Build.
local late = world.openList("Late", {noBox = true})
assert(engine.logCount("Search bar enabled on " .. late.__raw.fullName) == 0)
late.__raw.Widget_InventorySearchFilter.__raw.SearchFilterText =
  world.widget(late.__raw.fullName .. ".Box", {Visibility = 1, Text = mock.text("")})
world.buildList(late)
assert(engine.logCount("Search bar enabled on " .. late.__raw.fullName) == 1)

-- Bounded readiness for a list that never gets an owner.
local ownerless = world.openList("Ownerless", {noOwner = true})
for _ = 1, 45 do world.updateList(ownerless) end
assert(engine.logCount("List readiness timed out") == 1)
assert(engine.logCount("Search bar enabled on " .. ownerless.__raw.fullName) == 0)

-- Novel readiness errors are logged, not swallowed, and are not retried.
local broken = world.openList("Broken", {unbuilt = true})
broken.__raw.GetOwningPlayer = function() error("owner read failed") end
world.build(broken)
world.buildList(broken)
assert(engine.logCount("List setup failed:") == 1 and engine.logCount("owner read failed") == 1)

-- Several inventory-tab lists filter independently.
local lists = {}
for i, label in ipairs({"Materials", "Quests", "Usables"}) do
  lists[i] = world.openList(label, {firstItem = 1000 + i * 10})
  world.buildList(lists[i])
end
world.type(equipment, "alpha")
local shown = world.visibleCards(equipment)
assert(#shown == 1 and shown[1] == equipment.__raw.firstItem + 1)
for _, list in ipairs(lists) do assert(#world.visibleCards(list) == 2, "queries remain per list") end

-- Vanilla grid passes: immediate hook pass, the 150 ms pass, and the watchdog.
world.updateList(equipment, true)
assert(#world.visibleCards(equipment) == 1)
world.frame(100, 2) -- let the one-shot 150 ms pass finish first
for _, card in ipairs(equipment.__raw.InventoryGrid.__raw.children) do card.__raw.Visibility = 0 end
world.frame(100, 3)
assert(#world.visibleCards(equipment) == 1, "watchdog re-applies an active query")
world.clear(equipment)
assert(#world.visibleCards(equipment) == 2, "X/empty query restores the grid")

-- Focus in/out hides and restores the menu's tab hotkeys on the game thread.
engine.callBlueprint(W.FILTER .. ":OnAddedToFocusPath", filter, nil, {})
assert(world.menu.__raw.MapTab.__raw.Visibility == 2)
engine.callBlueprint(W.FILTER .. ":OnRemovedFromFocusPath", filter, nil, {})
assert(world.menu.__raw.MapTab.__raw.Visibility == 0)

-- A new list at a destroyed list's address is enabled as a new instance.
local reused = world.openList("Reused", {})
local reuse = world.openList("ReusedAddress", {unbuilt = true})
reuse.__raw.address = reused.__raw.address
world.build(reuse)
assert(engine.logCount("Search bar enabled on " .. reuse.__raw.fullName) == 1)

-- Errors in the delayed bar re-application are logged.
local fragile = world.openList("Fragile")
fragile.__raw.Widget_InventorySearchFilter.__raw.SetVisibility = function() error("reapply failed") end
world.frame(100, 6)
assert(engine.logCount("Search bar reapply error:") == 1)

engine.assertClean()
assert(#engine.aborts == 0)
assert(engine.logCount("hook registration FAILED") == 0 and engine.logCount("refresh error:") == 0)
print("PASS: class-gated hooks, cancelled listener, Construct readiness, Build retries, bounded/erroring lists, re-show on rebuild, HUD-tick reapply/watchdog, per-list filtering, clear, focus and address reuse.")
