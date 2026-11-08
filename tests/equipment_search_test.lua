-- Run from repo root: lua tests/equipment_search_test.lua
-- Executes the real entry point with scheduling/reflection mocks, not Unreal's ABI.
local realPrint = print
local logs, loops, queue, hooks = {}, {}, {}, {}
local inGameThread, notify, nextId = false, nil, 0
print = function(message) logs[#logs + 1] = message end
ExecuteInGameThread = function(fn) queue[#queue + 1] = fn end
LoopAsync = function(ms, fn)
    loops[#loops + 1] = {ms = ms, remaining = ms, fn = fn}
end
StaticFindObject = function(path)
    assert(path == "/Script/UMG.UserWidget" or path == "/Script/GunfireRuntime.InspectInfo",
        "do not resolve an unloaded Blueprint class")
    return {IsValid = function() return true end, ForEachProperty = function() end}
end
NotifyOnNewObject = function(path, fn)
    assert(path == "/Script/UMG.UserWidget", "cold start must watch the native ancestor")
    assert(not notify, "register exactly one construction listener")
    notify = fn
end
RegisterHook = function(path, pre, post)
    assert(inGameThread and not hooks[path], "hooks must register once, after list readiness")
    hooks[path] = {pre = pre, post = post}
end
FindAllOf = function() error("no global discovery scans during startup") end

local function tickWorker()
    local old = loops; loops = {}
    for _, task in ipairs(old) do
        task.remaining = task.remaining - 50
        if task.remaining > 0 then
            loops[#loops + 1] = task
        elseif not task.fn() then
            task.remaining = task.ms
            loops[#loops + 1] = task
        end
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
local function logCount(needle)
    local count = 0
    for _, line in ipairs(logs) do
        if line:find(needle, 1, true) then count = count + 1 end
    end
    return count
end
local function object(name)
    nextId = nextId + 1
    local obj = {valid = true, id = nextId, name = name, Visibility = 1, writes = 0}
    function obj:IsValid() return self.valid end
    function obj:GetAddress() return self.id end
    function obj:GetFullName() return self.name end
    function obj:SetVisibility(value)
        assert(inGameThread, "widget mutations must run on the game thread")
        self.Visibility, self.writes = value, self.writes + 1
    end
    return obj
end
local function text(value)
    return {ToString = function() return value end}
end
local function list(name, className, flags)
    local obj = object(name)
    obj.owner = object(name .. ".Player")
    function obj:GetClass()
        return {GetFName = function()
            return text(className or "Widget_InventoryList_C")
        end}
    end
    function obj:HasAnyFlags(mask) return ((flags or 0) & mask) ~= 0 end
    function obj:GetOwningPlayer()
        assert(inGameThread)
        return self.owner
    end
    -- Detect off-thread child reads even while children are uninitialized.
    obj.children = {}
    setmetatable(obj, {__index = function(self, key)
        if key == "Widget_InventorySearchFilter" then
            assert(inGameThread, "read child readiness on the game thread")
            return self.children.filter
        end
    end})
    return obj
end
local function addFilter(obj, withBox)
    local filter = object(obj.name .. ".Filter")
    filter.ComboBoxKey_58 = object(obj.name .. ".Combo")
    obj.children.filter = filter
    if withBox then
        filter.SearchFilterText = object(obj.name .. ".Box")
        filter.SearchFilterText.Text = text("")
    end
    return filter
end
local function addCards(obj, firstId)
    local cards = {}
    for i, name in ipairs({"Alpha Ring", "Beta Ring"}) do
        local card = object(obj.name .. ".Card" .. i)
        card.ItemID, card.Visibility = firstId + i, 0
        function card:Get_InspectInfo(info)
            assert(inGameThread)
            info.Label = text(name)
        end
        cards[i] = card
    end
    obj.InventoryGrid = object(obj.name .. ".Grid")
    function obj.InventoryGrid:GetChildrenCount() assert(inGameThread); return #cards end
    function obj.InventoryGrid:GetChildAt(i) assert(inGameThread); return cards[i + 1] end
    return cards
end

dofile("EquipmentSearch/Scripts/main.lua")
assert(not next(hooks) and #loops == 0 and notify)
assert(logCount("Native widget listener started") == 1)
notify(nil)
local dead = list("Dead"); dead.valid = false; notify(dead)
notify(list("Unrelated", "OtherWidget_C"))
notify(list("Archetype", nil, 0x20))
notify(list("CDO", nil, 0x10))
notify(list("Default__InventoryList"))
assert(#loops == 0, "ignore unrelated, invalid and template objects before polling")

local live = list("Equipment")
notify(live); notify(live)
assert(#loops == 1, "deduplicate pending instances")
for _ = 1, 100 do tickWorker() end
assert(#queue == 1, "a stalled game thread must not accumulate callbacks")
tickGame(); advance(2)
assert(logCount("Search bar enabled on") == 0)
local filter = addFilter(live, false)
advance(2)
assert(logCount("Search bar enabled on") == 0, "wait for the text box")
filter.SearchFilterText = object("Equipment.Box")
filter.SearchFilterText.Text = text("")
live.owner.valid = false
advance(2)
assert(logCount("Search bar enabled on") == 0, "wait for a live owning player")
live.owner.valid = true
local cards = addCards(live, 100)
advance(2)
assert(logCount("Search bar enabled on Equipment") == 1)
assert(filter.Visibility == 0 and filter.SearchFilterText.Visibility == 0)
assert(filter.ComboBoxKey_58.Visibility == 1)
local hookCount = 0
for _ in pairs(hooks) do hookCount = hookCount + 1 end
assert(hookCount == 6, "text, clear, focus in/out and Update/Build hooks")
notify(live); advance(2)
assert(logCount("Search bar enabled on Equipment") == 1, "initialize each live list once")
filter.Visibility, filter.SearchFilterText.Visibility = 1, 1
advance(10)
assert(filter.Visibility == 0 and filter.SearchFilterText.Visibility == 0,
    "delayed reapply must outlast vanilla's construction-time visibility binding")

-- Multiple inventory-tab lists initialize independently without re-registering hooks.
local inventory, inventoryCards = {}, {}
for i, name in ipairs({"Materials", "Quests", "Usables"}) do
    inventory[i] = list(name)
    addFilter(inventory[i], true)
    inventoryCards[i] = addCards(inventory[i], 200 + i * 10)
    notify(inventory[i])
end
advance(12)
assert(logCount("Search bar enabled on") == 4)
local changed, clear
for path, hook in pairs(hooks) do
    if path:find("OnEditableTextBoxChangedEvent__DelegateSignature", 1, true) then changed = hook.pre end
    if path:find("OnButtonClickedEvent__DelegateSignature", 1, true) then clear = hook.pre end
end
assert(changed and clear)
filter.SearchFilterText.Text = text("alpha")
changed(); tickGame()
assert(cards[1].Visibility == 0 and cards[2].Visibility == 1)
for _, group in ipairs(inventoryCards) do
    assert(group[1].Visibility == 0 and group[2].Visibility == 0, "queries must remain per-list")
end
filter.SearchFilterText.Text = text("")
clear(); tickGame()
assert(cards[1].Visibility == 0 and cards[2].Visibility == 0, "X/empty query restores the grid")

local destroyed = list("Destroyed")
notify(destroyed); destroyed.valid = false; advance(2)
local reused = list("ReusedAddress"); reused.id = destroyed.id
addFilter(reused, true); notify(reused); advance(12)
assert(logCount("Search bar enabled on ReusedAddress") == 1)
local ownerless = list("Ownerless"); ownerless.owner = nil
addFilter(ownerless, true); notify(ownerless)
local unready = list("MissingChildren"); notify(unready)
advance(45)
assert(logCount("List readiness timed out") == 2)
assert(logCount("Search bar enabled on Ownerless") == 0)
assert(logCount("Search bar enabled on MissingChildren") == 0)
local broken = list("Broken"); addFilter(broken, true)
broken.GetOwningPlayer = function() error("owner read failed") end
notify(broken); advance(2)
assert(logCount("List setup failed:") == 1 and logCount("owner read failed") == 1,
    "novel readiness errors must be logged, not swallowed")
local reopened = list("Reopened"); local reopenedFilter = addFilter(reopened, true)
notify(reopened); advance(2)
reopenedFilter.SetVisibility = function() error("reapply failed") end
advance(12)
assert(logCount("Search bar reapply error:") == 1)
assert(#loops == 1 and loops[1].ms == 300 and #queue == 0,
    "only the pre-existing filter watchdog should remain after bounded readiness work")
assert(logCount("List setup failed:") == 1 and logCount("assertion failed") == 0)
assert(logCount("hook registration FAILED") == 0 and logCount("refresh error:") == 0)
print = realPrint
print("PASS: native cold-start listener, template/lifetime/readiness guards, deduplication, bounded game-thread work, delayed reapply, multi-list filtering and clear.")
