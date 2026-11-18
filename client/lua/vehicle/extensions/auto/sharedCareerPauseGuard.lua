-- SharedCareer :: keeps other players' vehicles in one piece while the game is paused
--
-- When the game pauses (the career pauses for its menus, the computer, the big map), BeamMP sets
-- the game speed of every vehicle to 0 (positionGE -> positionVE.setGameSpeed(0)). For another
-- player's vehicle positionVE divides by that speed for every position packet
-- (1 / simSpeedReal): the predicted velocity becomes infinite, and the copy's physics blows up
-- ("Instability detected", NaN) and takes the vehicles next to it along.
--
-- So positionVE never gets a speed of 0 (or an invalid one): while paused it keeps the last real
-- speed, and positionVE.updateGFX / onPhysicsStep are skipped (also on frames without time).
-- Our own vehicles still report standing still while paused: positionVE.getVehicleRotation runs
-- with BeamMP's speed of 0, which it only multiplies with. When the pause starts and ends,
-- positionVE's prediction starts fresh (positionVE.onReset). Nothing else of BeamMP is changed.
--
-- positionVE is BeamMP's vehicle extension and may load after this one, so the guard is put in
-- place on the first frame that finds it (and again if BeamMP loads it anew).

local M = {}

local guarded = nil   -- the positionVE table the guard is in
local originals = {}  -- BeamMP's own functions: setGameSpeed, updateGFX, onPhysicsStep, getVehicleRotation
local paused = false
local lastSpeed = 1   -- the last real game speed

local function positive(n)
	return type(n) == "number" and n == n and n > 0 and n < math.huge
end

local function setGameSpeed(speed)
	local stopped = not positive(speed)
	if stopped ~= paused and type(guarded.onReset) == "function" then guarded.onReset() end
	paused = stopped
	if not stopped then lastSpeed = speed end
	originals.setGameSpeed(lastSpeed)
end

-- updateGFX(dt) / onPhysicsStep(dt): nothing to do while paused or on a frame without time
local function skipWhilePaused(original)
	return function(dt, ...)
		if paused or not positive(dt) then return end
		return original(dt, ...)
	end
end

-- own vehicle: while paused it reports standing still, as BeamMP intends
local function getVehicleRotation(...)
	if not paused then return originals.getVehicleRotation(...) end
	originals.setGameSpeed(0)
	local ok, err = pcall(originals.getVehicleRotation, ...)
	originals.setGameSpeed(lastSpeed)
	if not ok then error(err, 0) end
end

local function install()
	local target = rawget(_G, "positionVE")
	if type(target) ~= "table" or target == guarded or type(target.setGameSpeed) ~= "function" then return end
	guarded, originals, paused = target, {setGameSpeed = target.setGameSpeed}, false
	target.setGameSpeed = setGameSpeed
	for _, name in ipairs({"updateGFX", "onPhysicsStep"}) do
		if type(target[name]) == "function" then
			originals[name] = target[name]
			target[name] = skipWhilePaused(target[name])
		end
	end
	if type(target.getVehicleRotation) == "function" then
		originals.getVehicleRotation = target.getVehicleRotation
		target.getVehicleRotation = getVehicleRotation
	end
	-- the vehicle's hook lists hold the functions: refresh them
	local ext = rawget(_G, "extensions")
	if type(ext) == "table" and type(ext.hookUpdate) == "function" then
		ext.hookUpdate("updateGFX")
		ext.hookUpdate("onPhysicsStep")
	end
end

function M.onExtensionLoaded()
	install()
end

function M.updateGFX()
	install()
end

return M
