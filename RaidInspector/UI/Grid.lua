local addonName, ns = ...

local Grid = {}
ns.Grid = Grid

-- The grid is player rows by gear-slot columns. Cells are pooled and only the
-- row whose data just arrived is redrawn; the grid is never rebuilt per event.

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

-- Four states, distinguished by glyph as well as colour. Red against green is
-- unreadable for a good share of players, so colour is never the only channel.
local STATE_STYLE = {
  ok      = { r = 0.16, g = 0.50, b = 0.24, glyph = "",  text = { 1, 1, 1 } },
  warn    = { r = 0.62, g = 0.47, b = 0.05, glyph = "!", text = { 1, 0.95, 0.7 } },
  bad     = { r = 0.60, g = 0.15, b = 0.15, glyph = "\226\156\149", text = { 1, 0.85, 0.85 } },
  unknown = { r = 0.20, g = 0.20, b = 0.22, glyph = "?", text = { 0.6, 0.6, 0.65 } },
}

local ROW_HEIGHT   = 18
local CELL_SIZE    = 16
local CELL_GAP     = 2
local NAME_WIDTH   = 110
local ILVL_WIDTH   = 46
local SUMMARY_WIDTH = 52
local HEADER_HEIGHT = 46

local frame, scroll, content, coverageText
local rows = {}
local rowByGuid = {}
local sortMode = "issues"

local function gridWidth()
  return NAME_WIDTH + ILVL_WIDTH + (table.getn(SLOTS) * (CELL_SIZE + CELL_GAP)) + SUMMARY_WIDTH + 24
end

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

local function classColour(class)
  local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
  if c then return c.r, c.g, c.b end
  return 0.8, 0.8, 0.8
end

local function makeCell(parent, index)
  local cell = CreateFrame("Button", nil, parent)
  cell:SetSize(CELL_SIZE, CELL_SIZE)
  cell:SetPoint("LEFT", parent, "LEFT",
                NAME_WIDTH + ILVL_WIDTH + (index - 1) * (CELL_SIZE + CELL_GAP), 0)

  cell.bg = cell:CreateTexture(nil, "BACKGROUND")
  cell.bg:SetAllPoints()

  cell.glyph = cell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  cell.glyph:SetPoint("CENTER")

  cell:SetScript("OnEnter", function(self)
    if not self.tooltipLines or table.getn(self.tooltipLines) == 0 then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    for i = 1, table.getn(self.tooltipLines) do
      GameTooltip:AddLine(self.tooltipLines[i], 1, 1, 1, true)
    end
    GameTooltip:Show()
  end)
  cell:SetScript("OnLeave", function() GameTooltip:Hide() end)

  return cell
end

local function makeRow(index)
  local row = CreateFrame("Button", nil, content)
  row:SetSize(gridWidth(), ROW_HEIGHT)
  row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)

  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.name:SetPoint("LEFT", row, "LEFT", 4, 0)
  row.name:SetWidth(NAME_WIDTH - 8)
  row.name:SetJustifyH("LEFT")

  row.ilvl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.ilvl:SetPoint("LEFT", row, "LEFT", NAME_WIDTH, 0)
  row.ilvl:SetWidth(ILVL_WIDTH - 6)
  row.ilvl:SetJustifyH("LEFT")

  row.cells = {}
  for i = 1, table.getn(SLOTS) do
    row.cells[i] = makeCell(row, i)
  end

  row.summary = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.summary:SetPoint("LEFT", row, "LEFT",
                       NAME_WIDTH + ILVL_WIDTH + table.getn(SLOTS) * (CELL_SIZE + CELL_GAP) + 6, 0)
  row.summary:SetWidth(SUMMARY_WIDTH)
  row.summary:SetJustifyH("LEFT")

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
  local style = STATE_STYLE[state] or STATE_STYLE.unknown
  local alpha = stale and 0.40 or 1
  cell.bg:SetColorTexture(style.r, style.g, style.b, alpha)
  cell.glyph:SetText(style.glyph)
  cell.glyph:SetTextColor(style.text[1], style.text[2], style.text[3], alpha)
  cell.tooltipLines = lines
