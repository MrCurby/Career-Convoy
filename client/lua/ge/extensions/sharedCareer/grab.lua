-- SharedCareer :: our own node grabber as a rope with a winch – move vehicles slowly, by hand
--
-- The game's node grabber is weak in the career (the engine limits its force; a mod can't change
-- that). This is our own, built for moving vehicles that can't drive, e.g. onto a tow truck.
-- It is used only through the phone app "Tow" (phone.lua), as a remote control:
--
--   attach    where you look (middle of the view), or to one of your vehicles nearby (the point
--             of that vehicle closest to you)
--   anchor    buttons forward/back/left/right (as seen from the camera) and up/down, hold to move;
--             "to my view" puts it in the middle of the view; fine mode = quarter speed
--   winch     haul in (pulls the vehicle slowly to the anchor) / stop (the vehicle hangs on the
--             rope) / pay out
--   strength  30/60/100/150 % of the vehicle's weight
--   remove
-- The blue preview of where a rope would attach only shows while the Tow app is open.
--
-- The rope only pulls when it is taut, never pushes; moving the anchor pays out rope, so the
-- vehicle only moves when the winch runs.
--
-- The force itself is computed in the vehicle (sharedCareerVeh.handGrabRay / handGrabNearest /
-- handRope / handRelease in lua/vehicle/extensions/auto/sharedCareerVeh.lua). Here we only pick
-- the vehicle and send the view ray and the anchor. The vehicle grabs the node closest to the ray
-- (the rope goes where you look at the vehicle) and reports back: onGrip (grip position and
-- distance), onHandState (grip position and strain, 10 times per second), onProbe (preview).
--
-- What you see (debugDrawer lines, like the game's own markers):
--   rope      a line from the grip to the anchor: grey = slack; when taut, the color shows the
--             strain: green = easy, yellow = working hard, red = at the force limit. A slack rope
--             sags (a curve as long as the rope); it straightens smoothly when it is pulled taut
--   grip      a small ball on the vehicle, in the rope's color
--   anchor    a pin (post with a ball on top): white = resting, cyan = being moved, orange =
--             hauling in (the ball pulses), purple = paying out. While the Tow app is open, a
--             sign above it shows "Anchor · <distance to the grip>"
--   preview   while the Tow app is open, looking at one of your vehicles: a see-through ball
--             where the rope would attach
-- Balls, posts and the sign use debugDrawer:drawSphere/drawCylinder/drawTextAdvanced; if one of
-- them is missing or fails, that shape is drawn as a cross (or left out, for the sign).
--
-- Only your own vehicles (incl. your own traffic): other players' vehicles are simulated on
-- their PCs, BeamMP would put them back immediately. Not the player on foot.
-- Server settings: client.allowGrab (on/off), client.grabSpeed (m/s the winch hauls in at most),
-- client.grabStrength (the highest force limit a player may pick, in % of the vehicle's weight).
-- Each player picks the strength in the Tow app (30/60/100/150 %, capped at client.grabStrength).

local M = {}

local U

local MAX_DISTANCE = 120   -- m, how far away a vehicle can be grabbed
local MIN_DISTANCE = 3     -- m, closest "to my view" puts the anchor
local SEND_EVERY = 1 / 30  -- s: how often the target point is sent to the vehicle

local PROBE_EVERY = 0.2    -- s: how often the preview asks the vehicle where it would grab
local PROBE_KEEP = 0.5     -- s: how long a preview answer is shown

local NUDGE_SPEED = 1      -- m/s the anchor moves while a remote button is held
local FINE = 0.25          -- fine mode: speed factor for the winch and the anchor
local NEARBY_RANGE = 60    -- m: vehicles listed in the Tow app
local APP_PUSH_EVERY = 0.2 -- s: how often the Tow app gets the state while it's open

local held = nil           -- {id, since, grip = {x, y, z}, target (= anchor), strain, slack,
                           --  winch (1 haul in, 0 stop, -1 pay out), placed, nudge, length}
local fine = false         -- fine mode (Tow app)
local STRENGTHS = {30, 60, 100, 150} -- strength choices in the Tow app (% of the vehicle's weight)
local strengthPick = 60    -- the player's pick in the Tow app
local appOpen = false      -- the Tow app is open on the phone
local sinceAppPush = 0
local probe = nil          -- {id, x, y, z, age}
local sinceProbe = 0
local drawErrorLogged = false

local function allowed()
	local c = U.config()
	return c ~= nil and c.allowGrab == true
end

local function numberSetting(key, default, lo, hi)
	local c = U.config()
	local v = c and tonumber(c[key])
	if not v or v <= 0 then return default end
	return math.max(lo, math.min(hi, v))
end

-- m/s the grip moves at most, and the force limit in % of the vehicle's weight
local function grabSpeed() return numberSetting("grabSpeed", 1, 0.2, 5) end
local function maxStrength() return numberSetting("grabStrength", 150, 10, 150) end
local function grabStrength() return math.min(strengthPick, maxStrength()) end

local function sendToVehicle(id, cmd)
	local veh = be:getObjectByID(id)
	if veh and type(veh.queueLuaCommand) == "function" then
		veh:queueLuaCommand("if sharedCareerVeh then " .. cmd .. " end")
	end
end

local function vecOf(v)
	if v == nil then return nil end
	return {x = tonumber(v.x) or 0, y = tonumber(v.y) or 0, z = tonumber(v.z) or 0}
end

local function cameraPos()
	if core_camera and type(core_camera.getPosition) == "function" then
		local ok, p = pcall(core_camera.getPosition)
		if ok and p then return vecOf(p) end
	end
	return nil
end

-- true if this game vehicle is ours (not another player's)
local function isOwnVehicle(gameId)
	local mp = rawget(_G, "MPVehicleGE")
	if type(mp) ~= "table" then return true end
	if type(mp.isOwn) == "function" and mp.isOwn(gameId) then return true end
	if type(mp.getVehicles) == "function" then
		for _, entry in pairs(mp.getVehicles() or {}) do
			if type(entry) == "table" and entry.gameVehicleID == gameId then
				return entry.isLocal == true
			end
		end
	end
	return true -- not registered with BeamMP yet: a fresh vehicle of ours
end

local function message(text)
	U.toast("info", text, 3)
end

--== Grabbing ==================================================================

function M.release()
	if not held then return end
	sendToVehicle(held.id, "sharedCareerVeh.handRelease()")
	held = nil
	U.log("D", "grab", "vehicle released")
end

--- Winch: 1 haul in, 0 stop, -1 pay out.
function M.setWinch(mode)
	if not held then return false end
	mode = tonumber(mode) or 0
	held.winch = mode > 0 and 1 or (mode < 0 and -1 or 0)
	held.since = SEND_EVERY
	return true
end

-- Camera view direction (unit vector) or nil.
local function viewDir()
	if not (core_camera and type(core_camera.getForward) == "function") then return nil end
	local ok, f = pcall(core_camera.getForward)
	f = ok and vecOf(f)
	if not f then return nil end
	local len = math.sqrt(f.x * f.x + f.y * f.y + f.z * f.z)
	if len < 0.01 then return nil end
	return {x = f.x / len, y = f.y / len, z = f.z / len}
end

-- The vehicle closest to the aim line: {veh, id, t (distance along the line), miss (distance
-- from the line)}, or nil. The ray cast itself doesn't report vehicles in every game version,
-- so we search the vehicles ourselves.
local function vehicleOnRay(cam, dir)
	local best = nil
	local count = type(be.getObjectCount) == "function" and be:getObjectCount() or 0
	for i = 0, count - 1 do
		local veh = be:getObject(i)
		if veh and type(veh.getPosition) == "function" and type(veh.getID) == "function" then
			local p = vecOf(veh:getPosition())
			local rx, ry, rz = p.x - cam.x, p.y - cam.y, p.z - cam.z
			local t = rx * dir.x + ry * dir.y + rz * dir.z
			if t > 0.5 and t <= MAX_DISTANCE then
				local mx, my, mz = rx - dir.x * t, ry - dir.y * t, rz - dir.z * t
				local miss = math.sqrt(mx * mx + my * my + mz * mz)
				-- a vehicle counts as "pointed at" within a few meters of its center
				if miss <= math.max(3, 0.06 * t) and (not best or miss < best.miss) then
					best = {veh = veh, id = veh:getID(), t = t, miss = miss}
				end
			end
		end
	end
	return best
end
M.vehicleOnRay = vehicleOnRay

-- Can a rope go on this vehicle? Returns true, or false and a message.
local function canRope(veh, id)
	if not veh or type(veh.queueLuaCommand) ~= "function" then return false, "Look at one of your vehicles to attach the rope" end
	local model = veh.JBeam
	if model == nil and type(veh.getJBeamFilename) == "function" then model = veh:getJBeamFilename() end
	if model == "unicycle" then return false, "Players on foot can't be grabbed" end
	if not isOwnVehicle(id) then return false, "You can only grab your own vehicles" end
	local freeCam = core_camera and type(core_camera.getActiveGlobalCameraName) == "function"
		and core_camera.getActiveGlobalCameraName()
	if id == be:getPlayerVehicleID(0) and not freeCam then
		return false, "Get out (or use the free camera) to grab the vehicle you are in"
	end
	return true
end

local function startRope(id, dist, target, cmd)
	held = {id = id, since = SEND_EVERY, strain = 0, slack = true, winch = 0, placed = false, target = target}
	probe = nil
	sendToVehicle(id, cmd)
	U.log("I", "grab", string.format("rope attached to vehicle %s at %.1f m", tostring(id), dist))
end

-- Attach where you look (the middle of the view; the cursor is on the phone).
local function attachAtView()
	if not allowed() then
		message("Grabbing vehicles is switched off on this server")
		return false
	end
	local cam, dir = cameraPos(), viewDir()
	local found = cam and dir and vehicleOnRay(cam, dir)
	local ok, err = canRope(found and found.veh, found and found.id)
	if not ok then
		message(err)
		return false
	end
	-- the vehicle grabs the node closest to the aim line and reports it back (onGrip)
	startRope(found.id, found.t, {x = cam.x + dir.x * found.t, y = cam.y + dir.y * found.t, z = cam.z + dir.z * found.t},
		string.format("sharedCareerVeh.handGrabRay(%.3f, %.3f, %.3f, %.4f, %.4f, %.4f, %d, %.2f, %.1f)",
			cam.x, cam.y, cam.z, dir.x, dir.y, dir.z, MAX_DISTANCE, grabSpeed(), grabStrength()))
	return true
end

-- One step (every frame): while a remote button is held, the anchor moves; the rope state goes
-- to the vehicle about 30 times per second.
function M.step(dt)
	if not held then return end
	dt = tonumber(dt) or 0
	local veh = be:getObjectByID(held.id)
	if not veh or not allowed() then
		M.release()
		return
	end
	if held.nudge and held.target then
		-- remote control: forward/back and left/right as seen from the camera, up/down
		local f = viewDir() or {x = 0, y = 1, z = 0}
		local len = math.sqrt(f.x * f.x + f.y * f.y)
		local fx, fy = 0, 1
		if len > 0.01 then fx, fy = f.x / len, f.y / len end
		local rx, ry = fy, -fx
		local n, step = held.nudge, NUDGE_SPEED * (fine and FINE or 1) * dt
		held.target = {
			x = held.target.x + (fx * n.f + rx * n.r) * step,
			y = held.target.y + (fy * n.f + ry * n.r) * step,
			z = held.target.z + n.u * step,
		}
	end
	held.since = held.since + dt
	if held.since < SEND_EVERY or not held.target then return end
	held.since = 0
	local t = held.target
	local paying = held.nudge ~= nil or held.payOutOnce
	held.payOutOnce = nil
	sendToVehicle(held.id, string.format("sharedCareerVeh.handRope(%.3f, %.3f, %.3f, %d, %d, %.2f, %.1f)",
		t.x, t.y, t.z, held.winch, paying and 1 or 0, grabSpeed() * (fine and FINE or 1), grabStrength()))
end

--== Replies from the vehicle ====================================================

function M.onGrip(id, t, x, y, z)
	if not held or held.id ~= id then return end
	held.grip = {x = x, y = y, z = z}
	-- the anchor starts at the grip (rope slack) until it is moved
	if not held.placed then held.target = {x = x, y = y, z = z} end
	U.log("D", "grab", string.format("vehicle reported its grip at %.1f m", tonumber(t) or 0))
end

function M.onHandState(id, x, y, z, strain, slack, length)
	if not held or held.id ~= id then return end
	held.grip = {x = x, y = y, z = z}
	held.strain = math.max(0, math.min(1, tonumber(strain) or 0))
	held.slack = slack == 1 or slack == true
	held.length = tonumber(length)
end

function M.onProbe(id, x, y, z)
	probe = {id = id, x = x, y = y, z = z, age = 0}
end

--== Drawing =====================================================================

-- green (easy) -> yellow -> red (at the limit)
function M.strainColor(strain)
	local s = math.max(0, math.min(1, tonumber(strain) or 0))
	if s < 0.6 then
		local f = s / 0.6
		return 0.2 + 0.8 * f, 0.9 - 0.05 * f, 0.3 - 0.1 * f
	end
	local f = (s - 0.6) / 0.4
	return 1, 0.85 - 0.6 * f, 0.2
end

-- debugDrawer, ColorF and vec3 are engine/library globals: they may be provided lazily (not
-- visible to rawget) and ColorF/vec3 are constructors of type cdata/table, not "function" – so we
-- only check that they exist (0.10.1 checked rawget + "function" and never drew anything).
local canDrawCached = false -- only a positive result is kept; a negative one is checked again
local drawWarned = false
local function canDraw()
	if canDrawCached then return true end
	local ok, dd, cf, v3 = pcall(function() return debugDrawer, ColorF, vec3 end)
	canDrawCached = ok and dd ~= nil and cf ~= nil and v3 ~= nil
	if canDrawCached then
		U.log("I", "grab", "drawing available (debugDrawer)")
	elseif not drawWarned then
		drawWarned = true
		U.log("W", "grab", "drawing not available: debugDrawer " .. tostring(dd) .. ", ColorF " .. tostring(cf)
			.. ", vec3 " .. tostring(v3))
	end
	return canDrawCached
end

local function line(a, b, color)
	debugDrawer:drawLine(vec3(a.x, a.y, a.z), vec3(b.x, b.y, b.z), color)
end

-- how deep a slack rope sags in the middle: a parabola over the horizontal span d whose length is
-- about the rope length L (L ~ d + 8 s^2 / 3d), at most half the rope (hanging straight down)
local SAG_SEGMENTS = 12
local SAG_RATE = 8         -- 1/s: how fast the drawn sag follows the rope
local SAG_MAX = 6          -- m
function M.sagDepth(span, horizontal, length)
	span, horizontal, length = tonumber(span) or 0, tonumber(horizontal) or 0, tonumber(length) or 0
	if span < 0.05 or length <= span then return 0 end
	local s = math.sqrt(3 * span * (length - span) / 8)
	s = math.min(s, length / 2, SAG_MAX)
	-- a steep rope hangs along itself rather than below it
	return s * math.max(0, math.min(1, horizontal / span))
end

local function rope(a, b, sag, color)
	if sag < 0.02 then
		line(a, b, color)
		return
	end
	local prev = a
	for i = 1, SAG_SEGMENTS do
		local t = i / SAG_SEGMENTS
		local p = {x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t,
			z = a.z + (b.z - a.z) * t - 4 * sag * t * (1 - t)}
		line(prev, p, color)
		prev = p
	end
end

local function cross(p, size, color)
	line({x = p.x - size, y = p.y, z = p.z}, {x = p.x + size, y = p.y, z = p.z}, color)
	line({x = p.x, y = p.y - size, z = p.z}, {x = p.x, y = p.y + size, z = p.z}, color)
	line({x = p.x, y = p.y, z = p.z - size}, {x = p.x, y = p.y, z = p.z + size}, color)
end

-- shapes beyond lines: tried once each; a failure is logged once and that shape falls back
local shapeBroken = {}
local function tryShape(name, fn)
	if shapeBroken[name] then return false end
	local ok, err = pcall(fn)
	if not ok then
		shapeBroken[name] = true
		U.log("W", "grab", "debugDrawer:" .. name .. " not available, using lines instead: " .. tostring(err))
	end
	return ok
end

--- Forget which shapes failed (tests; the game keeps the result for the session).
function M.resetShapes() shapeBroken = {} end

local function ball(p, radius, color)
	local ok = tryShape("drawSphere", function()
		debugDrawer:drawSphere(vec3(p.x, p.y, p.z), radius, color)
	end)
	if not ok then cross(p, radius * 1.6, color) end
end

local PIN_HEIGHT = 0.6     -- m: the anchor's post, from the anchor point up
local PIN_BALL = 0.12      -- m: radius of the ball on top
local function pin(p, color, pulse)
	local top = {x = p.x, y = p.y, z = p.z + PIN_HEIGHT}
	local ok = tryShape("drawCylinder", function()
		debugDrawer:drawCylinder(vec3(p.x, p.y, p.z), vec3(top.x, top.y, top.z), 0.02, color)
	end)
	if not ok then line(p, top, color) end
	ball(top, PIN_BALL * (pulse or 1), color)
	ball(p, 0.05, color)
end

local function sign(p, text)
	tryShape("drawTextAdvanced", function()
		local str = String and String(text) or text
		debugDrawer:drawTextAdvanced(vec3(p.x, p.y, p.z), str, ColorF(1, 1, 1, 1), true, false,
			ColorI(20, 20, 24, 190))
	end)
end

local clock = 0            -- s, for the pulsing ball while the winch hauls in

function M.draw(dt)
	clock = clock + math.max(0, tonumber(dt) or 0)
	if not (held and held.grip and held.target) and not probe then return end
	if not canDraw() then return end
	if held and held.grip and held.target then
		local color
		if held.slack then
			color = ColorF(0.7, 0.7, 0.7, 0.6)
		else
			local r, g, b = M.strainColor(held.strain)
			color = ColorF(r, g, b, 0.9)
		end
		local a, b = held.grip, held.target
		local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
		local span = math.sqrt(dx * dx + dy * dy + dz * dz)
		local want = held.slack and M.sagDepth(span, math.sqrt(dx * dx + dy * dy), held.length) or 0
		local k = 1 - math.exp(-SAG_RATE * math.max(0, tonumber(dt) or 0))
		held.sag = (held.sag or want) + (want - (held.sag or want)) * k
		rope(a, b, held.sag, color)
		ball(held.grip, 0.09, color)
		local anchorColor = held.nudge and ColorF(0.3, 0.9, 1, 0.9)
			or held.winch == 1 and ColorF(1, 0.55, 0.1, 0.9)
			or held.winch == -1 and ColorF(0.75, 0.55, 1, 0.9) or ColorF(1, 1, 1, 0.8)
		local pulse = held.winch == 1 and not held.nudge
			and 1 + 0.25 * math.sin(clock * 2 * math.pi * 1.5) or 1
		pin(b, anchorColor, pulse)
		if appOpen then
			sign({x = b.x, y = b.y, z = b.z + PIN_HEIGHT + 0.35}, string.format("Anchor \194\183 %.1f m", span))
		end
	elseif probe then
		ball(probe, 0.12, ColorF(0.3, 0.8, 1, 0.45))
	end
end

-- the preview (where a rope would attach) only shows while the Tow app is open
local function previewWanted()
	return appOpen and not held and allowed()
end

function M.updatePreview(dt)
	if probe then
		probe.age = probe.age + dt
		if probe.age > PROBE_KEEP then probe = nil end
	end
	if not previewWanted() then
		probe = nil
		return
	end
	sinceProbe = sinceProbe + dt
	if sinceProbe < PROBE_EVERY then return end
	sinceProbe = 0
	-- the Tow app attaches where you look (the cursor is on the phone)
	local cam, dir = cameraPos(), viewDir()
	local found = cam and dir and vehicleOnRay(cam, dir)
	if not found or not canRope(found.veh, found.id) then return end
	sendToVehicle(found.id, string.format("sharedCareerVeh.handProbe(%.3f, %.3f, %.3f, %.4f, %.4f, %.4f, %d)",
		cam.x, cam.y, cam.z, dir.x, dir.y, dir.z, MAX_DISTANCE))
end

--== Tow app (phone) =============================================================

local function vehicleName(veh)
	local model = veh.JBeam
	if model == nil and type(veh.getJBeamFilename) == "function" then model = veh:getJBeamFilename() end
	model = tostring(model or "vehicle")
	if core_vehicles and type(core_vehicles.getModel) == "function" then
		local ok, info = pcall(core_vehicles.getModel, model)
		local m = ok and type(info) == "table" and info.model
		if type(m) == "table" and m.Name then
			return m.Brand and (tostring(m.Brand) .. " " .. tostring(m.Name)) or tostring(m.Name)
		end
	end
	return (model:gsub("^%l", string.upper))
end

-- own vehicles near the camera that can take a rope, nearest first (at most 6)
local function nearbyVehicles()
	local cam = cameraPos()
	if not cam then return {} end
	local list = {}
	local count = type(be.getObjectCount) == "function" and be:getObjectCount() or 0
	for i = 0, count - 1 do
		local veh = be:getObject(i)
		if veh and type(veh.getID) == "function" and type(veh.getPosition) == "function" then
			local id = veh:getID()
			if canRope(veh, id) then
				local p = vecOf(veh:getPosition())
				local dx, dy, dz = p.x - cam.x, p.y - cam.y, p.z - cam.z
				local d = math.sqrt(dx * dx + dy * dy + dz * dz)
				if d <= NEARBY_RANGE then table.insert(list, {id = id, name = vehicleName(veh), distance = math.floor(d + 0.5)}) end
			end
		end
	end
	table.sort(list, function(a, b) return a.distance < b.distance end)
	while #list > 6 do table.remove(list) end
	return list
end

--- State for the Tow app.
function M.appState()
	local max = maxStrength()
	local choices = {}
	for _, v in ipairs(STRENGTHS) do
		if v <= max then table.insert(choices, v) end
	end
	if #choices == 0 or choices[#choices] < max then table.insert(choices, math.floor(max + 0.5)) end
	local state = {allowed = allowed(), attached = held ~= nil, fine = fine,
		strength = grabStrength(), maxStrength = max, strengths = choices}
	if held then
		local veh = be:getObjectByID(held.id)
		state.vehicle = veh and vehicleName(veh) or "?"
		state.winch = held.winch
		state.moving = held.nudge ~= nil
		state.strain = held.strain or 0
		state.slack = held.slack ~= false
		state.length = held.length
		if held.grip and held.target then
			local dx, dy, dz = held.target.x - held.grip.x, held.target.y - held.grip.y, held.target.z - held.grip.z
			state.distance = math.sqrt(dx * dx + dy * dy + dz * dz)
		end
	else
		state.nearby = nearbyVehicles()
	end
	return state
end

local function pushApp()
	if guihooks and type(guihooks.trigger) == "function" then guihooks.trigger("SharedCareerTow", M.appState()) end
end

function M.setAppOpen(on)
	appOpen = on == true
	if not appOpen then
		probe = nil
		if held then held.nudge = nil end
	end
	pushApp()
end

-- buttons of the Tow app
function M.uiAttachView() local ok = attachAtView(); pushApp(); return ok end
function M.uiAttachVehicle(id)
	if not allowed() then return false end
	id = tonumber(id)
	local veh = id and be:getObjectByID(id)
	local ok, err = canRope(veh, id)
	local cam = cameraPos()
	if not ok or not cam then
		message(err or "Vehicle not found")
		return false
	end
	local p = vecOf(veh:getPosition())
	local dx, dy, dz = p.x - cam.x, p.y - cam.y, p.z - cam.z
	startRope(id, math.sqrt(dx * dx + dy * dy + dz * dz), p,
		string.format("sharedCareerVeh.handGrabNearest(%.3f, %.3f, %.3f, %.2f, %.1f)",
			cam.x, cam.y, cam.z, grabSpeed(), grabStrength()))
	pushApp()
	return true
end
function M.uiRelease() M.release(); pushApp() end
function M.uiWinch(mode) M.setWinch(mode); pushApp() end
function M.uiFine(on) fine = on == true; pushApp() end
--- Pull strength in % of the vehicle's weight (capped at the server's client.grabStrength).
function M.uiStrength(v)
	v = tonumber(v)
	if not v then return end
	strengthPick = math.max(10, math.min(150, v))
	if held then held.since = SEND_EVERY end
	pushApp()
end
--- Remote control: move the anchor while a button is held (f = forward, r = right, u = up; -1..1).
function M.uiNudge(f, r, u)
	if not held then return end
	held.nudge = {f = tonumber(f) or 0, r = tonumber(r) or 0, u = tonumber(u) or 0}
	held.placed = true
	held.since = SEND_EVERY
	pushApp()
end
function M.uiNudgeStop()
	if not held then return end
	held.nudge = nil
	held.since = SEND_EVERY
	pushApp()
end
--- Put the anchor in the middle of the view, at its current distance from you.
function M.uiAnchorToView()
	if not held or not held.target then return end
	local cam, dir = cameraPos(), viewDir()
	if not cam or not dir then return end
	local dx, dy, dz = held.target.x - cam.x, held.target.y - cam.y, held.target.z - cam.z
	local dist = math.max(MIN_DISTANCE, math.min(MAX_DISTANCE, math.sqrt(dx * dx + dy * dy + dz * dz)))
	held.target = {x = cam.x + dir.x * dist, y = cam.y + dir.y * dist, z = cam.z + dir.z * dist}
	held.placed = true
	held.payOutOnce = true
	held.since = SEND_EVERY
	pushApp()
end

-- the Tow app on the phone
local function registerPhoneApp()
	local phone = U.ext("sharedCareer_phone")
	if not phone or type(phone.registerApp) ~= "function" then return end
	if allowed() then
		phone.registerApp({id = "tow", title = "Tow", icon = "tow", color = "#e8730c", order = 10,
			onOpen = function() M.setAppOpen(true) end, onClose = function() M.setAppOpen(false) end})
	else
		phone.unregisterApp("tow")
		M.setAppOpen(false)
	end
end

function M.onConfigChanged()
	registerPhoneApp()
end

function M.isHolding()
	return held ~= nil
end

--== Hooks =====================================================================

function M.onUpdate(dtReal)
	if held then
		local ok, err = pcall(M.step, dtReal)
		if not ok then
			U.log("E", "grab", "grab failed: " .. tostring(err))
			M.release()
		end
	elseif U.isMP() then
		pcall(M.updatePreview, tonumber(dtReal) or 0)
	end
	if appOpen then
		sinceAppPush = sinceAppPush + (tonumber(dtReal) or 0)
		if sinceAppPush >= APP_PUSH_EVERY then
			sinceAppPush = 0
			pcall(pushApp)
		end
	end
	local ok, err = pcall(M.draw, tonumber(dtReal) or 0)
	if not ok and not drawErrorLogged then
		drawErrorLogged = true
		U.log("E", "grab", "drawing failed: " .. tostring(err))
	end
end

function M.onCareerActive(active)
	if active and U.isMP() then
		registerPhoneApp()
	end
end

function M.onVehicleDestroyed(id)
	if held and held.id == id then M.release() end
end

function M.onBeamMPServerLeave()
	M.release()
	probe = nil
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
