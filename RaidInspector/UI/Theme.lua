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
Theme.state = {
  ok = {
    fill  = { 0.18, 0.44, 0.26, 0.85 },
    edge  = { 0.30, 0.68, 0.40, 0.55 },
    glyph = "", glyphColour = { 1, 1, 1 },
  },
  warn = {
    fill  = { 0.52, 0.38, 0.06, 0.9 },
    edge  = { 0.92, 0.70, 0.18, 0.7 },
    glyph = "!", glyphColour = { 1, 0.90, 0.62 },
  },
  bad = {
    fill  = { 0.50, 0.13, 0.15, 0.92 },
    edge  = { 0.93, 0.31, 0.31, 0.75 },
    glyph = "\195\151", glyphColour = { 1, 0.82, 0.82 },
  },
  unknown = {
    fill  = { 0.13, 0.14, 0.17, 0.85 },
    edge  = { 1, 1, 1, 0.05 },
    glyph = "\194\183", glyphColour = { 0.42, 0.44, 0.50 },
  },
  empty = {
    fill  = { 0.08, 0.08, 0.10, 0.5 },
    edge  = { 1, 1, 1, 0.02 },
    glyph = "", glyphColour = { 0.3, 0.3, 0.3 },
  },
}

Theme.metrics = {
  rowHeight    = 20,
  cellSize     = 15,
  cellGap      = 3,
  nameWidth    = 116,
  ilvlWidth    = 46,
  summaryWidth = 40,
  padding      = 12,
  headerHeight = 62,
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
