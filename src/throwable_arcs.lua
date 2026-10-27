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
local VERSION = '1.0.3-test.6'

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

-- My velocity, from my feet over the last MOVE_OVER s. A throw is faster by my speed along where I aim, up to CARRY_MOST
-- m/s either way, and gets none of it across (1.0.3-test.1 to 5, 23 throws: walking forward throws farther and higher,
-- running no farther than walking, strafing no wider).
local MOVE_OVER, CARRY_MOST = 0.15, 3
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

-- ------------------------------------------------------------------ aiming
-- The balls come from a watch on their kind, always on: the loader asks the engine for that kind only, about 0.1 ms
-- every 0.5 s (test.13-17 ran it only after the stratagem key, which players who moved that key had to set in the
-- options; test.12 and before passed over every unit, 2.6-3.4 ms). A left click asks for a fresh list and looks for a
-- ball in hand for BALL_SCAN_FOR s; none, it is a shot.
local BALL_SCAN_FOR = 1
local ball_watch = chef.watch and chef.watch({ [STRATAGEM_BALL] = true }, 0.5)
local balls, held_since = {}, 0
local was_left, aiming, ball = false, false, nil
local looking = false

local function scan_balls()
  balls = {}
  if not ball_watch then return end
  for _, it in ipairs(ball_watch.items) do balls[#balls + 1] = it.unit end
end

-- the nearest stratagem ball in my hand, or nil
local function ball_in_hand(c)
  local best, bu
  for _, u in ipairs(balls) do
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
  scan_balls()
  update_feet(c)
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
local on_hold = nil              -- test builds: function(c, hold, what) at 'start' and 'end'
local on_frame = nil             -- test builds: function(c) each frame

local function start_hold(c, unit, c4)
  local x, y, z
  if unit and chef.unit_alive(unit) then x, y, z = chef.unit_position(unit) end
  if not x then hold = nil return end
  hold = { c4 = c4, unit = unit, at = now(), pos = { x, y, z },
           off = me and { x - me[1], y - me[2], z - me[3] } or nil }
  if on_hold then on_hold(c, hold, 'start') end
end

local function read_input(c)
  local t = now()
  local left = chef.mouse_down('left') == true
  local hold = left or chef.mouse_down('right') == true
  if not left then watch_pose(c) end
  if hold and not was_hold then
    held_since, looking = t, true
    if ball_watch then ball_watch.refresh() end
  end
  local held = false
  if was_left and not left and aiming then
    start_hold(c, ball, false)
    ball, ready_ball, looking = nil, nil, false   -- thrown
  elseif hold then
    if aiming then
      update_feet(c)
      held = still_in_hand(ball)
      if not held then ball, looking = nil, false end
    elseif pending then
      update_feet(c)
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
      scan_balls()
      update_feet(c)
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
  if not hold then pending = nil end
  was_left, was_hold = left, hold
  aiming = held
end

-- ------------------------------------------------------------------ C4
-- C4 is aimed with right mouse (left alone throws it at once): right held with C4 in my hand is the aim; it ends at
-- left (the throw) or when right is let go. Which weapon is in my hand: my helldiver's hand pose, the animation
-- variable weapon_selected, as NarrowHUD (luka189, Nexus 17882) reads it: C4_GRIP for C4 (its learned table: 42).
-- Without that variable, the hand alone: the C4 in my hand is the detonator's unit (filediver: equipment/backpacks/
-- c4_charge_backpack/c4_charge_detonator; its charge is no unit until it flies, and my helldiver's 1 mesh never
-- changes, test.24-25), held in my right hand (test.25, standing: about 0 ahead, 0.4 right, 1.05 up from my feet), and
-- right held it goes forward into the aim within 0.3 s, from about 0.40 m from my feet across to 0.53-0.55 m; C4_RIGHT
-- m or more to my right and not above C4_HIGH m (the throw raises it to 2.05-2.11 m). The aim pose is asked for with
-- the hand pose too (1.0.1): putting C4 away while aiming kept the pose a moment and drew the arc, and right in a
-- vehicle's driver seat (no aiming there) drew it as well. The aim pose: the detonator C4_PUSH m or more farther from
-- my feet (across) than it was nearest since right went down; kept while it stays C4_KEEP m or more farther. Its
-- distance, not how far ahead along the camera's heading (1.0.1-test.1): turning fast, my helldiver turns after the
-- camera, and seated in a vehicle it faces the vehicle's way, and the arc came and went with the heading.
-- After a throw, no arc for C4_REARM s: test.28 drew it again 0.2-0.3 s after each throw, from the arm still swinging
-- (0.8 ahead, 1.3-1.6 m up).
-- The charge is let go C4_RELEASE_UP m above the detonator in the aim pose (the arm swings up and throws from higher),
-- at about 22.4 m/s, C4_LIFT above the camera's pitch: fitted on 5 measured throws (test.26-30), 0.1 m off along 1-40 m.
local C4_DET = '51f50d6321f52f3d'
local C4_SPEED, C4_LIFT, C4_RELEASE_UP = 22.4, math.rad(4.4), 1.0
local C4_PUSH, C4_KEEP, C4_RIGHT, C4_HIGH = 0.1, 0.05, 0.15, 1.6
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
-- refuses the calls): the hand alone tells it, as before.
local C4_TYPE, C4_OPTIONS, C4_OWNER, C4_CARRY = 'kbv6zx', 'ozvglfc', 'g5g7b9d', 'n5jmvf'
local C4_SCAN = 2
local c4_obj = { goid = nil, world = nil, next = 0 }

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
  local v = chef.call_kind('GameSession.game_object_field', 'c4 carry', gs, goid, C4_CARRY)
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
       and peer_text(chef.call_kind('GameSession.game_object_field', 'c4 owner', gs, goid, C4_OWNER)) == peer_text(peer) then
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
  local v = tonumber(chef.call_kind('GameSession.game_object_field', 'c4 options', gs, c4_obj.goid, C4_OPTIONS))
  if not v then return nil end
  local m = math.floor(v / 256) % 4
  return (m == 0 and 'deploy') or (m == 1 and 'detonate') or nil, v
