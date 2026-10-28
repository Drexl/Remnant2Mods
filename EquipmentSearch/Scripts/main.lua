print("[EquipmentSearch] Loaded and running.\n")

-- EquipmentSearch: adds a working text search to the inventory item grids
-- (rings, amulets, armor, relics, weapons - plus the materials/quest/usable
-- lists, which use the same widget class).
--
-- The game ships a hidden, half-finished search filter widget
-- (Widget_InventorySearchFilter inside Widget_InventoryList). Its bar and text
-- box render fine once unhidden, but its filtering pipeline is dead (keyword
-- DataTable shipped empty) and every vanilla grid-rebuild entry point
-- early-outs when nothing changed, so the matching AND the hiding are ours:
-- on query change we walk the grid's card children and SetVisibility per
-- match. Matching text per ItemID comes from each card's Get_InspectInfo
-- (Label/SubLabel plus the Stats/Mods effect arrays; lore Description and
-- FlavorText deliberately excluded), cached per session.
-- Full findings: docs/remnant2-modding-research.md 3.6b.
--
-- Debug commands (type into the search box):
--   !<word>  print the FULL cached text of every item containing <word>
--   !!       clear the text cache (next keystroke rebuilds it fresh)
--   !?       list items whose cache is name-only (can't match effect search)

local LIST_CLASS_PATH = "/Game/UI/UI_Inventory/Widget_InventoryList.Widget_InventoryList_C"
local FILTER_CLASS = "/Game/UI/UI_Inventory/Widget_InventorySearchFilter.Widget_InventorySearchFilter_C"

local TEXTCHANGED_FUNC_PATH = FILTER_CLASS
    .. ":BndEvt__Widget_InventorySearchFilter_SearchFilterText_K2Node_ComponentBoundEvent_1_OnEditableTextBoxChangedEvent__DelegateSignature"
-- the X button clears the box WITHOUT firing OnTextChanged (traced), so its
-- clicked event needs its own hook
local XBUTTON_FUNC_PATH = FILTER_CLASS
    .. ":BndEvt__Widget_InventorySearchFilter_Button_246_K2Node_ComponentBoundEvent_3_OnButtonClickedEvent__DelegateSignature"
-- the game's own grid passes; post-hooked to re-apply our filter after
-- vanilla rebuilds ('Update Inventory List' covers equip/pickup refreshes,
-- 'Build Inventory List' covers popup reopen / tab construction)
local LIST_UPDATE_FUNC_PATH = LIST_CLASS_PATH .. ":Update Inventory List"
local LIST_BUILD_FUNC_PATH  = LIST_CLASS_PATH .. ":Build Inventory List"
-- the filter widget overrides these focus-path events (dump ~1705); they fire
-- when keyboard focus enters/leaves the search box - the typing-session
-- boundary for tab-hotkey suppression
local FOCUS_ADDED_FUNC_PATH   = FILTER_CLASS .. ":OnAddedToFocusPath"
local FOCUS_REMOVED_FUNC_PATH = FILTER_CLASS .. ":OnRemovedFromFocusPath"

local VISIBLE   = 0  -- ESlateVisibility::Visible
local COLLAPSED = 1  -- ESlateVisibility::Collapsed

-- Every live list gets its own entry: several instances coexist (equipment
-- screen + the materials/quest/usable lists on the Inventory tab), and a
-- single "current list" variable caused text changes on one list to stomp the
-- filter state of another. Keyed by list full name; pruned when invalid.
-- entry = { list = <widget>, box = <text box>, query = <lowercased string> }
local trackedLists = {}

-- ItemID -> lowercased searchable text. Session-lifetime, built lazily from
-- each list's own grid children (NOT the global card pool - stale pooled
-- cards from destroyed screens misreport and poisoned the cache once).
-- Known staleness: an upgraded item keeps its old cached "+N" label until
-- relaunch; name/description words still match, so acceptable.
local itemTextCache = {}

-- original visibility of cards we've hidden, keyed by card full name, so a
-- loosened query restores exactly what was there before
local hiddenCardVis = {}

