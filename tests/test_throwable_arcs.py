"""Stratagem and C4 Trajectory on PUC Lua 5.1 (lupa) against a fake Chef Shared Loader:  python tests/test_throwable_arcs.py"""
import importlib.util
import math
import os
import re
import unittest

import lupa.lua51 as lua51

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "..", "src", "throwable_arcs.lua")
_spec = importlib.util.spec_from_file_location("ta_build", os.path.join(HERE, "..", "build.py"))
ta_build = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ta_build)   # the mod's build.py: the source with its armour table in

FAKE = r"""
local fake = { t = 0, logs = {}, down = {}, pressed = {}, mouse = {}, wheel = 0, lines = {}, calls = {}, cam = nil,
               watches = {}, saved = {}, opts = {}, changes = {}, shapes = {}, settings = {} }
local world = newproxy(true)

local PLAYER = '4d1c334d294dfa97'
fake.me = { kind = PLAYER, x = 0, y = 0, z = 0 }
fake.mine = { kind = '465f4895f3dc98d1', x = 0.2, y = 0.3, z = 1.6 }   -- my backpack
fake.runtime = { kind = '46cab355bd8d4d37', x = 1, y = 1, z = 1 }
fake.units = { fake.me, fake.mine, fake.runtime }

local E = {
  ['World.units'] = function() local out = {}; for i, u in ipairs(fake.units) do out[i] = u end; return out end,
}
fake.E = E
local function call(name, ...)
  fake.calls[name] = (fake.calls[name] or 0) + 1
  local f = E[name]
  if not f then return nil, 'missing' end
  local r = { pcall(f, ...) }
  if not r[1] then return nil, 'error: ' .. tostring(r[2]) end
  return r[2], r[3], r[4], r[5]
end

chef = {
  api = 3, loader_version = '1.2.1',
  has = function() return true end, own_log = function() return true end,
  log = function(fmt, ...) fake.logs[#fake.logs + 1] = string.format(fmt, ...) end,
  time = function() return fake.t end,
  call = call, call_kind = function(name, kind, ...) return call(name, ...) end,
  world = function() return world end, world_id = function() return 4 end, in_mission = function() return false end,
  camera = function() return fake.cam end,
  unit_alive = function(u) return u.dead ~= true end,
  unit_kind = function(u) return u.kind end,
  unit_position = function(u)
    if u.kind == '46cab355bd8d4d37' then error('NATIVE CRASH: asked a runtime-built unit') end
    return u.x, u.y, u.z
  end,
  watch = function(kinds)
    local w = { items = {}, kinds = kinds, active = true, lists = 0 }
    function w.stop() fake.watch_stopped = true end
    function w.pause() w.active = false end
    function w.resume() w.active = true end
    function w.refresh() end
    fake.watches[#fake.watches + 1] = w
    return w
  end,
  key_down = function(k) return fake.down[k] == true end,
  key_pressed = function(k) return fake.pressed[k] == true end,
  mouse_down = function(b) return fake.mouse[b] == true end,
  wheel = function() return fake.wheel end,
  line = function(x1, y1, z1, x2, y2, z2, c) fake.lines[#fake.lines + 1] = { x1, y1, z1, x2, y2, z2 } end,
  color = function(r, g, b, a) return { r, g, b, a } end,
  screen = function() return 1920, 1200 end,
  lights = function() return 0 end,
  save_table = function(name, t) fake.saved[name] = t; return true end,
  load_table = function(name) return fake.saved[name] end,
  title = function() end,
  TOP = 100000,
  option = function(id, spec)
    local v = fake.opts[id]
    if v == nil then v = spec.default end
    return v
  end,
  on_change = function(id, fn) fake.changes[id] = fn end,
  rect = function(...) fake.shapes[#fake.shapes + 1] = 'rect' end,
  triangle = function(...) fake.shapes[#fake.shapes + 1] = 'triangle' end,
  circle = function(...) fake.shapes[#fake.shapes + 1] = 'circle' end,
  ring = function(...) fake.shapes[#fake.shapes + 1] = 'ring' end,
  setting = function(path) return fake.settings[path] end,
  bitmap = function(tex, x, y, w, h, c, layer)
    if fake.no_bitmap then return false end
    fake.shapes[#fake.shapes + 1] = 'bitmap ' .. tex
    return true
  end,
  texture_sizes = function(map) fake.sizes = map end,
  bind = function(id, default)
    fake.bound = fake.bound or default
    return { key = function() return fake.bound end, down = function() return fake.down[fake.bound] == true end }
  end,
}

function fake.look(pitch_deg)
  local p = math.rad(pitch_deg)
  fake.cam = { x = 0, y = 0, z = 2, fx = math.cos(p), fy = 0, fz = math.sin(p), fov = 0.96 }
end
fake.look(0)

function fake.frame(M, dt)
  fake.t = fake.t + dt
  if fake.ball and not fake.ball.still then
    local b, f = fake.ball, fake.t - fake.ball.t0
    if f < 0.1 then
      b.x, b.y, b.z = 0.4 - f * 3, -0.3, 1.5   -- still the hand's swing: back, before the throw
    else
      f = f - 0.1
      b.x, b.y, b.z = 1.0 + b.vx * f, 0, 2 + b.vz * f - 0.5 * b.g * f * f
      if b.z <= 0 then b.z, b.still = 0, true end   -- lands and stays: its velocity jumps to 0
    end
  end
  for _, w in ipairs(fake.watches) do
    if w.active then
      w.items, w.lists = {}, w.lists + 1
      for _, u in ipairs(fake.units) do if w.kinds[u.kind] then w.items[#w.items + 1] = { unit = u, kind = u.kind } end end
    end
  end
  fake.lines, fake.shapes = {}, {}
  M.update(dt)
  fake.pressed, fake.wheel = {}, 0
end

-- thrown now: the ball in hand flies from 0.1 s on (test.13: no other ball appears); before, the hand swings it
function fake.throw(kind, speed, pitch_deg, g, held)
  local p = math.rad(pitch_deg)
  local b = held or { kind = kind }
  b.t0, b.vx, b.vz, b.g, b.still, b.x, b.y, b.z = fake.t, speed * math.cos(p), speed * math.sin(p), g, nil, 0.4, -0.3, 1.5
  fake.ball = b
  if not held then fake.units[#fake.units + 1] = b end
end
return fake
"""


