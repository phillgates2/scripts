--[[
 Offline regression test for the ET: Legacy Lua modules in this folder.

 Run it with any Lua 5.1+ interpreter from anywhere:

     lua etlegacy/tests/test.lua

 It loads each module against a mock "et" API (tests/harness.lua) that
 reproduces the engine behaviour these modules got bitten by: client fields
 (sess.* / ps.* / pers.*) can only be read from entity slots that have a
 gclient attached - every other slot raises

     tried to get invalid gentity field "sess.sessionTeam"
]]--

local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "."
package.path = here .. "/?.lua;" .. package.path
local harness = require("harness")

local REPO = here .. "/../"

local failures = 0
local function check(cond, msg)
	if cond then
		print("  ok   - " .. msg)
	else
		failures = failures + 1
		print("  FAIL - " .. msg)
	end
end

local function load_module(file, et)
	local env = { et = et }
	env._G = env
	for _, k in ipairs({ "math", "string", "table", "type", "tostring", "tonumber",
		"pcall", "ipairs", "pairs", "print", "error", "select" }) do
		env[k] = _G[k]
	end
	local chunk, err
	if setfenv then
		-- Lua 5.1 / LuaJIT
		chunk, err = loadfile(REPO .. file)
		if chunk then
			setfenv(chunk, env)
		end
	else
		-- Lua 5.2+
		chunk, err = loadfile(REPO .. file, "t", env)
	end
	if not chunk then
		error("cannot load " .. file .. ": " .. tostring(err))
	end
	chunk()
	return env
end

local function player(team, health, origin, angles, vel, extra)
	local p = {
		["inuse"]             = 1,
		["sess.sessionTeam"]  = team,
		["ps.stats"]          = { health },
		["ps.origin"]         = origin,
		["ps.viewangles"]     = angles,
		["ps.viewheight"]     = 40,
		["ps.velocity"]       = vel or { 0, 0, 0 },
		["ps.weapon"]         = 4,
		["ps.powerups"]       = {},
	}
	for k, v in pairs(extra or {}) do p[k] = v end
	return p
end

-- ---------------------------------------------------------------------------
print("kick_projectiles: 20-slot server, players in slots 0/1, grenade nearby")

local ents = {}
-- slot 0: allied player standing next to the grenade, looking at it (yaw 0)
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 })
-- slot 1: axis player far away
ents[1] = player(1, 100, { 2000, 2000, 0 }, { 0, 0, 0 })
-- slot 5: connected but dead/limbo
ents[5] = player(1, 0, { 0, 0, 0 }, { 0, 0, 0 })
-- a live grenade 40 units in front of slot 0 (entity slots start at MAX_CLIENTS)
ents[70] = {
	["inuse"]    = 1,
	["s.eType"]  = 3,
	["s.weapon"] = 4,
	["origin"]   = { 40, 0, 0 },
	["s.pos"]    = { trType = 6, trTime = 0, trBase = { 40, 0, 0 }, trDelta = { 0, 0, 0 } },
}

local et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
local m = load_module("kick_projectiles.lua", et)
m.et_InitGame(0, 0, 0)
m.et_RunFrame(3000)

local joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line (" .. (joined:match("ERROR[^\n]*") or "none") .. ")")
check(joined:find("SET 70 s.pos", 1, true) ~= nil, "grenade trajectory was kicked")
check(joined:find("players=2", 1, true) ~= nil, "both live players counted, dead/limbo slot skipped")
check(joined:find("client slots=20", 1, true) ~= nil, "client slot count read from sv_maxclients")

-- ---------------------------------------------------------------------------
print("kick_projectiles: full 64-slot server, only 2 slots occupied")

ents = {}
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 })
ents[63] = player(1, 100, { 500, 0, 0 }, { 0, 0, 0 })
ents[70] = {
	["inuse"]    = 1,
	["s.eType"]  = 3,
	["s.weapon"] = 29,
	["origin"]   = { 40, 0, 0 },
	["s.pos"]    = { trType = 6, trTime = 0, trBase = { 40, 0, 0 }, trDelta = { 0, 0, 0 } },
}
et, _, out = harness.build({ sv_maxclients = 64, ents = ents, clientless = {} })
m = load_module("kick_projectiles.lua", et)
m.et_InitGame(0, 0, 0)
m.et_RunFrame(1000)
joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")
check(joined:find("SET 70 s.pos", 1, true) ~= nil, "smoke bomb kicked")

