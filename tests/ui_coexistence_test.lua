-- Run from the repository root: lua tests/ui_coexistence_test.lua
-- Loads the real EquipmentSearch, LoadoutNamer and MoreLoadoutSlots entry points
-- into one modelled UE4SS process with a shared Blueprint hook registry. The
-- model enforces game-thread UObject access and forbids LoopAsync and
-- ExecuteInGameThread. It does not prove native dispatch, threads or rendering.
package.path = "tests/support/?.lua;" .. package.path
local W = require("remnant_world")
local realPrint = print
local RESERVED = 10

local function files()
  return {
    ["loadout_names.txt"] = {text = "0\t0\tFirst\n0\t9\tNinth\n0\t20\tTwentieth\n"},
    ["settings.txt"] = {text = "RenameKey=F2\n"},
  }
end

local function loadAll(world, order, fs)
  local dirs = {
    EquipmentSearch = "EquipmentSearch/Scripts",
    LoadoutNamer = "LoadoutNamer/Scripts",
    MoreLoadoutSlots = "MoreLoadoutSlots/Scripts",
  }
  for _, name in ipairs(order) do
    world.engine.loadMod(name, dirs[name], name == "LoadoutNamer" and fs or nil)
  end
end

local function labels(panel)
  local out = {}
  for _, tile in ipairs(panel.__raw.LoadoutList.__raw.children) do
    out[tile.__raw.Index] = tile.__raw.Label.__raw.Text:ToString()
  end
  return out
end

