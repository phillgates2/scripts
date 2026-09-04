--[[
=============================================================================
 kick_projectiles.lua  -  ET: Legacy server-side Lua module
-----------------------------------------------------------------------------
 Lets players KICK grenades and canisters out of the way by "using" them
 (the USE button, default E key) while standing right next to them:

   kickable projectiles (thrown, ticking or lying on the ground):
     * WP_GRENADE_LAUNCHER  (4)  - axis hand grenade
     * WP_GRENADE_PINEAPPLE (9)  - allied hand grenade
     * WP_SMOKE_MARKER      (22) - airstrike canister
     * WP_SMOKE_BOMB        (29) - smoke grenade / canister

   stand within KICK_RANGE of the projectile, stop, look at it and use it
   -> it is kicked away from you with an extra hop. The fuse is NOT
   restarted - a ticking grenade you kick still explodes on time, it
   just explodes somewhere else.

 HOW IT WORKS
   * Thrown grenades/canisters are ET_MISSILE gentities (s.eType == 3)
     that fly on a TR_GRAVITY trajectory (s.pos). The engine moves them
     by evaluating s.pos every frame and keeps r.currentOrigin up to
     date, so "kicking" is exactly what G_BounceMissile() does on a
     bounce:
         - s.pos.trType  = TR_GRAVITY
         - s.pos.trTime  = level.time
         - s.pos.trBase  = current position (popped up a few units)
         - s.pos.trDelta = kick velocity (direction away from the player
                           plus a fixed upward component)
       The engine's own per-frame thinking then carries the new
       trajectory, so the kick behaves just like a strong bounce: it
       bounces off the ground, keeps ticking and can be kicked again
       after the cooldown.
   * The Lua API does not expose the raw usercmd button state, so the
     USE press is approximated: the player must be (1) standing within
     KICK_RANGE of the projectile, (2) roughly stationary (so the kick
     fires when you stop next to it to use it - not while you are still
     running towards it), and (3) looking at it. A per-projectile
     cooldown prevents continuous re-kicking while you keep looking at
     it.

 KNOWN LIMITATIONS
   * The airstrike canister (WP_SMOKE_MARKER) only exists as a kickable
     missile for about 5 seconds after it is thrown - once the airstrike
     has been called the entity turns into an explosion effect and is
     gone. Kick it while it is still smoking on the ground. The smoke
     bomb (WP_SMOKE_BOMB) can be kicked for its whole ~18 second life.
   * Kicking a canister does NOT cancel the airstrike: the plane will
     still bomb the spot where the canister ends up after the kick.
   * There is no way to read the USE button from Lua, so the kick is
     triggered by proximity + aim while standing still instead of the
     button press itself.

 TROUBLESHOOTING
   [kick_projectiles] ERROR: ... tried to get invalid gentity field
   "sess.sessionTeam"
     Client fields (sess.* / ps.* / pers.*) only exist on entity slots that
     have a client attached. et.MAX_CLIENTS is 64, but a server only has
     sv_maxclients client slots - the slots above that have a NULL client
     pointer and et.gentity_get() cannot even find the field name for them,
     so it raises this error and the whole server frame hook is aborted.
     This module therefore only walks slots 0 .. sv_maxclients-1, checks
     "inuse" (an entity field, always readable) first and reads every client
     field through a protected call. If you still see this error, you are
     running an older copy of this file - re-copy it to your luascripts
     folder and restart the map.

   The debug line counts projectiles but no "kick: ent ..." line ever appears
     A kick needs all three conditions at once: inside KICK_RANGE, standing
     still (STATIONARY_SPEED) and inside the CONE_HALF_ANGLE view cone. The
     view cone is the one that fails silently, and the usual cause is reading
     ps.viewangles in the wrong order: it is {pitch, yaw, roll} (q_shared.h
     PITCH 0 / YAW 1 / ROLL 2) and the engine's forward vector is
     (cos(pitch)*cos(yaw), cos(pitch)*sin(yaw), -sin(pitch)) - positive
     pitch looks DOWN. To test, raise CONE_HALF_ANGLE to 90: if kicks start
     appearing, the aim test was what blocked them.

 DEBUG
   Set DEBUG = true below to print diagnostics to the server console:
   module load status, a summary every 2 seconds and every kick event.
   You should see "[kick_projectiles] loaded: ..." on map start and then

     [kick_projectiles] debug: kickable projectiles=1 of 3 missiles
       (top entity slot 240) players=13 client slots=40

   "kickable projectiles" is what this module can act on; "of N missiles"
   is every ET_MISSILE the scan saw, including the ones that cannot be
   kicked (dynamite, rockets, landmines). So projectiles=0 with missiles>0
   simply means no grenade or canister was in the air at that moment,
   while projectiles=0 with missiles=0 through a whole busy map means the
   scan is not seeing the entities at all.

 CONFIG
   See the CONFIG block below - range, view cone, kick strength, cooldown
   and the set of kickable weapons are all adjustable.

 INSTALL
   1. Copy this file into your mod's luascripts folder, e.g.:
        <fs_home>/legacy/luascripts/kick_projectiles.lua
      (on Linux that is usually ~/.etlegacy/legacy/luascripts/)
   2. Load the module from your server config (legacy.cfg):
        set lua_modules "luascripts/kick_projectiles.lua"
      Space-separate several modules, e.g.:
        set lua_modules "luascripts/kick_projectiles.lua luascripts/covert_disguise_break.lua"
   3. Restart the map/server. On load the console prints:
        [kick_projectiles] loaded: stand next to a grenade/canister, stop, look at it and use it to kick it
=============================================================================
]]--