end

-- the nearest detonator in my hand, and where it is from my feet (ahead and right as the camera looks), or nil
local function det_in_hand(c)
  local fh = math.sqrt(c.fx * c.fx + c.fy * c.fy)
  if not (det_watch and me) or fh < 1e-6 then return nil end
  local hx, hy = c.fx / fh, c.fy / fh
  local best, bu, ahead, side, high
  for _, it in ipairs(det_watch.items) do
    local u = it.unit
    if chef.unit_alive(u) then
      local x, y, z = chef.unit_position(u)
      if x then
        local dx, dy, up = x - me[1], y - me[2], z - me[3]
        local across = math.sqrt(dx * dx + dy * dy)
        if across <= C4_HAND and up >= HAND_LOW and up <= HAND_HIGH and (not best or across < best) then
          best, bu, ahead, side, high = across, u, dx * hx + dy * hy, dx * hy - dy * hx, up
        end
      end
    end
  end
  return bu, ahead, side, high
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
  local right, left = chef.mouse_down('right') == true, chef.mouse_down('left') == true
  if right and not was_right then
    c4_least, c4_low = nil, nil
    if det_watch then det_watch.refresh() end
  end
  local held, posed = false, false
  if not right and now() >= grip_next then
    grip_next = now() + 0.2
    update_feet(c)
    hand_pose()
  end
  if right and not aiming and det_watch then
    update_feet(c)
    local u, ahead, side, high = det_in_hand(c)
    local grip = hand_pose()
    if grip == DIVE_GRIP and u and (c4_posed or high < C4_PRONE_UP) and now() - c4_grip_at <= C4_DIVE then grip = C4_GRIP end
    local ready = false
    if u and (grip == nil or grip == C4_GRIP) then
      local across = math.sqrt(ahead * ahead + side * side)
      c4_least, c4_low = math.min(c4_least or across, across), math.min(c4_low or high, high)
      ready = (grip ~= nil or side >= C4_RIGHT) and high <= C4_HIGH
              and (across - c4_least >= (c4_posed and C4_KEEP or C4_PUSH) or high - c4_low >= C4_RAISE)
      if grip == C4_GRIP then
        if in_vehicle() then
          if c4_posed then ready = true end
        elseif high < C4_LOW_UP then
          ready = true
        end
      end
      if ready then c4_ready_at = now() end
      if c4_posed and not ready and grip == C4_GRIP and now() - c4_ready_at < C4_GRACE then ready = true end
    end
    if c4_aim and left then
      c4_rearm = now() + C4_REARM
      start_hold(c, c4_det, true)
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
local COLOR = { 255, 255, 255 }
-- Parts of the arc came out faint blue now and then (1.0.1-test.3, 1.0.3-test.1): the game's temporal anti-aliasing /
-- upscaling blends a thin line (no motion of its own to follow) into what is around it, more so when it is two lines
-- with a gap. The arc is 3 lines a render pixel apart, 3 render pixels wide, at any render scale. The render scale: the game's settings file's
-- render resolution over the screen's height, read every SCALE_EVERY s.
local SCALE_EVERY = 2
local render_scale, scale_next = 1, 0
-- the arc is dashed by flight time: DASH segments drawn, GAP left out (about 1.3 m and 0.7 m). test.10-11 measured
-- dashes in px from the camera, so they slid along the arc whenever the camera moved: it rippled as you turned
local DASH, GAP = 2, 1
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
  local carried = math.max(-CARRY_MOST, math.min(CARRY_MOST, mx * hx + my * hy))
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
    t = t + STEP
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
        local k = math.sqrt(mx * mx + my * my + mz * mz) * px_angle / nl
        for _, o in ipairs(offsets) do
          local ox, oy, oz = nx * k * o, ny * k * o, nz * k * o
          chef.line(p[1] + ox, p[2] + oy, p[3] + oz, q[1] + ox, q[2] + oy, q[3] + oz, col)
        end
      end
    end
  end