class ArcTest(unittest.TestCase):
    def setUp(self):
        self.lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        self.fake = self.lua.execute(FAKE)
        self.M = self.load()

    def load(self):
        return self.lua.execute(ta_build.built_source(), self.lua.globals().chef)

    def frames(self, n, dt=1 / 60):
        for _ in range(n):
            self.fake.frame(self.M, dt)

    def lines(self):
        return [tuple(l.values()) for l in self.fake.lines.values()]

    def logs(self):
        return "\n".join(self.fake.logs.values())

    def add_unit(self, kind, x, y, z):
        return self.lua.eval("function(f, k, x, y, z) local u = { kind = k, x = x, y = y, z = z }; "
                             "f.units[#f.units + 1] = u; return u end")(self.fake, kind, x, y, z)

    def ball_watch(self):
        return [w for w in self.fake.watches.values() if w.kinds["16f397ca5f51f271"]][-1]

    def stratagem_key(self, key="left ctrl"):
        self.fake["down"][key] = True
        self.frames(20)
        self.fake["down"][key] = False
        self.frames(20)

    def ready_ball(self, at=(-0.05, -0.3, 1.5)):
        """A ball in my right hand: held 0.35 m farther ahead while its code goes in, then pulled back (lit)."""
        ball = self.add_unit("16f397ca5f51f271", at[0] + 0.35, at[1], at[2])
        self.frames(6)
        self.lua.eval("function(b, x) b.x = x end")(ball, at[0])
        self.frames(6)
        return ball

    def aim(self, pitch=10, at=(-0.05, -0.3, 1.5)):
        self.stratagem_key()
        self.fake.look(pitch)
        self.ball = self.ready_ball(at)
        self.fake["mouse"]["left"] = True
        self.frames(2)

    def test_no_arc_without_aiming(self):
        self.fake["down"]["g"] = True                 # grenades aren't drawn (dropped after test.7)
        self.frames(200)
        self.assertEqual(self.lines(), [])

    def test_the_arc_starts_where_the_ball_is_let_go_and_goes_on_below_my_feet(self):
        self.aim(10)
        lines = self.lines()
        self.assertEqual(len(lines) % 2, 0, "2 lines side by side per segment")
        first = [(a + b) / 2 for a, b in zip(lines[0][:3], lines[1][:3])]
        self.assertAlmostEqual(first[0], -0.05, delta=0.02)
        self.assertAlmostEqual(first[1], -0.3, delta=0.02)
        self.assertAlmostEqual(first[2], 1.9, delta=0.02, msg="let go 0.4 m above where it is held")
        # dashed: a drawn piece often doesn't start where the last one ended
        centre = lines[0::2]
        gaps = sum(1 for a, b in zip(centre, centre[1:]) if math.dist(a[3:], b[:3]) > 0.05)
        self.assertGreater(gaps, 5)
        # ends 15 m under my feet (the game hides what is under the ground)
        self.assertLess(min(l[5] for l in lines), -15)
        self.assertGreater(min(l[5] for l in lines), -17)

    def test_prone(self):
        # lying down, the ball in hand is about at my feet' height, with no pull-back: it rises into the aim
        self.aim(5, at=(0.6, -0.2, -0.15))
        self.assertEqual(self.lines(), [], "not yet: no pull-back lying down")
        self.lua.eval("function(b) b.z = 0.15 end")(self.ball)
        self.frames(2)
        lines = self.lines()
        self.assertGreater(len(lines), 20)
        self.assertAlmostEqual(lines[0][2], 0.55, delta=0.05)
        # a plain throw: the climb angle changes little from one piece to the next
        centre = lines[0::2]
        ang = [math.atan2(l[5] - l[2], math.hypot(l[3] - l[0], l[4] - l[1])) for l in centre[:15]]
        self.assertLess(max(abs(a - b) for a, b in zip(ang, ang[1:])), math.radians(6))

    def test_dashes_stay_put_when_the_camera_moves(self):
        # the arc hangs on the ball and the camera's heading only: the camera moving back leaves it where it is
        self.aim(10)
        before = self.lines()
        self.lua.eval("function(f) f.cam.x = f.cam.x - 1 end")(self.fake)
        self.frames(1)
        after = self.lines()
        ends = lambda ls: [round(l[3], 3) for l in ls[0::2]]
        self.assertEqual(ends(before)[16:26], ends(after)[16:26])
        self.assertEqual(len(before), len(after))

    def test_the_arc_stays_until_the_ball_leaves_the_hand(self):
        self.aim()
        self.fake["mouse"]["left"] = False          # let go: the swing, the ball still in hand
        self.frames(5)
        self.assertGreater(len(self.lines()), 20, "kept while the ball is in hand")
        self.lua.eval("function(b) b.x = b.x + 2 end")(self.ball)   # it flies
        self.frames(1)
        self.assertEqual([l[2] for l in self.lines()], [-10000], "one empty line resets the line object")
        self.frames(1)
        self.assertEqual(self.lines(), [])

    def test_the_hold_ends_by_itself(self):
        self.aim()
        self.fake["mouse"]["left"] = False          # let go, and nothing ever leaves the hand
        self.frames(30)
        self.assertGreater(len(self.lines()), 20)
        self.frames(10)                             # 0.6 s
        self.assertEqual(self.lines(), [])

    def test_right_mouse_aims_a_stratagem(self):
        ball = self.ready_ball()
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.assertGreater(len(self.lines()), 20)
        self.fake["mouse"]["right"] = False         # aim let go, the ball still in hand: off, and on again
        self.frames(2)
        self.assertEqual(self.lines(), [])
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.assertGreater(len(self.lines()), 20)
        self.fake["mouse"]["left"] = True           # thrown with left while right aims
        self.frames(2)
        self.fake["mouse"]["left"] = False
        self.frames(1)                              # let go, still in hand
        self.lua.eval("function(b) b.x = b.x + 2 end")(ball)   # then it flies
        self.frames(2)
        self.assertEqual(self.lines(), [])

    def test_no_key_needed(self):
        # whatever key calls stratagems: a ready ball in hand and left held is enough
        self.ready_ball()
        self.fake["mouse"]["left"] = True
        self.frames(2)
        self.assertGreater(len(self.lines()), 20)

    def test_put_away_then_a_shot(self):
        # the ball still in hand when left goes down (a stratagem put away), gone a moment later: the arc goes with it
        self.aim(10)
        self.assertGreater(len(self.lines()), 20)
        self.ball.dead = True
        self.frames(1)
        self.frames(1)
        self.assertEqual(self.lines(), [])
        self.frames(30)
        self.assertEqual(self.lines(), [], "and stays off while the shot goes on")

    def test_left_during_code_entry_draws_nothing(self):
        # the ball in hand, still in front (unlit: its code isn't in): left is no throw
        self.add_unit("16f397ca5f51f271", 0.3, -0.3, 1.2)
        self.frames(20)
        self.fake["mouse"]["left"] = True
        self.frames(20)
        self.assertEqual(self.lines(), [])

    def test_left_held_while_the_code_goes_in(self):
        # left down before the code is in: no pull-back, the ball goes up into the aim once it is lit
        ball = self.add_unit("16f397ca5f51f271", 0.3, -0.45, 1.25)
        self.frames(20)
        self.fake["mouse"]["left"] = True
        self.frames(30)
        self.assertEqual(self.lines(), [], "code still going in")
        self.lua.eval("function(b) b.x, b.z = -0.05, 1.47 end")(ball)
        self.frames(2)
        self.assertGreater(len(self.lines()), 20)

    def c4_in_hand(self):
        """C4 is the weapon: its backpack on me, the detonator in my right hand."""
        self.add_unit("2a18f81c44a26771", -0.15, 0.1, 1.3)
        return self.add_unit("51f50d6321f52f3d", -0.05, -0.4, 1.05)

    def test_c4_aimed_with_right(self):
        det = self.c4_in_hand()
        self.fake["mouse"]["right"] = True
        self.frames(5)
        self.assertEqual(self.lines(), [], "not yet: the detonator hasn't gone forward into the aim")
        self.lua.eval("function(u) u.x = 0.42 end")(det)
        self.frames(2)
        lines = self.lines()
        self.assertGreater(len(lines), 20)
        first = [(a + b) / 2 for a, b in zip(lines[0][:3], lines[1][:3])]
        self.assertAlmostEqual(first[0], 0.42, delta=0.02)
        self.assertAlmostEqual(first[1], -0.4, delta=0.02)
        # left throws it: the arc goes at once
        self.fake["mouse"]["left"] = True           # thrown: kept until the charge shows up
        self.frames(3)
        self.assertGreater(len(self.lines()), 20)
        self.add_unit("9b75217d8312dd67", -0.05, -0.4, 1.6)
        self.frames(1)
        self.assertEqual([l[2] for l in self.lines()], [-10000])
        self.frames(1)
        self.assertEqual(self.lines(), [])

    def c4_object(self, options, owner_host=False):
        """C4's network object (NarrowHUD's names): mine, or the host's with me in its owner field."""
        self.lua.eval("""function(f, options, by_host)
          f.c4_options = options
          f.E['Network.game_session'] = function() return 'gs' end
          f.E['Network.peer_id'] = function() return '00ab12' end
          f.E['GameSession.game_session_host'] = function() return by_host and 'ff01' or '00ab12' end
          f.E['GameSession.objects_owned_by'] = function(gs, peer)
            if peer == '00ab12' then return by_host and { 3 } or { 3, 7 } end
            return { 9 }
          end
          f.E['GameSession.game_object_exists'] = function(gs, id) return true end
          f.E['GameSession.game_object_is_type'] = function(gs, id, t) return t == 'kbv6zx' and id == (by_host and 9 or 7) end
          f.E['GameSession.game_object_field'] = function(gs, id, name)
            if name == 'ozvglfc' then return f.c4_options end
            if name == 'g5g7b9d' then return 'AB12' end
            if name == 'n5jmvf' then return f.c4_carry or 0 end
          end
        end""")(self.fake, options, owner_host)

    def c4_aim_try(self):
        det = self.c4_in_hand()
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.lua.eval("function(u) u.x = 0.42 end")(det)
        self.frames(2)

    def test_c4_detonate_mode_draws_nothing(self):
        self.c4_object(336)
        self.c4_aim_try()
        self.assertEqual(self.lines(), [])

    def test_c4_deploy_mode_draws(self):
        self.c4_object(80)
        self.c4_aim_try()
        self.assertGreater(len(self.lines()), 20)
        # switched to the detonator while aiming: the arc goes
        self.fake["c4_options"] = 336
        self.frames(2)
        self.assertEqual(self.lines(), [])

    def test_c4_owned_by_the_host(self):
        self.c4_object(336, owner_host=True)
        self.c4_aim_try()
        self.assertEqual(self.lines(), [])

    def hand_pose(self, grip):
        """my helldiver's animation variable weapon_selected (NarrowHUD's hand pose)"""
        self.lua.eval("""function(f, grip)
          f.grip = grip
          f.E['Unit.has_animation_state_machine'] = function(u) return u.kind == '4d1c334d294dfa97' end
          f.E['Unit.animation_has_variable'] = function(u, name) return name == 'weapon_selected' end
          f.E['Unit.animation_find_variable'] = function(u, name) return 3 end
          f.E['Unit.animation_get_variable'] = function(u, i) return i == 3 and f.grip or nil end
        end""")(self.fake, grip)

    def test_c4_pose_and_aim(self):
        # C4 in hand (42), right held and the detonator gone forward into the aim: the arc, from 1 m above it
        det = self.c4_in_hand()
        self.hand_pose(42)
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.assertEqual(self.lines(), [], "not yet in the aim pose (in a driver's seat it never is)")
        self.lua.eval("function(u) u.x = 0.42 end")(det)
        self.frames(2)
        lines = self.lines()
        self.assertGreater(len(lines), 20)
        self.assertAlmostEqual((lines[0][0] + lines[1][0]) / 2, 0.42, delta=0.02)   # from the detonator
        self.assertAlmostEqual((lines[0][2] + lines[1][2]) / 2, 2.05, delta=0.02)   # 1 m above it
        # thrown: the charge leaves, then no arc for 0.8 s while the arm swings, then again
        self.fake["mouse"]["left"] = True
        self.frames(2)
        self.add_unit("9b75217d8312dd67", 0.42, -0.4, 1.3)
        self.fake["mouse"]["left"] = False
        self.frames(20)
        self.assertEqual(self.lines(), [])
        self.frames(40)
        self.assertGreater(len(self.lines()), 20)

    def shapes(self):
        return list(self.fake.shapes.values())

    def test_c4_mode_icon_is_the_games(self):
        # the game's icon, shipped in the patch at 4 sizes: one bitmap, of the biggest (the loader picks the size)
        self.c4_in_hand()
        self.hand_pose(42)
        self.c4_object(80)
        self.frames(10)
        shapes = self.shapes()
        self.assertEqual(len(shapes), 1)
        deploy = self.lua.eval("function(f) local n = 0; for k, l in pairs(f.sizes) do n = n + 1 end; return n end")(self.fake)
        self.assertEqual(deploy, 2, "a size ladder for each icon")
        self.assertRegex(shapes[0], r"^bitmap [0-9a-f]{16}$")
        self.fake["c4_options"] = 336
        self.frames(10)
        self.assertNotEqual(self.shapes()[0], shapes[0], "DETONATE's own")

    def test_c4_mode_icon(self):
        # without the textures (chef.bitmap false): drawn with shapes
        self.fake["no_bitmap"] = True
        self.c4_in_hand()
        self.hand_pose(42)
        self.c4_object(80)
        self.frames(10)
        self.assertEqual(self.shapes().count("rect"), 14, "DEPLOY: the arrow's stem and 2 sticks of 3, and their shadow")
        self.fake["c4_options"] = 336
        self.frames(10)
        self.assertEqual(self.shapes().count("triangle"), 40, "DETONATE: a ring's 20 teeth, and its shadow")
        self.assertEqual(self.shapes().count("ring"), 2)
        self.hand_pose(10)                          # another weapon in hand: no icon
        self.frames(10)
        self.assertEqual(self.shapes(), [])
        self.hand_pose(42)
        self.fake.changes["c4_icon"](False)         # turned off in the menu
        self.frames(10)
        self.assertEqual(self.shapes(), [])

    def test_c4_mode_icon_off_from_the_start(self):
        self.fake.opts["c4_icon"] = False
        self.M = self.load()
        self.c4_in_hand()
        self.hand_pose(42)
        self.c4_object(80)
        self.frames(10)
        self.assertEqual(self.shapes(), [])

    def test_hand_pose_found_later(self):
        self.fake["no_bitmap"] = True
        # the variable not there yet at first: looked for again 5 s later
        self.c4_in_hand()
        self.c4_object(80)
        self.frames(30)
        self.assertEqual(self.shapes(), [])
        self.hand_pose(42)
        self.frames(330)
        self.assertGreater(len(self.shapes()), 0)

    def test_c4_put_away_while_aiming(self):
        # the hand pose stays C4 a moment while it is put away; the detonator leaving the aim pose ends the arc
        det = self.c4_in_hand()
        self.hand_pose(42)
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.lua.eval("function(u) u.x = 0.42 end")(det)
        self.frames(2)
        self.assertGreater(len(self.lines()), 20)
        self.lua.eval("function(u) u.x, u.z = -0.1, 0.9 end")(det)
        self.frames(30)                             # (kept 0.25 s, for dives)
        self.assertEqual(self.lines(), [])

    def test_c4_aim_kept_while_turning(self):
        # the camera turns ahead of my helldiver: the detonator, still as far from my feet, keeps the arc
        det = self.c4_in_hand()
        self.hand_pose(42)
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.lua.eval("function(u) u.x = 0.42 end")(det)
        self.frames(2)
        self.lua.eval("function(f) local p = math.rad(10); f.cam.fx, f.cam.fy = 0, 1 end")(self.fake)   # 90 degrees
        self.frames(2)
        self.assertGreater(len(self.lines()), 20)

    def test_c4_prone(self):
        # lying down the detonator lies low and right doesn't move it: C4 in hand and right is the aim
        self.add_unit("51f50d6321f52f3d", 0.67, -0.18, 0.06)
        self.hand_pose(42)
        self.frames(2)
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.assertGreater(len(self.lines()), 20)

    def test_c4_passenger_leaning_out(self):
        # seated, leaning out to aim up: the camera far off and the detonator 1.4 m from my feet
        det = self.c4_in_hand()
        self.hand_pose(42)
        self.frames(2)                              # found on foot first
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.lua.eval("function(u) u.x, u.y = 0.9, -1.07 end")(det)
        self.lua.eval("function(f) f.cam.x = -9 end")(self.fake)
        self.frames(3)
        self.assertGreater(len(self.lines()), 20)

    def test_thicker_below_native_render_scale(self):
        self.lua.eval("function(f) f.settings['render_settings.render_resolution'] = { 1129, 600 } end")(self.fake)
        self.aim(10)
        lines = self.lines()
        self.assertGreater(len(lines), 30)
        self.assertEqual(len(lines) % 3, 0, "3 lines a segment, not 2")
        # 2 render pixels across between the outer two (render scale 0.5 of 1200: 2 px each)
        a, b = lines[30], lines[32]
        mid = [(a[i] + a[i + 3]) / 2 for i in range(3)]
        width_px = math.dist(a[:3], b[:3]) / (math.dist(mid, (0, 0, 2)) * 0.96 / 1200)
        self.assertAlmostEqual(width_px, 4, delta=0.2)

    def test_c4_prone_looking_behind(self):
        # lying down, looking behind: the detonator 0.4 m up and close to my feet, still the aim
        self.add_unit("51f50d6321f52f3d", -0.12, -0.18, 0.40)
        self.hand_pose(42)
        self.frames(2)
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.assertGreater(len(self.lines()), 20)

    def test_c4_diving(self):
        # diving: the hand pose reads 40 a moment after C4's 42, the detonator low on my left
        det = self.add_unit("51f50d6321f52f3d", 0.0, -0.4, 1.05)
        self.hand_pose(42)
        self.frames(10)
        self.lua.eval("function(u) u.x, u.y, u.z = 0.1, 0.22, 0.14 end")(det)
        self.fake["grip"] = 40
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.assertGreater(len(self.lines()), 20)
        self.fake["mouse"]["right"] = False
        self.frames(200)                            # a grenade in hand long after: not C4
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.assertEqual(self.lines(), [])

    def test_c4_knee_slide(self):
        # sliding on my knees: the detonator at crouch height and not moving out, still the aim
        self.add_unit("51f50d6321f52f3d", 0.15, -0.3, 0.57)
        self.hand_pose(42)
        self.frames(2)
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.assertGreater(len(self.lines()), 20)

    def test_c4_passenger_aiming_behind(self):
        det = self.c4_in_hand()
        self.hand_pose(42)
        self.vehicle_at(0.4, 0.3, -0.6)             # seated
        self.frames(2)
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.lua.eval("function(u) u.x = 0.42 end")(det)   # leaning out
        self.frames(2)
        self.assertGreater(len(self.lines()), 20)
        self.lua.eval("function(u) u.x, u.y = -0.1, -0.1 end")(det)   # aiming behind: close in
        self.frames(2)
        self.assertGreater(len(self.lines()), 20)

    def test_c4_tank_seat(self):
        # on a tank's top, 3.1 m off its middle and 2.4 m up: in a vehicle, the aim kept as the detonator comes in
        det = self.c4_in_hand()
        self.hand_pose(42)
        self.add_unit("16474112801385b6", 3.1, 0, -2.4)
        self.frames(2)
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.lua.eval("function(u) u.x = 0.42 end")(det)
        self.frames(2)
        self.assertGreater(len(self.lines()), 20)
        self.lua.eval("function(u) u.x, u.y = 0.3, -0.3 end")(det)   # back to 0.42 m off: still kept
        self.frames(30)
        self.assertGreater(len(self.lines()), 20)

    def test_c4_tank_seat_raised(self):
        # on a tank's top the detonator sits 0.45 m off already and only rises to aim: from 0.59 to 1.1 m up
        det = self.add_unit("51f50d6321f52f3d", 0.37, -0.24, 0.59)
        self.hand_pose(42)
        self.add_unit("16474112801385b6", 3.1, 0, -2.2)
        self.frames(2)
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.assertEqual(self.lines(), [])
        self.lua.eval("function(u) u.z = 1.1 end")(det)
        self.frames(2)
        self.assertGreater(len(self.lines()), 20)

    def test_c4_driver_seat(self):
        # seated, right held, the detonator never leans out (and sits low, 0.46 m up): no arc
        self.add_unit("51f50d6321f52f3d", 0.06, -0.25, 0.46)
        self.hand_pose(42)
        self.vehicle_at(0.4, 0.3, -0.6)
        self.fake["mouse"]["right"] = True
        self.frames(30)
        self.assertEqual(self.lines(), [])

    def test_swapped_detonator(self):
        # the C4 dropped (not carried any more) is let go and the one carried is read
        self.fake["no_bitmap"] = True
        self.c4_in_hand()
        self.hand_pose(42)
        self.c4_object(80)
        self.frames(10)
        self.assertEqual(self.shapes().count("rect"), 14)
        self.lua.eval("""function(f)
          f.E['GameSession.objects_owned_by'] = function() return { 3, 7, 8 } end
          f.E['GameSession.game_object_is_type'] = function(gs, id, t) return t == 'kbv6zx' and (id == 7 or id == 8) end
          f.E['GameSession.game_object_field'] = function(gs, id, name)
            if name == 'n5jmvf' then return id == 8 and 0 or 2 end
            if name == 'ozvglfc' then return id == 8 and 336 or 80 end
          end
        end""")(self.fake)
        self.frames(150)
        self.assertEqual(self.shapes().count("ring"), 2, "the new detonator's mode")

    def vehicle_at(self, x, y, z):
        return self.add_unit("cc21c7ffd3ebefb9", x, y, z)

    def test_icon_in_a_vehicle_while_aiming(self):
        # seated, the icon only while C4 is aimed (a passenger leaning out), DETONATE too (no arc there)
        det = self.c4_in_hand()
        self.hand_pose(42)
        self.c4_object(336)
        self.vehicle_at(0.4, 0.3, -0.6)
        self.frames(40)
        self.assertEqual(self.shapes(), [])
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.lua.eval("function(u) u.x = 0.42 end")(det)   # leaning out
        self.frames(10)
        self.assertEqual(len(self.shapes()), 1, "the icon")
        self.assertEqual(self.lines(), [], "DETONATE: no arc")
        self.fake["mouse"]["right"] = False
        self.frames(10)
        self.assertEqual(self.shapes(), [])

    def test_no_icon_in_a_vehicle(self):
        self.c4_in_hand()
        self.hand_pose(42)
        self.c4_object(80)
        car = self.vehicle_at(2.2, 0, -0.6)        # seated: 2.2 m from its middle, 0.6 m above its base
        self.frames(40)
        self.assertEqual(self.shapes(), [])
        self.lua.eval("function(u) u.z = 0 end")(car)   # standing by it on the ground
        self.frames(40)
        self.assertGreater(len(self.shapes()), 0)

    def test_c4_pose_other_weapon_draws_nothing(self):
        # another weapon in hand (pose 10): the detonator going forward is no aim
        det = self.c4_in_hand()
        self.hand_pose(10)
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.lua.eval("function(u) u.x = 0.42 end")(det)
        self.frames(2)
        self.assertEqual(self.lines(), [])

    def test_c4_raised_arm_is_no_aim(self):
        # the throw lifts the detonator about 2.1 m up: no arc from there
        det = self.c4_in_hand()
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.lua.eval("function(u) u.x, u.z = 0.3, 2.1 end")(det)
        self.frames(10)
        self.assertEqual(self.lines(), [])

    def test_c4_arc_ends_when_right_is_let_go(self):
        det = self.c4_in_hand()
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.lua.eval("function(u) u.x = 0.42 end")(det)
        self.frames(2)
        self.assertGreater(len(self.lines()), 20)
        self.fake["mouse"]["right"] = False
        self.frames(2)
        self.assertEqual(self.lines(), [])

    def test_right_without_c4_in_hand_draws_nothing(self):
        # another weapon aimed: the detonator rides on my back, not in my right hand, even if it moves forward
        self.add_unit("2a18f81c44a26771", -0.15, 0.1, 1.3)
        det = self.add_unit("51f50d6321f52f3d", -0.2, 0.1, 1.2)
        self.fake["mouse"]["right"] = True
        self.frames(5)
        self.lua.eval("function(u) u.x = 0.2 end")(det)
        self.frames(5)
        self.assertEqual(self.lines(), [])

    def test_a_moving_throw_is_measured(self):
        # test builds: running 3 m/s forward, the ball thrown (the fake flies it from 0.1 s on, 22 m/s at 19 degrees)
        self.aim(10)
        self.lua.eval("function(f) f.run = 3 end")(self.fake)
        for _ in range(10):
            self.lua.eval("function(f) f.me.x = f.me.x + 3 / 60 end")(self.fake)
            self.frames(1)
        self.fake["mouse"]["left"] = False
        self.fake.throw("16f397ca5f51f271", 22, 19, 9.81, self.ball)
        self.frames(200)
        m = re.search(r"throw \(stratagem\): moving ([-\d.]+) fwd ([-\d.]+) right .*flew ([-\d.]+) fwd ([-\d.]+) right "
                      r"([-\d.]+) up \(gravity ([-\d.]+)", self.logs())
        self.assertTrue(m, self.logs())
        self.assertAlmostEqual(float(m.group(1)), 3, delta=0.2)
        self.assertAlmostEqual(float(m.group(3)), 22 * math.cos(math.radians(19)), delta=0.3)
        self.assertAlmostEqual(float(m.group(6)), 9.81, delta=0.3)
        self.assertRegex(self.logs(), r"held the arc 0\.\d\d s")

    def test_shooting_draws_nothing(self):
        self.fake["mouse"]["left"] = True                # no ball in hand: a shot
        self.frames(90)
        self.assertEqual(self.lines(), [])
        self.add_unit("16f397ca5f51f271", 0.4, -0.3, 1.5)
        self.frames(30)
        self.assertEqual(self.lines(), [], "still the same shot: looked for a second only")

    def test_after_a_throw_left_is_a_shot(self):
        f = self.fake
        self.aim(10)
        self.assertIn("armour: none of the table [on me], throw range +0%", self.logs())
        f["mouse"]["left"] = False
        f.throw("16f397ca5f51f271", 22, 19, 9.81, self.ball)
        self.frames(200)
        f["mouse"]["left"] = True
        self.frames(2)
        self.assertEqual(self.lines(), [], "thrown: the ball lies far away, a shot again")
        self.assertNotIn("NATIVE CRASH", self.logs())

    def wear(self, name):
        with open(ta_build.ARMOUR, encoding="utf-8") as f:
            rows = self.lua.execute(f.read())
        kinds = [row[3].split() for row in rows.values() if row[1] == name][0]
        return self.lua.table(*[self.add_unit(k, 0.1 * (i % 3), 0.1, 1.0) for i, k in enumerate(kinds)])   # on me

    def far_end(self):
        return max(l[3] for l in self.lines())

    def test_desert_stormer_throws_20_percent_farther(self):
        self.aim(15)
        plain = self.far_end()
        self.fake["mouse"]["left"] = False
        self.frames(2)
        self.wear("DS-10 Big Game Hunter")
        self.aim(15)
        self.assertIn("armour: DS-10 Big Game Hunter [on me] (100% of its units), throw range +20%", self.logs())
        # flat ground far below: the far end moves out by about the speed ratio (range grows with its square)
        self.assertGreater(self.far_end() / plain, 1.08)

    def drawn_speed(self, pitch):
        """the throw speed the arc was drawn with: a late segment's run along the view (it looks along x), per step"""
        centre = self.lines()[0::2]
        l = centre[len(centre) // 2]
        return (l[3] - l[0]) / 0.03 / math.cos(math.radians(pitch))

    def test_servo_assisted_speeds(self):
        # as measured in test.26: stratagem balls 1.2x (26.4 m/s), C4 1.3x (29.1 m/s)
        self.hand_pose(41)
        self.wear("SA-25 Steel Trooper")
        self.aim(15)
        self.assertIn("throw range +30%", self.logs())
        self.assertAlmostEqual(self.drawn_speed(15 + 7.8), 26.4, delta=0.1)
        self.fake["mouse"]["left"] = False
        self.ball.dead = True                       # thrown
        self.frames(2)
        det = self.c4_in_hand()
        self.fake["grip"] = 42
        self.fake["mouse"]["right"] = True
        self.frames(2)
        self.lua.eval("function(u) u.x = 0.42 end")(det)
        self.frames(2)
        self.assertAlmostEqual(self.drawn_speed(15 + 4.4), 29.1, delta=0.1)

    def test_armour_told_once(self):
        # the pass over all the world's units: at the first aim only, not at every throw
        self.wear("DS-10 Big Game Hunter")
        self.aim(15)
        first = self.fake.calls["World.units"]
        for _ in range(3):
            self.fake["mouse"]["left"] = False
            self.frames(2)
            self.aim(15)
        self.assertEqual(self.fake.calls["World.units"], first)
        self.assertIn("throw range +20%", self.logs())

    def test_a_lookalike_without_the_perk(self):
        # FS-23 Battle Master shares 20 of TR-62 Knight's 23 units, but throws no farther
        self.wear("FS-23 Battle Master")
        self.aim(15)
        self.assertIn("armour: FS-23 Battle Master [on me] (100% of its units), throw range +0%", self.logs())

    def test_transmog_tells_my_own_armour(self):
        # HD2 Transmog: the look's copies (DS-10) are on me as well as my own armour (SR-24, hidden); its worn('armor')
        # lists my own
        self.wear("DS-10 Big Game Hunter")
        mine = self.wear("SR-24 Street Scout")
        self.lua.eval("function(units) TransmogUI = { worn = function(g) return units end } end")(mine)
        self.aim(15)
        self.assertIn("armour: SR-24 Street Scout [Transmog] (100% of its units), throw range +0%", self.logs())
        self.lua.execute("TransmogUI = nil")

    def test_two_whole_armours_without_transmog(self):
        self.wear("DS-10 Big Game Hunter")
        self.wear("SR-24 Street Scout")
        self.aim(15)
        self.assertRegex(self.logs(), r"armour: .* and .* \(a look mod\? no bonus\) \[on me\].*throw range \+0%")

    def test_looking_down_keeps_the_ball_in_hand(self):
        self.lua.eval("function(f) local look = f.look; f.look = function(p) look(p); f.cam.z = 2 - p / 15 end end")(
            self.fake)
        self.aim(-60)
        self.assertGreater(len(self.lines()), 20)


if __name__ == "__main__":
    unittest.main()
