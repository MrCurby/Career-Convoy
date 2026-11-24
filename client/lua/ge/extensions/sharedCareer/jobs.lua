-- SharedCareer :: jobs: the shared job list and the Jobs app, for every kind of job
--
-- The server keeps one list of jobs for everyone (server.jobs, see main.lua "Jobs"). This file is
-- what all jobs have in common. What a job is about comes from its job type, an extension that
-- registers itself here (registerType): towJobs.lua (towing jobs), taxiJobs.lua (taxi rides). A job type:
--   id               short name, sent with every job ("tow")
--   name             its name in the Jobs app ("Towing") and in the money history ("Towing job: <title>")
--   icon             the icon of its jobs in the Jobs app (an icon of ui/sharedCareer/icons.svg, e.g. "tow")
--   branch           optional: the career branch whose XP a job also gives, next to the game's
--                    BeamXP ("commercial"): the branch whose attribute key, id or path id is or
--                    ends with it (career_branches; the names change between game versions).
--                    No branch XP if the career has no such branch
--   steps            the steps of a job in the Jobs app, e.g. {"Pick up", "Tow", "Paid"}; the last
--                    one is reached when the pay arrives
--   generate(tier)   makes up a job of this tier (1 easy .. 4 hard, see main.lua "Job levels") on
--                    this map: {title, pos, dest = {name, pos}, length, pay, data} (pos: where it
--                    starts; pay: at level 1; data: the type's own fields, the server passes them
--                    on), or nil and why not
--   iconOf(job)      optional: the icon of this job in the Jobs app (an icon of icons.svg, e.g. "pickup");
--                    nil: the type's icon
--   tags(job)        short labels for the job in the app: {{text, kind}} (kind picks the color)
--   start(a)         the job is yours: a = {id, job}; the type keeps its own state in a
--   step(a, dt)      every CHECK_EVERY s until it is handed over; calls M.handOver(a, share) when
--                    the job is done (share: how much of the pay was earned, 0..1 – less after
--                    damage, for example; the server turns it into money and XP)
--   status(a)        {step (0-based index into steps), text (Jobs app), short (the job strip),
--                    target (pos: the route and the distance in the app), from (pos the distance
--                    is measured from; default: you), hint (optional), inZone (optional)}
--   stop(a)          the job ends here (paid, given up, taken away, no answer): clean up
--   draw(a)          optional, every frame: markers in the world
--   vehicleReset(a, id)  optional: a vehicle was reset (R)
-- (Not named like the game's hooks – onUpdate, onVehicleResetted, ... – the game calls those on
-- every extension.)
--
-- Common to all jobs:
--   making one up  this client tells the server its job types (sc_jobsRequest {types}); when jobs
--                  are missing, the server asks one player for a job of a type and tier
--                  (sc_jobGenerate {type, tier}); this client asks that job type and sends the job
--                  (sc_jobOffer). The helpers below find places for it (randomRoadside,
--                  farFromVehicles, pickDestination, roadLength)
--   levels         every player has a level per job type; the server keeps it and decides (main.lua
--                  "Job levels"): which tiers you can take, your pay, the XP. The Jobs app has a
--                  section per job type with your level in it and its jobs by level, the ones you
--                  can't take yet at the bottom.
--                  The last levels the server sent are kept in the career save (LEVELS_FILE), to
--                  show them before the server's list has arrived
--   licenses       a job type can need a license (main.lua "Licenses"): the server refuses its jobs
--                  without it; the app greys them out and offers the route to the license office
--                  (licenses.lua)
--   taking         sc_jobTake, the server gives it to the first one; then the type's start() and
--                  the route to its status target (updated whenever the target changes)
--   giving up      sc_jobGiveUp; a job the server takes away (out of time, switched off) ends too
--   handing over   handOver -> sc_jobDone with the share; without the server's answer within
--                  PAID_WAIT s the job ends here (a pay the server did book still arrives later)
--   the pay        sc_jobPaid: credited to the career (playerAttributes), the career is saved and
--                  the server gets sc_jobPaidAck; until then it sends the pay again (also after a
--                  crash or reconnect, see main.lua "Payouts"). Each payout is credited once, with
--                  the job's XP also as the game's BeamXP (and branch XP). The type's stop()
--                  follows REMOVE_AFTER s later
--
-- Settings: server.jobs (on/off, also the Jobs app), server.jobsOpen, server.jobTimeoutMinutes,
-- server.jobPayMax (server); client.jobPay (factor on the pay, payFactor).

