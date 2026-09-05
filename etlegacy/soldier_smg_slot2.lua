--[[
=============================================================================
 soldier_smg_slot2.lua  -  ET: Legacy server-side Lua module
-----------------------------------------------------------------------------
 SOLDIER SMG IN WEAPON SLOT 2

 Stock ET: Legacy puts every SMG (Thompson / MP40 / Sten / MP34) in weapon
 bank 3 and the pistols in bank 2, so a soldier who picked an SMG as their
 class weapon can only reach it with the 3 key - bank 2 always gives the
 pistol.

 This module makes the SMG reachable from slot 2 as well for SOLDIERS:

     press 2  -> the SMG, if the soldier's slot 3 weapon is that same SMG
     press 2  -> the pistol again (the key toggles, so nothing is lost)
     press 3  -> unchanged, the class weapon

 "if weapon slot 3 is the same" is the condition: the soldier only gets the
 SMG on slot 2 when the weapon they carry in bank 3 IS an SMG (Thompson for
 Allies, MP40 for Axis, and by default also Sten / MP34). A soldier carrying
 a panzerfaust, flamethrower, mortar or MG42 in bank 3 is untouched - they
 keep the stock pistol-only slot 2.

 Optionally (GRANT_TEAM_SMG below) the module can also GRANT the team SMG to
 soldiers who do not have one at all, so slot 2 always has something better
 than a pistol.

 HOW IT WORKS
   * et_ClientCommand intercepts "weaponbank 2" / "weaponslot 2" / "slot2"
     and selects the SMG or the pistol, alternating on each press. Every
     other bank is passed straight through to qagame (return 0).
   * Ownership is read from the ps.weapons bitmask, so the module never
     selects a weapon the player does not actually carry, and the alternate
     forms (akimbo / silenced pistols) are honoured: if the soldier has
     akimbos, the "pistol" half of the toggle is the akimbo.
   * A weapon with no ammo left is skipped, so an empty SMG does not swallow
     the key press.
   * et_ClientSpawn does the optional grant, after the engine has built the
     spawn loadout.

 LIMITATIONS
   * Server side only: the client's own prediction still believes slot 2 is
     the pistol for a frame, so the HUD may flicker once on the switch.
   * Only soldiers (PC_SOLDIER, class 0) are affected. Every other class
     keeps stock behaviour.

 INSTALL
   1. Copy to <fs_home>/legacy/luascripts/soldier_smg_slot2.lua
   2. set lua_modules "luascripts/soldier_smg_slot2.lua"
   3. Restart the map.
=============================================================================
]]--

-- ============================ CONFIG =====================================
-- Give soldiers who carry no SMG at all the team SMG on spawn
-- (Thompson for Allies, MP40 for Axis). Off by default: with it off the
-- module never changes what a player carries, it only changes what slot 2
-- selects.
local GRANT_TEAM_SMG = false
local GRANT_AMMO     = 90    -- reserve ammo for a granted SMG
local GRANT_CLIP     = 30    -- rounds in the clip of a granted SMG
local DEBUG          = (DEBUG ~= nil and DEBUG) or false
-- ==========================================================================

local PC_SOLDIER = 0

local TEAM_AXIS   = (et and et.TEAM_AXIS) or 1
local TEAM_ALLIES = (et and et.TEAM_ALLIES) or 2
local MAX_CLIENTS = (et and et.MAX_CLIENTS) or 64

local WP_LUGER               = (et and et.WP_LUGER) or 2
local WP_MP40                = (et and et.WP_MP40) or 3
local WP_COLT                = (et and et.WP_COLT) or 7
local WP_THOMPSON            = (et and et.WP_THOMPSON) or 8
local WP_STEN                = (et and et.WP_STEN) or 10
local WP_SILENCER            = (et and et.WP_SILENCER) or 14
local WP_AKIMBO_COLT         = (et and et.WP_AKIMBO_COLT) or 35
local WP_AKIMBO_LUGER        = (et and et.WP_AKIMBO_LUGER) or 36
local WP_SILENCED_COLT       = (et and et.WP_SILENCED_COLT) or 39
local WP_AKIMBO_SILENCEDCOLT = (et and et.WP_AKIMBO_SILENCEDCOLT) or 45
local WP_AKIMBO_SILENCEDLUGER= (et and et.WP_AKIMBO_SILENCEDLUGER) or 46
local WP_MP34                = (et and et.WP_MP34) or 54

