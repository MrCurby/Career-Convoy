-- SharedCareer :: towing jobs: broken-down cars at the roadside, towed to a repair shop
--
-- A job type of the Jobs app (jobs.lua: the shared list, taking, giving up, the pay). This file
-- brings what a towing job is about:
--   making one up (generate), by tier (TIERS: the higher, the harder and the better paid)
--     a place     a random road node far from every vehicle, moved off the road onto the
--                 roadside (ROADSIDE m beyond the road's edge, the side that is free), standing
--                 along the road. A side is free when nothing stands between the road and the spot
--                 (a tunnel wall, a rock: a ray at car height) and there is ground at about the
--                 road's height (GROUND_STEP); a node without a free side isn't used. Without that
--                 check a spot in a tunnel wall made the game put the car under the tunnel
--     a vehicle   by the tier's heavy share a heavy vehicle (HEAVY_MODELS), else an old one from
--                 the career's own delivery filter (gameplay/delivery/vehicles.deliveryVehicles.json,
--                 JUNKER_FILTER) via util_configListGenerator; a pickup, van, bus or truck from it is
--                 drawn again (up to CAR_TRIES times) unless the tier's truck share lets it stay; a
--                 few common cars if that is missing. The higher the tier, the more trucks
--     a shop      a garage of the map (freeroam_facilities, the middle of its doors), as far away
--                 as the tier says in a straight line (the nearest fit if none is)
--     the pay     (PAY_BASE + PAY_PER_KM per km of the tow (by road: jobs.driveDistance; the
--                 straight line x ROAD_FACTOR where there is no way by road)) x the
--                 tier's pay, x PAY_FLAT with a flat tire, x client.jobPay
--     faults     what is broken (FAULTS: engine, clutch, gearbox, radiator, oil pan, windshield,
--                tail lights), each by its chance, at least one; a crash always has a broken engine
--     a crash    from tier 2 on, some jobs are crashes (the tier's crash chance) instead of a
--                breakdown: the car is wrecked (see "Crashes" below)
--     its kind    car, suv, pickup, van, bus or truck (KINDS, from the game's "Body Style", else its
--                 "Type"): the icon of the job in the Jobs app (iconOf)
--     job.data = {vehicle = {model, config}, kind, flatTire, heavy, crash = {kind, speed}, faults, dir};
--     job.title = the vehicle's body style (model, else config), else its name
--   doing it
--     1. the route leads to the place; within SPAWN_RANGE m the broken-down vehicle appears there
--        (spawned by this player, so it is theirs: the rope works on it, BeamMP shows it to
--        everyone). The vehicle breaks down: neutral, parking brake on, hazard lights on, a flat
--        tire and its faults if the job says so (sharedCareerVeh.jobBreakDown). A reset
--        (R) repairs it, so the job breaks it down again
--     2. near the vehicle the route switches to the repair shop, and a broken radiator's engine
--        that was kept hot so it steams from afar may cool down (sharedCareerVeh.jobCoolDown)
--     3. standing still in the drop-off zone (DROP_RADIUS m around the shop's doors) for
--        DROP_STILL s, nobody inside: handed over (jobs.handOver). New damage since the breakdown
--        costs up to PENALTY_MAX of the pay (DAMAGE_FOR_MAX damage points cost all of it)
--     Crashes: the car is spawned in the air, tilted the way the crash kind says (CRASHES: nose,
--     tail, side, corner or roof first), and falls onto the roadside: it hits the ground at the
--     crash's speed (the height is worked out from it), so the game's own physics bends it like a
--     real crash. It is spawned without the game's safe spawn, which would put it on its wheels on
--     the ground. Only once it lies still (CRASH_STILL s) does it break down, so the crash doesn't
--     count as new damage against the pay. If it landed too far away (rolled down a slope, fell
--     through the ground), it is removed and comes back as a plain breakdown. BeamMP shows the fall
--     to the others.
--     When the job ends (paid, given up, taken away), the vehicle is removed. A vehicle that
--     vanished (deleted, reloaded, or refused by the server's vehicle limit) appears again at its
--     place when you come near, at most every SPAWN_RETRY s.
--   What you see: a marker above the broken-down vehicle while you drive there, and the drop-off
--   zone (a flat ring with a sign) near the repair shop while you tow.

local M = {}

local U, J

local SPAWN_RANGE = 400 -- m: the broken-down vehicle appears when you are this close
local FAR_FROM_VEHICLES = 350 -- m: a new job is never made up closer to any vehicle
local DEST_NEAREST = 400 -- m: a shop at least this far away when none fits the tier
local MIN_ROAD_RADIUS = 2.5 -- m: half the width of a road the place may be on
local MIN_DRIVABILITY = 0.6 -- the road must be a normal road (not a dirt track)
local ROADSIDE = 1.8 -- m beyond the road's edge
local SIDE_CLEAR = 1.2 -- m free beyond the spot (half a car's width)
local GROUND_STEP = 1.5 -- m the roadside's ground may be above or below the road
local RAY_HEIGHT = 1 -- m above the road the rays start (above curbs, below a tunnel's roof)
local PLACE_TRIES = 40
local NEAR_VEHICLE = 30 -- m: close enough to the vehicle, the route goes to the shop
local DROP_RADIUS = 14 -- m around the middle of the shop's doors
local DROP_STILL = 3 -- s standing still in the drop-off zone
local DROP_SPEED = 0.5 -- m/s: slower counts as standing still
local DAMAGE_WAIT = 3 -- s for the vehicle's damage report; then no deduction
local PAY_BASE, PAY_PER_KM = 150, 120
local PAY_FLAT = 1.25
local ROAD_FACTOR = 1.3 -- without a way by road: roads are about this much longer than the straight line
-- the tiers: how far to the shop (m), how often a flat tire, how often a heavy vehicle, how often a
-- truck may come from the delivery filter otherwise, the pay; how often a crash, and its speed (m/s
-- when it hits the ground)
local TIERS = {
	{ destMin = 800, destMax = 2500, flatTire = 0.1, heavy = 0, trucks = 0, pay = 1, crash = 0 },
	{
		destMin = 1500,
		destMax = 4000,
		flatTire = 0.2,
		heavy = 0,
		trucks = 0.2,
		pay = 1.3,
		crash = 0.3,
		crashSpeed = { 6, 9 },
	},
	{
		destMin = 2500,
		destMax = 6000,
		flatTire = 0.3,
		heavy = 0.5,
		trucks = 0.4,
		pay = 1.7,
		crash = 0.5,
		crashSpeed = { 8, 12 },
	},
	{
		destMin = 3500,
		destMax = 8000,
		flatTire = 0.5,
		heavy = 0.7,
		trucks = 0.6,
		pay = 2.2,
		crash = 0.7,
		crashSpeed = { 10, 14 },
	},
}
-- the kinds of crash: how the car is tilted when it falls (pitch: nose down, roll: to the right, in
-- degrees), how much of the tier's speed (a car on its roof crushes at less), and its tag
local CRASHES = {
	{ kind = "front", pitch = 70, roll = 0, speed = 1, tag = "Crash" },
	{ kind = "rear", pitch = -70, roll = 0, speed = 1, tag = "Crash" },
	{ kind = "side", pitch = 0, roll = 80, speed = 0.8, tag = "Crash" },
	{ kind = "corner", pitch = 45, roll = 45, speed = 1, tag = "Crash" },
	{ kind = "roof", pitch = 0, roll = 180, speed = 0.5, tag = "On its roof" },
}

-- what can be broken on a broken-down car (not a crash): how often, and its tag; at least one always is
local FAULTS = {
	{ kind = "engine", chance = 0.1, tag = "Engine failure" },
	{ kind = "clutch", chance = 0.15, tag = "Broken clutch" },
	{ kind = "gearbox", chance = 0.15, tag = "Broken gearbox" },
	{ kind = "radiator", chance = 0.15, tag = "Broken radiator" },
	{ kind = "oilpan", chance = 0.2, tag = "Oil leak" },
	{ kind = "windshield", chance = 0.7, tag = "Broken windshield" },
	{ kind = "taillights", chance = 0.3, tag = "Broken taillights" },
}

local CRASH_CLEAR = 3 -- m above the ground the car's middle is at least (a tilted car is tall)
local CRASH_STILL = 2 -- s lying still: the crash is over
local CRASH_WAIT = 15 -- s at most for that; then it counts as over
local CRASH_DRIFT = 20 -- m: landed farther from its place than this, it comes back as a breakdown
local PENALTY_MAX = 0.5 -- share of the pay new damage can cost at most
local DAMAGE_FOR_MAX = 40000 -- damage points (beamstate.damage) that cost PENALTY_MAX
local BREAKDOWN_RETRY = 3 -- s without the vehicle's answer: break it down again
local SPAWN_RETRY = 10 -- s before a vehicle that vanished right away is spawned again
local MARKER_RANGE = 250 -- m: the markers show within this distance

local JUNKER_FILTER = "junkerVehFilter"
local FILTER_FILE = "gameplay/delivery/vehicles.deliveryVehicles.json"
local FALLBACK_MODELS = { "fullsize", "midsize", "covet", "pessima" }
local HEAVY_MODELS =
	{ { model = "pickup", kind = "pickup" }, { model = "van", kind = "van" }, { model = "roamer", kind = "suv" } }
local CAR_TRIES = 8 -- draws from the delivery filter for a vehicle that isn't a truck
-- the kinds of vehicle (each an icon in the Jobs app), by the words in the game's "Body Style" (else
-- its "Type") that make it one, the first that fits; none fits: a car. truck: counts as a truck
-- for the tier's truck share
local KINDS = {
	{ kind = "bus", words = { "bus" }, truck = true },
	{ kind = "van", words = { "van" }, truck = true },
	{ kind = "pickup", words = { "pickup" }, truck = true },
	{ kind = "suv", words = { "suv", "crossover" } },
	{ kind = "truck", words = { "truck" }, truck = true },
}

M.id = "tow"
M.name = "Towing"
M.icon = "tow"
M.branch = "commercial"
M.steps = { "Pick up", "Tow", "Paid" }

local clock = 0
local roadNodes = nil -- {level, names} road nodes a job may be placed at
local current = nil -- the towing job that is yours (jobs.lua's job state), for the
-- vehicle's replies: + vehId, spawnedAt, brokenDown, sentAt,
-- damageStart, phase, stillFor, checkingSince, damageNow

--== Making up a job =============================================================

-- road nodes a broken-down car may stand at: wide enough, on a normal road (cached per map)
local function candidateNodes(nodes)
	local level = type(getCurrentLevelIdentifier) == "function" and getCurrentLevelIdentifier() or ""
	if roadNodes and roadNodes.level == level then
		return roadNodes.names
	end
	local names = {}
	for name, n in pairs(nodes) do
		if
			type(n) == "table"
			and n.pos
			and (tonumber(n.radius) or 0) >= MIN_ROAD_RADIUS
			and type(n.links) == "table"
		then
			for _, link in pairs(n.links) do
				if type(link) == "table" and (tonumber(link.drivability) or 0) >= MIN_DRIVABILITY then
					table.insert(names, name)
					break
				end
			end
		end
	end
	table.sort(names, function(a, b)
		return tostring(a) < tostring(b)
	end) -- the same order on every PC
	roadNodes = { level = level, names = names }
	return names
end

-- The spot `side` m from the road point `p` towards `out` (x, y, length 1) with its ground, or nil
-- when something stands in the way or there is no ground at about the road's height.
local function freeSpot(p, out, side)
	local from = vec3(p.x, p.y, p.z + RAY_HEIGHT)
	if U.castRay(from, vec3(out.x, out.y, 0), side + SIDE_CLEAR) then
		return nil
	end
	local pos = { x = p.x + out.x * side, y = p.y + out.y * side, z = p.z }
	local hit = U.castRay(vec3(pos.x, pos.y, p.z + RAY_HEIGHT), vec3(0, 0, -1), RAY_HEIGHT + GROUND_STEP)
	if not hit then
		return nil
	end
	pos.z = p.z + RAY_HEIGHT - hit
	return pos
end

-- Where on the roadside of this node a car can stand: {pos, dir} or nil. The right side of the
-- road first, else the left.
local function roadside(nodes, name)
	local n = nodes[name]
	local p = n and J.vecOf(n.pos)
	if not p then
		return nil
	end
	for other, link in pairs(n.links) do
		local q = type(link) == "table"
			and (tonumber(link.drivability) or 0) >= MIN_DRIVABILITY
			and nodes[other]
			and J.vecOf(nodes[other].pos)
		if q then
			local dx, dy = q.x - p.x, q.y - p.y
			local len = math.sqrt(dx * dx + dy * dy)
			if len > 1 then
				dx, dy = dx / len, dy / len
				local side = tonumber(n.radius) + ROADSIDE
				for _, s in ipairs({ 1, -1 }) do
					local pos = freeSpot(p, { x = dy * s, y = -dx * s }, side)
					if pos then
						return { pos = pos, dir = { x = dx * s, y = dy * s } }
					end
				end
				return nil
			end
		end
	end
	return nil
end

local function vehiclePositions()
	local out = {}
	local count = type(be.getObjectCount) == "function" and be:getObjectCount() or 0
	for i = 0, count - 1 do
		local veh = be:getObject(i)
		local p = veh and type(veh.getPosition) == "function" and J.vecOf(veh:getPosition())
		if p then
			table.insert(out, p)
		end
	end
	return out
end

-- The repair shops the vehicle can go to: the map's garages (dealerships if there are none).
local function repairShops()
	local data = U.facilities()
	if not data then
		return {}
	end
	local shops = {}
	for _, kind in ipairs({ "garages", "dealerships" }) do
		for _, fac in pairs(type(data[kind]) == "table" and data[kind] or {}) do
			local p = type(fac) == "table" and U.facilityDoor(fac)
			if p then
				table.insert(shops, {
					name = U.translate(fac.name) or (type(fac.name) == "string" and fac.name) or tostring(fac.id),
					pos = p,
				})
			end
		end
		if #shops > 0 then
			break
		end
	end
	return shops
end

-- The game's info of a model: {model = {Name, Brand, Type, ["Body Style"], ...}, configs = {...}},
-- or nil.
local function modelInfo(model)
	if not (core_vehicles and type(core_vehicles.getModel) == "function") then
		return nil
	end
	local ok, data = pcall(core_vehicles.getModel, model)
	return ok and type(data) == "table" and type(data.model) == "table" and data or nil
end

local function modelName(model)
	local m = modelInfo(model)
	if m and m.model.Name then
		return (m.model.Brand and (m.model.Brand .. " ") or "") .. m.model.Name
	end
	return (model:gsub("^%l", string.upper))
end

-- The body style of a vehicle ("Sedan", "Pickup", ...): its model's, else its config's; or nil.
local function bodyStyle(vehicle)
	local m = modelInfo(vehicle.model)
	if not m then
		return nil
	end
	local c = vehicle.config and type(m.configs) == "table" and m.configs[vehicle.config]
	return type(m.model["Body Style"]) == "string" and m.model["Body Style"]
		or (type(c) == "table" and type(c["Body Style"]) == "string" and c["Body Style"])
		or nil
end

local function kindOf(kind)
	for _, k in ipairs(KINDS) do
		if k.kind == kind then
			return k
		end
	end
	return nil
end

--- The kind of a vehicle ("car", "pickup", ... see KINDS): from its config's info, else its model's;
--- its body style first, else its type.
function M.vehicleKind(model, info)
	local function has(t)
		return type(t) == "table" and (type(t["Body Style"]) == "string" or type(t.Type) == "string")
	end
	if not has(info) then
		local m = modelInfo(model)
		info = m and m.model
	end
	if not has(info) then
		return "car"
	end
	for _, field in ipairs({ "Body Style", "Type" }) do
		local text = tostring(info[field] or ""):lower()
		for _, k in ipairs(KINDS) do
			for _, w in ipairs(k.words) do
				if text:find(w, 1, true) then
					return k.kind
				end
			end
		end
	end
	return "car"
end

-- One old vehicle from the career's delivery filter: {model, config, name, kind}, or nil.
local function fromFilter()
	local gen = rawget(_G, "util_configListGenerator")
	if not (gen and type(gen.getRandomVehicleInfos) == "function" and type(jsonReadFile) == "function") then
		return nil
	end
	local ok, info = pcall(function()
		local filters = jsonReadFile(FILTER_FILE)
		local filter = type(filters) == "table" and filters[JUNKER_FILTER]
		if not filter then
			return nil
		end
		local eligible = type(gen.getEligibleVehicles) == "function" and gen.getEligibleVehicles(false, false) or nil
		local infos = gen.getRandomVehicleInfos(filter, 1, eligible)
		return infos and infos[1]
	end)
	if not ok or type(info) ~= "table" or not info.model_key then
		return nil
	end
	local name = info.Name and ((info.Brand and (info.Brand .. " ") or "") .. info.Name) or info.model_key
	return { model = info.model_key, config = info.key, name = name, kind = M.vehicleKind(info.model_key, info) }
end

-- The vehicle of a tier: a heavy one by its heavy share, else an old one from the delivery filter,
-- a truck only as often as its truck share allows: {model, config, name, kind, heavy}.
local function pickVehicle(t)
	if math.random() < (t.heavy or 0) then
		local h = HEAVY_MODELS[math.random(#HEAVY_MODELS)]
		return { model = h.model, name = modelName(h.model), kind = h.kind, heavy = true }
	end
	local truckOk = math.random() < (t.trucks or 0)
	for _ = 1, CAR_TRIES do
		local v = fromFilter()
		if not v then
			break
		end
		local kind = kindOf(v.kind)
		if truckOk or not (kind and kind.truck) then
			return v
		end
	end
	local model = FALLBACK_MODELS[math.random(#FALLBACK_MODELS)]
	return { model = model, name = modelName(model), kind = M.vehicleKind(model) }
end

local function roundTo(x, step)
	return math.floor(x / step + 0.5) * step
end

local function tierOf(tier)
	return TIERS[math.max(1, math.min(#TIERS, tonumber(tier) or 1))]
end

local function crashOf(kind)
	for _, c in ipairs(CRASHES) do
		if c.kind == kind then
			return c
		end
	end
	return nil
end

-- A crash for a job of this tier, or nil for a breakdown: {kind, speed (m/s when it hits the ground)}.
local function pickCrash(t)
	if not t.crashSpeed or math.random() >= t.crash then
		return nil
	end
	local c = CRASHES[math.random(#CRASHES)]
	local lo, hi = t.crashSpeed[1], t.crashSpeed[2]
	return { kind = c.kind, speed = math.floor((lo + math.random() * (hi - lo)) * c.speed * 10 + 0.5) / 10 }
end

local function faultOf(kind)
	for _, f in ipairs(FAULTS) do
		if f.kind == kind then
			return f
		end
	end
	return nil
end

-- What is broken on a broken-down car: each fault by its chance, at least one ({"clutch", ...}).
local function pickFaults()
	local faults = {}
	for _, f in ipairs(FAULTS) do
		if math.random() < f.chance then
			table.insert(faults, f.kind)
		end
	end
	if #faults == 0 then
		table.insert(faults, FAULTS[math.random(#FAULTS)].kind)
	end
	return faults
end

--- The pay for a tow of `length` m at level 1 (a flat tire and a higher tier pay more).
function M.payFor(length, flatTire, tier)
	local pay = (PAY_BASE + PAY_PER_KM * length / 1000)
		* tierOf(tier).pay
		* (flatTire and PAY_FLAT or 1)
		* J.payFactor()
	return roundTo(pay, 10)
end

--- Makes up a towing job of a tier on this map, or returns nil and why not.
function M.generate(tier)
	local t = tierOf(tier)
	local nodes = map and type(map.getMap) == "function" and map.getMap().nodes
	if type(nodes) ~= "table" then
		return nil, "no road network"
	end
	local shops = repairShops()
	if #shops == 0 then
		return nil, "no repair shops on this map"
	end
	local names = candidateNodes(nodes)
	if #names == 0 then
		return nil, "no roads for a breakdown"
	end
	local others = vehiclePositions()
	for _ = 1, PLACE_TRIES do
		local spot = roadside(nodes, names[math.random(#names)])
		local free = spot ~= nil
		for _, p in ipairs(free and others or {}) do
			if J.dist2D(p, spot.pos) < FAR_FROM_VEHICLES then
				free = false
				break
			end
		end
		if free then
			-- a shop as far away as the tier says; on a small map the one nearest to that
			local fitting, nearest, miss = {}, nil, math.huge
			for _, shop in ipairs(shops) do
				local d = J.dist2D(shop.pos, spot.pos)
				if d >= t.destMin and d <= t.destMax then
					table.insert(fitting, { shop = shop, d = d })
				end
				local off = d < t.destMin and t.destMin - d or math.max(0, d - t.destMax)
				if d >= DEST_NEAREST and off < miss then
					nearest, miss = { shop = shop, d = d }, off
				end
			end
			local pick = #fitting > 0 and fitting[math.random(#fitting)] or nearest
			if pick then
				local length = roundTo(J.driveDistance(spot.pos, pick.shop.pos) or pick.d * ROAD_FACTOR, 10)
				local flatTire = math.random() < t.flatTire
				local vehicle = pickVehicle(t)
				local crash = pickCrash(t)
				local faults = crash and { "engine" } or pickFaults()
				return {
					title = bodyStyle(vehicle) or vehicle.name,
					pos = spot.pos,
					dest = { name = pick.shop.name, pos = pick.shop.pos },
					length = length,
					pay = M.payFor(length, flatTire, tier),
					data = {
						vehicle = { model = vehicle.model, config = vehicle.config },
						kind = vehicle.kind,
						flatTire = flatTire,
						heavy = vehicle.heavy == true,
						crash = crash,
						faults = faults,
						dir = spot.dir,
					},
				}
			end
		end
	end
	return nil, "no free place found"
end

--- The icon of a towing job in the Jobs app: the kind of its vehicle ("car", "pickup", ...); nil for
--- a job without one (then the job type's icon).
function M.iconOf(job)
	local kind = type(job.data) == "table" and job.data.kind
	return (kind == "car" or kindOf(kind)) and kind or nil
end

--- The labels of a towing job in the Jobs app.
function M.tags(job)
	local d = type(job.data) == "table" and job.data or {}
	local crash = type(d.crash) == "table" and crashOf(d.crash.kind)
	local tags = {}

	if crash then
		table.insert(tags, { text = crash.tag, kind = "crash" })
	else
		for _, f in ipairs(type(d.faults) == "table" and d.faults or {}) do
			local fault = faultOf(f)
			if fault then
				table.insert(tags, { text = fault.tag, kind = fault.kind })
			end
		end
	end

	if d.flatTire == true then
		table.insert(tags, { text = "Flat tire", kind = "tire" })
	end
	if d.heavy == true then
		table.insert(tags, { text = "Heavy", kind = "heavy" })
	end
	return tags
end

--== Doing it ======================================================================

local function data(a)
	return type(a.job.data) == "table" and a.job.data or {}
end

local function removeVehicle(a)
	local veh = a.vehId and be:getObjectByID(a.vehId)
	if veh then
		pcall(function()
			veh:delete()
		end)
	end
end

local function breakDown(a)
	a.brokenDown, a.sentAt = false, clock

	local faults = {}
	for _, kind in ipairs(type(data(a).faults) == "table" and data(a).faults or {}) do
		if faultOf(kind) then
			table.insert(faults, kind .. " = true")
		end
	end

	local cmd = string.format(
		"sharedCareerVeh.jobBreakDown(%s, {%s})",
		tostring(data(a).flatTire == true),
		table.concat(faults, ", ")
	)
	if a.phase == "toDestination" then
		cmd = cmd .. "; sharedCareerVeh.jobCoolDown()" -- the player is there already
	end
	J.sendToVehicle(a.vehId, cmd)
end

-- The way the car faces: forward along the road, tilted for a crash (pitch: nose down, roll: to
-- the right, in degrees). Returns forward and up as {x, y, z}.
local function facing(dir, pitch, roll)
	local len = math.sqrt(dir.x * dir.x + dir.y * dir.y)
	local f = len > 0.01 and { x = dir.x / len, y = dir.y / len, z = 0 } or { x = 0, y = 1, z = 0 }
	local r = { x = f.y, y = -f.x, z = 0 } -- right of forward, with up = z
	local p, q = math.rad(pitch or 0), math.rad(roll or 0)
	local fwd = { x = f.x * math.cos(p), y = f.y * math.cos(p), z = -math.sin(p) }
	local up = { x = f.x * math.sin(p), y = f.y * math.sin(p), z = math.cos(p) }
	up = {
		x = up.x * math.cos(q) + r.x * math.sin(q),
		y = up.y * math.cos(q) + r.y * math.sin(q),
		z = up.z * math.cos(q),
	}
	return fwd, up
end

-- The crash this vehicle falls into, or nil (a breakdown, or a crash that went wrong before).
local function crashFor(a)
	local c = data(a).crash
	if a.crashFailed or type(c) ~= "table" or not crashOf(c.kind) then
		return nil
	end
	return crashOf(c.kind), math.max(1, tonumber(c.speed) or 8)
end

local function spawnVehicle(a)
	local job, d = a.job, data(a)
	local vehicle = type(d.vehicle) == "table" and d.vehicle or {}
	if not (core_vehicles and type(core_vehicles.spawnNewVehicle) == "function") or type(vehicle.model) ~= "string" then
		return
	end
	local crash, speed = crashFor(a)
	local fwd, up = facing(
		type(d.dir) == "table" and { x = tonumber(d.dir.x) or 0, y = tonumber(d.dir.y) or 1 } or { x = 0, y = 1 },
		crash and crash.pitch,
		crash and crash.roll
	)
	-- a crash falls from the height that makes it hit the ground at its speed: v^2 / 2g
	local height = crash and (CRASH_CLEAR + speed * speed / (2 * 9.81)) or 0
	-- a crash: no safe spawn, else the game (spawn.setSafePosition) turns a car on its roof back
	-- onto its wheels and puts it on the ground, so it doesn't fall and isn't bent
	local options = {
		pos = vec3(job.pos.x, job.pos.y, job.pos.z + height),
		autoEnterVehicle = false,
		cling = not crash,
		safeSpawn = not crash,
		config = vehicle.config,
	}
	if type(quatFromDir) == "function" then
		options.rot = quatFromDir(vec3(fwd.x, fwd.y, fwd.z), vec3(up.x, up.y, up.z))
	end
	local ok, veh = pcall(core_vehicles.spawnNewVehicle, vehicle.model, options)
	if not ok or not veh then
		U.log("E", "jobs", "could not spawn the broken-down vehicle: " .. tostring(veh))
		return
	end
	a.vehId, a.spawnedAt = veh:getID(), clock
	U.log(
		"I",
		"jobs",
		string.format(
			"job %s: %s spawned (%s)%s",
			tostring(job.id),
			job.title,
			tostring(a.vehId),
			crash and string.format(", crash %s at %.1f m/s", crash.kind, speed) or ""
		)
	)
	if crash then
		a.crashing, a.stillFor = { since = clock, still = 0 }, 0
	else
		breakDown(a)
	end
end

-- While the crashed car falls and settles: once it lies still it breaks down (the crash is not new
-- damage against the pay). Landed too far away: removed, it comes back as a plain breakdown.
local function settle(a, veh, dt)
	local p, v = J.vecOf(veh:getPosition()), type(veh.getVelocity) == "function" and J.vecOf(veh:getVelocity())
	local speed = v and math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) or 0
	a.crashing.still = speed <= DROP_SPEED and a.crashing.still + dt or 0
	if a.crashing.still < CRASH_STILL and clock - a.crashing.since < CRASH_WAIT then
		return
	end
	a.crashing = nil
	local pos = a.job.pos
	if not p or J.dist2D(p, pos) > CRASH_DRIFT or p.z < pos.z - 5 then
		U.log(
			"W",
			"jobs",
			"job " .. tostring(a.job.id) .. ": the crashed car landed too far away – a breakdown instead"
		)
		removeVehicle(a)
		a.vehId, a.crashFailed = nil, true
		a.spawnedAt = clock - SPAWN_RETRY -- spawned again at once
		return
	end
	breakDown(a)
end

-- Handed over: new damage since the breakdown costs part of the pay.
local function finish(a)
	local penalty = 0
	if a.damageNow and a.damageStart then
		penalty = math.min(PENALTY_MAX, math.max(0, a.damageNow - a.damageStart) / DAMAGE_FOR_MAX * PENALTY_MAX)
	end
	U.log(
		"I",
		"jobs",
		string.format(
			"job %s done: damage %s -> %s, %d %% of the pay",
			tostring(a.job.id),
			tostring(a.damageStart),
			tostring(a.damageNow),
			math.floor((1 - penalty) * 100 + 0.5)
		)
	)
	J.handOver(a, 1 - penalty)
end

function M.start(a)
	a.phase, a.stillFor = "toVehicle", 0
	current = a
	U.toast("info", "Route set: drive to the " .. a.job.title, 6)
end

function M.step(a, dt)
	local job = a.job
	local me = J.myPosition()
	local veh = a.vehId and be:getObjectByID(a.vehId)
	if a.vehId and not veh then
		-- deleted, reloaded or refused by the server: it appears again at its place
		U.log("W", "jobs", "the vehicle of job " .. tostring(job.id) .. " is gone")
		if clock - (a.spawnedAt or -math.huge) < 2 then
			U.toast("warning", "Car removed – vehicle limit reached?", 6)
		end
		a.vehId, a.brokenDown = nil, false
		a.phase = "toVehicle"
	end
	if not veh then
		local waited = clock - (a.spawnedAt or -math.huge) >= SPAWN_RETRY
		if waited and me and J.dist2D(me, job.pos) <= SPAWN_RANGE then
			spawnVehicle(a)
		end
		return
	end
	if a.crashing then
		settle(a, veh, dt)
		return
	end
	if not a.brokenDown and clock - a.sentAt >= BREAKDOWN_RETRY then
		breakDown(a)
	end
	local p = J.vecOf(veh:getPosition())
	if a.phase == "toVehicle" and me and p and J.dist2D(me, p) <= NEAR_VEHICLE then
		a.phase = "toDestination"
		J.sendToVehicle(a.vehId, "sharedCareerVeh.jobCoolDown()")
		U.toast("info", "Route set: tow it to " .. job.dest.name, 6)
	end
	local speed = 0
	if type(veh.getVelocity) == "function" then
		local v = J.vecOf(veh:getVelocity())
		if v then
			speed = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
		end
	end
	local inZone = p
		and J.dist2D(p, job.dest.pos) <= DROP_RADIUS
		and speed <= DROP_SPEED
		and be:getPlayerVehicleID(0) ~= a.vehId
	if a.checkingSince then
		if a.damageNow or clock - a.checkingSince >= DAMAGE_WAIT then
			finish(a)
		end
	elseif inZone then
		a.stillFor = a.stillFor + dt
		if a.stillFor >= DROP_STILL then
			a.checkingSince, a.damageNow = clock, nil
			J.sendToVehicle(a.vehId, "sharedCareerVeh.jobReportDamage()")
		end
	else
		a.stillFor = 0
	end
end

function M.status(a)
	local inZone = (a.stillFor or 0) > 0
	if a.phase == "toDestination" then
		local veh = a.vehId and be:getObjectByID(a.vehId)
		return {
			step = 1,
			target = a.job.dest.pos,
			from = veh and J.vecOf(veh:getPosition()) or nil,
			inZone = inZone,
			text = inZone and "In the ring – wait" or ("to " .. a.job.dest.name),
			short = inZone and "In the ring – wait" or ("Tow to " .. a.job.dest.name),
			hint = "Damage costs pay. Park it in the ring at the shop.",
		}
	end
	return {
		step = 0,
		target = a.job.pos,
		text = "to the " .. a.job.title,
		short = "Drive to the breakdown",
		hint = "Damage costs pay. Park it in the ring at the shop.",
	}
end

function M.stop(a)
	removeVehicle(a)
	if current == a then
		current = nil
	end
end

-- the reset (R) repairs the broken-down vehicle: break it down again
function M.vehicleReset(a, id)
	if a.vehId == id then
		breakDown(a)
	end
end

--== Replies from the vehicle ======================================================

function M.onJobBrokenDown(vehId, damage)
	if not current or current.vehId ~= vehId then
		return
	end
	current.brokenDown = true
	current.damageStart = tonumber(damage) or 0
end

function M.onJobDamage(vehId, damage)
	if not current or current.vehId ~= vehId then
		return
	end
	current.damageNow = tonumber(damage) or 0
end

--== Drawing ======================================================================

function M.draw(a)
	if not (debugDrawer and ColorF and vec3) then
		return
	end
	local me = J.myPosition()
	if not me then
		return
	end
	if a.phase == "toVehicle" then
		local veh = a.vehId and be:getObjectByID(a.vehId)
		local p = veh and J.vecOf(veh:getPosition()) or a.job.pos
		if J.dist2D(me, p) <= MARKER_RANGE then
			local bob = 0.15 * math.sin(clock * 2.5)
			local top = vec3(p.x, p.y, p.z + 3.2 + bob)
			debugDrawer:drawSphere(top, 0.35, ColorF(1, 0.6, 0.1, 0.85))
			debugDrawer:drawCylinder(
				vec3(p.x, p.y, p.z + 2.3 + bob),
				vec3(p.x, p.y, p.z + 2.85 + bob),
				0.06,
				ColorF(1, 0.6, 0.1, 0.85)
			)
		end
	elseif a.phase == "toDestination" then
		local d = a.job.dest.pos
		if J.dist2D(me, d) <= MARKER_RANGE then
			local inZone = (a.stillFor or 0) > 0
			local r, g, b = 0.25, 0.55, 1
			if inZone then
				r, g, b = 0.3, 0.9, 0.45
			end
			debugDrawer:drawCylinder(
				vec3(d.x, d.y, d.z + 0.02),
				vec3(d.x, d.y, d.z + 0.08),
				DROP_RADIUS,
				ColorF(r, g, b, 0.18)
			)
			debugDrawer:drawCylinder(vec3(d.x, d.y, d.z), vec3(d.x, d.y, d.z + 4), 0.08, ColorF(r, g, b, 0.7))
			local label = inZone
					and string.format("Drop-off \194\183 %d s", math.max(1, math.ceil(DROP_STILL - (a.stillFor or 0))))
				or ("Drop-off \194\183 " .. a.job.dest.name)
			local str = String and String(label) or label
			debugDrawer:drawTextAdvanced(
				vec3(d.x, d.y, d.z + 4.4),
				str,
				ColorF(1, 1, 1, 1),
				true,
				false,
				ColorI(20, 30, 50, 200)
			)
		end
	end
end

--== Hooks =======================================================================

function M.onUpdate(dtReal)
	clock = clock + (tonumber(dtReal) or 0)
end

function M.onBeamMPServerLeave()
	current, roadNodes = nil, nil
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
