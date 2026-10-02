-- Stryker vehicle for Server Addons, rev 12.
-- Commands: :spawn stryker, :stryker driver|commander|board, :fire, :vehicles, :cleanup vehicles
--
-- Driver seat drives. Commander seat aims the .50 cal (A/D traverse, W/S elevate) and fires
-- when the commander clicks the gun (or clicks anywhere / uses :fire). The parked position is
-- kept in a marker part so the vehicle is rebuilt in the same spot after a server save loads.
--
-- How it moves: the chassis stays ANCHORED and every other part is welded to it, exactly like
-- the input lab's test gun. Each tick the script sets the chassis CFrame (raycasts find the
-- ground and walls), so the server always controls it and the welded detail costs no physics.

local Strykers = {}
local SCALE = 1.25
local MAX_SPEED = 50
local REVERSE_SPEED = 15
local ACCELERATION = 0.05 -- share of the gap to target speed closed per 0.03 s
local TURN_RADIUS = 45
local MAX_STEER = math.rad(30)
local MARKER_NAME = "StrykerSpawnMarker"
local MARKER_UPDATE_INTERVAL = 0.5
local DETAIL = true -- full detail: bolts, lug nuts, valves, jacket holes
local LIMITS = { MAX_ACTIVE = 4, SPAWN_COOLDOWN = 15, CLEANUP_COOLDOWN = 30 }
local PERF = { IDLE_TICK = 0.25, DRIVE_TICK = 0.03, CREW_TICK = 0.25, WHEEL_TICK = 0.1 }
local DRIVE = {
  GRAVITY = 196.2, MAX_STEP = 3.5, PROBE_UP = 4, PROBE_DOWN = 10, GROUND_EVERY = 0.5,
  WALL_HEIGHTS = { 4.0, 7.5 }, WALL_NORMAL_Y = 0.7, TILT_BLEND = 0.25, FALL_LIMIT = -400,
}
local COPY = {
  PREFIX = "StrykerAddon#", REVISION = 12, name = false, root = false, retired = false,
  token = false, stamp = 0, world = false,
}

local function rgb(r, g, b) return Color3.new(r / 255, g / 255, b / 255) end
local COLOR = {
  AIM_DOT = Color3.new(1, 0.08, 0.08), TAN = rgb(196, 173, 128), TAN_DARK = rgb(158, 138, 100),
  STEEL = rgb(54, 54, 50), BLACK = rgb(28, 28, 26), GUN = rgb(34, 34, 32), RUBBER = rgb(26, 26, 26),
  OLIVE = rgb(86, 92, 58), INTERIOR = rgb(92, 96, 84), SEAT = rgb(60, 62, 48), LAMP = rgb(255, 242, 210),
  RED = rgb(210, 30, 24), DIM_RED = rgb(110, 24, 20), CANVAS = rgb(125, 114, 82), AMBER = rgb(255, 150, 30),
  GLASS = rgb(30, 40, 38),
}
local MAT = {
  SMOOTH = Enum.Material.SmoothPlastic, METAL = Enum.Material.Metal, RUBBER = Enum.Material.Rubber,
  NEON = Enum.Material.Neon, FABRIC = Enum.Material.Fabric,
}
local SHAPE = { CYLINDER = Enum.PartType.Cylinder }
local DIM = {
  CHASSIS_Y = 1.9, CHASSIS_Z = 3.96, ROOT_DENSITY = 30, WHEEL_R = 1.73, WHEEL_W = 1.3, WHEEL_X = 3.75,
  AXLES = { -6.52, -2.55, 1.75, 6.17 }, NOSE = -11.6, TAIL = 11.6, HULL_X = 4.3, LOWER_X = 2.9, BELLY_Y = 1.8,
  FLOOR_Y = 2.0, SPONSON_Y = 3.7, NOSE_Y = 5.4, ROOF_Y = 6.7, GLACIS_Z = -7.1, BULKHEAD_Z = -1.0, RAMP_W = 5.0,
  RAMP_H = 4.4, RAMP_OPEN = math.rad(114), RWS_X = 1.5, RWS_Z = -1.0, GUN_Y = 9.5, SEAT_Y = 3.0, DRIVER_X = -2.4,
  DRIVER_Z = -6.8, COMMANDER_X = 0.6, COMMANDER_Z = -3.0, TROOP_X = 2.2, TROOP_Z = { 2.4, 4.8, 7.2, 9.6 },
}
local GUN = {
  RANGE = 1000, TRAVERSE_SPEED = math.rad(60), ELEVATE_SPEED = math.rad(45), MIN_PITCH = math.rad(-20),
  MAX_PITCH = math.rad(60), BURST = 5, ROUND_GAP = 0.09, COOLDOWN = 0.8, SPREAD = math.rad(0.3), MUZZLE = 4.95,
  RAMP_TIME = 2.0, DOT_EVERY = 0.08, CLICK_RANGE = 80, HIT_RADIUS = 2.5, DAMAGE = 25, TRACER_SPEED = 900,
  RECOIL = 0.3, SEAT_RADIUS = 4.5, NAG_EVERY = 3,
  AUTO = false, -- true = fires by itself when the red dot is on an enemy
}

local function rx(deg) return CFrame.Angles(math.rad(deg), 0, 0) end
local function ry(deg) return CFrame.Angles(0, math.rad(deg), 0) end
local function rz(deg) return CFrame.Angles(0, 0, math.rad(deg)) end

local function flatFrame(pos, forward)
  local flat = Vector3.new(forward.X, 0, forward.Z)
  if flat.Magnitude < 0.01 then flat = Vector3.new(0, 0, -1) end
  return CFrame.new(pos, pos + flat.Unit)
end

local function weld(part0, part1)
  local w = Instance.new("WeldConstraint")
  w.Part0 = part0
  w.Part1 = part1
  w.Parent = part0
  return w
end

-- Same as the input lab's part(): set Parent, then hand the instance to f(). If f() moved it
-- out to the map root, put it back so the whole vehicle stays in one Model (one Destroy()
-- removes everything, and raycasts can skip the vehicle by filtering that Model).
local function place(inst, parent)
  if parent then pcall(function() inst.Parent = parent end) end
  pcall(f, inst)
  if parent then
    local home = false
    pcall(function() home = inst.Parent == parent end)
    if not home then pcall(function() inst.Parent = parent end) end
  end
  return inst
end

local function tell(message, player) pcall(announce, message, player) end

local function playerSet()
  local set = {}
  local ok, list = pcall(getPlayers)
  if ok and type(list) == "table" then
    for _, p in ipairs(list) do set[p] = true end
  end
  return set
end

local function playerCFrame(name)
  local ok, cf = pcall(getPlayerPosition, name)
  if not ok then return nil end
  if typeof(cf) == "CFrame" then return cf end
  if typeof(cf) == "Vector3" then return CFrame.new(cf) end
  return nil
end

local function playerPos(name)
  local cf = playerCFrame(name)
  if cf then return cf.Position end
  return nil
end

local function healthOf(name)
  local ok, hp = pcall(getPlayerHealth, name)
  if ok and type(hp) == "number" then return hp end
  return -1
end

local function occupantName(seat, online)
  local occupant = seat.Occupant
  if not occupant then return nil end
  online = online or playerSet()
  local ok, name = pcall(function() return occupant.Parent.Name end)
  if ok and type(name) == "string" and online[name] then return name end
  local seatPos = seat.Position
  local best, bestDist = nil, 4
  for candidate in pairs(online) do
    local pos = playerPos(candidate)
    if pos then
      local d = (pos - seatPos).Magnitude
      if d < bestDist then best, bestDist = candidate, d end
    end
  end
  return best
end

local function nameOf(who)
  if type(who) == "string" then return who end
  local ok, name = pcall(function() return who.Name end)
  if ok and type(name) == "string" then return name end
  return nil
end

local function humanoidOf(model)
  local ok, humanoid = pcall(function() return model:FindFirstChildOfClass("Humanoid") end)
  if ok then return humanoid end
  return nil
end

local function rayParams(ignore)
  local ok, params = pcall(function()
    local p = RaycastParams.new()
    p.FilterDescendantsInstances = ignore
    p.FilterType = Enum.RaycastFilterType.Exclude
    return p
  end)
  if ok then return params end
  return nil
end

local function castRay(from, direction, params)
  local ok, hit = pcall(raycast, from, direction, params)
  if ok then return hit end
  return nil
end

local function groundBelow(pos)
  local hit = castRay(pos + Vector3.new(0, 2, 0), Vector3.new(0, -60, 0), rayParams({}))
  if hit and type(hit.Instance) ~= "string" then return hit.Position end
  return nil
end

local function removePart(p)
  pcall(function() p:Destroy() end)
end

-- Every instance a Stryker owns lives inside its Model, so one Destroy() removes it all.
-- The list is a second net in case anything escaped the model.
local function destroyEntry(entry)
  entry.dead = true
  pcall(function() entry.car:Destroy() end)
  for _, p in ipairs(entry.parts or {}) do
    pcall(function() if p.Parent ~= nil then p:Destroy() end end)
  end
end

local function destroyStryker(key)
  local entry = Strykers[key]
  if entry then
    destroyEntry(entry)
    Strykers[key] = nil
  end
end

local function dispose(inst)
  if not inst then return end
  pcall(function() inst:Destroy() end)
  local stuck = false
  pcall(function() stuck = inst.Parent ~= nil end)
  if stuck then pcall(function() inst.Name = inst.Name .. "#junk" end) end
end

local function alive(entry)
  if entry.dead then return false end
  local ok, parent = pcall(function() return entry.car.Parent end)
  return ok and parent ~= nil
end

---------------------------------------------------------------------------------------------
-- Targeting
---------------------------------------------------------------------------------------------

local function lineOfFire(car, from, dir, range, skip)
  local params = rayParams({ car })
  local origin = from
  for _ = 1, 4 do
    local hit = castRay(origin, dir * range, params)
    if not hit then break end
    local own = false
    pcall(function()
      if type(hit.Instance) == "string" then
        own = skip[hit.Instance] == true
      else
        own = hit.Instance:IsDescendantOf(car) or skip[hit.Instance.Parent.Name] == true
      end
    end)
    if own then
      origin = hit.Position + dir * 0.3
    else
      return hit.Position, hit.Instance
    end
  end
  return from + dir * range, false
end

local function mapRoot()
  if not COPY.root then
    pcall(function()
      local probe = Instance.new("Part")
      probe.Name = "StrykerProbe"
      probe.Anchored = true
      probe.CanCollide = false
      probe.Transparency = 1
      probe.CFrame = CFrame.new(0, 3000, 0)
      f(probe)
      COPY.root = probe.Parent
      probe:Destroy()
    end)
  end
  return COPY.root
end

local function worldRoot()
  if not COPY.world then
    pcall(function()
      local node = mapRoot()
      for _ = 1, 4 do
        if node.ClassName == "Workspace" then
          COPY.world = node
          return
        end
        node = node.Parent
      end
    end)
    if not COPY.world then COPY.world = mapRoot() end
  end
  return COPY.world
end

local function isTarget(x)
  return type(x) == "table" and x.isTarget == true
end

-- Generous hit test against players only (raycasts already find NPC parts and player bodies).
-- Only used when a round is actually fired, never for the 12 Hz aim dot.
local function targetOnLine(from, dir, range, skip)
  local best, bestT = nil, range
  for p in pairs(playerSet()) do
    if not skip[p] then
      local pos = playerPos(p)
      if pos then
        local rel = pos - from
        local t = rel:Dot(dir)
        if t > 0 and t < bestT and (rel - dir * t).Magnitude <= GUN.HIT_RADIUS and healthOf(p) > 0 then
          best, bestT = { name = p, player = p, isTarget = true }, t
        end
      end
    end
  end
  return best, bestT
end

local function aimPoint(entry, from, dir, range, assist)
  local to, hitInst = lineOfFire(entry.car, from, dir, range, entry.aboard or {})
  if assist then
    local target, t = targetOnLine(from, dir, (to - from).Magnitude + 1, entry.aboard or {})
    if target then return from + dir * t, target end
  end
  return to, hitInst
end

local function victimOf(hit)
  if not hit then return nil end
  if isTarget(hit) then return hit end
  if type(hit) == "string" then return { name = hit, player = hit, isTarget = true } end
  local online = playerSet()
  local node = hit
  for _ = 1, 6 do
    local ok, parent = pcall(function() return node.Parent end)
    if not ok or not parent then return nil end
    node = parent
    local humanoid = humanoidOf(node)
    if humanoid then
      if online[node.Name] then return { name = node.Name, player = node.Name, isTarget = true } end
      return { name = node.Name, humanoid = humanoid, model = node, isTarget = true }
    end
  end
  return nil
end

local function isEnemy(target, gunner)
  if not isTarget(target) then return false end
  if not target.player then return true end
  if not gunner then return false end
  local ok1, mine = pcall(getTeam, gunner)
  local ok2, theirs = pcall(getTeam, target.player)
  return ok1 and ok2 and mine ~= nil and theirs ~= nil and mine ~= theirs
end

---------------------------------------------------------------------------------------------
-- Effects: the input lab's method. Each effect is one tween() instead of a server loop that
-- moves parts every frame.
---------------------------------------------------------------------------------------------

