-- One rename at a time, including queued opens/closes. UObject work stays on the
-- game thread; the worker only schedules a single outstanding observation.
local M = {}

function M.new(close, log)
  local api, current = {}, nil

  local function finish(session, commit)
    if current ~= session then return end
    if session.closing then
      -- Escape wins over a blur/Enter already waiting in the game-thread queue.
      if not commit then session.commit = false end
      return
    end
    session.closing, session.commit = true, commit
    ExecuteInGameThread(function()
      if current ~= session then return end
      current, session.closed = nil, true
      local ok, err = pcall(close, session, session.commit)
      if not ok then log("Rename cleanup failed: " .. tostring(err)) end
    end)
  end

  local function hasFocus(box)
    -- EditableTextBox forwards keyboard focus to its internal Slate text widget.
    return box:HasKeyboardFocus() or box:HasFocusedDescendants()
  end

  local function requestFocus(session)
    session.focusAttempts = session.focusAttempts + 1
    session.box:SetKeyboardFocus()
    session.focused = hasFocus(session.box)
  end

  function api.active()
    return current ~= nil
  end

  function api.finish(commit)
    if current then finish(current, commit) end
  end

  function api.pointerPressed()
    local session = current
    if not session or session.closing then return end
    ExecuteInGameThread(function()
      if current ~= session or session.closing then return end
      local ok, err = pcall(function()
        if not session.box or not session.box:IsValid() then
          finish(session, false)
        elseif not session.box:IsHovered() then
          -- Blank/non-focusable UI may leave keyboard focus in the editor.
          -- Observe clicks as well as blur; never consume the game's click.
          finish(session, true)
        end
      end)
      if not ok then
        log("Rename click-away check failed: " .. tostring(err))
        finish(session, false)
      end
    end)
  end

  function api.open(session, create)
    if current then return false end
    current = session -- reserve before queuing, so repeated F2 cannot open twice
    session.focusAttempts, session.blurTicks = 0, 0
    ExecuteInGameThread(function()
      if current ~= session or session.closing then return end
      local ok, err = pcall(function()
        assert(session.tile and session.tile:IsValid(), "loadout tile is unavailable")
        create(session)
        assert(session.box and session.box:IsValid(), "rename box is unavailable")
        requestFocus(session)
      end)
      if not ok then
        log("Could not focus/open the rename box: " .. tostring(err))
        finish(session, false)
        return
      end

      LoopAsync(50, function()
        if current ~= session or session.closing then return true end
        if not session.queued then
          session.queued = true
          ExecuteInGameThread(function()
            session.queued = false
            if current ~= session or session.closing then return end
            local observed, observeErr = pcall(function()
              if not session.box:IsValid() or not session.tile:IsValid() then
                finish(session, false)
                return
              end
              if hasFocus(session.box) then
                session.focused, session.blurTicks = true, 0
              elseif not session.focused then
                -- A newly attached Slate widget may not accept focus until the
                -- next frame. Retry briefly, but never steal focus after blur.
                if session.focusAttempts < 4 then
                  requestFocus(session)
                else
                  log("Rename box did not accept keyboard focus; cancelling.")
                  finish(session, false)
                end
              else
                session.blurTicks = session.blurTicks + 1
                -- Give Enter/Escape keybinds time to choose commit/cancel before
                -- interpreting Slate's own key-driven defocus as a click away.
                if session.blurTicks >= 2 then finish(session, true) end
              end
            end)
            if not observed then
              log("Rename focus check failed: " .. tostring(observeErr))
              finish(session, false)
            end
          end)
        end
        return current ~= session or session.closing
      end)
    end)
    return true
  end

  return api
end

return M
