-- STRYKER TURRET TEST: the Stryker's own detailed remote weapon station (.50 cal) and commander
-- seat, on their own, with the Stryker's aiming and firing. Use it to see which piece works in
-- this game. Run it as its own persistent addon (turn the Stryker addon off while testing). Chat:
--   :turret         build the test turret in front of you
--   :turret report  what worked so far (also printed to the server log)
--   :turret ping    is the addon still running?
--   :turret fire    fire once without clicking (tests firing apart from clicking)
--   :turret clear   remove it
-- Then: sit in the commander seat, press W/S and A/D (the gun should move), click the gun (it fires).
-- It fires on ANY click (like the input lab) and separately reports what the Stryker's
-- "is this the commander?" check would have said.

local SCALE = 1.25
local DIM = {
  CHASSIS_Y = 1.9, CHASSIS_Z = 3.96, HULL_X = 4.3, ROOF_Y = 6.7, RWS_X = 1.5, RWS_Z = -1.0, GUN_Y = 9.5,
  SEAT_Y = 3.0, COMMANDER_X = 0.6, COMMANDER_Z = -3.0,
}
local GUN = {
  RANGE = 1000, TRAVERSE_SPEED = math.rad(60), ELEVATE_SPEED = math.rad(45), MIN_PITCH = math.rad(-20),
  MAX_PITCH = math.rad(60), BURST = 5, ROUND_GAP = 0.09, COOLDOWN = 0.8, SPREAD = math.rad(0.3), MUZZLE = 4.95,
  TRACER_SPEED = 900, RECOIL = 0.3, CLICK_RANGE = 80,
}
local function rgb(r, g, b) return Color3.new(r / 255, g / 255, b / 255) end
local COLOR = {
  TAN = rgb(196, 173, 128), TAN_DARK = rgb(158, 138, 100), BLACK = rgb(28, 28, 26), GUN = rgb(34, 34, 32),
  OLIVE = rgb(86, 92, 58), SEAT = rgb(60, 62, 48), GLASS = rgb(30, 40, 38), STEEL = rgb(54, 54, 50),
  FLASH = Color3.new(1, 0.86, 0.5), TRACER = Color3.new(1, 0.62, 0.2),
}
local MAT = {
  SMOOTH = Enum.Material.SmoothPlastic, METAL = Enum.Material.Metal, RUBBER = Enum.Material.Rubber,
  NEON = Enum.Material.Neon, FABRIC = Enum.Material.Fabric,
}
local function ry(deg) return CFrame.Angles(0, math.rad(deg), 0) end
local function rz(deg) return CFrame.Angles(0, 0, math.rad(deg)) end

local T = {
  model = false, seat = false, rws = false, owner = false,
  yaw = 0, pitch = 0, recoil = 0, nextBurst = 0,
  ticks = 0, slowestTick = 0, buildTime = 0, parts = 0,
  seen = {}, clicks = 0, shots = 0, lastClick = "none yet", mousedown = "not seen yet",
  lastFire = "none yet", aimError = "none", lastTick = 0,
}

local function tell(message, player)
  print("[Turret] " .. message)
  pcall(announce, message, player)
end

local function nameOf(who)
  if type(who) == "string" then return who end
  local ok, name = pcall(function() return who.Name end)
  if ok and type(name) == "string" then return name end
  return nil
end

local function playerPos(name)
  local ok, cf = pcall(getPlayerPosition, name)
  if not ok then return nil end
  if typeof(cf) == "CFrame" then return cf.Position end
  if typeof(cf) == "Vector3" then return cf end
  return nil
end

-- announce the first time each piece works
local function saw(what)
  if not T.seen[what] then
    T.seen[what] = true
    tell("Turret test: " .. what .. " WORKS", T.owner)
  end
end

local built = {} -- every part, in case f() moved some out of the model
local function clear()
  if T.model then pcall(function() T.model:Destroy() end) end
  for _, p in ipairs(built) do pcall(function() p:Destroy() end) end
  built = {}
  T.model, T.seat, T.rws = false, false, false
