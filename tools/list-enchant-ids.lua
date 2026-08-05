-- Lists the distinct enchant and gem IDs actually observed in the spike data,
-- with the slots they appeared on. Input for the DB2 schema exploration.

local svPath = ...
assert(svPath, "usage: lua5.1.exe tools/list-enchant-ids.lua <path>")

local env = {}
local chunk = assert(loadfile(svPath))
setfenv(chunk, env)
chunk()
local db = assert(env.SimhammerInspectorSpikeDB, "no SimhammerInspectorSpikeDB found")

local ns = {}
assert(loadfile("LinkParser.lua"))("SimhammerInspector", ns)
local parse = ns.LinkParser.parse

local enchants, gems = {}, {}

for i = 1, table.getn(db) do
  for slot, data in pairs(db[i].slots) do
    local p = parse(data.link)
    if p then
      if p.enchantID ~= 0 then
        enchants[p.enchantID] = enchants[p.enchantID] or { count = 0, slots = {} }
        enchants[p.enchantID].count = enchants[p.enchantID].count + 1
        enchants[p.enchantID].slots[slot] = true
      end
      for g = 1, 4 do
        local gemID = p.gemIDs[g]
        if gemID ~= 0 then
          gems[gemID] = (gems[gemID] or 0) + 1
        end
      end
    end
  end
end

local ids = {}
for id in pairs(enchants) do ids[table.getn(ids) + 1] = id end
table.sort(ids)

print("ENCHANT IDs")
for i = 1, table.getn(ids) do
  local id = ids[i]
  local slotList = {}
  for slot in pairs(enchants[id].slots) do
    slotList[table.getn(slotList) + 1] = slot
  end
  table.sort(slotList)
  print(string.format("%d\tseen=%d\tslots=%s", id, enchants[id].count,
        table.concat(slotList, ",")))
end

local gemIDs = {}
for id in pairs(gems) do gemIDs[table.getn(gemIDs) + 1] = id end
table.sort(gemIDs)

print("")
print("GEM IDs")
for i = 1, table.getn(gemIDs) do
  print(string.format("%d\tseen=%d", gemIDs[i], gems[gemIDs[i]]))
end
