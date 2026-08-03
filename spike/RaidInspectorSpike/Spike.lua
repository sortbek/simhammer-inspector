local addonName, ns = ...

RaidInspectorSpikeDB = RaidInspectorSpikeDB or {}

-- De zestien gecontroleerde slots, in de volgorde van de spec.
local SLOTS = {
  1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17,
}

local function dumpGlobalString()
  return {
    exists = (ITEM_UPGRADE_TOOLTIP_FORMAT_STRING ~= nil),
    value  = ITEM_UPGRADE_TOOLTIP_FORMAT_STRING,
  }
end

-- Vergelijkt de kandidaat-APIs voor socketcount op hetzelfde item. Welke er
-- werkt voor andermans gear is precies wat deze spike moet uitwijzen.
local function socketSources(link)
  local result = {}

  local stats = C_Item.GetItemStats and C_Item.GetItemStats(link)
  if stats then
    local n = 0
    for key, value in pairs(stats) do
      if string.find(key, "EMPTY_SOCKET") then n = n + value end
    end
    result.fromGetItemStats = n
  else
    result.fromGetItemStats = "nil"
  end

  if C_Item.GetItemNumSockets then
    local ok, v = pcall(C_Item.GetItemNumSockets, link)
    result.fromGetItemNumSockets = ok and v or ("fout: " .. tostring(v))
  else
    result.fromGetItemNumSockets = "API bestaat niet"
  end

  if C_Item.GetItemNumAddedSockets then
    local ok, v = pcall(C_Item.GetItemNumAddedSockets, link)
    result.fromGetItemNumAddedSockets = ok and v or ("fout: " .. tostring(v))
  else
    result.fromGetItemNumAddedSockets = "API bestaat niet"
  end

  return result
end

local function tooltipLines(link)
  if not C_TooltipInfo or not C_TooltipInfo.GetHyperlink then
    return { error = "C_TooltipInfo.GetHyperlink bestaat niet" }
  end
  local data = C_TooltipInfo.GetHyperlink(link)
  if not data then return { error = "geen tooltipdata" } end

  local lines = { hasDynamicData = data.hasDynamicData }
  for i, line in ipairs(data.lines or {}) do
    lines[i] = line.leftText
  end
  return lines
end

local function capture(unit, label)
  local entry = {
    label      = label,
    name       = UnitName(unit),
    guid       = UnitGUID(unit),
    capturedAt = time(),
    build      = select(2, GetBuildInfo()),
    version    = GetBuildInfo(),
    globalStr  = dumpGlobalString(),
    slots      = {},
  }

  local count = 0
  for _, slot in ipairs(SLOTS) do
    local link = GetInventoryItemLink(unit, slot)
    if link then
      count = count + 1
      entry.slots[slot] = {
        link    = link,
        sockets = socketSources(link),
        tooltip = tooltipLines(link),
        setID   = select(16, C_Item.GetItemInfo(link)),
        ilvl    = C_Item.GetDetailedItemLevelInfo(link),
      }
    end
  end

  table.insert(RaidInspectorSpikeDB, entry)
  print(string.format("Spike: %s vastgelegd (%d slots).", label, count))
end

SLASH_RISPIKE1 = "/rispike"
SlashCmdList["RISPIKE"] = function(msg)
  if msg == "wipe" then
    RaidInspectorSpikeDB = {}
    print("Spike: database geleegd.")
    return
  end
  if msg == "target" then
    if not UnitExists("target") then print("Spike: geen target."); return end
    if not CanInspect("target") then print("Spike: kan dit doel niet inspecten."); return end
    NotifyInspect("target")
    print("Spike: inspect aangevraagd, wacht op INSPECT_READY.")
    return
  end
  capture("player", "player")
end

local f = CreateFrame("Frame")
f:RegisterEvent("INSPECT_READY")
f:SetScript("OnEvent", function(_, event, guid)
  local unit = UnitTokenFromGUID(guid)
  if unit and UnitGUID(unit) == guid then
    capture(unit, "inspect:" .. tostring(UnitName(unit)))
    ClearInspectPlayer()
  end
end)
