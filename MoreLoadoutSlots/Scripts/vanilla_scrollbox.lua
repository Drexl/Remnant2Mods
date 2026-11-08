-- Reuse Unreal's property instancing rather than manually copying style structs
-- (whole-struct style writes are unsupported on stable UE4SS).
local M = {}
local TEMPLATE = "/Game/UI2/UI_Widgets/UI_Game/UI_Game_Equipment/Widget_AdvancedStats.Widget_AdvancedStats_C:WidgetTree.ScrollBox_143"

function M.create(scrollClass, outer)
  local source = StaticFindObject(TEMPLATE)
  assert(source and source:IsValid(), "vanilla advanced-stats scrollbar template is unavailable")
  assert(source:GetClass():GetAddress() == scrollClass:GetAddress(), "unexpected stats scrollbar class")
  local sourceCount, sourceChildren = source:GetChildrenCount(), {}
  for i = 0, sourceCount - 1 do
    sourceChildren[i+1] = source:GetChildAt(i):GetAddress()
  end

  -- Parameter 8 is UObject Template. The design-time widget does not have
  -- RF_ArchetypeObject, so AssumeTemplateIsArchetype (parameter 7) stays false.
  local scroll = StaticConstructObject(scrollClass, outer, 0, 0, 0, false, false, source)
  assert(scroll and scroll:IsValid(), "could not instantiate the vanilla scrollbar")
  assert(scroll:GetAddress() ~= source:GetAddress(), "constructor returned the source scrollbar")

  -- Unreal copies the Slots array but shares its slot/content UObject references.
  -- This new ScrollBox has never built Slate or entered the live tree. Drop ONLY
  -- its private array of references, without ClearChildren/RemoveChild callbacks
  -- that would modify the original stats widgets. Verify array ownership first.
  local slots, sourceSlots = scroll.Slots, source.Slots
  assert(slots:GetArrayAddress() ~= sourceSlots:GetArrayAddress(), "stats slot containers alias")
  local sourceData = sourceSlots:GetArrayDataAddress()
  if #slots > 0 then
    assert(slots:GetArrayDataAddress() ~= sourceData, "stats slot buffers alias")
  end
  slots:Empty()
  assert(scroll:GetChildrenCount() == 0, "could not reset copied slot references")
  assert(sourceSlots:GetArrayDataAddress() == sourceData and source:GetChildrenCount() == sourceCount,
    "stats template slots changed")
  for i = 0, sourceCount - 1 do
    assert(source:GetChildAt(i):GetAddress() == sourceChildren[i+1], "stats template children changed")
  end
  return scroll
end

return M
