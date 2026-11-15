-- SharedCareer :: Fahrzeuge der anderen Spieler
--
-- Die Karriere versteckt und zeigt ständig eigene Autos (Garage, Händler, Missionen).
-- BeamMP überträgt das nicht. Deshalb:
--   * eigenes Auto ändert active -> Server (sc_vehActive) -> alle anderen setActive()
--   * einmal pro Sekunde: welche eigenen Autos sind Traffic/geparkt -> Server (sc_vehMarks).
--     Die anderen blenden dort das Namensschild aus (sonst steht dein Name über jedem
--     Traffic-Auto).
-- Außerdem bekommen fremde Autos "ignoreTraffic", damit die eigene Polizei/der eigene
-- Traffic sie nicht übernimmt, und eine größere Sichtweite – aber erst, wenn BeamMP sie fest
-- einem anderen Spieler zuordnet (sonst würde frisch gespawnter EIGENER Traffic gesperrt
-- und stünde still; Fehler aus 0.1.0). Kollisionen (Ghost) nach Server-Einstellung
-- (client.remoteVehicleGhost / remoteUnicycleGhost).
--
-- Empfängt: sc_vehStates. Sendet: sc_vehActive, sc_vehMarks, sc_vehStatesRequest.

local M = {}

local U

local EVERY = 1
local since = 0

-- server vehicle id -> {active, traffic}
local states = {}
-- server vehicle id -> {gameId, mark}
local sentMarks = {}
-- game id -> zuletzt gesetzter Ghost-Wert
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

-- Props/Anhänger, über denen nie ein Namensschild stehen soll.
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

-- Kollision (Ghost) nur für Spieler-Fahrzeuge:
--   eigene Fahrzeuge                      immer mit Kollision
--   Fußgänger anderer Spieler (Unicycle)  client.remoteUnicycleGhost
--   Autos anderer Spieler                 client.remoteVehicleGhost
--   Traffic/geparkte Autos anderer        IMMER mit Kollision – wie der eigene Traffic, damit
--                                         sich KI-Autos gleich verhalten, egal wem sie gehören
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

-- Beim Spawnen ist ein Auto bei BeamMP noch nicht registriert, auch ein eigenes (z.B.
-- frisch gespawnter Traffic): isOwn sagt dann false, bis der Server den Spawn bestätigt.
-- Ein Auto gilt deshalb erst als fremd, wenn BeamMP es in seiner Liste einem anderen
-- Spieler zuordnet. Die Einrichtung läuft im Sekundentakt (prepareRemoteVehicles).
-- Gesucht wird in der Liste selbst statt mit getServerVehicleID: das loggt bei jedem
-- noch unbekannten Auto einen Fehler mit Stacktrace.
local function serverIdOf(m, gameId)
	for serverId, entry in pairs(m.getVehicles()) do
		if entry.gameVehicleID == gameId then return serverId, entry end
	end
	return nil
end

-- game id -> true, sobald das fremde Auto eingerichtet ist
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
				-- Spiel-eigene Markierung: der eigene Traffic und die Polizei übernehmen
				-- dieses Auto nicht. NIE auf eigene Autos setzen, sonst steht der Traffic.
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
		-- Ein fremdes Auto hat sich hier verändert, ohne dass der Server es wollte
		-- (z.B. die eigene Karriere hat es versteckt): Server-Stand wiederherstellen.
		local state = states[serverId]
		if state and (state.active ~= false) ~= (active and true or false) then applyState(serverId) end
	end
end

-- Nie in ein fremdes Prop/Anhänger "einsteigen".
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