end

---------------------------------------------------------------------------------------------
-- Builder: the same kit the Stryker uses (parts welded to an anchored chassis part)
---------------------------------------------------------------------------------------------

local function newKit(model, root)
  local k = { pinned = {} }
  function k.at(x, y, z) return root * CFrame.new(x * SCALE, y * SCALE, z * SCALE) end
  function k.off(x, y, z) return CFrame.new(x * SCALE, y * SCALE, z * SCALE) end
  function k.facing(x, y, z, dx, dy, dz)
    local p = Vector3.new(x, y, z) * SCALE
    return root * CFrame.new(p, p + Vector3.new(dx, dy, dz))
  end
  function k.make(className, name, size, cf, color, material, weldTo, shape)
    local p = Instance.new(className)
    p.Name = name
    if shape then p.Shape = shape end
    p.Size = size * SCALE
    p.CFrame = cf
    p.Color = color
    p.Material = material
    p.Anchored = not weldTo
    p.CanCollide = false
    p.CanQuery = false
    p.Parent = model
    pcall(f, p)
    if weldTo then
      local w = Instance.new("WeldConstraint")
      w.Part0 = weldTo
      w.Part1 = p
      w.Parent = weldTo
    else
      table.insert(k.pinned, p)
    end
    T.parts = T.parts + 1
    table.insert(built, p)
    return p
  end
  function k.block(name, sx, sy, sz, cf, color, material, weldTo)
    return k.make("Part", name, Vector3.new(sx, sy, sz), cf, color, material, weldTo, false)
  end
  function k.cylinder(name, length, diameter, cf, color, material, weldTo)
    return k.make("Part", name, Vector3.new(length, diameter, diameter), cf, color, material, weldTo, Enum.PartType.Cylinder)
  end
  function k.bolt(cf, weldTo)
    return k.cylinder("Bolt", 0.06, 0.16, cf, COLOR.TAN_DARK, MAT.METAL, weldTo)
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

-- The Stryker's remote weapon station, unchanged.
local function buildRws(k)
  local c = k.chassis
  local x, z, roof, gy = DIM.RWS_X, DIM.RWS_Z, DIM.ROOF_Y, DIM.GUN_Y
  local block, cylinder, at = k.block, k.cylinder, k.at
  cylinder("RwsBase", 0.4, 2.2, at(x, roof + 0.2, z) * rz(90), COLOR.TAN_DARK, MAT.METAL, c)
  for b = 0, 7 do
    local a = b * math.pi / 4
    k.bolt(at(x + 0.95 * math.cos(a), roof + 0.42, z + 0.95 * math.sin(a)) * rz(90), c)
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
  for i = 0, 2 do
    cylinder("RwsJacketHole", 0.02, 0.1, at(x + 0.15, gy, z - 0.85 - i * 0.22), COLOR.BLACK, MAT.SMOOTH, cradle)
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
  for _, p in ipairs(trigger) do p.CanQuery = true end
  k.rws = { yaw = yaw, yawBase = yaw.C0, pitch = pitch, pitchBase = pitch.C0, cradle = cradle, trigger = trigger }
end

---------------------------------------------------------------------------------------------
-- Firing: the Stryker's 5-round burst (muzzle flash, tracer flying on a tween)
---------------------------------------------------------------------------------------------

