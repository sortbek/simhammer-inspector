local addonName, ns = ...

local Hydrator = {}
ns.Hydrator = Hydrator

-- Turns a raw item link into the item record Rules expects, together with the
-- evidence describing which sources actually answered. Everything here is
-- asynchronous or API-bound; anything that could be decided without the API
-- already lives in LinkParser, Rules or Evidence.

local upgradePattern

local function pattern()
  if upgradePattern == nil then
    -- Built from Blizzard's own global string so it holds on a non-English
    -- client. Measured on 12.0.7: "Upgrade Level: %s %d/%d".
    local fmt = ITEM_UPGRADE_TOOLTIP_FORMAT_STRING
    upgradePattern = fmt and ns.UpgradeTrackAdapter.buildPattern(fmt) or false
  end
  return upgradePattern or nil
end

local function socketCount(link)
  if not C_Item or not C_Item.GetItemStats then return nil end
  local stats = C_Item.GetItemStats(link)
  if not stats then return nil end

  -- The EMPTY_SOCKET_* keys count sockets present, not sockets empty. Verified
  -- against 184 real items: a bracer with a filled Prismatic Socket returns 1.
  local n = 0
  for key, value in pairs(stats) do
    if string.find(key, "EMPTY_SOCKET", 1, true) then n = n + value end
  end
  return n
end

local function tooltipLines(link)
  if not C_TooltipInfo or not C_TooltipInfo.GetHyperlink then return nil end
  local data = C_TooltipInfo.GetHyperlink(link)
  if not data or not data.lines then return nil end

  local lines = {}
  for i, line in ipairs(data.lines) do
    lines[i] = line.leftText
  end
  return lines
end

-- Tooltip completeness cannot be read off a flag: hasDynamicData was absent on
-- all 184 items measured. A tooltip that carries only the item name is treated
-- as incomplete, since every real item tooltip has several lines.
local MIN_COMPLETE_TOOLTIP_LINES = 3

-- Builds the item record synchronously from whatever is already cached. Callers
-- that need the item loaded first go through Hydrator.hydrate.
function Hydrator.build(link)
  local parsed = ns.LinkParser.parse(link)
  if not parsed then
    return nil, { linkComplete = false, socketsKnown = false,
                  tooltipComplete = false, itemLoaded = false }
  end

  local sockets = socketCount(link)
  local lines = tooltipLines(link)
  local p = pattern()
  local upgrade = (lines and p) and ns.UpgradeTrackAdapter.parse(lines, p) or nil

  local setID = nil
  local ilvl = nil
  if C_Item and C_Item.GetItemInfo then
    setID = select(16, C_Item.GetItemInfo(link))
  end
  if C_Item and C_Item.GetDetailedItemLevelInfo then
    ilvl = C_Item.GetDetailedItemLevelInfo(link)
  end

  local item = {
    parsed      = parsed,
    socketCount = sockets,
    upgrade     = upgrade,
    setID       = setID,
    ilvl        = ilvl,
  }

  local evidence = {
    linkComplete    = true,
    socketsKnown    = sockets ~= nil,
    tooltipComplete = lines ~= nil and table.getn(lines) >= MIN_COMPLETE_TOOLTIP_LINES,
    itemLoaded      = ilvl ~= nil,
  }

  return item, evidence
end

-- Waits for the item to load, then builds. A hydration timeout hands back what
-- is known so far rather than hanging: without one a slot can sit unresolved
-- forever on an item the server never answers for.
local HYDRATION_TIMEOUT = 5

function Hydrator.hydrate(link, callback)
  local parsed = ns.LinkParser.parse(link)
  if not parsed then
    callback(nil, { linkComplete = false, socketsKnown = false,
                    tooltipComplete = false, itemLoaded = false })
    return
  end

  local finished = false
  local function finish()
    if finished then return end
    finished = true
    callback(Hydrator.build(link))
  end

  local item = Item and Item.CreateFromItemLink and Item:CreateFromItemLink(link)
  if item and not item:IsItemEmpty() then
    item:ContinueOnItemLoad(finish)
  else
    finish()
    return
  end

  if C_Timer and C_Timer.After then
    C_Timer.After(HYDRATION_TIMEOUT, finish)
  end
end
