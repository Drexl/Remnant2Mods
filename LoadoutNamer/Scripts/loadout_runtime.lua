-- Standalone in each loadout mod. Keep the two copies identical.
-- Stable resolves NotifyOnNewObject's class when registering. A Blueprint class
-- may not exist yet, so watch its resident native ancestor and filter events.
local M = {}
local PANEL_CLASS = "Widget_LoadoutsPanel_C"
local TEMPLATE_FLAGS = 0x30 -- RF_ClassDefaultObject | RF_ArchetypeObject

function M.new(modName)
  local api = {}
  local onReady
  local panelStates = {}
  local started = false

  function api.log(message)
    print("[" .. modName .. "] " .. message .. "\n")
  end

  function api.watchPanels(callback)
    assert(not started and not onReady, "register one panel listener before starting")
    onReady = callback
  end

  local function dispatch(panel)
    if not panel or not panel:IsValid() then return end
    if panel:GetClass():GetFName():ToString() ~= PANEL_CLASS then return end
    if panel:HasAnyFlags(TEMPLATE_FLAGS) then return end
    if panel:GetFullName():find("Default__", 1, true) then return end

    for id, state in pairs(panelStates) do
      if not state.panel:IsValid() then panelStates[id] = nil end
    end
    local id = panel:GetAddress()
    if panelStates[id] then return end
    local state = {panel = panel, done = false, queued = false, attempts = 0}
    panelStates[id] = state
    -- Construction can precede the widget tree and owning player. Poll only
    -- this panel, briefly; never scan all UObjects to discover new screens.
    LoopAsync(50, function()
      if state.done then return true end
      if not state.queued then
        state.queued = true
        ExecuteInGameThread(function()
          state.queued = false
          if state.done then return end
          state.attempts = state.attempts + 1
          if not panel:IsValid() then
            state.done = true
            panelStates[id] = nil
            return
          end
          local ok, err = pcall(function()
            local list = panel.LoadoutList
            if list and list:IsValid() and list:GetChildrenCount() >= 8 then
              local player = panel:GetOwningPlayer()
              if player and player:IsValid() then
                state.done = true
                api.log("Live Loadouts panel ready: " .. panel:GetFullName())
                onReady(panel)
              end
            end
          end)
          if not ok then
            state.done = true
            api.log("Panel setup failed: " .. tostring(err))
          elseif not state.done and state.attempts >= 40 then
            state.done = true
            api.log("Panel readiness timed out; no changes made: " .. panel:GetFullName())
          end
        end)
      end
      return state.done
    end)
  end

  function api.start()
    assert(not started and onReady, "register a panel listener and start once")
    started = true
    local base = StaticFindObject("/Script/UMG.UserWidget")
    assert(base and base:IsValid(), "native UserWidget class is unavailable")
    NotifyOnNewObject("/Script/UMG.UserWidget", dispatch)
    api.log("Event-driven runtime started (no global discovery scans).")
  end
  return api
end

return M