end

local drew = false

local on_settings = nil          -- test builds: function() while the arc is drawn

local function draw_arc(c, c4, ox, oy, oz)
  local _, sh = chef.screen()
  if now() >= scale_next and chef.setting then
    scale_next = now() + SCALE_EVERY
    local r = chef.setting('render_settings.render_resolution')
    local rh = type(r) == 'table' and tonumber(r[2])
    render_scale = (rh and sh and sh > 0) and math.min(1, rh / sh) or 1
  end
  local px_angle = (tonumber(c.fov) or 0.96) / math.max(1, sh or 1080)
  local offsets = { -1 / render_scale, 0, 1 / render_scale }
  if on_settings then on_settings() end
  world_strip(c, path(c, c4, ox, oy, oz), chef.color(COLOR[1], COLOR[2], COLOR[3], 255), px_angle, offsets)
  drew = true
end

-- a line object keeps what it was last given until it is reset, and the loader resets it only when a line is drawn:
-- after the arc, one empty line far below the map clears it
local function clear_arc()
  if not drew then return end
  drew = false
  chef.line(0, 0, -10000, 0, 0, -10000, chef.color(0, 0, 0, 0))
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
  show_icon = chef.option('c4_icon', { type = 'toggle', label = 'C4 mode icon by the crosshair', default = true }) ~= false
  chef.on_change('c4_icon', function(v) show_icon = v ~= false end)
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
    update_feet(c)
    icon_mode = hand_pose() == C4_GRIP and (c4_posed or not in_vehicle()) and c4_mode(true) or nil
  end
  if icon_mode then draw_icon(icon_mode) end
end

-- ------------------------------------------------------------------ the hold's end

