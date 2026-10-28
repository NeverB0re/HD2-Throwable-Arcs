-- HD2-Addon: mods/codex/throwable_arcs
-- Stratagem and C4 Trajectory (Throwable Arcs until 1.0.1): while a stratagem ball is in my hand and left mouse is held, or C4 is aimed with right mouse, draws
-- where it will fly. The arc is a world line: the game hides it behind walls and ground, so where it goes into the
-- ground is where it lands (the terrain can't be asked). Below native Render Scale the game clips the 3D scene's drawing
-- to a corner of the screen when the game's anti-aliasing is off (with it on, it shows whole). The numbers are measured
-- from real throws (mods/throwable-arcs/PLAN.md, section 6-1). Grenades aren't drawn: which one is in the hand can't be
-- told before it is thrown.
-- C4's hand pose and mode are read as NarrowHUD by luka189 reads them (Nexus 17882); the armour table comes from HD2
-- Transmog's catalog (Nexus 16633).
local chef = ...
local M = {}
local VERSION = '1.1.0-test.19'

if chef.has and chef.has('own_log') then chef.own_log('throwable_arcs') end
local function log(fmt, ...) chef.log(fmt, ...) end

local STRATAGEM_BALL = '16f397ca5f51f271'
-- A ball is let go RELEASE_UP m above where it is held in the aim (the arm swings up), heading as the camera looks,
-- LIFT above its pitch, at SPEED: fitted on 24 measured throws along 1-40 m of their flight (test.18-30; prone ones fit
-- within 0.3 m). Until 1.0.0 the arc started at the ball and eased into a path from the camera (9 degrees up), which
-- fit far throws but was off near ones.
local SPEED, LIFT, RELEASE_UP, GRAVITY = 22, math.rad(7.8), 0.4, 9.81
local STEP = 0.03                -- seconds per arc segment
local MOST_T = 6                 -- seconds of flight drawn at most
local DEEPEST = 15               -- m under my feet the arc goes at most (it is hidden under the ground anyway)
-- a stratagem ball in my hand: within HAND m of my helldiver across, HAND_LOW to HAND_HIGH m above its feet (held balls
-- in test.10-12, standing: 0.36-0.54 m across, 0.74-1.30 m up; crouched or prone it is lower, down to the ground).
-- Without my helldiver: within 6 m of the camera, at most 1.5 m under it.
local HAND, HAND_LOW, HAND_HIGH = 1.2, -0.3, 2.2
-- while aiming, the ball must stay this close (the swing moves it): gone, the arc goes at once. test.18 kept the arc
-- up until left was let go, so a stratagem put away and a shot straight after drew it for a moment
local KEEP, KEEP_LOW, KEEP_HIGH = 2, -0.5, 2.8

local PLAYER = '4d1c334d294dfa97'

local now = function() return chef.time() end
local function camera_pitch(c) return math.atan2(c.fz, math.sqrt(c.fx * c.fx + c.fy * c.fy)) end

-- ------------------------------------------------------------------ my feet
local players = chef.watch and chef.watch({ [PLAYER] = true }, 2)
local feet_z, me = nil, nil      -- me: { x, y, z } of my helldiver (its feet)
local me_unit = nil              -- my helldiver's unit
-- Mine is the helldiver nearest the camera within 6 m across; once found it is kept while it is within KEEP_ME m: a
-- vehicle's camera is farther off (1.0.1-test.2 lost me in a passenger seat, aiming up), and others sit nearer to it.
local KEEP_ME = 15
local mine = nil

local function update_feet(c)
  feet_z, me, me_unit = nil, nil, nil
  if not players then return end
  if mine and chef.unit_alive(mine) then
    local x, y, z = chef.unit_position(mine)
    if x and (x - c.x) ^ 2 + (y - c.y) ^ 2 < KEEP_ME * KEEP_ME then
      feet_z, me, me_unit = z, { x, y, z }, mine
      return
    end
  end
  mine = nil
  local best
  for _, it in ipairs(players.items) do
    if chef.unit_alive(it.unit) then
      local x, y, z = chef.unit_position(it.unit)
      if x then
        local d = (x - c.x) ^ 2 + (y - c.y) ^ 2
        if d < 36 and (not best or d < best) then best, feet_z, me, me_unit = d, z, { x, y, z }, it.unit end
      end
    end
  end
  mine = me_unit
end

-- My velocity, from my feet over the last MOVE_OVER s. A throw is faster by CARRY times my speed along where I aim, up
-- to CARRY_MOST m/s either way, and gets none of it across (1.0.3-test.1 to 6, 36 throws: walking forward throws
-- farther and higher, running no farther than walking, strafing no wider; 8 C4 throws walking at 2.2 m/s carried
-- 1.30-1.47 times it).
local MOVE_OVER, CARRY, CARRY_MOST = 0.15, 1.4, 3
local trail = {}                 -- my feet: { t, x, y, z }, the last MOVE_OVER s and a bit

local function update_trail()
  if not me then trail = {} return end
  local t = now()
  trail[#trail + 1] = { t, me[1], me[2], me[3] }
  while #trail > 2 and t - trail[2][1] >= MOVE_OVER do table.remove(trail, 1) end
end

local function my_move()
  local a, b = trail[1], trail[#trail]
  if not (a and b and b[1] - a[1] > 0.02) then return 0, 0, 0 end
  local dt = b[1] - a[1]
  return (b[2] - a[2]) / dt, (b[3] - a[3]) / dt, (b[4] - a[4]) / dt
end

-- ------------------------------------------------------------------ my armour (the throw-range perks)
-- Servo-Assisted armours throw 30% farther, Desert Stormer ones 20%. The armour is told from the units on my helldiver
-- when aiming begins: the armour in the table (src/armour_table.lua, from HD2 Transmog's catalog) with the largest
-- share of its units there, at least ARMOUR_SHARE. It takes one pass over all the world's units (about 3 ms), so it is
-- done once for my helldiver (a mission's armour doesn't change; a new helldiver after a respawn is looked at again),
-- or again at the next aim while none was found.
-- The throw speed, as measured (not the square root of the range bonus: test.26 drew Servo-Assisted throws at 25.1 m/s,
-- they flew 25.5-26.8): stratagem balls 1.1x with Desert Stormer (test.17: 24.0-24.2 m/s of 22), 1.2x with
-- Servo-Assisted (test.26: 25.5-26.8, about 26.5); C4 1.3x with Servo-Assisted (test.26: about 29 of 22.4), and 1.2x with
-- Desert Stormer (test.28: 26.8).
local SPEED_UP = { [20] = { 1.1, 1.2 }, [30] = { 1.2, 1.3 } }   -- range bonus in % -> { stratagem, C4 }
-- A look mod can put another armour's units on me. HD2 Transmog spawns copies of the look and hides my own armour's
-- units (they stay on me): its TransmogUI.worn('armor') lists my own, so with it running those are used. Another
-- such mod leaves two whole armours on me: when they differ in range, it can't be told which is mine (no bonus then).
local ARMOUR = "@ARMOUR@"
local ARMOUR_SHARE = 0.6
local armour_rows, armour_kinds = {}, {}   -- rows: { name, bonus, size }; kinds: kind -> row indices
for i, row in ipairs(type(ARMOUR) == 'table' and ARMOUR or {}) do
  local n = 0
  for kind in row[3]:gmatch('%x+') do
    n = n + 1
    armour_kinds[kind] = armour_kinds[kind] or {}
    table.insert(armour_kinds[kind], i)
  end
  armour_rows[i] = { name = row[1], bonus = row[2], size = n }
end
local throw_bonus, said_armour = 0, nil
local armour_of = nil            -- the helldiver the armour was told for

local function speed_up(c4)
  local f = SPEED_UP[math.floor(throw_bonus * 100 + 0.5)]
  return f and f[c4 and 2 or 1] or 1
end

-- my own armour's unit kinds from HD2 Transmog, or nil without it (or when it has no avatar of mine)
local function transmog_kinds()
  local ok, T = pcall(function() return TransmogUI end)
  if not ok or type(T) ~= 'table' or type(T.worn) ~= 'function' then return nil end
  local done, units = pcall(T.worn, 'armor')
  if not done or type(units) ~= 'table' or #units == 0 then return nil end
  local kinds = {}
  for _, u in ipairs(units) do
    local k = chef.unit_kind(u)
    if k then kinds[k] = true end
  end
  return next(kinds) and kinds or nil
end

-- the armour units on my helldiver: kind -> true
local function kinds_on_me()
  local w = chef.world()
  local units = w and chef.call('World.units', w)
  if type(units) ~= 'table' then return nil end
  local kinds = {}
  for _, u in ipairs(units) do
    local kind = chef.unit_alive(u) and chef.unit_kind(u)
    if kind and not kinds[kind] and armour_kinds[kind] then
      local x, y, z = chef.unit_position(u)
      if x and (x - me[1]) ^ 2 + (y - me[2]) ^ 2 < 2.25 and z > me[3] - 0.5 and z < me[3] + 2.5 then kinds[kind] = true end
    end
  end
  return kinds
end

local function find_armour()
  if not me or (me_unit and me_unit == armour_of) then return end
  local from = 'Transmog'
  local kinds = transmog_kinds()
  if not kinds then kinds, from = kinds_on_me(), 'on me' end
  if not kinds then return end
  local hits = {}
  for kind in pairs(kinds) do
    for _, i in ipairs(armour_kinds[kind] or {}) do hits[i] = (hits[i] or 0) + 1 end
  end
  local best, bi, whole = ARMOUR_SHARE, nil, {}   -- whole: the bonuses of armours all of whose units are there
  for i, row in ipairs(armour_rows) do
    local share = (hits[i] or 0) / row.size
    if share > best or (share == best and not bi) then best, bi = share, i end
    if share >= 0.95 then whole[row.bonus] = row.name end
  end
  local two = nil
  for b, n in pairs(whole) do if bi and b ~= armour_rows[bi].bonus then two = n end end
  throw_bonus = bi and not two and armour_rows[bi].bonus or 0
  if bi then armour_of = me_unit end
  local name = bi and armour_rows[bi].name or 'none of the table'
  if two then name = name .. ' and ' .. two .. ' (a look mod? no bonus)' end
  name = name .. ' [' .. from .. ']'
  if name ~= said_armour then
    said_armour = name
    log('armour: %s%s, throw range +%d%%', name, bi and string.format(' (%d%% of its units)', best * 100 + 0.5) or '',
        throw_bonus * 100 + 0.5)
  end
end

-- ------------------------------------------------------------------ the buttons
-- The throw and the aim are the mouse's left and right buttons, and (1.0.4) a controller's right and left triggers: the
-- game's default layouts. Buttons rebound in the game aren't followed (they are buttons to the mod, not the game's
-- actions). The controller: the first of the engine's Pad1 to Pad8 that is active or connected, as Chef Shared Loader
-- finds its menu's, looked at again every PAD_LOOK s; its triggers by the names it lists itself. Only its number and
-- button indexes are kept between frames. Not tried on a real controller before 1.0.4's release.
local PAD_LOOK = 1
local PAD_THROW, PAD_AIM = { 'right_trigger', 'r2' }, { 'left_trigger', 'l2' }
local pad = { n = nil, button = nil, throw = nil, aim = nil, next = 0, said = nil }
local throw_down, aim_down = false, false      -- this frame's

local function find_pad()
  if pad.n then
    local p = 'Pad' .. pad.n
    if chef.call(p .. '.active') == true or chef.call(p .. '.connected') == true then return end
    pad.n, pad.button, pad.throw, pad.aim = nil, nil, nil, nil
  end
  for n = 1, 8 do
    local p = 'Pad' .. n
    if chef.call(p .. '.active') == true or chef.call(p .. '.connected') == true then
      local count, by, names = chef.call(p .. '.num_buttons'), {}, {}
      if type(count) == 'number' and count > 0 and count <= 64 then
        for i = 0, count - 1 do
          local nm = chef.call(p .. '.button_name', i)
          if type(nm) == 'string' and nm ~= '' then by[nm:lower()] = i; names[#names + 1] = nm:lower() end
        end
      end
      local function first(list) for _, nm in ipairs(list) do if by[nm] then return by[nm] end end end
      pad.n, pad.button, pad.throw, pad.aim = n, p .. '.button', first(PAD_THROW), first(PAD_AIM)
      local said = p .. (pad.throw and pad.aim and ', triggers found'
                         or ', no triggers among: ' .. table.concat(names, ' '))
      if said ~= pad.said then pad.said = said; log('controller: %s', said) end
      return
    end
  end
end

local function pad_down(i)
  if not (pad.button and i) then return false end
  local v = chef.call(pad.button, i)
  return type(v) == 'number' and v > 0.5
end

local function read_buttons()
  if now() >= pad.next then
    pad.next = now() + PAD_LOOK
    find_pad()
  end
  throw_down = chef.mouse_down('left') == true or pad_down(pad.throw)
  aim_down = chef.mouse_down('right') == true or pad_down(pad.aim)
end

-- ------------------------------------------------------------------ aiming
-- The balls come from a watch on their kind, always on: the loader asks the engine for that kind only, about 0.1 ms
-- every 0.5 s (test.13-17 ran it only after the stratagem key, which players who moved that key had to set in the
-- options; test.12 and before passed over every unit, 2.6-3.4 ms). A left click asks for a fresh list and looks for a
-- ball in hand for BALL_SCAN_FOR s; none, it is a shot.
local BALL_SCAN_FOR = 1
local ball_watch = chef.watch and chef.watch({ [STRATAGEM_BALL] = true }, 0.5)
local held_since = 0
local was_left, aiming, ball = false, false, nil
local looking = false

-- the nearest stratagem ball in my hand, or nil
local function ball_in_hand(c)
  if not ball_watch then return nil end
  local best, bu
  for _, it in ipairs(ball_watch.items) do
    local u = it.unit
    if chef.unit_alive(u) then
      local x, y, z = chef.unit_position(u)
      if x then
        local d
        if me then
          local across, up = math.sqrt((x - me[1]) ^ 2 + (y - me[2]) ^ 2), z - me[3]
          if across <= HAND and up >= HAND_LOW and up <= HAND_HIGH then d = across end
        elseif z >= c.z - 1.5 then
          d = math.sqrt((x - c.x) ^ 2 + (y - c.y) ^ 2 + (z - c.z) ^ 2)
          if d > 6 then d = nil end
        end
        if d and (not best or d < best) then best, bu = d, u end
      end
    end
  end
  return bu
end

-- is the ball still in my hand (loosely)?
local function still_in_hand(u)
  if not (u and chef.unit_alive(u)) then return false end
  local x, y, z = chef.unit_position(u)
  if not x then return false end
  if not me then return true end
  local up = z - me[3]
  return (x - me[1]) ^ 2 + (y - me[2]) ^ 2 <= KEEP * KEEP and up >= KEEP_LOW and up <= KEEP_HIGH
end

-- A ball in hand while its code is still going in (unlit) is held in front of me; once the code is in (lit), standing
-- or crouched, it is pulled back for the throw (test.21: from 0.2-0.4 m ahead of my feet to 0 to -0.3 m, within 0.3 s;
-- a put-away ball isn't). So a ball counts as ready once it was seen pulled back READY_PULL m or more, within
-- READY_WINDOW s, to under READY_AHEAD m ahead, while left was up: test.18-20 drew the arc for a ball still waiting for
-- its code (left during code entry, or a shot right after putting it away).
-- With left already held when the code goes in, there is no pull-back: the ball goes straight up into the aim, about
-- 0.2 m above where it was (test.22, standing: 1.25 -> 1.47 m above my feet; test.21, crouched +0.15-0.3, prone
-- +0.2-0.5). So while left is held with a ball in hand that isn't ready, it becomes the aim once it rose RAISE m above
-- its height when left went down; it is watched as long as left is held and it stays in hand.
-- Right mouse aims a ball too (1.0.1): held like left, the throw still being left's release.
local READY_PULL, READY_AHEAD, READY_WINDOW, RAISE = 0.15, 0.05, 0.5, 0.15
local pending, pending_up = nil, nil   -- a ball in hand with left held, not ready yet, and its height then
local ready_ball, pose = nil, { list = {} }   -- pose: the ball in hand while left is up, and where it was ({ t, ahead })

local function ball_ahead(c, u)
  local x, y, z = chef.unit_position(u)
  if not (x and me) then return nil end
  local fh = math.sqrt(c.fx * c.fx + c.fy * c.fy)
  if fh < 1e-6 then return nil end
  return ((x - me[1]) * c.fx + (y - me[2]) * c.fy) / fh, z - me[3]
end

local function watch_pose(c)
  local u = ball_in_hand(c)
  if u ~= pose.u then pose, ready_ball = { u = u, list = {} }, nil end
  if not u then return end
  local ahead = ball_ahead(c, u)
  if not ahead then return end
  local t, list = now(), pose.list
  list[#list + 1] = { t, ahead }
  while #list > 1 and t - list[1][1] > READY_WINDOW do table.remove(list, 1) end
  local most = ahead
  for _, e in ipairs(list) do if e[2] > most then most = e[2] end end
  if ahead < READY_AHEAD and most - ahead >= READY_PULL and ready_ball ~= u then
    ready_ball = u
  end
end


local was_hold = false

-- After the throw is let go (left released with a ball, left pressed with C4 aimed) the arc stays up until it leaves my
-- hand (1.0.3; the swing takes a moment): it keeps following the camera, from where the hand was then, kept by my feet.
-- It ends when the ball is HOLD_GONE m or more from there, or after HOLD_MOST s. C4's hold just lasts C4_HOLD s: the
-- charge leaves the hand about then (1.0.3-test.2, fitted back from its flight), but the game lists a new charge only
-- every half second or so, too late to end the arc on.
local HOLD_MOST, HOLD_GONE, C4_HOLD = 0.6, 1.5, 0.15
local hold = nil                 -- { c4, unit, off = { from my feet }, at, pos }

local function start_hold(unit, c4)
  local x, y, z
  if unit and chef.unit_alive(unit) then x, y, z = chef.unit_position(unit) end
  if not x then hold = nil return end
  hold = { c4 = c4, unit = unit, at = now(), pos = { x, y, z },
           off = me and { x - me[1], y - me[2], z - me[3] } or nil }
end

local function read_input(c)
  local t = now()
  local left = throw_down
  local down = left or aim_down
  if not left then watch_pose(c) end
  if down and not was_hold then
    held_since, looking = t, true
    if ball_watch then ball_watch.refresh() end
  end
  local held = false
  if was_left and not left and aiming then
    start_hold(ball, false)
    ball, ready_ball, looking = nil, nil, false   -- thrown
  elseif down then
    if aiming then
      held = still_in_hand(ball)
      if not held then ball, looking = nil, false end
    elseif pending then
      if not still_in_hand(pending) then
        pending, looking = nil, false        -- put away: a shot
      else
        local _, up = ball_ahead(c, pending)
        if pending == ready_ball or (up and up - pending_up >= RAISE) then
          ball, pending, held = pending, nil, true
          find_armour()
        end
      end
    elseif looking then
      local u = ball_in_hand(c)
      if u and u == ready_ball then
        ball, held = u, true
        find_armour()
      elseif u then
        local _, up = ball_ahead(c, u)
        pending, pending_up = u, up or 0     -- not ready (code still going in?): watched for the raise into the aim
      elseif t - held_since > BALL_SCAN_FOR then
        looking = false                      -- no ball in hand: a shot
      end
    end
  end
  if not down then pending = nil end
  was_left, was_hold = left, down
  aiming = held
end

-- ------------------------------------------------------------------ C4
-- C4 is aimed with right mouse (left alone throws it at once): right held with C4 in my hand is the aim; it ends at
-- left (the throw) or when right is let go. Which weapon is in my hand: my helldiver's hand pose, the animation
-- variable weapon_selected, as NarrowHUD (luka189, Nexus 17882) reads it: C4_GRIP for C4 (its learned table: 42).
-- Without that variable, no C4 arc (until 1.0.2 the detonator's place alone told it then; 1.0.3 after a report of an
-- arc while aiming the Censor rifle). The aim pose is told by the detonator's unit (filediver: equipment/backpacks/
-- c4_charge_backpack/c4_charge_detonator; its charge is no unit until it flies, and my helldiver's 1 mesh never
-- changes, test.24-25), held in my right hand (test.25, standing: about 0 ahead, 0.4 right, 1.05 up from my feet):
-- right held it goes forward into the aim within 0.3 s, from about 0.40 m from my feet across to 0.53-0.55 m, not above
-- C4_HIGH m (the throw raises it to 2.05-2.11 m). The hand pose alone isn't the aim (1.0.1): putting C4 away while
-- aiming kept the pose a moment and drew the arc, and right in a vehicle's driver seat (no aiming there) drew it as
-- well. The aim pose: the detonator C4_PUSH m or more farther from
-- my feet (across) than it was nearest since right went down; kept while it stays C4_KEEP m or more farther. Its
-- distance, not how far ahead along the camera's heading (1.0.1-test.1): turning fast, my helldiver turns after the
-- camera, and seated in a vehicle it faces the vehicle's way, and the arc came and went with the heading.
-- After a throw, no arc for C4_REARM s: test.28 drew it again 0.2-0.3 s after each throw, from the arm still swinging
-- (0.8 ahead, 1.3-1.6 m up).
-- The charge is let go C4_RELEASE_UP m above the detonator in the aim pose (the arm swings up and throws from higher),
-- at about 22.4 m/s, C4_LIFT above the camera's pitch: fitted on 5 measured throws (test.26-30), 0.1 m off along 1-40 m.
local C4_DET = '51f50d6321f52f3d'
local C4_SPEED, C4_LIFT, C4_RELEASE_UP = 22.4, math.rad(4.4), 1.0
local C4_PUSH, C4_KEEP, C4_HIGH = 0.1, 0.05, 1.6
-- Leaning out of a vehicle's window to aim, the detonator gets 1.15-1.2 m from my feet across (1.0.1-test.2): its hand
-- reaches C4_HAND m. Prone (0.06-0.46 m above my feet), crouched (0.56-0.69 m) and sliding on my knees (0.55-0.58 m)
-- it is under C4_LOW_UP m and right moves it little or not at all (1.0.1-test.2-4; standing it is 0.82 m up or more):
-- there, C4 in hand (the hand pose) and right held is the aim. Not in a vehicle: in the driver's seat it is 0.46 m up
-- (test.4 drew the arc there).
-- Diving, the hand pose reads 40 (as with a grenade) while the detonator lies low on my left (1.0.1-test.3): within
-- C4_DIVE s of C4's pose, 40 counts as C4 with the detonator under C4_PRONE_UP m, or while an aim goes on (in the air
-- it flickers, test.4). An aim that stops being one is kept C4_GRACE s, for such moments.
-- Seated in a vehicle, aiming behind brings the detonator in to 0.1-0.2 m from my feet (1.0.1-test.3): there an aim
-- once begun (leaning out moves it outward; in the driver's seat it never begins) is kept while right is held and C4 is
-- in hand.
-- On a tank's top seat it already sits 0.45 m off my feet and stays there; aiming raises it instead, from 0.59 to
-- 1.08-1.21 m (1.0.1-test.9): risen C4_RAISE m or more above its lowest since right went down is the aim pose too.
local C4_HAND, C4_LOW_UP, C4_PRONE_UP, C4_DIVE, DIVE_GRIP, C4_GRACE, C4_RAISE = 1.6, 0.75, 0.5, 2, 40, 0.25, 0.3
local c4_ready_at = -100
local c4_grip_at, grip_next = -100, 0   -- when C4's hand pose was last seen, and is next looked at with right up
local in_vehicle                 -- function() below (the icon's)
local C4_GRIP, C4_REARM = 42, 0.8
local c4_rearm = 0
local det_watch = chef.watch and chef.watch({ [C4_DET] = true }, 0.5)
local was_right, c4_aim, c4_det, c4_least, c4_low = false, false, nil, nil, nil
local c4_posed = false           -- in C4's aim pose (DEPLOY or DETONATE alike; c4_aim: and the arc drawn)

-- C4's mode: DEPLOY (a charge in hand, thrown) or DETONATE (the detonator in hand; right drew the arc there too in
-- test.27). Read as NarrowHUD (luka189, Nexus 17882) reads it: the C4 is a network game object of mine, of the type
-- C4_TYPE (a stand-in name with the same 32-bit hash as the real one, type 6b2c3bed, from the game's network config),
-- and its options field (C4_OPTIONS) holds the mode in the bits at 256 (80 deploy, 336 detonate). In someone else's
-- game the host may own it: the host's C4 objects whose owner field (C4_OWNER) is me count too. Only the one I carry
-- (its carry field, C4_CARRY, a multiple of 4: NarrowHUD's rule): a detonator swapped for another one stays mine where
-- it was dropped, and 1.0.0 kept reading it. The object is looked for when right goes down or for the icon (at most
-- every C4_SCAN s while none is found) and kept while I carry it; before each read it must still exist and be that
-- type (reading a gone object's field can end the game, NarrowHUD's notes). Not readable (a game patch, a Chef that
-- refuses the calls): the arc shows in either mode, and no icon.
local C4_TYPE, C4_OPTIONS, C4_OWNER, C4_CARRY = 'kbv6zx', 'ozvglfc', 'g5g7b9d', 'n5jmvf'
local C4_SCAN = 2
local c4_obj = { goid = nil, world = nil, next = 0 }

-- 1.1.0: a network field is read only when the game declares it for that type now (Network.object_info, as NarrowHUD
-- checks on a game version it wasn't made for): the names above are from one game build's network config, and reading
-- a field a type doesn't declare can end the game, so a patch that moved one turned C4's icon off instead. Field ids
-- (the 32-bit hashes the info lists, lower-case hex without leading zeros) from NarrowHUD's data. Info not given (a
-- Chef that refuses it): nothing is read.
-- (in a function of its own: the file is near Lua 5.1's 200 locals)
local read_field = (function()
local FIELD_ID = { [C4_OPTIONS] = '31f86165', [C4_OWNER] = '3ccffa7f', [C4_CARRY] = '788b9753', if5_pz = '49c250a6',
                   u4d1h9a = 'f27c68e' }
local declared = {}              -- type name -> { [field id] = true }, or false when the info isn't given
return function(gs, goid, type_name, field, tag)
  local set = declared[type_name]
  if set == nil then
    local ok, info = pcall(chef.call_kind, 'Network.object_info', 'objinfo ' .. type_name, type_name)
    set = false
    if ok and type(info) == 'table' and type(info.fields) == 'table' then
      set = {}
      for _, f in ipairs(info.fields) do
        local id = type(f) == 'table' and f.id
        if type(id) == 'number' then id = string.format('%x', id) end
        if type(id) == 'string' then set[(string.gsub(string.lower(id), '^0+', ''))] = true end
      end
    end
    declared[type_name] = set
    if not set then log('network: no field info for type %s: its fields are not read', type_name) end
  end
  if not set then return nil end
  if not set[FIELD_ID[field]] then
    if set[field] ~= 'said' then
      set[field] = 'said'
      log('network: type %s no longer declares field %s (a game patch?): not read', type_name, field)
    end
    return nil
  end
  return chef.call_kind('GameSession.game_object_field', tag, gs, goid, field)
end
end)()

local function peer_text(v)
  if type(v) == 'string' then return (string.gsub(string.lower(v), '^0+', '')) end
  return nil
end

local function is_c4(gs, goid)
  return chef.call_kind('GameSession.game_object_exists', 'c4 exists', gs, goid) == true
     and chef.call_kind('GameSession.game_object_is_type', 'c4 type', gs, goid, C4_TYPE) == true
end

-- (a C4 that I carry: one that is still there and is C4 first)
local function carried(gs, goid)
  local v = read_field(gs, goid, C4_TYPE, C4_CARRY, 'c4 carry')
  return type(v) == 'number' and v % 4 == 0
end

local function find_c4_object(gs, peer)
  local mine = chef.call_kind('GameSession.objects_owned_by', 'c4 owned', gs, peer)
  if type(mine) ~= 'table' then return nil end
  for _, goid in pairs(mine) do if is_c4(gs, goid) and carried(gs, goid) then return goid end end
  local host = chef.call_kind('GameSession.game_session_host', 'c4 host', gs)
  if host == nil or host == peer then return nil end
  local theirs = chef.call_kind('GameSession.objects_owned_by', 'c4 owned', gs, host)
  for _, goid in pairs(type(theirs) == 'table' and theirs or {}) do
    if is_c4(gs, goid) and carried(gs, goid)
       and peer_text(read_field(gs, goid, C4_TYPE, C4_OWNER, 'c4 owner')) == peer_text(peer) then
      return goid
    end
  end
  return nil
end

-- 'deploy', 'detonate', or nil when it can't be told; and the options value. look: may look for the object
local function c4_mode(look)
  local gs = chef.call_kind('Network.game_session', 'c4 session')
  local peer = chef.call_kind('Network.peer_id', 'c4 peer')
  if gs == nil or peer == nil then return nil end
  local w = chef.world_id()
  if c4_obj.world ~= w then c4_obj.goid, c4_obj.world, c4_obj.next = nil, w, 0 end
  if c4_obj.goid and not (is_c4(gs, c4_obj.goid) and carried(gs, c4_obj.goid)) then c4_obj.goid = nil end
  if not c4_obj.goid then
    if not look or now() < c4_obj.next then return nil end
    c4_obj.next = now() + C4_SCAN
    c4_obj.goid = find_c4_object(gs, peer)
    if not c4_obj.goid then return nil end
  end
  local v = tonumber(read_field(gs, c4_obj.goid, C4_TYPE, C4_OPTIONS, 'c4 options'))
  if not v then return nil end
  local m = math.floor(v / 256) % 4
  return (m == 0 and 'deploy') or (m == 1 and 'detonate') or nil, v
end

-- the nearest detonator in my hand, and how far it is from my feet across and above them, or nil
local function det_in_hand()
  if not (det_watch and me) then return nil end
  local best, bu, high
  for _, it in ipairs(det_watch.items) do
    local u = it.unit
    if chef.unit_alive(u) then
      local x, y, z = chef.unit_position(u)
      if x then
        local dx, dy, up = x - me[1], y - me[2], z - me[3]
        local across = math.sqrt(dx * dx + dy * dy)
        if across <= C4_HAND and up >= HAND_LOW and up <= HAND_HIGH and (not best or across < best) then
          best, bu, high = across, u, up
        end
      end
    end
  end
  return bu, best, high
end

-- my helldiver's hand pose (NarrowHUD's weapon_selected: 0 nothing in hand, 40 and 41 grenades and stratagem balls),
-- or nil when it can't be read
local GRIP_VARIABLE = 'weapon_selected'
-- (the variable's index per unit; not found, it is looked for again after GRIP_RETRY s)
local GRIP_RETRY = 5
local grip_index = setmetatable({}, { __mode = 'k' })
local function hand_pose()
  local u = me_unit
  if not (u and chef.unit_alive(u)) then return nil end
  local idx = grip_index[u]
  if idx == nil or (type(idx) == 'table' and now() >= idx.retry) then
    idx = { retry = now() + GRIP_RETRY }
    if chef.call_kind('Unit.has_animation_state_machine', PLAYER, u) == true
       and chef.call_kind('Unit.animation_has_variable', PLAYER, u, GRIP_VARIABLE) == true then
      local i = chef.call_kind('Unit.animation_find_variable', PLAYER, u, GRIP_VARIABLE)
      if type(i) == 'number' then idx = i end
    end
    grip_index[u] = idx
  end
  if type(idx) ~= 'number' then return nil end
  local v = chef.call_kind('Unit.animation_get_variable', PLAYER, u, idx)
  v = type(v) == 'number' and math.floor(v + 0.5) or nil
  if v == C4_GRIP then c4_grip_at = now() end
  return v
end

local function read_c4(c)
  local right, left = aim_down, throw_down
  if right and not was_right then
    c4_least, c4_low = nil, nil
    if det_watch then det_watch.refresh() end
  end
  local held, posed = false, false
  if not right and now() >= grip_next then
    grip_next = now() + 0.2
    hand_pose()
  end
  if right and not aiming and det_watch then
    local u, across, high = det_in_hand()
    local grip = hand_pose()
    if grip == DIVE_GRIP and u and (c4_posed or high < C4_PRONE_UP) and now() - c4_grip_at <= C4_DIVE then grip = C4_GRIP end
    local ready = false
    if u and grip == C4_GRIP then
      c4_least, c4_low = math.min(c4_least or across, across), math.min(c4_low or high, high)
      ready = high <= C4_HIGH
              and (across - c4_least >= (c4_posed and C4_KEEP or C4_PUSH) or high - c4_low >= C4_RAISE)
      if in_vehicle() then
        if c4_posed then ready = true end
      elseif high < C4_LOW_UP then
        ready = true
      end
      if ready then c4_ready_at = now() end
      if c4_posed and not ready and now() - c4_ready_at < C4_GRACE then ready = true end
    end
    if c4_aim and left then
      c4_rearm = now() + C4_REARM
      start_hold(c4_det, true)
    end
    posed = ready == true and not left and now() >= c4_rearm
    held = posed and c4_mode(not c4_posed) ~= 'detonate'
    if held and not c4_aim then find_armour() end
    if held then c4_det = u or c4_det end
  end
  was_right = right
  c4_aim, c4_posed = held, posed
  if not held then c4_det = nil end
end

-- ------------------------------------------------------------------ drawing
-- The arc's colour, an option: green (the default from 1.0.4; 1.0.4-test.1 saw it keep its colour where white turned
-- faint blue, red or green), white (until 1.0.3), blue or red.
local COLORS = { { 0, 255, 0 }, { 255, 255, 255 }, { 80, 160, 255 }, { 255, 70, 70 } }
local arc_color = 1
-- The arc is 3 lines a render pixel apart, 3 render pixels wide, at any render scale. The render scale: the game's
-- settings file's render resolution over the screen's height, read every SCALE_EVERY s. A white arc came out faint
-- blue, red or green in parts, at some places and headings only, on any map, at native scale and with anti-aliasing
-- off alike (1.0.3-test.3 and after); the cause is unknown.
local SCALE_EVERY = 2
local render_scale, scale_next = 1, 0
-- the arc is dashed by flight time: DASH segments drawn, GAP left out (about 1.3 m and 0.7 m). test.10-11 measured
-- dashes in px from the camera, so they slid along the arc whenever the camera moved: it rippled as you turned
local DASH, GAP = 2, 1
-- 1.1.0-test.7: past the top of the arc, where it lands, the dashes are DOWN as long (and as far apart): where the arc
-- goes into the ground shows finer (a dash cut short there is easier to see than in long ones)
local DOWN = 0.5
-- test.15: only within DOWN_NEAR m of where the arc starts: farther, the finer dashes ran together into a line (from the
-- start, not the camera: by the camera, the dashes past that line slid as the camera moved)
local function finer(start, p)
  local DOWN_NEAR = 40
  return (p[1] - start[1]) ^ 2 + (p[2] - start[2]) ^ 2 + (p[3] - start[3]) ^ 2 < DOWN_NEAR * DOWN_NEAR
end
-- where a throw is let go: above the ball (or the C4) in my hand, standing, crouched or prone alike (during the hold,
-- where it was then, from my feet); else right of my chest, or under the camera
local function release_point(c, held, c4, from_feet)
  local ox, oy, oz
  if from_feet and me then
    ox, oy, oz = me[1] + from_feet[1], me[2] + from_feet[2], me[3] + from_feet[3]
  elseif held and chef.unit_alive(held) then
    ox, oy, oz = chef.unit_position(held)
  end
  if not ox then
    local fh = math.sqrt(c.fx * c.fx + c.fy * c.fy)
    local hx, hy = 0, 1
    if fh > 1e-6 then hx, hy = c.fx / fh, c.fy / fh end
    if me then
      ox, oy, oz = me[1] + hy * 0.3 + hx * 0.3, me[2] - hx * 0.3 + hy * 0.3, me[3] + 1.35
    else
      ox, oy, oz = c.x + hy * 0.3 + hx * 1.5, c.y - hx * 0.3 + hy * 1.5, c.z - 0.6
    end
  end
  return ox, oy, oz + (c4 and C4_RELEASE_UP or RELEASE_UP)
end

-- the throw's velocity as drawn: x, y, z
local function throw_velocity(c, c4)
  local fh = math.sqrt(c.fx * c.fx + c.fy * c.fy)
  local pitch = camera_pitch(c) + (c4 and C4_LIFT or LIFT)
  local hx, hy = 0, 1
  if fh > 1e-6 then hx, hy = c.fx / fh, c.fy / fh end
  local mx, my = my_move()
  local carried = math.max(-CARRY_MOST, math.min(CARRY_MOST, CARRY * (mx * hx + my * hy)))
  local speed = (c4 and C4_SPEED or SPEED) * speed_up(c4) + carried
  return hx * speed * math.cos(pitch), hy * speed * math.cos(pitch), speed * math.sin(pitch)
end

-- the throw's path, from where the ball or charge is let go, until DEEPEST under my feet or MOST_T: a list of points
local function path(c, c4, ox, oy, oz)
  local vx, vy, vz = throw_velocity(c, c4)
  local deepest = (feet_z or (c.z - 2)) - DEEPEST
  local function at(t)
    return ox + vx * t, oy + vy * t, oz + vz * t - 0.5 * GRAVITY * t * t
  end
  local pts = { { at(0) } }
  local t = 0
  while t < MOST_T do
    t = t + ((vz - GRAVITY * t < 0 and finer(pts[1], pts[#pts])) and STEP * DOWN or STEP)
    local x, y, z = at(t)
    pts[#pts + 1] = { x, y, z }
    if z < deepest then break end
  end
  return pts
end

-- the arc dashed (segment i drawn unless it falls in a gap), each drawn segment as lines side by side (offsets: px off
-- its middle), across the view
local function world_strip(c, pts, col, px_angle, offsets)
  for i = 2, #pts do
    if (i - 2) % (DASH + GAP) < DASH then
      local p, q = pts[i - 1], pts[i]
      local dx, dy, dz = q[1] - p[1], q[2] - p[2], q[3] - p[3]
      local mx, my, mz = (p[1] + q[1]) / 2 - c.x, (p[2] + q[2]) / 2 - c.y, (p[3] + q[3]) / 2 - c.z
      local nx, ny, nz = dy * mz - dz * my, dz * mx - dx * mz, dx * my - dy * mx
      local nl = math.sqrt(nx * nx + ny * ny + nz * nz)
      if nl > 1e-9 then
        -- each end set off by its own distance (1.1.0-test.3: one offset from the middle made a segment going away
        -- from the camera, as a weapon's does, fan out into loose strands)
        local kp = math.sqrt((p[1] - c.x) ^ 2 + (p[2] - c.y) ^ 2 + (p[3] - c.z) ^ 2) * px_angle / nl
        local kq = math.sqrt((q[1] - c.x) ^ 2 + (q[2] - c.y) ^ 2 + (q[3] - c.z) ^ 2) * px_angle / nl
        for _, o in ipairs(offsets) do
          chef.line(p[1] + nx * kp * o, p[2] + ny * kp * o, p[3] + nz * kp * o,
                    q[1] + nx * kq * o, q[2] + ny * kq * o, q[3] + nz * kq * o, col)
        end
      end
    end
  end
end

local drew = false

local function draw_points(c, pts)
  local _, sh = chef.screen()
  if now() >= scale_next and chef.setting then
    scale_next = now() + SCALE_EVERY
    local r = chef.setting('render_settings.render_resolution')
    local rh = type(r) == 'table' and tonumber(r[2])
    render_scale = (rh and sh and sh > 0) and math.min(1, rh / sh) or 1
  end
  local px_angle = (tonumber(c.fov) or 0.96) / math.max(1, sh or 1080)
  local offsets = { -1 / render_scale, 0, 1 / render_scale }
  local col = COLORS[arc_color] or COLORS[1]
  world_strip(c, pts, chef.color(col[1], col[2], col[3], 255), px_angle, offsets)
  drew = true
end

local function draw_arc(c, c4, ox, oy, oz) draw_points(c, path(c, c4, ox, oy, oz)) end

-- a line object keeps what it was last given until it is reset, and the loader resets it only when a line is drawn:
-- after the arc, one empty line far below the map clears it
local function clear_arc()
  if not drew then return end
  drew = false
  chef.line(0, 0, -10000, 0, 0, -10000, chef.color(0, 0, 0, 0))
end

-- ------------------------------------------------------------------ weapons
-- 1.1.0: while a weapon whose round falls is aimed, in third person, the round's path. Measured with Weapon Probe 0.1.0
-- (27 tracked rounds of five weapons, WEAPON_ARCS_PLAN.md): the round flies the way the camera looks, WEAPON_LIFT above
-- it, from WEAPON_FROM (m ahead, right and up of the camera), at the weapon's speed plus my velocity; gravity times the
-- weapon's factor, and drag a = -WEAPON_K * drag * caliber^2 / mass * |v| * v, one K for every weapon (fitted per
-- weapon 4.6-4.8e-4; air's 1/2 rho pi/4 in the wiki's units is 4.81e-4). Within 0.73 m RMS of the rounds over 150 m.
-- The weapon in hand: while aiming, the one weapon unit near me that points the way the camera looks (held ones
-- 0.998 and more, worn ones 0.8 and less; hand poses don't tell, the CB-9 and the Ultimatum share one). Not drawn in
-- first person, the camera less than FIRST_PERSON m behind my feet (third person: 0.8-2.1 m).
-- test.2: drawn from the muzzle, where the round is first seen (MUZZLE m ahead of the weapon unit, which sits at the
-- grip: 0.4-0.5 m for the GL, the CB-9 and the RL-77 in the probe), and dashed by distance as the stratagem arc is (a
-- point every SEG m, farther apart far off: SEG_FAR of the distance from the camera), not by flight time (a 100 m/s
-- round's dashes were 6 m long).
local WEAPON_K, WEAPON_LIFT, WEAPON_FROM = 4.7e-4, math.rad(0.6), { 1.3, -0.18, -0.35 }
local WEAPON_STEP = 1 / 120      -- s per step of the flight
local MUZZLE, SEG, SEG_FAR, MOST_POINTS = 0.45, 0.66, 0.015, 800   -- (SEG_FAR 0.01 until test.14)
-- test.3: the round goes where the weapon points (the game's small aim circle), which lags the camera when turning (an
-- EAT and a GR-8 turned left fired right of the arc). Held still, a weapon points AIM_OFF off the round's way, its own
-- amount (0.2-2 degrees in the probe): learned while the camera turns less than STILL_TURN degrees/s, AIM_LEARN of the
-- difference a frame, and taken off the weapon's heading. Until learned, the camera's heading.
-- test.4: test.3 learned too eagerly (a fifth of the difference a frame, whenever the camera was still): the weapon still
-- catching up after a turn, and a weapon turned by the game toward a near corner under the crosshair (the Breacher's
-- barrel 5.3 degrees left, its round 5.1), were taken for its offset, and the arc went back to the camera too soon. Now
-- learned only once the camera and the weapon have both been still for STILL_FOR s, AIM_LEARN a frame, and never from a
-- difference more than AIM_ODD degrees off what is known; it starts from AIM_OFF (weapons point 1.3-2.4 degrees above
-- their round's way, about level across, in the probe and test.3).
-- My velocity: all of it along the aim; SIDE_CARRY of it across (test.3: walking 2.2 m/s sideways, the GL's round went
-- 0.6 of it with me, test.2's Breacher 0.3; the Punisher Plasma's clearly went with me; test.3 added none).
-- Once found, the weapon in hand is kept while aiming lasts and it points within HELD_KEEP of the camera (test.2's arc
-- went away mid-turn, the weapon lagging past HELD_ALONG).
-- (in one table: the file is near Lua 5.1's 200 locals)
local AIMING = { STILL_TURN = 8, STILL_FOR = 0.5, AIM_LEARN = 0.05, AIM_ODD = 1.0, HELD_KEEP = 0.8 }
local AIM_OFF, SIDE_CARRY = { 0, 1.5 }, 0.5
local aim_off = {}               -- weapon kind -> { yaw, pitch } (degrees) the weapon points off the round's way
local aim_still = { since = nil, yaw = nil, pitch = nil, t = 0 }   -- since when the camera and the weapon are still
local FIRST_PERSON = 0.6
local HELD_ALONG, HELD_NEAR = 0.99, 2.5
-- weapon unit kind -> { speed m/s, gravity factor, drag * caliber^2 / mass, lifetime s or false, name }. From the
-- Helldivers wiki's data (game 1.007.201); measured ones say so. Kinds named from filediver's hash list.
local WEAPONS = {
  ['02eecd0b1fa49630'] = { 100, 1, 38.4, false, 'GL-21 Grenade Launcher' },             -- measured
  ['fe3b29b2cfa63f9b'] = { 100, 1, 38.4, false, 'GL-52 De-Escalator' },                 -- measured (the GL-21's round)
  ['88c2d09ad85a7c9f'] = { 100, 1, 38.4, false, 'GL-28 Belt-Fed Grenade Launcher' },
  ['006e44327bb953fe'] = { 100, 1, 38.4, false, 'GL-15 Evictor' },          -- (the wiki: a pump-action launcher)
  ['52e4334e6a128caf'] = { 100, 1, 38.4, false, 'GP-31 Grenade Pistol' },
  ['9eb160830321bfd6'] = { 20, 1, 6.4, false, 'GP-20 Ultimatum' },                      -- measured
  ['e91f569c2ad8af01'] = { 100, 1, 0, false, 'P-34 Breacher' },   -- measured: 100 m/s, flies 7 s+ (wiki: 150, 1.7 s)
  ['f49227a0630a3f7f'] = { 100, 0.5, 2.25, false, 'CB-9 Exploding Crossbow' },           -- measured
  ['05d8d8c073b9d502'] = { 90, 3, 16, false, 'SG-8P Punisher Plasma' },
  ['26e40437ea275296'] = { 250, 1, 0.657, 1.5, 'RL-77 Airburst Rocket Launcher' },       -- measured (bursts at 1.5 s)
  ['9f80d67a12a7e40f'] = { 250, 1, 0.657, false, 'GR-8 Recoilless Rifle' },
  ['80932fa0ed6901d3'] = { 200, 1, 0, false, 'EAT-17 Expendable Anti-Tank' },
  ['b2b5e0d185605f9e'] = { 200, 1, 0, false, 'EAT-700 Expendable Napalm' },
  ['7617642765ac38c7'] = { 50, 1, 6.4, false, 'EAT-411 Leveller' },  -- (the wiki: a large disposable launcher)
  -- (its unit: plasma_blaster, test.11; its round isn't a unit, so only seen by eye: test.12's arc began below the
  -- muzzle, which sits farther along and higher than the unit's grip: a guess, to be seen in test.13)
  ['e8d5f49ad7780e54'] = { 250, 2, 0.4, 0.6, 'PLAS-45 Epoch', muzzle = { 0.8, 0.12 } },
  -- the One-Two's underbarrel launcher fires the GP-31's round; drawn only while its fire mode selects it (ub)
  ['a955c4ea6f6d4203'] = { 100, 1, 38.4, false, 'AR/GL-21 One-Two (its grenade launcher)', ub = true },
}
local weapon_watch
do
  local kinds = {}
  for kind in pairs(WEAPONS) do kinds[kind] = true end
  weapon_watch = chef.watch and chef.watch(kinds, 0.5)
end
local weapon_arcs = true         -- the option
local said_weapon = nil

-- the weapon in my hand, while aiming: its kind and unit, or nil when it isn't one of WEAPONS
local held = nil                 -- { kind, unit }: kept while aiming lasts
local function held_weapon(c)
  if not (weapon_watch and me) then return nil end
  if held and chef.unit_alive(held.unit) then
    local fx, fy, fz = chef.unit_rotation(held.unit)
    if type(fx) == 'number' and fx * c.fx + fy * c.fy + fz * c.fz >= AIMING.HELD_KEEP then return held.kind, held.unit end
  end
  held = nil
  for _, it in ipairs(weapon_watch.items) do
    if chef.unit_alive(it.unit) then
      local x, y = chef.unit_position(it.unit)
      if x and (x - me[1]) ^ 2 + (y - me[2]) ^ 2 < HELD_NEAR * HELD_NEAR then
        local fx, fy, fz = chef.unit_rotation(it.unit)
        if type(fx) == 'number' and fx * c.fx + fy * c.fy + fz * c.fz >= HELD_ALONG then
          held = { kind = it.kind, unit = it.unit }
          return it.kind, it.unit
        end
      end
    end
  end
  return nil
end

-- the muzzle of a held weapon: { x, y, z }, or nil. A row's muzzle = { ahead, up } (m) where MUZZLE isn't it
local function muzzle_of(u, w)
  local x, y, z = chef.unit_position(u)
  local fx, fy, fz = chef.unit_rotation(u)
  if not (x and type(fx) == 'number') then return nil end
  local ahead, up = MUZZLE, 0
  if w.muzzle then ahead, up = w.muzzle[1], w.muzzle[2] end
  return { x + fx * ahead, y + fy * ahead, z + fz * ahead + up }
end

local function first_person(c)
  if not me then return false end
  local fh = math.sqrt(c.fx * c.fx + c.fy * c.fy)
  if fh < 1e-6 then return false end
  return -((c.x - me[1]) * c.fx + (c.y - me[2]) * c.fy) / fh < FIRST_PERSON
end

-- the round as it is fired: where it starts and its velocity (mx, my: my velocity on the ground; aim: { yaw, pitch }
-- in radians the round goes, or nil for the camera's; from: the muzzle, or nil for WEAPON_FROM off the camera)
local function launch(c, w, mx, my, aim, from)
  local fh = math.sqrt(c.fx * c.fx + c.fy * c.fy)
  local hx, hy = 0, 1
  if fh > 1e-6 then hx, hy = c.fx / fh, c.fy / fh end
  local ux, uy, uz = -c.fz * hx, -c.fz * hy, fh     -- up, across the view
  local f = WEAPON_FROM
  local px, py, pz = c.x + c.fx * f[1] + hy * f[2] + ux * f[3], c.y + c.fy * f[1] - hx * f[2] + uy * f[3],
                     c.z + c.fz * f[1] + uz * f[3]
  if from then px, py, pz = from[1], from[2], from[3] end
  local pitch = (aim and aim[2] or camera_pitch(c)) + WEAPON_LIFT
  if aim then hx, hy = math.cos(aim[1]), math.sin(aim[1]) end
  local along, across = mx * hx + my * hy, (mx * hy - my * hx) * SIDE_CARRY
  local s = w[1] * math.cos(pitch) + along
  return px, py, pz, hx * s + hy * across, hy * s - hx * across, w[1] * math.sin(pitch)
end

-- where the round goes, from the weapon's heading less what it points off when held still ({ yaw, pitch } radians);
-- learns that while the camera and the weapon are still
local function weapon_aim(c, kind, u, turning)
  local fx, fy, fz = chef.unit_rotation(u)
  if type(fx) ~= 'number' then return nil end
  local wyaw, wpitch = math.deg(math.atan2(fy, fx)), math.deg(math.atan2(fz, math.sqrt(fx * fx + fy * fy)))
  local cyaw, cpitch = math.deg(math.atan2(c.fy, c.fx)), math.deg(camera_pitch(c))
  local st, t = aim_still, now()
  local swing = 0
  if st.yaw and t > st.t then
    swing = math.sqrt(((wyaw - st.yaw + 180) % 360 - 180) ^ 2 + (wpitch - st.pitch) ^ 2) / (t - st.t)
  end
  st.yaw, st.pitch, st.t = wyaw, wpitch, t
  if turning or swing >= AIMING.STILL_TURN then st.since = nil else st.since = st.since or t end
  local off = aim_off[kind]
  if not off then
    off = { AIM_OFF[1], AIM_OFF[2] }
    aim_off[kind] = off
  end
  if st.since and t - st.since >= AIMING.STILL_FOR then
    local dyaw, dpitch = (wyaw - cyaw + 180) % 360 - 180, wpitch - cpitch
    if math.abs(dyaw - off[1]) < AIMING.AIM_ODD and math.abs(dpitch - off[2]) < AIMING.AIM_ODD then
      off[1], off[2] = off[1] + (dyaw - off[1]) * AIMING.AIM_LEARN, off[2] + (dpitch - off[2]) * AIMING.AIM_LEARN
    end
  end
  return { math.rad(wyaw - off[1]), math.rad(wpitch - off[2]) }
end

-- one WEAPON_STEP of a round's flight
local function fly(w, px, py, pz, vx, vy, vz)
  local d = WEAPON_K * w[3] * math.sqrt(vx * vx + vy * vy + vz * vz) * WEAPON_STEP
  vx, vy, vz = vx - d * vx, vy - d * vy, vz - GRAVITY * w[2] * WEAPON_STEP - d * vz
  return px + vx * WEAPON_STEP, py + vy * WEAPON_STEP, pz + vz * WEAPON_STEP, vx, vy, vz
end

-- the round's path from the muzzle, until its lifetime, MOST_T or DEEPEST under my feet: points SEG m apart (farther
-- far off). test.4: from the muzzle itself; test.2-3 cut the camera's line where it passed the muzzle's distance, which
-- hung in the air ahead of the weapon while walking sideways (the weapon swinging off that line)
local function weapon_path(c, w, muzzle, aim)
  local mx, my = my_move()
  local px, py, pz, vx, vy, vz = launch(c, w, mx, my, aim, muzzle)
  local last = math.min(w[4] or MOST_T, MOST_T)
  local deepest = (feet_z or (c.z - 2)) - DEEPEST
  local pts, to_go = {}, 0       -- to_go: m of flight until the next point
  local function put(x, y, z)
    pts[#pts + 1] = { x, y, z }
    to_go = math.max(SEG * (vz < 0 and DOWN or 1), SEG_FAR * math.sqrt((x - c.x) ^ 2 + (y - c.y) ^ 2 + (z - c.z) ^ 2))
  end
  local t = 0
  while t < last and #pts < MOST_POINTS do
    local qx, qy, qz
    qx, qy, qz, vx, vy, vz = fly(w, px, py, pz, vx, vy, vz)
    t = t + WEAPON_STEP
    if #pts == 0 then put(px, py, pz) end
    local len = math.sqrt((qx - px) ^ 2 + (qy - py) ^ 2 + (qz - pz) ^ 2)
    local s = 0
    while len - s >= to_go and #pts < MOST_POINTS do
      s = s + to_go
      local f = s / len
      put(px + (qx - px) * f, py + (qy - py) * f, pz + (qz - pz) * f)
    end
    to_go = to_go - (len - s)
    px, py, pz = qx, qy, qz
    if pz < deepest then break end
  end
  pts[#pts + 1] = { px, py, pz }
  return pts
end

-- test.8: is the underbarrel launcher selected? As NarrowHUD tells it: my weapons' network objects, their fire mode
-- field (if5_pz) with the 8 bit set selects the underbarrel. Which of my objects are weapons is found by trying each
-- against the weapon types that declare that field (WEAPON_TYPES, from NarrowHUD's data), UB_BUDGET tries a frame (as
-- host I own every soldier's objects: thousands); a field is read only from an object just found to be of such a type
-- (reading one a type doesn't declare can end the game). Only while the One-Two is in hand; my objects looked for again
-- every UB_LOOK s.
local underbarrel_on = (function()
  local TYPES, FIRE_MODE, UB_BUDGET, UB_LOOK = {}, 'if5_pz', 300, 2
  for name in ("@WEAPON_TYPES@"):gmatch('%S+') do TYPES[#TYPES + 1] = name end
  local session, tried, weapons, next_look, said = nil, {}, {}, 0, {}
  local function call(name, tag, ...) return chef.call_kind(name, 'ub ' .. tag, ...) end
  return function()
    local gs = call('Network.game_session', 'session')
    if not gs then return false end
    -- (by the world: the session comes back as a new value each call, and test.9 started over every frame, 19,000
    -- "my object is weapon type" lines in a mission)
    if chef.world_id() ~= session then session, tried, weapons, said = chef.world_id(), {}, {}, {} end
    if now() >= next_look then
      next_look = now() + UB_LOOK
      local peer = call('Network.peer_id', 'peer')
      local mine = peer and call('GameSession.objects_owned_by', 'owned', gs, peer)
      if type(mine) == 'table' then for _, g in pairs(mine) do if tried[g] == nil then tried[g] = 1 end end end
    end
    local budget = UB_BUDGET
    for g, i in pairs(tried) do
      if budget <= 0 then break end
      if type(i) == 'number' then
        if i == 1 and call('GameSession.game_object_exists', 'exists', gs, g) ~= true then i = #TYPES + 1 end
        while budget > 0 and i <= #TYPES do
          budget = budget - 1
          if call('GameSession.game_object_is_type', 'type', gs, g, TYPES[i]) == true then
            weapons[g] = TYPES[i]
            log('one-two: my object %s is weapon type %s', tostring(g), TYPES[i])
            break
          end
          i = i + 1
        end
        -- (test.8-9 wrote this as "(...) and false or i", which is always i: found again every frame)
        if weapons[g] or i > #TYPES then tried[g] = false else tried[g] = i end
      end
    end
    local on = false
    for g, name in pairs(weapons) do
      if call('GameSession.game_object_exists', 'exists', gs, g) == true
         and call('GameSession.game_object_is_type', 'type', gs, g, name) == true then
        local fm = read_field(gs, g, name, FIRE_MODE, 'ub fire mode')
        if said[g] ~= fm then
          said[g] = fm
          log('one-two: object %s (type %s) fire mode %s', tostring(g), name, tostring(fm))
        end
        if type(fm) == 'number' and math.floor(fm / 8) % 2 == 1 then on = true end
      else
        weapons[g], tried[g] = nil, nil
      end
    end
    return on
  end
end)()

-- 1.1.0: grenades. The grenade in my hand is a unit of its own kind (test.13 on), so it is told by its kind, from the
-- game's throwables (THROWABLES, filediver's names): one within GRENADE_HAND m across and GRENADE_LOW to GRENADE_HIGH
-- m above my feet. While one is in my hand and G (the game keeps it in hand until G is let go, "cooking"), left (cooking
-- one drawn with its key) or right (aiming it) is held, its arc, as its kind is thrown: from where its throws start
-- (from my feet, along and across my heading), turned its kind's yaw from the camera's heading, its kind's lift over the
-- camera, at its kind's speed (my walk along the aim added, test.15, and the throw-range perks), slowed by its kind's
-- DRAG (a = -drag |v| v). No grenade in hand: no arc (test.17 drew one from the air when G had none to throw). Guided
-- kinds: no arc.
-- Each kind's throw is learned from its flights, kept across launches (chef.save_table): the grenade that leaves my hand
-- (that unit, followed) is measured over its free flight, from the first step after it leaves the hand at GRENADE_FAST
-- m/s or more and steady (within GRENADE_STEADY of the next: the frames it jumps from the hand to its path run 25-35
-- m/s), for GRENADE_FIT s or until it lands (a step at less than half the one before): least squares, falling at
-- GRAVITY (and DRAG). Its start: that path back at the frame it left my hand, from my feet then. Standing and walking
-- (WALK m/s along the aim or more: the game's own deadzone for a thrower's velocity, "thrower_velocity_deadzone", is 1)
-- lifts apart (test.15: Gigas 3 degrees standing, 6-16 walking). Each value is the median of its last GRENADE_KEEP
-- measurements (with the measured ones to start), so one odd throw doesn't move it. Not measured yet: GRENADE_SPEED,
-- GRENADE_LIFT, no yaw, from the grenade in hand RELEASE_UP above it and GRENADE_RIGHT across.
-- test.19: drag is no longer learned (test.18's, from the speed across at a flight's start and end, ran 0.0001-0.35:
-- landings and bounces in it) but fixed, from whole flights; the start and yaw are (test.18: a Melta mine is thrown from
-- 0.8 m up, 0.5 m right of the hand, an Arc grenade 0.3 m right of my feet: the arc from the hand was off).
-- Keys rebound in the game aren't followed.
-- (lift: the game's "throw_angle_offset" is 5 degrees, in the Helldiver's AvatarComponent data dumped in
-- github.com/shalzuth/HelldiversData; a grenade's speed and drag aren't in that data)
local grenade = (function()
  local GRENADE_SPEED, GRENADE_LIFT, WALK = 21, 5, 1
  local GRENADE_HAND, GRENADE_LOW, GRENADE_HIGH, GRENADE_RIGHT = 1.0, 0.6, 2.4, -0.2
  local GRENADE_FAST, GRENADE_STEADY, GRENADE_FIT, GRENADE_FLY, GRENADE_KEEP = 5, 0.15, 0.3, 2.5, 9
  local SAVE = 'grenade_throws5'  -- (test.12-18's files are not read: learned the wrong things)
  -- drag by kind, from whole flights (test.16: thermite 22 to 18 m/s across over 2 s, Giga 18.7 to 17 over 1.4 s;
  -- test.17: Arc, Melta and Impact kept their speed)
  local DRAG = { ['c5c05fcb5747c799'] = 0.0053, ['46333fc9e3d4bd34'] = 0.004 }
  -- the game's throwables (content/fac_helldivers/equipment/throwables/*), not their parts (a frag's spoon, caltrops'
  -- effect and the caltrops themselves)
  local THROWABLES = {}
  for kind in ([[6002622114037024 db922a7afc42894b 46333fc9e3d4bd34 8e325c933e55bf62 2968deba6d6c2f09 075b19b068fb1045
                 ee89cc10d80b6afb 14368dc8784220b0 1ff81c46cc79fd34 1b9ac59697006337 0080869506299773 4ce9eab785a79b7b
                 0416984f4922757b 693028644d27ffef 6b11fc757618c57e 7686544f539bb9b7 dab81b0d80b511c7 04653ab33f3ffb44
                 eb725c39fc38b87c e49a5ae078aad407 a20683199dfc19e8 ee4c107b941ab7f4 5c14f27759dd3be0 2d398d1ec35e0838
                 5de8fd02a05b4b0a c5c05fcb5747c799 3fa94f58f596bc0b 032489cf1d439bba f7b35a9c5ae340b6
                 03f31caf3a7d8f4e]]):gmatch('%x+') do THROWABLES[kind] = true end
  -- guided ones: no arc (they steer themselves once thrown); nothing learned
  local GUIDED = { ['2d398d1ec35e0838'] = true,       -- throwables/self_destruct_drone (G-50 Seeker)
                   ['8e325c933e55bf62'] = true }      -- throwables/at_self_destruct_drone (G-60 Anti-Tank Seeker)
  local FIELDS = { 'speed', 'lift', 'walk', 'yaw', 'ahead', 'right', 'up' }
  -- kind -> { field = { the last measurements } }, from testing to start (speeds and lifts as test.16-18 measured
  -- them; starts and yaws from test.18 where it had them)
  local known = {
    ['c5c05fcb5747c799'] = { speed = { 22.6, 23.3, 23.5 }, lift = { 7.0, 6.5, 5.4 }, walk = { 7.6, 6.6 } },  -- Thermite
    ['46333fc9e3d4bd34'] = { speed = { 17.0, 17.7, 17.6 }, lift = { 4.3, 6.4, 6.9 }, walk = { 4.1, 4.8 } },  -- G-48 Giga
    ['db922a7afc42894b'] = { speed = { 22.3, 22.5, 22.2 }, lift = { 3.2, 3.2, 3.4 }, walk = { 4.5, 4.6 },  -- G-31 Arc
                             yaw = { 0 }, ahead = { 0.1 }, right = { 0.3 }, up = { 1.5 } },
    ['ee4c107b941ab7f4'] = { speed = { 10.5, 10.5 }, lift = { 1.2, 4.5 }, walk = { 3.3, 4.3 },      -- G/40-K Melta mine
                             yaw = { 0 }, ahead = { 1.3 }, right = { 0.74 }, up = { 0.8 } },
    ['7686544f539bb9b7'] = { speed = { 22.4 }, lift = { 4.2 } },                                     -- G-16 Impact
  }
  local saved = chef.load_table and chef.load_table(SAVE)
  if type(saved) == 'table' and type(saved.known) == 'table' then
    for kind, v in pairs(saved.known) do
      if THROWABLES[kind] and type(v) == 'table' then
        local k = {}
        for _, field in ipairs(FIELDS) do
          local l = {}
          for _, x in ipairs(type(v[field]) == 'table' and v[field] or {}) do
            if type(x) == 'number' then l[#l + 1] = x end
          end
          k[field] = l
        end
        known[kind] = k
      end
    end
  end
  local watch = chef.watch and chef.watch(THROWABLES, 0.2)

  local function median(l)
    if not l or #l == 0 then return nil end
    local s = {}
    for i, x in ipairs(l) do s[i] = x end
    table.sort(s)
    local m = math.floor((#s + 1) / 2)
    return #s % 2 == 1 and s[m] or (s[m] + s[m + 1]) / 2
  end

  -- the grenade in my hand: its unit and kind, or nil
  local function in_hand(skip)
    if not (watch and me) then return nil end
    local best, kind, bd
    for _, it in ipairs(watch.items) do
      if chef.unit_alive(it.unit) and not skip[it.unit] then
        local x, y, z = chef.unit_position(it.unit)
        if x then
          local d = (x - me[1]) ^ 2 + (y - me[2]) ^ 2
          local up = z - me[3]
          if d < GRENADE_HAND * GRENADE_HAND and up >= GRENADE_LOW and up <= GRENADE_HIGH and (not bd or d < bd) then
            best, kind, bd = it.unit, it.kind, d
          end
        end
      end
    end
    return best, kind
  end

  -- the arc, as path() draws a stratagem ball's, with drag
  local function arc(c, u, kind)
    if GUIDED[kind] then return nil end
    local fh = math.sqrt(c.fx * c.fx + c.fy * c.fy)
    local hx, hy = 0, 1
    if fh > 1e-6 then hx, hy = c.fx / fh, c.fy / fh end
    local k = known[kind] or {}
    local ahead, right, up = median(k.ahead), median(k.right), median(k.up)
    local ox, oy, oz
    if ahead and right and up and me then
      ox, oy, oz = me[1] + hx * ahead + hy * right, me[2] + hy * ahead - hx * right, me[3] + up
    else
      ox, oy, oz = chef.unit_position(u)
      if not ox then return nil end
      ox, oy, oz = ox + hy * GRENADE_RIGHT, oy - hx * GRENADE_RIGHT, oz + RELEASE_UP
    end
    local mx, my = my_move()
    local along = mx * hx + my * hy
    local yaw = math.rad(median(k.yaw) or 0)       -- (+: right)
    local dx, dy = hx * math.cos(yaw) + hy * math.sin(yaw), hy * math.cos(yaw) - hx * math.sin(yaw)
    local s = (median(k.speed) or GRENADE_SPEED) * speed_up(false) + along
    local lift = (math.abs(along) >= WALK and median(k.walk)) or median(k.lift) or GRENADE_LIFT
    local drag = DRAG[kind] or 0
    local pitch = camera_pitch(c) + math.rad(lift)
    local vx, vy, vz = dx * s * math.cos(pitch), dy * s * math.cos(pitch), s * math.sin(pitch)
    local deepest = (feet_z or (c.z - 2)) - DEEPEST
    local pts, t, x, y, z = { { ox, oy, oz } }, 0, ox, oy, oz
    while t < MOST_T do
      local dt = (vz < 0 and finer(pts[1], pts[#pts])) and STEP * DOWN or STEP
      for _ = 1, 3 do                             -- (three steps a segment: drag)
        local h = dt / 3
        local d = drag * math.sqrt(vx * vx + vy * vy + vz * vz) * h
        vx, vy, vz = vx - d * vx, vy - d * vy, vz - GRAVITY * h - d * vz
        x, y, z = x + vx * h, y + vy * h, z + vz * h
      end
      t = t + dt
      pts[#pts + 1] = { x, y, z }
      if z < deepest then break end
    end
    return pts
  end

  -- a throw from the grenade's positions after it left my hand: speed, lift, yaw, and where it started from my feet
  -- (ahead, right, up), or nil
  local function measure(f)
    local p = f.pts
    local v = {}                                -- each step's speed
    for i = 2, #p do
      local dt = p[i][1] - p[i - 1][1]
      v[i] = dt > 0 and math.sqrt((p[i][2] - p[i - 1][2]) ^ 2 + (p[i][3] - p[i - 1][3]) ^ 2
                                  + (p[i][4] - p[i - 1][4]) ^ 2) / dt or 0
    end
    local first
    for i = 2, #p - 1 do
      if v[i] >= GRENADE_FAST and v[i + 1] >= GRENADE_FAST and math.abs(v[i] - v[i + 1]) <= GRENADE_STEADY * v[i + 1] then
        first = i
        break
      end
    end
    if not first then return nil end
    -- least squares over the first GRENADE_FIT s: straight across, falling at GRAVITY
    local t0 = p[first][1]
    local n, st, stt, sx, sy, sz, stx, sty, stz = 0, 0, 0, 0, 0, 0, 0, 0, 0
    for i = first, #p do
      local t = p[i][1] - t0
      if t > GRENADE_FIT or (i > first and v[i] < 0.5 * v[i - 1]) then break end
      local z = p[i][4] + 0.5 * GRAVITY * t * t
      n, st, stt = n + 1, st + t, stt + t * t
      sx, sy, sz, stx, sty, stz = sx + p[i][2], sy + p[i][3], sz + z, stx + t * p[i][2], sty + t * p[i][3], stz + t * z
    end
    local den = n * stt - st * st
    if n < 4 or den <= 0 then return nil end
    local vx, vy, vz = (n * stx - st * sx) / den, (n * sty - st * sy) / den, (n * stz - st * sz) / den
    local x0, y0, z0 = (sx - vx * st) / n, (sy - vy * st) / n, (sz - vz * st) / n
    local h = math.sqrt(vx * vx + vy * vy)
    if h < 1e-6 then return nil end
    -- the start: that path back at the last frame it was in my hand, from my feet then
    local tb = f.left - t0
    local bx, by, bz = x0 + vx * tb, y0 + vy * tb, z0 + vz * tb - 0.5 * GRAVITY * tb * tb
    local hx, hy = f.hx, f.hy
    local dx, dy = bx - f.feet[1], by - f.feet[2]
    -- my walk along the throw off (the arc adds it back), not across
    local along = (f.mx * vx + f.my * vy) / h
    local yaw = math.deg(math.atan2(vx * hy - vy * hx, vx * hx + vy * hy))
    -- a kind with drag: the fit's speed is about GRENADE_FIT / 2 s in, back to the start
    local r = 1 + (DRAG[f.kind] or 0) * math.sqrt(h * h + vz * vz) * GRENADE_FIT / 2
    local ha = h * r - along
    vz = vz * r
    if ha <= 0 then return nil end
    return math.sqrt(ha * ha + vz * vz) / f.up, math.deg(math.atan2(vz, ha)) - f.pitch, yaw,
           dx * hx + dy * hy, dx * hy - dy * hx, bz - f.feet[3]
  end

  local function remember(list, x)
    list[#list + 1] = x
    while #list > GRENADE_KEEP do table.remove(list, 1) end
  end

  local function learn(f)
    if GUIDED[f.kind] then return end
    local s, lift, yaw, ahead, right, up = measure(f)
    if not s then
      log('grenade %s thrown: no steady flight to measure (%d positions)', f.kind, #f.pts)
      return
    end
    local k = known[f.kind] or {}
    for _, field in ipairs(FIELDS) do k[field] = k[field] or {} end
    known[f.kind] = k
    local walking = math.abs(f.along) >= WALK
    remember(k.speed, s)
    remember(walking and k.walk or k.lift, lift)
    remember(k.yaw, yaw)
    remember(k.ahead, ahead)
    remember(k.right, right)
    remember(k.up, up)
    log('grenade %s thrown%s: %.1f m/s %+.1f deg up %+.1f right, from %.2f ahead %.2f right %.2f up; now %.1f m/s, '
        .. '%+.1f standing, %s walking, %+.1f right, from %.2f %.2f %.2f', f.kind, walking and ' walking' or '', s, lift,
        yaw, ahead, right, up, median(k.speed), median(k.lift) or GRENADE_LIFT,
        median(k.walk) and string.format('%+.1f', median(k.walk)) or '-', median(k.yaw), median(k.ahead),
        median(k.right), median(k.up))
    if chef.save_table then chef.save_table(SAVE, { known = known }) end
  end

  -- last frame's grenade in hand: its unit, kind, when and where. Thrown: it moves GRENADE_THROWN m/s or more (a cooking
  -- hand swings it 6 at most: test.15-17), or it's gone from the hand and still there; left the hand: the frame before
  local held, held_kind, held_t, held_p = nil, nil, 0, nil
  local flights, flying = {}, {}     -- grenades thrown: { u, kind, pts, pitch, mx, my, along, up, at, feet, hx, hy,
                                     -- left }; unit -> true while followed
  local GRENADE_THROWN = 10
  local M2 = { on = true }
  -- called every frame; free: nothing else is drawn. Returns the arc's points, or nil
  function M2.update(c, free)
    local t = now()
    if held and not flying[held] and chef.unit_alive(held) and me then
      local x, y, z = chef.unit_position(held)
      local fast = x and held_p and t > held_t
                   and math.sqrt((x - held_p[1]) ^ 2 + (y - held_p[2]) ^ 2 + (z - held_p[3]) ^ 2) / (t - held_t)
                       >= GRENADE_THROWN
      local u0 = in_hand(flying)
      if x and (fast or u0 ~= held) then
        local mx, my = my_move()
        local fh = math.max(1e-6, math.sqrt(c.fx * c.fx + c.fy * c.fy))
        flights[#flights + 1] = { u = held, kind = held_kind, pts = { { held_t, held_p[1], held_p[2], held_p[3] } },
                                  pitch = math.deg(camera_pitch(c)), mx = mx, my = my,
                                  along = (mx * c.fx + my * c.fy) / fh, up = speed_up(false), at = t,
                                  feet = { me[1], me[2], me[3] }, hx = c.fx / fh, hy = c.fy / fh, left = held_t }
        flying[held] = true
      end
    end
    local u, kind = in_hand(flying)
    held, held_kind, held_t = u, kind, t
    held_p = nil
    if u then
      local x, y, z = chef.unit_position(u)
      if x then held_p = { x, y, z } end
    end
    local keep = {}
    for _, f in ipairs(flights) do
      local x, y, z
      if chef.unit_alive(f.u) then x, y, z = chef.unit_position(f.u) end
      if x and t - f.at <= GRENADE_FLY then
        f.pts[#f.pts + 1] = { t, x, y, z }
        keep[#keep + 1] = f
      else
        flying[f.u] = nil
        learn(f)
      end
    end
    flights = keep
    local keys = chef.key_down('g') == true or throw_down or aim_down
    if u and keys and free and M2.on then return arc(c, u, kind) end
    return nil
  end
  return M2
end)()

-- the weapon to draw for this frame: its row in WEAPONS and its muzzle, or nil
local function weapon_aimed(c)
  if not (weapon_arcs and aim_down) then
    said_weapon, held, aim_still.since, aim_still.yaw = nil, nil, nil, nil
    return nil
  end
  local kind, u = held_weapon(c)
  if kind and WEAPONS[kind].ub and not underbarrel_on() then kind = nil end     -- (its rifle: no arc)
  local fp = kind and first_person(c)
  local said = kind and (WEAPONS[kind][5] .. (fp and ' (first person: not drawn)' or '')) or 'none'
  if said ~= said_weapon then
    said_weapon = said
    log('weapon aimed: %s', said)
  end
  if not kind or fp then return nil end
  return WEAPONS[kind], muzzle_of(u, WEAPONS[kind]), u, kind
end

-- test.2-3: each shot while a weapon's arc shows, its round is found and, CHECK_AT s after it is first seen, compared
-- with the arc drawn at the click: how far off across the view, and which way it flew against the camera and the
-- barrel. The round: of the units new since the click and first seen within 10 m of the camera, the one gone farthest
-- (test.2 looked only for the probe's five rounds, so the EAT, the GR-8 and the Punisher Plasma went unchecked).
-- (in a block of its own: the file is near Lua 5.1's 200 locals)
local watch_shots, camera_turn, watch_c4, lab_hook
do
local CHECK_AT, CHECK_MOST, CHECK_NEW, CHECK_FAR = 0.3, 0.8, 0.15, 20
local RUNTIME_BUILT = '46cab355bd8d4d37'   -- asking where one is ends the game
local check = nil                -- the shot being checked
local was_throw = false
local cam_was = nil              -- last frame's camera: { t, yaw, pitch }

function camera_turn(c)
  if not (cam_was and now() > cam_was[1]) then return 0, 0 end
  local dyaw = (math.atan2(c.fy, c.fx) - cam_was[2] + math.pi) % (2 * math.pi) - math.pi
  return math.deg(dyaw) / (now() - cam_was[1]), math.deg(camera_pitch(c) - cam_was[3]) / (now() - cam_was[1])
end

local function all_units()
  local w = chef.world()
  local units = w and chef.call('World.units', w)
  return type(units) == 'table' and units or {}
end

-- test.6 lab (test only): flights of what is fired or thrown, logged every FLIGHT_EVERY s for FLIGHT_MOST s, to fit
-- the rounds not measured yet and grenades; grenades: what the network and my hand show when one is drawn (key 4) or
-- thrown (G); weapons in my hand not in WEAPONS, by kind.
-- (in a function of its own: Lua 5.1 allows a function 200 locals, and the file is near that)
local record
lab_hook, record = (function()
local FLIGHT_EVERY, FLIGHT_MOST, CATCH_FOR = 0.05, 4, 2
local flights, flight_n, catches = {}, 0, {}

local function record(u, what, c)
  flight_n = flight_n + 1
  local mx, my, mz = my_move()
  flights[#flights + 1] = { u = u, id = flight_n, t0 = now(), next = 0 }
  -- (test.10: and which way my body faces, against the camera: test.9's C4 thrown walking sideways flew 25.4 or
  -- 20.8 m/s, not 22.4, maybe by the body's turn)
  local body = 'nil'
  if mine and chef.unit_alive(mine) then
    local bx, by = chef.unit_rotation(mine)
    if type(bx) == 'number' then
      body = string.format('%.4f %.4f (%+.1f deg right of the camera)', bx, by,
                           -(((math.deg(math.atan2(by, bx) - math.atan2(c.fy, c.fx)) + 180) % 360) - 180))
    end
  end
  log('flight %d: %s, kind %s; camera %.2f %.2f %.2f fwd %.4f %.4f %.4f; feet %s; moving %.2f %.2f %.2f; pose %s; body %s',
      flight_n, what, tostring(chef.unit_kind(u)), c.x, c.y, c.z, c.fx, c.fy, c.fz,
      me and string.format('%.2f %.2f %.2f', me[1], me[2], me[3]) or 'nil', mx, my, mz, tostring(hand_pose()), body)
end

local function follow_flights()
  local t, keep = now(), {}
  for _, f in ipairs(flights) do
    local x, y, z
    if chef.unit_alive(f.u) then x, y, z = chef.unit_position(f.u) end
    if x and t - f.t0 < FLIGHT_MOST then
      keep[#keep + 1] = f
      if t >= f.next then
        f.next = t + FLIGHT_EVERY
        log('flight %d %.3f %.2f %.2f %.2f', f.id, t - f.t0, x, y, z)
      end
    else
      log('flight %d: ended at %.2f s', f.id, t - f.t0)
    end
  end
  flights = keep
end

-- what turns up near me in CATCH_FOR s: each new unit within 10 m that then moves, its flight recorded
local function start_catch(what, c)
  local k = { what = what, at = now(), c = c, before = {}, new = {} }
  for _, r in ipairs(all_units()) do k.before[r] = true end
  catches[#catches + 1] = k
  log('catch: %s', what)
end

local function follow_catches(c)
  local t, keep = now(), {}
  for _, k in ipairs(catches) do
    if t - k.at < CATCH_FOR then
      keep[#keep + 1] = k
      for _, r in ipairs(all_units()) do
        if not k.before[r] then
          k.before[r] = true
          local kind = chef.unit_alive(r) and chef.unit_kind(r)
          if kind and kind ~= RUNTIME_BUILT then
            local x, y, z = chef.unit_position(r)
            if x and me and (x - me[1]) ^ 2 + (y - me[2]) ^ 2 + (z - me[3]) ^ 2 < 100 then
              k.new[#k.new + 1] = { r, x, y, z }
            end
          end
        end
      end
      for i = #k.new, 1, -1 do
        local n = k.new[i]
        local x, y, z = chef.unit_position(n[1])
        if x and (x - n[2]) ^ 2 + (y - n[3]) ^ 2 + (z - n[4]) ^ 2 > 1 then
          record(n[1], k.what, c)
          table.remove(k.new, i)
        end
      end
    end
  end
  catches = keep
end

-- grenades: the Helldiver's network object (NarrowHUD's data: the player type and its avatar field, the avatar type),
-- its declared fields (Network.object_info) logged once, and their values at each grenade event when the info names
-- them (a field is only ever read by a name the game declares for that type: reading another can end the game)
local PLAYER_TYPE, PLAYER_AVATAR, AVATAR_TYPE, NO_OBJECT = 'un6y1d', 'u4d1h9a', 'vvhx8ga', 32767
local avatar_info, avatar_said = nil, {}
local function my_avatar(gs)
  local peer = chef.call_kind('Network.peer_id', 'lab peer')
  local mine = peer and chef.call_kind('GameSession.objects_owned_by', 'lab owned', gs, peer)
  if type(mine) ~= 'table' then return nil end
  for _, goid in pairs(mine) do
    if chef.call_kind('GameSession.game_object_exists', 'lab exists', gs, goid) == true
       and chef.call_kind('GameSession.game_object_is_type', 'lab player', gs, goid, PLAYER_TYPE) == true then
      local a = read_field(gs, goid, PLAYER_TYPE, PLAYER_AVATAR, 'lab avatar')
      if type(a) == 'number' and a ~= NO_OBJECT
         and chef.call_kind('GameSession.game_object_exists', 'lab exists', gs, a) == true
         and chef.call_kind('GameSession.game_object_is_type', 'lab avatar type', gs, a, AVATAR_TYPE) == true then
        return a, #mine
      end
    end
  end
  return nil, #mine
end

local function show(v)
  if type(v) == 'table' then
    local parts = {}
    for key, x in pairs(v) do parts[#parts + 1] = tostring(key) .. '=' .. tostring(x) end
    table.sort(parts)
    return '{' .. table.concat(parts, ' ') .. '}'
  end
  return tostring(v)
end

local function grenade_event(what)
  local gs = chef.call_kind('Network.game_session', 'lab session')
  if not gs then log('grenade %s: no game session', what) return end
  local avatar, owned = my_avatar(gs)
  log('grenade %s: hand pose %s, my objects %s, my Helldiver object %s', what, tostring(hand_pose()), tostring(owned),
      tostring(avatar))
  if not avatar then return end
  if avatar_info == nil then
    local ok, info = pcall(chef.call_kind, 'Network.object_info', 'lab objinfo', AVATAR_TYPE)
    avatar_info = (ok and type(info) == 'table' and type(info.fields) == 'table') and info.fields or false
    log('grenade: the Helldiver type declares %s fields; the first: %s', avatar_info and #avatar_info or 'no',
        avatar_info and show(avatar_info[1]) or show(info))
  end
  if not avatar_info then return end
  local parts = {}
  for i, f in ipairs(avatar_info) do
    local name = type(f) == 'table' and f.name
    if type(name) == 'string' then
      local v = chef.call_kind('GameSession.game_object_field', 'lab field', gs, avatar, name)
      local text = show(v)
      if avatar_said[name] ~= text then parts[#parts + 1] = name .. '=' .. text end
      avatar_said[name] = text
    elseif i == 1 then
      log('grenade: the field info has no names; not read')
      break
    end
  end
  if #parts > 0 then log('grenade %s: Helldiver fields changed: %s', what, table.concat(parts, ' ')) end
end

-- the units on me (within 1.5 m across, 2.5 m up): their kinds, to tell what a pose brings into my hand
local on_me_said = nil
local function units_on_me(why)
  if not me then return end
  local kinds = {}
  for _, u in ipairs(all_units()) do
    local kind = chef.unit_alive(u) and chef.unit_kind(u)
    if kind and kind ~= RUNTIME_BUILT and kind ~= PLAYER then
      local x, y, z = chef.unit_position(u)
      if x and (x - me[1]) ^ 2 + (y - me[2]) ^ 2 < 2.25 and z > me[3] - 0.5 and z < me[3] + 2.5 then kinds[kind] = true end
    end
  end
  local now_set = {}
  for kind in pairs(kinds) do now_set[#now_set + 1] = kind end
  table.sort(now_set)
  if on_me_said then
    local was, came, went = {}, {}, {}
    for _, kind in ipairs(on_me_said) do was[kind] = true end
    for _, kind in ipairs(now_set) do if not was[kind] then came[#came + 1] = kind end end
    for _, kind in ipairs(on_me_said) do if not kinds[kind] then went[#went + 1] = kind end end
    log('on me at %s: came %s; went %s', why, table.concat(came, ' '), table.concat(went, ' '))
  else
    log('on me at %s: %s', why, table.concat(now_set, ' '))
  end
  on_me_said = now_set
end

-- a weapon in my hand that isn't in WEAPONS: the unit near me that points the way the camera looks
local unknown_said, unknown_next = {}, 0
local function unknown_weapon(c)
  if not me or now() < unknown_next then return end
  unknown_next = now() + 1
  -- (test.10: every one, with where it is: test.9 stopped at the first, a worn piece and a reverb volume, and the Epoch
  -- in hand was never named)
  local first
  for _, u in ipairs(all_units()) do
    local kind = chef.unit_alive(u) and chef.unit_kind(u)
    if kind and kind ~= RUNTIME_BUILT and kind ~= PLAYER and not WEAPONS[kind] then
      local x, y, z = chef.unit_position(u)
      if x and (x - me[1]) ^ 2 + (y - me[2]) ^ 2 < 2.25 then
        local fx, fy, fz = chef.unit_rotation(u)
        if type(fx) == 'number' and fx * c.fx + fy * c.fy + fz * c.fz >= HELD_ALONG then
          if not unknown_said[kind] then
            unknown_said[kind] = true
            log('unknown weapon aimed: kind %s, %.2f m across from my feet, %.2f m up', kind,
                math.sqrt((x - me[1]) ^ 2 + (y - me[2]) ^ 2), z - me[3])
          end
          first = first or kind
        end
      end
    end
  end
  if first then return first end
end

local lab_keys, lab_pose, lab_left, lab_unknown = {}, nil, false, nil
local function lab(c, weapon_drawn)
  for _, key in ipairs({ '4', 'g' }) do
    local d = chef.key_down(key) == true
    if d and not lab_keys[key] then
      grenade_event('key ' .. key)
      if key == 'g' then start_catch('grenade (G)', c) end
    end
    lab_keys[key] = d
  end
  local pose = hand_pose()
  if pose ~= lab_pose then
    -- (test.10: every change: test.9's key 4 showed no grenade pose)
    log('hand pose %s -> %s (a stratagem ball held: %s)', tostring(lab_pose), tostring(pose), tostring(ball ~= nil))
    if pose == 40 or pose == 41 or lab_pose == 40 or lab_pose == 41 then units_on_me('pose ' .. tostring(pose)) end
    if pose == 40 or pose == 41 then grenade_event('pose ' .. pose) end
    lab_pose = pose
  end
  local left = throw_down
  if left and not lab_left then
    if (pose == 40 or pose == 41) and not ball then
      start_catch('grenade (thrown from the hand)', c)
    elseif aim_down and not weapon_drawn and lab_unknown then
      start_catch('shot of unknown weapon ' .. lab_unknown, c)
    end
  end
  lab_left = left
  if aim_down and not weapon_drawn and pose ~= 40 and pose ~= 41 and pose ~= C4_GRIP then
    lab_unknown = unknown_weapon(c) or lab_unknown
  elseif not aim_down then
    lab_unknown = nil
  end
  follow_catches(c)
  follow_flights()
end
return lab, record
end)()

local function start_check(c, w, u, aim, muzzle)
  local mx, my = my_move()
  local turn, nod = camera_turn(c)
  local fx, fy, fz = chef.unit_rotation(u)
  local before = {}
  for _, r in ipairs(all_units()) do before[r] = true end
  check = { at = now(), c = { x = c.x, y = c.y, z = c.z, fx = c.fx, fy = c.fy, fz = c.fz }, w = w, mx = mx, my = my,
            aim = aim, muzzle = muzzle, turn = turn, nod = nod, barrel = type(fx) == 'number' and { fx, fy, fz } or nil,
            before = before, new = {} }
end

local function yaw_pitch(x, y, z) return math.deg(math.atan2(y, x)), math.deg(math.atan2(z, math.sqrt(x * x + y * y))) end

local function follow_check()
  local k = check
  if not k then return end
  local t = now()
  if t - k.at > CHECK_MOST then
    log('shot check %s: %s', k.w[5], k.round and 'lost the round' or 'no round seen')
    check = nil
    return
  end
  if not k.round then
    if t - k.at <= CHECK_NEW then
      for _, r in ipairs(all_units()) do
        if not k.before[r] then
          k.before[r] = true
          local kind = chef.unit_alive(r) and chef.unit_kind(r)
          if kind and kind ~= RUNTIME_BUILT then
            local x, y, z = chef.unit_position(r)
            if x and (x - k.c.x) ^ 2 + (y - k.c.y) ^ 2 + (z - k.c.z) ^ 2 < 100 then
              k.new[#k.new + 1] = { r, kind, t, x, y, z }
            end
          end
        end
      end
      return
    end
    local best, far = nil, 1
    for _, n in ipairs(k.new) do
      local x, y, z = chef.unit_position(n[1])
      local d = x and chef.unit_alive(n[1]) and (x - n[4]) ^ 2 + (y - n[5]) ^ 2 + (z - n[6]) ^ 2
      if d and d > far then best, far = n, d end
    end
    if not best then
      log('shot check %s: no round seen (%d new units near)', k.w[5], #k.new)
      check = nil
      return
    end
    k.round, k.kind, k.first = best[1], best[2], { best[3], best[4], best[5], best[6] }
    record(k.round, 'shot ' .. k.w[5], k.c)
  end
  -- (a fast round only CHECK_FAR m on: test.3's GR-8 rounds were gone by 0.3 s)
  if t - k.first[1] < math.min(CHECK_AT, CHECK_FAR / k.w[1]) then return end
  local x, y, z = chef.unit_position(k.round)
  if not (x and chef.unit_alive(k.round)) then
    log('shot check %s: the round went too soon', k.w[5])
    check = nil
    return
  end
  -- the arc's point nearest the round, flown from the click
  local c, w = k.c, k.w
  local px, py, pz, vx, vy, vz = launch(c, w, k.mx, k.my, k.aim, k.muzzle)
  local best, bx, by, bz = math.huge
  for _ = 1, math.floor((t - k.at + 0.3) / WEAPON_STEP) do
    px, py, pz, vx, vy, vz = fly(w, px, py, pz, vx, vy, vz)
    local d = (px - x) ^ 2 + (py - y) ^ 2 + (pz - z) ^ 2
    if d < best then best, bx, by, bz = d, px, py, pz end
  end
  local fh = math.sqrt(c.fx * c.fx + c.fy * c.fy)
  local hx, hy = c.fx / fh, c.fy / fh
  local dx, dy, dz = x - bx, y - by, z - bz
  local ry, rp = yaw_pitch(x - k.first[2], y - k.first[3], z - k.first[4])
  local cy, cp = yaw_pitch(c.fx, c.fy, c.fz)
  local by_, bp = cy, cp
  if k.barrel then by_, bp = yaw_pitch(k.barrel[1], k.barrel[2], k.barrel[3]) end
  log('shot check %s (round %s, aimed by %s): moving %.1f ahead %.1f right, turning %.0f deg/s right %.0f up; at %.0f m'
      .. ' the round is %.2f m right %.2f m up of the arc; it flew %+.2f deg right %+.2f up of the camera (the barrel:'
      .. ' %+.2f, %+.2f)', w[5], k.kind, k.aim and 'the weapon' or 'the camera', k.mx * hx + k.my * hy,
      k.mx * hy - k.my * hx, -k.turn, k.nod,
      math.sqrt((x - c.x) ^ 2 + (y - c.y) ^ 2 + (z - c.z) ^ 2), dx * hy - dy * hx, dz,
      -(((ry - cy + 180) % 360) - 180), rp - cp, -(((ry - by_ + 180) % 360) - 180), rp - bp)
  check = nil
end

-- test.2: called every frame with the weapon drawn this frame (or nil)
function watch_shots(c, w, u, aim, muzzle)
  local down = throw_down
  if down and not was_throw and w and u then start_check(c, w, u, aim, muzzle) end
  was_throw = down
  cam_was = { now(), math.atan2(c.fy, c.fx), camera_pitch(c) }
  follow_check()
end

-- test.5: each C4 throw, the charge (a new unit of C4_CHARGE) is compared C4_AT s after it is first seen with the arc
-- as drawn on the hold's last frame: does walking sideways carry it (1.0.3-test.1 found it didn't)?
local C4_CHARGE, C4_AT = '9b75217d8312dd67', 0.25
local c4_check = nil
function watch_c4(c, h)
  local k = c4_check
  if h and h.c4 then
    if not k or k.done then
      k = { before = {} }
      for _, r in ipairs(all_units()) do k.before[r] = true end
      c4_check = k
    end
    local fh = math.sqrt(c.fx * c.fx + c.fy * c.fy)
    k.pts, k.at = path(c, true, release_point(c, h.unit, true, h.off)), now()
    k.mx, k.my = my_move()
    k.hx, k.hy = c.fx / fh, c.fy / fh
    k.cx, k.cy, k.cz = c.x, c.y, c.z
    return
  end
  if not k or k.done then return end
  local t = now()
  if t - k.at > 1 then
    log('c4 check: %s', k.charge and 'the charge went' or 'no charge seen')
    k.done = true
    return
  end
  if not k.charge then
    for _, r in ipairs(all_units()) do
      if not k.before[r] then
        k.before[r] = true
        if chef.unit_alive(r) and chef.unit_kind(r) == C4_CHARGE then
          k.charge, k.first = r, t
          record(r, 'c4', c)
        end
      end
    end
    return
  end
  if t - k.first < C4_AT then return end
  local x, y, z = chef.unit_position(k.charge)
  if not (x and chef.unit_alive(k.charge)) then return end
  -- the nearest point on the arc's segments
  local best, bx, by, bz = math.huge
  for i = 2, #k.pts do
    local p, q = k.pts[i - 1], k.pts[i]
    local dx, dy, dz = q[1] - p[1], q[2] - p[2], q[3] - p[3]
    local l2 = dx * dx + dy * dy + dz * dz
    local f = l2 > 0 and math.max(0, math.min(1, ((x - p[1]) * dx + (y - p[2]) * dy + (z - p[3]) * dz) / l2)) or 0
    local ax, ay, az = p[1] + dx * f, p[2] + dy * f, p[3] + dz * f
    local d = (x - ax) ^ 2 + (y - ay) ^ 2 + (z - az) ^ 2
    if d < best then best, bx, by, bz = d, ax, ay, az end
  end
  local hx, hy = k.hx, k.hy
  log('c4 check: moving %.1f ahead %.1f right; at %.0f m the charge is %.2f m right %.2f m up of the arc',
      k.mx * hx + k.my * hy, k.mx * hy - k.my * hx, math.sqrt((x - k.cx) ^ 2 + (y - k.cy) ^ 2 + (z - k.cz) ^ 2),
      (x - bx) * hy - (y - by) * hx, z - bz)
  k.done = true
end
end

-- ------------------------------------------------------------------ C4's mode by the crosshair
-- C4 is known for not showing which of its two is in the hand. While it is in mine (hand pose C4_GRIP) and its mode can
-- be read, an icon to the right of the crosshair, the game's own: an arrow up over a charge for DEPLOY, a toothed ring
-- for DETONATE. An option turns it off (another HUD mod may show it).
-- The icons are cut from the game's HUD atlas (tools/c4_icons.py) and shipped in the mod's patch, each at a few sizes
-- (the screen's drawing has no mipmaps): ICONS, put in by build.py, is mode -> { size, texture, ... } from the smallest.
-- The icon fills ICON_FILL of its texture's height. Where a texture can't be drawn (chef.bitmap gives false), the icon
-- is drawn with shapes after it, as 1.0.0 did.
local ICON_SIZE, ICON_GAP = 0.024, 0.06     -- of the screen's height: the icon's height, and from the centre to its left
local ICONS = "@ICONS@"
local ICON_FILL, ICON_ALPHA = 65 / 76, 200
if type(ICONS) == 'table' and chef.texture_sizes then
  local sizes = {}
  for _, l in pairs(ICONS) do sizes[l[#l]] = l end
  chef.texture_sizes(sizes)
end
local show_icon = true
if chef.has and chef.has('menu') then
  chef.title('Stratagem and C4 Trajectory')
  arc_color = chef.option('arc_color', { type = 'choice', label = 'Arc colour',
                                         choices = { 'Green', 'White', 'Blue', 'Red' }, default = 1 })
  chef.on_change('arc_color', function(v) arc_color = v end)
  show_icon = chef.option('c4_icon', { type = 'toggle', label = 'C4 mode icon by the crosshair', default = true }) ~= false
  chef.on_change('c4_icon', function(v) show_icon = v ~= false end)
  weapon_arcs = chef.option('weapon_arcs', { type = 'toggle', label = 'Weapon arcs (grenade launchers, rockets...)',
                                             default = true }) ~= false
  chef.on_change('weapon_arcs', function(v) weapon_arcs = v ~= false end)
  grenade.on = chef.option('grenade_arcs', { type = 'toggle', label = 'Grenade arcs (G held, or one in hand aimed)',
                                            default = true })
               ~= false
  chef.on_change('grenade_arcs', function(v) grenade.on = v ~= false end)
end
local icon_mode, icon_next = nil, 0

-- In a vehicle the icon shows only in C4's aim pose (1.0.0 kept it up all the time; 1.0.1-test.1-7 left it out): a
-- passenger leans out to aim, the driver can't aim. My helldiver seated in one is within VEHICLE_NEAR m of
-- its middle across, or within VEHICLE_SEAT m and VEHICLE_UP m or more above its base (standing by one, my feet are on
-- the ground). Seats measured: an FRV's 0.4-0.7 m off its middle and 0.6 m up, a tank's on its top 3.1 m off and 2.4 m
-- up (1.0.1-test.1-5; standing by an FRV, 2 m off and 0.4 m under its base). The vehicles: the FRVs, the tanks and the
-- exosuit (filediver's names, as in Extended Pickup Icons Range).
local VEHICLES = { cc21c7ffd3ebefb9 = true, ['2d85bfe3d8717fe5'] = true, ['9b2140378640432e'] = true,
                   ['16474112801385b6'] = true, b0c9faf4af8903f9 = true, ['79e4b3d2da5e45e3'] = true }
local VEHICLE_NEAR, VEHICLE_SEAT, VEHICLE_UP = 1.2, 4.5, 0.35
local vehicle_watch = chef.watch and chef.watch(VEHICLES, 0.5)

in_vehicle = function()
  if not (vehicle_watch and me) then return false end
  local best, bup
  for _, it in ipairs(vehicle_watch.items) do
    if chef.unit_alive(it.unit) then
      local x, y, z = chef.unit_position(it.unit)
      if x then
        local across = math.sqrt((x - me[1]) ^ 2 + (y - me[2]) ^ 2)
        if not best or across < best then best, bup = across, me[3] - z end
      end
    end
  end
  return best ~= nil and (best < VEHICLE_NEAR or (best < VEHICLE_SEAT and bup >= VEHICLE_UP))
end

local function draw_icon(mode)
  local w, h = chef.screen()
  if not (w and h) then return end
  local sz = math.floor(h * ICON_SIZE + 0.5)
  local layer = (chef.TOP or 0) + 1100      -- over the HUD and the map, under the menus
  local tex = type(ICONS) == 'table' and ICONS[mode]
  if tex and chef.bitmap then
    local box = sz / ICON_FILL
    if chef.bitmap(tex[#tex], w / 2 + h * ICON_GAP - (box - sz) / 2, h / 2 - box / 2, box, box,
                   chef.color(255, 255, 255, ICON_ALPHA), layer) then
      return
    end
  end
  local ink = chef.color(250, 250, 236, 190)
  local shade = chef.color(0, 0, 0, 110)
  -- a shadow 1/16 down and right, then the icon
  for pass = 1, 2 do
    local o = pass == 1 and math.max(1, sz / 16) or 0
    local col, l = pass == 1 and shade or ink, layer + pass
    local x, y = w / 2 + h * ICON_GAP + o, h / 2 - sz / 2 - o   -- the icon's bottom left
    if mode == 'deploy' then
      -- the game's icon on a grid 18 wide and 33.5 tall: an arrow up over a charge of two sticks, banded twice
      local u = sz / 33.5
      local function box(bx, by, bw, bh) chef.rect(x + bx * u, y + by * u, bw * u, bh * u, col, l) end
      chef.triangle(x + 9 * u, y + 33.5 * u, x, y + 27 * u, x + 18 * u, y + 27 * u, col, l)
      box(3.5, 22, 11, 5)
      for _, sx in ipairs({ 0, 10 }) do
        box(sx, 0, 8, 3)
        box(sx, 5, 8, 10)
        box(sx, 17, 8, 3)
      end
    else
      -- the game's icon: a ring with 20 teeth round it, open in the middle
      local r = sz / 2
      local cx, cy, base, half = x + r, y + r, r * 0.7, math.pi / 20
      for i = 0, 19 do
        local a = i * math.pi / 10
        chef.triangle(cx + math.sin(a) * r, cy + math.cos(a) * r, cx + math.sin(a - half) * base,
                      cy + math.cos(a - half) * base, cx + math.sin(a + half) * base, cy + math.cos(a + half) * base, col, l)
      end
      chef.ring(cx, cy, r * 0.42, r * 0.72, col, l)
    end
  end
end

local function c4_icon(c)
  if not show_icon then return end
  if now() >= icon_next then
    icon_next = now() + 0.1
    icon_mode = hand_pose() == C4_GRIP and (c4_posed or not in_vehicle()) and c4_mode(true) or nil
  end
  if icon_mode then draw_icon(icon_mode) end
end

-- ------------------------------------------------------------------ the hold's end

-- the hold, or nil once the throw has left my hand
local function follow_hold()
  if not hold then return nil end
  local h = hold
  local hx, hy, hz = h.pos[1], h.pos[2], h.pos[3]
  if h.off and me then hx, hy, hz = me[1] + h.off[1], me[2] + h.off[2], me[3] + h.off[3] end
  local gone = now() - h.at > (h.c4 and C4_HOLD or HOLD_MOST)
  if not gone and not h.c4 then
    local x, y, z
    if chef.unit_alive(h.unit) then x, y, z = chef.unit_position(h.unit) end
    gone = not x or (x - hx) ^ 2 + (y - hy) ^ 2 + (z - hz) ^ 2 >= HOLD_GONE * HOLD_GONE
  end
  if gone then
    hold = nil
    return nil
  end
  return h
end

-- ------------------------------------------------------------------ the frame
local said_world = nil

function M.update(dt)
  if said_world == nil then
    said_world = false
    log('Stratagem and C4 Trajectory %s, loader %s, api %s', VERSION, tostring(chef.loader_version), tostring(chef.api))
  end
  local c = chef.camera()
  if not (chef.world() and c) then return end
  if said_world ~= chef.world_id() then
    said_world = chef.world_id()
    ball, aiming, looking = nil, false, false
    c4_aim, c4_posed, c4_det, hold = false, false, nil, nil
  end
  update_feet(c)
  update_trail()
  read_buttons()
  read_input(c)
  read_c4(c)
  c4_icon(c)
  local h = follow_hold()
  local weapon, muzzle, weapon_unit, weapon_kind, aim
  if not (aiming or c4_aim or h) then weapon, muzzle, weapon_unit, weapon_kind = weapon_aimed(c) end
  if weapon then
    local turn, nod = camera_turn(c)
    aim = weapon_aim(c, weapon_kind, weapon_unit, math.sqrt(turn * turn + nod * nod) >= AIMING.STILL_TURN)
  end
  local nade = grenade.update(c, not (aiming or c4_aim or h or weapon))
  watch_shots(c, weapon, weapon_unit, aim, muzzle)
  watch_c4(c, h)
  lab_hook(c, weapon ~= nil)
  if aiming then
    draw_arc(c, false, release_point(c, ball, false))
  elseif c4_aim then
    draw_arc(c, true, release_point(c, c4_det, true))
  elseif h then
    draw_arc(c, h.c4, release_point(c, h.unit, h.c4, h.off))
  elseif weapon then
    draw_points(c, weapon_path(c, weapon, muzzle, aim))
  elseif nade then
    draw_points(c, nade)
  else
    clear_arc()
  end
end

function M.shutdown()
  if players then players.stop() end
  if det_watch then det_watch.stop() end
  if vehicle_watch then vehicle_watch.stop() end
  if ball_watch then ball_watch.stop() end
  if weapon_watch then weapon_watch.stop() end
end

return M