-- ============================ CONFIG =====================================
local KICK_RANGE        = 64     -- max distance (units, ~5 ft) feet->projectile
local CONE_HALF_ANGLE   = 60     -- half of the "looking at" cone, in degrees
local KICK_POWER        = 420    -- horizontal kick speed (units/sec)
local KICK_UP           = 240    -- extra upward speed so it hops off the ground
local KICK_COOLDOWN_MS  = 1200   -- per-projectile cooldown between kicks
local KICK_POP          = 4      -- units lifted off the surface on a kick
local KICK_SOUND        = true   -- play a footstep sound at the projectile
local KICK_SOUND_FILE   = "sound/footsteps/footstep1.wav"
local STATIONARY_SPEED  = 120    -- max horizontal speed (u/s) for a "use" attempt
local DEBUG             = true   -- console diagnostics (set false for production)
-- weapons that can be kicked (weapon ids, bg_public.h / et.WP_*)
local KICKABLE_WEAPONS = {
	[ (et and et.WP_GRENADE_LAUNCHER) or 4 ] = true,  -- axis hand grenade
	[ (et and et.WP_GRENADE_PINEAPPLE)  or 9 ] = true,  -- allied hand grenade
	[ (et and et.WP_SMOKE_MARKER)       or 22] = true,  -- airstrike canister
	[ (et and et.WP_SMOKE_BOMB)         or 29] = true,  -- smoke grenade
}
-- ==========================================================================

local TEAM_FREE        = (et and et.TEAM_FREE) or 0
local TEAM_SPECTATOR   = (et and et.TEAM_SPECTATOR) or 3
local MAX_CLIENTS      = (et and et.MAX_CLIENTS) or 64
local MAX_ENTITIES     = (et and et.MAX_GENTITIES) or 1024
local STAT_HEALTH      = (et and et.STAT_HEALTH) or 0

-- entity types (q_shared.h: ET_GENERAL=0, ET_PLAYER=1, ET_ITEM=2, ...)
local ET_MISSILE = 3
-- trajectory types (q_shared.h: TR_STATIONARY=0, ..., TR_GRAVITY=6, ...)
local TR_GRAVITY = 6

local DEG2RAD = math.pi / 180
local CONE_COS = math.cos(CONE_HALF_ANGLE * DEG2RAD)
local RANGE_SQ = KICK_RANGE * KICK_RANGE
local STATIONARY_SQ = STATIONARY_SPEED * STATIONARY_SPEED

local MODULE_NAME = "kick_projectiles"

-- last kick time (levelTime) per projectile entity number
local last_kick = {}

local kick_sound_index = 0

-- last time (levelTime) we printed the debug summary
local last_debug_print = 0
-- runtime errors already reported this map (message -> true), so the same
-- error is printed once instead of every frame
local reported_errors = {}

-- how many entity slots are client slots on THIS server (see
-- refresh_client_slots below); nil until it has been read from the server
local client_slots = nil

-- client slots that turned out to have no gclient attached: reading a
-- client field from them raises an error, so they are skipped from then on
local no_client = {}

-- safe console print - never crash because the API is missing
local function log(msg)
	if type(et) == "table" and type(et.G_Print) == "function" then
		et.G_Print("[" .. MODULE_NAME .. "] " .. msg .. "\n")
	end
end

