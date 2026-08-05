local helper = dofile("spec/helper.lua")

local MODULES = {
  "SimhammerInspector/Policy/Slots.lua",
  "SimhammerInspector/Policy/Season.lua",
  "SimhammerInspector/Data/Enchants.lua",
  "SimhammerInspector/Data/Gems.lua",
  "SimhammerInspector/Evidence.lua",
  "SimhammerInspector/Rules.lua",
}

-- The generated Data tables hold thousands of real entries. Testing the rules
-- against them would mean testing production data instead of the cases these
-- tests mean to cover, and every regeneration would break assertions. So the
-- rules tests inject their own small tables after loading.
local TEST_ENCHANTS = {
  [7364] = { quality = "gold",   tier = "midnight-s1" },
  [7361] = { quality = "silver", tier = "midnight-s1" },
  [6625] = { quality = "gold",   tier = "legacy" },
  [2841] = { quality = nil,      tier = "legacy" },
}

local TEST_GEMS = {
  [213743] = { quality = "gold",   tier = "midnight-s1" },
  [213740] = { quality = "silver", tier = "midnight-s1" },
  [213470] = { quality = "gold",   tier = "legacy" },
}

local function fresh()
  local ns = helper.loadModules(MODULES)
  ns.Data.Enchants = TEST_ENCHANTS
  ns.Data.Gems = TEST_GEMS
  return ns
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

-- Builds the item record evaluateSlot expects. Without this wrapper every test
-- would have to assemble a table that has nothing to do with the test.
local function item(parsedItem, extra)
  local it = { parsed = parsedItem }
  if extra then
    it.socketCount = extra.socketCount
    it.upgrade     = extra.upgrade
    it.setID       = extra.setID
  end
  return it
end

describe("Rules enchants", function()
  it("reports nothing when a current gold enchant is present", function()
    local ns = fresh()
    local findings = ns.Rules.evaluateSlot(1, item(parsed(7364)),
                                           confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "missing_enchant"))
    assert.is_nil(findingOfKind(findings, "low_enchant"))
  end)

  it("reports a missing enchant on an enchantable slot", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, item(parsed(0)), confirmedRecord(ns, "a"), CONTEXT),
      "missing_enchant")
    assert.equals("error", f.severity)
    assert.equals("bad", f.state)
  end)

  it("reports no missing enchant on a non-enchantable slot", function()
    local ns = fresh()
    local findings = ns.Rules.evaluateSlot(15, item(parsed(0)),
                                           confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "missing_enchant"))
  end)

  it("marks a missing enchant as unknown without confirmation", function()
    local ns = fresh()
    local rec = ns.Evidence.newSlotRecord()
    ns.Evidence.record(rec, "a", COMPLETE, 100)
    local f = findingOfKind(ns.Rules.evaluateSlot(1, item(parsed(0)), rec, CONTEXT),
                            "missing_enchant")
    assert.equals("unknown", f.state)
  end)

  it("reports a silver enchant as a warning", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, item(parsed(7361)), confirmedRecord(ns, "a"), CONTEXT),
      "low_enchant")
    assert.equals("warn", f.severity)
  end)

  it("reports an enchant from a previous season as outdated, not unknown", function()
    local ns = fresh()
    local findings = ns.Rules.evaluateSlot(1, item(parsed(6625)),
                                           confirmedRecord(ns, "a"), CONTEXT)
    local f = findingOfKind(findings, "outdated_enchant")
    assert.equals("warn", f.severity)
    assert.equals("bad", f.state)
  end)

  -- Caught in a live raid: four players were told their weapon enchant was
  -- outdated. Death knight runeforges, engineering tinkers and pre-quality
  -- enchants all carry no crafting tier, and a runeforged weapon is correctly
  -- enchanted. An enchant that cannot be ranked must not be judged.
  it("says nothing about a known enchant that has no crafting quality", function()
    local ns = fresh()
    local findings = ns.Rules.evaluateSlot(16, item(parsed(2841)),
                                           confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "outdated_enchant"))
    assert.is_nil(findingOfKind(findings, "low_enchant"))
    assert.is_nil(findingOfKind(findings, "missing_enchant"))
  end)

  it("marks an unrecognised enchant ID as unknown", function()
    local ns = fresh()
    local findings = ns.Rules.evaluateSlot(1, item(parsed(999999)),
                                           confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "outdated_enchant"))
    assert.is_nil(findingOfKind(findings, "low_enchant"))
  end)

  -- Not silence. A check that returns no finding renders as a green cell, which
  -- claims the enchant was verified against tables we know are out of date.
  it("degrades to unknown when the data is invalid", function()
    local ns = fresh()
    local findings = ns.Rules.evaluateSlot(1, item(parsed(7361)), confirmedRecord(ns, "a"),
                                           { minInterval = 10, dataValid = false })
    assert.is_nil(findingOfKind(findings, "low_enchant"))
    assert.equals("unknown", findingOfKind(findings, "enchant_unverified").state)
  end)

  -- A missing enchant needs no data table to see, so stale tables must not
  -- suppress the one enchant finding that is still trustworthy.
  it("still reports a missing enchant when the data is invalid", function()
    local ns = fresh()
    local findings = ns.Rules.evaluateSlot(1, item(parsed(0)), confirmedRecord(ns, "a"),
                                           { minInterval = 10, dataValid = false })
    assert.equals("bad", findingOfKind(findings, "missing_enchant").state)
  end)
