-- Mock ET: Legacy Lua API used to smoke-test the server modules offline.
--
-- It reproduces the engine behaviour that matters here:
--   * entity slots 0 .. sv_maxclients-1 have a gclient attached
--   * slots sv_maxclients .. MAX_CLIENTS-1 do NOT: reading any client field
--     (sess.* / ps.* / pers.*) raises
--       "tried to get invalid gentity field \"<name>\""
--     exactly like g_lua.c _et_gentity_get() does
--   * entity slots >= MAX_CLIENTS are normal entities (missiles etc.)

local M = {}

local CLIENT_FIELD = {}
for _, f in ipairs({
	"sess.sessionTeam", "sess.playerType", "ps.stats", "ps.origin",
	"ps.viewangles", "ps.viewheight", "ps.velocity", "ps.powerups",
	"ps.weapon", "ps.weapons", "ps.weaponstate", "ps.ammo", "ps.ammoclip",
	"pers.netname", "sess.playerWeapon", "sess.playerWeapon2",
}) do
	CLIENT_FIELD[f] = true
end

function M.build(cfg)
	local sv_maxclients = cfg.sv_maxclients or 64
	local ents          = cfg.ents or {}
	local out           = {}

	local et = {}
	et.MAX_CLIENTS   = 64
	et.MAX_GENTITIES = 1024
	et.TEAM_FREE     = 0
	et.TEAM_AXIS     = 1
	et.TEAM_ALLIES   = 2
	et.TEAM_SPECTATOR = 3
	et.STAT_HEALTH   = 0
	et.PW_OPS_DISGUISED = 7
	et.MASK_SOLID    = 1
	et.WP_GRENADE_LAUNCHER  = 4
	et.WP_GRENADE_PINEAPPLE = 9
	et.WP_SMOKE_MARKER      = 22
	et.WP_SMOKE_BOMB        = 29
	et.WP_MEDIC_ADRENALINE  = 44
	et.WP_KNIFE             = 1
	et.WP_LUGER             = 2
	et.WP_MP40              = 3
	et.WP_COLT              = 7
	et.WP_THOMPSON          = 8
	et.WP_STEN              = 10
	et.WP_MEDIC_SYRINGE     = 11
	et.WP_LANDMINE          = 26
	et.WP_KNIFE_KABAR       = 48
	et.WP_MP34              = 54
	et.MOD_KNIFE            = 5
	et.MOD_SYRINGE          = 24
	et.MASK_SHOT            = 1

	et.output = out

	function et.G_Print(s)
		out[#out + 1] = s:gsub("\n$", "")
	end

	et.G_LogPrint    = et.G_Print
	function et.RegisterModname(_) end
	function et.G_SoundIndex(_) return 1 end
	function et.G_Sound(_, _) end
	function et.trap_SendServerCommand(_, _) end
	function et.AddWeaponToPlayer(...) end
	function et.RemoveWeaponFromPlayer(...) end
	-- command arguments, set per test with et.set_args{...}
	local args = {}
	function et.set_args(t) args = t or {} end
	function et.trap_Argc() return #args end
	function et.trap_Argv(i) return args[i + 1] end
	function et.ConcatArgs(i) return table.concat(args, " ", (i or 0) + 1) end

	-- level time, advanced per test with et.set_time(ms)
	local level_time = cfg.time or 0
	function et.set_time(t) level_time = t end
	function et.trap_Milliseconds() return level_time end

	-- trace result, overridable per test with et.set_trace{...}
	local trace_result = { fraction = 1.0, entityNum = 1023 }
	function et.set_trace(t) trace_result = t end
	function et.trap_Trace() return trace_result end

	-- damage log: each entry is "target:attacker:damage:mod"
	et.damage_log = {}
	function et.G_Damage(target, inflictor, attacker, damage, dflags, mod)
		et.damage_log[#et.damage_log + 1] =
			target .. ":" .. attacker .. ":" .. damage .. ":" .. tostring(mod)
	end

	-- entity allocation, mirroring G_Spawn(): slots below MAX_CLIENTS are
	-- reserved for clients, so new entities come from MAX_CLIENTS upwards
	local next_ent = et.MAX_CLIENTS
	function et.G_Spawn()
		while ents[next_ent] do
			next_ent = next_ent + 1
		end
		ents[next_ent] = { ["inuse"] = 1 }
		out[#out + 1] = "SPAWN " .. next_ent
		return next_ent
	end
	function et.G_FreeEntity(num)
		ents[num] = nil
		out[#out + 1] = "FREE " .. num
	end
	function et.trap_LinkEntity(_) end

	function et.trap_Cvar_Get(name)
		if name == "sv_maxclients" then
			return tostring(sv_maxclients)
		end
		return ""
	end

	local function ent(num)
		return ents[num]
	end

	function et.gentity_get(num, field, index)
		if type(num) ~= "number" or num < 0 or num >= et.MAX_GENTITIES then
			error("entnum \"" .. tostring(num) .. "\" is out of range", 0)
		end

		local e = ent(num) or {}

		-- the engine can only look up client fields when a gclient is attached
		if CLIENT_FIELD[field] then
			local has_client = (num < sv_maxclients) and not cfg.clientless[num]
			if not has_client then
				error("tried to get invalid gentity field \"" .. field .. "\"", 0)
			end
		end

		local v = e[field]
		if index ~= nil and type(v) == "table" and v[index + 1] ~= nil then
			return v[index + 1]
		end
		return v
	end

	function et.gentity_set(num, field, a, b)
		local e = ents[num]
		if not e then
			e = {}
			ents[num] = e
		end
		if CLIENT_FIELD[field] then
			local has_client = (num < sv_maxclients) and not cfg.clientless[num]
			if not has_client then
				error("tried to set invalid gentity field \"" .. field .. "\"", 0)
			end
		end
		if b ~= nil then
			local arr = e[field] or {}
			arr[a + 1] = b
			e[field] = arr
		else
			e[field] = a
		end
		out[#out + 1] = "SET " .. num .. " " .. field
	end

	return et, ents, out
end

return M
