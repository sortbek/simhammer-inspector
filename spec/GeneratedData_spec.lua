local helper = dofile("spec/helper.lua")

-- Shape and sanity checks on the generated tables. These deliberately do not
-- assert exact counts: a regeneration against a newer build is expected to
-- change them, and a test that has to be edited on every regeneration teaches
-- people to edit tests instead of thinking.
local function data()
  return helper.loadModules({
    "RaidInspector/Data/Enchants.lua",
    "RaidInspector/Data/Gems.lua",
    "RaidInspector/Data/Version.lua",
    "RaidInspector/Data/TierSets.lua",
  }).Data
end

local VALID_QUALITY = { gold = true, silver = true }

local function auditTable(entries)
  local count, current, badShape = 0, 0, nil
  for id, info in pairs(entries) do
    count = count + 1
    if type(id) ~= "number" then badShape = badShape or ("non-numeric key: " .. tostring(id)) end
    if type(info) ~= "table" then badShape = badShape or ("non-table value at " .. tostring(id)) end
    if type(info.tier) ~= "string" then badShape = badShape or ("missing tier at " .. tostring(id)) end
    if info.quality ~= nil and not VALID_QUALITY[info.quality] then
      badShape = badShape or ("bad quality at " .. tostring(id) .. ": " .. tostring(info.quality))
    end
    if info.tier == "midnight-s1" then current = current + 1 end
  end
  return count, current, badShape
end

describe("generated enchant data", function()
  it("is a numeric-keyed table of well-formed entries", function()
    local count, _, badShape = auditTable(data().Enchants)
    assert.is_nil(badShape, tostring(badShape))
    assert.truthy(count > 1000, "expected the full history, got " .. count)
  end)

  it("contains current-season entries", function()
    local _, current = auditTable(data().Enchants)
    assert.truthy(current > 0, "no midnight-s1 enchants found")
  end)

  it("classifies both quality tiers in the current season", function()
    local silver, gold = 0, 0
    for _, info in pairs(data().Enchants) do
      if info.tier == "midnight-s1" then
        if info.quality == "silver" then silver = silver + 1 end
        if info.quality == "gold" then gold = gold + 1 end
      end
    end
    assert.truthy(silver > 0, "no silver enchants")
    assert.truthy(gold > 0, "no gold enchants")
  end)

  -- Enchant 2841 is an engineering tinker observed on gloves in real raid data.
  -- It has no crafting quality, and must classify as legacy rather than being
  -- absent -- absent would render as unknown instead of outdated.
  it("keeps quality-less legacy enchants in the table", function()
    local info = data().Enchants[2841]
    assert.truthy(info, "enchant 2841 missing from the table")
    assert.equals("legacy", info.tier)
    assert.is_nil(info.quality)
  end)
end)

describe("generated gem data", function()
  it("is a numeric-keyed table of well-formed entries", function()
    local count, _, badShape = auditTable(data().Gems)
    assert.is_nil(badShape, tostring(badShape))
    assert.truthy(count > 100, "expected the full history, got " .. count)
  end)

  it("classifies both quality tiers in the current season", function()
    local silver, gold = 0, 0
    for _, info in pairs(data().Gems) do
      if info.tier == "midnight-s1" then
        if info.quality == "silver" then silver = silver + 1 end
        if info.quality == "gold" then gold = gold + 1 end
      end
    end
    assert.truthy(silver > 0, "no silver gems")
    assert.truthy(gold > 0, "no gold gems")
  end)
end)

describe("generated version stamp", function()
  it("carries a parseable patch version and a build number", function()
    local v = data().Version
    assert.matches("^%d+%.%d+%.%d+$", v.version)
    assert.matches("^%d+$", v.build)
  end)
end)
