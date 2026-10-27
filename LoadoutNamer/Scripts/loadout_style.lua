-- Leaf-only styling: stable UE4SS maps struct reads to widget memory but cannot
-- assign UScriptStruct userdata back as a whole struct. Never do that here.
-- Apply BEFORE AddChild so Slate builds with the configured font/brush values.
local M = {}

local function color(value, r, g, b, a)
  value.SpecifiedColor.R = r
  value.SpecifiedColor.G = g
  value.SpecifiedColor.B = b
  value.SpecifiedColor.A = a
  value.ColorUseRule = 0 -- UseColor_Specified
end

local function font(value, fontObject)
  assert(fontObject and fontObject:IsValid(), "game font is unavailable")
  value.Size = 10 -- int32, NOT 10.0
  value.FontObject = fontObject
end

function M.prompt(label, fontObject)
  font(label.Font, fontObject)
  color(label.ColorAndOpacity, 0.7, 0.7, 0.7, 1.0)
end

function M.editor(box, fontObject)
  local style = box.WidgetStyle
  font(style.TextStyle.Font, fontObject)
  color(style.ForegroundColor, 0.85, 0.85, 0.85, 1.0)
  color(style.FocusedForegroundColor, 0.85, 0.85, 0.85, 1.0)
  color(style.BackgroundImageNormal.TintColor, 0.02, 0.02, 0.02, 0.85)
  color(style.BackgroundImageHovered.TintColor, 0.04, 0.04, 0.04, 0.9)
  color(style.BackgroundImageFocused.TintColor, 0.04, 0.04, 0.04, 0.9)
end

return M
