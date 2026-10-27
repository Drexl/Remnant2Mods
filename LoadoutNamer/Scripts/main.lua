print("[LoadoutNamer] Loaded and running.\n")

-- Mod #2: custom names for loadout slots.
--   Hover a loadout tile and press the rename key (F2 by default, configurable via
--   settings.txt) -> a text box opens in the tile's title row. Type the new name, then
--   Enter or the rename key commits; Escape cancels. Names persist per-character in
--   loadout_names.txt next to this mod (one "characterID<TAB>recordIndex<TAB>name"
--   line per slot) and are re-applied every time the Loadouts panel is constructed.
--   The hover tooltip's title also shows the (full, untruncated) name; long names
--   show truncated on the tile itself.
--
-- Everything here composes building blocks proven in ZZTestMod probe rounds 1-2
-- (research doc 3.4y/3.4z): LabelOverride FText writes survive the game's own
-- refreshes; EditableTextBox injection + Text reads work; RegisterKeyBind fires in
-- menu context; the OnMouseEnter bound-event hook gives hover identity.

local runtime = require("loadout_runtime").new("LoadoutNamer")
local styles = require("loadout_style")
local MOUSE_ENTER_FN = "/Game/UI2/UI_Widgets/UI_Game/UI_Game_Character/Widget_Loadout.Widget_Loadout_C:BndEvt__Widget_Loadout_Button_K2Node_ComponentBoundEvent_4_OnAdvButtonClickedEvent__DelegateSignature"

-- Record 10 is the game's reserved last-gear-state auto-save (research doc 3.4w); it
-- renders as the hoverable "Last Gear State" tile on the character screen (3.4z).
local RESERVED_RECORD_INDEX = 10

-- Longest name a slot can keep (storage cap). The full name shows in the hover
-- tooltip's title, which is much wider than the tile.
local MAX_NAME_LENGTH = 32

-- The tile label (GFGRemnantCracked font, size 12, rendered uppercase) runs off the
-- tile's right edge somewhere past ~18 characters - there's no wrapping or ellipsis -
-- so names longer than this are shown truncated on the tile (full name in the tooltip).
local TILE_LABEL_MAX = 18

-- The hover tooltip (Widget_LoadoutTooltip dump): its title is an ItemLabel TextBlock
-- whose text is the static string "Loadout" (dump line ~2186) - the game never varies
-- it, so writing it per-hover is safe and writing the literal back restores default.
local TOOLTIP_CLASS_NAME = "Widget_LoadoutTooltip_C"
local TOOLTIP_DEFAULT_TITLE = "Loadout"

-- The tile label's font asset, from dev-data/Widget_Loadout.json (~3574-3580). Loaded
-- whenever the character screen is up, so StaticFindObject finds it when we need it.
-- StaticFindObject needs the FULL object path (Package.ObjectName) - the bare package
-- path fails with "GetPackageNameFromLongName: Name wasn't long" (2026-07-13 log).
local EDIT_FONT_PATH = "/Game/UI/Fonts/GFGRemnantCracked_Font.GFGRemnantCracked_Font"

-- The game's reusable key-glyph widget (dev-data/Widget_KeyIcon.json): Background image
-- + KeyText TextBlock. Used for the tooltip's "F2 Rename" prompt.
local KEYICON_CLASS_PATH = "/Game/UI/UI_Widgets/Widget_KeyIcon.Widget_KeyIcon_C"

-- MoreLoadoutSlots builds the panel out to 20 tiles; waiting for that count sequences
-- our apply-names pass after its label pass with no explicit coordination (3.4y).
-- If that mod is ever disabled, the 8-tile vanilla panel would time the poll out - the
-- fallback below then applies names to however many tiles exist.
local EXPECTED_TILES = 20

-- ============================== name store ==============================

-- The game's io working directory is the game exe dir; which relative prefix reaches
-- this (symlinked) mod folder depends on the UE4SS layout, so probe candidates once.
local NAMES_FILE_CANDIDATES = {
  "ue4ss/Mods/LoadoutNamer/loadout_names.txt",
  "Mods/LoadoutNamer/loadout_names.txt",
}

local namesFilePath = nil
local names = {} -- [characterID][recordIndex] = custom name
local legacyNames = {} -- [recordIndex] = name, pre-update entries pending migration once a character ID is known
local saveNames -- forward-declared: migrateLegacyNamesIfNeeded (below) calls it before its own definition further down

-- Which of the 4 character-select slots is active right now (SavedCharacter.ID,
-- research 2026-08-04 - see resolveActiveCharacterID below). Refreshed on every
-- apply pass so it's always current by the time the player can interact.
local activeCharacterID = nil
local FALLBACK_CHARACTER_ID = 0
local fallbackWarned = false

