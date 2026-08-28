--[[
=============================================================================
 covert_disguise_break.lua  -  ET: Legacy server-side Lua module
-----------------------------------------------------------------------------
 Removes the Covert Ops disguise when the player switches weapons (the
 "weapon button": a slot key or the weapon wheel) while an enemy is in
 front of them:

   * a disguised covert op presses a weapon key / spins the wheel
   * an enemy (any live player of the other team) is within range, in
     front of the player's view direction, and - by default - not hidden
     behind cover
   * -> the disguise is broken on the spot

 In stock ET: Legacy the disguise only breaks when the covert op fires a
 weapon (or is killed). This module adds a second, harsher condition:
 getting spotted while fiddling with your guns blows your cover.

 HOW IT WORKS
   * The disguise is the PW_OPS_DISGUISED powerup (ps.powerups[7]). The
     cgame chooses the disguised model from that exact powerup bit in the
     entity state, and all disguise mechanics (friendly-fire handling,
     crosshair HUD, uniform stealing, ...) check the same bit - so
     clearing it with et.gentity_set reverts the player to his own model
     on the very next snapshot. This is the same operation the engine
     itself performs in FireWeapon() when a disguised player shoots.
   * The Lua API does not expose the raw usercmd button state, so the
     "weapon button" is detected as a change of ps.weapon between two
     server frames (the pmove switches the held weapon as soon as the
     selected one differs). Alt/scope/silencer toggles of the same base
     weapon (e.g. Garand -> scoped Garand, Luger -> silenced Luger,
     mortar -> deployed mortar) count as the same weapon and do NOT
     break the disguise.

 CONFIG
   See the CONFIG block below - range, view cone, line-of-sight and the
   centerprint message are all adjustable.

 INSTALL
   1. Copy this file into your mod's luascripts folder, e.g.:
        <fs_home>/legacy/luascripts/covert_disguise_break.lua
      (on Linux that is usually ~/.etlegacy/legacy/luascripts/)
   2. Load the module from your server config (legacy.cfg):
        set lua_modules "luascripts/covert_disguise_break.lua"
      Space-separate several modules, e.g.:
        set lua_modules "luascripts/adrenaline_all_classes.lua luascripts/covert_disguise_break.lua"
   3. Restart the map/server. On load the console prints:
        [covert_disguise_break] loaded: disguise breaks on weapon switch in front of an enemy
=============================================================================
]]--

-- ============================ CONFIG =====================================
local BREAK_RANGE       = 384    -- max distance (units, ~32 ft) to the enemy
local CONE_HALF_ANGLE   = 75     -- half of the "in front" cone, in degrees
local REQUIRE_LOS       = true   -- enemy must not be behind cover
local ANNOUNCE          = true   -- centerprint for the blown player
local ANNOUNCE_TEXT     = "Your cover has been blown!"
local CHEST_HEIGHT      = 24     -- aim point above the enemy's feet
-- ==========================================================================

local TEAM_FREE        = (et and et.TEAM_FREE) or 0
local TEAM_SPECTATOR   = (et and et.TEAM_SPECTATOR) or 3
local MAX_CLIENTS      = (et and et.MAX_CLIENTS) or 64
local PW_OPS_DISGUISED = (et and et.PW_OPS_DISGUISED) or 7
local STAT_HEALTH      = (et and et.STAT_HEALTH) or 0
-- MASK_SOLID == CONTENTS_SOLID == 1 (world geometry only - players do not
-- block the check, which is exactly what we want for a line-of-sight test)
local MASK_SOLID       = (et and et.MASK_SOLID) or 1

local DEG2RAD = math.pi / 180
local CONE_COS = math.cos(CONE_HALF_ANGLE * DEG2RAD)
local RANGE_SQ = BREAK_RANGE * BREAK_RANGE

local MODULE_NAME = "covert_disguise_break"

-- last seen ps.weapon per client slot (nil = "no data yet" / reset)
local last_weapon = {}

-- alt-mode pairs of the same base weapon (bg_classes / weapon table):
-- scoped rifles, rifle nades, silenced pistols, set-mode heavy weapons
local ALT_MODE = {
	[2] = 14,  [14] = 2,    -- Luger <-> silenced Luger
	[7] = 39,  [39] = 7,    -- Colt <-> silenced Colt
	[35] = 45, [45] = 35,   -- akimbo Colt <-> akimbo silenced Colt
	[36] = 46, [46] = 36,   -- akimbo Luger <-> akimbo silenced Luger
	[23] = 37, [37] = 23,   -- Kar98 <-> GPG40 (rifle nade)
	[24] = 38, [38] = 24,   -- M1 Carbine <-> M7 (rifle nade)
	[25] = 40, [40] = 25,   -- Garand <-> scoped Garand
	[31] = 41, [41] = 31,   -- K43 <-> scoped K43
	[32] = 42, [42] = 32,   -- FG42 <-> scoped FG42
	[30] = 47, [47] = 30,   -- mobile MG42 <-> deployed MG42
	[34] = 43, [43] = 34,   -- mortar <-> deployed mortar
	[51] = 52, [52] = 51,   -- axis mortar <-> deployed axis mortar
	[49] = 50, [50] = 49,   -- mobile Browning <-> deployed Browning
	[27] = 28, [28] = 27,   -- satchel <-> satchel detonator
}

