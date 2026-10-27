-- Run from repo root: lua tests/loadout_style_test.lua
local styles = dofile("LoadoutNamer/Scripts/loadout_style.lua")
local gameFont = { IsValid = function() return true end }
local function mapped(fields, kinds)
  return setmetatable({}, {
    __index = fields,
    __newindex = function(_, key, value)
      if kinds and kinds[key] == "int" then
        assert(math.type(value) == "integer", key .. " requires an integer")
      elseif key ~= "FontObject" then
        assert(type(fields[key]) ~= "table", "whole-struct assignment forbidden: " .. key)
      end
      fields[key] = value
    end,
  })
end
local function color()
  return mapped({SpecifiedColor = mapped({R=1.0,G=1.0,B=1.0,A=1.0}), ColorUseRule=1}, {ColorUseRule="int"})
end
local function font()
  return mapped({Size=12, FontObject=gameFont}, {Size="int"})
end
local label = mapped({Font=font(), ColorAndOpacity=color()})
styles.prompt(label, gameFont)
assert(label.Font.Size == 10 and label.Font.FontObject == gameFont)
assert(label.ColorAndOpacity.SpecifiedColor.R == 0.7)
assert(label.ColorAndOpacity.ColorUseRule == 0)
local box = mapped({WidgetStyle=mapped({TextStyle=mapped({Font=font()}),
  ForegroundColor=color(), FocusedForegroundColor=color(),
  BackgroundImageNormal=mapped({TintColor=color()}),
  BackgroundImageHovered=mapped({TintColor=color()}),
  BackgroundImageFocused=mapped({TintColor=color()})})})
styles.editor(box, gameFont)
assert(box.WidgetStyle.TextStyle.Font.Size == 10)
assert(box.WidgetStyle.TextStyle.Font.FontObject == gameFont)
assert(box.WidgetStyle.ForegroundColor.SpecifiedColor.R == 0.85)
assert(box.WidgetStyle.FocusedForegroundColor.ColorUseRule == 0)
assert(box.WidgetStyle.BackgroundImageNormal.TintColor.SpecifiedColor.A == 0.85)
assert(box.WidgetStyle.BackgroundImageHovered.TintColor.SpecifiedColor.R == 0.04)
assert(box.WidgetStyle.BackgroundImageFocused.TintColor.SpecifiedColor.A == 0.9)
assert(not pcall(styles.prompt, label, nil))
local file = assert(io.open("LoadoutNamer/Scripts/main.lua", "r"))
local source = file:read("*a"); file:close()
assert(source:find('local styles = require("loadout_style")', 1, true), "main must load the leaf-only styling helper")
for _, property in ipairs({"label.Font", "label.ColorAndOpacity", "box.WidgetStyle", "style.TextStyle.Font"}) do
  local pattern = property:gsub("%.", "%%.") .. "%s*="
  assert(not source:match(pattern), "whole-struct write-back in main: " .. property)
end
local promptStyle = assert(source:find("applyPromptLabelStyle(label, tooltip.ItemLabel)", 1, true))
local promptAdd = assert(source:find("extra:AddChild(label)", promptStyle, true))
assert(promptStyle < promptAdd)
local editorStyle = assert(source:find("styleEditBox(box, tile.Label)", 1, true))
local editorAdd = assert(source:find("AddChild(box)", editorStyle, true))
assert(editorStyle < editorAdd)
print("PASS: prompt/editor scalar-only styling; whole-struct assignments and float font sizes forbidden; styled before insertion.")
