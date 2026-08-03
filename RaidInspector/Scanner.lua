local addonName, ns = ...

local Scanner = {}
ns.Scanner = Scanner

-- The event layer. Every scheduling decision lives in ScanQueue; what is left
-- here is plumbing around an API that is throttled, shared with other addons,
-- and only valid inside the handler that delivered it.

local SLOTS = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17 }

Scanner.config = {
  budgetRequests = 5,
  budgetWindow   = 10,
  timeoutSeconds = 3,
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

local function updateRangeHints()
  for guid, info in pairs(ns.Roster.all()) do
    local unit = info.unit
    local ok = unit and UnitExists(unit) and CanInspect(unit, false) and UnitInRange(unit)
    queue:setRangeHint(guid, ok and true or false)
  end
end

local function tick()
  if paused or inspectFrameOpen() then return end

  if pending and (now() - pending.at) > Scanner.config.timeoutSeconds then
    queue:onTimeout(pending.guid, serverNow())
    pending = nil
  end
  if pending then return end
  if not budgetAvailable() then return end

  updateRangeHints()

  local guid = queue:next(serverNow())
  if not guid then return end

  local info = ns.Roster.get(guid)
  if not info or not info.unit then return end

  pending = { guid = guid, at = now() }
  requestTimes[table.getn(requestTimes) + 1] = now()
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
