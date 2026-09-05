--[[
=============================================================================
 no_combat_selfkill.lua  -  ET: Legacy server-side Lua module
-----------------------------------------------------------------------------
 NO /KILL IN A FIRE FIGHT

 Blocks the /kill (and /suicide) self-kill command while the player is in
 combat, so nobody can deny an enemy the frag by killing themselves.

 A player cannot /kill when EITHER of these is true:

   1. IN A FIRE FIGHT - they dealt damage to, or took damage from, an enemy
      within COMBAT_WINDOW_MS (default 5 seconds), or

   2. SEEN BY AN ENEMY - a living enemy is within SIGHT_RANGE, has them
      inside their view cone, and has clear line of sight to them (a real
      trace, so walls, doors and cover block it).

 When the command is refused the player gets a centre print telling them
 why and how long they have to wait. As soon as they break contact and no
 enemy can see them, /kill works normally again.

 HOW IT WORKS
   * et_Damage records the level time on both the attacker and the victim
     whenever damage crosses the team line, which is what "in a fire fight"
     means. Falling damage, world damage and friendly fire do NOT count.
   * et_ClientCommand intercepts "kill" and "suicide" (and, optionally,
     "team" changes, which are the other way to dodge a frag - see
     BLOCK_TEAM_SWITCH). Returning 1 swallows the command.
   * The line-of-sight test uses et.trap_Trace from the enemy's eyes to the
     player's chest, ignoring the enemy's own entity. A trace that arrives
     (fraction >= 1, or it hits the player) means the player is visible.
     The enemy must also be facing them: the dot product of the enemy's
     view vector with the direction to the player has to be inside
     SIGHT_CONE_ANGLE. ps.viewangles is {pitch, yaw, roll} and the engine's
     forward vector is (cos p cos y, cos p sin y, -sin p) - getting that
     wrong makes the cone test silently never match.
   * Spectators, players already dead, and players in limbo are ignored
     everywhere.

 EXCEPTIONS (all configurable)
   * A player who is stuck can still escape: after STUCK_GRACE_MS of not
     moving at all, /kill is allowed regardless.
   * ALLOW_WHEN_LOW_HEALTH lets a player finish themselves off below a
     health threshold if you want mercy kills to stay possible (off by
     default).

 INSTALL
   1. Copy to <fs_home>/legacy/luascripts/no_combat_selfkill.lua
   2. set lua_modules "luascripts/no_combat_selfkill.lua"
   3. Restart the map.
=============================================================================
]]--

-- ============================ CONFIG =====================================
local COMBAT_WINDOW_MS    = 5000   -- "in a fire fight" for this long after damage
local SIGHT_RANGE         = 2000   -- how far an enemy can "see" you (units)
local SIGHT_CONE_ANGLE    = 90     -- half angle of the enemy's view cone (deg)
local BLOCK_TEAM_SWITCH   = false  -- also block /team while in combat
local STUCK_GRACE_MS      = 8000   -- perfectly still this long -> allow /kill
local ALLOW_WHEN_LOW_HEALTH = false
local LOW_HEALTH          = 20     -- with the above on, /kill is free below this
local DEBUG               = (DEBUG ~= nil and DEBUG) or false
-- ==========================================================================

local TEAM_AXIS      = (et and et.TEAM_AXIS) or 1
local TEAM_ALLIES    = (et and et.TEAM_ALLIES) or 2
local MAX_CLIENTS    = (et and et.MAX_CLIENTS) or 64
local STAT_HEALTH    = (et and et.STAT_HEALTH) or 0
local MASK_SHOT      = (et and et.MASK_SHOT) or 1

local DEG2RAD    = math.pi / 180
local CONE_COS   = math.cos(SIGHT_CONE_ANGLE * DEG2RAD)
local RANGE_SQ   = SIGHT_RANGE * SIGHT_RANGE

local MODULE_NAME = "no_combat_selfkill"

-- last time (levelTime) each client was involved in cross-team damage
local last_combat = {}
-- stillness tracking: still_since[c] = levelTime the client stopped moving
local still_since = {}
local last_origin = {}

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

