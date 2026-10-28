# Stratagem and C4 Trajectory

(Called Throwable Arcs until 1.0.1.)

A **HELLDIVERS 2** mod that draws where your throw or shot will fly while you aim it:

- **Stratagem balls:** once the code is in and you hold the throw (left mouse) or aim it (right mouse), a dashed arc
  shows the flight (green by default; white, blue or red in the options menu).
- **C4:** while you aim it with right mouse in DEPLOY mode, the same arc shows where the charge goes: standing,
  crouched, prone, sliding, diving, and from a vehicle's passenger seats.
- **C4 mode icon:** while C4 is in your hand, the game's DEPLOY or DETONATE icon sits beside the crosshair, so you
  always know whether you hold a charge or the detonator (in a vehicle, only while you aim). It can be turned off in
  the options menu (F9 > Stratagem and C4 Trajectory), for players whose HUD mod already shows it.

The arc is a line in the 3D world: walls and ground hide it, so the point where it disappears into the terrain is
where the throw lands. It starts where your hand lets go and follows your armour: Servo-Assisted and Desert Stormer
armours throw farther, and the arc goes with them (all measured from real throws). It stays up until the throw leaves
your hand, and throws on the move are drawn too: the game adds some of your speed forward or back to a throw (none
sideways), and the arc with it.

**Render Scale below native:** with the game's Anti-Aliasing off, the game clips 3D drawing to a corner of the
screen, and the arc with it. Turn Anti-Aliasing on (any quality) and the arc shows whole.

**Controller:** the right trigger throws and the left trigger aims (the game's default layout). Buttons or keys
rebound in the game's settings aren't followed: the mod reads the mouse buttons and the triggers themselves.

**Arc changing colour:** at some places and headings, part of a white arc could look faint blue (sometimes red or
green). It isn't anti-aliasing or the map's fog, and the exact cause is unknown. The arc is green by default since
1.0.4, which seems to keep its colour; if you find what causes it, please open an issue.

**Weapons (1.1.0):** while you aim a weapon whose round falls, in third person and not prone, its path from the
muzzle: grenade launchers (GL-21, GL-28, GL-52, GL-15), GP-31, GP-20 Ultimatum, P-34 Breacher, CB-9, SG-8P Punisher
Plasma, the One-Two's launcher, RL-77, GR-8, EAT-17, EAT-700, EAT-411, PLAS-45 Epoch. The rounds' speed, drag and gravity
are the game's data from the Helldivers Wiki; one drag law fits them all (`a = -4.7e-4 * drag * caliber^2 / mass *
|v| * v`, fitted on tracked rounds). The arc follows where the weapon points (the game's aim circle).

**Grenades (1.1.0):** while you hold G, or aim or cook a grenade drawn with its key, its arc. The grenade in hand is
told by its unit's kind; each kind's throw (speed, lift, yaw, start, from your throws; drag fixed) is learned and kept
(`chef.save_table`), with several kinds measured to start. Guided Seekers get no arc.

Weapon and grenade arcs are new and not fully polished: more checking and fixes are needed.

Works with HD2 Transmog (the throw-range perk is read from the armour you really wear) and with mods that only change
textures. Other mods that put another armour's model on you may hide the perk (the arc is then drawn without it).

Requires **Chef Shared Loader** 1.2 or newer (Nexus 17760). The mod only reads the game and draws; it never changes
anything in the game.

## Install

Add `release/Stratagem and C4 Trajectory v<version>.zip` in your mod manager (HD2 Arsenal / HD2 Mod Manager) next to Chef Shared
Loader and enable both.

## Layout

| Path | What |
| --- | --- |
| `src/throwable_arcs.lua` | The mod (PUC Lua 5.1, runs inside Chef Shared Loader). `VERSION` is set here. |
| `src/armour_table.lua` | Every named body armour: its throw-range bonus and its unit kinds, to tell the armour you wear. |
| `src/c4_deploy.png`, `src/c4_detonate.png` | C4's mode icons (from the game's HUD atlas; `tools/c4_icons.py`). |
| `build.py` | Builds `dist/Stratagem and C4 Trajectory v<VERSION>.zip`; a release is copied to `release/`, a test version to `test-builds/`. |
| `tests/test_throwable_arcs.py` | Runs the mod against a fake loader (needs `lupa`). |
| `PLAN.md` | The design notes and measurements from the test builds (Korean). |
| `probe/` | Engine Probe, the test addon used to find what the game lets a mod read. |

`build.py` takes the patch header and the name hash from Extended Pickup Icons Range's `build.py`
(https://github.com/NeverB0re/HD2-Extended-Pickup-Icons), expected next to this folder.

## Working on it

```bash
python -m pip install lupa
python tests/test_throwable_arcs.py
python build.py
```

## Credits

- C4's mode and the hand pose are read the way **NarrowHUD** by luka189 reads them (Nexus 17882,
  https://github.com/luka189/NarrowHUD): the C4's network object type and option field names, and the
  `weapon_selected` hand pose; the One-Two's fire mode the same way, from its weapon type list
  (`src/weapon_types.lua`). Based on NarrowHUD by luka189; its licence is in `THIRD_PARTY_NOTICES.txt`.
- Weapon rounds' numbers: the **Helldivers Wiki**'s game data (helldivers.wiki.gg, Module:Decodedata-Attacks).
- The throw angle: the game data dumped in shalzuth/HelldiversData (https://github.com/shalzuth/HelldiversData).
- The armour list (names, throw-range perks, unit kinds) comes from the catalog of **HD2 Transmog** (Nexus 16633).
- Runs on **Chef Shared Loader** by Th3chef. Parts adapted from Chef Shared Loader by Th3chef (the patch writer with
  textures in `build.py`).
- C4's mode icons are the game's own, cut from its HUD atlas by `tools/c4_icons.py`.
- Unit names from filediver's resource listing (https://github.com/xypwn/filediver).

Not affiliated with Arrowhead Game Studios.