local FX = {
  FLASH = Color3.new(1, 0.86, 0.5), FIRE = Color3.new(1, 0.46, 0.12), SPARK = Color3.new(1, 0.82, 0.35),
  TRACER = Color3.new(1, 0.62, 0.2), DUST = Color3.new(0.7, 0.62, 0.47),
}

local function linear(t)
  return TweenInfo.new(t, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, false, 0)
end

local function removeLater(p, t)
  task.spawn(function()
    task.wait(t)
    removePart(p)
  end)
end

local function fxPart(holder, name, ball, size, cf, color, transparency)
  local p = Instance.new("Part")
  p.Name = name
  if ball then p.Shape = Enum.PartType.Ball end
  p.Size = size
  p.CFrame = cf
  p.Color = color
  p.Material = Enum.Material.Neon
  p.Transparency = transparency
  p.Anchored = true
  p.CanCollide = false
  p.CanQuery = false
  p.CanTouch = false
  return place(p, holder)
end

-- grow and fade out, then delete
local function fade(p, life, grow)
  pcall(tween, p, linear(life), { Transparency = 1, Size = p.Size * grow })
  removeLater(p, life + 0.05)
end

local function glow(p, color, brightness, range)
  pcall(function()
    local light = Instance.new("PointLight")
    light.Color = color
    light.Brightness = brightness
    light.Range = range
    light.Parent = p
  end)
end

local function smoke(holder, pos, size, rise, color, life)
  local p = fxPart(holder, "SmokePuff", false, Vector3.new(0.2, 0.2, 0.2), CFrame.new(pos), color, 1)
  local ok, cloud = pcall(function()
    local s = Instance.new("Smoke")
    s.Size = size
    s.RiseVelocity = rise
    s.Opacity = 0.5
    s.Color = color
    s.Parent = p
    return s
  end)
  task.spawn(function()
    task.wait(life)
    if ok then pcall(function() cloud.Enabled = false end) end
    task.wait(3)
    removePart(p)
  end)
end

local function impact(holder, pos, color, size)
  local p = fxPart(holder, "Impact", true, Vector3.new(size, size, size), CFrame.new(pos), color, 0)
  glow(p, color, 2, 8)
  fade(p, 0.2, 3)
end

-- A glowing round that flies from the muzzle to the impact point on one tween, like the lab's
-- shell. Returns how long the flight takes.
local function tracer(holder, from, to, speed)
  local dist = (to - from).Magnitude
  if dist < 0.5 then return 0 end
  local dir = (to - from).Unit
  local flight = math.max(0.03, dist / speed)
  local p = fxPart(holder, "Tracer", false, Vector3.new(0.18, 0.18, 2.5), CFrame.new(from, from + dir), FX.TRACER, 0)
  pcall(tween, p, linear(flight), { CFrame = CFrame.new(to, to + dir) })
  removeLater(p, flight)
  return flight
end

---------------------------------------------------------------------------------------------
-- Damage and firing
---------------------------------------------------------------------------------------------

local function hurtPlayer(name, amount)
  local hp = healthOf(name)
  if hp <= 0 then return false end
  if hp - amount <= 0 then
    pcall(kill, name)
    return true
  end
  pcall(damage, name, amount)
  return false
end

local function hurtNpc(humanoid, amount)
  local dead = false
  pcall(function()
    humanoid.Health = math.max(0, humanoid.Health - amount)
    dead = humanoid.Health <= 0
  end)
  return dead
end

local function strike(victim, amount, safe)
  if not victim then return nil end
  if victim.player then
    if safe[victim.player] then return nil end
    return hurtPlayer(victim.player, amount)
  end
  return hurtNpc(victim.humanoid, amount)
end

-- Is this player sitting in this seat? Same check as the lab's seatedInLab(): the occupant's
-- name if the game lets us read it, otherwise the player standing right on the seat.
local function inSeat(seat, player)
  if not seat or not player then return false end
  local occupied = false
  pcall(function() occupied = seat.Occupant ~= nil end)
  if not occupied then return false end
  local ok, name = pcall(function() return seat.Occupant.Parent.Name end)
  if ok and name == player then return true end
  local pos = playerPos(player)
  return pos ~= nil and (pos - seat.Position).Magnitude < GUN.SEAT_RADIUS
end

local function fireBurst(entry, shooter)
  local hits, killed, order = {}, {}, {}
  for round = 1, GUN.BURST do
    if round > 1 then task.wait(GUN.ROUND_GAP) end
    if not alive(entry) then return end
    local muzzle = entry.cradle.CFrame * CFrame.new(0, 0, -GUN.MUZZLE * SCALE)
    local spread = CFrame.Angles((math.random() - 0.5) * 2 * GUN.SPREAD, (math.random() - 0.5) * 2 * GUN.SPREAD, 0)
    local dir = (muzzle * spread).LookVector
    local from = muzzle.Position
    local flash = fxPart(entry.car, "MuzzleFlash", true, Vector3.new(0.9, 0.9, 0.9), CFrame.new(from + dir * 0.5), FX.FLASH, 0)
    glow(flash, FX.FLASH, 3, 12)
    fade(flash, 0.08, 2)
    entry.recoil = GUN.RECOIL
    -- Hitscan: where the round lands is decided now; the tracer just shows it getting there.
    local to, hit = aimPoint(entry, from, dir, GUN.RANGE, true)
    local victim = victimOf(hit)
    local dead = strike(victim, GUN.DAMAGE, entry.aboard or {})
    if dead ~= nil then
      if not hits[victim.name] then table.insert(order, victim.name) end
      hits[victim.name] = (hits[victim.name] or 0) + 1
      if dead then killed[victim.name] = true end
    end
    local flight = tracer(entry.car, from, to, GUN.TRACER_SPEED)
    if hit then
      task.spawn(function()
        task.wait(flight)
        if not alive(entry) then return end
        if dead ~= nil then
          impact(entry.car, to, FX.FIRE, 0.6)
        else
          impact(entry.car, to, FX.SPARK, 0.4)
          smoke(entry.car, to, 1.5, 2, FX.DUST, 0.25)
        end
      end)
    end
  end
  local lines = {}
  for _, name in ipairs(order) do
    local text = name .. " hit " .. hits[name] .. "x"
    if killed[name] then text = text .. ", killed" end
    table.insert(lines, text)
  end
  if #lines > 0 and shooter then tell(".50 cal: " .. table.concat(lines, "; "), shooter) end
end

local function shoot(entry, shooter)
  if tick() < entry.nextBurst then return end
  entry.nextBurst = tick() + GUN.BURST * GUN.ROUND_GAP + GUN.COOLDOWN
  task.spawn(fireBurst, entry, shooter)
end

-- Called straight from the ClickDetector, like the lab's test gun: no flag for another loop
-- to pick up. Only the player sitting in the commander seat can fire.
local function gunnerFire(entry, who)
  local name = nameOf(who)
  if not name or not alive(entry) or not entry.allSeats then return end
  local gunSeat = entry.allSeats[2].seat
  if inSeat(gunSeat, name) then
    entry.commander = entry.commander or name
    shoot(entry, name)
    return
  end
  entry.nagged = entry.nagged or {}
  if tick() - (entry.nagged[name] or 0) > GUN.NAG_EVERY then
    entry.nagged[name] = tick()
    tell("Sit in the Stryker's commander seat to fire the .50.", name)
  end
end

---------------------------------------------------------------------------------------------
-- Seats, prompts, aim dot
---------------------------------------------------------------------------------------------

local function seatPlayer(seat, who, name)
  local sat = false
  pcall(function()
    local character = nil
    if type(who) ~= "string" then character = who.Character end
    if not character then character = worldRoot():FindFirstChild(name) end
    seat:Sit(character:FindFirstChildOfClass("Humanoid"))
    sat = true
  end)
  if not sat and name then pcall(setPlayerPosition, name, seat.CFrame * CFrame.new(0, 2.5, 0)) end
end

local function setEnabled(prompt, on)
  if prompt and prompt.Enabled ~= on then prompt.Enabled = on end
end

local function setPromptField(prompt, field, text)
  if prompt and prompt[field] ~= text then prompt[field] = text end
end

local function newPrompt(parent, name, key, action, objectText, range, hold)
  local prompt = Instance.new("ProximityPrompt")
  prompt.Name = name
  prompt.ActionText = action
  prompt.ObjectText = objectText
  prompt.KeyboardKeyCode = key
  prompt.HoldDuration = hold
  prompt.MaxActivationDistance = range
  prompt.RequiresLineOfSight = false
  prompt.Parent = parent
  return prompt
end

local function makeAimDot(car, at)
  local dot = Instance.new("Part")
  dot.Name = "AimDot"
  dot.Shape = Enum.PartType.Ball
  dot.Size = Vector3.new(0.8, 0.8, 0.8)
  dot.Color = COLOR.AIM_DOT
  dot.Material = MAT.NEON
  dot.Transparency = 1
  dot.CFrame = at
  dot.Anchored = true
  dot.CanCollide = false
  dot.CanQuery = false
  dot.CanTouch = false
  return place(dot, car)
end

local function showAimDot(entry, from, dir, range)
  local pos, hit = aimPoint(entry, from, dir, range, false)
  local size = math.max(0.6, (pos - from).Magnitude * 0.012)
  pcall(function()
    if not entry.dotAt or (pos - entry.dotAt).Magnitude > 0.05 then
      entry.aimDot.CFrame = CFrame.new(pos)
      entry.dotAt = pos
    end
    if math.abs(size - entry.dotSize) > 0.1 * size then
      entry.aimDot.Size = Vector3.new(size, size, size)
      entry.dotSize = size
    end
    if entry.aimDot.Transparency ~= 0 then entry.aimDot.Transparency = 0 end
  end)
  return hit
end

local function hideAimDot(entry)
  pcall(function()
    if entry.aimDot.Transparency ~= 1 then entry.aimDot.Transparency = 1 end
  end)
end

local function keepRunning(entry, name, fn)
  task.spawn(function()
    local lastTold, failures = 0, 0
    while alive(entry) do
      local ok, err = pcall(fn)
      if ok then return end
      failures = failures + 1
      print("[Stryker] " .. name .. " loop error: " .. tostring(err))
      if tick() - lastTold > 10 then
        lastTold = tick()
        tell("Stryker " .. name .. " hit an error and restarted: " .. tostring(err), entry.owner)
      end
      task.wait(math.min(10, failures)) -- back off instead of spinning on a permanent error
    end
  end)
end

---------------------------------------------------------------------------------------------
-- Builder
---------------------------------------------------------------------------------------------

-- Every part goes through place(): Parent into the car Model, then f(), then back into the
-- Model if f() moved it. The old code let f() pull parts out to the map root, so car:Destroy()
-- and the gun's ray filter missed them, and every respawn or save left loose parts behind.
local function newKit(car, root, entry)
  local k = { parts = {}, wheels = {}, troopSeats = {} }
  entry.parts = k.parts
  function k.at(x, y, z) return root * CFrame.new(x * SCALE, y * SCALE, z * SCALE) end
  function k.off(x, y, z) return CFrame.new(x * SCALE, y * SCALE, z * SCALE) end
  function k.facing(x, y, z, dx, dy, dz)
    local p = Vector3.new(x, y, z) * SCALE
    return root * CFrame.new(p, p + Vector3.new(dx, dy, dz))
  end
  function k.make(className, name, size, cf, color, material, weldTo, shape)
    if entry.dead or not car.Parent then error("removed while it was being built", 0) end
    local p = Instance.new(className)
    p.Name = name
    if shape then p.Shape = shape end
    p.Size = size * SCALE
    p.CFrame = cf
    p.Color = color
    p.Material = material
    p.Anchored = true
    p.CanCollide = false
    p.CanTouch = false
    p.CanQuery = false
    p.Massless = true
    place(p, car)
    if weldTo then weld(weldTo, p) end
    table.insert(k.parts, p)
    if #k.parts % 25 == 0 then task.wait() end
    return p
  end
  function k.block(name, sx, sy, sz, cf, color, material, weldTo)
    return k.make("Part", name, Vector3.new(sx, sy, sz), cf, color, material, weldTo, false)
  end
  function k.wedge(name, sx, sy, sz, cf, color, material, weldTo)
    return k.make("WedgePart", name, Vector3.new(sx, sy, sz), cf, color, material, weldTo, false)
  end
  function k.cylinder(name, length, diameter, cf, color, material, weldTo)
    return k.make("Part", name, Vector3.new(length, diameter, diameter), cf, color, material, weldTo, SHAPE.CYLINDER)
  end
  function k.bolt(cf, weldTo)
    if not DETAIL then return nil end
    return k.cylinder("Bolt", 0.06, 0.16, cf, COLOR.TAN_DARK, MAT.METAL, weldTo)
  end
  -- A hull panel players can't walk through.
  function k.solid(p)
    p.CanCollide = true
    p.CanQuery = true
    return p
  end
  function k.seat(className, name, cf, weldTo)
    local s = k.make(className, name, Vector3.new(1.5, 0.4, 1.4), cf, COLOR.SEAT, MAT.FABRIC, weldTo, false)
    s.CanCollide = true
    s.CanTouch = true
    s.CanQuery = true
    return s
  end
  -- invisible handle that holds a prompt and can be clicked to get in
  function k.anchor(name, x, y, z, weldTo)
    local p = k.block(name, 1.6, 2.4, 1.6, k.at(x, y, z), COLOR.BLACK, MAT.SMOOTH, weldTo)
    p.Transparency = 1
    p.CanQuery = true
    return p
  end
  function k.joint(name, part0, part1, offset, c1)
    local j = Instance.new("Weld")
    j.Name = name
    j.Part0 = part0
    j.Part1 = part1
    j.C0 = offset
    j.C1 = c1
    j.Parent = part0
    return j
  end
  return k