--[[
 Number of client slots on this server.

 Entity slots 0 .. sv_maxclients-1 are the client slots; the engine attaches
 a gclient structure to exactly those (g_main.c: "set client fields on player
 ents" loops over level.maxclients). Slots sv_maxclients .. MAX_CLIENTS-1
 exist as entities but have a NULL client pointer.

 That matters because et.gentity_get() looks a field name up in the client
 field table ONLY when the entity has a client attached (g_lua.c ->
 _etH_gentity_getfield). On a slot without one, "sess.sessionTeam" (and
 every other sess.* / ps.* / pers.* field) is not found at all and the API
 raises

     tried to get invalid gentity field "sess.sessionTeam"

 which aborts the whole et_RunFrame call. So never loop client fields up to
 et.MAX_CLIENTS - loop up to sv_maxclients.
]]--
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

-- cached client slot count; read it from the server on first use so the
-- module also works when it is loaded after et_InitGame has run
local function get_client_slots()
	return client_slots or refresh_client_slots()
end

--[[
 Reads a client-only field (sess.* / ps.* / pers.*) from a client slot.

 Belt and braces on top of refresh_client_slots(): the read is wrapped in a
 pcall so that a slot without a gclient can never abort the module. Such a
 slot is remembered and skipped for the rest of the map (the condition never
 changes while a map is running).

 Returns nil when the field cannot be read.
]]--
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

-- forward view direction from ps.viewangles
--
-- ps.viewangles is ordered {pitch, yaw, roll}: q_shared.h defines
-- PITCH 0, YAW 1, ROLL 2, so in Lua (1-based) angles[1] is the PITCH and
-- angles[2] is the YAW. The engine builds the view vector in
-- angles_vectors() (q_math.c) as
--
--     forward[0] =  cos(pitch) * cos(yaw)
--     forward[1] =  cos(pitch) * sin(yaw)
--     forward[2] = -sin(pitch)          <-- note the sign
--
-- Positive pitch means looking DOWN, so the vertical component is negated.
-- Mixing the two angles up (or dropping the sign) makes the dot product
-- below point somewhere else entirely and the "looking at it" test never
-- succeeds: the module then reports projectiles but never kicks anything.
local function view_forward(angles)
	local pitch = angles[1] * DEG2RAD
	local yaw   = angles[2] * DEG2RAD
	local cp    = math.cos(pitch)
	return { cp * math.cos(yaw), cp * math.sin(yaw), -math.sin(pitch) }
end

-- collects the live players (on a team, not dead) into players[]
local function collect_players(players)
	for i = 0, get_client_slots() - 1 do
		-- only read sess.* / ps.* from slots that actually have a client
		-- attached (inuse == 1); empty slots would raise "tried to get
		-- invalid gentity field" in et.gentity_get
		if et.gentity_get(i, "inuse") == 1 then
			local team = client_get(i, "sess.sessionTeam")
			local health = client_get(i, "ps.stats", STAT_HEALTH)
			if team and team ~= TEAM_FREE and team ~= TEAM_SPECTATOR
				and health and health > 0 then
				local origin = client_get(i, "ps.origin")
				if origin then
					local view  = client_get(i, "ps.viewangles")
					local viewh = client_get(i, "ps.viewheight")
					local vel   = client_get(i, "ps.velocity")
					if view and vel then
						players[#players + 1] = {
							num    = i,
							origin = origin,
							eye    = { origin[1], origin[2],
								origin[3] + (viewh or 32) },
							fwd    = view_forward(view),
							-- horizontal speed squared - used to require the
							-- player to stand still ("use" intent) before kicking
							speed2 = vel[1] * vel[1] + vel[2] * vel[2],
						}
					end
				end
			end
		end
	end
end

-- kicks the projectile entity `p` away from player `pl`
local function kick_projectile(p, pos, pl, levelTime)
	local feetX  = pl.origin[1]
	local feetY  = pl.origin[2]
	local feetZ  = pl.origin[3] + 8

	local dx = pos[1] - feetX
	local dy = pos[2] - feetY
	local dz = pos[3] - feetZ
	local len = math.sqrt(dx * dx + dy * dy + dz * dz)
	if len < 1 then
		len = 1
	end

	local vx = dx / len * KICK_POWER
	local vy = dy / len * KICK_POWER
	local vz = dz / len * KICK_POWER + KICK_UP

	local newBase = { pos[1], pos[2], pos[3] + KICK_POP }

	local tr = et.gentity_get(p, "s.pos")
	if not tr then
		return
	end
	tr.trType    = TR_GRAVITY
	tr.trTime    = levelTime
	tr.trBase    = newBase
	tr.trDelta   = { vx, vy, vz }
	et.gentity_set(p, "s.pos", tr)
	et.gentity_set(p, "r.currentOrigin", newBase)

	last_kick[p] = levelTime

	if KICK_SOUND and kick_sound_index > 0
		and type(et.G_Sound) == "function" then
		et.G_Sound(p, kick_sound_index)
	end

	if DEBUG then
		log("kick: ent " .. p .. " (weapon " .. tostring(et.gentity_get(p, "s.weapon"))
			.. ") by client " .. pl.num .. " vel=(" .. vx .. "," .. vy .. "," .. vz .. ")")
	end
end

--[[
 Called every server frame; levelTime is the level time in ms.
]]--
function et_RunFrame(levelTime)
	if type(et) ~= "table" then
		return
	end
	-- never let a runtime error silently kill the module: report it once
	-- and keep going. (Without this, a single Lua error sets the VM error
	-- state and et_RunFrame stops being called for the rest of the map.)
	local ok, err = pcall(function()
		if not levelTime then
			return
		end

		-- 1. find all kickable projectiles (few in number)
		--    Slots 0..MAX_CLIENTS-1 are client slots; G_Spawn() reserves them
		--    ("the slots from 0 to MAX_CLIENTS-1 are always reserved for
		--    clients") and hands out every other entity - grenades included -
		--    from MAX_CLIENTS upwards, whatever sv_maxclients is. So the scan
		--    starts at et.MAX_CLIENTS (64), not at the client slot count.
		local nades    = {}
		local missiles = 0    -- every ET_MISSILE seen, kickable or not
		local top_ent  = -1   -- highest in-use entity slot seen this frame
		for e = MAX_CLIENTS, MAX_ENTITIES - 1 do
			if et.gentity_get(e, "inuse") == 1 then
				top_ent = e
				if et.gentity_get(e, "s.eType") == ET_MISSILE then
					missiles = missiles + 1
					local wp = et.gentity_get(e, "s.weapon")
					if wp and KICKABLE_WEAPONS[wp] then
						local pos = et.gentity_get(e, "origin")
						if pos then
							nades[#nades + 1] = { e, pos }
						end
					end
				end
			end
		end

		if DEBUG and (not last_debug_print or levelTime - last_debug_print >= 2000) then
			last_debug_print = levelTime
			local players = {}
			collect_players(players)
			-- "of N missiles" and "top entity slot" are what make
			-- kickable projectiles=0 interpretable: missiles > 0 with a top
			-- slot above MAX_CLIENTS means the scan works and there simply
			-- was no grenade/canister in the air this frame; missiles = 0
			-- every second of a busy map means the scan is not seeing them.
			log("debug: kickable projectiles=" .. #nades .. " of " .. missiles
				.. " missiles (top entity slot " .. top_ent .. ") players="
				.. #players .. " client slots=" .. get_client_slots())
		end

		if #nades == 0 then
			return
		end

		-- 2. find all live players
		local players = {}
		collect_players(players)
		if #players == 0 then
			return
		end

		-- 3. for each projectile, look for a player close by, standing
		--    still and looking at it
		for _, n in ipairs(nades) do
			local p   = n[1]
			local pos = n[2]

			if not last_kick[p] or levelTime - last_kick[p] >= KICK_COOLDOWN_MS then
				for _, pl in ipairs(players) do
					local dx = pos[1] - pl.origin[1]
					local dy = pos[2] - pl.origin[2]
					local dz = pos[3] - (pl.origin[3] + 8)
					local d2 = dx * dx + dy * dy + dz * dz

					if d2 <= RANGE_SQ and pl.speed2 <= STATIONARY_SQ then
						-- must be looking at it (from the eyes)
						local ex = pos[1] - pl.eye[1]
						local ey = pos[2] - pl.eye[2]
						local ez = pos[3] - pl.eye[3]
						local el = math.sqrt(ex * ex + ey * ey + ez * ez)
						if el >= 1 then
							local dot = pl.fwd[1] * ex / el
							        + pl.fwd[2] * ey / el
							        + pl.fwd[3] * ez / el
							if dot >= CONE_COS then
								kick_projectile(p, pos, pl, levelTime)
								break  -- one kick per frame per projectile
							end
						end
					end
				end
			end
		end
	end)

	if not ok and not reported_errors[tostring(err)] then
		reported_errors[tostring(err)] = true
		log("ERROR: " .. tostring(err) .. " (this error is reported once per map)")
	end
end

function et_InitGame(levelTime, randomSeed, restart)
	if type(et) ~= "table" then
		return
	end
	local ok, err = pcall(function()
		reported_errors = {}
		no_client = {}
		last_kick = {}
		last_debug_print = 0

		refresh_client_slots()

		if type(et.RegisterModname) == "function" then
			et.RegisterModname(MODULE_NAME)
		end

		if KICK_SOUND then
			if type(et.G_SoundIndex) == "function" then
				local idx = et.G_SoundIndex(KICK_SOUND_FILE)
				if idx and idx ~= 0 then
					kick_sound_index = idx
				else
					log("warning: sound '" .. KICK_SOUND_FILE .. "' not found, kicking silently")
				end
			else
				log("warning: et.G_SoundIndex not available, kicking silently")
			end
		end

		log("loaded: stand next to a grenade/canister, stop, look at it and use it to kick it"
			.. " (client slots: " .. get_client_slots() .. ")")
	end)

	if not ok then
		log("init error: " .. tostring(err))
	end
end
