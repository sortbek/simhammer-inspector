local helper = dofile("spec/helper.lua")

local function cache(store, overrides)
  local ns = helper.loadModules({ "SimhammerInspector/Cache.lua" })
  local config = { schemaVersion = 1, staleSeconds = 7200, pruneSeconds = 2592000 }
  for k, v in pairs(overrides or {}) do config[k] = v end
  return ns.Cache.new(store or {}, config)
end

local function record()
  return { name = "Tester", slots = { [1] = { itemLink = "item:1" } } }
end

describe("Cache storage", function()
  it("stores and retrieves a record", function()
    local c = cache()
    c:put("A", record(), 100)
    assert.equals("Tester", c:get("A").name)
  end)

  it("returns nil for an unknown guid", function()
    assert.is_nil(cache():get("nope"))
  end)

  it("stamps the store with the schema version", function()
    local store = {}
    local c = cache(store)
    c:put("A", record(), 100)
    assert.equals(1, store.schemaVersion)
  end)
end)

describe("Cache staleness", function()
  it("is fresh inside the stale window", function()
    local c = cache(nil, { staleSeconds = 100 })
    c:put("A", record(), 100)
    assert.falsy(c:isStale("A", 150))
  end)

  it("is stale past the window", function()
    local c = cache(nil, { staleSeconds = 100 })
    c:put("A", record(), 100)
    assert.truthy(c:isStale("A", 300))
  end)

  it("treats a missing record as stale", function()
    assert.truthy(cache():isStale("nope", 100))
  end)
end)

describe("Cache pruning", function()
  it("drops records past the prune window", function()
    local c = cache(nil, { pruneSeconds = 100 })
    c:put("old", record(), 100)
    c:put("new", record(), 500)
    local dropped = c:prune(550)
    assert.equals(1, dropped)
    assert.is_nil(c:get("old"))
    assert.truthy(c:get("new"))
  end)

  it("keeps everything when nothing is old enough", function()
    local c = cache(nil, { pruneSeconds = 1000 })
    c:put("A", record(), 100)
    assert.equals(0, c:prune(200))
  end)
end)

-- The store was written on every harvest and never read back, so a /reload threw
-- away the whole raid's gear. What makes reading it back safe is that evidence
-- timestamps are server time rather than session-relative GetTime: a record put
-- in one session still means the same thing when the next one opens it.
describe("Cache round trip", function()
  local function withEvidence()
    local ns = helper.loadModules({
      "SimhammerInspector/Evidence.lua", "SimhammerInspector/Cache.lua",
    })
    return ns, ns.Cache.new({}, { schemaVersion = 1, staleSeconds = 7200,
                                  pruneSeconds = 2592000 })
  end

  it("keeps a slot confirmed across a restore", function()
    local ns, c = withEvidence()
    local slotRecord = ns.Evidence.newSlotRecord()
    ns.Evidence.record(slotRecord, "item:1", { linkComplete = true }, 1000)
    ns.Evidence.record(slotRecord, "item:1", { linkComplete = true }, 1020)

    c:put("A", { slots = { [1] = slotRecord } }, 1020)

    local restored = c:get("A")
    assert.truthy(ns.Evidence.isConfirmed(restored.slots[1], { "linkComplete" }, 10))
  end)

  it("does not confirm a slot that was only read once before the reload", function()
    local ns, c = withEvidence()
    local slotRecord = ns.Evidence.newSlotRecord()
    ns.Evidence.record(slotRecord, "item:1", { linkComplete = true }, 1000)

    c:put("A", { slots = { [1] = slotRecord } }, 1000)

    local restored = c:get("A")
    assert.falsy(ns.Evidence.isConfirmed(restored.slots[1], { "linkComplete" }, 10))
  end)
end)

describe("Cache schema migration", function()
  -- Discarding beats migrating: a half-migrated cache renders as confident data
  -- that was derived under different rules.
  it("discards a store written by an older schema", function()
    local store = { schemaVersion = 0, players = { A = record() } }
    local c = cache(store)
    c:migrate()
    assert.is_nil(c:get("A"))
    assert.equals(1, store.schemaVersion)
  end)

  it("keeps a store written by the current schema", function()
    local store = {}
    local c = cache(store)
    c:put("A", record(), 100)
    c:migrate()
    assert.truthy(c:get("A"))
  end)
end)