-- the hold, or nil once the throw has left my hand
local function follow_hold(c)
  if not hold then return nil end
  local h = hold
  local hx, hy, hz = h.pos[1], h.pos[2], h.pos[3]
  if h.off and me then hx, hy, hz = me[1] + h.off[1], me[2] + h.off[2], me[3] + h.off[3] end
  local gone, flying = now() - h.at > (h.c4 and C4_HOLD or HOLD_MOST), nil
  if not gone and not h.c4 then
    local x, y, z
    if chef.unit_alive(h.unit) then x, y, z = chef.unit_position(h.unit) end
    if not x or (x - hx) ^ 2 + (y - hy) ^ 2 + (z - hz) ^ 2 >= HOLD_GONE * HOLD_GONE then gone, flying = true, h.unit end
  end
  if gone then
    if on_hold then on_hold(c, h, 'end', flying) end
    hold = nil
    return nil
  end
  return h
end

-- ------------------------------------------------------------------ test builds only: moving throws
-- Does the arc match throws on the move? At each throw: my velocity then (from my feet over the last MOVE_OVER s), the
-- throw's real velocity (fitted on its flight from the release on: when the hold ends), and the drawn
-- one, all as forward / right as the camera looked and up; and how long the hold lasted. Logged per throw.
local said_render = nil
on_settings = function()
  local text = string.format('render scale %.2f, upscaling method %s quality %s, sharpening %s', render_scale,
    tostring(chef.setting('render_settings.upscaling_method')), tostring(chef.setting('render_settings.upscaling_quality')),
    tostring(chef.setting('render_settings.sharpening_enabled')))
  if text ~= said_render then said_render = text; log('arc drawn with %s', text) end
end
local measuring = nil            -- { c4, cam, pitch, move, drawn, start, release, unit, samples }

