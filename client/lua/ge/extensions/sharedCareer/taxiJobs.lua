-- SharedCareer :: taxi jobs: a passenger at the roadside, driven to a place on the map
--
-- A job type of the Jobs app (jobs.lua: the shared list, taking, giving up, the pay). This file
-- brings what a taxi job is about:
--   making one up (generate), by tier (TIERS: the higher, the longer the ride and the better paid)
--     a pickup    beside a normal road (jobs.randomRoadside), far from every vehicle
--     a place     a facility of the map (garage, dealership, gas station, ...: jobs.facilityPlaces,
--                 the middle of its doors), as far away as the tier says in a straight line
--                 (jobs.pickDestination: the nearest fit if none is)
--     a VIP       by the tier's VIP share: pays PAY_VIP times more, jolts and speeding cost twice as much
--     the pay     (PAY_BASE + PAY_PER_KM per km of the ride (jobs.roadLength)) x the tier's pay,
--                 x PAY_VIP for a VIP, x client.jobPay
--     job.data = {vip}; job.title = "Passenger" or "VIP"
--   doing it
--     1. the route leads to the passenger (a yellow marker); stopping in a vehicle (not on foot)
--        within PICKUP_RADIUS m of them for BOARD_STILL s: they get in. That vehicle is the taxi
--     2. the route leads to the place. A smooth ride pays all: every jolt (the taxi's speed
--        changes faster than JOLT_ACCEL m/s^2: hard braking, a crash, a hard landing; at most one
--        per JOLT_GAP s) costs JOLT_COST of the pay; speeding (on a road, faster than its speed
--        limit x SPEED_TOLERANCE for SPEEDING_FOR s; again after every SPEEDING_AGAIN s more)
--        SPEEDING_COST; new damage to the taxi up to PENALTY_MAX (DAMAGE_FOR_MAX damage points cost
--        all of it), a reset (R) PENALTY_MAX; all together at most PENALTY_MAX. The speed limit is
--        the one of the road's link in the game's road network (map.findClosestRoad, link.speedLimit
--        in m/s); a road without one has no limit. The taxi gone (deleted): the passenger waits at
--        the pickup again
--     3. you in the taxi, standing still in the drop-off zone (DROP_RADIUS m around the place's
--        doors) for DROP_STILL s: handed over (jobs.handOver)
--   No vehicle is spawned: the passenger is a marker, nothing to clean up when the job ends.

local M = {}

local U, J

local FAR_FROM_VEHICLES = 300 -- m: a new job is never made up closer to any vehicle
local PLACE_TRIES = 40
local PICKUP_RADIUS = 10 -- m around the passenger
local BOARD_STILL = 2 -- s standing still next to them: they get in
local DROP_RADIUS = 12 -- m around the middle of the place's doors
local DROP_STILL = 2 -- s standing still in the drop-off zone
local STOP_SPEED = 0.5 -- m/s: slower counts as standing still
local JOLT_ACCEL = 7 -- m/s^2: the taxi's speed changing faster than this is a jolt
local JOLT_GAP = 2 -- s: at most one jolt in this time (one hard stop counts once)
local JOLT_COST = 0.05 -- share of the pay a jolt costs (twice that for a VIP)
local SPEED_TOLERANCE = 1.15 -- faster than the speed limit x this is speeding
local SPEEDING_FOR = 2 -- s of speeding before it counts
local SPEEDING_AGAIN = 10 -- s more of speeding until it counts again
local SPEEDING_COST = 0.05 -- share of the pay speeding costs each time (twice that for a VIP)
local ROAD_MARGIN = 3 -- m beyond a road's edge that still count as on it
local PENALTY_MAX = 0.5 -- share of the pay a bumpy ride can cost at most
local DAMAGE_FOR_MAX = 40000 -- damage points (beamstate.damage) that cost PENALTY_MAX
local PAY_BASE, PAY_PER_KM = 100, 100
local PAY_VIP = 1.5
local MARKER_COLOR = { 1, 0.82, 0.1 } -- taxi yellow
-- the tiers: how far to the place (m), how often a VIP, the pay
local TIERS = {
	{ destMin = 600, destMax = 2000, vip = 0, pay = 1 },
	{ destMin = 1200, destMax = 3500, vip = 0.15, pay = 1.3 },
	{ destMin = 2000, destMax = 5000, vip = 0.3, pay = 1.7 },
	{ destMin = 3000, destMax = 7000, vip = 0.5, pay = 2.2 },
}

M.id = "taxi"
M.name = "Taxi"
M.icon = "taxi"
M.branch = "commercial"
M.deduction = "rough ride"
M.steps = { "Pick up", "Drive", "Paid" }

local clock = 0

