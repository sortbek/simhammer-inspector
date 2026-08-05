local addonName, ns = ...

local Core = {}
ns.Core = Core

SimhammerInspectorDB = SimhammerInspectorDB or {}

Core.config = {
  schemaVersion    = 1,
  staleSeconds     = 7200,
  pruneSeconds     = 2592000,
  minInterval      = 10,
}

local QUEUE_CONFIG = {
  backoffBase          = 5,
  backoffCeiling       = 60,
  -- Raised from 5. A timeout is weak evidence: with the inspect budget shared
  -- across addons, a dropped request looks exactly like an absent player. Five
  -- of them was enough to write off eight raiders who were standing next to us.
  unreachableAfter     = 10,
  reconfirmSeconds     = 600,
  -- Scheduling only, and a lower bar than Slots.MIN_COMPLETE_PASS on purpose: a
  -- pass that read ten slots taught us something worth backing off on, even
  -- though it is not enough to conclude the six it missed are empty.
  substantialPassSlots = 10,
}

local queue, cache
local records = {}

-- Session constants, resolved once at login. dataValid depends on GetBuildInfo
-- and the generated data stamp, neither of which can change without a client
-- restart -- it was being recomputed once per player on every 2 s refresh.
local sharedContext, dataStatus

-- GUIDs are what the queue reports; names are what a raid leader reads.
local function namesFor(guids)
  local names = {}
  for i = 1, table.getn(guids) do
    local info = ns.Roster.get(guids[i])
    names[i] = info and info.name or guids[i]
  end
  return names
end

local function say(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Simhammer|r " .. msg)
end

-- Derived values are never persisted, so the validity of the generated data is
-- decided fresh every session against the running client -- once, at login.
local function resolveDataStatus()
  local version, _, _, interface = GetBuildInfo()
  dataStatus = ns.DataVersion.compare(ns.Data.Version,
                                      { version = version, build = tostring(interface) })
  sharedContext = {
    minInterval = Core.config.minInterval,
    dataValid = ns.DataVersion.isValid(dataStatus),
  }
end

-- One shared immutable table rather than a fresh one per player per refresh.
-- Rules never mutates it.
local function context()
  return sharedContext
end

local function findingsFor(guid)
  local record = records[guid]
  if not record then return nil end

  local slots = {}
  for slot, slotRecord in pairs(record.slots) do
    local item = slotRecord.item
    slots[slot] = {
      parsed      = item and item.parsed or nil,
      socketCount = item and item.socketCount or nil,
      upgrade     = item and item.upgrade or nil,
      setID       = item and item.setID or nil,
      -- Not `item and item.embellished or nil`: that turns a definite false into
      -- nil, and nil means unknown, which silences the whole check.
      embellished = item and item.embellished,
      -- The off-hand enchant check needs the item class, and the empty-off-hand
      -- check needs the main hand's equip location. Both come off the item
      -- record; they used to be read from context fields nobody ever set, which
      -- meant an off-hand weapon was never checked for an enchant at all.
      classID     = item and item.classID or nil,
      equipLoc    = item and item.equipLoc or nil,
      record      = slotRecord,
    }
  end

  return ns.Rules.evaluatePlayer(slots, context())
end

local ALL_SLOTS = ns.Policy.Slots.ALL
local SLOT_NAMES = ns.Policy.Slots.NAMES

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
    realm = info.realm,
    class = info.class,
    role = info.role,
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
  local embFound, embKnown, embTotal = 0, 0, 0
  for i = 1, table.getn(ALL_SLOTS) do
    local slot = ALL_SLOTS[i]
    local slotRecord = record.slots[slot]
    local slotFindings = bySlot[slot] or {}

    if not slotRecord then
      entry.slots[slot] = { state = "unknown", findings = {} }
    else
      -- Name, icon and quality now come off the item record, computed once at
      -- harvest instead of re-derived from the link on every render pass.
      local item = slotRecord.item
      entry.slots[slot] = {
        state = worstState(slotFindings),
        findings = slotFindings,
        itemName = item and item.name or nil,
        icon = item and item.icon or nil,
        quality = item and item.quality or nil,
        ilvl = item and item.ilvl or nil,
      }

      if item and item.ilvl then
        total = total + item.ilvl
        counted = counted + 1
      end

      -- Folded into the main pass rather than a third loop over the same slots.
      -- Surfaced explicitly because the embellishment check goes silent when any
      -- slot's status is unreadable, and a silent check is indistinguishable
      -- from a passing one.
      if item and item.parsed then
        embTotal = embTotal + 1
        if item.embellished ~= nil then
          embKnown = embKnown + 1
          if item.embellished then embFound = embFound + 1 end
        end
      end
    end
  end

  entry.playerFindings = bySlot.player or {}
  if counted > 0 then entry.ilvl = total / counted end
  entry.embellishments = { found = embFound, known = embKnown, total = embTotal }

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

local SIMC_ROLE = { TANK = "tank", HEALER = "heal", DAMAGER = "attack" }

-- Falls back to reading the unit directly, so a target that is not in your group
-- can still be exported. That is what makes the format verifiable without a raid.
local function playerInfo(guid, unit)
  local info = ns.Roster.get(guid)
  if info then return info end
  if not unit or not UnitExists(unit) then return nil end

  local name, realm = UnitName(unit)
  if not realm or realm == "" then realm = GetRealmName and GetRealmName() or nil end
  local _, class = UnitClass(unit)

  return {
    name = name, realm = realm, class = class,
    race = UnitRace and UnitRace(unit) or nil,
    level = UnitLevel and UnitLevel(unit) or nil,
    role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit) or nil,
  }
