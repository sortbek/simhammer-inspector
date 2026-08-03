local helper = dofile("spec/helper.lua")
local links  = dofile("spec/fixtures/links.lua")

local function parser()
  return helper.loadModules({ "RaidInspector/LinkParser.lua" }).LinkParser
end

describe("LinkParser vaste velden", function()
  it("leest itemID, enchantID en gems uit een volledige link", function()
    local r = parser().parse(links.ringWithEnchantAndGem)
    assert.equals(268290, r.itemID)
    assert.equals(7967, r.enchantID)
    assert.same({ 240890, 0, 0, 0 }, r.gemIDs)
    assert.equals(1, r.gemCount)
  end)

  it("geeft nul terug voor lege velden in plaats van nil", function()
    local r = parser().parse(links.bareNoEnchantNoGem)
    assert.equals(249343, r.itemID)
    assert.equals(0, r.enchantID)
    assert.same({ 0, 0, 0, 0 }, r.gemIDs)
    assert.equals(0, r.gemCount)
  end)

  it("leest linkLevel, specID en itemContext", function()
    local r = parser().parse(links.ringWithEnchantAndGem)
    assert.equals(90, r.linkLevel)
    assert.equals(270, r.specID)
    assert.equals(6, r.itemContext)
  end)

  it("accepteert het nieuwe cnIQ-kleurvoorvoegsel", function()
    local r = parser().parse(links.upgradedItem)
    assert.equals(251217, r.itemID)
    assert.equals(7967, r.enchantID)
  end)

  it("accepteert een kale payload zonder kleurcode", function()
    local r = parser().parse(links.plainPayload)
    assert.equals(268290, r.itemID)
    assert.equals(7967, r.enchantID)
  end)

  it("verwerkt een minimale link zonder te crashen", function()
    local r = parser().parse(links.minimal)
    assert.equals(6948, r.itemID)
    assert.equals(0, r.enchantID)
  end)

  it("geeft nil voor een niet-item hyperlink", function()
    assert.is_nil(parser().parse(links.notAnItem))
  end)

  it("geeft nil voor nil en voor een lege string", function()
    assert.is_nil(parser().parse(nil))
    assert.is_nil(parser().parse(""))
  end)
end)

describe("LinkParser bonus-IDs en modifiers", function()
  it("leest een lengte-geprefixte bonuslijst", function()
    local r = parser().parse(links.ringWithEnchantAndGem)
    assert.same({ 6652, 13668, 13335, 13786 }, r.bonusIDs)
  end)

  it("geeft lege modifiers als het aantal nul is", function()
    local r = parser().parse(links.ringWithEnchantAndGem)
    assert.same({}, r.modifiers)
  end)

  it("parseert crafted gear met negen bonussen en tien modifier-paren", function()
    local r = parser().parse(links.craftedEmbellished)
    assert.same({ 12214, 13667, 12497, 12066, 8960, 12384, 8791, 13622, 12666 }, r.bonusIDs)
    assert.same({
      [28] = 3615, [29] = 49, [30] = 32, [38] = 8, [40] = 4006,
      [47] = 232875, [48] = 240167, [49] = 245790, [50] = -2147480301, [51] = 246212,
    }, r.modifiers)
  end)

  it("leest negatieve modifier-waarden correct", function()
    local r = parser().parse(links.craftedEmbellished)
    assert.equals(-2147480301, r.modifiers[50])
  end)

  it("laat zich niet in de war brengen door een crafter-GUID achter de modifiers", function()
    local r = parser().parse(links.weaponEnchanted)
    assert.equals(8039, r.enchantID)
    assert.same({ 12214, 13655, 12497, 12066, 13640, 8960, 8790, 13622 }, r.bonusIDs)
    assert.equals(245874, r.modifiers[46])
    assert.equals(-2147480301, r.modifiers[48])
  end)

  it("gaat om met bonussen gevolgd door één modifier-paar", function()
    local r = parser().parse(links.heldInOffhand)
    assert.same({ 12795, 13440, 6652, 12699 }, r.bonusIDs)
    assert.same({ [28] = 1279 }, r.modifiers)
  end)

  it("geeft lege tabellen als de link vroegtijdig eindigt", function()
    local r = parser().parse(links.minimal)
    assert.same({}, r.bonusIDs)
    assert.same({}, r.modifiers)
  end)

  it("legt geen interne velden bloot", function()
    local r = parser().parse(links.ringWithEnchantAndGem)
    assert.is_nil(r._fields)
  end)
end)
