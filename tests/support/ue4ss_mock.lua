-- Offline model of the pinned UE4SS 3.0.1 Lua surface used by the UI mods.
-- It enforces the threading contract the mods rely on. It does not reproduce
-- native dispatch, Slate layout, rendering or marshaling.
--
-- Contexts: "start" (mod load), "game" (Blueprint hooks, the HUD tick),
-- "construct" (StaticConstructObject listeners, any thread), "input" (keybinds,
-- UE4SS's own thread). UObject access outside "game" fails, except for the
-- identity reads that construction listeners need.
local M = {}
local realPcall = pcall
M.ABORT = setmetatable({}, {__tostring = function() return "native exception (pierces Lua pcall)" end})

local CONSTRUCT_SAFE = {IsValid = true, GetClass = true, HasAnyFlags = true, GetFullName = true, GetAddress = true}

-- Lazily created nested tables, for struct fields such as Font or WidgetStyle.
function M.struct()
  return setmetatable({}, {__index = function(t, k)
    local v = M.struct(); rawset(t, k, v); return v
  end})
end

function M.text(value)
  return {ToString = function() return value end}
end

function M.new(options)
  options = options or {}
  local engine = {
    logs = {}, context = nil, hooks = {}, active = {}, listeners = {}, keybinds = {},
    loaded = {}, residents = {}, classes = {}, findAll = {}, aborts = {}, violations = {},
    nextId = 0, nextHookId = 0, mods = {},
  }

  local function violation(message)
    engine.violations[#engine.violations + 1] = message
    error(message, 0)
  end

  function engine.within(context, fn, ...)
    local previous = engine.context
    engine.context = context
    local result = table.pack(realPcall(fn, ...))
    engine.context = previous
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
  end

  function engine.requireGame(what)
    if engine.context ~= "game" then
      violation(what .. " outside the game thread (" .. tostring(engine.context) .. ")")
    end
  end

  -- UObjects ----------------------------------------------------------------
  local proto = {}
  function proto.IsValid(self) return not rawget(self.__raw, "dead") end
  function proto.GetAddress(self) return self.__raw.address end
  function proto.GetFullName(self) return self.__raw.fullName end
  function proto.HasAnyFlags(self, mask) return ((self.__raw.flags or 0) & mask) ~= 0 end
  function proto.GetClass(self)
    local className = self.__raw.className or "Object"
    return {
      GetFName = function() return M.text(className) end,
      GetFullName = function() return "Class " .. (self.__raw.classPath or className) end,
      GetAddress = function() return self.__raw.classAddress end,
    }
  end

  function engine.object(fullName, fields)
    engine.nextId = engine.nextId + 1
    local raw = fields or {}
    raw.fullName, raw.address = fullName, raw.address or engine.nextId
    local obj = {}
    setmetatable(obj, {
      __index = function(_, key)
        if key == "__raw" then return raw end
        if not raw.unguarded and not (engine.context == "construct" and CONSTRUCT_SAFE[key]) then
          engine.requireGame("read of " .. fullName .. "." .. tostring(key))
        end
        local value = raw[key]
        if value == nil then value = proto[key] end
        if value == nil and raw.methods then value = raw.methods[key] end
        return value
      end,
      __newindex = function(_, key, value)
        if not raw.unguarded then engine.requireGame("write of " .. fullName .. "." .. tostring(key)) end
        raw[key] = value
      end,
    })
    return obj
  end

  -- Resident metadata such as assets and default objects, readable anywhere.
  function engine.resident(path, fields)
    fields = fields or {}
    fields.unguarded = true
    local obj = engine.object(path, fields)
    engine.residents[path] = obj
    return obj
  end

  -- A class is visible to StaticFindObject and RegisterHook once loaded.
  function engine.class(path, fields, loaded)
    fields = fields or {}
    fields.unguarded, fields.classPath = true, path
    engine.classes[path] = engine.object(path, fields)
    if loaded then engine.loaded[path] = true end
    return engine.classes[path]
  end

  function engine.load(classPath)
    assert(engine.classes[classPath], "unknown class " .. classPath)
    engine.loaded[classPath] = true
  end

  function engine.addFindAll(className, obj)
    local list = engine.findAll[className] or {}
    list[#list + 1] = obj
    engine.findAll[className] = list
  end

  -- Hooks ---------------------------------------------------------------------
  local function functionClass(path)
    return path:match("^(.-):[^:]+$")
  end

  function engine.registerHook(mod, path, pre, post)
    assert(type(pre) == "function", "RegisterHook needs a callback")
    if engine.active[path] then
      violation("RegisterHook into " .. path .. " during its own dispatch")
    end
    local class = functionClass(path)
    if not engine.loaded[class] then
      error("Tried to register a hook with Lua function 'RegisterHook' but no UFunction with the specified name was found.", 0)
    end
    engine.nextHookId = engine.nextHookId + 1
    local id = engine.nextHookId
    local list = engine.hooks[path] or {}
    -- Blueprint paths: the first callback runs after the function and the
    -- second does nothing (pinned docs). Native paths: pre and post.
    list[#list + 1] = {mod = mod, id = id, pre = pre, post = path:find("^/Script/") and post or nil}
    engine.hooks[path] = list
    return id, id
  end

  function engine.unregisterHook(_, path, preId)
    if engine.active[path] then
      violation("UnregisterHook from " .. path .. " during its own dispatch")
    end
    local list = engine.hooks[path] or {}
    for i, hook in ipairs(list) do
      if hook.id == preId then table.remove(list, i); return end
    end
  end

  local function param(value)
    return {get = function() return value end}
  end

  -- Runs every callback for path in registration order. Like UE4SS's TRY, an
  -- escaped native exception or uncaught Lua error ends the whole dispatch.
  function engine.dispatch(path, selfObj, ...)
    local list = engine.hooks[path]
    if not list or #list == 0 then return 0 end
    local args = table.pack(...)
    local wrapped = {n = args.n}
    for i = 1, args.n do wrapped[i] = param(args[i]) end
    engine.active[path] = (engine.active[path] or 0) + 1
    local snapshot = {table.unpack(list)}
    local ran = 0
    local ok, err = realPcall(function()
      engine.within("game", function()
        for _, hook in ipairs(snapshot) do
          ran = ran + 1
          hook.pre(param(selfObj), table.unpack(wrapped, 1, wrapped.n))
        end
      end)
    end)
    engine.active[path] = engine.active[path] - 1
    if engine.active[path] == 0 then engine.active[path] = nil end
    if not ok then
      engine.aborts[#engine.aborts + 1] = {path = path, error = err, skipped = #snapshot - ran}
      if err ~= M.ABORT then engine.logs[#engine.logs + 1] = "[UE4SS] " .. tostring(err) end
    end
    return ran
  end

  -- Blueprint function body, then UE4SS's post-callback hooks.
  function engine.callBlueprint(path, selfObj, body, ...)
    engine.within("game", function() if body then body() end end)
    return engine.dispatch(path, selfObj, ...)
  end

  -- Native function: pre hooks, then the body.
  function engine.callNative(path, selfObj, body, ...)
    engine.dispatch(path, selfObj, ...)
    if body then engine.within("game", body) end
  end

  -- StaticConstructObject listeners -------------------------------------------
  function engine.construct(obj)
    local raw = obj.__raw
    local remaining = {}
    for _, listener in ipairs(engine.listeners) do
      local cancel = false
      if raw.isUserWidget then
        local ok, result = realPcall(engine.within, "construct", listener.fn, obj)
        if not ok then
          engine.logs[#engine.logs + 1] = "[UE4SS] " .. tostring(result)
        else
          cancel = result == true
        end
      end
      if not cancel then remaining[#remaining + 1] = listener end
    end
    engine.listeners = remaining
    return obj
  end

  function engine.key(mod, key)
    local fn = engine.keybinds[mod] and engine.keybinds[mod][key]
    if fn then engine.within("input", fn) end
  end

  -- Mods ----------------------------------------------------------------------
  local function forbidden(name)
    return function()
      violation(name .. " is not allowed: it runs work off the game thread or lazily registers ProcessEvent")
    end
  end

  -- main: optional source text that replaces scriptsDir/main.lua.
  function engine.loadMod(name, scriptsDir, files, main)
    local env = setmetatable({}, {__index = _G})
    local loadedModules = {}
    env.print = function(message) engine.logs[#engine.logs + 1] = message end
    env.pcall = function(fn, ...)
      local result = table.pack(realPcall(fn, ...))
      if not result[1] and result[2] == M.ABORT then error(M.ABORT, 0) end
      return table.unpack(result, 1, result.n)
    end
    env.RegisterHook = function(path, pre, post) return engine.registerHook(name, path, pre, post) end
    env.UnregisterHook = function(path, pre, post) return engine.unregisterHook(name, path, pre, post) end
    env.NotifyOnNewObject = function(path, fn)
      assert(engine.loaded[path], "NotifyOnNewObject class must already exist: " .. path)
      engine.listeners[#engine.listeners + 1] = {mod = name, path = path, fn = fn}
    end
    env.RegisterKeyBind = function(key, fn)
      engine.keybinds[name] = engine.keybinds[name] or {}
      engine.keybinds[name][key] = fn
    end
    env.StaticFindObject = function(path)
      if engine.classes[path] then
        return engine.loaded[path] and engine.classes[path] or nil
      end
      return engine.residents[path]
    end
    env.FindAllOf = function(className)
      engine.requireGame("FindAllOf(" .. className .. ")")
      return engine.findAll[className]
    end
    env.FindFirstOf = function(className)
      engine.requireGame("FindFirstOf(" .. className .. ")")
      local all = engine.findAll[className]
      return all and all[1]
    end
    env.StaticConstructObject = function(class, outer, ...)
      engine.requireGame("StaticConstructObject")
      assert(class and class.__raw.construct, "unexpected StaticConstructObject class")
      return class.__raw.construct(outer, ...)
    end
    env.FText = function(s) return M.text(s) end
    env.FName = function(s) return s end
    env.Key = {F2 = 113, F3 = 114, RETURN = 13, ESCAPE = 27, LEFT_MOUSE_BUTTON = 1, RIGHT_MOUSE_BUTTON = 2}
    for _, api in ipairs({"ExecuteInGameThread", "LoopAsync", "ExecuteWithDelay", "ExecuteAsync"}) do
      env[api] = forbidden(api)
    end
    env.io = setmetatable({open = function(path, mode)
      local key = path:match("([^/\\]+)$")
      if not files or not files[key] then return nil, "no such file" end
      local file = files[key]
      if mode == "w" then file.text = ""; file.writes = (file.writes or 0) + 1 end
      return {
        close = function() end,
        write = function(_, s) file.text = file.text .. s end,
        lines = function()
          local lines = {}
          for line in file.text:gmatch("[^\n]+") do lines[#lines + 1] = line end
          local i = 0
          return function() i = i + 1; return lines[i] end
        end,
        read = function() return file.text end,
      }
    end}, {__index = io})
    env.require = function(module)
      if loadedModules[module] == nil then
        local chunk = assert(loadfile(scriptsDir .. "/" .. module .. ".lua", "t", env))
        loadedModules[module] = chunk() or true
      end
      return loadedModules[module]
    end
    engine.mods[name] = env
    engine.within("start", function()
      if main then
        assert(load(main, "=" .. name .. "/main.lua", "t", env))()
      else
        assert(loadfile(scriptsDir .. "/main.lua", "t", env))()
      end
    end)
    return env
  end

  function engine.logCount(needle)
    local count = 0
    for _, line in ipairs(engine.logs) do
      if tostring(line):find(needle, 1, true) then count = count + 1 end
    end
    return count
  end

  function engine.hookCount(path)
    return engine.hooks[path] and #engine.hooks[path] or 0
  end

  function engine.assertClean()
    assert(#engine.violations == 0, "threading violation: " .. tostring(engine.violations[1]))
  end

  return engine
end

return M
