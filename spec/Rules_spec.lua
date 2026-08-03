local helper = dofile("spec/helper.lua")

local MODULES = {
  "RaidInspector/Policy/Slots.lua",
  "RaidInspector/Policy/Season.lua",
  "RaidInspector/Data/Enchants.lua",
  "RaidInspector/Data/Gems.lua",
  "RaidInspector/Data/Embellishments.lua",
  "RaidInspector/Evidence.lua",
  "RaidInspector/Rules.lua",
}

local function fresh()
  return helper.loadModules(MODULES)
end

local COMPLETE = {
  linkComplete = true, socketsKnown = true,
  tooltipComplete = true, itemLoaded = true,
}

-- Bouwt een slotRecord dat twee complete uitlezingen ver genoeg uit elkaar
-- heeft, zodat negatieve bevindingen bevestigd mogen worden.
local function confirmedRecord(ns, link)
  local rec = ns.Evidence.newSlotRecord()
  ns.Evidence.record(rec, link, COMPLETE, 100)
  ns.Evidence.record(rec, link, COMPLETE, 120)
  return rec
end

local function findingOfKind(findings, kind)
  for i = 1, table.getn(findings) do
    if findings[i].kind == kind then return findings[i] end
  end
  return nil
end

local CONTEXT = { minInterval = 10, dataValid = true }

describe("Rules enchants", function()
  it("meldt niets als er een actuele gold-enchant op zit", function()
    local ns = fresh()
    local parsed = { itemID = 1, enchantID = 7364, gemIDs = {0,0,0,0}, gemCount = 0,
                     bonusIDs = {}, modifiers = {} }
    local findings = ns.Rules.evaluateSlot(1, parsed, confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "missing_enchant"))
    assert.is_nil(findingOfKind(findings, "low_enchant"))
  end)

  it("meldt een ontbrekende enchant op een enchantbaar slot", function()
    local ns = fresh()
    local parsed = { itemID = 1, enchantID = 0, gemIDs = {0,0,0,0}, gemCount = 0,
                     bonusIDs = {}, modifiers = {} }
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, parsed, confirmedRecord(ns, "a"), CONTEXT),
      "missing_enchant")
    assert.equals("error", f.severity)
    assert.equals("bad", f.state)
  end)

  it("meldt geen ontbrekende enchant op een niet-enchantbaar slot", function()
    local ns = fresh()
    local parsed = { itemID = 1, enchantID = 0, gemIDs = {0,0,0,0}, gemCount = 0,
                     bonusIDs = {}, modifiers = {} }
    local findings = ns.Rules.evaluateSlot(15, parsed, confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "missing_enchant"))
  end)

  it("markeert een ontbrekende enchant als onbekend zonder bevestiging", function()
    local ns = fresh()
    local rec = ns.Evidence.newSlotRecord()
    ns.Evidence.record(rec, "a", COMPLETE, 100)
    local parsed = { itemID = 1, enchantID = 0, gemIDs = {0,0,0,0}, gemCount = 0,
                     bonusIDs = {}, modifiers = {} }
    local f = findingOfKind(ns.Rules.evaluateSlot(1, parsed, rec, CONTEXT), "missing_enchant")
    assert.equals("unknown", f.state)
  end)

  it("meldt een silver-enchant als waarschuwing", function()
    local ns = fresh()
    local parsed = { itemID = 1, enchantID = 7361, gemIDs = {0,0,0,0}, gemCount = 0,
                     bonusIDs = {}, modifiers = {} }
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, parsed, confirmedRecord(ns, "a"), CONTEXT), "low_enchant")
    assert.equals("warn", f.severity)
  end)

  it("meldt een enchant uit een vorig seizoen als verouderd, niet als onbekend", function()
    local ns = fresh()
    local parsed = { itemID = 1, enchantID = 6625, gemIDs = {0,0,0,0}, gemCount = 0,
                     bonusIDs = {}, modifiers = {} }
    local findings = ns.Rules.evaluateSlot(1, parsed, confirmedRecord(ns, "a"), CONTEXT)
    local f = findingOfKind(findings, "outdated_enchant")
    assert.equals("warn", f.severity)
    assert.equals("bad", f.state)
  end)

  it("markeert een onbekende enchant-ID als onbekend", function()
    local ns = fresh()
    local parsed = { itemID = 1, enchantID = 999999, gemIDs = {0,0,0,0}, gemCount = 0,
                     bonusIDs = {}, modifiers = {} }
    local findings = ns.Rules.evaluateSlot(1, parsed, confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "outdated_enchant"))
    assert.is_nil(findingOfKind(findings, "low_enchant"))
  end)

  it("degradeert alles naar onbekend als de data ongeldig is", function()
    local ns = fresh()
    local parsed = { itemID = 1, enchantID = 7361, gemIDs = {0,0,0,0}, gemCount = 0,
                     bonusIDs = {}, modifiers = {} }
    local findings = ns.Rules.evaluateSlot(1, parsed, confirmedRecord(ns, "a"),
                                           { minInterval = 10, dataValid = false })
    local f = findingOfKind(findings, "low_enchant")
    assert.is_nil(f)
  end)
