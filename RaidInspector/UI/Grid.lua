local addonName, ns = ...

local Grid = {}
ns.Grid = Grid

-- Player rows by gear-slot columns. Cells are pooled and only the row whose data
-- just arrived is redrawn; the grid is never rebuilt per event.

local SLOTS = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17 }

-- Blizzard's own inventory slot names, used to ask the client for each slot's
-- icon. Going through GetInventorySlotInfo rather than hardcoding texture paths
-- means the icons stay correct if Blizzard moves the art.
local SLOT_FRAME_NAMES = {
  [1] = "HeadSlot", [2] = "NeckSlot", [3] = "ShoulderSlot", [15] = "BackSlot",
  [5] = "ChestSlot", [9] = "WristSlot", [10] = "HandsSlot", [6] = "WaistSlot",
  [7] = "LegsSlot", [8] = "FeetSlot", [11] = "Finger0Slot", [12] = "Finger1Slot",
  [13] = "Trinket0Slot", [14] = "Trinket1Slot", [16] = "MainHandSlot",
  [17] = "SecondaryHandSlot",
}

local SLOT_NAMES = {
  [1] = "Head", [2] = "Neck", [3] = "Shoulders", [5] = "Chest", [6] = "Waist",
  [7] = "Legs", [8] = "Feet", [9] = "Wrist", [10] = "Hands", [11] = "Finger 1",
  [12] = "Finger 2", [13] = "Trinket 1", [14] = "Trinket 2", [15] = "Back",
  [16] = "Main Hand", [17] = "Off Hand",
}

local M = ns.Theme.metrics
local C = ns.Theme.colour

local frame, content, coverageText, subText, totalsText, sortButton
local rows = {}
local sortMode = "issues"
local lastEntries, lastCoverage
local selectedGuid

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
    if row.guid then Grid.selectPlayer(row.guid) end
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

  -- A single inspect takes roughly a second, so which player is being read is
  -- worth showing: it makes the wait legible instead of looking stalled.
  row.scanning = row:CreateTexture(nil, "ARTWORK")
  row.scanning:SetSize(3, M.rowHeight - 4)
  row.scanning:SetPoint("LEFT", row, "LEFT", 0, 0)
  row.scanning:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.9)
  row.scanning:Hide()

  -- Class and role read faster as icons than as a colour alone, and a raid
  -- leader scanning twenty rows is looking for "which healer" as often as
  -- "which name".
  row.classIcon = row:CreateTexture(nil, "ARTWORK")
  row.classIcon:SetSize(M.iconSize, M.iconSize)
  row.classIcon:SetPoint("LEFT", row, "LEFT", 6, 0)
  row.classIcon:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")

  row.roleIcon = row:CreateTexture(nil, "ARTWORK")
  row.roleIcon:SetSize(M.iconSize, M.iconSize)
  row.roleIcon:SetPoint("LEFT", row.classIcon, "RIGHT", 3, 0)
  row.roleIcon:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-ROLES")

  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.name:SetPoint("LEFT", row.roleIcon, "RIGHT", 5, 0)
  row.name:SetWidth(M.nameWidth - (M.iconSize * 2) - 20)
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

  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnEnter", function(self) self.hover:Show() end)
  row:SetScript("OnLeave", function(self) self.hover:Hide() end)
  row:SetScript("OnClick", function(self, button)
    if not self.guid then return end
    if button == "RightButton" then
      Grid.composeWhisper(self.guid)
    else
      Grid.selectPlayer(self.guid)
    end
  end)

  return row
end

