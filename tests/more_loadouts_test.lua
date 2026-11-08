-- Run: lua tests/more_loadouts_test.lua [native]
-- Real MoreLoadoutSlots entry point in the modelled UE4SS process. The stable
-- delegate abort is simulated; this is not a UE4SS ABI or rendering test.
package.path = "tests/support/?.lua;" .. package.path
local W = require("remnant_world")
local native = arg[1] == "native"
local realPrint = print

local world = W.new({multicast = native})
local engine = world.engine
engine.loadMod("MoreLoadoutSlots", "MoreLoadoutSlots/Scripts")
assert(#engine.listeners == 1 and engine.hookCount(W.PANEL .. ":Construct") == 0)

world.clientRestart()
assert(world.component.__raw.Slots[1].NumRecords == 21, "record capacity patched inside the spawn hook")

local first = world.openPanel()
local list = first.__raw.LoadoutList
assert(#list.__raw.children == 20, "first setup completes despite the capability-probe abort")
assert(#engine.aborts == (native and 0 or 1))
if not native then
  assert(engine.aborts[1].path == W.PANEL .. ":Refresh", "the abort ends only the probe's Refresh dispatch")
end
assert(engine.hookCount(W.PANEL .. ":Refresh") == 1, "probe unregistered by the same Construct")
local seen = {}
for _, tile in ipairs(list.__raw.children) do
  local index = tile.__raw.Index
  assert(index ~= 10 and not seen[index], "reserved/duplicate record")
  seen[index] = true
  if index > 10 then assert(tile.__raw.LabelOverride:ToString() == "Loadout " .. index) end
end
assert(seen[20] and seen[8] and seen[9])

-- Rebuilding the same panel does not ready it again.
first.__raw.built = false
world.build(first)
assert(#list.__raw.children == 20 and engine.logCount("Added 12 extra loadout tiles") == 1)
local second = world.openPanel()
assert(#second.__raw.LoadoutList.__raw.children == 20 and engine.logCount("Added 12 extra loadout tiles") == 2)
assert(#engine.aborts == (native and 0 or 1), "the probe runs once per process")

if native then
  assert(engine.hookCount(W.TILE_RMB) == 0) -- no forwarding alongside native bindings
  local tile = list.__raw.children[9]
  assert(tile.__raw.delegates.OnClicked.owner == first and tile.__raw.delegates.OnClicked.handler == "OnLoadoutClicked")
  assert(tile.__raw.delegates.OnLoadoutSaved.owner == first and tile.__raw.delegates.OnLoadoutSlotDeleted.owner == first)
else
  assert(engine.hookCount(W.TILE_RMB) == 1 and engine.hookCount(W.TILE_LMB) == 1 and engine.hookCount(W.TILE_INPUT) == 1)
  local tile = second.__raw.LoadoutList.__raw.children[9]
  local calls = second.__raw.calls
  engine.callBlueprint(W.TILE_RMB, tile)
  assert(#calls == 1 and calls[1][1] == "OnLoadoutSlotSaved" and calls[1][2] == 8)
  tile.__raw.EquippedIconBox.__raw.Visibility = 0
  engine.callBlueprint(W.TILE_RMB, tile); assert(#calls == 1, "no overwrite-save on the equipped loadout")
  tile.__raw.EquippedIconBox.__raw.Visibility = 1
  engine.callBlueprint(W.TILE_LMB, tile); assert(#calls == 1, "empty slots ignore load")
  tile.__raw.IsEmpty = false
  engine.callBlueprint(W.TILE_LMB, tile); assert(#calls == 2)
  engine.callBlueprint(W.TILE_INPUT, tile, nil, tile, 1); assert(#calls == 3 and calls[3][1] == "OnLoadoutClicked")
  engine.callBlueprint(W.TILE_INPUT, tile, nil, tile, 3); assert(#calls == 4)
  assert(calls[4][1] == "OnLoadoutSlotDeleted" and calls[4][2] == 8)
  engine.callBlueprint(W.TILE_RMB, second.__raw.LoadoutList.__raw.children[1])
  assert(#calls == 4, "vanilla tiles already reach the panel")
  assert(#first.__raw.calls == 0, "forwarding targets the current panel")
end
engine.assertClean()
print = realPrint
print("PASS (" .. (native and "native" or "stable forwarding") .. "): spawn patch, probe isolation, reserved indices, once-per-panel setup, bindings and interaction gates.")
