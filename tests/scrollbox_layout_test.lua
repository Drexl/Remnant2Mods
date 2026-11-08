-- Run from the repository root: lua tests/scrollbox_layout_test.lua
-- Mock construction/layout only; does not prove native ABI or rendered geometry.
local realPrint = print
local loops, queue, logs, onPanel = {}, {}, {}
local created, scrolls, frames, failFrame = 0, {}, {}, false
print = function(message) logs[#logs+1] = message end
local function obj(name)
  return {IsValid=function(self) return not self.dead end, GetFullName=function() return name end}
end
local function slot(parent)
  local s = obj("slot")
  s.Parent, s.Padding = parent, {Left=0, Top=0, Right=0, Bottom=0}
  return s
end
local function build(widget)
  -- Model Slate copying slot values when the subtree enters the live tree.
  widget.builtPadding = {}
  for key, value in pairs(widget.Slot.Padding) do widget.builtPadding[key] = value end
  for _, child in ipairs(widget.children or {}) do build(child) end
end
local function addChild(parent, child)
  parent.children[#parent.children+1] = child
  child.parent, child.Slot = parent, slot(parent)
  return child.Slot
end
local function tile(name)
  local t = obj(name)
  t.Refresh = function() end
  for _, event in ipairs({"OnClicked", "OnLoadoutSaved", "OnLoadoutSlotDeleted"}) do
    t[event] = {Add=function() end, Remove=function() end}
  end
  return t
end
local player, template, wbl = obj("local.Player"), obj("Gear_Loadout"), obj("WidgetBlueprintLibrary")
wbl.Create = function() created=created+1; return tile("Extra" .. created) end
StaticFindObject = function(path)
  if path == "/Script/UMG.Default__WidgetBlueprintLibrary" then return wbl end
  if path == "/Game/_Core/Loadouts/Gear_Loadout.Gear_Loadout" then return template end
  local class=obj(path); class.path=path; return class
end
StaticConstructObject = function(class)
  assert(class.path == "/Script/UMG.ScrollBox" or class.path == "/Script/UMG.Overlay")
  local widget = obj(class.path)
  widget.children = {}
  widget.Clipping = class.path == "/Script/UMG.ScrollBox" and 1 or 0
  widget.GetClass = function() return {GetFullName=function() return "Class " .. class.path end} end
  widget.AddChild = addChild
  if class.path == "/Script/UMG.ScrollBox" then scrolls[#scrolls+1]=widget
  else frames[#frames+1]=widget; widget.dead=failFrame end
  return widget
end
LoopAsync = function(_, fn) loops[#loops+1]=fn end
ExecuteInGameThread = function(fn) queue[#queue+1]=fn end
RegisterHook = function() end
NotifyOnNewObject = function(_, fn) onPanel=fn end
-- Also allow this focused test to run against the compatibility branch.
package.loaded.loadout_runtime = {new=function() return {
  watchPanels=function(fn) onPanel=fn end, start=function() end,
} end}
FName, FText = function(s) return s end, function(s) return s end
local function panel(name)
  local p, list, size = obj(name), obj(name .. ".list"), obj(name .. ".size")
  p.WidgetTree, p.LoadoutList, p.size = obj(name .. ".tree"), list, size
  p.GetOwningPlayer = function() return player end
  list.children, list.parent, list.Slot = {}, size, slot(size)
  list.GetParent = function(self) return self.parent end
  list.RemoveFromParent = function(self) self.parent=nil end
  list.GetChildrenCount = function(self) return #self.children end
  list.GetChildAt = function(self, i) return self.children[i+1] end
  list.AddChild = addChild
  size.child, size.HeightOverride = list, 688
  size.RemoveChild = function(self, child)
    if self.child == child then self.child=nil end
    if child.parent == self then child.parent=nil end
  end
  size.AddChild = function(self, child)
    if p.failAttach and child ~= list then return nil end
    self.child, child.parent, child.Slot = child, self, slot(self)
    build(child)
    return child.Slot
  end
  for i=0,7 do local t=tile("Vanilla" .. i); t.Index=i; addChild(list,t) end
  return p
end
local function drain()
  for _=1,20 do
    if #loops == 0 and #queue == 0 then return end
    local pending=loops; loops={}
    for _, fn in ipairs(pending) do if not fn() then loops[#loops+1]=fn end end
    pending=queue; queue={}
    for _, fn in ipairs(pending) do fn() end
  end
  error("scheduler did not quiesce")
end
local function check(p)
  local list = p.LoadoutList
  local scroll, frame = list.parent, list.parent.parent
  assert(p.size.child == frame and frame.parent == p.size)
  assert(scroll.Clipping == 1 and p.size.HeightOverride == 688, "retain clipped native-height viewport")
  assert(scroll.builtPadding.Left == -24 and list.builtPadding.Left == 24,
    "configure gutter before Slate builds the subtree")
  assert(scroll.builtPadding.Left + list.builtPadding.Left == 0, "do not shift tiles")
  for _, padding in ipairs({scroll.builtPadding,list.builtPadding}) do
    assert(padding.Top == 0 and padding.Right == 0 and padding.Bottom == 0)
  end
  assert(#list.children == 20)
end
dofile("MoreLoadoutSlots/Scripts/main.lua")
local first=panel("first"); onPanel(first); drain(); check(first)
onPanel(first); drain(); check(first)
assert(#scrolls == 1 and #frames == 1 and created == 12, "idempotent injection")
local second=panel("second"); onPanel(second); drain(); check(second)
assert(created == 24)
local failed=panel("attachFailure"); failed.failAttach=true
onPanel(failed); drain()
assert(failed.LoadoutList.parent == failed.size and failed.size.child == failed.LoadoutList,
  "restore original list if frame attachment fails")
assert(#failed.LoadoutList.children == 8 and created == 24)
failFrame=true
local unconstructed=panel("constructionFailure"); onPanel(unconstructed); drain()
assert(unconstructed.LoadoutList.parent == unconstructed.size and created == 24,
  "failed frame construction must not detach the original list")
print=realPrint
print("PASS: icon gutter, pre-build padding, unchanged clipping/height/tile position, reopen, idempotency and rollback.")
