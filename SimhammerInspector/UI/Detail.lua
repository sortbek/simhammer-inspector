local addonName, ns = ...

local Detail = {}
ns.Detail = Detail

local SLOT_ORDER = ns.Policy.Slots.ALL

local SLOT_NAMES = ns.Policy.Slots.NAMES

local C = ns.Theme.colour
local MAX_EMB = ns.Policy.Season.MAX_EMBELLISHMENTS
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

  -- A child of the grid, flush against its right edge, rather than a window of
  -- its own. Three frames each finding their own spot on screen is not an
  -- interface; this one moves with the grid, closes with it, and leaves the
  -- roster visible while you read one player.
  local parent = ns.Grid.getFrame()

  frame = CreateFrame("Frame", "SimhammerInspectorDetail", parent)
  frame:SetWidth(WIDTH + 40)
  -- Minus one so the two panel borders land on top of each other and read as a
  -- single seam. At zero you get a two pixel double line; at anything positive
  -- it stops looking attached and starts looking like a second window that
  -- happens to be nearby.
  frame:SetPoint("TOPLEFT", parent, "TOPRIGHT", -1, 0)
  frame:SetPoint("BOTTOM", parent, "BOTTOM", 0, 0)
  frame:EnableMouse(true)
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
  -- Goes through the grid so the row highlight clears with it.
  close:SetScript("OnClick", function() ns.Grid.selectPlayer(nil) end)

  subText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  subText:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -32)
  subText:SetJustifyH("LEFT")
  ns.Theme.setText(subText, C.textMuted)

  scroll = CreateFrame("ScrollFrame", "SimhammerInspectorDetailScroll", frame,
                       "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -50)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 12)

  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(WIDTH, 1)
  scroll:SetScrollChild(content)

  frame:Hide()
end

function Detail.show(guid)
  if not guid then Detail.hide() return end
  create()

  local entry = ns.Core and ns.Core.entryFor and ns.Core.entryFor(guid)
  if not entry then
    titleText:SetText("Simhammer Inspector")
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
      embText = string.format("embellishments %d of %d  (%d/%d slots readable)",
                              emb.found, MAX_EMB, emb.known, emb.total)
    else
      embText = string.format("embellishments %d of %d", emb.found, MAX_EMB)
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
    local c = ns.Theme.findingColour(f)
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
