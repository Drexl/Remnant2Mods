-- Run from repo root: lua tests/loadout_runtime_test.lua
-- Scheduling/ownership mocks, not a real UE4SS marshaling test.
local function read(path)
  local file = assert(io.open(path, "r"))
  local source = file:read("*a"); file:close()
  return source
end
assert(read("LoadoutNamer/Scripts/loadout_runtime.lua") == read("MoreLoadoutSlots/Scripts/loadout_runtime.lua"),
  "standalone runtime copies must match")
local realPrint = print
local logs, loops, queue, subscribed = {}, {}, {}, {}
local inGameThread = false
print = function(message) logs[#logs + 1] = message end
ExecuteInGameThread = function(fn) queue[#queue + 1] = fn end
LoopAsync = function(_, fn) loops[#loops + 1] = fn end
StaticFindObject = function(path)
  assert(path == "/Script/UMG.UserWidget", "do not resolve an unloaded Blueprint class")
  return {IsValid = function() return true end}
end
NotifyOnNewObject = function(path, fn)
  assert(path == "/Script/UMG.UserWidget")
  subscribed[#subscribed + 1] = fn
end
FindAllOf = function() error("global discovery scans are forbidden") end
local function tickWorker()
  local old = loops; loops = {}
  for _, fn in ipairs(old) do
    if not fn() then loops[#loops + 1] = fn end
  end
end
local function tickGame()
  local old = queue; queue = {}
  inGameThread = true
  for _, fn in ipairs(old) do fn() end
  inGameThread = false
end
local function advance(count)
  for _ = 1, count do tickWorker(); tickGame() end
end
local function panel(id, flags, className)
  local p = {valid = true, count = 0, owner = true}
  p.IsValid = function(self) return self.valid end
  p.GetAddress = function() return id end
  p.GetFullName = function() return "test.Panel" .. id end
  p.GetClass = function()
    return {GetFName = function() return {ToString = function() return className or "Widget_LoadoutsPanel_C" end} end}
  end
  p.HasAnyFlags = function(_, requested) return (requested & (flags or 0)) ~= 0 end
  p.GetOwningPlayer = function(self)
    assert(inGameThread)
    return {IsValid = function() return self.owner end}
  end
  p.LoadoutList = {
    IsValid = function() assert(inGameThread); return true end,
    GetChildrenCount = function() assert(inGameThread); return p.count end,
  }
  return p
end
local runtime = dofile("LoadoutNamer/Scripts/loadout_runtime.lua").new("TestMod")
local ready = {}
runtime.watchPanels(function(p) assert(inGameThread); ready[#ready + 1] = p end)
runtime.start()
assert(#subscribed == 1)
local notify = subscribed[1]
notify(panel(0, nil, "OtherWidget_C"))
notify(panel(1, 0x20))
local cdo = panel(2)
cdo.GetFullName = function() return "test.Default__Panel" end
notify(cdo)
assert(#loops == 0)

local live = panel(3)
notify(live); notify(live)
assert(#loops == 1)
for _ = 1, 100 do tickWorker() end
assert(#queue == 1, "a stalled game thread must not accumulate readiness callbacks")
tickGame()
advance(2)
assert(#ready == 0)
live.count = 4
advance(2)
assert(#ready == 0, "wait for all eight vanilla tiles")
live.count = 8
advance(2)
assert(#ready == 1 and ready[1] == live)
notify(live); advance(2)
assert(#ready == 1, "do not initialize a panel twice")

local destroyed = panel(4)
notify(destroyed)
destroyed.valid = false
advance(2)
assert(#ready == 1)
local noOwner = panel(5)
noOwner.count, noOwner.owner = 8, false
notify(noOwner)
advance(45)
assert(#ready == 1 and #loops == 0, "bound readiness work for asset/ownerless panels")
local reused = panel(4)
reused.count = 8
notify(reused); advance(2)
assert(#ready == 2 and ready[2] == reused)
local reopened = panel(6)
reopened.count = 8
notify(reopened); advance(2)
assert(#ready == 3 and ready[3] == reopened)
advance(100)
assert(#loops == 0 and #queue == 0)
print = realPrint
print("PASS: cold-start native ancestor, template/owner/readiness/lifetime guards, deduplication, bounded work; no scans.")
