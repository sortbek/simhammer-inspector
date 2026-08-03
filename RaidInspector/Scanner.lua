local addonName, ns = ...

local Scanner = {}
ns.Scanner = Scanner

-- The event layer. Every scheduling decision lives in ScanQueue; what is left
-- here is plumbing around an API that is throttled, shared with other addons,
-- and only valid inside the handler that delivered it.

local SLOTS = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17 }

Scanner.config = {
  -- The server allows roughly 6 requests per 10 s and that budget is shared
  -- with every other addon that inspects. RaiderIO alone is a heavy user. Going
  -- to the ceiling means the server silently drops our requests, which arrives
  -- as a timeout and is indistinguishable from being out of range -- a live raid
  -- standing shoulder to shoulder reported eight players "out of range".
  -- Asking for less gets more answered.
  budgetRequests = 3,
  budgetWindow   = 10,
  -- Measured in a live raid: 271 ticks produced 40 requests, and 81 of those
  -- ticks were spent waiting on one in flight. Only one inspect can be pending
  -- at a time -- the slot is global -- so the timeout is the throughput limit
  -- for unreachable players. A successful in-range INSPECT_READY lands well
  -- under a second, and a false timeout only costs a retry, so 2 s buys a third
  -- more attempts per minute at negligible risk.
  timeoutSeconds = 2,
  tickSeconds    = 1,
}

local queue, cache, records
local requestTimes = {}
local pending = nil
local paused = false
local frame

local function now() return GetTime() end
local function serverNow() return time() end

-- Budget accounting is a sliding window rather than a fixed tick, because the
-- server throttle is measured over a window and the penalty for exceeding it is
-- a silently dropped request rather than an error.
local function budgetAvailable()
  local cutoff = now() - Scanner.config.budgetWindow
  local kept = {}
  for i = 1, table.getn(requestTimes) do
    if requestTimes[i] > cutoff then kept[table.getn(kept) + 1] = requestTimes[i] end
  end
  requestTimes = kept
  return table.getn(requestTimes) < Scanner.config.budgetRequests
end

local function inspectFrameOpen()
  return InspectFrame and InspectFrame:IsShown()
end

local function recordFor(guid)
  records[guid] = records[guid] or { guid = guid, slots = {} }
  return records[guid]
end

-- Harvest must happen inside the INSPECT_READY handler: GetInventoryItemLink is
-- only valid until the next NotifyInspect or ClearInspectPlayer.
local function harvest(unit, guid)
  local record = recordFor(guid)
  local returned = 0
  local stamp = serverNow()

  for i = 1, table.getn(SLOTS) do
    local slot = SLOTS[i]
    local link = GetInventoryItemLink(unit, slot)
    if link then
      returned = returned + 1
      local item, evidence = ns.Hydrator.build(link)
      local slotRecord = record.slots[slot] or ns.Evidence.newSlotRecord()
      ns.Evidence.record(slotRecord, link, evidence, stamp)
      slotRecord.itemLink = link
      slotRecord.item = item
      record.slots[slot] = slotRecord
    end
  end

  record.specID = GetInspectSpecialization and GetInspectSpecialization(unit) or nil
  record.slotsLastPass = returned
  record.scannedAt = stamp

  if cache then cache:put(guid, record, stamp) end
  return returned
end

local function allSlotsConfirmed(record)
  local confirmed, seen = 0, 0
  for _, slotRecord in pairs(record.slots) do
    seen = seen + 1
    if ns.Evidence.isConfirmed(slotRecord, { "linkComplete" }, ns.Core.config.minInterval) then
      confirmed = confirmed + 1
    end
  end
  return seen > 0 and confirmed == seen
end

local function onInspectReady(guid)
  local unit = UnitTokenFromGUID and UnitTokenFromGUID(guid)
  -- UnitTokenFromGUID is documented as unstable, so the token is verified before
  -- anything is read off it. Raid indices shift between request and reply.
  if not unit or UnitGUID(unit) ~= guid then return end

  local returned = harvest(unit, guid)
  local isOurs = (pending and pending.guid == guid)

  if isOurs then
    pending = nil
    queue:onSuccess(guid, returned, serverNow())
    if allSlotsConfirmed(recordFor(guid)) then
      queue:onConfirmed(guid, serverNow())
    end
    -- Only clear after our own request, and only while Blizzard's frame is
    -- closed: a foreign requester still needs the data we just read.
    if not inspectFrameOpen() and ClearInspectPlayer then
      ClearInspectPlayer()
    end
  else
    -- Free coverage from someone else's inspect.
    queue:onSuccess(guid, returned, serverNow())
  end
