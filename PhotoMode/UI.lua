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

function UI.Slash(msg)
    local cmd = (msg or ""):lower():match("^%s*(%S*)") or ""
    if cmd == "" then
        ns.Core.Start()
    elseif cmd == "debug" then
        ns.Core.Debug()
    elseif cmd == "restore" then
        if ns.Core.RestorePending() == false then ns.Core.Print("nothing to restore.") end
    elseif cmd == "reset" then
        UI.ResetPosition()
        ns.Core.Print("button position reset.")
    else
        ns.Core.Print("/photo - take a clean screenshot")
        ns.Core.Print("/photo debug - list name CVars on this client and their values")
        ns.Core.Print("/photo restore - put back settings from an interrupted photo")
        ns.Core.Print("/photo reset - move the button back to its default spot")
    end
end

SLASH_PHOTOMODE1 = "/photo"
SLASH_PHOTOMODE2 = "/photomode"
SlashCmdList.PHOTOMODE = UI.Slash