-- Every read/write of a saved name goes through these three so callers never touch
-- `names` directly - keeps the character-scoping in one place.
local function characterKey()
  if activeCharacterID ~= nil then
    return activeCharacterID
  end
  if not fallbackWarned then
    fallbackWarned = true
    print("[LoadoutNamer] WARNING: could not resolve the active character's ID yet - names will use a shared fallback store until this resolves (usually on the next Loadouts screen open).\n")
  end
  return FALLBACK_CHARACTER_ID
end

local function getName(recordIndex)
  local t = names[characterKey()]
  return t and t[recordIndex]
end

local function setName(recordIndex, name)
  local key = characterKey()
  local t = names[key]
  if not t then
    t = {}
    names[key] = t
  end
  t[recordIndex] = name
end

local function clearName(recordIndex)
  local t = names[characterKey()]
  if t then
    t[recordIndex] = nil
  end
end

-- Merges pre-update (recordIndex-only) entries into the first character that loads
-- after this update, then rewrites the file in the new per-character format. Only
-- runs once (legacyNames is emptied after). User-decided migration behavior
-- (2026-08-04): auto-assign to whichever character loads first rather than
-- discarding, since these names predate per-character keying and there's no way
-- to recover which character they actually belonged to.
local function migrateLegacyNamesIfNeeded()
  if not next(legacyNames) or activeCharacterID == nil then
    return
  end
  local target = names[activeCharacterID]
  if not target then
    target = {}
    names[activeCharacterID] = target
  end
  local migrated = 0
  for idx, nm in pairs(legacyNames) do
    if target[idx] == nil then
      target[idx] = nm
      migrated = migrated + 1
    end
  end
  legacyNames = {}
  if migrated > 0 then
    print(string.format("[LoadoutNamer] Migrated %d pre-update name(s) to character ID %d (the first character loaded after this update) - if any ended up on the wrong character, just F2-rename them there; loadout_names.txt now stores names per character.\n", migrated, activeCharacterID))
    saveNames()
  end
end

local function firstNonDefault(className)
  local found = nil
  pcall(function()
    local all = FindAllOf(className)
    if all then
      for _, obj in ipairs(all) do
        if obj:IsValid() and not obj:GetFullName():find("Default__") then
          found = obj
          break
        end
      end
    end
  end)
  return found
end

-- Confirmed 2026-08-04 via ZZTestMod F9 probe: GameInstance.CharacterManager is a
-- RemnantCharacterManager whose GetActiveCharacter() returns a SavedCharacter struct
-- with an ID int property that matches the "SELECT CHARACTER" slot (0-3 for the 4
-- tabs) - the per-character identity this store was missing (all names used to be
-- keyed by recordIndex alone, so they leaked across characters). Both calls are
-- non-mutating, no-arg getters - the safe end of the risk ladder; H8's caution about
-- native calls is specifically about RegisterHook bodies, not game-thread reads like
-- this (called from the apply pass, already on the game thread).
local function resolveActiveCharacterID()
  local id = nil
  local gi = firstNonDefault("GameInstance")
  if gi and gi:IsValid() then
    pcall(function()
      local charMgr = gi.CharacterManager
      if charMgr and charMgr:IsValid() and charMgr:HasActiveCharacter() then
        local active = charMgr:GetActiveCharacter()
        if active and active:IsValid() then
          id = active.ID
        end
      end
    end)
  end
  return id
end

local function resolveNamesFilePath()
  for _, path in ipairs(NAMES_FILE_CANDIDATES) do
    local f = io.open(path, "r")
    if f then
      f:close()
      return path
    end
  end
  for _, path in ipairs(NAMES_FILE_CANDIDATES) do
    local f = io.open(path, "a") -- creates an empty file where writable
    if f then
      f:close()
      return path
    end
  end
  return nil
end

