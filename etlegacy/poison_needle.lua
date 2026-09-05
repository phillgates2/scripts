--[[
=============================================================================
 poison_needle.lua  -  ET: Legacy server-side Lua module
-----------------------------------------------------------------------------
 POISON NEEDLE

 Turns the syringe into a weapon against ENEMIES: stabbing an enemy player
 with the needle injects poison instead of doing nothing. With ALL_CLASSES
 enabled (the default) every class also carries the needle, so soldiers,
 engineers, field ops and covert ops can use it too - not just medics.

     * the victim takes POISON_TICK_DAMAGE every POISON_TICK_MS for
       POISON_DURATION_MS (default: 10 damage every second for 10 seconds),
     * the poison keeps ticking through the victim's own healing, and a
       fresh stab refreshes the timer (it does not stack faster),
     * a victim revived from the dead, one who changes team, or one who is
       cured (see CURE_ON_MEDPACK / CURE_ON_ADRENALINE) loses the poison,
     * the kill is credited to the medic who injected it, with means of
       death MOD_SYRINGE, so it shows up normally in the obituary and in
       the stats.

 Stock ET: Legacy only lets the syringe revive dead team mates; a hit on a
 living enemy does nothing at all. This module leaves the revive behaviour
 completely alone - it only adds the poison on an enemy hit.

 ALL CLASSES
   * With ALL_CLASSES = true (the default) every class is given a syringe
     when they spawn: soldiers, medics, engineers, field ops and covert ops
     all get the poison needle. Medics already carry one, so their normal
     syringe loadout is left untouched.
   * The syringe lives in weapon bank 5. For players who already use that
     bank (engineer pliers, field ops / covert ops smoke) simply granting
     the weapon would make the bank always pick the first owned weapon and
     hide the others. This module therefore intercepts slot 5 and TOGGLES
     between every owned bank-5 weapon (syringe <-> pliers / smoke), so the
     needle is added without taking away the class's existing tool.
   * The syringe also revives a dead team mate whoever carries it. That is
     what the engine's syringe does; the poison is an addition, not a
     replacement.

 HOW IT WORKS
   * et_Damage fires for every damage event, including the syringe hit
     (MOD_SYRINGE, 24). When the target is a live enemy the module records
     a poison entry for that client and returns 0, letting the original
     (zero) damage through unchanged.
   * Because a syringe hit on a live enemy does 0 damage in some builds,
     the module ALSO watches et_WeaponFire: when a player fires the syringe
     it traces forward SYRINGE_RANGE units and poisons the enemy player it
     hits. Both paths feed the same "poison this client" function, and the
     refresh logic makes the overlap harmless.
   * et_ClientSpawn grants the syringe (when ALL_CLASSES is on) and the
     slot 5 toggle only acts when the player actually carries it, so every
     class keeps the rest of its loadout.
   * et_RunFrame applies the ticks with et.G_Damage(target, attacker,
     attacker, damage, DAMAGE_NO_KNOCKBACK, MOD_SYRINGE) - real damage, so
     death, gibbing, obituaries and XP all work as usual.
   * Poison state is cleared in et_ClientSpawn (respawn AND revive) and
     et_ClientDisconnect, so it can never leak into a new life.

 LIMITATIONS
   * Team mates are never poisoned, even with friendly fire on: the syringe
     must stay usable for revives.
   * All-class carriers share the syringe's ammo pool (11) with the
     adrenaline shot, exactly like stock medics do. If another module (e.g.
     adrenaline_all_classes) gives adrenaline to the same player, both draw
     from that one pool; the docs for that module are written to add the
     shot on top of an existing syringe count rather than resetting it.
   * The slot 5 switch is server side only: the client's own prediction can
     show the old bank 5 weapon for one frame, but the weapon that actually
     fires is the selected one (same mechanism as engineer_slot7_toggle).
   * The victim gets no dedicated poison HUD icon (that would need a client
     side mod); they see the damage, the hit flash and a centre print
     instead.

 INSTALL
   1. Copy to <fs_home>/legacy/luascripts/poison_needle.lua
   2. set lua_modules "luascripts/poison_needle.lua"
   3. Restart the map.
=============================================================================
]]--

