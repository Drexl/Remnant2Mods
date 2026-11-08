-- Standalone in each loadout mod. Keep the two copies identical.
-- Panel work runs in the panel's own Blueprint hooks, on the game thread and
-- serialized by UE4SS with its other Blueprint hooks. Construct calls
-- Refresh(true), which builds the vanilla tiles, so Construct is the readiness
-- point; later Refresh calls retry a panel that was not ready yet.
-- Stable resolves NotifyOnNewObject's class when registering, and a Blueprint
-- class may not be loaded at mod start. Until it is, watch the resident native
-- ancestor only to learn that the class exists, then stop listening.
local M = {}
local PANEL_CLASS = "Widget_LoadoutsPanel_C"
local PANEL_PATH = "/Game/UI2/UI_Widgets/UI_Game/UI_Game_Character/Widget_LoadoutsPanel.Widget_LoadoutsPanel_C"
local TEMPLATE_FLAGS = 0x30 -- RF_ClassDefaultObject | RF_ArchetypeObject
local MAX_ATTEMPTS = 40

function M.new(modName)
  local api = {}
  local onReady
  local beforeHooks = {}
  local panelStates = {}
  local started, installed = false, false

  function api.log(message)
    print("[" .. modName .. "] " .. message .. "\n")
  end

  function api.watchPanels(callback)
    assert(not started and not onReady, "register one panel listener before starting")
    onReady = callback
  end

  -- Registers a panel-class hook ahead of the readiness hooks. Call remove()
  -- only from a hook on a different UFunction.
  function api.beforeReadiness(functionName, callback)
    assert(not started, "add panel hooks before starting")
    local hook = {name = functionName, fn = callback}
    function hook.remove()
      if not hook.ids then return end
      local ids = hook.ids
      hook.ids = nil
      UnregisterHook(PANEL_PATH .. ":" .. hook.name, ids[1], ids[2])
    end
    beforeHooks[#beforeHooks + 1] = hook
    return hook
  end

  -- Address reuse after garbage collection is detected by the unique full name.
  local function stateFor(panel)
    for id, state in pairs(panelStates) do
      if not state.panel:IsValid() then panelStates[id] = nil end
    end
    local id, name = panel:GetAddress(), panel:GetFullName()
    local state = panelStates[id]
    if state and state.name ~= name then state = nil end
    if not state then
      state = {panel = panel, name = name, done = false, attempts = 0}
      panelStates[id] = state
    end
    return state
  end

  local function check(context, constructed)
    local ok, err = pcall(function()
      local panel = context:get()
      if not panel or not panel:IsValid() then return end
      if panel:HasAnyFlags(TEMPLATE_FLAGS) then return end
      local state = stateFor(panel)
      if constructed then state.constructed = true end
      -- The nested Refresh inside Construct waits for Construct to finish.
      if state.done or not state.constructed then return end
      state.attempts = state.attempts + 1
      local list = panel.LoadoutList
      if list and list:IsValid() and list:GetChildrenCount() >= 8 then
        local player = panel:GetOwningPlayer()
        if player and player:IsValid() then
          state.done = true
          api.log("Live Loadouts panel ready: " .. state.name)
          onReady(panel)
          return
        end
      end
      if state.attempts >= MAX_ATTEMPTS then
        state.done = true
        api.log("Panel readiness timed out; no changes made: " .. state.name)
      end
    end)
    if not ok then
      api.log("Panel setup failed: " .. tostring(err))
    end
  end

  local function install()
    if installed then return true end
    local class = StaticFindObject(PANEL_PATH)
    if not class or not class:IsValid() then return false end
    for _, hook in ipairs(beforeHooks) do
      hook.ids = {RegisterHook(PANEL_PATH .. ":" .. hook.name, hook.fn)}
    end
    RegisterHook(PANEL_PATH .. ":Construct", function(context) check(context, true) end)
    RegisterHook(PANEL_PATH .. ":Refresh", function(context) check(context, false) end)
    installed = true
    api.log("Panel lifecycle hooks registered.")
    return true
  end

  function api.start()
    assert(not started and onReady, "register a panel listener and start once")
    started = true
    if install() then return end
    local base = StaticFindObject("/Script/UMG.UserWidget")
    assert(base and base:IsValid(), "native UserWidget class is unavailable")
    NotifyOnNewObject("/Script/UMG.UserWidget", function(widget)
      if installed then return true end
      if not widget or not widget:IsValid() then return false end
      if widget:GetClass():GetFName():ToString() ~= PANEL_CLASS then return false end
      if widget:HasAnyFlags(TEMPLATE_FLAGS) then return false end
      if widget:GetFullName():find("Default__", 1, true) then return false end
      local ok, result = pcall(install)
      if not ok then
        api.log("Panel hook registration failed: " .. tostring(result))
        return false
      end
      return result
    end)
    api.log("Waiting for the Loadouts panel class (no global discovery scans).")
  end
  return api
end

return M
