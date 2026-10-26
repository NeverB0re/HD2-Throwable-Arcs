# Throwable Arcs

A **HELLDIVERS 2** mod that draws where your throw will fly while you aim it:

- **Stratagem balls:** once the code is in and you hold the throw, a white dashed arc shows the flight.
- **C4:** while you aim it with right mouse (DEPLOY mode), the same arc shows where the charge goes.
- **C4 mode icon:** while C4 is in your hand, the game's DEPLOY or DETONATE icon sits beside the crosshair, so you
  always know whether you hold a charge or the detonator. It can be turned off in the options menu (F9 > Throwable
  Arcs), for players whose HUD mod already shows it.

The arc is a line in the 3D world: walls and ground hide it, so the point where it disappears into the terrain is
where the throw lands. It follows your stance (standing, crouched, prone) and your armour: Servo-Assisted and Desert
Stormer armours throw farther, and the arc goes with them (measured from real throws).

**Render Scale below native:** with the game's Anti-Aliasing off, the game clips 3D drawing to a corner of the
screen, and the arc with it. Turn Anti-Aliasing on (any quality) and the arc shows whole. Right after changing it the
arc can look faint blue or be missing at some angles for a moment; it settles after moving around a little.

Grenades aren't drawn: which grenade is in your hand can't be told before it is thrown.

Requires **Chef Shared Loader** 1.2 or newer (Nexus 17760). The mod only reads the game and draws; it never changes
anything in the game.

## Install

Add `release/Throwable Arcs v<version>.zip` in your mod manager (HD2 Arsenal / HD2 Mod Manager) next to Chef Shared
Loader and enable both.

## Layout

| Path | What |
| --- | --- |
| `src/throwable_arcs.lua` | The mod (PUC Lua 5.1, runs inside Chef Shared Loader). `VERSION` is set here. |
| `src/armour_table.lua` | Every named body armour: its throw-range bonus and its unit kinds, to tell the armour you wear. |
| `src/c4_deploy.png`, `src/c4_detonate.png` | C4's mode icons (from the game's HUD atlas; `tools/c4_icons.py`). |
| `build.py` | Builds `dist/Throwable Arcs v<VERSION>.zip`; a release is copied to `release/`, a test version to `test-builds/`. |
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
  `weapon_selected` hand pose. Based on NarrowHUD by luka189.
- The armour list (names, throw-range perks, unit kinds) comes from the catalog of **HD2 Transmog** (Nexus 16633).
- Runs on **Chef Shared Loader** by Th3chef. Parts adapted from Chef Shared Loader by Th3chef (the patch writer with
  textures in `build.py`).
- C4's mode icons are the game's own, cut from its HUD atlas by `tools/c4_icons.py`.
- Unit names from filediver's resource listing (https://github.com/xypwn/filediver).

Not affiliated with Arrowhead Game Studios.
