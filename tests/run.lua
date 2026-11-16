-- PhotoMode tests against a mocked WoW API. Run from the repo root:  lua tests/run.lua
-- Works with Lua 5.1 (WoW's dialect) and newer.

local unpack = table.unpack or unpack

---------------------------------------------------------------------------
-- Mock WoW environment
---------------------------------------------------------------------------
local W -- world state, rebuilt per test

local function genericObject()
    return setmetatable({}, { __index = function() return function() end end })
end

local function newFrame(name)
    local f = { events = {}, scripts = {}, shown = true, name = name }
    function f:RegisterEvent(e) self.events[e] = true end
    function f:UnregisterEvent(e) self.events[e] = nil end
    function f:SetScript(n, fn) self.scripts[n] = fn end
    function f:Show() self.shown = true end
    function f:Hide()
        self.shown = false
        if self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    function f:IsShown() return self.shown end
    W.frames[#W.frames + 1] = f
    -- unknown methods are no-ops that return a dummy object (for CreateTexture/CreateFontString)
    return setmetatable(f, { __index = function() return function() return genericObject() end end })
end

local function newEditBox(name)
    local e = newFrame(name)
    e.text = ""
    function e:SetText(t) self.text = t; self.highlighted = false end
    function e:GetText() return self.text end
    function e:HighlightText() self.highlighted = true end
    function e:SetFocus() self.focused = true end
    function e:ClearFocus() self.focused = false end
    return e
end

local function newButton()
    local b = newFrame()
    b.points = {}
    function b:ClearAllPoints() self.points = {} end
    function b:SetPoint(p, rel, rp, x, y) self.points[1] = { p, rel, rp, x, y } end
    function b:GetPoint() local p = self.points[1]; return p[1], p[2], p[3], p[4], p[5] end
    function b:CreateTexture() return genericObject() end
    return setmetatable(b, { __index = function() return function() end end })
end

local function plate(alpha)
    local p = { alpha = alpha }
    function p:GetAlpha() return self.alpha end
    function p:SetAlpha(a) self.alpha = a end
    return p
end

-- Default existing CVars: roughly what Forever is believed to have.
local function defaultCVars()
    local cv = {}
    for _, n in ipairs({
        "UnitNameOwn", "UnitNameNPC", "UnitNameInteractiveNPC", "UnitNameNonCombatCreatureName",
        "UnitNameFriendlyPlayerName", "UnitNameFriendlyPetName", "UnitNameFriendlyMinionName",
        "UnitNameFriendlyGuardianName", "UnitNameFriendlyTotemName", "UnitNameFriendlySpecialNPCName",
        "UnitNameEnemyPlayerName", "UnitNameEnemyPetName", "UnitNameEnemyMinionName",
        "UnitNameEnemyGuardianName", "UnitNameEnemyTotemName", "UnitNameHostleNPC",
        "UnitNamePlayerGuild", "UnitNameGuildTitle", "UnitNamePlayerPVPTitle",
        "nameplateShowAll", "nameplateShowFriends", "nameplateShowFriendlyNPCs", "nameplateShowEnemies",
        "nameplateShowEnemyMinions", "nameplateShowEnemyMinus", "nameplateShowSelf",
        "chatBubbles", "chatBubblesParty",
        "ShowQuestUnitCircles", "showTaxiNodeLearnedIcon",
    }) do cv[n] = "1" end
    cv.UnitNameOwn = "0"
    cv.UnitNameForceHideMinus = "0"
    cv.nameplateMinAlpha = "0.6"
    cv.nameplateMaxAlpha = "1"
    cv.cameraZoomSpeed = "20"
    return cv
end

-- Moves the mocked camera toward its target and returns the current distance.
local function camNow()
    if not W.zoomRate then
        W.cam = W.zoom
    else
        local step = W.zoomRate * (W.now - W.camT)
        local d = W.zoom - W.cam
        if math.abs(d) <= step then W.cam = W.zoom else W.cam = W.cam + (d > 0 and step or -step) end
    end
    W.camT = W.now
    if W.cam == 0 and not W.reachedZeroAt then W.reachedZeroAt = W.now end
    return W.cam
end

-- Minimap tracking menu, as C_Minimap exposes it. Filter IDs are arbitrary but distinct.
local FILTER = { TrivialQuests = 9, AccountCompletedQuests = 14, Repair = 2 }
local function defaultTracking()
    return {
        { filterID = FILTER.Repair, active = true },
        { filterID = FILTER.TrivialQuests, active = true },
        { filterID = FILTER.AccountCompletedQuests, active = false },
    }
end

local function trackingState(filterName)
    for _, t in ipairs(W.tracking) do
        if t.filterID == FILTER[filterName] then return t.active end
    end
end

local function setupWorld(opts)
    opts = opts or {}
    W = {
        cvars = opts.cvars or defaultCVars(),
        ignored = opts.ignored or {}, -- CVar writes the client silently drops
        combat = false,
        uiShown = true,
        zoom = opts.zoom or 12, -- camera target distance
        timers = {},
        now = 0,
        frames = {},
        printed = {},
        screenshots = 0,
        screenshotError = opts.screenshotError,
        plates = opts.plates or {},
        setLog = {},
        zoomInFloors = opts.zoomInFloors,
        tracking = opts.tracking or defaultTracking(),
        trackingLocked = {}, -- filterID -> true: SetTracking is silently ignored
    }
    _G.PhotoModeDB = opts.db
    _G.C_CVar = {
        GetCVar = function(n) return W.cvars[n] end,
        SetCVar = function(n, v)
            W.setLog[#W.setLog + 1] = n
            if W.cvars[n] == nil then error("unknown cvar " .. n) end
            if W.ignored[n] or (W.combat and W.cvarsProtected) then return false end
            W.cvars[n] = tostring(v)
            return true
        end,
    }
    _G.InCombatLockdown = function() return W.combat end
    _G.UnitAffectingCombat = function() return W.combat end
    _G.UIParent = {
        IsShown = function() return W.uiShown end,
        Hide = function() assert(not W.combat, "UIParent:Hide in combat"); W.uiShown = false end,
        Show = function() assert(not W.combat, "UIParent:Show in combat"); W.uiShown = true end,
    }
    -- W.zoom is the camera's target distance. With opts.zoomRate the actual distance
    -- (what GetCameraZoom returns) animates toward it at that many yards per second.
    W.zoomRate = opts.zoomRate
    W.cam, W.camT = W.zoom, 0
    _G.GetCameraZoom = function() return camNow() end
    _G.CameraZoomIn = function(d)
        camNow()
        W.zoomInCalls = (W.zoomInCalls or 0) + 1
        W.zoomSpeedAtZoomIn = W.zoomSpeedAtZoomIn or W.cvars.cameraZoomSpeed
        -- opts.zoomInFloors: per-call lowest distance reached (simulates a zoom that stops short)
        local floor = W.zoomInFloors and table.remove(W.zoomInFloors, 1) or 0
        W.zoom = math.max(floor, W.zoom - d)
    end
    _G.CameraZoomOut = function(d)
        if (W.zoomOutErrors or 0) > 0 then
            W.zoomOutErrors = W.zoomOutErrors - 1
            error("camera busy")
        end
        camNow()
        W.zoom = math.min(39, W.zoom + d)
    end
    _G.Screenshot = function()
        if W.screenshotError then error("boom") end
        W.screenshots = W.screenshots + 1
        W.snapAt = { cvars = {}, ui = W.uiShown, zoom = camNow(), time = W.now }
        for k, v in pairs(W.cvars) do W.snapAt.cvars[k] = v end
        W.snapAt.tracking = {}
        for name in pairs(FILTER) do W.snapAt.tracking[name] = trackingState(name) end
    end
    _G.Enum = { MinimapTrackingFilter = FILTER }
    _G.C_Minimap = opts.noMinimap and {} or {
        GetNumTrackingTypes = function() return #W.tracking end,
        GetTrackingFilter = function(i) local t = W.tracking[i]; return t and { filterID = t.filterID, spellID = 0 } end,
        GetTrackingInfo = function(i)
            local t = W.tracking[i]
            return t and { name = "t" .. i, texture = 0, active = t.active, type = "other", subType = -1 }
        end,
        SetTracking = function(i, on)
            local t = assert(W.tracking[i], "bad tracking index")
            W.trackingWrites = (W.trackingWrites or 0) + 1
            if not W.trackingLocked[t.filterID] then t.active = on end
        end,
    }
    _G.C_Timer = { After = function(d, fn) W.timers[#W.timers + 1] = { at = W.now + d, fn = fn } end }
    _G.GetTime = function() return W.now end
    _G.GetBuildInfo = function() return "1.60.1", "69913", "Nov 2026", 16001 end
    _G.C_NamePlate = {
        GetNamePlates = function() return W.plates end,
        GetNamePlateForUnit = function(unit) return W.plateByUnit and W.plateByUnit[unit] end,
    }
    _G.issecretvalue = function() return false end
    _G.CreateFrame = function(kind, name)
        if kind == "Button" then return newButton() end
        if kind == "EditBox" then return newEditBox(name) end
        return newFrame(name)
    end
    _G.UISpecialFrames = {}
    _G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) W.printed[#W.printed + 1] = m end }
    _G.GameTooltip = genericObject()
    _G.SlashCmdList = {}

    local ns = {}
    for _, file in ipairs({ "Config.lua", "Core.lua", "UI.lua" }) do
        local chunk = assert(loadfile("PhotoMode/" .. file))
        chunk("PhotoMode", ns)
    end
    if opts.config then opts.config(ns.Config) end
    W.ns = ns
    return ns
end

local function fire(event, ...)
    for _, f in ipairs(W.frames) do
        if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
    end
end

local function advance(dt)
    local target = W.now + dt
    while true do
        table.sort(W.timers, function(a, b) return a.at < b.at end)
        local t = W.timers[1]
        if not t or t.at > target then break end
        table.remove(W.timers, 1)
        W.now = t.at
        t.fn()
    end
    W.now = target
end

-- Long enough for any zoom wait (cap) plus the post-zoom delay; shorter than the screenshot timeout.
local function settle(ns)
    advance(ns.Config.zoomSettleTimeout + ns.Config.postZoomDelay + 0.1)
end

local function load(opts)
    local ns = setupWorld(opts)
    fire("ADDON_LOADED", "PhotoMode")
    return ns
end

local function copy(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end

local function printedMatch(pat)
    for _, m in ipairs(W.printed) do if m:find(pat) then return true end end
    return false
end

---------------------------------------------------------------------------
-- Tiny test runner
---------------------------------------------------------------------------
local tests, failures = {}, 0
local function test(name, fn) tests[#tests + 1] = { name, fn } end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function sameTable(a, b, msg)
    for k, v in pairs(b) do eq(a[k], v, (msg or "") .. " [" .. k .. "]") end
    for k, v in pairs(a) do eq(v, b[k], (msg or "") .. " [" .. k .. "]") end
end

---------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------

test("TOC declares Interface 16001 and SavedVariables", function()
    local f = assert(io.open("PhotoMode/PhotoMode.toc"))
    local toc = f:read("*a"); f:close()
    assert(toc:find("## Interface: 16001%s"), "interface line")
    assert(toc:find("## SavedVariables: PhotoModeDB", 1, true), "savedvariables line")
end)

test("combat press prints the message and changes nothing", function()
    local ns = load()
    local before = copy(W.cvars)
    W.combat = true
    eq(ns.Core.Start(), false)
    assert(printedMatch("^PhotoMode: not available in combat$"), "combat message")
    sameTable(W.cvars, before, "cvars")
    eq(W.uiShown, true); eq(W.zoom, 12); eq(#W.setLog, 0); eq(ns.Core.state, "idle")
    eq(PhotoModeDB.pendingRestore, nil)
end)

test("full sequence hides everything, shoots, then restores exactly", function()
    local ns = load()
    W.cvars.chatBubblesParty = "0" -- already at hide value: must stay untouched and be restored as-is
    local before = copy(W.cvars)
    assert(ns.Core.Start())
    eq(W.uiShown, false, "ui hidden"); eq(W.zoom, 0, "first person")
    assert(PhotoModeDB.pendingRestore, "snapshot persisted")
    eq(W.screenshots, 0, "waits for settle")
    settle(ns)
    eq(W.screenshots, 1)
    -- every existing candidate is at its hide value at the moment of the screenshot
    for _, e in ipairs(ns.Config.cvars) do
        if before[e[1]] ~= nil then eq(W.snapAt.cvars[e[1]], e[2], e[1]) end
    end
    eq(W.snapAt.ui, false); eq(W.snapAt.zoom, 0)
    eq(W.snapAt.cvars.nameplateMinAlpha, "0.6", "no alpha fallback when CVars work")
    fire("SCREENSHOT_SUCCEEDED")
    sameTable(W.cvars, before, "restored")
    eq(W.uiShown, true); eq(W.zoom, 12); eq(ns.Core.state, "idle")
    eq(PhotoModeDB.pendingRestore, nil)
end)

test("missing CVars are never written and cause no error", function()
    local ns = load()
    assert(ns.Core.Start())
    settle(ns); fire("SCREENSHOT_SUCCEEDED")
    for _, n in ipairs(W.setLog) do assert(W.cvars[n] ~= nil, "wrote missing cvar " .. n) end
    assert(not printedMatch("error"), "no error printed")
    for _, n in ipairs({ "nameplateShowFriendlyMinions", "nameplateShowFriendlyPets",
        "nameplateShowFriendlyGuardians", "nameplateShowFriendlyTotems", "UnitNameHostileNPC" }) do
        eq(W.cvars[n], nil, n .. " was created")
    end
end)

test("SCREENSHOT_FAILED restores", function()
    local ns = load(); local before = copy(W.cvars)
    ns.Core.Start(); settle(ns); fire("SCREENSHOT_FAILED")
    sameTable(W.cvars, before); eq(W.uiShown, true); eq(W.zoom, 12)
    assert(printedMatch("screenshot failed"))
end)

test("timeout restores when no screenshot event arrives", function()
    local ns = load(); local before = copy(W.cvars)
    ns.Core.Start(); settle(ns)
    eq(ns.Core.state, "running")
    advance(ns.Config.screenshotTimeout)
    sameTable(W.cvars, before); eq(W.uiShown, true); eq(W.zoom, 12); eq(ns.Core.state, "idle")
end)

test("error mid-sequence restores everything", function()
    local ns = load({ screenshotError = true }); local before = copy(W.cvars)
    ns.Core.Start(); settle(ns)
    sameTable(W.cvars, before); eq(W.uiShown, true); eq(W.zoom, 12); eq(ns.Core.state, "idle")
    assert(printedMatch("error, restoring"))
end)

test("combat during settle: camera now, CVars + UI after combat, no screenshot", function()
    local ns = load(); local before = copy(W.cvars)
    W.cvarsProtected = true
    ns.Core.Start(); advance(0.1)
    W.combat = true -- lockdown already active when the event is handled (worst case)
    fire("PLAYER_REGEN_DISABLED")
    eq(W.zoom, 12, "camera restored immediately")
    eq(W.uiShown, false, "UI waits for combat end")
    eq(ns.Core.state, "restoring")
    advance(10)
    eq(W.screenshots, 0, "no screenshot after cancel")
    eq(ns.Core.Start(), false, "cannot start while restoring")
    W.combat = false
    fire("PLAYER_REGEN_ENABLED")
    sameTable(W.cvars, before); eq(W.uiShown, true); eq(ns.Core.state, "idle")
    eq(PhotoModeDB.pendingRestore, nil)
end)

test("combat event before lockdown restores everything at once", function()
    local ns = load(); local before = copy(W.cvars)
    ns.Core.Start(); settle(ns)
    fire("PLAYER_REGEN_DISABLED") -- InCombatLockdown() still false, as on retail
    sameTable(W.cvars, before); eq(W.uiShown, true); eq(W.zoom, 12); eq(ns.Core.state, "idle")
    fire("SCREENSHOT_SUCCEEDED") -- late event must be ignored
    eq(ns.Core.state, "idle")
end)

test("ignored nameplate write triggers alpha fallback, which is restored", function()
    local p1 = plate(1)
    local ns = load({ ignored = { nameplateShowFriends = true }, plates = { p1 } })
    local before = copy(W.cvars)
    W.plateByUnit = { nameplate2 = plate(0.8) }
    ns.Core.Start()
    eq(W.cvars.nameplateMinAlpha, "0"); eq(W.cvars.nameplateMaxAlpha, "0"); eq(p1.alpha, 0)
    fire("NAME_PLATE_UNIT_ADDED", "nameplate2"); eq(W.plateByUnit.nameplate2.alpha, 0)
    settle(ns); fire("SCREENSHOT_SUCCEEDED")
    sameTable(W.cvars, before); eq(p1.alpha, 1); eq(W.plateByUnit.nameplate2.alpha, 0.8)
end)

test("alpha fallback when no nameplate visibility CVars exist", function()
    local cv = defaultCVars(); cv.nameplateShowFriends = nil; cv.nameplateShowEnemies = nil
    local ns = load({ cvars = cv }); local before = copy(W.cvars)
    ns.Core.Start(); eq(W.cvars.nameplateMaxAlpha, "0")
    settle(ns); fire("SCREENSHOT_SUCCEEDED"); sameTable(W.cvars, before)
end)

test("interrupted session is restored on next load from SavedVariables", function()
    local ns = load(); local before = copy(W.cvars)
    ns.Core.Start()
    local saved, hidden = PhotoModeDB, copy(W.cvars) -- simulate /reload mid-sequence
    load({ cvars = hidden, db = saved })
    sameTable(W.cvars, before); eq(PhotoModeDB.pendingRestore, nil)
end)

test("camera error on restore stays pending; combat-end retry restores the zoom", function()
    local ns = load(); local before = copy(W.cvars)
    ns.Core.Start(); settle(ns)
    W.zoomOutErrors = 1
    fire("SCREENSHOT_SUCCEEDED")
    sameTable(W.cvars, before, "cvars restored"); eq(W.uiShown, true, "ui restored")
    eq(W.zoom, 0, "camera not restored yet")
    eq(ns.Core.state, "restoring", "session kept")
    assert(PhotoModeDB.pendingRestore, "recovery state kept"); eq(PhotoModeDB.pendingRestore.zoom, 12)
    assert(printedMatch("restore step failed")); assert(printedMatch("could not restore: camera zoom"))
    eq(ns.Core.Start(), false, "no new photo on top of a pending restore")
    W.combat = true; fire("PLAYER_REGEN_DISABLED"); W.combat = false
    fire("PLAYER_REGEN_ENABLED")
    eq(W.zoom, 12, "zoom restored on retry"); sameTable(W.cvars, before)
    eq(ns.Core.state, "idle"); eq(PhotoModeDB.pendingRestore, nil)
end)

test("camera error on restore: /photo restore retries it", function()
    local ns = load()
    ns.Core.Start(); settle(ns)
    W.zoomOutErrors = 1
    fire("SCREENSHOT_SUCCEEDED"); eq(W.zoom, 0)
    ns.UI.Slash("restore")
    eq(W.zoom, 12); eq(ns.Core.state, "idle"); eq(PhotoModeDB.pendingRestore, nil)
end)

test("camera error during combat cancel is retried when combat ends", function()
    local ns = load(); local before = copy(W.cvars)
    W.cvarsProtected = true
    ns.Core.Start(); advance(0.1)
    W.zoomOutErrors = 1
    W.combat = true; fire("PLAYER_REGEN_DISABLED")
    eq(W.zoom, 0); eq(PhotoModeDB.pendingRestore.zoom, 12)
    W.combat = false; fire("PLAYER_REGEN_ENABLED")
    eq(W.zoom, 12); sameTable(W.cvars, before); eq(W.uiShown, true); eq(ns.Core.state, "idle")
end)

test("reload while the camera is pending restores the zoom on load", function()
    local ns = load(); local before = copy(W.cvars)
    ns.Core.Start()
    local saved, hidden = PhotoModeDB, copy(W.cvars)
    load({ cvars = hidden, db = saved, zoom = 0 })
    sameTable(W.cvars, before); eq(W.zoom, 12); eq(PhotoModeDB.pendingRestore, nil)
end)

test("failed CVar restore out of combat blocks new photos until restored", function()
    local ns = load(); local before = copy(W.cvars)
    ns.Core.Start(); settle(ns)
    W.ignored.UnitNameNPC = true -- client refuses to put it back for now
    fire("SCREENSHOT_SUCCEEDED")
    eq(W.cvars.UnitNameNPC, "0"); eq(ns.Core.state, "restoring")
    eq(PhotoModeDB.pendingRestore.cvars.UnitNameNPC, "1", "original kept")
    eq(ns.Core.Start(), false, "second photo refused")
    eq(PhotoModeDB.pendingRestore.cvars.UnitNameNPC, "1", "original not overwritten by hide value")
    W.ignored.UnitNameNPC = nil
    ns.UI.Slash("restore")
    sameTable(W.cvars, before); eq(ns.Core.state, "idle"); eq(PhotoModeDB.pendingRestore, nil)
    assert(ns.Core.Start(), "photos work again")
end)

test("leftover pendingRestore is applied before a new snapshot", function()
    local cv = defaultCVars(); cv.UnitNameNPC = "0"
    local ns = setupWorld({ cvars = cv, db = { pendingRestore = { cvars = { UnitNameNPC = "1" } } } })
    -- skip ADDON_LOADED so the leftover is still there when the button is pressed
    assert(ns.Core.Start())
    settle(ns); fire("SCREENSHOT_SUCCEEDED")
    eq(W.cvars.UnitNameNPC, "1", "original survived the second photo")
end)

test("/photo forget drops a restore that never succeeds", function()
    local ns = load()
    ns.Core.Start(); settle(ns)
    W.ignored.UnitNameNPC = true
    fire("SCREENSHOT_SUCCEEDED"); eq(ns.Core.state, "restoring")
    ns.UI.Slash("forget")
    eq(ns.Core.state, "idle"); eq(PhotoModeDB.pendingRestore, nil)
    W.ignored.UnitNameNPC = nil
    assert(ns.Core.Start())
end)

test("logout mid-sequence writes CVars back", function()
    local ns = load(); local before = copy(W.cvars)
    ns.Core.Start(); fire("PLAYER_LOGOUT")
    sameTable(W.cvars, before); eq(PhotoModeDB.pendingRestore, nil)
end)

test("second press while running is ignored", function()
    local ns = load(); ns.Core.Start()
    eq(ns.Core.Start(), false); assert(printedMatch("already taking"))
end)

test("/photo debug opens a copyable window and saves the report", function()
    local ns = load()
    W.ns.UI.Slash("debug")
    local f = ns.UI.debugFrame; assert(f, "debug window created")
    eq(f:IsShown(), true, "window shown")
    local text = f.edit:GetText()
    assert(text:find("UnitNameNPC = 1", 1, true), "existing cvar in window")
    assert(text:find("nameplateShowFriendlyPets: MISSING", 1, true), "missing cvar in window")
    assert(text:find("cameraZoomSpeed = 20", 1, true), "camera cvar in window")
    assert(text:find("interface 16001", 1, true), "build info in window")
    eq(f.edit.highlighted, true, "text pre-selected"); eq(f.edit.focused, true, "edit box focused")
    -- saved to SavedVariables as lines matching the window
    eq(type(PhotoModeDB.lastDebug), "table"); eq(table.concat(PhotoModeDB.lastDebug, "\n"), text)
    assert(not printedMatch("UnitNameNPC = 1"), "report not spammed into chat")
    assert(printedMatch("Ctrl%+C"), "chat says where the report is")
    eq(#W.setLog, 0, "debug writes nothing"); eq(ns.Core.state, "idle")
    -- typing does not change the report (read-only)
    f.edit:SetText("junk"); f.edit.scripts.OnTextChanged(f.edit, true); eq(f.edit:GetText(), text)
    -- close button / Esc hide it and release keyboard focus; a second /photo debug reuses it
    f.edit.scripts.OnEscapePressed(f.edit); eq(f:IsShown(), false); eq(f.edit.focused, false)
    W.cvars.UnitNameNPC = "0"
    ns.UI.Slash("debug")
    eq(ns.UI.debugFrame, f, "same window"); eq(f:IsShown(), true)
    assert(f.edit:GetText():find("UnitNameNPC = 0", 1, true), "report refreshed")
end)

test("/photo debug falls back to chat if the window cannot be built", function()
    local ns = load()
    ns.UI.ShowDebug = function() error("no templates") end
    ns.UI.Slash("debug")
    assert(printedMatch("UnitNameNPC = 1")); assert(PhotoModeDB.lastDebug)
end)

---------------------------------------------------------------------------
-- Quest markers (minimap tracking filters + marker CVars)
---------------------------------------------------------------------------

test("quest marker filters are off for the shot and restored exactly", function()
    local ns = load(); local before = copy(W.cvars)
    assert(ns.Core.Start())
    eq(trackingState("TrivialQuests"), false, "trivial quests hidden")
    eq(PhotoModeDB.pendingRestore.tracking.TrivialQuests, true, "original persisted")
    settle(ns)
    eq(W.snapAt.tracking.TrivialQuests, false)
    eq(W.snapAt.tracking.AccountCompletedQuests, false, "already off stays off")
    eq(W.snapAt.tracking.Repair, true, "unrelated tracking untouched")
    eq(W.snapAt.cvars.ShowQuestUnitCircles, "0"); eq(W.snapAt.cvars.showTaxiNodeLearnedIcon, "0")
    fire("SCREENSHOT_SUCCEEDED")
    eq(trackingState("TrivialQuests"), true); eq(trackingState("AccountCompletedQuests"), false)
    eq(trackingState("Repair"), true)
    sameTable(W.cvars, before); eq(ns.Core.state, "idle"); eq(PhotoModeDB.pendingRestore, nil)
end)

test("quest filters the player had off are never turned on", function()
    local tracking = defaultTracking()
    tracking[2].active = false -- TrivialQuests off; AccountCompletedQuests is off by default
    local ns = load({ tracking = tracking })
    assert(ns.Core.Start()); settle(ns)
    eq(W.snapAt.tracking.TrivialQuests, false)
    fire("SCREENSHOT_SUCCEEDED")
    eq(trackingState("TrivialQuests"), false, "still off after the photo")
    eq(trackingState("AccountCompletedQuests"), false, "still off after the photo")
    eq(W.trackingWrites, nil, "tracking menu never written")
    -- same after a reload mid-photo
    ns.Core.Start()
    load({ cvars = copy(W.cvars), db = PhotoModeDB, tracking = W.tracking })
    eq(trackingState("TrivialQuests"), false); eq(trackingState("AccountCompletedQuests"), false)
    eq(W.trackingWrites, nil, "tracking menu never written after reload")
end)

test("only the quest filters the player had on are restored to on", function()
    local tracking = defaultTracking()
    tracking[3].active = true -- AccountCompletedQuests on, TrivialQuests on
    local ns = load({ tracking = tracking })
    ns.Core.Start(); settle(ns)
    eq(W.snapAt.tracking.TrivialQuests, false); eq(W.snapAt.tracking.AccountCompletedQuests, false)
    fire("SCREENSHOT_SUCCEEDED")
    eq(trackingState("TrivialQuests"), true); eq(trackingState("AccountCompletedQuests"), true)
end)

test("tracking menu reordered mid-photo still restores the right filter", function()
    local ns = load()
    ns.Core.Start(); settle(ns)
    table.insert(W.tracking, 1, { filterID = 99, active = false }) -- indexes shift
    fire("SCREENSHOT_SUCCEEDED")
    eq(trackingState("TrivialQuests"), true); eq(W.tracking[1].active, false)
end)

test("quest marker filters are restored after a reload mid-sequence", function()
    local ns = load()
    ns.Core.Start()
    local saved, hidden, tracking = PhotoModeDB, copy(W.cvars), W.tracking
    eq(trackingState("TrivialQuests"), false)
    load({ cvars = hidden, db = saved, tracking = tracking })
    eq(trackingState("TrivialQuests"), true); eq(PhotoModeDB.pendingRestore, nil)
end)

test("logout mid-sequence puts quest marker filters back", function()
    local ns = load()
    ns.Core.Start(); fire("PLAYER_LOGOUT")
    eq(trackingState("TrivialQuests"), true); eq(PhotoModeDB.pendingRestore, nil)
end)

test("tracking that will not restore keeps the session pending", function()
    local ns = load()
    ns.Core.Start(); settle(ns)
    W.trackingLocked[FILTER.TrivialQuests] = true
    fire("SCREENSHOT_SUCCEEDED")
    eq(ns.Core.state, "restoring"); assert(printedMatch("could not restore: tracking TrivialQuests"))
    eq(PhotoModeDB.pendingRestore.tracking.TrivialQuests, true)
    W.trackingLocked[FILTER.TrivialQuests] = nil
    ns.UI.Slash("restore")
    eq(trackingState("TrivialQuests"), true); eq(ns.Core.state, "idle")
end)

test("no C_Minimap tracking API: photo still works, nothing pending", function()
    local ns = load({ noMinimap = true }); local before = copy(W.cvars)
    assert(ns.Core.Start()); eq(PhotoModeDB.pendingRestore.tracking, nil)
    settle(ns); fire("SCREENSHOT_SUCCEEDED")
    sameTable(W.cvars, before); eq(ns.Core.state, "idle")
end)

test("/photo debug lists the quest marker tracking filters", function()
    local ns = load()
    ns.UI.Slash("debug")
    local text = ns.UI.debugFrame.edit:GetText()
    assert(text:find("tracking TrivialQuests = true", 1, true), text)
    assert(text:find("tracking AccountCompletedQuests = false", 1, true))
    assert(text:find("ShowQuestUnitCircles = 1", 1, true))
end)

---------------------------------------------------------------------------
-- Zoom settle before the screenshot
---------------------------------------------------------------------------

test("screenshot waits until the animated zoom reaches first person, plus postZoomDelay", function()
    local ns = load({ zoomRate = 6 }) -- 12 yards at 6 yd/s: reaches 0 after 2s
    local before = copy(W.cvars)
    assert(ns.Core.Start())
    advance(1.0)
    assert(GetCameraZoom() > 0, "still zooming"); eq(W.screenshots, 0, "no shot mid-zoom")
    advance(1.0 + ns.Config.postZoomDelay - 0.05)
    eq(W.screenshots, 0, "no shot before postZoomDelay has passed after reaching 0")
    advance(0.5)
    eq(W.screenshots, 1, "shot after settle + delay")
    eq(W.snapAt.zoom, 0, "shot at first person")
    assert(W.snapAt.time - W.reachedZeroAt >= ns.Config.postZoomDelay - 1e-9, "post-zoom delay honoured")
    assert(W.snapAt.time < ns.Config.zoomSettleTimeout, "settled before the cap")
    assert(not printedMatch("did not settle"), "no cap message")
    fire("SCREENSHOT_SUCCEEDED")
    sameTable(W.cvars, before); eq(W.zoom, 12); eq(ns.Core.state, "idle")
end)

test("zoom that stops short of first person is nudged in again", function()
    local ns = load({ zoomInFloors = { 3 } }) -- first CameraZoomIn only reaches 3 yards
    assert(ns.Core.Start())
    eq(W.zoom, 3)
    settle(ns)
    eq(W.zoomInCalls, 2, "nudged once"); eq(W.screenshots, 1); eq(W.snapAt.zoom, 0)
    assert(not printedMatch("did not settle"))
    fire("SCREENSHOT_SUCCEEDED"); eq(W.zoom, 12)
end)

test("zoom wait is capped: shoots anyway at zoomSettleTimeout", function()
    local ns = load({ zoomRate = 1 }) -- far too slow to reach 0 within the cap
    local before = copy(W.cvars)
    assert(ns.Core.Start())
    advance(ns.Config.zoomSettleTimeout - 0.1)
    eq(W.screenshots, 0, "still waiting before the cap")
    advance(0.2)
    eq(W.screenshots, 1, "shot at the cap"); assert(W.snapAt.zoom > 0, "camera never settled")
    assert(printedMatch("did not settle in first person"), "cap reported")
    eq(W.snapAt.ui, false, "UI still hidden at the shot")
    fire("SCREENSHOT_SUCCEEDED")
    sameTable(W.cvars, before); eq(W.zoom, 12); eq(ns.Core.state, "idle")
end)

test("zoom stuck short even after nudges: cap still shoots, nudges limited", function()
    local ns = load({ zoomInFloors = { 3, 3, 3, 3, 3, 3, 3, 3 } })
    assert(ns.Core.Start()); settle(ns)
    eq(W.screenshots, 1); eq(W.zoomInCalls, 1 + ns.Config.maxZoomNudges)
    assert(printedMatch("did not settle"))
end)

test("cameraZoomSpeed is raised for the zoom-in and restored afterwards", function()
    local ns = load()
    assert(ns.Core.Start())
    eq(W.zoomSpeedAtZoomIn, "50", "speed raised before CameraZoomIn")
    eq(PhotoModeDB.pendingRestore.cvars.cameraZoomSpeed, "20", "original saved for recovery")
    settle(ns); eq(W.snapAt.cvars.cameraZoomSpeed, "50")
    fire("SCREENSHOT_SUCCEEDED")
    eq(W.cvars.cameraZoomSpeed, "20", "restored"); eq(PhotoModeDB.pendingRestore, nil)
end)

test("cameraZoomSpeed is restored after a reload mid-sequence", function()
    local ns = load()
    ns.Core.Start()
    local saved, hidden = PhotoModeDB, copy(W.cvars)
    eq(hidden.cameraZoomSpeed, "50")
    load({ cvars = hidden, db = saved })
    eq(W.cvars.cameraZoomSpeed, "20")
end)

test("missing cameraZoomSpeed is skipped", function()
    local cv = defaultCVars(); cv.cameraZoomSpeed = nil
    local ns = load({ cvars = cv })
    assert(ns.Core.Start()); settle(ns); eq(W.screenshots, 1)
    for _, n in ipairs(W.setLog) do assert(n ~= "cameraZoomSpeed", "wrote missing cameraZoomSpeed") end
    eq(W.cvars.cameraZoomSpeed, nil)
end)

test("combat during the zoom wait cancels the photo; no shot later", function()
    local ns = load({ zoomRate = 6 }); local before = copy(W.cvars)
    ns.Core.Start(); advance(1.0)
    fire("PLAYER_REGEN_DISABLED")
    eq(ns.Core.state, "idle"); sameTable(W.cvars, before)
    advance(10); eq(W.screenshots, 0)
end)

test("/photo slash command and button click start the sequence", function()
    local ns = load()
    eq(SlashCmdList.PHOTOMODE, ns.UI.Slash); eq(SLASH_PHOTOMODE1, "/photo")
    SlashCmdList.PHOTOMODE(""); eq(ns.Core.state, "running")
    settle(ns); fire("SCREENSHOT_SUCCEEDED")
    local b = ns.UI.button; assert(b, "button created on ADDON_LOADED")
    W.now = 100; b.scripts.OnDragStop(b)
    b.scripts.OnClick(b); eq(ns.Core.state, "idle", "click right after drag ignored")
    W.now = 101; b.scripts.OnClick(b); eq(ns.Core.state, "running")
end)

test("button position saved and reapplied", function()
    local ns = load()
    local b = ns.UI.button
    b:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 40, -50)
    b.scripts.OnDragStop(b)
    local saved = PhotoModeDB
    ns = load({ db = saved })
    local p, _, rp, x, y = ns.UI.button:GetPoint()
    eq(p, "TOPLEFT"); eq(rp, "TOPLEFT"); eq(x, 40); eq(y, -50)
end)

---------------------------------------------------------------------------
for _, t in ipairs(tests) do
    local ok, err = pcall(t[2])
    if ok then print("ok   " .. t[1]) else failures = failures + 1; print("FAIL " .. t[1] .. "\n     " .. tostring(err)) end
end
print(("%d tests, %d failed"):format(#tests, failures))
if failures > 0 then os.exit(1) end