end

-- One row's worth of work. Called for a single player when their scan lands,
-- never for the whole grid.
function Grid.updateRow(index, entry)
  local row = acquireRow(index)
  row.guid = entry.guid
  row:Show()

  local r, g, b = classColour(entry.class)
  -- Class colour stays muted: the cells are the dominant channel and two loud
  -- colour scales fighting each other makes the grid unreadable.
  row.name:SetText(entry.name or "?")
  row.name:SetTextColor(r * 0.75 + 0.25, g * 0.75 + 0.25, b * 0.75 + 0.25)

  row.ilvl:SetText(entry.ilvl and string.format("%.1f", entry.ilvl) or "-")

  for i = 1, table.getn(SLOTS) do
    local slot = SLOTS[i]
    local slotInfo = entry.slots and entry.slots[slot]
    local state = slotInfo and slotInfo.state or "unknown"
    local lines = nil
    if slotInfo and slotInfo.findings and table.getn(slotInfo.findings) > 0 then
      lines = { SLOT_NAMES[slot] or ("Slot " .. slot) }
      for j = 1, table.getn(slotInfo.findings) do
        local f = slotInfo.findings[j]
        lines[table.getn(lines) + 1] = "- " .. f.detail
      end
    elseif state == "unknown" then
      lines = { SLOT_NAMES[slot] or ("Slot " .. slot), "- not scanned yet" }
    end
    styleCell(row.cells[i], state, entry.stale, lines)
  end

  if entry.errors > 0 then
    row.summary:SetText(string.format("|cffff4444%d|r", entry.errors))
  elseif entry.warnings > 0 then
    row.summary:SetText(string.format("|cffffcc00%d|r", entry.warnings))
  elseif entry.unknowns > 0 then
    row.summary:SetText(string.format("|cff888888%d?|r", entry.unknowns))
  else
    row.summary:SetText("|cff44cc44ok|r")
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

  content:SetHeight(math.max(1, table.getn(entries) * ROW_HEIGHT))

  -- The build-up phase is called out explicitly. Without it the first couple of
  -- minutes of a mostly-grey grid reads as a broken addon.
  if coverage.confirmed < coverage.total and coverage.confirmed == 0 then
    coverageText:SetText(string.format("|cffffcc00Scanning|r  %d/%d confirmed",
                                       coverage.confirmed, coverage.total))
  else
    local text = string.format("%d/%d confirmed", coverage.confirmed, coverage.total)
    if table.getn(coverage.unreachableNames) > 0 then
      text = text .. string.format("  |cff888888%d out of range: %s|r",
             table.getn(coverage.unreachableNames),
             table.concat(coverage.unreachableNames, ", "))
    end
    coverageText:SetText(text)
  end
end

function Grid.create()
  if frame then return frame end

  frame = CreateFrame("Frame", "RaidInspectorGrid", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(gridWidth() + 20, HEADER_HEIGHT + 30 * ROW_HEIGHT + 20)
  frame:SetPoint("CENTER")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetClampedToScreen(true)
  frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.title:SetPoint("TOP", frame, "TOP", 0, -5)
  frame.title:SetText("Raid Inspector")

  coverageText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  coverageText:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -26)
  coverageText:SetJustifyH("LEFT")

  local header = CreateFrame("Frame", nil, frame)
  header:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -HEADER_HEIGHT + 12)
  header:SetSize(gridWidth(), 12)
  for i = 1, table.getn(SLOTS) do
    local label = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    label:SetPoint("LEFT", header, "LEFT",
                   NAME_WIDTH + ILVL_WIDTH + (i - 1) * (CELL_SIZE + CELL_GAP), 0)
    label:SetWidth(CELL_SIZE)
    label:SetJustifyH("CENTER")
    label:SetText(SLOT_ABBREV[SLOTS[i]] or "?")
  end

  scroll = CreateFrame("ScrollFrame", "RaidInspectorGridScroll", frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -HEADER_HEIGHT)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 12)

  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(gridWidth(), 1)
  scroll:SetScrollChild(content)

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
