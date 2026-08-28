--[[
=============================================================================
 adrenaline_all_classes.lua  -  ET: Legacy server-side Lua module
-----------------------------------------------------------------------------
 Gives an adrenaline shot (WP_MEDIC_ADRENALINE) to every player class
 EXCEPT medics:

     Soldier    (class 0) -> gets adrenaline
     Medic      (class 1) -> NO adrenaline (skipped on purpose)
     Engineer   (class 2) -> gets adrenaline
     Field Ops  (class 3) -> gets adrenaline
     Covert Ops (class 4) -> gets adrenaline

 In stock ET: Legacy the adrenaline shot is a First Aid level-4 perk that
 only medics can unlock. This module grants the weapon on every spawn,
 revive and team change, so no skill level is required for the other four
 classes. Medics are deliberately skipped - they keep their normal
 skill-based adrenaline behaviour.

 HOW IT WORKS
   * The et_ClientSpawn hook runs right after the engine has built the
     player's spawn loadout (SetWolfSpawnWeapons), so the weapon can be
     added on top of whatever the class normally carries.
   * et.AddWeaponToPlayer(clientNum, weapon, ammo, ammoclip, setcurrent)
     sets the weapon bit and its ammo/clip. Adrenaline shares its ammo pool
     with the medic syringe (ammo/clip index 11); non-medics never carry a
     syringe so that pool is free for them.
   * The adrenaline weapon (id 44) lives in weapon bank 7 together with
     the landmine, so players pull it out with slot key 7 (or the mouse
     wheel).
   * One ready-to-use shot is given per spawn/revive. Firing it applies the
     10 second PW_ADRENALINE powerup (fast health regen + no fatigue),
     exactly like the medic version.

 INSTALL
   1. Copy this file into your mod's luascripts folder, e.g.:
        <fs_home>/legacy/luascripts/adrenaline_all_classes.lua
      (on Linux that is usually ~/.etlegacy/legacy/luascripts/)
   2. Load the module from your server config (legacy.cfg):
        set lua_modules "luascripts/adrenaline_all_classes.lua"
      Space-separate several modules, e.g.:
        set lua_modules "luascripts/wolfadmin/main.lua luascripts/adrenaline_all_classes.lua"
   3. Restart the map/server. On load the console prints:
        [adrenaline_all_classes] loaded: adrenaline for all classes except medics
=============================================================================
]]--

-- Player classes (bg_public.h: PC_SOLDIER=0, PC_MEDIC=1, PC_ENGINEER=2,
-- PC_FIELDOPS=3, PC_COVERTOPS=4)
local PC_MEDIC = 1

-- Teams (bg_public.h: TEAM_FREE=0, TEAM_AXIS=1, TEAM_ALLIES=2,
-- TEAM_SPECTATOR=3)
local TEAM_SPECTATOR = (et and et.TEAM_SPECTATOR) or 3

-- WP_MEDIC_ADRENALINE is weapon id 44 (bg_public.h). Use the constant the
-- Lua API registers, with a numeric fallback just in case.
local WP_MEDIC_ADRENALINE = (et and et.WP_MEDIC_ADRENALINE) or 44

-- One ready-to-use shot in the "clip", no reserve ammo. This mirrors how
-- the game itself spawns adrenaline for medics (classMiscWeapons entry:
-- startingAmmo = 0, startingClip = 1).
local ADRENALINE_AMMO     = 0
local ADRENALINE_AMMOCLIP = 1

local MODULE_NAME = "adrenaline_all_classes"

local function log(msg)
	et.G_Print("[" .. MODULE_NAME .. "] " .. msg .. "\n")
end

--[[
 Called by the engine after a client spawns (also after revive / team
 change).
   clientNum     - entity slot of the spawning client
   revived       - 1 if the player was revived, 0 on a normal respawn
   teamChange    - 1 if this spawn follows a team change
   restoreHealth - 1 if health was fully restored
]]--
function et_ClientSpawn(clientNum, revived, teamChange, restoreHealth)
	-- Skip spectators and anyone not on a playable team.
	local team = et.gentity_get(clientNum, "sess.sessionTeam")
	if team == nil or team == TEAM_SPECTATOR then
		return
	end

	-- Skip medics: adrenaline stays their own skill-based perk.
	local playerClass = et.gentity_get(clientNum, "sess.playerType")
	if playerClass == nil or playerClass == PC_MEDIC then
		return
	end

	-- Grant the adrenaline shot to every other class.
	-- setcurrent = 0 -> don't force-switch the player to the weapon.
	et.AddWeaponToPlayer(clientNum, WP_MEDIC_ADRENALINE,
		ADRENALINE_AMMO, ADRENALINE_AMMOCLIP, 0)
end

function et_InitGame(levelTime, randomSeed, restart)
	et.RegisterModname(MODULE_NAME)
	log("loaded: adrenaline for all classes except medics")
end