-- Effect text ships with rich-text markup (<stat>7%</>, <span color=...>) and
-- embedded newlines that break phrase matching ("grey health" failed when a
-- tag or line break sat between the words). Strip tags, collapse whitespace
-- (incl. UTF-8 non-breaking spaces), lowercase. Applied to cached text and
-- queries alike so both sides normalize identically.
local function normalizeText(s)
    s = string.lower(s or "")
    s = string.gsub(s, "<[^>]*>", " ")
    s = string.gsub(s, "\194\160", " ") -- U+00A0 no-break space
    s = string.gsub(s, "%s+", " ")
    return s
end

-- The Stats/Mods arrays hold native structs; their entries arrive in Lua as
-- LocalUnrealParam wrappers (probed) that need :get() before field access.
-- Field names are resolved once at load via reflection: InspectInfo's array
-- properties -> inner struct -> its Text/Str-typed fields.
-- PER-ARRAY lists: Stats entries (InspectStat) and Mods entries (InspectMod)
-- have different structs, and reading a field name on a struct that doesn't
-- own it hard-crashes. The shared-list version crashed the full cache pass
-- (2026-07-14) by trying Stats' CustomDescription on Mods entries; probe P8
-- proved reading CustomDescription on Stats entries alone is safe for all
-- 213 rings.
local statTextFields = { Stats = {}, Mods = {} }

