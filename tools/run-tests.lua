-- Minimale testrunner voor Lua 5.1. Geen dependencies, bewust klein gehouden.
-- Aanroep: lua5.1.exe tools/run-tests.lua [--filter=PATROON] <specbestand>...

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

-- Diepe gelijkheid die het afwijkende sleutelpad teruggeeft. Dit is het enige
-- stuk van de runner dat echt goed moet zijn: bevindingenlijsten zijn geneste
-- tabellen en "ze zijn ongelijk" is dan een nutteloze foutmelding.
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
      return false, path .. "." .. tostring(k) .. ": ontbreekt in verwachte waarde"
    end
  end
  return true
end

local A = setmetatable({}, {
  __call = function(_, ...) return builtinAssert(...) end,
})

function A.equals(expected, actual, msg)
  if expected ~= actual then
    error((msg or "equals") .. ": verwacht " .. tostring(expected)
          .. ", kreeg " .. tostring(actual), 2)
  end
end

function A.same(expected, actual, msg)
  local ok, path = deepEqual(expected, actual)
  if not ok then
    error((msg or "same") .. ": verschil bij " .. path, 2)
  end
end

function A.truthy(v, msg)
  if not v then error((msg or "truthy") .. ": kreeg " .. tostring(v), 2) end
end

function A.falsy(v, msg)
  if v then error((msg or "falsy") .. ": kreeg " .. tostring(v), 2) end
end

function A.is_nil(v, msg)
  if v ~= nil then error((msg or "is_nil") .. ": kreeg " .. tostring(v), 2) end
end

function A.matches(pattern, s, msg)
  if type(s) ~= "string" or not string.find(s, pattern) then
    error((msg or "matches") .. ": " .. tostring(s) .. " voldoet niet aan " .. pattern, 2)
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

-- Vanaf hier is het schrijven naar een global een fout. Per ongeluk een global
-- aanmaken is in WoW-addons een klassieke bug: je vervuilt de gedeelde
-- namespace van de hele client. Buiten de game is dat gratis te vangen.
setmetatable(_G, {
  __newindex = function(_, k)
    error("verboden global aangemaakt: " .. tostring(k) .. " (gebruik local)", 2)
  end,
})

for i = 1, table.getn(files) do
  local chunk, loadErr = loadfile(files[i])
  if not chunk then
    failed = failed + 1
    failures[table.getn(failures) + 1] = { name = files[i], err = "laadfout: " .. tostring(loadErr) }
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
  print("FAAL: " .. failures[i].name)
  print(failures[i].err)
end

print("")
print(string.format("%d geslaagd, %d gefaald", passed, failed))
if failed > 0 then os.exit(1) end
os.exit(0)
