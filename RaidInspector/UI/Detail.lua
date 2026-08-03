local addonName, ns = ...

local Detail = {}
ns.Detail = Detail

local SLOT_ORDER = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17 }

local SLOT_NAMES = {
  [1] = "Head", [2] = "Neck", [3] = "Shoulders", [5] = "Chest", [6] = "Waist",
  [7] = "Legs", [8] = "Feet", [9] = "Wrist", [10] = "Hands", [11] = "Finger 1",
  [12] = "Finger 2", [13] = "Trinket 1", [14] = "Trinket 2", [15] = "Back",
  [16] = "Main Hand", [17] = "Off Hand",
}

local STATE_COLOUR = {
  ok      = "|cff44cc44",
  warn    = "|cffffcc00",
  bad     = "|cffff4444",
  unknown = "|cff888888",
}

local frame, scroll, content, lines, titleText

local function acquireLine(index)
  if not lines[index] then
    local fs = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -(index - 1) * 14)
    fs:SetWidth(340)
    fs:SetJustifyH("LEFT")
    lines[index] = fs
  end
  return lines[index]
end

local function create()
  if frame then return end

  frame = CreateFrame("Frame", "RaidInspectorDetail", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(370, 400)
  frame:SetPoint("CENTER", UIParent, "CENTER", 320, 0)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetClampedToScreen(true)

  titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  titleText:SetPoint("TOP", frame, "TOP", 0, -5)

  scroll = CreateFrame("ScrollFrame", "RaidInspectorDetailScroll", frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -28)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 10)

  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(340, 1)
  scroll:SetScrollChild(content)

  lines = {}
  frame:Hide()
end

function Detail.show(guid)
  create()

  local entry = ns.Core and ns.Core.entryFor and ns.Core.entryFor(guid)
  if not entry then
    titleText:SetText("Raid Inspector")
    acquireLine(1):SetText("|cff888888no data for this player yet|r")
    for i = 2, table.getn(lines) do lines[i]:SetText("") end
    content:SetHeight(20)
    frame:Show()
    return
  end

  titleText:SetText(entry.name or "?")

  local n = 0
  local function addLine(text)
    n = n + 1
    acquireLine(n):SetText(text)
  end

  addLine(string.format("average item level: %s%s",
          entry.ilvl and string.format("%.1f", entry.ilvl) or "unknown",
          entry.stale and "   |cff888888(stale)|r" or ""))
  addLine(" ")

  for i = 1, table.getn(SLOT_ORDER) do
    local slot = SLOT_ORDER[i]
    local info = entry.slots and entry.slots[slot]
    local name = SLOT_NAMES[slot] or ("Slot " .. slot)

    if not info then
      addLine(string.format("|cff555555%-12s not scanned|r", name))
    else
      local colour = STATE_COLOUR[info.state] or STATE_COLOUR.unknown
      addLine(string.format("%s%-12s|r %s", colour, name, info.itemName or ""))
      if info.findings then
        for j = 1, table.getn(info.findings) do
          local f = info.findings[j]
          local c = (f.state == "unknown") and STATE_COLOUR.unknown
                    or ((f.severity == "error") and STATE_COLOUR.bad or STATE_COLOUR.warn)
          -- Unknown findings are shown here, unlike in the chat report: this is
          -- the view you open deliberately to understand one player, so "we do
          -- not know yet" is useful rather than noise.
          addLine(string.format("    %s%s|r  |cff666666(%s)|r", c, f.detail, f.state))
        end
      end
    end
  end

  for i = n + 1, table.getn(lines) do lines[i]:SetText("") end
  content:SetHeight(math.max(1, n * 14))
  frame:Show()
end

function Detail.hide()
  if frame then frame:Hide() end
end
