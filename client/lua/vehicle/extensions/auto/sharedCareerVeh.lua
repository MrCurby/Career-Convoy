-- SharedCareer :: vehicle Lua (runs in every vehicle)
--
-- Called from the GE side via queueLuaCommand:
--   setGhost(enabled)              collisions with this vehicle on/off (vehicles.lua; ghost mode
--                                  for other players' cars / players on foot)
--   setAiTuning(gap, sightFactor)  traffic AI reacts earlier to obstacles (traffic.lua)
--   ropeTieRay / ropeTieNearest / ropeTieNode / ropeUpdate / ropeRelease / tieProbe
--                                  ropes and straps from this vehicle (rope.lua), see "Ropes" below
--   anchorNear / hookProbe / anchorHook / anchorPull / anchorRelease / strapCorners / hookBelow
--                                  this vehicle holds the other end of a rope or strap, see
--                                  "Anchor on a vehicle" below
--   jobBreakDown / jobReportDamage the broken-down vehicle of a towing job (jobs.lua), see
--                                  "Towing jobs" below
--   damageSnapshot / damageLoad    other players see the owner's damage (damage.lua), see
--                                  "Damage" below
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

--== Ropes: a rope from this vehicle to an anchor ===================================
-- Ropes that the GE side places (rope.lua, for the Tow and Straps apps). This vehicle can hold
-- several at once, each under the id the GE side gave it (rid). A rope is tied to one node (the
-- "tie node"); its pull is spread over the nodes around it (the grip) by their mass, so thin panels
-- don't bend. Two kinds:
--   KIND_TOW    a portable winch with its line (staked to the ground, or on another vehicle):
--               the Tow app
--   KIND_STRAP  a ratchet strap to another vehicle (a car on a trailer): the Straps app. No winch;
--               once its other end is hooked on, it is pulled tight by STRAP_PRELOAD and keeps that
--               length. It stretches STRAP_STRETCH under the vehicle's weight (webbing gives a
--               little, and a softer strap stays calm while both vehicles drive)
-- A tow rope is computed like this:
--   * stiff: under the vehicle's weight it stretches ROPE_STRAIN of its length (at least
--     ROPE_STRETCH_MIN), like a steel or synthetic winch line, so it catches the vehicle instead of
--     springing it back like rubber; what is left of a swing (a cm or so) dies down quickly through
--     the rope's own damping
--   * it only pulls when it is taut (tie node farther from the anchor than the rope is long); it
--     never pushes (straps neither)
--   * winch 1 (haul in): the motor winds the rope in at most `speed` m/s; the harder the rope
--     pulls, the slower it turns (like a winch's series-wound motor: WINCH_FULL_LOAD of the speed
--     just below the pull limit), and at the pull limit (`strength` % of the vehicle's weight) it
--     stalls. Over the last WINCH_SOFT_END m before ROPE_MIN it slows down
--   * winch -1 (pay out): the rope gets longer at `speed` m/s, e.g. to lower a lifted end
--   * the motor needs a moment to get up to speed and to stop (WINCH_ACCEL_IN); paying out, the
--     drum speeds up and slows down slowly (WINCH_ACCEL_OUT), so a hanging load follows it instead
--     of dropping into the rope
--   * winch 0 (stop): the drum is locked – the rope keeps its length like a tow rope, whatever
--     pulls on it, until the rope itself snaps. The strength only matters while hauling in
--   * while the anchor is being moved, the drum turns freely: the rope pays out, the vehicle stays.
--     An anchor that jumps more than ANCHOR_JUMP between two messages was placed somewhere else
--     ("to my view"): the rope pays out to it as well – a jump is no shock load on the rope
--   * the anchor can sit on another vehicle (see "Anchor on a vehicle"): then it moves with that
--     vehicle. The GE side sends its position and speed every frame; between two messages it moves
--     on at that speed (so a fast tow doesn't jolt the rope), the rope's damping works on the speed
--     between the two vehicles, and the pull on the anchor vehicle goes back every frame
--     (onRopePull) – the GE side hands it on, so the other vehicle feels the load
--   * the rope snaps above ROPE_BREAK times the vehicle's weight: only a shock load does that, e.g.
--     a vehicle that drops or drives into the taut rope; the winch alone can't break it
-- Ropes are computed at the physics rate (onPhysicsStep, about 2000 times per second, switched on
-- with the game's enablePhysicsStepHook once a rope is tied); only that makes a stiff rope
-- possible. If the game doesn't offer the hook, the same runs once per frame in updateGFX with
-- forces for the whole frame (obj:applyForceVectorTime), and the rope is made as soft as a frame
-- needs to stay stable (STABLE_K, STABLE_C). A long frame (a hitch) counts as at most ROPE_MAX_DT.
-- An error in the physics step is logged once and the ropes go on once per frame (never takes the
-- vehicle down).
--
-- Called from the GE side:
--   ropeTieRay(rid, kind, cx, cy, cz, dx, dy, dz, maxDist, speed, strength)   tie where the view
--                 ray meets the vehicle (the node closest to it)
--   ropeTieNearest(rid, kind, px, py, pz, speed, strength)   tie at the node closest to a point
--   ropeTieNode(rid, kind, cid)                     tie at this node (Strap down)
--     each reports sharedCareer_rope.onRopeTied(id, rid, t, x, y, z, tie node) or onRopeLost
--   ropeUpdate(rid, ax, ay, az, winch, moving, speed, strength, avx, avy, avz, onVehicle)
--   ropeRelease(rid)
--   tieProbe(cx, cy, cz, dx, dy, dz, maxDist)       preview: where would a rope be tied?
--                                                    -> onTieProbe(id, x, y, z)
-- Every REPORT_EVERY s each rope reports onRopeState(id, rid, x, y, z (tie node), strain,
-- slack, length, ropeLoad).
-- A rope comes off by itself and tells the GE side (onRopeLost(id, rid, reason)):
--   LOST_NO_GRIP  nothing to tie to where you aimed
--   LOST_RESET    the vehicle was reset (onReset) – the rope would pull it back to the old anchor
--   LOST_JUMP     the vehicle jumped (moved without a reset, e.g. teleported)
--   LOST_TORN     the tie node moved far from the vehicle's reference node: the part tore off or
--                 bent away; pulling on would only drag the loose part
--   LOST_SNAPPED  the rope itself snapped (overload)

local KIND_TOW, KIND_STRAP = 0, 1

local GRIP_RADIUS = 0.8   -- m around the tie node: the grip
local GRIP_MIN_NODES = 4  -- at least this many nodes, even if fewer are inside the radius
local GRIP_MAX_NODES = 24
local VELOCITY_NODES = 6  -- the grip's speed is measured on its heaviest nodes
local ROPE_MAX_DT = 0.05  -- s: the longest frame the rope works with (without the physics step)
local TIE_JUMP = 2       -- m the tie node may move in one frame beyond what its speed explains
local TIE_TEAR = 2       -- m the tie node may move away from (or towards) the reference node
local ROPE_MIN = 0.5      -- m: the winch doesn't haul in further than this
local ROPE_MAX = 150      -- m: the winch doesn't pay out further than this
local ROPE_STRAIN = 0.005 -- share of its length the rope stretches under the vehicle's weight
local ROPE_STRETCH_MIN = 0.01 -- m it stretches at least under the vehicle's weight (a short rope)
local ROPE_DAMPING = 0.3  -- the rope's own damping, as a share of critical damping (for the vehicle)
local ROPE_BREAK = 4      -- the rope snaps at this many times the vehicle's weight
local BREAK_FILTER = 0.01 -- s the tension is averaged over before it can snap the rope
local STRAP_STRETCH = 0.04 -- m a strap stretches under the vehicle's weight
local STRAP_PRELOAD = 0.012 -- m a strap is pulled tight by when it is hooked on (about 0.3 of the
                          -- vehicle's weight per strap)
local STRAP_MIN = 0.1     -- m: the shortest strap
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

local REPORT_EVERY = 0.1 -- s: how often each rope's state goes back to the GE side

local ropes = {} -- rid -> {kind, nodes = {{cid, m}}, velNodes = {{cid, w}}, tie (cid), ref (cid),
                 --  refDist, gripMass, vehMass, ax, ay, az (anchor; nil for a strap until it is
                 --  hooked on), placed (it jumped: pay out to it), onVehicle (the anchor is on a
                 --  vehicle), avx, avy, avz (the anchor's speed), pullX, pullY, pullZ (force on the
                 --  anchor, summed over the frame's steps), length, drum (m/s the rope runs out,
                 --  < 0 = in), winch, moving, speed, strength, tension (last step), peak (highest
                 --  since the last report), tensionF (averaged for snapping), tensionSum,
                 --  tensionTime (since the last frame), strain, slack, since,
                 --  last = {x, y, z} (tie node one frame ago)}
local physicsStep = false -- the game calls onPhysicsStep for this vehicle

-- tell the GE side something about this vehicle (module: sharedCareer_rope unless named)
local function reportToGE(fn, fmt, ...)
	if type(obj.queueGameEngineLua) ~= "function" then return end
	local args = fmt and (", " .. string.format(fmt, ...)) or ""
	local module = "sharedCareer_rope"
	obj:queueGameEngineLua(string.format("if %s then %s.%s(%d%s) end", module, module, fn, obj:getId(), args))
end

local function reportToStraps(fn, fmt, ...)
	if type(obj.queueGameEngineLua) ~= "function" then return end
	obj:queueGameEngineLua(string.format("if sharedCareer_straps then sharedCareer_straps.%s(%d, %s) end",
		fn, obj:getId(), string.format(fmt, ...)))
end

local function lose(rid, reason)
	ropes[rid] = nil
	reportToGE("onRopeLost", "%d, %d", rid, reason)
end

local function allNodes()
	local nodes = v and v.data and v.data.nodes
	return type(nodes) == "table" and nodes or {}
end

-- the vehicle's reference nodes (the game's refNodes[0]: ref, back, left, up), or nil
local function refNodes()
	local refs = v and v.data and v.data.refNodes
	local r = type(refs) == "table" and refs[0]
	return type(r) == "table" and r or nil
end

local function refNode()
	local r = refNodes()
	return r and r.ref or nil
end

local function distance(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function switchOnPhysicsStep(what)
	if physicsStep or type(enablePhysicsStepHook) ~= "function" then return end
	local ok, err = pcall(enablePhysicsStepHook)
	physicsStep = ok
	if not ok then log("W", "sharedCareer.rope", "physics-step hook not available, " .. what .. " once per frame: " .. tostring(err)) end
end

-- Sturdy nodes: heavier than half the vehicle's average node. Light ones are panels, glass and
-- mirrors – a rope or strap would only tear them off. A guess from the masses, but a safe one: if
-- no sturdy node is in reach, any node will do.
local function sturdyMass()
	local total, count = 0, 0
	for _, node in pairs(allNodes()) do
		local cid = type(node) == "table" and node.cid
		if cid then
			total = total + (tonumber(obj:getNodeMass(cid)) or 0)
			count = count + 1
		end
	end
	return count > 0 and 0.5 * total / count or 0
end

--- Ties rope `rid` around the world point x/y/z (the nodes around it). Returns true.
local function tie(rid, kind, x, y, z, speed, strength)
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
		if i > GRIP_MAX_NODES or (i > GRIP_MIN_NODES and n.d2 > GRIP_RADIUS * GRIP_RADIUS) then break end
		if n.m > 0 then
			table.insert(nodes, n)
			gripMass = gripMass + n.m
		end
	end
	if #nodes == 0 or gripMass <= 0 or vehMass <= 0 then
		ropes[rid] = nil
		return false
	end
	-- the grip's speed: measured on its heaviest nodes (light panel nodes shake)
	local heavy = {}
	for _, n in ipairs(nodes) do table.insert(heavy, n) end
	table.sort(heavy, function(a, b) return a.m > b.m end)
	local velNodes, velMass = {}, 0
	for i = 1, math.min(VELOCITY_NODES, #heavy) do velMass = velMass + heavy[i].m end
	for i = 1, math.min(VELOCITY_NODES, #heavy) do table.insert(velNodes, {cid = heavy[i].cid, w = heavy[i].m / velMass}) end
	local tieNode, ref = nodes[1].cid, refNode()
	local strap = tonumber(kind) == KIND_STRAP
	ropes[rid] = {kind = strap and KIND_STRAP or KIND_TOW, nodes = nodes, velNodes = velNodes, tie = tieNode, ref = ref,
		gripMass = gripMass, vehMass = vehMass,
		-- a tow rope's anchor starts at the grip; a strap has none until it is hooked on
		ax = not strap and x or nil, ay = not strap and y or nil, az = not strap and z or nil,
		refDist = ref and distance(obj:getAbsNodePosition(tieNode), obj:getAbsNodePosition(ref)) or nil,
		length = nil, drum = 0, winch = 0, moving = false, slack = true,
		speed = tonumber(speed) or 1, strength = tonumber(strength) or 60,
		tension = 0, tensionF = 0, tensionSum = 0, tensionTime = 0, strain = 0, peak = 0,
		avx = 0, avy = 0, avz = 0, pullX = 0, pullY = 0, pullZ = 0,
		since = REPORT_EVERY}
	switchOnPhysicsStep("rope")
	return true
end
M.ropeTie = tie

-- The node closest to a ray (camera position + direction): {cid, t, x, y, z} or nil.
-- t = distance along the ray. minMass: only nodes at least this heavy.
local function nodeOnRay(cx, cy, cz, dx, dy, dz, maxDist, minMass)
	local best = nil
	for _, node in pairs(allNodes()) do
		local cid = type(node) == "table" and node.cid
		if cid and (not minMass or (tonumber(obj:getNodeMass(cid)) or 0) >= minMass) then
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

-- after tying: tell the GE side where the rope is tied (distance, position, tie node)
local function reportTied(rid, t)
	local p = obj:getAbsNodePosition(ropes[rid].tie)
	reportToGE("onRopeTied", "%d, %.3f, %.3f, %.3f, %.3f, %d", rid, t, p.x, p.y, p.z, ropes[rid].tie)
end

--- Ties rope `rid` where the view ray from the camera meets the vehicle (the node closest to the
--- ray) and reports it: sharedCareer_rope.onRopeTied(id, rid, t, x, y, z, tie node).
function M.ropeTieRay(rid, kind, cx, cy, cz, dx, dy, dz, maxDist, speed, strength)
	local n = nodeOnRay(cx, cy, cz, dx, dy, dz, tonumber(maxDist) or 120)
	if not n or not tie(rid, kind, n.x, n.y, n.z, speed, strength) then
		lose(rid, LOST_NO_GRIP)
		return false
	end
	reportTied(rid, n.t)
	return true
end

--- Ties rope `rid` at the node closest to a point (the player's camera) – for the Tow app's
--- vehicle list. Reports onRopeTied like ropeTieRay.
function M.ropeTieNearest(rid, kind, px, py, pz, speed, strength)
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
	if not best or not tie(rid, kind, best.x, best.y, best.z, speed, strength) then
		lose(rid, LOST_NO_GRIP)
		return false
	end
	reportTied(rid, math.sqrt(best.d2))
	return true
end

--- Ties rope `rid` at node `cid` (one of the corners from strapCorners). Reports onRopeTied.
function M.ropeTieNode(rid, kind, cid)
	local known = false
	for _, node in pairs(allNodes()) do
		if type(node) == "table" and node.cid == cid then known = true end
	end
	local p = known and obj:getAbsNodePosition(cid)
	if not p or not tie(rid, kind, p.x, p.y, p.z) then
		lose(rid, LOST_NO_GRIP)
		return false
	end
	reportTied(rid, 0)
	return true
end

--- Preview: where would "where I look" tie the rope? Reports onTieProbe(id, x, y, z).
function M.tieProbe(cx, cy, cz, dx, dy, dz, maxDist)
	local n = nodeOnRay(cx, cy, cz, dx, dy, dz, tonumber(maxDist) or 120)
	if n then reportToGE("onTieProbe", "%.3f, %.3f, %.3f", n.x, n.y, n.z) end
end

--- Rope state from the GE side: anchor point, winch (1 haul in, 0 stop, -1 pay out), anchor being
--- moved, settings; onVehicle = 1: the anchor sits on a vehicle and moves at avx/avy/avz m/s.
function M.ropeUpdate(rid, ax, ay, az, winch, moving, speed, strength, avx, avy, avz, onVehicle)
	local h = ropes[rid]
	if not h then return end
	h.onVehicle = onVehicle == 1 or onVehicle == true
	-- an anchor on a vehicle moves by itself; only a jump elsewhere means it was placed
	if not h.onVehicle and h.ax then
		local jump = math.sqrt((ax - h.ax) ^ 2 + (ay - h.ay) ^ 2 + (az - h.az) ^ 2)
		if jump > ANCHOR_JUMP then h.placed = true end
	end
	h.ax, h.ay, h.az = ax, ay, az
	if h.onVehicle then
		h.avx, h.avy, h.avz = tonumber(avx) or 0, tonumber(avy) or 0, tonumber(avz) or 0
	else
		h.avx, h.avy, h.avz = 0, 0, 0
	end
	if winch == true then winch = 1 elseif winch == false then winch = 0 end
	winch = tonumber(winch) or 0
	-- a strap has no winch
	h.winch = h.kind == KIND_TOW and (winch > 0 and 1 or (winch < 0 and -1 or 0)) or 0
	h.moving = h.kind == KIND_TOW and (moving == true or moving == 1)
	if tonumber(speed) then h.speed = tonumber(speed) end
	if tonumber(strength) then h.strength = tonumber(strength) end
end

function M.ropeRelease(rid)
	ropes[rid] = nil
end

function M.ropeInfo(rid)
	return ropes[rid]
end

-- forward declaration: the damage section below fills it in
local damageAfterReset

-- the vehicle was reset (R, recovery, a new config): no rope must pull it back; a damage waiting
-- for this reset is loaded on the next frame
function M.onReset()
	for rid in pairs(ropes) do lose(rid, LOST_RESET) end
	damageAfterReset()
end

-- the grip's speed (mass-weighted over its heaviest nodes)
local function gripVelocity(h)
	local vx, vy, vz = 0, 0, 0
	for _, n in ipairs(h.velNodes) do
		local vel = obj:getNodeVelocityVector(n.cid)
		vx, vy, vz = vx + vel.x * n.w, vy + vel.y * n.w, vz + vel.z * n.w
	end
	return vx, vy, vz
end

-- One step of a rope: the winch changes the rope's length, a taut rope pulls the grip towards
-- the anchor. perFrame: forces for the whole frame (no physics step).
local function ropeStep(rid, h, dt, perFrame)
	if not h.ax then return end -- a strap that isn't hooked on yet
	-- an anchor on a vehicle moves on at its speed until the next message
	h.ax, h.ay, h.az = h.ax + h.avx * dt, h.ay + h.avy * dt, h.az + h.avz * dt
	local tieAt = obj:getAbsNodePosition(h.tie)
	local dx, dy, dz = h.ax - tieAt.x, h.ay - tieAt.y, h.az - tieAt.z
	local d = math.sqrt(dx * dx + dy * dy + dz * dz)
	local strap = h.kind == KIND_STRAP
	-- a strap is pulled tight once, when it is hooked on
	if not h.length then h.length = strap and math.max(STRAP_MIN, d - STRAP_PRELOAD) or d end
	local weight = h.vehMass * GRAVITY
	if not strap then
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
		-- the motor speeds up and stops quickly; only paying out changes speed slowly
		local step = ((h.winch == 1 or h.drum < 0) and WINCH_ACCEL_IN or WINCH_ACCEL_OUT) * dt
		h.drum = h.drum + math.max(-step, math.min(step, want - h.drum))
		if h.winch == 1 then h.drum = math.max(h.drum, want) end -- the motor stalls at once under load
		h.length = math.max(ROPE_MIN, math.min(ROPE_MAX, h.length + h.drum * dt))
		if h.moving then h.length = math.max(h.length, d) end
		if h.placed then
			h.length = math.min(ROPE_MAX, math.max(h.length, d))
			h.placed = false
		end
	end
	-- a taut rope: stiff spring with about critical damping, pulling only
	local tension = 0
	local stretch = d - h.length
	if stretch > 0 and d > 0.001 then
		local ux, uy, uz = dx / d, dy / d, dz / d
		local vx, vy, vz = gripVelocity(h)
		-- the stretch grows when the grip moves away from the anchor (or the anchor away from the
		-- grip) and when the drum winds in
		local stretchRate = -((vx - h.avx) * ux + (vy - h.avy) * uy + (vz - h.avz) * uz) - h.drum
		local k = weight / (strap and STRAP_STRETCH or math.max(ROPE_STRETCH_MIN, ROPE_STRAIN * h.length))
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
	h.peak = math.max(h.peak, tension)
	h.tensionSum, h.tensionTime = h.tensionSum + tension * dt, h.tensionTime + dt
	h.tensionF = h.tensionF + (tension - h.tensionF) * math.min(1, dt / BREAK_FILTER)
	if h.tensionF > ROPE_BREAK * weight then lose(rid, LOST_SNAPPED) end
end

--== Anchor on a vehicle: this vehicle holds the other end of a rope ===============
-- This vehicle can hold the other end of several ropes (a tow rope, straps), each under its rope
-- id. Nothing hooks on by itself: the player hooks it on with a button, and the GE side asks
-- first where it would go.
--   anchorNear(rid, x, y, z)   the Tow app's anchor is near this vehicle (a few times per second).
--               Answers onAnchorNear(id, rid, "cid,cid,...", cid, isHitch): its tow hitches within
--               TARGET_RANGE m (shown as rings), and the hook point – a tow hitch within HITCH_SNAP
--               m (a coupler node whose tag names a hitch, fifth wheel or gooseneck), otherwise the
--               nearest sturdy node within NODE_SNAP m (any node if no sturdy one is in reach);
--               cid -1 = none
--   hookProbe(cx, cy, cz, dx, dy, dz, maxDist)   the Straps app aims at this vehicle: the sturdy
--               node closest to the view ray -> onHookProbe(id, cid, isHitch)
--   anchorHook(rid, cid)       hook rope `rid` on at node cid -> onAnchorNode(id, rid, cid, isHitch)
--   anchorPull(rid, fx, fy, fz) the rope's pull on this vehicle (N, from the roped vehicle, every
--               frame), spread over the nodes around the anchor node by their mass like the
--               grip; it stops by itself ANCHOR_PULL_KEEP s after the last message
--   anchorRelease(rid)         no more rope `rid` on this vehicle
-- For "Strap down" (Straps app):
--   strapCorners(req)          this vehicle is the load: four sturdy, low nodes at the corners of
--               its body -> sharedCareer_straps.onStrapCorners(id, req, "cid,x,y,z;...")
--   hookBelow(req, "x,y,z;...") this vehicle may carry the load: for each corner its best hook
--               point below it within STRAP_REACH m -> onHookBelow(id, req, "i,cid,d;...")

local ANCHOR_PULL_KEEP = 0.25 -- s a pull message is applied without a new one
local HITCH_SNAP = 0.7        -- m: a tow hitch this close is the hook point
local NODE_SNAP = 0.5         -- m: otherwise a node this close
local TARGET_RANGE = 6        -- m: tow hitches this close to the anchor are reported for the rings
local HITCH_TAGS = {"hitch", "fifthwheel", "gooseneck"}
local STRAP_REACH = 2.5       -- m: a strap's carrier end at most this far from its corner
local STRAP_ABOVE = 0.2       -- m: a carrier end at most this much higher than its corner
local PROBE_SLACK = 0.25      -- m: a sturdy node this much farther from the view ray still wins

local anchors = {} -- rid -> {node, nodes = {{cid, m}}, mass, fx, fy, fz, age}

local function isHitch(node)
	local tag = node.couplerTag or node.tag
	if type(tag) ~= "string" then return false end
	tag = tag:lower()
	for _, t in ipairs(HITCH_TAGS) do
		if tag:find(t, 1, true) then return true end
	end
	return false
end

local function nodeByCid(cid)
	for _, node in pairs(allNodes()) do
		if type(node) == "table" and node.cid == cid then return node end
	end
	return nil
end

-- Rope `rid` goes onto this node: the nodes around it carry the pull (like the grip of the roped
-- vehicle). Reports onAnchorNode.
local function anchorAt(rid, cid, hitch)
	local center = obj:getAbsNodePosition(cid)
	local found = {}
	for _, node in pairs(allNodes()) do
		local id = type(node) == "table" and node.cid
		if id then
			local m = tonumber(obj:getNodeMass(id)) or 0
			if m > 0 then table.insert(found, {cid = id, m = m, d = distance(obj:getAbsNodePosition(id), center)}) end
		end
	end
	table.sort(found, function(a, b) return a.d < b.d end)
	local nodes, mass = {}, 0
	for i, n in ipairs(found) do
		if i > GRIP_MAX_NODES or (i > GRIP_MIN_NODES and n.d > GRIP_RADIUS) then break end
		table.insert(nodes, n)
		mass = mass + n.m
	end
	if mass <= 0 then return false end
	anchors[rid] = {node = cid, nodes = nodes, mass = mass, fx = 0, fy = 0, fz = 0, age = ANCHOR_PULL_KEEP}
	switchOnPhysicsStep("anchor")
	reportToGE("onAnchorNode", "%d, %d, %d", rid, cid, hitch and 1 or 0)
	return true
end

-- The best hook point near p: a tow hitch within HITCH_SNAP, otherwise the nearest sturdy node
-- within NODE_SNAP (any node if none is sturdy). Also the hitches within TARGET_RANGE.
-- Returns cid or nil, isHitch, targets.
local function hookPointNear(p)
	local minMass = sturdyMass()
	local targets, bestHitch, bestSturdy, bestAny = {}, nil, nil, nil
	for _, node in pairs(allNodes()) do
		local cid = type(node) == "table" and node.cid
		if cid then
			local d = distance(obj:getAbsNodePosition(cid), p)
			if isHitch(node) then
				if d <= TARGET_RANGE then table.insert(targets, tostring(cid)) end
				if d <= HITCH_SNAP and (not bestHitch or d < bestHitch.d) then bestHitch = {cid = cid, d = d} end
			elseif d <= NODE_SNAP then
				if not bestAny or d < bestAny.d then bestAny = {cid = cid, d = d} end
				if (tonumber(obj:getNodeMass(cid)) or 0) >= minMass and (not bestSturdy or d < bestSturdy.d) then
					bestSturdy = {cid = cid, d = d}
				end
			end
		end
	end
	if bestHitch then return bestHitch.cid, true, targets end
	local best = bestSturdy or bestAny
	return best and best.cid or nil, false, targets
end

--- The Tow app's anchor is at x/y/z: report the tow hitches near it and where it would hook on.
function M.anchorNear(rid, x, y, z)
	local cid, hitch, targets = hookPointNear({x = tonumber(x) or 0, y = tonumber(y) or 0, z = tonumber(z) or 0})
	reportToGE("onAnchorNear", "%d, %q, %d, %d", rid, table.concat(targets, ","), cid or -1, hitch and 1 or 0)
end

--- The Straps app aims at this vehicle: where would the strap hook on? The sturdy node closest to
--- the view ray (a light one only if it is clearly closer). Reports onHookProbe(id, cid, isHitch).
function M.hookProbe(cx, cy, cz, dx, dy, dz, maxDist)
	maxDist = tonumber(maxDist) or 120
	local any = nodeOnRay(cx, cy, cz, dx, dy, dz, maxDist)
	if not any then return end
	local sturdy = nodeOnRay(cx, cy, cz, dx, dy, dz, maxDist, sturdyMass())
	local n = any
	if sturdy and math.sqrt(sturdy.miss) <= math.sqrt(any.miss) + PROBE_SLACK then n = sturdy end
	local node = nodeByCid(n.cid)
	reportToGE("onHookProbe", "%d, %d", n.cid, node and isHitch(node) and 1 or 0)
end

--- Hooks rope `rid` on at node cid (the hook point the GE side was told).
function M.anchorHook(rid, cid)
	local node = nodeByCid(tonumber(cid))
	if not node then return false end
	return anchorAt(rid, node.cid, isHitch(node))
end

function M.anchorPull(rid, fx, fy, fz)
	local a = anchors[rid]
	if not a then return end
	a.fx, a.fy, a.fz = tonumber(fx) or 0, tonumber(fy) or 0, tonumber(fz) or 0
	a.age = 0
end

function M.anchorRelease(rid)
	anchors[rid] = nil
end

function M.anchorInfo(rid)
	return anchors[rid]
end

local function anchorStep(dt, perFrame)
	for _, a in pairs(anchors) do
		if a.age < ANCHOR_PULL_KEEP then
			for _, n in ipairs(a.nodes) do
				local share = n.m / a.mass
				local f = vec3(a.fx * share, a.fy * share, a.fz * share)
				if perFrame then obj:applyForceVectorTime(n.cid, f, dt) else obj:applyForceVector(n.cid, f) end
			end
		end
	end
end

-- The vehicle's axes from its reference nodes (forward, left, up; unit vectors), or nil.
local function axes()
	local r = refNodes()
	if not (r and r.ref and r.back and r.left) then return nil end
	local o, b, l = obj:getAbsNodePosition(r.ref), obj:getAbsNodePosition(r.back), obj:getAbsNodePosition(r.left)
	local function unit(x, y, z)
		local len = math.sqrt(x * x + y * y + z * z)
		if len < 1e-6 then return nil end
		return {x = x / len, y = y / len, z = z / len}
	end
	local fwd = unit(o.x - b.x, o.y - b.y, o.z - b.z)
	local left = unit(l.x - o.x, l.y - o.y, l.z - o.z)
	if not (fwd and left) then return nil end
	local up = unit(fwd.y * left.z - fwd.z * left.y, fwd.z * left.x - fwd.x * left.z, fwd.x * left.y - fwd.y * left.x)
	if not up then return nil end
	return fwd, left, up, o
end

--- This vehicle is the load: four corners for straps (front left, front right, back left, back
--- right) – sturdy nodes in the lower half of the body, as far out at each corner as possible.
function M.strapCorners(req)
	local fwd, left, up, o = axes()
	local list = {}
	if fwd then
		local minMass = sturdyMass()
		local pts, lo, hi = {}, math.huge, -math.huge
		for _, node in pairs(allNodes()) do
			local cid = type(node) == "table" and node.cid
			if cid and (tonumber(obj:getNodeMass(cid)) or 0) >= minMass then
				local p = obj:getAbsNodePosition(cid)
				local rx, ry, rz = p.x - o.x, p.y - o.y, p.z - o.z
				local h = rx * up.x + ry * up.y + rz * up.z
				table.insert(pts, {cid = cid, p = p, f = rx * fwd.x + ry * fwd.y + rz * fwd.z,
					l = rx * left.x + ry * left.y + rz * left.z, h = h})
				lo, hi = math.min(lo, h), math.max(hi, h)
			end
		end
		local lowHalf = lo + 0.5 * (hi - lo)
		for _, corner in ipairs({{1, 1}, {1, -1}, {-1, 1}, {-1, -1}}) do
			local best, bestScore = nil, -math.huge
			for _, n in ipairs(pts) do
				if n.h <= lowHalf then
					local score = corner[1] * n.f + corner[2] * n.l
					if score > bestScore then best, bestScore = n, score end
				end
			end
			if best then table.insert(list, string.format("%d,%.3f,%.3f,%.3f", best.cid, best.p.x, best.p.y, best.p.z)) end
		end
	end
	reportToStraps("onStrapCorners", "%d, %q", tonumber(req) or 0, table.concat(list, ";"))
end

--- This vehicle may carry the load: for each corner (x,y,z;...) the nearest sturdy node below it
--- (at most STRAP_ABOVE higher) within STRAP_REACH m. Reports onHookBelow(id, req, "i,cid,d;...").
function M.hookBelow(req, corners)
	local minMass = sturdyMass()
	local out, i = {}, 0
	for x, y, z in tostring(corners or ""):gmatch("([-%d%.]+),([-%d%.]+),([-%d%.]+)") do
		i = i + 1
		local c = {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
		local best = nil
		for _, node in pairs(allNodes()) do
			local cid = type(node) == "table" and node.cid
			if cid and (tonumber(obj:getNodeMass(cid)) or 0) >= minMass then
				local p = obj:getAbsNodePosition(cid)
				local d = distance(p, c)
				if p.z <= c.z + STRAP_ABOVE and d <= STRAP_REACH and (not best or d < best.d) then
					best = {cid = cid, d = d}
				end
			end
		end
		if best then table.insert(out, string.format("%d,%d,%.3f", i, best.cid, best.d)) end
	end
	reportToStraps("onHookBelow", "%d, %q", tonumber(req) or 0, table.concat(out, ";"))
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

--== Damage: other players see the owner's damage ==================================
-- BeamMP only syncs parts that break off (break groups). How a body bends is worked out by every
-- PC on its own, so a car that hit something only one PC sees looks different everywhere. The
-- owner therefore sends its damage (damage.lua), and the others load it the way the game loads a
-- saved vehicle (beamstate.load): node positions, beam rest lengths, broken beams, commitLoad.
-- Changing beams of a moving car instead makes its physics blow up.
--   damageSnapshot()  owner: every node's position in the vehicle's own frame (right, forward,
--                     up from the reference node; all of them, or neighbouring parts tear apart on
--                     loading), every bent body beam {cid, rest length, recorded deformation} and
--                     every broken beam -> sharedCareer_damage.onSnapshot(id, json)
--   damageLoad(data)  other PCs, only while the car stands still: keeps the damage and asks to be
--                     reset in place (sharedCareer_damage.onReadyToLoad); on the first frame after
--                     that reset the undamaged car takes the owner's shape (loadDamage)
-- obj:getNodePosition is relative to the reference node in world axes, so positions are turned
-- into the vehicle's frame and back with its direction vectors. A damage of a vehicle with other
-- node or beam counts (other parts) is ignored.
-- A bent beam is a body beam (no wheel, pressured or other moving beam) whose rest length differs
-- from the undamaged one by more than BENT: obj:getBeamDeformation reads 0 even on a crashed car,
-- and a healthy car settles by up to about 2.5 mm. The undamaged rest lengths are read on the
-- first frame after the vehicle spawned or was reset. The deformation the game recorded for a
-- beam (beamstate.deformedBeams, e.g. broken glass and lights) is replayed with
-- beamstate.onBeamDeformed.

local BENT = 0.003          -- m: a body beam whose rest length changed more than this is bent
local undamagedLengths = nil -- cid -> rest length of the undamaged beam
local pendingDamage = nil    -- the damage to load after the next reset: {data, armed, age}
local PENDING_FOR = 2        -- s: a damage whose reset doesn't come is dropped (never loaded on a later one)

-- beam types that hold the body together (normal, anisotropic); the others move by design
local BODY_BEAM = {[0] = true, [1] = true}

local function isBodyBeam(beam)
	return beam.wheelID == nil and (beam.beamType == nil or BODY_BEAM[beam.beamType] == true)
end

local function count(list)
	local n = 0
	for _ in pairs(type(list) == "table" and list or {}) do n = n + 1 end
	return n
end

local function vehicleData(key)
	return type(v) == "table" and type(v.data) == "table" and type(v.data[key]) == "table" and v.data[key] or {}
end

local function round4(x)
	return math.floor(x * 10000 + 0.5) / 10000
end

-- the vehicle's frame: right, forward, up (unit vectors in world axes)
local function frame()
	local fwd, up = obj:getDirectionVector(), obj:getDirectionVectorUp()
	return fwd:cross(up), fwd, up
end

local function reportToDamage(fn, arg)
	if type(obj.queueGameEngineLua) ~= "function" then return end
	obj:queueGameEngineLua(string.format("if sharedCareer_damage then sharedCareer_damage.%s(%d%s) end",
		fn, obj:getId(), arg and (", " .. string.format("%q", arg)) or ""))
end

function M.damageSnapshot()
	local right, fwd, up = frame()
	local nodes, nodeCount = {}, 0
	for _, node in pairs(vehicleData("nodes")) do
		nodeCount = nodeCount + 1
		local p = obj:getNodePosition(node.cid)
		local i = #nodes
		nodes[i + 1], nodes[i + 2], nodes[i + 3], nodes[i + 4] = node.cid, round4(p:dot(right)), round4(p:dot(fwd)), round4(p:dot(up))
	end
	local recorded = beamstate and type(beamstate.deformedBeams) == "table" and beamstate.deformedBeams or {}
	local deformed, broken, beamCount = {}, {}, 0
	for _, beam in pairs(vehicleData("beams")) do
		beamCount = beamCount + 1
		local cid = beam.cid
		local undamaged = undamagedLengths and undamagedLengths[cid]
		if obj:beamIsBroken(cid) then
			broken[#broken + 1] = cid
		elseif undamaged and isBodyBeam(beam) then
			local length = obj:getBeamRestLength(cid)
			local ratio = tonumber(recorded[cid]) or 0
			if math.abs(length - undamaged) > BENT or ratio ~= 0 then
				local i = #deformed
				deformed[i + 1], deformed[i + 2], deformed[i + 3] = cid, length, ratio
			end
		end
	end
	log("I", "sharedCareer.damage", string.format("damage sent: %d bent, %d broken of %d beams",
		#deformed / 3, #broken, beamCount))
	reportToDamage("onSnapshot", jsonEncode({nn = nodeCount, bn = beamCount, n = nodes, d = deformed, b = broken}))
end

function M.damageLoad(data)
	if type(data) ~= "table" or type(data.n) ~= "table" or type(data.d) ~= "table" or type(data.b) ~= "table" then return end
	local nodeCount, beamCount = count(vehicleData("nodes")), count(vehicleData("beams"))
	if data.nn ~= nodeCount or data.bn ~= beamCount then
		log("W", "sharedCareer.damage", string.format("damage not loaded: %d nodes / %d beams here, %s / %s at the owner",
			nodeCount, beamCount, tostring(data.nn), tostring(data.bn)))
		return
	end
	pendingDamage = {data = data, age = 0}
	reportToDamage("onReadyToLoad")
end

-- the undamaged vehicle (right after its reset) takes the owner's shape
local function loadDamage(data)
	local right, fwd, up = frame()
	local n = data.n
	for i = 1, #n - 3, 4 do
		obj:setNodePosition(n[i], right * n[i + 1] + fwd * n[i + 2] + up * n[i + 3])
	end
	local d = data.d
	local replay = beamstate and type(beamstate.onBeamDeformed) == "function" and beamstate.onBeamDeformed
	for i = 1, #d - 2, 3 do
		if d[i + 1] > 0 then obj:setBeamLength(d[i], d[i + 1]) end
		if replay and d[i + 2] ~= 0 then pcall(replay, d[i], d[i + 2]) end
	end
	for _, cid in ipairs(data.b) do obj:breakBeam(cid) end
	obj:commitLoad()
	log("I", "sharedCareer.damage", string.format("damage loaded: %d nodes, %d bent, %d broken beams",
		#n / 4, #d / 3, #data.b))
end

damageAfterReset = function()
	undamagedLengths = nil
	if pendingDamage then pendingDamage.armed = true end
end

-- the vehicle is undamaged (just spawned or reset): remember its rest lengths
local function readUndamagedLengths()
	if undamagedLengths then return end
	undamagedLengths = {}
	for _, beam in pairs(vehicleData("beams")) do
		undamagedLengths[beam.cid] = obj:getBeamRestLength(beam.cid)
	end
end

local function loadPendingDamage(dt)
	if not pendingDamage then return end
	if not pendingDamage.armed then
		pendingDamage.age = pendingDamage.age + dt
		if pendingDamage.age > PENDING_FOR then pendingDamage = nil end
		return
	end
	local data = pendingDamage.data
	pendingDamage = nil
	local ok, err = pcall(loadDamage, data)
	if not ok then log("E", "sharedCareer.damage", "loading the damage failed: " .. tostring(err)) end
end

function M.onPhysicsStep(dt)
	if not (physicsStep and (next(ropes) or next(anchors)) and dt and dt > 0) then return end
	local ok, err = pcall(function()
		for rid, h in pairs(ropes) do ropeStep(rid, h, dt, false) end
		anchorStep(dt, false)
	end)
	if not ok then
		-- never take the vehicle down: log it once, the ropes go on once per frame
		physicsStep = false
		log("E", "sharedCareer.rope", "rope at the physics rate failed, going on once per frame: " .. tostring(err))
	end
end

-- Once per frame for one rope: the checks (teleported, torn off), the rope without the physics
-- step, the pull for the anchor vehicle and the report to the GE side.
local function ropeFrame(rid, h, dt)
	local tieAt = obj:getAbsNodePosition(h.tie)
	local tx, ty, tz = tieAt.x, tieAt.y, tieAt.z
	-- jumped further than its speed explains: moved by the game (teleport), not by the rope
	local last = h.last
	if last then
		local vx, vy, vz = gripVelocity(h)
		local jx, jy, jz = tx - last.x - vx * dt, ty - last.y - vy * dt, tz - last.z - vz * dt
		if jx * jx + jy * jy + jz * jz > TIE_JUMP * TIE_JUMP then
			lose(rid, LOST_JUMP)
			return
		end
	end
	h.last = {x = tx, y = ty, z = tz}
	if h.ref and h.refDist and math.abs(distance(tieAt, obj:getAbsNodePosition(h.ref)) - h.refDist) > TIE_TEAR then
		lose(rid, LOST_TORN)
		return
	end
	if not physicsStep then
		ropeStep(rid, h, math.min(dt, ROPE_MAX_DT), true)
		if not ropes[rid] then return end
	end
	-- what this frame's steps pulled on average
	local weight = h.vehMass * GRAVITY
	local tension = h.tensionTime > 0 and h.tensionSum / h.tensionTime or h.tension
	if h.onVehicle and h.tensionTime > 0 then
		local t = h.tensionTime
		reportToGE("onRopePull", "%d, %.1f, %.1f, %.1f", rid, h.pullX / t, h.pullY / t, h.pullZ / t)
	end
	h.tensionSum, h.tensionTime = 0, 0
	h.pullX, h.pullY, h.pullZ = 0, 0, 0
	-- slack or taut, with a margin in between so the display doesn't flicker
	if h.slack then
		h.slack = tension <= TAUT_ABOVE * weight
	else
		h.slack = tension < SLACK_BELOW * weight
	end
	-- strain: how hard the winch works while it hauls in, share of its pull limit (1 = the motor's
	-- limit), smoothed for the display; 0 otherwise (stopped it is locked, paying out it gives way)
	local pull = weight * h.strength / 100
	local working = h.winch == 1 and math.min(1, tension / pull) or 0
	h.strain = h.strain + (working - h.strain) * math.min(1, dt * 6)
	h.since = h.since + dt
	if h.since >= REPORT_EVERY then
		h.since = 0
		-- the rope's load: its highest pull since the last report, share of its breaking load (a short
		-- jolt shows up too). Before the first step (no length yet, or a strap not hooked on yet) it
		-- reports too, so the GE side knows the vehicle is there
		local ropeLoad = h.peak / (ROPE_BREAK * weight)
		h.peak = 0
		reportToGE("onRopeState", "%d, %.3f, %.3f, %.3f, %.2f, %d, %.2f, %.3f", rid, tx, ty, tz, h.strain,
			h.slack and 1 or 0, h.length or 0, ropeLoad)
	end
end

function M.updateGFX(dt)
	if not dt or dt <= 0 then return end
	readUndamagedLengths()
	loadPendingDamage(dt)
	if next(anchors) then
		if not physicsStep then anchorStep(math.min(dt, ROPE_MAX_DT), true) end
		for _, a in pairs(anchors) do a.age = a.age + dt end
	end
	for rid, h in pairs(ropes) do ropeFrame(rid, h, dt) end
end

return M
