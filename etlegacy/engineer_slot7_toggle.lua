--[[
=============================================================================
 engineer_slot7_toggle.lua  -  ET: Legacy server-side Lua module
-----------------------------------------------------------------------------
 FIXES THE "SLOT 7" BUG

 Weapon bank 7 holds BOTH the landmine (WP_LANDMINE, 26) and the adrenaline
 shot (WP_MEDIC_ADRENALINE, 44). The engine's bank cycling
 (bg_misc.c: weapBanksMultiPlayer / BG_ValidStatWeapon -> Cmd_WeaponBank_f)
 walks the bank list and stops at the FIRST weapon in the bank the player
 owns. An engineer who carries landmines therefore always gets the landmine
 back when pressing 7 - the adrenaline shot in the same bank can never be
 selected, so a player who has both (e.g. with adrenaline_all_classes.lua
 loaded) is stuck on mines.

 This module makes slot 7 TOGGLE between the two: press 7 with the landmine
 out and you switch to adrenaline, press it again and you are back on mines.
 Nothing else about either weapon changes.

 HOW IT WORKS
   * et_ClientCommand intercepts the client's weapon selection commands:
       weaponbank 7      (what the "7" key sends in ET: Legacy)
       weaponslot 7      (alias used by some configs / older clients)
       slot7             (ETPro-style alias)
       togglemine        (extra command this module adds, bind it if you
                          prefer a dedicated key)
     Any other bank is passed through untouched (return 0), so the engine
     handles slots 1-6 exactly as before.
   * When the player owns both bank-7 weapons the module picks the one that
     is NOT currently selected and selects it with AddWeaponToPlayer's
     setcurrent flag (ps.weapon is read-only through et.gentity_set, so the
     engine call is the supported write path). When the player owns only one
     of them it selects that one - which reproduces stock behaviour, so the
     module is safe to leave loaded for every class.
   * Ownership is read from the ps.weapons bitmask (two 32 bit words:
     weapon w is bit (w % 32) of word (w / 32)). Adrenaline (44) lives in
     word 1 bit 12, the landmine (26) in word 0 bit 26.
   * A weapon with no ammo left is skipped: an engineer who has already
     used the adrenaline shot keeps getting mines from the 7 key instead of
     an empty syringe, and vice versa.

 LIMITATIONS
   * Only the SERVER side toggles. The client's own prediction still thinks
     "7 = landmine" for one frame, so the HUD can flicker once on the
     switch; the weapon that actually fires is the toggled one.
   * A client that has bound 7 to something other than "weaponbank 7"
     (a custom "weaponbank 7; +attack" script, for instance) still works,
     as long as the weaponbank command itself is sent.

 INSTALL
   1. Copy to <fs_home>/legacy/luascripts/engineer_slot7_toggle.lua
   2. set lua_modules "luascripts/engineer_slot7_toggle.lua"
      (load it together with adrenaline_all_classes.lua - that module is
      what gives engineers adrenaline in the first place)
   3. Restart the map.
=============================================================================
]]--

-- ============================ CONFIG =====================================
-- Announce the switch to the player in the centre print area.
local NOTIFY            = false
-- Extra command clients may bind directly, e.g. bind x "togglemine".
local TOGGLE_COMMAND    = "togglemine"
local DEBUG             = (DEBUG ~= nil and DEBUG) or false
-- ==========================================================================

local WP_LANDMINE          = (et and et.WP_LANDMINE) or 26
local WP_MEDIC_ADRENALINE  = (et and et.WP_MEDIC_ADRENALINE) or 44
local MAX_CLIENTS          = (et and et.MAX_CLIENTS) or 64
local TEAM_AXIS            = (et and et.TEAM_AXIS) or 1
local TEAM_ALLIES          = (et and et.TEAM_ALLIES) or 2

-- the weapons that share weapon bank 7, in the order the engine would
-- consider them
local BANK7 = { WP_LANDMINE, WP_MEDIC_ADRENALINE }

local MODULE_NAME = "engineer_slot7_toggle"

local client_slots = nil
local no_client    = {}

local function log(msg)
	if type(et) == "table" and type(et.G_Print) == "function" then
		et.G_Print("[" .. MODULE_NAME .. "] " .. msg .. "\n")
	end
end

-- see README: never loop client fields up to et.MAX_CLIENTS
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

-- protected read of a client-only field (sess.* / ps.* / pers.*)
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

local function is_on_team(clientNum)
	if not has_client(clientNum) then
		return false
	end
	local team = client_get(clientNum, "sess.sessionTeam")
	return team == TEAM_AXIS or team == TEAM_ALLIES
end

--[[
 True when the client carries `weapon`.

 ps.weapons is the MAX_WEAPONS/32 word bitmask from playerState_t: weapon w
 is bit (w % 32) of word floor(w / 32). Lua array indexes into engine arrays
 are 0 based in et.gentity_get, so word 0 is index 0.
]]--
local function has_weapon(clientNum, weapon)
	local word = math.floor(weapon / 32)
	local bit  = weapon % 32
	local mask = client_get(clientNum, "ps.weapons", word)
	if type(mask) ~= "number" then
		return false
	end
	-- 2^bit without bitops so this works on Lua 5.1 .. 5.4 alike
	local div = 2 ^ bit
	return math.floor(mask / div) % 2 == 1
end

