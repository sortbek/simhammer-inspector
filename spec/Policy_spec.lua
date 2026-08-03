local helper = dofile("spec/helper.lua")

local function policy()
  return helper.loadModules({
    "RaidInspector/Policy/Slots.lua",
    "RaidInspector/Policy/Season.lua",
  }).Policy
end

describe("Policy slots", function()
  it("controleert precies zestien slots", function()
    assert.equals(16, table.getn(policy().Slots.ALL))
  end)

  it("markeert helm, shoulders, chest, benen, boots en ringen als enchantbaar", function()
    local S = policy().Slots
    assert.truthy(S.isEnchantable(1))
    assert.truthy(S.isEnchantable(3))
    assert.truthy(S.isEnchantable(5))
    assert.truthy(S.isEnchantable(7))
    assert.truthy(S.isEnchantable(8))
    assert.truthy(S.isEnchantable(11))
    assert.truthy(S.isEnchantable(12))
  end)

  it("markeert cloak en bracers niet als enchantbaar in Midnight", function()
    local S = policy().Slots
    assert.falsy(S.isEnchantable(15))
    assert.falsy(S.isEnchantable(9))
  end)

  it("eist een enchant op een off-hand wapen maar niet op een schild", function()
    local S = policy().Slots
    assert.truthy(S.isEnchantable(17, "weapon"))
    assert.falsy(S.isEnchantable(17, "shield"))
    assert.falsy(S.isEnchantable(17, "holdable"))
  end)

  it("markeert helm, bracers en riem als socket-baar", function()
    local S = policy().Slots
    assert.truthy(S.isSocketable(1))
    assert.truthy(S.isSocketable(9))
    assert.truthy(S.isSocketable(6))
    assert.falsy(S.isSocketable(5))
  end)

  it("kent vijf tier-slots", function()
    assert.equals(5, table.getn(policy().Slots.TIER))
  end)
end)

describe("Policy seizoen", function()
  it("noemt de actuele tier", function()
    assert.equals("midnight-s1", policy().Season.CURRENT_TIER)
  end)

  it("staat maximaal twee embellishments toe", function()
    assert.equals(2, policy().Season.MAX_EMBELLISHMENTS)
  end)

  it("houdt de tier-setIDs op één plek", function()
    assert.equals("table", type(policy().Season.TIER_SET_IDS))
  end)
end)