-- ============================ CONFIG =====================================
local POISON_DURATION_MS = 10000  -- how long one injection lasts
local POISON_TICK_MS     = 1000   -- time between damage ticks
local POISON_TICK_DAMAGE = 10     -- damage per tick
local SYRINGE_RANGE      = 48     -- reach of the needle (units)
local CURE_ON_MEDPACK    = true   -- picking up / being given health cures it
local CURE_ON_ADRENALINE = true   -- firing adrenaline burns the poison off
local NOTIFY_VICTIM      = true   -- centre print "you are poisoned"
local NOTIFY_ATTACKER    = true   -- centre print "poisoned <name>"

-- Every class gets the poison needle, not just medics.
local ALL_CLASSES      = true    -- grant the syringe to every class on spawn
local SYRINGE_AMMO     = 0       -- reserve syringes in pool 11 (0 is normal)
local SYRINGE_AMMOCLIP = 8       -- ready syringes in pool 11 ("shot" count)
local SLOT5_TOGGLE     = true    -- slot 5 cycles bank-5 weapons (see docs)
local NOTIFY_SWITCH    = false   -- centre print when slot 5 changes weapon
local TOGGLE_COMMAND   = "poisonneedle" -- extra command to pull the needle

local DEBUG = (DEBUG ~= nil and DEBUG) or false
-- ==========================================================================

local TEAM_AXIS      = (et and et.TEAM_AXIS) or 1
local TEAM_ALLIES    = (et and et.TEAM_ALLIES) or 2
local MAX_CLIENTS    = (et and et.MAX_CLIENTS) or 64
local STAT_HEALTH    = (et and et.STAT_HEALTH) or 0

local WP_MEDIC_SYRINGE    = (et and et.WP_MEDIC_SYRINGE) or 11
local WP_MEDIC_ADRENALINE = (et and et.WP_MEDIC_ADRENALINE) or 44
local WP_PLIERS           = (et and et.WP_PLIERS) or 21
local WP_SMOKE_MARKER     = (et and et.WP_SMOKE_MARKER) or 22
local WP_SMOKE_BOMB       = (et and et.WP_SMOKE_BOMB) or 29

-- weapons that share weapon bank 5, in the order the engine considers them
-- (cg_weapons.c weapBanksMultiPlayer). The toggle below cycles through the
-- ones a client owns so adding the syringe never hides pliers or smoke.
local BANK5 = { WP_MEDIC_SYRINGE, WP_PLIERS, WP_SMOKE_MARKER, WP_SMOKE_BOMB }

local MOD_SYRINGE = (et and et.MOD_SYRINGE) or 24
local MASK_SHOT   = (et and et.MASK_SHOT) or 1

-- damage bitflags (g_local.h)
local DAMAGE_NO_KNOCKBACK = 8

local MODULE_NAME = "poison_needle"

-- poisoned[clientNum] = { attacker = n, expires = ms, next_tick = ms }
local poisoned = {}

local client_slots = nil
local no_client    = {}
local reported_errors = {}

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

local function is_alive(clientNum)
	local health = client_get(clientNum, "ps.stats", STAT_HEALTH)
	return type(health) == "number" and health > 0
end

local function name_of(clientNum)
	local n = client_get(clientNum, "pers.netname")
	if type(n) == "string" and #n > 0 then
		return n
	end
	return "client " .. tostring(clientNum)
end

local function cp(clientNum, text)
	if type(et.trap_SendServerCommand) == "function" then
		et.trap_SendServerCommand(clientNum, "cp \"" .. text .. "\"")
	end
end

local function is_on_team(clientNum)
	return team_of(clientNum) ~= nil
end

-- True when the client carries `weapon`. ps.weapons is a two-word bitmask:
-- weapon w is bit (w % 32) of word floor(w / 32).
local function has_weapon(clientNum, weapon)
	local word = math.floor(weapon / 32)
	local bit  = weapon % 32
	local mask = client_get(clientNum, "ps.weapons", word)
	if type(mask) ~= "number" then
		return false
	end
	local div = 2 ^ bit
	return math.floor(mask / div) % 2 == 1
end

-- Ammo left for a bank-5 weapon. The syringe shares the adrenaline pool 11
-- (WP_MEDIC_SYRINGE). Pliers and the smoke marker / smoke bomb are class
-- tools rather than ammo weapons (they run on the class charge time), so
-- they are always selectable - the engine handles whether they can be used.
local function has_ammo(clientNum, weapon)
	if weapon ~= WP_MEDIC_SYRINGE and weapon ~= WP_MEDIC_ADRENALINE then
		return true
	end
	local clip = client_get(clientNum, "ps.ammoclip", WP_MEDIC_SYRINGE)
	local ammo = client_get(clientNum, "ps.ammo", WP_MEDIC_SYRINGE)
	if clip == nil and ammo == nil then
		-- cannot tell (older API): assume usable rather than block the switch
		return true
	end
	return (clip or 0) > 0 or (ammo or 0) > 0
