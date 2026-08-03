local addonName, ns = ...

RaidInspectorSpikeDB = RaidInspectorSpikeDB or {}

-- The sixteen checked slots, in the order used by the spec.
local SLOTS = {
  1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17,
}

local function dumpGlobalString()
  return {
    exists = (ITEM_UPGRADE_TOOLTIP_FORMAT_STRING ~= nil),
    value  = ITEM_UPGRADE_TOOLTIP_FORMAT_STRING,
  }
end

-- Compares the candidate APIs for socket count on the same item. Which one
-- works for other players' gear is exactly what this spike has to establish.
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
    result.fromGetItemNumSockets = ok and v or ("error: " .. tostring(v))
  else
    result.fromGetItemNumSockets = "API does not exist"
  end

  if C_Item.GetItemNumAddedSockets then
    local ok, v = pcall(C_Item.GetItemNumAddedSockets, link)
    result.fromGetItemNumAddedSockets = ok and v or ("error: " .. tostring(v))
  else
    result.fromGetItemNumAddedSockets = "API does not exist"
  end

  return result
end

local function tooltipLines(link)
  if not C_TooltipInfo or not C_TooltipInfo.GetHyperlink then
    return { error = "C_TooltipInfo.GetHyperlink does not exist" }
  end
  local data = C_TooltipInfo.GetHyperlink(link)
  if not data then return { error = "no tooltip data" } end

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
  print(string.format("Spike: captured %s (%d slots).", label, count))
end

SLASH_RISPIKE1 = "/rispike"
SlashCmdList["RISPIKE"] = function(msg)
  if msg == "wipe" then
    RaidInspectorSpikeDB = {}
    print("Spike: database cleared.")
    return
  end
  if msg == "target" then
    if not UnitExists("target") then print("Spike: no target."); return end
    if not CanInspect("target") then print("Spike: cannot inspect this target."); return end
    NotifyInspect("target")
    print("Spike: inspect requested, waiting for INSPECT_READY.")
    return
  end
  capture("player", "player")
end

local f = CreateFrame("Frame")
f:RegisterEvent("INSPECT_READY")
f:SetScript("OnEvent", function(_, event, guid)
  -- UnitTokenFromGUID is documented as unstable, so verify the token still
  -- points at the GUID we asked about before reading anything off it.
  local unit = UnitTokenFromGUID(guid)
  if unit and UnitGUID(unit) == guid then
    capture(unit, "inspect:" .. tostring(UnitName(unit)))
    ClearInspectPlayer()
  end
end)
