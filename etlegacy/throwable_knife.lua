--[[
=============================================================================
 throwable_knife.lua  -  ET: Legacy server-side Lua module
-----------------------------------------------------------------------------
 THROWABLE KNIFE

 Lets players THROW their knife instead of only stabbing with it:

     hold the knife, aim, and fire while the throw is armed
       -> the knife flies out as a projectile,
     it damages the first player it hits (THROW_DAMAGE, MOD_KNIFE),
     it sticks in the world / falls to the ground where it lands,
     you can walk over a thrown knife to pick it up again.

 Both knives are supported: the Axis dagger (WP_KNIFE, 1) and the Allied
 KA-BAR (WP_KNIFE_KABAR, 48).

 HOW IT WORKS
   * et_WeaponFire fires on every shot. When the weapon is a knife and the
     player has a throw available, the module returns 1 to ABORT the normal
     melee stab, then spawns the flying knife itself.
   * The flying knife is a plain entity given a TR_GRAVITY trajectory,
     exactly like a thrown grenade:
         s.eType    = ET_MISSILE
         s.weapon   = the knife weapon id (so it draws as a knife)
         s.pos      = { trType = TR_GRAVITY, trTime = now,
                        trBase = muzzle, trDelta = forward * THROW_SPEED }
     The engine's own missile movement then carries it.
   * Damage is resolved by the module rather than by the engine's missile
     code: every frame each knife in flight is traced from its previous
     position to its current one, and the first player on the way takes
     THROW_DAMAGE via et.G_Damage(..., MOD_KNIFE). This keeps hit detection
     honest for fast knives (a per-frame proximity check would tunnel
     straight through a player at THROW_SPEED).
   * A knife that hits the world stops (TR_STATIONARY) and stays lying
     there for KNIFE_LIFETIME_MS so it can be picked up, then it is freed.
   * Throwing costs the knife: it is removed from the thrower (unless
     KEEP_KNIFE is on) and given back on pickup, on respawn, or after
     RETURN_AFTER_MS if the knife is lost.

 LIMITATIONS
   * There is no client-side "thrown knife" animation, so the thrower sees
     a normal stab animation while the knife model flies away.
   * The knife does not stick visually INTO walls - it comes to rest on the
     surface it hit.
   * Backstab bonus damage does not apply to a thrown knife; it always does
     THROW_DAMAGE (or THROW_DAMAGE_HEADSHOT on a head hit).

 INSTALL
   1. Copy to <fs_home>/legacy/luascripts/throwable_knife.lua
   2. set lua_modules "luascripts/throwable_knife.lua"
   3. Restart the map.
=============================================================================
]]--

-- ============================ CONFIG =====================================
local THROW_SPEED         = 1400   -- how fast the knife flies (units/sec)
local THROW_UP            = 40     -- slight upward bias so it does not dip
local THROW_DAMAGE        = 45     -- damage on a body hit
local THROW_DAMAGE_HEAD   = 100    -- damage on a head hit (instant kill)
local THROW_COOLDOWN_MS   = 800    -- min time between two throws
local KNIFE_LIFETIME_MS   = 30000  -- how long a landed knife stays pickupable
local PICKUP_RANGE        = 48     -- walk this close to pick a knife back up
local KEEP_KNIFE          = false  -- true: throwing does not cost you a knife
local RETURN_AFTER_MS     = 30000  -- give a lost knife back after this long
local HEAD_HEIGHT         = 46     -- above ps.origin: hits above this = head
local DEBUG               = (DEBUG ~= nil and DEBUG) or false
-- ==========================================================================

local WP_KNIFE       = (et and et.WP_KNIFE) or 1
local WP_KNIFE_KABAR = (et and et.WP_KNIFE_KABAR) or 48

local KNIVES = { [WP_KNIFE] = true, [WP_KNIFE_KABAR] = true }

local TEAM_AXIS      = (et and et.TEAM_AXIS) or 1
local TEAM_ALLIES    = (et and et.TEAM_ALLIES) or 2
local MAX_CLIENTS    = (et and et.MAX_CLIENTS) or 64
local STAT_HEALTH    = (et and et.STAT_HEALTH) or 0
local MASK_SHOT      = (et and et.MASK_SHOT) or 1
local MOD_KNIFE      = (et and et.MOD_KNIFE) or 5

-- q_shared.h entity / trajectory types
local ET_MISSILE    = 3
local TR_STATIONARY = 0
local TR_GRAVITY    = 6

local MODULE_NAME = "throwable_knife"