-- File format is `characterID<TAB>recordIndex<TAB>name` (2026-08-04, per-character
-- keying added - see resolveActiveCharacterID). Lines from before that update are
-- `recordIndex<TAB>name` (2 columns) - those fall into legacyNames and get merged
-- into whichever character loads first (migrateLegacyNamesIfNeeded).
local function loadNames()
  namesFilePath = resolveNamesFilePath()
  if not namesFilePath then
    print("[LoadoutNamer] WARNING: no writable names-file location found (tried: " .. table.concat(NAMES_FILE_CANDIDATES, ", ") .. ") - renames will work but WILL NOT persist across sessions.\n")
    return
  end
  local count, legacyCount = 0, 0
  local f = io.open(namesFilePath, "r")
  if f then
    for line in f:lines() do
      local charId, idx, name = line:match("^(%d+)\t(%d+)\t(.+)$")
      if charId and idx and name then
        charId, idx = tonumber(charId), tonumber(idx)
        -- Enforce the length cap on pre-existing entries too (older saves may predate it).
        local trimmed = name:sub(1, MAX_NAME_LENGTH):match("^(.-)%s*$")
        names[charId] = names[charId] or {}
        names[charId][idx] = trimmed
        count = count + 1
      else
        local legIdx, legName = line:match("^(%d+)\t(.+)$")
        if legIdx and legName then
          legacyNames[tonumber(legIdx)] = legName:sub(1, MAX_NAME_LENGTH):match("^(.-)%s*$")
          legacyCount = legacyCount + 1
        end
      end
    end
    f:close()
  end
  print(string.format("[LoadoutNamer] Names file: %s (%d saved name(s) loaded%s).\n", namesFilePath, count,
    legacyCount > 0 and string.format(", %d pre-update name(s) pending migration to the active character", legacyCount) or ""))
end

saveNames = function()
  if not namesFilePath then
    return
  end
  local f, err = io.open(namesFilePath, "w")
  if not f then
    print("[LoadoutNamer] FAILED to write the names file: " .. tostring(err) .. "\n")
    return
  end
  for charId, charNames in pairs(names) do
    for idx, name in pairs(charNames) do
      f:write(string.format("%d\t%d\t%s\n", charId, idx, name))
    end
  end
  f:close()
end

loadNames()

-- ============================== settings ==============================

-- Same io-path uncertainty as the names file (game exe dir differs by UE4SS layout).
local SETTINGS_FILE_CANDIDATES = {
  "ue4ss/Mods/LoadoutNamer/settings.txt",
  "Mods/LoadoutNamer/settings.txt",
}

local DEFAULT_RENAME_KEY_NAME = "F2"
local renameKeyName = DEFAULT_RENAME_KEY_NAME
local renameKey = Key.F2

-- Writes a fresh settings.txt with the default so the option is discoverable without
-- reading the README - same reasoning as loadNames() creating an empty names file.
local function writeDefaultSettings()
  for _, path in ipairs(SETTINGS_FILE_CANDIDATES) do
    local f = io.open(path, "w")
    if f then
      f:write("# LoadoutNamer settings\n")
      f:write("# RenameKey: the key that opens/commits the rename box while hovering a loadout tile.\n")
      f:write("# Must match a UE4SS Key enum name (e.g. F1-F12, letters, digits) - see docs.ue4ss.com.\n")
      f:write(string.format("RenameKey=%s\n", DEFAULT_RENAME_KEY_NAME))
      f:close()
      return
    end
  end
end

local function loadSettings()
  local found = false
  for _, path in ipairs(SETTINGS_FILE_CANDIDATES) do
    local f = io.open(path, "r")
    if f then
      found = true
      for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and v and v ~= "" and k:lower() == "renamekey" then
          local candidate = Key[v:upper()]
          if candidate then
            renameKeyName = v:upper()
            renameKey = candidate
          else
            print(string.format("[LoadoutNamer] settings.txt: '%s' isn't a recognized key name - keeping default %s.\n", v, DEFAULT_RENAME_KEY_NAME))
          end
        end
      end
      f:close()
      break
    end
  end
  if not found then
    writeDefaultSettings()
  end
  print(string.format("[LoadoutNamer] Rename key: %s%s.\n", renameKeyName,
    renameKeyName == DEFAULT_RENAME_KEY_NAME and "" or " (from settings.txt)"))
end

loadSettings()

-- ============================== labels ==============================

-- What a slot shows with no custom name. Records 0-9 derive "Loadout {Index+1}"
-- natively, so an empty override lets the tile regenerate it; records 11+ carry the
-- "Loadout N" override MoreLoadoutSlots pins on them (label number == record index
-- past the reserved record), so removing a custom name must restore that, not blank.
local function defaultLabelFor(recordIndex)
  if recordIndex > RESERVED_RECORD_INDEX then
    return string.format("Loadout %d", recordIndex)
  end
  return ""
end

-- Game thread only.
local function writeLabel(tile, text)
  local ok, err = pcall(function()
    tile.LabelOverride = FText(text)
    tile:Refresh()
  end)
  if not ok then
    print("[LoadoutNamer] FAILED to write a tile label: " .. tostring(err) .. "\n")
  end
  return ok
end

-- What the tile itself displays for a custom name: truncated with a ".." marker when
-- it would run off the tile. The stored name stays full-length for the tooltip.
local function tileTextFor(name)
  if #name > TILE_LABEL_MAX then
    return name:sub(1, TILE_LABEL_MAX - 2) .. ".."
  end
  return name
