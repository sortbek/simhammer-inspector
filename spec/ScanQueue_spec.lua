local helper = dofile("spec/helper.lua")

local function queue(overrides)
  local ns = helper.loadModules({ "RaidInspector/ScanQueue.lua" })
  local config = {
    timeoutSeconds       = 3,
    backoffBase          = 5,
    backoffCeiling       = 60,
    retryCap             = 3,
    unreachableAfter     = 5,
    reprobeSeconds       = 60,
    reconfirmSeconds     = 600,
    substantialPassSlots = 10,
  }
  for k, v in pairs(overrides or {}) do config[k] = v end
  return ns.ScanQueue.new(config)
end

describe("ScanQueue state machine", function()
  it("starts a new player as unseen", function()
    local q = queue()
    q:addPlayer("A", 100)
    assert.equals("unseen", q:stateOf("A"))
  end)

  it("moves a player to partial after a substantial pass", function()
    local q = queue()
    q:addPlayer("A", 100)
    q:onSuccess("A", 15, 110)
    assert.equals("partial", q:stateOf("A"))
  end)

  -- The spike showed inspects returning as few as 2 of 16 slots. A pass that
  -- thin is not evidence of anything and must not advance the player.
  it("does not advance on a thin pass", function()
    local q = queue()
    q:addPlayer("A", 100)
    q:onSuccess("A", 2, 110)
    assert.equals("unseen", q:stateOf("A"))
  end)

  it("reaches confirmed only when told every slot is confirmed", function()
    local q = queue()
    q:addPlayer("A", 100)
    q:onSuccess("A", 15, 110)
    q:onConfirmed("A", 130)
    assert.equals("confirmed", q:stateOf("A"))
  end)

  it("becomes unreachable after the configured consecutive timeouts", function()
    local q = queue({ unreachableAfter = 3 })
    q:addPlayer("A", 100)
    q:onTimeout("A", 101)
    q:onTimeout("A", 110)
    assert.truthy(q:stateOf("A") ~= "unreachable")
    q:onTimeout("A", 130)
    assert.equals("unreachable", q:stateOf("A"))
  end)

  it("resets the timeout streak on a successful pass", function()
    local q = queue({ unreachableAfter = 3 })
    q:addPlayer("A", 100)
    q:onTimeout("A", 101)
    q:onTimeout("A", 110)
    q:onSuccess("A", 15, 120)
    q:onTimeout("A", 130)
    assert.truthy(q:stateOf("A") ~= "unreachable")
  end)

  -- Without this exit an out-of-range player stays grey all night, which the
  -- design review flagged as a hole in the original state machine.
  it("returns an unreachable player to the queue when they come into range", function()
    local q = queue({ unreachableAfter = 1 })
    q:addPlayer("A", 100)
    q:onTimeout("A", 101)
    assert.equals("unreachable", q:stateOf("A"))
    q:onInRange("A", 200)
    assert.equals("queued", q:stateOf("A"))
  end)

  it("goes stale once the data ages past the reconfirmation window", function()
    local q = queue({ reconfirmSeconds = 100 })
    q:addPlayer("A", 100)
    q:onSuccess("A", 15, 110)
    q:onConfirmed("A", 120)
    assert.equals("confirmed", q:stateOf("A", 150))
    assert.equals("stale", q:stateOf("A", 500))
  end)

  it("forgets a player who left the group", function()
    local q = queue()
    q:addPlayer("A", 100)
    q:removePlayer("A")
    assert.is_nil(q:stateOf("A"))
  end)
end)