end

-- Each component is evaluated separately so a failing prefilter can be
-- attributed. Collapsing them into one boolean expression made a live raid
-- report "range=false" for twenty players with no way to tell which check said
-- no.
-- Every API call is made through pcall and records its own outcome. A live raid
-- showed 76 ticks entering this function and none leaving it, with no visible
-- error: BugGrabber was capturing them and no display addon was installed. One
-- unavailable or renamed API silently killed the entire scanner every second.
-- Guessing which one wastes a raid night; measuring costs nothing.
-- Patch 12.0 introduced "secret" values: an insecure addon may hold one but may
-- not branch on it. UnitInRange now returns such a value, and evaluating it
-- throws "attempt to perform boolean test on a secret boolean value". Coercion
-- therefore happens through pcall, and a value that cannot be tested comes back
-- as nil meaning "unknowable" rather than as false.
local function toBool(value)
  local ok, result = pcall(function() return value and true or false end)
  if ok then return result end
  return nil
end

local function call1(results, name, fn, ...)
  if type(fn) ~= "function" then
    results[name] = "MISSING"
    return nil
  end
  local ok, a = pcall(fn, ...)
  if not ok then
    results[name] = "ERROR: " .. tostring(a)
    return nil
  end
  local b = toBool(a)
  results[name] = (b == nil) and "SECRET" or b
  return b
end

function Scanner.probe(unit)
  local p = { unit = unit, calls = {} }
  if not unit then
    p.calls.unit = "MISSING"
    return p
  end

  p.exists = call1(p.calls, "UnitExists", UnitExists, unit)
  if p.exists == false then return p end

  p.isPlayer   = call1(p.calls, "UnitIsPlayer", UnitIsPlayer, unit)
  p.connected  = call1(p.calls, "UnitIsConnected", UnitIsConnected, unit)
  p.canInspect = call1(p.calls, "CanInspect", CanInspect, unit, false)
  p.inRange    = call1(p.calls, "UnitInRange", UnitInRange, unit)

  return p
end

-- Only a definite "no" excludes a player. Anything unknowable -- a secret value,
-- a missing API -- lets the request through, and the INSPECT_READY timeout
-- becomes the real out-of-range signal, exactly as the spec says it should be.
--
-- UnitInRange is deliberately not consulted here: since 12.0 it returns a secret
-- value that cannot be branched on at all. It was never more than a coarse 40 yd
-- proxy for a 28 yd limit anyway, so the tiers are now driven by measured
-- reachability -- timeout history -- instead of a hint that lied either way.
local function passesPrefilter(p)
  if p.exists == false then return false end
  if p.isPlayer == false then return false end
  if p.connected == false then return false end
  if p.canInspect == false then return false end
  return true
end

local function updateRangeHints()
  local passes = 0
  for guid, info in pairs(ns.Roster.all()) do
    local p = Scanner.probe(info.unit)
    info.probe = p
    local ok = passesPrefilter(p)
    if ok then passes = passes + 1 end
    queue:setRangeHint(guid, ok)
  end
  Scanner.stats.hintPasses = passes
end

-- Counters, not booleans. "The tick never runs" and "the tick runs and rejects
-- everyone" produced identical output in a live raid, because addPlayer starts
-- players at inRange=false. Counting each exit tells them apart.
Scanner.stats = { ticks = 0, hintPasses = 0, exitPaused = 0, exitPending = 0,
                  exitBudget = 0, exitNoCandidate = 0, requests = 0 }

-- Your own gear never needs an inspect: GetInventoryItemLink works on "player"
-- directly and always returns everything. Queueing yourself wastes budget and,
-- worse, can report you as unreachable while you are standing still looking at
-- your own character.
function Scanner.scanSelf()
  local guid = UnitGUID("player")
  if not guid or not queue then return end
  local returned = harvest("player", guid)
  queue:onSuccess(guid, returned, serverNow())
  if allSlotsConfirmed(recordFor(guid)) then
    queue:onConfirmed(guid, serverNow())
  end
  return returned
