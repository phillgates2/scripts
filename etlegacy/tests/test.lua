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

local function load_module(file, et, extra_env)
	local env = { et = et }
	if extra_env then
		for k, v in pairs(extra_env) do
			env[k] = v
		end
	end
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
local m = load_module("kick_projectiles.lua", et, { DEBUG = true })
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
m = load_module("kick_projectiles.lua", et, { DEBUG = true })
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
m = load_module("kick_projectiles.lua", et, { DEBUG = true })
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
m = load_module("kick_projectiles.lua", et, { DEBUG = true })
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
m = load_module("kick_projectiles.lua", et, { DEBUG = true })
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
m = load_module("kick_projectiles.lua", et, { DEBUG = true })
m.et_InitGame(0, 0, 0)
m.et_RunFrame(2000)
joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")
local kick = joined:match("kick: ent 64 %(weapon 9%) by client (%d+)")
check(kick == "0", "yaw 90 kicks the grenade (kicked by client " .. tostring(kick) .. ", expected 0)")

-- ---------------------------------------------------------------------------
print("kick_projectiles: default DEBUG = false produces no debug log spam")

ents = {}
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 })
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
check(not joined:find("debug: kickable projectiles"), "default DEBUG = false produces no debug log spam")

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
check(table.concat(stripped, ","):find("0:44", 1, true) ~= nil, "medic stripped of adrenaline")
check(table.concat(granted, ","):find("1:44", 1, true) ~= nil, "soldier granted adrenaline")

-- ---------------------------------------------------------------------------
-- weapon bitmask helper: ps.weapons is words of 32 bits, weapon w is
-- bit (w % 32) of word floor(w / 32)
local function weapons_mask(list)
	local words = { 0, 0 }
	for _, w in ipairs(list) do
		local i = math.floor(w / 32) + 1
		words[i] = words[i] + 2 ^ (w % 32)
	end
	return words
end

-- ---------------------------------------------------------------------------
print("adrenaline_all_classes: an existing all-class syringe pool is preserved")

ents = {}
-- engineer that poison_needle.lua has already given a syringe (pool 11 = 8)
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, {
	["sess.playerType"] = 2,
	["ps.weapon"]       = 21,
	["ps.weapons"]      = weapons_mask({ 11 }),
	["ps.ammoclip"]     = { [12] = 8 },   -- index 11, 0-based
	["ps.ammo"]         = { [12] = 0 },
})
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
granted = {}
function et.AddWeaponToPlayer(c, w, ammo, clip)
	granted[#granted + 1] = string.format("%d:%d:%d:%d", c, w, ammo or 0, clip or 0)
end
m = load_module("adrenaline_all_classes.lua", et)
m.et_InitGame(0, 0, 0)
m.et_ClientSpawn(0, 0, 0, 0)
joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")
check(table.concat(granted, ","):find("0:44:0:9", 1, true) ~= nil,
	"one adrenaline shot added on top of 8 ready syringes (got "
	.. table.concat(granted, ",") .. ")")

-- ---------------------------------------------------------------------------
print("engineer_slot7_toggle: slot 7 alternates landmine <-> adrenaline")

ents = {}
-- engineer holding the landmine, carrying both bank 7 weapons
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, {
	["sess.playerType"] = 2,
	["ps.weapon"]       = 26,
	["ps.weapons"]      = weapons_mask({ 26, 44 }),
	["ps.ammoclip"]     = { [27] = 4, [12] = 1 },  -- index 26 / 11, 0-based
	["ps.ammo"]         = { [27] = 0, [12] = 0 },
})
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
m = load_module("engineer_slot7_toggle.lua", et, { DEBUG = true })
m.et_InitGame(0, 0, 0)

et.set_args({ "weaponbank", "7" })
local r = m.et_ClientCommand(0, "weaponbank")
check(r == 1, "slot 7 command was intercepted (got " .. tostring(r) .. ")")
check(ents[0]["ps.weapon"] == 44, "landmine -> adrenaline (got "
	.. tostring(ents[0]["ps.weapon"]) .. ")")

