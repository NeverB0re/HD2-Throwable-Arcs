-- HD2-Addon: mods/codex/engine_probe
-- HD2-Keep-On-Crash: yes
-- Engine Probe 0.2.1: a one-off test mod, not for release. Stage 0 of mods/throwable-arcs/PLAN.md. It writes to
-- engine_probe.log (in %APPDATA%\Arrowhead\Helldivers2):
--   always: what is in your hand while G (grenade) or ctrl + left mouse (stratagem) is held, and where a thrown one
--           goes for up to 4 s (every 0.05 s), with the camera at the throw and the terrain's height where it stops;
--   F5: draws a line from where you stand along your view, 60 m, until F5 again: red is chef.line, green is a line
--       object with depth testing off. Step sideways and look: is the red line hidden behind walls and ground?
--   F6: looks for terrain units and tries to read the terrain's height (Terrain.capture_offset, TerrainOffset.sample);
--   F7: reads the bounding boxes of units within 40 m (Unit.box) and casts your view against them
--       (Math.ray_box_intersection): which box, if any, is the thing you look at?
--   F8: tries AI.find_intersecting_units and ScatterSystem.offset_with_terrain (unknown arguments: may end the game, so
--       last; this file stays on after a crash, and only the crashing call is skipped from then on).
local chef = ...
local M = {}
local VERSION = '0.2.1'
local S = rawget(_G, 'stingray') or {}
local Vector3 = rawget(_G, 'Vector3') or S.Vector3
local Color = rawget(_G, 'Color') or S.Color

if chef.has and chef.has('own_log') then chef.own_log('engine_probe') end

local LOG_MOST = 30000          -- lines; tracking stops logging at LOG_MOST - 3000 so the F-key tests still fit
local lines = 0
local function log(fmt, ...)
  if lines >= LOG_MOST then return end
  lines = lines + 1
  chef.log(fmt, ...)
end
local function log_track(fmt, ...) if lines < LOG_MOST - 3000 then log(fmt, ...) end end

local RUNTIME_BUILT = '46cab355bd8d4d37'   -- asking where one is ends the game: never asked anything
-- kinds that sat at z = 0 and jumped hundreds of metres a frame in 0.1.0's log: not throwables
local NOISE = { ['620769fb47f74906'] = true, ['3f84fd1fde7713de'] = true }

local function now() return chef.time() end
local function fmt3(x, y, z) return string.format('%.2f %.2f %.2f', x, y, z) end
local function cam_text(c)
  if not c then return 'camera nil' end
  return string.format('camera %s fwd %.3f %.3f %.3f fov %s', fmt3(c.x, c.y, c.z), c.fx, c.fy, c.fz, tostring(c.fov))
end

-- ------------------------------------------------------------------ engine values as text
local function type_name(v)
  if type(v) ~= 'userdata' then return type(v) end
  local t = chef.call('Script.type_name', v)
  return type(t) == 'string' and t or 'userdata'
end

local function vec_text(v)
  local x, y, z = chef.call('Vector3.to_elements', v)
  if type(x) == 'number' then return '(' .. fmt3(x, y, z) .. ')' end
  return 'Vector3?'
end

local function value_text(v)
  local t = type_name(v)
  if t == 'Vector3' then return vec_text(v) end
  if t == 'Matrix4x4' then
    local p = chef.call('Matrix4x4.translation', v)
    return 'Matrix4x4 at ' .. (p and vec_text(p) or '?')
  end
  if t == 'IdString64' or t == 'IdString32' then
    local s = chef.call(t .. '.to_hex', v)
    return t .. ' ' .. tostring(s)
  end
  if type(v) == 'number' then return string.format('%.3f', v) end
  if t ~= type(v) then return t end
  return tostring(v)
end

