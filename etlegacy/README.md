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
skill-based grant is removed in time), and an every-frame sweep in
`et_RunFrame` catches any adrenaline granted mid-match (First Aid level 4,
admin give, other modules, ...). The `et_WeaponFire` hook also blocks the
weapon if it is granted between sweeps. Firing it applies the normal 10
second adrenaline powerup
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
* stop within `KICK_RANGE` (default 64 units) of the projectile, look at it
  and use it - it is kicked away from you with an extra hop. You have to be
  roughly standing still (default `STATIONARY_SPEED` 120 u/s) so the kick
  fires when you stop next to it to use it, not while you are still running
  towards it;
* the fuse is **not** restarted: a ticking grenade you kick still explodes
  on time, just somewhere else. Kicking is implemented the same way the
  engine handles bounces (`s.pos` TR_GRAVITY trajectory reset), so kicked
  projectiles bounce off the ground and can be kicked again after the
  per-projectile cooldown (default 1200 ms).

Config (top of the file): `KICK_RANGE`, `CONE_HALF_ANGLE`, `KICK_POWER`,
`KICK_UP`, `KICK_COOLDOWN_MS`, `KICK_POP`, `KICK_SOUND`,
`KICK_SOUND_FILE`, `STATIONARY_SPEED`, `DEBUG`, `KICKABLE_WEAPONS`.

Known limitations:

* **Airstrike canisters have a short kick window.** The canister
  (WP_SMOKE_MARKER) only exists as a kickable missile for about **5 seconds
  after it is thrown** - once the airstrike is called it turns into an
  explosion effect and is gone, so kick it while it is still smoking on the
  ground. The smoke bomb (WP_SMOKE_BOMB) can be kicked for its whole ~18
  second life. Hand grenades are kickable until they explode.
* **Kicking a canister does not cancel the airstrike** - the plane still
  bombs the spot where the canister ended up after the kick.
* The module never dies silently: load/init problems and runtime errors are
  printed to the server console as `[kick_projectiles] ...` messages.

Troubleshooting (`DEBUG = true`, the default):

* on map start you should see `[kick_projectiles] loaded: ...`;
* while playing, a line like

  ```
  [kick_projectiles] debug: kickable projectiles=1 of 3 missiles (top entity slot 240) players=13 client slots=40
  ```

  is printed every 2 seconds. `kickable projectiles` is what the module can
  act on, `of N missiles` is every `ET_MISSILE` it saw - including dynamite,
  rockets and landmines, which are deliberately not kickable. So
  `projectiles=0 of 3 missiles` means nothing throwable was in the air at
  that instant; `projectiles=0 of 0 missiles` throughout a busy map means
  the scan is not seeing the entities. `players=0` means the module cannot
  see any live player;
* every kick prints `[kick_projectiles] kick: ent ... (weapon ...) by
  client ...`. If the debug line counts projectiles but no kick line ever
  appears, the aim test is failing: `ps.viewangles` is `{pitch, yaw, roll}`
  and the view vector is `(cos(pitch)*cos(yaw), cos(pitch)*sin(yaw),
  -sin(pitch))`. Set `CONE_HALF_ANGLE` to 90 to confirm.

Set `DEBUG = false` for production.

> **API note:** the Legacy Lua API does not expose the raw usercmd button
> state, so both "USE button" (kick) and "weapon button" (disguise break)
> are detected from observable game state (player stopped next to the
> projectile and looking at it / `ps.weapon` change between frames). The
> disguise-break detection is exact for real weapon switches; the kick
> triggers on proximity + aim while standing still, which in practice is
> the moment you would press USE on it.
>
> **API note:** `et.gentity_get()` only resolves `sess.*` / `ps.*` fields
> for entities that actually have a client attached. Reading one from an
> empty client slot raises `tried to get invalid gentity field`, which
> aborts `et_RunFrame` (spamming the console every frame). The scripts
> therefore guard every per-slot sweep with the entity-level `inuse`
> field (`et.gentity_get(i, "inuse") == 1`), which the engine sets
> exactly when a slot has a spawned client.

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