--== Making up a job =============================================================

local function tierOf(tier)
	return TIERS[math.max(1, math.min(#TIERS, tonumber(tier) or 1))]
end

--- The pay for a ride of `length` m at level 1 (a VIP and a higher tier pay more).
function M.payFor(length, vip, tier)
	local pay = (PAY_BASE + PAY_PER_KM * length / 1000) * tierOf(tier).pay * (vip and PAY_VIP or 1) * J.payFactor()
	return J.roundTo(pay, 10)
end

--- Makes up a taxi job of a tier on this map, or returns nil and why not.
function M.generate(tier)
	local t = tierOf(tier)
	local places = J.facilityPlaces()
	if #places == 0 then
		return nil, "no places to go on this map"
	end
	for _ = 1, PLACE_TRIES do
		local spot, why = J.randomRoadside()
		if why then
			return nil, why
		end
		if spot and J.farFromVehicles(spot.pos, FAR_FROM_VEHICLES) then
			local pick = J.pickDestination(places, spot.pos, t.destMin, t.destMax)
			if pick then
				local length = J.roadLength(spot.pos, pick.place.pos)
				local vip = math.random() < t.vip
				return {
					title = vip and "VIP" or "Passenger",
					pos = spot.pos,
					dest = { name = pick.place.name, pos = pick.place.pos },
					length = length,
					pay = M.payFor(length, vip, tier),
					data = { vip = vip },
				}
			end
		end
	end
	return nil, "no free place found"
end

--- The labels of a taxi job in the Jobs app.
function M.tags(job)
	if type(job.data) == "table" and job.data.vip == true then
		return { { text = "VIP", kind = "vip" } }
	end
	return {}
end

--== Doing it ======================================================================

local function isVip(a)
	return type(a.job.data) == "table" and a.job.data.vip == true
end

-- The vehicle you drive and its id, or nil (on foot, or none).
local function myVehicle()
	local id = be:getPlayerVehicleID(0)
	local veh = id and id >= 0 and be:getObjectByID(id)
	if not veh or U.modelOf(veh) == "unicycle" then
		return nil
	end
	return veh, id
end

-- The damage of a vehicle so far (the game's map of objects: beamstate.damage), or nil.
local function damageOf(id)
	local ok, d = pcall(function()
		return map.objects[id].damage
	end)
	return ok and tonumber(d) or nil
end

-- The share of the pay the ride has cost so far (0..PENALTY_MAX).
function M.penalty(a)
	if a.rough then
		return PENALTY_MAX
	end
	local p = ((a.jolts or 0) * JOLT_COST + (a.speeding or 0) * SPEEDING_COST) * (isVip(a) and 2 or 1)
	local damage = damageOf(a.taxiId)
	if damage and a.damageStart then
		p = p + math.max(0, damage - a.damageStart) / DAMAGE_FOR_MAX * PENALTY_MAX
	end
	return math.min(PENALTY_MAX, p)
end

-- The passenger gets into this vehicle: it is the taxi now.
local function board(a, id)
	a.phase, a.stillFor = "toDestination", 0
	a.taxiId, a.damageStart = id, damageOf(id)
	a.jolts, a.joltAt, a.lastVel, a.rough = 0, -math.huge, nil, false
	a.speeding, a.speedingFor = 0, 0
	U.toast("info", "Passenger in: drive to " .. a.job.dest.name, 6)
end

-- The speed limit (m/s) of the road at p, or nil (off the road, or a road without one).
local function speedLimitAt(p)
	local ok, limit = pcall(function()
		local a, b, d = map.findClosestRoad(vec3(p.x, p.y, p.z))
		local nodes = a and b and map.getMap().nodes
		local n, m = nodes and nodes[a], nodes and nodes[b]
		if not (n and m) or (tonumber(d) or math.huge) > (tonumber(n.radius) or 0) + ROAD_MARGIN then
			return nil
		end
		local link = (n.links or {})[b] or (m.links or {})[a]
		return type(link) == "table" and tonumber(link.speedLimit) or nil
	end)
	return ok and limit and limit > 0 and limit or nil
end

-- Speeding: faster than the road's speed limit x SPEED_TOLERANCE for SPEEDING_FOR s.
local function watchSpeed(a, taxi, dt)
	local p = U.vecOf(taxi:getPosition())
	local limit = p and speedLimitAt(p)
	if not limit or J.speedOf(taxi) <= limit * SPEED_TOLERANCE then
		a.speedingFor = 0
		return
	end
	a.speedingFor = a.speedingFor + dt
	if a.speedingFor >= SPEEDING_FOR then
		a.speeding, a.speedingFor = a.speeding + 1, SPEEDING_FOR - SPEEDING_AGAIN
		U.toast("warning", "Too fast!", 3)
	end
end

-- A jolt: the taxi's speed changed faster than JOLT_ACCEL since the last check.
local function watchJolts(a, taxi, dt)
	local v = type(taxi.getVelocity) == "function" and U.vecOf(taxi:getVelocity())
	if not v then
		return
	end
	local last = a.lastVel
	a.lastVel = v
	if not last or dt <= 0 then
		return
	end
	local dx, dy, dz = v.x - last.x, v.y - last.y, v.z - last.z
	if math.sqrt(dx * dx + dy * dy + dz * dz) / dt > JOLT_ACCEL and clock - a.joltAt >= JOLT_GAP then
		a.jolts, a.joltAt = a.jolts + 1, clock
		U.toast("warning", "Drive smoother!", 3)
	end
end

function M.start(a)
	a.phase, a.stillFor = "toPassenger", 0
	U.toast("info", "Route set: pick up the passenger", 6)
end

function M.step(a, dt)
	local job = a.job
	local veh, id = myVehicle()
	if a.phase == "toPassenger" then
		local p = veh and U.vecOf(veh:getPosition())
		local near = p and J.dist2D(p, job.pos) <= PICKUP_RADIUS and J.speedOf(veh) <= STOP_SPEED
		a.stillFor = near and a.stillFor + dt or 0
		if a.stillFor >= BOARD_STILL then
			board(a, id)
		end
		return
	end
	local taxi = a.taxiId and be:getObjectByID(a.taxiId)
	if not taxi then
		U.log("W", "jobs", "the taxi of job " .. tostring(job.id) .. " is gone")
		U.toast("warning", "Taxi gone – pick them up again", 6)
		a.phase, a.taxiId, a.stillFor = "toPassenger", nil, 0
		return
	end
	watchJolts(a, taxi, dt)
	watchSpeed(a, taxi, dt)
	local p = U.vecOf(taxi:getPosition())
	local inZone = id == a.taxiId and p and J.dist2D(p, job.dest.pos) <= DROP_RADIUS and J.speedOf(taxi) <= STOP_SPEED
	a.stillFor = inZone and a.stillFor + dt or 0
	if a.stillFor >= DROP_STILL then
		local penalty = M.penalty(a)
		U.log(
			"I",
			"jobs",
			string.format(
				"job %s done: %d jolts, %d times speeding, damage %s -> %s, %d %% of the pay",
				tostring(job.id),
				a.jolts,
				a.speeding,
				tostring(a.damageStart),
				tostring(damageOf(a.taxiId)),
				math.floor((1 - penalty) * 100 + 0.5)
			)
		)
		J.handOver(a, 1 - penalty)
	end
end

function M.status(a)
	local inZone = (a.stillFor or 0) > 0
	if a.phase == "toDestination" then
		local taxi = a.taxiId and be:getObjectByID(a.taxiId)
		local taxiPos = taxi and U.vecOf(taxi:getPosition()) or nil
		local _, id = myVehicle()
		if taxiPos and id ~= a.taxiId then
			return { step = 1, target = taxiPos, text = "back to your taxi", short = "Back to your taxi" }
		end
		return {
			step = 1,
			target = a.job.dest.pos,
			from = taxiPos,
			inZone = inZone,
			text = inZone and "In the ring – wait" or ("to " .. a.job.dest.name),
			short = inZone and "In the ring – wait" or ("Drive to " .. a.job.dest.name),
			hint = "No bumps, no speeding.",
		}
	end
	return {
		step = 0,
		target = a.job.pos,
		inZone = inZone,
		text = inZone and "Wait – they get in" or "to the passenger",
		short = inZone and "Wait – they get in" or "Pick up the passenger",
		hint = myVehicle() and "Stop next to them." or "Pick them up in a car.",
	}
end

function M.stop() end

-- a reset (R) of the taxi during the ride: a rough ride
function M.vehicleReset(a, id)
	if a.phase == "toDestination" and id == a.taxiId and not a.rough then
		a.rough = true
		U.toast("warning", "Rough ride – less pay", 4)
	end
end

function M.draw(a)
	if a.phase == "toPassenger" then
		J.drawMarker(a.job.pos, MARKER_COLOR)
	else
		local waitLeft = (a.stillFor or 0) > 0 and DROP_STILL - a.stillFor or nil
		J.drawDropOff(a.job.dest.pos, DROP_RADIUS, a.job.dest.name, waitLeft)
	end
end

--== Hooks =======================================================================

function M.onUpdate(dtReal)
	clock = clock + (tonumber(dtReal) or 0)
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	J = extensions.sharedCareer_jobs
	J.registerType(M)
end

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