end

-- Game thread only. Puts the slot's correct at-rest label on the tile.
local function applyRestingLabel(tile, recordIndex)
  local name = getName(recordIndex)
  writeLabel(tile, name and tileTextFor(name) or defaultLabelFor(recordIndex))
end

-- ============================== apply pass ==============================

-- Game thread only. Writes saved names onto tiles 0..count-1. Only ever touches tiles
-- that HAVE a saved name (the `getName(idx)` guard below) - it never writes a tile's
-- default label, so it can never race MoreLoadoutSlots' own default-label pass no
-- matter which order the two mods' hooks run in. That's what makes calling this
-- repeatedly, on whatever tile count exists at the time, safe and idempotent.
local function applyNamesToCount(panel, count)
  -- Refreshed every apply pass (every Loadouts screen construction) rather than
  -- cached once - cheap (one read-only getter call), and this is what makes a
  -- character switch (which reconstructs the whole panel/world) pick up the right
  -- character's names instead of the previous character's.
  local resolvedId = resolveActiveCharacterID()
  if resolvedId ~= nil and resolvedId ~= activeCharacterID then
    activeCharacterID = resolvedId
    migrateLegacyNamesIfNeeded()
    print(string.format("[LoadoutNamer] Active character ID: %d.\n", activeCharacterID))
  end

  local applied = 0
  for i = 0, count - 1 do
    local ok = pcall(function()
      local tile = panel.LoadoutList:GetChildAt(i)
      local idx = tile.Index
      local nm = getName(idx)
      if nm then
        if writeLabel(tile, tileTextFor(nm)) then
          applied = applied + 1
        end
      end
    end)
    if not ok then
      print(string.format("[LoadoutNamer] Could not read tile %d during the apply-names pass - skipping it.\n", i))
    end
  end
  if applied > 0 then
    print(string.format("[LoadoutNamer] Applied %d saved names to the Loadouts panel.\n", applied))
  end
end

-- MoreLoadoutSlots injects its extra tiles synchronously - one panel-construction poll
-- cycle takes the tile count straight from 8 to EXPECTED_TILES in a single tick, it
-- never grows gradually (see MoreLoadoutSlots/Scripts/main.lua addExtraLoadoutTile).
-- So there's nothing to "wait until it's safe" for: apply on the very first tick to
-- whatever tile count already exists (instant in the common case, including without
-- MoreLoadoutSlots), then keep polling only to catch a LATER count change (that mod
-- present but still mid-injection) and redo the pass when it happens. Previously this
-- blocked the first apply on reaching EXPECTED_TILES, which without MoreLoadoutSlots
-- (vanilla 8-tile panel, count never reaches it) burned the full ~4s timeout on every
-- panel construction before applying anything - the couple-second delay reported
-- 2026-07-17.
local function applySavedNames(panel)
  local attempts = 0
  local MAX_ATTEMPTS = 80 -- ~4s safety cap on how long to keep watching for a late count change
  local lastAppliedCount = -1

  LoopAsync(50, function()
    attempts = attempts + 1

    local countOk, count = pcall(function() return panel.LoadoutList:GetChildrenCount() end)
    local haveList = countOk and count and count > 0

    if not haveList then
      return attempts >= MAX_ATTEMPTS -- benign non-UI panel instance; nothing to do
    end

    if count ~= lastAppliedCount then
      lastAppliedCount = count
      ExecuteInGameThread(function() applyNamesToCount(panel, count) end)
    end

    return count >= EXPECTED_TILES or attempts >= MAX_ATTEMPTS
  end)
end

-- ============================== tooltip rename prompt ==============================