end

local function buildWheel(k, name, x, z, steer)
  local s = 1
  if x < 0 then s = -1 end
  local r, w, y = DIM.WHEEL_R, DIM.WHEEL_W, DIM.WHEEL_R
  local tyre = k.cylinder(name, w, r * 2, k.at(x, y, z), COLOR.RUBBER, MAT.RUBBER, false)
  tyre.CanCollide = true
  tyre.CanQuery = true
  local face = x + s * w / 2
  k.cylinder("Rim", 0.1, r * 1.2, k.at(face, y, z), COLOR.TAN, MAT.SMOOTH, tyre)
  k.cylinder("Hub", 0.28, r * 0.55, k.at(face + s * 0.12, y, z), COLOR.TAN_DARK, MAT.METAL, tyre)
  k.cylinder("HubCap", 0.12, r * 0.25, k.at(face + s * 0.3, y, z), COLOR.STEEL, MAT.METAL, tyre)
  if DETAIL then
    k.cylinder("TyreValve", 0.2, 0.12, k.at(face + s * 0.25, y + r * 0.25, z + r * 0.12), COLOR.BLACK, MAT.METAL, tyre)
    for lug = 0, 7 do
      local a = lug * math.pi / 4
      k.cylinder("LugNut", 0.12, 0.15, k.at(face + s * 0.1, y + r * 0.42 * math.cos(a), z + r * 0.42 * math.sin(a)),
        COLOR.STEEL, MAT.METAL, tyre)
    end
  end
  local j = k.joint("WheelJoint", k.chassis, tyre, k.off(x, y - DIM.CHASSIS_Y, z - DIM.CHASSIS_Z), CFrame.new())
  table.insert(k.wheels, { weld = j, base = j.C0, steer = steer })
end

local function buildHull(k)
  local c = k.chassis
  local at, block, wedge, cylinder, solid = k.at, k.block, k.wedge, k.cylinder, k.solid
  local hx, lx = DIM.HULL_X, DIM.LOWER_X
  local sp, roof = DIM.SPONSON_Y, DIM.ROOF_Y
  local bz, tail = DIM.BULKHEAD_Z, DIM.TAIL
  local troopLen = tail - bz
  local troopZ = (tail + bz) / 2
  local frontLen = DIM.GLACIS_Z - DIM.NOSE
  local frontZ = (DIM.GLACIS_Z + DIM.NOSE) / 2
  block("Floor", lx * 2, DIM.FLOOR_Y - DIM.BELLY_Y, tail + 9.4, at(0, (DIM.FLOOR_Y + DIM.BELLY_Y) / 2, (tail - 9.4) / 2), COLOR.TAN_DARK, MAT.SMOOTH, c)
  block("LowerFront", lx * 2, sp - DIM.FLOOR_Y, bz + 9.4, at(0, (sp + DIM.FLOOR_Y) / 2, (bz - 9.4) / 2), COLOR.TAN, MAT.SMOOTH, c)
  wedge("LowerGlacis", lx * 2, sp - DIM.BELLY_Y, 2.2, at(0, (sp + DIM.BELLY_Y) / 2, -10.5) * rz(180), COLOR.TAN, MAT.SMOOTH, c)
  -- Solid outer panels, so players can't walk through the hull.
  solid(block("Bow", hx * 2, DIM.NOSE_Y - sp, frontLen, at(0, (DIM.NOSE_Y + sp) / 2, frontZ), COLOR.TAN, MAT.SMOOTH, c))
  solid(wedge("UpperGlacis", hx * 2, roof - DIM.NOSE_Y, frontLen, at(0, (roof + DIM.NOSE_Y) / 2, frontZ), COLOR.TAN, MAT.SMOOTH, c))
  block("FrontSection", hx * 2, roof - sp, bz - DIM.GLACIS_Z, at(0, (roof + sp) / 2, (bz + DIM.GLACIS_Z) / 2), COLOR.TAN, MAT.SMOOTH, c)
  for _, s in ipairs({ -1, 1 }) do
    solid(block("LowerWall", 0.3, sp - DIM.FLOOR_Y, troopLen, at(s * (lx - 0.15), (sp + DIM.FLOOR_Y) / 2, troopZ), COLOR.TAN, MAT.SMOOTH, c))
    block("SponsonFloor", hx - lx, 0.2, troopLen, at(s * (hx + lx) / 2, sp + 0.1, troopZ), COLOR.TAN, MAT.SMOOTH, c)
    solid(block("UpperWall", 0.3, roof - sp, troopLen, at(s * (hx - 0.15), (roof + sp) / 2, troopZ), COLOR.TAN, MAT.SMOOTH, c))
    block("WallLiner", 0.05, sp - DIM.FLOOR_Y - 0.1, troopLen - 0.4, at(s * (lx - 0.33), (sp + DIM.FLOOR_Y) / 2, troopZ), COLOR.INTERIOR, MAT.SMOOTH, c)
    block("WallLiner", 0.05, roof - sp - 0.5, troopLen - 0.4, at(s * (hx - 0.33), (roof + sp) / 2 - 0.1, troopZ), COLOR.INTERIOR, MAT.SMOOTH, c)
    solid(block("RearPillar", hx - DIM.RAMP_W / 2, roof - sp, 0.3, at(s * (hx + DIM.RAMP_W / 2) / 2, (roof + sp) / 2, tail - 0.15), COLOR.TAN, MAT.SMOOTH, c))
    solid(block("RearPillar", lx - DIM.RAMP_W / 2, sp - DIM.FLOOR_Y, 0.3, at(s * (lx + DIM.RAMP_W / 2) / 2, (sp + DIM.FLOOR_Y) / 2, tail - 0.15), COLOR.TAN, MAT.SMOOTH, c))
  end
  solid(block("Roof", hx * 2, 0.3, troopLen, at(0, roof - 0.15, troopZ), COLOR.TAN, MAT.SMOOTH, c))
  block("RoofLiner", hx * 2 - 0.8, 0.05, troopLen - 0.4, at(0, roof - 0.33, troopZ), COLOR.INTERIOR, MAT.SMOOTH, c)
  solid(block("RampHeader", DIM.RAMP_W, roof - DIM.FLOOR_Y - DIM.RAMP_H, 0.3, at(0, (roof + DIM.FLOOR_Y + DIM.RAMP_H) / 2, tail - 0.15), COLOR.TAN, MAT.SMOOTH, c))
  solid(block("FloorMat", lx * 2 - 0.6, 0.05, troopLen - 0.4, at(0, DIM.FLOOR_Y + 0.03, troopZ), COLOR.INTERIOR, MAT.FABRIC, c))
  solid(block("BulkheadLiner", lx * 2 - 0.6, roof - DIM.FLOOR_Y - 0.6, 0.05, at(0, (roof + DIM.FLOOR_Y) / 2 - 0.1, bz + 0.03), COLOR.INTERIOR, MAT.SMOOTH, c))
  for _, lz in ipairs({ 2.5, 6.5, 10.0 }) do
    block("DomeLight", 0.6, 0.08, 0.3, at(0, roof - 0.38, lz), COLOR.LAMP, MAT.NEON, c)
  end
  for _, z in ipairs(DIM.AXLES) do
    cylinder("Axle", DIM.WHEEL_X * 2 - DIM.WHEEL_W, 0.45, at(0, DIM.WHEEL_R, z), COLOR.STEEL, MAT.METAL, c)
    block("Differential", 1.2, 0.9, 1.0, at(0, DIM.WHEEL_R, z), COLOR.STEEL, MAT.METAL, c)
  end
end

local function buildArmour(k)
  local c = k.chassis
  local at, block, bolt = k.at, k.block, k.bolt
  local hx = DIM.HULL_X
  local rise = DIM.ROOF_Y - DIM.NOSE_Y
  local run = DIM.GLACIS_Z - DIM.NOSE
  local slope = math.deg(math.atan(rise / run))
  for _, s in ipairs({ -1, 1 }) do
    for col = 0, 6 do
      local z = -6.95 + col * 2.62 + 1.275
      for row = 0, 1 do
        local y = 3.95 + row * 1.37 + 0.65
        if not (s > 0 and row == 0 and col <= 1) then
          block("ArmourTile", 0.12, 1.3, 2.55, at(s * (hx + 0.06), y, z), COLOR.TAN, MAT.SMOOTH, c)
          if DETAIL then
            for _, dy in ipairs({ -0.45, 0.45 }) do
              for _, dz in ipairs({ -1.0, 1.0 }) do bolt(at(s * (hx + 0.15), y + dy, z + dz), c) end
            end
          end
        end
      end
    end
    block("BowTile", 0.12, 1.4, 3.6, at(s * (hx + 0.06), 4.5, -9.6), COLOR.TAN, MAT.SMOOTH, c)
    if DETAIL then
      for _, dz in ipairs({ -1.4, 0, 1.4 }) do
        bolt(at(s * (hx + 0.15), 4.95, -9.6 + dz), c)
        bolt(at(s * (hx + 0.15), 4.05, -9.6 + dz), c)
      end
    end
  end
  for ix = -1, 1 do
    for iz = 0, 1 do
      local z = DIM.NOSE + 1.2 + iz * 2.1
      local y = DIM.NOSE_Y + rise * (z - DIM.NOSE) / run + 0.06
      local frame = at(ix * 2.75, y, z) * rx(-slope)
      block("GlacisTile", 2.6, 0.12, 2.0, frame, COLOR.TAN, MAT.SMOOTH, c)
      if DETAIL then
        for _, dx in ipairs({ -1.05, 1.05 }) do
          for _, dz in ipairs({ -0.8, 0.8 }) do bolt(frame * k.off(dx, 0.08, dz) * rz(90), c) end
        end
      end
    end
  end
end

local function buildBow(k)
  local c = k.chassis
  local at, block, cylinder, bolt, facing = k.at, k.block, k.cylinder, k.bolt, k.facing
  local nose, hx, roof = DIM.NOSE, DIM.HULL_X, DIM.ROOF_Y
  block("WinchCover", 2.4, 1.0, 0.1, at(0, 4.55, nose - 0.05), COLOR.TAN_DARK, MAT.SMOOTH, c)
  for _, dx in ipairs({ -1.0, 0, 1.0 }) do
    bolt(at(dx, 4.95, nose - 0.12) * ry(90), c)
    bolt(at(dx, 4.15, nose - 0.12) * ry(90), c)
  end
  block("TowEye", 0.6, 0.45, 0.45, at(0, 3.95, nose - 0.2), COLOR.STEEL, MAT.METAL, c)
  cylinder("TowEyePin", 0.8, 0.16, at(0, 3.95, nose - 0.38), COLOR.BLACK, MAT.METAL, c)
  for _, s in ipairs({ -1, 1 }) do
    block("HeadlightHousing", 0.9, 0.65, 0.14, at(s * 3.2, 4.8, nose - 0.07), COLOR.BLACK, MAT.SMOOTH, c)
    cylinder("Headlight", 0.06, 0.45, at(s * 3.05, 4.8, nose - 0.15) * ry(90), COLOR.LAMP, MAT.NEON, c)
    block("TurnSignal", 0.22, 0.16, 0.05, at(s * 3.52, 4.95, nose - 0.16), COLOR.AMBER, MAT.NEON, c)
    block("BlackoutLight", 0.22, 0.12, 0.05, at(s * 3.52, 4.68, nose - 0.16), COLOR.LAMP, MAT.SMOOTH, c)
    block("LightCageTop", 1.1, 0.08, 0.08, at(s * 3.2, 5.25, nose - 0.45), COLOR.TAN_DARK, MAT.METAL, c)
    block("LightCageBottom", 1.1, 0.08, 0.08, at(s * 3.2, 4.35, nose - 0.45), COLOR.TAN_DARK, MAT.METAL, c)
    for _, dx in ipairs({ -0.5, 0.5 }) do
      block("LightCageBar", 0.08, 0.98, 0.08, at(s * 3.2 + dx, 4.8, nose - 0.45), COLOR.TAN_DARK, MAT.METAL, c)
      block("LightCageStrut", 0.08, 0.08, 0.4, at(s * 3.2 + dx, 5.25, nose - 0.25), COLOR.TAN_DARK, MAT.METAL, c)
    end
    block("TowHook", 0.35, 0.5, 0.5, at(s * 1.8, 2.6, -11.0), COLOR.STEEL, MAT.METAL, c)
    cylinder("ShacklePin", 0.6, 0.14, at(s * 1.8, 2.75, -11.2), COLOR.BLACK, MAT.METAL, c)
    block("MirrorArm", 1.0, 0.08, 0.08, at(s * (hx + 0.5), 6.2, -8.2), COLOR.BLACK, MAT.METAL, c)
    block("MirrorArm", 0.08, 0.7, 0.08, at(s * (hx + 1.0), 5.9, -8.2), COLOR.BLACK, MAT.METAL, c)
    block("Mirror", 0.7, 1.0, 0.12, at(s * (hx + 1.1), 5.9, -8.26), COLOR.BLACK, MAT.METAL, c)
    block("MirrorGlass", 0.58, 0.88, 0.03, at(s * (hx + 1.1), 5.9, -8.18), COLOR.GLASS, MAT.SMOOTH, c)
    block("SmokeBracket", 0.5, 0.3, 1.9, at(s * 3.75, roof + 0.15, -6.6), COLOR.TAN_DARK, MAT.METAL, c)
    for i = 0, 3 do
      cylinder("SmokeTube", 0.55, 0.24, facing(s * 3.75, roof + 0.45, -7.25 + i * 0.43, s * 0.4, 0.5, -0.75) * ry(90),
        COLOR.TAN_DARK, MAT.METAL, c)
    end
  end
