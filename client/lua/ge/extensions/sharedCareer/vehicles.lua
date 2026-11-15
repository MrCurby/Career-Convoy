-- SharedCareer :: the other players' vehicles
--
-- The career keeps hiding and showing your own cars (garage, dealer, missions).
-- BeamMP doesn't sync that. Therefore:
--   * own car changes active -> server (sc_vehActive) -> all others call setActive()
--   * once per second: which own cars are traffic/parked -> server (sc_vehMarks).
--     The others hide the name tag there (otherwise your name would hover above every
--     traffic car).
-- Remote cars also get "ignoreTraffic", so our own police/traffic doesn't take them over,
-- and a larger view distance – but only once BeamMP firmly assigns them to another player
-- (otherwise freshly spawned OWN traffic would be blocked and stand still; bug in 0.1.0).
-- Collisions (ghost) according to the server settings
-- (client.remoteVehicleGhost / remoteUnicycleGhost).
--
-- Receives: sc_vehStates. Sends: sc_vehActive, sc_vehMarks, sc_vehStatesRequest.

local M = {}

local U

local EVERY = 1
local since = 0

-- server vehicle id -> {active, traffic}
local states = {}
-- server vehicle id -> {gameId, mark}
local sentMarks = {}
-- game id -> last ghost value that was set
local ghosts = {}
local wantList = false

local function mp()
	local m = rawget(_G, "MPVehicleGE")
	if type(m) == "table" and type(m.getVehicles) == "function" then return m end
	return nil
end

local function config()
	local core = U.ext("sharedCareer_core")
	return core and core.getConfig()
end

-- props/trailers that should never have a name tag above them.
local PROPS = {
	barrels = true, barrier = true, barrier_plastic = true, blockwall = true, bollard = true,
	boxutility = true, boxutility_large = true, cannon = true, cargotrailer = true, cones = true,
	containerTrailer = true, dolly = true, dryvan = true, flatbed = true, gate = true, haybale = true,
	logs = true, log_trailer = true, metal_box = true, metal_ramp = true, rocks = true,
	roadsigns = true, sawhorse = true, shipping_container = true, spikestrip = true, tanker = true,
	tirestacks = true, tirewall = true, trafficbarrel = true, tsfb = true, woodcrate = true,
	woodplanks = true, caravan = true, frameless_dump = true, tiltdeck = true,
}

local function applyState(serverId)
	local m = mp()
	local state = states[serverId]
	if not m or not state then return end
	local entry = m.getVehicles()[serverId]
	local gameId = entry and entry.gameVehicleID
	if not gameId or gameId == -1 or m.isOwn(gameId) then return end
	local veh = be:getObjectByID(gameId)
	if not veh then return end
	local active = state.active ~= false
	if veh:getActive() ~= active then veh:setActive(active and 1 or 0) end
	entry.hideNametag = (state.active == false) or (state.traffic == true) or PROPS[entry.jbeam] == true
end

local function rxStates(data)
	local list = U.decode(data)
	if not list then return end
	for serverId, state in pairs(list) do
		if type(state) == "table" then
			states[serverId] = state
			applyState(serverId)
		end
	end
end

local function isTrafficCar(gameId, veh)
	if gameId == be:getPlayerVehicleID(0) then return false end
	if veh.isTraffic == "true" or veh.isParked == "true" then return true end
	if gameplay_traffic and type(gameplay_traffic.getTrafficData) == "function" then
		local data = (gameplay_traffic.getTrafficData() or {})[gameId]
		if type(data) == "table" and data.isAi == true then return true end
	end
	if gameplay_parking and type(gameplay_parking.getParkedCarsList) == "function" then
		for _, id in ipairs(gameplay_parking.getParkedCarsList(true) or {}) do
			if id == gameId then return true end
		end
	end
	return false
end

local function sendMarks()
	local m = mp()
	if not m then return end
	local changed, seen = nil, {}
	for serverId, entry in pairs(m.getVehicles()) do
		local gameId = entry.gameVehicleID
		if gameId and gameId ~= -1 and m.isOwn(gameId) then
			local veh = be:getObjectByID(gameId)
			if veh then
				seen[serverId] = true
				local mark = isTrafficCar(gameId, veh)
				local sent = sentMarks[serverId]
				if not sent or sent.gameId ~= gameId or sent.mark ~= mark then
					changed = changed or {}
					changed[serverId] = mark
					sentMarks[serverId] = {gameId = gameId, mark = mark}
				end
			end
		end
	end
	for serverId in pairs(sentMarks) do
		if not seen[serverId] then sentMarks[serverId] = nil end
	end
	if changed then U.send("sc_vehMarks", changed) end
