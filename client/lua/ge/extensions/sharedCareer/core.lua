-- SharedCareer :: Karrierestart beim Join (Client)
--
-- Ablauf:
--   1. Karte geladen (onWorldReadyState 2)    -> sc_hello an den Server
--   2. Server schickt Einstellungen (sc_config) -> Karriere starten:
--        Profil = profileBase vom Server (fest pro BeamMP-Account, siehe Server
--        profiles.json) + client.saveSuffix. Ältere Server ohne profileBase: BeamMP-Name.
--        Startmodus "freshStart" (Open World, kein Singleplayer-Tutorial in einer
--        geteilten Welt); geschützt durch sharedCareer_protect (sonst werden fremde
--        Autos gelöscht)
--      Außerdem: Spiel-Einstellungen vom Server setzen (simple vehicles) und Konsole /
--      Welteditor sperren; die eigenen Werte des Spielers werden beim Verlassen
--      wiederhergestellt.
--   3. Warten bis career_career.isActive() und die Ladebildschirme weg sind
--        -> sc_careerResult {ok = true}
--      Hängt der Start, werden die Ladebildschirme nach JOIN_TIMEOUT freigegeben und der
--      Fehler an den Server gemeldet (statt für immer im Ladebildschirm zu stecken).
--
-- Wichtig: createOrLoadCareerAndStart(name, saveFolder, startingOptions) – der dritte
-- Parameter ist seit 0.39 eine Tabelle. Ein boolean wird stillschweigend ignoriert.
--
-- Empfängt: sc_config (beim Join), sc_configUpdate (sc set client.* auf dem Server),
--           sc_signals (Ampel-Takt). Sendet: sc_hello, sc_careerResult.

local M = {}

local U

local JOIN_TIMEOUT = 60
local CAREER_WAIT_TIMEOUT = 30
local CAREER_SCREENS = {"careerActivate", "careerVehicles"}

local config = nil
local helloSent = false
local started = false
local waiting = nil  -- {since}: Einstellungen da, career_career noch nicht geladen
local starting = nil -- {since}: Start läuft
local reported = false
local readyOk = false   -- Karrierestart erfolgreich gemeldet (Ladebildschirme weg)
local currentProfile = nil

function M.getConfig()
	return config
end

--- true, sobald die Karriere vollständig läuft und die Ladebildschirme weg sind.
function M.isReady()
	return readyOk
end

function M.isStarted()
	return started
end

--== Eingaben sperren (Konsole / Welteditor) ===================================

