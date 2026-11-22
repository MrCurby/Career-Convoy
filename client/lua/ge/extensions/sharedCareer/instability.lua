-- SharedCareer :: physics glitches: invalid sync values are blocked, your vehicles are put back
--
-- Now and then the physics of a vehicle blows up ("Instability detected": its nodes get invalid
-- values, NaN). With BeamMP this happens more often, also to several vehicles in the same moment,
-- and it tears parts off (wheels, bumpers).
-- BeamMP handles every glitch itself (beammp/multiplayer.lua, onInstabilityDetected): it only
-- resets the vehicle's physics (obj:requestReset(RESET_PHYSICS)). The vehicle's position is
-- invalid at that moment, so it lands where it was spawned: in the career that is the garage,
-- often far away. The parts counted as broken stay hidden. It looks as if the car was teleported
-- to the garage and robbed.
--
-- 1. Blocking the cause: BeamMP sets another player's vehicle in place when it is too far off
--    (positionGE.setPositionRotationVelocity: position, rotation and velocity straight into the
--    physics) and never checks the numbers. Here that call is dropped if a value is not a finite
--    number, or if the vehicle itself already is (its velocity or direction). The forces BeamMP
--    uses otherwise are guarded inside the vehicle (sharedCareerSyncGuard.lua).
--
-- 2. Putting your vehicles back: the game sends the hook onInstabilityDetected(vehicleId,
--    returnData) to every extension, BeamMP's included, in no fixed order. BeamMP's reset is left
--    in place (it also counts glitches and parks a vehicle that keeps blowing up), but for your
--    own vehicles (BeamMP: isOwn), whether or not BeamMP already marked the glitch as handled:
--   * once per second the last safe spot of each one is kept: position and heading, only while
--     both are valid numbers and the vehicle is slower than SAFE_SPEED (not flying away)
--   * on a glitch the vehicle is set back onto that spot upright and fully reset
--     (spawn.safeTeleport with reset): the invalid physics is gone, the parts are on again, and
--     BeamMP's physics reset then happens right there instead of at the garage.
--     Without a safe spot (just spawned) BeamMP handles it alone.
-- Other players' vehicles are left to their owner; they are only counted.
--
-- In the game: one toast per glitch (all reports within BURST seconds belong to one), only if one
-- of your own vehicles that is not traffic was hit. It says whether it was put back and names the
-- other players whose vehicles blew up in the same moment. The log has the details of each
-- vehicle (id, model, owner, position).

local M = {}

local U

local SAMPLE_EVERY = 1 -- s between two looks at the safe spots
local SAFE_SPEED = 60 -- m/s: faster than this, the spot isn't kept (the vehicle may be flying away)
local BURST = 0.5 -- s: reports within this time belong to one glitch
local HANDLED_FOR = 2 -- s: the game reports a glitch more than once; repeats count as handled
local TOAST_SECONDS = 8

local sinceSample = SAMPLE_EVERY
local safeSpots = {} -- game id -> {pos = {x, y, z}, dir = {x, y, z}}
local putBackAt = {} -- game id -> clock of the last put-back
local burst = nil -- {since, hits = {[game id] = hit}}

local function clock()
	return os.clockhp()
end

local function finite(n)
	return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

local function finiteVec(v)
	v = U.vecOf(v)
	if v and finite(v.x) and finite(v.y) and finite(v.z) then
		return v
	end
	return nil
end

local function call(veh, method)
	if type(veh[method]) ~= "function" then
		return nil
	end
	local ok, result = pcall(veh[method], veh)
	return ok and result or nil
end

local function mp()
	local m = rawget(_G, "MPVehicleGE")
	if type(m) == "table" and type(m.getVehicles) == "function" and type(m.isOwn) == "function" then
		return m
	end
	return nil
end

-- serverId, entry of a game id in BeamMP's list, or nil
local function entryOf(m, gameId)
	for serverId, entry in pairs(m.getVehicles() or {}) do
		if entry.gameVehicleID == gameId then
			return serverId, entry
		end
	end
	return nil
