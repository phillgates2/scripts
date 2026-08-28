--[[
=============================================================================
 adrenaline_all_classes.lua  -  ET: Legacy server-side Lua module
-----------------------------------------------------------------------------
 Gives an adrenaline shot (WP_MEDIC_ADRENALINE) to every player class and
 removes adrenaline from medics entirely:

     Soldier    (class 0) -> gets adrenaline
     Medic      (class 1) -> NO adrenaline, ever (weapon stripped)
     Engineer   (class 2) -> gets adrenaline
     Field Ops  (class 3) -> gets adrenaline
     Covert Ops (class 4) -> gets adrenaline

 In stock ET: Legacy the adrenaline shot is a First Aid level-4 perk that
 only medics can unlock. This module:

   1. grants the weapon to the other four classes on every spawn, revive
      and team change, so no skill level is required for them; and
   2. strips the adrenaline weapon from medics so they can never use it,
      even if they have the First Aid level-4 unlock (or if the weapon is
      granted some other way, e.g. an admin command or another module).

 HOW IT WORKS
   * The et_ClientSpawn hook runs right after the engine has built the
     player's spawn loadout (SetWolfSpawnWeapons), so weapons can be
     added or removed on top of whatever the class normally carries.
     This also covers revives (the engine restores pre-death weapons
     AFTER the loadout is built, and the hook runs after that).
   * et.AddWeaponToPlayer(clientNum, weapon, ammo, ammoclip, setcurrent)
     sets the weapon bit and its ammo/clip. Adrenaline shares its ammo
     pool with the medic syringe (ammo/clip index 11); non-medics never
     carry a syringe so that pool is free for them.
   * et.RemoveWeaponFromPlayer(clientNum, weapon) only clears the weapon
     bit - it never touches the shared ammo pool, so a medic's syringe
     (same pool) is unaffected.
   * Firing it applies the 10 second PW_ADRENALINE powerup (fast health
     regen + no fatigue), exactly like the original medic version.
   * The adrenaline weapon (id 44) lives in weapon bank 7 together with
     the landmine, so players pull it out with slot key 7 (or the mouse
     wheel).
   * A light safety sweep in et_RunFrame (once per second) removes the
     weapon from any medic that still has it. The spawn hook already
     covers the normal case; the sweep only catches weapons granted
     mid-match.

 INSTALL
   1. Copy this file into your mod's luascripts folder, e.g.:
        <fs_home>/legacy/luascripts/adrenaline_all_classes.lua
      (on Linux that is usually ~/.etlegacy/legacy/luascripts/)
   2. Load the module from your server config (legacy.cfg):
        set lua_modules "luascripts/adrenaline_all_classes.lua"
      Space-separate several modules, e.g.:
        set lua_modules "luascripts/wolfadmin/main.lua luascripts/adrenaline_all_classes.lua"
   3. Restart the map/server. On load the console prints:
        [adrenaline_all_classes] loaded: adrenaline for all classes - medics can never use it
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

local MAX_CLIENTS = (et and et.MAX_CLIENTS) or 64

-- Interval (ms) of the safety sweep that strips adrenaline from medics.
local SWEEP_INTERVAL = 1000

local MODULE_NAME = "adrenaline_all_classes"

local function log(msg)
	et.G_Print("[" .. MODULE_NAME .. "] " .. msg .. "\n")
end

-- true if the client is on a playable team (not spectator, sess known)
local function is_on_team(clientNum)
	local team = et.gentity_get(clientNum, "sess.sessionTeam")
	return team ~= nil and team ~= TEAM_SPECTATOR
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
	if not is_on_team(clientNum) then
		return
	end

	local playerClass = et.gentity_get(clientNum, "sess.playerType")
	if playerClass == nil then
		return
	end

	if playerClass == PC_MEDIC then
		-- Medics never get adrenaline: strip the weapon if the First Aid
		-- skill unlock (or anything else) put it in the spawn loadout.
		et.RemoveWeaponFromPlayer(clientNum, WP_MEDIC_ADRENALINE)
		return
	end

	-- Grant the adrenaline shot to every other class.
	-- setcurrent = 0 -> don't force-switch the player to the weapon.
	et.AddWeaponToPlayer(clientNum, WP_MEDIC_ADRENALINE,
		ADRENALINE_AMMO, ADRENALINE_AMMOCLIP, 0)
end

--[[
 Called every server frame; levelTime is the level time in ms.
 Runs the safety sweep once per SWEEP_INTERVAL.
]]--
function et_RunFrame(levelTime)
	if not levelTime or (levelTime % SWEEP_INTERVAL) ~= 0 then
		return
	end

	for i = 0, MAX_CLIENTS - 1 do
		if is_on_team(i)
			and et.gentity_get(i, "sess.playerType") == PC_MEDIC then
			-- no-op if the medic doesn't carry it; safe to call always
			et.RemoveWeaponFromPlayer(i, WP_MEDIC_ADRENALINE)
		end
	end
end

function et_InitGame(levelTime, randomSeed, restart)
	et.RegisterModname(MODULE_NAME)
	log("loaded: adrenaline for all classes - medics can never use it")
end
