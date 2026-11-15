-- PhotoMode core: snapshot -> hide -> first person -> screenshot -> restore.
-- No frames are drawn here (see UI.lua), so this file can be tested with a mocked WoW API.
local ADDON, ns = ...
local Config = ns.Config

local Core = {}
ns.Core = Core

Core.state = "idle" -- "idle" | "running" | "restoring" (waiting for combat to end)

local session        -- everything needed to undo the current photo
local sessionId = 0  -- stale timer callbacks compare against this

local events = CreateFrame("Frame")
Core.eventFrame = events

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

function Core.Print(msg)
    local text = "PhotoMode: " .. msg
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(text)
    else
        print(text)
    end
end

local function isSecret(v)
    if issecretvalue == nil then return false end
    local ok, secret = pcall(issecretvalue, v)
    return ok and secret == true
end

local function sameValue(a, b)
    if a == b then return true end
    local na, nb = tonumber(a), tonumber(b)
    return na ~= nil and na == nb
end
Core.SameValue = sameValue

local function db()
    PhotoModeDB = PhotoModeDB or {}
    return PhotoModeDB
end

-- Returns the CVar's value as a string, or nil if it does not exist on this client.
function Core.GetCVar(name)
    local fn = (C_CVar and C_CVar.GetCVar) or GetCVar
    if not fn then return nil end
    local ok, v = pcall(fn, name)
    if not ok or v == nil or isSecret(v) then return nil end
    return tostring(v)
end

-- Writes a CVar and reads it back. Returns true only if the client actually holds the value.
function Core.SetCVar(name, value)
    local fn = (C_CVar and C_CVar.SetCVar) or SetCVar
    if not fn then return false end
    local ok = pcall(fn, name, value)
    return ok and sameValue(Core.GetCVar(name), value)
end

local function safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then Core.Print("restore step failed: " .. tostring(err)) end
    return ok
end

-- Runs fn; any error prints and triggers a full restore.
function Core.Run(fn)
    local ok, err = xpcall(fn, function(e) return tostring(e) end)
    if not ok then
        Core.Print("error, restoring settings: " .. err)
        Core.Restore()
    end
    return ok
end

-- Wraps fn so it only runs if the session that scheduled it is still the active one.
local function forSession(id, fn)
    return function()
        if session and session.id == id and Core.state == "running" then
            Core.Run(fn)
        end
    end
end

local function cameraPending(s)
    return s.zoomChanged and not s.zoomRestored
end

-- Saves what is still needed to undo this session, so /reload, a crash or a later
-- /photo restore can finish the job. UI visibility is not saved: a reload always shows it.
local function persistPending(s)
    local copy = {}
    for name, value in pairs(s.cvars) do copy[name] = value end
    db().pendingRestore = { cvars = copy, zoom = cameraPending(s) and s.zoom or nil }
end

