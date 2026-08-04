-- Cross-checks the generated data tables against the enchant and gem IDs that
-- were actually observed in the spike. If the generator's derivation is wrong,
-- this is where it shows up.
--
--   tools\lua\lua5.1.exe tools\verify-generated.lua <path to SavedVariables>

local svPath = ...
assert(svPath, "usage: lua5.1.exe tools/verify-generated.lua <path>")

local env = {}
local chunk = assert(loadfile(svPath))
setfenv(chunk, env)
chunk()
local db = assert(env.SimhammerInspectorSpikeDB, "no SimhammerInspectorSpikeDB found")

local ns = {}
for _, path in ipairs({
  "SimhammerInspector/LinkParser.lua",
  "SimhammerInspector/Data/Enchants.lua",
  "SimhammerInspector/Data/Gems.lua",
  "SimhammerInspector/Data/Version.lua",
}) do
  assert(loadfile(path), "could not load " .. path)("SimhammerInspector", ns)
end

local parse = ns.LinkParser.parse
local enchants, gems = {}, {}

for i = 1, table.getn(db) do
  for slot, data in pairs(db[i].slots) do
    local p = parse(data.link)
    if p then
      if p.enchantID ~= 0 then
        enchants[p.enchantID] = (enchants[p.enchantID] or 0) + 1
      end
      for g = 1, 4 do
        if p.gemIDs[g] ~= 0 then
          gems[p.gemIDs[g]] = (gems[p.gemIDs[g]] or 0) + 1
        end
      end
    end
  end
end

local function report(label, observed, lookup)
  local ids = {}
  for id in pairs(observed) do ids[table.getn(ids) + 1] = id end
  table.sort(ids)

  local unknown = 0
  print("=== " .. label .. " ===")
  for i = 1, table.getn(ids) do
    local id = ids[i]
    local info = lookup[id]
    if info then
      print(string.format("%8d  seen=%-3d %-8s %s", id, observed[id],
            tostring(info.quality), info.tier))
    else
      unknown = unknown + 1
      print(string.format("%8d  seen=%-3d NOT IN TABLE", id, observed[id]))
    end
  end
  return unknown
end

local unknownEnchants = report("enchants observed in the raid", enchants, ns.Data.Enchants)
print("")
local unknownGems = report("gems observed in the raid", gems, ns.Data.Gems)

print("")
print(string.format("data version: %s build %s", ns.Data.Version.version, ns.Data.Version.build))
print(string.format("unresolved: %d enchants, %d gems", unknownEnchants, unknownGems))
if unknownEnchants > 0 or unknownGems > 0 then os.exit(1) end
