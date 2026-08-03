local helper = dofile("spec/helper.lua")

local function evidence()
  return helper.loadModules({ "RaidInspector/Evidence.lua" }).Evidence
end

local COMPLETE = {
  linkComplete = true, socketsKnown = true,
  tooltipComplete = true, itemLoaded = true,
}
local NO_TOOLTIP = {
  linkComplete = true, socketsKnown = true,
  tooltipComplete = false, itemLoaded = true,
}

describe("Evidence fingerprint", function()
  it("geeft hetzelfde getal voor dezelfde string", function()
    local E = evidence()
    assert.equals(E.fingerprint("item:1:2:3"), E.fingerprint("item:1:2:3"))
  end)

  it("geeft verschillende getallen voor verschillende strings", function()
    local E = evidence()
    assert.truthy(E.fingerprint("item:1:2:3") ~= E.fingerprint("item:1:2:4"))
  end)

  it("blijft onder 2^32 zodat 5.1 en 5.4 hetzelfde rekenen", function()
    local E = evidence()
    local h = E.fingerprint(string.rep("x", 500))
    assert.truthy(h >= 0 and h < 4294967296)
  end)

  it("geeft nil voor nil", function()
    assert.is_nil(evidence().fingerprint(nil))
  end)
end)

describe("Evidence bevestiging", function()
  it("bevestigt niets na één uitlezing", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, "item:1", COMPLETE, 100)
    assert.falsy(E.isConfirmed(rec, { "linkComplete" }, 10))
  end)

  it("bevestigt na twee complete uitlezingen ver genoeg uit elkaar", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, "item:1", COMPLETE, 100)
    E.record(rec, "item:1", COMPLETE, 115)
    assert.truthy(E.isConfirmed(rec, { "linkComplete" }, 10))
  end)

  it("bevestigt niet als de twee uitlezingen te snel op elkaar volgen", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, "item:1", COMPLETE, 100)
    E.record(rec, "item:1", COMPLETE, 103)
    assert.falsy(E.isConfirmed(rec, { "linkComplete" }, 10))
  end)

  -- Dit is het scenario dat het hele bewijsmodel rechtvaardigt: dezelfde link,
  -- twee keer gezien, maar de bron die de bevinding nodig heeft ontbrak beide
  -- keren. Zonder deze regel zou hier ten onrechte rood gekleurd worden.
  it("bevestigt een bron niet die twee keer ontbrak", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, "item:1", NO_TOOLTIP, 100)
    E.record(rec, "item:1", NO_TOOLTIP, 115)
    assert.truthy(E.isConfirmed(rec, { "linkComplete" }, 10))
    assert.falsy(E.isConfirmed(rec, { "tooltipComplete" }, 10))
  end)

  it("eist dat elke gevraagde bron bevestigd is", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, "item:1", NO_TOOLTIP, 100)
    E.record(rec, "item:1", NO_TOOLTIP, 115)
    assert.falsy(E.isConfirmed(rec, { "linkComplete", "tooltipComplete" }, 10))
  end)

  it("zet alle tellers terug als de fingerprint verandert", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, "item:1", COMPLETE, 100)
    E.record(rec, "item:1", COMPLETE, 115)
    assert.truthy(E.isConfirmed(rec, { "linkComplete" }, 10))
    E.record(rec, "item:2", COMPLETE, 130)
    assert.falsy(E.isConfirmed(rec, { "linkComplete" }, 10))
  end)
end)