r = m.et_ClientCommand(0, "weaponbank")
check(r == 1, "second press also intercepted")
check(ents[0]["ps.weapon"] == 26, "adrenaline -> landmine (got "
	.. tostring(ents[0]["ps.weapon"]) .. ")")

joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")

-- ---------------------------------------------------------------------------
print("engineer_slot7_toggle: other banks and one-weapon players pass through")

et.set_args({ "weaponbank", "3" })
check(m.et_ClientCommand(0, "weaponbank") == 0, "bank 3 is passed through")

ents = {}
-- only landmines: nothing to toggle with, engine keeps stock behaviour
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, {
	["sess.playerType"] = 2,
	["ps.weapon"]       = 26,
	["ps.weapons"]      = weapons_mask({ 26 }),
	["ps.ammoclip"]     = { [27] = 4 },
})
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
m = load_module("engineer_slot7_toggle.lua", et)
m.et_InitGame(0, 0, 0)
et.set_args({ "weaponbank", "7" })
check(m.et_ClientCommand(0, "weaponbank") == 0,
	"landmine-only player: slot 7 falls through to the engine")

-- ---------------------------------------------------------------------------
print("engineer_slot7_toggle: an empty adrenaline shot does not eat the key")

ents = {}
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, {
	["sess.playerType"] = 2,
	["ps.weapon"]       = 26,
	["ps.weapons"]      = weapons_mask({ 26, 44 }),
	["ps.ammoclip"]     = { [27] = 4, [12] = 0 },   -- adrenaline used up
	["ps.ammo"]         = { [27] = 0, [12] = 0 },
})
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
m = load_module("engineer_slot7_toggle.lua", et)
m.et_InitGame(0, 0, 0)
et.set_args({ "weaponbank", "7" })
m.et_ClientCommand(0, "weaponbank")
check(ents[0]["ps.weapon"] == 26, "spent adrenaline is skipped, mines stay out")

-- ---------------------------------------------------------------------------
print("soldier_smg_slot2: slot 2 toggles SMG <-> pistol when slot 3 is an SMG")

ents = {}
-- Allied soldier with a Thompson (8) in bank 3 and a Colt (7) in bank 2
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, {
	["sess.playerType"]   = 0,
	["sess.playerWeapon"] = 8,
	["ps.weapon"]         = 7,
	["ps.weapons"]        = weapons_mask({ 7, 8 }),
	["ps.ammoclip"]       = { [8] = 8, [9] = 30 },  -- colt 7, thompson 8
})
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
m = load_module("soldier_smg_slot2.lua", et, { DEBUG = true })
m.et_InitGame(0, 0, 0)

et.set_args({ "weaponbank", "2" })
check(m.et_ClientCommand(0, "weaponbank") == 1, "slot 2 intercepted")
check(ents[0]["ps.weapon"] == 8, "pistol -> Thompson (got "
	.. tostring(ents[0]["ps.weapon"]) .. ")")
m.et_ClientCommand(0, "weaponbank")
check(ents[0]["ps.weapon"] == 7, "Thompson -> pistol (got "
	.. tostring(ents[0]["ps.weapon"]) .. ")")

joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")

-- ---------------------------------------------------------------------------
print("soldier_smg_slot2: MP40 for Axis, and non-SMG/non-soldier untouched")

