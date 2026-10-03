-- TURRET TEST: the Stryker's commander seat, gun, WASD aiming and click firing, on their own.
-- Built the same way as the input lab's test gun (the parts of the lab that worked).
-- Run it as its own persistent addon. Chat:
--   :turret         build the test turret in front of you
--   :turret report  what worked so far (also printed to the server log)
--   :turret clear   remove it
-- Then: sit in the seat, press W/S and A/D (the gun should move), click the gun (it should fire).

local T = {
  model = false, seat = false, gun = false, owner = false,
  yaw = 0, pitch = 0, nextShot = 0,
  ticks = 0, loopStarted = false, slowestTick = 0,
  seen = {}, clicks = 0, shots = 0, lastClick = "none yet", mousedown = "not seen yet",
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

-- record the first time something works, and say so
local function saw(what)
  if not T.seen[what] then
    T.seen[what] = true
    tell("Turret test: " .. what .. " WORKS", T.owner)
  end
end

-- same as the lab's part(): set Parent, then f()
local function part(name, size, cf, color, parent)
  local p = Instance.new("Part")
  p.Name = name
  p.Size = size
  p.CFrame = cf
  p.Color = color
  p.Material = Enum.Material.SmoothPlastic
  p.Anchored = true
  p.CanCollide = false
  p.Parent = parent
  f(p)
  return p
end

local function clear()
  if T.model then pcall(function() T.model:Destroy() end) end
  T.model, T.seat, T.gun = false, false, false
end

-- ===== FIRING (the lab's fireShell: one raycast decides, a shell flies there on a tween) =====
local function fire(shooter)
  if not T.gun or tick() < T.nextShot then return end
  T.nextShot = tick() + 0.4
  T.shots = T.shots + 1
  local muzzle = T.gun.cradle.CFrame * CFrame.new(0, 0, -4.5)
  local dir = muzzle.LookVector
  local from = muzzle.Position
  local params = nil
  pcall(function()
    params = RaycastParams.new()
    params.FilterDescendantsInstances = { T.model }
    params.FilterType = Enum.RaycastFilterType.Exclude
  end)
  local hitPos = from + dir * 300
  local ok, hit = pcall(raycast, from, dir * 300, params)
  if ok and hit then hitPos = hit.Position end
  local shell = part("TestShell", Vector3.new(0.3, 0.3, 1.5), CFrame.new(from, from + dir),
    Color3.new(1, 0.7, 0.3), T.model)
  pcall(function() shell.Material = Enum.Material.Neon end)
  local flight = math.max(0.05, (hitPos - from).Magnitude / 300)
  pcall(tween, shell, TweenInfo.new(flight, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, false, 0),
    { CFrame = CFrame.new(hitPos, hitPos + dir) })
  task.spawn(function()
    task.wait(flight)
    pcall(function() shell:Destroy() end)
    pcall(function()
      local boom = Instance.new("Explosion")
      boom.Position = hitPos
      boom.BlastRadius = 2
      boom.BlastPressure = 0
      boom.DestroyJointRadiusPercent = 0
      f(boom)
    end)
  end)
  saw("FIRING")
  print("[Turret] shot " .. T.shots .. " by " .. tostring(shooter) .. ", hit " .. (ok and hit and tostring(hit.Instance) or "nothing"))
end

-- the Stryker's seat checks, reported but NOT required (the lab fired on any click)
local function seatCheck(name)
  local seat = T.seat
  local occupied, occName, dist = false, "unreadable", -1
  pcall(function() occupied = seat.Occupant ~= nil end)
  pcall(function() occName = seat.Occupant.Parent.Name end)
  pcall(function() dist = (playerPos(name) - seat.Position).Magnitude end)
  return string.format("seat occupied %s, occupant name %s, clicker %.1f studs from seat",
    tostring(occupied), tostring(occName), dist)
end

local function onClick(who, button)
  local name = nameOf(who)
  T.clicks = T.clicks + 1
  T.lastClick = tostring(name) .. " (" .. button .. "): " .. seatCheck(name)
  print("[Turret] click " .. T.clicks .. ": " .. T.lastClick)
  saw("CLICKING THE GUN")
  fire(name)
end

-- ===== BUILD (the lab's buildRange gun, plus a seat) =====
local function build(player)
  clear()
  local cf = nil
  pcall(function() cf = getPlayerPosition(player) end)
  if typeof(cf) ~= "CFrame" then
    tell("Turret test: couldn't find you (getPlayerPosition gave " .. typeof(cf) .. ")", player)
    return
  end
  T.owner = player
  local look = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z).Unit
  local feet = cf.Position - Vector3.new(0, 3, 0) + look * 8
  local root = CFrame.new(feet, feet + look)
  local at = function(x, y, z) return root * CFrame.new(x, y, z) end

  local model = Instance.new("Model")
  model.Name = "TurretTest"
  f(model)
  T.model = model

  local floor = part("TestFloor", Vector3.new(10, 0.4, 10), at(0, 0.2, 0), Color3.new(0.5, 0.5, 0.52), model)
  floor.CanCollide = true

  local seat = Instance.new("VehicleSeat")
  seat.Name = "TestCommanderSeat"
  seat.Size = Vector3.new(2, 0.6, 2)
  seat.CFrame = at(0, 0.7, 2)
  seat.Color = Color3.new(0.2, 0.2, 0.22)
  seat.Anchored = true
  seat.CanCollide = true
  seat.MaxSpeed = 0
  seat.Torque = 0
  seat.TurnSpeed = 0
  seat.HeadsUpDisplay = false
  seat.Parent = model
  f(seat)
  T.seat = seat

  -- gun: anchored base, yaw part and pitch part on Welds, barrel on a WeldConstraint
  local base = part("GunBase", Vector3.new(2, 1, 2), at(0, 0.9, -2), Color3.new(0.2, 0.21, 0.2), model)
  local yawPart = part("GunTurret", Vector3.new(1.8, 0.8, 2), base.CFrame * CFrame.new(0, 0.9, 0), Color3.new(0.77, 0.68, 0.5), model)
  local cradle = part("GunCradle", Vector3.new(0.7, 0.7, 0.7), yawPart.CFrame * CFrame.new(0, 0.75, -0.4), Color3.new(0.2, 0.21, 0.2), model)
  local barrel = part("GunBarrel", Vector3.new(4, 0.35, 0.35), cradle.CFrame * CFrame.new(0, 0, -2.2) * CFrame.Angles(0, math.pi / 2, 0), Color3.new(0.2, 0.21, 0.2), model)
  barrel.Shape = Enum.PartType.Cylinder
  yawPart.Anchored = false
  cradle.Anchored = false
  barrel.Anchored = false
  local yawWeld = Instance.new("Weld")
  yawWeld.Part0 = base
  yawWeld.Part1 = yawPart
  yawWeld.C0 = CFrame.new(0, 0.9, 0)
  yawWeld.C1 = CFrame.new()
  yawWeld.Parent = base
  local pitchWeld = Instance.new("Weld")
  pitchWeld.Part0 = yawPart
  pitchWeld.Part1 = cradle
  pitchWeld.C0 = CFrame.new(0, 0.75, -0.4)
  pitchWeld.C1 = CFrame.new()
  pitchWeld.Parent = yawPart
  local hold = Instance.new("WeldConstraint")
  hold.Part0 = cradle
  hold.Part1 = barrel
  hold.Parent = cradle
  T.gun = { yaw = yawWeld, yawBase = yawWeld.C0, pitch = pitchWeld, pitchBase = pitchWeld.C0, cradle = cradle }
  T.yaw, T.pitch = 0, 0

  for _, gunPart in ipairs({ base, yawPart, cradle, barrel }) do
    local ok, err = pcall(function()
      local detector = Instance.new("ClickDetector")
      detector.MaxActivationDistance = 60
      detector.Parent = gunPart
      detector.MouseClick:Connect(function(who) onClick(who, "left") end)
      detector.RightMouseClick:Connect(function(who) onClick(who, "right") end)
    end)
    if not ok then tell("Turret test: ClickDetector could not be made: " .. tostring(err), player) end
  end
  tell("Turret test built. Sit in the seat, press W/S and A/D, then click the gun. :turret report shows results.", player)
end

-- ===== AIM LOOP (exactly the lab's seat watcher) =====
task.spawn(function()
  T.loopStarted = true
  while true do
    task.wait(0.05)
    local started = tick()
    T.ticks = T.ticks + 1
    local seat, gun = T.seat, T.gun
    if seat and gun then
      local ok, err = pcall(function()
        if seat.Occupant then
          saw("SITTING IN THE SEAT")
          local throttle, steer = seat.Throttle, seat.Steer
          if throttle ~= 0 then saw("W/S IN THE SEAT") end
          if steer ~= 0 then saw("A/D IN THE SEAT") end
          if throttle ~= 0 or steer ~= 0 then
            T.yaw = T.yaw - steer * math.rad(60) * 0.05
            T.pitch = math.max(math.rad(-10), math.min(math.rad(45), T.pitch + throttle * math.rad(30) * 0.05))
            gun.yaw.C0 = gun.yawBase * CFrame.Angles(0, T.yaw, 0)
            gun.pitch.C0 = gun.pitchBase * CFrame.Angles(T.pitch, 0, 0)
            saw("TURRET MOVING")
          end
        end
      end)
      if not ok then print("[Turret] aim loop error: " .. tostring(err)) end
    end
    T.slowestTick = math.max(T.slowestTick, tick() - started)
  end
end)

-- ===== REPORT =====
local function report(player)
  local worked = {}
  for _, what in ipairs({ "SITTING IN THE SEAT", "W/S IN THE SEAT", "A/D IN THE SEAT", "TURRET MOVING",
    "CLICKING THE GUN", "FIRING" }) do
    table.insert(worked, what .. (T.seen[what] and " yes" or " NO"))
  end
  local lines = {
    "Turret report: " .. table.concat(worked, ", "),
    "Aim loop ran " .. T.ticks .. " ticks (about 20 a second is healthy), slowest tick "
      .. string.format("%.0f ms", T.slowestTick * 1000) .. ". Clicks " .. T.clicks .. ", shots " .. T.shots .. ".",
    "Last click: " .. T.lastClick,
    "mousedown event: " .. T.mousedown,
  }
  for _, line in ipairs(lines) do tell(line, player) end
end

-- mousedown: does the game send a click position? (needed for click-to-aim on the Stryker)
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
  elseif command == ":turret clear" then
    clear()
    tell("Turret test removed.", player)
  end
end)

print("[Turret] turret test loaded. Type :turret to build it.")
