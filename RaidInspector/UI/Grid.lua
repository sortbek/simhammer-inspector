local addonName, ns = ...

local Grid = {}
ns.Grid = Grid

-- Player rows by gear-slot columns. Cells are pooled and only the row whose data
-- just arrived is redrawn; the grid is never rebuilt per event.

local SLOTS = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17 }

local SLOT_ABBREV = {
  [1] = "Hd", [2] = "Nk", [3] = "Sh", [15] = "Bk", [5] = "Ch", [9] = "Wr",
  [10] = "Hn", [6] = "Ws", [7] = "Lg", [8] = "Ft", [11] = "R1", [12] = "R2",
  [13] = "T1", [14] = "T2", [16] = "MH", [17] = "OH",
}

local SLOT_NAMES = {
  [1] = "Head", [2] = "Neck", [3] = "Shoulders", [5] = "Chest", [6] = "Waist",
  [7] = "Legs", [8] = "Feet", [9] = "Wrist", [10] = "Hands", [11] = "Finger 1",
  [12] = "Finger 2", [13] = "Trinket 1", [14] = "Trinket 2", [15] = "Back",
  [16] = "Main Hand", [17] = "Off Hand",
}

local M = ns.Theme.metrics
local C = ns.Theme.colour

local frame, scroll, content, coverageText, subText, sortButton
local rows = {}
local sortMode = "issues"
local lastEntries, lastCoverage

local function gridWidth()
  return M.nameWidth + M.ilvlWidth + M.embWidth
         + (table.getn(SLOTS) * (M.cellSize + M.cellGap))
         + M.summaryWidth
end

local function cellX(index)
  return M.nameWidth + M.ilvlWidth + M.embWidth + (index - 1) * (M.cellSize + M.cellGap)
end

local function makeCell(parent, index)
  local cell = CreateFrame("Button", nil, parent)
  cell:SetSize(M.cellSize, M.cellSize)
  cell:SetPoint("LEFT", parent, "LEFT", cellX(index), 0)

  cell.fill = cell:CreateTexture(nil, "ARTWORK")
  cell.fill:SetAllPoints()

  -- A one pixel inner edge gives each state a distinct silhouette, so the grid
  -- still parses at a glance when the colours are close in value.
  cell.edge = cell:CreateTexture(nil, "OVERLAY")
  cell.edge:SetPoint("TOPLEFT")
  cell.edge:SetPoint("TOPRIGHT")
  cell.edge:SetHeight(1)

  cell.glyph = cell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  cell.glyph:SetPoint("CENTER", 0, 0)

  cell:SetScript("OnEnter", function(self)
    if self:GetParent().hover then
      self:GetParent().hover:Show()
    end
    if not self.tooltipLines or table.getn(self.tooltipLines) == 0 then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(self.tooltipLines[1], 1, 1, 1)
    for i = 2, table.getn(self.tooltipLines) do
      local line = self.tooltipLines[i]
      GameTooltip:AddLine(line.text, line.r, line.g, line.b, true)
    end
    GameTooltip:Show()
  end)

  cell:SetScript("OnLeave", function(self)
    if self:GetParent().hover then self:GetParent().hover:Hide() end
    GameTooltip:Hide()
  end)

  cell:SetScript("OnClick", function(self)
    local row = self:GetParent()
    if row.guid and ns.Detail then ns.Detail.show(row.guid) end
  end)

  return cell
end