local M = {}

local U

local PAID_WAIT = 15 -- s for the server's answer to sc_jobDone; then the job ends here
local REMOVE_AFTER = 6 -- s after paying, the job ends (the type's stop())
local CHECK_EVERY = 0.25 -- s between two checks of the job
local PUSH_EVERY = 1 -- s between two app updates while the phone is out
local ROUTE_MOVE = 0.05 -- share of a drive distance you move before the app works it out again
local ROUTE_MOVE_MIN = 50 -- m: at least this far
local ROUTES_PER_PUSH = 4 -- drive distances worked out at most per app update (each searches the roads)
local LEVELS_FILE = "/career/sharedCareerJobLevels.json" -- in the career save: a copy of your levels
-- places beside the road (randomRoadside)
local MIN_ROAD_RADIUS = 2.5 -- m: half the width of a road the place may be on
local MIN_DRIVABILITY = 0.6 -- the road must be a normal road (not a dirt track)
local ROADSIDE = 1.8 -- m beyond the road's edge
local SIDE_CLEAR = 1.2 -- m free beyond the spot (half a car's width)
local GROUND_STEP = 1.5 -- m the roadside's ground may be above or below the road
local RAY_HEIGHT = 1 -- m above the road the rays start (above curbs, below a tunnel's roof)
local DEST_NEAREST = 400 -- m: a destination at least this far away when none fits (pickDestination)
local ROAD_FACTOR = 1.3 -- without a way by road: roads are about this much longer than the straight line
local MARKER_RANGE = 250 -- m: the markers in the world show within this distance

local types = {} -- id -> job type
local typeOrder = {} -- ids, in the order they registered
local roadNodes = nil -- {level, names}: the road nodes a place beside the road may be at
local list = {} -- jobs from the server (sc_jobs)
local levels = {} -- your levels from the server: type -> {level, xp, from, to}
local enabled = false
local active = nil -- your job: {id, job, type, doneSent, doneAt, paidAt, route}
-- and the type's own fields
-- payout ids already credited: a payout the server sends again is only confirmed. Kept when leaving
-- the server, so a payout sent again after a reconnect isn't credited twice.
local creditedPayouts = {}
local clock = 0
local sinceCheck, sincePush = 0, 0
local routes = {} -- drive distances for the app: key -> {from, to, d}
local pushApp -- defined with the app below

--== Helpers for the job types ====================================================

function M.dist2D(a, b)
	local dx, dy = a.x - b.x, a.y - b.y
	return math.sqrt(dx * dx + dy * dy)
end
local dist2D = M.dist2D

local function dist3D(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- The distance from a to b by road (m): the game's way between the two points
--- (map.getPointToPointPath, which also finds where to join and leave the roads), its length
--- (map.getPathLen) and the bits off the road at both ends. nil without a road map or a way.
function M.driveDistance(a, b)
	if
		not (
			map
			and type(map.getPointToPointPath) == "function"
			and type(map.getPathLen) == "function"
			and type(map.getMap) == "function"
			and type(vec3) == "function"
		)
	then
		return nil
	end
	local ok, d = pcall(function()
		local path = map.getPointToPointPath(vec3(a.x, a.y, a.z or 0), vec3(b.x, b.y, b.z or 0))
		if type(path) ~= "table" or #path == 0 then
			return nil
		end
		local nodes = map.getMap().nodes
		local first, last =
			nodes[path[1]] and U.vecOf(nodes[path[1]].pos), nodes[path[#path]] and U.vecOf(nodes[path[#path]].pos)
		if not (first and last) then
			return nil
		end
		return dist3D(a, first) + map.getPathLen(path) + dist3D(last, b)
	end)
	return ok and tonumber(d) or nil
end

--- client.jobPay: the server's factor on every pay (0..10, default 1).
function M.payFactor()
	local c = U.config()
	local f = c and tonumber(c.jobPay)
	if not f or f < 0 then
		return 1
	end
	return math.min(f, 10)
end

function M.roundTo(x, step)
	return math.floor(x / step + 0.5) * step
end

--- The length of a drive from a to b (m, rounded to 10): by road, else the straight line x ROAD_FACTOR.
function M.roadLength(a, b)
	return M.roundTo(M.driveDistance(a, b) or dist2D(a, b) * ROAD_FACTOR, 10)
end

--- The speed of a vehicle (m/s), 0 if it has none.
function M.speedOf(veh)
	local v = veh and type(veh.getVelocity) == "function" and U.vecOf(veh:getVelocity())
	return v and math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) or 0
end

-- road nodes a place beside the road may be at: wide enough, on a normal road (cached per map)
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
	local p = n and U.vecOf(n.pos)
	if not p then
		return nil
	end
	for other, link in pairs(n.links) do
		local q = type(link) == "table"
			and (tonumber(link.drivability) or 0) >= MIN_DRIVABILITY
			and nodes[other]
			and U.vecOf(nodes[other].pos)
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

--- A place beside a normal road at a random road node of this map: {pos, dir (along the road)}, or
--- nil (that node has no free side: try again) and why. ROADSIDE m beyond the road's edge, on the
--- side that is free: nothing stands between the road and the spot (a tunnel wall, a rock: a ray at
--- car height) and there is ground at about the road's height (GROUND_STEP). The right side first.
function M.randomRoadside()
	local nodes = map and type(map.getMap) == "function" and map.getMap().nodes
	if type(nodes) ~= "table" then
		return nil, "no road network"
	end
	local names = candidateNodes(nodes)
	if #names == 0 then
		return nil, "no normal roads"
	end
	return roadside(nodes, names[math.random(#names)])
end

--- Whether no vehicle is within `dist` m of pos.
function M.farFromVehicles(pos, dist)
	local count = type(be.getObjectCount) == "function" and be:getObjectCount() or 0
	for i = 0, count - 1 do
		local veh = be:getObject(i)
		local p = veh and type(veh.getPosition) == "function" and U.vecOf(veh:getPosition())
		if p and dist2D(p, pos) < dist then
			return false
		end
	end
	return true
end

--- A destination for a job starting at `from`: one of `places` ({name, pos}) between min and max m
--- away in a straight line; none there (a small map): the one nearest to that range, at least
--- DEST_NEAREST m away. {place, d} or nil.
function M.pickDestination(places, from, min, max)
	local fitting, nearest, miss = {}, nil, math.huge
	for _, place in ipairs(places) do
		local d = dist2D(place.pos, from)
		if d >= min and d <= max then
			table.insert(fitting, { place = place, d = d })
		end
		local off = d < min and min - d or math.max(0, d - max)
		if d >= DEST_NEAREST and off < miss then
			nearest, miss = { place = place, d = d }, off
		end
	end
	return #fitting > 0 and fitting[math.random(#fitting)] or nearest
end

--- The map's facilities of these kinds ({"garages", ...}) as places {name, pos (the middle of their
--- doors)}; the first kind that has any wins. All kinds without `kinds`.
function M.facilityPlaces(kinds)
	local data = U.facilities()
	if not data then
		return {}
	end
	local order = kinds
	if not order then
		order = {}
		for kind in pairs(data) do
			table.insert(order, kind)
		end
		table.sort(order) -- the same order on every PC
	end
	local places = {}
	for _, kind in ipairs(order) do
		for _, fac in pairs(type(data[kind]) == "table" and data[kind] or {}) do
			local p = type(fac) == "table" and U.facilityDoor(fac)
			if p then
				table.insert(places, {
					name = U.translate(fac.name) or (type(fac.name) == "string" and fac.name) or tostring(fac.id),
					pos = p,
				})
			end
		end
		if kinds and #places > 0 then
			break
		end
	end
	return places
end

function M.sendToVehicle(id, cmd)
	local veh = id and be:getObjectByID(id)
	if veh and type(veh.queueLuaCommand) == "function" then
		veh:queueLuaCommand("if sharedCareerVeh then " .. cmd .. " end")
	end
end

local function serverAllows()
	local c = U.config()
	return c ~= nil and type(c.ui) == "table" and c.ui.jobs == true
end

local function navigate(pos)
	if pos then
		U.setRoute("jobs", pos)
	else
		U.clearRoute("jobs")
	end
end

--== Job types =====================================================================

--- A job type registers itself (see the top of this file for what it brings).
function M.registerType(t)
	if type(t) ~= "table" or type(t.id) ~= "string" then
		return
	end
	if not types[t.id] then
		table.insert(typeOrder, t.id)
	end
	types[t.id] = t
end

-- The job type's status of your job.
local function statusOf(a)
	local ok, s = pcall(a.type.status, a)
	if ok and type(s) == "table" then
		return s
	end
	return { step = 0, text = "", short = "" }
end

--== Making up a job ===============================================================

--- Makes up a new job of a job type and tier (default 1). Returns the job (with its type and tier)
--- or nil and why not.
function M.generate(kind, tier)
	tier = math.max(1, math.floor(tonumber(tier) or 1))
	local t = types[kind]
	if not t then
		return nil, "unknown job type " .. tostring(kind)
	end
	local ok, job, err = pcall(t.generate, tier)
	if not ok or type(job) ~= "table" then
		return nil, tostring(kind) .. ": " .. tostring(ok and err or job)
	end
	job.type, job.tier = kind, tier
	return job
end

--== Your job ======================================================================

-- The job ends here: the type cleans up, no route.
local function endActive()
	if not active then
		return
	end
	local a = active
	active = nil
	pcall(a.type.stop, a)
	navigate(nil)
end

local function startActive(job)
	local t = types[job.type]
	if not t then
		U.log("W", "jobs", "job " .. tostring(job.id) .. " has an unknown type: " .. tostring(job.type))
		return
	end
	active = { id = job.id, job = job, type = t }
	local ok, err = pcall(t.start, active)
	if not ok then
		U.log("E", "jobs", "job start failed: " .. tostring(err))
	end
	active.route = statusOf(active).target
	navigate(active.route)
end

--- The job type: the job is done, and this share of the pay was earned (0..1). Sends it to the
--- server once; the server works out your pay (with your level bonus) and the XP.
function M.handOver(a, share)
	if a ~= active or a.doneSent then
		return
	end
	a.doneSent, a.doneAt = true, clock
	U.send("sc_jobDone", { id = a.id, share = math.max(0, math.min(1, tonumber(share) or 1)) })
end

-- One check of your job (every CHECK_EVERY s).
function M.step(dt)
	if not active then
		return
	end
	if active.paidAt then
		if clock - active.paidAt >= REMOVE_AFTER then
			endActive()
			pushApp()
		end
		return
	end
	if active.doneSent and clock - active.doneAt >= PAID_WAIT then
		U.log("W", "jobs", "no answer from the server to job " .. tostring(active.id) .. " – ended here")
		U.toast("warning", "No answer from the server – job ended", 6)
		endActive()
		pushApp()
		return
	end
	if not active.doneSent then
		active.type.step(active, dt)
	end
	-- the route follows the type's target
	local target = active and not active.paidAt and statusOf(active).target
	if active and target ~= active.route then
		active.route = target
		navigate(target)
	end
end

--== Messages from the server ======================================================

local function mineIn(jobs)
	for _, job in ipairs(jobs) do
		if job.state == "mine" then
			return job
		end
	end
end

local function rxJobs(data)
	local msg = U.decode(data)
	if not msg then
		return
	end
	enabled = msg.enabled == true
	list = type(msg.jobs) == "table" and msg.jobs or {}
	if type(msg.levels) == "table" then
		levels = msg.levels
	end
	local mine = mineIn(list)
	if active and not active.doneSent and (not mine or mine.id ~= active.id) then
		-- taken away (out of time, switched off, given up elsewhere)
		endActive()
	end
	if mine and not active then
		startActive(mine)
	end
	M.registerApp()
	pushApp()
end

local function rxGenerate(data)
	if not enabled or not U.careerActive() then
		return
	end
	local msg = U.decode(data) or {}
	local job, why = M.generate(msg.type, msg.tier)
	if job then
		U.send("sc_jobOffer", job)
	else
		U.log("W", "jobs", "could not make up a job: " .. tostring(why))
	end
end

-- A payout for a finished job: {payout, job, type, title, pay, deduction, xp}. Credited and saved,
-- then confirmed (sc_jobPaidAck); without the confirmation the server sends it again (also after a
-- reconnect). The XP also go to the career: BeamXP and the job type's branch, if the career has them.

-- The career's attribute key of a branch (see "branch" at the top), or nil.
local function branchKey(name)
	local branches = rawget(_G, "career_branches")
	if type(name) ~= "string" or not branches or type(branches.getSortedBranches) ~= "function" then
		return nil
	end
	local ok, list = pcall(branches.getSortedBranches)
	if not ok or type(list) ~= "table" then
		return nil
	end
	local function fits(v)
		if type(v) ~= "string" then
			return false
		end
		local tail = v:sub(-#name - 1)
		return v == name or tail == "/" .. name or tail == "-" .. name or tail == "_" .. name
	end
	for _, b in ipairs(list) do
		if
			type(b) == "table"
			and type(b.attributeKey) == "string"
			and (fits(b.attributeKey) or fits(b.id) or fits(b.pathId))
		then
			return b.attributeKey
		end
	end
	return nil
end
local function rxPaid(data)
	local msg = U.decode(data)
	local pay = msg and tonumber(msg.pay)
	if not msg or type(msg.payout) ~= "string" or not pay or pay < 0 then
		return
	end
	if creditedPayouts[msg.payout] then
		U.send("sc_jobPaidAck", { payout = msg.payout })
		return
	end
	local attributes = rawget(_G, "career_modules_playerAttributes")
	if not U.careerActive() or not attributes or type(attributes.addAttributes) ~= "function" then
		return
	end
	local mine = active ~= nil and active.id == msg.job
	local t = types[msg.type]
	local label = (t and (t.name .. " job") or "Job") .. ": " .. (type(msg.title) == "string" and msg.title or "?")
	local xp = math.max(0, math.floor(tonumber(msg.xp) or 0))
	local change = { money = pay }
	local function has(key)
		local ok, value = pcall(function()
			return type(attributes.getAttribute) == "function" and attributes.getAttribute(key)
		end)
		return ok and value ~= nil and value ~= false
	end
	if xp > 0 then
		if has("beamXP") then
			change.beamXP = xp
		end
		local key = t and branchKey(t.branch)
		if key and has(key) then
			change[key] = xp
		end
	end
	if pay > 0 or xp > 0 then
		local ok, err = pcall(attributes.addAttributes, change, { tags = { "gameplay" }, label = label })
		if not ok then
			U.log("E", "jobs", "could not credit the pay of job " .. tostring(msg.job) .. ": " .. tostring(err))
			return
		end
		U.saveCareer("jobs")
	end
	creditedPayouts[msg.payout] = true
	U.send("sc_jobPaidAck", { payout = msg.payout })
	local deduction = math.max(0, math.floor(tonumber(msg.deduction) or 0))
	U.toast(
		"success",
		string.format("Job done: +$%d", pay)
			.. (deduction > 0 and string.format(" (−$%d damage)", deduction) or "")
			.. (xp > 0 and string.format(" · +%d XP", xp) or ""),
		8
	)
	if mine then
		active.paidAt = clock
		active.route = nil
		navigate(nil)
	end
	pushApp()
end

--== Jobs app (phone) ============================================================

local appOpen = false
local routesLeft = 0 -- drive distances still allowed in this app update
local routesUsed = {} -- keys asked for in this app update; the others are dropped after it

-- The drive distance for the app under a key (a job, your job): worked out again only once the
-- start moved ROUTE_MOVE of it (at least ROUTE_MOVE_MIN m) or the target changed, and at most
-- ROUTES_PER_PUSH per update – until then the last one (nil before the first).
local function routeFor(key, from, to)
	routesUsed[key] = true
	local r = routes[key]
	local fresh = r and r.to.x == to.x and r.to.y == to.y
	if fresh and dist2D(r.from, from) < math.max(ROUTE_MOVE_MIN, r.d * ROUTE_MOVE) then
		return r.d
	end
	if routesLeft <= 0 then
		return fresh and r.d or nil
	end
	routesLeft = routesLeft - 1
	local d = M.driveDistance(from, to)
	routes[key] = d and { from = from, to = to, d = d } or nil
	return d
end

local function iconOf(job)
	local t = types[job.type]
	local ok, icon = pcall(function()
		return t and t.iconOf and t.iconOf(job)
	end)
	return ok and type(icon) == "string" and icon or (t and t.icon) or "?"
end

local function tagsOf(job)
	local t = types[job.type]
	local ok, tags = pcall(function()
		return t and t.tags and t.tags(job)
	end)
	return ok and type(tags) == "table" and tags or {}
end

-- Your level in a job type for the app: {level, share (0..1 of the way to the next level), toGo
-- (XP to the next level; nil at the top)}, or nil before the server has sent it.
local function levelForApp(id)
	local lv = levels[id]
	if type(lv) ~= "table" or not tonumber(lv.level) then
		return nil
	end
	local xp, from, to = tonumber(lv.xp) or 0, tonumber(lv.from) or 0, tonumber(lv.to)
	return {
		level = math.floor(lv.level),
		share = to and to > from and math.max(0, math.min(1, (xp - from) / (to - from))) or 1,
		toGo = to and math.max(0, math.ceil(to - xp)) or nil,
	}
end

-- One job of the list, for the app.
local function jobForApp(job, me)
	return {
		id = job.id,
		icon = iconOf(job),
		title = job.title or "?",
		tags = tagsOf(job),
		dest = job.dest and job.dest.name or "?",
		length = job.length,
		pay = job.pay,
		xp = tonumber(job.xp),
		state = job.state,
		takenBy = job.takenBy,
		locked = job.locked == true,
		minLevel = math.max(1, math.floor(tonumber(job.minLevel) or 1)),
		distance = me and job.pos and routeFor(job.id, me, job.pos) or nil,
	}
end

-- A job type's jobs in groups by the level they need: the ones you can take first, the hardest at
-- the top; the ones you can't take yet at the bottom, the nearest level first.
local function levelGroups(jobs)
	local byLevel, groups = {}, {}
	for _, j in ipairs(jobs) do
		local key = j.minLevel .. (j.locked and "L" or "")
		if not byLevel[key] then
			byLevel[key] = { minLevel = j.minLevel, locked = j.locked, open = 0, jobs = {} }
			table.insert(groups, byLevel[key])
		end
		table.insert(byLevel[key].jobs, j)
		if j.state == "open" then
			byLevel[key].open = byLevel[key].open + 1
		end
	end
	for _, g in ipairs(groups) do
		table.sort(g.jobs, function(a, b)
			if (a.state == "open") ~= (b.state == "open") then
				return a.state == "open"
			end
			return (a.distance or 1e12) < (b.distance or 1e12)
		end)
	end
	table.sort(groups, function(a, b)
		if a.locked ~= b.locked then
			return not a.locked
		end
		if a.locked then
			return a.minLevel < b.minLevel
		end
		return a.minLevel > b.minLevel
	end)
	return groups
end

--- State for the Jobs app: a section per job type (in the order they registered; job types this
--- client doesn't know last) with your level in it and its jobs in groups by level (levelGroups).
--- Your own job is not in the list, it has its own card.
function M.appState()
	local me = U.myPosition()
	routesLeft, routesUsed = ROUTES_PER_PUSH, {}
	-- your job's distance first: it matters most
	local activeStatus, activeDistance
	if active then
		activeStatus = statusOf(active)
		local from = activeStatus.from or me
		activeDistance = from and activeStatus.target and routeFor("active", from, activeStatus.target) or nil
	end
	local byType, order = {}, {}
	local function section(id)
		if not byType[id] then
			local t = types[id]
			byType[id] =
				{ type = id, name = t and t.name or id, icon = t and t.icon or "?", level = levelForApp(id), jobs = {} }
			table.insert(order, id)
		end
		return byType[id]
	end
	for _, id in ipairs(typeOrder) do
		if levels[id] then
			section(id)
		end
	end
	for _, job in ipairs(list) do
		if job.state ~= "mine" and type(job.type) == "string" then
			table.insert(section(job.type).jobs, jobForApp(job, me))
		end
	end
	local rank = {}
	for i, id in ipairs(typeOrder) do
		rank[id] = i
	end
	table.sort(order, function(a, b)
		if (rank[a] ~= nil) ~= (rank[b] ~= nil) then
			return rank[a] ~= nil
		end
		if rank[a] then
			return rank[a] < rank[b]
		end
		return a < b
	end)
	local sections, open = {}, 0
	for _, id in ipairs(order) do
		local sec = byType[id]
		sec.groups, sec.open = levelGroups(sec.jobs), 0
		sec.jobs = nil
		for _, g in ipairs(sec.groups) do
			if not g.locked then
				sec.open = sec.open + g.open
			end
		end
		open = open + sec.open
		table.insert(sections, sec)
	end
	for key in pairs(routes) do
		if not routesUsed[key] then
			routes[key] = nil
		end
	end
	local lic = U.ext("sharedCareer_licenses")
	local state = {
		enabled = enabled and serverAllows(),
		sections = sections,
		open = open,
		licenses = lic and lic.byJobType() or {},
	}
	if active then
		local job, s = active.job, activeStatus
		local steps = active.type.steps or {}
		state.active = {
			id = job.id,
			type = active.type.id,
			icon = iconOf(job),
			title = job.title,
			tags = tagsOf(job),
			dest = job.dest.name,
			pay = job.pay,
			xp = tonumber(job.xp),
			steps = steps,
			step = active.paidAt and math.max(0, #steps - 1) or (s.step or 0),
			phase = active.paidAt and "paid" or (active.doneSent and "checking" or "running"),
			text = s.text,
			short = s.short,
			hint = s.hint,
			inZone = s.inZone == true,
			distance = activeDistance,
		}
	end
	return state
end

function pushApp()
	if guihooks and type(guihooks.trigger) == "function" then
		guihooks.trigger("SharedCareerJobs", M.appState())
	end
end

function M.setAppOpen(on)
	appOpen = on == true
	pushApp()
end

function M.registerApp()
	local phone = U.ext("sharedCareer_phone")
	if not phone or type(phone.registerApp) ~= "function" then
		return
	end
	if serverAllows() then
		phone.registerApp({
			id = "jobs",
			title = "Jobs",
			icon = "jobs",
			color = "#2d6fd8",
			order = 5,
			onOpen = function()
				M.setAppOpen(true)
			end,
			onClose = function()
				M.setAppOpen(false)
			end,
		})
	else
		phone.unregisterApp("jobs")
		appOpen = false
	end
end

-- buttons of the Jobs app
function M.uiTake(id)
	if active then
		U.toast("warning", "Finish your job first", 4)
		return
	end
	U.send("sc_jobTake", { id = tonumber(id) })
end

function M.uiGiveUp()
	if not active or active.doneSent then
		return
	end
	U.send("sc_jobGiveUp", { id = active.id })
	endActive()
	U.toast("info", "Job given up", 4)
	pushApp()
end

function M.uiNavigate()
	if not active or active.paidAt then
		return
	end
	local target = statusOf(active).target
	active.route = target
	navigate(target)
end

function M.uiRequest()
	pushApp()
end

--- Something the app shows changed elsewhere (licenses.lua: a license bought).
function M.refreshApp()
	pushApp()
end

function M.getActive()
	return active
end

--== Markers in the world (for the job types' draw) ==============================

--- A marker floating above p (a ball on a short pole) in a color {r, g, b}, within MARKER_RANGE of you.
function M.drawMarker(p, color)
	local me = U.myPosition()
	if not (debugDrawer and ColorF and vec3) or not me or dist2D(me, p) > MARKER_RANGE then
		return
	end
	local c = ColorF(color[1], color[2], color[3], 0.85)
	local bob = 0.15 * math.sin(clock * 2.5)
	debugDrawer:drawSphere(vec3(p.x, p.y, p.z + 3.2 + bob), 0.35, c)
	debugDrawer:drawCylinder(vec3(p.x, p.y, p.z + 2.3 + bob), vec3(p.x, p.y, p.z + 2.85 + bob), 0.06, c)
end

--- The drop-off zone at d, within MARKER_RANGE of you: a flat ring of `radius` m with a sign, blue;
--- green while you stand in it, the sign counting down the s still to wait (waitLeft).
function M.drawDropOff(d, radius, name, waitLeft)
	local me = U.myPosition()
	if not (debugDrawer and ColorF and vec3) or not me or dist2D(me, d) > MARKER_RANGE then
		return
	end
	local r, g, b = 0.25, 0.55, 1
	if waitLeft then
		r, g, b = 0.3, 0.9, 0.45
	end
	debugDrawer:drawCylinder(vec3(d.x, d.y, d.z + 0.02), vec3(d.x, d.y, d.z + 0.08), radius, ColorF(r, g, b, 0.18))
	debugDrawer:drawCylinder(vec3(d.x, d.y, d.z), vec3(d.x, d.y, d.z + 4), 0.08, ColorF(r, g, b, 0.7))
	local label = waitLeft and string.format("Drop-off \194\183 %d s", math.max(1, math.ceil(waitLeft)))
		or ("Drop-off \194\183 " .. name)
	debugDrawer:drawTextAdvanced(
		vec3(d.x, d.y, d.z + 4.4),
		String and String(label) or label,
		ColorF(1, 1, 1, 1),
		true,
		false,
		ColorI(20, 30, 50, 200)
	)
end

--== Hooks =======================================================================

function M.onUpdate(dtReal)
	local dt = tonumber(dtReal) or 0
	clock = clock + dt
	if not active and not appOpen then
		return
	end
	sinceCheck = sinceCheck + dt
	if sinceCheck >= CHECK_EVERY then
		local stepDt = sinceCheck
		sinceCheck = 0
		local ok, err = pcall(M.step, stepDt)
		if not ok then
			U.log("E", "jobs", "job check failed: " .. tostring(err))
		end
	end
	sincePush = sincePush + dt
	if sincePush >= PUSH_EVERY then
		sincePush = 0
		local menu = U.ext("sharedCareer_menu")
		if appOpen or (menu and menu.isVisible("phone")) then
			pcall(pushApp)
		end
	end
	if active and not active.paidAt and active.type.draw then
		pcall(active.type.draw, active)
	end
end

function M.onVehicleResetted(id)
	if active and not active.paidAt and active.type.vehicleReset then
		pcall(active.type.vehicleReset, active, id)
	end
end

-- The career save's folder: the game names it when it loads a profile (career_saveSystem).
local savePath = nil

function M.onSetProfile(currentSavePath)
	savePath = type(currentSavePath) == "string" and currentSavePath or nil
end

-- The game saves the career: a copy of your levels goes with it (written like the career's own files).
function M.onSaveCurrentProfile(currentSavePath)
	if type(currentSavePath) ~= "string" or not next(levels) then
		return
	end
	savePath = currentSavePath
	local saveSystem = rawget(_G, "career_saveSystem")
	local write = saveSystem and type(saveSystem.jsonWriteFileSafe) == "function" and saveSystem.jsonWriteFileSafe
		or rawget(_G, "jsonWriteFile")
	if type(write) ~= "function" then
		return
	end
	local ok, err = pcall(write, currentSavePath .. LEVELS_FILE, { version = 1, levels = levels }, true)
	if not ok then
		U.log("W", "jobs", "could not save the job levels: " .. tostring(err))
	end
end

function M.onCareerActive(on)
	if on and U.isMP() then
		-- the copy in the save, until the server's list arrives
		local path = savePath
		if path and not next(levels) and type(jsonReadFile) == "function" then
			local ok, saved = pcall(jsonReadFile, path .. LEVELS_FILE)
			if ok and type(saved) == "table" and type(saved.levels) == "table" then
				levels = saved.levels
			end
		end
		M.registerApp()
		U.send("sc_jobsRequest", { types = typeOrder })
	end
end

function M.onConfigChanged()
	M.registerApp()
	pushApp()
end

function M.onBeamMPServerLeave()
	navigate(nil)
	active, list, levels, enabled = nil, {}, {}, false
	appOpen, routes, roadNodes = false, {}, nil
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	U.on("sc_jobs", rxJobs)
	U.on("sc_jobGenerate", rxGenerate)
	U.on("sc_jobPaid", rxPaid)
end

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
