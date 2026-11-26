-- Career-Convoy :: keeps other players' vehicles in one piece: BeamMP's sync never feeds them
-- invalid values
--
-- BeamMP moves another player's vehicle on your PC with forces (positionVE -> velocityVE) and
-- from time to time by setting it in place (positionGE.setPositionRotationVelocity, guarded on the
-- GE side in instability.lua). It never checks the numbers. One NaN or infinite value and the
-- vehicle's physics blows up ("Instability detected"), and takes the vehicles next to it along.
--
-- 1. Pause: when the game pauses (the career pauses for its menus, the computer, the big map),
--    BeamMP sets the game speed of every vehicle to 0 (positionGE -> positionVE.setGameSpeed(0)).
--    For another player's vehicle positionVE divides by that speed for every position packet
--    (1 / simSpeedReal): the predicted velocity becomes infinite.
--    So positionVE never gets a speed of 0 (or an invalid one): while paused it keeps the last
--    real speed, and positionVE.updateGFX / onPhysicsStep are skipped (also on frames without
--    time). Our own vehicles still report standing still while paused:
--    positionVE.getVehicleRotation runs with BeamMP's speed of 0, which it only multiplies with.
--    When the pause starts and ends, positionVE's prediction starts fresh (positionVE.onReset).
--
-- 2. Invalid values: velocityVE's addVelocity / setVelocity / addAngularVelocity /
--    setAngularVelocity drop a call with a value that is not a finite number instead of pushing
--    it into the physics. Dropped calls are counted and logged once per second at most.
--
-- Nothing else of BeamMP is changed. positionVE and velocityVE are BeamMP's vehicle extensions
-- and may load after this one, so the guards are put in place on the first frame that finds
-- them (and again if BeamMP loads them anew).

local M = {}

local guarded = nil -- the positionVE table the pause guard is in
local originals = {} -- BeamMP's own functions: setGameSpeed, updateGFX, onPhysicsStep, getVehicleRotation
local paused = false
local lastSpeed = 1 -- the last real game speed

local guardedVelocity = nil -- the velocityVE table the value guard is in
local VELOCITY_FUNCTIONS = { "addVelocity", "setVelocity", "addAngularVelocity", "setAngularVelocity" }
local dropped = 0 -- calls with invalid values since the last log line
local sinceLog = 0

local function positive(n)
	return type(n) == "number" and n == n and n > 0 and n < math.huge
end

local function finite(n)
	return n == n and n > -math.huge and n < math.huge
end

--== 1. Pause ===================================================================

local function setGameSpeed(speed)
	local stopped = not positive(speed)
	if stopped ~= paused and type(guarded.onReset) == "function" then
		guarded.onReset()
	end
	paused = stopped
	if not stopped then
		lastSpeed = speed
	end
	originals.setGameSpeed(lastSpeed)
end

-- updateGFX(dt) / onPhysicsStep(dt): nothing to do while paused or on a frame without time
local function skipWhilePaused(original)
	return function(dt, ...)
		if paused or not positive(dt) then
			return
		end
		return original(dt, ...)
	end
end

-- own vehicle: while paused it reports standing still, as BeamMP intends
local function getVehicleRotation(...)
	if not paused then
		return originals.getVehicleRotation(...)
	end
	originals.setGameSpeed(0)
	local ok, err = pcall(originals.getVehicleRotation, ...)
	originals.setGameSpeed(lastSpeed)
	if not ok then
		error(err, 0)
	end
end

local function installPauseGuard()
	local target = rawget(_G, "positionVE")
	if type(target) ~= "table" or target == guarded or type(target.setGameSpeed) ~= "function" then
		return false
	end
	guarded, originals, paused = target, { setGameSpeed = target.setGameSpeed }, false
	target.setGameSpeed = setGameSpeed
	for _, name in ipairs({ "updateGFX", "onPhysicsStep" }) do
		if type(target[name]) == "function" then
			originals[name] = target[name]
			target[name] = skipWhilePaused(target[name])
		end
	end
	if type(target.getVehicleRotation) == "function" then
		originals.getVehicleRotation = target.getVehicleRotation
		target.getVehicleRotation = getVehicleRotation
	end
	return true
end

--== 2. Invalid values ==========================================================

-- velocityVE.<name>(...) only with finite numbers
local function onlyFinite(original)
	return function(...)
		for i = 1, select("#", ...) do
			local n = select(i, ...)
			if type(n) == "number" and not finite(n) then
				dropped = dropped + 1
				return
			end
		end
		return original(...)
	end
end

local function installValueGuard()
	local target = rawget(_G, "velocityVE")
	if type(target) ~= "table" or target == guardedVelocity then
		return
	end
	guardedVelocity = target
	for _, name in ipairs(VELOCITY_FUNCTIONS) do
		if type(target[name]) == "function" then
			target[name] = onlyFinite(target[name])
		end
	end
end

local function logDropped(dt)
	sinceLog = sinceLog + (positive(dt) and dt or 0)
	if dropped == 0 or sinceLog < 1 then
		return
	end
	sinceLog = 0
	local logFn = rawget(_G, "log")
	if type(logFn) == "function" then
		logFn("W", "careerConvoy.syncGuard", "dropped " .. dropped .. " sync correction(s) with invalid values")
	end
	dropped = 0
end

--== Hooks ======================================================================

local function install()
	installValueGuard()
	if installPauseGuard() then
		-- the vehicle's hook lists hold the functions: refresh them
		local ext = rawget(_G, "extensions")
		if type(ext) == "table" and type(ext.hookUpdate) == "function" then
			ext.hookUpdate("updateGFX")
			ext.hookUpdate("onPhysicsStep")
		end
	end
end

function M.onExtensionLoaded()
	install()
end

function M.updateGFX(dt)
	install()
	logDropped(dt)
end

return M
