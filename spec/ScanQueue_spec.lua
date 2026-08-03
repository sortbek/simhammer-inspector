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
