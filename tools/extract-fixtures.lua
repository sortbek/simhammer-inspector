-- Turns the spike's SavedVariables into the link fixtures used by the parser
-- tests. One-off helper, not part of the addon. Run with:
--   tools\lua\lua5.1.exe tools\extract-fixtures.lua <path to SavedVariables>

local svPath = ...
assert(svPath, "usage: lua5.1.exe tools/extract-fixtures.lua <path>")

local env = {}
local chunk = assert(loadfile(svPath))
setfenv(chunk, env)
chunk()
local db = assert(env.RaidInspectorSpikeDB, "no RaidInspectorSpikeDB found")

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
      consider("ringWithEnchantAndGem", (slot == 11 or slot == 12) and p.enchantID ~= 0, data, p)
      consider("bareNoEnchantNoGem", p.enchantID == 0 and p.gemCount == 0, data, p)
      consider("weaponEnchanted", slot == 16 and p.enchantID ~= 0, data, p)
      consider("upgradedItem", has(data.tooltip, "Upgrade Level"), data, p)
      consider("heldInOffhand", slot == 17, data, p)
    end
  end
end

print("-- GENERATED from real spike data.")
print("-- Do not edit by hand; regenerate with tools/extract-fixtures.lua.")
print("")
print("return {")

local order = { "ringWithEnchantAndGem", "craftedEmbellished", "weaponEnchanted",
                "bareNoEnchantNoGem", "upgradedItem", "heldInOffhand" }
for _, key in ipairs(order) do
  local b = best[key]
  if b then
    print(string.format("  -- itemID %d, enchant %d, %d gems, %d bonus IDs",
          b.p.itemID, b.p.enchantID, b.p.gemCount, table.getn(b.p.bonusIDs)))
    print(string.format("  %s =", key))
    print(string.format("    %q,", b.data.link))
    print("")
  else
    print("  -- MISSING from the spike data: " .. key)
    print("")
  end
end

print("  notAnItem =")
print('    "|cff71d5ff|Hspell:12345|h[A spell]|h|r",')
print("}")
