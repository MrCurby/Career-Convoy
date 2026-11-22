-- SharedCareer :: physics glitches: invalid sync values are blocked, a glitch is shown
--
-- Now and then the physics of a vehicle blows up ("Instability detected": its nodes get invalid
-- values, NaN). With BeamMP this happens more often, also to several vehicles in the same moment,
-- and it tears parts off (wheels, bumpers). BeamMP cleans up after it (beammp/multiplayer.lua,
-- onInstabilityDetected): it resets the vehicle's physics, which puts a car of yours back where it
-- was spawned (in the career: the garage), and parks or deletes a vehicle that keeps blowing up.
-- That is left as it is. Here:
--
-- 1. Blocking a cause: BeamMP sets another player's vehicle in place when it is too far off
--    (positionGE.setPositionRotationVelocity: position, rotation and velocity straight into the
--    physics) and never checks the numbers. That call is dropped if a value is not a finite
--    number, or if the vehicle itself already is (its velocity or direction). The forces BeamMP
--    uses otherwise are guarded inside the vehicle (sharedCareerSyncGuard.lua). Dropped calls are
--    summed up in the log every LOG_DROPS_EVERY seconds.
--
-- 2. Showing a glitch: all reports of onInstabilityDetected within BURST seconds belong to one
--    glitch. If one of your own vehicles that is not traffic was hit, one toast says so and names
--    the other players whose vehicles blew up in the same moment. The log has every vehicle (id,
--    model, owner) and a summary, also for glitches without a toast.

local M = {}

local U

local CHECK_EVERY = 1 -- s between two checks of the BeamMP patch
local LOG_DROPS_EVERY = 10 -- s: dropped placements are summed up in one log line
local BURST = 0.5 -- s: reports within this time belong to one glitch
local TOAST_SECONDS = 8

local sinceCheck = CHECK_EVERY
local drops = { count = 0, since = 0, owners = {} }
local burst = nil -- {since, hits = {[game id] = {own, owner, playerVehicle}}}

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

--== 2. Showing a glitch ========================================================

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
	local mine, total, others, seenOwner = false, 0, {}, {}
	for _, hit in pairs(hits) do
		total = total + 1
		if hit.own then
			mine = mine or hit.playerVehicle
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
			"physics glitch: %d vehicle(s), one of your cars: %s, other players: %s",
			total,
			tostring(mine),
			#others > 0 and table.concat(others, ", ") or "none"
		)
	)
	if not mine then
		return
	end
	local msg = "Physics glitch"
	if #others > 0 then
		msg = msg .. " (also " .. names(others) .. ")"
	end
	U.toast("warning", msg, TOAST_SECONDS)
end

--== Hooks ======================================================================

function M.onInstabilityDetected(vid)
	if not U.isMP() then
		return
	end
	local m = mp()
	local veh = m and vid and be:getObjectByID(vid)
	if not veh then
		return
	end
	burst = burst or { since = clock(), hits = {} }
	if burst.hits[vid] then
		return -- the game reports the same glitch more than once
	end
	local own = m.isOwn(vid) == true
	local serverId, entry = entryOf(m, vid)
	local vehicles = U.ext("sharedCareer_vehicles")
	local hit = {
		own = own,
		owner = not own and entry and entry.ownerName or nil,
		playerVehicle = vid == be:getPlayerVehicleID(0)
			or (serverId ~= nil and vehicles ~= nil and vehicles.isPlayerVehicle(serverId)),
	}
	burst.hits[vid] = hit
	U.log(
		"W",
		"instability",
		string.format(
			"vehicle %d (%s, %s) blew up",
			vid,
			tostring(veh.JBeam),
			own and "yours" or ("of " .. tostring(hit.owner or "unknown"))
		)
	)
end

function M.onUpdate(dtReal)
	if burst and clock() - burst.since >= BURST then
		finishBurst()
	end
	sinceCheck = sinceCheck + (tonumber(dtReal) or 0)
	if sinceCheck < CHECK_EVERY then
		return
	end
	sinceCheck = 0
	if U.isMP() then
		M.ensurePatches()
		logDrops(clock())
	end
end

function M.onBeamMPServerLeave()
	burst, sinceCheck = nil, CHECK_EVERY
	drops = { count = 0, since = 0, owners = {} }
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
end

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