ents = {}
-- Axis soldier with an MP40 (3)
ents[0] = player(1, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, {
	["sess.playerType"]   = 0,
	["sess.playerWeapon"] = 3,
	["ps.weapon"]         = 2,
	["ps.weapons"]        = weapons_mask({ 2, 3 }),
	["ps.ammoclip"]       = { [3] = 8, [4] = 32 },
})
-- soldier with a panzerfaust (5) in bank 3: slot 2 must stay stock
ents[1] = player(1, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, {
	["sess.playerType"]   = 0,
	["sess.playerWeapon"] = 5,
	["ps.weapon"]         = 2,
	["ps.weapons"]        = weapons_mask({ 2, 5 }),
	["ps.ammoclip"]       = { [3] = 8, [6] = 1 },
})
-- a MEDIC carrying a Thompson: not a soldier, so untouched
ents[2] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, {
	["sess.playerType"]   = 1,
	["sess.playerWeapon"] = 8,
	["ps.weapon"]         = 7,
	["ps.weapons"]        = weapons_mask({ 7, 8 }),
	["ps.ammoclip"]       = { [8] = 8, [9] = 30 },
})
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
m = load_module("soldier_smg_slot2.lua", et)
m.et_InitGame(0, 0, 0)

et.set_args({ "weaponbank", "2" })
m.et_ClientCommand(0, "weaponbank")
check(ents[0]["ps.weapon"] == 3, "Axis soldier gets the MP40 on slot 2")
check(m.et_ClientCommand(1, "weaponbank") == 0, "panzer soldier: slot 2 stock")
check(ents[1]["ps.weapon"] == 2, "panzer soldier keeps the pistol")
check(m.et_ClientCommand(2, "weaponbank") == 0, "medic: slot 2 stock")
check(ents[2]["ps.weapon"] == 7, "medic keeps the pistol")

-- ---------------------------------------------------------------------------
print("poison_needle: an enemy stab poisons and ticks, a team mate does not")

ents = {}
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 })        -- allied medic
ents[1] = player(1, 100, { 30, 0, 0 }, { 0, 0, 0 })       -- axis victim
ents[2] = player(2, 100, { 30, 0, 0 }, { 0, 0, 0 })       -- allied team mate
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
m = load_module("poison_needle.lua", et, { DEBUG = true })
m.et_InitGame(0, 0, 0)

et.set_time(1000)
m.et_Damage(1, 0, 0, 0, 24)      -- MOD_SYRINGE hit on the enemy
m.et_Damage(2, 0, 0, 0, 24)      -- MOD_SYRINGE hit on a team mate

m.et_RunFrame(2000)              -- first tick
m.et_RunFrame(3000)              -- second tick

local dmg = table.concat(et.damage_log, ",")
local ticks = select(2, dmg:gsub("1:0:10:24", ""))
check(ticks == 2, "the poisoned enemy took 2 ticks (got " .. ticks .. ")")
check(not dmg:find("2:0:", 1, true), "the team mate was never poisoned")

joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")

-- ---------------------------------------------------------------------------
print("poison_needle: poison expires, and a respawn cures it")

m.et_RunFrame(12500)             -- past the 10 s duration
local before = #et.damage_log
m.et_RunFrame(14000)
check(#et.damage_log == before, "no ticks after the poison expired")

et.set_time(20000)
m.et_Damage(1, 0, 0, 0, 24)
m.et_ClientSpawn(1, 0, 0, 1)     -- respawn / revive
before = #et.damage_log
m.et_RunFrame(21000)
check(#et.damage_log == before, "respawning cures the poison")

-- ---------------------------------------------------------------------------
print("poison_needle: a syringe stab that deals no damage still poisons")

ents = {}
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 })
ents[1] = player(1, 100, { 30, 0, 0 }, { 0, 0, 0 })
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
m = load_module("poison_needle.lua", et)
m.et_InitGame(0, 0, 0)
et.set_time(1000)
et.set_trace({ fraction = 0.5, entityNum = 1, endpos = { 30, 0, 0 } })
m.et_WeaponFire(0, 11)           -- WP_MEDIC_SYRINGE
m.et_RunFrame(2000)
check(table.concat(et.damage_log, ","):find("1:0:10:24", 1, true) ~= nil,
	"the traced stab poisoned the enemy in front of the medic")

-- ---------------------------------------------------------------------------
print("poison_needle: ALL_CLASSES grants the syringe to every class")

