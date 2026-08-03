local svPath = ...
local env = {}
local chunk = assert(loadfile(svPath))
setfenv(chunk, env)
chunk()
local db = env.RaidInspectorSpikeDB

local ns = {}
assert(loadfile("RaidInspector/LinkParser.lua"))("RaidInspector", ns)
local parse = ns.LinkParser.parse

local function has(tooltip, needle)
  for _, line in ipairs(tooltip) do
    if type(line) == "string" and string.find(line, needle, 1, true) then return true end
  end
  return false
end

local best = {}
local function consider(key, cond, data, p)
  if cond and not best[key] then best[key] = { data = data, p = p } end
end

for i = 1, table.getn(db) do
  for slot, data in pairs(db[i].slots) do
    local p = parse(data.link)
    if p then
      consider("craftedEmbellished", has(data.tooltip, "Embellished"), data, p)
      consider("socketedWithGem", p.gemCount > 0 and has(data.tooltip, "Socket"), data, p)
      consider("ringWithEnchantAndGem", (slot == 11 or slot == 12) and p.enchantID ~= 0, data, p)
      consider("bareNoEnchantNoGem", p.enchantID == 0 and p.gemCount == 0, data, p)
      consider("weaponEnchanted", slot == 16 and p.enchantID ~= 0, data, p)
      consider("upgradedItem", has(data.tooltip, "Upgrade Level"), data, p)
      consider("heldInOffhand", slot == 17, data, p)
    end
  end
end

print("-- GEGENEREERD uit echte spike-data, Midnight 12.0.7 build 68887.")
print("-- Niet met de hand aanpassen; regenereer met tools/extract-fixtures.lua.")
print("")
print("return {")
local order = { "ringWithEnchantAndGem", "socketedWithGem", "craftedEmbellished",
                "bareNoEnchantNoGem", "weaponEnchanted", "upgradedItem", "heldInOffhand" }
for _, key in ipairs(order) do
  local b = best[key]
  if b then
    print(string.format("  -- itemID %d, enchant %d, %d gems, %d bonus-IDs",
          b.p.itemID, b.p.enchantID, b.p.gemCount, table.getn(b.p.bonusIDs)))
    print(string.format("  %s =", key))
    print(string.format("    %q,", b.data.link))
    print("")
  else
    print("  -- ONTBREEKT in de spike-data: " .. key)
    print("")
  end
end
print("  notAnItem =")
print('    "|cff71d5ff|Hspell:12345|h[Een spreuk]|h|r",')
print("}")
