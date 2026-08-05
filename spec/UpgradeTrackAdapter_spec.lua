local helper   = dofile("spec/helper.lua")
local tooltips = dofile("spec/fixtures/tooltips.lua")

local function adapter()
  return helper.loadModules({ "UpgradeTrackAdapter.lua" }).UpgradeTrackAdapter
end

local function pattern()
  return adapter().buildPattern(tooltips.formatString)
end

describe("UpgradeTrackAdapter pattern building", function()
  it("builds a pattern with three captures from the global string", function()
    local track, rank, max = string.match("Upgrade Level: Myth 6/6", pattern())
    assert.equals("Myth", track)
    assert.equals("6", rank)
    assert.equals("6", max)
  end)

  it("escapes magic characters in the literal segments", function()
    local p = adapter().buildPattern("Rank (%s) %d/%d")
    local track, rank, max = string.match("Rank (Hero) 3/6", p)
    assert.equals("Hero", track)
    assert.equals("3", rank)
    assert.equals("6", max)
  end)

  it("handles a track name containing a space", function()
    local track = string.match("Upgrade Level: Explorer Plus 2/8", pattern())
    assert.equals("Explorer Plus", track)
  end)

  it("works on a non-English format string", function()
    local p = adapter().buildPattern("Verbesserungsstufe: %s %d/%d")
    local track, rank = string.match("Verbesserungsstufe: Mythisch 4/6", p)
    assert.equals("Mythisch", track)
    assert.equals("4", rank)
  end)
end)

describe("UpgradeTrackAdapter parsing", function()
  it("recognises every real upgrade line from the spike", function()
    local A, p = adapter(), pattern()
    for i = 1, table.getn(tooltips.withTrack) do
      local line = tooltips.withTrack[i]
      local r = A.parse({ line }, p)
      assert.truthy(r, "no match on: " .. line)
      assert.truthy(r.rank >= 1 and r.rank <= r.max)
    end
  end)

  it("returns track, rank and max with the right types", function()
    local r = adapter().parse({ "Upgrade Level: Hero 3/6" }, pattern())
    assert.equals("Hero", r.track)
    assert.equals(3, r.rank)
    assert.equals(6, r.max)
  end)

  it("finds the line in the middle of a full tooltip", function()
    local lines = { "Name", "Item Level 298", "Upgrade Level: Myth 5/6", "+123 Mastery" }
    local r = adapter().parse(lines, pattern())
    assert.equals("Myth", r.track)
    assert.equals(5, r.rank)
  end)

  it("returns nil when there is no upgrade line", function()
    assert.is_nil(adapter().parse(tooltips.withoutTrack, pattern()))
  end)

  it("returns nil for an empty or missing tooltip", function()
    local A, p = adapter(), pattern()
    assert.is_nil(A.parse({}, p))
    assert.is_nil(A.parse(nil, p))
  end)

  it("ignores non-string lines without crashing", function()
    local r = adapter().parse({ 42, false, "Upgrade Level: Myth 1/6" }, pattern())
    assert.equals(1, r.rank)
  end)
end)