-- One shot, done exactly like the input lab's fireShell (the firing that worked in this game):
-- a raycast decides where it lands, a shell part flies there on a tween, a small explosion.
-- Every step is recorded, so a failure says which step it was.
local function fireShot(shooter, source)
  local log = {}
  local function step(name, fn)
    local ok, err = pcall(fn)
    table.insert(log, name .. (ok and " ok" or (" FAILED: " .. tostring(err))))
    return ok
  end
  if not T.rws then
    T.lastFire = source .. ": no turret built"
    return
  end
  if tick() < T.nextBurst then return end
  T.nextBurst = tick() + 0.5
  local from, dir, hitPos, hitName = nil, nil, nil, "nothing"
  step("aim", function()
    local muzzle = T.rws.cradle.CFrame * CFrame.new(0, 0, -GUN.MUZZLE * SCALE)
    from, dir = muzzle.Position, muzzle.LookVector
    hitPos = from + dir * 300
  end)
  if not from then
    T.lastFire = source .. ": " .. table.concat(log, ", ")
    tell("Turret fire " .. T.lastFire, T.owner)
    return
  end
  step("raycast", function()
    local params = RaycastParams.new()
    local ignore = { T.model }
    for _, p in ipairs(built) do table.insert(ignore, p) end
    params.FilterDescendantsInstances = ignore
    params.FilterType = Enum.RaycastFilterType.Exclude
    local hit = raycast(from, dir * 300, params)
    if hit then
      hitPos = hit.Position
      hitName = tostring(hit.Instance)
    end
  end)
  local shell = nil
  local flight = math.max(0.05, (hitPos - from).Magnitude / 250)
  step("shell", function()
    shell = Instance.new("Part")
    shell.Name = "TestShell"
    shell.Size = Vector3.new(0.4, 0.4, 1.4)
    shell.CFrame = CFrame.new(from, from + dir)
    shell.Color = Color3.new(1, 0.7, 0.3)
    shell.Material = Enum.Material.Neon
    shell.Anchored = true
    shell.CanCollide = false
    shell.Parent = T.model
    f(shell)
  end)
  step("tween", function()
    tween(shell, TweenInfo.new(flight, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, false, 0),
      { CFrame = CFrame.new(hitPos, hitPos + dir) })
  end)
  task.spawn(function()
    task.wait(flight)
    pcall(function() shell:Destroy() end)
    pcall(function()
      local boom = Instance.new("Explosion")
      boom.Position = hitPos
      boom.BlastRadius = 3
      boom.BlastPressure = 0
      boom.DestroyJointRadiusPercent = 0
      f(boom)
    end)
  end)
  T.recoil = GUN.RECOIL
  T.shots = T.shots + 1
  T.lastFire = source .. " by " .. tostring(shooter) .. ": " .. table.concat(log, ", ") .. "; hit " .. hitName
    .. " at " .. tostring(math.floor((hitPos - from).Magnitude)) .. " studs"
  print("[Turret] fire " .. T.lastFire)
  saw("FIRING")
end

-- the Stryker's "is this the commander?" checks, reported but NOT required here
local function seatCheck(name)
  local occupied, occName, dist = false, "unreadable", -1
  pcall(function() occupied = T.seat.Occupant ~= nil end)
  pcall(function() occName = T.seat.Occupant.Parent.Name end)
  pcall(function() dist = (playerPos(name) - T.seat.Position).Magnitude end)
  local wouldFire = occupied and (occName == name or (dist >= 0 and dist <= 10))
  return "seat occupied " .. tostring(occupied) .. ", occupant name " .. tostring(occName) .. ", clicker "
    .. tostring(math.floor((tonumber(dist) or -1) * 10 + 0.5) / 10) .. " studs from seat -> Stryker would "
    .. (wouldFire and "FIRE" or "REFUSE")
end

local function onClick(who, button)
  local ok, err = pcall(function()
    local name = nameOf(who)
    T.clicks = T.clicks + 1
    local check = "seat check failed"
    pcall(function() check = seatCheck(name) end)
    T.lastClick = tostring(name) .. " (" .. button .. "): " .. check
    print("[Turret] click " .. T.clicks .. ": " .. T.lastClick)
    saw("CLICKING THE GUN")
    fireShot(name, "click")
  end)
  if not ok then
    T.lastClick = "CLICK HANDLER ERROR: " .. tostring(err)
    tell("Turret test: " .. T.lastClick, T.owner)
  end
end

---------------------------------------------------------------------------------------------
-- Build: roof section with the turret, commander seat underneath (Stryker positions)
---------------------------------------------------------------------------------------------

