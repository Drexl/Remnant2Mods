-- Remnant II widget lifecycle model for offline UI-mod fixtures.
-- Construct follows the shipped Blueprint order checked with KismetAnalyzer:
-- Widget_LoadoutsPanel_C:Construct calls Refresh(true), which creates the
-- vanilla tiles. Slate building, layout and rendering are not modelled beyond
-- "a widget added to a built container is built and runs its Construct".
local mock = require("ue4ss_mock")
local W = {}

W.PANEL = "/Game/UI2/UI_Widgets/UI_Game/UI_Game_Character/Widget_LoadoutsPanel.Widget_LoadoutsPanel_C"
W.TILE = "/Game/UI2/UI_Widgets/UI_Game/UI_Game_Character/Widget_Loadout.Widget_Loadout_C"
W.LIST = "/Game/UI/UI_Inventory/Widget_InventoryList.Widget_InventoryList_C"
W.FILTER = "/Game/UI/UI_Inventory/Widget_InventorySearchFilter.Widget_InventorySearchFilter_C"
W.HUD = "/Game/UI/HUD/TPSHud.TPSHud_C"
W.KEYICON = "/Game/UI/UI_Widgets/Widget_KeyIcon.Widget_KeyIcon_C"
W.TEXT_CHANGED = W.FILTER .. ":BndEvt__Widget_InventorySearchFilter_SearchFilterText_K2Node_ComponentBoundEvent_1_OnEditableTextBoxChangedEvent__DelegateSignature"
W.X_BUTTON = W.FILTER .. ":BndEvt__Widget_InventorySearchFilter_Button_246_K2Node_ComponentBoundEvent_3_OnButtonClickedEvent__DelegateSignature"
W.TILE_HOVER = W.TILE .. ":BndEvt__Widget_Loadout_Button_K2Node_ComponentBoundEvent_4_OnAdvButtonClickedEvent__DelegateSignature"
W.TILE_RMB = W.TILE .. ":BndEvt__Widget_Loadout_Button_K2Node_ComponentBoundEvent_0_OnFocusMouseEventDelegate__DelegateSignature"
W.TILE_LMB = W.TILE .. ":BndEvt__Widget_Loadout_Button_K2Node_ComponentBoundEvent_2_OnAdvButtonClickedEvent__DelegateSignature"
W.TILE_INPUT = W.TILE .. ":OnInputAction"
W.CLIENT_RESTART = "/Script/Engine.PlayerController:ClientRestart"
W.SCROLL_TEMPLATE = "/Game/UI2/UI_Widgets/UI_Game/UI_Game_Equipment/Widget_AdvancedStats.Widget_AdvancedStats_C:WidgetTree.ScrollBox_143"