end

--== 1. Blocking invalid sync values ============================================

local LOG_DROPS_EVERY = 10 -- s: dropped placements are summed up in one log line

local drops = { count = 0, since = 0, owners = {} }

local function finiteQuat(q)
	local ok, x, y, z, w = pcall(function()
		return q.x, q.y, q.z, q.w
	end)
	return ok and finite(x) and finite(y) and finite(z) and finite(w) and (x * x + y * y + z * z + w * w) > 0.25
end

-- true if BeamMP may set this vehicle in place with these values
local function validPlacement(veh, data)
	if not veh or type(data) ~= "table" then
		return false
	end
	if not (finiteVec(data.pos) and finiteVec(data.vel) and finiteVec(data.rvel) and finiteVec(data.vehVel)) then
		return false
	end
	if not finiteQuat(data.rot) then
		return false
	end
	-- the vehicle itself: BeamMP turns and subtracts with these
	return finiteVec(call(veh, "getVelocity")) ~= nil
		and finiteVec(call(veh, "getDirectionVector")) ~= nil
		and finiteVec(call(veh, "getDirectionVectorUp")) ~= nil
end

local function makeSetPositionRotationVelocity(original)
	return function(gameVehicleId, positionData, ...)
		local veh = be:getObjectByID(gameVehicleId)
		if validPlacement(veh, positionData) then
			return original(gameVehicleId, positionData, ...)
		end
		drops.count = drops.count + 1
		local m, entry = mp(), nil
		if m then
			entry = select(2, entryOf(m, gameVehicleId))
		end
		drops.owners[entry and entry.ownerName or "unknown"] = true
	end
end

local function logDrops(now)
	if drops.count == 0 or now - drops.since < LOG_DROPS_EVERY then
		return
	end
	local owners = {}
	for name in pairs(drops.owners) do
		table.insert(owners, name)
	end
	table.sort(owners)
	U.log(
		"W",
		"instability",
		"blocked " .. drops.count .. " placement(s) with invalid values for: " .. table.concat(owners, ", ")
	)
	drops = { count = 0, since = now, owners = {} }
end

function M.ensurePatches()
	U.replace(rawget(_G, "positionGE"), "setPositionRotationVelocity", makeSetPositionRotationVelocity)
end

--== 2. Safe spots ==============================================================

local function sampleSpots()
	local m = mp()
	if not m then
		return
	end
	local seen = {}
	for _, entry in pairs(m.getVehicles() or {}) do
		local id = entry.gameVehicleID
		local veh = id and id ~= -1 and m.isOwn(id) and be:getObjectByID(id)
		if veh then
			seen[id] = true
			local pos, dir = finiteVec(call(veh, "getPosition")), finiteVec(call(veh, "getDirectionVector"))
			local vel = finiteVec(call(veh, "getVelocity"))
			local speed = vel and math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z)
			if pos and dir and (dir.x ~= 0 or dir.y ~= 0) and speed and speed < SAFE_SPEED then
				safeSpots[id] = { pos = pos, dir = dir }
			end
		end
	end
	for id in pairs(safeSpots) do
		if not seen[id] then
			safeSpots[id] = nil
		end
	end
end

--== Putting a vehicle back =====================================================

-- Sets the vehicle upright onto its safe spot and resets it. Returns true if that worked.
local function putBack(veh, id)
	local spot = safeSpots[id]
	if not spot or not (spawn and type(spawn.safeTeleport) == "function") then
		return false
	end
	local p, d = spot.pos, spot.dir
	local ok, err = pcall(function()
		local rot = quatFromDir(vec3(d.x, d.y, 0), vec3(0, 0, 1))
		spawn.safeTeleport(veh, vec3(p.x, p.y, p.z), rot, nil, nil, nil, nil, true)
	end)
	if not ok then
		U.log("E", "instability", "putting vehicle " .. tostring(id) .. " back failed: " .. tostring(err))
		return false
	end
	pcall(call, veh, "resetBrokenFlexMesh")
	return true