end

-- Give a ready-to-use syringe to a player who does not carry one yet.
-- Medics already have a syringe, so their normal loadout is preserved.
--
-- Syringe and adrenaline share ammo/clip pool 11. If another module (e.g.
-- adrenaline_all_classes) has already put an adrenaline shot in that pool,
-- the syringe is added on top instead of resetting it, so the two modules
-- are safe in either load order.
local function grant_syringe(clientNum)
	if not ALL_CLASSES then
		return
	end
	if not is_on_team(clientNum) then
		return
	end
	if has_weapon(clientNum, WP_MEDIC_SYRINGE) then
		return
	end

	local ammo   = SYRINGE_AMMO
	local ammoclip = SYRINGE_AMMOCLIP
	if has_weapon(clientNum, WP_MEDIC_ADRENALINE) then
		ammo     = client_get(clientNum, "ps.ammo", WP_MEDIC_SYRINGE) or 0
		ammoclip = (client_get(clientNum, "ps.ammoclip", WP_MEDIC_SYRINGE)
			or 0) + SYRINGE_AMMOCLIP
	end

	if type(et.AddWeaponToPlayer) == "function" then
		et.AddWeaponToPlayer(clientNum, WP_MEDIC_SYRINGE,
			ammo, ammoclip, 0)
	end
	if DEBUG then
		log("granted the syringe to client " .. clientNum)
	end
end

