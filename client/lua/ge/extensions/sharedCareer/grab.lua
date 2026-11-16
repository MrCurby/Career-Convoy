-- SharedCareer :: our own node grabber – move your own vehicles slowly, by hand
--
-- The game's node grabber is weak in the career (the engine limits its force; a mod can't change
-- that). This is our own: it pulls a few nodes around a grab point towards a target point, with
-- a limited force and a slow speed, so the vehicle keeps its physics (it turns when you pull a
-- corner, the wheels roll, one end can be lifted). Goal: moving vehicles that can't drive, e.g.
-- onto a tow truck, by hand.
--
--   Key (default F6, rebindable under Options → Controls → BeamMP, "SharedCareer: grab vehicle"):
--     1st press  grabs your vehicle under the mouse cursor (or in the middle of the view if the
--                cursor points at the sky); the vehicle closest to that line is taken, and the
--                nodes around the point on that line closest to its center are the grip
--     2nd press  lets go
--   While holding, the target point is in the middle of your view at the grab distance
--   ("gravity gun"): look around and the vehicle is pulled there. Mouse wheel = farther / closer
--   (we push the game's "Nodegrabber" input layer while holding and take its wheel action; see
--   adjustDistance). Fallback keys: Page Up / Page Down. Without a camera view direction the
--   mouse ray is used. The vehicle you sit in can't be grabbed (the camera would move with it);
--   on foot or from the free camera it works.
--
-- The force itself is computed in the vehicle (sharedCareerVeh.handGrabRay / handTarget /
-- handRelease in lua/vehicle/extensions/auto/sharedCareerVeh.lua). Here we only pick the
-- vehicle and send the ray and target points. The vehicle grabs the node closest to the ray
-- (you hold the vehicle where you point at it) and reports back: onGrip (grip position and
-- distance), onHandState (grip position and strain, 10 times per second), onProbe (preview).
--
-- What you see (debugDrawer lines, like the game's own markers):
--   holding   a rope from the grip to the target point and a small cross at both ends; the
--             color shows the strain: green = easy, yellow = working hard, red = at the limit
--   preview   on foot or in the free camera, pointing at one of your vehicles: a small cross
--             where F6 would grab
--   hint      the first grab of a session shows how it works
--
-- Only your own vehicles (incl. your own traffic): other players' vehicles are simulated on
-- their PCs, BeamMP would put them back immediately. Not the player on foot.
-- Server settings: client.allowGrab (on/off), client.grabSpeed (m/s the grip moves at most),
-- client.grabStrength (force limit in % of the vehicle's weight).

local M = {}

local U

local ACTION = "sharedCareerGrab"
local KEY = "f6"
local MAX_DISTANCE = 120   -- m, how far away a vehicle can be grabbed
local MIN_DISTANCE = 3     -- m, closest the mouse wheel brings a vehicle
local DISTANCE_STEP = 1.5  -- m per mouse wheel notch / key press
local SEND_EVERY = 1 / 30  -- s: how often the target point is sent to the vehicle

local PROBE_EVERY = 0.2    -- s: how often the preview asks the vehicle where it would grab
local PROBE_KEEP = 0.5     -- s: how long a preview answer is shown

local held = nil           -- {id, dist, dx, dy, dz, since, grip = {x, y, z}, strain, target}
local probe = nil          -- {id, x, y, z, age}
local sinceProbe = 0
local hintShown = false
local keyRegistered = false
local actionMapPushed = false

local function config()
	local core = U.ext("sharedCareer_core")
	return core and core.getConfig()
end

local function allowed()
	local c = config()
	return c ~= nil and c.allowGrab == true
end

local function numberSetting(key, default, lo, hi)
	local c = config()
	local v = c and tonumber(c[key])
	if not v or v <= 0 then return default end
	return math.max(lo, math.min(hi, v))
end

-- m/s the grip moves at most, and the force limit in % of the vehicle's weight
local function grabSpeed() return numberSetting("grabSpeed", 1, 0.2, 5) end
local function grabStrength() return numberSetting("grabStrength", 60, 10, 150) end

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

local function mouseRay()
	if type(rawget(_G, "cameraMouseRayCast")) ~= "function" then return nil end
	local ok, hit = pcall(cameraMouseRayCast, true)
	if ok and type(hit) == "table" and hit.pos then return hit end
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

local function setWheelLayer(on)
	if on == actionMapPushed then return end
	local push, pop = rawget(_G, "pushActionMap"), rawget(_G, "popActionMap")
	if type(push) ~= "function" or type(pop) ~= "function" then return end
	if on then pcall(push, "Nodegrabber") else pcall(pop, "Nodegrabber") end
	actionMapPushed = on
end

function M.release()
	if not held then return end
	sendToVehicle(held.id, "sharedCareerVeh.handRelease()")
	held = nil
	setWheelLayer(false)
	U.log("D", "grab", "vehicle released")
end

--- Moves the held vehicle farther away (positive) or closer (negative), in wheel notches.
function M.adjustDistance(notches)
	if not held then return false end
	local n = tonumber(notches) or 0
	held.dist = math.max(MIN_DISTANCE, math.min(MAX_DISTANCE, held.dist + n * DISTANCE_STEP))
	return true
end

-- While holding, the mouse wheel (the game's node grabber strength action) changes the distance.
local function wrapWheel()
	local gp = U.ext("core_nodegrabberGamepad")
	if not gp then return end
	U.replace(gp, "changeStrength", function(original)
		return function(value, filterType, ...)
			if held then
				M.adjustDistance(tonumber(value) or 0)
				return
			end
			return original(value, filterType, ...)
		end
	end)
end

-- Direction from the camera through the mouse cursor (or the view direction if the ray hits
-- nothing). Returns cam, dir (unit vector), or nil.
local function aimRay()
	local cam = cameraPos()
	if not cam then return nil end
	local hit = mouseRay()
	if hit then
		local h = vecOf(hit.pos)
		local dx, dy, dz = h.x - cam.x, h.y - cam.y, h.z - cam.z
		local len = math.sqrt(dx * dx + dy * dy + dz * dz)
		if len > 0.01 then return cam, {x = dx / len, y = dy / len, z = dz / len} end
	end
	if core_camera and type(core_camera.getForward) == "function" then
		local ok, f = pcall(core_camera.getForward)
		f = ok and vecOf(f)
		if f then
			local len = math.sqrt(f.x * f.x + f.y * f.y + f.z * f.z)
			if len > 0.01 then return cam, {x = f.x / len, y = f.y / len, z = f.z / len} end
		end
	end
	return nil
end
M.aimRay = aimRay

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

local function grab()
	if not allowed() then
		message("Grabbing vehicles is switched off on this server")
		return
	end
	local cam, dir = aimRay()
	local found = cam and vehicleOnRay(cam, dir)
	if not found or type(found.veh.queueLuaCommand) ~= "function" then
		message("Point at one of your vehicles to grab it")
		return
	end
	local veh, id = found.veh, found.id
	local model = veh.JBeam
	if model == nil and type(veh.getJBeamFilename) == "function" then model = veh:getJBeamFilename() end
	if model == "unicycle" then
		message("Players on foot can't be grabbed")
		return
	end
	if not isOwnVehicle(id) then
		message("You can only grab your own vehicles")
		return
	end
	local freeCam = core_camera and type(core_camera.getActiveGlobalCameraName) == "function"
		and core_camera.getActiveGlobalCameraName()
	if id == be:getPlayerVehicleID(0) and not freeCam then
		message("Get out (or use the free camera) to grab the vehicle you are in")
		return
	end
	-- the vehicle grabs the node closest to the aim line and reports it back (onGrip)
	held = {id = id, dist = found.t, dx = dir.x, dy = dir.y, dz = dir.z, since = SEND_EVERY, strain = 0}
	probe = nil
	sendToVehicle(id, string.format("sharedCareerVeh.handGrabRay(%.3f, %.3f, %.3f, %.4f, %.4f, %.4f, %d, %.2f, %.1f)",
		cam.x, cam.y, cam.z, dir.x, dir.y, dir.z, MAX_DISTANCE, grabSpeed(), grabStrength()))
	if not hintShown then
		hintShown = true
		U.toast("info", "Holding: look where it should go · Mouse wheel: distance · F6: let go", 6)
	end
	wrapWheel()
	setWheelLayer(true)
	U.log("I", "grab", string.format("grabbed vehicle %s at %.1f m (%s)", tostring(id), found.t,
		viewDir() and "follows the view" or "follows the mouse"))
end

function M.toggle()
	if held then M.release() else grab() end
end

-- One step: send the current target point to the vehicle (called every frame, sent ~30 times/s).
function M.step(dt)
	if not held then return end
	dt = tonumber(dt) or 0
	local veh = be:getObjectByID(held.id)
	if not veh or not allowed() then
		M.release()
		return
	end
	-- the view direction while holding ("gravity gun"), the mouse ray if there is none
	local cam, dir = cameraPos(), viewDir()
	if not dir then cam, dir = aimRay() end
	if not cam then return end
	held.dx, held.dy, held.dz = dir.x, dir.y, dir.z
	local tx, ty, tz = cam.x + dir.x * held.dist, cam.y + dir.y * held.dist, cam.z + dir.z * held.dist
	held.target = {x = tx, y = ty, z = tz}
	held.since = held.since + dt
	if held.since < SEND_EVERY then return end
	held.since = 0
	sendToVehicle(held.id, string.format("sharedCareerVeh.handTarget(%.3f, %.3f, %.3f, %.2f, %.1f)",
		tx, ty, tz, grabSpeed(), grabStrength()))
end

--== Replies from the vehicle ====================================================

function M.onGrip(id, t, x, y, z)
	if not held or held.id ~= id then return end
	held.dist = math.max(MIN_DISTANCE, math.min(MAX_DISTANCE, tonumber(t) or held.dist))
	held.grip = {x = x, y = y, z = z}
end

function M.onHandState(id, x, y, z, strain)
	if not held or held.id ~= id then return end
	held.grip = {x = x, y = y, z = z}
	held.strain = math.max(0, math.min(1, tonumber(strain) or 0))
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

local function canDraw()
	return type(rawget(_G, "debugDrawer")) ~= "nil" and type(rawget(_G, "ColorF")) == "function"
		and type(rawget(_G, "vec3")) == "function"
end

local function line(a, b, color)
	debugDrawer:drawLine(vec3(a.x, a.y, a.z), vec3(b.x, b.y, b.z), color)
end

local function cross(p, size, color)
	line({x = p.x - size, y = p.y, z = p.z}, {x = p.x + size, y = p.y, z = p.z}, color)
	line({x = p.x, y = p.y - size, z = p.z}, {x = p.x, y = p.y + size, z = p.z}, color)
	line({x = p.x, y = p.y, z = p.z - size}, {x = p.x, y = p.y, z = p.z + size}, color)
end

function M.draw()
	if not canDraw() then return end
	if held and held.grip and held.target then
		local r, g, b = M.strainColor(held.strain)
		local color = ColorF(r, g, b, 0.9)
		line(held.grip, held.target, color)
		cross(held.grip, 0.15, color)
		cross(held.target, 0.25, ColorF(1, 1, 1, 0.7))
	elseif probe then
		cross(probe, 0.2, ColorF(0.3, 0.8, 1, 0.9))
	end
end

-- on foot (or in the free camera) the preview shows where F6 would grab
local function previewWanted()
	if held or not allowed() then return false end
	local freeCam = core_camera and type(core_camera.getActiveGlobalCameraName) == "function"
		and core_camera.getActiveGlobalCameraName()
	if freeCam then return true end
	local walking = gameplay_walk and type(gameplay_walk.isWalking) == "function" and gameplay_walk.isWalking()
	return walking == true
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
	local cam, dir = aimRay()
	local found = cam and vehicleOnRay(cam, dir)
	if not found or not isOwnVehicle(found.id) then return end
	local model = found.veh.JBeam
	if model == "unicycle" or found.id == be:getPlayerVehicleID(0) then return end
	sendToVehicle(found.id, string.format("sharedCareerVeh.handProbe(%.3f, %.3f, %.3f, %.4f, %.4f, %.4f, %d)",
		cam.x, cam.y, cam.z, dir.x, dir.y, dir.z, MAX_DISTANCE))
end

function M.isHolding()
	return held ~= nil
end

--== Key =======================================================================

local function registerKey()
	if keyRegistered then return end
	keyRegistered = true
	local keys = rawget(_G, "MPKeybindsGE")
	if type(keys) ~= "table" or type(keys.addAction) ~= "function" then
		U.log("W", "grab", "MPKeybindsGE.addAction not available – no grab key (BeamMP too old?)")
		return
	end
	local ok, err = pcall(keys.addAction, ACTION, {
		title = "SharedCareer: grab vehicle",
		desc = "Grabs your vehicle under the mouse cursor and moves it slowly; press again to let go",
		default = KEY,
		onDown = function() M.toggle() end,
	})
	if not ok then U.log("E", "grab", "could not register the grab key: " .. tostring(err)) end
	for _, k in ipairs({
		{ACTION .. "Farther", "SharedCareer: grabbed vehicle farther", "pageup", 1},
		{ACTION .. "Closer", "SharedCareer: grabbed vehicle closer", "pagedown", -1},
	}) do
		pcall(keys.addAction, k[1], {
			title = k[2], desc = "Moves the grabbed vehicle away from you or towards you",
			default = k[3], onDown = function() M.adjustDistance(k[4]) end,
		})
	end
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
	pcall(M.draw)
end

function M.onCareerActive(active)
	if active and U.isMP() then registerKey() end
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