local function build(player)
  clear()
  local started = tick()
  local cf = nil
  pcall(function() cf = getPlayerPosition(player) end)
  if typeof(cf) ~= "CFrame" then
    tell("Turret test: couldn't find you (getPlayerPosition gave " .. typeof(cf) .. ")", player)
    return
  end
  T.owner = player
  T.parts = 0
  local look = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z).Unit
  local feet = cf.Position - Vector3.new(0, 3, 0) + look * 12
  local root = CFrame.new(feet, feet + look)

  local model = Instance.new("Model")
  model.Name = "StrykerTurretTest"
  f(model)
  T.model = model
  local k = newKit(model, root)
  local chassis = k.block("Chassis", 3.0, 0.4, 4.0, k.at(0, DIM.CHASSIS_Y, DIM.CHASSIS_Z), COLOR.BLACK, MAT.SMOOTH, false)
  chassis.Transparency = 1
  k.chassis = chassis
  -- floor, a roof section with the commander hatch, and two posts holding it up
  local floor = k.block("TestFloor", 8.6, 0.3, 8, k.at(0, 0.15, -2.5), COLOR.TAN_DARK, MAT.SMOOTH, chassis)
  floor.CanCollide = true
  local roof = k.block("TestRoof", 8.6, 0.3, 6.5, k.at(0, DIM.ROOF_Y - 0.15, -2.5), COLOR.TAN, MAT.SMOOTH, chassis)
  roof.CanCollide = true
  for _, s in ipairs({ -1, 1 }) do
    k.block("TestPost", 0.4, DIM.ROOF_Y - 0.3, 0.4, k.at(s * 4.0, DIM.ROOF_Y / 2, 0.4), COLOR.TAN, MAT.SMOOTH, chassis)
  end
  k.cylinder("CommanderRing", 0.2, 2.0, k.at(-1.0, DIM.ROOF_Y + 0.1, -3.2) * rz(90), COLOR.TAN_DARK, MAT.METAL, chassis)
  buildRws(k)

  local seat = k.make("VehicleSeat", "CommanderSeat", Vector3.new(1.5, 0.4, 1.4),
    k.at(DIM.COMMANDER_X, DIM.SEAT_Y, DIM.COMMANDER_Z), COLOR.SEAT, MAT.FABRIC, chassis, false)
  seat.CanCollide = true
  seat.CanQuery = true
  seat.MaxSpeed = 0
  seat.Torque = 0
  seat.TurnSpeed = 0
  seat.HeadsUpDisplay = false
  T.seat = seat

  for _, gunPart in ipairs(k.rws.trigger) do
    local ok, err = pcall(function()
      local detector = Instance.new("ClickDetector")
      detector.MaxActivationDistance = GUN.CLICK_RANGE
      detector.Parent = gunPart
      detector.MouseClick:Connect(function(who) onClick(who, "left") end)
      detector.RightMouseClick:Connect(function(who) onClick(who, "right") end)
    end)
    if not ok then tell("Turret test: ClickDetector could not be made: " .. tostring(err), player) end
  end
  for _, p in ipairs(k.pinned) do
    if p ~= chassis then p.Anchored = false end
  end
  T.rws = k.rws
  T.yaw, T.pitch, T.recoil = 0, 0, 0
  T.buildTime = tick() - started
  tell(string.format("Turret test built (%d parts in %.1f s). Sit in the seat under the roof, press W/S and A/D, then click the gun. :turret report shows results.",
    T.parts, T.buildTime), player)
end

---------------------------------------------------------------------------------------------
-- Aim loop: the Stryker's turret code (A/D traverse, W/S elevate, recoil)
---------------------------------------------------------------------------------------------

