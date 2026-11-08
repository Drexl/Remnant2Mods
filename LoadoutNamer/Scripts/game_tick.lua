-- Standalone in each UI mod that needs deferred work. Keep the copies identical.
-- Deferred UI work runs in the HUD actor's Blueprint tick: a game-thread
-- callback that UE4SS serializes with its other Blueprint hooks and keybinds.
-- UE4SS 3.0.1 runs LoopAsync on a worker thread. ExecuteInGameThread drains
-- inside whichever thread next calls ProcessEvent, and its first call per mod
-- registers a process-wide ProcessEvent callback without synchronization.
-- Neither is used by these mods.
local M = {}
local HUD_CLASS = "/Game/UI/HUD/TPSHud.TPSHud_C"

function M.new(log)
  local api = {}
  local tasks, pending = {}, {}
  local nowMs, installed, clockUnavailable = 0, false, false

  local function run(task)
    local ok, result = pcall(task.fn)
    if not ok then
      log("Deferred UI task failed: " .. tostring(result))
      return true
    end
    return task.interval == nil or result == true
  end

  -- Call only at mod start or from a widget's Construct hook. UE4SS appends the
  -- hook to the callback list that the HUD tick iterates, so registration must
  -- never run inside that iteration, including through code that another mod's
  -- HUD-tick callback can trigger, such as list or panel refreshes.
  function api.install()
    if installed then return true end
    local class = StaticFindObject(HUD_CLASS)
    if not class or not class:IsValid() then return false end
    local ok, err = pcall(RegisterHook, HUD_CLASS .. ":ReceiveTick", function(_, deltaSeconds)
      local readOk, seconds = pcall(function() return deltaSeconds:get() end)
      local ms = readOk and type(seconds) == "number" and seconds * 1000 or nil
      if not ms or ms ~= ms or ms < 0 or ms == math.huge then
        if not clockUnavailable then
          clockUnavailable = true
          log("HUD tick delta unavailable; deferred UI work is waiting.")
        end
        return
      end
      if clockUnavailable then
        clockUnavailable = false
        log("HUD tick delta recovered; deferred UI work resumed.")
      end
      api.advance(ms)
    end)
    if not ok then
      log("Could not register the HUD tick for deferred UI work: " .. tostring(err))
      return false
    end
    installed = true
    log("Deferred UI work runs on the HUD tick.")
    return true
  end

  function api.installed() return installed end

  -- Runs fn once on a later HUD tick.
  function api.later(delayMs, fn)
    pending[#pending + 1] = {due = delayMs, fn = fn}
  end

  -- Runs fn every intervalMs until it returns true.
  function api.loop(intervalMs, fn)
    pending[#pending + 1] = {due = intervalMs, interval = intervalMs, fn = fn}
  end

  -- Game thread only. Tasks queued while running wait for the next tick.
  -- A task is retired before it runs. A native exception that escapes Lua's
  -- pcall therefore drops only that task, and later ticks continue.
  function api.advance(ms)
    -- Delays count from the last tick before the task was queued.
    for _, task in ipairs(pending) do
      task.due = nowMs + task.due
      tasks[#tasks + 1] = task
    end
    pending = {}
    nowMs = nowMs + ms
    for _, task in ipairs({table.unpack(tasks)}) do
      if not task.retired and task.due <= nowMs then
        task.retired = true
        if not run(task) then
          task.retired, task.due = false, nowMs + task.interval
        end
      end
    end
    local kept = {}
    for _, task in ipairs(tasks) do
      if not task.retired then kept[#kept + 1] = task end
    end
    tasks = kept
  end

  return api
end

return M
