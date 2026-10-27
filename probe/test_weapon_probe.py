"""Weapon Probe 0.1.0 on PUC Lua 5.1 (lupa) against a fake Chef Shared Loader:  python test_weapon_probe.py"""
import os
import sys
import unittest

import lupa.lua51 as lua51

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from build_weapon_probe import source_text  # noqa: E402

FAKE = r"""
local fake = { t = 0, logs = {}, mouse = {}, pose = 61, asked_runtime = false }
local PLAYER, PISTOL, SHELL = '4d1c334d294dfa97', '52e4334e6a128caf', '9999999999999999'
local me = { kind = PLAYER, x = 0, y = 0, z = 0 }
local pistol = { kind = PISTOL, x = 0.3, y = 0.5, z = 1.4, f = { 0, 1, 0 } }
local helmet = { kind = '7777777777777777', x = 0, y = 0, z = 1.7, f = { 0, 0, 1 } }
local runtime = { kind = '46cab355bd8d4d37', x = 0, y = 0, z = 1 }
fake.units = { me, pistol, helmet, runtime }
local shell = nil

local E = {
  ['World.units'] = function(w) local out = {}; for i, u in ipairs(fake.units) do out[i] = u end; return out end,
  ['Unit.has_animation_state_machine'] = function(u) return u == me end,
  ['Unit.animation_has_variable'] = function(u, n) return n == 'weapon_selected' end,
  ['Unit.animation_find_variable'] = function(u, n) return 3 end,
  ['Unit.animation_get_variable'] = function(u, i) return fake.pose end,
}
local function call(name, ...)
  local f = E[name]
  if not f then return nil, 'missing' end
  return f(...)
end

chef = {
  api = 3, loader_version = '1.2.1',
  has = function() return true end, own_log = function() return true end,
  log = function(fmt, ...) fake.logs[#fake.logs + 1] = string.format(fmt, ...) end,
  time = function() return fake.t end,
  call = call,
  call_kind = function(name, kind, ...) return call(name, ...) end,
  world = function() return {} end, world_id = function() return 4 end, in_mission = function() return true end,
  camera = function() return { x = 0, y = -2, z = 1.8, fx = 0, fy = 1, fz = 0, fov = 0.96 } end,
  watch = function(kinds) return { items = { { unit = me, kind = PLAYER } } } end,
  unit_alive = function(u) return u.dead ~= true end,
  unit_kind = function(u) return u.kind end,
  unit_position = function(u, node)
    if u.kind == '46cab355bd8d4d37' then fake.asked_runtime = true; error('NATIVE CRASH') end
    if node == 7 then return u.x, u.y + 0.4, u.z end
    return u.x, u.y, u.z
  end,
  unit_rotation = function(u, node)
    if u.kind == '46cab355bd8d4d37' then fake.asked_runtime = true; error('NATIVE CRASH') end
    local f = u.f or { 1, 0, 0 }
    return f[1], f[2], f[3], 0
  end,
  unit_node = function(u, name) if u == pistol and name == 'muzzle' then return 7 end end,
  mouse_down = function(b) return fake.mouse[b] == true end,
}

function fake.frame(M, dt)
  fake.t = fake.t + dt
  if shell and not shell.still then
    local f = fake.t - shell.t0
    shell.x, shell.y, shell.z = 0.3, 0.9 + 100 * f, 1.4 - 4.9 * f * f
    if shell.z <= 0 then shell.z, shell.still = 0, true end
  end
  M.update(dt)
end

function fake.fire()       -- the game makes the shell a frame after the click
  shell = { kind = SHELL, t0 = fake.t, x = 0.3, y = 0.9, z = 1.4 }
  fake.units[#fake.units + 1] = shell
end
return fake
"""


class WeaponProbeTest(unittest.TestCase):
    def setUp(self):
        self.lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        self.fake = self.lua.execute(FAKE)
        self.M = self.lua.execute(source_text(), self.lua.globals().chef)

    def frames(self, n, dt=1 / 60):
        for _ in range(n):
            self.fake.frame(self.M, dt)

    def text(self):
        return "\n".join(self.fake.logs.values())

    def test_a_shot(self):
        f = self.fake
        self.frames(30)
        f.mouse["right"] = True
        self.frames(30)
        f.mouse["left"] = True
        self.frames(1)
        f.fire()
        self.frames(5)
        f.mouse["left"] = False
        self.frames(120)
        text = self.text()
        print(text[-3000:])
        self.assertIn("weapon names", text)
        self.assertIn("hand pose 61: hand pose 61", text)
        self.assertIn("weapon 52e4334e6a128caf sidearm_weapons/grenade_pistol: ahead 0.50 right 0.30 up 1.40", text)
        self.assertIn("nodes of 52e4334e6a128caf sidearm_weapons/grenade_pistol: muzzle=7", text)
        self.assertIn("node muzzle at 0.30 0.90 1.40", text)
        self.assertIn("unnamed kinds on me now (1): 7777777777777777", text)
        self.assertIn("shot 1 at", text)
        self.assertIn("aiming true", text)
        self.assertIn("new unit 9999999999999999 ?", text)
        self.assertIn("track 1 9999999999999999", text)
        self.assertIn("track 1 9999999999999999 stopped at", text)
        self.assertIn("shot 1: 1 new units within 20 m", text)
        self.assertFalse(f.asked_runtime, "a runtime-built unit was asked where it is")

    def test_pose_flicker_is_not_reported(self):
        f = self.fake
        self.frames(30)
        f.pose = 40
        self.frames(5)
        f.pose = 61
        self.frames(30)
        self.assertNotIn("hand pose 40", self.text())


if __name__ == "__main__":
    unittest.main()
