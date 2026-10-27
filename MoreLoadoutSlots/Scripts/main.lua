print("[MoreLoadoutSlots] Loaded and running.\n")
local runtime = require("loadout_runtime").new("MoreLoadoutSlots")

-- The one knob: total loadout slots (vanilla has 8). Drives both the LoadoutComponent
-- record-capacity patch and how many extra tiles get added to the Loadouts screen; the
-- injected ScrollBox handles however many don't fit in the panel's fixed height.
local TOTAL_LOADOUT_SLOTS = 20

-- Patch the LoadoutComponent's record capacity upward on spawn. Confirmed (research session,
-- see docs/remnant2-modding-research.md 3.4g) that GetMaxRecordsForTemplate directly proxies
-- this field - not currently load-bearing for the single extra tile below (the underlying
-- record storage already supports index 8 with the native default of NumRecords=11), but kept
-- here since going beyond 11 total slots eventually will need it.
RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self, NewPawn)
  print(string.format("[MoreLoadoutSlots] Player spawned - patching LoadoutComponent.Slots[].NumRecords to %d (%d player slots + the reserved last-gear-state record).\n", TOTAL_LOADOUT_SLOTS + 1, TOTAL_LOADOUT_SLOTS))

  ExecuteInGameThread(function()
    local components = FindAllOf("LoadoutComponent")
    if not components then
      print("[MoreLoadoutSlots] WARNING: FindAllOf(\"LoadoutComponent\") returned nothing - NumRecords not patched, extra loadout slots will error when used.\n")
      return
    end

    local componentsPatched, slotsPatched, slotsAttempted = 0, 0, 0
    for i, comp in ipairs(components) do
      if comp:IsValid() then
        local ok, slots = pcall(function() return comp.Slots end)
        if ok and slots then
          -- +1 because record 10 is the game's reserved "last gear state" auto-save - the
          -- visible tiles skip it, so the highest player-facing record index is
          -- TOTAL_LOADOUT_SLOTS (not TOTAL_LOADOUT_SLOTS - 1).
          local anyOk = false
          for j = 1, #slots do
            slotsAttempted = slotsAttempted + 1
            local writeOk = pcall(function() slots[j].NumRecords = TOTAL_LOADOUT_SLOTS + 1 end)
            if writeOk then
              slotsPatched = slotsPatched + 1
              anyOk = true
            end
          end
          if anyOk then
            componentsPatched = componentsPatched + 1
          end
        end
      end
    end
    if slotsPatched < slotsAttempted then
      print(string.format("[MoreLoadoutSlots] WARNING: only patched %d/%d slot(s) across %d/%d LoadoutComponent(s) - some loadout records may still cap at the vanilla limit.\n",
        slotsPatched, slotsAttempted, componentsPatched, #components))
    end
  end)
end)

-- Mod #1 extra-tile logic.
--
-- HAZARD (resolved, but the rule still matters): RegisterHook's "self" parameter is a
-- RemoteUnrealParam wrapper, NOT a plain UObject. Touching it directly crashes: a method
-- call (self:GetFullName()) silently returned nil, and a plain property access
-- (self.LoadoutList) hard-crashed the game with no catchable error. The documented accessor
-- self:get() unwraps it to the real UObject and was safety-tested in ZZTestMod (3 runs, all
-- reads fine afterward). Rule: inside any RegisterHook callback, ALWAYS self:get() first,
-- never touch the raw wrapper.

-- The most recently constructed Loadouts panel. Screen reopens construct a fresh panel each
-- time, so the tile-click hooks below must always act on the CURRENT panel, never a closured
-- stale one (a stale closure was the original cause of the reopen bug).
local currentPanel = nil

-- Full names of every tile widget this mod has created, so the tile-click hooks can tell our
-- tiles apart from the game's own (whose clicks already work via the panel's own delegate
-- subscriptions - reacting to those too would double-trigger their dialogs).
local ourTileFullNames = {}

-- Wire up save/load for OUR tiles. Background (see docs/remnant2-modding-research.md
-- 3.4o/3.4p): a tile's right/left click handlers just broadcast multicast delegates; the
-- panel subscribes its OnLoadoutSlotSaved/OnLoadoutClicked handlers (which own the actual
-- confirmation dialogs and save/load calls) to each tile IT creates. UE4SS Lua cannot bind
-- multicast delegates (unsupported property type in this build), so instead we post-hook the
-- tile class's click handlers - which DO fire on our tiles, since WidgetBlueprintLibrary
-- .Create applied the tile-internal button bindings - and forward the event to the panel's
-- handler ourselves, exactly as the missing delegate subscription would have.
local tileHooksRegistered = false