end

local function buildRoof(k)
  local c = k.chassis
  local at, block, cylinder = k.at, k.block, k.cylinder
  local roof = DIM.ROOF_Y
  local dx = DIM.DRIVER_X
  block("DriverHatchRing", 1.9, 0.12, 1.9, at(dx, roof + 0.06, -6.1), COLOR.TAN_DARK, MAT.METAL, c)
  block("DriverHatch", 1.6, 0.15, 1.6, at(dx, roof + 0.18, -6.1), COLOR.TAN, MAT.SMOOTH, c)
  block("DriverHatchHinge", 1.2, 0.18, 0.25, at(dx, roof + 0.2, -5.25), COLOR.STEEL, MAT.METAL, c)
  block("DriverHatchHandle", 0.5, 0.08, 0.08, at(dx, roof + 0.3, -6.6), COLOR.BLACK, MAT.METAL, c)
  for i = -1, 1 do
    block("DriverPeriscope", 0.35, 0.22, 0.1, at(dx + i * 0.5, roof + 0.13, -7.05), COLOR.GLASS, MAT.SMOOTH, c)
    block("PeriscopeHood", 0.42, 0.08, 0.3, at(dx + i * 0.5, roof + 0.27, -7.0), COLOR.TAN_DARK, MAT.METAL, c)
  end
  cylinder("CommanderRing", 0.2, 2.0, at(-1.0, roof + 0.1, -3.2) * rz(90), COLOR.TAN_DARK, MAT.METAL, c)
  cylinder("CommanderHatch", 0.12, 1.7, at(-1.0, roof + 0.25, -3.2) * rz(90), COLOR.TAN_DARK, MAT.METAL, c)
  block("CommanderHatchHinge", 1.0, 0.16, 0.22, at(-1.0, roof + 0.27, -2.35), COLOR.STEEL, MAT.METAL, c)
  block("CommanderHatchHandle", 0.5, 0.08, 0.08, at(-1.0, roof + 0.35, -3.6), COLOR.BLACK, MAT.METAL, c)
  for _, a in ipairs({ 0, 60, 120, 180, 240, 300 }) do
    local r = math.rad(a)
    block("VisionBlock", 0.35, 0.2, 0.1, at(-1.0 + 0.95 * math.sin(r), roof + 0.15, -3.2 - 0.95 * math.cos(r)) * ry(-a),
      COLOR.GLASS, MAT.SMOOTH, c)
  end
  for _, s in ipairs({ -1, 1 }) do
    local x = s * 1.7
    block("TroopHatchFrame", 3.0, 0.1, 3.4, at(x, roof + 0.05, 5.6), COLOR.TAN_DARK, MAT.METAL, c)
    block("TroopHatch", 2.7, 0.12, 3.1, at(x, roof + 0.16, 5.6), COLOR.TAN, MAT.SMOOTH, c)
    block("TroopHatchHinge", 0.25, 0.18, 2.6, at(x + s * 1.35, roof + 0.2, 5.6), COLOR.STEEL, MAT.METAL, c)
    block("TroopHatchHandle", 0.08, 0.08, 0.6, at(x - s * 0.9, roof + 0.26, 5.6), COLOR.BLACK, MAT.METAL, c)
    block("TroopHatchLatch", 0.3, 0.1, 0.2, at(x - s * 1.15, roof + 0.22, 4.4), COLOR.BLACK, MAT.METAL, c)
    block("TroopHatchVision", 0.45, 0.14, 0.12, at(x, roof + 0.25, 4.15), COLOR.GLASS, MAT.SMOOTH, c)
  end
  block("IntakeGrille", 2.4, 0.06, 2.6, at(2.2, roof + 0.03, -4.4), COLOR.BLACK, MAT.METAL, c)
  for i = 0, 6 do
    block("IntakeSlat", 2.2, 0.06, 0.12, at(2.2, roof + 0.07, -5.5 + i * 0.36), COLOR.TAN_DARK, MAT.METAL, c)
  end
  for _, s in ipairs({ -1, 1 }) do
    block("RackRail", 0.1, 0.1, 10.2, at(s * 3.95, roof + 0.75, 5.6), COLOR.BLACK, MAT.METAL, c)
    block("RackRail", 0.1, 0.1, 10.2, at(s * 3.95, roof + 0.3, 5.6), COLOR.BLACK, MAT.METAL, c)
    for _, pz in ipairs({ 0.6, 3.1, 5.6, 8.1, 10.6 }) do
      block("RackPost", 0.1, 0.8, 0.1, at(s * 3.95, roof + 0.4, pz), COLOR.BLACK, MAT.METAL, c)
    end
    block("Rucksack", 0.9, 0.9, 1.1, at(s * 3.4, roof + 0.45, 1.8), COLOR.OLIVE, MAT.FABRIC, c)
    block("Rucksack", 0.9, 0.8, 1.0, at(s * 3.4, roof + 0.4, 3.2), COLOR.CANVAS, MAT.FABRIC, c)
    cylinder("Bedroll", 1.6, 0.6, at(s * 3.4, roof + 0.3, 8.8) * ry(90), COLOR.OLIVE, MAT.FABRIC, c)
    block("AmmoCan", 0.4, 0.5, 0.8, at(s * 3.5, roof + 0.25, 10.2), COLOR.OLIVE, MAT.METAL, c)
    for _, hz in ipairs({ -5.4, -2.2 }) do
      block("GrabHandle", 0.08, 0.08, 0.8, at(s * 4.1, roof + 0.22, hz), COLOR.TAN_DARK, MAT.METAL, c)
      block("GrabHandlePost", 0.08, 0.2, 0.08, at(s * 4.1, roof + 0.1, hz - 0.36), COLOR.TAN_DARK, MAT.METAL, c)
      block("GrabHandlePost", 0.08, 0.2, 0.08, at(s * 4.1, roof + 0.1, hz + 0.36), COLOR.TAN_DARK, MAT.METAL, c)
    end
    cylinder("AntennaBase", 0.3, 0.3, at(s * 3.6, roof + 0.15, 11.1) * rz(90), COLOR.BLACK, MAT.METAL, c)
    cylinder("AntennaSpring", 0.35, 0.16, at(s * 3.6, roof + 0.47, 11.1) * rz(90), COLOR.BLACK, MAT.METAL, c)
    cylinder("Antenna", 6.0, 0.07, at(s * 3.6, roof + 3.65, 11.1) * rz(90), COLOR.BLACK, MAT.METAL, c)
  end
  cylinder("AntennaBase", 0.3, 0.3, at(-3.6, roof + 0.15, -1.6) * rz(90), COLOR.BLACK, MAT.METAL, c)
  cylinder("Antenna", 4.5, 0.07, at(-3.6, roof + 2.55, -1.6) * rz(90), COLOR.BLACK, MAT.METAL, c)
  cylinder("GPSDome", 0.25, 0.7, at(0, roof + 0.12, 9.8) * rz(90), COLOR.TAN, MAT.SMOOTH, c)
  cylinder("JammerMast", 1.2, 0.15, at(-2.2, roof + 0.6, 10.3) * rz(90), COLOR.BLACK, MAT.METAL, c)
  block("JammerPaddle", 0.1, 1.2, 0.6, at(-2.2, roof + 1.7, 10.3), COLOR.BLACK, MAT.SMOOTH, c)
end

local function buildSides(k)
  local c = k.chassis
  local at, block, cylinder = k.at, k.block, k.cylinder
  local hx = DIM.HULL_X
  block("ExhaustGrille", 0.08, 1.2, 4.8, at(hx + 0.04, 4.6, -4.4), COLOR.BLACK, MAT.METAL, c)
  for i = 0, 4 do
    block("GrilleSlat", 0.1, 0.1, 4.6, at(hx + 0.08, 4.1 + i * 0.25, -4.4), COLOR.TAN_DARK, MAT.METAL, c)
  end
  cylinder("ExhaustOutlet", 0.45, 0.4, at(hx + 0.2, 4.4, -1.9), COLOR.STEEL, MAT.METAL, c)
  cylinder("FuelFiller", 0.12, 0.5, at(hx + 0.08, 6.0, -7.5), COLOR.TAN_DARK, MAT.METAL, c)
  for _, s in ipairs({ -1, 1 }) do
    block("SideStep", 0.7, 0.1, 0.9, at(s * (hx + 0.3), 3.55, -0.4), COLOR.STEEL, MAT.METAL, c)
    block("StepHanger", 0.08, 0.4, 0.9, at(s * (hx + 0.62), 3.75, -0.4), COLOR.STEEL, MAT.METAL, c)
    block("GrabBar", 0.08, 1.2, 0.08, at(s * (hx + 0.3), 5.6, -0.4), COLOR.TAN_DARK, MAT.METAL, c)
    block("GrabBarMount", 0.2, 0.08, 0.08, at(s * (hx + 0.22), 6.2, -0.4), COLOR.TAN_DARK, MAT.METAL, c)
    block("GrabBarMount", 0.2, 0.08, 0.08, at(s * (hx + 0.22), 5.0, -0.4), COLOR.TAN_DARK, MAT.METAL, c)
    block("Mudflap", 1.3, 1.6, 0.06, at(s * DIM.WHEEL_X, 1.7, -0.7), COLOR.RUBBER, MAT.RUBBER, c)
    block("Mudflap", 1.3, 1.8, 0.06, at(s * DIM.WHEEL_X, 1.6, 8.1), COLOR.RUBBER, MAT.RUBBER, c)
  end
  local tx = -(hx + 0.3)
  cylinder("ShovelHandle", 3.0, 0.14, at(tx, 4.3, 7.4) * ry(90), COLOR.TAN_DARK, MAT.FABRIC, c)
  block("ShovelBlade", 0.08, 0.7, 0.8, at(tx, 4.3, 9.3), COLOR.STEEL, MAT.METAL, c)
  cylinder("PickHandle", 2.8, 0.14, at(tx, 4.75, 7.2) * ry(90), COLOR.TAN_DARK, MAT.FABRIC, c)
  block("PickHead", 0.1, 1.2, 0.2, at(tx, 4.75, 5.75), COLOR.STEEL, MAT.METAL, c)
  for _, bz in ipairs({ 6.2, 8.3 }) do
    block("ToolBracket", 0.3, 0.8, 0.12, at(-(hx + 0.18), 4.5, bz), COLOR.BLACK, MAT.METAL, c)
  end
  cylinder("Extinguisher", 1.0, 0.35, at(-(hx + 0.25), 4.6, -7.4) * rz(90), COLOR.RED, MAT.SMOOTH, c)
  block("ExtinguisherStrap", 0.45, 0.1, 0.45, at(-(hx + 0.25), 4.8, -7.4), COLOR.BLACK, MAT.METAL, c)
end

local function buildRear(k)
  local c = k.chassis
  local at, block, cylinder = k.at, k.block, k.cylinder
  local tail, roof = DIM.TAIL, DIM.ROOF_Y
  for _, s in ipairs({ -1, 1 }) do
    block("TaillightHousing", 0.9, 0.7, 0.1, at(s * 3.55, 4.6, tail + 0.05), COLOR.BLACK, MAT.SMOOTH, c)
    block("Taillight", 0.3, 0.22, 0.05, at(s * 3.72, 4.72, tail + 0.11), COLOR.RED, MAT.NEON, c)
    block("TurnSignal", 0.22, 0.16, 0.05, at(s * 3.4, 4.72, tail + 0.11), COLOR.AMBER, MAT.NEON, c)
    block("BlackoutTaillight", 0.25, 0.1, 0.05, at(s * 3.55, 4.42, tail + 0.11), COLOR.DIM_RED, MAT.SMOOTH, c)
    block("LightGuard", 1.1, 0.08, 0.08, at(s * 3.55, 5.05, tail + 0.35), COLOR.TAN_DARK, MAT.METAL, c)
    for _, d in ipairs({ -0.5, 0.5 }) do
      block("LightGuardPost", 0.08, 0.5, 0.3, at(s * 3.55 + d, 4.82, tail + 0.2), COLOR.TAN_DARK, MAT.METAL, c)
    end
    block("CanRack", 1.4, 0.1, 0.7, at(s * 3.4, 3.95, tail + 0.4), COLOR.STEEL, MAT.METAL, c)
    for i = 0, 1 do
      block("Jerrycan", 0.55, 1.1, 0.6, at(s * (3.1 + i * 0.6), 4.55, tail + 0.4), COLOR.OLIVE, MAT.METAL, c)
    end
    block("CanStrap", 1.3, 0.08, 0.1, at(s * 3.4, 4.85, tail + 0.72), COLOR.BLACK, MAT.FABRIC, c)
    block("RearShackle", 0.35, 0.45, 0.4, at(s * 1.9, 1.5, tail + 0.2), COLOR.STEEL, MAT.METAL, c)
    block("Reflector", 0.2, 0.2, 0.04, at(s * 4.1, 3.85, tail + 0.03), COLOR.RED, MAT.SMOOTH, c)
  end
  block("TowPintle", 0.5, 0.45, 0.4, at(0, 1.5, tail + 0.2), COLOR.STEEL, MAT.METAL, c)
  block("PintleHook", 0.18, 0.35, 0.25, at(0, 1.3, tail + 0.45), COLOR.BLACK, MAT.METAL, c)
  block("RearCamera", 0.4, 0.3, 0.3, at(0, roof - 0.2, tail + 0.18), COLOR.BLACK, MAT.SMOOTH, c)
  cylinder("RearCameraLens", 0.05, 0.18, at(0, roof - 0.2, tail + 0.35) * ry(90), COLOR.GLASS, MAT.SMOOTH, c)
  block("IdPanel", 1.2, 0.45, 0.04, at(3.4, 6.2, tail + 0.03), COLOR.BLACK, MAT.SMOOTH, c)