local function makeRow(index)
  local row = CreateFrame("Button", nil, content)
  row:SetSize(gridWidth(), M.rowHeight)
  row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(index - 1) * M.rowHeight)

  row.stripe = row:CreateTexture(nil, "BACKGROUND")
  row.stripe:SetAllPoints()

  row.hover = row:CreateTexture(nil, "BORDER")
  row.hover:SetAllPoints()
  row.hover:SetColorTexture(C.rowHover[1], C.rowHover[2], C.rowHover[3], C.rowHover[4])
  row.hover:Hide()

  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.name:SetPoint("LEFT", row, "LEFT", 8, 0)
  row.name:SetWidth(M.nameWidth - 12)
  row.name:SetJustifyH("LEFT")

  row.ilvl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.ilvl:SetPoint("LEFT", row, "LEFT", M.nameWidth, 0)
  row.ilvl:SetWidth(M.ilvlWidth - 8)
  row.ilvl:SetJustifyH("LEFT")

  -- Embellishments get their own column rather than living inside a per-slot
  -- cell: the cap is two across the whole character, so it is a property of the
  -- player, and every raider is expected to be at 2 of 2.
  row.emb = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.emb:SetPoint("LEFT", row, "LEFT", M.nameWidth + M.ilvlWidth, 0)
  row.emb:SetWidth(M.embWidth - 6)
  row.emb:SetJustifyH("LEFT")

  row.cells = {}
  for i = 1, table.getn(SLOTS) do
    row.cells[i] = makeCell(row, i)
  end

  row.summary = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.summary:SetPoint("LEFT", row, "LEFT", cellX(table.getn(SLOTS) + 1) + 4, 0)
  row.summary:SetWidth(M.summaryWidth)
  row.summary:SetJustifyH("LEFT")

  row:SetScript("OnEnter", function(self) self.hover:Show() end)
  row:SetScript("OnLeave", function(self) self.hover:Hide() end)
  row:SetScript("OnClick", function(self)
    if self.guid and ns.Detail then ns.Detail.show(self.guid) end
  end)

  return row
end

local function acquireRow(index)
  if not rows[index] then rows[index] = makeRow(index) end
  return rows[index]
end

local function styleCell(cell, state, stale, lines)
  local style = ns.Theme.state[state] or ns.Theme.state.unknown
  local a = stale and ns.Theme.STALE_ALPHA or 1

  cell.fill:SetColorTexture(style.fill[1], style.fill[2], style.fill[3], style.fill[4] * a)
  cell.edge:SetColorTexture(style.edge[1], style.edge[2], style.edge[3], style.edge[4] * a)
  cell.glyph:SetText(style.glyph)
  cell.glyph:SetTextColor(style.glyphColour[1], style.glyphColour[2], style.glyphColour[3], a)
  cell.tooltipLines = lines
end

local SEVERITY_COLOUR = {
  error = { 0.93, 0.31, 0.31 },
  warn  = { 0.92, 0.70, 0.18 },
}

local function tooltipFor(slot, slotInfo, state)
  local name = SLOT_NAMES[slot] or ("Slot " .. slot)

  if not slotInfo or state == "empty" then
    return { name, { text = "nothing equipped", r = 0.5, g = 0.5, b = 0.5 } }
  end

  local lines = { name }
  if slotInfo.itemName then
    lines[2] = { text = slotInfo.itemName, r = 0.62, g = 0.66, b = 0.74 }
  end

  if slotInfo.findings and table.getn(slotInfo.findings) > 0 then
    for i = 1, table.getn(slotInfo.findings) do
      local f = slotInfo.findings[i]
      local c = (f.state == "unknown") and { 0.45, 0.47, 0.52 }
                or (SEVERITY_COLOUR[f.severity] or SEVERITY_COLOUR.warn)
      lines[table.getn(lines) + 1] = { text = f.detail, r = c[1], g = c[2], b = c[3] }
    end
  elseif state == "unknown" then
    lines[table.getn(lines) + 1] =
      { text = "not scanned yet", r = 0.45, g = 0.47, b = 0.52 }
  end

  return lines
end