local function values_text(...)
  local out = {}
  for i = 1, select('#', ...) do out[#out + 1] = value_text((select(i, ...))) end
  return table.concat(out, ', ')
end

-- one guarded try per argument shape, each under its own crash key, so a crash skips only that shape
local function try(name, tag, ...)
  local a, b, c, d = chef.call_kind(name, tag, ...)
  if a == nil then
    log('try %s [%s]: nil %s', name, tag, tostring(b))
  else
    log('try %s [%s]: %s', name, tag, values_text(a, b, c, d))
  end
  return a, b, c, d
end

-- ------------------------------------------------------------------ units
local function all_units()
  local w = chef.world()
  if not w then return {} end
  local units = chef.call('World.units', w)
  return type(units) == 'table' and units or {}
end

local function askable(u)
  if not chef.unit_alive(u) then return nil end
  local kind = chef.unit_kind(u)
  if not kind or kind == RUNTIME_BUILT then return nil end
  return kind
end

local named = {}                -- kind -> true once its names were logged
local function log_names(u, kind)
  if named[kind] then return end
  named[kind] = true
  local r = chef.call_kind('Unit.resource_name', kind, u)
  local h = chef.call_kind('Unit.name_hash', kind, u)
  local d = chef.call_kind('Unit.debug_name', kind, u)
  log('names %s: resource_name %s; name_hash %s; debug_name %s', kind, value_text(r), value_text(h), value_text(d))
end

-- a job that walks a list over frames: step(item) for `per` items a frame, then done()
local jobs = {}
local function spread(list, per, step, done)
  jobs[#jobs + 1] = { list = list, at = 1, per = per, step = step, done = done }
end
local function run_jobs()
  local left = {}
  for _, j in ipairs(jobs) do
    local stop = math.min(#j.list, j.at + j.per - 1)
    for i = j.at, stop do j.step(j.list[i]) end
    j.at = stop + 1
    if j.at > #j.list then if j.done then j.done() end else left[#left + 1] = j end
  end
  jobs = left
end

-- ------------------------------------------------------------------ terrain height (F6), once found
local sampler = nil             -- function(x, y, z) -> height or nil, once a shape worked

local function first_number(...)
  for i = 1, select('#', ...) do
    local v = select(i, ...)
    if type(v) == 'number' then return v end
    if type_name(v) == 'Vector3' then
      local _, _, z = chef.call('Vector3.to_elements', v)
      if type(z) == 'number' then return z end
    end
  end
end

local function test_terrain(u, kind, c)
  local ux, uy, uz = chef.unit_position(u)
  log('F6: terrain unit %s at %s', kind, ux and fmt3(ux, uy, uz) or '?')
  local terrain
  for i, args in ipairs({ { 1 }, { 0 }, {} }) do
    local t = try('Unit.terrain', 'shape' .. i, u, unpack(args))
    if type_name(t) == 'Terrain' then terrain = t; break end
  end
  if not terrain then log('F6: no Terrain from Unit.terrain'); return end
  try('Terrain.boundary_min_max', 'a', terrain)
  try('Terrain.data_id', 'a', terrain)
  local pos = Vector3(c.x, c.y, c.z)
  local offset
  local shapes = { { 'none', {} }, { 'pos', { pos } } }
  for _, s in ipairs(shapes) do
    local o = try('Terrain.capture_offset', s[1], terrain, unpack(s[2]))
    if type_name(o) == 'TerrainOffset' then offset = o; break end
  end
  if not offset then log('F6: no TerrainOffset from Terrain.capture_offset'); return end
  local sample_shapes = {
    { 'xy', function(x, y, z) return x, y end },
    { 'vec', function(x, y, z) return Vector3(x, y, z) end },
    { 'vec0', function(x, y, z) return Vector3(x, y, 0) end },
  }
  for _, s in ipairs(sample_shapes) do
    local h = first_number(try('TerrainOffset.sample', s[1], offset, s[2](c.x, c.y, c.z)))
    if h then
      log('F6: sample [%s] under the camera: %.2f (camera z %.2f: %.2f below)', s[1], h, c.z, c.z - h)
      -- ahead along the view, on the ground plane
      local fl = math.sqrt(c.fx * c.fx + c.fy * c.fy)
      if fl > 0.01 then
        for _, d in ipairs({ 5, 10, 20, 40 }) do
          local x, y = c.x + c.fx / fl * d, c.y + c.fy / fl * d
          log('F6: sample %d m ahead (%.2f %.2f): %s', d, x, y,
              tostring(first_number(chef.call_kind('TerrainOffset.sample', s[1], offset, s[2](x, y, c.z)))))
        end
      end
      local shape = s
      local w0 = chef.world_id()
      sampler = function(x, y, z)
        if chef.world_id() ~= w0 then return nil end
        return first_number(chef.call_kind('TerrainOffset.sample', shape[1], offset, shape[2](x, y, z)))
      end
      return
    end
  end
  log('F6: no shape of TerrainOffset.sample gave a number')
end

local function find_terrain()
  local c = chef.camera()
  if not c then log('F6: no camera'); return end
  log('F6: looking for terrain units; %s', cam_text(c))
  local per_kind, found, landscapes, runtime = {}, {}, 0, 0
  local units = all_units()
  spread(units, 600, function(u)
    if not chef.unit_alive(u) then return end
    local kind = chef.unit_kind(u)
    if kind == RUNTIME_BUILT then runtime = runtime + 1; return end
    if not kind or (per_kind[kind] or 0) >= 3 then return end
    per_kind[kind] = (per_kind[kind] or 0) + 1
    local n = chef.call_kind('Unit.num_terrains', kind, u)
    if type(n) == 'number' and n > 0 and #found < 3 then found[#found + 1] = { u = u, kind = kind, n = n } end
    local l = chef.call_kind('Unit.num_landscapes', kind, u)
    if type(l) == 'number' and l > 0 then
      landscapes = landscapes + 1
      log('F6: unit %s has %d landscapes', kind, l)
    end
  end, function()
    local kinds = 0
    for _ in pairs(per_kind) do kinds = kinds + 1 end
    log('F6: %d units, %d runtime-built (skipped), %d kinds checked; %d with terrain, %d with landscapes',
        #units, runtime, kinds, #found, landscapes)
    local cam = chef.camera()
    for _, f in ipairs(found) do
      log('F6: %s has %d terrains', f.kind, f.n)
      if not sampler and cam and chef.unit_alive(f.u) then test_terrain(f.u, f.kind, cam) end
    end
  end)
end

-- ------------------------------------------------------------------ boxes (F7)
local function find_boxes()
  local c = chef.camera()
  if not c then log('F7: no camera'); return end
  log('F7: boxes within 40 m; %s', cam_text(c))
  local cx, cy, cz, fx, fy, fz = c.x, c.y, c.z, c.fx, c.fy, c.fz
  local near, runtime, kinds = {}, 0, {}
  spread(all_units(), 800, function(u)
    if not chef.unit_alive(u) then return end
    local kind = chef.unit_kind(u)
    if kind == RUNTIME_BUILT then runtime = runtime + 1; return end
    if not kind then return end
    local x, y, z = chef.unit_position(u)
    if not x then return end
    local d = math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2 + (z - cz) ^ 2)
    if d <= 40 then near[#near + 1] = { u = u, kind = kind, d = d } end
  end, function()
    table.sort(near, function(a, b) return a.d < b.d end)
    while #near > 300 do near[#near] = nil end
    local boxed, hits, big, first = 0, {}, {}, true
    spread(near, 40, function(it)
      if not chef.unit_alive(it.u) then return end
      local pose, radius = chef.call_kind('Unit.box', it.kind, it.u)
      if type_name(pose) ~= 'Matrix4x4' or type_name(radius) ~= 'Vector3' then
        if first then log('F7: Unit.box on %s gave %s', it.kind, values_text(pose, radius)); first = false end
        return
      end
      boxed = boxed + 1
      kinds[it.kind] = (kinds[it.kind] or 0) + 1
      local ex, ey, ez = chef.call('Vector3.to_elements', radius)
      if type(ex) == 'number' then big[#big + 1] = { kind = it.kind, d = it.d, size = ex * ey * ez, text = fmt3(ex, ey, ez),
                                                       at = value_text(pose) } end
      local hit = chef.call('Math.ray_box_intersection', Vector3(cx, cy, cz), Vector3(fx, fy, fz), pose, radius)
      if type(hit) == 'number' and hit >= 0 then hits[#hits + 1] = { kind = it.kind, hit = hit, size = ex and fmt3(ex, ey, ez) } end
    end, function()
      local nk = 0
      for _ in pairs(kinds) do nk = nk + 1 end
      log('F7: %d units within 40 m, %d boxes read (%d kinds); %d runtime-built units in the world (not asked)',
          #near, boxed, nk, runtime)
      table.sort(hits, function(a, b) return a.hit < b.hit end)
      for i = 1, math.min(10, #hits) do
        log('F7: view hits box of %s at %.2f m (half size %s)', hits[i].kind, hits[i].hit, tostring(hits[i].size))
      end
      if #hits == 0 then log('F7: the view hits no box') end
      table.sort(big, function(a, b) return a.size > b.size end)
      for i = 1, math.min(10, #big) do
        log('F7: big box %s, half size %s, %.1f m away, %s', big[i].kind, big[i].text, big[i].d, big[i].at)
      end
    end)
  end)
end

-- ------------------------------------------------------------------ unknown calls (F8)
local function risky_calls()
  local c, w = chef.camera(), chef.world()
  if not (c and w) then log('F8: no camera or world'); return end
  log('F8: %s', cam_text(c))
  local from = Vector3(c.x, c.y, c.z)
  local to = Vector3(c.x + c.fx * 30, c.y + c.fy * 30, c.z + c.fz * 30)
  local r = try('AI.find_intersecting_units', 'world_from_to', w, from, to)
  if type(r) == 'table' then log('F8: AI.find_intersecting_units gave %d entries', #r) end
  local ss = try('World.scatter_system', 'a', w)
  if type_name(ss) == 'ScatterSystem' then try('ScatterSystem.offset_with_terrain', 'pos', ss, from) end
end

-- ------------------------------------------------------------------ depth test lines (F5)
local depth_line = nil          -- { x1, y1, z1, x2, y2, z2 } while shown
local own_lines, own_world = nil, nil

local function draw_depth_line()
  if not depth_line then return end
  local p = depth_line
  chef.line(p[1], p[2], p[3], p[4], p[5], p[6], chef.color(255, 40, 40, 255))
  local w = chef.world()
  if not w then return end
  if own_world ~= chef.world_id() then
    own_lines, own_world = chef.call('World.create_line_object', w, true), chef.world_id()
    log('F5: own line object (depth test off): %s', value_text(own_lines))
  end
  if not own_lines then return end
  chef.call('LineObject.reset', own_lines)
  chef.call('LineObject.add_line', own_lines, Color(40, 255, 40),
            Vector3(p[1], p[2], p[3] + 0.2), Vector3(p[4], p[5], p[6] + 0.2))
  chef.call('LineObject.dispatch', w, own_lines)
end

local function toggle_depth_line()
  if depth_line then depth_line = nil; log('F5: line off'); return end
  local c = chef.camera()
  if not c then log('F5: no camera'); return end
  local x, y, z = c.x, c.y, c.z - 0.5
  depth_line = { x, y, z, x + c.fx * 60, y + c.fy * 60, z + c.fz * 60 }
  log('F5: line on, from %s along %.3f %.3f %.3f', fmt3(x, y, z), c.fx, c.fy, c.fz)
end

-- ------------------------------------------------------------------ in hand and thrown
local base = setmetatable({}, { __mode = 'k' })     -- units there before the key went down
local tracked = {}              -- { u, kind, until_t, next_t, last = {x,y,z}, still_since }
local scans = {}                -- { at, r, why, track, hold }
local holding = {}              -- 'g' / 'stratagem' -> true while held
local last_ctrl = -100

local function take_base()
  for u in pairs(base) do base[u] = nil end
  local n = 0
  for _, u in ipairs(all_units()) do base[u] = true; n = n + 1 end
  return n
end

local function is_tracked(u)
  for _, t in ipairs(tracked) do if t.u == u then return true end end
  return false
end

local function scan(s)
  if s.hold and not holding[s.hold] then return end
  local c = chef.camera()
  if not c then return end
  local found = 0
  for _, u in ipairs(all_units()) do
    if not base[u] then
      local kind = askable(u)
      if kind and not NOISE[kind] then
        local x, y, z = chef.unit_position(u)
        if x then
          local d = math.sqrt((x - c.x) ^ 2 + (y - c.y) ^ 2 + (z - c.z) ^ 2)
          if d <= s.r then
            found = found + 1
            log('%s: new unit %s at %s (%.2f m)', s.why, kind, fmt3(x, y, z), d)
            log_names(u, kind)
            if s.track and not is_tracked(u) and #tracked < 6 then
              tracked[#tracked + 1] = { u = u, kind = kind, until_t = now() + 4, next_t = 0 }
            end
          end
        end
      end
    end
  end
  log('%s: %d new units within %.0f m; %s', s.why, found, s.r, cam_text(c))
end

local function on_key(name, down)
  local t = now()
  log('%s %s at %.3f; %s', name, down and 'down' or 'up', t, cam_text(chef.camera()))
  if name == 'left ctrl' and down then
    last_ctrl = t
    log('base: %d units', take_base())
    return
  end
  local what = (name == 'g' and 'g') or (name == 'mouse left' and t - last_ctrl < 10 and 'stratagem') or nil
  if not what then return end
  if down then
    holding[what] = true
    if what == 'g' then log('base: %d units', take_base()) end
    for _, dt in ipairs({ 0.15, 0.4, 0.8 }) do
      scans[#scans + 1] = { at = t + dt, r = 3, why = what .. ' held ' .. dt .. ' s', hold = what }
    end
  else
    holding[what] = false
    for _, dt in ipairs({ 0.05, 0.1, 0.2 }) do
      scans[#scans + 1] = { at = t + dt, r = 10, why = what .. ' released +' .. dt .. ' s', track = true }
    end
  end
end

local function follow()
  local t = now()
  local keep = {}
  for _, it in ipairs(tracked) do
    if t < it.until_t and chef.unit_alive(it.u) then
      keep[#keep + 1] = it
      if t >= it.next_t then
        it.next_t = t + 0.05
        local x, y, z = chef.unit_position(it.u)
        if x then
          log_track('track %s t=%.3f pos %s', it.kind, t, fmt3(x, y, z))
          local l = it.last
          if l and math.abs(x - l[1]) + math.abs(y - l[2]) + math.abs(z - l[3]) < 0.01 then
            it.still_since = it.still_since or t
            if t - it.still_since >= 0.5 then
              local h = sampler and sampler(x, y, z)
              log('track %s stopped at %s; terrain there %s', it.kind, fmt3(x, y, z),
                  h and string.format('%.2f (%.2f below it)', h, z - h) or 'unknown')
              it.until_t = 0
              keep[#keep] = nil
            end
          else
            it.still_since = nil
          end
          it.last = { x, y, z }
        end
      end
    elseif t < it.until_t then
      log('track %s t=%.3f gone', it.kind, t)
    end
  end
  tracked = keep
end

-- ------------------------------------------------------------------ the frame
local KEYS = { 'g', 'left ctrl' }
local was = {}
local said_world = nil

function M.update(dt)
  if said_world == nil then
    said_world = false
    log('Engine Probe %s, loader %s, api %s', VERSION, tostring(chef.loader_version), tostring(chef.api))
  end
  -- not gated on chef.in_mission(): 0.2.0's second mission was taken for "not a mission" and the probe slept there
  if not (chef.world() and chef.camera()) then return end
  if said_world ~= chef.world_id() then
    said_world = chef.world_id()
    log('world %s (in_mission %s); %s', tostring(said_world), tostring(chef.in_mission()), cam_text(chef.camera()))
    tracked, scans, jobs, holding, sampler, depth_line = {}, {}, {}, {}, nil, nil
  end
  for _, k in ipairs(KEYS) do
    local d = chef.key_down(k) == true
    if d ~= (was[k] or false) then was[k] = d; on_key(k, d) end
  end
  local d = chef.mouse_down('left') == true
  if d ~= (was['mouse left'] or false) then was['mouse left'] = d; on_key('mouse left', d) end

  if chef.key_pressed('f5') then toggle_depth_line() end
  if chef.key_pressed('f6') then find_terrain() end
  if chef.key_pressed('f7') then find_boxes() end
  if chef.key_pressed('f8') then risky_calls() end

  local t, left = now(), {}
  for _, s in ipairs(scans) do
    if t >= s.at then scan(s) else left[#left + 1] = s end
  end
  scans = left
  follow()
  run_jobs()
  draw_depth_line()
end

function M.shutdown()
  local w = chef.world()
  if own_lines and w and own_world == chef.world_id() then chef.call('World.destroy_line_object', w, own_lines) end
  log('bye')
end

return M
