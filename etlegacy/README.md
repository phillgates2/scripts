# ET: Legacy Lua scripts

## adrenaline_all_classes.lua

Server-side Lua module for [ET: Legacy](https://www.etlegacy.com/) that gives
an **adrenaline shot to every player class except medics**:

| Class | Adrenaline |
|---|---|
| Soldier | yes |
| Medic | **no** (keeps vanilla skill-based behaviour) |
| Engineer | yes |
| Field Ops | yes |
| Covert Ops | yes |

In stock ET: Legacy the adrenaline shot (`WP_MEDIC_ADRENALINE`, weapon id 44)
is a First Aid level-4 perk that only medics unlock. This module grants the
weapon on every spawn/revive to the other four classes with no skill
requirement. Firing it applies the normal 10 second adrenaline powerup
(health regen + no fatigue). Players select it with weapon slot key **7**
(it shares the weapon bank with the engineer landmine).

### Install

1. Copy the script to your mod's `luascripts` folder, e.g.
   `~/.etlegacy/legacy/luascripts/adrenaline_all_classes.lua`.
2. Load it in your server config (`legacy.cfg`):
   ```
   set lua_modules "luascripts/adrenaline_all_classes.lua"
   ```
   Multiple modules are space separated, e.g.
   `set lua_modules "luascripts/wolfadmin/main.lua luascripts/adrenaline_all_classes.lua"`.
3. Restart the map/server. The console will print
   `[adrenaline_all_classes] loaded: adrenaline for all classes except medics`.

Works with the ET: Legacy Lua API (Lua 5.1–5.5).
