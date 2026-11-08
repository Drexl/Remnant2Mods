-- Run from repo root: lua tests/game_tick_test.lua
-- HUD-tick scheduler in the modelled UE4SS process; not a native dispatch test.
package.path = "tests/support/?.lua;" .. package.path
local W = require("remnant_world")
local mock = require("ue4ss_mock")

local world = W.new()
local engine = world.engine
local env = engine.loadMod("TickTest", "LoadoutNamer/Scripts", nil, [[
TICK = require("game_tick").new(function(message) print("[TickTest] " .. message) end)
RUNS = {}
]])
local tick, runs = env.TICK, env.RUNS
local TICK_PATH = W.HUD .. ":ReceiveTick"

assert(not tick.install() and not tick.installed(), "no HUD class before entering a world")
world.enterWorld()
assert(tick.install() and tick.install() and engine.hookCount(TICK_PATH) == 1, "registers once")

local function count(name)
  local n = 0
  for _, v in ipairs(runs) do if v == name then n = n + 1 end end
  return n
end

-- Delays count from the tick before queueing; work runs only inside the tick.
tick.later(0, function() runs[#runs + 1] = "now" end)
tick.later(150, function() runs[#runs + 1] = "later" end)
local loops = 0
tick.loop(50, function()
  engine.requireGame("deferred task")
  loops = loops + 1
  return loops == 3
end)
assert(#runs == 0)
world.frame(50)
assert(count("now") == 1 and count("later") == 0 and loops == 1)
world.frame(50, 2)
assert(count("later") == 1 and loops == 3)
world.frame(50, 3)
assert(loops == 3 and count("now") == 1 and count("later") == 1, "finished tasks retire")

-- A Lua error is logged and retires only that task.
tick.later(0, function() error("lua failure") end)
tick.loop(50, function() runs[#runs + 1] = "steady" end)
world.frame(50)
assert(engine.logCount("Deferred UI task failed: ") == 1 and count("steady") == 1)

-- A native exception escapes pcall and ends this tick's dispatch, like UE4SS's
-- TRY. The aborting task is retired; the other loop keeps running.
local aborted = 0
tick.later(0, function() aborted = aborted + 1; error(mock.ABORT, 0) end)
world.frame(50)
assert(#engine.aborts == 1 and engine.aborts[1].path == TICK_PATH and aborted == 1)
world.frame(50, 2)
assert(aborted == 1, "an aborting task never reruns")
assert(count("steady") >= 3, "deferred work continues after an aborted tick")

-- An unreadable or invalid delta preserves queued work and reports the outage
-- once. Only actual valid tick time can advance the delayed task.
local recovered = 0
tick.later(30, function() recovered = recovered + 1 end)
engine.callBlueprint(TICK_PATH, world.hud, nil, nil)
engine.callBlueprint(TICK_PATH, world.hud, nil, nil)
for _, delta in ipairs({-1, 0 / 0, math.huge, 1e308, "invalid"}) do
  engine.callBlueprint(TICK_PATH, world.hud, nil, delta)
end
assert(recovered == 0, "invalid clock samples cannot fabricate elapsed time")
assert(engine.logCount("HUD tick delta unavailable") == 1)
world.frame(15)
assert(recovered == 0)
world.frame(15)
assert(recovered == 1, "pending work survives until enough valid tick time")
assert(engine.logCount("HUD tick delta recovered") == 1)
engine.callBlueprint(TICK_PATH, world.hud, nil, -1)
assert(engine.logCount("HUD tick delta unavailable") == 2, "a later outage is reported")
world.frame(0)
assert(recovered == 1 and engine.logCount("HUD tick delta recovered") == 2)
engine.assertClean()
print("PASS: HUD-tick install gating, delays, loop retirement, Lua errors, escaped native aborts and clock failure/recovery.")
