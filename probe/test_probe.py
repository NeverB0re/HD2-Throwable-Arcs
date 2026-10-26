"""Engine Probe 0.2.1 on PUC Lua 5.1 (lupa) against a fake Chef Shared Loader:  python test_probe.py"""
import os
import unittest

import lupa.lua51 as lua51

HERE = os.path.dirname(os.path.abspath(__file__))

FAKE = r"""
local fake = { t = 0, logs = {}, keys = {}, mouse = {}, pressed = {}, lines = 0, own_lines = 0, calls = {} }
local function ud(t, fields)   -- engine values are userdata, as in the game
  fields = fields or {}; fields.__t = t
  local p = newproxy(true)
  getmetatable(p).__index = fields
  return p
end
Vector3 = function(x, y, z) return ud('Vector3', { x = x, y = y, z = z }) end
Color = function(r, g, b) return ud('Color', { r, g, b }) end
local world = ud('World')

local TERRAIN_KIND, ROCK_KIND, GRENADE_KIND = '1111111111111111', '2222222222222222', '5c14f27759dd3be0'
local terrain_unit = { kind = TERRAIN_KIND, x = 0, y = 0, z = -4 }
local rock = { kind = ROCK_KIND, x = 10, y = 0, z = -3 }
local runtime = { kind = '46cab355bd8d4d37', x = 1, y = 1, z = 1 }
fake.units = { terrain_unit, rock, runtime }
local grenade = nil

local E = {
  ['World.units'] = function(w) local out = {}; for i, u in ipairs(fake.units) do out[i] = u end; return out end,
  ['Script.type_name'] = function(v) return type(v) == 'userdata' and v.__t or nil end,
  ['Vector3.to_elements'] = function(v) return v.x, v.y, v.z end,
  ['Matrix4x4.translation'] = function(m) return Vector3(m.x, m.y, m.z) end,
  ['IdString64.to_hex'] = function(v) return v.hex end,
  ['Unit.resource_name'] = function(u) return ud('IdString64', { hex = 'feedfeedfeedfeed' }) end,
  ['Unit.name_hash'] = function(u) return ud('IdString32', { hex = 'beef' }) end,
  ['Unit.debug_name'] = function(u) return '#ID[' .. u.kind .. ']' end,
  ['Unit.num_terrains'] = function(u) return u == terrain_unit and 1 or 0 end,
  ['Unit.num_landscapes'] = function(u) return 0 end,
  ['Unit.terrain'] = function(u, i) if i == 1 then return ud('Terrain') end end,
  ['Terrain.boundary_min_max'] = function(t) return Vector3(-500, -500, -50), Vector3(500, 500, 50) end,
  ['Terrain.data_id'] = function(t) return 7 end,
  ['Terrain.capture_offset'] = function(t, p) if p then return ud('TerrainOffset') end end,
  ['TerrainOffset.sample'] = function(o, x, y) if type(x) == 'number' then return -4.1 + x * 0.01 end end,
  ['Unit.box'] = function(u)
    if u == rock then return ud('Matrix4x4', { x = 10, y = 0, z = -3 }), Vector3(2, 2, 2) end
  end,
  ['Math.ray_box_intersection'] = function(from, dir, pose, r)
    if dir.x > 0.9 then return pose.x - r.x - from.x end
    return -1
  end,
  ['World.create_line_object'] = function(w, off) return ud('LineObject') end,
  ['LineObject.reset'] = function() end,
  ['LineObject.add_line'] = function() fake.own_lines = fake.own_lines + 1 end,
  ['LineObject.dispatch'] = function() end,
  ['World.destroy_line_object'] = function() end,
  ['AI.find_intersecting_units'] = function() error('bad argument #1') end,
  ['World.scatter_system'] = function() return ud('ScatterSystem') end,
  ['ScatterSystem.offset_with_terrain'] = function() return Vector3(0, 0, -4) end,
}

local function call(name, ...)
  fake.calls[name] = (fake.calls[name] or 0) + 1
  local f = E[name]
  if not f then return nil, 'missing' end
  local r = { pcall(f, ...) }
  if not r[1] then return nil, 'error: ' .. tostring(r[2]) end
  return r[2], r[3], r[4], r[5]
end

chef = {
  api = 3, loader_version = '1.2.0',
  has = function() return true end, own_log = function() return true end,
  log = function(fmt, ...) fake.logs[#fake.logs + 1] = string.format(fmt, ...) end,
  time = function() return fake.t end,
  call = call,
  call_kind = function(name, kind, ...) return call(name, ...) end,
  world = function() return world end, world_id = function() return 4 end, in_mission = function() return false end,
  camera = function() return { x = 0, y = 0, z = -2, fx = 1, fy = 0, fz = 0, fov = 0.96 } end,
  unit_alive = function(u) return true end,
  unit_kind = function(u) return u.kind end,
  unit_position = function(u)
    if u.kind == '46cab355bd8d4d37' then error('NATIVE CRASH: asked a runtime-built unit') end
    return u.x, u.y, u.z
  end,
  key_down = function(k) return fake.keys[k] == true end,
  key_pressed = function(k) return fake.pressed[k] == true end,
  mouse_down = function(b) return fake.mouse[b] == true end,
  line = function() fake.lines = fake.lines + 1 end,
  color = function(r, g, b, a) return { r, g, b, a } end,
}

function fake.frame(M, dt)
  fake.t = fake.t + dt
  if grenade and not grenade.still then
    local f = fake.t - grenade.t0
    grenade.x, grenade.y, grenade.z = 0.5 + 20 * f, 0, -2.2 + 3 * f - 4.9 * f * f
    if grenade.z <= -4 then grenade.z, grenade.still = -4, true end
  end
  M.update(dt)
  fake.pressed = {}
end

function fake.throw()
  grenade = { kind = GRENADE_KIND, t0 = fake.t, x = 0.5, y = 0, z = -2.2 }
  fake.units[#fake.units + 1] = grenade
end
return fake
"""


