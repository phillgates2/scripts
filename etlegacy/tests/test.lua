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
