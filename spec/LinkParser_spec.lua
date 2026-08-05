local helper = dofile("spec/helper.lua")
local links  = dofile("spec/fixtures/links.lua")

local function parser()
  return helper.loadModules({ "LinkParser.lua" }).LinkParser
end

describe("LinkParser fixed fields", function()
  it("reads itemID, enchantID and gems from a complete link", function()
    local r = parser().parse(links.ringWithEnchantAndGem)
    assert.equals(268290, r.itemID)
    assert.equals(7967, r.enchantID)
    assert.same({ 240890, 0, 0, 0 }, r.gemIDs)
    assert.equals(1, r.gemCount)
  end)

  it("returns zero for empty fields rather than nil", function()
    local r = parser().parse(links.bareNoEnchantNoGem)
    assert.equals(249343, r.itemID)
    assert.equals(0, r.enchantID)
    assert.same({ 0, 0, 0, 0 }, r.gemIDs)
    assert.equals(0, r.gemCount)
  end)

  it("reads linkLevel, specID and itemContext", function()
    local r = parser().parse(links.ringWithEnchantAndGem)
    assert.equals(90, r.linkLevel)
    assert.equals(270, r.specID)
    assert.equals(6, r.itemContext)
  end)

  it("accepts the new cnIQ colour prefix", function()
    local r = parser().parse(links.upgradedItem)
    assert.equals(251217, r.itemID)
    assert.equals(7967, r.enchantID)
  end)

  it("accepts a bare payload without a colour prefix", function()
    local r = parser().parse(links.plainPayload)
    assert.equals(268290, r.itemID)
    assert.equals(7967, r.enchantID)
  end)

  it("survives a minimal link", function()
    local r = parser().parse(links.minimal)
    assert.equals(6948, r.itemID)
    assert.equals(0, r.enchantID)
  end)

  it("returns nil for a non-item hyperlink", function()
    assert.is_nil(parser().parse(links.notAnItem))
  end)

  it("returns nil for nil and for an empty string", function()
    assert.is_nil(parser().parse(nil))
    assert.is_nil(parser().parse(""))
  end)
end)

describe("LinkParser bonus IDs and modifiers", function()
  it("reads a length-prefixed bonus list", function()
    local r = parser().parse(links.ringWithEnchantAndGem)
    assert.same({ 6652, 13668, 13335, 13786 }, r.bonusIDs)
  end)

  it("returns empty modifiers when the count is zero", function()
    local r = parser().parse(links.ringWithEnchantAndGem)
    assert.same({}, r.modifiers)
  end)

  it("parses crafted gear with nine bonuses and ten modifier pairs", function()
    local r = parser().parse(links.craftedEmbellished)
    assert.same({ 12214, 13667, 12497, 12066, 8960, 12384, 8791, 13622, 12666 }, r.bonusIDs)
    assert.same({
      [28] = 3615, [29] = 49, [30] = 32, [38] = 8, [40] = 4006,
      [47] = 232875, [48] = 240167, [49] = 245790, [50] = -2147480301, [51] = 246212,
    }, r.modifiers)
  end)

  it("reads negative modifier values correctly", function()
    local r = parser().parse(links.craftedEmbellished)
    assert.equals(-2147480301, r.modifiers[50])
  end)

  it("is not confused by a crafter GUID behind the modifiers", function()
    local r = parser().parse(links.weaponEnchanted)
    assert.equals(8039, r.enchantID)
    assert.same({ 12214, 13655, 12497, 12066, 13640, 8960, 8790, 13622 }, r.bonusIDs)
    assert.equals(245874, r.modifiers[46])
    assert.equals(-2147480301, r.modifiers[48])
  end)

  it("handles bonuses followed by a single modifier pair", function()
    local r = parser().parse(links.heldInOffhand)
    assert.same({ 12795, 13440, 6652, 12699 }, r.bonusIDs)
    assert.same({ [28] = 1279 }, r.modifiers)
  end)

  it("returns empty tables when the link ends early", function()
    local r = parser().parse(links.minimal)
    assert.same({}, r.bonusIDs)
    assert.same({}, r.modifiers)
  end)

  -- SimC emits gem_bonus_id from a count-prefixed list that sits two fields
  -- past the end of the modifier pairs. Nothing before this reached that far
  -- into the link.
  it("returns an empty gem bonus list when the link has none", function()
    local r = parser().parse(links.ringWithEnchantAndGem)
    assert.same({}, r.gemBonusIDs)
  end)

  it("returns an empty gem bonus list on a link that ends early", function()
    local r = parser().parse(links.minimal)
    assert.same({}, r.gemBonusIDs)
  end)

  it("reads gem bonus IDs when present", function()
    -- Synthetic: no captured item carried gem bonuses. Structure follows the
    -- reference implementation -- two fields past the modifier pairs, then a
    -- count, then that many IDs.
    local link = "|cnIQ4:|Hitem:200000:0:0::::::90:270::6:1:1111:1:28:2462:0:2:7777:8888|h[Test]|h|r"
    local r = parser().parse(link)
    assert.same({ 7777, 8888 }, r.gemBonusIDs)
  end)

  it("does not expose internal fields", function()
    local r = parser().parse(links.ringWithEnchantAndGem)
    assert.is_nil(r._fields)
  end)
end)
