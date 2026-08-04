local addonName, ns = ...

-- One place for every colour and measurement the UI uses. Two loud colour
-- scales fighting each other is what makes dense grids unreadable, so the
-- palette is deliberately narrow: a near-neutral surface, muted class colour for
-- identity, and saturation reserved for the thing that needs attention.
local Theme = {}
ns.Theme = Theme

Theme.colour = {
  window      = { 0.055, 0.059, 0.071, 0.96 },
  header      = { 0.086, 0.094, 0.114, 1 },
  border      = { 1, 1, 1, 0.06 },
  rowOdd      = { 1, 1, 1, 0.018 },
  rowEven     = { 0, 0, 0, 0 },
  rowHover    = { 1, 1, 1, 0.055 },
  divider     = { 1, 1, 1, 0.05 },
  textPrimary = { 0.92, 0.93, 0.95 },
  textMuted   = { 0.48, 0.50, 0.56 },
  textFaint   = { 0.32, 0.34, 0.40 },
  accent      = { 0.38, 0.62, 0.95 },
}

-- Cell states carry a glyph as well as a colour. Red against green is
-- unreadable for a meaningful share of players, so colour is never the only
-- channel that distinguishes them.
--
-- "ok" is deliberately the quietest state in the palette. It is also the most
-- common one: sixteen slots times twenty players is mostly fine, and when the
-- default state is a saturated green the one amber cell that matters has to
-- compete with three hundred that do not. A calm grid makes the exception
-- obvious without needing a brighter colour for it.
Theme.state = {
  ok = {
    fill  = { 0.13, 0.24, 0.17, 0.85 },
    edge  = { 0.24, 0.46, 0.30, 0.45 },
    glyph = "", glyphColour = { 1, 1, 1 },
  },
  warn = {
    fill  = { 0.55, 0.40, 0.05, 0.95 },
    edge  = { 1.00, 0.76, 0.20, 0.85 },
    glyph = "!", glyphColour = { 1, 0.93, 0.68 },
  },
  bad = {
    fill  = { 0.56, 0.13, 0.15, 1 },
    edge  = { 1.00, 0.36, 0.36, 0.9 },
    glyph = "\195\151", glyphColour = { 1, 0.86, 0.86 },
  },
  unknown = {
    fill  = { 0.12, 0.13, 0.16, 0.85 },
    edge  = { 1, 1, 1, 0.05 },
    glyph = "\194\183", glyphColour = { 0.40, 0.42, 0.48 },
  },
  empty = {
    fill  = { 0.08, 0.08, 0.10, 0.5 },
    edge  = { 1, 1, 1, 0.02 },
    glyph = "", glyphColour = { 0.3, 0.3, 0.3 },
  },
}

Theme.metrics = {
  rowHeight    = 23,
  -- 15 px was too small for the paperdoll slot icons used as column heads: at
  -- that size they were indistinguishable grey smudges. 19 makes them legible
  -- and gives the grid room to breathe.
  cellSize     = 19,
  cellGap      = 3,
  iconSize     = 14,
  nameWidth    = 148,
  ilvlWidth    = 46,
  embWidth     = 34,
  summaryWidth = 40,
  padding      = 12,
  -- Title bar, toolbar, coverage, totals, the not-answering line and a row of
  -- slot icons, none of them crowding each other.
  headerHeight = 118,
}

-- Item quality colours, for item names in the detail panel. Blizzard exposes
-- these but only after the item is cached, so the table is kept here to avoid a
-- second async dependency for something purely decorative.
Theme.quality = {
  [0] = { 0.62, 0.62, 0.62 },
  [1] = { 1.00, 1.00, 1.00 },
  [2] = { 0.12, 1.00, 0.00 },
  [3] = { 0.00, 0.44, 0.87 },
  [4] = { 0.64, 0.21, 0.93 },
  [5] = { 0.90, 0.80, 0.50 },
  [6] = { 0.90, 0.80, 0.50 },
  [7] = { 0.00, 0.80, 1.00 },
}

Theme.role = {
  TANK    = { 0, 0.25, 0.25, 0.5,  label = "T" },
  HEALER  = { 0.25, 0.5, 0, 0.25,  label = "H" },
  DAMAGER = { 0.25, 0.5, 0.25, 0.5, label = "D" },
}

Theme.STALE_ALPHA = 0.38

-- Draws a flat panel with a hairline border. Blizzard's templates carry a lot of
-- ornamental art that fights with a dense grid; a plain surface reads better and
-- costs less.
function Theme.panel(frame, colour)
  local c = colour or Theme.colour.window
  frame.bg = frame:CreateTexture(nil, "BACKGROUND")
  frame.bg:SetAllPoints()
  frame.bg:SetColorTexture(c[1], c[2], c[3], c[4])

  local e = Theme.colour.border
  local function edge(point1, point2, w, h)
    local t = frame:CreateTexture(nil, "BORDER")
    t:SetColorTexture(e[1], e[2], e[3], e[4])
    t:SetPoint(point1)
    t:SetPoint(point2)
    if w then t:SetWidth(w) end
    if h then t:SetHeight(h) end
    return t
  end
  edge("TOPLEFT", "TOPRIGHT", nil, 1)
  edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
  edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
  edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)

  return frame
end

-- A small flat text button. Defined once so every control in the addon reacts
-- the same way; four hand-rolled buttons drift apart within a week.
function Theme.button(parent, label, width, onClick, tooltip)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(width, 18)

  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints()
  b.bg:SetColorTexture(1, 1, 1, 0.05)

  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  b.text:SetAllPoints()
  b.text:SetJustifyH("CENTER")
  b.text:SetText(label)
  Theme.setText(b.text, Theme.colour.textMuted)

  b:SetScript("OnEnter", function(self)
    self.bg:SetColorTexture(1, 1, 1, 0.11)
    Theme.setText(self.text, Theme.colour.textPrimary)
    if tooltip then
      GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
      GameTooltip:AddLine(label)
      GameTooltip:AddLine(tooltip, 0.7, 0.7, 0.7, true)
      GameTooltip:Show()
    end
  end)

  b:SetScript("OnLeave", function(self)
    self.bg:SetColorTexture(1, 1, 1, 0.05)
    Theme.setText(self.text, Theme.colour.textMuted)
    GameTooltip:Hide()
  end)

  b:SetScript("OnClick", function()
    local ok, err = pcall(onClick)
    if not ok then
      DEFAULT_CHAT_FRAME:AddMessage("|cffff4444Simhammer|r " .. tostring(err))
    end
  end)

  return b
end

function Theme.setText(fontString, colour)
  fontString:SetTextColor(colour[1], colour[2], colour[3], colour[4] or 1)
end

-- Class colour, pulled towards the neutral surface so names stay legible without
-- competing with the cells for attention.
function Theme.mutedClassColour(class)
  local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
  if not c then return 0.72, 0.74, 0.78 end
  local mix = 0.35
  return c.r * (1 - mix) + 0.75 * mix,
         c.g * (1 - mix) + 0.75 * mix,
         c.b * (1 - mix) + 0.78 * mix
end