-- knives currently in the world:
--   flying[entnum] = { owner, weapon, last = {x,y,z}, landed = nil|ms }
local knives = {}
-- next allowed throw time per client
local next_throw = {}
-- clients owed a knife back: owed[clientNum] = { weapon = w, at = ms }
local owed = {}

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
	local h = client_get(clientNum, "ps.stats", STAT_HEALTH)
	return type(h) == "number" and h > 0
end

-- ps.viewangles is {pitch, yaw, roll}; forward[2] = -sin(pitch), so a
-- positive pitch looks DOWN (q_math.c angles_vectors)
local function view_forward(angles)
	local pitch = angles[1] * math.pi / 180
	local yaw   = angles[2] * math.pi / 180
	local cp    = math.cos(pitch)
	return { cp * math.cos(yaw), cp * math.sin(yaw), -math.sin(pitch) }
end

local function dist2(a, b)
	local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
	return dx * dx + dy * dy + dz * dz
end

-- ---------------------------------------------------------------------------
-- throwing

local function spawn_knife(clientNum, weapon, levelTime)
	if type(et.G_Spawn) ~= "function" then
		log("warning: et.G_Spawn is not available - knives cannot be thrown")
		return nil
	end

	local origin = client_get(clientNum, "ps.origin")
	local view   = client_get(clientNum, "ps.viewangles")
	if not origin or not view then
		return nil
	end
	local vh  = client_get(clientNum, "ps.viewheight") or 32
	local fwd = view_forward(view)

	-- muzzle: from the eyes, a little way forward so it does not spawn
	-- inside the thrower's own bounding box
	local muzzle = {
		origin[1] + fwd[1] * 16,
		origin[2] + fwd[2] * 16,
		origin[3] + vh + fwd[3] * 16,
	}

	local ok, ent = pcall(et.G_Spawn)
	if not ok or type(ent) ~= "number" then
		return nil
	end

	pcall(et.gentity_set, ent, "classname", "thrown_knife")
	pcall(et.gentity_set, ent, "s.eType", ET_MISSILE)
	pcall(et.gentity_set, ent, "s.weapon", weapon)
	pcall(et.gentity_set, ent, "r.ownerNum", clientNum)
	pcall(et.gentity_set, ent, "s.pos", {
		trType  = TR_GRAVITY,
		trTime  = levelTime,
		trBase  = muzzle,
		trDelta = {
			fwd[1] * THROW_SPEED,
			fwd[2] * THROW_SPEED,
			fwd[3] * THROW_SPEED + THROW_UP,
		},
	})
	pcall(et.gentity_set, ent, "r.currentOrigin", muzzle)
	if type(et.trap_LinkEntity) == "function" then
		pcall(et.trap_LinkEntity, ent)
	end

	knives[ent] = {
		owner  = clientNum,
		weapon = weapon,
		last   = muzzle,
		landed = nil,
	}

	if DEBUG then
		log("client " .. clientNum .. " threw knife (weapon " .. weapon
			.. ") as entity " .. ent)
	end
	return ent
end

--[[
 Called for every shot. Returning 1 aborts qagame's own weapon handling,
 which is how the melee stab is replaced by the throw.
]]--
function et_WeaponFire(clientNum, weapon)
	if type(et) ~= "table" then
		return 0
	end

	local ok, res = pcall(function()
		if not KNIVES[weapon] then
			return 0
		end
		if not team_of(clientNum) or not is_alive(clientNum) then
			return 0
		end

		local now = (type(et.trap_Milliseconds) == "function"
			and et.trap_Milliseconds()) or 0

		if next_throw[clientNum] and now < next_throw[clientNum] then
			return 0     -- still on cooldown: let them stab normally
		end

		if not spawn_knife(clientNum, weapon, now) then
			return 0     -- could not spawn: fall back to the stock stab
		end

		next_throw[clientNum] = now + THROW_COOLDOWN_MS

		if not KEEP_KNIFE then
			pcall(et.RemoveWeaponFromPlayer, clientNum, weapon)
			owed[clientNum] = { weapon = weapon, at = now + RETURN_AFTER_MS }
		end

		return 1         -- swallow the stab, the knife is in the air
	end)

	if not ok then
		log("ERROR (et_WeaponFire): " .. tostring(res))
		return 0
	end
	return res
end

-- ---------------------------------------------------------------------------
-- flight, hits, landing and pickup

local function give_knife_back(clientNum, weapon)
	pcall(et.AddWeaponToPlayer, clientNum, weapon, 0, 1, 0)
	owed[clientNum] = nil
	if DEBUG then
		log("client " .. clientNum .. " got knife " .. weapon .. " back")
	end
end

local function free_knife(ent)
	knives[ent] = nil
	if type(et.G_FreeEntity) == "function" then
		pcall(et.G_FreeEntity, ent)
	end
