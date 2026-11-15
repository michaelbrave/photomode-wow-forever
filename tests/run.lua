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

local function newFrame()
    local f = { events = {}, scripts = {} }
    function f:RegisterEvent(e) self.events[e] = true end
    function f:UnregisterEvent(e) self.events[e] = nil end
    function f:SetScript(name, fn) self.scripts[name] = fn end
    W.frames[#W.frames + 1] = f
    return f
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
    }) do cv[n] = "1" end
    cv.UnitNameOwn = "0"
    cv.UnitNameForceHideMinus = "0"
    cv.nameplateMinAlpha = "0.6"
    cv.nameplateMaxAlpha = "1"
    return cv
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
    _G.GetCameraZoom = function() return W.zoom end
    _G.CameraZoomIn = function(d) W.zoom = math.max(0, W.zoom - d) end
    _G.CameraZoomOut = function(d) W.zoom = math.min(39, W.zoom + d) end
    _G.Screenshot = function()
        if W.screenshotError then error("boom") end
        W.screenshots = W.screenshots + 1
        W.snapAt = { cvars = {}, ui = W.uiShown, zoom = W.zoom }
        for k, v in pairs(W.cvars) do W.snapAt.cvars[k] = v end
    end
    _G.C_Timer = { After = function(d, fn) W.timers[#W.timers + 1] = { at = W.now + d, fn = fn } end }
    _G.GetTime = function() return W.now end
    _G.GetBuildInfo = function() return "1.60.1", "69913", "Nov 2026", 16001 end
    _G.C_NamePlate = {
        GetNamePlates = function() return W.plates end,
        GetNamePlateForUnit = function(unit) return W.plateByUnit and W.plateByUnit[unit] end,
    }
    _G.issecretvalue = function() return false end
    _G.CreateFrame = function(kind) if kind == "Button" then return newButton() end return newFrame() end
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
    advance(ns.Config.settleDelay)
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
    advance(ns.Config.settleDelay); fire("SCREENSHOT_SUCCEEDED")
    for _, n in ipairs(W.setLog) do assert(W.cvars[n] ~= nil, "wrote missing cvar " .. n) end
    assert(not printedMatch("error"), "no error printed")
    for _, n in ipairs({ "nameplateShowFriendlyMinions", "nameplateShowFriendlyPets",
        "nameplateShowFriendlyGuardians", "nameplateShowFriendlyTotems", "UnitNameHostileNPC" }) do
        eq(W.cvars[n], nil, n .. " was created")
    end
end)

test("SCREENSHOT_FAILED restores", function()
    local ns = load(); local before = copy(W.cvars)
    ns.Core.Start(); advance(ns.Config.settleDelay); fire("SCREENSHOT_FAILED")
    sameTable(W.cvars, before); eq(W.uiShown, true); eq(W.zoom, 12)
    assert(printedMatch("screenshot failed"))
end)

test("timeout restores when no screenshot event arrives", function()
    local ns = load(); local before = copy(W.cvars)
    ns.Core.Start(); advance(ns.Config.settleDelay)
    eq(ns.Core.state, "running")
    advance(ns.Config.screenshotTimeout)
    sameTable(W.cvars, before); eq(W.uiShown, true); eq(W.zoom, 12); eq(ns.Core.state, "idle")
end)

test("error mid-sequence restores everything", function()
    local ns = load({ screenshotError = true }); local before = copy(W.cvars)
    ns.Core.Start(); advance(ns.Config.settleDelay)
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
    ns.Core.Start(); advance(ns.Config.settleDelay)
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
    advance(ns.Config.settleDelay); fire("SCREENSHOT_SUCCEEDED")
    sameTable(W.cvars, before); eq(p1.alpha, 1); eq(W.plateByUnit.nameplate2.alpha, 0.8)
end)

test("alpha fallback when no nameplate visibility CVars exist", function()
    local cv = defaultCVars(); cv.nameplateShowFriends = nil; cv.nameplateShowEnemies = nil
    local ns = load({ cvars = cv }); local before = copy(W.cvars)
    ns.Core.Start(); eq(W.cvars.nameplateMaxAlpha, "0")
    advance(ns.Config.settleDelay); fire("SCREENSHOT_SUCCEEDED"); sameTable(W.cvars, before)
end)

test("interrupted session is restored on next load from SavedVariables", function()
    local ns = load(); local before = copy(W.cvars)
    ns.Core.Start()
    local saved, hidden = PhotoModeDB, copy(W.cvars) -- simulate /reload mid-sequence
    load({ cvars = hidden, db = saved })
    sameTable(W.cvars, before); eq(PhotoModeDB.pendingRestore, nil)
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

test("/photo debug lists existing and missing CVars", function()
    local ns = load()
    W.ns.UI.Slash("debug")
    assert(printedMatch("UnitNameNPC = 1")); assert(printedMatch("nameplateShowFriendlyPets: MISSING"))
    assert(printedMatch("interface 16001")); assert(PhotoModeDB.lastDebug)
    eq(#W.setLog, 0, "debug writes nothing"); eq(ns.Core.state, "idle")
end)

test("/photo slash command and button click start the sequence", function()
    local ns = load()
    eq(SlashCmdList.PHOTOMODE, ns.UI.Slash); eq(SLASH_PHOTOMODE1, "/photo")
    SlashCmdList.PHOTOMODE(""); eq(ns.Core.state, "running")
    advance(ns.Config.settleDelay); fire("SCREENSHOT_SUCCEEDED")
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