describe("ScanQueue tiers and selection", function()
  it("puts a fresh in-range player in tier A", function()
    local q = queue()
    q:addPlayer("A", 100)
    q:setRangeHint("A", true)
    assert.equals("A", q:tierOf("A", 100))
  end)

  it("puts a confirmed player due for reconfirmation in tier B", function()
    local q = queue({ reconfirmSeconds = 100 })
    q:addPlayer("A", 100)
    q:setRangeHint("A", true)
    q:onSuccess("A", 15, 110)
    q:onConfirmed("A", 120)
    assert.equals("B", q:tierOf("A", 500))
  end)

  it("puts a player in backoff in tier C", function()
    local q = queue()
    q:addPlayer("A", 100)
    q:setRangeHint("A", true)
    q:onTimeout("A", 101)
    assert.equals("C", q:tierOf("A", 102))
  end)

  it("puts an unreachable player in tier C", function()
    local q = queue({ unreachableAfter = 1 })
    q:addPlayer("A", 100)
    q:setRangeHint("A", true)
    q:onTimeout("A", 101)
    assert.equals("C", q:tierOf("A", 500))
  end)

  it("skips a player the range hint says is out of range", function()
    local q = queue()
    q:addPlayer("A", 100)
    q:setRangeHint("A", false)
    assert.is_nil(q:next(100))
  end)

  it("prefers tier A over tier C", function()
    local q = queue()
    q:addPlayer("cold", 100)
    q:setRangeHint("cold", true)
    q:onTimeout("cold", 101)
    q:addPlayer("warm", 100)
    q:setRangeHint("warm", true)
    assert.equals("warm", q:next(200))
  end)

  -- The starvation guard: a cold player must not be picked while a warm one is
  -- waiting, no matter how long the cold one has been eligible.
  it("does not let tier C starve tier A", function()
    local q = queue()
    for i = 1, 5 do
      local id = "cold" .. i
      q:addPlayer(id, 100)
      q:setRangeHint(id, true)
      q:onTimeout(id, 101)
    end
    q:addPlayer("warm", 100)
    q:setRangeHint("warm", true)
    for _ = 1, 10 do
      assert.equals("warm", q:next(1000))
    end
  end)

  it("returns nil when nothing is eligible", function()
    local q = queue()
    assert.is_nil(q:next(100))
  end)

  it("respects the backoff deadline", function()
    local q = queue({ backoffBase = 50 })
    q:addPlayer("A", 100)
    q:setRangeHint("A", true)
    q:onTimeout("A", 100)
    assert.is_nil(q:next(120))
    assert.equals("A", q:next(200))
  end)

  it("reports coverage as confirmed out of total", function()
    local q = queue()
    q:addPlayer("A", 100); q:setRangeHint("A", true)
    q:addPlayer("B", 100); q:setRangeHint("B", true)
    q:onSuccess("A", 15, 110)
    q:onConfirmed("A", 120)
    local confirmed, total = q:coverage(130)
    assert.equals(1, confirmed)
    assert.equals(2, total)
  end)

  -- A second scan of a player who still has unconfirmed slots yields
  -- information; a second scan of one who is already fully confirmed does not.
  -- Ordering by that turns problems red sooner without spending more requests.
  it("prefers the player with the most unconfirmed slots", function()
    local q = queue()
    q:addPlayer("few", 100); q:setRangeHint("few", true); q:setPending("few", 1)
    q:addPlayer("many", 100); q:setRangeHint("many", true); q:setPending("many", 9)
    assert.equals("many", q:next(200))
  end)

  it("falls back to the longest wait when the pending counts match", function()
    local q = queue()
    q:addPlayer("later", 150); q:setRangeHint("later", true); q:setPending("later", 3)
    q:addPlayer("earlier", 100); q:setRangeHint("earlier", true); q:setPending("earlier", 3)
    assert.equals("earlier", q:next(200))
  end)

  it("still puts tier A ahead of a cold player with more pending slots", function()
    local q = queue()
    q:addPlayer("cold", 100); q:setRangeHint("cold", true); q:setPending("cold", 16)
    q:onTimeout("cold", 101)
    q:addPlayer("warm", 100); q:setRangeHint("warm", true); q:setPending("warm", 1)
    assert.equals("warm", q:next(500))
  end)

  it("treats an unset pending count as zero rather than erroring", function()
    local q = queue()
    q:addPlayer("A", 100); q:setRangeHint("A", true)
    assert.equals("A", q:next(200))
  end)

  it("lists unreachable players in the coverage report", function()
    local q = queue({ unreachableAfter = 1 })
    q:addPlayer("A", 100); q:setRangeHint("A", true)
    q:onTimeout("A", 101)
    local _, _, unreachable = q:coverage(200)
    assert.equals(1, table.getn(unreachable))
    assert.equals("A", unreachable[1])
  end)
end)
