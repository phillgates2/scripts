# scripts

Small server-side scripts. Currently: Lua modules for an
[ET: Legacy](https://www.etlegacy.com/) dedicated server.

## etlegacy/

| module | what it does |
| --- | --- |
| `adrenaline_all_classes.lua` | gives the adrenaline shot to every class except medics |
| `covert_disguise_break.lua` | a disguised covert op loses the disguise when switching weapons in front of an enemy |
| `kick_projectiles.lua` | lets players kick grenades / airstrike canisters / smoke bombs away |
| `engineer_slot7_toggle.lua` | weapon slot 7 toggles between landmine and adrenaline instead of always giving the landmine |
| `soldier_smg_slot2.lua` | soldiers can pull their SMG (Thompson / MP40) from weapon slot 2 when it is their slot 3 weapon |
| `poison_needle.lua` | the medic syringe poisons enemies: damage over time credited to the medic |
| `throwable_knife.lua` | knives can be thrown as a projectile, and picked back up where they land |
| `no_combat_selfkill.lua` | `/kill` is refused while the player is in a fire fight or an enemy can see them |

Install: copy the file(s) into `<fs_home>/legacy/luascripts/` and load them
from your server config:

```
set lua_modules "luascripts/kick_projectiles.lua luascripts/covert_disguise_break.lua"
```

Each file's header comment documents its config block and limitations.

### Weapon slot modules

`engineer_slot7_toggle.lua` and `soldier_smg_slot2.lua` both work by
intercepting the client's weapon selection command (`weaponbank N`,
`weaponslot N`, `slotN`) in `et_ClientCommand` and writing `ps.weapon`
themselves. That is server side only: the client's own prediction still
believes the stock bank layout for one frame, so the HUD can flicker once on
a switch, but the weapon that actually fires is the toggled one.

Weapon ownership is read from the `ps.weapons` bitmask - two 32 bit words,
where weapon `w` is bit `w % 32` of word `floor(w / 32)`. Adrenaline (44)
therefore lives in word 1 bit 12, not word 0. A module that reads only word 0
will silently think nobody owns adrenaline, and slot 7 will never toggle.

### Reading client fields safely

Client fields (`sess.*`, `ps.*`, `pers.*`) exist only on entity slots that
have a `gclient` attached, i.e. slots `0 .. sv_maxclients-1`. `et.MAX_CLIENTS`
is always 64, so looping to it and reading e.g. `sess.sessionTeam` from a slot
above `sv_maxclients` makes the API raise

```
ERROR: [string "luascripts/<module>.lua"]:NNN: tried to get invalid gentity field "sess.sessionTeam"
```

which aborts the whole callback for that frame. The modules here therefore

* bound every client loop by `sv_maxclients` (read once per map),
* check the entity-level `inuse` field first, and
* read client fields through a `pcall` helper that skips a bad slot instead of
  dying.

If you still see that error, the copy in your `luascripts/` folder is older
than this repository - copy it over again and restart the map.

## Tests

`etlegacy/tests/` contains an offline regression test that runs the modules
against a mock `et` API (including clientless entity slots, and the engine's
rule that entity slots `0 .. MAX_CLIENTS-1` are reserved for clients while
grenades are allocated from `MAX_CLIENTS` upwards). Aim tests use real pitch
and yaw values - an all-zero `ps.viewangles` cannot tell a correct view
vector from a pitch/yaw mix-up. It needs nothing but a Lua interpreter:

```
lua etlegacy/tests/test.lua
```
