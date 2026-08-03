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

local C = ns.Theme.colour
local ROW_H = 15
local WIDTH = 330

local frame, scroll, content, titleText, subText
local slotRows = {}

local function acquireRow(index)
  if not slotRows[index] then
    local row = CreateFrame("Frame", nil, content)
    row:SetSize(WIDTH, ROW_H)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(index - 1) * ROW_H)

    row.marker = row:CreateTexture(nil, "ARTWORK")
    row.marker:SetSize(3, ROW_H - 4)
    row.marker:SetPoint("LEFT", row, "LEFT", 0, 0)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ROW_H - 3, ROW_H - 3)
    row.icon:SetPoint("LEFT", row, "LEFT", 9, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    row.slot = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.slot:SetPoint("LEFT", row, "LEFT", 9, 0)
    row.slot:SetWidth(64)
    row.slot:SetJustifyH("LEFT")

    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", row, "LEFT", 78, 0)
    row.label:SetJustifyH("LEFT")

    slotRows[index] = row
  end
  return slotRows[index]
end

local function create()
  if frame then return end

  frame = CreateFrame("Frame", "RaidInspectorDetail", UIParent)
  frame:SetSize(WIDTH + 40, 420)
  frame:SetPoint("CENTER", UIParent, "CENTER", 340, 0)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetClampedToScreen(true)
  frame:SetFrameStrata("HIGH")
  ns.Theme.panel(frame)

  local titleBar = CreateFrame("Frame", nil, frame)
  titleBar:SetPoint("TOPLEFT")
  titleBar:SetPoint("TOPRIGHT")
  titleBar:SetHeight(26)
  ns.Theme.panel(titleBar, C.header)

  titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  titleText:SetPoint("LEFT", titleBar, "LEFT", 12, 0)
  ns.Theme.setText(titleText, C.textPrimary)

  local close = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
  close:SetPoint("RIGHT", titleBar, "RIGHT", -2, 0)
  close:SetSize(24, 24)
  -- The template's default handler hides its own parent, which here is the title
  -- bar rather than the window. Close the window explicitly.
  close:SetScript("OnClick", function() frame:Hide() end)

  subText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  subText:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -32)
  subText:SetJustifyH("LEFT")
  ns.Theme.setText(subText, C.textMuted)

  scroll = CreateFrame("ScrollFrame", "RaidInspectorDetailScroll", frame,
                       "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -50)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 12)

  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(WIDTH, 1)
  scroll:SetScrollChild(content)

  -- Escape closes it, the way every other WoW panel behaves.
  tinsert(UISpecialFrames, "RaidInspectorDetail")

  frame:Hide()
end

local SEVERITY = {
  error = { 0.93, 0.31, 0.31 },
  warn  = { 0.92, 0.70, 0.18 },
}

function Detail.show(guid)
  create()

  local entry = ns.Core and ns.Core.entryFor and ns.Core.entryFor(guid)
  if not entry then
    titleText:SetText("Raid Inspector")
    subText:SetText("no data for this player yet")
    for i = 1, table.getn(slotRows) do slotRows[i]:Hide() end
    frame:Show()
    return
  end

  local r, g, b = ns.Theme.mutedClassColour(entry.class)
  titleText:SetText(entry.name or "?")
  titleText:SetTextColor(r, g, b)

  local emb = entry.embellishments
  local embText = "embellishments unknown"
  if emb then
    if emb.known < emb.total then
      embText = string.format("embellishments %d of 2  (%d/%d slots readable)",
                              emb.found, emb.known, emb.total)
    else
      embText = string.format("embellishments %d of 2", emb.found)
    end
  end

  subText:SetText(string.format("item level %s     %s%s",
                  entry.ilvl and string.format("%.1f", entry.ilvl) or "unknown",
                  embText,
                  entry.stale and "     stale" or ""))

  local n = 0

  local function itemRow(slotName, info)
    n = n + 1
    local it = acquireRow(n)
    it:Show()

    local marker = ns.Theme.state[info and info.state or "unknown"]
    if marker then
      it.marker:SetColorTexture(marker.edge[1], marker.edge[2], marker.edge[3], 0.9)
      it.marker:Show()
    else
      it.marker:Hide()
    end

    if info and info.icon then
      it.icon:SetTexture(info.icon)
      it.icon:Show()
      it.slot:Hide()
      it.label:SetPoint("LEFT", it, "LEFT", 30, 0)
      it.label:SetText(string.format("%s  |cff70747e%s|r", info.itemName or "?", slotName))
    else
      it.icon:Hide()
      it.slot:Show()
      it.slot:SetText(slotName)
      it.label:SetPoint("LEFT", it, "LEFT", 78, 0)
      it.label:SetText(info and info.itemName or "not scanned")
    end

    local q = info and info.quality and ns.Theme.quality[info.quality]
    if q and info.icon then
      it.label:SetTextColor(q[1], q[2], q[3])
    else
      it.label:SetTextColor(C.textFaint[1], C.textFaint[2], C.textFaint[3])
    end
  end

  local function findingRow(f)
    n = n + 1
    local it = acquireRow(n)
    it:Show()
    it.marker:Hide()
    it.icon:Hide()
    it.slot:Hide()
    it.label:SetPoint("LEFT", it, "LEFT", 32, 0)
    -- Unknown findings appear here, unlike in the chat report: this view is
    -- opened deliberately to understand one player, so "we do not know yet" is
    -- useful rather than noise.
    local c = (f.state == "unknown") and { 0.42, 0.44, 0.50 }
              or (SEVERITY[f.severity] or SEVERITY.warn)
    it.label:SetText("\226\128\162  " .. f.detail)
    it.label:SetTextColor(c[1], c[2], c[3])
  end

  for i = 1, table.getn(SLOT_ORDER) do
    local slot = SLOT_ORDER[i]
    local info = entry.slots and entry.slots[slot]
    itemRow(SLOT_NAMES[slot] or ("Slot " .. slot), info)

    if info and info.findings then
      for j = 1, table.getn(info.findings) do
        findingRow(info.findings[j])
      end
    end
  end

  if entry.playerFindings then
    for i = 1, table.getn(entry.playerFindings) do
      findingRow(entry.playerFindings[i])
    end
  end

  for i = n + 1, table.getn(slotRows) do slotRows[i]:Hide() end
  content:SetHeight(math.max(1, n * ROW_H))
  frame:Show()
end

function Detail.hide()
  if frame then frame:Hide() end
end
