local addonName, ns = ...

local Export = {}
ns.Export = Export

local C = ns.Theme.colour
local S = ns.Theme.severity

local frame, editBox, statusText, skippedText, titleText, roleBar
local roleBoxes = {}

local function create()
  if frame then return end

  frame = CreateFrame("Frame", "SimhammerInspectorExport", UIParent)
  frame:SetSize(620, 460)
  -- Opens over the grid rather than wherever the screen centre happens to be,
  -- so it appears where you are already looking. Still draggable and still its
  -- own frame, because it is transient: Ctrl+C dismisses it.
  local anchor = (ns.Grid and ns.Grid.isShown() and ns.Grid.getFrame()) or UIParent
  frame:SetPoint("CENTER", anchor, "CENTER", 0, 0)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetClampedToScreen(true)
  frame:SetFrameStrata("DIALOG")
  ns.Theme.panel(frame)

  local titleBar = CreateFrame("Frame", nil, frame)
  titleBar:SetPoint("TOPLEFT")
  titleBar:SetPoint("TOPRIGHT")
  titleBar:SetHeight(26)
  ns.Theme.panel(titleBar, C.header)

  titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  titleText:SetPoint("LEFT", titleBar, "LEFT", 12, 0)
  titleText:SetText("SimulationCraft export")
  ns.Theme.setText(titleText, C.textPrimary)

  local close = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
  close:SetPoint("RIGHT", titleBar, "RIGHT", -2, 0)
  close:SetSize(24, 24)
  close:SetScript("OnClick", function() frame:Hide() end)

  -- The toggles live here rather than being asked before the window opens: you
  -- usually find out you wanted tanks in it by looking at what you got, and
  -- re-running from the grid to change your mind is a worse loop.
  roleBar = CreateFrame("Frame", nil, frame)
  roleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -30)
  roleBar:SetSize(400, 18)

  local roleLabel = roleBar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  roleLabel:SetPoint("LEFT", roleBar, "LEFT", 0, 0)
  roleLabel:SetText("include")
  ns.Theme.setText(roleLabel, C.textFaint)

  local previous = nil
  for i = 1, table.getn(ns.Core.ROLE_ORDER) do
    local role = ns.Core.ROLE_ORDER[i]
    local box = ns.Theme.checkbox(roleBar, ns.Core.ROLE_LABELS[role], 72,
      function() return ns.Core.simcRoles()[role] end,
      function()
        ns.Core.toggleSimcRole(role)
        -- Rebuilds straight away, so the effect of a toggle is the text in front
        -- of you rather than something you have to go and re-trigger.
        ns.Core.exportSimc()
      end)
    if previous then
      box:SetPoint("LEFT", previous, "RIGHT", 6, 0)
    else
      box:SetPoint("LEFT", roleLabel, "RIGHT", 10, 0)
    end
    previous = box
    roleBoxes[table.getn(roleBoxes) + 1] = box
  end

  statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  statusText:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -52)
  statusText:SetJustifyH("LEFT")

  skippedText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  skippedText:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -68)
  skippedText:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
  skippedText:SetJustifyH("LEFT")
  ns.Theme.setText(skippedText, C.textFaint)

  local scroll = CreateFrame("ScrollFrame", "SimhammerInspectorExportScroll", frame,
                             "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -86)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 12)

  editBox = CreateFrame("EditBox", nil, scroll)
  editBox:SetMultiLine(true)
  editBox:SetAutoFocus(false)
  editBox:SetFontObject("ChatFontNormal")
  editBox:SetWidth(560)
  editBox:SetScript("OnEscapePressed", function() frame:Hide() end)

  -- Close on copy. The hide is deferred a frame so the copy itself completes
  -- first: hiding the box in the same frame as the keypress can take the
  -- selection away before the client has read it.
  editBox:SetScript("OnKeyDown", function(_, key)
    if key == "C" and IsControlKeyDown() then
      C_Timer.After(0, function() frame:Hide() end)
    end
  end)
  -- The text is read-only in intent: any edit is undone rather than blocked, so
  -- selection and copying still behave normally.
  editBox:SetScript("OnTextChanged", function(self, userInput)
    if userInput then self:SetText(self.payload or "") end
  end)
  scroll:SetScrollChild(editBox)

  tinsert(UISpecialFrames, "SimhammerInspectorExport")
  frame:Hide()
end

-- A subject is the name of the single player the export is about. Without one
-- the window is the raid export it has always been.
function Export.show(text, skipped, exported, subject)
  create()

  if subject then
    -- Every toggle rebuilds the whole raid bundle, so leaving them live here
    -- means one stray click throws away the profile you just opened.
    roleBar:Hide()
    titleText:SetText("SimulationCraft export \226\128\148 " .. subject)
  else
    roleBar:Show()
    titleText:SetText("SimulationCraft export")
    for i = 1, table.getn(roleBoxes) do roleBoxes[i]:Refresh() end
  end

  editBox.payload = text
  editBox:SetText(text)

  if exported > 0 then
    statusText:SetText(string.format("%d profile%s  \194\183  Ctrl+C copies and closes",
                                     exported, exported == 1 and "" or "s"))
    statusText:SetTextColor(S.ok[1], S.ok[2], S.ok[3])
  elseif subject then
    -- The role explanations below are about a selection this window does not
    -- have; the skipped line underneath carries the actual reason.
    statusText:SetText("could not build a profile for " .. subject)
    statusText:SetTextColor(S.warn[1], S.warn[2], S.warn[3])
  else
    -- Nothing selected and nothing matched look identical in an empty box, so
    -- say which of the two it is.
    local anyRole = false
    for _, on in pairs(ns.Core.simcRoles()) do
      if on then anyRole = true break end
    end
    statusText:SetText(anyRole and "no players matched those roles yet"
                                or "no roles selected")
    statusText:SetTextColor(S.warn[1], S.warn[2], S.warn[3])
  end

  if skipped and table.getn(skipped) > 0 then
    local names = {}
    for i = 1, table.getn(skipped) do
      names[i] = skipped[i].name .. " (" .. (skipped[i].reason or "?") .. ")"
    end
    skippedText:SetText("skipped: " .. table.concat(names, ", "))
  else
    skippedText:SetText("")
  end

  frame:Show()

  -- Focus and selection only stick once the frame is actually shown, and the
  -- scroll frame needs a frame to lay the edit box out. Doing it before Show
  -- silently does nothing, which is why the text was not selected on open.
  C_Timer.After(0, function()
    if not frame:IsShown() then return end
    editBox:SetFocus()
    editBox:HighlightText()
  end)
end
