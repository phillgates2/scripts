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
	"ps.weapon", "pers.netname",
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
	et.WP_MEDIC_ADRENALINE  = 47

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
	function et.trap_Trace() return { fraction = 1.0 } end

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