local function log(msg)
	et.G_Print("[" .. MODULE_NAME .. "] " .. msg .. "\n")
end

-- forward view direction from ps.viewangles {yaw, pitch, roll} (degrees)
local function view_forward(angles)
	local yaw   = angles[1] * DEG2RAD
	local pitch = angles[2] * DEG2RAD
	local cp    = math.cos(pitch)
	return { math.cos(yaw) * cp, math.sin(yaw) * cp, math.sin(pitch) }
end

-- true if two weapon ids are alt-modes (scope/silencer/set) of each other
local function same_base_weapon(a, b)
	return a == b or (ALT_MODE[a] ~= nil and ALT_MODE[a] == b)
end

local function is_disguised(clientNum)
	return et.gentity_get(clientNum, "ps.powerups", PW_OPS_DISGUISED) == 1
end

-- true if any live enemy of the given client is in front of them
local function enemy_in_front(cnum, eye, fwd)
	local myTeam = et.gentity_get(cnum, "sess.sessionTeam")

	for j = 0, MAX_CLIENTS - 1 do
		if j ~= cnum then
			local t = et.gentity_get(j, "sess.sessionTeam")
			if t and t ~= TEAM_FREE and t ~= TEAM_SPECTATOR and t ~= myTeam then
				local h = et.gentity_get(j, "ps.stats", STAT_HEALTH)
				if h and h > 0 then
					local po = et.gentity_get(j, "ps.origin")
					if po then
						local cx = po[1]
						local cy = po[2]
						local cz = po[3] + CHEST_HEIGHT
						local dx = cx - eye[1]
						local dy = cy - eye[2]
						local dz = cz - eye[3]
						local d2 = dx * dx + dy * dy + dz * dz

						if d2 <= RANGE_SQ and d2 > 0 then
							local inv = 1 / math.sqrt(d2)
							local dot = fwd[1] * dx * inv
							        + fwd[2] * dy * inv
							        + fwd[3] * dz * inv

							if dot >= CONE_COS then
								if not REQUIRE_LOS then
									return true
								end
								-- point trace; mins/maxs MUST be tables
								-- (passing nil makes the API crash)
								local tr = et.trap_Trace(
									eye,
									{ 0, 0, 0 }, { 0, 0, 0 },
									{ cx, cy, cz },
									cnum, MASK_SOLID)
								if not tr or tr.fraction >= 1.0 then
									return true
								end
							end
						end
					end
				end
			end
		end
	end

	return false
end

local function break_disguise(clientNum)
	et.gentity_set(clientNum, "ps.powerups", PW_OPS_DISGUISED, 0)
	log("client " .. clientNum .. " lost the disguise (weapon switch in front of an enemy)")
	if ANNOUNCE then
		et.trap_SendServerCommand(clientNum,
			'cp "' .. ANNOUNCE_TEXT .. '"')
	end
end

-- checks one client; breaks the disguise when a disguised player switched
-- weapons with an enemy in front
local function check_client(i)
	local team   = et.gentity_get(i, "sess.sessionTeam")
	local health = et.gentity_get(i, "ps.stats", STAT_HEALTH)
	local weapon = et.gentity_get(i, "ps.weapon")

	-- no client, dead/limbo or off-team: drop the tracking state so a
	-- respawn never fires a phantom "weapon switch"
	if not team or team == TEAM_SPECTATOR or not weapon
		or not health or health <= 0 then
		last_weapon[i] = nil
		return
	end

	local prev = last_weapon[i]
	last_weapon[i] = weapon

	if prev ~= nil and not same_base_weapon(prev, weapon)
		and is_disguised(i) then
		-- a weapon button was used - check for an enemy in front
		local origin = et.gentity_get(i, "ps.origin")
		local view   = et.gentity_get(i, "ps.viewangles")
		local viewh  = et.gentity_get(i, "ps.viewheight")
		if origin and view then
			local eye = { origin[1], origin[2],
				origin[3] + (viewh or 32) }
			if enemy_in_front(i, eye, view_forward(view)) then
				break_disguise(i)
			end
		end
	end
end

--[[
 Called every server frame; levelTime is the level time in ms.
 et_RunFrame runs before the clients think for this frame, so it sees the
 state of the previous frame - a one-frame delay, which is not visible.
]]--
function et_RunFrame(levelTime)
	for i = 0, MAX_CLIENTS - 1 do
		check_client(i)
	end
end

function et_InitGame(levelTime, randomSeed, restart)
	et.RegisterModname(MODULE_NAME)
	log("loaded: disguise breaks on weapon switch in front of an enemy")
end