end)

describe("Rules gems", function()
  it("reports a silver gem as a warning", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, item(parsed(7364, { 213740, 0, 0, 0 }, 1)),
                            confirmedRecord(ns, "a"), CONTEXT), "low_gem")
    assert.equals("warn", f.severity)
  end)

  it("reports a gem from a previous season as outdated", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, item(parsed(7364, { 213470, 0, 0, 0 }, 1)),
                            confirmedRecord(ns, "a"), CONTEXT), "outdated_gem")
    assert.equals("warn", f.severity)
  end)
end)

describe("Rules upgrade track", function()
  it("reports nothing on a fully upgraded item", function()
    local ns = fresh()
    local it = item(parsed(7364), { upgrade = { track = "Myth", rank = 6, max = 6 } })
    local findings = ns.Rules.evaluateSlot(1, it, confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "upgrades_left"))
  end)

  it("reports remaining upgrades as a warning", function()
    local ns = fresh()
    local it = item(parsed(7364), { upgrade = { track = "Hero", rank = 3, max = 6 } })
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, it, confirmedRecord(ns, "a"), CONTEXT), "upgrades_left")
    assert.equals("warn", f.severity)
    assert.equals("bad", f.state)
    assert.matches("3/6", f.detail)
    assert.matches("Hero", f.detail)
  end)

  -- The case the spike surfaced: 78 of 184 items had no upgrade line. Those must
  -- not count as fully upgraded.
  it("reports nothing when the track is unknown", function()
    local ns = fresh()
    local findings = ns.Rules.evaluateSlot(1, item(parsed(7364)),
                                           confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "upgrades_left"))
  end)

  it("uses the denominator from the tooltip rather than a hardcoded six", function()
    local ns = fresh()
    local it = item(parsed(7364), { upgrade = { track = "Explorer", rank = 2, max = 8 } })
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, it, confirmedRecord(ns, "a"), CONTEXT), "upgrades_left")
    assert.matches("2/8", f.detail)
  end)

  it("requires confirmed tooltip evidence before turning bad", function()
    local ns = fresh()
    local rec = ns.Evidence.newSlotRecord()
    ns.Evidence.record(rec, "a", { linkComplete = true, tooltipComplete = false }, 100)
    ns.Evidence.record(rec, "a", { linkComplete = true, tooltipComplete = false }, 120)
    local it = item(parsed(7364), { upgrade = { track = "Hero", rank = 3, max = 6 } })
    local f = findingOfKind(ns.Rules.evaluateSlot(1, it, rec, CONTEXT), "upgrades_left")
    assert.equals("unknown", f.state)
  end)
end)

