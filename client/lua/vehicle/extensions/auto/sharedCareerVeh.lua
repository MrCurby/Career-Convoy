-- SharedCareer :: vehicle Lua (runs in every vehicle)
--
-- Called from the GE side via queueLuaCommand:
--   setGhost(enabled)              collisions with this vehicle on/off (vehicles.lua; ghost mode
--                                  for other players' cars / players on foot)
--   setAiTuning(gap, sightFactor)  traffic AI reacts earlier to obstacles (traffic.lua)
--   handGrab / handTarget / handRelease   our own node grabber (grab.lua), see "Hand" below
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

--== Hand: our own node grabber =================================================
-- Moves a vehicle by hand, slowly and with physics: a few nodes around the grab point are
-- pulled towards a target point (the GE side moves the target with the player's view).
--   * The grab point moves at most `speed` m/s.
--   * The total force is limited to `strength` % of the vehicle's weight: you can lift one end
--     and drag or push the vehicle, but not float it (with less than 100 %).
--   * The force is split over the grabbed nodes by their mass, so heavy frame nodes take most of
--     it and thin panels hardly any – nothing gets bent.
-- Forces are applied once per frame for that frame (obj:applyForceVectorTime in updateGFX, like
-- the game's container locks do).

local HAND_RADIUS = 0.8   -- m around the grab point
local HAND_MIN_NODES = 4  -- at least this many nodes, even if fewer are inside the radius
local HAND_MAX_NODES = 24
local HAND_KP = 2         -- 1/s: wanted speed = distance to the target * HAND_KP (then limited)
local HAND_TAU = 0.4      -- s: how quickly the vehicle's speed follows the wanted speed
local HAND_LIFT_RAMP = 0.5 -- m: target this much above the grip = carry the full weight
local GRAVITY = 9.81

local hand = nil -- {nodes = {{cid, m}}, gripMass, vehMass, tx, ty, tz, speed, strength}

local function allNodes()
	local nodes = v and v.data and v.data.nodes
	return type(nodes) == "table" and nodes or {}
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
	hand = {nodes = nodes, gripMass = gripMass, vehMass = vehMass, tx = x, ty = y, tz = z,
		speed = tonumber(speed) or 1, strength = tonumber(strength) or 60}
	return true
end

--- New target point (and optionally new speed / strength).
function M.handTarget(x, y, z, speed, strength)
	if not hand then return end
	hand.tx, hand.ty, hand.tz = x, y, z
	if tonumber(speed) then hand.speed = tonumber(speed) end
	if tonumber(strength) then hand.strength = tonumber(strength) end
end

function M.handRelease()
	hand = nil
end

function M.handInfo()
	return hand
end

function M.updateGFX(dt)
	if not hand or not dt or dt <= 0 then return end
	-- where the grip is and how fast it moves (mass-weighted)
	local cx, cy, cz, vx, vy, vz = 0, 0, 0, 0, 0, 0
	for _, n in ipairs(hand.nodes) do
		local p, vel = obj:getAbsNodePosition(n.cid), obj:getNodeVelocityVector(n.cid)
		local w = n.m / hand.gripMass
		cx, cy, cz = cx + p.x * w, cy + p.y * w, cz + p.z * w
		vx, vy, vz = vx + vel.x * w, vy + vel.y * w, vz + vel.z * w
	end
	-- wanted speed towards the target, at most hand.speed
	local wx, wy, wz = (hand.tx - cx) * HAND_KP, (hand.ty - cy) * HAND_KP, (hand.tz - cz) * HAND_KP
	local wl = math.sqrt(wx * wx + wy * wy + wz * wz)
	if wl > hand.speed then
		local f = hand.speed / wl
		wx, wy, wz = wx * f, wy * f, wz * f
	end
	-- force that brings the whole vehicle to that speed, limited to strength % of its weight
	local k = hand.vehMass / HAND_TAU
	local fx, fy, fz = (wx - vx) * k, (wy - vy) * k, (wz - vz) * k
	-- lifting: when the target is above the grip, the hand also carries the weight (fully from
	-- HAND_LIFT_RAMP meters up); at the same height all the force goes into pulling
	local lift = math.max(0, math.min(1, (hand.tz - cz) / HAND_LIFT_RAMP))
	fz = fz + hand.vehMass * GRAVITY * lift
	local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
	local limit = hand.vehMass * GRAVITY * hand.strength / 100
	if fl > limit then
		local f = limit / fl
		fx, fy, fz = fx * f, fy * f, fz * f
	end
	for _, n in ipairs(hand.nodes) do
		local w = n.m / hand.gripMass
		obj:applyForceVectorTime(n.cid, vec3(fx * w, fy * w, fz * w), dt)
	end
end

return M