local function now_ms()
	if type(et.trap_Milliseconds) == "function" then
		return et.trap_Milliseconds() or 0
	end
	return 0
end

-- ps.viewangles is {pitch, yaw, roll}; forward[2] = -sin(pitch), so a
-- positive pitch means looking DOWN (q_math.c angles_vectors)
local function view_forward(angles)
	local pitch = angles[1] * DEG2RAD
	local yaw   = angles[2] * DEG2RAD
	local cp    = math.cos(pitch)
	return { cp * math.cos(yaw), cp * math.sin(yaw), -math.sin(pitch) }
end

local function eyes_of(clientNum)
	local o = client_get(clientNum, "ps.origin")
	if not o then
		return nil
	end
	local vh = client_get(clientNum, "ps.viewheight") or 32
	return { o[1], o[2], o[3] + vh }
end

--[[
 Can `watcher` currently see `target`?
 Range, view cone and a real line-of-sight trace all have to agree.
]]--
local function can_see(watcher, target)
	local weye = eyes_of(watcher)
	local torg = client_get(target, "ps.origin")
	if not weye or not torg then
		return false
	end

	-- aim at the target's chest rather than their feet
	local tpos = { torg[1], torg[2], torg[3] + 32 }

	local dx, dy, dz = tpos[1] - weye[1], tpos[2] - weye[2], tpos[3] - weye[3]
	local d2 = dx * dx + dy * dy + dz * dz
	if d2 > RANGE_SQ then
		return false
	end

	local len = math.sqrt(d2)
	if len < 1 then
		return true          -- standing inside each other
	end

	local view = client_get(watcher, "ps.viewangles")
	if not view then
		return false
	end
	local fwd = view_forward(view)
	local dot = fwd[1] * dx / len + fwd[2] * dy / len + fwd[3] * dz / len
	if dot < CONE_COS then
		return false         -- not facing the target
	end

	if type(et.trap_Trace) ~= "function" then
		return true          -- no trace available: be strict, assume seen
	end
	local ok, tr = pcall(et.trap_Trace, weye, nil, nil, tpos, watcher, MASK_SHOT)
	if not ok or type(tr) ~= "table" then
		return true
	end

	-- the trace reached the target, or stopped ON the target
	if (tr.fraction or 1.0) >= 1.0 then
		return true
	end
	return tr.entityNum == target
end

-- Is any living enemy looking at this player right now?
-- Returns the enemy's client number, or nil.
local function seen_by_enemy(clientNum)
	local myteam = team_of(clientNum)
	if not myteam then
		return nil
	end
	for c = 0, get_client_slots() - 1 do
		if c ~= clientNum and has_client(c) then
			local t = team_of(c)
			if t and t ~= myteam and is_alive(c) and can_see(c, clientNum) then
				return c
			end
		end
	end
	return nil
end

-- Has the player been perfectly still long enough to count as stuck?
local function is_stuck(clientNum, now)
	local since = still_since[clientNum]
	return since ~= nil and (now - since) >= STUCK_GRACE_MS
end

--[[
 Called whenever a player takes damage.
 Cross-team damage puts BOTH parties in a fire fight.
]]--
function et_Damage(target, attacker, damage, damageFlags, meansOfDeath)
	if type(et) ~= "table" then
		return 0
	end
	local ok, err = pcall(function()
		local tteam = team_of(target)
		local ateam = team_of(attacker)
		-- world / falling / friendly damage does not start a fire fight
		if not tteam or not ateam or tteam == ateam or target == attacker then
			return
		end
		local now = now_ms()
		last_combat[target]   = now
		last_combat[attacker] = now
	end)
	if not ok then
		log("ERROR (et_Damage): " .. tostring(err))
	end
	return 0
end

local function cp(clientNum, text)
	if type(et.trap_SendServerCommand) == "function" then
		et.trap_SendServerCommand(clientNum, "cp \"" .. text .. "\"")
	end
end