-- Adds an "F2 Rename" entry to the tooltip's action-button footer. The footer widget
-- (Widget_Tooltip_Actions_C, a named variable on the tooltip) has an ExtraActionList
-- HorizontalBox that exists precisely for extra entries, so this is the game's own
-- extension point - we append a real Widget_KeyIcon (the game's key-glyph widget,
-- created through WidgetBlueprintLibrary.Create so it initializes like the game's own)
-- plus a TextBlock label styled like the tile text.
-- One prompt per live tooltip instance: more than one tooltip can be alive at once
-- (hovering tile B while tile A's tooltip still exists), so track by the instance's
-- ExtraActionList full name. A single global reference here caused an alternating
-- recreate loop that stacked duplicate prompts (2026-07-13 test).
local promptsByExtra = {} -- [ExtraActionList full name] = { icon = ..., label = ... }

-- Scalar writes were read back successfully on the installed stable runtime.
-- Never assign Font/ColorAndOpacity/WidgetStyle userdata back as whole structs.
local promptStyleLogged = false
local function gameFont(sourceLabel)
  local font = StaticFindObject(EDIT_FONT_PATH)
  if font and font:IsValid() then return font end
  return sourceLabel.Font.FontObject -- the already-loaded vanilla font
end

local function applyPromptLabelStyle(label, sourceLabel)
  local ok, err = pcall(function() styles.prompt(label, gameFont(sourceLabel)) end)
  if not ok then
    runtime.log("Rename-prompt styling failed: " .. tostring(err))
  elseif not promptStyleLogged then
    promptStyleLogged = true
    runtime.log("Rename-prompt scalar styling applied.")
  end
end

-- Game thread only. Idempotent - called on every tooltip-poll tick.
local function ensureRenamePrompt(tooltip, recordIndex)
  local ok, err = pcall(function()
    local actions = tooltip.Widget_Tooltip_Actions
    if not actions or not actions:IsValid() then
      return
    end
    local extra = actions.ExtraActionList
    if not extra or not extra:IsValid() then
      return
    end

    -- Already installed in THIS tooltip instance? Validate the stored widgets are
    -- alive AND still parented here (an object name can be recycled by a new
    -- instance after the old one is garbage-collected).
    local extraName = extra:GetFullName()
    local entry = promptsByExtra[extraName]
    local present = false
    pcall(function()
      if entry and entry.icon:IsValid() and entry.label:IsValid() then
        local parent = entry.icon:GetParent()
        present = parent and parent:IsValid() and parent:GetFullName() == extraName
      end
    end)

    if not present then
      local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
      local keyIconClass = StaticFindObject(KEYICON_CLASS_PATH)
      if not (wbl and wbl:IsValid() and keyIconClass and keyIconClass:IsValid()) then
        return
      end
      -- Owning player must come from an owned widget, never FindFirstOf (multiplayer
      -- rule, research doc 3.4z).
      local player = tooltip:GetOwningPlayer()
      if not player or not player:IsValid() then
        return
      end

      local keyIcon = wbl:Create(tooltip, keyIconClass, player)
      if not keyIcon or not keyIcon:IsValid() then
        print("[LoadoutNamer] Could not create the KeyIcon widget for the tooltip's Rename prompt.\n")
        return
      end

      local label = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), tooltip.WidgetTree)
      if not label or not label:IsValid() then
        return
      end

      -- All styling is leaf-only and runs before Slate builds the label.
      applyPromptLabelStyle(label, tooltip.ItemLabel)

      extra:AddChild(keyIcon)
      extra:AddChild(label)
      -- Center the label vertically in the action row like the game's own prompt
      -- labels (2 = VAlign_Center). The slot only exists after AddChild.
      pcall(function() label.Slot:SetVerticalAlignment(2) end)

      entry = { icon = keyIcon, label = label }
      promptsByExtra[extraName] = entry
      print(string.format("[LoadoutNamer] '%s Rename' prompt added to the loadout tooltip's action row.\n", renameKeyName))
    end

    -- Re-assert the texts every tick: the KeyIcon's own Construct may derive KeyText
    -- from its (unset) InputActionName after we first write it, and SetText is cheap.
    pcall(function() entry.icon.KeyText:SetText(FText(renameKeyName)) end)
    pcall(function() entry.label:SetText(FText("Rename")) end)

    -- The reserved Last Gear State record can't be renamed - hide the prompt there.
    local vis = (recordIndex == RESERVED_RECORD_INDEX) and 1 or 0 -- 1 = Collapsed
    pcall(function() entry.icon:SetVisibility(vis) end)
    pcall(function() entry.label:SetVisibility(vis) end)
  end)
  if not ok then
    print("[LoadoutNamer] Rename-prompt injection failed: " .. tostring(err) .. "\n")
  end
end

-- ============================== tooltip title ==============================

-- Write the hovered slot's name (or the "Loadout" default) into the tooltip's title.
-- The tooltip widget is created/shown by the game some time after mouse-enter, so a
-- short poll finds it and keeps rewriting for ~1s to land after the game's own setup.
-- A generation counter cancels stale polls when the hover moves on.
local tooltipGen = 0