function Grid.updateRow(index, entry)
  local row = acquireRow(index)
  row.guid = entry.guid
  row:Show()

  local stripe = (index % 2 == 1) and C.rowOdd or C.rowEven
  row.stripe:SetColorTexture(stripe[1], stripe[2], stripe[3], stripe[4])

  local r, g, b = ns.Theme.mutedClassColour(entry.class)
  row.name:SetText(entry.name or "?")
  row.name:SetTextColor(r, g, b, entry.stale and 0.55 or 1)

  if entry.ilvl then
    row.ilvl:SetText(string.format("%.1f", entry.ilvl))
    ns.Theme.setText(row.ilvl, C.textPrimary)
  else
    row.ilvl:SetText("--")
    ns.Theme.setText(row.ilvl, C.textFaint)
  end

  local emb = entry.embellishments
  if not emb or emb.total == 0 then
    row.emb:SetText("--")
    ns.Theme.setText(row.emb, C.textFaint)
  elseif emb.known < emb.total and emb.found < 2 then
    -- Some slot could not be read, so the count is a floor rather than a total.
    row.emb:SetText(emb.found .. "/2?")
    ns.Theme.setText(row.emb, C.textFaint)
  elseif emb.found >= 2 then
    row.emb:SetText("2/2")
    row.emb:SetTextColor(0.36, 0.74, 0.46)
  else
    row.emb:SetText(emb.found .. "/2")
    row.emb:SetTextColor(0.92, 0.70, 0.18)
  end

  for i = 1, table.getn(SLOTS) do
    local slot = SLOTS[i]
    local slotInfo = entry.slots and entry.slots[slot]
    local state = slotInfo and slotInfo.state or "unknown"
    styleCell(row.cells[i], state, entry.stale, tooltipFor(slot, slotInfo, state))
  end

  if entry.errors > 0 then
    row.summary:SetText(tostring(entry.errors))
    row.summary:SetTextColor(0.93, 0.31, 0.31)
  elseif entry.warnings > 0 then
    row.summary:SetText(tostring(entry.warnings))
    row.summary:SetTextColor(0.92, 0.70, 0.18)
  elseif entry.unknowns > 0 then
    row.summary:SetText(tostring(entry.unknowns) .. "?")
    row.summary:SetTextColor(0.40, 0.42, 0.48)
  else
    row.summary:SetText("\226\156\147")
    row.summary:SetTextColor(0.36, 0.74, 0.46)
  end
end

-- Fresh unknown must never sort below stale bad: an old red cell is a weaker
-- claim than a current grey one, and sorting on severity alone hides that.
local function comparator(a, b)
  if a.stale ~= b.stale then return b.stale end
  if a.errors ~= b.errors then return a.errors > b.errors end
  if a.warnings ~= b.warnings then return a.warnings > b.warnings end
  if a.unknowns ~= b.unknowns then return a.unknowns > b.unknowns end
  return (a.name or "") < (b.name or "")
end

function Grid.refresh(entries, coverage)
  if not frame then return end
  lastEntries, lastCoverage = entries, coverage

  if sortMode == "issues" then
    table.sort(entries, comparator)
  else
    table.sort(entries, function(a, b) return (a.name or "") < (b.name or "") end)
  end

  for i = 1, table.getn(entries) do
    Grid.updateRow(i, entries[i])
  end
  for i = table.getn(entries) + 1, table.getn(rows) do
    rows[i]:Hide()
  end

  content:SetHeight(math.max(1, table.getn(entries) * M.rowHeight))

  local visibleRows = math.min(math.max(table.getn(entries), 4), 25)
  frame:SetHeight(M.headerHeight + visibleRows * M.rowHeight + M.padding * 2)

  -- The build-up phase is called out explicitly. Without it the first couple of
  -- minutes of a mostly-grey grid reads as a broken addon.
  local scanning = coverage.confirmed < coverage.total
  if scanning and coverage.confirmed == 0 then
    coverageText:SetText("Scanning")
    coverageText:SetTextColor(0.92, 0.70, 0.18)
  else
    coverageText:SetText(string.format("%d / %d confirmed", coverage.confirmed, coverage.total))
    if scanning then
      coverageText:SetTextColor(0.92, 0.70, 0.18)
    else
      coverageText:SetTextColor(0.36, 0.74, 0.46)
    end
  end

  -- "not answering", not "out of range": a timeout means no reply arrived, and
  -- the cause may be distance or a dropped request. Claiming a cause the addon
  -- cannot establish is the mistake the evidence model exists to prevent.
  if table.getn(coverage.unreachableNames) > 0 then
    subText:SetText(string.format("%d not answering: %s",
                    table.getn(coverage.unreachableNames),
                    table.concat(coverage.unreachableNames, ", ")))
  else
    subText:SetText("")
  end
end

