-- Run from the repository root: lua tests/loadout_panel_lifetime_test.lua
-- A retired native panel can fault inside IsValid before Lua can catch it.
local function exercise(path)
  local callbacks={}
  function RegisterHook(path,callback)
      callbacks[path]=callbacks[path] or {};table.insert(callbacks[path],callback)
      return #callbacks[path],#callbacks[path]
  end
  function StaticFindObject()return {IsValid=function()return true end}end
  local root='/Game/UI2/UI_Widgets/UI_Game/UI_Game_Character/Widget_LoadoutsPanel.Widget_LoadoutsPanel_C'
  local api=dofile(path).new('LoadoutLifetimeFixture')
  local errors,ready,staleReads=0,{},0
  function api.log(message)if message:find('failed',1,true)then errors=errors+1 end end
  api.watchPanels(function(panel)ready[#ready+1]=panel end);api.start()
  local function panel(id,name,count)
      local p={id=id,name=name,count=count or 8}
      local function live()if p.retired then staleReads=staleReads+1;error('dereferenced a retired panel')end end
      function p:IsValid()live();return true end
      function p:GetAddress()live();return self.id end
      function p:GetFullName()live();return self.name end
      function p:HasAnyFlags()live();return false end
      function p:GetOwningPlayer()live();return {IsValid=function()return true end}end
      p.LoadoutList={IsValid=function()live();return true end,GetChildrenCount=function()live();return p.count end}
      return p
  end
  local function fire(event,p)
      for _,fn in ipairs(assert(callbacks[root..':'..event]))do fn({get=function()return p end})end
  end
  local first=panel(1,'Panel_1');fire('Construct',first);assert(#ready==1)
  first.retired=true
  local second=panel(2,'Panel_2');fire('Refresh',second);assert(#ready==1)
  fire('Construct',second);assert(#ready==2,'a retired cached panel prevented the new panel becoming ready')
  fire('Refresh',second);assert(#ready==2,'completed panel initialization repeated')
  second.retired=true
  local reused=panel(1,'Panel_3');fire('Construct',reused);assert(#ready==3,'same-address replacement inherited old readiness')
  local delayed=panel(4,'Panel_4',2);fire('Construct',delayed);fire('Refresh',delayed)
  assert(#ready==3);delayed.count=8;fire('Refresh',delayed);assert(#ready==4,'readiness retry was lost')
  assert(staleReads==0 and errors==0,'old native references were still read')
  print('PASS '..path..': retired panels, address reuse and delayed readiness without old UObject reads.')
end

exercise("LoadoutNamer/Scripts/loadout_runtime.lua")
exercise("MoreLoadoutSlots/Scripts/loadout_runtime.lua")