class ProbeTest(unittest.TestCase):
    def setUp(self):
        self.lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        self.fake = self.lua.execute(FAKE)
        with open(os.path.join(HERE, "engine_probe.lua"), encoding="utf-8") as f:
            self.M = self.lua.execute(f.read(), self.lua.globals().chef)

    def frames(self, n, dt=1 / 60):
        for _ in range(n):
            self.fake.frame(self.M, dt)

    def logs(self):
        return list(self.fake.logs.values())

    def test_full_session(self):
        f = self.fake
        self.frames(5)
        f.pressed["f5"] = True
        self.frames(3)
        self.assertGreater(f.lines, 0, "red chef.line drawn")
        self.assertGreater(f.own_lines, 0, "green own line drawn")
        f.pressed["f6"] = True
        self.frames(10)
        f.pressed["f7"] = True
        self.frames(20)
        f["keys"]["g"] = True
        self.frames(30)
        f["keys"]["g"] = False
        f.throw()
        self.frames(240)
        f.pressed["f8"] = True
        self.frames(3)
        f.pressed["f5"] = True
        self.frames(3)
        self.M.shutdown()
        text = "\n".join(self.logs())
        print(text[-6000:])
        self.assertIn("F6: sample [xy] under the camera: -4.10", text)
        self.assertIn("F7: view hits box of 2222222222222222 at 8.00 m", text)
        self.assertIn("names 5c14f27759dd3be0: resource_name IdString64 feedfeedfeedfeed", text)
        self.assertIn("track 5c14f27759dd3be0 stopped at", text)
        self.assertIn("terrain there", text)
        self.assertNotIn("terrain there unknown", text)
        self.assertIn("try AI.find_intersecting_units [world_from_to]: nil error", text)
        self.assertIn("F5: line off", text)
        self.assertNotIn("NATIVE CRASH", text)
        self.assertEqual(f.calls["Unit.box"], 2, "boxes read for the terrain unit and rock only")


if __name__ == "__main__":
    unittest.main()
