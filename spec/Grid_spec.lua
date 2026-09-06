local helper = dofile("spec/helper.lua")

-- Grid is mostly frames, which only exist in the client. What is testable is
-- what the frames display: the sort order behind the clickable column heads and
-- the status line's arithmetic. Both are pure, so they load here without any
-- WoW API present -- and anything that stops being pure breaks this file.
local MODULES = {
  "Policy/Slots.lua",
  "Policy/Season.lua",
  "UI/Theme.lua",
  "UI/Grid.lua",
}

local function fresh()
  return helper.loadModules(MODULES)
end

-- A grid entry with nothing wrong, to be overridden per case.
local function entry(over)
  local e = { name = "Anon", errors = 0, warnings = 0, unknowns = 0, stale = false }
  for k, v in pairs(over or {}) do e[k] = v end
  return e
end

local function namesInOrder(entries, mode, ns)
  table.sort(entries, ns.Grid.comparatorFor(mode))
  local names = {}
  for i = 1, table.getn(entries) do names[i] = entries[i].name end
  return names
end

describe("Grid.comparatorFor", function()
  it("issues: a fresh unknown outranks a stale error", function()
    local ns = fresh()
    local order = namesInOrder({
      entry({ name = "Stale", errors = 3, stale = true }),
      entry({ name = "Fresh", unknowns = 1 }),
    }, "issues", ns)
    assert.same({ "Fresh", "Stale" }, order)
  end)

  it("issues: errors outrank warnings, ties break by name", function()
    local ns = fresh()
    local order = namesInOrder({
      entry({ name = "Warned", warnings = 5 }),
      entry({ name = "Broken", errors = 1 }),
      entry({ name = "Alpha", errors = 1 }),
    }, "issues", ns)
    assert.same({ "Alpha", "Broken", "Warned" }, order)
  end)

  it("name: alphabetical", function()
    local ns = fresh()
    local order = namesInOrder({
      entry({ name = "Cera" }), entry({ name = "Aza" }), entry({ name = "Bel" }),
    }, "name", ns)
    assert.same({ "Aza", "Bel", "Cera" }, order)
  end)

  it("ilvl: lowest first, unscanned last", function()
    local ns = fresh()
    local order = namesInOrder({
      entry({ name = "High", ilvl = 645.2 }),
      entry({ name = "NoData" }),
      entry({ name = "Low", ilvl = 620.5 }),
    }, "ilvl", ns)
    assert.same({ "Low", "High", "NoData" }, order)
  end)

  it("tier: biggest deficit first, complete before no data", function()
    local ns = fresh()
    local order = namesInOrder({
      entry({ name = "Done", tier = { worn = 4, required = 4, confirmed = true } }),
      entry({ name = "NoData" }),
      entry({ name = "Bare", tier = { worn = 1, required = 4, confirmed = true } }),
      entry({ name = "Close", tier = { worn = 3, required = 4, confirmed = true } }),
    }, "tier", ns)
    assert.same({ "Bare", "Close", "Done", "NoData" }, order)
  end)

  it("emb: most missing first, no data last", function()
    local ns = fresh()
    local order = namesInOrder({
      entry({ name = "Full", embellishments = { total = 16, known = 16, found = 2 } }),
      entry({ name = "NoData" }),
      entry({ name = "Bare", embellishments = { total = 16, known = 16, found = 0 } }),
    }, "emb", ns)
    assert.same({ "Bare", "Full", "NoData" }, order)
  end)
end)

-- The status line tells the scan's story and nothing else: what the findings
-- amount to is the grid's own job, so no tally of errors or warnings belongs
-- here.
describe("Grid.statusFor", function()
  it("says Scanning before anything is confirmed", function()
    local ns = fresh()
    local text = ns.Grid.statusFor({ confirmed = 0, total = 5, unreachableNames = {} })
    assert.matches("Scanning", text)
  end)

  it("shows progress while scanning", function()
    local ns = fresh()
    local text = ns.Grid.statusFor({ confirmed = 3, total = 5, unreachableNames = {} })
    assert.matches("3 / 5 confirmed", text)
  end)

  it("is just the coverage figure once complete", function()
    local ns = fresh()
    local text = ns.Grid.statusFor({ confirmed = 5, total = 5, unreachableNames = {} })
    assert.equals(ns.Theme.hex(ns.Theme.severity.ok) .. "5 / 5 confirmed|r", text)
  end)

  it("counts the unreachable without spelling out their names", function()
    local ns = fresh()
    local text = ns.Grid.statusFor(
      { confirmed = 3, total = 5, unreachableNames = { "Aza", "Bel" } })
    assert.matches("2|r not answering", text)
    assert.falsy(string.find(text, "Aza"))
  end)
end)