--[[
 Called for every client command.
 Return 1 to swallow it, 0 to let qagame handle it.
]]--
function et_ClientCommand(clientNum, command)
	if type(et) ~= "table" then
		return 0
	end

	local ok, res = pcall(function()
		if type(command) ~= "string" then
			return 0
		end
		local cmd = command:lower()

		local is_selfkill = (cmd == "kill" or cmd == "suicide")
		local is_team     = (cmd == "team")
		if not is_selfkill and not (BLOCK_TEAM_SWITCH and is_team) then
			return 0
		end

		-- only living players on a team are restricted
		if not team_of(clientNum) or not is_alive(clientNum) then
			return 0
		end

		local now = now_ms()

		if ALLOW_WHEN_LOW_HEALTH then
			local h = client_get(clientNum, "ps.stats", STAT_HEALTH)
			if h and h <= LOW_HEALTH then
				return 0
			end
		end

		-- stuck players must always be able to free themselves
		if is_stuck(clientNum, now) then
			return 0
		end

		-- 1. in a fire fight?
		local lc = last_combat[clientNum]
		if lc and (now - lc) < COMBAT_WINDOW_MS then
			local left = math.ceil((COMBAT_WINDOW_MS - (now - lc)) / 1000)
			cp(clientNum, "^1you cannot ^7/kill ^1in a fire fight^7\n"
				.. "^3wait " .. left .. " second" .. (left == 1 and "" or "s"))
			if DEBUG then
				log("blocked /kill for " .. clientNum .. " (in combat)")
			end
			return 1
		end

		-- 2. seen by an enemy?
		local watcher = seen_by_enemy(clientNum)
		if watcher then
			cp(clientNum, "^1you cannot ^7/kill ^1while an enemy can see you")
			if DEBUG then
				log("blocked /kill for " .. clientNum
					.. " (seen by " .. watcher .. ")")
			end
			return 1
		end

		return 0
	end)

	if not ok then
		log("ERROR (et_ClientCommand): " .. tostring(res))
		return 0
	end
	return res
end

--[[
 Tracks stillness so a genuinely stuck player is not trapped by this module.
 Runs every frame; the timestamps are compared against stored values rather
 than testing levelTime % interval, which server frames never guarantee.
]]--
function et_RunFrame(levelTime)
	if type(et) ~= "table" or not levelTime then
		return
	end

	local ok, err = pcall(function()
		for c = 0, get_client_slots() - 1 do
			if has_client(c) and team_of(c) and is_alive(c) then
				local o = client_get(c, "ps.origin")
				if o then
					local prev = last_origin[c]
					if prev and prev[1] == o[1] and prev[2] == o[2]
						and prev[3] == o[3] then
						if not still_since[c] then
							still_since[c] = levelTime
						end
					else
						still_since[c] = nil
					end
					last_origin[c] = { o[1], o[2], o[3] }
				end
			else
				still_since[c] = nil
				last_origin[c] = nil
			end
		end
	end)

	if not ok and not reported_errors[tostring(err)] then
		reported_errors[tostring(err)] = true
		log("ERROR: " .. tostring(err) .. " (this error is reported once per map)")
	end
end

function et_ClientSpawn(clientNum, revived, teamChange, restoreHealth)
	last_combat[clientNum] = nil
	still_since[clientNum] = nil
	last_origin[clientNum] = nil
end

function et_ClientDisconnect(clientNum)
	last_combat[clientNum] = nil
	still_since[clientNum] = nil
	last_origin[clientNum] = nil
	no_client[clientNum]   = nil
end

function et_InitGame(levelTime, randomSeed, restart)
	if type(et) ~= "table" then
		return
	end
	last_combat = {}
	still_since = {}
	last_origin = {}
	no_client = {}
	reported_errors = {}
	refresh_client_slots()
	if type(et.RegisterModname) == "function" then
		et.RegisterModname(MODULE_NAME)
	end
	log("loaded: /kill is blocked in a fire fight or while an enemy sees you"
		.. " (client slots: " .. get_client_slots() .. ")")
end