local function registerTileInteractionHooks()
  if tileHooksRegistered then
    return
  end

  -- Reads the tile's own equipped-state indicator (the EquippedIconBox overlay, whose
  -- visibility the tile's RefreshEquipped keeps in sync by calling the LoadoutComponent's
  -- native IsLoadoutEquipped). Reading the icon avoids calling that native function
  -- ourselves - its parameter signature is unknown, and guess-calling native functions has
  -- crashed the game before (the FText incident).
  local function isTileEquipped(tile)
    local ok, visible = pcall(function() return tile.EquippedIconBox:IsVisible() end)
    return ok and visible == true
  end

  -- The tile keeps its own IsEmpty bool in sync via its Refresh (confirmed in the FModel
  -- dump - it's a class property on Widget_Loadout_C, not a sub-widget's). Same rationale
  -- as isTileEquipped: read the tile's cached state instead of guess-calling the native
  -- HasRecord function.
  local function isTileEmpty(tile)
    local ok, empty = pcall(function() return tile.IsEmpty end)
    return ok and empty == true
  end

  local function forwardTileEventToPanel(selfParam, panelHandlerName, actionLabel, blockedWhenEquipped, blockedWhenEmpty)
    local getOk, tile = pcall(function() return selfParam:get() end)
    if not getOk or not tile or not tile:IsValid() then
      return
    end

    local nameOk, fullName = pcall(function() return tile:GetFullName() end)
    if not nameOk or not fullName or not ourTileFullNames[fullName] then
      return -- one of the game's own tiles; its clicks already reach the panel natively
    end

    if blockedWhenEquipped and isTileEquipped(tile) then
      print(string.format(
        "[MoreLoadoutSlots] %s on this mod's extra tile suppressed - its loadout is currently equipped, and the game disables this action on the equipped loadout (matching vanilla tile behavior).\n",
        actionLabel
      ))
      return
    end

    if blockedWhenEmpty and isTileEmpty(tile) then
      print(string.format(
        "[MoreLoadoutSlots] %s on this mod's extra tile suppressed - the slot is empty, and vanilla tiles ignore this action on empty slots (the vanilla check lives in the tile's own handler, pre-broadcast, so a raw forward would bypass it).\n",
        actionLabel
      ))
      return
    end

    if not currentPanel or not currentPanel:IsValid() then
      print(string.format(
        "[MoreLoadoutSlots] %s detected on one of this mod's extra tiles, but no valid Loadouts panel reference is available to forward it to - ignoring.\n",
        actionLabel
      ))
      return
    end

    local idxOk, idx = pcall(function() return tile.Index end)
    if not idxOk or type(idx) ~= "number" then
      print(string.format(
        "[MoreLoadoutSlots] %s detected on one of this mod's extra tiles, but its Index could not be read - ignoring.\n",
        actionLabel
      ))
      return
    end

    print(string.format(
      "[MoreLoadoutSlots] %s on this mod's extra tile (Index=%d) - forwarding to the panel's %s handler (the game's own tiles get this via a delegate subscription UE4SS can't replicate).\n",
      actionLabel, idx, panelHandlerName
    ))
    ExecuteInGameThread(function()
      local callOk, callErr = pcall(function()
        currentPanel[panelHandlerName](currentPanel, idx)
      end)
      if not callOk then
        print(string.format(
          "[MoreLoadoutSlots] FAILED to call the panel's %s handler: %s\n",
          panelHandlerName, tostring(callErr)
        ))
      end
    end)
  end

  -- Right-click = save. The tile's internal button's OnMouseRightClick is bound (via the
  -- class's ComponentDelegateBinding) to this handler. Suppressed when the tile's loadout is
  -- currently equipped - vanilla tiles disable overwrite-save on the equipped loadout, and
  -- that check lives inside the vanilla tile's own handler (pre-broadcast), so a raw event
  -- forward would bypass it.
  local rmbOk = pcall(function()
    RegisterHook(
      "/Game/UI2/UI_Widgets/UI_Game/UI_Game_Character/Widget_Loadout.Widget_Loadout_C:BndEvt__Widget_Loadout_Button_K2Node_ComponentBoundEvent_0_OnFocusMouseEventDelegate__DelegateSignature",
      function(self)
        forwardTileEventToPanel(self, "OnLoadoutSlotSaved", "Right-click (save)", true, false)
      end
    )
  end)

  -- Left-click = load, same mechanism via the button's OnClicked.
  local lmbOk = pcall(function()
    RegisterHook(
      "/Game/UI2/UI_Widgets/UI_Game/UI_Game_Character/Widget_Loadout.Widget_Loadout_C:BndEvt__Widget_Loadout_Button_K2Node_ComponentBoundEvent_2_OnAdvButtonClickedEvent__DelegateSignature",
      function(self)
        forwardTileEventToPanel(self, "OnLoadoutClicked", "Left-click (load)", false, true)
      end
    )
  end)

  -- Keyboard context-actions (F = delete, Space = equip) never touch the mouse bound events -
  -- they dispatch through the tooltip framework's OnInputAction(ButtonWidget, InputAction)
  -- instead. Enum byte values mapped via a scripted in-game test (see
  -- docs/remnant2-modding-research.md): 1 = equip (Space), 3 = delete (F). Same forwarding
  -- rationale: the vanilla tile's OnInputAction broadcasts delegates only panel-created tiles
  -- have subscribers for.
  local INPUT_ACTION_EQUIP = 1
  local INPUT_ACTION_DELETE = 3

  local keyOk = pcall(function()
    RegisterHook(
      "/Game/UI2/UI_Widgets/UI_Game/UI_Game_Character/Widget_Loadout.Widget_Loadout_C:OnInputAction",
      function(self, ButtonWidgetParam, InputActionParam)
        local actionOk, action = pcall(function() return InputActionParam:get() end)
        if not actionOk then
          return
        end
        if action == INPUT_ACTION_EQUIP then
          forwardTileEventToPanel(self, "OnLoadoutClicked", "Space (equip)", false, true)
        elseif action == INPUT_ACTION_DELETE then
          -- F on an empty slot already no-ops naturally (the panel's delete handler checks
          -- HasRecord itself - confirmed matching vanilla in testing), so no empty gate.
          forwardTileEventToPanel(self, "OnLoadoutSlotDeleted", "F (delete)", false, false)
        end
      end
    )
  end)

  if rmbOk and lmbOk and keyOk then
    tileHooksRegistered = true
    print("[MoreLoadoutSlots] Tile interaction forwarding hooks registered: right-click (save), left-click (load), Space (equip), F (delete).\n")
  else
    print(string.format(
      "[MoreLoadoutSlots] FAILED to register tile interaction forwarding hooks (right-click ok: %s, left-click ok: %s, keyboard ok: %s) - will retry next time the Loadouts screen opens.\n",
      tostring(rmbOk), tostring(lmbOk), tostring(keyOk)
    ))
  end
end

-- Wrap the panel's tile container (LoadoutList) in a runtime-created ScrollBox so more tiles
-- than the panel's fixed 688px can hold stay reachable by scrolling. The vanilla widget tree
-- is SizeBox_0 (fixed height) -> LoadoutList (VerticalBox); we splice a ScrollBox between
-- them: SizeBox_0 -> ScrollBox -> LoadoutList. A plain engine ScrollBox is safe to build with
-- StaticConstructObject - unlike the Blueprint tile widget, it's a raw C++ widget with no
-- Initialize()-time delegate bindings to miss (the thing that forced tiles onto
-- WidgetBlueprintLibrary.Create).
local function injectScrollBox(panel, list)
  -- Already inside a ScrollBox? (Each screen-open builds a fresh panel, so this normally
  -- can't happen - cheap guard against the callback somehow running twice for one panel.)
  local parentOk, parent = pcall(function() return list:GetParent() end)
  if parentOk and parent and parent:IsValid() then
    local classOk, className = pcall(function() return parent:GetClass():GetFullName() end)
    if classOk and className and className:find("ScrollBox") then
      return true
    end
  end

  -- Grab the SizeBox BEFORE detaching the list - after RemoveChild, list.Slot is gone.
  local sizeBoxOk, sizeBox = pcall(function() return list.Slot.Parent end)
  if not sizeBoxOk or not sizeBox or not sizeBox:IsValid() then
    print("[MoreLoadoutSlots] FAILED to reach the SizeBox above LoadoutList - cannot inject the ScrollBox, extra tiles would render off-panel.\n")
    return false
  end

  local scrollClassOk, scrollClass = pcall(function()
    return StaticFindObject("/Script/UMG.ScrollBox")
  end)
  if not scrollClassOk or not scrollClass or not scrollClass:IsValid() then
    print("[MoreLoadoutSlots] FAILED to find the engine ScrollBox class - cannot inject the ScrollBox.\n")
    return false
  end

  local constructOk, scrollBox = pcall(function()
    return StaticConstructObject(scrollClass, panel.WidgetTree)
  end)
  if not constructOk or not scrollBox or not scrollBox:IsValid() then
    print("[MoreLoadoutSlots] FAILED to construct a ScrollBox widget: " .. tostring(scrollBox) .. "\n")
    return false
  end

  local spliceOk, spliceErr = pcall(function()
    sizeBox:RemoveChild(list)
    sizeBox:AddChild(scrollBox)
    scrollBox:AddChild(list)
  end)
  if not spliceOk then
    print("[MoreLoadoutSlots] FAILED to splice the ScrollBox into the widget tree: " .. tostring(spliceErr) .. "\n")
    return false
  end

  print("[MoreLoadoutSlots] ScrollBox injected between the panel's SizeBox and LoadoutList.\n")
  return true
end

-- Whether this UE4SS build supports Lua access to MulticastInlineDelegateProperty
-- (added in experimental-latest, 3.4x). On builds without it, merely READING
-- newTile.OnClicked pierces pcall and aborts the whole enclosing function - not a
-- catchable Lua error - so this is probed once, in isolation, on an EXISTING
-- vanilla tile (index 0, always present) BEFORE the tile-creation loop ever
-- touches the property on a tile of ours. Success is detected by reaching the
-- line after the risky read, never by pcall's return value (which the failure
-- is known to bypass).
local multicastDelegatesProbed = false
local multicastDelegatesSupported = false

local function probeMulticastDelegateSupport(list)
  if multicastDelegatesProbed then
    return
  end
  multicastDelegatesProbed = true
  pcall(function()
    local vanillaTile = list:GetChildAt(0)
    if vanillaTile and vanillaTile:IsValid() then
      local _ = vanillaTile.OnClicked -- the risky read; unreached below if unsupported
      multicastDelegatesSupported = true
    end
  end)
  print(string.format("[MoreLoadoutSlots] Multicast delegate Lua support: %s.\n",
    multicastDelegatesSupported and "yes (native tile bindings will be used)"
      or "no (all tiles will use the hook-forwarding fallback)"))
end

local function addExtraLoadoutTile(panel)
  local TARGET_TILE_COUNT = TOTAL_LOADOUT_SLOTS
  local attempts = 0
  local MAX_ATTEMPTS = 40 -- ~2 seconds at 50ms per attempt, safety cap

  LoopAsync(50, function()
    attempts = attempts + 1

    local listOk, list = pcall(function() return panel.LoadoutList end)
    if not listOk or not list or not list:IsValid() then
      if attempts >= MAX_ATTEMPTS then
        print("[MoreLoadoutSlots] Timed out after " .. attempts .. " polling attempts waiting for the Loadouts screen's tile container (LoadoutList) to finish initializing - giving up for this screen-open, no extra tile added.\n")
        return true -- stop looping
      end
      return false -- keep polling
    end

    -- LoadoutList is valid - safe to proceed. Do the actual work inside the game thread.
    ExecuteInGameThread(function()
      if not injectScrollBox(panel, list) then
        return -- without the ScrollBox, extra tiles would render below the visible panel
      end

      probeMulticastDelegateSupport(list)

      -- Idempotency guard: this whole function can run again on a screen reopen (a fresh
      -- NotifyOnNewObject firing for a newly-constructed panel instance). Skip if the target
      -- count is already met.
      local countOk, currentCount = pcall(function() return list:GetChildrenCount() end)
      if countOk and currentCount and currentCount >= TARGET_TILE_COUNT then
        print(string.format("[MoreLoadoutSlots] Loadouts screen already has %d tiles (target %d) - not adding another.\n", currentCount, TARGET_TILE_COUNT))
        return
      end

      local tileClassOk, tileClass = pcall(function()
        return StaticFindObject("/Game/UI2/UI_Widgets/UI_Game/UI_Game_Character/Widget_Loadout.Widget_Loadout_C")
      end)
      if not tileClassOk or not tileClass or not tileClass:IsValid() then
        print("[MoreLoadoutSlots] FAILED to find the Widget_Loadout_C tile class - cannot add an extra loadout slot this session. Error: " .. tostring(tileClass) .. "\n")
        return
      end

      -- Construct the tile the same way the game's own panel Refresh does: via
      -- WidgetBlueprintLibrary.Create, the native function behind the Blueprint "Create Widget"
      -- node. The earlier StaticConstructObject approach produced a tile that rendered and
      -- showed tooltips but ignored all clicks - the tile class's FModel JSON dump revealed a
      -- ComponentDelegateBinding wiring Button.OnMouseRightClick (save), Button.OnClicked
      -- (load), and mouse enter/leave to the tile's handlers, and those dynamic delegate
      -- bindings are only applied during UUserWidget::Initialize(), which CreateWidget runs
      -- and raw StaticConstructObject skips (Initialize isn't a reflected UFunction, so it
      -- can't be called from Lua after the fact).
      local wblOk, wbl = pcall(function()
        return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
      end)
      if not wblOk or not wbl or not wbl:IsValid() then
        print("[MoreLoadoutSlots] FAILED to find the engine's WidgetBlueprintLibrary (needed to create widgets through the normal UMG lifecycle) - cannot add an extra loadout slot this session. Error: " .. tostring(wbl) .. "\n")
        return
      end

      local templateOk, template = pcall(function()
        return StaticFindObject("/Game/_Core/Loadouts/Gear_Loadout.Gear_Loadout")
      end)
      if not templateOk or not template or not template:IsValid() then
        print("[MoreLoadoutSlots] FAILED to find the Gear_Loadout template asset - cannot configure new tiles. Error: " .. tostring(template) .. "\n")
        return
      end

      -- The owning player for CreateWidget must be the LOCAL player controller. In solo play
      -- FindFirstOf("PlayerController") happened to be it, but in multiplayer other controller
      -- objects exist on this machine and FindFirstOf can return a remote one - CreateWidget
      -- then returns an invalid widget (observed 2026-07-12 in a co-op session: every tile
      -- failed IsValid). The panel widget already knows its owning player, so ask it.
      local playerController = nil
      local ownerOk, owner = pcall(function() return panel:GetOwningPlayer() end)
      if ownerOk and owner and owner:IsValid() then
        playerController = owner
      else
        playerController = FindFirstOf("PlayerController")
        print(string.format("[MoreLoadoutSlots] panel:GetOwningPlayer() unavailable (%s) - falling back to FindFirstOf(\"PlayerController\"); tile creation may fail in multiplayer.\n",
          tostring(owner)))
      end

      -- A tile's clicks broadcast multicast delegates (OnClicked/OnLoadoutSaved/
      -- OnLoadoutSlotDeleted) that the PANEL subscribes to for tiles it creates itself - the
      -- save/load confirmation dialogs live in the panel's handlers, not the tile. Each new
      -- tile below tries to replicate those exact subscriptions natively via the delegate
      -- :Add() API (added in experimental UE4SS; under 3.0.1 merely READING the property
      -- aborted the whole callback despite pcall - see research doc 3.4o). Tiles where the
      -- native binding fails fall back to the hook-forwarding path (registerTileInteraction-
      -- Hooks + the ourTileFullNames registry).

      -- Create one tile per missing slot. Vanilla tiles occupy records 0..7; ours continue
      -- from there - EXCEPT record 10, the game's reserved "last gear state" auto-save
      -- (discovered in testing: a tile at Index=10 self-overwrites on every equip, exactly
      -- like the auto-save slot; native NumRecords=11 = 8 visible + reserved storage). So
      -- our tiles use records 8, 9, 11, 12, ... and each tile whose record index no longer
      -- matches its visible position gets a LabelOverride so the on-screen names stay a
      -- clean "Loadout 9".."Loadout 20" with no gap.
      local RESERVED_RECORD_INDEX = 10
      local addedCount = 0
      local boundCount = 0    -- tiles on the native delegate-subscription path
      local fallbackCount = 0 -- tiles on the hook-forwarding fallback path
      local recordIndex = currentCount
      local visibleCount = currentCount
      while visibleCount < TARGET_TILE_COUNT do
        if recordIndex == RESERVED_RECORD_INDEX then
          recordIndex = recordIndex + 1
        else
          local constructOk, newTile = pcall(function()
            return wbl:Create(panel, tileClass, playerController)
          end)
          if not constructOk or not newTile or not newTile:IsValid() then
            print(string.format("[MoreLoadoutSlots] FAILED to create the tile for record index %d via WidgetBlueprintLibrary.Create - stopping here (%d of the extra tiles were added). Error: %s\n",
              recordIndex, addedCount, tostring(newTile)))
            break
          end

          pcall(function() newTile.Index = recordIndex end)
          pcall(function() newTile.LoadoutTemplate = template end)

          -- Default tile label is "Loadout {Index+1}"; past the reserved record the index
          -- runs ahead of the visible position, so pin the label to the visible position.
          -- FText() wrapping is mandatory - a raw Lua string into an FText slot is the
          -- known hard-crash class (research doc 3.4b), though that was a function call
          -- and this is a property write.
          if recordIndex ~= visibleCount then
            local labelOk, labelErr = pcall(function()
              newTile.LabelOverride = FText(string.format("Loadout %d", visibleCount + 1))
            end)
            if not labelOk then
              print(string.format("[MoreLoadoutSlots] Could not set the label override for the tile at record index %d (it will display its record-derived name instead): %s\n",
                recordIndex, tostring(labelErr)))
            end
          end

          -- Subscribe the panel's handlers to this tile's delegates - the exact bindings the
          -- panel's own Refresh gives the tiles IT creates (delegate names and handler
          -- pairings verified against both FModel dumps). On this path the tile behaves 100%
          -- vanilla: its own handlers gate the equipped/empty cases BEFORE broadcasting, and
          -- all four inputs (LMB/RMB/Space/F) route through these three delegates natively.
          -- Never attempt this when the startup probe found no multicast delegate
          -- support - on those builds even the property READ inside the pcall below
          -- would pierce it and abort this whole tile-creation pass.
          local bindOk, bindErr = false, nil
          if multicastDelegatesSupported then
            bindOk, bindErr = pcall(function()
              newTile.OnClicked:Add(panel, FName("OnLoadoutClicked"))
              newTile.OnLoadoutSaved:Add(panel, FName("OnLoadoutSlotSaved"))
              newTile.OnLoadoutSlotDeleted:Add(panel, FName("OnLoadoutSlotDeleted"))
            end)
          end
          if bindOk then
            boundCount = boundCount + 1
          else
            if multicastDelegatesSupported then
              -- Roll back any binding that DID land before the failure (a half-bound tile on
              -- the fallback path would double-fire that event), then register the tile for
              -- the hook-forwarding fallback.
              pcall(function() newTile.OnClicked:Remove(panel, FName("OnLoadoutClicked")) end)
              pcall(function() newTile.OnLoadoutSaved:Remove(panel, FName("OnLoadoutSlotSaved")) end)
              pcall(function() newTile.OnLoadoutSlotDeleted:Remove(panel, FName("OnLoadoutSlotDeleted")) end)
              print(string.format("[MoreLoadoutSlots] Native delegate binding failed for the tile at record index %d - using the hook-forwarding fallback for it. Error: %s\n",
                recordIndex, tostring(bindErr)))
            end
            fallbackCount = fallbackCount + 1
            pcall(function() ourTileFullNames[newTile:GetFullName()] = true end)
          end

          pcall(function() newTile:Refresh() end)

          local addOk, addResult = pcall(function() return list:AddChild(newTile) end)
          if not addOk then
            print(string.format("[MoreLoadoutSlots] FAILED to add the tile for record index %d into the Loadouts screen's tile list - stopping here (%d of the extra tiles were added). Error: %s\n",
              recordIndex, addedCount, tostring(addResult)))
            break
          end

          addedCount = addedCount + 1
          visibleCount = visibleCount + 1
          recordIndex = recordIndex + 1
        end
      end

      -- The forwarding hooks are only needed for fallback-path tiles (registered lazily
      -- here because the Widget_Loadout_C class is guaranteed loaded at this point, which
      -- isn't true at mod startup).
      if fallbackCount > 0 then
        registerTileInteractionHooks()
      end

      -- The SizeBox stays at its native 688px HeightOverride (8 tiles' worth) on purpose -
      -- the injected ScrollBox handles all overflow. (Historical: before the ScrollBox we
      -- grew the SizeBox itself via list.Slot.Parent:SetHeightOverride - that path is dead,
      -- and list.Slot.Parent now resolves to the ScrollBox, not the SizeBox.)

      print(string.format("[MoreLoadoutSlots] Added %d extra loadout tiles (records %d-%d, skipping the reserved last-gear-state record %d) - the Loadouts screen now has %d slots. Interaction paths: %d native delegate subscriptions, %d hook-forwarding fallbacks.\n",
        addedCount, currentCount, recordIndex - 1, RESERVED_RECORD_INDEX, visibleCount, boundCount, fallbackCount))
    end)

    return true -- stop looping, we found a valid LoadoutList
  end)
end

runtime.watchPanels(function(panel)
  currentPanel = panel
  addExtraLoadoutTile(panel)
end)
runtime.start()
