-- Run: lua tests/vanilla_scrollbox_test.lua
-- Mocks validate the constructor/array-ownership contract, not Unreal's ABI.
local vanilla = dofile("MoreLoadoutSlots/Scripts/vanilla_scrollbox.lua")
local path = "/Game/UI2/UI_Widgets/UI_Game/UI_Game_Equipment/Widget_AdvancedStats.Widget_AdvancedStats_C:WidgetTree.ScrollBox_143"
local nextId, source, mode, constructed, emptied = 100, nil, nil, 0, 0
local function obj()
  nextId=nextId+1; local id=nextId
  return {IsValid=function(self) return not self.dead end, GetAddress=function() return id end}
end
local class, outer = obj(), obj()
local function slots()
  local s=obj(); s.entries={}; s.data=obj():GetAddress()
  s.GetArrayAddress=s.GetAddress
  s.GetArrayDataAddress=function(self) return #self.entries > 0 and self.data or 0 end
  s.Empty=function(self)
    assert(self ~= source.Slots, "never empty the original stats array")
    emptied=emptied+1
    if mode ~= "emptyFails" then self.entries={} end
  end
  return setmetatable(s,{__len=function(self) return #self.entries end})
end
local function container()
  local c=obj(); c.Slots=slots()
  c.GetChildrenCount=function(self) return #self.Slots end
  c.GetChildAt=function(self,i) return self.Slots.entries[i+1] end
  c.ClearChildren=function() error("must not invoke shared-child removal callbacks") end
  return c
end
local function fixture()
  source=container()
  source.GetClass=function() return class end
  source.Slots.entries={obj(),obj()}
  source.WidgetStyle={marker="native track/shadow assets"}
  source.WidgetBarStyle={marker="native normal/hover/drag assets"}
  source.ScrollbarThickness={X=3,Y=7}
  source.ScrollbarPadding={Left=2,Top=3,Right=4,Bottom=5}
  source.Orientation=1
  source.ScrollBarVisibility=4
  source.WheelScrollMultiplier=1.75
  source.AllowOverscroll=false
  source.bAnimateWheelScrolling=true
  source.ScrollWhenFocusChanges=2
  mode,constructed,emptied=nil,0,0
end
StaticFindObject=function(p) assert(p == path); return source end
StaticConstructObject=function(...)
  local args=table.pack(...)
  assert(args.n == 8 and args[1] == class and args[2] == outer)
  assert(args[3] == 0 and args[4] == 0 and args[5] == 0)
  assert(args[6] == false and args[7] == false and args[8] == source,
    "pass the design template as argument 8 without assuming archetype flags")
  constructed=constructed+1
  if mode == "aliasObject" then return source end
  if mode == "invalid" then return nil end
  local result=container()
  -- Model reflected property copying, including the observed shared slot refs.
  for _,name in ipairs({"WidgetStyle","WidgetBarStyle","ScrollbarThickness","ScrollbarPadding",
      "Orientation","ScrollBarVisibility","WheelScrollMultiplier","AllowOverscroll",
      "bAnimateWheelScrolling","ScrollWhenFocusChanges"}) do result[name]=source[name] end
  for _,c in ipairs(source.Slots.entries) do result.Slots.entries[#result.Slots.entries+1]=c end
  if mode == "aliasContainer" then result.Slots=source.Slots end
  if mode == "aliasBuffer" then result.Slots.data=source.Slots.data end
  return result
end
fixture()
local originalFirst=source:GetChildAt(0)
local result=vanilla.create(class,outer)
assert(result ~= source and result:GetChildrenCount() == 0 and emptied == 1)
assert(source:GetChildrenCount() == 2 and source:GetChildAt(0) == originalFirst)
assert(result.WidgetStyle.marker == "native track/shadow assets")
assert(result.WidgetBarStyle.marker == "native normal/hover/drag assets")
assert(result.WheelScrollMultiplier == 1.75 and result.AllowOverscroll == false)
assert(result.bAnimateWheelScrolling and result.ScrollWhenFocusChanges == 2)
assert(result.ScrollbarThickness.Y == 7 and result.ScrollbarPadding.Right == 4)
fixture(); source.Slots.entries={}
assert(vanilla.create(class,outer):GetChildrenCount() == 0)
for _,failure in ipairs({"aliasObject","invalid","aliasContainer","aliasBuffer","emptyFails"}) do
  fixture(); mode=failure
  local before=source:GetChildAt(0)
  assert(not pcall(vanilla.create,class,outer),"must reject " .. failure)
  assert(source:GetChildAt(0) == before and source:GetChildrenCount() == 2)
  if failure ~= "emptyFails" then assert(emptied == 0,"validate storage ownership before resetting references") end
end
fixture(); source.dead=true
assert(not pcall(vanilla.create,class,outer) and constructed == 0)
fixture(); source.GetClass=function() return obj() end
assert(not pcall(vanilla.create,class,outer) and constructed == 0)
local f=assert(io.open("MoreLoadoutSlots/Scripts/main.lua","r"))
local main=f:read("*a"); f:close()
assert(main:find('require("vanilla_scrollbox")',1,true))
local create=assert(main:find("pcall(vanillaScrollBox.create, scrollClass, panel.WidgetTree)",1,true))
assert(main:find("sizeBox:AddChild(",create,true),"construct before attachment")
assert(main:find("Vanilla scrollbar unavailable; using the engine default",1,true),"fallback must be explicit")
assert(not main:find("scrollbarStyle",1,true),"remove the manual tint approach")
print("PASS: native template/settings, private slot reset with shared children, source preservation, alias guards and explicit fallback.")