-- SMGs that count as "slot 3 is the same" and may appear on slot 2
local SMG_WEAPONS = {
	[WP_THOMPSON] = true,
	[WP_MP40]     = true,
	[WP_STEN]     = true,
	[WP_MP34]     = true,
}

-- the team SMG used by GRANT_TEAM_SMG
local TEAM_SMG = {
	[TEAM_AXIS]   = WP_MP40,
	[TEAM_ALLIES] = WP_THOMPSON,
}

-- bank 2 pistols, best form first (akimbo/silenced before the plain gun)
local PISTOLS = {
	WP_AKIMBO_SILENCEDCOLT, WP_AKIMBO_SILENCEDLUGER,
	WP_AKIMBO_COLT, WP_AKIMBO_LUGER,
	WP_SILENCED_COLT, WP_SILENCER,
	WP_COLT, WP_LUGER,
}

-- ammo pools shared between a weapon and its alternate form
-- (bg_misc.c weaponTable: the akimbo/silenced variants draw from the
-- pistol's own pool)
local AMMO_POOL = {
	[WP_AKIMBO_COLT]          = WP_COLT,
	[WP_AKIMBO_SILENCEDCOLT]  = WP_COLT,
	[WP_SILENCED_COLT]        = WP_COLT,
	[WP_AKIMBO_LUGER]         = WP_LUGER,
	[WP_AKIMBO_SILENCEDLUGER] = WP_LUGER,
	[WP_SILENCER]             = WP_LUGER,
}

local MODULE_NAME = "soldier_smg_slot2"

local client_slots = nil
local no_client    = {}

local function log(msg)
	if type(et) == "table" and type(et.G_Print) == "function" then
		et.G_Print("[" .. MODULE_NAME .. "] " .. msg .. "\n")
	end
end

local function refresh_client_slots()
	local n
	if type(et.trap_Cvar_Get) == "function" then
		n = tonumber(et.trap_Cvar_Get("sv_maxclients") or "")
	end
	if not n or n <= 0 or n > MAX_CLIENTS then
		n = MAX_CLIENTS
	end
	client_slots = n
	return n
end

local function get_client_slots()
	return client_slots or refresh_client_slots()
end

local function client_get(num, field, index)
	if no_client[num] then
		return nil
	end
	local ok, val = pcall(et.gentity_get, num, field, index)
	if not ok then
		no_client[num] = true
		log("warning: client slot " .. num .. " has no client fields ("
			.. tostring(val) .. ") - skipping it for this map")
		return nil
	end
	return val
end

local function has_client(clientNum)
	if type(clientNum) ~= "number" or clientNum < 0
		or clientNum >= get_client_slots() or no_client[clientNum] then
		return false
	end
	return et.gentity_get(clientNum, "inuse") == 1
end

local function team_of(clientNum)
	if not has_client(clientNum) then
		return nil
	end
	local team = client_get(clientNum, "sess.sessionTeam")
	if team == TEAM_AXIS or team == TEAM_ALLIES then
		return team
	end
	return nil
end

local function is_soldier(clientNum)
	return team_of(clientNum) ~= nil
		and client_get(clientNum, "sess.playerType") == PC_SOLDIER
end

-- ps.weapons is a bitmask of 32 bit words: weapon w is bit (w % 32) of
-- word floor(w / 32)
local function has_weapon(clientNum, weapon)
	local mask = client_get(clientNum, "ps.weapons", math.floor(weapon / 32))
	if type(mask) ~= "number" then
		return false
	end
	return math.floor(mask / (2 ^ (weapon % 32))) % 2 == 1
end

local function has_ammo(clientNum, weapon)
	local pool = AMMO_POOL[weapon] or weapon
	local clip = client_get(clientNum, "ps.ammoclip", pool)
	local ammo = client_get(clientNum, "ps.ammo", pool)
	if clip == nil and ammo == nil then
		return true
	end
	return (clip or 0) > 0 or (ammo or 0) > 0
end

-- The SMG the soldier carries in bank 3, or nil. This is the
-- "slot 3 is the same" test: slot 2 only offers the SMG that is actually
-- the soldier's class weapon.
local function smg_of(clientNum)
	-- sess.playerWeapon is the chosen class weapon; fall back to scanning
	-- the SMG list for servers/mods where it is not set
	local chosen = client_get(clientNum, "sess.playerWeapon")
	if chosen and SMG_WEAPONS[chosen] and has_weapon(clientNum, chosen) then
		return chosen
	end
	for w in pairs(SMG_WEAPONS) do
		if has_weapon(clientNum, w) then
			return w
		end
	end
	return nil
end

local function pistol_of(clientNum)
	for _, w in ipairs(PISTOLS) do
		if has_weapon(clientNum, w) then
			return w
		end
	end
	return nil
end

local function select_weapon(clientNum, weapon)
	local ok = pcall(et.gentity_set, clientNum, "ps.weapon", weapon)
	if not ok then
		return false
	end
	pcall(et.gentity_set, clientNum, "ps.weaponstate", 0)  -- WEAPON_READY
	if DEBUG then
		log("client " .. clientNum .. " slot 2 -> weapon " .. weapon)
	end
	return true
end

local function is_slot2_command(command)
	if type(command) ~= "string" then
		return false
	end
	local cmd = command:lower()
	if cmd == "slot2" then
		return true
	end
	if cmd == "weaponbank" or cmd == "weaponslot" then
		if type(et.trap_Argv) == "function" then
			return tonumber(et.trap_Argv(1) or "") == 2
		end
	end
	return false
end

function et_ClientCommand(clientNum, command)
	if type(et) ~= "table" then
		return 0
	end

	local ok, intercepted = pcall(function()
		if not is_slot2_command(command) then
			return 0
		end
		if not is_soldier(clientNum) then
			return 0
		end

		local smg = smg_of(clientNum)
		if not smg then
			return 0        -- slot 3 is not an SMG: stock slot 2
		end

		local pistol  = pistol_of(clientNum)
		local current = client_get(clientNum, "ps.weapon")

		-- toggle: holding the SMG -> pistol, anything else -> SMG
		local want
		if current == smg then
			want = pistol
		elseif has_ammo(clientNum, smg) then
			want = smg
		else
			want = pistol   -- SMG dry, do not swallow the key press
		end

		if not want or want == current then
			return 0
		end
		if select_weapon(clientNum, want) then
			return 1
		end
		return 0
	end)

	if not ok then
		log("ERROR: " .. tostring(intercepted))
		return 0
	end
	return intercepted
end

--[[
 Optional: hand soldiers the team SMG so slot 2 has one to offer.
 Runs after the engine built the spawn loadout, so it adds on top of it.
]]--
function et_ClientSpawn(clientNum, revived, teamChange, restoreHealth)
	if not GRANT_TEAM_SMG or type(et) ~= "table" then
		return
	end
	local ok, err = pcall(function()
		if not is_soldier(clientNum) then
			return
		end
		if smg_of(clientNum) then
			return          -- already carries one
		end
		local smg = TEAM_SMG[team_of(clientNum)]
		if smg then
			et.AddWeaponToPlayer(clientNum, smg, GRANT_AMMO, GRANT_CLIP, 0)
			if DEBUG then
				log("granted SMG " .. smg .. " to soldier " .. clientNum)
			end
		end
	end)
	if not ok then
		log("ERROR: " .. tostring(err))
	end
end

function et_ClientDisconnect(clientNum)
	no_client[clientNum] = nil
end

function et_InitGame(levelTime, randomSeed, restart)
	if type(et) ~= "table" then
		return
	end
	no_client = {}
	refresh_client_slots()
	if type(et.RegisterModname) == "function" then
		et.RegisterModname(MODULE_NAME)
	end
	log("loaded: soldiers can pull their SMG from weapon slot 2"
		.. " (client slots: " .. get_client_slots() .. ")")
end
