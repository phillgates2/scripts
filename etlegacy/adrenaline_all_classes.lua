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
   * et.RemoveWeaponFromPlayer(clientNum, weapon) clears the weapon bit
     and also clears the current weapon if it is selected. The shared
     syringe/adrenaline ammo pool is left alone, so medic syringes are
     unaffected.
   * Firing it applies the 10 second PW_ADRENALINE powerup (fast health
     regen + no fatigue), exactly like the original medic version.
   * The adrenaline weapon (id 44) lives in weapon bank 7 together with
     the landmine, so players pull it out with slot key 7 (or the mouse
     wheel).
   * A safety sweep in et_RunFrame removes the weapon from any medic that
     still has it. It runs every server frame, rather than relying on a
     particular millisecond value, so it also catches weapons granted
     mid-match (for example when First Aid level 4 is reached).
   * The et_WeaponFire hook is a second guard: even if another module grants
     adrenaline after the sweep, a medic cannot fire it.

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
local TEAM_AXIS      = (et and et.TEAM_AXIS) or 1
local TEAM_ALLIES    = (et and et.TEAM_ALLIES) or 2

-- WP_MEDIC_ADRENALINE is weapon id 44 (bg_public.h). Use the constant the
-- Lua API registers, with a numeric fallback just in case.
local WP_MEDIC_ADRENALINE = (et and et.WP_MEDIC_ADRENALINE) or 44

-- One ready-to-use shot in the "clip", no reserve ammo. This mirrors how
-- the game itself spawns adrenaline for medics (classMiscWeapons entry:
-- startingAmmo = 0, startingClip = 1).
local ADRENALINE_AMMO     = 0
local ADRENALINE_AMMOCLIP = 1

local MAX_CLIENTS = (et and et.MAX_CLIENTS) or 64

local MODULE_NAME = "adrenaline_all_classes"

local function log(msg)
	et.G_Print("[" .. MODULE_NAME .. "] " .. msg .. "\n")
end

-- true when the slot currently has a live client attached.
--
-- "inuse" is an entity-level field, so it can be read from ANY entity
-- (client or not) without error. sess.* / ps.* fields only exist on client
-- entities: reading them from an empty slot makes et.gentity_get raise
-- "tried to get invalid gentity field", which aborts et_RunFrame for the
-- whole map. The engine sets inuse = 1 exactly when a slot has a spawned
-- client (and clears it on disconnect), so it is the right guard.
local function has_client(clientNum)
	return et.gentity_get(clientNum, "inuse") == 1
end

-- true only for a connected client on Axis or Allies. In particular, do not
-- treat TEAM_FREE as a playable team while a client is changing teams.
local function is_on_team(clientNum)
	if not has_client(clientNum) then
		return false
	end
	local team = et.gentity_get(clientNum, "sess.sessionTeam")
	return team == TEAM_AXIS or team == TEAM_ALLIES
end

local function is_medic(clientNum)
	return is_on_team(clientNum)
		and et.gentity_get(clientNum, "sess.playerType") == PC_MEDIC
end

local function strip_adrenaline(clientNum)
	-- RemoveWeaponFromPlayer also clears ps.weapon when adrenaline is
	-- currently selected, so it cannot remain usable for this life.
	et.RemoveWeaponFromPlayer(clientNum, WP_MEDIC_ADRENALINE)
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
		strip_adrenaline(clientNum)
		return
	end

	-- Grant the adrenaline shot to every other class.
	-- setcurrent = 0 -> don't force-switch the player to the weapon.
	et.AddWeaponToPlayer(clientNum, WP_MEDIC_ADRENALINE,
		ADRENALINE_AMMO, ADRENALINE_AMMOCLIP, 0)
end

--[[
 Called every server frame; levelTime is the level time in ms.
 Do not use `levelTime % interval` here: server frame times are not
 guaranteed to land exactly on a particular millisecond. Running this
 small sweep every frame closes the gap between a skill unlock/admin grant
 and the next snapshot.
]]--
function et_RunFrame(levelTime)
	for i = 0, MAX_CLIENTS - 1 do
		if is_medic(i) then
			-- no-op if the medic doesn't carry it; safe to call always
			strip_adrenaline(i)
		end
	end
end

-- The weapon-fire hook is a second line of defense. It prevents a medic
-- from using adrenaline in the brief interval before the frame sweep, or if
-- another module grants it after this module's sweep.
function et_WeaponFire(clientNum, weapon)
	if weapon == WP_MEDIC_ADRENALINE and is_medic(clientNum) then
		strip_adrenaline(clientNum)
		return 1 -- abort the qagame weapon-fire handler
	end

	return 0 -- pass control to the game
end

function et_InitGame(levelTime, randomSeed, restart)
	et.RegisterModname(MODULE_NAME)
	log("loaded: adrenaline for all classes - medics can never use it")
end