end

-- Collision (ghost) only for player vehicles:
--   own vehicles                          always collide
--   other players on foot (unicycle)      client.remoteUnicycleGhost
--   other players' cars                   client.remoteVehicleGhost
--   other players' traffic/parked cars    ALWAYS collide – like our own traffic, so that
--                                         AI cars behave the same no matter who owns them
local function applyGhosts()
	local m, cfg = mp(), config()
	if not m or not cfg then return end
	for serverId, entry in pairs(m.getVehicles()) do
		local gameId = entry.gameVehicleID
		local veh = gameId and gameId ~= -1 and be:getObjectByID(gameId)
		if veh then
			local ghost
			local state = states[serverId]
			if m.isOwn(gameId) then
				ghost = false
			elseif veh.JBeam == "unicycle" then
				ghost = cfg.remoteUnicycleGhost == true
			elseif type(state) == "table" and state.traffic == true then
				ghost = false
			else
				ghost = cfg.remoteVehicleGhost == true
			end
			if ghosts[gameId] ~= ghost then
				ghosts[gameId] = ghost
				veh:queueLuaCommand("if sharedCareerVeh then sharedCareerVeh.setGhost(" .. tostring(ghost) .. ") end")
			end
		end
	end
end

--== Hooks =====================================================================

-- When it spawns, a car is not registered with BeamMP yet, even our own one (e.g.
-- freshly spawned traffic): isOwn returns false until the server confirms the spawn.
-- So a car only counts as remote once BeamMP assigns it to another player in its list.
-- The setup runs once per second (prepareRemoteVehicles).
-- We search the list itself instead of using getServerVehicleID: that logs an error with
-- a stack trace for every car it doesn't know yet.
local function serverIdOf(m, gameId)
	for serverId, entry in pairs(m.getVehicles()) do
		if entry.gameVehicleID == gameId then return serverId, entry end
	end
	return nil
end

-- game id -> true once the remote car is set up
local prepared = {}

local function prepareRemoteVehicles()
	local m = mp()
	if not m then return end
	for serverId, entry in pairs(m.getVehicles()) do
		local gameId = entry.gameVehicleID
		if gameId and gameId ~= -1 and not prepared[gameId] and entry.isLocal ~= true and not m.isOwn(gameId) then
			local veh = be:getObjectByID(gameId)
			if veh then
				prepared[gameId] = true
				-- The game's own flag: our own traffic and the police don't take over
				-- this car. NEVER set it on our own cars, or the traffic stands still.
				veh:setDynDataFieldbyName("ignoreTraffic", 0, "true")
				veh:setField("renderDistance", "", 1610)
				if states[serverId] then applyState(serverId) else wantList = true end
			end
		end
	end
end
M.prepareRemoteVehicles = prepareRemoteVehicles

function M.onVehicleSpawned(gameId)
	ghosts[gameId] = nil
	prepared[gameId] = nil
end

function M.onVehicleResetted(gameId)
	ghosts[gameId] = nil
end

function M.onVehicleDestroyed(gameId)
	ghosts[gameId] = nil
	prepared[gameId] = nil
end

function M.onVehicleActiveChanged(gameId, active)
	local m = mp()
	if not m or not U.isMP() or not gameId then return end
	local serverId = serverIdOf(m, gameId)
	if not serverId then return end
	if m.isOwn(gameId) then
		U.send("sc_vehActive", {id = serverId, active = active and true or false})
	else
		-- A remote car changed here without the server wanting it
		-- (e.g. our own career hid it): restore the server state.
		local state = states[serverId]
		if state and (state.active ~= false) ~= (active and true or false) then applyState(serverId) end
	end
end

-- Never "get into" a remote prop/trailer.
function M.onVehicleSwitched(oldId, newId)
	local m = mp()
	if not m or not U.isMP() then return end
	local veh = newId and be:getObjectByID(newId)
	if veh and PROPS[veh.JBeam] and not m.isOwn(newId) then be:enterNextVehicle(0, 1) end
end

function M.onUpdate(dtReal)
	if not U.isMP() or not config() then return end
	since = since + (tonumber(dtReal) or 0)
	if since < EVERY then return end
	since = 0
	if wantList then
		wantList = false
		U.send("sc_vehStatesRequest", "")
	end
	prepareRemoteVehicles()
	sendMarks()
	applyGhosts()
end

function M.onBeamMPServerLeave()
	states, sentMarks, ghosts, prepared, wantList, since = {}, {}, {}, {}, false, 0
end

function M.onConfigChanged()
	ghosts = {}
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	U.on("sc_vehStates", rxStates)
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