task.spawn(function()
  local last = tick()
  while true do
    task.wait(0.03)
    local now = tick()
    local dt = math.min(now - last, 0.3)
    last = now
    T.ticks = T.ticks + 1
    local seat, rws = T.seat, T.rws
    if seat and rws then
      local ok, err = pcall(function()
        local moved = false
        if seat.Occupant then
          saw("SITTING IN THE SEAT")
          local steer, throttle = seat.Steer, seat.Throttle
          if throttle ~= 0 then saw("W/S IN THE SEAT") end
          if steer ~= 0 then saw("A/D IN THE SEAT") end
          if steer ~= 0 or throttle ~= 0 then
            T.yaw = (T.yaw - steer * GUN.TRAVERSE_SPEED * dt + math.pi) % (2 * math.pi) - math.pi
            T.pitch = math.max(GUN.MIN_PITCH, math.min(GUN.MAX_PITCH, T.pitch + throttle * GUN.ELEVATE_SPEED * dt))
            moved = true
          end
        end
        if T.recoil > 0 then
          T.recoil = math.max(0, T.recoil - dt * 4)
          moved = true
        end
        if moved then
          rws.yaw.C0 = rws.yawBase * CFrame.Angles(0, T.yaw, 0)
          rws.pitch.C0 = rws.pitchBase * CFrame.Angles(T.pitch, 0, 0) * CFrame.new(0, 0, T.recoil * SCALE)
          if seat.Occupant then saw("TURRET MOVING") end
        end
      end)
      if not ok then
        if T.aimError ~= tostring(err) then tell("Turret test: aim loop error: " .. tostring(err), T.owner) end
        T.aimError = tostring(err)
      end
    end
    T.slowestTick = math.max(T.slowestTick, tick() - now)
    T.lastTick = tick()
  end
end)

---------------------------------------------------------------------------------------------
-- Report and events
---------------------------------------------------------------------------------------------

local function report(player)
  local worked = {}
  for _, what in ipairs({ "SITTING IN THE SEAT", "W/S IN THE SEAT", "A/D IN THE SEAT", "TURRET MOVING",
    "CLICKING THE GUN", "FIRING" }) do
    table.insert(worked, what .. (T.seen[what] and " yes" or " NO"))
  end
  local lines = {
    "Turret report: " .. table.concat(worked, ", "),
    string.format("Built %d parts in %.1f s. Aim loop ran %d ticks (about 30 a second is healthy), slowest tick %.0f ms. Clicks %d, shots %d.",
      T.parts, T.buildTime, T.ticks, T.slowestTick * 1000, T.clicks, T.shots),
    "Last click: " .. T.lastClick,
    "Last shot: " .. T.lastFire,
    "Aim loop last ran " .. tostring(math.floor((tick() - T.lastTick) * 10) / 10) .. " s ago, last aim error: " .. T.aimError,
    "mousedown event: " .. T.mousedown,
  }
  for _, line in ipairs(lines) do tell(line, player) end
end

-- does the game send a click position with mousedown? (the Stryker's click-to-aim needs it)
event("mousedown", function(data)
  pcall(function()
    local who, tool, pos = data.Value[1], data.Value[2], data.Value[3]
    T.mousedown = "seen from " .. tostring(who) .. ", tool " .. tostring(tool) .. ", position " .. tostring(pos)
      .. " (" .. typeof(pos) .. ")"
  end)
end)

event("chatted", function(data)
  local player = data.Value[1]
  local message = data.Value[2]
  if type(player) ~= "string" or type(message) ~= "string" then return end
  local command = string.lower(message)
  if command == ":turret" then
    task.spawn(build, player)
  elseif command == ":turret report" then
    task.spawn(report, player)
  elseif command == ":turret ping" then
    tell("Turret test is alive. Aim loop ticks: " .. T.ticks .. ", last ran "
      .. tostring(math.floor((tick() - T.lastTick) * 10) / 10) .. " s ago.", player)
  elseif command == ":turret fire" then
    task.spawn(function()
      local ok, err = pcall(fireShot, player, ":turret fire")
      if not ok then tell("Turret test: :turret fire error: " .. tostring(err), player) end
      tell("Turret test: " .. T.lastFire, player)
    end)
  elseif command == ":turret clear" then
    clear()
    tell("Turret test removed.", player)
  end
end)

print("[Turret] Stryker turret test loaded. Type :turret to build it.")
