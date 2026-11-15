-- SharedCareer :: Traffic-Menge vom Server
--
-- Jeder Spieler spawnt seinen eigenen Karriere-Traffic, und BeamMP zeigt ihn allen.
-- Bei 4 Spielern mit je 10 Autos fahren also 40 herum. Der Server teilt deshalb ein
-- Gesamtlimit auf und schickt jedem seinen Anteil.
--
-- Die Karriere (career/modules/playerDriving.lua) übergibt ihre Mengen an einer Stelle:
--   gameplay_traffic.setupTrafficHelper(trafficAmount, trafficOptions, parkingAmount, ...)
-- Diese Funktion wird für genau einen Aufruf ersetzt, damit die Server-Mengen ankommen.
-- Alles andere (Polizei, Strafen, Parken) bleibt Spielcode.
--
-- Dabei auch:
--   * simple vehicles (client.trafficSimpleVehicles): Traffic spawnt als einfaches Modell
--     "simple_traffic" – weniger Rechenlast bei allen, weil BeamMP genau dieses Modell verteilt
--   * vorsichtigere KI (client.trafficAggression): siehe "Vorsichtigere KI" unten
--
-- Live-Änderung (Menü, Spieler kommen/gehen): setActiveAmount blendet Autos aus dem beim Start
-- gespawnten Vorrat ein oder aus. Vorrat = Anteil + client.trafficReserve. Weniger geht immer
-- live, mehr bis zur Vorratsgröße; darüber hinaus wirkt es beim nächsten Join.
--
-- Empfängt: sc_traffic {road, parked} – neuer Anteil, wenn Spieler kommen oder gehen.

local M = {}

local U

local MAX = 50
local armed = nil -- {original, share}

-- Vorrat, der beim Karrierestart gespawnt wurde: {road, parked}. Live lässt sich die Menge
-- nur bis hierhin erhöhen (setActiveAmount blendet Autos aus dem Vorrat ein/aus); mehr
-- bräuchte neue Fahrzeuge, die BeamMP bei allen auf einmal bauen müsste (Ruckler).
-- Siehe client.trafficReserve.
M.pool = nil

local function clamp(n)
	n = tonumber(n)
	if not n or n ~= n then return 0 end
	return math.floor(math.max(0, math.min(MAX, n)))
end

function M.amounts(config)
	local share = type(config) == "table" and config.trafficShare
	if type(share) ~= "table" then return nil end
	return clamp(share.road), clamp(share.parked)
end

local function disarm()
	if armed and gameplay_traffic and gameplay_traffic.setupTrafficHelper == armed.wrapper then
		gameplay_traffic.setupTrafficHelper = armed.original
	end
	armed = nil
end

--- Vor dem Karrierestart aufrufen.
function M.arm(config)
	disarm()
	local road, parked = M.amounts(config)
	if not road then return end
	if not gameplay_traffic or type(gameplay_traffic.setupTrafficHelper) ~= "function" then
		U.log("W", "traffic", "gameplay_traffic.setupTrafficHelper missing – server traffic not applied")
		return
	end
	local original = gameplay_traffic.setupTrafficHelper
	local entry = {original = original, since = os.clockhp()}
	entry.wrapper = function(trafficAmount, trafficOptions, parkingAmount, ...)
		disarm()
		local options = {}
		if type(trafficOptions) == "table" then
			for k, v in pairs(trafficOptions) do options[k] = v end
		end
		if road > 0 then options.police = options.police ~= false end
		-- Traffic als "simple_traffic" spawnen: weniger Physik, kleinere Konfiguration, und
		-- weil BeamMP die Konfiguration des Besitzers verteilt, bei allen Spielern einfach.
		if type(config.trafficSimpleVehicles) == "boolean" then options.simpleVehs = config.trafficSimpleVehicles end
		-- Vorrat = Anteil + Reserve; die Reserve bleibt versteckt, bis jemand im Menü mehr
		-- Traffic einstellt.
		local reserve = clamp(config.trafficReserve)
		local poolRoad, poolParked = clamp(road + reserve), clamp(parked + reserve)
		U.log("I", "traffic", string.format("server traffic: %d driving, %d parked (pool %d / %d)",
			road, parked, poolRoad, poolParked))
		local ok, result = pcall(original, poolRoad, options, poolParked, ...)
		if ok then
			M.pool = {road = poolRoad, parked = poolParked}
			-- Die Karriere setzt die aktiven Mengen danach evtl. aus den eigenen Einstellungen;
			-- einen Frame später erzwingen wir die Server-Werte.
			M.pending = {road = road, parked = parked}
			return result
		end
		U.log("E", "traffic", "setupTrafficHelper with server amounts failed: " .. tostring(result))
		return original(trafficAmount, trafficOptions, parkingAmount, ...)
	end
	gameplay_traffic.setupTrafficHelper = entry.wrapper
	armed = entry