end)

describe("Rules gems", function()
  it("meldt een silver-gem als waarschuwing", function()
    local ns = fresh()
    local parsed = { itemID = 1, enchantID = 7364, gemIDs = {213740,0,0,0}, gemCount = 1,
                     bonusIDs = {}, modifiers = {} }
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, parsed, confirmedRecord(ns, "a"), CONTEXT), "low_gem")
    assert.equals("warn", f.severity)
  end)

  it("meldt een gem uit een vorig seizoen als verouderd", function()
    local ns = fresh()
    local parsed = { itemID = 1, enchantID = 7364, gemIDs = {213470,0,0,0}, gemCount = 1,
                     bonusIDs = {}, modifiers = {} }
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, parsed, confirmedRecord(ns, "a"), CONTEXT), "outdated_gem")
    assert.equals("warn", f.severity)
  end)
end)

describe("Rules leeg slot", function()
  it("meldt een leeg gear-slot als fout", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, nil, confirmedRecord(ns, "a"), CONTEXT), "missing_item")
    assert.equals("error", f.severity)
  end)

  it("meldt een lege off-hand niet als er een tweehander is", function()
    local ns = fresh()
    local ctx = { minInterval = 10, dataValid = true, twoHanded = true }
    local findings = ns.Rules.evaluateSlot(17, nil, confirmedRecord(ns, "a"), ctx)
    assert.is_nil(findingOfKind(findings, "missing_item"))
  end)
end)

describe("Rules speler-brede checks", function()
  local function slotEntry(ns, opts)
    local rec = ns.Evidence.newSlotRecord()
    ns.Evidence.record(rec, opts.link or "a", COMPLETE, 100)
    ns.Evidence.record(rec, opts.link or "a", COMPLETE, 120)
    return {
      parsed = opts.parsed or { itemID = 1, enchantID = 7364, gemIDs = {0,0,0,0},
                                gemCount = 0, bonusIDs = opts.bonusIDs or {}, modifiers = {} },
      record = rec,
      setID  = opts.setID,
    }
  end

  local function withTierSet(ns, count)
    ns.Policy.Season.TIER_SET_IDS = { [4242] = true }
    local slots = {}
    local tierSlots = ns.Policy.Slots.TIER
    for i = 1, table.getn(tierSlots) do
      slots[tierSlots[i]] = slotEntry(ns, { setID = (i <= count) and 4242 or nil,
                                            link = "tier" .. i })
    end
    return slots
  end

  it("meldt niets bij vijf van de vijf tierstukken", function()
    local ns = fresh()
    local findings = ns.Rules.evaluatePlayer(withTierSet(ns, 5), CONTEXT)
    assert.is_nil(findingOfKind(findings, "tier_incomplete"))
  end)

  it("meldt drie van de vijf tierstukken als waarschuwing", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluatePlayer(withTierSet(ns, 3), CONTEXT), "tier_incomplete")
    assert.equals("warn", f.severity)
    assert.matches("3", f.detail)
  end)

  it("meldt tier niet als de setIDs nog niet ingevuld zijn", function()
    local ns = fresh()
    ns.Policy.Season.TIER_SET_IDS = {}
    local slots = {}
    local tierSlots = ns.Policy.Slots.TIER
    for i = 1, table.getn(tierSlots) do
      slots[tierSlots[i]] = slotEntry(ns, { link = "x" .. i })
    end
    assert.is_nil(findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT), "tier_incomplete"))
  end)

  it("meldt nul embellishments als waarschuwing", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluatePlayer({ [5] = slotEntry(ns, {}) }, CONTEXT),
      "embellishments_missing")
    assert.equals("warn", f.severity)
  end)

  it("meldt niets bij twee embellishments", function()
    local ns = fresh()
    local slots = {
      [5]  = slotEntry(ns, { bonusIDs = { 11144 }, link = "c1" }),
      [10] = slotEntry(ns, { bonusIDs = { 11145 }, link = "c2" }),
    }
    assert.is_nil(findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT),
                                "embellishments_missing"))
  end)

  it("meldt geen embellishments als de data ongeldig is", function()
    local ns = fresh()
    local findings = ns.Rules.evaluatePlayer({ [5] = slotEntry(ns, {}) },
                                             { minInterval = 10, dataValid = false })
    assert.is_nil(findingOfKind(findings, "embellishments_missing"))
  end)

  it("bundelt de bevindingen per slot in het spelerresultaat", function()
    local ns = fresh()
    local slots = {
      [1] = slotEntry(ns, { parsed = { itemID = 1, enchantID = 0, gemIDs = {0,0,0,0},
                                       gemCount = 0, bonusIDs = {}, modifiers = {} } }),
    }
    local f = findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT), "missing_enchant")
    assert.equals(1, f.slot)
  end)
end)
