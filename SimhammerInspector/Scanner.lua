local addonName, ns = ...

local Scanner = {}
ns.Scanner = Scanner

-- The event layer. Every scheduling decision lives in ScanQueue; what is left
-- here is plumbing around an API that is throttled, shared with other addons,
-- and only valid inside the handler that delivered it.

local SLOTS = ns.Policy.Slots.ALL

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
  -- Read from Evidence rather than copied. It was a literal here and another in
  -- Core.config, and the two have to agree: the scanner uses it to call a player
  -- covered, Rules to let a finding turn red. Nothing would have caught them
  -- drifting apart except a raid leader noticing the header disagreed with the
  -- grid.
  minInterval    = ns.Evidence.MIN_INTERVAL,
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
local function budgetUsed()
  local cutoff = now() - Scanner.config.budgetWindow
  local kept = {}
  for i = 1, table.getn(requestTimes) do
    if requestTimes[i] > cutoff then kept[table.getn(kept) + 1] = requestTimes[i] end
  end
  requestTimes = kept
  return table.getn(requestTimes)
end

local function budgetAvailable()
  return budgetUsed() < Scanner.config.budgetRequests
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
  local absent = {}

  for i = 1, table.getn(SLOTS) do
    local slot = SLOTS[i]
    local link = GetInventoryItemLink(unit, slot)

    if not link then
      -- Collected, not concluded. Whether this is an empty slot or one the
      -- inspect simply did not answer for cannot be told from inside the loop;
      -- it depends on how much of the character the whole pass returned.
      absent[table.getn(absent) + 1] = slot
    else
      returned = returned + 1
      local slotRecord = record.slots[slot] or ns.Evidence.newSlotRecord()
      record.slots[slot] = slotRecord

      local item, evidence = ns.Hydrator.build(link)
      ns.Evidence.record(slotRecord, link, evidence, stamp)
      slotRecord.itemLink = link
      slotRecord.item = item

      -- The harvest has to be synchronous -- GetInventoryItemLink is only valid
      -- inside this handler -- but an item the client has not cached yet has no
      -- tooltip, no item level and no socket count at that moment. The stored
      -- link stays valid indefinitely, so anything incomplete is rebuilt once
      -- the item loads. Without this, every check that needs the item cache
      -- silently reads as "unknown" forever.
      if not ns.Hydrator.isComplete(item, evidence) then
        ns.Hydrator.hydrate(link, function(rebuilt, rebuiltEvidence)
          if not rebuilt then return end
          local current = record.slots[slot]
          if not current or current.itemLink ~= link then return end
          ns.Evidence.record(current, link, rebuiltEvidence, serverNow())
          current.item = rebuilt
        end)
      end
    end
  end

  -- Absence is only concluded from a pass that clearly read the whole character.
  -- A thin pass looks exactly like a naked raider, and two thin passes ten
  -- seconds apart would confirm it -- turning a partial answer into sixteen red
  -- cells. Evidence.record resets the counters when the fingerprint changes, and
  -- an empty slot fingerprints as nil, so equipping or removing an item starts
  -- the two-read rule over on its own.
  --
  -- The item is dropped here and nowhere else. Clearing it inside the loop meant
  -- a thin pass -- the measured median is eight of sixteen slots -- destroyed
  -- gear that had already been read, then persisted the loss through cache:put.
  -- A slot the pass did not reach keeps what it knew and stays stale, which is
  -- what stale data is for.
  if returned >= ns.Policy.Slots.MIN_COMPLETE_PASS then
    for i = 1, table.getn(absent) do
      local slot = absent[i]
      local slotRecord = record.slots[slot] or ns.Evidence.newSlotRecord()
      record.slots[slot] = slotRecord
      slotRecord.itemLink = nil
      slotRecord.item = nil
      ns.Evidence.record(slotRecord, nil, { absent = true }, stamp)
    end
  end

  record.specID = GetInspectSpecialization and GetInspectSpecialization(unit) or nil
  record.slotsLastPass = returned
  record.scannedAt = stamp

  -- Talents are only reachable while the inspect data is live. The API is
  -- documented as sometimes needing a frame, so an empty result is retried once
  -- before the data is cleared -- which is why ClearInspectPlayer waits.
  local function readTalents()
    if not C_Traits or not C_Traits.GenerateInspectImportString then return nil end
    local ok, str = pcall(C_Traits.GenerateInspectImportString, unit)
    if not ok or type(str) ~= "string" or str == "" then return nil end
    return str
  end

  record.talents = readTalents()

  if cache then cache:put(guid, record, stamp) end
  return returned