local function newSession(cvars)
    sessionId = sessionId + 1
    local s = {
        id = sessionId,
        cvars = {},     -- name -> original value (only CVars that exist)
        order = {},     -- names in apply order
        group = {},     -- name -> group
        unhonored = {}, -- name -> true when the client ignored our hide write
        frameAlpha = {},-- nameplate frame -> original alpha
    }
    if cvars then
        for name, value in pairs(cvars) do
            s.cvars[name] = value
            s.order[#s.order + 1] = name
        end
        table.sort(s.order)
    end
    return s
end

-- Rebuilds a session from SavedVariables (after /reload, crash or logout).
local function sessionFromPending(pending)
    local s = newSession(pending.cvars)
    if type(pending.zoom) == "number" then
        s.zoom = pending.zoom
        s.zoomChanged = true
    end
    return s
end

local function hasPending(pending)
    return pending ~= nil and ((pending.cvars ~= nil and next(pending.cvars) ~= nil)
        or type(pending.zoom) == "number")
end

---------------------------------------------------------------------------
-- Steps
---------------------------------------------------------------------------

local function snapshot(s, list)
    for _, entry in ipairs(list) do
        local name, hide, group = entry[1], entry[2], entry[3]
        if s.cvars[name] == nil then
            local value = Core.GetCVar(name)
            if value ~= nil then -- missing CVars are skipped silently
                s.cvars[name] = value
                s.order[#s.order + 1] = name
                s.group[name] = group
                s.hide = s.hide or {}
                s.hide[name] = hide
            end
        end
    end
end

local function applyHide(s, fromIndex)
    for i = fromIndex or 1, #s.order do
        local name = s.order[i]
        local hide = s.hide[name]
        if not sameValue(s.cvars[name], hide) and not Core.SetCVar(name, hide) then
            s.unhonored[name] = true
        end
    end
end

local function needAlphaFallback(s)
    local mode = Config.alphaFallback
    if mode == "always" then return true end
    if mode ~= "auto" then return false end
    local anyCore = false
    for _, name in ipairs(Config.coreNameplateCVars) do
        if s.cvars[name] ~= nil then anyCore = true end
    end
    if not anyCore then return true end
    for name in pairs(s.unhonored) do
        if s.group[name] == "nameplate" then return true end
    end
    return false
end

local function hidePlate(s, plate)
    if not plate or s.frameAlpha[plate] ~= nil then return end
    local ok, alpha = pcall(plate.GetAlpha, plate)
    s.frameAlpha[plate] = (ok and type(alpha) == "number") and alpha or 1
    pcall(plate.SetAlpha, plate, 0)
end

local function applyAlphaFallback(s)
    s.alphaFallback = true
    local first = #s.order + 1
    local list = {}
    for i, entry in ipairs(Config.alphaCVars) do list[i] = { entry[1], entry[2], "alpha" } end
    snapshot(s, list)
    persistPending(s)
    applyHide(s, first)

    if C_NamePlate and C_NamePlate.GetNamePlates then
        local ok, plates = pcall(C_NamePlate.GetNamePlates)
        if ok and type(plates) == "table" then
            for _, plate in ipairs(plates) do hidePlate(s, plate) end
        end
        events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    end
end

local function shoot()
    local s = session
    s.waitingShot = true
    events:RegisterEvent("SCREENSHOT_SUCCEEDED")
    events:RegisterEvent("SCREENSHOT_FAILED")
    C_Timer.After(Config.screenshotTimeout, forSession(s.id, function()
        if session.waitingShot then Core.Finish("timeout") end
    end))
    Screenshot()
end

local function readZoom()
    local ok, z = pcall(GetCameraZoom)
    if not ok or isSecret(z) then return nil end
    return tonumber(z)
end

-- Polls GetCameraZoom() until it sits at first person and has stopped changing for
-- Config.zoomStableTicks polls, then shoots after Config.postZoomDelay. A zoom that settles
-- short of first person is nudged with CameraZoomIn() again. After Config.zoomSettleTimeout
-- the screenshot is taken anyway.
local function waitForZoom()
    local s = session
    local start = GetTime()
    local last, stable, nudges = nil, 0, 0

    local function poll()
        local z = readZoom()
        if z ~= nil and last ~= nil and math.abs(z - last) <= Config.zoomStillEpsilon then
            stable = stable + 1
        else
            stable = 0
        end
        last = z

        if z ~= nil and stable >= Config.zoomStableTicks then
            if z <= Config.firstPersonEpsilon then
                s.zoomSettled = true
                Core.lastZoomWait = ("settled at %s after %.2fs, %d nudge(s)"):format(
                    tostring(z), GetTime() - start, nudges)
                C_Timer.After(Config.postZoomDelay, forSession(s.id, shoot))
                return
            elseif nudges < Config.maxZoomNudges then
                nudges = nudges + 1
                CameraZoomIn(Config.firstPersonZoomIn)
                stable = 0
            end
        end

        if GetTime() - start >= Config.zoomSettleTimeout then
            s.zoomSettled = false
            Core.lastZoomWait = ("hit the %ss cap at zoom %s, %d nudge(s)"):format(
                tostring(Config.zoomSettleTimeout), tostring(z), nudges)
            Core.Print(("camera did not settle in first person within %ss (zoom %s); taking the screenshot anyway.")
                :format(tostring(Config.zoomSettleTimeout), tostring(z)))
            shoot()
            return
        end
        C_Timer.After(Config.zoomPollInterval, forSession(s.id, poll))
    end

    C_Timer.After(Config.zoomPollInterval, forSession(s.id, poll))
end

local function prepare()
    local s = session

    -- 1. snapshot + hide names/nameplates/bubbles, and set camera CVars (zoom speed)
    snapshot(s, Config.cvars)
    snapshot(s, Config.cameraCVars)
    persistPending(s) -- survives /reload or a crash mid-sequence
    applyHide(s)
    if needAlphaFallback(s) then applyAlphaFallback(s) end

    -- 2. hide UI
    s.uiHidden = UIParent:IsShown()
    if s.uiHidden then UIParent:Hide() end

    -- 3. first person
    s.zoom = GetCameraZoom()
    s.zoomChanged = true
    persistPending(s) -- now includes the saved zoom
    CameraZoomIn(Config.firstPersonZoomIn)

    -- 4. wait for the zoom to settle at first person, then shoot
    waitForZoom()
end

---------------------------------------------------------------------------
-- Restore
---------------------------------------------------------------------------

local function restoreCamera(s)
    if not cameraPending(s) then return end
    -- Zoom fully in again first so the result does not depend on whether the earlier zoom-in
    -- animation finished; from first person, zooming out by the saved distance is exact.
    -- This also makes a retry after a partial failure exact.
    CameraZoomIn(Config.firstPersonZoomIn)
    if s.zoom and s.zoom > 0 then CameraZoomOut(s.zoom) end
    s.zoomRestored = true -- only once both calls succeeded; an error leaves it pending
end

local function restoreFrameAlpha(s)
    events:UnregisterEvent("NAME_PLATE_UNIT_ADDED")
    for plate, alpha in pairs(s.frameAlpha) do
        pcall(plate.SetAlpha, plate, alpha)
    end
    s.frameAlpha = {}
end

local function inCombat()
    if InCombatLockdown() then return true end
    if not UnitAffectingCombat then return false end
    -- pcall: the result could be a secret value, which errors when compared
    local ok, fighting = pcall(function() return UnitAffectingCombat("player") == true end)
    return ok and fighting
end

local function waitForCombatEnd()
    events:RegisterEvent("PLAYER_REGEN_ENABLED")
    if Core.state ~= "restoring" then
        Core.state = "restoring"
        Core.Print("combat started - names, nameplates and UI come back when combat ends (Alt+Z shows the UI now).")
    end
end

-- Puts everything back. Safe to call repeatedly; protected parts wait for combat to end.
function Core.Restore()
    local s = session
    if not s then return end
    s.waitingShot = false
    events:UnregisterEvent("SCREENSHOT_SUCCEEDED")
    events:UnregisterEvent("SCREENSHOT_FAILED")

    -- Not protected: do these right away.
    safe(restoreCamera, s)
    safe(restoreFrameAlpha, s)

    if InCombatLockdown() then
        persistPending(s)
        waitForCombatEnd()
        return
    end

    -- Each part (CVar, UI, camera) counts as done only when it actually holds the original
    -- again; anything else stays pending and is retried by the next Restore() call.
    local failed = {}
    for _, name in ipairs(s.order) do
        local orig = s.cvars[name]
        if not sameValue(Core.GetCVar(name), orig) and not Core.SetCVar(name, orig) then
            failed[#failed + 1] = name
        end
    end
    if s.uiHidden and not UIParent:IsShown() then
        safe(UIParent.Show, UIParent)
        if not UIParent:IsShown() then failed[#failed + 1] = "UIParent" end
    end
    if cameraPending(s) then failed[#failed + 1] = "camera zoom" end

    if #failed > 0 then
        -- Keep the session and its SavedVariables copy so the combat-end retry,
        -- /photo restore and the next login can still finish it.
        persistPending(s)
        if inCombat() then
            waitForCombatEnd() -- writes were likely blocked by combat; retry when it ends
        else
            Core.state = "restoring"
            events:RegisterEvent("PLAYER_REGEN_ENABLED") -- also retry after the next fight
            Core.Print("could not restore: " .. table.concat(failed, ", ")
                .. ". Try /photo restore (or /photo forget to give up).")
        end
        return
    end

    session = nil
    Core.state = "idle"
    events:UnregisterEvent("PLAYER_REGEN_ENABLED")
    events:UnregisterEvent("PLAYER_REGEN_DISABLED")
    db().pendingRestore = nil
end

-- Drops any pending restore without applying it. Escape hatch for a part that never
-- restores, which would otherwise block new photos forever.
function Core.Forget()
    local had = session ~= nil or hasPending(db().pendingRestore)
    if session then restoreFrameAlpha(session) end
    session = nil
    Core.state = "idle"
    events:UnregisterEvent("PLAYER_REGEN_ENABLED")
    events:UnregisterEvent("PLAYER_REGEN_DISABLED")
    db().pendingRestore = nil
    return had
end

---------------------------------------------------------------------------
-- Public entry points
---------------------------------------------------------------------------

function Core.Start()
    if Core.state ~= "idle" then
        if Core.state == "restoring" then
            Core.Print("the last photo's settings are not fully restored yet - they come back when combat ends, or try /photo restore.")
        else
            Core.Print("already taking a photo.")
        end
        return false
    end
    if InCombatLockdown() then
        Core.Print("not available in combat")
        return false
    end
    -- Never snapshot on top of an unfinished restore: the "originals" would be our hide values.
    if hasPending(db().pendingRestore) then
        Core.RestorePending()
        if Core.state ~= "idle" or hasPending(db().pendingRestore) then return false end
    end
    session = newSession()
    Core.state = "running"
    events:RegisterEvent("PLAYER_REGEN_DISABLED")
    return Core.Run(prepare)
end

function Core.Finish(result)
    if not session then return end
    if result == "failed" then
        Core.Print("screenshot failed.")
    elseif result == "timeout" then
        Core.Print("no screenshot confirmation after " .. Config.screenshotTimeout .. "s; restoring anyway.")
    end
    Core.Restore()
end

-- Restores CVars left over from an interrupted session (reload, crash, disconnect).
function Core.RestorePending()
    if session then
        Core.Restore()
        return
    end
    local pending = db().pendingRestore
    if not hasPending(pending) then
        db().pendingRestore = nil
        return false
    end
    session = sessionFromPending(pending)
    Core.state = "running"
    Core.Restore()
    if Core.state == "idle" and not db().pendingRestore then
        Core.Print("restored settings from an interrupted photo.")
    end
    return true
end

function Core.IsActive() return session ~= nil end

---------------------------------------------------------------------------
-- Debug
---------------------------------------------------------------------------

function Core.Debug()
    local lines = {}
    local function add(line) lines[#lines + 1] = line end

    local version, build, _, toc = "?", "?", nil, "?"
    if GetBuildInfo then version, build, _, toc = GetBuildInfo() end
    add(("debug - client %s build %s interface %s"):format(tostring(version), tostring(build), tostring(toc)))

    local present, total = 0, 0
    local function dump(list)
        for _, entry in ipairs(list) do
            total = total + 1
            local value = Core.GetCVar(entry[1])
            if value ~= nil then
                present = present + 1
                add(("  %s = %s"):format(entry[1], value))
            else
                add(("  %s: MISSING"):format(entry[1]))
            end
        end
    end
    dump(Config.cvars)
    dump(Config.alphaCVars)
    dump(Config.cameraCVars)
    add(("%d of %d candidate CVars exist"):format(present, total))

    local function has(v) return v ~= nil and "yes" or "NO" end
    add(("api: C_CVar.GetCVar=%s C_CVar.SetCVar=%s GetCameraZoom=%s CameraZoomIn=%s CameraZoomOut=%s Screenshot=%s C_NamePlate.GetNamePlates=%s issecretvalue=%s"):format(
        has(C_CVar and C_CVar.GetCVar), has(C_CVar and C_CVar.SetCVar), has(GetCameraZoom),
        has(CameraZoomIn), has(CameraZoomOut), has(Screenshot),
        has(C_NamePlate and C_NamePlate.GetNamePlates), has(issecretvalue)))
    local zoomOk, zoom = pcall(GetCameraZoom)
    add(("camera zoom = %s, state = %s, pending restore = %s"):format(
        zoomOk and tostring(zoom) or "error", Core.state, db().pendingRestore and "yes" or "no"))
    add("last zoom wait: " .. (Core.lastZoomWait or "none this session"))

    -- Saved as a list of lines so it stays readable in
    -- WTF\Account\<ACCOUNT>\SavedVariables\PhotoMode.lua (written on /reload or logout).
    db().lastDebug = lines
    local report = table.concat(lines, "\n")
    if ns.UI and ns.UI.ShowDebug then
        local ok = pcall(ns.UI.ShowDebug, report)
        if ok then
            Core.Print("debug report opened in a window (Ctrl+A, Ctrl+C to copy). Also saved as lastDebug in SavedVariables\\PhotoMode.lua after /reload or logout.")
            return lines, report
        end
    end
    for _, line in ipairs(lines) do Core.Print(line) end -- window failed: fall back to chat
    return lines, report
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

function Core.OnEvent(event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then return end
        events:UnregisterEvent("ADDON_LOADED")
        db()
        if ns.UI and ns.UI.Create then ns.UI.Create() end
        if hasPending(db().pendingRestore) then
            if InCombatLockdown() then
                session = sessionFromPending(db().pendingRestore)
                waitForCombatEnd()
            else
                Core.RestorePending()
            end
        end
    elseif event == "SCREENSHOT_SUCCEEDED" or event == "SCREENSHOT_FAILED" then
        if session and session.waitingShot then
            Core.Finish(event == "SCREENSHOT_SUCCEEDED" and "ok" or "failed")
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        if session and Core.state == "running" then
            Core.Print("combat started - photo cancelled.")
            Core.Restore()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if session and Core.state == "restoring" then Core.Restore() end
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        if session and session.alphaFallback and C_NamePlate and C_NamePlate.GetNamePlateForUnit then
            local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, ...)
            if ok then hidePlate(session, plate) end
        end
    elseif event == "PLAYER_LOGOUT" then
        -- Last chance to put CVars back; pendingRestore covers it on next login if this fails.
        if session then
            safe(restoreCamera, session) -- stays pending (and is saved below) if it errors
            local left = {}
            for _, name in ipairs(session.order) do
                local orig = session.cvars[name]
                if not sameValue(Core.GetCVar(name), orig) and not Core.SetCVar(name, orig) then
                    left[name] = orig
                end
            end
            local zoom = cameraPending(session) and session.zoom or nil
            db().pendingRestore = (next(left) or zoom) and { cvars = left, zoom = zoom } or nil
        end
    end
end

events:SetScript("OnEvent", function(_, event, ...) Core.OnEvent(event, ...) end)
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGOUT")