-- Puts the player's issues into the chat box addressed to them, without
-- sending. Telling twenty people what to fix is the actual job; typing it out
-- is not. Sending on a click would be a message going out on a mis-click, so
-- the last keypress stays with the user.
function Grid.composeWhisper(guid)
  local entry = ns.Core and ns.Core.entryFor and ns.Core.entryFor(guid)
  if not entry then return end

  local parts = {}
  for slot, info in pairs(entry.slots or {}) do
    if info.findings then
      for i = 1, table.getn(info.findings) do
        local f = info.findings[i]
        if f.state == "bad" then
          parts[table.getn(parts) + 1] = (SLOT_NAMES[slot] or ("slot " .. slot))
                                         .. ": " .. f.detail
        end
      end
    end
  end
  for i = 1, table.getn(entry.playerFindings or {}) do
    local f = entry.playerFindings[i]
    if f.state == "bad" then
      parts[table.getn(parts) + 1] = f.detail
    end
  end

  if table.getn(parts) == 0 then
    print("|cff33ff99RaidInspector|r " .. (entry.name or "?") .. " has nothing to fix.")
    return
  end

  local target = entry.name
  if entry.realm and entry.realm ~= "" then target = target .. "-" .. entry.realm end

  ChatFrame_OpenChat("/w " .. target .. " gear check: " .. table.concat(parts, "; "),
                     DEFAULT_CHAT_FRAME)
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

  -- The selected row keeps a visible marker, otherwise the side panel shows
  -- someone's gear with no indication of who you clicked.
  if entry.guid == selectedGuid then
    row.stripe:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.16)
  else
    local stripe = (index % 2 == 1) and C.rowOdd or C.rowEven
    row.stripe:SetColorTexture(stripe[1], stripe[2], stripe[3], stripe[4])
  end

  local iconAlpha = entry.stale and 0.5 or 1

  local coords = entry.class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[entry.class]
  if coords then
    row.classIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    row.classIcon:SetAlpha(iconAlpha)
    row.classIcon:Show()
  else
    row.classIcon:Hide()
  end

  local role = ns.Theme.role[entry.role or ""]
  if role then
    row.roleIcon:SetTexCoord(role[1], role[2], role[3], role[4])
    row.roleIcon:SetAlpha(iconAlpha)
    row.roleIcon:Show()
  else
    row.roleIcon:Hide()
  end

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

  -- The window sizes to its content, so there is nothing to scroll. A raid caps
  -- at thirty and thirty rows still fit a 1080p screen, which is why the scroll
  -- frame that used to live here was dead weight taking up horizontal space.
  local visibleRows = math.min(math.max(table.getn(entries), 4), 30)
  content:SetHeight(math.max(1, visibleRows * M.rowHeight))
  frame:SetHeight(M.headerHeight + visibleRows * M.rowHeight + M.padding * 2)

  -- Totals first: the coverage line needs to know whether anything is wrong
  -- before it can decide what to say.
  local players, errors, warnings, missingEmb = 0, 0, 0, 0
  for i = 1, table.getn(entries) do
    local e = entries[i]
    errors = errors + e.errors
    warnings = warnings + e.warnings
    if e.errors > 0 or e.warnings > 0 then players = players + 1 end
    if e.embellishments and e.embellishments.known == e.embellishments.total
       and e.embellishments.total > 0 and e.embellishments.found < 2 then
      missingEmb = missingEmb + 1
    end
  end

  -- The build-up phase is called out explicitly. Without it the first couple of
  -- minutes of a mostly-grey grid reads as a broken addon.
  local scanning = coverage.confirmed < coverage.total
  if scanning and coverage.confirmed == 0 then
    coverageText:SetText("Scanning")
    coverageText:SetTextColor(0.92, 0.70, 0.18)
  else
    local text = string.format("%d / %d confirmed", coverage.confirmed, coverage.total)
    if scanning then
      coverageText:SetTextColor(0.92, 0.70, 0.18)
    else
      coverageText:SetTextColor(0.36, 0.74, 0.46)
      if errors == 0 and warnings == 0 then
        text = text .. "   \194\183   everyone is clean"
      end
    end
    coverageText:SetText(text)
  end

  -- The panel reads the same live data as the grid, so it has to follow along:
  -- a slot that gets confirmed while you are looking at it should update rather
  -- than sit there stale until you click away and back.
  if selectedGuid then ns.Detail.show(selectedGuid) end

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

  -- An aggregate line answers the question the grid cannot: how much work is
  -- there in total, and is it worth holding the pull for.
  local bits = {}
  if players > 0 then
    bits[table.getn(bits) + 1] = string.format("|cffe0e2e8%d|r players need attention", players)
  end
  if errors > 0 then
    bits[table.getn(bits) + 1] = string.format("|cffee5050%d|r errors", errors)
  end
  if warnings > 0 then
    bits[table.getn(bits) + 1] = string.format("|cffeab32e%d|r warnings", warnings)
  end
  if missingEmb > 0 then
    bits[table.getn(bits) + 1] = string.format("|cffeab32e%d|r short on embellishments", missingEmb)
  end

  -- When there is nothing wrong, the coverage line already says everything worth
  -- saying. A second green line underneath repeating it in other words is noise.
  if table.getn(bits) == 0 then
    totalsText:SetText("")
  else
    totalsText:SetText(table.concat(bits, "   \194\183   "))
  end
