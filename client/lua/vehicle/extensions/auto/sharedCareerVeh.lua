-- SharedCareer :: vehicle Lua (runs in every vehicle)
--
-- Called from the GE side via queueLuaCommand:
--   setGhost(enabled)              collisions with this vehicle on/off (vehicles.lua; ghost mode
--                                  for other players' cars / players on foot)
--   setAiTuning(gap, sightFactor)  traffic AI reacts earlier to obstacles (traffic.lua)
--   handGrabRay / handGrabNearest / handRope / handRelease / handProbe
--                                  our own node grabber as a rope (grab.lua), see "Hand" below
--
-- AI tuning: two values inside the game's lua/vehicle/ai.lua that have no official setter.
--   ego.race_time_gap      safety gap in seconds that the AI keeps to a vehicle on its path
--                          (game: 0.3 s). Larger = starts braking earlier, keeps more distance.
--   traffic.Rfl_fun(speed) how far ahead (meters) the AI checks its path for other vehicles
--                          (game: (speed + 10) * 3, clamped to 60..200 m). Larger factor = sees
--                          obstacles earlier.
-- Both live in local tables of ai.lua. They are found through the upvalues of the functions
-- in the `ai` module (Lua debug library), never by editing game files. If they can't be found
-- (a game update renamed them, or the debug library is unavailable), nothing is changed and
-- one line is logged. A value of 0 restores the game's own value.

local M = {}

local SEARCH_DEPTH = 4

function M.setGhost(enabled)
	obj:setGhostEnabled(enabled and true or false)
end

--== Finding the AI tables =====================================================

-- Walks the upvalues of all functions in the ai module (and of functions found there) and
-- returns the `ego` and `traffic` tables, or nil for the ones that weren't found.
local function findAiTables(aiModule)
	if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then return nil, nil end
	local ego, traffic
	local visited = {}
	local queue = {}
	for _, fn in pairs(aiModule) do
		if type(fn) == "function" and not visited[fn] then
			visited[fn] = true
			table.insert(queue, {fn, 1})
		end
	end
	local head = 1
	while head <= #queue and not (ego and traffic) do
		local fn, depth = queue[head][1], queue[head][2]
		head = head + 1
		local i = 1
		while true do
			local ok, name, value = pcall(debug.getupvalue, fn, i)
			if not ok or name == nil then break end
			if name == "ego" and type(value) == "table" and type(value.race_time_gap) == "number" then
				ego = value
			elseif name == "traffic" and type(value) == "table" and type(value.Rfl_fun) == "function" then
				traffic = value
			elseif type(value) == "function" and not visited[value] and depth < SEARCH_DEPTH then
				visited[value] = true
				table.insert(queue, {value, depth + 1})
			end
			i = i + 1
		end
	end
	return ego, traffic
end
M.findAiTables = findAiTables

--== Applying the values =======================================================

local original = nil   -- {gap, sight} = the game's values, remembered on first use
local warned = false

local function sightFunction(factor)
	local maxRange = math.max(200, math.min(300, 60 * factor))
	return function(speed)
		return math.max(60, math.min(maxRange, ((tonumber(speed) or 0) + 10) * factor))
	end
end

--- gap: safety gap in seconds (0 = game value). sightFactor: range factor (0 = game value).
--- Returns true if the AI tables were found.
function M.setAiTuning(gap, sightFactor)
	if type(ai) ~= "table" then return false end
	local ego, traffic = findAiTables(ai)
	if not ego or not traffic then
		if not warned then
			warned = true
			log("W", "sharedCareer.ai", "AI tuning not applied: ai.lua internals not found (game update?)")
		end
		return false
	end
	gap, sightFactor = tonumber(gap) or 0, tonumber(sightFactor) or 0
	if not original then
		original = {gap = ego.race_time_gap, sight = traffic.Rfl_fun}
		-- once per vehicle, so an in-game test can confirm it in beamng.log
		-- (pcall: only a log line, it must never stop the tuning itself)
		pcall(function()
			log("I", "sharedCareer.ai", string.format("AI tuning active: safety gap %.2f s -> %.2f s, sight range at 100 km/h %d m -> %d m",
				original.gap, gap > 0 and gap or original.gap, math.floor(original.sight(27.8) + 0.5),
				math.floor((sightFactor > 0 and sightFunction(sightFactor) or original.sight)(27.8) + 0.5)))
		end)
	end
	ego.race_time_gap = gap > 0 and gap or original.gap
	traffic.Rfl_fun = sightFactor > 0 and sightFunction(sightFactor) or original.sight
	return true
end

--== Hand: our own node grabber, as a rope =======================================
-- A rope from a vehicle to an anchor point that the GE side places (grab.lua). The rope is tied to
-- one node (the one you aimed at, the "tie node"); its pull is spread over the nodes around it (the
-- grip). It behaves like a real rope with a winch:
--   * it only pulls when it is taut (distance tie node -> anchor longer than the rope); it never
--     pushes
--   * while the anchor is being moved, the winch pays out rope, so the vehicle stays where it is
--   * winch 1 (haul in): the rope is hauled in at most `speed` m/s and the vehicle is pulled to
--     the anchor; the winch also brakes (up to half the force limit), so it doesn't roll past it
--   * winch 0 (stop): the rope length stays, the vehicle hangs on it
--   * winch -1 (pay out): the rope gets longer at `speed` m/s, e.g. to lower a lifted end
--   * the pull is limited to `strength` % of the vehicle's weight: you can lift one end and drag
--     the vehicle, but not float it (below 100 %)
--   * if the vehicle doesn't follow (handbrake, gear in park, a wheel against a curb), the pull
--     builds up to the limit within about 2 s, like a winch working harder; once the vehicle
--     moves at the wanted speed it eases off again
--   * the force is split over the grip nodes by their mass, so thin panels don't bend
-- Forces are applied once per frame for that frame (obj:applyForceVectorTime in updateGFX, like
-- the game's container locks do). A long frame (a hitch) counts as at most HAND_MAX_DT, so the rope
-- never gives a jolt in an old direction.
--
-- The rope comes off by itself and tells the GE side (sharedCareer_grab.onHandLost(id, reason)):
--   LOST_NO_GRIP  nothing to grab where you aimed
--   LOST_RESET    the vehicle was reset (onReset) – the rope would pull it back to the old anchor
--   LOST_JUMP     the vehicle jumped (moved without a reset, e.g. teleported)
--   LOST_TORN     the tie node moved far from the vehicle's reference node: the part tore off or
--                 bent away; pulling on would only drag the loose part

local HAND_RADIUS = 0.8   -- m around the grab point
local HAND_MIN_NODES = 4  -- at least this many nodes, even if fewer are inside the radius
local HAND_MAX_NODES = 24
local HAND_KP = 2         -- 1/s: wanted speed = distance to the target * HAND_KP (then limited)
local HAND_TAU = 0.4      -- s: how quickly the vehicle's speed follows the wanted speed
local HAND_LIFT_RAMP = 0.3 -- m of stretch at which an upward rope carries the full weight
local HAND_MAX_DT = 0.05   -- s: the longest frame the rope works with
local HAND_JUMP = 2        -- m the tie node may move in one frame beyond what its speed explains
local HAND_TEAR = 2        -- m the tie node may move away from (or towards) the reference node
local ROPE_MIN = 0.5       -- m: the winch doesn't haul in further than this
local ROPE_MAX = 150       -- m: the winch doesn't pay out further than this
local SLACK_BELOW = 0.02   -- m of stretch: a taut rope counts as slack again below this
local TAUT_ABOVE = 0.08    -- m of stretch: a slack rope counts as taut above this (no flicker)
local WINCH_BRAKE = 0.5    -- share of the force limit the running winch may use to brake
local BOOST_RISE = 0.5     -- share of the force limit per second the pull builds up while stuck
local BOOST_FALL = 2       -- share of the force limit per second it eases off once it moves
local GRAVITY = 9.81

local LOST_NO_GRIP, LOST_RESET, LOST_JUMP, LOST_TORN = 0, 1, 2, 3

local HAND_REPORT_EVERY = 0.1 -- s: how often the rope state goes back to the GE side

local hand = nil -- {nodes = {{cid, m}}, tie (cid), ref (cid), refDist, gripMass, vehMass,
                 --  ax, ay, az (anchor), length, winch, moving, speed, strength, strain, slack,
                 --  boost, since, last = {x, y, z} (tie node one frame ago)}

-- tell the GE side (grab.lua) something about this vehicle
local function reportToGE(fn, fmt, ...)
	if type(obj.queueGameEngineLua) ~= "function" then return end
	local args = fmt and (", " .. string.format(fmt, ...)) or ""
	obj:queueGameEngineLua(string.format("if sharedCareer_grab then sharedCareer_grab.%s(%d%s) end",
		fn, obj:getId(), args))
end

local function lose(reason)
	hand = nil
	reportToGE("onHandLost", "%d", reason)
end

local function allNodes()
	local nodes = v and v.data and v.data.nodes
	return type(nodes) == "table" and nodes or {}
end

-- the vehicle's reference node (the game's refNodes[0].ref), or nil
local function refNode()
	local refs = v and v.data and v.data.refNodes
	local r = type(refs) == "table" and refs[0]
	return type(r) == "table" and r.ref or nil
end

local function distance(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Grabs the nodes around the world point x/y/z. speed in m/s, strength in % of the weight.
function M.handGrab(x, y, z, speed, strength)
	local found, vehMass = {}, 0
	for _, node in pairs(allNodes()) do
		local cid = type(node) == "table" and node.cid
		if cid then
			local m = tonumber(obj:getNodeMass(cid)) or 0
			vehMass = vehMass + m
			local p = obj:getAbsNodePosition(cid)
			local dx, dy, dz = p.x - x, p.y - y, p.z - z
			table.insert(found, {cid = cid, m = m, d2 = dx * dx + dy * dy + dz * dz})
		end
	end
	table.sort(found, function(a, b) return a.d2 < b.d2 end)
	local nodes, gripMass = {}, 0
	for i, n in ipairs(found) do
		if i > HAND_MAX_NODES or (i > HAND_MIN_NODES and n.d2 > HAND_RADIUS * HAND_RADIUS) then break end
		if n.m > 0 then
			table.insert(nodes, n)
			gripMass = gripMass + n.m
		end
	end
	if #nodes == 0 or gripMass <= 0 or vehMass <= 0 then
		hand = nil
		return false
	end
	local tie, ref = nodes[1].cid, refNode()
	hand = {nodes = nodes, tie = tie, ref = ref, gripMass = gripMass, vehMass = vehMass, ax = x, ay = y, az = z,
		refDist = ref and distance(obj:getAbsNodePosition(tie), obj:getAbsNodePosition(ref)) or nil,
		length = nil, winch = 0, moving = false, boost = 0, slack = true,
		speed = tonumber(speed) or 1, strength = tonumber(strength) or 60, strain = 0,
		since = HAND_REPORT_EVERY}
	return true
end

-- The node closest to a ray (camera position + direction): {cid, t, x, y, z} or nil.
-- t = distance along the ray.
local function nodeOnRay(cx, cy, cz, dx, dy, dz, maxDist)
	local best = nil
	for _, node in pairs(allNodes()) do
		local cid = type(node) == "table" and node.cid
		if cid then
			local p = obj:getAbsNodePosition(cid)
			local rx, ry, rz = p.x - cx, p.y - cy, p.z - cz
			local t = rx * dx + ry * dy + rz * dz
			if t > 0.3 and t <= maxDist then
				local mx, my, mz = rx - dx * t, ry - dy * t, rz - dz * t
				local miss = mx * mx + my * my + mz * mz
				-- closest to the ray; among nearly equal ones the front-most (the one you see)
				if not best or miss < best.miss - 0.01 or (miss < best.miss + 0.01 and t < best.t) then
					best = {cid = cid, t = t, miss = miss, x = p.x, y = p.y, z = p.z}
				end
			end
		end
	end
	return best
end

-- after a grab: tell the GE side where the rope is tied (distance, position, tie node)
local function reportGrip(t)
	local p = obj:getAbsNodePosition(hand.tie)
	reportToGE("onGrip", "%.3f, %.3f, %.3f, %.3f, %d", t, p.x, p.y, p.z, hand.tie)
end

--- Grabs the vehicle where the view ray from the camera meets it (the node closest to the ray)
--- and reports the grip back: sharedCareer_grab.onGrip(id, t, x, y, z, tie node).
function M.handGrabRay(cx, cy, cz, dx, dy, dz, maxDist, speed, strength)
	local n = nodeOnRay(cx, cy, cz, dx, dy, dz, tonumber(maxDist) or 120)
	if not n or not M.handGrab(n.x, n.y, n.z, speed, strength) then
		lose(LOST_NO_GRIP)
		return false
	end
	reportGrip(n.t)
	return true
end

--- Grabs the vehicle at the node closest to a point (the player's camera) – for "attach" from the
--- phone's vehicle list. Reports sharedCareer_grab.onGrip like handGrabRay.
function M.handGrabNearest(px, py, pz, speed, strength)
	local best = nil
	for _, node in pairs(allNodes()) do
		local cid = type(node) == "table" and node.cid
		if cid then
			local p = obj:getAbsNodePosition(cid)
			local dx, dy, dz = p.x - px, p.y - py, p.z - pz
			local d2 = dx * dx + dy * dy + dz * dz
			if not best or d2 < best.d2 then best = {d2 = d2, x = p.x, y = p.y, z = p.z} end
		end
	end
	if not best or not M.handGrab(best.x, best.y, best.z, speed, strength) then
		lose(LOST_NO_GRIP)
		return false
	end
	reportGrip(math.sqrt(best.d2))
	return true
end

--- Preview: where would "attach where I look" grab? Reports sharedCareer_grab.onProbe(id, x, y, z).
function M.handProbe(cx, cy, cz, dx, dy, dz, maxDist)
	local n = nodeOnRay(cx, cy, cz, dx, dy, dz, tonumber(maxDist) or 120)
	if n then reportToGE("onProbe", "%.3f, %.3f, %.3f", n.x, n.y, n.z) end
end

--- Rope state from the GE side: anchor point, winch (1 haul in, 0 stop, -1 pay out), anchor being
--- moved, settings.
function M.handRope(ax, ay, az, winch, moving, speed, strength)
	if not hand then return end
	hand.ax, hand.ay, hand.az = ax, ay, az
	if winch == true then winch = 1 elseif winch == false then winch = 0 end
	winch = tonumber(winch) or 0
	hand.winch = winch > 0 and 1 or (winch < 0 and -1 or 0)
	hand.moving = moving == true or moving == 1
	if tonumber(speed) then hand.speed = tonumber(speed) end
	if tonumber(strength) then hand.strength = tonumber(strength) end
end

function M.handRelease()
	hand = nil
end

function M.handInfo()
	return hand
end

-- the vehicle was reset (R, recovery, a new config): the rope must not pull it back
function M.onReset()
	if hand then lose(LOST_RESET) end
end

function M.updateGFX(dt)
	if not hand or not dt or dt <= 0 then return end
	local tie = obj:getAbsNodePosition(hand.tie)
	local tx, ty, tz = tie.x, tie.y, tie.z
	-- how fast the grip moves (mass-weighted)
	local vx, vy, vz = 0, 0, 0
	for _, n in ipairs(hand.nodes) do
		local vel = obj:getNodeVelocityVector(n.cid)
		local w = n.m / hand.gripMass
		vx, vy, vz = vx + vel.x * w, vy + vel.y * w, vz + vel.z * w
	end
	-- jumped further than its speed explains: moved by the game (teleport), not by the rope
	local last = hand.last
	if last then
		local jx, jy, jz = tx - last.x - vx * dt, ty - last.y - vy * dt, tz - last.z - vz * dt
		if jx * jx + jy * jy + jz * jz > HAND_JUMP * HAND_JUMP then
			lose(LOST_JUMP)
			return
		end
	end
	hand.last = {x = tx, y = ty, z = tz}
	if hand.ref and hand.refDist
		and math.abs(distance(tie, obj:getAbsNodePosition(hand.ref)) - hand.refDist) > HAND_TEAR then
		lose(LOST_TORN)
		return
	end
	dt = math.min(dt, HAND_MAX_DT)
	local dx, dy, dz = hand.ax - tx, hand.ay - ty, hand.az - tz
	local d = math.sqrt(dx * dx + dy * dy + dz * dz)
	-- rope length: starts at the current distance; paid out while the anchor is moved; hauled in
	-- by the winch
	if not hand.length then hand.length = d end
	if hand.winch == 1 then
		hand.length = math.max(ROPE_MIN, math.min(hand.length, d) - hand.speed * dt)
	elseif hand.winch == -1 then
		hand.length = math.min(ROPE_MAX, math.max(hand.length, hand.moving and d or 0) + hand.speed * dt)
	elseif hand.moving then
		hand.length = math.max(hand.length, d)
	end
	local tension = 0
	local limit = hand.vehMass * GRAVITY * hand.strength / 100
	local stretch = d - hand.length
	-- a taut rope pulls; a running winch also brakes near its end (it holds on to the vehicle)
	local active = d > 0.001 and (stretch > 0.001 or hand.winch == 1)
	if active then
		local ux, uy, uz = dx / d, dy / d, dz / d
		-- wanted speed along the rope: towards the anchor, at most hand.speed (0 at the rope's end)
		local want = math.max(0, math.min(hand.speed, stretch * HAND_KP))
		local along = vx * ux + vy * uy + vz * uz
		tension = hand.vehMass / HAND_TAU * (want - along)
		-- stuck (slower than wanted): build up an extra pull, step by step up to the limit
		if want - along > 0.1 then
			hand.boost = math.min(limit, hand.boost + limit * BOOST_RISE * dt)
		else
			hand.boost = math.max(0, hand.boost - limit * BOOST_FALL * dt)
		end
		tension = tension + hand.boost
		-- an upward rope also carries the weight once it is stretched a bit
		tension = tension + hand.vehMass * GRAVITY * math.max(0, uz) * math.min(1, math.max(0, stretch) / HAND_LIFT_RAMP)
		-- a rope only pulls; the running winch may also brake a little
		local minTension = hand.winch == 1 and -limit * WINCH_BRAKE or 0
		tension = math.max(minTension, math.min(limit, tension))
		if tension ~= 0 then
			for _, n in ipairs(hand.nodes) do
				local f = tension * n.m / hand.gripMass
				obj:applyForceVectorTime(n.cid, vec3(ux * f, uy * f, uz * f), dt)
			end
		end
	else
		hand.boost = 0
	end
	-- slack or taut, with a margin in between so the display doesn't flicker
	if hand.slack then
		hand.slack = stretch <= TAUT_ABOVE
	else
		hand.slack = stretch < SLACK_BELOW
	end
	-- strain: share of the force limit in use (1 = at the limit), smoothed for the display
	hand.strain = hand.strain + (math.abs(tension) / limit - hand.strain) * math.min(1, dt * 6)
	hand.since = hand.since + dt
	if hand.since >= HAND_REPORT_EVERY then
		hand.since = 0
		reportToGE("onHandState", "%.3f, %.3f, %.3f, %.2f, %d, %.2f", tx, ty, tz, hand.strain,
			hand.slack and 1 or 0, hand.length)
	end
end

return M