-- ---------------------------------------------------------------------------
print("kick_projectiles: pathological slot - inuse == 1 but no gclient attached")

ents = {}
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 })
ents[3] = { ["inuse"] = 1 }   -- looks like a client, has no client fields
ents[70] = {
	["inuse"]    = 1,
	["s.eType"]  = 3,
	["s.weapon"] = 4,
	["origin"]   = { 40, 0, 0 },
	["s.pos"]    = { trType = 6, trTime = 0, trBase = { 40, 0, 0 }, trDelta = { 0, 0, 0 } },
}
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = { [3] = true } })
m = load_module("kick_projectiles.lua", et)
m.et_InitGame(0, 0, 0)
for frame = 1, 5 do
	m.et_RunFrame(1000 * frame)
end
joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "module survives a clientless slot without an ERROR")
check(joined:find("SET 70 s.pos", 1, true) ~= nil, "grenade still kicked")
local warnings = select(2, joined:gsub("has no client fields", ""))
check(warnings == 1, "clientless slot warned about exactly once (got " .. warnings .. ")")

-- ---------------------------------------------------------------------------
-- ps.viewangles is {pitch, yaw, roll} (q_shared.h: PITCH 0, YAW 1, ROLL 2) and
-- the engine builds the view vector with forward[2] = -sin(pitch)
-- (q_math.c angles_vectors()), so a player who looks DOWN at a grenade on the
-- floor has a POSITIVE pitch. Every case above uses {0,0,0}, which cannot tell
-- a correct view vector from a pitch/yaw mix-up - these can.
print("kick_projectiles: 40-slot server, player looking DOWN at the grenade")

ents = {}
-- slot 0: pitch 30 (looking down), yaw 0 -> looking at the grenade on the floor
ents[0] = player(2, 100, { 0, 0, 0 }, { 30, 0, 0 })
-- grenade 20 units ahead on the ground (eye height is 40, so it is below the eyes)
ents[64] = {
	["inuse"]    = 1,
	["s.eType"]  = 3,
	["s.weapon"] = 4,
	["origin"]   = { 20, 0, 0 },
	["s.pos"]    = { trType = 6, trTime = 0, trBase = { 20, 0, 0 }, trDelta = { 0, 0, 0 } },
}
et, _, out = harness.build({ sv_maxclients = 40, ents = ents, clientless = {} })
m = load_module("kick_projectiles.lua", et)
m.et_InitGame(0, 0, 0)
m.et_RunFrame(2000)          -- the debug summary prints from 2000 ms on
joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")
check(joined:find("kickable projectiles=1", 1, true) ~= nil,
	"grenade in slot 64 counted (entity slots start at MAX_CLIENTS)")
check(joined:find("SET 64 s.pos", 1, true) ~= nil,
	"grenade kicked when the player looks down at it (pitch 30)")
check(joined:find("of 1 missiles (top entity slot 64)", 1, true) ~= nil,
	"debug line reports the missile total and the top entity slot")

-- ---------------------------------------------------------------------------
-- The line the console shows when nothing is in the air must stay readable:
-- "0 of 0 missiles (top entity slot -1)" means the scan saw no missile at all,
-- while "0 of 3 missiles" means it saw missiles that are simply not kickable
-- (dynamite, panzerfaust rocket, landmine, ...).
print("kick_projectiles: nothing in the air - debug line stays interpretable")

ents = {}
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 })
-- a non-kickable missile (dynamite, weapon 15) must be counted but not kicked
ents[80] = {
	["inuse"]    = 1,
	["s.eType"]  = 3,
	["s.weapon"] = 15,
	["origin"]   = { 40, 0, 0 },
	["s.pos"]    = { trType = 6, trTime = 0, trBase = { 40, 0, 0 }, trDelta = { 0, 0, 0 } },
}
et, _, out = harness.build({ sv_maxclients = 40, ents = ents, clientless = {} })
m = load_module("kick_projectiles.lua", et)
m.et_InitGame(0, 0, 0)
m.et_RunFrame(2000)
joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")
check(joined:find("kickable projectiles=0 of 1 missiles (top entity slot 80) players=1 client slots=40",
	1, true) ~= nil, "debug line: " .. (joined:match("debug:[^\n]*") or "missing"))
