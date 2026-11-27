-- Career-Convoy :: trailers and dollies stay coupled on every PC
--
-- BeamMP sends a coupling only in the moment it happens, and the other PCs try once to couple
-- their copies (couplerVE.toggleCouplerState, which locks only within a few centimeters). If the
-- copies are a bit apart in that moment, during the first moment after a spawn or reset, or for
-- a player who joins later, the trailer stays uncoupled there: its coupler hangs on the ground
-- while it follows the truck's position.
--
-- So couplings are synced by state, like the vehicle visibility:
--   * every client tracks the couplings it sees (the game's onCouplerAttached / onCouplerDetached
--     hooks) and reports those of its own vehicles to the server every few seconds and right after
--     a change (sc_couplings {list = {{a, an, b, bn}}}: server vehicle ids and coupler node ids)
--   * a coupling of other players' vehicles that is missing here is tried again every RETRY
--     seconds with BeamMP's own coupling (couplerVE.toggleCouplerState), from one side and then
--     the other, until it holds; one that the owners no longer report is undone after GRACE
--     seconds (time for their report to arrive)
-- Couplings that involve one of our own vehicles are left to our own physics.
--
-- Receives: sc_couplings {pid, list}. Sends: sc_couplings {list}.

local M = {}

local U

local EVERY = 1 -- seconds between two checks
local REPORT_ALL = 10 -- own couplings are reported at least this often
local RETRY = 2 -- seconds between two tries to couple a missing coupling
local GRACE = 4 -- a coupling here that no owner reports is undone after this long
local NEAR = 30 -- m: both vehicles must be this close for a try

local since, sinceReport = 0, 0
-- couplings seen here: key -> {a, an, b, bn, at} (server ids, node ids, when it was seen)
local here = {}
-- couplings the other players report: pid -> {key -> {a, an, b, bn}}
local reported = {}
-- key -> {at, side} of the last try to couple it
local tries = {}
local sentKey = nil -- the own list sent last, as one string
local changed = false -- a coupling of an own vehicle changed: report on the next check

local function mp()
	local m = rawget(_G, "MPVehicleGE")
	if type(m) == "table" and type(m.getVehicles) == "function" then
		return m
	end
	return nil
end

local function serverIdOf(m, gameId)
	for serverId, entry in pairs(m.getVehicles()) do
		if entry.gameVehicleID == gameId then
			return serverId
		end
	end
	return nil
end

local function gameIdOf(m, serverId)
	local entry = m.getVehicles()[serverId]
	local gameId = entry and entry.gameVehicleID
	return gameId and gameId ~= -1 and gameId or nil
end

-- the same coupling seen from either side gets the same key
local function normalize(a, an, b, bn)
	if b < a or (b == a and bn < an) then
		a, an, b, bn = b, bn, a, an
	end
	return a .. ":" .. an .. "-" .. b .. ":" .. bn, { a = a, an = an, b = b, bn = bn }
end

local function isOwnServerId(m, serverId)
	local gameId = gameIdOf(m, serverId)
	return gameId ~= nil and m.isOwn(gameId)
end

--- Whether the vehicle (server id) is coupled to another one here.
function M.isCoupled(serverId)
	for _, c in pairs(here) do
		if c.a == serverId or c.b == serverId then
			return true
		end
	end
	return false
end

--== What we see here ==========================================================

function M.onCouplerAttached(objId1, objId2, nodeId, obj2nodeId)
	local m = mp()
	if not m or not U.isMP() then
		return
	end
	local a, b = serverIdOf(m, objId1), serverIdOf(m, objId2)
	if not a or not b or not nodeId or not obj2nodeId then
		return
	end
	local key, pair = normalize(a, nodeId, b, obj2nodeId)
	pair.at = os.clockhp()
	here[key] = pair
	if m.isOwn(objId1) or m.isOwn(objId2) then
		changed = true
	end
end

function M.onCouplerDetached(objId1, objId2, nodeId, obj2nodeId)
	local m = mp()
	if not m or not U.isMP() then
		return
	end
	local a, b = serverIdOf(m, objId1), serverIdOf(m, objId2)
	if not a or not b or not nodeId or not obj2nodeId then
		return
	end
	local key = normalize(a, nodeId, b, obj2nodeId)
	here[key] = nil
	if m.isOwn(objId1) or m.isOwn(objId2) then
		changed = true
	end
end

--== Reporting our own couplings ===============================================

