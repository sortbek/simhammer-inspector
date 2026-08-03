-- Lists the item set IDs observed on tier slots in the captured data, so the
-- current tier set can be filled into Policy/Season.lua from evidence rather
-- than from a guess.
--
--   tools\lua\lua5.1.exe tools\list-setids.lua

local hydrated = dofile("spec/fixtures/hydrated.lua")

local TIER_SLOTS = { [1] = "head", [3] = "shoulders", [5] = "chest",
                     [10] = "hands", [7] = "legs" }

local bySet = {}
local embellishedSeen = 0

for i = 1, table.getn(hydrated) do
  local rec = hydrated[i]
  if rec.setID and TIER_SLOTS[rec.slot] then
    bySet[rec.setID] = bySet[rec.setID] or { count = 0, slots = {}, sample = nil }
    bySet[rec.setID].count = bySet[rec.setID].count + 1
    bySet[rec.setID].slots[TIER_SLOTS[rec.slot]] = true
    bySet[rec.setID].sample = bySet[rec.setID].sample or (rec.tooltip and rec.tooltip[1])
  end

  for j = 1, table.getn(rec.tooltip or {}) do
    local line = rec.tooltip[j]
    if type(line) == "string" and string.find(line, "Embellished", 1, true) then
      embellishedSeen = embellishedSeen + 1
      if embellishedSeen <= 3 then
        print("embellishment line: " .. string.format("%q", line))
      end
    end
  end
end

print("")
print("set IDs seen on tier slots:")
local ids = {}
for id in pairs(bySet) do ids[table.getn(ids) + 1] = id end
table.sort(ids)

for i = 1, table.getn(ids) do
  local id = ids[i]
  local slots = {}
  for slot in pairs(bySet[id].slots) do slots[table.getn(slots) + 1] = slot end
  table.sort(slots)
  print(string.format("  setID %-6d seen=%-3d slots=%-40s e.g. %s",
        id, bySet[id].count, table.concat(slots, ","), tostring(bySet[id].sample)))
end

print("")
print("tooltip lines containing 'Embellished': " .. embellishedSeen)