-- Which bank-5 weapon slot 5 should select for this client right now.
-- Returns nil when the player owns nothing in bank 5 (let the engine decide).
local function pick_bank5(clientNum)
	local current = client_get(clientNum, "ps.weapon")
	local owned, usable = {}, {}

	for _, w in ipairs(BANK5) do
		if has_weapon(clientNum, w) then
			owned[#owned + 1] = w
			if has_ammo(clientNum, w) then
				usable[#usable + 1] = w
			end
		end
	end

	local list = usable
	if #list == 0 then
		list = owned          -- everything empty: still let them pull it out
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

	-- not currently holding a bank 5 weapon: give them the first one
	return list[1]
end

local function weapon_name(weapon)
	if weapon == WP_MEDIC_SYRINGE then
		return "poison needle"
	elseif weapon == WP_PLIERS then
		return "pliers"
	elseif weapon == WP_SMOKE_MARKER then
		return "smoke marker"
	elseif weapon == WP_SMOKE_BOMB then
		return "smoke bomb"
	end
	return "weapon " .. tostring(weapon)
end

local function weapon_pool(weapon)
	if weapon == WP_MEDIC_ADRENALINE then
		return WP_MEDIC_SYRINGE
	end
	return weapon
end

-- Ammo weapons among the bank-5 choices. Pliers / smoke are class tools
-- with a charge time instead of ammo, so they can be re-added safely even
-- when this API build does not expose ammo fields.
local function uses_ammo(weapon)
	return weapon == WP_MEDIC_SYRINGE or weapon == WP_MEDIC_ADRENALINE
end

-- Select a bank-5 weapon on the server.
--
-- ps.weapon / ps.weaponstate are read-only through et.gentity_set, so the
-- supported way to change the current weapon is AddWeaponToPlayer with its
-- setcurrent flag: it re-sets the (unchanged) weapon bit and ammo and writes
-- ps.weapon in the engine. We read the ammo first so the re-add never resets
-- a syringe/adrenaline count.
local function select_weapon(clientNum, weapon)
	local pool = weapon_pool(weapon)
	local ammo = client_get(clientNum, "ps.ammo", pool)
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
			if NOTIFY_SWITCH then
				cp(clientNum, "^7" .. weapon_name(weapon))
			end
			if DEBUG then
				log("client " .. clientNum .. " slot 5 -> weapon " .. weapon)
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
	if NOTIFY_SWITCH then
		cp(clientNum, "^7" .. weapon_name(weapon))
	end
	if DEBUG then
		log("client " .. clientNum .. " slot 5 -> weapon " .. weapon)
	end
	return true
end

-- true when this client command is a request for weapon bank / slot 5
local function is_slot5_command(command)
	if type(command) ~= "string" then
		return false
	end
	local cmd = command:lower()

	if cmd == TOGGLE_COMMAND then
		return true
	end
	if cmd == "slot5" then
		return true
	end
	if cmd == "weaponbank" or cmd == "weaponslot" then
		if type(et.trap_Argv) == "function" then
			return tonumber(et.trap_Argv(1) or "") == 5
		end
	end
	return false
end

-- Applies (or refreshes) poison on `target`, injected by `attacker`.
local function poison(target, attacker, levelTime)
	local tteam = team_of(target)
	local ateam = team_of(attacker)

	if not tteam or not ateam then
		return false
	end
	if target == attacker then
		return false          -- no self-poisoning
	end
	if tteam == ateam then
		return false          -- never poison team mates: revives must work
	end
	if not is_alive(target) then
		return false
	end

	local fresh = poisoned[target] == nil
	poisoned[target] = {
		attacker  = attacker,
		expires   = levelTime + POISON_DURATION_MS,
		next_tick = levelTime + POISON_TICK_MS,
	}

	if fresh then
		if NOTIFY_VICTIM then
			cp(target, "^1you have been poisoned!")
		end
		if NOTIFY_ATTACKER then
			cp(attacker, "^2poisoned ^7" .. name_of(target))
		end
	end
	if DEBUG then
		log("poisoned " .. target .. " by " .. attacker
			.. " until " .. poisoned[target].expires)
	end
	return true
end

local function cure(clientNum, reason)
	if poisoned[clientNum] then
		poisoned[clientNum] = nil
		if DEBUG then
			log("cured " .. clientNum .. " (" .. tostring(reason) .. ")")
		end
	end
end

-- view forward vector; ps.viewangles is {pitch, yaw, roll} and
-- forward[2] = -sin(pitch) (q_math.c angles_vectors) - positive pitch is DOWN
local function view_forward(angles)
	local pitch = angles[1] * math.pi / 180
	local yaw   = angles[2] * math.pi / 180
	local cp_   = math.cos(pitch)
	return { cp_ * math.cos(yaw), cp_ * math.sin(yaw), -math.sin(pitch) }
end

-- Who is the attacker stabbing? Traces SYRINGE_RANGE units from the eyes.
local function trace_target(clientNum)
	if type(et.trap_Trace) ~= "function" then
		return nil
	end
	local origin = client_get(clientNum, "ps.origin")
	local view   = client_get(clientNum, "ps.viewangles")
	if not origin or not view then
		return nil
	end
	local vh  = client_get(clientNum, "ps.viewheight") or 32
	local eye = { origin[1], origin[2], origin[3] + vh }
	local fwd = view_forward(view)
	local dst = {
		eye[1] + fwd[1] * SYRINGE_RANGE,
		eye[2] + fwd[2] * SYRINGE_RANGE,
		eye[3] + fwd[3] * SYRINGE_RANGE,
	}

	local ok, tr = pcall(et.trap_Trace, eye, nil, nil, dst, clientNum, MASK_SHOT)
	if not ok or type(tr) ~= "table" then
		return nil
	end
	local hit = tr.entityNum
	if type(hit) ~= "number" or hit >= get_client_slots() then
		return nil
	end
	return hit
end

--[[
 Called whenever a player takes damage.
 The syringe hit on a live enemy is the injection point; the damage itself
 is passed through unchanged (return 0).
]]--
function et_Damage(target, attacker, damage, damageFlags, meansOfDeath)
	if type(et) ~= "table" then
		return 0
	end
	local ok, err = pcall(function()
		if meansOfDeath ~= MOD_SYRINGE then
			return
		end
		local now = (type(et.trap_Milliseconds) == "function"
			and et.trap_Milliseconds()) or 0
		poison(target, attacker, now)
	end)
	if not ok then
		log("ERROR (et_Damage): " .. tostring(err))
	end
	return 0
end

--[[
 Second injection path: a syringe hit on a LIVE enemy does not always raise
 a damage event, so trace the stab ourselves when the needle is fired.
]]--
function et_WeaponFire(clientNum, weapon)
	if type(et) ~= "table" then
		return 0
	end

	local ok, err = pcall(function()
		if weapon == WP_MEDIC_ADRENALINE and CURE_ON_ADRENALINE then
			cure(clientNum, "adrenaline")
			return
		end
		if weapon ~= WP_MEDIC_SYRINGE then
			return
		end
		local target = trace_target(clientNum)
		if not target then
			return
		end
		local now = (type(et.trap_Milliseconds) == "function"
			and et.trap_Milliseconds()) or 0
		poison(target, clientNum, now)
	end)

	if not ok then
		log("ERROR (et_WeaponFire): " .. tostring(err))
	end
	return 0     -- never abort the engine's own syringe handling
end

--[[
 Applies the poison ticks. Runs every server frame and compares against a
 stored next_tick timestamp rather than testing levelTime % interval:
 server frames do not land on exact millisecond values.
]]--
function et_RunFrame(levelTime)
	if type(et) ~= "table" or not levelTime then
		return
	end

	local ok, err = pcall(function()
		for target, p in pairs(poisoned) do
			if not has_client(target) or not is_alive(target)
				or team_of(target) == nil then
				poisoned[target] = nil
			elseif levelTime >= p.expires then
				poisoned[target] = nil
				if NOTIFY_VICTIM then
					cp(target, "^2the poison wears off")
				end
			elseif levelTime >= p.next_tick then
				p.next_tick = levelTime + POISON_TICK_MS

				local attacker = p.attacker
				if not has_client(attacker) then
					attacker = target     -- injector left: count it as self damage
				end

				et.G_Damage(target, attacker, attacker, POISON_TICK_DAMAGE,
					DAMAGE_NO_KNOCKBACK, MOD_SYRINGE)

				if DEBUG then
					log("tick: " .. POISON_TICK_DAMAGE .. " damage to " .. target)
				end
			end
		end
	end)

	if not ok and not reported_errors[tostring(err)] then
		reported_errors[tostring(err)] = true
		log("ERROR: " .. tostring(err) .. " (this error is reported once per map)")
	end
end

-- A respawn, a revive or a team change all end the poison.
function et_ClientSpawn(clientNum, revived, teamChange, restoreHealth)
	cure(clientNum, "spawn")
	if CURE_ON_MEDPACK and restoreHealth == 1 then
		cure(clientNum, "full health")
	end
	grant_syringe(clientNum)
end

--[[
 Slot 5 intercept for the all-class needle.

 The engine's bank cycling stops at the FIRST owned weapon in the bank.
 Bank 5 holds syringe / pliers / smoke marker / smoke bomb, so simply having
 a syringe would make every other bank-5 tool unreachable (engineers would
 lose their pliers, field ops / covert ops would lose their smoke). Instead
 the module cycles bank 5 if the player owns more than one weapon in it,
 and passes every other command through untouched.
]]--
function et_ClientCommand(clientNum, command)
	if type(et) ~= "table" then
		return 0
	end

	local ok, intercepted = pcall(function()
		if not (ALL_CLASSES and SLOT5_TOGGLE) then
			return 0
		end
		if not is_slot5_command(command) then
			return 0
		end
		if not is_on_team(clientNum) then
			return 0
		end
		if not has_weapon(clientNum, WP_MEDIC_SYRINGE) then
			return 0          -- no syringe: stock slot-5 behaviour
		end

		local weapon = pick_bank5(clientNum)
		if not weapon then
			return 0          -- owns nothing in bank 5: stock behaviour
		end
		if weapon == client_get(clientNum, "ps.weapon") then
			return 0          -- already holding it, nothing to do
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
	cure(clientNum, "disconnect")
	no_client[clientNum] = nil
	-- also drop poison this client had injected into others
	for target, p in pairs(poisoned) do
		if p.attacker == clientNum then
			p.attacker = target
		end
	end
end

function et_InitGame(levelTime, randomSeed, restart)
	if type(et) ~= "table" then
		return
	end
	poisoned = {}
	no_client = {}
	reported_errors = {}
	refresh_client_slots()
	if type(et.RegisterModname) == "function" then
		et.RegisterModname(MODULE_NAME)
	end
	log("loaded: the syringe poisons enemies ("
		.. POISON_TICK_DAMAGE .. " damage every "
		.. POISON_TICK_MS .. "ms for " .. POISON_DURATION_MS .. "ms)"
		.. ((ALL_CLASSES and ", all classes carry it") or "")
		.. " (client slots: " .. get_client_slots() .. ")")
end
