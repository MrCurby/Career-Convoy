-- SharedCareer :: career start on join (client)
--
-- Flow:
--   1. map loaded (onWorldReadyState 2)       -> sc_hello to the server
--   2. server sends the settings (sc_config)  -> start the career:
--        profile = profileBase from the server (fixed per BeamMP account, see the server's
--        profiles.json) + client.saveSuffix. Older servers without profileBase: BeamMP name.
--        Start mode "freshStart" (open world, no single-player tutorial in a shared
--        world); protected by sharedCareer_protect (otherwise remote cars get
--        deleted)
--      Also: apply game settings from the server (simple vehicles) and lock the console /
--      world editor; the player's own values are restored when leaving.
--
--   3. wait until career_career.isActive() and the loading screens are gone
--        -> sc_careerResult {ok = true}
--      If the start hangs, the loading screens are released after JOIN_TIMEOUT and the
--      error is reported to the server (instead of being stuck in a loading screen forever).
--
-- Important: createOrLoadCareerAndStart(name, saveFolder, startingOptions) – since 0.39 the
-- third parameter is a table. A boolean is silently ignored.
--
-- Receives: sc_config (on join), sc_configUpdate (sc set client.* on the server),
--           sc_signals (traffic light cycle). Sends: sc_hello, sc_careerResult.

local M = {}

local U

local JOIN_TIMEOUT = 60
local CAREER_WAIT_TIMEOUT = 30
local CAREER_SCREENS = {"careerActivate", "careerVehicles"}

local config = nil
local helloSent = false
local started = false
local waiting = nil  -- {since}: settings received, career_career not loaded yet
local starting = nil -- {since}: start in progress
local reported = false
local readyOk = false   -- career start reported as successful (loading screens gone)
local currentProfile = nil

function M.getConfig()
	return config
end

--- true as soon as the career runs completely and the loading screens are gone.
function M.isReady()
	return readyOk
end

function M.isStarted()
	return started
end

--== Locking input (console / world editor) ===================================

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

--== Simplified vehicles ("simple vehicles") ===================================
-- Two game settings, set by the server:
--   trafficSimpleVehicles  (BeamNG) our own traffic spawns as the "simple_traffic" model.
--                          BeamMP sends exactly this config to everyone, i.e. the
--                          traffic is then the simple model on EVERY PC.
--   simplifyRemoteVehicles (BeamMP) other players' cars are built locally as a simple
--                          model (only for 17 standard models). Saves performance,
--                          but looks plainer.
-- The player's own values are remembered and restored when leaving.

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

--== Loading screen ============================================================

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
	-- The career's own handler also cleans up on the traffic loading screen.
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

--== Starting the career =======================================================

local function careerActive()
	return career_career and type(career_career.isActive) == "function" and career_career.isActive() == true
end

local function callStart(profile)
	if type(career_career.startingOptions) == "table" then
		-- 0.39+
		return career_career.createOrLoadCareerAndStart(profile, false, {startMode = "freshStart"})
	end
	-- older versions: third parameter = tutorial on/off
	return career_career.createOrLoadCareerAndStart(profile, false, false)
end

local function beginStart()
	waiting = nil
	-- The server assigns the profile name per BeamMP account (stays the same when renamed).
	-- Older servers don't send one: then the BeamMP name.
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
			-- The career runs, only the loading screen hung (often: traffic never reports "ready").
			report(true)
		else
			report(false, "start did not finish within " .. JOIN_TIMEOUT .. " s")
		end
	end
end

--== Server messages ===========================================================

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
	local nodegrab = U.ext("sharedCareer_nodegrab")
	if nodegrab and nodegrab.onConfigChanged then nodegrab.onConfigChanged() end
	local phone = U.ext("sharedCareer_phone")
	if phone and phone.onConfigChanged then phone.onConfigChanged() end
	-- Update the menu immediately (for everyone who has it open right now)
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
	-- The mod was reloaded while the map was already ready.
	if rawget(_G, "worldReadyState") == 2 then M.onWorldReadyState(2) end
end

function M.onExtensionUnloaded()
	clearInputBlocks()
	restoreGameSettings()
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
