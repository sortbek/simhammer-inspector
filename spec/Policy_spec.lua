local helper = dofile("spec/helper.lua")

local function policy()
  return helper.loadModules({
    "SimhammerInspector/Policy/Slots.lua",
    "SimhammerInspector/Policy/Season.lua",
  }).Policy
end

describe("Policy slots", function()
  it("checks exactly sixteen slots", function()
    assert.equals(16, table.getn(policy().Slots.ALL))
  end)

  it("marks helm, shoulders, chest, legs, boots and rings as enchantable", function()
    local S = policy().Slots
    assert.truthy(S.isEnchantable(1))
    assert.truthy(S.isEnchantable(3))
    assert.truthy(S.isEnchantable(5))
    assert.truthy(S.isEnchantable(7))
    assert.truthy(S.isEnchantable(8))
    assert.truthy(S.isEnchantable(11))
    assert.truthy(S.isEnchantable(12))
  end)

  it("does not mark cloak and bracers as enchantable in Midnight", function()
    local S = policy().Slots
    assert.falsy(S.isEnchantable(15))
    assert.falsy(S.isEnchantable(9))
  end)

  -- Matched on the numeric item class, not the item type string: that string is
  -- localised, so a German client would have called every weapon unenchantable.
  it("requires an enchant on an off-hand weapon but not on a shield", function()
    local S = policy().Slots
    assert.truthy(S.isEnchantable(17, S.WEAPON_CLASS_ID))
    assert.falsy(S.isEnchantable(17, 4))
    assert.falsy(S.isEnchantable(17, nil))
  end)

  it("treats two-handers and ranged weapons as occupying the off-hand", function()
    local S = policy().Slots
    assert.truthy(S.occupiesBothHands("INVTYPE_2HWEAPON"))
    assert.truthy(S.occupiesBothHands("INVTYPE_RANGED"))
    assert.falsy(S.occupiesBothHands("INVTYPE_WEAPONMAINHAND"))
    assert.falsy(S.occupiesBothHands(nil))
  end)

  it("marks helm, bracers and waist as socketable", function()
    local S = policy().Slots
    assert.truthy(S.isSocketable(1))
    assert.truthy(S.isSocketable(9))
    assert.truthy(S.isSocketable(6))
    assert.falsy(S.isSocketable(5))
  end)

  it("knows five tier slots", function()
    assert.equals(5, table.getn(policy().Slots.TIER))
  end)
end)

describe("Policy season", function()
  it("names the current tier", function()
    assert.equals("midnight-s1", policy().Season.CURRENT_TIER)
  end)

  it("allows at most two embellishments", function()
    assert.equals(2, policy().Season.MAX_EMBELLISHMENTS)
  end)

  it("keeps the tier set IDs in one place", function()
    assert.equals("table", type(policy().Season.TIER_SET_IDS))
  end)
end)