local function applyInputBlocks()
	local filter = extensions.core_input_actionFilter
	if not filter or not config then return end
	local blocked = {}
	if not config.allowConsole then table.insert(blocked, "toggleConsoleNG") end
	if not config.allowWorldEditor then
		table.insert(blocked, "editorToggle")
		table.insert(blocked, "editorSafeModeToggle")
		table.insert(blocked, "objectEditorToggle")
	end
	filter.setGroup("sharedCareer", blocked)
	filter.addAction(0, "sharedCareer", #blocked > 0)
end

local function clearInputBlocks()
	local filter = extensions.core_input_actionFilter
	if not filter then return end
	filter.setGroup("sharedCareer", {})
	filter.addAction(0, "sharedCareer", false)
end

--== Vereinfachte Fahrzeuge ("simple vehicles") ================================
-- Zwei Spiel-Einstellungen, vom Server vorgegeben:
--   trafficSimpleVehicles  (BeamNG) eigener Traffic spawnt als "simple_traffic"-Modell.
--                          BeamMP überträgt genau diese Konfiguration an alle, d.h. der
--                          Traffic ist dann auf JEDEM Rechner das einfache Modell.
--   simplifyRemoteVehicles (BeamMP) die Autos der anderen Spieler werden hier lokal als
--                          einfaches Modell gebaut (nur für 17 Standardmodelle). Spart
--                          Rechenleistung, sieht aber schlichter aus.
-- Die eigenen Werte des Spielers werden gemerkt und beim Verlassen zurückgesetzt.

local GAME_SETTINGS = {"trafficSimpleVehicles", "simplifyRemoteVehicles"}
local userSettings = nil

local function applyGameSettings()
	if not config or type(settings) ~= "table" or type(settings.setValue) ~= "function" then return end
	if not userSettings then
		userSettings = {}
		for _, key in ipairs(GAME_SETTINGS) do userSettings[key] = settings.getValue(key) end
	end
	for _, key in ipairs(GAME_SETTINGS) do
		if type(config[key]) == "boolean" and settings.getValue(key) ~= config[key] then
			settings.setValue(key, config[key])
		end
	end
end

local function restoreGameSettings()
	if not userSettings or type(settings) ~= "table" then return end
	for key, value in pairs(userSettings) do
		if value ~= nil then settings.setValue(key, value) end
	end
	userSettings = nil
end

--== Ladebildschirm ============================================================

local function loadingOpen(tag)
	return core_gamestate and type(core_gamestate.getLoadingStatus) == "function"
		and core_gamestate.getLoadingStatus(tag) == true
end

local function openCareerScreens()
	local open = {}
	for _, tag in ipairs(CAREER_SCREENS) do
		if loadingOpen(tag) then table.insert(open, tag) end
	end
	return open
end

local function releaseCareerScreens()
	-- Der eigene Handler der Karriere räumt beim Traffic-Bildschirm noch mit auf.
	if loadingOpen("careerVehicles") and career_modules_playerDriving
			and type(career_modules_playerDriving.onTrafficOrParkingReady) == "function" then
		pcall(career_modules_playerDriving.onTrafficOrParkingReady)
	end
	for _, tag in ipairs(openCareerScreens()) do
		core_gamestate.requestExitLoadingScreen(tag)
		U.log("W", "core", "released loading screen '" .. tag .. "'")
	end
	if extensions.ui_router and type(extensions.ui_router.navigate) == "function" then
		pcall(extensions.ui_router.navigate, "play")
	end
end

local function report(ok, reason)
	if reported then return end
	reported = true
	readyOk = ok == true
	U.send("sc_careerResult", {ok = ok, reason = reason and tostring(reason):sub(1, 200) or nil, profile = currentProfile})
	if ok then
		U.log("I", "core", "career running")
	else
		U.log("E", "core", "career start failed: " .. tostring(reason))
		U.toast("error", "Career could not start: " .. tostring(reason), 15)
	end
end

--== Karriere starten ==========================================================

local function careerActive()
	return career_career and type(career_career.isActive) == "function" and career_career.isActive() == true
end

local function callStart(profile)
	if type(career_career.startingOptions) == "table" then
		-- 0.39+
		return career_career.createOrLoadCareerAndStart(profile, false, {startMode = "freshStart"})
	end
	-- ältere Versionen: dritter Parameter = Tutorial an/aus
	return career_career.createOrLoadCareerAndStart(profile, false, false)
end

local function beginStart()
	waiting = nil
	-- Der Server vergibt den Profilnamen pro BeamMP-Account (bleibt bei Namensänderung gleich).
	-- Ältere Server schicken keinen: dann der BeamMP-Name.
	local base = type(config.profileBase) == "string" and config.profileBase ~= "" and config.profileBase
		or (MPConfig and MPConfig.getNickname and MPConfig.getNickname()) or "player"
	local profile = U.profileName(base, config.saveSuffix)
	currentProfile = profile
	U.log("I", "core", "starting career with profile '" .. profile .. "'")
	starting = {since = os.clockhp()}
	started = true

	local traffic = U.ext("sharedCareer_traffic")
	if traffic then traffic.arm(config) end

	local protect = U.ext("sharedCareer_protect")
	local ok, result = protect.run(callStart, profile)
	if not ok then
		starting = nil
		releaseCareerScreens()
		report(false, result)
		return
	end
	if result == false then
		starting = nil
		releaseCareerScreens()
		report(false, "profile '" .. profile .. "' could not be loaded")
	end
end

local function updateStart()
	if waiting then
		if career_career and type(career_career.createOrLoadCareerAndStart) == "function" then
			beginStart()
		elseif os.clockhp() - waiting.since > CAREER_WAIT_TIMEOUT then
			waiting = nil
			report(false, "career module not available")
		end
		return
	end
	if not starting then return end
	local open = openCareerScreens()
	if careerActive() and #open == 0 then
		starting = nil
		report(true)
		local garage = U.ext("sharedCareer_garage")
		if garage then garage.ensurePatches() end
		return
	end
	if os.clockhp() - starting.since > JOIN_TIMEOUT then
		starting = nil
		releaseCareerScreens()
		if careerActive() then
			-- Karriere läuft, nur der Ladebildschirm hing (oft: Traffic meldet nie "fertig").
			report(true)
		else
			report(false, "start did not finish within " .. JOIN_TIMEOUT .. " s")
		end
	end
end

--== Server-Nachrichten ========================================================

local function rxConfig(data)
	local decoded = U.decode(data)
	if not decoded then
		report(false, "server settings could not be read")
		return
	end
	config = decoded
	applyInputBlocks()
	applyGameSettings()
	if started or waiting then return end
	if decoded.serverVersion and decoded.serverVersion ~= U.VERSION then
		U.log("W", "core", "server version " .. tostring(decoded.serverVersion) .. ", client " .. U.VERSION)
	end
	if career_career and type(career_career.createOrLoadCareerAndStart) == "function" then
		beginStart()
	else
		waiting = {since = os.clockhp()}
	end
end

local function rxConfigUpdate(data)
	local decoded = U.decode(data)
	if not decoded then return end
	config = decoded
	applyInputBlocks()
	applyGameSettings()
	local vehicles = U.ext("sharedCareer_vehicles")
	if vehicles then vehicles.onConfigChanged() end
	local traffic = U.ext("sharedCareer_traffic")
	if traffic and started and type(decoded.trafficShare) == "table" then
		traffic.applyLive(decoded.trafficShare.road, decoded.trafficShare.parked)
	end
	local players = U.ext("sharedCareer_players")
	if players and players.onConfigChanged then players.onConfigChanged() end
	-- Menü sofort aktualisieren (bei allen, die es gerade offen haben)
	local env = U.ext("sharedCareer_env")
	if env and env.onSettingsChanged then env.onSettingsChanged() end
end

local function rxSignals(data)
	local t = tonumber(data)
	if t and core_trafficSignals and type(core_trafficSignals.setTimer) == "function" then
		pcall(core_trafficSignals.setTimer, t)
	end
end

--== Hooks =====================================================================

function M.onWorldReadyState(state)
	if state == 2 and not helloSent and U.isMP() then
		helloSent = true
		U.send("sc_hello", {version = U.VERSION})
		U.log("I", "core", "map loaded, settings requested")
	end
end

function M.onUpdate()
	if waiting or starting then
		local ok, err = pcall(updateStart)
		if not ok then
			waiting, starting = nil, nil
			report(false, err)
		end
	end
end

function M.onBeamMPServerLeave()
	clearInputBlocks()
	restoreGameSettings()
	config, helloSent, started, waiting, starting, reported, currentProfile = nil, false, false, nil, nil, false, nil
	readyOk = false
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	U.on("sc_config", rxConfig)
	U.on("sc_configUpdate", rxConfigUpdate)
	U.on("sc_signals", rxSignals)
	U.log("I", "core", "SharedCareer " .. U.VERSION .. " loaded")
	-- Mod wurde nachgeladen, während die Karte schon fertig war.
	if rawget(_G, "worldReadyState") == 2 then M.onWorldReadyState(2) end
end

function M.onExtensionUnloaded()
	clearInputBlocks()
	restoreGameSettings()
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