check(not joined:find("SET 80 s.pos", 1, true), "dynamite (weapon 15) is not kicked")

-- ---------------------------------------------------------------------------
print("kick_projectiles: yaw-only aim, and a player facing away must not kick")

ents = {}
-- slot 0: pitch 0, yaw 90 -> looking along +Y at the grenade
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 90, 0 })
-- slot 1: yaw 180 -> looking along -X, the grenade is behind them
ents[1] = player(1, 100, { 0, 0, 0 }, { 0, 180, 0 })
ents[64] = {
	["inuse"]    = 1,
	["s.eType"]  = 3,
	["s.weapon"] = 9,
	["origin"]   = { 0, 40, 0 },
	["s.pos"]    = { trType = 6, trTime = 0, trBase = { 0, 40, 0 }, trDelta = { 0, 0, 0 } },
}
et, _, out = harness.build({ sv_maxclients = 40, ents = ents, clientless = {} })
m = load_module("kick_projectiles.lua", et)
m.et_InitGame(0, 0, 0)
m.et_RunFrame(2000)
joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")
local kick = joined:match("kick: ent 64 %(weapon 9%) by client (%d+)")
check(kick == "0", "yaw 90 kicks the grenade (kicked by client " .. tostring(kick) .. ", expected 0)")

-- ---------------------------------------------------------------------------
print("covert_disguise_break: weapon switch in front of an enemy")

ents = {}
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 },
	{ ["ps.powerups"] = { [8] = 1 } })    -- PW_OPS_DISGUISED == 7 -> index 8
ents[1] = player(1, 100, { 200, 0, 0 }, { 0, 0, 0 })
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
m = load_module("covert_disguise_break.lua", et)
m.et_InitGame(0, 0, 0)
m.et_RunFrame(1000)             -- first frame only records the weapon
ents[0]["ps.weapon"] = 8        -- player switches weapon
m.et_RunFrame(1050)
joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")
check(joined:find("SET 0 ps.powerups", 1, true) ~= nil, "disguise was broken")

-- ---------------------------------------------------------------------------
print("covert_disguise_break: clientless slots must not kill the module")

ents = {}
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 },
	{ ["ps.powerups"] = { [8] = 1 } })
ents[1] = player(1, 100, { 200, 0, 0 }, { 0, 0, 0 })
ents[9] = { ["inuse"] = 1 }
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = { [9] = true } })
m = load_module("covert_disguise_break.lua", et)
m.et_InitGame(0, 0, 0)
m.et_RunFrame(1000)
ents[0]["ps.weapon"] = 8
m.et_RunFrame(1050)
joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")
check(joined:find("SET 0 ps.powerups", 1, true) ~= nil, "disguise still broken")

-- ---------------------------------------------------------------------------
print("adrenaline_all_classes: medic sweep and spawn grant")

ents = {}
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 },
	{ ["sess.playerType"] = 1 })   -- PC_MEDIC
ents[1] = player(1, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 },
	{ ["sess.playerType"] = 0 })   -- PC_SOLDIER
ents[9] = { ["inuse"] = 1 }
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = { [9] = true } })
local stripped, granted = {}, {}
function et.RemoveWeaponFromPlayer(c, w) stripped[#stripped + 1] = c .. ":" .. w end
function et.AddWeaponToPlayer(c, w) granted[#granted + 1] = c .. ":" .. w end
m = load_module("adrenaline_all_classes.lua", et)
m.et_InitGame(0, 0, 0)
m.et_RunFrame(1000)
m.et_ClientSpawn(1, 0, 0, 1)
m.et_ClientSpawn(0, 0, 0, 1)
joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")
check(table.concat(stripped, ","):find("0:47", 1, true) ~= nil, "medic stripped of adrenaline")
check(table.concat(granted, ","):find("1:47", 1, true) ~= nil, "soldier granted adrenaline")

print("")
if failures > 0 then
	print(failures .. " check(s) FAILED")
	os.exit(1)
end
print("all checks passed")
