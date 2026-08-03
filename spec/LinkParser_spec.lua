local helper = dofile("spec/helper.lua")
local links  = dofile("spec/fixtures/links.lua")

local function parser()
  return helper.loadModules({ "RaidInspector/LinkParser.lua" }).LinkParser
end

describe("LinkParser vaste velden", function()
  it("leest itemID, enchantID en gems uit een volledige link", function()
    local r = parser().parse(links.ringWithEnchantAndGem)
    assert.equals(211018, r.itemID)
    assert.equals(7364, r.enchantID)
    assert.same({ 213743, 0, 0, 0 }, r.gemIDs)
    assert.equals(1, r.gemCount)
  end)

  it("geeft nul terug voor lege velden in plaats van nil", function()
    local r = parser().parse(links.chestBare)
    assert.equals(212446, r.itemID)
    assert.equals(0, r.enchantID)
    assert.same({ 0, 0, 0, 0 }, r.gemIDs)
    assert.equals(0, r.gemCount)
  end)

  it("leest linkLevel, specID en itemContext", function()
    local r = parser().parse(links.ringWithEnchantAndGem)
    assert.equals(80, r.linkLevel)
    assert.equals(268, r.specID)
    assert.equals(6, r.itemContext)
  end)

  it("accepteert een kale payload zonder kleurcode", function()
    local r = parser().parse(links.plainPayload)
    assert.equals(211018, r.itemID)
    assert.equals(7364, r.enchantID)
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