ents = {}
-- a soldier with no syringe: the module must give one on spawn
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, {
	["sess.playerType"] = 0,              -- PC_SOLDIER
	["ps.weapons"]      = weapons_mask({}),
})
-- a medic already has the syringe: its loadout must be left alone
ents[1] = player(1, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, {
	["sess.playerType"] = 1,              -- PC_MEDIC
	["ps.weapons"]      = weapons_mask({ 11 }),
	["ps.ammoclip"]     = { [12] = 6 },   -- index 11, 0-based
	["ps.ammo"]         = { [12] = 0 },
})
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
granted = {}
function et.AddWeaponToPlayer(c, w) granted[#granted + 1] = c .. ":" .. w end
m = load_module("poison_needle.lua", et)
m.et_InitGame(0, 0, 0)
m.et_ClientSpawn(0, 0, 0, 0)
m.et_ClientSpawn(1, 0, 0, 0)
joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")
check(table.concat(granted, ","):find("0:11", 1, true) ~= nil,
	"a class without a syringe was given the poison needle")
check(not table.concat(granted, ","):find("1:11", 1, true),
	"the medic's existing syringe was left alone (got "
	.. table.concat(granted, ",") .. ")")

-- ---------------------------------------------------------------------------
print("poison_needle: an existing adrenaline share of pool 11 is preserved")

ents = {}
-- adrenaline_all_classes already gave this soldier one adrenaline shot: the
-- poison needle must be added on top of that shared pool, not reset it
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, {
	["sess.playerType"] = 0,              -- PC_SOLDIER
	["ps.weapons"]      = weapons_mask({ 44 }),
	["ps.ammoclip"]     = { [12] = 1 },   -- index 11, 0-based
	["ps.ammo"]         = { [12] = 0 },
})
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
granted = {}
function et.AddWeaponToPlayer(c, w, ammo, clip)
	granted[#granted + 1] = string.format("%d:%d:%d:%d", c, w, ammo or 0, clip or 0)
end
m = load_module("poison_needle.lua", et)
m.et_InitGame(0, 0, 0)
m.et_ClientSpawn(0, 0, 0, 0)
joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")
check(table.concat(granted, ","):find("0:11:0:9", 1, true) ~= nil,
	"syringes added on top of the adrenaline shot (got "
	.. table.concat(granted, ",") .. ")")

-- ---------------------------------------------------------------------------
print("poison_needle: slot 5 toggles the needle and the class's bank-5 tool")

ents = {}
-- engineer carrying pliers (21) and the new syringe (11), current hand = pliers
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, {
	["sess.playerType"] = 2,              -- PC_ENGINEER
	["ps.weapon"]       = 21,
	["ps.weapons"]      = weapons_mask({ 11, 21 }),
	["ps.ammoclip"]     = { [12] = 8, [22] = 999 },  -- pool 11 / pool 21
	["ps.ammo"]         = { [12] = 0, [22] = 0 },
})
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
m = load_module("poison_needle.lua", et, { DEBUG = true })
m.et_InitGame(0, 0, 0)

et.set_args({ "weaponbank", "5" })
local r = m.et_ClientCommand(0, "weaponbank")
check(r == 1, "slot 5 was intercepted (got " .. tostring(r) .. ")")
check(ents[0]["ps.weapon"] == 11, "pliers -> poison needle (got "
	.. tostring(ents[0]["ps.weapon"]) .. ")")
r = m.et_ClientCommand(0, "weaponbank")
check(r == 1, "second press also intercepted")
check(ents[0]["ps.weapon"] == 21, "poison needle -> pliers (got "
	.. tostring(ents[0]["ps.weapon"]) .. ")")

et.set_args({ "weaponbank", "3" })
check(m.et_ClientCommand(0, "weaponbank") == 0, "other banks pass through")

joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")

-- ---------------------------------------------------------------------------
print("poison_needle: slot 5 is untouched for a player without the needle")

ents = {}
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, {
	["sess.playerType"] = 0,
	["ps.weapon"]       = 4,
	["ps.weapons"]      = weapons_mask({}),
})
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
m = load_module("poison_needle.lua", et)
m.et_InitGame(0, 0, 0)
et.set_args({ "weaponbank", "5" })
check(m.et_ClientCommand(0, "weaponbank") == 0,
	"a no-syringe player keeps stock slot-5 behaviour")
