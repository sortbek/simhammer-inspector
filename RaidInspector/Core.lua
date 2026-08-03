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
  -- Raised from 5. A timeout is weak evidence: with the inspect budget shared
  -- across addons, a dropped request looks exactly like an absent player. Five
  -- of them was enough to write off eight raiders who were standing next to us.
  unreachableAfter     = 10,
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

local ALL_SLOTS = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17 }

-- Worst state wins per slot: an error outranks a warning outranks unknown.
local function worstState(findings)
  local seen = nil
  for i = 1, table.getn(findings) do
    local f = findings[i]
    if f.state == "bad" then
      if f.severity == "error" then return "bad" end
      seen = "warn"
    elseif f.state == "unknown" and seen == nil then
      seen = "unknown"
    end
  end
  return seen or "ok"
end

-- Builds the shape the UI renders. Findings come back flat from Rules, so they
-- are grouped by slot here rather than in the view.
function Core.entryFor(guid)
  local info = ns.Roster.get(guid)
  if not info then return nil end

  local record = records[guid]
  local entry = {
    guid = guid,
    name = info.name,
    class = info.class,
    slots = {},
    errors = 0, warnings = 0, unknowns = 0,
    stale = false,
  }

  if not record then
    for i = 1, table.getn(ALL_SLOTS) do
      entry.slots[ALL_SLOTS[i]] = { state = "unknown", findings = {} }
      entry.unknowns = entry.unknowns + 1
    end
    return entry
  end

  entry.stale = cache and cache:isStale(guid, time()) or false

  local findings = findingsFor(guid) or {}
  local bySlot = {}
  for i = 1, table.getn(findings) do
    local f = findings[i]
    local key = f.slot or "player"
    bySlot[key] = bySlot[key] or {}
    bySlot[key][table.getn(bySlot[key]) + 1] = f

    if f.state == "bad" then
      if f.severity == "error" then entry.errors = entry.errors + 1
      else entry.warnings = entry.warnings + 1 end
    elseif f.state == "unknown" then
      entry.unknowns = entry.unknowns + 1
    end
  end

  local total, counted = 0, 0
  for i = 1, table.getn(ALL_SLOTS) do
    local slot = ALL_SLOTS[i]
    local slotRecord = record.slots[slot]
    local slotFindings = bySlot[slot] or {}

    if not slotRecord then
      entry.slots[slot] = { state = "unknown", findings = {} }
    else
      local itemName = slotRecord.itemLink
                       and string.match(slotRecord.itemLink, "%|h%[(.-)%]%|h") or nil
      entry.slots[slot] = {
        state = worstState(slotFindings),
        findings = slotFindings,
        itemName = itemName,
      }
      if slotRecord.item and slotRecord.item.ilvl then
        total = total + slotRecord.item.ilvl
        counted = counted + 1
      end
    end
  end

  entry.playerFindings = bySlot.player or {}
  if counted > 0 then entry.ilvl = total / counted end

  return entry
end

function Core.entries()
  local out = {}
  for guid in pairs(ns.Roster.all()) do
    local entry = Core.entryFor(guid)
    if entry then out[table.getn(out) + 1] = entry end
  end
  return out
end

local function refreshGrid()
  if not ns.Grid or not ns.Grid.isShown() then return end
  local confirmed, total, unreachable = queue:coverage(time())
  local names = {}
  for i = 1, table.getn(unreachable) do
    local info = ns.Roster.get(unreachable[i])
    names[i] = info and info.name or unreachable[i]
  end
  ns.Grid.refresh(Core.entries(),
                  { confirmed = confirmed, total = total, unreachableNames = names })
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
    say("not answering: " .. table.concat(names, ", "))
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

  -- The grid refreshes on a slow timer rather than on every scan event: the row
  -- redraw is cheap, but rebuilding twenty entries on each of five inspects per
  -- ten seconds is work nobody asked for.
  C_Timer.NewTicker(2, function()
    local ok, err = pcall(refreshGrid)
    if not ok then say("|cffff4444grid error:|r " .. tostring(err)) end
  end)

  local _, status = dataValid()
  say(string.format("loaded %s, data %s (%s)", ns.VERSION, ns.Data.Version.version, status))
  say("use |cffffff00/ri|r for the grid, |cffffff00/ri report|r for chat output")
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
    refreshGrid()
  elseif msg == "debug" then
    debugDump()
  elseif msg == "why" then
    whyDump()
  elseif msg == "report" then
    report()
  else
    local shown = ns.Grid.toggle()
    if shown then refreshGrid() end
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