end

local function buildRamp(k)
  local w, h = DIM.RAMP_W, DIM.RAMP_H
  local hingeY, hingeZ = DIM.FLOOR_Y, DIM.TAIL - 0.15
  local hinge = k.off(0, hingeY - DIM.CHASSIS_Y, hingeZ - DIM.CHASSIS_Z)
  local c1 = CFrame.new(0, -h / 2 * SCALE, 0)
  local rampCF = k.at(0, hingeY + h / 2, hingeZ)
  local ramp = k.solid(k.block("Ramp", w, h, 0.3, rampCF, COLOR.TAN, MAT.SMOOTH, false))
  k.block("RampLiner", w - 0.3, h - 0.3, 0.05, rampCF * k.off(0, 0, -0.17), COLOR.INTERIOR, MAT.SMOOTH, ramp)
  k.block("RampDoor", 1.8, 3.1, 0.05, rampCF * k.off(0.6, -0.05, 0.17), COLOR.TAN, MAT.SMOOTH, ramp)
  k.block("RampDoorSeam", 1.9, 0.06, 0.04, rampCF * k.off(0.6, 1.55, 0.2), COLOR.BLACK, MAT.SMOOTH, ramp)
  k.block("RampDoorSeam", 0.06, 3.2, 0.04, rampCF * k.off(-0.33, -0.05, 0.2), COLOR.BLACK, MAT.SMOOTH, ramp)
  k.block("RampDoorSeam", 0.06, 3.2, 0.04, rampCF * k.off(1.55, -0.05, 0.2), COLOR.BLACK, MAT.SMOOTH, ramp)
  for _, dy in ipairs({ -1.0, 1.0 }) do
    k.block("RampDoorHinge", 0.15, 0.4, 0.12, rampCF * k.off(-0.38, dy, 0.24), COLOR.STEEL, MAT.METAL, ramp)
  end
  k.block("RampVisionBlock", 0.4, 0.25, 0.06, rampCF * k.off(0.6, 1.1, 0.2), COLOR.GLASS, MAT.SMOOTH, ramp)
  k.block("RampHandle", 0.1, 0.5, 0.1, rampCF * k.off(1.25, 0.2, 0.24), COLOR.BLACK, MAT.METAL, ramp)
  k.block("RampHinge", w - 0.4, 0.25, 0.25, rampCF * k.off(0, -h / 2 + 0.12, 0.18), COLOR.STEEL, MAT.METAL, ramp)
  for _, dx in ipairs({ -2.1, 2.1 }) do
    k.block("RampLock", 0.3, 0.3, 0.12, rampCF * k.off(dx, h / 2 - 0.3, 0.2), COLOR.BLACK, MAT.METAL, ramp)
  end
  for i = 0, 3 do
    k.block("RampTread", w - 0.8, 0.08, 0.06, rampCF * k.off(0, -1.5 + i * 0.9, -0.21), COLOR.STEEL, MAT.METAL, ramp)
  end
  local j = k.joint("RampJoint", k.chassis, ramp, hinge, c1)
  k.ramp = { weld = j, base = hinge }
end

local function buildRws(k)
  local c = k.chassis
  local x, z, roof, gy = DIM.RWS_X, DIM.RWS_Z, DIM.ROOF_Y, DIM.GUN_Y
  local block, cylinder, at = k.block, k.cylinder, k.at
  cylinder("RwsBase", 0.4, 2.2, at(x, roof + 0.2, z) * rz(90), COLOR.TAN_DARK, MAT.METAL, c)
  if DETAIL then
    for b = 0, 7 do
      local a = b * math.pi / 4
      k.bolt(at(x + 0.95 * math.cos(a), roof + 0.42, z + 0.95 * math.sin(a)) * rz(90), c)
    end
  end
  local mount = block("RwsMount", 0.3, 0.3, 0.3, at(x, roof + 0.4, z), COLOR.BLACK, MAT.SMOOTH, false)
  mount.Transparency = 1
  local yaw = k.joint("RwsYawWeld", c, mount, k.off(x, roof + 0.4 - DIM.CHASSIS_Y, z - DIM.CHASSIS_Z), CFrame.new())
  local columnH = gy - roof - 1.0
  local pedestal = block("RwsPedestal", 1.1, columnH, 1.1, at(x, roof + 0.4 + columnH / 2, z + 0.1), COLOR.TAN, MAT.SMOOTH, mount)
  block("RwsCable", 0.2, columnH, 0.2, at(x - 0.4, roof + 0.4 + columnH / 2, z + 0.7), COLOR.BLACK, MAT.RUBBER, mount)
  block("RwsJunctionBox", 0.6, 0.5, 0.4, at(x + 0.55, roof + 0.9, z + 0.5), COLOR.TAN_DARK, MAT.SMOOTH, mount)
  for _, s in ipairs({ -1, 1 }) do
    block("RwsYoke", 0.2, 1.3, 1.0, at(x + s * 0.75, gy - 0.3, z + 0.1), COLOR.TAN_DARK, MAT.METAL, mount)
    for i = 0, 3 do
      cylinder("RwsSmokeTube", 0.45, 0.2, k.facing(x + s * 0.8, roof + 0.85 + i * 0.24, z - 0.35, s * 0.5, 0.4, -0.75) * ry(90),
        COLOR.TAN_DARK, MAT.METAL, mount)
    end
  end
  -- Parts the commander can click to fire.
  local trigger = {}
  table.insert(trigger, block("RwsAmmoCan", 0.6, 0.8, 1.1, at(x - 1.15, gy - 0.35, z + 0.1), COLOR.OLIVE, MAT.METAL, mount))
  block("RwsAmmoLid", 0.62, 0.08, 1.12, at(x - 1.15, gy + 0.07, z + 0.1), COLOR.OLIVE, MAT.METAL, mount)
  block("RwsFeedChute", 0.35, 0.2, 0.6, at(x - 0.6, gy - 0.05, z + 0.1), COLOR.BLACK, MAT.METAL, mount)
  local cradle = block("RwsCradle", 0.3, 0.3, 0.3, at(x, gy, z), COLOR.BLACK, MAT.SMOOTH, false)
  cradle.Transparency = 1
  local pitch = k.joint("RwsPitchWeld", mount, cradle, k.off(0, gy - roof - 0.4, 0), CFrame.new())
  table.insert(trigger, pedestal)
  table.insert(trigger, block("RwsReceiver", 0.45, 0.55, 1.8, at(x, gy, z + 0.2), COLOR.GUN, MAT.METAL, cradle))
  block("RwsFeedCover", 0.47, 0.08, 1.1, at(x, gy + 0.31, z + 0.05), COLOR.GUN, MAT.METAL, cradle)
  block("RwsChargingHandle", 0.3, 0.08, 0.08, at(x + 0.3, gy + 0.1, z + 0.6), COLOR.BLACK, MAT.METAL, cradle)
  table.insert(trigger, cylinder("RwsJacket", 0.8, 0.3, at(x, gy, z - 1.1) * ry(90), COLOR.GUN, MAT.METAL, cradle))
  if DETAIL then
    for i = 0, 2 do
      cylinder("RwsJacketHole", 0.02, 0.1, at(x + 0.15, gy, z - 0.85 - i * 0.22), COLOR.BLACK, MAT.SMOOTH, cradle)
    end
  end
  table.insert(trigger, cylinder("RwsBarrel", 3.2, 0.16, at(x, gy, z - 3.1) * ry(90), COLOR.GUN, MAT.METAL, cradle))
  block("RwsCarryHandle", 0.08, 0.08, 0.5, at(x, gy + 0.35, z - 1.55), COLOR.GUN, MAT.METAL, cradle)
  for _, dz in ipairs({ -0.22, 0.22 }) do
    block("RwsCarryHandlePost", 0.08, 0.25, 0.08, at(x, gy + 0.2, z - 1.55 + dz), COLOR.GUN, MAT.METAL, cradle)
  end
  block("RwsFrontSight", 0.06, 0.2, 0.06, at(x, gy + 0.15, z - 4.5), COLOR.GUN, MAT.METAL, cradle)
  table.insert(trigger, cylinder("RwsFlashHider", 0.3, 0.24, at(x, gy, z - 4.8) * ry(90), COLOR.GUN, MAT.METAL, cradle))
  table.insert(trigger, block("RwsSight", 0.8, 0.8, 1.2, at(x + 1.3, gy + 0.1, z - 0.1), COLOR.TAN, MAT.SMOOTH, cradle))
  block("RwsSightArm", 0.6, 0.25, 0.4, at(x + 0.75, gy, z - 0.1), COLOR.TAN_DARK, MAT.METAL, cradle)
  block("RwsSunshade", 0.9, 0.06, 0.45, at(x + 1.3, gy + 0.53, z - 0.8), COLOR.TAN_DARK, MAT.METAL, cradle)
  cylinder("RwsDayCamera", 0.05, 0.34, at(x + 1.12, gy + 0.25, z - 0.72) * ry(90), COLOR.GLASS, MAT.SMOOTH, cradle)
  block("RwsThermal", 0.3, 0.28, 0.05, at(x + 1.48, gy + 0.25, z - 0.72), COLOR.BLACK, MAT.SMOOTH, cradle)
  cylinder("RwsLaser", 0.05, 0.16, at(x + 1.3, gy - 0.12, z - 0.72) * ry(90), COLOR.GLASS, MAT.SMOOTH, cradle)
  -- ClickDetectors only see parts the mouse ray can hit.
  for _, p in ipairs(trigger) do p.CanQuery = true end
  k.rws = { yaw = yaw, yawBase = yaw.C0, pitch = pitch, pitchBase = pitch.C0, cradle = cradle, trigger = trigger }
end

local function buildInterior(k)
  local c = k.chassis
  local at, block = k.at, k.block
  local roof, bz = DIM.ROOF_Y, DIM.BULKHEAD_Z
  for _, s in ipairs({ -1, 1 }) do
    block("BenchFrame", 0.9, 0.3, 8.6, at(s * DIM.TROOP_X, 2.55, 6.0), COLOR.STEEL, MAT.METAL, c)
    for _, lz in ipairs({ 2.0, 6.0, 10.0 }) do
      block("BenchLeg", 0.12, 0.35, 0.12, at(s * (DIM.TROOP_X - 0.3), 2.22, lz), COLOR.STEEL, MAT.METAL, c)
    end
    block("BenchBack", 0.2, 1.8, 8.6, at(s * 2.5, 3.9, 6.0), COLOR.SEAT, MAT.FABRIC, c)
    for _, z in ipairs(DIM.TROOP_Z) do
      block("SeatBelt", 0.05, 1.6, 0.12, at(s * 2.38, 3.9, z + 0.3), COLOR.BLACK, MAT.FABRIC, c)
      block("SeatDivider", 0.5, 0.5, 0.06, at(s * 2.3, 3.2, z + 1.2), COLOR.STEEL, MAT.METAL, c)
    end
    block("Handrail", 0.1, 0.1, 10.0, at(s * 1.2, roof - 0.55, 5.8), COLOR.STEEL, MAT.METAL, c)
    for _, hz in ipairs({ 1.2, 5.8, 10.4 }) do
      block("HandrailBracket", 0.08, 0.2, 0.08, at(s * 1.2, roof - 0.43, hz), COLOR.STEEL, MAT.METAL, c)
    end
    for _, iz in ipairs({ 3.6, 8.4 }) do
      block("Intercom", 0.12, 0.35, 0.3, at(s * 2.62, 5.3, iz), COLOR.BLACK, MAT.SMOOTH, c)
    end
  end
  block("FirstAidKit", 0.8, 0.6, 0.25, at(1.6, 5.2, bz + 0.18), COLOR.OLIVE, MAT.FABRIC, c)
  block("FirstAidCross", 0.45, 0.12, 0.02, at(1.6, 5.2, bz + 0.31), COLOR.RED, MAT.SMOOTH, c)
  block("FirstAidCross", 0.12, 0.45, 0.02, at(1.6, 5.2, bz + 0.31), COLOR.RED, MAT.SMOOTH, c)
  for i = 0, 1 do
    block("WaterCan", 0.35, 0.7, 0.55, at(-1.9 + i * 0.45, 2.45, bz + 0.45), COLOR.TAN, MAT.SMOOTH, c)
  end
  block("RifleRack", 1.4, 0.1, 0.3, at(-1.6, 4.6, bz + 0.2), COLOR.BLACK, MAT.METAL, c)
end

