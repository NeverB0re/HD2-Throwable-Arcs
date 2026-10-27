-- HD2-Addon: mods/codex/weapon_probe
-- Weapon Probe 0.1.0: a one-off test mod, not for release. Stage 0 of mods/throwable-arcs/WEAPON_ARCS_PLAN.md. It
-- draws nothing and changes nothing; it writes weapon_probe.log (in %APPDATA%\Arrowhead\Helldivers2):
--   the weapon in hand: when the hand pose changes, when aiming begins and at each shot, the weapon units on my
--     helldiver (named from filediver's hash list) and the unnamed units on it that point along the camera, with
--     their place from my feet and where they point; muzzle node names tried on them;
--   each shot (left mouse down): camera, feet, my velocity, aiming or not, hand pose;
--   what a shot made: units new since the last look, within NEW_NEAR m of the camera, from the click until RELEASE_AFTER
--     s after the button is let go, each followed every TRACK_EVERY s until it stops, goes, or TRACK_MOST s pass.
local chef = ...
local M = {}
local VERSION = '0.1.0'

if chef.has and chef.has('own_log') then chef.own_log('weapon_probe') end

local LOG_MOST = 80000          -- lines
local lines = 0
local function log(fmt, ...)
  if lines >= LOG_MOST then return end
  lines = lines + 1
  if lines == LOG_MOST then chef.log('log full: nothing more is written') return end
  chef.log(fmt, ...)
end

local PLAYER = '4d1c334d294dfa97'
local RUNTIME_BUILT = '46cab355bd8d4d37'   -- asking where one is ends the game: never asked anything
local GRIP_VARIABLE = 'weapon_selected'
local BASE_EVERY = 0.5          -- s between looks at every unit, outside a shot
local NEW_NEAR = 20             -- m from the camera a shot's new unit is first seen within
local RELEASE_AFTER = 0.6       -- s after the button is let go that new units still count as the shot's
local TRACK_EVERY, TRACK_MOST, TRACK_COUNT = 0.02, 8, 12
local POSE_STEADY = 0.3         -- s a new hand pose must hold before it is reported
local AIM_SETTLE = 0.4          -- s after aiming begins that the weapon is reported (the raise is done)

-- weapon units by kind, from filediver's hash list (build_weapon_probe.py fills this in): kind -> short name
local WEAPONS = {}
for kind, name in ([[@WEAPONS@]]):gmatch('(%x+) (%S+)') do WEAPONS[kind] = name end

-- muzzle node names tried on the weapon in hand (node names are hashed: these are guesses)
local NODES = { 'muzzle', 'fx_muzzle', 'a_muzzle', 'attach_muzzle', 'ap_muzzle', 'muzzle_flash', 'fx_muzzle_flash',
                'a_fx_muzzle', 'j_muzzle', 'muzzle_01', 'barrel', 'fx_barrel', 'projectile', 'projectile_spawn',
                'spawn_projectile', 'fire', 'fx_fire', 'shoot', 'eject', 'fx_eject', 'grip', 'a_grip' }

local function now() return chef.time() end
local function f3(x, y, z) return string.format('%.2f %.2f %.2f', x, y, z) end
local function name_of(kind) return WEAPONS[kind] or '?' end

local function all_units()
  local w = chef.world()
  local units = w and chef.call('World.units', w)
  return type(units) == 'table' and units or {}
end

-- the camera's heading on the ground: x, y
local function heading(c)
  local h = math.sqrt(c.fx * c.fx + c.fy * c.fy)
  if h < 1e-6 then return 0, 1 end
  return c.fx / h, c.fy / h
end

-- ------------------------------------------------------------------ my helldiver
-- the one nearest the camera within 6 m across, kept while within 15 m (as Stratagem and C4 Trajectory finds it)
local players = chef.watch and chef.watch({ [PLAYER] = true }, 2)
local mine, me = nil, nil       -- me: { x, y, z } of its feet

local function update_me(c)
  me = nil
  if mine and chef.unit_alive(mine) then
    local x, y, z = chef.unit_position(mine)
    if x and (x - c.x) ^ 2 + (y - c.y) ^ 2 < 225 then me = { x, y, z } return end
  end
  mine = nil
  if not players then return end
  local best
  for _, it in ipairs(players.items) do
    if chef.unit_alive(it.unit) then
      local x, y, z = chef.unit_position(it.unit)
      if x then
        local d = (x - c.x) ^ 2 + (y - c.y) ^ 2
        if d < 36 and (not best or d < best) then best, mine, me = d, it.unit, { x, y, z } end
      end
    end
  end
end

-- my velocity from my feet over the last 0.15 s
local trail = {}
local function update_trail()
  if not me then trail = {} return end
  local t = now()
  trail[#trail + 1] = { t, me[1], me[2], me[3] }
  while #trail > 2 and t - trail[2][1] >= 0.15 do table.remove(trail, 1) end
end
local function my_move()
  local a, b = trail[1], trail[#trail]
  if not (a and b and b[1] - a[1] > 0.02) then return 0, 0, 0 end
  local dt = b[1] - a[1]
  return (b[2] - a[2]) / dt, (b[3] - a[3]) / dt, (b[4] - a[4]) / dt
end

-- my hand pose (NarrowHUD's weapon_selected), or nil
local grip_index = setmetatable({}, { __mode = 'k' })
local function hand_pose()
  local u = mine
  if not (u and chef.unit_alive(u)) then return nil end
  local idx = grip_index[u]
  if idx == nil or (type(idx) == 'table' and now() >= idx.retry) then
    idx = { retry = now() + 5 }
    if chef.call_kind('Unit.has_animation_state_machine', PLAYER, u) == true
       and chef.call_kind('Unit.animation_has_variable', PLAYER, u, GRIP_VARIABLE) == true then
      local i = chef.call_kind('Unit.animation_find_variable', PLAYER, u, GRIP_VARIABLE)
      if type(i) == 'number' then idx = i end
    end
    grip_index[u] = idx
  end
  if type(idx) ~= 'number' then return nil end
  local v = chef.call_kind('Unit.animation_get_variable', PLAYER, u, idx)
  return type(v) == 'number' and math.floor(v + 0.5) or nil
end

-- ------------------------------------------------------------------ the weapon in hand
-- the units on my helldiver: within 1.5 m across, 0.5 m under to 2.5 m over its feet
local function units_on_me()
  local out = {}
  if not me then return out end
  for _, u in ipairs(all_units()) do
    if chef.unit_alive(u) then
      local kind = chef.unit_kind(u)
      if kind and kind ~= RUNTIME_BUILT and kind ~= PLAYER then
        local x, y, z = chef.unit_position(u)
        if x and (x - me[1]) ^ 2 + (y - me[2]) ^ 2 < 2.25 and z > me[3] - 0.5 and z < me[3] + 2.5 then
          out[#out + 1] = { u = u, kind = kind, x = x, y = y, z = z }
        end
      end
    end
  end
  return out
end

-- how far a unit points along the camera (1: the same way), and its forward
local function along(c, u)
  local fx, fy, fz = chef.unit_rotation(u)
  if type(fx) ~= 'number' then return nil end
  return fx * c.fx + fy * c.fy + fz * c.fz, fx, fy, fz
end

local function place(c, it)
  local hx, hy = heading(c)
  local dx, dy = it.x - me[1], it.y - me[2]
  local dot, fx, fy, fz = along(c, it.u)
  return string.format('ahead %.2f right %.2f up %.2f, points %s (%s along the camera)', dx * hx + dy * hy,
    dx * hy - dy * hx, it.z - me[3], fx and f3(fx, fy, fz) or '?', dot and string.format('%.3f', dot) or '?')
end

local node_cache = {}           -- kind -> { { name, index } }
local function nodes_of(u, kind)
  local found = node_cache[kind]
  if found then return found end
  found = {}
  for _, n in ipairs(NODES) do
    local i = chef.unit_node(u, n)
    if type(i) == 'number' then found[#found + 1] = { n, i } end
  end
  node_cache[kind] = found
  local names = {}
  for _, f in ipairs(found) do names[#names + 1] = f[1] .. '=' .. f[2] end
  log('  nodes of %s %s: %s', kind, name_of(kind), #names > 0 and table.concat(names, ' ') or 'none of the guesses')
  return found
end

local function log_nodes(c, it)
  for _, f in ipairs(nodes_of(it.u, it.kind)) do
    local x, y, z = chef.unit_position(it.u, f[2])
    local fx, fy, fz = chef.unit_rotation(it.u, f[2])
    if x then
      log('    node %s at %s (from the camera %s), points %s', f[1], f3(x, y, z), f3(x - c.x, y - c.y, z - c.z),
          type(fx) == 'number' and f3(fx, fy, fz) or '?')
    end
  end
end

local unnamed_said = ''         -- the unnamed kinds on me at the last report, sorted
local function report_hand(c, why, pose)
  local list = units_on_me()
  local named, unnamed_kinds = {}, {}
  for _, it in ipairs(list) do
    if WEAPONS[it.kind] then named[#named + 1] = it else unnamed_kinds[it.kind] = true end
  end
  log('%s: hand pose %s; %d units on me, %d named weapons', why, tostring(pose), #list, #named)
  for _, it in ipairs(named) do
    log('  weapon %s %s: %s', it.kind, WEAPONS[it.kind], place(c, it))
    if (along(c, it.u) or 0) > 0.8 then log_nodes(c, it) end
  end
  -- unnamed units pointing along the aim: a weapon filediver has no name for (or a part of one)
  for _, it in ipairs(list) do
    if not WEAPONS[it.kind] and (along(c, it.u) or 0) > 0.9 then
      log('  unnamed along the aim %s: %s', it.kind, place(c, it))
      log_nodes(c, it)
    end
  end
  local kinds = {}
  for k in pairs(unnamed_kinds) do kinds[#kinds + 1] = k end
  table.sort(kinds)
  local text = table.concat(kinds, ' ')
  if text ~= unnamed_said then
    unnamed_said = text
    log('  unnamed kinds on me now (%d): %s', #kinds, text)
  end
end

-- ------------------------------------------------------------------ shots
local base = setmetatable({}, { __mode = 'k' })     -- units there at the last look
local base_next = 0
local function take_base()
  for u in pairs(base) do base[u] = nil end
  for _, u in ipairs(all_units()) do base[u] = true end
end

local shots = 0
local shot = nil                -- the shot being looked after: { n, at, until_t, found }
local tracked = {}              -- { u, kind, n, until_t, next_t, last, still_since }

local function look_for_new(c)
  for _, u in ipairs(all_units()) do
    if not base[u] then
      base[u] = true
      if chef.unit_alive(u) then
        local kind = chef.unit_kind(u)
        if kind and kind ~= RUNTIME_BUILT then
          local x, y, z = chef.unit_position(u)
          if x then
            local d = math.sqrt((x - c.x) ^ 2 + (y - c.y) ^ 2 + (z - c.z) ^ 2)
            if d <= NEW_NEAR then
              shot.found = shot.found + 1
              log('shot %d +%.3f s: new unit %s %s at %s (%.2f m from the camera)', shot.n, now() - shot.at, kind,
                  name_of(kind), f3(x, y, z), d)
              if #tracked < TRACK_COUNT then
                tracked[#tracked + 1] = { u = u, kind = kind, n = shot.n, until_t = now() + TRACK_MOST, next_t = 0 }
              end
            end
          end
        end
      end
    end
  end
end

local function on_shot(c, pose, aiming)
  shots = shots + 1
  shot = { n = shots, at = now(), until_t = math.huge, found = 0 }
  local mx, my, mz = my_move()
  local hx, hy = heading(c)
  log('shot %d at %.3f: pose %s, aiming %s, camera %s fwd %.4f %.4f %.4f fov %s, feet %s, moving %s (%.2f ahead, %.2f right)',
      shots, shot.at, tostring(pose), tostring(aiming), f3(c.x, c.y, c.z), c.fx, c.fy, c.fz, tostring(c.fov),
      me and f3(me[1], me[2], me[3]) or 'nil', f3(mx, my, mz), mx * hx + my * hy, mx * hy - my * hx)
  report_hand(c, 'shot ' .. shots, pose)
end

local function follow()
  local t = now()
  local keep = {}
  for _, it in ipairs(tracked) do
    if t < it.until_t and chef.unit_alive(it.u) then
      keep[#keep + 1] = it
      if t >= it.next_t then
        it.next_t = t + TRACK_EVERY
        local x, y, z = chef.unit_position(it.u)
        if x then
          log('track %d %s t=%.3f %s', it.n, it.kind, t, f3(x, y, z))
          local l = it.last
          if l and math.abs(x - l[1]) + math.abs(y - l[2]) + math.abs(z - l[3]) < 0.01 then
            it.still_since = it.still_since or t
            if t - it.still_since >= 0.5 then
              log('track %d %s stopped at %s', it.n, it.kind, f3(x, y, z))
              keep[#keep] = nil
            end
          else
            it.still_since = nil
          end
          it.last = { x, y, z }
        end
      end
    elseif t < it.until_t then
      log('track %d %s t=%.3f gone', it.n, it.kind, t)
    else
      log('track %d %s t=%.3f still going after %d s', it.n, it.kind, t, TRACK_MOST)
    end
  end
  tracked = keep
end

-- ------------------------------------------------------------------ the frame
local said_world = nil
local was_left, was_right = false, false
local pose_seen, pose_since, pose_said = nil, 0, nil
local aim_since = nil

function M.update(dt)
  if said_world == nil then
    said_world = false
    local n = 0
    for _ in pairs(WEAPONS) do n = n + 1 end
    log('Weapon Probe %s, loader %s, api %s, %d weapon names', VERSION, tostring(chef.loader_version), tostring(chef.api), n)
  end
  local c = chef.camera()
  if not (chef.world() and c) then return end
  if said_world ~= chef.world_id() then
    said_world = chef.world_id()
    log('world %s (in_mission %s)', tostring(said_world), tostring(chef.in_mission()))
    mine, me, trail, tracked, shot, pose_seen, pose_said, aim_since, unnamed_said = nil, nil, {}, {}, nil, nil, nil, nil, ''
    base_next = 0
  end
  update_me(c)
  update_trail()
  local t = now()
  local pose = hand_pose()

  if pose ~= pose_seen then pose_seen, pose_since = pose, t end
  if pose_seen ~= pose_said and t - pose_since >= POSE_STEADY and me then
    pose_said = pose_seen
    report_hand(c, 'hand pose ' .. tostring(pose_seen), pose_seen)
  end

  local right = chef.mouse_down('right') == true
  if right and not was_right then aim_since = t end
  if not right then aim_since = nil end
  if aim_since and t - aim_since >= AIM_SETTLE and me then
    aim_since = nil
    report_hand(c, 'aiming', pose)
  end
  was_right = right

  local left = chef.mouse_down('left') == true
  if left and not was_left then on_shot(c, pose, right) end
  if shot and not left and was_left then shot.until_t = t + RELEASE_AFTER end
  was_left = left

  if shot then
    look_for_new(c)
    if t >= shot.until_t then
      log('shot %d: %d new units within %d m', shot.n, shot.found, NEW_NEAR)
      shot = nil
      base_next = 0
    end
  elseif t >= base_next then
    base_next = t + BASE_EVERY
    take_base()
  end
  follow()
end

function M.shutdown()
  log('bye')
end

return M