describe("Rules sockets", function()
  it("reports nothing when every socket is filled", function()
    local ns = fresh()
    local it = item(parsed(7364, { 213743, 0, 0, 0 }, 1), { socketCount = 1 })
    local findings = ns.Rules.evaluateSlot(5, it, confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "empty_socket"))
  end)

  it("reports an empty socket as an error", function()
    local ns = fresh()
    local it = item(parsed(7364), { socketCount = 1 })
    local f = findingOfKind(
      ns.Rules.evaluateSlot(5, it, confirmedRecord(ns, "a"), CONTEXT), "empty_socket")
    assert.equals("error", f.severity)
    assert.equals("bad", f.state)
    assert.matches("1", f.detail)
  end)

  it("counts multiple empty sockets", function()
    local ns = fresh()
    local it = item(parsed(7364, { 213743, 0, 0, 0 }, 1), { socketCount = 3 })
    local f = findingOfKind(
      ns.Rules.evaluateSlot(5, it, confirmedRecord(ns, "a"), CONTEXT), "empty_socket")
    assert.matches("2", f.detail)
  end)

  it("stays silent while the socket count is unknown", function()
    local ns = fresh()
    local it = item(parsed(7364), { socketCount = nil })
    local findings = ns.Rules.evaluateSlot(5, it, confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "empty_socket"))
  end)

  it("requires confirmed socket evidence before turning bad", function()
    local ns = fresh()
    local rec = ns.Evidence.newSlotRecord()
    ns.Evidence.record(rec, "a", { linkComplete = true, socketsKnown = false }, 100)
    ns.Evidence.record(rec, "a", { linkComplete = true, socketsKnown = false }, 120)
    local it = item(parsed(7364), { socketCount = 1 })
    local f = findingOfKind(ns.Rules.evaluateSlot(5, it, rec, CONTEXT), "empty_socket")
    assert.equals("unknown", f.state)
  end)

  it("reports a socketable slot without a socket as a warning", function()
    local ns = fresh()
    local it = item(parsed(7364), { socketCount = 0 })
    local f = findingOfKind(
      ns.Rules.evaluateSlot(9, it, confirmedRecord(ns, "a"), CONTEXT), "missing_socket")
    assert.equals("warn", f.severity)
  end)

  it("reports no missing socket on a slot that cannot take one", function()
    local ns = fresh()
    local it = item(parsed(7364), { socketCount = 0 })
    local findings = ns.Rules.evaluateSlot(5, it, confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "missing_socket"))
  end)

  it("reports no missing socket when a socket is already present", function()
    local ns = fresh()
    local it = item(parsed(7364, { 213743, 0, 0, 0 }, 1), { socketCount = 1 })
    local findings = ns.Rules.evaluateSlot(9, it, confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "missing_socket"))
  end)
end)

-- Two inspects that both came back with no link for this slot. This is the
-- evidence an empty slot produces; there is no item to read, so none of the
-- other sources can ever arrive for it.
local function absentRecord(ns)
  local rec = ns.Evidence.newSlotRecord()
  ns.Evidence.record(rec, nil, { absent = true }, 100)
  ns.Evidence.record(rec, nil, { absent = true }, 120)
  return rec
end

describe("Rules empty slot", function()
  it("reports an empty gear slot as an error", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, nil, absentRecord(ns), CONTEXT), "missing_item")
    assert.equals("error", f.severity)
    assert.equals("bad", f.state)
  end)

  -- The whole point of the absence source: one read is not enough to accuse
  -- someone of a naked slot, exactly as with every other negative finding.
  it("holds an empty slot at unknown after a single read", function()
    local ns = fresh()
    local rec = ns.Evidence.newSlotRecord()
    ns.Evidence.record(rec, nil, { absent = true }, 100)
    local f = findingOfKind(ns.Rules.evaluateSlot(1, nil, rec, CONTEXT), "missing_item")
    assert.equals("unknown", f.state)
  end)

  -- The property that makes the scanner's completeness threshold safe to set
  -- high: a slot the scanner declined to record an absence for still produces
  -- the finding, held at unknown. Suppressing the evidence delays the verdict,
  -- it never manufactures a pass. Nobody in a raid should have an empty slot, so
  -- an empty one going quietly green would be the worst outcome available.
  it("shows an empty slot as unknown rather than clean when no pass confirmed it", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, nil, ns.Evidence.newSlotRecord(), CONTEXT), "missing_item")
    assert.truthy(f)
    assert.equals("unknown", f.state)
  end)

  -- Regression: this finding was unreachable for the whole of its existence.
  -- Consumers build the slot table from the harvest record, which only held
  -- slots that returned a link, so an empty slot was not a finding -- it was a
  -- player with fifteen slots.
  it("reports an empty slot through the player-wide pass", function()
    local ns = fresh()
    local slots = { [13] = { record = absentRecord(ns) } }
    local f = findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT), "missing_item")
    assert.equals(13, f.slot)
    assert.equals("bad", f.state)
  end)

  it("does not report an empty off-hand when a two-hander is equipped", function()
    local ns = fresh()
    local slots = {
      [16] = { parsed = parsed(7364), record = confirmedRecord(ns, "mh"),
               equipLoc = "INVTYPE_2HWEAPON" },
      [17] = { record = absentRecord(ns) },
    }
    assert.is_nil(findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT), "missing_item"))
  end)

  -- Neither accusing nor excusing. Without the main hand's equip location a
  -- greatsword and a one-hander look the same, and both guesses are wrong for
  -- half the raid.
  it("holds an empty off-hand at unknown while the main hand's type is unread", function()
    local ns = fresh()
    local slots = {
      [16] = { parsed = parsed(7364), record = confirmedRecord(ns, "mh") },
      [17] = { record = absentRecord(ns) },
    }
    local f = findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT), "missing_item")
    assert.equals("unknown", f.state)
  end)

  it("still reports an empty off-hand beside a one-handed weapon", function()
    local ns = fresh()
    local slots = {
      [16] = { parsed = parsed(7364), record = confirmedRecord(ns, "mh"),
               equipLoc = "INVTYPE_WEAPONMAINHAND" },
      [17] = { record = absentRecord(ns) },
    }
    local f = findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT), "missing_item")
    assert.equals(17, f.slot)
  end)