local function resolveStatTextFields()
    local ok, err = pcall(function()
        local infoStruct = StaticFindObject("/Script/GunfireRuntime.InspectInfo")
        if not infoStruct or not infoStruct:IsValid() then
            print("[EquipmentSearch] InspectInfo struct not found for reflection\n")
            return
        end
        infoStruct:ForEachProperty(function(prop)
            local okProp = pcall(function()
                local full = prop:GetFullName() -- "ArrayProperty /Script/...:Stats"
                local propName = string.match(full, ":(%w+)$")
                if propName ~= "Stats" and propName ~= "Mods" then return end
                local inner = prop:GetInner()
                if not inner then return end
                local innerStruct = inner:GetStruct()
                if not innerStruct or not innerStruct:IsValid() then return end
                local fields = statTextFields[propName]
                local seen = {}
                -- Walk the SUPER chain too: InspectStat inherits
                -- InspectStatBase, whose CustomDescription carries the
                -- trigger-ring effect text - ForEachProperty alone only sees
                -- a struct's own fields and missed it (probe P6/P7).
                local s = innerStruct
                local depth = 0
                while s and s:IsValid() and depth < 6 do
                    s:ForEachProperty(function(fieldProp)
                        pcall(function()
                            local ffull = fieldProp:GetFullName()
                            local ftype, fname = string.match(ffull, "^(%w+) .*:(%w+)$")
                            -- FlavorText excluded by user decision: lore quotes
                            -- are not gameplay text and caused surprising
                            -- matches. NOTE: effect text lives in
                            -- InspectMod.Label for stat-style rings and in
                            -- InspectStatBase.CustomDescription for
                            -- trigger-style rings; Description is unused.
                            if (ftype == "TextProperty" or ftype == "StrProperty")
                               and fname and fname ~= "FlavorText"
                               and not seen[fname] then
                                seen[fname] = true
                                fields[#fields + 1] = fname
                            end
                        end)
                    end)
                    local okSuper, super = pcall(function() return s:GetSuperStruct() end)
                    s = okSuper and super or nil
                    depth = depth + 1
                end
            end)
        end)
        print("[EquipmentSearch] stat text fields - Stats: "
            .. table.concat(statTextFields.Stats, ", ")
            .. " | Mods: " .. table.concat(statTextFields.Mods, ", ") .. "\n")
    end)
    if not ok then
        print("[EquipmentSearch] stat field reflection FAILED: " .. tostring(err) .. "\n")
    end
end
resolveStatTextFields()

-- ItemIDs whose cached text is name-only (no effect text found anywhere);
-- '!?' in the search box lists them
local nameOnlyItems = {}

-- Whether this UE4SS build's reflection can resolve the InspectObject property
-- on Stats/Mods struct entries (the "belt-and-braces" fallback below). On a
-- build without it, the read errors with "unable to retrieve property
-- 'InspectObject'" and pierces pcall - not a catchable Lua error, it aborts
-- the whole enclosing function - and since extractTexts runs on every cache
-- pass (every keystroke, every watchdog tick), an unguarded retry here floods
-- the log continuously and breaks search entirely (2026-07-14 stable-UE4SS
-- test). Probed once per session; the "probed" flag is set BEFORE the risky
-- read so it survives even if the read aborts this whole function.
local inspectObjectProbed = false
local inspectObjectSupported = false

-- Pull display strings out of a Stats/Mods array. Out-param arrays arrive as
-- Lua tables of LocalUnrealParam-wrapped structs; arrays read off a returned
-- struct arrive as TArray userdata (# and [i] indexing).
local function extractTexts(arr, parts, fields)
    local entries = {}
    if type(arr) == "table" then
        for _, e in pairs(arr) do entries[#entries + 1] = e end
    elseif type(arr) == "userdata" then
        pcall(function()
            for i = 1, #arr do entries[#entries + 1] = arr[i] end
        end)
    else
        return
    end
    for _, entry in ipairs(entries) do
        pcall(function()
            local unwrapped = entry
            if type(entry) == "userdata" then
                local okGet, inner = pcall(function() return entry:get() end)
                if okGet and inner ~= nil then unwrapped = inner end
            end
            local gotText = false
            for _, field in ipairs(fields) do
                pcall(function()
                    local v = unwrapped[field]
                    if v ~= nil then
                        local okStr, s = pcall(function() return v:ToString() end)
                        if okStr and type(s) == "string" and s ~= "" then
                            parts[#parts + 1] = s
                            if field == "Description" then gotText = true end
                        end
                    end
                end)
            end
            -- belt-and-braces: entries that yielded no Description text may
            -- reference a perk object that owns display text of its own.
            -- Skipped entirely once known unsupported on this build (see
            -- inspectObjectProbed above).
            if not gotText and not (inspectObjectProbed and not inspectObjectSupported) then
                inspectObjectProbed = true
                pcall(function()
                    local obj = unwrapped.InspectObject -- the risky read
                    inspectObjectSupported = true
                    if obj == nil or not obj:IsValid() then return end
                    for _, field in ipairs({ "Description", "Label", "TooltipText" }) do
                        pcall(function()
                            local v = obj[field]
                            if v ~= nil then
                                local okStr, s = pcall(function() return v:ToString() end)
                                if okStr and type(s) == "string" and s ~= "" then
                                    parts[#parts + 1] = s
                                end
                            end
                        end)
                    end
                end)
            end
        end)
    end
end

-- Build cache entries for grid cards whose ItemID we haven't seen yet.
-- Game thread only: Get_InspectInfo is a BlueprintPure BP call with a struct
-- out param (UE4SS spreads the struct's fields into the passed table - probed).
local function ensureItemTextCache(list)
    if not list or not list:IsValid() then return end
    local added = 0
    local firstErr = nil
    local okGrid, gridErr = pcall(function()
        local grid = list.InventoryGrid
        if not grid or not grid:IsValid() then return end
        local n = grid:GetChildrenCount()
        for i = 0, n - 1 do
            local okCard, cardErr = pcall(function()
                local card = grid:GetChildAt(i)
                if not card or not card:IsValid() then return end
                local id = card.ItemID
                if not id or id == 0 or itemTextCache[id] then return end

                local info = {}
                card:Get_InspectInfo(info)
                -- InspectInfo.Description (lore paragraph) and FlavorText
                -- (quoted lore) intentionally excluded: not gameplay text
                -- (user decision) - the search covers name, type, and the
                -- effect text from the Stats/Mods arrays
                local parts = {}
                for _, field in ipairs({ "Label", "SubLabel" }) do
                    local v = info[field]
                    if v ~= nil then
                        local okStr, str = pcall(function() return v:ToString() end)
                        if okStr and str then parts[#parts + 1] = str end
                    end
                end
                -- gameplay-effect text lives in the arrays, not on InspectInfo
                -- itself: Mods[].Label for stat-style items,
                -- Stats[].CustomDescription for trigger-style items
                extractTexts(info.Stats, parts, statTextFields.Stats)
                extractTexts(info.Mods, parts, statTextFields.Mods)

                -- "no effect text" means: nothing beyond Label/SubLabel except
                -- name echoes (Momentum Driver's mod Label repeats the item
                -- name - a plain part count misses it)
                local labelNorm = normalizeText(parts[1] or "")
                local hasEffect = false
                for i = 3, #parts do
                    local p = normalizeText(parts[i])
                    p = string.match(p, "^%s*(.-)%s*$")
                    if p ~= "" and p ~= labelNorm then hasEffect = true end
                end

                -- anything still name-only here won't match effect searches -
                -- '!?' lists these (0 for all 213 rings as of 2026-07-14; a
                -- game patch could reintroduce some, hence the diagnostic)
                nameOnlyItems[id] = (not hasEffect) or nil
                itemTextCache[id] = normalizeText(table.concat(parts, " "))
                added = added + 1
            end)
            -- per-card pcall: one bad card must not abort the whole cache pass
            if not okCard and not firstErr then firstErr = tostring(cardErr) end
        end
    end)
    if not okGrid then firstErr = firstErr or tostring(gridErr) end
    if added > 0 then
        print(string.format("[EquipmentSearch] cached search text for %d new item(s)\n", added))
    end
    if firstErr then
        print("[EquipmentSearch] cache pass error (first): " .. firstErr .. "\n")
    end
end

-- Walk one list's grid children and toggle visibility per match. Game thread
-- only. Collapsed reflows the WrapBox so matches flow together; restoring
-- uses each card's own recorded pre-hide visibility.
local function applyFilter(entry, verbose)
    local list, query = entry.list, entry.query
    if not list or not list:IsValid() then return end
    local shown, hidden = 0, 0
    local okApply, applyErr = pcall(function()
        local grid = list.InventoryGrid
        if not grid or not grid:IsValid() then return end
        local n = grid:GetChildrenCount()
        for i = 0, n - 1 do
            pcall(function()
                local card = grid:GetChildAt(i)
                if not card or not card:IsValid() then return end
                local id = card.ItemID
                if not id then return end -- not an item card; leave alone

                local text = itemTextCache[id]
                local matches = query == ""
                    or (text ~= nil and string.find(text, query, 1, true) ~= nil)
                local key = card:GetFullName()

                if matches then
                    if hiddenCardVis[key] ~= nil then
                        card:SetVisibility(hiddenCardVis[key])
                        hiddenCardVis[key] = nil
                    end
                    shown = shown + 1
                else
                    if hiddenCardVis[key] == nil then
                        hiddenCardVis[key] = card.Visibility
                    end
                    card:SetVisibility(COLLAPSED)
                    hidden = hidden + 1
                end
            end)
        end
    end)
    if not okApply then
        print("[EquipmentSearch] applyFilter error: " .. tostring(applyErr) .. "\n")
        return
    end
    -- one line per committed keystroke; silent on watchdog/rebuild passes
    if verbose then
        print(string.format("[EquipmentSearch] filter applied: %d shown, %d hidden\n",
            shown, hidden))
    end
end

-- Sync every tracked list against its own text box. Runs on the game thread
-- only (never from inside a hook body directly - H8). Prunes dead entries.
local function refreshAllLists(forceApply)
    for key, entry in pairs(trackedLists) do
        local ok, err = pcall(function()
            if not entry.list:IsValid() or not entry.box:IsValid() then
                trackedLists[key] = nil
                return
            end
            local query = normalizeText(entry.box.Text:ToString())
            query = string.match(query, "^%s*(.-)%s*$") -- trim edges
            -- debug commands (kept in the shipped mod - see file header):
            -- '!<word>' dumps the FULL
            -- cached text of every item containing <word>; '!!' clears the
            -- cache so the next keystroke rebuilds it fresh; '!?' lists every
            -- item whose cache is name-only (won't match description search)
            if string.sub(query, 1, 1) == "!" then
                local needle = string.sub(query, 2)
                if needle == "!" then
                    itemTextCache = {}
                    nameOnlyItems = {}
                    print("[EquipmentSearch] item text cache cleared\n")
                    needle = ""
                elseif needle == "?" then
                    local count = 0
                    for id in pairs(nameOnlyItems) do
                        count = count + 1
                        print(string.format("[EquipmentSearch] NAME-ONLY ItemID=%d: %s\n",
                            id, tostring(itemTextCache[id])))
                    end
                    print(string.format("[EquipmentSearch] %d name-only item(s) total\n", count))
                    needle = ""
                end
                if #needle >= 2 then
                    for id, text in pairs(itemTextCache) do
                        if string.find(text, needle, 1, true) then
                            print(string.format("[EquipmentSearch] DUMP ItemID=%d:\n%s\n---\n",
                                id, text))
                        end
                    end
                end
                query = "" -- show the full grid while debugging
            end
            if query ~= entry.query then
                entry.query = query
                ensureItemTextCache(entry.list)
                applyFilter(entry, true)
            elseif forceApply and query ~= "" then
                -- silent pass: watchdog / vanilla-rebuild re-apply
                ensureItemTextCache(entry.list)
                applyFilter(entry, false)
            end
        end)
        if not ok then
            print("[EquipmentSearch] refresh error: " .. tostring(err) .. "\n")
            trackedLists[key] = nil
        end
    end
end

-- Un-hide the search bar on one freshly-constructed list instance.
-- Two hiding layers (research doc 3.6b): the filter child itself (inert
-- CanSeeSearchBar binding evaluates a few times during construction) and the
-- SearchFilterText box (Collapsed at the asset level). The combo box is
-- vanilla-functional but redundant with the W-filters screen - collapse it.
local function showSearchBar(list)
    local filter = list.Widget_InventorySearchFilter
    if not filter or not filter:IsValid() then
        return false, "filter child not valid"
    end
    local box = filter.SearchFilterText
    if not box or not box:IsValid() then
        return false, "SearchFilterText not valid"
    end

    filter:SetVisibility(VISIBLE)
    box:SetVisibility(VISIBLE)

    local okCombo, comboErr = pcall(function()
        local combo = filter.ComboBoxKey_58
        if combo and combo:IsValid() then combo:SetVisibility(COLLAPSED) end
    end)
    if not okCombo then
        -- cosmetic only - log and carry on
        print("[EquipmentSearch] combo collapse failed: " .. tostring(comboErr) .. "\n")
    end
    return true, box
end

-- ---------- tab hotkey suppression (LoadoutNamer's proven trick) ----------
-- Typing M in the search box also fires the menu's map-tab hotkey and yanks
-- the screen away mid-word. UE4SS can't consume input, but the game gates
-- each tab switch on the tab BUTTON's own visibility (Focus* handlers fire
-- regardless, then early-out on an IsVisible check - LoadoutNamer probe).
-- So: hide the tab buttons while the search box has keyboard focus.
-- Hidden (ESlateVisibility 2), NOT Collapsed, keeps their layout space so the
-- tab bar doesn't reflow. Restore only what we hid. A leaked Hidden state
-- (screen closed mid-focus) self-heals: the game resets tab visibility when
-- the menu reopens.
local TAB_HOTKEY_PROPS = { "TraitTab", "InventoryTab", "MapTab" }
local hiddenTabs = {}

-- Disambiguate multiple live Widget_InGameMenu_C instances by IsVisible() (only the
-- on-screen one should be true) rather than "whichever non-Default__ instance
-- FindAllOf returned last" - the latter caused an intermittent, hard-to-reproduce
-- failure to suppress in LoadoutNamer (same copied technique - fixed there 2026-07-17,
-- root-caused via a logged instance count/visibility breakdown after a GetParent()-walk
-- alternative was tried and found structurally wrong: GetParent() only walks nesting
-- WITHIN one UserWidget's own tree, it can't cross into the tree that embeds it).
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
                        visible[#visible + 1] = m
                    end
                end
            end
        end
    end)
    if #visible == 1 then
        return visible[1]
    end
    print(string.format("[EquipmentSearch] findOwningMenu: %d non-default Widget_InGameMenu_C instance(s), %d visible - %s.\n",
        totalNonDefault, #visible,
        #visible == 0 and "none usable" or "using the last visible one"))
    return visible[#visible] -- nil if #visible == 0
end

-- Game thread only.
local function suppressTabHotkeys()
    local menu = findOwningMenu()
    if not menu then
        print("[EquipmentSearch] WARNING: could not find a visible Widget_InGameMenu_C - T/I/M tab hotkeys will NOT be suppressed while typing.\n")
        return
    end
    local suppressed = 0
    for _, prop in ipairs(TAB_HOTKEY_PROPS) do
        local ok, err = pcall(function()
            local tab = menu[prop]
            -- only touch tabs the game is currently showing, so restore can't
            -- force-show a tab the game itself hides in this context
            if tab and tab:IsValid() and tab:IsVisible() then
                tab:SetVisibility(2) -- Hidden: blocks the hotkey, keeps layout
                table.insert(hiddenTabs, tab)
                suppressed = suppressed + 1
            end
        end)
        if not ok then
            print(string.format("[EquipmentSearch] WARNING: failed to suppress the %s tab hotkey: %s\n", prop, tostring(err)))
        end
    end
    if suppressed < #TAB_HOTKEY_PROPS then
        print(string.format("[EquipmentSearch] Tab hotkey suppression: %d/%d tabs hidden (the rest were already not visible in this context, or failed - see above).\n", suppressed, #TAB_HOTKEY_PROPS))
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
            print("[EquipmentSearch] WARNING: failed to restore a tab's visibility after search box focus was lost: " .. tostring(err) .. "\n")
        end
    end
    hiddenTabs = {}
end

-- Hooks on /Game/ classes can only be registered once the Blueprint is loaded
-- (fails with 'no UFunction found' at mod start on a fresh launch - research
-- doc 3.6b), so registration is deferred to the first successful capture.
local hooksRegistered = false
local function registerHooksOnce()
    if hooksRegistered then return end

    local ok, err = pcall(function()
        -- fires per keystroke (proven). Hook bodies defer to the game thread;
        -- no native calls in hook context. Which box changed doesn't matter -
        -- the sync pass reads every tracked list's own box.
        RegisterHook(TEXTCHANGED_FUNC_PATH, function()
            ExecuteInGameThread(function() refreshAllLists(false) end)
        end)

        -- X button: box is now empty; the sync pass restores that list's grid
        RegisterHook(XBUTTON_FUNC_PATH, function()
            ExecuteInGameThread(function() refreshAllLists(false) end)
        end)

        -- typing session boundary: focus enters the search box -> hide the
        -- menu's tab buttons (blocks the M-to-map hotkey); focus leaves ->
        -- restore. Fires on click-in, so suppression is in place before the
        -- first keystroke. Own pcall: these are inherited-override functions
        -- (not bound events); if they fail to register the core search hooks
        -- must survive, and the outer pcall must not retry-and-double-register
        -- them on the next list construction.
        local okFocus, focusErr = pcall(function()
            RegisterHook(FOCUS_ADDED_FUNC_PATH, function()
                ExecuteInGameThread(suppressTabHotkeys)
            end)
            RegisterHook(FOCUS_REMOVED_FUNC_PATH, function()
                ExecuteInGameThread(restoreTabHotkeys)
            end)
        end)
        if not okFocus then
            print("[EquipmentSearch] focus-hook registration failed (M-to-map "
                .. "hotkey NOT suppressed while typing): "
                .. tostring(focusErr) .. "\n")
        end

        -- re-apply after the game's own grid passes (tab switch, equip,
        -- pickup, popup reopen). Build repopulates cards asynchronously, so
        -- re-apply again after a short delay - an immediate pass alone left
        -- reopened popups unfiltered.
        local function reapplyAfterVanillaPass()
            ExecuteInGameThread(function() refreshAllLists(true) end)
            LoopAsync(150, function()
                ExecuteInGameThread(function() refreshAllLists(true) end)
                return true -- one-shot
            end)
        end
        RegisterHook(LIST_UPDATE_FUNC_PATH, function() end, reapplyAfterVanillaPass)
        RegisterHook(LIST_BUILD_FUNC_PATH,  function() end, reapplyAfterVanillaPass)

        -- watchdog: the game has rebuild paths that bypass Update/Build (the
        -- equip -> popup-reopen flow reset the grid to unfiltered). Instead of
        -- chasing every entry point, silently re-apply active filters on a
        -- short interval; a full pass measured ~2ms, so this is cheap.
        LoopAsync(300, function()
            local anyActive = false
            for _, entry in pairs(trackedLists) do
                if entry.query ~= "" then anyActive = true break end
            end
            if anyActive then
                ExecuteInGameThread(function() refreshAllLists(true) end)
            end
            return false -- keep running for the mod's lifetime
        end)
    end)

    if ok then
        hooksRegistered = true
        print("[EquipmentSearch] hooks registered (TextChanged, X button, "
            .. "focus in/out, Update/Build passes).\n")
    else
        print("[EquipmentSearch] hook registration FAILED: " .. tostring(err) .. "\n")
    end
end

-- Stable v3.0.1 resolves NotifyOnNewObject's class at registration time;
-- LIST_CLASS_PATH may not be loaded yet on a cold launch. Watch the resident
-- native ancestor instead, as in the loadout mods, and discard unrelated
-- widgets immediately. No global discovery scan or hot-reload is required.
local LIST_CLASS_NAME = "Widget_InventoryList_C"
local TEMPLATE_FLAGS = 0x30 -- RF_ClassDefaultObject | RF_ArchetypeObject
local listStates = {}
local baseWidget = StaticFindObject("/Script/UMG.UserWidget")
assert(baseWidget and baseWidget:IsValid(), "native UserWidget class is unavailable")

NotifyOnNewObject("/Script/UMG.UserWidget", function(list)
    if not list or not list:IsValid() then return end
    if list:GetClass():GetFName():ToString() ~= LIST_CLASS_NAME then return end
    if list:HasAnyFlags(TEMPLATE_FLAGS) then return end
    if list:GetFullName():find("Default__", 1, true) then return end

    -- Keep pending and completed instances deduplicated, but allow a new
    -- instance to reuse an address after the previous widget is destroyed.
    for id, state in pairs(listStates) do
        if not state.list:IsValid() then listStates[id] = nil end
    end
    local id = list:GetAddress()
    if listStates[id] then return end
    local state = {list = list, attempts = 0, queued = false, done = false}
    listStates[id] = state

    LoopAsync(50, function()
        if state.done then return true end
        -- A stalled game thread must not accumulate readiness callbacks.
        if not state.queued then
            state.queued = true
            ExecuteInGameThread(function()
                state.queued = false
                if state.done then return end
                state.attempts = state.attempts + 1
                if not list:IsValid() then
                    state.done = true
                    listStates[id] = nil
                    return
                end
                -- All child/owner reads and widget work stay on the game thread.
                local ok, err = pcall(function()
                    local filter = list.Widget_InventorySearchFilter
                    if not filter or not filter:IsValid() then return end
                    local box = filter.SearchFilterText
                    if not box or not box:IsValid() then return end
                    local player = list:GetOwningPlayer()
                    if not player or not player:IsValid() then return end

                    local shown, boxOrWhy = showSearchBar(list)
                    state.done = true
                    if not shown then
                        print("[EquipmentSearch] Search bar NOT enabled: "
                            .. tostring(boxOrWhy) .. "\n")
                        return
                    end
                    trackedLists[list:GetFullName()] = {
                        list = list, box = boxOrWhy, query = "",
                    }
                    registerHooksOnce()
                    print("[EquipmentSearch] Search bar enabled on "
                        .. list:GetFullName() .. "\n")
                    -- CanSeeSearchBar may stomp an early visibility write;
                    -- preserve the existing one-shot construction-time reapply.
                    LoopAsync(500, function()
                        ExecuteInGameThread(function()
                            local okReapply, reapplyErr = pcall(function()
                                if list:IsValid() then showSearchBar(list) end
                            end)
                            if not okReapply then
                                print("[EquipmentSearch] Search bar reapply error: "
                                    .. tostring(reapplyErr) .. "\n")
                            end
                        end)
                        return true
                    end)
                end)
                if not ok then
                    state.done = true
                    print("[EquipmentSearch] List setup failed: " .. tostring(err) .. "\n")
                elseif not state.done and state.attempts >= 40 then
                    state.done = true
                    print("[EquipmentSearch] List readiness timed out; bar not enabled: "
                        .. list:GetFullName() .. "\n")
                end
            end)
        end
        return state.done
    end)
end)
print("[EquipmentSearch] Native widget listener started (no global discovery scans).\n")
