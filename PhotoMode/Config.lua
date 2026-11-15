-- PhotoMode tunables and CVar candidate list.
-- Everything a designer/user might want to tune lives here; Core.lua holds no magic numbers.
local _, ns = ...

local Config = {}
ns.Config = Config

-- Seconds to wait after hiding names/UI and zooming in, so the camera and names settle
-- before Screenshot() is called.
Config.settleDelay = 0.75

-- Seconds to wait for SCREENSHOT_SUCCEEDED / SCREENSHOT_FAILED before restoring anyway.
Config.screenshotTimeout = 5

-- Amount passed to CameraZoomIn() to reach first person. The engine clamps it, so any
-- value larger than the max camera distance works.
Config.firstPersonZoomIn = 50

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