local C4_CHARGE = '9b75217d8312dd67'
local charge_watch = chef.watch and chef.watch({ [C4_CHARGE] = true }, 0.5)
local said_pose, pose_next = false, 0
on_frame = function(c)
  local t = now()
  if t >= pose_next then             -- the hand pose, when it changes (which weapons share C4's 42?)
    pose_next = t + 0.25
    local g = hand_pose()
    if g ~= said_pose then
      said_pose = g
      log('hand pose %s (C4 detonator %s)', tostring(g), det_watch and #det_watch.items > 0 and 'about' or 'none')
    end
  end
  local m = measuring
  if m and m.wait_c4 then            -- C4: the new charge, listed some time after it left the hand
    charge_watch.refresh()
    for _, it in ipairs(charge_watch.items) do
      if not m.before[it.unit] and chef.unit_alive(it.unit) then m.unit, m.wait_c4 = it.unit, nil end
    end
    if m.wait_c4 and t - m.release > 1.5 then
      log('throw (c4): no new charge seen in 1.5 s')
      measuring = nil
    end
    return
  end
  if not (m and m.unit) then return end
  if not chef.unit_alive(m.unit) or t - m.release > 2.5 then
    measuring = nil
    local s, ls = {}, nil              -- from 0.1 s after the release until it hits something (its speed halves)
    for i, p in ipairs(m.samples) do
      local q = m.samples[i - 1]
      if p[1] - m.release >= 0.1 then
        if q and p[1] > q[1] then
          local sp = math.sqrt((p[2] - q[2]) ^ 2 + (p[3] - q[3]) ^ 2 + (p[4] - q[4]) ^ 2) / (p[1] - q[1])
          if ls and sp < ls * 0.5 then break end
          ls = sp
        end
        s[#s + 1] = p
      end
    end
    if #s < 4 then log('throw (%s): too few samples (%d)', m.c4 and 'c4' or 'stratagem', #s) return end
    -- x, y as lines and z as a parabola in t (from the release): least squares
    local S, Sx, Sy, Sz = { 0, 0, 0, 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0, 0 }
    for _, p in ipairs(s) do
      local u = p[1] - m.release
      for k = 0, 4 do S[k + 1] = S[k + 1] + u ^ k end
      for k = 0, 2 do Sz[k + 1] = Sz[k + 1] + p[4] * u ^ k end
      for k = 0, 1 do Sx[k + 1] = Sx[k + 1] + p[2] * u ^ k; Sy[k + 1] = Sy[k + 1] + p[3] * u ^ k end
    end
    local d2 = S[1] * S[3] - S[2] * S[2]
    local vx, vy = (S[1] * Sx[2] - S[2] * Sx[1]) / d2, (S[1] * Sy[2] - S[2] * Sy[1]) / d2
    local A = { { S[1], S[2], S[3], Sz[1] }, { S[2], S[3], S[4], Sz[2] }, { S[3], S[4], S[5], Sz[3] } }
    for i = 1, 3 do
      for j = i + 1, 3 do
        local f = A[j][i] / A[i][i]
        for k = i, 4 do A[j][k] = A[j][k] - f * A[i][k] end
      end
    end
    local z = {}
    for i = 3, 1, -1 do
      local v = A[i][4]
      for k = i + 1, 3 do v = v - A[i][k] * z[k] end
      z[i] = v / A[i][i]
    end
    local fx, fy = m.cam[1], m.cam[2]
    local function parts(x, y) return x * fx + y * fy, x * fy - y * fx end
    local flf, flr = parts(vx, vy)
    local drf, drr = parts(m.drawn[1], m.drawn[2])
    local mvf, mvr = parts(m.move[1], m.move[2])
    log('throw (%s): moving %.1f fwd %.1f right %.1f up m/s; flew %.1f fwd %.1f right %.1f up (gravity %.2f, %d samples); '
        .. 'drawn %.1f fwd %.1f right %.1f up; off by %.1f fwd %.1f right %.1f up; camera %.1f deg; held the arc %.2f s',
        m.c4 and 'c4' or 'stratagem', mvf, mvr, m.move[3], flf, flr, z[2], -2 * z[3], #s, drf, drr, m.drawn[3],
        flf - drf, flr - drr, z[2] - m.drawn[3], math.deg(m.pitch), m.release - m.start)
    return
  end
  local x, y, z = chef.unit_position(m.unit)
  if x then m.samples[#m.samples + 1] = { t, x, y, z } end
end

on_hold = function(c, h, what, flying)
  if what == 'start' then
    local move = { my_move() }
    local fh = math.sqrt(c.fx * c.fx + c.fy * c.fy)
    local vx, vy, vz = throw_velocity(c, h.c4)
    measuring = { c4 = h.c4, cam = { c.fx / fh, c.fy / fh }, pitch = camera_pitch(c), move = move,
                  drawn = { vx, vy, vz }, start = now(), samples = {}, before = {} }
    if h.c4 and charge_watch then
      for _, it in ipairs(charge_watch.items) do measuring.before[it.unit] = true end
    end
  elseif measuring and not measuring.unit then
    if flying then
      measuring.unit, measuring.release = flying, now()
    elseif h.c4 and charge_watch then  -- fitted from where it left the hand, C4_HOLD s after the press
      measuring.release, measuring.wait_c4 = h.at + C4_HOLD, true
    else
      log('throw (%s): nothing seen leaving the hand in %.1f s', h.c4 and 'c4' or 'stratagem', HOLD_MOST)
      measuring = nil
    end
  end
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
  read_input(c)
  read_c4(c)
  c4_icon(c)
  update_feet(c)
  update_trail()
  local h = follow_hold(c)
  if on_frame then on_frame(c) end
  if aiming then
    draw_arc(c, false, release_point(c, ball, false))
  elseif c4_aim then
    draw_arc(c, true, release_point(c, c4_det, true))
  elseif h then
    draw_arc(c, h.c4, release_point(c, h.unit, h.c4, h.off))
  else
    clear_arc()
  end
end

function M.shutdown()
  if players then players.stop() end
  if det_watch then det_watch.stop() end
  if vehicle_watch then vehicle_watch.stop() end
  if ball_watch then ball_watch.stop() end
  if charge_watch then charge_watch.stop() end
end

return M
