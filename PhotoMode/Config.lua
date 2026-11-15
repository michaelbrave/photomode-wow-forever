-- PhotoMode tunables and CVar candidate list.
-- Everything a designer/user might want to tune lives here; Core.lua holds no magic numbers.
local _, ns = ...

local Config = {}
ns.Config = Config

-- Waiting for first person. After CameraZoomIn() the camera animates in, and the character
-- model fades while the camera passes close to the head; shooting during that leaves a ghost
-- of the head in the picture. So GetCameraZoom() is polled until it is at first person and
-- has stopped changing, then postZoomDelay passes, then Screenshot() is called.

-- Seconds between GetCameraZoom() polls (a couple of frames at 60 fps).
Config.zoomPollInterval = 0.03

-- Consecutive polls the zoom must stay unchanged before it counts as settled.
Config.zoomStableTicks = 3

-- Two polls this close (in yards) count as "unchanged".
Config.zoomStillEpsilon = 0.01

-- A zoom at or below this counts as first person.
Config.firstPersonEpsilon = 0.05

-- Extra seconds after the zoom settled at first person, so the character fade finishes.
Config.postZoomDelay = 0.5

-- If the zoom has settled but is not at first person, call CameraZoomIn() again, at most
-- this many times.
Config.maxZoomNudges = 3

-- Cap on the whole zoom wait (seconds from the first CameraZoomIn). After it, the screenshot
-- is taken anyway (without postZoomDelay).
Config.zoomSettleTimeout = 3

-- Seconds to wait for SCREENSHOT_SUCCEEDED / SCREENSHOT_FAILED before restoring anyway.
Config.screenshotTimeout = 5

-- Amount passed to CameraZoomIn() to reach first person. The engine clamps it, so any
-- value larger than the max camera distance works.
Config.firstPersonZoomIn = 50

-- Camera CVars set for the photo and restored afterwards, like the name CVars
-- ({ name, photo value, group }). Each is skipped if it does not exist on this client.
-- cameraZoomSpeed: makes the zoom-in finish fast. 50 is the highest value retail/classic
-- accept; UNCERTAIN on Forever - if the client clamps it, the zoom is just slower.
-- No character-fade CVar is touched: none is known to exist, so none is guessed at.
Config.cameraCVars = {
    { "cameraZoomSpeed", "50", "camera" },
}

-- /photo debug window.
Config.debugWindow = {
    width = 640,
    height = 420,
    backgroundAlpha = 0.9,
}

-- Alpha fallback for nameplates:
--   "auto"   = only if a nameplate visibility CVar is missing or the client ignores the write
--   "always" = always set nameplate alpha CVars / frame alpha to 0 as well
--   "never"  = never use alpha
Config.alphaFallback = "auto"

-- Button defaults.
Config.button = {
    size = 36,
    icon = "Interface\\Icons\\INV_Misc_Spyglass_03",
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = -200,
    -- A click arriving within this many seconds of a drag ending is treated as part of the drag.
    dragClickGuard = 0.2,
}

-- Candidate CVars: { name, hide value, group }.
-- Each one is read with C_CVar.GetCVar first; if it returns nil the CVar does not exist on this
-- client and is skipped without an error. Only CVars that exist are snapshotted and changed.
-- group "nameplate" is used to decide whether the alpha fallback is needed.
Config.cvars = {
    -- Unit names above heads (list confirmed on Forever by BleakfibersUnitToggles-Forever, Interface 16001)
    { "UnitNameOwn",                    "0", "name" },
    { "UnitNameNPC",                    "0", "name" },
    { "UnitNameInteractiveNPC",         "0", "name" },
    { "UnitNameNonCombatCreatureName",  "0", "name" }, -- critters / non-combat creatures
    { "UnitNameFriendlyPlayerName",     "0", "name" },
    { "UnitNameFriendlyPetName",        "0", "name" },
    { "UnitNameFriendlyMinionName",     "0", "name" },
    { "UnitNameFriendlyGuardianName",   "0", "name" },
    { "UnitNameFriendlyTotemName",      "0", "name" },
    { "UnitNameFriendlySpecialNPCName", "0", "name" },
    { "UnitNameEnemyPlayerName",        "0", "name" },
    { "UnitNameEnemyPetName",           "0", "name" },
    { "UnitNameEnemyMinionName",        "0", "name" },
    { "UnitNameEnemyGuardianName",      "0", "name" },
    { "UnitNameEnemyTotemName",         "0", "name" },
    { "UnitNameHostleNPC",              "0", "name" }, -- Blizzard's own misspelling
    { "UnitNameHostileNPC",             "0", "name" }, -- in case the spelling is ever fixed
    { "UnitNamePlayerGuild",            "0", "name" },
    { "UnitNameGuildTitle",             "0", "name" },
    { "UnitNamePlayerPVPTitle",         "0", "name" },
    { "UnitNameForceHideMinus",         "1", "name" }, -- inverted: 1 = hide minor mobs' names

    -- Nameplates. Forever lacks nameplateShowFriendly{Minions,Pets,Guardians,Totems}; they are
    -- listed anyway so the addon keeps working if they appear, and are skipped while missing.
    { "nameplateShowAll",               "0", "nameplate" },
    { "nameplateShowFriends",           "0", "nameplate" },
    { "nameplateShowFriendlyNPCs",      "0", "nameplate" },
    { "nameplateShowFriendlyMinions",   "0", "nameplate" },
    { "nameplateShowFriendlyPets",      "0", "nameplate" },
    { "nameplateShowFriendlyGuardians", "0", "nameplate" },
    { "nameplateShowFriendlyTotems",    "0", "nameplate" },
    { "nameplateShowEnemies",           "0", "nameplate" },
    { "nameplateShowEnemyMinions",      "0", "nameplate" },
    { "nameplateShowEnemyMinus",        "0", "nameplate" },
    { "nameplateShowEnemyPets",         "0", "nameplate" },
    { "nameplateShowEnemyGuardians",    "0", "nameplate" },
    { "nameplateShowEnemyTotems",       "0", "nameplate" },
    { "nameplateShowSelf",              "0", "nameplate" }, -- personal resource display

    -- Chat bubbles
    { "chatBubbles",                    "0", "bubble" },
    { "chatBubblesParty",               "0", "bubble" },
}

-- Nameplate alpha CVars used only by the alpha fallback (same existence rules).
Config.alphaCVars = {
    { "nameplateMinAlpha",          "0" },
    { "nameplateMaxAlpha",          "0" },
    { "nameplateSelectedAlpha",     "0" },
    { "nameplateNotSelectedAlpha",  "0" },
    { "nameplateOccludedAlphaMult", "0" },
}

-- If none of these exist, nameplate hiding by CVar is considered impossible (triggers "auto" fallback).
Config.coreNameplateCVars = { "nameplateShowFriends", "nameplateShowEnemies" }