local function buildSeats(k)
  local c = k.chassis
  local y = DIM.SEAT_Y
  local driver = k.seat("VehicleSeat", "DriverSeat", k.at(DIM.DRIVER_X, y, DIM.DRIVER_Z), c)
  driver.MaxSpeed = 0
  driver.Torque = 0
  driver.TurnSpeed = 0
  driver.HeadsUpDisplay = false
  local commander = k.seat("VehicleSeat", "CommanderSeat", k.at(DIM.COMMANDER_X, y, DIM.COMMANDER_Z), c)
  commander.MaxSpeed = 0
  commander.Torque = 0
  commander.TurnSpeed = 0
  commander.HeadsUpDisplay = false
  k.driverSeat = driver
  k.commanderSeat = commander
  for _, s in ipairs({ -1, 1 }) do
    for _, z in ipairs(DIM.TROOP_Z) do
      table.insert(k.troopSeats, k.seat("Seat", "TroopSeat", k.at(s * DIM.TROOP_X, y, z) * ry(90 * s), c))
    end
  end
  table.insert(k.troopSeats, k.seat("Seat", "TroopSeat", k.at(0, y, DIM.BULKHEAD_Z + 1.2) * ry(180), c))
  k.block("TroopSeatBack", 1.4, 1.8, 0.2, k.at(0, y + 1.1, DIM.BULKHEAD_Z + 0.5), COLOR.SEAT, MAT.FABRIC, c)
end

---------------------------------------------------------------------------------------------
-- Crew
---------------------------------------------------------------------------------------------

local function exitPoint(role, index)
  if role == "driver" then return Vector3.new(-(DIM.HULL_X + 3), 2.4, DIM.DRIVER_Z) end
  if role == "commander" then return Vector3.new(DIM.HULL_X + 3, 2.4, DIM.COMMANDER_Z) end
  return Vector3.new(((index % 3) - 1) * 2.5, 2.4, DIM.TAIL + 4 + math.floor(index / 3) * 2)
end

local function moveToward(value, goal, step)
  if value < goal then return math.min(goal, value + step) end
  return math.max(goal, value - step)
end

