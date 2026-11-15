-- PhotoMode presentation: the movable camera button and the /photo slash command.
local _, ns = ...

local UI = {}
ns.UI = UI

local function db()
    PhotoModeDB = PhotoModeDB or {}
    return PhotoModeDB
end

function UI.ApplyPosition(button)
    local cfg = ns.Config.button
    local pos = db().button or {}
    button:ClearAllPoints()
    button:SetPoint(pos.point or cfg.point, UIParent, pos.relativePoint or cfg.relativePoint,
        pos.x or cfg.x, pos.y or cfg.y)
end

function UI.SavePosition(button)
    local point, _, relativePoint, x, y = button:GetPoint(1)
    db().button = { point = point, relativePoint = relativePoint, x = x, y = y }
end

function UI.ResetPosition()
    db().button = nil
    if UI.button then UI.ApplyPosition(UI.button) end
end

function UI.Create()
    if UI.button then return UI.button end
    local cfg = ns.Config.button

    local b = CreateFrame("Button", "PhotoModeButton", UIParent)
    b:SetSize(cfg.size, cfg.size)
    b:SetFrameStrata("MEDIUM")
    b:SetMovable(true)
    b:EnableMouse(true)
    b:SetClampedToScreen(true)
    b:RegisterForClicks("LeftButtonUp")
    b:RegisterForDrag("LeftButton")

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(cfg.icon)
    b.icon = icon
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    UI.ApplyPosition(b)

    b:SetScript("OnDragStart", function(self) self:StartMoving() end)
    b:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self:SetUserPlaced(false) -- our SavedVariables own the position, not layout-local.txt
        UI.SavePosition(self)
        self.lastDragEnd = GetTime()
    end)
    b:SetScript("OnClick", function(self)
        if self.lastDragEnd and GetTime() - self.lastDragEnd < cfg.dragClickGuard then return end
        ns.Core.Start()
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("PhotoMode")
        GameTooltip:AddLine("Click: screenshot without names or UI", 1, 1, 1)
        GameTooltip:AddLine("Drag: move this button", 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UI.button = b
    return b
end

-- Movable window with a read-only, scrollable, pre-selected EditBox so the report can be
-- copied with Ctrl+A / Ctrl+C (chat text cannot be copied).
local function createDebugFrame()
    local cfg = ns.Config.debugWindow
    local f = CreateFrame("Frame", "PhotoModeDebugFrame", UIParent)
    f:SetSize(cfg.width, cfg.height)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, cfg.backgroundAlpha)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
    title:SetText("PhotoMode debug - Ctrl+A, then Ctrl+C to copy. Drag to move.")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    close:SetScript("OnClick", function() f:Hide() end)

    local scroll = CreateFrame("ScrollFrame", "PhotoModeDebugScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -32)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 12)

    local edit = CreateFrame("EditBox", "PhotoModeDebugEditBox", scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(0)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(cfg.width - 48)
    edit:SetHeight(cfg.height - 48)
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    -- Read-only: typing puts the report back (copy shortcuts do not change the text).
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            self:SetText(f.report or "")
            self:HighlightText()
        end
    end)
    scroll:SetScrollChild(edit)
    f:SetScript("OnHide", function() edit:ClearFocus() end) -- give the keyboard back
    f.edit = edit

    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "PhotoModeDebugFrame") -- Esc closes it
    end
    return f
end

function UI.ShowDebug(report)
    UI.debugFrame = UI.debugFrame or createDebugFrame()
    local f = UI.debugFrame
    f.report = report
    f:Show()
    f.edit:SetText(report)
    f.edit:SetFocus()
    f.edit:HighlightText()
    return f
end

function UI.Slash(msg)
    local cmd = (msg or ""):lower():match("^%s*(%S*)") or ""
    if cmd == "" then
        ns.Core.Start()
    elseif cmd == "debug" then
        ns.Core.Debug()
    elseif cmd == "restore" then
        if ns.Core.RestorePending() == false then ns.Core.Print("nothing to restore.") end
    elseif cmd == "forget" then
        if ns.Core.Forget() then
            ns.Core.Print("dropped the pending restore; settings stay as they are now.")
        else
            ns.Core.Print("nothing to forget.")
        end
    elseif cmd == "reset" then
        UI.ResetPosition()
        ns.Core.Print("button position reset.")
    else
        ns.Core.Print("/photo - take a clean screenshot")
        ns.Core.Print("/photo debug - show this client's CVars and camera info in a copyable window")
        ns.Core.Print("/photo restore - put back settings from an interrupted photo")
        ns.Core.Print("/photo forget - give up on a restore that keeps failing")
        ns.Core.Print("/photo reset - move the button back to its default spot")
    end
end

SLASH_PHOTOMODE1 = "/photo"
SLASH_PHOTOMODE2 = "/photomode"
SlashCmdList.PHOTOMODE = UI.Slash