local function scheduleTooltipTitle(recordIndex)
  tooltipGen = tooltipGen + 1
  local gen = tooltipGen
  local title = getName(recordIndex) or TOOLTIP_DEFAULT_TITLE
  local attempts = 0
  local logged = false

  LoopAsync(50, function()
    if gen ~= tooltipGen then
      return true -- a newer hover superseded this poll
    end
    attempts = attempts + 1

    pcall(function()
      local tooltips = FindAllOf(TOOLTIP_CLASS_NAME)
      if tooltips then
        for _, tt in ipairs(tooltips) do
          -- Skip the class-default object: writing its template would leak the
          -- title into every future tooltip instance.
          if tt:IsValid() and not tt:GetFullName():find("Default__") then
            ExecuteInGameThread(function()
              -- The hover may have moved on between this callback being queued and the
              -- game thread actually running it - re-check so a stale generation doesn't
              -- still do work (and doesn't add to how many of these can be in flight at
              -- once when the mouse sweeps quickly across several tiles).
              if gen ~= tooltipGen then
                return
              end
              pcall(function() tt.ItemLabel:SetText(FText(title)) end)
              ensureRenamePrompt(tt, recordIndex)
            end)
            if not logged then
              logged = true
              print(string.format("[LoadoutNamer] Tooltip title set for record %d ('%s').\n", recordIndex, title))
            end
          end
        end
      end
    end)

    return attempts >= 20 -- ~1s of coverage
  end)
end

-- ============================== tab hotkey suppression ==============================

-- The in-game menu's T/I/M keys switch tabs even while the rename box has keyboard
-- focus, and UE4SS can't consume input. But the game gates each switch on the tab
-- button's own visibility (ZZTestMod probe: FocusTraits/FocusInventory/FocusMap still
-- fire with the buttons hidden, then early-out on an IsVisible check). So: hide those
-- tab buttons for the duration of an edit. Hidden (ESlateVisibility 2) - not Collapsed -
-- keeps their layout space, so the tab bar doesn't reflow; the labels just fade out.
-- The game resets tab visibility itself when the menu reopens, so a leaked Hidden
-- state (screen closed mid-edit) self-heals.
local TAB_HOTKEY_PROPS = { "TraitTab", "InventoryTab", "MapTab" }
local hiddenTabs = {}