local function updateCrew(entry)
  local online = playerSet()
  local aboard = {}
  for _, seatInfo in ipairs(entry.allSeats) do
    local name = occupantName(seatInfo.seat, online)
    if name ~= seatInfo.name then
      local previous = seatInfo.name
      seatInfo.name = name
      if name then
        if seatInfo.role == "driver" then
          tell("Stryker: W/S drive, A/D steer. F at the back lowers or raises the ramp. Space gets you out.", name)
        elseif seatInfo.role == "commander" then
          tell("Stryker commander: A/D turns the .50, W/S raises and lowers it. Click the gun (or say :fire) to shoot. Space gets you out.", name)
        else
          tell("You're aboard the Stryker. Space gets you out.", name)
        end
      elseif previous and online[previous] and healthOf(previous) > 0 then
        local p = exitPoint(seatInfo.role, seatInfo.index)
        pcall(setPlayerPosition, previous, entry.chassis.CFrame
          * CFrame.new(p.X * SCALE, (p.Y - DIM.CHASSIS_Y) * SCALE, (p.Z - DIM.CHASSIS_Z) * SCALE))
      end
    end
    if seatInfo.name then aboard[seatInfo.name] = true end
  end
  entry.aboard = aboard
  entry.driver = entry.allSeats[1].name
  entry.commander = entry.allSeats[2].name
  local freeTroopSeats = 0
  for i = 3, #entry.allSeats do
    local seatInfo = entry.allSeats[i]
    local free = not seatInfo.name and not seatInfo.seat.Occupant
    if free then freeTroopSeats = freeTroopSeats + 1 end
    pcall(setEnabled, seatInfo.prompt, free)
  end
  if entry.prompts then
    pcall(setEnabled, entry.prompts.driver, entry.driver == nil)
    pcall(setEnabled, entry.prompts.commander, entry.commander == nil)
    pcall(setEnabled, entry.prompts.board, freeTroopSeats > 0)
    pcall(setPromptField, entry.prompts.board, "ObjectText", freeTroopSeats .. " of " .. (#entry.allSeats - 2) .. " seats free")
    pcall(setPromptField, entry.prompts.ramp, "ActionText", entry.rampOpen and "Raise ramp" or "Lower ramp")
  end
end

local function addPrompts(entry, anchors)
  local function takeSeat(seatInfo, who)
    local name = nameOf(who)
    if seatInfo.seat.Occupant or occupantName(seatInfo.seat) then
      if name then tell("That seat is taken.", name) end
      return
    end
    if name and entry.aboard[name] then
      tell("Hop out of your seat first (Space), then try again.", name)
      return
    end
    seatPlayer(seatInfo.seat, who, name)
  end
  local ok, err = pcall(function()
    local p = {}
    p.driver = newPrompt(anchors.driver, "DriverPrompt", Enum.KeyCode.E, "Get in", "Driver", 6, 0)
    p.commander = newPrompt(anchors.commander, "CommanderPrompt", Enum.KeyCode.E, "Get in", "Commander (.50 cal)", 6, 0)
    p.board = newPrompt(anchors.rear, "BoardPrompt", Enum.KeyCode.E, "Board", "9 of 9 seats free", 8, 0)
    p.ramp = newPrompt(anchors.rear, "RampPrompt", Enum.KeyCode.F, "Lower ramp", "Rear ramp", 8, 0)
    pcall(function()
      p.board.UIOffset = Vector2.new(-85, 0)
      p.ramp.UIOffset = Vector2.new(85, 0)
    end)
    entry.prompts = p
    p.driver.Triggered:Connect(function(who) takeSeat(entry.allSeats[1], who) end)
    p.commander.Triggered:Connect(function(who) takeSeat(entry.allSeats[2], who) end)
    for i = 3, #entry.allSeats do
      local seatInfo = entry.allSeats[i]
      seatInfo.prompt = newPrompt(seatInfo.seat, "SitPrompt", Enum.KeyCode.E, "Sit", "Troop seat", 5, 0)
      seatInfo.prompt.Triggered:Connect(function(who) takeSeat(seatInfo, who) end)
    end
    p.board.Triggered:Connect(function(who)
      for i = 3, #entry.allSeats do
        local seatInfo = entry.allSeats[i]
        if not seatInfo.name and not seatInfo.seat.Occupant then
          takeSeat(seatInfo, who)
          return
        end
      end
      local name = nameOf(who)
      if name then tell("The troop compartment is full.", name) end
    end)
    p.ramp.Triggered:Connect(function() entry.rampOpen = not entry.rampOpen end)
  end)
  if not ok then print("[Stryker] key prompts unavailable: " .. tostring(err)) end

  -- Clicking works in this game (the input lab proved it), so the doors are clickable too:
  -- click the driver or commander door to get in, click the back to board.
  local function clickable(part, onClick)
    pcall(function()
      local detector = Instance.new("ClickDetector")
      detector.MaxActivationDistance = 16
      detector.Parent = part
      detector.MouseClick:Connect(onClick)
    end)
  end
  clickable(anchors.driver, function(who) takeSeat(entry.allSeats[1], who) end)
  clickable(anchors.commander, function(who) takeSeat(entry.allSeats[2], who) end)
  clickable(anchors.rear, function(who)
    for i = 3, #entry.allSeats do
      local seatInfo = entry.allSeats[i]
      if not seatInfo.name and not seatInfo.seat.Occupant then
        takeSeat(seatInfo, who)
        return
      end
    end
    local name = nameOf(who)
    if name then tell("The troop compartment is full.", name) end
  end)
end

---------------------------------------------------------------------------------------------
-- Driving. The chassis is anchored and moved by CFrame (raycasts for ground and walls).
-- Unanchored physics driven by the server never worked here: the VehicleSeat hands physics to
-- the driver's client, which threw away the server's velocity, so the wheel welds turned but
-- the hull never moved. An anchored part is always the server's, and welded parts follow it.
---------------------------------------------------------------------------------------------

-- Frame-rate independent version of "close `share` of the gap every 0.03 s".
local function blend(share, dt) return 1 - (1 - share) ^ (dt / 0.03) end

-- First thing along the ray a vehicle can stand on or hit. Skips players (the API returns their
-- name as a string) and non-colliding parts such as trigger zones; the vehicle itself is
-- filtered out by `params`.
local function solidHit(origin, dir, params)
  local length = dir.Magnitude
  if length < 0.001 then return nil end
  local unit = dir / length
  local travelled = 0
  for _ = 1, 5 do
    local hit = castRay(origin + unit * travelled, unit * (length - travelled), params)
    if not hit then return nil end
    local solid, hitPos = false, nil
    pcall(function()
      hitPos = hit.Position
      if type(hit.Instance) ~= "string" then solid = hit.Instance.CanCollide == true end
    end)
    if solid then return hit end
    if not hitPos then return nil end
    travelled = (hitPos - origin).Magnitude + 0.05
    if travelled >= length then return nil end
  end
  return nil
end

local function headingOf(cf)
  local look = cf.LookVector
  return math.atan2(-look.X, -look.Z)
end

local function yawFrame(pos, heading)
  return CFrame.new(pos) * CFrame.Angles(0, heading, 0)
end

local function vehicleFrame(state)
  return yawFrame(state.pos, state.heading) * CFrame.Angles(state.pitch, 0, state.roll)
end

-- Ground height under the front axle, rear axle and the left / right wheel lines.
local function sampleGround(entry, yawCF, baseY)
  local meanZ = 0
  for _, z in ipairs(DIM.AXLES) do meanZ = meanZ + z end
  meanZ = meanZ / #DIM.AXLES * SCALE
  local points = {
    front = Vector3.new(0, 0, DIM.AXLES[1] * SCALE),
    rear = Vector3.new(0, 0, DIM.AXLES[#DIM.AXLES] * SCALE),
    left = Vector3.new(-DIM.WHEEL_X * SCALE, 0, meanZ),
    right = Vector3.new(DIM.WHEEL_X * SCALE, 0, meanZ),
  }
  local heights = {}
  for key, offset in pairs(points) do
    local world = yawCF * offset
    local origin = Vector3.new(world.X, baseY + DRIVE.PROBE_UP, world.Z)
    local hit = solidHit(origin, Vector3.new(0, -(DRIVE.PROBE_UP + DRIVE.PROBE_DOWN), 0), entry.params)
    if hit then heights[key] = hit.Position.Y end
  end
  return heights
end

-- Would moving `distance` along the heading run the nose (or the tail, reversing) into a wall?
local function blockedAhead(entry, yawCF, distance)
  local sign = 1
  if distance < 0 then sign = -1 end
  local edgeZ = DIM.NOSE * SCALE + 0.5
  if sign < 0 then edgeZ = DIM.TAIL * SCALE - 0.5 end
  local dir = yawCF.LookVector * sign * (math.abs(distance) + 1)
  local side = DIM.HULL_X * SCALE - 0.3
  for _, x in ipairs({ -side, 0, side }) do
    for _, y in ipairs(DRIVE.WALL_HEIGHTS) do
      local hit = solidHit(yawCF * Vector3.new(x, y, edgeZ), dir, entry.params)
      if hit then
        local normalY = 0
        pcall(function() normalY = hit.Normal.Y end)
        if normalY < DRIVE.WALL_NORMAL_Y then return true end
      end
    end
  end
  return false
end

local function driveStryker(entry)
  local chassis = entry.chassis
  local seat = entry.allSeats[1].seat
  local state = entry.drive
  local wheelbase = (DIM.AXLES[#DIM.AXLES] - DIM.AXLES[1]) * SCALE
  local track = DIM.WHEEL_X * 2 * SCALE
  local speed, steerAngle, rolled = 0, 0, 0
  local shownSteer, shownRolled, lastWheels = 0, 0, 0
  local groundCheck = 0
  local last = tick()
  while alive(entry) do
    local occupied = seat.Occupant ~= nil
    if occupied or speed ~= 0 or not state.grounded then
      task.wait(PERF.DRIVE_TICK)
    else
      task.wait(PERF.IDLE_TICK)
    end
    local now = tick()
    local dt = math.min(now - last, 0.2)
    last = now

    local throttle, steer = 0, 0
    if seat.Occupant then
      throttle = seat.Throttle
      steer = seat.Steer
    end
    local target = throttle * MAX_SPEED
    if throttle < 0 then target = throttle * REVERSE_SPEED end
    if seat.Occupant then
      speed = speed + (target - speed) * blend(ACCELERATION, dt)
    else
      speed = speed * (1 - blend(0.2, dt))
    end
    if throttle == 0 and math.abs(speed) < 0.05 then speed = 0 end
    steerAngle = steerAngle + (-steer * MAX_STEER - steerAngle) * blend(0.15, dt)
    if steer == 0 and math.abs(steerAngle) < 0.002 then steerAngle = 0 end

    -- move along the ground, unless a wall is in the way
    local pos, heading = state.pos, state.heading
    local step = speed * dt
    if step ~= 0 and state.grounded then
      if blockedAhead(entry, yawFrame(pos, heading), step) then
        speed, step = 0, 0
      else
        heading = heading + speed / TURN_RADIUS * (steerAngle / MAX_STEER) * dt
        pos = pos + yawFrame(pos, heading).LookVector * step
      end
    elseif not state.grounded then
      step = 0 -- no steering in mid-air
    end

    -- follow the ground (and fall when there isn't any)
    groundCheck = groundCheck - dt
    if step ~= 0 or not state.grounded or groundCheck <= 0 then
      groundCheck = DRIVE.GROUND_EVERY
      local heights = sampleGround(entry, yawFrame(pos, heading), state.pos.Y)
      local lead = nil
      if step > 0 then lead = heights.front elseif step < 0 then lead = heights.rear end
      if lead and lead - state.pos.Y > DRIVE.MAX_STEP then
        -- a ledge too tall to climb: treat it as a wall
        pos, heading, speed = state.pos, state.heading, 0
      else
        local sum, n = 0, 0
        for _, y in pairs(heights) do
          sum = sum + y
          n = n + 1
        end
        local y = pos.Y
        if n > 0 then
          local groundY = sum / n
          if groundY >= y - 0.05 then
            y = groundY
            state.vy = 0
            state.grounded = true
          else
            state.vy = state.vy - DRIVE.GRAVITY * dt
            y = math.max(groundY, y + state.vy * dt)
            state.grounded = y <= groundY + 0.01
            if state.grounded then state.vy = 0 end
          end
          local pitch, roll = state.pitch, state.roll
          if heights.front and heights.rear then pitch = math.atan2(heights.front - heights.rear, wheelbase) end
          if heights.left and heights.right then roll = math.atan2(heights.right - heights.left, track) end
          local k = blend(DRIVE.TILT_BLEND, dt)
          state.pitch = state.pitch + (pitch - state.pitch) * k
          state.roll = state.roll + (roll - state.roll) * k
        else
          state.vy = state.vy - DRIVE.GRAVITY * dt
          y = y + state.vy * dt
          state.grounded = false
        end
        pos = Vector3.new(pos.X, y, pos.Z)
      end
    end

    local moved = (pos - state.pos).Magnitude > 0.001 or heading ~= state.heading
      or math.abs(state.pitch - (state.shownPitch or 0)) > 0.0005
      or math.abs(state.roll - (state.shownRoll or 0)) > 0.0005
    state.pos, state.heading = pos, heading
    if moved then
      state.shownPitch, state.shownRoll = state.pitch, state.roll
      chassis.CFrame = vehicleFrame(state) * entry.chassisOffset
    end
    if pos.Y < DRIVE.FALL_LIMIT then
      print("[Stryker] " .. entry.owner .. "'s Stryker fell out of the map")
      tell("Your Stryker fell out of the map. Spawn a new one with :spawn stryker.", entry.owner)
      destroyStryker(entry.key)
      return
    end

    rolled = rolled + speed * dt
    if now - lastWheels >= PERF.WHEEL_TICK and (rolled ~= shownRolled or steerAngle ~= shownSteer) then
      lastWheels = now
      rolled = rolled % (2 * math.pi * DIM.WHEEL_R * SCALE)
      shownRolled, shownSteer = rolled, steerAngle
      for _, w in ipairs(entry.wheels) do
        w.weld.C0 = w.base * CFrame.Angles(0, steerAngle * w.steer, 0)
          * CFrame.Angles(-rolled / (DIM.WHEEL_R * SCALE), 0, 0)
      end
    end
    if math.abs(speed) > 3 then entry.rampOpen = false end
  end
end

---------------------------------------------------------------------------------------------
-- Gun, ramp and crew loop
---------------------------------------------------------------------------------------------

local function stationLoop(entry)
  local rws = entry.rws
  local yaw = entry.yaw or 0
  local pitch = entry.pitch or 0
  local ramp = entry.rampShown or 0
  local shownYaw, shownPitch, shownRecoil = yaw, pitch, 0
  local last = tick()
  local lastCrew, lastDot = 0, 0
  local gunSeat = entry.allSeats[2].seat
  while alive(entry) do
    local busy = gunSeat.Occupant ~= nil or entry.recoil > 0 or ramp ~= (entry.rampOpen and 1 or 0)
    if busy then task.wait(0.03) else task.wait(PERF.IDLE_TICK) end
    local now = tick()
    local dt = math.min(now - last, 0.3)
    last = now
    if now - lastCrew >= PERF.CREW_TICK then
      lastCrew = now
      updateCrew(entry)
    end

    local goal = entry.rampOpen and 1 or 0
    if ramp ~= goal then
      ramp = moveToward(ramp, goal, dt / GUN.RAMP_TIME)
      entry.ramp.weld.C0 = entry.ramp.base * CFrame.Angles(DIM.RAMP_OPEN * ramp, 0, 0)
      entry.rampShown = ramp
    end

    local moved = false
    local occupied = gunSeat.Occupant ~= nil
    if occupied then
      local steer, throttle = gunSeat.Steer, gunSeat.Throttle
      if steer ~= 0 or throttle ~= 0 then
        yaw = (yaw - steer * GUN.TRAVERSE_SPEED * dt + math.pi) % (2 * math.pi) - math.pi
        pitch = math.max(GUN.MIN_PITCH, math.min(GUN.MAX_PITCH, pitch + throttle * GUN.ELEVATE_SPEED * dt))
        moved = true
      end
    end
    if entry.recoil > 0 then
      entry.recoil = math.max(0, entry.recoil - dt * 4)
      moved = true
    end
    if moved and (math.abs(yaw - shownYaw) > 0.0005 or math.abs(pitch - shownPitch) > 0.0005 or entry.recoil ~= shownRecoil) then
      shownYaw, shownPitch, shownRecoil = yaw, pitch, entry.recoil
      entry.yaw, entry.pitch = yaw, pitch
      rws.yaw.C0 = rws.yawBase * CFrame.Angles(0, yaw, 0)
      rws.pitch.C0 = rws.pitchBase * CFrame.Angles(pitch, 0, 0) * CFrame.new(0, 0, entry.recoil * SCALE)
    end

    if occupied then
      if now - lastDot >= GUN.DOT_EVERY then
        lastDot = now
        local muzzle = entry.cradle.CFrame * CFrame.new(0, 0, -GUN.MUZZLE * SCALE)
        local hit = showAimDot(entry, muzzle.Position, muzzle.LookVector, GUN.RANGE)
        if GUN.AUTO and isEnemy(victimOf(hit), entry.commander) then shoot(entry, entry.commander) end
      end
    else
      hideAimDot(entry)
    end
  end
end

---------------------------------------------------------------------------------------------
-- Build / spawn
---------------------------------------------------------------------------------------------

local function buildStryker(owner, car, root, entry, dropOwnerIn)
  local marker = Instance.new("Part")
  marker.Name = MARKER_NAME
  marker.Size = Vector3.new(1, 1, 1)
  marker.CFrame = root
  marker.Transparency = 1
  marker.Anchored = true
  marker.CanCollide = false
  marker.CanQuery = false
  marker.CanTouch = false
  place(marker, car)
  entry.marker = marker

  local k = newKit(car, root, entry)
  local chassis = k.block("Chassis", 3.0, 0.4, 4.0, k.at(0, DIM.CHASSIS_Y, DIM.CHASSIS_Z), COLOR.BLACK, MAT.SMOOTH, false)
  chassis.Massless = false
  chassis.CustomPhysicalProperties = PhysicalProperties.new(DIM.ROOT_DENSITY, 0.3, 0, 1, 1)
  chassis.Transparency = 1
  k.chassis = chassis
  pcall(function() car.PrimaryPart = chassis end)

  buildHull(k)
  buildArmour(k)
  buildBow(k)
  buildRoof(k)
  buildSides(k)
  buildRear(k)
  buildInterior(k)
  for i, z in ipairs(DIM.AXLES) do
    local steer = 0
    if i == 1 then steer = 1 elseif i == 2 then steer = 0.55 end
    local name = "RoadWheel"
    if i >= 3 then name = "RoadWheelRear" end
    buildWheel(k, name, -DIM.WHEEL_X, z, steer)
    buildWheel(k, name, DIM.WHEEL_X, z, steer)
  end
  buildRamp(k)
  buildRws(k)
  buildSeats(k)
  local anchors = {
    driver = k.anchor("DriverDoor", -(DIM.HULL_X + 0.9), 4.6, DIM.DRIVER_Z, chassis),
    commander = k.anchor("CommanderDoor", DIM.HULL_X + 0.9, 4.6, DIM.COMMANDER_Z, chassis),
    rear = k.anchor("RearDoor", 0, 4.0, DIM.TAIL + 1.6, chassis),
  }
  entry.aimDot = makeAimDot(car, root)
  entry.dotSize = 0

  for _, gunPart in ipairs(k.rws.trigger) do
    pcall(function()
      local detector = Instance.new("ClickDetector")
      detector.MaxActivationDistance = GUN.CLICK_RANGE
      detector.Parent = gunPart
      detector.MouseClick:Connect(function(who) gunnerFire(entry, who) end)
      detector.RightMouseClick:Connect(function(who) gunnerFire(entry, who) end)
    end)
  end

  entry.chassis = chassis
  entry.wheels = k.wheels
  entry.ramp = k.ramp
  entry.rws = k.rws
  entry.cradle = k.rws.cradle
  entry.allSeats = {
    { seat = k.driverSeat, role = "driver", index = 0 },
    { seat = k.commanderSeat, role = "commander", index = 0 },
  }
  for i, seat in ipairs(k.troopSeats) do
    table.insert(entry.allSeats, { seat = seat, role = "troop", index = i - 1 })
  end
  entry.seats = { driver = k.driverSeat, commander = k.commanderSeat }
  entry.aboard = {}
  entry.rampOpen = false
  entry.recoil = 0
  entry.nextBurst = 0
  addPrompts(entry, anchors)

  -- Unanchor everything except the chassis, last, after every weld exists. The anchored
  -- chassis carries the welded parts (and seated players) wherever its CFrame is set.
  entry.params = rayParams({ car })
  entry.chassisOffset = k.off(0, DIM.CHASSIS_Y, DIM.CHASSIS_Z)
  entry.drive = { pos = root.Position, heading = headingOf(root), pitch = 0, roll = 0, vy = 0, grounded = false }
  for _, p in ipairs(k.parts) do
    if p ~= chassis then p.Anchored = false end
  end

  keepRunning(entry, "driving", function() driveStryker(entry) end)
  keepRunning(entry, "gun and crew", function() stationLoop(entry) end)

  -- Keep the marker on the parked position; a map save stores it with the model.
  task.spawn(function()
    local shown = root
    while alive(entry) do
      task.wait(MARKER_UPDATE_INTERVAL)
      pcall(function()
        local ground = chassis.CFrame * CFrame.new(0, -DIM.CHASSIS_Y * SCALE, -DIM.CHASSIS_Z * SCALE)
        local cf = flatFrame(ground.Position, ground.LookVector)
        if (cf.Position - shown.Position).Magnitude > 0.1 or cf.LookVector:Dot(shown.LookVector) < 0.99995 then
          marker.CFrame = cf
          shown = cf
        end
      end)
    end
  end)

  print("[Stryker] built " .. #k.parts .. " parts for " .. owner)
  if dropOwnerIn then
    tell(owner .. " deployed a Stryker. Walk up and press E to get in: driver (front left), commander (right side) or board at the ramp.", owner)
  end
end

local function createStryker(key, owner, root, dropOwnerIn)
  local car = Instance.new("Model")
  car.Name = owner .. "_Stryker"
  f(car) -- the Model goes into the map first; parts are then parented into it
  local entry = { key = key, car = car, carName = car.Name, owner = owner, seats = {}, aboard = {}, parts = {} }
  Strykers[key] = entry
  local ok, err = pcall(buildStryker, owner, car, root, entry, dropOwnerIn)
  if not ok then
    print("[Stryker] build failed: " .. tostring(err))
    if dropOwnerIn then tell("Stryker failed to build: " .. tostring(err), owner) end
    if Strykers[key] == entry then Strykers[key] = nil end
    destroyEntry(entry)
  end
  return ok
end

local function countActive()
  local n = 0
  for _, entry in pairs(Strykers) do
    if alive(entry) then n = n + 1 end
  end
  return n
end

local function clearStrays(owner)
  local ours = {}
  for _, entry in pairs(Strykers) do ours[entry.car] = true end
  pcall(function()
    for _, inst in ipairs(mapRoot():GetChildren()) do
      if inst.Name == owner .. "_Stryker" and not ours[inst] then dispose(inst) end
    end
  end)
end

local lastSpawn = {}
local function spawnStryker(player)
  local now = tick()
  if lastSpawn[player] and now - lastSpawn[player] < LIMITS.SPAWN_COOLDOWN then
    tell("Wait a few seconds before spawning another Stryker.", player)
    return
  end
  local playerCF = playerCFrame(player)
  if not playerCF then
    tell("Couldn't find where you are. Respawn and try :spawn stryker again.", player)
    return
  end
  for key, entry in pairs(Strykers) do
    if entry.owner == player then destroyStryker(key) end
  end
  clearStrays(player)
  if countActive() >= LIMITS.MAX_ACTIVE then
    tell("There are already " .. LIMITS.MAX_ACTIVE .. " Strykers out. Remove one before spawning another.", player)
    return
  end
  lastSpawn[player] = now
  local ahead = (playerCF * CFrame.new(0, 0, -26)).Position
  -- Place the wheels on whatever floor is there instead of guessing from the player's height.
  local ground = groundBelow(ahead) or (ahead - Vector3.new(0, 3, 0))
  createStryker(player, player, flatFrame(ground + Vector3.new(0, 0.3, 0), playerCF.LookVector), true)
end

-- :fire and the mousedown event: fire the gun of whichever Stryker this player commands.
local function chatControl(player)
  for _, entry in pairs(Strykers) do
    local inside = false
    pcall(function() inside = alive(entry) and inSeat(entry.allSeats[2].seat, player) end)
    if inside then
      shoot(entry, player)
      return
    end
  end
end

local function enterStryker(player, role)
  local pos = playerPos(player)
  if not pos then return end
  local best, bestDist = nil, 50
  for _, entry in pairs(Strykers) do
    if entry.chassis and alive(entry) then
      local d = (entry.chassis.Position - pos).Magnitude
      if d < bestDist then best, bestDist = entry, d end
    end
  end
  if not best then
    tell("No Stryker close enough. Walk up to one and try again.", player)
    return
  end
  if best.aboard[player] then
    tell("Hop out of your seat first (Space), then try again.", player)
    return
  end
  local choices = {}
  if role == "driver" then
    choices = { best.allSeats[1] }
  elseif role == "commander" then
    choices = { best.allSeats[2] }
  else
    for i = 3, #best.allSeats do table.insert(choices, best.allSeats[i]) end
  end
  for _, seatInfo in ipairs(choices) do
    if not seatInfo.seat.Occupant and not occupantName(seatInfo.seat) then
      seatPlayer(seatInfo.seat, player, player)
      return
    end
  end
  tell("That seat is taken.", player)
end

---------------------------------------------------------------------------------------------
-- Save / restore
---------------------------------------------------------------------------------------------

local function uniqueKey(owner)
  local key, n = owner, 2
  while Strykers[key] do
    key = owner .. "#" .. n
    n = n + 1
  end
  return key
end

local function strykerOwner(model)
  local ok, name = pcall(function() return model.Name end)
  if ok and type(name) == "string" then return string.match(name, "^(.+)_Stryker$") end
  return nil
end

-- Where a saved model was parked, worked out from its wheels (used when there is no marker).
local function parkedFromTyres(model)
  local ok, parked = pcall(function()
    local sum = Vector3.new(0, 0, 0)
    local right = Vector3.new(0, 0, 0)
    local points = {}
    for _, d in ipairs(model:GetDescendants()) do
      if d.Name == "RoadWheel" or d.Name == "RoadWheelRear" then
        table.insert(points, d.Position)
        sum = sum + d.Position
        if d.Name == "RoadWheelRear" then right = right + d.CFrame.RightVector end
      end
    end
    if #points < 6 then return nil end
    local centre = sum / #points
    for _, p in ipairs(points) do
      if (p - centre).Magnitude > 20 then return nil end
    end
    local flat = Vector3.new(right.X, 0, right.Z)
    if flat.Magnitude < 0.1 then return nil end
    local forward = Vector3.new(0, 1, 0):Cross(flat.Unit)
    local meanZ = 0
    for _, z in ipairs(DIM.AXLES) do meanZ = meanZ + z end
    meanZ = meanZ / #DIM.AXLES
    return flatFrame(centre - Vector3.new(0, DIM.WHEEL_R * SCALE, 0) + forward * (meanZ * SCALE), forward)
  end)
  if ok then return parked end
  return nil
end

local function setLiveNames(suffix)
  for _, entry in pairs(Strykers) do
    pcall(function()
      entry.car.Name = entry.carName .. suffix
      if entry.marker then entry.marker.Name = MARKER_NAME .. suffix end
    end)
  end
end

local function findSavedStrykers()
  local jobs = {}
  setLiveNames("#live")
  local scanned = pcall(function()
    for _, inst in ipairs(mapRoot():GetChildren()) do
      if inst.Name == MARKER_NAME then
        table.insert(jobs, { marker = inst, model = false, root = inst.CFrame })
      elseif strykerOwner(inst) and inst:IsA("Model") then
        local marker = inst:FindFirstChild(MARKER_NAME)
        if marker then
          table.insert(jobs, { marker = marker, model = inst, root = marker.CFrame })
        else
          table.insert(jobs, { marker = false, model = inst, root = false })
        end
      end
    end
  end)
  if not scanned then
    for _ = 1, 100 do
      local m = f(MARKER_NAME)
      if not m then break end
      m.Name = MARKER_NAME .. "#taken"
      local model = m.Parent
      if not strykerOwner(model) then model = false end
      table.insert(jobs, { marker = m, model = model, root = m.CFrame })
    end
  end
  setLiveNames("")
  return jobs
end

-- Loose parts that older revisions leaked into the map root (f() pulled them out of the Model).
-- Names are Stryker-specific, and only massless parts are touched, so map geometry is safe.
local LEFTOVERS = {
  RoadWheel = true, RoadWheelRear = true, LowerWall = true, RearPillar = true, FloorMat = true,
  BulkheadLiner = true, Ramp = true, DriverSeat = true, CommanderSeat = true, TroopSeat = true,
  ArmourTile = true, BowTile = true, GlacisTile = true, LugNut = true, TyreValve = true, HubCap = true,
  UpperGlacis = true, LowerGlacis = true, SponsonFloor = true, WallLiner = true, RoofLiner = true,
  RampHeader = true, RampLiner = true, RampDoor = true, RampDoorSeam = true, RampDoorHinge = true,
  RampVisionBlock = true, RampHandle = true, RampHinge = true, RampLock = true, RampTread = true,
  DriverHatchRing = true, DriverHatch = true, DriverHatchHinge = true, DriverHatchHandle = true,
  DriverPeriscope = true, PeriscopeHood = true, CommanderRing = true, CommanderHatch = true,
  CommanderHatchHinge = true, CommanderHatchHandle = true, TroopHatchFrame = true, TroopHatch = true,
  TroopHatchHinge = true, TroopHatchHandle = true, TroopHatchLatch = true, TroopHatchVision = true,
  RwsBase = true, RwsMount = true, RwsPedestal = true, RwsCable = true, RwsJunctionBox = true, RwsYoke = true,
  RwsSmokeTube = true, RwsAmmoCan = true, RwsAmmoLid = true, RwsFeedChute = true, RwsCradle = true,
  RwsReceiver = true, RwsFeedCover = true, RwsChargingHandle = true, RwsJacket = true, RwsJacketHole = true,
  RwsBarrel = true, RwsCarryHandle = true, RwsCarryHandlePost = true, RwsFrontSight = true,
  RwsFlashHider = true, RwsSight = true, RwsSightArm = true, RwsSunshade = true, RwsDayCamera = true,
  RwsThermal = true, RwsLaser = true, BenchFrame = true, BenchBack = true, SeatDivider = true,
  TroopSeatBack = true, DriverDoor = true, CommanderDoor = true, RearDoor = true, AimDot = true,
}

local function clearLeftovers()
  local cleared = 0
  pcall(function()
    for _, inst in ipairs(mapRoot():GetChildren()) do
      if LEFTOVERS[inst.Name] and inst:IsA("BasePart") and inst.Massless == true then
        dispose(inst)
        cleared = cleared + 1
        if cleared % 100 == 0 then task.wait() end
      end
    end
  end)
  return cleared
end

---------------------------------------------------------------------------------------------
-- One running copy at a time. If the addon is run again, the newer copy takes over and the
-- older one goes quiet. A token left over in a saved map is never treated as a rival: it is
-- older than this copy, so it gets cleared. (Rev 10 retired itself whenever a saved map
-- brought its own old token back, and then ignored every command; that was one reason
-- ":spawn stryker" sometimes did nothing.)
---------------------------------------------------------------------------------------------

local function stampToken()
  pcall(function()
    COPY.stamp = math.floor(tick())
    local token = Instance.new("Part")
    token.Name = COPY.PREFIX .. COPY.REVISION .. "#" .. string.format("%d", COPY.stamp) .. "-" .. math.random(1, 999999)
    token.Size = Vector3.new(0.2, 0.2, 0.2)
    token.Transparency = 1
    token.Anchored = true
    token.CanCollide = false
    token.CanQuery = false
    token.CanTouch = false
    token.CFrame = CFrame.new(0, 3000, 0)
    f(token)
    COPY.name = token.Name
    COPY.token = token
  end)
end

-- Other copies' tokens. Ones from newer copies (higher revision, or same revision started
-- later) are returned; older ones are deleted on sight.
local function newerRivals()
  local newer = {}
  pcall(function()
    for _, inst in ipairs(mapRoot():GetChildren()) do
      local rev, stamp = string.match(inst.Name, "^StrykerAddon#(%d+)#(%d+)")
      if rev and inst.Name ~= COPY.name then
        rev, stamp = tonumber(rev), tonumber(stamp)
        if rev > COPY.REVISION or (rev == COPY.REVISION and stamp > COPY.stamp) then
          table.insert(newer, inst)
        else
          dispose(inst)
        end
      end
    end
  end)
  return newer
end

local function claimCopy()
  COPY.stamp = math.floor(tick())
  if #newerRivals() > 0 then
    COPY.retired = true
    print("[Stryker] a newer copy of this addon is running, so this one stays inactive")
    return false
  end
  stampToken()
  return true
end

local function copyActive()
  if COPY.retired then return false end
  local here = false
  pcall(function() here = COPY.token and COPY.token.Parent ~= nil and COPY.token.Name == COPY.name end)
  if here then return true end
  if #newerRivals() > 0 then
    COPY.retired = true
    print("[Stryker] a newer copy of this addon took over, so this one goes inactive")
    return false
  end
  -- our token was cleared (map reload, cleanup): put it back and carry on
  local stamp = COPY.stamp
  stampToken()
  COPY.stamp = stamp
  return true
end

local function restoreSavedStrykers()
  if not copyActive() then return 0 end
  local has = {}
  for key, entry in pairs(Strykers) do
    if alive(entry) then has[entry.owner] = true else Strykers[key] = nil end
  end
  local jobs = findSavedStrykers()
  local restored, orphans = 0, 0
  for _, job in ipairs(jobs) do
    local owner = nil
    local root = job.root
    if job.model then
      owner = strykerOwner(job.model)
      local parked = parkedFromTyres(job.model)
      -- the marker is anchored, so it is the reliable record; tyres are the fallback
      if parked and not root then root = parked end
    end
    dispose(job.model)
    dispose(job.marker)
    -- Markers with no model have no owner; give each its own name so none get dropped.
    if not owner then
      orphans = orphans + 1
      owner = "Saved" .. orphans
    end
    if root and not has[owner] then
      has[owner] = true
      if createStryker(uniqueKey(owner), owner, root * CFrame.new(0, 0.5, 0), false) then
        restored = restored + 1
      end
    end
  end
  return restored
end

---------------------------------------------------------------------------------------------
-- Startup and events
---------------------------------------------------------------------------------------------

local STARTUP = { OFFSET = 8, SETTLED = 3, MAX_WAIT = 60, SECOND_PASS = 20 }
claimCopy()

-- Wait for the saved map to finish loading, then rebuild saved Strykers in place.
task.spawn(function()
  task.wait(STARTUP.OFFSET)
  local count, steady = -1, 0
  for _ = 1, STARTUP.MAX_WAIT do
    local now = 0
    pcall(function() now = #mapRoot():GetChildren() end)
    if now == count then steady = steady + 1 else steady = 0 end
    count = now
    if steady >= STARTUP.SETTLED then break end
    task.wait(1)
  end
  for pass = 1, 2 do
    if pass == 2 then task.wait(STARTUP.SECOND_PASS) end
    if not copyActive() then return end
    local ok, n = pcall(restoreSavedStrykers)
    local cleared = clearLeftovers()
    if not ok then
      print("[Stryker] restore pass failed: " .. tostring(n))
    elseif n > 0 or cleared > 0 then
      print("[Stryker] restored " .. n .. " saved Strykers, cleared " .. cleared .. " loose leftovers")
    end
  end
end)

event("mousedown", function(data)
  local player = nil
  pcall(function() player = data.Value[1] end)
  if type(player) == "string" and not COPY.retired then task.spawn(chatControl, player) end
end)

local function versionReport(player)
  local state = "in charge"
  if not copyActive() then state = "INACTIVE (another copy of this addon is in charge)" end
  tell("Stryker addon rev " .. COPY.REVISION .. ": " .. state .. ", " .. countActive() .. " built.", player)
end

local lastCleanup = -1000
event("chatted", function(data)
  local player = data.Value[1]
  local message = data.Value[2]
  if type(player) ~= "string" or type(message) ~= "string" then return end
  local command = string.match(string.lower(message), "^%s*(.-)%s*$")
  if command == ":vehicles" then
    task.spawn(versionReport, player)
    return
  end
  if string.sub(command, 1, 1) ~= ":" or not copyActive() then return end
  if command == ":spawn stryker" then
    task.spawn(spawnStryker, player)
  elseif command == ":fire" then
    task.spawn(chatControl, player)
  elseif command == ":cleanup vehicles" then
    if tick() - lastCleanup < LIMITS.CLEANUP_COOLDOWN then
      tell("Cleanup ran recently. Try again in a bit.", player)
      return
    end
    lastCleanup = tick()
    task.spawn(function()
      local rebuilt = restoreSavedStrykers()
      local cleared = clearLeftovers()
      tell("Stryker: " .. rebuilt .. " rebuilt, " .. cleared .. " loose leftovers cleared.", player)
    end)
  else
    local role = string.match(command, "^:stryker (%a+)$")
    if role == "driver" or role == "commander" or role == "board" then
      task.spawn(enterStryker, player, role)
    end
  end
end)
