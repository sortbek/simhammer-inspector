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

-- Builds a slot record with two complete reads far enough apart that negative
-- findings are allowed to be confirmed.
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

local function parsed(enchantID, gems, gemCount, bonusIDs)
  return {
    itemID = 1, enchantID = enchantID,
    gemIDs = gems or { 0, 0, 0, 0 }, gemCount = gemCount or 0,
    bonusIDs = bonusIDs or {}, modifiers = {},
  }
end

describe("Rules enchants", function()
  it("reports nothing when a current gold enchant is present", function()
    local ns = fresh()
    local findings = ns.Rules.evaluateSlot(1, parsed(7364), confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "missing_enchant"))
    assert.is_nil(findingOfKind(findings, "low_enchant"))
  end)

  it("reports a missing enchant on an enchantable slot", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, parsed(0), confirmedRecord(ns, "a"), CONTEXT),
      "missing_enchant")
    assert.equals("error", f.severity)
    assert.equals("bad", f.state)
  end)

  it("reports no missing enchant on a non-enchantable slot", function()
    local ns = fresh()
    local findings = ns.Rules.evaluateSlot(15, parsed(0), confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "missing_enchant"))
  end)

  it("marks a missing enchant as unknown without confirmation", function()
    local ns = fresh()
    local rec = ns.Evidence.newSlotRecord()
    ns.Evidence.record(rec, "a", COMPLETE, 100)
    local f = findingOfKind(ns.Rules.evaluateSlot(1, parsed(0), rec, CONTEXT), "missing_enchant")
    assert.equals("unknown", f.state)
  end)

  it("reports a silver enchant as a warning", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, parsed(7361), confirmedRecord(ns, "a"), CONTEXT), "low_enchant")
    assert.equals("warn", f.severity)
  end)

  it("reports an enchant from a previous season as outdated, not unknown", function()
    local ns = fresh()
    local findings = ns.Rules.evaluateSlot(1, parsed(6625), confirmedRecord(ns, "a"), CONTEXT)
    local f = findingOfKind(findings, "outdated_enchant")
    assert.equals("warn", f.severity)
    assert.equals("bad", f.state)
  end)

  it("marks an unrecognised enchant ID as unknown", function()
    local ns = fresh()
    local findings = ns.Rules.evaluateSlot(1, parsed(999999), confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "outdated_enchant"))
    assert.is_nil(findingOfKind(findings, "low_enchant"))
  end)

  it("degrades to unknown when the data is invalid", function()
    local ns = fresh()
    local findings = ns.Rules.evaluateSlot(1, parsed(7361), confirmedRecord(ns, "a"),
                                           { minInterval = 10, dataValid = false })
    assert.is_nil(findingOfKind(findings, "low_enchant"))
  end)
end)

describe("Rules gems", function()
  it("reports a silver gem as a warning", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, parsed(7364, { 213740, 0, 0, 0 }, 1),
                            confirmedRecord(ns, "a"), CONTEXT), "low_gem")
    assert.equals("warn", f.severity)
  end)

  it("reports a gem from a previous season as outdated", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, parsed(7364, { 213470, 0, 0, 0 }, 1),
                            confirmedRecord(ns, "a"), CONTEXT), "outdated_gem")
    assert.equals("warn", f.severity)
  end)
end)

describe("Rules empty slot", function()
  it("reports an empty gear slot as an error", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, nil, confirmedRecord(ns, "a"), CONTEXT), "missing_item")
    assert.equals("error", f.severity)
  end)

  it("does not report an empty off-hand when a two-hander is equipped", function()
    local ns = fresh()
    local ctx = { minInterval = 10, dataValid = true, twoHanded = true }
    local findings = ns.Rules.evaluateSlot(17, nil, confirmedRecord(ns, "a"), ctx)
    assert.is_nil(findingOfKind(findings, "missing_item"))
  end)
end)

describe("Rules player-wide checks", function()
  local function slotEntry(ns, opts)
    local rec = ns.Evidence.newSlotRecord()
    ns.Evidence.record(rec, opts.link or "a", COMPLETE, 100)
    ns.Evidence.record(rec, opts.link or "a", COMPLETE, 120)
    return {
      parsed = opts.parsed or parsed(7364, nil, 0, opts.bonusIDs),
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

  it("reports nothing at five of five tier pieces", function()
    local ns = fresh()
    local findings = ns.Rules.evaluatePlayer(withTierSet(ns, 5), CONTEXT)
    assert.is_nil(findingOfKind(findings, "tier_incomplete"))
  end)

  it("reports three of five tier pieces as a warning", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluatePlayer(withTierSet(ns, 3), CONTEXT), "tier_incomplete")
    assert.equals("warn", f.severity)
    assert.matches("3", f.detail)
  end)

  it("reports no tier finding while the set IDs are unset", function()
    local ns = fresh()
    ns.Policy.Season.TIER_SET_IDS = {}
    local slots = {}
    local tierSlots = ns.Policy.Slots.TIER
    for i = 1, table.getn(tierSlots) do
      slots[tierSlots[i]] = slotEntry(ns, { link = "x" .. i })
    end
    assert.is_nil(findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT), "tier_incomplete"))
  end)

  it("reports zero embellishments as a warning", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluatePlayer({ [5] = slotEntry(ns, {}) }, CONTEXT),
      "embellishments_missing")
    assert.equals("warn", f.severity)
  end)

  it("reports nothing at two embellishments", function()
    local ns = fresh()
    local slots = {
      [5]  = slotEntry(ns, { bonusIDs = { 11144 }, link = "c1" }),
      [10] = slotEntry(ns, { bonusIDs = { 11145 }, link = "c2" }),
    }
    assert.is_nil(findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT),
                                "embellishments_missing"))
  end)

  it("reports no embellishment finding when the data is invalid", function()
    local ns = fresh()
    local findings = ns.Rules.evaluatePlayer({ [5] = slotEntry(ns, {}) },
                                             { minInterval = 10, dataValid = false })
    assert.is_nil(findingOfKind(findings, "embellishments_missing"))
  end)

  it("carries the slot number through into the player result", function()
    local ns = fresh()
    local slots = { [1] = slotEntry(ns, { parsed = parsed(0) }) }
    local f = findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT), "missing_enchant")
    assert.equals(1, f.slot)
  end)
end)