end

local function simcPlayer(guid, unit)
  local info = playerInfo(guid, unit)
  local record = records[guid]
  if not info or not record then return nil end

  local slots = {}
  for i = 1, table.getn(ALL_SLOTS) do
    local slotRecord = record.slots[ALL_SLOTS[i]]
    if slotRecord and slotRecord.item and slotRecord.item.parsed then
      slots[table.getn(slots) + 1] = {
        simcSlot = ns.Policy.Slots.SIMC[ALL_SLOTS[i]],
        parsed = slotRecord.item.parsed,
      }
    end
  end

  local specName = record.specID and ns.Data.SpecNames
                   and ns.Data.SpecNames[record.specID] or nil

  return {
    name = info.name, realm = info.realm, region = Core.region(),
    class = info.class, race = info.race, level = info.level,
    spec = specName, role = SIMC_ROLE[info.role or ""] or "attack",
    talents = record.talents,
    slots = slots,
  }
end

local REGIONS = { [1] = "US", [2] = "KR", [3] = "EU", [4] = "TW", [5] = "CN" }

function Core.region()
  return REGIONS[GetCurrentRegion and GetCurrentRegion() or 0] or "US"
end

-- Throws away everything collected and starts over. Not destructive in any
-- lasting sense -- the data is rebuilt by scanning -- but it does mean waiting
-- for the grid to fill again, so it says so rather than silently blanking.
function Core.resetScan()
  for guid in pairs(records) do records[guid] = nil end

  local n = time()
  for guid in pairs(ns.Roster.all()) do
    queue:removePlayer(guid)
    queue:addPlayer(guid, n)
  end

  if cache then
    for guid in pairs(ns.Roster.all()) do cache:put(guid, { guid = guid, slots = {} }, n) end
  end

  ns.Scanner.rescanAll()
  say("cleared everything and started a fresh scan")
end

local function showBundle(players)
  table.sort(players, function(a, b) return (a.name or "") < (b.name or "") end)
  local text, skipped = ns.SimcExport.bundle(players)
  ns.Export.show(text, skipped, table.getn(players) - table.getn(skipped))
end

-- Which roles go into the export. Persisted per character, because whoever sims
-- their tanks tends to keep doing that.
Core.ROLE_ORDER = { "DAMAGER", "TANK", "HEALER" }
Core.ROLE_LABELS = { DAMAGER = "DPS", TANK = "Tanks", HEALER = "Healers" }

