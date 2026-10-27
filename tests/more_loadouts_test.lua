-- Run: lua tests/more_loadouts_test.lua [native]
-- Engine mocks; native-abort behavior is simulated, not a real UE4SS ABI test.
local native = arg[1] == "native"
local realPrint, realPcall = print, pcall
local ABORT = {}
local queue, loops, hooks, logs = {}, {}, {}, {}
local aborts, created = 0, 0
print = function(s) logs[#logs+1] = s end
-- Stable C++ exceptions can escape every Lua pcall: model that distinction.
pcall = function(fn, ...)
  local result = table.pack(realPcall(fn, ...))
  if not result[1] and result[2] == ABORT then error(ABORT, 0) end
  return table.unpack(result, 1, result.n)
end
local runtime = {}
runtime.log = function(s) logs[#logs+1] = s end
runtime.watchPanels = function(fn) runtime.onPanel = fn end
runtime.start = function() end
package.loaded.loadout_runtime = {new=function() return runtime end}
ExecuteInGameThread = function(fn) queue[#queue+1] = fn end
LoopAsync = function(_, fn) loops[#loops+1] = fn end
RegisterHook = function(path, fn) assert(not hooks[path], "duplicate hook"); hooks[path] = fn end
FText = function(s) return {text=s} end
FName = function(s) return s end
local function obj(name)
  return {IsValid=function(self) return not self.dead end, GetFullName=function() return name end}
end
local player, template = obj("local.Player"), obj("Gear_Loadout")
local component = obj("LoadoutComponent")
component.Slots = {{NumRecords=11}}
FindAllOf = function(name) assert(name == "LoadoutComponent"); return {component} end
FindFirstOf = function() error("nonlocal owner fallback forbidden") end
local function delegate()
  return {Add=function(self, owner, handler) self.owner, self.handler=owner, handler end,
    Remove=function(self) self.owner=nil end}
end
local function tile(name)
  local t = obj(name)
  t.IsEmpty, t.equipped = true, false
  t.EquippedIconBox = {IsVisible=function() return t.equipped end}
  t.Refresh = function() end
  local delegates = {OnClicked=delegate(), OnLoadoutSaved=delegate(), OnLoadoutSlotDeleted=delegate()}
  return setmetatable(t, {__index=function(_, key)
    if delegates[key] then
      if not native then error(ABORT, 0) end
      return delegates[key]
    end
  end})
end
local scrolls = {}
StaticConstructObject = function(class)
  assert(class.path == "/Script/UMG.ScrollBox")
  local scroll = obj("new.ScrollBox")
  scroll.GetClass = function() return {GetFullName=function() return "Class /Script/UMG.ScrollBox" end} end
  scroll.AddChild = function(self, child) child.parent = self end
  scrolls[#scrolls+1] = scroll
  return scroll
end
local wbl = obj("WidgetBlueprintLibrary")
wbl.Create = function(_, panel, _, owner)
  assert(owner == player)
  created = created+1
  return tile(panel:GetFullName() .. ".Extra" .. created)
end
StaticFindObject = function(path)
  if path == "/Script/UMG.Default__WidgetBlueprintLibrary" then return wbl end
  if path == "/Game/_Core/Loadouts/Gear_Loadout.Gear_Loadout" then return template end
  local class = obj(path); class.path=path; return class
end
local function panel(name)
  local p, size = obj(name), obj(name .. ".SizeBox")
  p.WidgetTree = obj(name .. ".WidgetTree")
  p.GetOwningPlayer = function() return player end
  p.calls = {}
  for _, handler in ipairs({"OnLoadoutSlotSaved", "OnLoadoutClicked", "OnLoadoutSlotDeleted"}) do
    p[handler] = function(self, idx) self.calls[#self.calls+1] = {handler,idx} end
  end
  local list = obj(name .. ".List")
  list.children, list.parent, list.Slot = {}, size, {Parent=size}
  list.GetParent = function(self) return self.parent end
  list.GetChildrenCount = function(self) return #self.children end
  list.GetChildAt = function(self, i) return self.children[i+1] end
  list.AddChild = function(self, child) self.children[#self.children+1] = child; return {} end
  size.RemoveChild = function(_, child) child.parent=nil end
  size.AddChild = function(self, child) child.parent=self end
  for i=0,7 do
    local t=tile(name .. ".Vanilla" .. i); t.Index=i; list.children[#list.children+1]=t
  end
  p.LoadoutList=list
  return p
end
local function drain()
  for _=1,20 do
    if #loops == 0 and #queue == 0 then return end
    local oldLoops=loops; loops={}
    for _, fn in ipairs(oldLoops) do if not fn() then loops[#loops+1]=fn end end
    local oldQueue=queue; queue={}
    for _, fn in ipairs(oldQueue) do
      local ok, err=realPcall(fn)
      if not ok then if err == ABORT then aborts=aborts+1 else error(err,0) end end
    end
  end
  error("scheduler did not quiesce")
end

dofile("MoreLoadoutSlots/Scripts/main.lua")
hooks["/Script/Engine.PlayerController:ClientRestart"]()
local first=panel("FirstPanel")
runtime.onPanel(first)
drain()
assert(component.Slots[1].NumRecords == 21)
assert(#first.LoadoutList.children == 20, "first setup must complete despite capability-probe abort")
assert(aborts == (native and 0 or 1))
local seen={}
for _, t in ipairs(first.LoadoutList.children) do
  assert(t.Index ~= 10 and not seen[t.Index], "reserved/duplicate record")
  seen[t.Index]=true
  if t.Index > 10 then assert(t.LabelOverride.text == "Loadout " .. t.Index) end
end
assert(seen[20] and seen[8] and seen[9])
runtime.onPanel(first)
drain()
assert(#first.LoadoutList.children == 20 and created == 12)
local second=panel("SecondPanel")
runtime.onPanel(second)
drain()
assert(#second.LoadoutList.children == 20 and created == 24)
assert(aborts == (native and 0 or 1))
local hookCount=0; for _ in pairs(hooks) do hookCount=hookCount+1 end
if native then
  assert(hookCount == 1) -- only ClientRestart; no forwarding alongside native bindings
  local t=first.LoadoutList.children[9]
  assert(t.OnClicked.owner == first and t.OnClicked.handler == "OnLoadoutClicked")
  assert(t.OnLoadoutSaved.owner == first and t.OnLoadoutSlotDeleted.owner == first)
else
  assert(hookCount == 4) -- spawn plus exactly three forwarding hooks
  local rmb, lmb, key
  for path, fn in pairs(hooks) do
    if path:find("BoundEvent_0_",1,true) then rmb=fn end
    if path:find("BoundEvent_2_",1,true) then lmb=fn end
    if path:find(":OnInputAction",1,true) then key=fn end
  end
  local t=second.LoadoutList.children[9]
  local self={get=function() return t end}
  rmb(self); drain()
  assert(#second.calls == 1 and second.calls[1][1] == "OnLoadoutSlotSaved")
  t.equipped=true; rmb(self); drain(); assert(#second.calls == 1)
  t.equipped=false; lmb(self); drain(); assert(#second.calls == 1) -- empty
  t.IsEmpty=false; lmb(self); drain(); assert(#second.calls == 2)
  key(self,nil,{get=function() return 1 end}); drain(); assert(#second.calls == 3)
  key(self,nil,{get=function() return 3 end}); drain(); assert(#second.calls == 4)
  assert(second.calls[4][1] == "OnLoadoutSlotDeleted" and second.calls[4][2] == 8)
end
print, pcall = realPrint, realPcall
print("PASS (" .. (native and "native" or "stable forwarding") .. "): first injection survives probe abort; reserved indices, idempotency, bindings and interaction gates.")
