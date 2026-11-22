-- SharedCareer :: how often your parked cars and traffic send their position
--
-- BeamMP sends the position of every car this game owns, parked cars and traffic included, up to
-- 50 times a second (positionGE.tick -> positionVE.getVehicleRotation ->
-- positionGE.sendVehiclePosRot). On every other PC its copy is then held to that position with
-- forces in every frame, as long as the last packet is younger than 0.1 s (positionVE:
-- packetTimeout). A parked car standing still is pushed around like that all the time, and
-- those copies (parked cars, traffic, police) are the ones that blow up ("Instability detected")
-- and take the cars next to them along. Between packets older than 0.1 s BeamMP leaves a copy
-- alone, and the game's own physics simply keeps it standing.
--
-- So positionGE.sendVehiclePosRot drops a position of your own vehicles under these rules
-- (worked out every CLASSIFY_EVERY seconds; a parked car's speed every PARKED_CHECK_EVERY):
--   hidden    a hidden car (garage, traffic reserve)                       no position at all
--   parked    a parked car slower than PARKED_STILL_SPEED                  once a second
--   far       driving traffic more than FAR_DISTANCE from every other     twice a second
--             player's vehicle
-- Everything else sends every position, as before: the car you drive, your other cars, traffic
-- near other players, and a parked car that moves (it was hit) - at once, not only at the next
-- check. Only positions are thinned out; lights, inputs, engine and broken parts are sent as
-- BeamMP sends them. Same idea as Mileage's send rate for traffic and parked cars.

local M = {}

local U

local CLASSIFY_EVERY = 1 -- s between working out each car's rule
local PARKED_CHECK_EVERY = 0.25 -- s between speed checks of still parked cars
local PARKED_STILL_SPEED = 0.5 -- m/s
local FAR_DISTANCE = 500 -- m from every other player's vehicle
local SPACING = { parked = 1, far = 0.5 } -- s between two positions under a rule; hidden: none

local rules = {} -- game id -> "hidden" | "parked" | "far" (not listed: every position)
local nextDue = {} -- game id -> clock when the next position may go out
local sinceClassify = CLASSIFY_EVERY
local sinceParkedCheck = 0

local function clock()
	return os.clockhp()
end

local function mp()
	local m = rawget(_G, "MPVehicleGE")
	if type(m) == "table" and type(m.getVehicles) == "function" and type(m.isOwn) == "function" then
		return m
	end
	return nil
end

local function speedOf(veh)
	local v = U.vecOf(veh:getVelocity())
	if not v then
		return math.huge
	end
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function farFromAll(veh, others)
	local p = U.vecOf(veh:getPosition())
	if not p then
		return false
	end
	for _, o in ipairs(others) do
		local dx, dy, dz = p.x - o.x, p.y - o.y, p.z - o.z
		if dx * dx + dy * dy + dz * dz <= FAR_DISTANCE * FAR_DISTANCE then
			return false
		end
	end
	return true
end

--== Rules ======================================================================

local function classify()
	local m = mp()
	local vehicles = U.ext("sharedCareer_vehicles")
	if not m or not vehicles then
		rules = {}
		return
	end
	local own, others = {}, {}
	for _, entry in pairs(m.getVehicles() or {}) do
		local id = entry.gameVehicleID
		local veh = id and id ~= -1 and be:getObjectByID(id)
		if veh then
			if m.isOwn(id) then
				own[id] = veh
			elseif veh:getActive() then
				-- every vehicle of another player counts, their traffic too: a car near any of
				-- them keeps every position
				local p = U.vecOf(veh:getPosition())
				if p then
					table.insert(others, p)
				end
			end
		end
	end
	local newRules = {}
	for id, veh in pairs(own) do
		local kind = vehicles.trafficKind(id, veh)
		if kind and not veh:getActive() then
			newRules[id] = "hidden"
		elseif kind == "parked" and speedOf(veh) < PARKED_STILL_SPEED then
			newRules[id] = "parked"
		elseif kind == "traffic" and farFromAll(veh, others) then
			newRules[id] = "far"
		end
	end
	rules = newRules
	for id in pairs(nextDue) do
		if not own[id] then
			nextDue[id] = nil
		end
	end
end

-- A still parked car that starts moving (it was hit) or a hidden car shown again sends every
-- position until the next full check gives it its rule.
local function checkParked()
	for id, rule in pairs(rules) do
		if rule ~= "far" then
			local veh = be:getObjectByID(id)
			if
				not veh
				or (rule == "parked" and speedOf(veh) >= PARKED_STILL_SPEED)
				or (rule == "hidden" and veh:getActive())
			then
				rules[id] = nil
			end
		end
	end
end

-- true if this position of the vehicle may go out now
local function due(id)
	local rule = rules[id]
	if not rule then
		return true
	end
	local every = SPACING[rule]
	if not every then
		return false -- hidden
	end
	local now = clock()
	if nextDue[id] and now < nextDue[id] then
		return false
	end
	nextDue[id] = now + every
	return true
end
M.due = due

--== BeamMP's send ==============================================================

local function makeSendVehiclePosRot(original)
	return function(data, gameVehicleId, ...)
		local ok, through = pcall(due, gameVehicleId)
		if not ok or through then
			return original(data, gameVehicleId, ...)
		end
	end
end

function M.ensurePatches()
	U.replace(rawget(_G, "positionGE"), "sendVehiclePosRot", makeSendVehiclePosRot)
end

--== Hooks ======================================================================

function M.onUpdate(dtReal)
	if not U.isMP() then
		return
	end
	local dt = tonumber(dtReal) or 0
	sinceClassify, sinceParkedCheck = sinceClassify + dt, sinceParkedCheck + dt
	if sinceClassify >= CLASSIFY_EVERY then
		sinceClassify, sinceParkedCheck = 0, 0
		M.ensurePatches()
		local ok, err = pcall(classify)
		if not ok then
			rules = {}
			U.log("E", "sendRate", "working out the rules failed, every position is sent: " .. tostring(err))
		end
	elseif sinceParkedCheck >= PARKED_CHECK_EVERY then
		sinceParkedCheck = 0
		pcall(checkParked)
	end
end

function M.onVehicleDestroyed(id)
	rules[id], nextDue[id] = nil, nil
end

function M.onBeamMPServerLeave()
	rules, nextDue, sinceClassify, sinceParkedCheck = {}, {}, CLASSIFY_EVERY, 0
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
end

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
