--[[
=============================================================================
 poison_needle.lua  -  ET: Legacy server-side Lua module
-----------------------------------------------------------------------------
 POISON NEEDLE

 Turns the medic syringe into a weapon against ENEMIES: stabbing an enemy
 player with the needle injects poison instead of doing nothing.

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

 HOW IT WORKS
   * et_Damage fires for every damage event, including the syringe hit
     (MOD_SYRINGE, 24). When the target is a live enemy the module records
     a poison entry for that client and returns 0, letting the original
     (zero) damage through unchanged.
   * Because a syringe hit on a live enemy does 0 damage in some builds,
     the module ALSO watches et_WeaponFire: when a medic fires the syringe
     it traces forward SYRINGE_RANGE units and poisons the enemy player it
     hits. Both paths feed the same "poison this client" function, and the
     refresh logic makes the overlap harmless.
   * et_RunFrame applies the ticks with et.G_Damage(target, attacker,
     attacker, damage, DAMAGE_NO_KNOCKBACK, MOD_SYRINGE) - real damage, so
     death, gibbing, obituaries and XP all work as usual.
   * Poison state is cleared in et_ClientSpawn (respawn AND revive) and
     et_ClientDisconnect, so it can never leak into a new life.

 LIMITATIONS
   * Team mates are never poisoned, even with friendly fire on: the syringe
     must stay usable for revives.
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
local DEBUG              = (DEBUG ~= nil and DEBUG) or false
-- ==========================================================================

local TEAM_AXIS      = (et and et.TEAM_AXIS) or 1
local TEAM_ALLIES    = (et and et.TEAM_ALLIES) or 2
local MAX_CLIENTS    = (et and et.MAX_CLIENTS) or 64
local STAT_HEALTH    = (et and et.STAT_HEALTH) or 0

local WP_MEDIC_SYRINGE    = (et and et.WP_MEDIC_SYRINGE) or 11
local WP_MEDIC_ADRENALINE = (et and et.WP_MEDIC_ADRENALINE) or 44

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

-- Who is the medic stabbing? Traces SYRINGE_RANGE units from the eyes.
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
		.. " (client slots: " .. get_client_slots() .. ")")
end
