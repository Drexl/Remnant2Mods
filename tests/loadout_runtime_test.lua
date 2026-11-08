-- Run from repo root: lua tests/loadout_runtime_test.lua
-- The shared panel runtime in the modelled UE4SS process; not a native ABI test.
package.path = "tests/support/?.lua;" .. package.path
local W = require("remnant_world")
local function read(path)
  local file = assert(io.open(path, "r"))
  local source = file:read("*a"); file:close()
  return source
end
assert(read("LoadoutNamer/Scripts/loadout_runtime.lua") == read("MoreLoadoutSlots/Scripts/loadout_runtime.lua"),
  "standalone runtime copies must match")
assert(read("LoadoutNamer/Scripts/game_tick.lua") == read("EquipmentSearch/Scripts/game_tick.lua"),
  "standalone tick copies must match")

local MAIN = [[
local runtime = require("loadout_runtime").new("TestMod")
READY, ORDER = {}, {}
local hook = runtime.beforeReadiness("Refresh", function() ORDER[#ORDER + 1] = "before-refresh" end)
runtime.beforeReadiness("Construct", function() ORDER[#ORDER + 1] = "before-construct" end)
runtime.watchPanels(function(panel)
  ORDER[#ORDER + 1] = "ready"
  READY[#READY + 1] = panel
  if REMOVE then hook.remove() end
end)
runtime.start()
]]

local function start(classesLoaded)
  local world = W.new()
  if classesLoaded then world.engine.load(W.PANEL); world.engine.load(W.TILE) end
  local env = world.engine.loadMod("TestMod", "LoadoutNamer/Scripts", nil, MAIN)
  return world, world.engine, env
end

-- Cold start: listen on the native ancestor until the panel class exists.
local world, engine, env = start(false)
assert(#engine.listeners == 1 and next(engine.hooks) == nil)
engine.load(W.PANEL); engine.load(W.TILE)
world.userWidget("unrelated", "OtherWidget_C")
world.userWidget("archetype", "Widget_LoadoutsPanel_C", {flags = 0x20})
world.userWidget("cdo", "Widget_LoadoutsPanel_C", {flags = 0x10})
world.userWidget("/Game/Pkg.Default__Widget_LoadoutsPanel_C", "Widget_LoadoutsPanel_C")
local dead = world.userWidget("dead", "Widget_LoadoutsPanel_C", {dead = true})
assert(dead and #engine.listeners == 1 and next(engine.hooks) == nil, "templates and unrelated widgets are ignored")

-- The first live panel registers hooks before its own Construct, then stops listening.
local live = world.openPanel()
assert(#engine.listeners == 0)
assert(#env.READY == 1 and env.READY[1] == live)
assert(table.concat(env.ORDER, ",") == "before-refresh,before-construct,ready",
  "the nested Refresh inside Construct must not ready the panel early")
assert(engine.logCount("Live Loadouts panel ready") == 1)

-- Rebuilds and later Refresh calls do not ready a panel twice.
live.__raw.built = false
world.build(live)
world.refreshPanel(live)
assert(#env.READY == 1)

-- A panel with too few tiles at Construct is retried by its later Refresh.
world.blockVanillaTiles = true
local late = world.openPanel()
assert(#env.READY == 1, "wait for all eight vanilla tiles")
world.blockVanillaTiles = false
world.refreshPanel(late)
assert(#env.READY == 2 and env.READY[2] == late)

-- Ownerless panels stop after a bounded number of hook events.
local ownerless = world.openPanel({noOwner = true})
for _ = 1, 45 do world.refreshPanel(ownerless) end
assert(#env.READY == 2 and engine.logCount("Panel readiness timed out") == 1)

-- A new panel at a collected panel's address is a new instance, even while a
-- stale wrapper for that address still reports valid.
local reused = world.openPanel({address = live.__raw.address})
assert(#env.READY == 3 and env.READY[3] == reused)

-- A pre-readiness hook can be retired from another UFunction's hook.
env.REMOVE = true
local refreshHooks = engine.hookCount(W.PANEL .. ":Refresh")
world.openPanel()
assert(engine.hookCount(W.PANEL .. ":Refresh") == refreshHooks - 1)
engine.assertClean()

-- Hot reload with the class resident registers immediately; no listener.
world, engine, env = start(true)
assert(#engine.listeners == 0 and engine.hookCount(W.PANEL .. ":Construct") == 2)
world.openPanel()
assert(#env.READY == 1)
engine.assertClean()
print("PASS: class-gated registration, cancelled listener, Construct-after-Refresh readiness, retries, bounded ownerless work, address reuse, hook retirement and hot reload.")