function W.new(options)
  options = options or {}
  local engine = mock.new()
  local world = {engine = engine, panels = {}, lists = {}, serial = 2147480000, multicast = options.multicast}

  local function unique(base)
    world.serial = world.serial + 1
    return base .. "_" .. world.serial
  end

  -- Widgets ---------------------------------------------------------------------
  local methods = {}
  function methods.SetVisibility(self, value)
    self.__raw.Visibility = value
    self.__raw.visibilityWrites = (self.__raw.visibilityWrites or 0) + 1
  end
  function methods.IsVisible(self)
    local v = self.__raw.Visibility or 0
    return v ~= 1 and v ~= 2
  end
  function methods.GetParent(self) return self.__raw.parent end
  function methods.SetText(self, text) self.__raw.Text = text end
  function methods.SetMinDesiredWidth(self, width) self.__raw.minWidth = width end
  function methods.GetChildrenCount(self) return #self.__raw.children end
  function methods.GetChildAt(self, i) return self.__raw.children[i + 1] end
  function methods.GetOwningPlayer(self) return self.__raw.owner end
  function methods.SetVerticalAlignment() end
  function methods.SetKeyboardFocus(self)
    local raw = self.__raw
    assert(raw.parent, "focus requested before insertion")
    raw.focusAttempts = (raw.focusAttempts or 0) + 1
    raw.focused = raw.focusAttempts >= (raw.acceptFocusAfter or 1)
  end
  function methods.HasKeyboardFocus() return false end
  function methods.HasFocusedDescendants(self) return self.__raw.focused == true end
  function methods.IsHovered(self) return self.__raw.hovered == true end

  local build
  local function unbuild(widget)
    local raw = widget.__raw
    raw.built = false
    for _, child in ipairs(raw.children or {}) do unbuild(child) end
  end
  function methods.AddChild(self, child)
    local raw = self.__raw
    local slot = engine.object(raw.fullName .. ".Slot" .. (#raw.children + 1), {
      Parent = self, Padding = {Left = 0, Top = 0, Right = 0, Bottom = 0}, methods = methods,
    })
    raw.children[#raw.children + 1] = child
    child.__raw.parent, child.__raw.Slot = self, slot
    if raw.built then build(child) end
    return slot
  end
  function methods.RemoveChild(self, child)
    local children = self.__raw.children
    for i, c in ipairs(children) do
      if c == child then table.remove(children, i); break end
    end
    if child.__raw.parent == self then child.__raw.parent, child.__raw.Slot = nil, nil end
    unbuild(child)
  end
  function methods.RemoveFromParent(self)
    local parent = self.__raw.parent
    if parent then methods.RemoveChild(parent, self) end
  end

  function world.widget(fullName, fields)
    fields = fields or {}
    fields.methods = methods
    fields.children = fields.children or {}
    return engine.object(fullName, fields)
  end

  -- Slate building: a built UserWidget runs its Blueprint Construct once per build.
  function build(widget)
    local raw = widget.__raw
    if raw.built then return end
    raw.built = true
    for _, child in ipairs(raw.children or {}) do build(child) end
    if raw.constructPath and not raw.dead then
      raw.constructs = (raw.constructs or 0) + 1
      engine.callBlueprint(raw.constructPath, widget, raw.constructBody)
    end
  end
  world.build = build

  local function userWidget(fullName, className, fields)
    fields = fields or {}
    fields.isUserWidget, fields.className = true, className
    local w = world.widget(fullName, fields)
    engine.construct(w)
    return w
  end
  world.userWidget = userWidget

  -- Classes and resident objects -----------------------------------------------
  engine.class("/Script/UMG.UserWidget", {}, true)
  engine.class("/Script/Engine.PlayerController", {}, true)
  engine.class("/Script/GunfireRuntime.InspectInfo", {ForEachProperty = function() end}, true)
  local function nativeWidgetClass(path, className)
    engine.class(path, {construct = function(outer)
      local name = (outer and outer.__raw.fullName or "/Engine/Transient") .. "." .. unique(className)
      local w = world.widget(name, {className = className, classPath = path})
      if className == "ScrollBox" then w.__raw.Clipping = 1 end
      if className == "EditableTextBox" then
        w.__raw.WidgetStyle = mock.struct()
        w.__raw.acceptFocusAfter = world.focusAfter or 1
        world.editors = world.editors or {}
        world.editors[#world.editors + 1] = w
      end
      if className == "TextBlock" then
        w.__raw.Font, w.__raw.ColorAndOpacity = mock.struct(), mock.struct()
      end
      return w
    end}, true)
  end
  nativeWidgetClass("/Script/UMG.ScrollBox", "ScrollBox")
  nativeWidgetClass("/Script/UMG.Overlay", "Overlay")
  nativeWidgetClass("/Script/UMG.EditableTextBox", "EditableTextBox")
  nativeWidgetClass("/Script/UMG.TextBlock", "TextBlock")
  for _, path in ipairs({W.PANEL, W.TILE, W.LIST, W.FILTER, W.HUD, W.KEYICON}) do
    engine.class(path)
  end
  engine.resident("/Game/_Core/Loadouts/Gear_Loadout.Gear_Loadout")
  engine.resident("/Game/UI/Fonts/GFGRemnantCracked_Font.GFGRemnantCracked_Font")

  -- Players, components and menus ------------------------------------------------
  world.player = engine.object("/Engine/Transient.World:PersistentLevel.BP_RemnantPlayerController_C_0", {methods = methods})
  world.component = engine.object("/Engine/Transient.World:PersistentLevel.Pawn.LoadoutComponent", {
    Slots = {{NumRecords = 11}, {NumRecords = 11}},
  })
  engine.addFindAll("LoadoutComponent", world.component)
  world.character = engine.object("SavedCharacter", {ID = options.characterID or 0})
  local manager = engine.object("CharacterManager", {
    HasActiveCharacter = function() return true end,
    GetActiveCharacter = function() return world.character end,
  })
  world.gameInstance = engine.object("/Engine/Transient.BP_RemnantGameInstance_C_0", {CharacterManager = manager})
  engine.addFindAll("GameInstance", world.gameInstance)
  world.menu = world.widget("/Engine/Transient.BP_RemnantGameInstance_C_0.Widget_InGameMenu_C_0")
  for _, prop in ipairs({"TraitTab", "InventoryTab", "MapTab"}) do
    world.menu.__raw[prop] = world.widget(world.menu.__raw.fullName .. "." .. prop, {Visibility = 0})
  end
  engine.addFindAll("Widget_InGameMenu_C", world.menu)

  -- Tiles --------------------------------------------------------------------------
  local function delegate()
    return {Add = function(self, owner, handler) self.owner, self.handler = owner, handler end,
      Remove = function(self) self.owner, self.handler = nil, nil end}
  end
  function world.createTile(outer, player)
    local name = (outer and outer.__raw.fullName or "/Engine/Transient") .. "." .. unique("Widget_Loadout_C")
    local row = world.widget(name .. ".WidgetTree.TitleRow")
    local label = world.widget(name .. ".WidgetTree.Label", {minWidth = 130, Font = {FontObject = engine.residents["/Game/UI/Fonts/GFGRemnantCracked_Font.GFGRemnantCracked_Font"]}})
    methods.AddChild(row, label)
    local tile = userWidget(name, "Widget_Loadout_C", {
      constructPath = W.TILE .. ":Construct", owner = player, IsEmpty = true,
      WidgetTree = engine.object(name .. ".WidgetTree"), Label = label, titleRow = row,
      EquippedIconBox = world.widget(name .. ".EquippedIconBox", {Visibility = 1}),
      children = {row},
    })
    local raw = tile.__raw
    raw.delegates = {OnClicked = delegate(), OnLoadoutSaved = delegate(), OnLoadoutSlotDeleted = delegate()}
    raw.Refresh = function(self)
      local r = self.__raw
      local override = r.LabelOverride and r.LabelOverride:ToString() or ""
      r.Label.__raw.Text = mock.text(override ~= "" and override or ("Loadout " .. (r.Index + 1)))
    end
    -- Stable UE4SS cannot read multicast delegates: the read escapes Lua pcall.
    setmetatable(raw, {__index = function(_, key)
      if raw.delegates[key] then
        if not world.multicast then error(mock.ABORT, 0) end
        return raw.delegates[key]
      end
    end})
    return tile
  end

  local wbl = engine.resident("/Script/UMG.Default__WidgetBlueprintLibrary")
  wbl.__raw.Create = function(_, outer, class, player)
    engine.requireGame("WidgetBlueprintLibrary.Create")
    assert(player == world.player, "CreateWidget needs the panel's local owning player")
    if class == engine.classes[W.TILE] then return world.createTile(outer, player) end
    if class == engine.classes[W.KEYICON] then
      local icon = userWidget(outer.__raw.fullName .. "." .. unique("Widget_KeyIcon_C"), "Widget_KeyIcon_C", {owner = player})
      icon.__raw.KeyText = world.widget(icon.__raw.fullName .. ".KeyText")
      return icon
    end
    error("unexpected widget class")
  end

  -- Loadouts panel -------------------------------------------------------------------
  local function vanillaRefresh(panel)
    local list = panel.__raw.LoadoutList
    while #list.__raw.children < 8 and not world.blockVanillaTiles do
      local tile = world.createTile(panel, panel.__raw.owner)
      tile.__raw.Index = #list.__raw.children
      tile.__raw.vanilla, tile.__raw.panel = true, panel
      methods.AddChild(list, tile)
      tile.__raw.Refresh(tile)
    end
  end

  function world.refreshPanel(panel)
    engine.callBlueprint(W.PANEL .. ":Refresh", panel, function() vanillaRefresh(panel) end, true)
  end

  -- opts.noOwner, opts.address (reuse after collection), opts.flags
  function world.openPanel(opts)
    opts = opts or {}
    engine.load(W.PANEL); engine.load(W.TILE)
    local name = "/Engine/Transient.BP_RemnantGameInstance_C_0." .. unique("Widget_InGameMenu_C") .. ".WidgetTree.Widget_LoadoutsPanel"
    local panel = userWidget(name, "Widget_LoadoutsPanel_C", {
      constructPath = W.PANEL .. ":Construct", owner = (not opts.noOwner) and world.player or nil,
      calls = {}, address = opts.address, flags = opts.flags,
    })
    local raw = panel.__raw
    raw.WidgetTree = engine.object(name .. ".WidgetTree")
    local size = world.widget(name .. ".WidgetTree.SizeBox_0", {HeightOverride = 688})
    local list = world.widget(name .. ".WidgetTree.LoadoutList", {className = "VerticalBox"})
    methods.AddChild(size, list)
    raw.children, raw.LoadoutList, raw.sizeBox = {size}, list, size
    for _, handler in ipairs({"OnLoadoutSlotSaved", "OnLoadoutClicked", "OnLoadoutSlotDeleted"}) do
      raw[handler] = function(self, index) self.__raw.calls[#self.__raw.calls + 1] = {handler, index} end
    end
    raw.constructBody = function() world.refreshPanel(panel) end
    world.panels[#world.panels + 1] = panel
    build(panel)
    return panel
  end

  function world.closePanel(panel)
    panel.__raw.dead = true
    for _, child in ipairs(panel.__raw.LoadoutList.__raw.children) do child.__raw.dead = true end
  end

  -- Tooltips -------------------------------------------------------------------------
  function world.showTooltip()
    engine.load(W.KEYICON)
    local name = "/Engine/Transient.BP_RemnantGameInstance_C_0." .. unique("Widget_LoadoutTooltip_C")
    local actions = world.widget(name .. ".Widget_Tooltip_Actions")
    actions.__raw.ExtraActionList = world.widget(name .. ".Widget_Tooltip_Actions.ExtraActionList")
    local tooltip = world.widget(name, {
      owner = world.player, WidgetTree = engine.object(name .. ".WidgetTree"),
      ItemLabel = world.widget(name .. ".ItemLabel", {Text = mock.text("Loadout"), Font = {FontObject = engine.residents["/Game/UI/Fonts/GFGRemnantCracked_Font.GFGRemnantCracked_Font"]}}),
      Widget_Tooltip_Actions = actions,
    })
    engine.findAll.Widget_LoadoutTooltip_C = {tooltip}
    return tooltip
  end

  -- HUD tick --------------------------------------------------------------------------
  function world.enterWorld()
    engine.load(W.HUD)
    world.hud = engine.object("/Engine/Transient.World:PersistentLevel.TPSHud_C_0")
  end

  function world.frame(ms, count)
    for _ = 1, count or 1 do
      if world.hud then
        engine.callBlueprint(W.HUD .. ":ReceiveTick", world.hud, nil, (ms or 50) / 1000)
      end
    end
  end

  function world.clientRestart()
    engine.callNative(W.CLIENT_RESTART, world.player, nil, engine.object("Pawn"))
  end

  -- Inventory lists -------------------------------------------------------------------
  function world.openList(label, opts)
    opts = opts or {}
    engine.load(W.LIST); engine.load(W.FILTER)
    local name = opts.fullName or ("/Engine/Transient.BP_RemnantGameInstance_C_0." .. unique("Widget_InGameMenu_C") .. ".WidgetTree.Widget_InventoryList_" .. label)
    local list = userWidget(name, "Widget_InventoryList_C", {
      constructPath = W.LIST .. ":Construct", owner = (not opts.noOwner) and world.player or nil, flags = opts.flags,
    })
    local raw = list.__raw
    local filter = world.widget(name .. ".WidgetTree.Widget_InventorySearchFilter", {Visibility = 1})
    filter.__raw.ComboBoxKey_58 = world.widget(name .. ".Combo", {Visibility = 0})
    if not opts.noBox then
      filter.__raw.SearchFilterText = world.widget(name .. ".SearchFilterText", {Visibility = 1, Text = mock.text("")})
    end
    raw.Widget_InventorySearchFilter, raw.children = filter, {filter}
    raw.InventoryGrid = world.widget(name .. ".WidgetTree.InventoryGrid")
    -- Vanilla's CanSeeSearchBar binding hides the bar while Slate builds it.
    raw.constructBody = function() filter.__raw.Visibility = 1 end
    raw.cardsNamed = opts.cards or {"Alpha Ring", "Beta Ring"}
    raw.firstItem = opts.firstItem or (#world.lists + 1) * 100
    world.lists[#world.lists + 1] = list
    if not opts.unbuilt then build(list) end
    return list
  end

  local function fillGrid(list)
    local raw = list.__raw
    local grid = raw.InventoryGrid
    grid.__raw.children = {}
    for i, label in ipairs(raw.cardsNamed) do
      local card = world.widget(grid.__raw.fullName .. ".Card" .. i, {ItemID = raw.firstItem + i, Visibility = 0})
      card.__raw.Get_InspectInfo = function(_, info) info.Label = mock.text(label) end
      grid.__raw.children[i] = card
    end
  end

  function world.buildList(list)
    engine.callBlueprint(W.LIST .. ":Build Inventory List", list, function() fillGrid(list) end)
  end

  function world.updateList(list, resetVisibility)
    engine.callBlueprint(W.LIST .. ":Update Inventory List", list, function()
      if resetVisibility then
        for _, card in ipairs(list.__raw.InventoryGrid.__raw.children) do card.__raw.Visibility = 0 end
      end
    end)
  end

  function world.type(list, text)
    local filter = list.__raw.Widget_InventorySearchFilter
    filter.__raw.SearchFilterText.__raw.Text = mock.text(text)
    engine.callBlueprint(W.TEXT_CHANGED, filter, nil, mock.text(text))
  end

  function world.clear(list)
    local filter = list.__raw.Widget_InventorySearchFilter
    filter.__raw.SearchFilterText.__raw.Text = mock.text("")
    engine.callBlueprint(W.X_BUTTON, filter)
  end

  function world.visibleCards(list)
    local shown = {}
    for _, card in ipairs(list.__raw.InventoryGrid.__raw.children) do
      if card.__raw.Visibility ~= 1 then shown[#shown + 1] = card.__raw.ItemID end
    end
    return shown
  end

  return world
end

return W