end

-- Setzt die aktive Menge; nie mehr als der gespawnte Vorrat.
function M.applyLive(road, parked)
	road, parked = clamp(road), clamp(parked)
	if M.pool then
		road, parked = math.min(road, M.pool.road), math.min(parked, M.pool.parked)
	end
	M.active = {road = road, parked = parked}
	if gameplay_traffic and type(gameplay_traffic.setActiveAmount) == "function" then
		pcall(gameplay_traffic.setActiveAmount, road)
	end
	if gameplay_parking and type(gameplay_parking.setActiveAmount) == "function" then
		pcall(gameplay_parking.setActiveAmount, parked)
	end
end

local function rxTraffic(data)
	local share = U.decode(data)
	if not share then return end
	local core = U.ext("sharedCareer_core")
	local config = core and core.getConfig()
	if config then config.trafficShare = share end
	M.applyLive(share.road, share.parked)
	U.log("I", "traffic", string.format("new traffic share: %d / %d", clamp(share.road), clamp(share.parked)))
end

--== Vorsichtigere KI ==========================================================
-- Die Fahr-KI bremst umso später und fährt umso dichter auf, je höher ihre Aggressivität
-- ist (0 = sehr vorsichtig, 1 = sehr aggressiv). Der Traffic setzt sie beim Spawnen und
-- Respawnen selbst neu, deshalb wird sie für den eigenen Traffic regelmäßig auf den
-- Server-Wert gesetzt. Polizei bleibt unverändert, sonst funktionieren Verfolgungen nicht.
-- client.trafficAggression = 0 lässt die KI ganz in Ruhe.

local AI_EVERY = 3
local sinceAi = AI_EVERY
local aiApplied = {} -- game id -> {value, at}
local AI_REFRESH = 10

local function isPolice(data)
	local role = type(data) == "table" and data.role
	local name = type(role) == "table" and role.name or data.roleName
	return name == "police"
end

function M.applyAiCaution(now)
	local core = U.ext("sharedCareer_core")
	local config = core and core.getConfig()
	local value = config and tonumber(config.trafficAggression)
	if not value or value <= 0 then return end
	value = math.max(0.05, math.min(1, value))
	if not gameplay_traffic or type(gameplay_traffic.getTrafficData) ~= "function" then return end
	local seen = {}
	for gameId, data in pairs(gameplay_traffic.getTrafficData() or {}) do
		if type(data) == "table" and data.isAi == true and not isPolice(data) and gameId ~= be:getPlayerVehicleID(0) then
			seen[gameId] = true
			local veh = be:getObjectByID(gameId)
			local last = aiApplied[gameId]
			if veh and (not last or last.value ~= value or now - last.at >= AI_REFRESH) then
				veh:queueLuaCommand(string.format("if ai and ai.setAggression then ai.setAggression(%.3f) end", value))
				aiApplied[gameId] = {value = value, at = now}
			end
		end
	end
	for gameId in pairs(aiApplied) do
		if not seen[gameId] then aiApplied[gameId] = nil end
	end
end

function M.onVehicleResetted(gameId)
	aiApplied[gameId] = nil
end

function M.onVehicleSpawned(gameId)
	aiApplied[gameId] = nil
end

function M.onUpdate(dtReal)
	sinceAi = sinceAi + (tonumber(dtReal) or 0)
	if sinceAi >= AI_EVERY then
		sinceAi = 0
		if U.isMP() then
			local ok, err = pcall(M.applyAiCaution, os.clockhp())
			if not ok then U.log("E", "traffic", "AI setting failed: " .. tostring(err)) end
		end
	end
	if M.pending then
		local p = M.pending
		M.pending = nil
		M.applyLive(p.road, p.parked)
	end
	-- Hat die Karriere den Helfer nie aufgerufen, nicht ewig eingehängt lassen.
	if armed and os.clockhp() - armed.since > 120 then disarm() end
end

function M.onBeamMPServerLeave()
	disarm()
	M.pool, M.active = nil, nil
	aiApplied = {}
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	U.on("sc_traffic", rxTraffic)
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