local function reportOwn(m, all)
	local list, keys = {}, {}
	for key, pair in pairs(here) do
		if isOwnServerId(m, pair.a) or isOwnServerId(m, pair.b) then
			table.insert(list, { a = pair.a, an = pair.an, b = pair.b, bn = pair.bn })
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	local now = table.concat(keys, ",")
	if all or now ~= sentKey then
		sentKey = now
		U.send("sc_couplings", { list = list })
	end
end

--== Other players' couplings ==================================================

local function couple(veh, nodeId, state)
	veh:queueLuaCommand(
		string.format(
			"if couplerVE then couplerVE.toggleCouplerState(%q) end",
			jsonEncode({ { state = state, _nodetag = nodeId } })
		)
	)
end

local function wanted()
	local all = {}
	for _, list in pairs(reported) do
		for key, pair in pairs(list) do
			all[key] = pair
		end
	end
	return all
end

local function distance(va, vb)
	local p, q = va:getPosition(), vb:getPosition()
	local dx, dy, dz = p.x - q.x, p.y - q.y, p.z - q.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function vehicles(m, pair)
	local ga, gb = gameIdOf(m, pair.a), gameIdOf(m, pair.b)
	local va, vb = ga and be:getObjectByID(ga), gb and be:getObjectByID(gb)
	if not va or not vb or m.isOwn(ga) or m.isOwn(gb) then
		return nil
	end
	return va, vb
end

local function syncOthers(m, now)
	local want = wanted()
	-- missing here: try again, from one side, then the other
	for key, pair in pairs(want) do
		if not here[key] then
			local va, vb = vehicles(m, pair)
			local try = tries[key]
			if
				va
				and va:getActive()
				and vb:getActive()
				and (not try or now - try.at >= RETRY)
				and distance(va, vb) < NEAR
			then
				local side = try and try.side == "a" and "b" or "a"
				tries[key] = { at = now, side = side }
				if side == "a" then
					couple(va, pair.an, true)
				else
					couple(vb, pair.bn, true)
				end
			end
		end
	end
	-- coupled here, but no owner reports it any more: undo it
	for key, pair in pairs(here) do
		if not want[key] and now - pair.at >= GRACE then
			local va, vb = vehicles(m, pair)
			if va then
				couple(va, pair.an, false)
				couple(vb, pair.bn, false)
				pair.at = now -- the detach hook removes it; otherwise try again later
			end
		end
	end
	for key in pairs(tries) do
		if here[key] or not want[key] then
			tries[key] = nil
		end
	end
end

local function rxCouplings(data)
	local msg = U.decode(data)
	if not msg or msg.pid == nil or type(msg.list) ~= "table" then
		return
	end
	local list = {}
	for _, p in ipairs(msg.list) do
		if
			type(p) == "table"
			and type(p.a) == "string"
			and type(p.b) == "string"
			and tonumber(p.an)
			and tonumber(p.bn)
		then
			local key, pair = normalize(p.a, tonumber(p.an), p.b, tonumber(p.bn))
			list[key] = pair
		end
	end
	reported[tostring(msg.pid)] = list
end

--== Hooks =====================================================================

function M.onUpdate(dtReal)
	if not U.isMP() or not U.config() then
		return
	end
	dtReal = tonumber(dtReal) or 0
	since, sinceReport = since + dtReal, sinceReport + dtReal
	if since < EVERY then
		return
	end
	since = 0
	local m = mp()
	if not m then
		return
	end
	local all = sinceReport >= REPORT_ALL
	if all then
		sinceReport = 0
	end
	local ok, err = pcall(function()
		if changed or all then
			changed = false
			reportOwn(m, all)
		end
		syncOthers(m, os.clockhp())
	end)
	if not ok then
		U.log("E", "couplings", "coupling sync failed: " .. tostring(err))
	end
end

-- a vehicle that is gone, rebuilt or reset has no couplings any more (a reset doesn't always
-- report the detach)
local function forgetVehicle(gameId)
	local m = mp()
	local serverId = m and serverIdOf(m, gameId)
	if not serverId then
		return
	end
	for key, pair in pairs(here) do
		if pair.a == serverId or pair.b == serverId then
			here[key] = nil
		end
	end
	if m.isOwn(gameId) then
		changed = true
	end
end

M.onVehicleDestroyed = forgetVehicle
M.onVehicleResetted = forgetVehicle

function M.onBeamMPServerLeave()
	here, reported, tries, sentKey, changed, since, sinceReport = {}, {}, {}, nil, false, 0, 0
end

function M.onExtensionLoaded()
	U = extensions.careerConvoy_util
	U.on("sc_couplings", rxCouplings)
end

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