-- ammo left for a weapon: clip first, then the reserve pool.
-- Adrenaline and the syringe share pool 11 (WP_MEDIC_SYRINGE); the landmine
-- uses its own. A weapon with nothing left is not worth switching to.
local function has_ammo(clientNum, weapon)
	local pool = weapon
	if weapon == WP_MEDIC_ADRENALINE then
		pool = (et and et.WP_MEDIC_SYRINGE) or 11
	end
	local clip = client_get(clientNum, "ps.ammoclip", pool)
	local ammo = client_get(clientNum, "ps.ammo", pool)
	if clip == nil and ammo == nil then
		-- cannot tell (older API): assume usable rather than block the swap
		return true
	end
	return (clip or 0) > 0 or (ammo or 0) > 0
end

-- The weapon slot 7 should select for this client right now.
-- Returns nil when the player owns nothing in bank 7 (let the engine decide).
local function pick_bank7(clientNum)
	local current = client_get(clientNum, "ps.weapon")
	local owned, usable = {}, {}

	for _, w in ipairs(BANK7) do
		if has_weapon(clientNum, w) then
			owned[#owned + 1] = w
			if has_ammo(clientNum, w) then
				usable[#usable + 1] = w
			end
		end
	end

	local list = usable
	if #list == 0 then
		list = owned          -- everything empty: still let them pull one out
	end
	if #list == 0 then
		return nil
	end
	if #list == 1 then
		return list[1]
	end

	-- more than one: take the next one after the currently held weapon,
	-- wrapping around - that is the toggle
	for i, w in ipairs(list) do
		if w == current then
			return list[(i % #list) + 1]
		end
	end

	-- not currently holding a bank 7 weapon: give them the first one
	return list[1]
end

local function ammo_pool(weapon)
	if weapon == WP_MEDIC_ADRENALINE then
		return (et and et.WP_MEDIC_SYRINGE) or 11
	end
	return weapon
end

-- Both bank-7 weapons are ammo weapons (landmine / adrenaline), so the
-- re-add below must not run when the ammo fields are unreadable - it would
-- otherwise wipe the count.
local function uses_ammo(weapon)
	return weapon == WP_LANDMINE or weapon == WP_MEDIC_ADRENALINE
end

-- Select a bank-7 weapon on the server.
--
-- ps.weapon / ps.weaponstate are read-only through et.gentity_set, so the
-- supported way to change the current weapon is AddWeaponToPlayer with its
-- setcurrent flag: it re-sets the (unchanged) weapon bit and ammo and writes
-- ps.weapon in the engine. We read the ammo first so the re-add never resets
-- a syringe/adrenaline count.
local function select_weapon(clientNum, weapon)
	local pool     = ammo_pool(weapon)
	local ammo     = client_get(clientNum, "ps.ammo", pool)
	local ammoclip = client_get(clientNum, "ps.ammoclip", pool)
	if uses_ammo(weapon) and ammo == nil and ammoclip == nil then
		if DEBUG then
			log("cannot read ammo for weapon " .. weapon .. "; not switching")
		end
		return false
	end
	if ammo == nil then
		ammo = 0
	end
	if ammoclip == nil then
		ammoclip = 0
	end

	if type(et.AddWeaponToPlayer) == "function" then
		local ok, err = pcall(et.AddWeaponToPlayer, clientNum, weapon,
			ammo, ammoclip, 1)
		if ok then
			if NOTIFY and type(et.trap_SendServerCommand) == "function" then
				local name = (weapon == WP_MEDIC_ADRENALINE) and "adrenaline" or "landmine"
				et.trap_SendServerCommand(clientNum, "cp \"^7" .. name .. "\"")
			end
			if DEBUG then
				log("client " .. clientNum .. " slot 7 -> weapon " .. weapon)
			end
			return true
		end
		if DEBUG then
			log("ERROR (select weapon): " .. tostring(err))
		end
	end

	-- Fallback for older engines where ps.weapon is still writable.
	local ok = pcall(et.gentity_set, clientNum, "ps.weapon", weapon)
	if not ok then
		return false
	end
	pcall(et.gentity_set, clientNum, "ps.weaponstate", 0)
	if NOTIFY and type(et.trap_SendServerCommand) == "function" then
		local name = (weapon == WP_MEDIC_ADRENALINE) and "adrenaline" or "landmine"
		et.trap_SendServerCommand(clientNum, "cp \"^7" .. name .. "\"")
	end
	if DEBUG then
		log("client " .. clientNum .. " slot 7 -> weapon " .. weapon)
	end
	return true
end

-- true when this client command is a request for weapon bank / slot 7
local function is_slot7_command(command)
	if type(command) ~= "string" then
		return false
	end
	local cmd = command:lower()

	if cmd == TOGGLE_COMMAND then
		return true
	end
	if cmd == "slot7" then
		return true
	end
	if cmd == "weaponbank" or cmd == "weaponslot" then
		if type(et.trap_Argv) == "function" then
			return tonumber(et.trap_Argv(1) or "") == 7
		end
	end
	return false
end

--[[
 Called for every command a client sends.
 Return 1 to swallow the command, 0 to pass it on to qagame (and to the
 other Lua modules in the chain).
]]--
function et_ClientCommand(clientNum, command)
	if type(et) ~= "table" then
		return 0
	end

	local ok, intercepted = pcall(function()
		if not is_slot7_command(command) then
			return 0
		end
		if not is_on_team(clientNum) then
			return 0
		end

		local weapon = pick_bank7(clientNum)
		if not weapon then
			return 0     -- owns nothing in bank 7: stock behaviour
		end
		if weapon == client_get(clientNum, "ps.weapon") then
			return 0     -- already holding it, nothing to do
		end
		if select_weapon(clientNum, weapon) then
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
	log("loaded: weapon slot 7 toggles landmine <-> adrenaline"
		.. " (client slots: " .. get_client_slots() .. ")")
end
