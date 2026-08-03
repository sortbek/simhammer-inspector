local addonName, ns = ...

local ScanQueue = {}
ns.ScanQueue = ScanQueue

local Queue = {}
Queue.__index = Queue

-- Time is always a parameter, never read from the clock. That is what makes the
-- scheduling logic testable at all, and it keeps the reconfirmation cadence from
-- being untestable in principle.
function ScanQueue.new(config)
  return setmetatable({ config = config, players = {} }, Queue)
end

function Queue:addPlayer(guid, now)
  if self.players[guid] then return end
  self.players[guid] = {
    guid = guid,
    state = "unseen",
    inRange = false,
    timeoutStreak = 0,
    retriesThisPass = 0,
    backoff = 0,
    nextEligibleAt = now,
    lastSuccessAt = nil,
    confirmedAt = nil,
  }
end

function Queue:removePlayer(guid)
  self.players[guid] = nil
end

function Queue:onTimeout(guid, now)
  local p = self.players[guid]
  if not p then return end

  p.timeoutStreak = p.timeoutStreak + 1
  p.retriesThisPass = p.retriesThisPass + 1

  -- Exponential backoff from a stated base. Without a base an implementer has to
  -- invent one, and the schedule silently differs from the spec.
  if p.backoff == 0 then
    p.backoff = self.config.backoffBase
  else
    p.backoff = math.min(p.backoff * 2, self.config.backoffCeiling)
  end
  p.nextEligibleAt = now + p.backoff

  if p.timeoutStreak >= self.config.unreachableAfter then
    p.state = "unreachable"
  end
end

function Queue:onSuccess(guid, slotsReturned, now)
  local p = self.players[guid]
  if not p then return end

  p.timeoutStreak = 0
  p.retriesThisPass = 0
  p.backoff = 0
  p.nextEligibleAt = now

  -- A thin pass still proves the player is reachable, so the streak resets, but
  -- it is not enough to advance the state. The spike measured passes returning
  -- anywhere from 2 to 15 of 16 slots.
  if slotsReturned >= self.config.substantialPassSlots then
    p.lastSuccessAt = now
    if p.state ~= "confirmed" then p.state = "partial" end
  end
end

function Queue:onConfirmed(guid, now)
  local p = self.players[guid]
  if not p then return end
  p.state = "confirmed"
  p.confirmedAt = now
end

function Queue:onInRange(guid, now)
  local p = self.players[guid]
  if not p then return end
  if p.state == "unreachable" then
    p.state = "queued"
    p.timeoutStreak = 0
    p.backoff = 0
    p.nextEligibleAt = now
  end
end

function Queue:setRangeHint(guid, inRange)
  local p = self.players[guid]
  if p then p.inRange = inRange and true or false end
end

-- Tier is a priority class; eligibility is a point in time. Keeping them apart
-- matters: a player in backoff belongs to tier C regardless of whether their
-- deadline has passed, and conflating the two makes next() hand out a player
-- whose backoff is still running.
function Queue:isEligible(guid, now)
  local p = self.players[guid]
  if not p then return false end
  if not p.inRange then return false end
  if p.nextEligibleAt and now < p.nextEligibleAt then return false end
  return true
end

function Queue:tierOf(guid, now)
  local p = self.players[guid]
  if not p then return nil end

  if p.state == "unreachable" then return "C" end
  if p.backoff > 0 then return "C" end

  if p.state == "confirmed" then
    if p.confirmedAt and (now - p.confirmedAt) > self.config.reconfirmSeconds then
      return "B"
    end
    return nil
  end

  return "A"
end

-- Selection is strictly A before B before C. The shares in the spec act as a
-- ceiling on tier C rather than a round robin: what matters is that a handful of
-- players in the 28-40 yd band, who pass UnitInRange but fail inspect, cannot
-- absorb the budget while someone standing next to you goes unscanned.
local TIER_ORDER = { "A", "B", "C" }

function Queue:next(now)
  for i = 1, table.getn(TIER_ORDER) do
    local wanted = TIER_ORDER[i]
    local best = nil
    for guid, p in pairs(self.players) do
      if self:isEligible(guid, now) and self:tierOf(guid, now) == wanted then
        if not best or p.nextEligibleAt < self.players[best].nextEligibleAt then
          best = guid
        end
      end
    end
    if best then return best end
  end
  return nil
end

-- Exposed for diagnostics. In a live raid "tier=A" told us nothing about why a
-- player was not being scanned, because tier deliberately ignores range.
function Queue:debugInfo(guid, now)
  local p = self.players[guid]
  if not p then return nil end
  return {
    state          = self:stateOf(guid, now),
    tier           = self:tierOf(guid, now),
    inRange        = p.inRange,
    eligible       = self:isEligible(guid, now),
    waitSeconds    = p.nextEligibleAt and math.max(0, p.nextEligibleAt - now) or 0,
    timeoutStreak  = p.timeoutStreak,
  }
end

function Queue:coverage(now)
  local confirmed, total, unreachable = 0, 0, {}
  for guid, p in pairs(self.players) do
    total = total + 1
    if self:stateOf(guid, now) == "confirmed" then confirmed = confirmed + 1 end
    if p.state == "unreachable" then
      unreachable[table.getn(unreachable) + 1] = guid
    end
  end
  table.sort(unreachable)
  return confirmed, total, unreachable
end

function Queue:stateOf(guid, now)
  local p = self.players[guid]
  if not p then return nil end

  if p.state == "confirmed" and now and p.confirmedAt then
    if (now - p.confirmedAt) > self.config.reconfirmSeconds then
      return "stale"
    end
  end

  return p.state
end