local function buildHeader()
  local header = CreateFrame("Frame", nil, frame)
  header:SetPoint("TOPLEFT", frame, "TOPLEFT", M.padding, -M.headerHeight + 16)
  header:SetSize(gridWidth(), 14)

  local function label(text, x, width)
    local fs = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetPoint("LEFT", header, "LEFT", x, 0)
    fs:SetWidth(width)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    ns.Theme.setText(fs, C.textFaint)
    return fs
  end

  label("PLAYER", 8, M.nameWidth)
  label("ILVL", M.nameWidth, M.ilvlWidth)
  label("EMB", M.nameWidth + M.ilvlWidth, M.embWidth)

  for i = 1, table.getn(SLOTS) do
    local fs = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetPoint("LEFT", header, "LEFT", cellX(i), 0)
    fs:SetWidth(M.cellSize)
    fs:SetJustifyH("CENTER")
    fs:SetText(SLOT_ABBREV[SLOTS[i]] or "?")
    ns.Theme.setText(fs, C.textFaint)
  end

  local divider = frame:CreateTexture(nil, "ARTWORK")
  divider:SetPoint("TOPLEFT", frame, "TOPLEFT", M.padding, -M.headerHeight + 4)
  divider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -M.padding, -M.headerHeight + 4)
  divider:SetHeight(1)
  divider:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], C.divider[4])
end

function Grid.create()
  if frame then return frame end

  frame = CreateFrame("Frame", "RaidInspectorGrid", UIParent)
  frame:SetSize(gridWidth() + M.padding * 2 + 22,
                M.headerHeight + 20 * M.rowHeight + M.padding * 2)
  frame:SetPoint("CENTER")
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

  local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("LEFT", titleBar, "LEFT", M.padding, 0)
  title:SetText("Raid Inspector")
  ns.Theme.setText(title, C.textPrimary)

  local close = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
  close:SetPoint("RIGHT", titleBar, "RIGHT", -2, 0)
  close:SetSize(24, 24)
  -- The template's default handler hides its own parent, which here is the title
  -- bar rather than the window. Close the window explicitly.
  close:SetScript("OnClick", function() frame:Hide() end)

  sortButton = CreateFrame("Button", nil, titleBar)
  sortButton:SetSize(78, 16)
  sortButton:SetPoint("RIGHT", close, "LEFT", -6, 0)
  sortButton.text = sortButton:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  sortButton.text:SetAllPoints()
  sortButton.text:SetJustifyH("RIGHT")
  sortButton.text:SetText("sort: issues")
  ns.Theme.setText(sortButton.text, C.textMuted)
  sortButton:SetScript("OnClick", function(self)
    sortMode = (sortMode == "issues") and "name" or "issues"
    self.text:SetText("sort: " .. sortMode)
    if lastEntries then Grid.refresh(lastEntries, lastCoverage) end
  end)
  sortButton:SetScript("OnEnter", function(self) ns.Theme.setText(self.text, C.accent) end)
  sortButton:SetScript("OnLeave", function(self) ns.Theme.setText(self.text, C.textMuted) end)

  coverageText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  coverageText:SetPoint("TOPLEFT", frame, "TOPLEFT", M.padding, -32)
  coverageText:SetJustifyH("LEFT")

  subText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  subText:SetPoint("TOPLEFT", frame, "TOPLEFT", M.padding, -46)
  subText:SetPoint("RIGHT", frame, "RIGHT", -M.padding, 0)
  subText:SetJustifyH("LEFT")
  ns.Theme.setText(subText, C.textFaint)

  buildHeader()

  scroll = CreateFrame("ScrollFrame", "RaidInspectorGridScroll", frame,
                       "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", M.padding, -M.headerHeight)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -26, M.padding)

  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(gridWidth(), 1)
  scroll:SetScrollChild(content)

  -- Escape closes it, the way every other WoW panel behaves.
  tinsert(UISpecialFrames, "RaidInspectorGrid")

  frame:Hide()
  return frame
end

function Grid.toggle()
  Grid.create()
  if frame:IsShown() then frame:Hide() else frame:Show() end
  return frame:IsShown()
end

function Grid.isShown()
  return frame and frame:IsShown()
end