check(ents[0]["ps.weapon"] == 4, "weapon unchanged (got "
	.. tostring(ents[0]["ps.weapon"]) .. ")")
joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")

-- ---------------------------------------------------------------------------
print("no_combat_selfkill: /kill is refused right after taking enemy fire")

ents = {}
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 })
-- an enemy far away and facing the other way: cannot see slot 0
ents[1] = player(1, 100, { 5000, 5000, 0 }, { 0, 180, 0 })
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
m = load_module("no_combat_selfkill.lua", et, { DEBUG = true })
m.et_InitGame(0, 0, 0)

et.set_time(10000)
m.et_Damage(0, 1, 25, 0, 1)                    -- shot by the enemy
check(m.et_ClientCommand(0, "kill") == 1, "/kill blocked while in a fire fight")
check(m.et_ClientCommand(0, "suicide") == 1, "/suicide is blocked too")

et.set_time(10000 + 5001)                      -- past COMBAT_WINDOW_MS
check(m.et_ClientCommand(0, "kill") == 0, "/kill allowed once combat cools off")

joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")

-- ---------------------------------------------------------------------------
print("no_combat_selfkill: /kill is refused while an enemy has line of sight")

ents = {}
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 })
-- axis player 400 units away on +X, looking back along -X at slot 0
ents[1] = player(1, 100, { 400, 0, 0 }, { 0, 180, 0 })
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
m = load_module("no_combat_selfkill.lua", et)
m.et_InitGame(0, 0, 0)
et.set_time(10000)
et.set_trace({ fraction = 1.0, entityNum = 1023 })   -- clear line of sight
check(m.et_ClientCommand(0, "kill") == 1, "/kill blocked while seen by an enemy")

-- a wall in between: the trace stops on the world, so /kill is fine again
et.set_trace({ fraction = 0.4, entityNum = 1022 })
check(m.et_ClientCommand(0, "kill") == 0, "/kill allowed when cover blocks sight")

-- an enemy facing away cannot see them even with a clear trace
ents[1]["ps.viewangles"] = { 0, 0, 0 }
et.set_trace({ fraction = 1.0, entityNum = 1023 })
check(m.et_ClientCommand(0, "kill") == 0, "an enemy facing away does not block /kill")

-- ---------------------------------------------------------------------------
print("no_combat_selfkill: other commands and dead players are untouched")

check(m.et_ClientCommand(0, "say") == 0, "unrelated commands pass through")
ents[0]["ps.stats"] = { 0 }
et.set_trace({ fraction = 1.0, entityNum = 1023 })
ents[1]["ps.viewangles"] = { 0, 180, 0 }
check(m.et_ClientCommand(0, "kill") == 0, "a dead player is not restricted")

-- ---------------------------------------------------------------------------
print("throwable_knife: firing a knife throws it instead of stabbing")

ents = {}
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 },
	{ ["ps.weapon"] = 48 })
