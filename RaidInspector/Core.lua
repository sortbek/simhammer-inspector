local addonName, ns = ...

local Core = {}
ns.Core = Core

RaidInspectorDB = RaidInspectorDB or {}

Core.config = {
  schemaVersion    = 1,
  staleSeconds     = 7200,
  pruneSeconds     = 2592000,
  minInterval      = 10,
  reconfirmSeconds = 600,
}

local QUEUE_CONFIG = {
  timeoutSeconds       = 3,
  backoffBase          = 5,
  backoffCeiling       = 60,
  retryCap             = 3,
  unreachableAfter     = 5,
  reprobeSeconds       = 60,
  reconfirmSeconds     = 600,
  substantialPassSlots = 10,
}

local SLOT_NAMES = {
  [1] = "Head", [2] = "Neck", [3] = "Shoulders", [5] = "Chest", [6] = "Waist",
  [7] = "Legs", [8] = "Feet", [9] = "Wrist", [10] = "Hands", [11] = "Finger 1",
  [12] = "Finger 2", [13] = "Trinket 1", [14] = "Trinket 2", [15] = "Back",
  [16] = "Main Hand", [17] = "Off Hand",
}

local queue, cache
local records = {}

local function say(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99RaidInspector|r " .. msg)
end

-- Derived values are never persisted, so the validity of the generated data is
-- decided fresh every session against the running client.
local function dataValid()
  local version, _, _, interface = GetBuildInfo()
  local build = tostring(interface)
  local status = ns.DataVersion.compare(ns.Data.Version,
                                        { version = version, build = build })
  return ns.DataVersion.isValid(status), status
end

local function context()
  local valid = dataValid()
  return { minInterval = Core.config.minInterval, dataValid = valid }
end

local function findingsFor(guid)
  local record = records[guid]
  if not record then return nil end

  local slots = {}
  for slot, slotRecord in pairs(record.slots) do
    slots[slot] = {
      parsed      = slotRecord.item and slotRecord.item.parsed or nil,
      socketCount = slotRecord.item and slotRecord.item.socketCount or nil,
      upgrade     = slotRecord.item and slotRecord.item.upgrade or nil,
      setID       = slotRecord.item and slotRecord.item.setID or nil,
      record      = slotRecord,
    }
  end

  return ns.Rules.evaluatePlayer(slots, context())
end

local function report()
  local confirmed, total, unreachable = queue:coverage(time())
  say(string.format("coverage: %d/%d confirmed", confirmed, total))

  if table.getn(unreachable) > 0 then
    local names = {}
    for i = 1, table.getn(unreachable) do
      local info = ns.Roster.get(unreachable[i])
      names[i] = info and info.name or unreachable[i]
    end
    say("out of range: " .. table.concat(names, ", "))
  end

  local valid, status = dataValid()
  if not valid then
    say("|cffff8800data is older than the running patch; checks degraded to unknown|r")
  elseif status == "newer-build" then
    say("|cffaaaaaadata may be slightly outdated (newer build, same patch)|r")
  end

  for guid, info in pairs(ns.Roster.all()) do
    local findings = findingsFor(guid)
    if findings then
      local shown = {}
      for i = 1, table.getn(findings) do
        local f = findings[i]
        -- Unknown findings are deliberately not reported. A finding without
        -- confirmed evidence is not something to call someone out over.
        if f.state == "bad" then
          local where = f.slot and (SLOT_NAMES[f.slot] or ("slot " .. f.slot)) or "overall"
          local colour = (f.severity == "error") and "|cffff4444" or "|cffffcc00"
          shown[table.getn(shown) + 1] =
            string.format("  %s%s|r: %s (%s)", colour, where, f.detail, f.kind)
        end
      end
      if table.getn(shown) > 0 then
        say(info.name or guid)
        for i = 1, table.getn(shown) do say(shown[i]) end
      end
    end
  end
end

local function debugDump()
  local n = time()
  local status = ns.Scanner.status()
  say(string.format("scanner %s | pending=%s | budget %d/%d used",
      status.paused and "PAUSED" or "running",
      tostring(status.pending or "-"),
      status.budgetUsed, status.budgetMax))

  if status.pausedBy then say("  paused by: " .. status.pausedBy) end

  local s = ns.Scanner.stats
  say(string.format("  ticks=%d requests=%d prefilterPasses=%d", s.ticks, s.requests, s.hintPasses))
  say(string.format("  exits: paused=%d pending=%d budget=%d noCandidate=%d",
      s.exitPaused, s.exitPending, s.exitBudget, s.exitNoCandidate))

  -- The range hint is the reason a player is skipped far more often than the
  -- tier is, so it has to be visible here. In a live raid "tier=A" for everyone
  -- said nothing about why nothing was being scanned.
  for guid, info in pairs(ns.Roster.all()) do
    local d = queue:debugInfo(guid, n)
    local record = records[guid]
    if d then
      say(string.format("  %-20s %-11s tier=%-4s range=%-5s elig=%-5s wait=%-4s slots=%s",
          info.name or guid,
          tostring(d.state),
          tostring(d.tier),
          tostring(d.inRange),
          tostring(d.eligible),
          tostring(d.waitSeconds),
          tostring(record and record.slotsLastPass or "-")))
    end
  end
end

local function onLogin()
  cache = ns.Cache.new(RaidInspectorDB, Core.config)
  cache:migrate()
  cache:prune(time())

  queue = ns.ScanQueue.new(QUEUE_CONFIG)

  ns.Roster.onAdded(function(guid) queue:addPlayer(guid, time()) end)
  ns.Roster.onRemoved(function(guid) queue:removePlayer(guid) end)
  ns.Roster.refresh()

  ns.Scanner.init(queue, cache, records)

  local _, status = dataValid()
  say(string.format("loaded %s, data %s (%s)", ns.VERSION, ns.Data.Version.version, status))
end

-- Reports each prefilter component separately, so a scanner that refuses to
-- scan can be diagnosed in one run instead of by guessing.
local function whyDump()
  local count = 0
  say("prefilter components, per API call:")

  for guid, info in pairs(ns.Roster.all()) do
    count = count + 1
    -- Only the first few, otherwise twenty players flood the chat frame and the
    -- interesting line scrolls away.
    if count <= 3 then
      local ok, p = pcall(ns.Scanner.probe, info.unit)
      if not ok then
        say(string.format("  %-18s probe itself threw: %s", info.name or guid, tostring(p)))
      else
        local parts = {}
        for name, value in pairs(p.calls) do
          parts[table.getn(parts) + 1] = name .. "=" .. tostring(value)
        end
        table.sort(parts)
        say(string.format("  %-18s unit=%s", info.name or guid, tostring(p.unit)))
        for i = 1, table.getn(parts) do say("      " .. parts[i]) end
      end
    end
  end

  if count == 0 then say("  roster is empty") end
  say(string.format("  (%d players in roster)", count))

  local s = ns.Scanner.stats
  if s.lastError then
    say("last scanner error: " .. s.lastError)
    say(string.format("scanner errors: %d", s.errors or 0))
  else
    say("no scanner errors recorded")
  end
end

SLASH_RAIDINSPECTOR1 = "/ri"
SlashCmdList["RAIDINSPECTOR"] = function(msg)
  msg = string.lower(msg or "")
  if msg == "scan" then
    ns.Scanner.rescanAll()
    say("priority pass queued")
  elseif msg == "debug" then
    debugDump()
  elseif msg == "why" then
    whyDump()
  else
    report()
  end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("GROUP_ROSTER_UPDATE")
loader:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    onLogin()
  elseif event == "GROUP_ROSTER_UPDATE" and queue then
    ns.Roster.refresh()
  end
end)