end

-- did the knife hit a player between `from` and `to`?
local function trace_hit(ent, k, from, to)
	if type(et.trap_Trace) ~= "function" then
		return nil
	end
	local ok, tr = pcall(et.trap_Trace, from, nil, nil, to, ent, MASK_SHOT)
	if not ok or type(tr) ~= "table" then
		return nil
	end
	return tr
end

local function hit_player(ent, k, victim, hitpos)
	local vorigin = client_get(victim, "ps.origin")
	local damage  = THROW_DAMAGE

	-- head hit: anything above HEAD_HEIGHT over the victim's feet
	if vorigin and hitpos and hitpos[3] - vorigin[3] >= HEAD_HEIGHT then
		damage = THROW_DAMAGE_HEAD
	end

	et.G_Damage(victim, k.owner, k.owner, damage, 0, MOD_KNIFE)

	if DEBUG then
		log("thrown knife " .. ent .. " hit client " .. victim
			.. " for " .. damage)
	end
end

--[[
 Called every server frame.
 Do not use levelTime % interval anywhere here: server frame times are not
 guaranteed to land on a particular millisecond value.
]]--
function et_RunFrame(levelTime)
	if type(et) ~= "table" or not levelTime then
		return
	end

	local ok, err = pcall(function()
		-- 1. knives in flight / lying around
		for ent, k in pairs(knives) do
			if et.gentity_get(ent, "inuse") ~= 1 then
				knives[ent] = nil
			elseif k.landed then
				-- lying on the ground: pick it up or time it out
				if levelTime - k.landed >= KNIFE_LIFETIME_MS then
					free_knife(ent)
				else
					local pos = et.gentity_get(ent, "r.currentOrigin")
						or et.gentity_get(ent, "origin")
					if pos then
						for c = 0, get_client_slots() - 1 do
							if has_client(c) and is_alive(c) and team_of(c) then
								local o = client_get(c, "ps.origin")
								if o and dist2(o, pos) <= PICKUP_RANGE * PICKUP_RANGE then
									give_knife_back(c, k.weapon)
									free_knife(ent)
									break
								end
							end
						end
					end
				end
			else
				-- in flight: trace from where it was to where it is
				local pos = et.gentity_get(ent, "r.currentOrigin")
					or et.gentity_get(ent, "origin")
				if pos then
					local tr = trace_hit(ent, k, k.last, pos)
					if tr then
						local hitent = tr.entityNum
						local frac   = tr.fraction or 1.0

						if type(hitent) == "number" and hitent < get_client_slots()
							and has_client(hitent) and is_alive(hitent)
							and hitent ~= k.owner then
							hit_player(ent, k, hitent, tr.endpos or pos)
							free_knife(ent)
						elseif frac < 1.0 then
							-- hit the world: come to rest here
							local endpos = tr.endpos or pos
							pcall(et.gentity_set, ent, "s.pos", {
								trType  = TR_STATIONARY,
								trTime  = levelTime,
								trBase  = endpos,
								trDelta = { 0, 0, 0 },
							})
							pcall(et.gentity_set, ent, "r.currentOrigin", endpos)
							k.landed = levelTime
							if DEBUG then
								log("knife " .. ent .. " landed")
							end
						end
					end
					k.last = pos
				end
			end
		end

		-- 2. hand back knives nobody picked up
		for c, o in pairs(owed) do
			if not has_client(c) then
				owed[c] = nil
			elseif levelTime >= o.at then
				give_knife_back(c, o.weapon)
			end
		end
	end)

	if not ok and not reported_errors[tostring(err)] then
		reported_errors[tostring(err)] = true
		log("ERROR: " .. tostring(err) .. " (this error is reported once per map)")
	end
end

-- A fresh spawn always comes with a knife, so nothing is owed any more.
function et_ClientSpawn(clientNum, revived, teamChange, restoreHealth)
	owed[clientNum] = nil
	next_throw[clientNum] = nil
end

function et_ClientDisconnect(clientNum)
	owed[clientNum] = nil
	next_throw[clientNum] = nil
	no_client[clientNum] = nil
end

function et_InitGame(levelTime, randomSeed, restart)
	if type(et) ~= "table" then
		return
	end
	knives = {}
	owed = {}
	next_throw = {}
	no_client = {}
	reported_errors = {}
	refresh_client_slots()
	if type(et.RegisterModname) == "function" then
		et.RegisterModname(MODULE_NAME)
	end
	log("loaded: knives can be thrown (" .. THROW_DAMAGE .. " damage, "
		.. THROW_DAMAGE_HEAD .. " on a head hit)"
		.. " (client slots: " .. get_client_slots() .. ")")
end
