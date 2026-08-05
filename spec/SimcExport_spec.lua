local helper = dofile("spec/helper.lua")
local links  = dofile("spec/fixtures/links.lua")

local function modules()
  return helper.loadModules({
    "SimhammerInspector/LinkParser.lua",
    "SimhammerInspector/SimcExport.lua",
  })
end

local function parseLink(link)
  return modules().LinkParser.parse(link)
end

local function exporter()
  return modules().SimcExport
end

describe("SimcExport tokenize", function()
  it("lowercases", function()
    assert.equals("hunter", exporter().tokenize("Hunter"))
  end)

  it("turns spaces into underscores, the way realm names need", function()
    assert.equals("tarren_mill", exporter().tokenize("Tarren Mill"))
  end)

  -- The reference drops apostrophes rather than turning them into underscores,
  -- and discards anything outside a-z, 0-9 and underscore. Realm names carry
  -- both apostrophes and accents, so this has to match exactly or SimC will not
  -- recognise the server.
  it("drops apostrophes without leaving an underscore", function()
    assert.equals("alnhara", exporter().tokenize("Aln'hara"))
  end)

  it("drops accented characters", function()
    assert.equals("aggra_portugus", exporter().tokenize("Aggra (Português)"))
  end)

  it("survives nil", function()
    assert.equals("", exporter().tokenize(nil))
  end)
end)

describe("SimcExport item line", function()
  it("emits slot, id, enchant, gem and bonus ids", function()
    local line = exporter().itemLine("finger1", parseLink(links.ringWithEnchantAndGem))
    assert.matches("^finger1=,id=268290", line)
    assert.matches("enchant_id=7967", line)
    assert.matches("gem_id=240890", line)
    assert.matches("bonus_id=6652/13668/13335/13786", line)
  end)

  it("omits the enchant when there is none", function()
    local line = exporter().itemLine("trinket1", parseLink(links.bareNoEnchantNoGem))
    assert.falsy(string.find(line, "enchant_id", 1, true))
  end)

  it("omits gems when there are none", function()
    local line = exporter().itemLine("trinket1", parseLink(links.bareNoEnchantNoGem))
    assert.falsy(string.find(line, "gem_id", 1, true))
  end)

  -- Modifier types 29 and 30 are the crafted stat pair; the crafted bracer in
  -- the fixtures carries ten modifier pairs including a negative value.
  it("collects crafted stats from modifier types 29 and 30", function()
    local line = exporter().itemLine("wrist", parseLink(links.craftedEmbellished))
    assert.matches("crafted_stats=49/32", line)
  end)

  it("emits content tuning from modifier type 28", function()
    local line = exporter().itemLine("wrist", parseLink(links.craftedEmbellished))
    assert.matches("content_tuning=3615", line)
  end)

  it("returns nil for an empty slot", function()
    assert.is_nil(exporter().itemLine("off_hand", nil))
  end)
end)

local function player()
  return {
    name = "Shambaerth", realm = "Argent Dawn", region = "EU",
    class = "HUNTER", race = "Dark Iron Dwarf", level = 90,
    spec = "Marksmanship", role = "attack",
    talents = "CEUAAAAAAAAAAAAAAAAAA",
    slots = {
      { simcSlot = "finger1", parsed = parseLink(links.ringWithEnchantAndGem) },
      { simcSlot = "main_hand", parsed = parseLink(links.weaponEnchanted) },
    },
  }
end

-- The same preconditions the profile enforces, asked before anything is built.
-- The detail panel needs the answer to decide whether its export button is live,
-- and a second copy of the rules there would drift from these.
describe("SimcExport validate", function()
  it("accepts a complete player", function()
    assert.equals(true, exporter().validate(player()))
  end)

  it("rejects a player without talents", function()
    local p = player()
    p.talents = nil
    local ok, err = exporter().validate(p)
    assert.is_nil(ok)
    assert.matches("talents", err)
  end)

  it("rejects an empty talent string, not just a missing one", function()
    local p = player()
    p.talents = ""
    local ok, err = exporter().validate(p)
    assert.is_nil(ok)
    assert.matches("talents", err)
  end)

  it("rejects a player without a spec", function()
    local p = player()
    p.spec = nil
    local ok, err = exporter().validate(p)
    assert.is_nil(ok)
    assert.matches("spec", err)
  end)

  it("rejects a player without a class", function()
    local p = player()
    p.class = nil
    local ok, err = exporter().validate(p)
    assert.is_nil(ok)
    assert.matches("class", err)
  end)

  it("rejects nothing at all", function()
    local ok, err = exporter().validate(nil)
    assert.is_nil(ok)
    assert.equals("string", type(err))
  end)
end)

describe("SimcExport profile", function()
  it("opens with the class assignment", function()
    assert.matches('hunter="Shambaerth"', exporter().profile(player()))
  end)

  it("tokenises race, realm and spec", function()
    local text = exporter().profile(player())
    assert.matches("race=dark_iron_dwarf", text)
    assert.matches("server=argent_dawn", text)
    assert.matches("spec=marksmanship", text)
    assert.matches("region=eu", text)
  end)

  it("carries level, role and talents", function()
    local text = exporter().profile(player())
    assert.matches("level=90", text)
    assert.matches("role=attack", text)
    assert.matches("talents=CEUAAAAAAAAAAAAAAAAAA", text)
  end)

  it("includes a comment header naming the player and spec", function()
    assert.matches("^# Shambaerth %- Marksmanship", exporter().profile(player()))
  end)

  it("emits one line per equipped slot", function()
    local text = exporter().profile(player())
    assert.matches("\nfinger1=,id=268290", text)
    assert.matches("\nmain_hand=,id=245770", text)
  end)

  -- A profile without talents sims as an unspecced character and produces a
  -- number that looks real. Refusing is safer than exporting something wrong.
  it("refuses to build a profile without talents", function()
    local p = player()
    p.talents = nil
    local text, err = exporter().profile(p)
    assert.is_nil(text)
    assert.matches("talents", err)
  end)

  -- Caught in real output: the self-scan path never set specID, because
  -- GetInspectSpecialization returns nothing for your own character. That
  -- produced a profile with an empty spec= line that looked complete.
  it("refuses to build a profile without a spec", function()
    local p = player()
    p.spec = nil
    local text, err = exporter().profile(p)
    assert.is_nil(text)
    assert.matches("spec", err)
  end)
end)

describe("SimcExport bundle", function()
  it("joins profiles with a blank line between them", function()
    local a, b = player(), player()
    b.name = "Second"
    local text, skipped = exporter().bundle({ a, b })
    assert.matches('hunter="Shambaerth"', text)
    assert.matches('hunter="Second"', text)
    assert.equals(0, table.getn(skipped))
  end)

  it("skips players it cannot build and says who", function()
    local a, b = player(), player()
    b.name = "NoTalents"
    b.talents = nil
    local text, skipped = exporter().bundle({ a, b })
    assert.matches('hunter="Shambaerth"', text)
    assert.falsy(string.find(text, "NoTalents", 1, true))
    assert.equals(1, table.getn(skipped))
    assert.equals("NoTalents", skipped[1].name)
  end)
end)
