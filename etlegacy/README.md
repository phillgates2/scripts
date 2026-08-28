# ET: Legacy Lua scripts

Server-side Lua modules for [ET: Legacy](https://www.etlegacy.com/), written
against the official [Legacy Lua API](https://etlegacy-lua-docs.readthedocs.io/)
(Lua 5.1–5.5 compatible).

| Script | What it does |
|---|---|
| [`adrenaline_all_classes.lua`](adrenaline_all_classes.lua) | Gives the adrenaline shot to every class **except medics**, which can **never** use adrenaline anymore |
| [`covert_disguise_break.lua`](covert_disguise_break.lua) | Breaks a Covert Ops' disguise when they switch weapons (weapon button) in front of an enemy |
| [`kick_projectiles.lua`](kick_projectiles.lua) | Lets players kick grenades and canisters with the USE button |

## adrenaline_all_classes.lua

Gives an **adrenaline shot to every player class and removes it from medics
entirely**:

| Class | Adrenaline |
|---|---|
| Soldier | yes |
| Medic | **no, ever** (weapon stripped, even with the First Aid level-4 unlock) |
| Engineer | yes |
| Field Ops | yes |
| Covert Ops | yes |

In stock ET: Legacy the adrenaline shot (`WP_MEDIC_ADRENALINE`, weapon id 44)
is a First Aid level-4 perk that only medics unlock. This module grants the
weapon (one ready-to-use shot) on every spawn/revive to the other four
classes with no skill requirement, and strips it from medics: the
`et_ClientSpawn` hook runs after the engine built the spawn loadout (so the
skill-based grant is removed in time), and a once-per-second sweep in
`et_RunFrame` catches any adrenaline granted mid-match (admin give, other
modules, ...). Firing it applies the normal 10 second adrenaline powerup
(health regen + no fatigue). Players select it with weapon slot key **7**
(it shares the weapon bank with the engineer landmine).

Note: `et.RemoveWeaponFromPlayer` only clears the weapon bit - the shared
ammo pool 11 (syringe/adrenaline) is left alone, so medic syringes are
unaffected.

## covert_disguise_break.lua

Removes the Covert Ops disguise when the player switches weapons (slot key or
weapon wheel) while an enemy is in front of them:

* an enemy (any live player of the other team) must be within `BREAK_RANGE`
  (default 384 units), inside the view cone (default 75° half-angle) and,
  by default, with line of sight (not behind cover);
* scope/silencer/set-mode toggles of the same base weapon (Garand → scoped
  Garand, mortar → deployed mortar, ...) do **not** break the disguise;
* breaking is done by clearing the `PW_OPS_DISGUISED` powerup - the same
  operation the engine performs when a disguised player fires a weapon. The
  cgame renders the disguised model from that exact powerup bit, so the
  player reverts to their own model on the next snapshot and all disguise
  mechanics stop at once.

Config (top of the file): `BREAK_RANGE`, `CONE_HALF_ANGLE`, `REQUIRE_LOS`,
`ANNOUNCE` (centerprint "Your cover has been blown!").

## kick_projectiles.lua

Lets players kick thrown grenades and canisters out of the way by "using"
them (USE button, default E key) while standing next to them:

* kickable: axis hand grenade (4), allied hand grenade (9), airstrike
  canister (22) and smoke grenade (29) - in the air, ticking or resting;
* stand within `KICK_RANGE` (default 64 units), look at the projectile and
  use it - it is kicked away from you with an extra hop;
* the fuse is **not** restarted: a ticking grenade you kick still explodes
  on time, just somewhere else. Kicking is implemented the same way the
  engine handles bounces (`s.pos` TR_GRAVITY trajectory reset), so kicked
  projectiles bounce off the ground and can be kicked again after the
  per-projectile cooldown (default 1200 ms).

Config (top of the file): `KICK_RANGE`, `CONE_HALF_ANGLE`, `KICK_POWER`,
`KICK_UP`, `KICK_COOLDOWN_MS`, `KICK_SOUND`, `KICKABLE_WEAPONS`.

> **API note:** the Legacy Lua API does not expose the raw usercmd button
> state, so both "USE button" (kick) and "weapon button" (disguise break)
> are detected from observable game state (player looking at the projectile
> in contact range / `ps.weapon` change between frames). The disguise-break
> detection is exact for real weapon switches; the kick triggers on aim +
> proximity, which in practice is the moment you would press USE on it.

## Install

1. Copy the script(s) to your mod's `luascripts` folder, e.g.
   `~/.etlegacy/legacy/luascripts/`.
2. Load them in your server config (`legacy.cfg`):
   ```
   set lua_modules "luascripts/adrenaline_all_classes.lua luascripts/covert_disguise_break.lua luascripts/kick_projectiles.lua"
   ```
   Multiple modules are space separated; e.g. together with wolfadmin:
   ```
   set lua_modules "luascripts/wolfadmin/main.lua luascripts/adrenaline_all_classes.lua luascripts/covert_disguise_break.lua luascripts/kick_projectiles.lua"
   ```
3. Restart the map/server. Each module prints a `[module_name] loaded: ...`
   line to the server console on load.
