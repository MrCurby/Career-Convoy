-- SharedCareer :: "telekinesis" grabber – move your own vehicles with the mouse
--
-- The game's node grabber is weak in the career (the engine limits its force; a mod can't change
-- that). This is our own grabber that moves the WHOLE vehicle instead of a single node, so it
-- doesn't bend anything and isn't limited by vehicle weight.
--
--   Key (default F6, rebindable under Options → Controls → BeamMP, "SharedCareer: grab vehicle"):
--     1st press  grabs your vehicle under the mouse cursor (or in the middle of the view)
--     2nd press  lets go – the vehicle keeps its speed, so you can throw it
--   While grabbed, the vehicle is pulled to the point on the line from the camera through the
--   mouse cursor, at the distance where you grabbed it.
--
-- How: like the game's own "fling" (core/funstuff.lua), via
-- veh:applyClusterVelocityScaleAdd(refNode, scale, x, y, z): new velocity = old * scale + add,
-- for all nodes of the vehicle at once. Every frame we blend the vehicle's velocity towards
-- the speed that brings the grabbed point to the target.
--
-- Only your own vehicles (incl. your own traffic): other players' vehicles are simulated on
-- their PCs, BeamMP would put them back immediately. Not the player on foot.
-- Server settings: client.allowGrab (on/off), client.grabSpeed (max pull speed in m/s).

local M = {}

local U

local ACTION = "sharedCareerGrab"
local KEY = "f6"
local MAX_DISTANCE = 120   -- m, how far away a vehicle can be grabbed
local GAIN = 4             -- 1/s: target speed = distance to target * GAIN
local BLEND = 10           -- 1/s: how fast the vehicle's speed follows the target speed

local held = nil           -- {id, dist, ox, oy, oz, dx, dy, dz}
local keyRegistered = false

local function config()
	local core = U.ext("sharedCareer_core")
	return core and core.getConfig()
end

local function allowed()
	local c = config()
	return c ~= nil and c.allowGrab == true
end

local function maxSpeed()
	local c = config()
	local v = c and tonumber(c.grabSpeed)
	if not v or v <= 0 then return 30 end
	return math.max(5, math.min(80, v))
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

function M.release()
	if not held then return end
	held = nil
	U.log("D", "grab", "vehicle released")
end

local function grab()
	if not allowed() then
		message("Grabbing vehicles is switched off on this server")
		return
	end
	local cam = cameraPos()
	local hit = mouseRay()
	local obj = hit and hit.object
	if not cam or not obj or type(obj.getID) ~= "function" then
		message("Point at one of your vehicles to grab it")
		return
	end
	local id = obj:getID()
	local veh = be:getObjectByID(id)
	if not veh or type(veh.applyClusterVelocityScaleAdd) ~= "function" then
		message("Point at one of your vehicles to grab it")
		return
	end
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
	local p, h = vecOf(veh:getPosition()), vecOf(hit.pos)
	local dx, dy, dz = h.x - cam.x, h.y - cam.y, h.z - cam.z
	local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
	if dist > MAX_DISTANCE or dist < 0.5 then
		message("Too far away to grab")
		return
	end
	held = {id = id, dist = dist, ox = h.x - p.x, oy = h.y - p.y, oz = h.z - p.z,
		dx = dx / dist, dy = dy / dist, dz = dz / dist}
	U.log("D", "grab", "grabbed vehicle " .. tostring(id) .. string.format(" at %.1f m", dist))
end

function M.toggle()
	if held then M.release() else grab() end
end

-- One step of pulling the held vehicle (called every frame).
function M.step(dt)
	if not held then return end
	dt = tonumber(dt) or 0
	if dt <= 0 then return end
	local veh = be:getObjectByID(held.id)
	if not veh or not allowed() then
		M.release()
		return
	end
	local cam = cameraPos()
	if not cam then return end
	-- direction from the camera through the mouse cursor; keep the last one if the ray hits nothing
	local hit = mouseRay()
	if hit then
		local h = vecOf(hit.pos)
		local dx, dy, dz = h.x - cam.x, h.y - cam.y, h.z - cam.z
		local len = math.sqrt(dx * dx + dy * dy + dz * dz)
		if len > 0.01 then held.dx, held.dy, held.dz = dx / len, dy / len, dz / len end
	end
	local p = vecOf(veh:getPosition())
	local tx, ty, tz = cam.x + held.dx * held.dist, cam.y + held.dy * held.dist, cam.z + held.dz * held.dist
	local ex, ey, ez = tx - (p.x + held.ox), ty - (p.y + held.oy), tz - (p.z + held.oz)
	local vx, vy, vz = ex * GAIN, ey * GAIN, ez * GAIN
	local speed = math.sqrt(vx * vx + vy * vy + vz * vz)
	local limit = maxSpeed()
	if speed > limit then
		local f = limit / speed
		vx, vy, vz = vx * f, vy * f, vz * f
	end
	-- new velocity = old * (1 - k) + target * k
	local k = math.min(1, dt * BLEND)
	veh:applyClusterVelocityScaleAdd(veh:getRefNodeId(), 1 - k, vx * k, vy * k, vz * k)
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
		desc = "Grabs your vehicle under the mouse cursor; press again to let go (or throw)",
		default = KEY,
		onDown = function() M.toggle() end,
	})
	if not ok then U.log("E", "grab", "could not register the grab key: " .. tostring(err)) end
end

--== Hooks =====================================================================

function M.onUpdate(dtReal)
	if not held then return end
	local ok, err = pcall(M.step, dtReal)
	if not ok then
		U.log("E", "grab", "grab failed: " .. tostring(err))
		M.release()
	end
end

function M.onCareerActive(active)
	if active and U.isMP() then registerKey() end
end

function M.onVehicleDestroyed(id)
	if held and held.id == id then M.release() end
end

function M.onBeamMPServerLeave()
	M.release()
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
