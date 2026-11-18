-- SharedCareer :: vehicle Lua (runs in every vehicle)
--
-- Called from the GE side via queueLuaCommand:
--   setGhost(enabled)              collisions with this vehicle on/off (vehicles.lua; ghost mode
--                                  for other players' cars / players on foot)
--   setAiTuning(gap, sightFactor)  traffic AI reacts earlier to obstacles (traffic.lua)
--   handGrabRay / handGrabNearest / handRope / handRelease / handProbe
--                                  our own node grabber as a rope (grab.lua), see "Hand" below
--   anchorFind / anchorPull / anchorRelease   this vehicle holds the other end of a rope (its tow
--                                  hitch), see "Anchor on a vehicle" below
--   jobBreakDown / jobReportDamage the broken-down vehicle of a towing job (jobs.lua), see
--                                  "Towing jobs" below
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
-- grip) by their mass, so thin panels don't bend. It is computed like a real winch line:
--   * stiff: under the vehicle's weight it stretches ROPE_STRAIN of its length (at least
--     ROPE_STRETCH_MIN), like a steel or synthetic winch line, so it catches the vehicle instead of
--     springing it back like rubber; what is left of a swing (a cm or so) dies down quickly through
--     the rope's own damping
--   * it only pulls when it is taut (tie node farther from the anchor than the rope is long); it
--     never pushes
--   * winch 1 (haul in): the motor winds the rope in at most `speed` m/s; the harder the rope
--     pulls, the slower it turns (like a winch's series-wound motor: WINCH_FULL_LOAD of the speed
--     just below the pull limit), and at the pull limit (`strength` % of the vehicle's weight) it
--     stalls. Over the last WINCH_SOFT_END m before ROPE_MIN it slows down
--   * winch -1 (pay out): the rope gets longer at `speed` m/s, e.g. to lower a lifted end
--   * the motor needs a moment to get up to speed (WINCH_ACCEL_IN); paying out, the drum speeds up
--     slowly (WINCH_ACCEL_OUT), so a hanging load follows it instead of dropping into the rope
--   * winch 0 (stop): the rope length stays, the vehicle hangs on it
--   * while the anchor is being moved, the drum turns freely: the rope pays out, the vehicle stays.
--     An anchor that jumps more than ANCHOR_JUMP between two messages was placed somewhere else
--     ("to my view"): the rope pays out to it as well – a jump is no shock load on the rope
--   * the anchor can sit on another vehicle (its tow hitch, see "Anchor on a vehicle"): then it
--     moves with that vehicle. The GE side sends its position and speed every frame; between two
--     messages it moves on at that speed (so a fast tow doesn't jolt the rope), the rope's damping
--     works on the speed between the two vehicles, and the pull on the anchor vehicle goes back
--     every frame (onRopePull) – the GE side hands it on, so the towing vehicle feels the load
--   * the brake (and the motor's gear while hauling in) holds BRAKE_HOLD times the pull limit;
--     above that it slips and lets out rope at most BRAKE_SLIP m/s
--   * the rope snaps above ROPE_BREAK times the vehicle's weight: only a shock load does that, e.g.
--     a vehicle that drops or drives into the taut rope; the winch alone can't break it
-- The rope is computed at the physics rate (onPhysicsStep, about 2000 times per second, switched
-- on with the game's enablePhysicsStepHook once a rope is attached); only that makes a stiff rope
-- possible. If the game doesn't offer the hook, the same runs once per frame in updateGFX with
-- forces for the whole frame (obj:applyForceVectorTime), and the rope is made as soft as a frame
-- needs to stay stable (STABLE_K, STABLE_C). A long frame (a hitch) counts as at most HAND_MAX_DT.
-- An error in the physics step is logged once and the rope goes on once per frame (never takes the
-- vehicle down).
--
-- The rope comes off by itself and tells the GE side (sharedCareer_grab.onHandLost(id, reason)):
--   LOST_NO_GRIP  nothing to grab where you aimed
--   LOST_RESET    the vehicle was reset (onReset) – the rope would pull it back to the old anchor
--   LOST_JUMP     the vehicle jumped (moved without a reset, e.g. teleported)
--   LOST_TORN     the tie node moved far from the vehicle's reference node: the part tore off or
--                 bent away; pulling on would only drag the loose part
--   LOST_SNAPPED  the rope itself snapped (overload)

local HAND_RADIUS = 0.8   -- m around the grab point
local HAND_MIN_NODES = 4  -- at least this many nodes, even if fewer are inside the radius
local HAND_MAX_NODES = 24
local VELOCITY_NODES = 6  -- the grip's speed is measured on its heaviest nodes
local HAND_MAX_DT = 0.05  -- s: the longest frame the rope works with (without the physics step)
local HAND_JUMP = 2       -- m the tie node may move in one frame beyond what its speed explains
local HAND_TEAR = 2       -- m the tie node may move away from (or towards) the reference node
local ROPE_MIN = 0.5      -- m: the winch doesn't haul in further than this
local ROPE_MAX = 150      -- m: the winch doesn't pay out further than this
local ROPE_STRAIN = 0.005 -- share of its length the rope stretches under the vehicle's weight
local ROPE_STRETCH_MIN = 0.01 -- m it stretches at least under the vehicle's weight (a short rope)
local ROPE_DAMPING = 0.3  -- the rope's own damping, as a share of critical damping (for the vehicle)
local ROPE_BREAK = 4      -- the rope snaps at this many times the vehicle's weight
local BREAK_FILTER = 0.01 -- s the tension is averaged over before it can snap the rope
local BRAKE_HOLD = 1.5    -- the brake holds this many times the pull limit
local BRAKE_SLIP = 0.5    -- m/s the brake lets out at most when it slips
local WINCH_SOFT_END = 1  -- m before ROPE_MIN over which the winch slows down
local WINCH_SOFT_MIN = 0.15 -- share of the speed it keeps at the very end
local WINCH_ACCEL_IN = 10 -- m/s^2 the motor speeds up hauling in (about 0.1 s to full speed)
local WINCH_ACCEL_OUT = 2 -- m/s^2 the drum speeds up and slows down paying out (a hanging load
                          -- follows it instead of dropping into the rope)
local WINCH_FULL_LOAD = 0.2 -- share of the speed the motor still makes just below the pull limit
local TAUT_ABOVE = 0.03   -- share of the weight: a slack rope counts as taut above this tension
local SLACK_BELOW = 0.01  -- share of the weight: a taut rope counts as slack again below this
local STABLE_K = 0.25     -- stiffness limit for a stable step: k * dt^2 / grip mass
local STABLE_C = 0.5      -- damping limit for a stable step: c * dt / grip mass
local ANCHOR_JUMP = 0.2   -- m the anchor may move between two messages before it counts as placed
local GRAVITY = 9.81

local LOST_NO_GRIP, LOST_RESET, LOST_JUMP, LOST_TORN, LOST_SNAPPED = 0, 1, 2, 3, 4

local HAND_REPORT_EVERY = 0.1 -- s: how often the rope state goes back to the GE side

local hand = nil -- {nodes = {{cid, m}}, velNodes = {{cid, w}}, tie (cid), ref (cid), refDist,
                 --  gripMass, vehMass, ax, ay, az (anchor), placed (it jumped: pay out to it),
                 --  onVehicle (the anchor is on a vehicle), avx, avy, avz (the anchor's speed),
                 --  pullX, pullY, pullZ (force on the anchor, summed over the frame's steps),
                 --  length, drum (m/s the rope runs out, < 0 = in), winch, moving, speed, strength,
                 --  tension (last step), tensionF (averaged for snapping), tensionSum, tensionTime
                 --  (since the last frame), strain, slack, since, last = {x, y, z} (tie node one
                 --  frame ago)}
local physicsStep = false -- the game calls onPhysicsStep for this vehicle

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
	-- the grip's speed: measured on its heaviest nodes (light panel nodes shake)
	local heavy = {}
	for _, n in ipairs(nodes) do table.insert(heavy, n) end
	table.sort(heavy, function(a, b) return a.m > b.m end)
	local velNodes, velMass = {}, 0
	for i = 1, math.min(VELOCITY_NODES, #heavy) do velMass = velMass + heavy[i].m end
	for i = 1, math.min(VELOCITY_NODES, #heavy) do table.insert(velNodes, {cid = heavy[i].cid, w = heavy[i].m / velMass}) end
	local tie, ref = nodes[1].cid, refNode()
	hand = {nodes = nodes, velNodes = velNodes, tie = tie, ref = ref, gripMass = gripMass, vehMass = vehMass,
		ax = x, ay = y, az = z,
		refDist = ref and distance(obj:getAbsNodePosition(tie), obj:getAbsNodePosition(ref)) or nil,
		length = nil, drum = 0, winch = 0, moving = false, slack = true,
		speed = tonumber(speed) or 1, strength = tonumber(strength) or 60,
		tension = 0, tensionF = 0, tensionSum = 0, tensionTime = 0, strain = 0,
		avx = 0, avy = 0, avz = 0, pullX = 0, pullY = 0, pullZ = 0,
		since = HAND_REPORT_EVERY}
	-- the rope is computed at the physics rate from now on (see above)
	if not physicsStep and type(enablePhysicsStepHook) == "function" then
		local ok, err = pcall(enablePhysicsStepHook)
		physicsStep = ok
		if not ok then log("W", "sharedCareer.rope", "physics-step hook not available, rope once per frame: " .. tostring(err)) end
	end
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
--- moved, settings; onVehicle = 1: the anchor sits on a vehicle and moves at avx/avy/avz m/s.
function M.handRope(ax, ay, az, winch, moving, speed, strength, avx, avy, avz, onVehicle)
	if not hand then return end
	hand.onVehicle = onVehicle == 1 or onVehicle == true
	-- an anchor on a vehicle moves by itself; only a jump elsewhere means it was placed
	if not hand.onVehicle then
		local jump = math.sqrt((ax - hand.ax) ^ 2 + (ay - hand.ay) ^ 2 + (az - hand.az) ^ 2)
		if jump > ANCHOR_JUMP then hand.placed = true end
	end
	hand.ax, hand.ay, hand.az = ax, ay, az
	if hand.onVehicle then
		hand.avx, hand.avy, hand.avz = tonumber(avx) or 0, tonumber(avy) or 0, tonumber(avz) or 0
	else
		hand.avx, hand.avy, hand.avz = 0, 0, 0
	end
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

-- the grip's speed (mass-weighted over its heaviest nodes)
local function gripVelocity()
	local vx, vy, vz = 0, 0, 0
	for _, n in ipairs(hand.velNodes) do
		local vel = obj:getNodeVelocityVector(n.cid)
		vx, vy, vz = vx + vel.x * n.w, vy + vel.y * n.w, vz + vel.z * n.w
	end
	return vx, vy, vz
end

-- One step of the rope: the winch changes the rope's length, a taut rope pulls the grip towards
-- the anchor. perFrame: forces for the whole frame (no physics step).
local function ropeStep(dt, perFrame)
	local h = hand
	-- an anchor on a vehicle moves on at its speed until the next message
	h.ax, h.ay, h.az = h.ax + h.avx * dt, h.ay + h.avy * dt, h.az + h.avz * dt
	local tie = obj:getAbsNodePosition(h.tie)
	local dx, dy, dz = h.ax - tie.x, h.ay - tie.y, h.az - tie.z
	local d = math.sqrt(dx * dx + dy * dy + dz * dz)
	if not h.length then h.length = d end
	local weight = h.vehMass * GRAVITY
	local pull = weight * h.strength / 100
	-- the winch: the motor slows down under load and stalls at once at the pull limit (it can't
	-- pull harder); otherwise the drum follows the wanted speed at its acceleration
	local want = 0
	if h.winch == 1 then
		local soft = math.max(WINCH_SOFT_MIN, math.min(1, (h.length - ROPE_MIN) / WINCH_SOFT_END))
		local load = h.tension / pull
		want = load >= 1 and 0 or -h.speed * soft * (1 - (1 - WINCH_FULL_LOAD) * load)
	elseif h.winch == -1 then
		want = h.speed
	end
	local step = (h.winch == 1 and WINCH_ACCEL_IN or WINCH_ACCEL_OUT) * dt
	h.drum = h.drum + math.max(-step, math.min(step, want - h.drum))
	if h.winch == 1 then h.drum = math.max(h.drum, want) end -- the motor stalls at once under load
	h.length = math.max(ROPE_MIN, math.min(ROPE_MAX, h.length + h.drum * dt))
	if h.moving then h.length = math.max(h.length, d) end
	if h.placed then
		h.length = math.min(ROPE_MAX, math.max(h.length, d))
		h.placed = false
	end
	-- the brake slips under too much load
	if h.winch ~= -1 and h.tension > pull * BRAKE_HOLD then
		h.length = math.min(ROPE_MAX, h.length + BRAKE_SLIP * dt)
	end
	-- a taut rope: stiff spring with about critical damping, pulling only
	local tension = 0
	local stretch = d - h.length
	if stretch > 0 and d > 0.001 then
		local ux, uy, uz = dx / d, dy / d, dz / d
		local vx, vy, vz = gripVelocity()
		-- the stretch grows when the grip moves away from the anchor (or the anchor away from the
		-- grip) and when the drum winds in
		local stretchRate = -((vx - h.avx) * ux + (vy - h.avy) * uy + (vz - h.avz) * uz) - h.drum
		local k = weight / math.max(ROPE_STRETCH_MIN, ROPE_STRAIN * h.length)
		k = math.min(k, STABLE_K * h.gripMass / (dt * dt))
		local c = math.min(ROPE_DAMPING * 2 * math.sqrt(k * h.vehMass), STABLE_C * h.gripMass / dt)
		tension = math.max(0, k * stretch + c * stretchRate)
		for _, n in ipairs(h.nodes) do
			local f = tension * n.m / h.gripMass
			if perFrame then
				obj:applyForceVectorTime(n.cid, vec3(ux * f, uy * f, uz * f), dt)
			else
				obj:applyForceVector(n.cid, vec3(ux * f, uy * f, uz * f))
			end
		end
		-- the same pull, the other way, on the anchor
		h.pullX, h.pullY, h.pullZ = h.pullX - ux * tension * dt, h.pullY - uy * tension * dt, h.pullZ - uz * tension * dt
	end
	h.tension = tension
	h.tensionSum, h.tensionTime = h.tensionSum + tension * dt, h.tensionTime + dt
	h.tensionF = h.tensionF + (tension - h.tensionF) * math.min(1, dt / BREAK_FILTER)
	if h.tensionF > ROPE_BREAK * weight then lose(LOST_SNAPPED) end
end

--== Anchor on a vehicle: this vehicle holds the other end of a rope ===============
-- anchorFind(px, py, pz): the point where the rope is tied to this vehicle – its tow hitch (a
-- coupler node whose tag names a hitch, fifth wheel or gooseneck), the one closest to the roped
-- vehicle (px, py, pz) if there are several; without one, the node closest to it. Reports
-- sharedCareer_grab.onAnchorNode(id, node, isHitch). anchorPull(fx, fy, fz): the rope's pull on
-- this vehicle (N, from the roped vehicle, every frame), spread over the nodes around the anchor
-- node by their mass like the grip; it stops by itself ANCHOR_PULL_KEEP s after the last message.
-- anchorRelease(): no more rope on this vehicle.

local ANCHOR_PULL_KEEP = 0.25 -- s a pull message is applied without a new one
local HITCH_TAGS = {"hitch", "fifthwheel", "gooseneck"}

local anchor = nil -- {node, nodes = {{cid, m}}, mass, fx, fy, fz, age}

local function isHitch(node)
	local tag = node.couplerTag or node.tag
	if type(tag) ~= "string" then return false end
	tag = tag:lower()
	for _, t in ipairs(HITCH_TAGS) do
		if tag:find(t, 1, true) then return true end
	end
	return false
end

function M.anchorFind(px, py, pz)
	local target = {x = tonumber(px) or 0, y = tonumber(py) or 0, z = tonumber(pz) or 0}
	local bestHitch, bestAny
	for _, node in pairs(allNodes()) do
		local cid = type(node) == "table" and node.cid
		if cid then
			local d = distance(obj:getAbsNodePosition(cid), target)
			if isHitch(node) and (not bestHitch or d < bestHitch.d) then bestHitch = {cid = cid, d = d} end
			if not bestAny or d < bestAny.d then bestAny = {cid = cid, d = d} end
		end
	end
	local pick = bestHitch or bestAny
	if not pick then return false end
	-- the nodes around the anchor node carry the pull (like the grip of the roped vehicle)
	local center = obj:getAbsNodePosition(pick.cid)
	local found = {}
	for _, node in pairs(allNodes()) do
		local cid = type(node) == "table" and node.cid
		if cid then
			local m = tonumber(obj:getNodeMass(cid)) or 0
			if m > 0 then table.insert(found, {cid = cid, m = m, d = distance(obj:getAbsNodePosition(cid), center)}) end
		end
	end
	table.sort(found, function(a, b) return a.d < b.d end)
	local nodes, mass = {}, 0
	for i, n in ipairs(found) do
		if i > HAND_MAX_NODES or (i > HAND_MIN_NODES and n.d > HAND_RADIUS) then break end
		table.insert(nodes, n)
		mass = mass + n.m
	end
	if mass <= 0 then return false end
	anchor = {node = pick.cid, nodes = nodes, mass = mass, fx = 0, fy = 0, fz = 0, age = ANCHOR_PULL_KEEP}
	if not physicsStep and type(enablePhysicsStepHook) == "function" then
		local ok, err = pcall(enablePhysicsStepHook)
		physicsStep = ok
		if not ok then log("W", "sharedCareer.rope", "physics-step hook not available, anchor once per frame: " .. tostring(err)) end
	end
	reportToGE("onAnchorNode", "%d, %d", pick.cid, bestHitch and 1 or 0)
	return true
end

function M.anchorPull(fx, fy, fz)
	if not anchor then return end
	anchor.fx, anchor.fy, anchor.fz = tonumber(fx) or 0, tonumber(fy) or 0, tonumber(fz) or 0
	anchor.age = 0
end

function M.anchorRelease()
	anchor = nil
end

function M.anchorInfo()
	return anchor
end

local function anchorStep(dt, perFrame)
	if not anchor or anchor.age >= ANCHOR_PULL_KEEP then return end
	for _, n in ipairs(anchor.nodes) do
		local share = n.m / anchor.mass
		local f = vec3(anchor.fx * share, anchor.fy * share, anchor.fz * share)
		if perFrame then obj:applyForceVectorTime(n.cid, f, dt) else obj:applyForceVector(n.cid, f) end
	end
end

--== Towing jobs: the broken-down vehicle ========================================
-- jobBreakDown(flatTire): engines off and disabled (they don't start again), neutral, parking brake
-- off (so it can be towed or rolled), hazard lights on, optionally a flat tire. Reports
-- sharedCareer_jobs.onJobBrokenDown(id, damage) with the damage so far (beamstate.damage), so the
-- job can tell new damage at the drop-off (jobReportDamage -> onJobDamage). Every step is
-- optional: a vehicle without one of them breaks down without it.

local function damageNow()
	return tonumber(beamstate and beamstate.damage) or 0
end

local function reportToJobs(fn, value)
	if type(obj.queueGameEngineLua) ~= "function" then return end
	obj:queueGameEngineLua(string.format("if sharedCareer_jobs then sharedCareer_jobs.%s(%d, %.1f) end", fn, obj:getId(), value))
end

function M.jobBreakDown(flatTire)
	pcall(function()
		for _, device in pairs(powertrain.getDevices()) do
			if (device.type == "combustionEngine" or device.type == "electricMotor") and type(device.disable) == "function" then
				device:disable()
			end
		end
	end)
	pcall(function() controller.mainController.shiftToGearIndex(0) end)
	pcall(function() input.event("parkingbrake", 0, FILTER_DIRECT) end)
	pcall(function() electrics.set_warn_signal(true) end)
	if flatTire then pcall(function() beamstate.deflateRandomTire() end) end
	reportToJobs("onJobBrokenDown", damageNow())
end

function M.jobReportDamage()
	reportToJobs("onJobDamage", damageNow())
end

function M.onPhysicsStep(dt)
	if not (physicsStep and (hand or anchor) and dt and dt > 0) then return end
	local ok, err = pcall(function()
		if hand then ropeStep(dt, false) end
		anchorStep(dt, false)
	end)
	if not ok then
		-- never take the vehicle down: log it once, the rope goes on once per frame
		physicsStep = false
		log("E", "sharedCareer.rope", "rope at the physics rate failed, going on once per frame: " .. tostring(err))
	end
end

function M.updateGFX(dt)
	if not dt or dt <= 0 then return end
	if anchor then
		if not physicsStep then anchorStep(math.min(dt, HAND_MAX_DT), true) end
		anchor.age = anchor.age + dt
	end
	if not hand then return end
	local tie = obj:getAbsNodePosition(hand.tie)
	local tx, ty, tz = tie.x, tie.y, tie.z
	-- jumped further than its speed explains: moved by the game (teleport), not by the rope
	local last = hand.last
	if last then
		local vx, vy, vz = gripVelocity()
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
	if not physicsStep then
		ropeStep(math.min(dt, HAND_MAX_DT), true)
		if not hand then return end
	end
	-- a frame right after the grab, before the first physics step: the rope has no length yet
	if not hand.length then return end
	-- what this frame's steps pulled on average
	local weight = hand.vehMass * GRAVITY
	local tension = hand.tensionTime > 0 and hand.tensionSum / hand.tensionTime or hand.tension
	if hand.onVehicle and hand.tensionTime > 0 then
		local t = hand.tensionTime
		reportToGE("onRopePull", "%.1f, %.1f, %.1f", hand.pullX / t, hand.pullY / t, hand.pullZ / t)
	end
	hand.tensionSum, hand.tensionTime = 0, 0
	hand.pullX, hand.pullY, hand.pullZ = 0, 0, 0
	-- slack or taut, with a margin in between so the display doesn't flicker
	if hand.slack then
		hand.slack = tension <= TAUT_ABOVE * weight
	else
		hand.slack = tension < SLACK_BELOW * weight
	end
	-- strain: share of the pull limit in use (1 = at the limit), smoothed for the display
	local pull = weight * hand.strength / 100
	hand.strain = hand.strain + (math.min(1.5, tension / pull) - hand.strain) * math.min(1, dt * 6)
	hand.since = hand.since + dt
	if hand.since >= HAND_REPORT_EVERY then
		hand.since = 0
		reportToGE("onHandState", "%.3f, %.3f, %.3f, %.2f, %d, %.2f", tx, ty, tz, math.min(1, hand.strain),
			hand.slack and 1 or 0, hand.length)
	end
end

return M
