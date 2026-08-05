local helper = dofile("spec/helper.lua")

local function evidence()
  return helper.loadModules({ "Evidence.lua" }).Evidence
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
  it("returns the same number for the same string", function()
    local E = evidence()
    assert.equals(E.fingerprint("item:1:2:3"), E.fingerprint("item:1:2:3"))
  end)

  it("returns different numbers for different strings", function()
    local E = evidence()
    assert.truthy(E.fingerprint("item:1:2:3") ~= E.fingerprint("item:1:2:4"))
  end)

  it("stays below 2^32 so 5.1 and 5.4 compute the same value", function()
    local E = evidence()
    local h = E.fingerprint(string.rep("x", 500))
    assert.truthy(h >= 0 and h < 4294967296)
  end)

  it("returns nil for nil", function()
    assert.is_nil(evidence().fingerprint(nil))
  end)
end)

describe("Evidence confirmation", function()
  it("confirms nothing after a single read", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, "item:1", COMPLETE, 100)
    assert.falsy(E.isConfirmed(rec, { "linkComplete" }, 10))
  end)

  it("confirms after two complete reads far enough apart", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, "item:1", COMPLETE, 100)
    E.record(rec, "item:1", COMPLETE, 115)
    assert.truthy(E.isConfirmed(rec, { "linkComplete" }, 10))
  end)

  it("does not confirm when the two reads follow too quickly", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, "item:1", COMPLETE, 100)
    E.record(rec, "item:1", COMPLETE, 103)
    assert.falsy(E.isConfirmed(rec, { "linkComplete" }, 10))
  end)

  -- This is the scenario that justifies the whole evidence model: same link,
  -- seen twice, but the source the finding needs was missing both times.
  -- Without this rule the grid would turn red on data that never existed.
  it("does not confirm a source that was missing twice", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, "item:1", NO_TOOLTIP, 100)
    E.record(rec, "item:1", NO_TOOLTIP, 115)
    assert.truthy(E.isConfirmed(rec, { "linkComplete" }, 10))
    assert.falsy(E.isConfirmed(rec, { "tooltipComplete" }, 10))
  end)

  it("requires every requested source to be confirmed", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, "item:1", NO_TOOLTIP, 100)
    E.record(rec, "item:1", NO_TOOLTIP, 115)
    assert.falsy(E.isConfirmed(rec, { "linkComplete", "tooltipComplete" }, 10))
  end)

  it("resets every counter when the fingerprint changes", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, "item:1", COMPLETE, 100)
    E.record(rec, "item:1", COMPLETE, 115)
    assert.truthy(E.isConfirmed(rec, { "linkComplete" }, 10))
    E.record(rec, "item:2", COMPLETE, 130)
    assert.falsy(E.isConfirmed(rec, { "linkComplete" }, 10))
  end)
end)

-- Two callers asked "is this slot settled" and answered it differently: the
-- scanner learned to judge an empty slot by its absence reads, the queue's
-- priority pass was left asking for a link that can never arrive for a slot with
-- no item. The player it happened to -- anyone carrying a two-hander -- stayed
-- permanently outstanding and parked at the top of the queue.
describe("Evidence slot settlement", function()
  local function withLink(E, link)
    local rec = E.newSlotRecord()
    rec.itemLink = link
    E.record(rec, link, COMPLETE, 100)
    E.record(rec, link, COMPLETE, 120)
    return rec
  end

  local function empty(E)
    local rec = E.newSlotRecord()
    E.record(rec, nil, { absent = true }, 100)
    E.record(rec, nil, { absent = true }, 120)
    return rec
  end

  it("settles a filled slot on its link", function()
    local E = evidence()
    assert.truthy(E.isSlotSettled(withLink(E, "item:1"), 10))
  end)

  it("settles an empty slot on its absence reads", function()
    local E = evidence()
    assert.truthy(E.isSlotSettled(empty(E), 10))
  end)

  it("does not settle an empty slot read only once", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, nil, { absent = true }, 100)
    assert.falsy(E.isSlotSettled(rec, 10))
  end)

  it("does not settle a slot nobody has scanned", function()
    assert.falsy(evidence().isSlotSettled(nil, 10))
  end)
end)