end

local function allSlotsConfirmed(record)
  local confirmed, seen = 0, 0
  for _, slotRecord in pairs(record.slots) do
    seen = seen + 1
    if ns.Evidence.isSlotSettled(slotRecord, Scanner.config.minInterval) then
      confirmed = confirmed + 1
    end
  end
  return seen > 0 and confirmed == seen
end

-- UnitTokenFromGUID is documented as unstable and may simply not resolve. The
-- roster already holds a GUID to unit-token mapping, so fall back to it rather
-- than dropping the event: silently discarding a reply we asked for looks
-- exactly like never getting one.
local function resolveUnit(guid)
  local unit = UnitTokenFromGUID and UnitTokenFromGUID(guid)
  if unit and UnitGUID(unit) == guid then return unit, "UnitTokenFromGUID" end

  local info = ns.Roster.get(guid)
  if info and info.unit and UnitGUID(info.unit) == guid then
    return info.unit, "roster"
  end

  return nil, nil
end

local function onInspectReady(guid)

  local unit, how = resolveUnit(guid)
  if not unit then
    Scanner.stats.tokenResolveFailed = Scanner.stats.tokenResolveFailed + 1
    -- Still clear our pending slot: the reply arrived, we just could not use it.
    if pending and pending.guid == guid then pending = nil end
    return
  end
  Scanner.stats.resolvedVia = how

  local returned = harvest(unit, guid)
  local isOurs = (pending and pending.guid == guid)

  if isOurs then
    pending = nil
    Scanner.stats.answered = Scanner.stats.answered + 1
    queue:onSuccess(guid, returned, serverNow())
    if allSlotsConfirmed(recordFor(guid)) then
      queue:onConfirmed(guid, serverNow())
    end
    -- Clearing is deferred a frame so a talent string that was not ready yet
    -- gets one more chance while the inspect data is still live. Only clear
    -- after our own request, and only while Blizzard's frame is closed: a
    -- foreign requester still needs the data we just read.
    local record = recordFor(guid)
    C_Timer.After(0, function()
      if not record.talents and C_Traits and C_Traits.GenerateInspectImportString then
        local ok, str = pcall(C_Traits.GenerateInspectImportString, unit)
        if ok and type(str) == "string" and str ~= "" then
          record.talents = str
        end
      end
      if not inspectFrameOpen() and ClearInspectPlayer then
        ClearInspectPlayer()
      end
    end)
  else
    -- Free coverage from someone else's inspect. Worth counting separately:
    -- disabling a competing addon frees budget but also removes these.
    Scanner.stats.harvestedForeign = Scanner.stats.harvestedForeign + 1
    queue:onSuccess(guid, returned, serverNow())
  end
end

-- Each component is evaluated separately so a failing prefilter can be
-- attributed. Collapsing them into one boolean expression made a live raid
-- report "range=false" for twenty players with no way to tell which check said
-- no. Every API call goes through pcall and records its own outcome.
--
-- Patch 12.0 introduced "secret" values: an insecure addon may hold one but may
-- not branch on it. UnitInRange now returns such a value, and evaluating it
-- throws "attempt to perform boolean test on a secret boolean value". Coercion
-- therefore happens through pcall, and a value that cannot be tested comes back
-- as nil meaning "unknowable" rather than as false.
-- A file-scope function, not a closure per call: this used to allocate one
-- closure for every API result on every tick.
local function coerce(value)
  return value and true or false
end

