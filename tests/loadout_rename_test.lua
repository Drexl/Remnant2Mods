-- Run: lua tests/loadout_rename_test.lua [path/to/LoadoutNamer/Scripts/main.lua]
-- UI/session integration with in-memory names/settings and a mock game thread.
local source = arg[1] or "LoadoutNamer/Scripts/main.lua"
package.path = source:match("^(.*[/\\])") .. "?.lua;" .. package.path
local realPrint, realOpen = print, io.open
local queue, loops, hooks, keys, logs, boxes = {}, {}, {}, {}, {}, {}
local inGame, onPanel, focusAfter, writes = false, nil, 1, 0
local namesText = "0\t0\tExisting name\n"
local function checkGame() assert(inGame, "editor UObject access outside game thread") end
print = function(s) logs[#logs+1]=s end
io.open = function(path, mode)
  local isNames = path:match("loadout_names%.txt$")
  if not isNames and not path:match("settings%.txt$") then return realOpen(path,mode) end
  local contents = isNames and namesText or "RenameKey=F2\n"
  local f = {close=function() end}
  f.lines = function()
    local lines={}; for line in contents:gmatch("[^\n]+") do lines[#lines+1]=line end
    local i=0; return function() i=i+1; return lines[i] end
  end
  if mode == "w" and isNames then writes=writes+1; namesText="" end
  f.write = function(_, s) if isNames then namesText=namesText .. s end end
  return f
end
FText = function(s) return {ToString=function() return s end} end
FName = function(s) return s end
Key = {F2=113, RETURN=13, ESCAPE=27, LEFT_MOUSE_BUTTON=1, RIGHT_MOUSE_BUTTON=2}
RegisterKeyBind = function(k, fn) keys[k]=fn end
RegisterHook = function(path, fn) hooks[path]=fn end
NotifyOnNewObject = function(_, fn) onPanel=fn end
package.loaded.loadout_runtime = {new=function() return {
  watchPanels=function(fn) onPanel=fn end, start=function() end,
  log=function(s) logs[#logs+1]=s end,
} end}
ExecuteInGameThread = function(fn) queue[#queue+1]=fn end
LoopAsync = function(_, fn) loops[#loops+1]=fn end
local function obj(name)
  return {IsValid=function(self) return not self.dead end, GetFullName=function() return name end}
end
local font = obj("gameFont")
StaticFindObject = function(path) local o=obj(path); o.path=path; return o end
StaticConstructObject = function(class)
  checkGame(); assert(class.path == "/Script/UMG.EditableTextBox")
  local box = obj("editor")
  box.IsValid = function(self) checkGame(); return not self.dead end
  box.GetParent = function(self) checkGame(); return self.parent end
  box.attempts, box.acceptAfter, box.focused = 0, focusAfter, false
  box.SetKeyboardFocus = function(self)
    checkGame(); assert(self.parent, "focus requested before insertion")
    self.attempts=self.attempts+1
    self.focused=self.attempts >= self.acceptAfter
  end
  box.IsHovered = function(self) checkGame(); return self.hovered == true end
  box.HasKeyboardFocus = function() checkGame(); return false end
  box.HasFocusedDescendants = function(self) checkGame(); return self.focused end
  boxes[#boxes+1]=box
  return box
end
local menu=obj("menu")
for _, prop in ipairs({"TraitTab","InventoryTab","MapTab"}) do
  local tab=obj(prop); tab.visibility=0
  tab.IsVisible=function(self) return self.visibility == 0 end
  tab.SetVisibility=function(self,v) checkGame(); self.visibility=v end
  menu[prop]=tab
end
menu.IsVisible=function() return true end
local active=obj("active"); active.ID=0
local manager=obj("manager")
manager.HasActiveCharacter=function() return true end
manager.GetActiveCharacter=function() return active end
local gi=obj("gameInstance"); gi.CharacterManager=manager
FindAllOf=function(class)
  if class == "GameInstance" then return {gi} end
  if class == "Widget_InGameMenu_C" then return {menu} end
  return {}
end
local panel=obj("panel")
local tiles={}
for i=0,19 do
  local tile, label, row=obj("tile"..i), obj("label"..i), obj("row"..i)
  tile.Index, tile.WidgetTree, tile.Label = i < 10 and i or i+1, obj("tree"), label
  tile.Refresh=function() end
  row.children={}
  row.AddChild=function(self, child)
    checkGame(); self.children[#self.children+1]=child; child.parent=self
    return obj("slot")
  end
  row.RemoveChild=function(self, child)
    checkGame()
    for j,c in ipairs(self.children) do if c == child then table.remove(self.children,j); break end end
    child.parent=nil
  end
  label.GetParent=function() return row end
  label.SetMinDesiredWidth=function(self,w) checkGame(); self.width=w end
  label.Font={FontObject=font}
  tiles[#tiles+1]=tile
end
panel.LoadoutList={GetChildrenCount=function() return #tiles end, GetChildAt=function(_,i) return tiles[i+1] end}
local function flush()
  local pending=queue; queue={}; inGame=true
  for _,fn in ipairs(pending) do fn() end
  inGame=false
end
local function tick(n)
  for _=1,n or 1 do
    local pending=loops; loops={}
    for _,fn in ipairs(pending) do if not fn() then loops[#loops+1]=fn end end
    flush()
  end
end
local function tabs(visibility)
  for _,prop in ipairs({"TraitTab","InventoryTab","MapTab"}) do assert(menu[prop].visibility == visibility) end
end
dofile(source)
onPanel(panel); tick()
local hover
for path,fn in pairs(hooks) do if path:find("BoundEvent_4_",1,true) then hover=fn end end
assert(hover,"hover hook not installed")
hover({get=function() return tiles[1] end})
local function open()
  keys[Key.F2](); flush()
  local box=boxes[#boxes]; assert(box.parent and tiles[1].Label.width == 0)
  tabs(2); return box
end
local box=open()
assert(box.focused and box.attempts == 1, "F2 must focus without a click")
assert(box.Text:ToString() == "Existing name" and box.SelectAllTextWhenFocused,
  "prefill/select the old name so an unchanged click-away cannot delete it")
box.Text=FText("  Saved\t on blur  "); box.focused=false
tick(4)
assert(not box.parent and writes == 1 and namesText == "0\t0\tSaved on blur\n")
assert(tiles[1].Label.width == 130); tabs(0)
box=open(); box.Text=FText("Discard me"); box.focused=false
tick(); keys[Key.ESCAPE](); tick(4)
assert(not box.parent and writes == 1 and tiles[1].LabelOverride:ToString() == "Saved on blur")
tabs(0)
box=open(); box.Text=FText("Enter saved")
keys[Key.RETURN](); keys[Key.F2](); flush(); tick(3)
assert(not box.parent and writes == 2 and namesText == "0\t0\tEnter saved\n", "one commit for duplicate finish requests")
box=open(); box.Text=FText("Do not save")
keys[Key.RETURN](); keys[Key.ESCAPE](); flush(); tick(3)
assert(writes == 2 and not box.parent, "Escape must override a queued commit")
local before=#boxes
keys[Key.F2](); keys[Key.F2](); flush(); flush(); tick(3)
assert(#boxes == before and writes == 2, "cancel a queued open without creating another editor")
focusAfter=3; box=open(); assert(not box.focused)
tick(3); assert(box.focused and box.attempts == 3 and box.parent and writes == 2)
box.Text=FText(""); keys[Key.RETURN](); flush(); tick(3)
assert(writes == 3 and namesText == "", "explicit empty commit removes the custom name")
focusAfter=math.huge; box=open(); tick(8)
assert(not box.parent and box.attempts == 4 and writes == 3, "bounded focus retry and cleanup")
tabs(0)
focusAfter=1; box=open(); box.Text={ToString=function() error("unreadable") end}
keys[Key.RETURN](); flush(); tick(3)
assert(writes == 3 and not box.parent, "unreadable text must not become a deleted name")
box=open(); box.Text=FText("wrong character"); active.ID=1
onPanel(panel); tick(); box.focused=false; tick(4)
assert(writes == 3 and not box.parent, "do not save an old session into a different character")
tabs(0)
box=open(); tiles[1].dead=true; tick(4)
assert(writes == 3 and not box.parent, "destroyed tile cancels and removes the editor")
tabs(0)
tiles[1].dead=false
box=open(); box.Text=FText("Pointer saved"); box.hovered=true
keys[Key.LEFT_MOUSE_BUTTON](); flush(); tick(2)
assert(box.parent and writes == 3, "clicking inside must not end the edit")
box.hovered=false
keys[Key.LEFT_MOUSE_BUTTON](); flush(); tick(3)
assert(not box.parent and writes == 4 and namesText == "1\t0\tPointer saved\n",
  "click outside must save even if the new target does not take keyboard focus")
box=open(); keys[Key.RIGHT_MOUSE_BUTTON](); flush(); tick(3)
assert(not box.parent and writes == 5, "right-click outside also finishes the edit")
tabs(0)
print,io.open=realPrint,realOpen
print("PASS: automatic/descendant focus, prefill, save-on-blur/click-away, Enter/Escape races, duplicate opens/closes, retries, read failures and lifetime guards.")
