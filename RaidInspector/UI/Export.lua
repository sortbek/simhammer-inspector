local addonName, ns = ...

local Export = {}
ns.Export = Export

local C = ns.Theme.colour

local frame, editBox, statusText, skippedText

local function create()
  if frame then return end

  frame = CreateFrame("Frame", "RaidInspectorExport", UIParent)
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

  local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("LEFT", titleBar, "LEFT", 12, 0)
  title:SetText("SimulationCraft export")
  ns.Theme.setText(title, C.textPrimary)

  local close = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
  close:SetPoint("RIGHT", titleBar, "RIGHT", -2, 0)
  close:SetSize(24, 24)
  close:SetScript("OnClick", function() frame:Hide() end)

  statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  statusText:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -32)
  statusText:SetJustifyH("LEFT")

  skippedText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  skippedText:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -48)
  skippedText:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
  skippedText:SetJustifyH("LEFT")
  ns.Theme.setText(skippedText, C.textFaint)

  local scroll = CreateFrame("ScrollFrame", "RaidInspectorExportScroll", frame,
                             "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -66)
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

  tinsert(UISpecialFrames, "RaidInspectorExport")
  frame:Hide()
end

function Export.show(text, skipped, exported)
  create()

  editBox.payload = text
  editBox:SetText(text)

  statusText:SetText(string.format("%d profiles  \194\183  Ctrl+C copies and closes", exported))
  if exported > 0 then
    statusText:SetTextColor(0.36, 0.74, 0.46)
  else
    statusText:SetTextColor(0.92, 0.70, 0.18)
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