end

local function buildHeader()
  local header = CreateFrame("Frame", nil, frame)
  header:SetPoint("TOPLEFT", frame, "TOPLEFT", M.padding, -M.headerHeight + 18)
  header:SetSize(gridWidth(), 18)

  local function label(text, x, width)
    local fs = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetPoint("LEFT", header, "LEFT", x, 0)
    fs:SetWidth(width)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    ns.Theme.setText(fs, C.textFaint)
    return fs
  end

  label("PLAYER", 8, M.nameWidth - 8)
  label("ILVL", M.nameWidth, M.ilvlWidth)
  label("EMB", M.nameWidth + M.ilvlWidth, M.embWidth)

  -- Icons rather than two-letter abbreviations. The abbreviations had to be
  -- learned, and worse, wide pairs like "MH" did not fit the column and were
  -- silently ellipsised to "...". An icon is the same width whatever the slot.
  for i = 1, table.getn(SLOTS) do
    local slot = SLOTS[i]
    local hit = CreateFrame("Frame", nil, header)
    hit:SetSize(M.cellSize, M.cellSize)
    hit:SetPoint("LEFT", header, "LEFT", cellX(i), 0)

    local icon = hit:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local frameName = SLOT_FRAME_NAMES[slot]
    local texture = nil
    if frameName and GetInventorySlotInfo then
      local ok, _, tex = pcall(GetInventorySlotInfo, frameName)
      if ok then texture = tex end
    end

    if texture then
      icon:SetTexture(texture)
      -- Full colour at near-full opacity. Desaturating these at 55% made them
      -- unreadable against a dark panel, which defeated the point of using
      -- icons at all.
      icon:SetAlpha(0.85)
    else
      icon:Hide()
      local fs = hit:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      fs:SetAllPoints()
      fs:SetJustifyH("CENTER")
      fs:SetText("?")
      ns.Theme.setText(fs, C.textFaint)
    end

    hit:SetScript("OnEnter", function(self)
      icon:SetAlpha(1)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(SLOT_NAMES[slot] or ("Slot " .. slot))
      GameTooltip:Show()
    end)
    hit:SetScript("OnLeave", function()
      icon:SetAlpha(0.85)
      GameTooltip:Hide()
    end)
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
  frame:SetSize(gridWidth() + M.padding * 2,
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

  -- A toolbar rather than controls squeezed into the title bar: four of them
  -- there left no room for the title and made every one of them cryptic.
  local toolbar = CreateFrame("Frame", nil, frame)
  toolbar:SetPoint("TOPLEFT", frame, "TOPLEFT", M.padding, -30)
  toolbar:SetSize(gridWidth(), 18)

  local function place(button, previous)
    if previous then
      button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
    else
      button:SetPoint("LEFT", toolbar, "LEFT", 0, 0)
    end
    return button
  end

  local rescan = place(ns.Theme.button(toolbar, "Rescan", 62, function()
    ns.Scanner.rescanAll()
  end, "Priority pass over everyone in range. Best used while the raid is stacked before a pull."))

  local reset = place(ns.Theme.button(toolbar, "Reset", 54, function()
    ns.Core.resetScan()
  end, "Throw away everything collected and start over. The grid will be empty for a minute."), rescan)

  local report = place(ns.Theme.button(toolbar, "Report", 60, function()
    ns.Core.reportToChat()
  end, "Print the findings to chat."), reset)

  place(ns.Theme.button(toolbar, "SimC DPS", 72, function()
    ns.Core.exportSimc()
  end, "SimulationCraft profiles for every DPS, ready to paste."), report)

  sortButton = ns.Theme.button(toolbar, "sort: issues", 88, function(self)
    sortMode = (sortMode == "issues") and "name" or "issues"
    sortButton.text:SetText("sort: " .. sortMode)
    if lastEntries then Grid.refresh(lastEntries, lastCoverage) end
  end, "Order rows by severity, or alphabetically.")
  sortButton:SetPoint("RIGHT", toolbar, "RIGHT", 0, 0)

  coverageText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  coverageText:SetPoint("TOPLEFT", frame, "TOPLEFT", M.padding, -54)
  coverageText:SetJustifyH("LEFT")

  totalsText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  totalsText:SetPoint("TOPLEFT", frame, "TOPLEFT", M.padding, -70)
  totalsText:SetPoint("RIGHT", frame, "RIGHT", -M.padding, 0)
  totalsText:SetJustifyH("LEFT")

  subText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  subText:SetPoint("TOPLEFT", frame, "TOPLEFT", M.padding, -84)
  subText:SetPoint("RIGHT", frame, "RIGHT", -M.padding, 0)
  subText:SetJustifyH("LEFT")
  ns.Theme.setText(subText, C.textFaint)

  buildHeader()

  content = CreateFrame("Frame", nil, frame)
  content:SetPoint("TOPLEFT", frame, "TOPLEFT", M.padding, -M.headerHeight)
  content:SetSize(gridWidth(), 1)

  -- Escape closes it, the way every other WoW panel behaves.
  tinsert(UISpecialFrames, "RaidInspectorGrid")

  frame:Hide()
  return frame
end

-- Touches only the scanning marker, never the row contents, so it can run far
-- more often than the full refresh without costing anything.
function Grid.updateScanMarker()
  if not frame or not frame:IsShown() then return end
  local status = ns.Scanner and ns.Scanner.status and ns.Scanner.status()
  local scanning = status and status.pending or nil

  for i = 1, table.getn(rows) do
    local row = rows[i]
    if row:IsShown() and row.guid and row.guid == scanning then
      row.scanning:Show()
    else
      row.scanning:Hide()
    end
  end
end

function Grid.toggle()
  Grid.create()
  if frame:IsShown() then
    frame:Hide()
    -- The panel is a child, so it hides with the parent, but the selection has
    -- to be cleared too or reopening lands on a highlighted row with no panel.
    selectedGuid = nil
    ns.Detail.hide()
  else
    frame:Show()
  end
  return frame:IsShown()
end

function Grid.isShown()
  return frame and frame:IsShown()
end

-- The detail panel attaches to this rather than floating on its own, so the two
-- move and close together instead of scattering across the screen.
function Grid.getFrame()
  Grid.create()
  return frame
end

-- Clicking the selected player again closes the panel, which is what people
-- expect from a toggle and saves hunting for a close button.
function Grid.selectPlayer(guid)
  if selectedGuid == guid then
    selectedGuid = nil
    ns.Detail.hide()
  else
    selectedGuid = guid
    ns.Detail.show(guid)
  end
  if lastEntries then Grid.refresh(lastEntries, lastCoverage) end
end

function Grid.selectedPlayer()
  return selectedGuid
end
