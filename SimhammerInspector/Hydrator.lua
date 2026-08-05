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

-- Embellishments announce themselves in the tooltip: "Unique-Equipped:
-- Embellished (2)", seen on 19 of 184 captured items. That is far simpler than
-- chasing bonus IDs through DB2, but the word is localised, so on a client whose
-- locale we cannot read this returns nil -- unknown -- rather than false.
-- Absence of an English word on a German client is not evidence of absence.
local ENGLISH_LOCALES = { enUS = true, enGB = true }

local function isEmbellished(lines)
  if not lines then return nil end

  for i = 1, table.getn(lines) do
    local line = lines[i]
    if type(line) == "string" and string.find(line, "Embellished", 1, true) then
      return true
    end
  end

  local locale = GetLocale and GetLocale() or nil
  if locale and ENGLISH_LOCALES[locale] then return false end
  return nil
end

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

  -- One GetItemInfo call, not one per value: name is return 1, quality is 3 and
  -- setID is 16. These used to be re-derived from the link on every 2 s render
  -- pass -- four hundred API calls a second for values that only change when the
  -- link does, which is at harvest.
  local name, quality, setID
  if C_Item and C_Item.GetItemInfo then
    local n, _, q = C_Item.GetItemInfo(link)
    name, quality = n, q
    setID = select(16, C_Item.GetItemInfo(link))
  end

  local icon
  if C_Item and C_Item.GetItemInfoInstant then
    icon = select(5, C_Item.GetItemInfoInstant(link))
  end

  local ilvl = nil
  if C_Item and C_Item.GetDetailedItemLevelInfo then
    ilvl = C_Item.GetDetailedItemLevelInfo(link)
  end

  -- Crafted items carry inline texture escapes in their name; strip them so
  -- consumers get a name rather than a name plus markup.
  if name then name = string.gsub(name, "%s*|A.-|a", "") end

  local item = {
    parsed      = parsed,
    socketCount = sockets,
    upgrade     = upgrade,
    setID       = setID,
    ilvl        = ilvl,
    embellished = isEmbellished(lines),
    name        = name,
    icon        = icon,
    quality     = quality,
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