ents[1] = player(1, 100, { 300, 0, 0 }, { 0, 0, 0 })
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
local removed, added = {}, {}
function et.RemoveWeaponFromPlayer(c, w) removed[#removed + 1] = c .. ":" .. w end
function et.AddWeaponToPlayer(c, w) added[#added + 1] = c .. ":" .. w end
m = load_module("throwable_knife.lua", et, { DEBUG = true })
m.et_InitGame(0, 0, 0)

et.set_time(1000)
check(m.et_WeaponFire(0, 48) == 1, "the melee stab was replaced by a throw")
joined = table.concat(out, "\n")
check(joined:find("SPAWN 64", 1, true) ~= nil, "a knife entity was spawned")
check(table.concat(removed, ","):find("0:48", 1, true) ~= nil,
	"throwing costs the thrower their knife")
check(not joined:find("ERROR"), "no ERROR line")

-- the knife flies into the enemy: they take damage and the knife is freed
ents[64]["r.currentOrigin"] = { 300, 0, 40 }
et.set_trace({ fraction = 0.9, entityNum = 1, endpos = { 300, 0, 40 } })
m.et_RunFrame(1050)
check(table.concat(et.damage_log, ","):find("1:0:45:5", 1, true) ~= nil,
	"the thrown knife damaged the enemy it hit (got "
	.. table.concat(et.damage_log, ",") .. ")")

-- ---------------------------------------------------------------------------
print("throwable_knife: a knife that hits the world lands and can be picked up")

ents = {}
ents[0] = player(2, 100, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 },
	{ ["ps.weapon"] = 1 })
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
added = {}
function et.RemoveWeaponFromPlayer(_, _) end
function et.AddWeaponToPlayer(c, w) added[#added + 1] = c .. ":" .. w end
m = load_module("throwable_knife.lua", et)
m.et_InitGame(0, 0, 0)
et.set_time(1000)
m.et_WeaponFire(0, 1)

-- world hit (entityNum is not a client slot) 20 units in front of the player
ents[64]["r.currentOrigin"] = { 20, 0, 0 }
et.set_trace({ fraction = 0.5, entityNum = 1022, endpos = { 20, 0, 0 } })
m.et_RunFrame(1050)
check(ents[64]["s.pos"].trType == 0, "the landed knife is TR_STATIONARY")

-- the thrower walks over it
m.et_RunFrame(1100)
check(table.concat(added, ","):find("0:1", 1, true) ~= nil,
	"walking over the knife picks it back up")
check(ents[64] == nil, "the picked up knife entity was freed")

joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")

-- ---------------------------------------------------------------------------
print("kick_projectiles: aiming at the GROUND next to a canister still kicks it")

ents = {}
-- looking steeply DOWN (pitch 70) at the floor: the crosshair lands on the
-- ground, not on the canister lying 24 units ahead - this is the case the
-- old pure-cone aim test rejected
ents[0] = player(2, 100, { 0, 0, 0 }, { 70, 0, 0 })
ents[64] = {
	["inuse"]    = 1,
	["s.eType"]  = 3,
	["s.weapon"] = 22,          -- WP_SMOKE_MARKER, airstrike canister
	["origin"]   = { 24, 0, 0 },
	["s.pos"]    = { trType = 6, trTime = 0, trBase = { 24, 0, 0 }, trDelta = { 0, 0, 0 } },
}
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
m = load_module("kick_projectiles.lua", et, { DEBUG = true })
m.et_InitGame(0, 0, 0)
m.et_RunFrame(2000)
joined = table.concat(out, "\n")
check(not joined:find("ERROR"), "no ERROR line")
check(joined:find("SET 64 s.pos", 1, true) ~= nil,
	"canister kicked while pointing at the ground (pitch 70)")

-- ---------------------------------------------------------------------------
print("kick_projectiles: a projectile behind you is still not kicked")

ents = {}
-- looking down and AWAY (yaw 180): the canister is behind the player
ents[0] = player(2, 100, { 0, 0, 0 }, { 70, 180, 0 })
ents[64] = {
	["inuse"]    = 1,
	["s.eType"]  = 3,
	["s.weapon"] = 22,
	["origin"]   = { 40, 0, 0 },
	["s.pos"]    = { trType = 6, trTime = 0, trBase = { 40, 0, 0 }, trDelta = { 0, 0, 0 } },
}
et, _, out = harness.build({ sv_maxclients = 20, ents = ents, clientless = {} })
m = load_module("kick_projectiles.lua", et, { DEBUG = true })
m.et_InitGame(0, 0, 0)
m.et_RunFrame(2000)
joined = table.concat(out, "\n")
check(not joined:find("SET 64 s.pos", 1, true),
	"a canister behind the player is not kicked")

print("")

if failures > 0 then
	print(failures .. " check(s) FAILED")
	os.exit(1)
end
print("all checks passed")