-- GetParent() only walks nesting WITHIN one UserWidget's own internal tree - tried
-- walking up from the tile (2026-07-17) to find the owning Widget_InGameMenu_C
-- directly, but it dead-ends at the CanvasPanel root of Widget_LoadoutsPanel_C's own
-- tree every time (confirmed via logged chain: Widget_Loadout_C -> VerticalBox ->
-- ScrollBox -> SizeBox -> VerticalBox -> RemnantCursorPanel -> Overlay -> CanvasPanel
-- -> invalid). Crossing from a nested UserWidget into the tree that embeds it isn't a
-- parent-slot relationship, so there's no further GetParent() hop to take - abandoned.
--
-- Back to a global FindAllOf, but disambiguating candidates by IsVisible() (only the
-- on-screen instance should be visible; the "last non-Default__ found" heuristic this
-- replaced could land on a stale instance depending on FindAllOf's iteration order -
-- the likely cause of the original intermittent failure). IsVisible() is already the
-- confirmed-working signal this file gates the tabs themselves on (3.4aa).
local function findOwningMenu()
  local visible = {}
  local totalNonDefault = 0
  pcall(function()
    local all = FindAllOf("Widget_InGameMenu_C")
    if all then
      for _, m in ipairs(all) do
        if m:IsValid() and not m:GetFullName():find("Default__") then
          totalNonDefault = totalNonDefault + 1
          local visOk, vis = pcall(function() return m:IsVisible() end)
          if visOk and vis then
            table.insert(visible, m)
          end
        end
      end
    end
  end)
  if #visible == 1 then
    return visible[1]
  end
  print(string.format("[LoadoutNamer] findOwningMenu: %d non-default Widget_InGameMenu_C instance(s), %d visible - %s.\n",
    totalNonDefault, #visible,
    #visible == 0 and "none usable" or "using the last visible one"))
  return visible[#visible] -- nil if #visible == 0
end

-- Game thread only.
local function suppressTabHotkeys()
  local menu = findOwningMenu()
  if not menu then
    print("[LoadoutNamer] WARNING: could not find a visible Widget_InGameMenu_C - T/I/M tab hotkeys will NOT be suppressed for this edit.\n")
    return
  end
  local suppressed = 0
  for _, prop in ipairs(TAB_HOTKEY_PROPS) do
    local ok, err = pcall(function()
      local tab = menu[prop]
      -- Only touch tabs the game is currently showing, so restore can't force-show
      -- a tab the game itself hides in this context.
      if tab and tab:IsValid() and tab:IsVisible() then
        tab:SetVisibility(2) -- Hidden: blocks the hotkey, keeps layout space
        table.insert(hiddenTabs, tab)
        suppressed = suppressed + 1
      end
    end)
    if not ok then
      print(string.format("[LoadoutNamer] WARNING: failed to suppress the %s tab hotkey: %s\n", prop, tostring(err)))
    end
  end
  if suppressed < #TAB_HOTKEY_PROPS then
    print(string.format("[LoadoutNamer] Tab hotkey suppression: %d/%d tabs hidden (the rest were already not visible in this context, or failed - see above).\n", suppressed, #TAB_HOTKEY_PROPS))
  end
end

-- Game thread only.
local function restoreTabHotkeys()
  for _, tab in ipairs(hiddenTabs) do
    local ok, err = pcall(function()
      if tab:IsValid() then
        tab:SetVisibility(0) -- Visible
      end
    end)
    if not ok then
      print("[LoadoutNamer] WARNING: failed to restore a tab's visibility after a rename: " .. tostring(err) .. "\n")
    end
  end
  hiddenTabs = {}
end

-- ============================== edit box styling ==============================

-- Target look, from dev-data/Widget_Loadout.json (~3565-3581): the tile label is
-- EDIT_FONT_PATH size 12, color 0.7/0.7/0.7.

local editStyleLogged = false
local function styleEditBox(box, sourceLabel)
  local ok, err = pcall(function() styles.editor(box, gameFont(sourceLabel)) end)
  if not ok then
    runtime.log("Rename-editor styling failed: " .. tostring(err))
  elseif not editStyleLogged then
    editStyleLogged = true
    runtime.log("Rename-editor scalar styling applied.")
  end
end

-- ============================== rename session ==============================

local hoveredTile = nil -- last tile the mouse entered (kept on leave - forgiving F2 timing)
local editBox = nil     -- live EditableTextBox while a rename is in progress
local editTile = nil
local editIndex = nil
local hoverHookRegistered = false

-- Track which tile the mouse is over. Registered lazily on first panel construction so
-- Widget_Loadout_C is guaranteed loaded. Hazards respected: self:get() only (H3), read
-- cached properties only, no native calls in the hook body (H8).
local function registerHoverHook()
  if hoverHookRegistered then
    return
  end
  local ok, err = pcall(function()
    RegisterHook(MOUSE_ENTER_FN, function(self)
      local getOk, tile = pcall(function() return self:get() end)
      if getOk and tile and tile:IsValid() then
        hoveredTile = tile
        -- Reflected property read only in the hook body (H8); the tooltip work
        -- itself runs later on the async poll + game thread.
        local idxOk, idx = pcall(function() return tile.Index end)
        if idxOk and type(idx) == "number" then
          scheduleTooltipTitle(idx)
        end
      end
    end)
  end)
  if ok then
    hoverHookRegistered = true
    print(string.format("[LoadoutNamer] Hover tracking registered - hover a loadout tile and press %s to rename it.\n", renameKeyName))
  else
    print("[LoadoutNamer] FAILED to register hover tracking (renaming unavailable): " .. tostring(err) .. "\n")
  end
end

local function beginRename(tile, recordIndex)
  ExecuteInGameThread(function()
    local ok, err = pcall(function()
      -- Parent the box into the TITLE row (the HorizontalBox holding the Label), so the
      -- edit happens visually where the name lives. The blanked Label would normally
      -- squish the box by reserving its MinDesiredWidth=130 in that row, so zero it for
      -- the duration of the edit (plain-float property write; endRename restores it).
      local row = tile.Label:GetParent()
      if not row or not row:IsValid() then
        error("could not reach the tile's title row")
      end

      local box = StaticConstructObject(StaticFindObject("/Script/UMG.EditableTextBox"), tile.WidgetTree)
      if not box or not box:IsValid() then
        error("failed to construct the EditableTextBox")
      end
      -- Raw write is fine here: MinimumDesiredWidth feeds desired-size computation each
      -- frame, and a failed/ignored write just means a narrower box.
      pcall(function() box.MinimumDesiredWidth = 130.0 end)
      styleEditBox(box, tile.Label) -- before AddChild: Slate builds with these values

      -- Blank the tile's label and stop it reserving width, THEN add the box - it
      -- takes the label's place in the title row. The subtitle stays visible below.
      -- MinDesiredWidth is a LAYOUT property: the real SetMinDesiredWidth setter is
      -- mandatory, a raw write doesn't invalidate Slate layout (H4 - the raw write
      -- indeed changed nothing, 2026-07-13 test).
      writeLabel(tile, " ")
      local widthOk, widthErr = pcall(function() tile.Label:SetMinDesiredWidth(0.0) end)
      if not widthOk then
        print("[LoadoutNamer] WARNING: failed to release the tile label's reserved width - the edit box may render squeezed: " .. tostring(widthErr) .. "\n")
      end
      row:AddChild(box)

      editBox = box
      editTile = tile
      editIndex = recordIndex

      -- Typing T/I/M must not yank the menu to another tab mid-edit.
      suppressTabHotkeys()
    end)
    if ok then
      print(string.format("[LoadoutNamer] Renaming slot (record %d) - click the box, type the new name, then Enter/%s to commit or Escape to cancel. Committing an empty name removes the custom name.\n", recordIndex, renameKeyName))
    else
      print("[LoadoutNamer] FAILED to open the rename box: " .. tostring(err) .. "\n")
    end
  end)
end

local function endRename(commit)
  ExecuteInGameThread(function()
    local box, tile, idx = editBox, editTile, editIndex
    editBox, editTile, editIndex = nil, nil, nil

    restoreTabHotkeys()

    local text = ""
    local textOk, textErr = pcall(function() text = box.Text:ToString() end)
    if commit and not textOk then
      print("[LoadoutNamer] WARNING: could not read the edit box's text on commit - treating as empty (name will be removed): " .. tostring(textErr) .. "\n")
    end

    local removeOk, removeErr = pcall(function()
      local parent = box:GetParent()
      if parent and parent:IsValid() then
        parent:RemoveChild(box)
      end
    end)
    if not removeOk then
      print("[LoadoutNamer] WARNING: failed to remove the edit box from the tile - it may linger visually: " .. tostring(removeErr) .. "\n")
    end

    if not tile or not tile:IsValid() then
      return -- screen closed mid-edit; the next apply pass restores labels anyway
    end

    -- Give the label its reserved title-row width back (zeroed for the edit).
    -- Real setter, not a raw write - layout property (H4).
    local widthOk, widthErr = pcall(function() tile.Label:SetMinDesiredWidth(130.0) end)
    if not widthOk then
      print("[LoadoutNamer] WARNING: failed to restore the tile label's width after a rename - the title row may look squeezed: " .. tostring(widthErr) .. "\n")
    end

    if not commit then
      applyRestingLabel(tile, idx)
      print("[LoadoutNamer] Rename cancelled.\n")
      return
    end

    -- Trim and strip characters that would corrupt the tab-separated store.
    text = text:gsub("[\t\r\n]", ""):match("^%s*(.-)%s*$")

    if #text > MAX_NAME_LENGTH then
      print(string.format("[LoadoutNamer] Name truncated to %d characters (the storage cap; the tile shows the first %d with '..', the tooltip shows the rest).\n", MAX_NAME_LENGTH, TILE_LABEL_MAX))
      text = text:sub(1, MAX_NAME_LENGTH):match("^(.-)%s*$")
    end

    if text == "" then
      clearName(idx)
      saveNames()
      applyRestingLabel(tile, idx)
      print(string.format("[LoadoutNamer] Custom name removed from record %d - back to its default label.\n", idx))
    else
      setName(idx, text)
      saveNames()
      applyRestingLabel(tile, idx)
      print(string.format("[LoadoutNamer] Record %d named '%s' (saved).\n", idx, text))
    end

    -- If the tooltip is on screen right now (mouse is still over the tile), bring its
    -- title in line with the new name immediately.
    scheduleTooltipTitle(idx)
  end)
end

local function editSessionActive()
  if not editBox then
    return false
  end
  local ok, alive = pcall(function() return editBox:IsValid() end)
  if ok and alive then
    return true
  end
  editBox, editTile, editIndex = nil, nil, nil -- box died with the screen
  ExecuteInGameThread(restoreTabHotkeys) -- belt-and-braces; menu reopen resets these anyway
  return false
end

-- ============================== keybinds ==============================

RegisterKeyBind(renameKey, function()
  if editSessionActive() then
    endRename(true)
    return
  end

  if not hoveredTile then
    return
  end
  local aliveOk, alive = pcall(function() return hoveredTile:IsValid() end)
  if not aliveOk or not alive then
    hoveredTile = nil
    return
  end

  local idxOk, idx = pcall(function() return hoveredTile.Index end)
  if not idxOk or type(idx) ~= "number" then
    print(string.format("[LoadoutNamer] %s: could not read the hovered tile's record index - ignoring.\n", renameKeyName))
    return
  end
  if idx == RESERVED_RECORD_INDEX then
    print(string.format("[LoadoutNamer] %s: that's the game's Last Gear State auto-save slot - it can't be renamed.\n", renameKeyName))
    return
  end

  beginRename(hoveredTile, idx)
end)

RegisterKeyBind(Key.RETURN, function()
  if editSessionActive() then
    endRename(true)
  end
end)

RegisterKeyBind(Key.ESCAPE, function()
  if editSessionActive() then
    endRename(false)
  end
end)

-- ============================== wiring ==============================

runtime.watchPanels(function(panel)
  registerHoverHook()
  applySavedNames(panel)
end)
runtime.start()