local function checkPanel(world, panel, expectNames)
  local list = panel.__raw.LoadoutList
  assert(#list.__raw.children == 20, "expected 20 tiles, got " .. #list.__raw.children)
  local seen = {}
  for _, tile in ipairs(list.__raw.children) do
    local index = tile.__raw.Index
    assert(index ~= RESERVED and not seen[index], "reserved or duplicate record " .. tostring(index))
    seen[index] = true
  end
  assert(seen[8] and seen[9] and seen[11] and seen[20])
  local scroll = list.__raw.parent
  assert(scroll and scroll.__raw.className == "ScrollBox", "tile list must sit inside the injected ScrollBox")
  if expectNames then
    local text = labels(panel)
    assert(text[0] == "First" and text[9] == "Ninth" and text[20] == "Twentieth",
      "saved names must reach vanilla and extra tiles in either mod order")
    assert(text[1] == "Loadout 2" and text[11] == "Loadout 11", "unnamed tiles keep their labels")
  end
end

local function scenario(order, multicast)
  local world = W.new({multicast = multicast})
  local engine = world.engine
  local fs = files()
  loadAll(world, order, fs)

  -- Cold start: Blueprint classes are not loaded, so only the native ancestor
  -- listeners and the native spawn hook exist.
  assert(#engine.listeners == 3, "each UI mod waits for its class")
  assert(engine.hookCount(W.CLIENT_RESTART) == 1)
  for path in pairs(engine.hooks) do
    assert(path == W.CLIENT_RESTART, "no Blueprint hook before its class loads: " .. path)
  end

  -- Startup storm: unrelated widgets and design-time objects only meet the
  -- listener's identity checks, from whatever thread constructs them.
  for i = 1, 40 do world.userWidget("/Game/UI/Startup.Startup_C:WidgetTree.W" .. i, "Startup_C") end
  world.clientRestart() -- main-menu controller
  assert(world.component.__raw.Slots[1].NumRecords == 21 and world.component.__raw.Slots[2].NumRecords == 21)
  assert(#engine.listeners == 3)

  world.enterWorld()
  world.frame(50, 3)

  -- A loaded design-time list proves the class exists; EquipmentSearch stops listening.
  engine.load(W.LIST); engine.load(W.FILTER)
  world.userWidget("/Game/UI/UI_Inventory/Widget_Equipment_Screen.Widget_Equipment_Screen_C:WidgetTree.Widget_InventoryList",
    "Widget_InventoryList_C", {flags = 0x80400})
  assert(#engine.listeners == 2, "EquipmentSearch cancels its construction listener after registering")
  assert(engine.hookCount(W.LIST .. ":Construct") == 1)

  -- Another mod's HUD-tick callback (like BoF's servicing) may refresh widgets
  -- synchronously. A list that exists before it is first shown then gets Update
  -- inside the tick's callback iteration, where registering the tick is unsafe.
  local foreign = true
  engine.registerHook("OtherMod", W.HUD .. ":ReceiveTick", function()
    if not foreign then return end
    for _, list in ipairs(world.lists) do world.updateList(list) end
  end)
  local prebuilt = world.openList("Prebuilt", {unbuilt = true})
  world.frame(50, 3)
  assert(engine.hookCount(W.HUD .. ":ReceiveTick") == 1, "no tick registration from inside the HUD tick")
  assert(engine.logCount("Search bar enabled on " .. prebuilt.__raw.fullName) == 0)
  foreign = false

  -- First Loadouts open: both loadout mods register from the construction
  -- listener, then become ready inside the panel's own Construct.
  local first = world.openPanel()
  assert(#engine.listeners == 0, "all construction listeners are cancelled")
  checkPanel(world, first, true)
  if multicast then
    assert(#engine.aborts == 0)
  else
    assert(#engine.aborts == 1 and engine.aborts[1].path == W.PANEL .. ":Refresh",
      "the stable delegate probe may abort only its own Refresh dispatch")
  end
  assert(engine.hookCount(W.PANEL .. ":Refresh") == 2, "probe hook retired; two readiness hooks remain")
  assert(engine.logCount("Live Loadouts panel ready") == 2)
  -- On stable the abort ends the probe before its own log line, as before.
  assert(engine.logCount("Multicast delegate Lua support: yes") == (multicast and 1 or 0))
  assert(engine.hookCount(W.HUD .. ":ReceiveTick") == 2, "LoadoutNamer registers its HUD tick from the panel")

  -- Extra-tile interactions reach the current panel from the click hook itself.
  local extra = first.__raw.LoadoutList.__raw.children[9]
  if multicast then
    assert(engine.hookCount(W.TILE_RMB) == 0, "no forwarding alongside native bindings")
    assert(extra.__raw.delegates.OnClicked.owner == first)
  else
    extra.__raw.IsEmpty = false
    engine.callBlueprint(W.TILE_RMB, extra)
    engine.callBlueprint(W.TILE_LMB, extra)
    engine.callBlueprint(W.TILE_INPUT, extra, nil, extra, 3)
    local calls = first.__raw.calls
    assert(#calls == 3 and calls[1][1] == "OnLoadoutSlotSaved" and calls[1][2] == 8)
    assert(calls[2][1] == "OnLoadoutClicked" and calls[3][1] == "OnLoadoutSlotDeleted")
    local vanilla = first.__raw.LoadoutList.__raw.children[1]
    engine.callBlueprint(W.TILE_RMB, vanilla)
    assert(#calls == 3, "vanilla tiles already reach the panel")
  end

  -- Hover runs tooltip discovery and writes on HUD ticks.
  local tooltip = world.showTooltip()
  local named = first.__raw.LoadoutList.__raw.children[20]
  assert(named.__raw.Index == 20)
  engine.callBlueprint(W.TILE_HOVER, named)
  assert(tooltip.__raw.ItemLabel.__raw.Text:ToString() == "Loadout", "no tooltip writes inside the hover hook")
  world.frame(50, 2)
  assert(tooltip.__raw.ItemLabel.__raw.Text:ToString() == "Twentieth")
  local extraList = tooltip.__raw.Widget_Tooltip_Actions.__raw.ExtraActionList
  assert(#extraList.__raw.children == 2, "one rename prompt per tooltip")
  world.frame(50, 25)
  assert(#extraList.__raw.children == 2)

  -- Rename: keybinds run on UE4SS's input thread and only record the request.
  engine.key("LoadoutNamer", 113)
  assert(not world.editors, "F2 must not touch widgets from the input thread")
  world.frame(0)
  local box = world.editors[1]
  assert(box.__raw.parent and box.__raw.Text:ToString() == "Twentieth" and box.__raw.focused)
  box.__raw.Text = W and require("ue4ss_mock").text("Renamed slot")
  engine.key("LoadoutNamer", 13)
  world.frame(0)
  assert(not box.__raw.parent and fs["loadout_names.txt"].text:find("0\t20\tRenamed slot", 1, true))
  assert(named.__raw.Label.__raw.Text:ToString() == "Renamed slot")
  for _, prop in ipairs({"TraitTab", "InventoryTab", "MapTab"}) do
    assert(world.menu.__raw[prop].__raw.Visibility == 0, "tab hotkeys restored")
  end

  -- Inventory lists: several open at once, one without its text box until a
  -- later Build, one without an owner. Readiness runs in each list's hooks.
  local equipment = world.openList("Equipment")
  local materials = world.openList("Materials", {firstItem = 300})
  local quests = world.openList("Quests", {noBox = true, firstItem = 400})
  local ownerless = world.openList("Ownerless", {noOwner = true})
  for _, list in ipairs({equipment, materials, quests, ownerless}) do world.buildList(list) end
  assert(engine.hookCount(W.HUD .. ":ReceiveTick") == 3, "EquipmentSearch registers its own HUD tick from a list")
  assert(engine.logCount("Search bar enabled on") == 2)
  local filter = equipment.__raw.Widget_InventorySearchFilter
  assert(filter.__raw.Visibility == 0 and filter.__raw.SearchFilterText.__raw.Visibility == 0)
  assert(filter.__raw.ComboBoxKey_58.__raw.Visibility == 1)
  quests.__raw.Widget_InventorySearchFilter.__raw.SearchFilterText =
    world.widget(quests.__raw.fullName .. ".LateBox", {Visibility = 1, Text = require("ue4ss_mock").text("")})
  world.buildList(quests)
  assert(engine.logCount("Search bar enabled on") == 3, "a late text box is picked up by the next Build")
  for _ = 1, 40 do world.updateList(ownerless) end
  assert(engine.logCount("List readiness timed out") == 1, "bounded readiness for an ownerless list")

  -- The construction-time binding may hide the bar again; the delayed
  -- re-application runs on the HUD tick.
  filter.__raw.Visibility = 1
  world.frame(100, 5)
  assert(filter.__raw.Visibility == 0)

  -- Live filtering stays per list.
  world.type(equipment, "alpha")
  local shown = world.visibleCards(equipment)
  assert(#shown == 1 and shown[1] == equipment.__raw.firstItem + 1)
  assert(#world.visibleCards(materials) == 2, "queries remain per list")
  -- A vanilla pass that resets cards is re-filtered by its hook and the watchdog.
  world.updateList(equipment, true)
  assert(#world.visibleCards(equipment) == 1)
  world.frame(100, 2) -- let the one-shot 150 ms pass finish first
  for _, card in ipairs(equipment.__raw.InventoryGrid.__raw.children) do card.__raw.Visibility = 0 end
  world.frame(100, 4)
  assert(#world.visibleCards(equipment) == 1, "watchdog re-applies after an unhooked reset")
  world.clear(equipment)
  assert(#world.visibleCards(equipment) == 2)

  -- A Slate rebuild re-applies vanilla's binding; Construct re-shows the bar once.
  equipment.__raw.built = false
  world.build(equipment)
  assert(filter.__raw.Visibility == 0)
  assert(engine.logCount("Search bar enabled on " .. equipment.__raw.fullName) == 1)

  -- Reopen: a new panel instance, even at a reused address, is readied once.
  world.closePanel(first)
  local reopened = world.openPanel()
  checkPanel(world, reopened, false)
  assert(labels(reopened)[20] == "Renamed slot")
  world.closePanel(reopened)
  local reused = world.openPanel()
  checkPanel(world, reused, false)
  assert(engine.logCount("Live Loadouts panel ready") == 6)

  engine.assertClean()
  assert(engine.logCount("FAILED") == 0 and engine.logCount("failed") == 0, "unexpected failure log")
  return engine
end

local engines = {
  scenario({"EquipmentSearch", "LoadoutNamer", "MoreLoadoutSlots"}, false),
  scenario({"MoreLoadoutSlots", "EquipmentSearch", "LoadoutNamer"}, false),
  scenario({"LoadoutNamer", "MoreLoadoutSlots", "EquipmentSearch"}, true),
}
assert(#engines == 3)

-- Hot reload inside a world: classes are resident, so hooks register at start
-- and no construction listener is added.
local world = W.new({multicast = false})
for _, path in ipairs({W.PANEL, W.TILE, W.LIST, W.FILTER, W.HUD}) do world.engine.load(path) end
world.hud = world.engine.object("/Engine/Transient.World:PersistentLevel.TPSHud_C_0")
loadAll(world, {"LoadoutNamer", "EquipmentSearch", "MoreLoadoutSlots"}, files())
assert(#world.engine.listeners == 0, "hot reload needs no construction listener")
assert(world.engine.hookCount(W.HUD .. ":ReceiveTick") == 2)
local panel = world.openPanel()
checkPanel(world, panel, true)
world.engine.assertClean()

print = realPrint
print("PASS: three UI mods coexist without LoopAsync/ExecuteInGameThread; cold start, hot reload, both loadout hook orders, stable probe isolation, readiness, extra slots, names, tooltip, rename, inventory filtering, retries and reopen.")
