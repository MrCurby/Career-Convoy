-- Career-Convoy :: taxi jobs: passengers at the roadside, driven to a place on the map
--
-- A job type of the Jobs app (jobs.lua: the shared list, taking, giving up, the pay). This file
-- brings what a taxi job is about:
--   making one up (generate), by tier (TIERS: the higher, the longer the ride and the better paid;
--   flatter than towing: a ride is easier than a tow, and a smooth one earns a tip)
--     a pickup    beside a normal road (jobs.randomRoadside), far from every vehicle
--     a place     a facility of the map (garage, dealership, gas station, ...: jobs.facilityPlaces,
--                 the middle of its doors), as far away as the tier says in a straight line
--                 (jobs.pickDestination: the nearest fit if none is)
--     the town    the pickup is in town (jobs.inTown) by TOWN_START, the place by TOWN_END, each on
--                 its own: most rides touch the town, every mix stays possible (in town, out of
--                 town, into it, past it). None that fits there (a map without a town, a long ride
--                 from a small one): anywhere
--     a VIP       by the tier's VIP share: pays PAY_VIP times more, jolts and speeding cost twice as much
--     passengers  1..5, at random by the tier's chances (PASSENGERS): a higher tier (unlocked by a
--                 higher level) makes a group more likely, but a ride for one stays common
--     the pay     (PAY_BASE + PAY_PER_KM per km of the ride (jobs.roadLength)) x the tier's pay,
--                 x PAY_VIP for a VIP, x client.jobPay
--     job.data = {vip, passengers, face (x, y: the way the passengers look, towards the road)};
--     job.title = "Passenger" or "VIP"; a group has a tag ("3 people")
--   doing it
--     1. the route leads to the passengers: the game's figure (PASSENGER_SHAPE, a static mesh only
--        this client sees) for each, side by side at the roadside, facing the road, with a yellow
--        marker above; stopping in a vehicle of your own (not on foot) within PICKUP_RADIUS m of them for
--        BOARD_STILL s: they get in, if it has a seat for each (seatsIn; else "Too few seats").
--        That vehicle is the taxi. The figures go; dummies sit in the taxi instead: the game's
--        seat occupants (gameplay_seatOccupants.setDummyOccupant, PASSENGER_WEIGHT kg each),
--        spread evenly over the rear seats (spreadSeats), the front passenger seat only when the
--        rear is full. A vehicle without such seats (older or mod vehicles) can't be counted: they
--        get in unseen; the ride is the same. Every SEAT_CHECK s the dummies are seated again if
--        the game took one out (the taxi rebuilt in the garage)
--     2. the route leads to the place. A smooth ride pays all: every jolt (the taxi's speed on
--        the ground or up/down changes faster than JOLT_ACCEL m/s^2, measured over JOLT_WINDOW s
--        so bumps and curbs don't count; turning doesn't count either: hard braking, a crash, a
--        hard landing; at most one per JOLT_GAP s) costs JOLT_COST of the pay. Speeding (on a road,
--        faster than its speed limit x speedLimit.TOLERANCE): after COMPLAIN_AFTER s the passengers
--        complain ("Slow down, please!", free); still too fast after SPEEDING_FOR s it costs
--        SPEEDING_COST ("Too fast! Less pay."); staying too fast, they complain and it costs again
--        every SPEEDING_AGAIN s. New damage to the taxi up to PENALTY_MAX (DAMAGE_FOR_MAX damage points cost
--        all of it), a reset (R) PENALTY_MAX; all together at most PENALTY_MAX. The speed limit
--        comes from speedLimit.lua (the sign shows it); a road without one has no limit. The taxi
--        gone (deleted): the passenger waits at the pickup again
--        The passenger rates the ride: 1..5 stars by what it has cost so far (STARS), shown live in
--        the Jobs app with the pay as it is now
--     3. you in the taxi, standing still in the drop-off zone (DROP_RADIUS m around the place's
--        doors) for DROP_STILL s: the dummies get out, handed over (jobs.handOver), with a tip for
--        4 or 5 stars (TIPS)
--   No vehicle is spawned. When the job ends (stop), the figures and the dummies go.
--   Calls: with "On duty" on (the switch on the taxi page of the Jobs app; off on every join), the
--   nearest open ride within CALL_RANGE m rings the phone (phone.ring) while you sit in a vehicle of
--   your own (not on foot, not in another player's you watch) with a seat for each of its passengers (a vehicle that can't be counted: rides for one only),
--   own the Taxi License and have no job; the call says how many they are ("3 people to …").
--   The Jobs app lists every ride, whatever you drive. "Accept" takes it. Not nagging: after a call that wasn't
--   taken the next one waits CALL_PAUSE s (and that ride doesn't call again), after a ride
--   CALL_AFTER_RIDE s; MISSED_MAX calls missed in a row put you off duty. A call whose ride someone
--   else took hangs up.

local M = {}

local U, J

local FAR_FROM_VEHICLES = 300 -- m: a new job is never made up closer to any vehicle
local PLACE_TRIES = 40
local PICKUP_RADIUS = 10 -- m around the passenger
local BOARD_STILL = 2 -- s standing still next to them: they get in
local DROP_RADIUS = 12 -- m around the middle of the place's doors
local DROP_STILL = 2 -- s standing still in the drop-off zone
local STOP_SPEED = 0.5 -- m/s: slower counts as standing still
local JOLT_ACCEL = 9 -- m/s^2: the taxi's speed changing faster than this is a jolt (about a full stop)
local JOLT_WINDOW = 0.5 -- s: the change is measured over this long (not every frame: bumps don't count)
local JOLT_GAP = 2 -- s: at most one jolt in this time (one hard stop counts once)
local JOLT_COST = 0.05 -- share of the pay a jolt costs (twice that for a VIP)
local COMPLAIN_AFTER = 2 -- s of speeding before the passengers complain (free)
local SPEEDING_FOR = 7 -- s of speeding before it costs (5 s after they complained)
local SPEEDING_AGAIN = 10 -- s more of speeding until they complain and it costs again
local SPEEDING_COST = 0.05 -- share of the pay speeding costs each time (twice that for a VIP)
local PENALTY_MAX = 0.5 -- share of the pay a bumpy ride can cost at most
local DAMAGE_FOR_MAX = 40000 -- damage points (beamstate.damage) that cost PENALTY_MAX
local PAY_BASE, PAY_PER_KM = 60, 80
local PAY_VIP = 1.5
-- the stars: the most a ride may have cost (share of the pay) for each rating, the best first
local STARS = { { 5, 0.01 }, { 4, 0.1 }, { 3, 0.2 }, { 2, 0.35 } } -- else 1 star
-- the tip by stars, as a share of the pay; a VIP tips more
local TIPS = { [5] = 0.15, [4] = 0.05 }
local TIPS_VIP = { [5] = 0.25, [4] = 0.1 }
local MARKER_COLOR = { 1, 0.82, 0.1 } -- taxi yellow
local PASSENGER_SHAPE = "/vehicles/simple_traffic/traffic_character.dae" -- the game's figure: body and head
local PASSENGER_WEIGHT = 89 -- kg: a dummy in the taxi (the game's own default for a seat occupant)
local SEAT_CHECK = 2 -- s between two looks whether the dummies still sit in the taxi
local FIGURE_GAP = 0.8 -- m between two passengers waiting side by side
local MAX_PASSENGERS = 5
local TOWN_START = 0.6 -- share of rides that start in town
local TOWN_END = 0.6 -- share of rides that end in town (on its own: 84 % touch the town)
-- the chances of 1, 2, 3, 4, 5 passengers by tier
local PASSENGERS = {
	{ 0.8, 0.2 },
	{ 0.55, 0.3, 0.15 },
	{ 0.4, 0.3, 0.15, 0.1, 0.05 },
	{ 0.3, 0.25, 0.2, 0.15, 0.1 },
}
local CALL_CHECK = 2 -- s between two looks for a ride to call about
local CALL_RANGE = 2000 -- m (straight line): rides closer than this call
local CALL_FIRST = 3 -- s after going on duty before the first call
local CALL_PAUSE = 45 -- s after a call that wasn't taken before the next one
local CALL_AFTER_RIDE = 20 -- s after a ride before the next call
local MISSED_MAX = 2 -- calls missed in a row: off duty
-- the tiers: how far to the place (m), how often a VIP, the pay
local TIERS = {
	{ destMin = 600, destMax = 2000, vip = 0, pay = 1 },
	{ destMin = 1200, destMax = 3500, vip = 0.15, pay = 1.15 },
	{ destMin = 2000, destMax = 5000, vip = 0.3, pay = 1.3 },
	{ destMin = 3000, destMax = 7000, vip = 0.5, pay = 1.5 },
}

M.id = "taxi"
M.name = "Taxi"
M.icon = "taxi"
M.branch = "commercial"
M.deduction = "Rough ride"
M.bonus = "Smooth ride bonus"
M.steps = { "Pick up", "Drive", "Paid" }

local clock = 0
local onDuty = false
local calling = nil -- the ride that rings the phone: its job id
local nextCallAt, sinceCallCheck = 0, 0
local missed = 0 -- calls missed in a row
local declined = {} -- job ids that called and weren't taken: they don't call again

--== Making up a job =============================================================

local function tierOf(tier)
	return TIERS[math.max(1, math.min(#TIERS, tonumber(tier) or 1))]
end

--- The pay for a ride of `length` m at level 1 (a VIP and a higher tier pay more).
function M.payFor(length, vip, tier)
	local pay = (PAY_BASE + PAY_PER_KM * length / 1000) * tierOf(tier).pay * (vip and PAY_VIP or 1) * J.payFactor()
	return J.roundTo(pay, 10)
end

--- How many passengers a ride of this tier has: 1..MAX_PASSENGERS, at random by PASSENGERS.
function M.rollPassengers(tier)
	local chances = PASSENGERS[math.max(1, math.min(#PASSENGERS, tonumber(tier) or 1))]
	local r = math.random()
	for n, chance in ipairs(chances) do
		r = r - chance
		if r < 0 then
			return n
		end
	end
	return #chances
end

--- How many passengers a job has (1..MAX_PASSENGERS).
function M.passengersOf(job)
	local n = type(job) == "table" and type(job.data) == "table" and tonumber(job.data.passengers)
	return math.max(1, math.min(MAX_PASSENGERS, math.floor(n or 1)))
end

--- Makes up a taxi job of a tier on this map, or returns nil and why not.
function M.generate(tier)
	local t = tierOf(tier)
	local places = J.facilityPlaces()
	if #places == 0 then
		return nil, "no places to go on this map"
	end
	local startInTown, endInTown = math.random() < TOWN_START, math.random() < TOWN_END
	local ends = {}
	for _, place in ipairs(places) do
		if J.inTown(place.pos) == endInTown then
			table.insert(ends, place)
		end
	end
	for _ = 1, PLACE_TRIES do
		local spot, why = J.randomRoadside(startInTown)
		if why then
			return nil, why
		end
		if spot and J.farFromVehicles(spot.pos, FAR_FROM_VEHICLES) then
			local pick = J.pickDestination(ends, spot.pos, t.destMin, t.destMax)
			if not pick or pick.d < t.destMin or pick.d > t.destMax then
				pick = J.pickDestination(places, spot.pos, t.destMin, t.destMax) or pick
			end
			if pick then
				local length = J.roadLength(spot.pos, pick.place.pos)
				local vip = math.random() < t.vip
				-- spot.dir runs along the road; the road is to the left of it
				local face = spot.dir and { x = J.roundTo(-spot.dir.y, 0.01), y = J.roundTo(spot.dir.x, 0.01) }
				return {
					title = vip and "VIP" or "Passenger",
					pos = spot.pos,
					dest = { name = pick.place.name, pos = pick.place.pos },
					length = length,
					pay = M.payFor(length, vip, tier),
					data = { vip = vip, passengers = M.rollPassengers(tier), face = face },
				}
			end
		end
	end
	return nil, "no free place found"
end

--- The labels of a taxi job in the Jobs app.
function M.tags(job)
	local tags = {}
	if type(job.data) == "table" and job.data.vip == true then
		table.insert(tags, { text = "VIP", kind = "vip" })
	end
	local n = M.passengersOf(job)
	if n > 1 then
		table.insert(tags, { text = n .. " people", kind = "group" })
	end
	return tags
end

--== Doing it ======================================================================

local function isVip(a)
	return type(a.job.data) == "table" and a.job.data.vip == true
end

-- The vehicle you sit in and its id, if it is yours; else nil (on foot, none, or another player's
-- vehicle you watch).
local function myVehicle()
	local id = be:getPlayerVehicleID(0)
	local veh = id and id >= 0 and be:getObjectByID(id)
	if not veh or U.modelOf(veh) == "unicycle" or not U.isOwnVehicle(id) then
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

--- The passenger's rating (1..5 stars) of a ride that has cost this share of the pay.
function M.starsFor(penalty)
	for _, s in ipairs(STARS) do
		if penalty <= s[2] then
			return s[1]
		end
	end
	return 1
end

--- The tip (a share of the pay) for this many stars.
function M.tipFor(stars, vip)
	return (vip and TIPS_VIP or TIPS)[stars] or 0
end

-- The passengers at the roadside: the game's figure for each, side by side along the road,
-- facing it (job.data.face).
local function showFigures(a)
	if a.figures or type(createObject) ~= "function" then
		return
	end
	local p = U.vecOf(a.job.pos)
	if not p then
		return
	end
	a.figures = {}
	local face = type(a.job.data) == "table" and U.vecOf(a.job.data.face)
	local rot = { x = 0, y = 0, z = 0, w = 1 }
	if face and type(quatFromDir) == "function" then
		rot = quatFromDir(vec3(face.x, face.y, 0), vec3(0, 0, 1))
	end
	local along = face and { x = face.y, y = -face.x } or { x = 1, y = 0 }
	local n = M.passengersOf(a.job)
	for i = 1, n do
		local off = (i - (n + 1) / 2) * FIGURE_GAP
		local ok, err = pcall(function()
			local o = createObject("TSStatic")
			o.shapeName = PASSENGER_SHAPE
			o:setPosRot(p.x + along.x * off, p.y + along.y * off, p.z, rot.x, rot.y, rot.z, rot.w)
			o:registerObject("")
			table.insert(a.figures, o)
		end)
		if not ok then
			U.log("W", "jobs", "could not place a passenger: " .. tostring(err))
		end
	end
end

local function hideFigures(a)
	for _, o in ipairs(a.figures or {}) do
		pcall(function()
			o:delete()
		end)
	end
	a.figures = nil
end

-- The game's seat occupants (newer game versions), or nil.
local function seatSystem()
	local so = U.ext("gameplay_seatOccupants")
	return so and type(so.getSeats) == "function" and type(so.setDummyOccupant) == "function" and so or nil
end

-- The seats of a vehicle (gameplay_seatOccupants.getSeats), {} without them.
local function seatsOf(so, id)
	local ok, seats = pcall(so.getSeats, id)
	return ok and type(seats) == "table" and seats or {}
end

-- The seats of a vehicle passengers can take: not the driver's, not taken. The rear ones and the
-- front ones, each in the game's order (by name).
local function freeSeats(so, id)
	local rear, front = {}, {}
	for _, seat in ipairs(seatsOf(so, id)) do
		local seatId = seat.seatId
		if type(seatId) == "string" and not seat.isDriver and not seat.occupied then
			table.insert(seatId:sub(1, 1) == "F" and front or rear, seatId)
		end
	end
	return rear, front
end

--- How many passengers vehicle `id` has seats for, or nil when the game can't tell (no seat
--- occupants in this game version, or none in this vehicle).
function M.seatsIn(id)
	local so = seatSystem()
	if not so or not id or #seatsOf(so, id) == 0 then
		return nil
	end
	local rear, front = freeSeats(so, id)
	return #rear + #front
end

--- Where n passengers sit: spread evenly over the rear seats (two of three: the outer ones; one of
--- two: the second), the front seats only for those the rear has no room for.
function M.spreadSeats(rear, front, n)
	local out = {}
	if n >= #rear then
		for _, seatId in ipairs(rear) do
			table.insert(out, seatId)
		end
		for i = 1, math.min(n - #rear, #front) do
			table.insert(out, front[i])
		end
		return out
	end
	for i = 1, n do
		table.insert(out, rear[math.floor((i - 0.5) * #rear / n) + 1])
	end
	return out
end

-- The dummies get out of the taxi.
local function unseatPassengers(a)
	local so = seatSystem()
	for _, seatId in ipairs(a.seats or {}) do
		if so and a.taxiId then
			pcall(so.clearDummyOccupant, a.taxiId, seatId)
		end
	end
	a.seats = nil
end

-- The dummies sit in the taxi: nothing to do while all of them are still on their seats; else
-- they all sit down again (spreadSeats). Seats there's no room for: those passengers ride unseen.
local function seatPassengers(a)
	local so = seatSystem()
	if not so or not a.taxiId then
		return
	end
	if a.seats then
		local dummies = {}
		for _, seat in ipairs(seatsOf(so, a.taxiId)) do
			if seat.seatId ~= nil then
				dummies[seat.seatId] = seat.occupantType == "dummy"
			end
		end
		local all = true
		for _, seatId in ipairs(a.seats) do
			all = all and dummies[seatId] == true
		end
		if all then
			return
		end
	end
	unseatPassengers(a)
	a.seats = {}
	local rear, front = freeSeats(so, a.taxiId)
	for _, seatId in ipairs(M.spreadSeats(rear, front, M.passengersOf(a.job))) do
		local ok, seated = pcall(so.setDummyOccupant, a.taxiId, seatId, PASSENGER_WEIGHT)
		if ok and seated == true then
			table.insert(a.seats, seatId)
		end
	end
end

-- The passenger gets into this vehicle: it is the taxi now.
local function board(a, id)
	a.phase, a.stillFor = "toDestination", 0
	a.taxiId, a.damageStart = id, damageOf(id)
	a.jolts, a.joltAt, a.lastVel, a.velFor, a.rough = 0, -math.huge, nil, 0, false
	a.speeding, a.speedingFor = 0, 0
	hideFigures(a)
	a.seats, a.seatCheck = nil, 0
	seatPassengers(a)
	local who = M.passengersOf(a.job) > 1 and "Passengers" or "Passenger"
	U.toast("info", who .. " in: drive to " .. a.job.dest.name, 6)
end

-- Speeding: faster than the road's speed limit x speedLimit.TOLERANCE. The passengers complain
-- after COMPLAIN_AFTER s; after SPEEDING_FOR s it costs. Staying too fast: both again every
-- SPEEDING_AGAIN s (speedingFor goes back by that much, so it passes COMPLAIN_AFTER again).
local function watchSpeed(a, taxi, dt)
	local p = U.vecOf(taxi:getPosition())
	local roads = U.ext("careerConvoy_speedLimit")
	local limit = p and roads and roads.limitAt(p)
	if not limit or J.speedOf(taxi) <= limit * roads.TOLERANCE then
		a.speedingFor = 0
		return
	end
	local before = a.speedingFor
	a.speedingFor = before + dt
	if before < COMPLAIN_AFTER and a.speedingFor >= COMPLAIN_AFTER and a.speedingFor < SPEEDING_FOR then
		U.toast("warning", "Slow down, please!", 3)
	end
	if a.speedingFor >= SPEEDING_FOR then
		a.speeding, a.speedingFor = a.speeding + 1, a.speedingFor - SPEEDING_AGAIN
		U.toast("warning", "Too fast! Less pay.", 3)
	end
end

-- A jolt: the taxi's speed on the ground (not its direction: a tight turn is fine) or up/down
-- changed faster than JOLT_ACCEL over the last JOLT_WINDOW s.
local function watchJolts(a, taxi, dt)
	local v = type(taxi.getVelocity) == "function" and U.vecOf(taxi:getVelocity())
	if not v then
		return
	end
	local last = a.lastVel
	if not last then
		a.lastVel, a.velFor = v, 0
		return
	end
	a.velFor = (a.velFor or 0) + dt
	if a.velFor < JOLT_WINDOW then
		return
	end
	local span = a.velFor
	a.lastVel, a.velFor = v, 0
	local ground = math.abs(math.sqrt(v.x * v.x + v.y * v.y) - math.sqrt(last.x * last.x + last.y * last.y))
	local change = math.max(ground, math.abs(v.z - last.z))
	if change / span > JOLT_ACCEL and clock - a.joltAt >= JOLT_GAP then
		a.jolts, a.joltAt = a.jolts + 1, clock
		U.toast("warning", "Drive smoother!", 3)
	end
end

function M.start(a)
	a.phase, a.stillFor = "toPassenger", 0
	showFigures(a)
	U.toast("info", "Route set: pick up the passenger", 6)
end

function M.step(a, dt)
	local job = a.job
	local veh, id = myVehicle()
	if a.phase == "toPassenger" then
		showFigures(a)
		local p = veh and U.vecOf(veh:getPosition())
		local near = p and J.dist2D(p, job.pos) <= PICKUP_RADIUS and J.speedOf(veh) <= STOP_SPEED
		local seats = near and M.seatsIn(id)
		a.tooFewSeats = near and seats and seats < M.passengersOf(job) or false
		a.stillFor = near and not a.tooFewSeats and a.stillFor + dt or 0
		if a.stillFor >= BOARD_STILL then
			board(a, id)
		end
		return
	end
	local taxi = a.taxiId and be:getObjectByID(a.taxiId)
	if not taxi then
		U.log("W", "jobs", "the taxi of job " .. tostring(job.id) .. " is gone")
		U.toast("warning", "Taxi gone – pick them up again", 6)
		a.phase, a.taxiId, a.seats, a.stillFor = "toPassenger", nil, nil, 0
		showFigures(a)
		return
	end
	a.seatCheck = (a.seatCheck or 0) + dt
	if a.seatCheck >= SEAT_CHECK then
		a.seatCheck = 0
		seatPassengers(a)
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
				"job %s done: %d jolts, %d times speeding, damage %s -> %s, %d %% of the pay, %d stars",
				tostring(job.id),
				a.jolts,
				a.speeding,
				tostring(a.damageStart),
				tostring(damageOf(a.taxiId)),
				math.floor((1 - penalty) * 100 + 0.5),
				M.starsFor(penalty)
			)
		)
		local stars = M.starsFor(penalty)
		unseatPassengers(a)
		J.handOver(a, 1 - penalty, M.tipFor(stars, isVip(a)))
	end
end

function M.status(a)
	local inZone = (a.stillFor or 0) > 0
	if a.phase == "toDestination" then
		local taxi = a.taxiId and be:getObjectByID(a.taxiId)
		local taxiPos = taxi and U.vecOf(taxi:getPosition()) or nil
		local _, id = myVehicle()
		local penalty = M.penalty(a)
		if taxiPos and id ~= a.taxiId then
			return {
				step = 1,
				target = taxiPos,
				text = "back to your taxi",
				short = "Back to your taxi",
				share = 1 - penalty,
				stars = M.starsFor(penalty),
			}
		end
		return {
			step = 1,
			target = a.job.dest.pos,
			from = taxiPos,
			inZone = inZone,
			share = 1 - penalty,
			stars = M.starsFor(penalty),
			text = inZone and "In the ring – wait" or ("to " .. a.job.dest.name),
			short = inZone and "In the ring – wait" or ("Drive to " .. a.job.dest.name),
			hint = "No bumps, no speeding.",
		}
	end
	local whom = M.passengersOf(a.job) > 1 and "passengers" or "passenger"
	local hint = "Pick them up in a car."
	if a.tooFewSeats then
		hint = "Too few seats. Take a bigger car."
	elseif myVehicle() then
		hint = "Stop next to them."
	end
	return {
		step = 0,
		target = a.job.pos,
		inZone = inZone,
		text = inZone and "Wait – they get in" or ("to the " .. whom),
		short = inZone and "Wait – they get in" or ("Pick up the " .. whom),
		hint = hint,
	}
end

function M.stop(a)
	hideFigures(a)
	unseatPassengers(a)
	nextCallAt = math.max(nextCallAt, clock + CALL_AFTER_RIDE)
end

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

--== Calls (on duty) ================================================================

local function callId(jobId)
	return "taxi-" .. tostring(jobId)
end

function M.isOnDuty()
	return onDuty
end

--- The "On duty" switch: while on, rides nearby call you.
function M.setOnDuty(on)
	if on == onDuty then
		return
	end
	onDuty, missed = on, 0
	if on then
		nextCallAt = clock + CALL_FIRST
		U.toast("info", "On duty: rides will call you", 4)
	else
		local phone = U.ext("careerConvoy_phone")
		if calling and phone then
			phone.hangUp(callId(calling))
		end
		calling = nil
		U.toast("info", "Off duty", 3)
	end
end

local function distText(m)
	return m < 1000 and string.format("%d m", math.floor(m / 10 + 0.5) * 10) or string.format("%.1f km", m / 1000)
end

-- The nearest ride you could take now that hasn't called before, within CALL_RANGE m, with no
-- more passengers than `seats` (nil: the vehicle can't be counted – rides for one only), or nil.
local function rideToCall(me, seats)
	local best, bestD = nil, CALL_RANGE
	for _, job in ipairs(J.openJobsOf(M.id)) do
		local p = type(job.pos) == "table" and U.vecOf(job.pos)
		local d = p and J.dist2D(me, p)
		if d and d <= bestD and not declined[job.id] and M.passengersOf(job) <= (seats or 1) then
			best, bestD = job, d
		end
	end
	return best, bestD
end

-- How a call ended: taken, declined or missed.
local function answered(job, accepted, wasMissed)
	calling = nil
	if accepted then
		missed = 0
		J.uiTake(job.id)
		return
	end
	declined[job.id] = true
	nextCallAt = clock + CALL_PAUSE
	missed = wasMissed and missed + 1 or 0
	if missed >= MISSED_MAX then
		onDuty, missed = false, 0
		U.toast("warning", "Off duty: calls missed", 5)
		J.refreshApp()
	end
end

-- A look for a ride to call about (every CALL_CHECK s while on duty).
local function checkCalls()
	local phone = U.ext("careerConvoy_phone")
	if calling then
		-- the ride is gone (someone else took it), or you took a job yourself: hang up
		local stillOpen = false
		for _, job in ipairs(J.openJobsOf(M.id)) do
			stillOpen = stillOpen or job.id == calling
		end
		if not stillOpen or J.getActive() then
			phone.hangUp(callId(calling))
			calling = nil
			nextCallAt = clock + CALL_CHECK
		end
		return
	end
	local lic = U.ext("careerConvoy_licenses")
	if clock < nextCallAt or J.getActive() or not U.careerActive() or not (lic and lic.has("taxi")) then
		return
	end
	local veh, id = myVehicle()
	local me = veh and U.vecOf(veh:getPosition())
	if not me then
		return
	end
	local job, d = rideToCall(me, M.seatsIn(id))
	if not job then
		return
	end
	local n = M.passengersOf(job)
	local dest = tostring(job.dest and job.dest.name or "?")
	local rang = phone
		and phone.ring({
			id = callId(job.id),
			title = "Ride request",
			text = (n > 1 and n .. " people" or "1 person") .. " to " .. dest,
			detail = distText(d) .. " away · $" .. math.floor(tonumber(job.pay) or 0),
			icon = M.icon,
			open = { app = "jobs", page = M.id },
			onAnswer = function(accepted, wasMissed)
				answered(job, accepted, wasMissed)
			end,
		})
	if rang then
		calling = job.id
	end
end

--== Hooks =======================================================================

function M.onUpdate(dtReal)
	local dt = tonumber(dtReal) or 0
	clock = clock + dt
	if not onDuty then
		return
	end
	sinceCallCheck = sinceCallCheck + dt
	if sinceCallCheck >= CALL_CHECK then
		sinceCallCheck = 0
		local ok, err = pcall(checkCalls)
		if not ok then
			U.log("E", "jobs", "taxi call failed: " .. tostring(err))
		end
	end
end

function M.onBeamMPServerLeave()
	onDuty, calling, missed, declined = false, nil, 0, {}
end

function M.onExtensionLoaded()
	U = extensions.careerConvoy_util
	J = extensions.careerConvoy_jobs
	J.registerType(M)
end

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