function Core.simcRoles()
  SimhammerInspectorDB.simcRoles = SimhammerInspectorDB.simcRoles
                                   or { DAMAGER = true, TANK = false, HEALER = false }
  return SimhammerInspectorDB.simcRoles
end

function Core.toggleSimcRole(role)
  local roles = Core.simcRoles()
  roles[role] = not roles[role]
end

-- Solo, nobody has an assigned role, so you are included regardless -- otherwise
-- the export is empty outside a group and cannot be tried at all.
function Core.exportSimc()
  local players = {}
  local roles = Core.simcRoles()
  local solo = not (IsInGroup and IsInGroup())
  local ownGuid = UnitGUID("player")

  for guid, info in pairs(ns.Roster.all()) do
    if roles[info.role or ""] or (solo and guid == ownGuid) then
      local p = simcPlayer(guid)
      if p then players[table.getn(players) + 1] = p end
    end
  end

  showBundle(players)
end

-- Exports whoever you have targeted. The point is verification: run this on your
-- own character, run /simc from the SimulationCraft addon on the same character,
-- and compare. Any difference is a defect in this addon's reading of the format.
function Core.exportSimcTarget()
  local ok, err = ns.Scanner.inspectTarget(function(guid)
    local p = simcPlayer(guid, "target")
    if not p then
      say("|cffff4444no data captured for that target|r")
      return
    end
    showBundle({ p })
  end)

  if not ok then say("|cffff4444" .. tostring(err) .. "|r") return end
  say("inspecting target, export will open when the data lands")
end

function Core.exportSimcSelf()
  ns.Scanner.scanSelf()
  local p = simcPlayer(UnitGUID("player"), "player")
  if not p then say("|cffff4444no data for yourself yet|r") return end
  showBundle({ p })
end

-- Counts slots that still lack a confirmed reading, and hands that to the queue
-- so the next request goes to whoever it will teach us the most about. Uses
-- Evidence directly rather than running Rules: the question is "is this slot
-- settled", not "what is wrong with it", and the cheap answer is the right one
-- to run on a timer.
local function updatePriorities()
  if not queue then return end
  local total = table.getn(ALL_SLOTS)

  for guid in pairs(ns.Roster.all()) do
    local record = records[guid]
    local pending = total

    if record then
      local seen, confirmed = 0, 0
      for _, slotRecord in pairs(record.slots) do
        seen = seen + 1
        if ns.Evidence.isConfirmed(slotRecord, { "linkComplete" }, Core.config.minInterval) then
          confirmed = confirmed + 1
        end
      end
      -- Slots never seen count as outstanding too, otherwise a player we only
      -- half scanned looks finished.
      pending = (total - seen) + (seen - confirmed)
    end

    queue:setPending(guid, pending)
  end
end

local function refreshGrid()
  if not ns.Grid or not ns.Grid.isShown() then return end
  local confirmed, total, unreachable = queue:coverage(time())
  local names = namesFor(unreachable)
  ns.Grid.refresh(Core.entries(),
                  { confirmed = confirmed, total = total, unreachableNames = names })
end

function Core.reportToChat()
  local confirmed, total, unreachable = queue:coverage(time())
  say(string.format("coverage: %d/%d confirmed", confirmed, total))

  if table.getn(unreachable) > 0 then
    local names = namesFor(unreachable)
    say("not answering: " .. table.concat(names, ", "))
  end

  local valid, status = sharedContext.dataValid, dataStatus
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
  -- The answer rate is the number that matters. A low rate with everyone
  -- standing together means requests are being dropped, not that people are far
  -- away, and the response to that is to ask for less rather than more.
  local rate = (s.requests > 0) and math.floor(s.answered / s.requests * 100) or 0
  say(string.format("  ticks=%d prefilterPasses=%d", s.ticks, s.hintPasses))
  say(string.format("  requests=%d answered=%d (%d%%) timedOut=%d foreignHarvests=%d",
      s.requests, s.answered, rate, s.timedOut, s.harvestedForeign))
  say(string.format("  exits: paused=%d pending=%d budget=%d noCandidate=%d",
      s.exitPaused, s.exitPending, s.exitBudget, s.exitNoCandidate))
  -- Events received is the sum of answered, foreign harvests and resolve
  -- failures, so it was a fourth number restating the other three.
  say(string.format("  tokenResolveFailed=%d via=%s",
      s.tokenResolveFailed, tostring(s.resolvedVia)))
  if s.selfError then
    say("  |cffff4444self scan error:|r " .. s.selfError)
  else
    say(string.format("  self scan: %s slots", tostring(s.selfSlots)))
  end

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
          -- No tier means confirmed and not yet due for reconfirmation, which is
          -- the desired resting state rather than a missing value.
          d.tier or "done",
          tostring(d.inRange),
          tostring(d.eligible),
          tostring(d.waitSeconds),
          tostring(record and record.slotsLastPass or "-")))
    end
  end
