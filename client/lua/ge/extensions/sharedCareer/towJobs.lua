-- SharedCareer :: towing jobs: broken-down cars at the roadside, towed to a repair shop
--
-- A job type of the Jobs app (jobs.lua: the shared list, taking, giving up, the pay). This file
-- brings what a towing job is about:
--   making one up (generate), by tier (TIERS: the higher, the harder and the better paid)
--     a place     a random road node far from every vehicle, moved off the road onto the
--                 roadside (ROADSIDE m beyond the road's edge), standing along the road
--     a vehicle   tiers 1-2: an old car from the career's own delivery filter (gameplay/delivery/
--                 vehicles.deliveryVehicles.json, JUNKER_FILTER) via util_configListGenerator, a
--                 few common models if that is missing; tiers 3-4: a heavy vehicle (HEAVY_MODELS)
--     a shop      a garage of the map (freeroam_facilities, the middle of its doors), as far away
--                 as the tier says (the nearest fit if none is)
--     the pay     (PAY_BASE + PAY_PER_KM per km of the tow (straight line x ROAD_FACTOR)) x the
--                 tier's pay, x PAY_FLAT with a flat tire, x client.jobPay
--     job.data = {vehicle = {model, config}, flatTire, dir}; job.title = the vehicle's name
--   doing it
--     1. the route leads to the place; within SPAWN_RANGE m the broken-down vehicle appears there
--        (spawned by this player, so it is theirs: the rope works on it, BeamMP shows it to
--        everyone). The vehicle breaks down: engines off and disabled, neutral, parking brake off,
--        hazard lights on, a flat tire if the job says so (sharedCareerVeh.jobBreakDown). A reset
--        (R) repairs it, so the job breaks it down again
--     2. near the vehicle the route switches to the repair shop
--     3. standing still in the drop-off zone (DROP_RADIUS m around the shop's doors) for
--        DROP_STILL s, nobody inside: handed over (jobs.handOver). New damage since the breakdown
--        costs up to PENALTY_MAX of the pay (DAMAGE_FOR_MAX damage points cost all of it)
--     When the job ends (paid, given up, taken away), the vehicle is removed. A vehicle that
--     vanished (deleted, reloaded, or refused by the server's vehicle limit) appears again at its
--     place when you come near, at most every SPAWN_RETRY s.
--   What you see: a marker above the broken-down vehicle while you drive there, and the drop-off
--   zone (a flat ring with a sign) near the repair shop while you tow.

local M = {}

local U, J

local SPAWN_RANGE = 400       -- m: the broken-down vehicle appears when you are this close
local FAR_FROM_VEHICLES = 350 -- m: a new job is never made up closer to any vehicle
local DEST_NEAREST = 400      -- m: a shop at least this far away when none fits the tier
local MIN_ROAD_RADIUS = 2.5   -- m: half the width of a road the place may be on
local MIN_DRIVABILITY = 0.6   -- the road must be a normal road (not a dirt track)
local ROADSIDE = 1.8          -- m beyond the road's edge
local PLACE_TRIES = 40
local NEAR_VEHICLE = 30       -- m: close enough to the vehicle, the route goes to the shop
local DROP_RADIUS = 14        -- m around the middle of the shop's doors
local DROP_STILL = 3          -- s standing still in the drop-off zone
local DROP_SPEED = 0.5        -- m/s: slower counts as standing still
local DAMAGE_WAIT = 3         -- s for the vehicle's damage report; then no deduction
local PAY_BASE, PAY_PER_KM = 150, 120
local PAY_FLAT = 1.25
local ROAD_FACTOR = 1.3       -- roads are about this much longer than the straight line
-- the tiers: how far to the shop (m), how often a flat tire, a heavy vehicle, the pay
local TIERS = {
	{destMin = 800, destMax = 2500, flatTire = 0.2, heavy = false, pay = 1},
	{destMin = 1500, destMax = 4000, flatTire = 0.4, heavy = false, pay = 1.3},
	{destMin = 2500, destMax = 6000, flatTire = 0.6, heavy = true, pay = 1.7},
	{destMin = 3500, destMax = 8000, flatTire = 1, heavy = true, pay = 2.2},
}
local PENALTY_MAX = 0.5       -- share of the pay new damage can cost at most
local DAMAGE_FOR_MAX = 40000  -- damage points (beamstate.damage) that cost PENALTY_MAX
local BREAKDOWN_RETRY = 3     -- s without the vehicle's answer: break it down again
local SPAWN_RETRY = 10        -- s before a vehicle that vanished right away is spawned again
local MARKER_RANGE = 250      -- m: the markers show within this distance

local JUNKER_FILTER = "junkerVehFilter"
local FILTER_FILE = "gameplay/delivery/vehicles.deliveryVehicles.json"
local FALLBACK_MODELS = {"fullsize", "midsize", "pickup", "covet", "pessima", "van"}
local HEAVY_MODELS = {"pickup", "van", "roamer"}

M.id = "tow"
M.name = "Towing"
M.icon = "tow"
M.branch = "labourer"
M.steps = {"Pick up", "Tow", "Paid"}

local clock = 0
local roadNodes = nil         -- {level, names} road nodes a job may be placed at
local current = nil           -- the towing job that is yours (jobs.lua's job state), for the
                              -- vehicle's replies: + vehId, spawnedAt, brokenDown, sentAt,
                              -- damageStart, phase, stillFor, checkingSince, damageNow

--== Making up a job =============================================================

-- road nodes a broken-down car may stand at: wide enough, on a normal road (cached per map)
local function candidateNodes(nodes)
	local level = type(getCurrentLevelIdentifier) == "function" and getCurrentLevelIdentifier() or ""
	if roadNodes and roadNodes.level == level then return roadNodes.names end
	local names = {}
	for name, n in pairs(nodes) do
		if type(n) == "table" and n.pos and (tonumber(n.radius) or 0) >= MIN_ROAD_RADIUS and type(n.links) == "table" then
			for _, link in pairs(n.links) do
				if type(link) == "table" and (tonumber(link.drivability) or 0) >= MIN_DRIVABILITY then
					table.insert(names, name)
					break
				end
			end
		end
	end
	table.sort(names, function(a, b) return tostring(a) < tostring(b) end) -- the same order on every PC
	roadNodes = {level = level, names = names}
	return names
end

-- The ground below a point, or the point's own height.
local function groundAt(p)
	local ok, cast = pcall(function() return castRayStatic end)
	if ok and type(cast) == "function" then
		local hitOk, hit = pcall(cast, vec3(p.x, p.y, p.z + 4), vec3(0, 0, -1), 20)
		hit = hitOk and tonumber(hit)
		if hit and hit >= 0 and hit < 20 then return p.z + 4 - hit end
	end
	return p.z
end

-- Where on the roadside of this node a car can stand: {pos, dir} or nil.
local function roadside(nodes, name)
	local n = nodes[name]
	local p = n and J.vecOf(n.pos)
	if not p then return nil end
	for other, link in pairs(n.links) do
		local q = type(link) == "table" and (tonumber(link.drivability) or 0) >= MIN_DRIVABILITY and nodes[other]
			and J.vecOf(nodes[other].pos)
		if q then
			local dx, dy = q.x - p.x, q.y - p.y
			local len = math.sqrt(dx * dx + dy * dy)
			if len > 1 then
				dx, dy = dx / len, dy / len
				local side = tonumber(n.radius) + ROADSIDE
				local pos = {x = p.x + dy * side, y = p.y - dx * side, z = p.z}
				pos.z = groundAt(pos)
				return {pos = pos, dir = {x = dx, y = dy}}
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
		if p then table.insert(out, p) end
	end
	return out
end

-- The repair shops the vehicle can go to: the map's garages (dealerships if there are none).
local function repairShops()
	local data = U.facilities()
	if not data then return {} end
	local shops = {}
	for _, kind in ipairs({"garages", "dealerships"}) do
		for _, fac in pairs(type(data[kind]) == "table" and data[kind] or {}) do
			local p = type(fac) == "table" and U.facilityDoor(fac)
			if p then
				table.insert(shops, {name = U.translate(fac.name) or (type(fac.name) == "string" and fac.name) or tostring(fac.id), pos = p})
			end
		end
		if #shops > 0 then break end
	end
	return shops
end

local function modelName(model)
	local name = model:gsub("^%l", string.upper)
	if core_vehicles and type(core_vehicles.getModel) == "function" then
		local ok, data = pcall(core_vehicles.getModel, model)
		local m = ok and type(data) == "table" and data.model
		if type(m) == "table" and m.Name then name = (m.Brand and (m.Brand .. " ") or "") .. m.Name end
	end
	return name
end

-- An old car from the career's delivery filter, or a heavy vehicle: {model, config, name}.
local function pickVehicle(heavy)
	if heavy then
		local model = HEAVY_MODELS[math.random(#HEAVY_MODELS)]
		return {model = model, name = modelName(model)}
	end
	local gen = rawget(_G, "util_configListGenerator")
	if gen and type(gen.getRandomVehicleInfos) == "function" and type(jsonReadFile) == "function" then
		local ok, info = pcall(function()
			local filters = jsonReadFile(FILTER_FILE)
			local filter = type(filters) == "table" and filters[JUNKER_FILTER]
			if not filter then return nil end
			local eligible = type(gen.getEligibleVehicles) == "function" and gen.getEligibleVehicles(false, false) or nil
			local infos = gen.getRandomVehicleInfos(filter, 1, eligible)
			return infos and infos[1]
		end)
		if ok and type(info) == "table" and info.model_key then
			local name = info.Name and ((info.Brand and (info.Brand .. " ") or "") .. info.Name) or info.model_key
			return {model = info.model_key, config = info.key, name = name}
		end
	end
	local model = FALLBACK_MODELS[math.random(#FALLBACK_MODELS)]
	return {model = model, name = modelName(model)}
end

local function roundTo(x, step) return math.floor(x / step + 0.5) * step end

local function tierOf(tier) return TIERS[math.max(1, math.min(#TIERS, tonumber(tier) or 1))] end

--- The pay for a tow of `length` m at level 1 (a flat tire and a higher tier pay more).
function M.payFor(length, flatTire, tier)
	local pay = (PAY_BASE + PAY_PER_KM * length / 1000) * tierOf(tier).pay * (flatTire and PAY_FLAT or 1) * J.payFactor()
	return roundTo(pay, 10)
end

--- Makes up a towing job of a tier on this map, or returns nil and why not.
function M.generate(tier)
	local t = tierOf(tier)
	local nodes = map and type(map.getMap) == "function" and map.getMap().nodes
	if type(nodes) ~= "table" then return nil, "no road network" end
	local shops = repairShops()
	if #shops == 0 then return nil, "no repair shops on this map" end
	local names = candidateNodes(nodes)
	if #names == 0 then return nil, "no roads for a breakdown" end
	local others = vehiclePositions()
	for _ = 1, PLACE_TRIES do
		local spot = roadside(nodes, names[math.random(#names)])
		local free = spot ~= nil
		for _, p in ipairs(free and others or {}) do
			if J.dist2D(p, spot.pos) < FAR_FROM_VEHICLES then free = false break end
		end
		if free then
			-- a shop as far away as the tier says; on a small map the one nearest to that
			local fitting, nearest, miss = {}, nil, math.huge
			for _, shop in ipairs(shops) do
				local d = J.dist2D(shop.pos, spot.pos)
				if d >= t.destMin and d <= t.destMax then table.insert(fitting, {shop = shop, d = d}) end
				local off = d < t.destMin and t.destMin - d or math.max(0, d - t.destMax)
				if d >= DEST_NEAREST and off < miss then nearest, miss = {shop = shop, d = d}, off end
			end
			local pick = #fitting > 0 and fitting[math.random(#fitting)] or nearest
			if pick then
				local length = roundTo(pick.d * ROAD_FACTOR, 10)
				local flatTire = math.random() < t.flatTire
				local vehicle = pickVehicle(t.heavy)
				return {title = vehicle.name, pos = spot.pos, dest = {name = pick.shop.name, pos = pick.shop.pos},
					length = length, pay = M.payFor(length, flatTire, tier),
					data = {vehicle = {model = vehicle.model, config = vehicle.config}, flatTire = flatTire, heavy = t.heavy, dir = spot.dir}}
			end
		end
	end
	return nil, "no free place found"
end

--- The labels of a towing job in the Jobs app.
function M.tags(job)
	local d = type(job.data) == "table" and job.data or {}
	local tags = {{text = "Engine failure", kind = "engine"}}
	if d.flatTire == true then table.insert(tags, {text = "Flat tire", kind = "tire"}) end
	if d.heavy == true then table.insert(tags, {text = "Heavy", kind = "heavy"}) end
	return tags
end

--== Doing it ======================================================================

local function data(a) return type(a.job.data) == "table" and a.job.data or {} end

local function removeVehicle(a)
	local veh = a.vehId and be:getObjectByID(a.vehId)
	if veh then pcall(function() veh:delete() end) end
end

local function breakDown(a)
	a.brokenDown, a.sentAt = false, clock
	J.sendToVehicle(a.vehId, "sharedCareerVeh.jobBreakDown(" .. tostring(data(a).flatTire == true) .. ")")
end

local function spawnVehicle(a)
	local job, d = a.job, data(a)
	local vehicle = type(d.vehicle) == "table" and d.vehicle or {}
	if not (core_vehicles and type(core_vehicles.spawnNewVehicle) == "function") or type(vehicle.model) ~= "string" then return end
	local dir = type(d.dir) == "table" and vec3(tonumber(d.dir.x) or 0, tonumber(d.dir.y) or 1, 0) or vec3(0, 1, 0)
	local options = {pos = vec3(job.pos.x, job.pos.y, job.pos.z), autoEnterVehicle = false, cling = true,
		config = vehicle.config}
	if type(quatFromDir) == "function" then options.rot = quatFromDir(dir, vec3(0, 0, 1)) end
	local ok, veh = pcall(core_vehicles.spawnNewVehicle, vehicle.model, options)
	if not ok or not veh then
		U.log("E", "jobs", "could not spawn the broken-down vehicle: " .. tostring(veh))
		return
	end
	a.vehId, a.spawnedAt = veh:getID(), clock
	U.log("I", "jobs", string.format("job %s: %s spawned (%s)", tostring(job.id), job.title, tostring(a.vehId)))
	breakDown(a)
end

-- Handed over: new damage since the breakdown costs part of the pay.
local function finish(a)
	local penalty = 0
	if a.damageNow and a.damageStart then
		penalty = math.min(PENALTY_MAX, math.max(0, a.damageNow - a.damageStart) / DAMAGE_FOR_MAX * PENALTY_MAX)
	end
	U.log("I", "jobs", string.format("job %s done: damage %s -> %s, %d %% of the pay", tostring(a.job.id),
		tostring(a.damageStart), tostring(a.damageNow), math.floor((1 - penalty) * 100 + 0.5)))
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
		if waited and me and J.dist2D(me, job.pos) <= SPAWN_RANGE then spawnVehicle(a) end
		return
	end
	if not a.brokenDown and clock - a.sentAt >= BREAKDOWN_RETRY then breakDown(a) end
	local p = J.vecOf(veh:getPosition())
	if a.phase == "toVehicle" and me and p and J.dist2D(me, p) <= NEAR_VEHICLE then
		a.phase = "toDestination"
		U.toast("info", "Route set: tow it to " .. job.dest.name, 6)
	end
	local speed = 0
	if type(veh.getVelocity) == "function" then
		local v = J.vecOf(veh:getVelocity())
		if v then speed = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end
	end
	local inZone = p and J.dist2D(p, job.dest.pos) <= DROP_RADIUS and speed <= DROP_SPEED
		and be:getPlayerVehicleID(0) ~= a.vehId
	if a.checkingSince then
		if a.damageNow or clock - a.checkingSince >= DAMAGE_WAIT then finish(a) end
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
		return {step = 1, target = a.job.dest.pos, from = veh and J.vecOf(veh:getPosition()) or nil, inZone = inZone,
			text = inZone and "In the ring – wait" or ("to " .. a.job.dest.name),
			short = inZone and "In the ring – wait" or ("Tow to " .. a.job.dest.name),
			hint = "Damage costs pay. Park it in the ring at the shop."}
	end
	return {step = 0, target = a.job.pos, text = "to the " .. a.job.title, short = "Drive to the breakdown",
		hint = "Damage costs pay. Park it in the ring at the shop."}
end

function M.stop(a)
	removeVehicle(a)
	if current == a then current = nil end
end

-- the reset (R) repairs the broken-down vehicle: break it down again
function M.vehicleReset(a, id)
	if a.vehId == id then breakDown(a) end
end

--== Replies from the vehicle ======================================================

function M.onJobBrokenDown(vehId, damage)
	if not current or current.vehId ~= vehId then return end
	current.brokenDown = true
	current.damageStart = tonumber(damage) or 0
end

function M.onJobDamage(vehId, damage)
	if not current or current.vehId ~= vehId then return end
	current.damageNow = tonumber(damage) or 0
end

--== Drawing ======================================================================

function M.draw(a)
	if not (debugDrawer and ColorF and vec3) then return end
	local me = J.myPosition()
	if not me then return end
	if a.phase == "toVehicle" then
		local veh = a.vehId and be:getObjectByID(a.vehId)
		local p = veh and J.vecOf(veh:getPosition()) or a.job.pos
		if J.dist2D(me, p) <= MARKER_RANGE then
			local bob = 0.15 * math.sin(clock * 2.5)
			local top = vec3(p.x, p.y, p.z + 3.2 + bob)
			debugDrawer:drawSphere(top, 0.35, ColorF(1, 0.6, 0.1, 0.85))
			debugDrawer:drawCylinder(vec3(p.x, p.y, p.z + 2.3 + bob), vec3(p.x, p.y, p.z + 2.85 + bob), 0.06, ColorF(1, 0.6, 0.1, 0.85))
		end
	elseif a.phase == "toDestination" then
		local d = a.job.dest.pos
		if J.dist2D(me, d) <= MARKER_RANGE then
			local inZone = (a.stillFor or 0) > 0
			local r, g, b = 0.25, 0.55, 1
			if inZone then r, g, b = 0.3, 0.9, 0.45 end
			debugDrawer:drawCylinder(vec3(d.x, d.y, d.z + 0.02), vec3(d.x, d.y, d.z + 0.08), DROP_RADIUS, ColorF(r, g, b, 0.18))
			debugDrawer:drawCylinder(vec3(d.x, d.y, d.z), vec3(d.x, d.y, d.z + 4), 0.08, ColorF(r, g, b, 0.7))
			local label = inZone and string.format("Drop-off \194\183 %d s", math.max(1, math.ceil(DROP_STILL - (a.stillFor or 0))))
				or ("Drop-off \194\183 " .. a.job.dest.name)
			local str = String and String(label) or label
			debugDrawer:drawTextAdvanced(vec3(d.x, d.y, d.z + 4.4), str, ColorF(1, 1, 1, 1), true, false, ColorI(20, 30, 50, 200))
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

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