end

local function tick()
  Scanner.stats.ticks = Scanner.stats.ticks + 1

  if paused or inspectFrameOpen() then
    Scanner.stats.exitPaused = Scanner.stats.exitPaused + 1
    return
  end

  if pending and (now() - pending.at) > Scanner.config.timeoutSeconds then
    queue:onTimeout(pending.guid, serverNow())
    pending = nil
  end
  if pending then
    Scanner.stats.exitPending = Scanner.stats.exitPending + 1
    return
  end
  if not budgetAvailable() then
    Scanner.stats.exitBudget = Scanner.stats.exitBudget + 1
    return
  end

  -- One bad unit must not take the whole scanner down for the rest of the
  -- session. The error is recorded rather than swallowed.
  local ok, err = pcall(updateRangeHints)
  if not ok then
    Scanner.stats.lastError = tostring(err)
    Scanner.stats.errors = (Scanner.stats.errors or 0) + 1
    return
  end

  local guid = queue:next(serverNow())
  if not guid then
    Scanner.stats.exitNoCandidate = Scanner.stats.exitNoCandidate + 1
    return
  end

  -- Never spend an inspect on yourself; read it directly instead.
  if guid == UnitGUID("player") then
    Scanner.scanSelf()
    return
  end

  local info = ns.Roster.get(guid)
  if not info or not info.unit then return end

  pending = { guid = guid, at = now() }
  requestTimes[table.getn(requestTimes) + 1] = now()
  Scanner.stats.requests = Scanner.stats.requests + 1
  NotifyInspect(info.unit)
end

function Scanner.init(q, c, r)
  queue, cache, records = q, c, r

  frame = CreateFrame("Frame")
  frame:RegisterEvent("INSPECT_READY")
  frame:RegisterEvent("PLAYER_REGEN_DISABLED")
  frame:RegisterEvent("PLAYER_REGEN_ENABLED")
  frame:RegisterEvent("ENCOUNTER_START")
  frame:RegisterEvent("ENCOUNTER_END")
  frame:RegisterEvent("UNIT_IN_RANGE_UPDATE")

  frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "INSPECT_READY" then
      onInspectReady(arg1)
    elseif event == "PLAYER_REGEN_DISABLED" or event == "ENCOUNTER_START" then
      -- Scanning during an encounter achieves nothing, and Blizzard keeps
      -- tightening what addons may do in combat.
      paused = true
      pending = nil
    elseif event == "PLAYER_REGEN_ENABLED" or event == "ENCOUNTER_END" then
      paused = false
    elseif event == "UNIT_IN_RANGE_UPDATE" then
      local guid = UnitGUID(arg1)
      if guid then queue:onInRange(guid, serverNow()) end
    end
  end)

  C_Timer.NewTicker(Scanner.config.tickSeconds, tick)

  -- Own gear is free and always complete, so take it immediately and keep it
  -- refreshed rather than waiting for the queue to come round.
  C_Timer.After(2, function() pcall(Scanner.scanSelf) end)
  C_Timer.NewTicker(30, function() pcall(Scanner.scanSelf) end)
end

-- Priority pass for the moment just before the pull, when the raid is stacked
-- and coverage is at its best.
function Scanner.rescanAll()
  pending = nil
  requestTimes = {}
  updateRangeHints()
  for guid in pairs(ns.Roster.all()) do
    queue:onInRange(guid, serverNow())
  end
end

function Scanner.isPaused()
  return paused or inspectFrameOpen()
end

function Scanner.status()
  local pausedBy = nil
  if paused then pausedBy = "combat or encounter" end
  if inspectFrameOpen() then pausedBy = "Blizzard inspect window is open" end

  -- Recompute the window so the reported figure matches what tick() will see.
  local cutoff = now() - Scanner.config.budgetWindow
  local used = 0
  for i = 1, table.getn(requestTimes) do
    if requestTimes[i] > cutoff then used = used + 1 end
  end

  return {
    paused     = Scanner.isPaused(),
    pausedBy   = pausedBy,
    pending    = pending and pending.guid or nil,
    budgetUsed = used,
    budgetMax  = Scanner.config.budgetRequests,
  }
end