end)

describe("Rules off-hand enchant", function()
  -- Regression: this check read context.itemSubclass, which nothing ever set,
  -- so isEnchantable(17, nil) was always false and an off-hand weapon was never
  -- checked for an enchant at all.
  it("reports a missing enchant on an off-hand weapon", function()
    local ns = fresh()
    local it = item(parsed(0))
    it.classID = ns.Policy.Slots.WEAPON_CLASS_ID
    local f = findingOfKind(
      ns.Rules.evaluateSlot(17, it, confirmedRecord(ns, "a"), CONTEXT), "missing_enchant")
    assert.equals("error", f.severity)
  end)

  it("reports nothing on an off-hand shield", function()
    local ns = fresh()
    local it = item(parsed(0))
    it.classID = 4
    local findings = ns.Rules.evaluateSlot(17, it, confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "missing_enchant"))
  end)
end)

describe("Rules player-wide checks", function()
  local function slotEntry(ns, opts)
    local rec = ns.Evidence.newSlotRecord()
    ns.Evidence.record(rec, opts.link or "a", COMPLETE, 100)
    ns.Evidence.record(rec, opts.link or "a", COMPLETE, 120)
    return {
      parsed      = opts.parsed or parsed(7364, nil, 0, opts.bonusIDs),
      record      = rec,
      setID       = opts.setID,
      socketCount = opts.socketCount,
      upgrade     = opts.upgrade,
      embellished = opts.embellished,
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

  -- Four is the set bonus that decides the sim; the fifth piece is a stat gain,
  -- not a raid-readiness question. Counting against five put a yellow warning on
  -- correctly geared raiders, with nothing anywhere in the grid to explain it.
  it("reports nothing at four of five tier pieces", function()
    local ns = fresh()
    assert.is_nil(findingOfKind(
      ns.Rules.evaluatePlayer(withTierSet(ns, 4), CONTEXT), "tier_incomplete"))
  end)

  it("counts tier against the four that are required, not the five that exist", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluatePlayer(withTierSet(ns, 3), CONTEXT), "tier_incomplete")
    assert.equals("warn", f.severity)
    assert.matches("3 of 4", f.detail)
  end)

  -- The grid column needs the count as numbers rather than as a sentence, and
  -- asking the same question in a second place is how a column and a warning end
  -- up disagreeing about the same player.
  it("hands the tier count to the grid", function()
    local ns = fresh()
    local tier = ns.Rules.tierStatus(withTierSet(ns, 3), CONTEXT)
    assert.equals(3, tier.worn)
    assert.equals(4, tier.required)
    assert.equals(true, tier.confirmed)
  end)

  it("reports the tier count as unconfirmed while a tier slot is unread", function()
    local ns = fresh()
    local slots = withTierSet(ns, 3)
    slots[ns.Policy.Slots.TIER[1]].record = ns.Evidence.newSlotRecord()
    assert.equals(false, ns.Rules.tierStatus(slots, CONTEXT).confirmed)
  end)

  -- Same reason the finding turns into tier_unverified: last season's IDs match
  -- nobody, so a fully tiered raider would read as 0 of 4. An empty column is
  -- honest where a wrong number is not.
  it("has no tier count while the data is out of date for this build", function()
    local ns = fresh()
    assert.is_nil(ns.Rules.tierStatus(withTierSet(ns, 3),
                                      { minInterval = 10, dataValid = false }))
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
    assert.is_nil(ns.Rules.tierStatus(slots, CONTEXT))
  end)

  it("reports zero embellishments as a warning", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluatePlayer({ [5] = slotEntry(ns, { embellished = false }) }, CONTEXT),
      "embellishments_missing")
    assert.equals("warn", f.severity)
  end)

  it("reports nothing at two embellishments", function()
    local ns = fresh()
    local slots = {
      [5]  = slotEntry(ns, { embellished = true, link = "c1" }),
      [10] = slotEntry(ns, { embellished = true, link = "c2" }),
    }
    assert.is_nil(findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT),
                                "embellishments_missing"))
  end)

  -- Caught in a live raid: an ungenerated stub table matched nobody, so all
  -- twenty raiders collected a confident "0 of 2 embellishments". Counting only
  -- the slots we could read reproduces that fault, so an unreadable slot makes
  -- the whole count unknown.
  it("reports nothing when any slot's embellishment status is unknown", function()
    local ns = fresh()
    local slots = {
      [5]  = slotEntry(ns, { embellished = false, link = "c1" }),
      [10] = slotEntry(ns, { embellished = nil, link = "c2" }),
    }
    assert.is_nil(findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT),
                                "embellishments_missing"))
  end)

  it("counts one embellishment as still short of the cap", function()
    local ns = fresh()
    local slots = {
      [5]  = slotEntry(ns, { embellished = true, link = "c1" }),
      [10] = slotEntry(ns, { embellished = false, link = "c2" }),
    }
    local f = findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT),
                            "embellishments_missing")
    assert.equals("warn", f.severity)
    assert.matches("1 of 2", f.detail)
  end)

  -- Embellishments are read off the tooltip, not out of a generated table, so a
  -- data version this addon does not recognise is no reason to go quiet. It used
  -- to share an early return with the tier check and silently pass everyone.
  it("still counts embellishments when the data is invalid", function()
    local ns = fresh()
    local findings = ns.Rules.evaluatePlayer(
      { [5] = slotEntry(ns, { embellished = false }) },
      { minInterval = 10, dataValid = false })
    assert.equals("warn", findingOfKind(findings, "embellishments_missing").severity)
  end)

  -- Tier is the opposite case: it is counted against generated set IDs, so stale
  -- data does not merely leave it unranked, it makes the count wrong. Last
  -- season's IDs match nobody and a fully tiered raider reads as 0 of 5.
  it("reports tier as unverified rather than incomplete when the data is invalid", function()
    local ns = fresh()
    local findings = ns.Rules.evaluatePlayer(withTierSet(ns, 0),
                                             { minInterval = 10, dataValid = false })
    assert.is_nil(findingOfKind(findings, "tier_incomplete"))
    assert.equals("unknown", findingOfKind(findings, "tier_unverified").state)
  end)

  -- Both player-wide findings used to hardcode "bad", which made them the only
  -- ones in the file that could go red on evidence that had not arrived.
  it("holds the tier count at unknown while a tier slot is unconfirmed", function()
    local ns = fresh()
    local slots = withTierSet(ns, 3)
    slots[ns.Policy.Slots.TIER[1]].record = ns.Evidence.newSlotRecord()
    assert.equals("unknown",
      findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT), "tier_incomplete").state)
  end)

  it("holds the embellishment count at unknown while a slot is unconfirmed", function()
    local ns = fresh()
    local slots = {
      [5]  = slotEntry(ns, { embellished = false, link = "c1" }),
      [10] = slotEntry(ns, { embellished = false, link = "c2" }),
    }
    slots[10].record = ns.Evidence.newSlotRecord()
    assert.equals("unknown",
      findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT), "embellishments_missing").state)
  end)

  it("carries the slot number through into the player result", function()
    local ns = fresh()
    local slots = { [1] = slotEntry(ns, { parsed = parsed(0) }) }
    local f = findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT), "missing_enchant")
    assert.equals(1, f.slot)
  end)
end)
