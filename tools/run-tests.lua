-- Minimal test runner for Lua 5.1. No dependencies, deliberately small.
-- Usage: lua5.1.exe tools/run-tests.lua [--filter=PATTERN] <specfile>...

local argv = {...}
local filter, files = nil, {}
for i = 1, table.getn(argv) do
  local a = argv[i]
  local f = string.match(a, "^%-%-filter=(.*)$")
  if f then filter = f else files[table.getn(files) + 1] = a end
end

local builtinAssert = assert
local passed, failed, failures = 0, 0, {}
local currentDescribe, currentBeforeEach = nil, nil

-- Deep equality that reports the diverging key path. This is the one part of
-- the runner that has to be good: findings are nested tables, and "they differ"
-- is a useless failure message.
local function deepEqual(a, b, path)
  path = path or "<root>"
  if type(a) ~= type(b) then
    return false, path .. ": type " .. type(a) .. " vs " .. type(b)
  end
  if type(a) ~= "table" then
    if a ~= b then
      return false, path .. ": " .. tostring(a) .. " vs " .. tostring(b)
    end
    return true
  end
  for k, v in pairs(a) do
    local ok, p = deepEqual(v, b[k], path .. "." .. tostring(k))
    if not ok then return false, p end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false, path .. "." .. tostring(k) .. ": missing from expected value"
    end
  end
  return true
end

local A = setmetatable({}, {
  __call = function(_, ...) return builtinAssert(...) end,
})

function A.equals(expected, actual, msg)
  if expected ~= actual then
    error((msg or "equals") .. ": expected " .. tostring(expected)
          .. ", got " .. tostring(actual), 2)
  end
end

function A.same(expected, actual, msg)
  local ok, path = deepEqual(expected, actual)
  if not ok then
    error((msg or "same") .. ": differs at " .. path, 2)
  end
end

function A.truthy(v, msg)
  if not v then error((msg or "truthy") .. ": got " .. tostring(v), 2) end
end

function A.falsy(v, msg)
  if v then error((msg or "falsy") .. ": got " .. tostring(v), 2) end
end

function A.is_nil(v, msg)
  if v ~= nil then error((msg or "is_nil") .. ": got " .. tostring(v), 2) end
end

function A.matches(pattern, s, msg)
  if type(s) ~= "string" or not string.find(s, pattern) then
    error((msg or "matches") .. ": " .. tostring(s) .. " does not match " .. pattern, 2)
  end
end

assert = A

describe = function(name, fn)
  local previousDescribe, previousBefore = currentDescribe, currentBeforeEach
  currentDescribe, currentBeforeEach = name, nil
  fn()
  currentDescribe, currentBeforeEach = previousDescribe, previousBefore
end

before_each = function(fn) currentBeforeEach = fn end

it = function(name, fn)
  local full = (currentDescribe and (currentDescribe .. " > ") or "") .. name
  if filter and not string.find(full, filter, 1, true) then return end
  local before = currentBeforeEach
  local ok, err = xpcall(function()
    if before then before() end
    fn()
  end, function(e) return debug.traceback(tostring(e), 2) end)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    failures[table.getn(failures) + 1] = { name = full, err = err }
  end
end

-- From here on, writing a global is an error. Accidentally creating a global is
-- a classic WoW addon bug: you pollute the shared namespace of the whole
-- client. Outside the game that is free to catch.
setmetatable(_G, {
  __newindex = function(_, k)
    error("forbidden global created: " .. tostring(k) .. " (use local)", 2)
  end,
})

for i = 1, table.getn(files) do
  local chunk, loadErr = loadfile(files[i])
  if not chunk then
    failed = failed + 1
    failures[table.getn(failures) + 1] = { name = files[i], err = "load error: " .. tostring(loadErr) }
  else
    local ok, err = xpcall(chunk, function(e) return debug.traceback(tostring(e), 2) end)
    if not ok then
      failed = failed + 1
      failures[table.getn(failures) + 1] = { name = files[i], err = err }
    end
  end
end

for i = 1, table.getn(failures) do
  print("")
  print("FAIL: " .. failures[i].name)
  print(failures[i].err)
end

print("")
print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
os.exit(0)
