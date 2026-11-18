-- SharedCareer :: towing jobs (beta): broken-down cars at the roadside, towed to a repair shop
--
-- The server keeps one list of jobs for everyone (server.jobs, see main.lua "Towing jobs"). When
-- jobs are missing it asks one player to make one up (sc_jobGenerate): this client knows the map
-- and picks
--   a place     a random road node far from every vehicle, moved off the road onto the
--               roadside (ROADSIDE m beyond the road's edge), standing along the road
--   a vehicle   an old car from the career's own delivery filter (gameplay/delivery/
--               vehicles.deliveryVehicles.json, JUNKER_FILTER) via util_configListGenerator;
--               a few common models if that is missing
--   a shop      a garage of the map (freeroam_facilities, the middle of its doors) DEST_MIN to
--               DEST_MAX m away
--   the pay     PAY_BASE + PAY_PER_KM per km of the tow (straight line x ROAD_FACTOR), x PAY_FLAT
--               with a flat tire, x client.jobPay
-- and sends it (sc_jobOffer). Every player sees the jobs in the Jobs app on the phone.
--
-- Taking a job (sc_jobTake; the server gives it to the first one):
--   1. the navigation leads to the place; within SPAWN_RANGE m the broken-down vehicle appears
--      there (spawned by this player, so it is theirs: the rope works on it, BeamMP shows it to
--      everyone). The vehicle breaks down: engines off and disabled, neutral, parking brake off,
--      hazard lights on, a flat tire if the job says so (sharedCareerVeh.jobBreakDown). A reset
--      (R) repairs it, so the job breaks it down again
--   2. near the vehicle the navigation switches to the repair shop
--   3. standing still in the drop-off zone (DROP_RADIUS m around the shop's doors) for DROP_STILL
--      s, nobody inside: the job is done (sc_jobDone with the pay). New damage since the
--      breakdown costs up to PENALTY_MAX of the pay (DAMAGE_FOR_MAX damage points cost all of it)
--   4. the server answers sc_jobPaid: the pay goes to the career (playerAttributes), the vehicle
--      is removed REMOVE_AFTER s later
-- Giving up removes the vehicle; the job is open again for everyone. A vehicle that vanished
-- (deleted, reloaded, or refused by the server's vehicle limit) appears again at its place when
-- you come near, at most every SPAWN_RETRY s. Without the server's answer to sc_jobDone within
-- PAID_WAIT s the job ends here (the server pays only once anyway).
--
-- What you see: a marker above the broken-down vehicle while you drive there, and the drop-off
-- zone (a flat ring with a sign) near the repair shop while you tow.
--
-- Settings: server.jobs (on/off, also the Jobs app), server.jobsOpen, server.jobTimeoutMinutes,
-- server.jobPayMax (server); client.jobPay (factor on the pay).

local M = {}

local U

local SPAWN_RANGE = 400       -- m: the broken-down vehicle appears when you are this close
local FAR_FROM_VEHICLES = 350 -- m: a new job is never made up closer to any vehicle
local DEST_MIN, DEST_MAX = 800, 6000 -- m from the place to the repair shop
local MIN_ROAD_RADIUS = 2.5   -- m: half the width of a road the place may be on
local MIN_DRIVABILITY = 0.6   -- the road must be a normal road (not a dirt track)
local ROADSIDE = 1.8          -- m beyond the road's edge
local PLACE_TRIES = 40
local NEAR_VEHICLE = 30       -- m: close enough to the vehicle, the navigation goes to the shop
local DROP_RADIUS = 14        -- m around the middle of the shop's doors
local DROP_STILL = 3          -- s standing still in the drop-off zone
local DROP_SPEED = 0.5        -- m/s: slower counts as standing still
local DAMAGE_WAIT = 3         -- s for the vehicle's damage report; then no deduction
local PAY_BASE, PAY_PER_KM = 150, 120
local PAY_FLAT = 1.25
local ROAD_FACTOR = 1.3       -- roads are about this much longer than the straight line
local FLAT_TIRE_CHANCE = 0.4
local PENALTY_MAX = 0.5       -- share of the pay new damage can cost at most
local DAMAGE_FOR_MAX = 40000  -- damage points (beamstate.damage) that cost PENALTY_MAX
local BREAKDOWN_RETRY = 3     -- s without the vehicle's answer: break it down again
local REMOVE_AFTER = 6        -- s after paying, the vehicle is removed
local SPAWN_RETRY = 10        -- s before a vehicle that vanished right away is spawned again
local PAID_WAIT = 15          -- s for the server's answer to sc_jobDone; then the job ends here
local CHECK_EVERY = 0.25      -- s between two checks of the job
local PUSH_EVERY = 1          -- s between two app updates while the phone is out
local MARKER_RANGE = 250      -- m: the markers show within this distance

local JUNKER_FILTER = "junkerVehFilter"
local FILTER_FILE = "gameplay/delivery/vehicles.deliveryVehicles.json"
local FALLBACK_MODELS = {"fullsize", "midsize", "pickup", "covet", "pessima", "van"}

local list = {}               -- jobs from the server (sc_jobs)
local enabled = false
local active = nil            -- {id, job, vehId, spawnedAt, brokenDown, sentAt, damageStart, phase,
                              --  stillFor, checkingSince, damageNow, doneSent, doneAt, paidAt}
local paidIds = {}            -- jobs already credited (a message that arrives twice)
local clock = 0
local sinceCheck, sincePush = 0, 0
local roadNodes = nil         -- {level, names} road nodes a job may be placed at
local pushApp                 -- defined with the app below

--== Helpers ===================================================================

local function vecOf(v)
	if v == nil then return nil end
	local ok, x, y, z = pcall(function() return v.x, v.y, v.z end)
	if not ok or not tonumber(x) then return nil end
	return {x = tonumber(x), y = tonumber(y) or 0, z = tonumber(z) or 0}
end

local function dist2D(a, b)
	local dx, dy = a.x - b.x, a.y - b.y
	return math.sqrt(dx * dx + dy * dy)
end

local function myPosition()
	local veh = type(getPlayerVehicle) == "function" and getPlayerVehicle(0) or nil
	if veh then
		local ok, p = pcall(function() return veh:getPosition() end)
		if ok and p then return vecOf(p) end
	end
	if core_camera and type(core_camera.getPosition) == "function" then
		local ok, p = pcall(core_camera.getPosition)
		if ok and p then return vecOf(p) end
	end
	return nil
end

local function payFactor()
	local c = U.config()
	local f = c and tonumber(c.jobPay)
	if not f or f < 0 then return 1 end
	return math.min(f, 10)
end

local function serverAllows()
	local c = U.config()
	return c ~= nil and type(c.ui) == "table" and c.ui.jobs == true
end

local function navigate(pos)
	local markers = rawget(_G, "core_groundMarkers")
	if not markers or type(markers.setPath) ~= "function" then return end
	if pos then
		pcall(markers.setPath, vec3(pos.x, pos.y, pos.z))
	else
		pcall(markers.setPath, nil)
	end
end

local function sendToVehicle(id, cmd)
	local veh = id and be:getObjectByID(id)
	if veh and type(veh.queueLuaCommand) == "function" then
		veh:queueLuaCommand("if sharedCareerVeh then " .. cmd .. " end")
	end
end

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
	local p = n and vecOf(n.pos)
	if not p then return nil end
	for other, link in pairs(n.links) do
		local q = type(link) == "table" and (tonumber(link.drivability) or 0) >= MIN_DRIVABILITY and nodes[other]
			and vecOf(nodes[other].pos)
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
		local p = veh and type(veh.getPosition) == "function" and vecOf(veh:getPosition())
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

-- An old car from the career's delivery filter: {model, config, name}.
local function pickVehicle()
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
	local name = model:gsub("^%l", string.upper)
	if core_vehicles and type(core_vehicles.getModel) == "function" then
		local ok, data = pcall(core_vehicles.getModel, model)
		local m = ok and type(data) == "table" and data.model
		if type(m) == "table" and m.Name then name = (m.Brand and (m.Brand .. " ") or "") .. m.Name end
	end
	return {model = model, name = name}
end

local function roundTo(x, step) return math.floor(x / step + 0.5) * step end

--- The pay for a tow of `length` m (with a flat tire: more).
function M.payFor(length, flatTire)
	local pay = (PAY_BASE + PAY_PER_KM * length / 1000) * (flatTire and PAY_FLAT or 1) * payFactor()
	return roundTo(pay, 10)
end

--- Makes up a new job, or returns nil and why not.
function M.generate()
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
			if dist2D(p, spot.pos) < FAR_FROM_VEHICLES then free = false break end
		end
		if free then
			local fitting = {}
			for _, shop in ipairs(shops) do
				local d = dist2D(shop.pos, spot.pos)
				if d >= DEST_MIN and d <= DEST_MAX then table.insert(fitting, {shop = shop, d = d}) end
			end
			if #fitting > 0 then
				local pick = fitting[math.random(#fitting)]
				local length = roundTo(pick.d * ROAD_FACTOR, 10)
				local flatTire = math.random() < FLAT_TIRE_CHANCE
				return {vehicle = pickVehicle(), flatTire = flatTire, pos = spot.pos, dir = spot.dir,
					dest = {name = pick.shop.name, pos = pick.shop.pos}, length = length, pay = M.payFor(length, flatTire)}
			end
		end
	end
	return nil, "no free place found"
end

--== The active job ================================================================

local function removeVehicle()
	local veh = active and active.vehId and be:getObjectByID(active.vehId)
	if veh then pcall(function() veh:delete() end) end
end

local function endActive()
	if not active then return end
	removeVehicle()
	navigate(nil)
	active = nil
end

local function breakDown()
	active.brokenDown, active.sentAt = false, clock
	sendToVehicle(active.vehId, "sharedCareerVeh.jobBreakDown(" .. tostring(active.job.flatTire == true) .. ")")
end

local function spawnVehicle()
	local job = active.job
	if not (core_vehicles and type(core_vehicles.spawnNewVehicle) == "function") then return end
	local dir = vec3(job.dir.x, job.dir.y, 0)
	local options = {pos = vec3(job.pos.x, job.pos.y, job.pos.z), autoEnterVehicle = false, cling = true,
		config = job.vehicle.config}
	if type(quatFromDir) == "function" then options.rot = quatFromDir(dir, vec3(0, 0, 1)) end
	local ok, veh = pcall(core_vehicles.spawnNewVehicle, job.vehicle.model, options)
	if not ok or not veh then
		U.log("E", "jobs", "could not spawn the broken-down vehicle: " .. tostring(veh))
		return
	end
	active.vehId, active.spawnedAt = veh:getID(), clock
	U.log("I", "jobs", string.format("job %s: %s spawned (%s)", tostring(job.id), job.vehicle.name, tostring(active.vehId)))
	breakDown()
end

local function startActive(job)
	active = {id = job.id, job = job, phase = "toVehicle", stillFor = 0}
	navigate(job.pos)
	U.toast("info", "Towing job: drive to the " .. job.vehicle.name .. " – the route is set", 6)
end

local function finish()
	local job = active.job
	local penalty = 0
	if active.damageNow and active.damageStart then
		penalty = math.min(PENALTY_MAX, math.max(0, active.damageNow - active.damageStart) / DAMAGE_FOR_MAX * PENALTY_MAX)
	end
	local pay = math.floor(job.pay * (1 - penalty) + 0.5)
	active.doneSent, active.doneAt, active.deduction = true, clock, job.pay - pay
	U.log("I", "jobs", string.format("job %s done: damage %s -> %s, pay %d of %d", tostring(job.id),
		tostring(active.damageStart), tostring(active.damageNow), pay, job.pay))
	U.send("sc_jobDone", {id = job.id, pay = pay})
end

-- One check of the active job (every CHECK_EVERY s).
function M.step(dt)
	if not active or active.paidAt then
		if active and clock - active.paidAt >= REMOVE_AFTER then
			removeVehicle()
			active = nil
			pushApp()
		end
		return
	end
	local job = active.job
	local me = myPosition()
	local veh = active.vehId and be:getObjectByID(active.vehId)
	if active.doneSent and clock - active.doneAt >= PAID_WAIT then
		U.log("W", "jobs", "no answer from the server to job " .. tostring(job.id) .. " – ended here")
		U.toast("warning", "No answer from the server – the towing job ended", 6)
		endActive()
		pushApp()
		return
	end
	if active.vehId and not veh then
		-- deleted, reloaded or refused by the server: it appears again at its place
		U.log("W", "jobs", "the vehicle of job " .. tostring(job.id) .. " is gone")
		if clock - (active.spawnedAt or -math.huge) < 2 then
			U.toast("warning", "The broken-down car was removed right away – is the server's vehicle limit reached?", 6)
		end
		active.vehId, active.brokenDown = nil, false
		active.phase = "toVehicle"
		navigate(job.pos)
	end
	if not veh then
		local waited = clock - (active.spawnedAt or -math.huge) >= SPAWN_RETRY
		if waited and me and dist2D(me, job.pos) <= SPAWN_RANGE then spawnVehicle() end
		return
	end
	if not active.brokenDown and clock - active.sentAt >= BREAKDOWN_RETRY then breakDown() end
	local p = vecOf(veh:getPosition())
	if active.phase == "toVehicle" and me and p and dist2D(me, p) <= NEAR_VEHICLE then
		active.phase = "toDestination"
		navigate(job.dest.pos)
		U.toast("info", "Tow it to " .. job.dest.name .. " – the route is set", 6)
	end
	if active.doneSent then return end
	local speed = 0
	if type(veh.getVelocity) == "function" then
		local v = vecOf(veh:getVelocity())
		if v then speed = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end
	end
	local inZone = p and dist2D(p, job.dest.pos) <= DROP_RADIUS and speed <= DROP_SPEED
		and be:getPlayerVehicleID(0) ~= active.vehId
	if active.checkingSince then
		if active.damageNow or clock - active.checkingSince >= DAMAGE_WAIT then finish() end
	elseif inZone then
		active.stillFor = active.stillFor + dt
		if active.stillFor >= DROP_STILL then
			active.checkingSince, active.damageNow = clock, nil
			sendToVehicle(active.vehId, "sharedCareerVeh.jobReportDamage()")
		end
	else
		active.stillFor = 0
	end
end

--== Replies from the vehicle ======================================================

function M.onJobBrokenDown(vehId, damage)
	if not active or active.vehId ~= vehId then return end
	active.brokenDown = true
	active.damageStart = tonumber(damage) or 0
end

function M.onJobDamage(vehId, damage)
	if not active or active.vehId ~= vehId then return end
	active.damageNow = tonumber(damage) or 0
end

--== Messages from the server ======================================================

local function mineIn(jobs)
	for _, job in ipairs(jobs) do
		if job.state == "mine" then return job end
	end
end

local function rxJobs(data)
	local msg = U.decode(data)
	if not msg then return end
	enabled = msg.enabled == true
	list = type(msg.jobs) == "table" and msg.jobs or {}
	local mine = mineIn(list)
	if active and not active.doneSent and (not mine or mine.id ~= active.id) then
		-- taken away (out of time, switched off, given up elsewhere)
		endActive()
	end
	if mine and not active then startActive(mine) end
	M.registerApp()
	pushApp()
end

local function rxGenerate()
	if not enabled or not U.careerActive() then return end
	local job, why = M.generate()
	if job then
		U.send("sc_jobOffer", job)
	else
		U.log("W", "jobs", "could not make up a towing job: " .. tostring(why))
	end
end

local function rxPaid(data)
	local msg = U.decode(data)
	local pay = msg and tonumber(msg.pay)
	if not msg or not pay or pay < 0 or paidIds[msg.id] then return end
	paidIds[msg.id] = true
	local name = active and active.id == msg.id and active.job.vehicle.name or "vehicle"
	local attributes = rawget(_G, "career_modules_playerAttributes")
	if attributes and type(attributes.addAttributes) == "function" and pay > 0 then
		pcall(attributes.addAttributes, {money = pay}, {tags = {"gameplay"}, label = "Towing job: " .. name})
	end
	local deduction = active and active.id == msg.id and active.deduction or 0
	U.toast("success", string.format("Towing job done: +$%d", pay)
		.. (deduction > 0 and string.format(" ($%d less for new damage)", deduction) or ""), 8)
	if active and active.id == msg.id then
		active.paidAt = clock
		navigate(nil)
	end
	pushApp()
end

--== Jobs app (phone) ============================================================

local appOpen = false

--- State for the Jobs app.
function M.appState()
	local me = myPosition()
	local jobs = {}
	for _, job in ipairs(list) do
		table.insert(jobs, {id = job.id, vehicle = job.vehicle and job.vehicle.name or "?", flatTire = job.flatTire == true,
			dest = job.dest and job.dest.name or "?", length = job.length, pay = job.pay, state = job.state,
			takenBy = job.takenBy, distance = me and job.pos and dist2D(me, job.pos) or nil})
	end
	table.sort(jobs, function(a, b)
		if (a.state == "open") ~= (b.state == "open") then return a.state == "open" end
		return (a.distance or 1e12) < (b.distance or 1e12)
	end)
	local state = {enabled = enabled and serverAllows(), jobs = jobs}
	if active then
		local job = active.job
		local veh = active.vehId and be:getObjectByID(active.vehId)
		local from = active.phase == "toDestination" and veh and vecOf(veh:getPosition()) or me
		local target = active.phase == "toDestination" and job.dest.pos or job.pos
		state.active = {id = job.id, vehicle = job.vehicle.name, flatTire = job.flatTire == true, dest = job.dest.name,
			pay = job.pay, phase = active.paidAt and "paid" or (active.doneSent and "checking" or active.phase),
			distance = from and target and dist2D(from, target) or nil, inZone = (active.stillFor or 0) > 0}
	end
	return state
end

function pushApp()
	if guihooks and type(guihooks.trigger) == "function" then guihooks.trigger("SharedCareerJobs", M.appState()) end
end

function M.setAppOpen(on)
	appOpen = on == true
	pushApp()
end

function M.registerApp()
	local phone = U.ext("sharedCareer_phone")
	if not phone or type(phone.registerApp) ~= "function" then return end
	if serverAllows() then
		phone.registerApp({id = "jobs", title = "Jobs", icon = "jobs", color = "#2d6fd8", order = 5, beta = true,
			onOpen = function() M.setAppOpen(true) end, onClose = function() M.setAppOpen(false) end})
	else
		phone.unregisterApp("jobs")
		appOpen = false
	end
end

-- buttons of the Jobs app
function M.uiTake(id)
	if active then
		U.toast("warning", "Finish or give up your towing job first", 4)
		return
	end
	U.send("sc_jobTake", {id = tonumber(id)})
end

function M.uiGiveUp()
	if not active or active.doneSent then return end
	U.send("sc_jobGiveUp", {id = active.id})
	endActive()
	U.toast("info", "Towing job given up", 4)
	pushApp()
end

function M.uiNavigate()
	if not active then return end
	navigate(active.phase == "toDestination" and active.job.dest.pos or active.job.pos)
end

function M.uiRequest() pushApp() end

function M.getActive() return active end

--== Drawing ======================================================================

local function drawMarkers()
	if not active or active.paidAt or not (debugDrawer and ColorF and vec3) then return end
	local me = myPosition()
	if not me then return end
	if active.phase == "toVehicle" then
		local veh = active.vehId and be:getObjectByID(active.vehId)
		local p = veh and vecOf(veh:getPosition()) or active.job.pos
		if dist2D(me, p) <= MARKER_RANGE then
			local bob = 0.15 * math.sin(clock * 2.5)
			local top = vec3(p.x, p.y, p.z + 3.2 + bob)
			debugDrawer:drawSphere(top, 0.35, ColorF(1, 0.6, 0.1, 0.85))
			debugDrawer:drawCylinder(vec3(p.x, p.y, p.z + 2.3 + bob), vec3(p.x, p.y, p.z + 2.85 + bob), 0.06, ColorF(1, 0.6, 0.1, 0.85))
		end
	elseif active.phase == "toDestination" then
		local d = active.job.dest.pos
		if dist2D(me, d) <= MARKER_RANGE then
			local inZone = (active.stillFor or 0) > 0
			local r, g, b = 0.25, 0.55, 1
			if inZone then r, g, b = 0.3, 0.9, 0.45 end
			debugDrawer:drawCylinder(vec3(d.x, d.y, d.z + 0.02), vec3(d.x, d.y, d.z + 0.08), DROP_RADIUS, ColorF(r, g, b, 0.18))
			debugDrawer:drawCylinder(vec3(d.x, d.y, d.z), vec3(d.x, d.y, d.z + 4), 0.08, ColorF(r, g, b, 0.7))
			local label = inZone and string.format("Drop-off \194\183 hold still %d s", math.max(1, math.ceil(DROP_STILL - (active.stillFor or 0))))
				or ("Drop-off \194\183 " .. active.job.dest.name)
			local str = String and String(label) or label
			debugDrawer:drawTextAdvanced(vec3(d.x, d.y, d.z + 4.4), str, ColorF(1, 1, 1, 1), true, false, ColorI(20, 30, 50, 200))
		end
	end
end

--== Hooks =======================================================================

function M.onUpdate(dtReal)
	local dt = tonumber(dtReal) or 0
	clock = clock + dt
	if not active and not appOpen then return end
	sinceCheck = sinceCheck + dt
	if sinceCheck >= CHECK_EVERY then
		local stepDt = sinceCheck
		sinceCheck = 0
		local ok, err = pcall(M.step, stepDt)
		if not ok then U.log("E", "jobs", "job check failed: " .. tostring(err)) end
	end
	sincePush = sincePush + dt
	if sincePush >= PUSH_EVERY then
		sincePush = 0
		local menu = U.ext("sharedCareer_menu")
		if appOpen or (menu and menu.isVisible("phone")) then pcall(pushApp) end
	end
	pcall(drawMarkers)
end

-- the reset (R) repairs the broken-down vehicle: break it down again
function M.onVehicleResetted(id)
	if active and active.vehId == id and not active.paidAt then breakDown() end
end

function M.onCareerActive(on)
	if on and U.isMP() then
		M.registerApp()
		U.send("sc_jobsRequest", "")
	end
end

function M.onConfigChanged()
	M.registerApp()
	pushApp()
end

function M.onBeamMPServerLeave()
	navigate(nil)
	active, list, enabled, paidIds, roadNodes = nil, {}, false, {}, nil
	appOpen = false
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	U.on("sc_jobs", rxJobs)
	U.on("sc_jobGenerate", rxGenerate)
	U.on("sc_jobPaid", rxPaid)
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