end

--== The toast ==================================================================

-- "Borian" / "Borian, Max" / "Borian and 2 more"
local function names(list)
	if #list <= 2 then
		return table.concat(list, ", ")
	end
	return list[1] .. " and " .. (#list - 1) .. " more"
end

local function finishBurst()
	local hits = burst.hits
	burst = nil
	local mine, putBackCount, others, seenOwner = false, 0, {}, {}
	local total = 0
	for _, hit in pairs(hits) do
		total = total + 1
		if hit.own then
			if hit.playerVehicle then
				mine = true
			end
			if hit.putBack then
				putBackCount = putBackCount + 1
			end
		elseif hit.owner and not seenOwner[hit.owner] then
			seenOwner[hit.owner] = true
			table.insert(others, hit.owner)
		end
	end
	table.sort(others)
	U.log(
		"W",
		"instability",
		string.format(
			"physics glitch: %d vehicle(s), %d of yours put back, other players: %s",
			total,
			putBackCount,
			#others > 0 and table.concat(others, ", ") or "none"
		)
	)
	if not mine then
		return
	end
	local msg = putBackCount > 0 and "Physics glitch – car put back" or "Physics glitch"
	if #others > 0 then
		msg = msg .. " (also " .. names(others) .. ")"
	end
	U.toast("warning", msg, TOAST_SECONDS)
end

--== Hooks ======================================================================

function M.onInstabilityDetected(vid, returnData)
	if not U.isMP() then
		return
	end
	local m = mp()
	local veh = m and vid and be:getObjectByID(vid)
	if not veh then
		return
	end
	local now = clock()
	burst = burst or { since = now, hits = {} }
	local own = m.isOwn(vid) == true
	local serverId, entry = entryOf(m, vid)
	local hit = burst.hits[vid]
	if not hit then
		local vehicles = U.ext("sharedCareer_vehicles")
		hit = {
			own = own,
			owner = not own and entry and entry.ownerName or nil,
			playerVehicle = vid == be:getPlayerVehicleID(0)
				or (serverId ~= nil and vehicles ~= nil and vehicles.isPlayerVehicle(serverId)),
		}
		burst.hits[vid] = hit
		local spot = safeSpots[vid]
		U.log(
			"W",
			"instability",
			string.format(
				"vehicle %d (%s, %s) blew up; last safe spot %s",
				vid,
				tostring(veh.JBeam),
				own and "yours" or ("of " .. tostring(hit.owner or "unknown")),
				spot and string.format("%.1f, %.1f, %.1f", spot.pos.x, spot.pos.y, spot.pos.z) or "unknown"
			)
		)
	end
	if not own then
		return
	end
	-- the game reports the same glitch again a moment later: it is already handled
	local recently = putBackAt[vid] and now - putBackAt[vid] < HANDLED_FOR
	if recently or putBack(veh, vid) then
		if not recently then
			putBackAt[vid] = now
		end
		hit.putBack = true
		if returnData then
			returnData.instabilityHandled = true
		end
	end
end

function M.onUpdate(dtReal)
	if burst and clock() - burst.since >= BURST then
		finishBurst()
	end
	sinceSample = sinceSample + (tonumber(dtReal) or 0)
	if sinceSample < SAMPLE_EVERY then
		return
	end
	sinceSample = 0
	if U.isMP() then
		M.ensurePatches()
		sampleSpots()
		logDrops(clock())
	end
end

function M.onVehicleDestroyed(id)
	safeSpots[id], putBackAt[id] = nil, nil
end

function M.onBeamMPServerLeave()
	safeSpots, putBackAt, burst, sinceSample = {}, {}, nil, SAMPLE_EVERY
	drops = { count = 0, since = 0, owners = {} }
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
end

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