end

local function onLogin()
  resolveDataStatus()
  cache = ns.Cache.new(SimhammerInspectorDB, Core.config)
  cache:migrate()
  cache:prune(time())

  queue = ns.ScanQueue.new(QUEUE_CONFIG)

  ns.Roster.onAdded(function(guid) queue:addPlayer(guid, time()) end)
  ns.Roster.onRemoved(function(guid) queue:removePlayer(guid) end)
  ns.Roster.refresh()

  -- Read the cache back. It was written on every harvest and never opened once,
  -- so a /reload threw away the whole raid's gear and the grid came back empty
  -- -- which is the one thing persisting it was for. Evidence timestamps are
  -- server time precisely so they still mean something across a session
  -- boundary, and anything older than staleSeconds still renders dimmed.
  local restored = 0
  for guid in pairs(ns.Roster.all()) do
    local cached = cache:get(guid)
    if cached and cached.slots and next(cached.slots) then
      records[guid] = cached
      restored = restored + 1
    end
  end

  ns.Scanner.init(queue, cache, records)

  if restored > 0 then
    say("restored " .. restored .. " players from the last session")
  end

  -- The grid refreshes on a slow timer rather than on every scan event: the row
  -- redraw is cheap, but rebuilding twenty entries on each of five inspects per
  -- ten seconds is work nobody asked for.
  C_Timer.NewTicker(2, function()
    local ok, err = pcall(refreshGrid)
    if not ok then say("|cffff4444grid error:|r " .. tostring(err)) end
  end)

  -- Slower than the grid: priorities only shift when a scan lands, and a request
  -- goes out at most once every few seconds anyway.
  C_Timer.NewTicker(5, function()
    local ok, err = pcall(updatePriorities)
    if not ok then say("|cffff4444priority error:|r " .. tostring(err)) end
  end)

  -- Far faster than the grid refresh, because it only toggles one texture per
  -- row. An inspect lasts about a second and the grid redraws every two, so
  -- without this the marker would usually be missed entirely.
  C_Timer.NewTicker(0.2, function() pcall(ns.Grid.updateScanMarker) end)

  say(string.format("loaded %s, data %s (%s)",
      ns.VERSION, ns.Data.Version.version, dataStatus))
  say("use |cffffff00/sh|r for the grid, |cffffff00/sh report|r for chat output")
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

-- Full name first so it always works, short alias second for daily use. /sh is
-- short enough to collide with another addon, so it must never be the only way
-- in.
SLASH_SIMHAMMERINSPECTOR1 = "/simhammer"
SLASH_SIMHAMMERINSPECTOR2 = "/sh"
SlashCmdList["SIMHAMMERINSPECTOR"] = function(msg)
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
    Core.reportToChat()
  elseif msg == "simc" then
    local ok, err = pcall(Core.exportSimc)
    if not ok then say("|cffff4444simc export failed:|r " .. tostring(err)) end
  elseif msg == "simc target" then
    local ok, err = pcall(Core.exportSimcTarget)
    if not ok then say("|cffff4444simc export failed:|r " .. tostring(err)) end
  elseif msg == "simc self" then
    local ok, err = pcall(Core.exportSimcSelf)
    if not ok then say("|cffff4444simc export failed:|r " .. tostring(err)) end
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