local function toBool(value)
  local ok, result = pcall(coerce, value)
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
                  exitBudget = 0, exitNoCandidate = 0, requests = 0,
                  answered = 0, timedOut = 0, harvestedForeign = 0,
                  tokenResolveFailed = 0,
                  resolvedVia = nil, selfSlots = nil, selfError = nil }

-- Your own gear never needs an inspect: GetInventoryItemLink works on "player"
-- directly and always returns everything. Queueing yourself wastes budget and,
-- worse, can report you as unreachable while you are standing still looking at
-- your own character.
-- Your own spec and talents both come from different calls than an inspected
-- player's: the inspect variants need inspect data, which you never have for
-- yourself. Missing this on the spec produced a SimC profile with an empty
-- spec= line, which SimC will not accept.
local function ownSpecID()
  if not GetSpecialization or not GetSpecializationInfo then return nil end
  local index = GetSpecialization()
  if not index then return nil end
  local ok, specID = pcall(GetSpecializationInfo, index)
  if not ok then return nil end
  return specID
end

local function ownTalents()
  if not C_Traits or not C_Traits.GenerateImportString then return nil end
  if not C_ClassTalents or not C_ClassTalents.GetActiveConfigID then return nil end
  local configID = C_ClassTalents.GetActiveConfigID()
  if not configID then return nil end
  local ok, str = pcall(C_Traits.GenerateImportString, configID)
  if not ok or type(str) ~= "string" or str == "" then return nil end
  return str
end

function Scanner.scanSelf()
  local guid = UnitGUID("player")
  if not guid or not queue then return end
  local returned = harvest("player", guid)
  local record = recordFor(guid)
  record.talents = ownTalents() or record.talents
  record.specID = ownSpecID() or record.specID
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
    Scanner.stats.timedOut = Scanner.stats.timedOut + 1
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
  -- refreshed rather than waiting for the queue to come round. The error is
  -- recorded, not swallowed: a silent pcall around this is what hid the last
  -- three faults in this file.
  local function selfScan()
    local ok, err = pcall(Scanner.scanSelf)
    if ok then
      Scanner.stats.selfSlots = err
      Scanner.stats.selfError = nil
    else
      Scanner.stats.selfError = tostring(err)
    end
  end

  C_Timer.After(2, selfScan)
  C_Timer.NewTicker(30, selfScan)
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

-- Inspects whatever you have targeted and harvests it, roster or not. Exists so
-- the export can be verified against a single known character without needing a
-- raid: stand anywhere, target someone, compare the result.
function Scanner.inspectTarget(onDone)
  if not UnitExists("target") or not UnitIsPlayer("target") then
    return false, "no player targeted"
  end
  if not CanInspect("target", false) then
    return false, "cannot inspect this target"
  end

  local guid = UnitGUID("target")
  local waiting = CreateFrame("Frame")
  waiting:RegisterEvent("INSPECT_READY")
  waiting:SetScript("OnEvent", function(self, _, readyGuid)
    if readyGuid ~= guid then return end
    self:UnregisterAllEvents()
    self:SetScript("OnEvent", nil)
    -- One frame of slack, the same reason the roster path defers: the talent
    -- string is not always ready the instant the event fires.
    C_Timer.After(0, function() onDone(guid) end)
  end)

  NotifyInspect("target")
  return true
end

function Scanner.isPaused()
  return paused or inspectFrameOpen()
end

-- The scan marker polls five times a second and wants only this. Scanner.status
-- allocates a table and walks the budget window, none of which the marker reads.
function Scanner.pendingGuid()
  return pending and pending.guid or nil
end

function Scanner.status()
  local pausedBy = nil
  if paused then pausedBy = "combat or encounter" end
  if inspectFrameOpen() then pausedBy = "Blizzard inspect window is open" end

  local used = budgetUsed()

  return {
    paused     = Scanner.isPaused(),
    pausedBy   = pausedBy,
    pending    = pending and pending.guid or nil,
    budgetUsed = used,
    budgetMax  = Scanner.config.budgetRequests,
  }
end
