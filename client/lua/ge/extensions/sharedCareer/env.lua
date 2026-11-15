-- SharedCareer :: same time of day for everyone, environment locked in the pause menu
--
-- Time of day: the server runs the clock (hour 0–24) and sends it every 30 s (sc_time).
-- Day and night run at different speeds (server.dayMinutes / nightMinutes, boundaries
-- dayStartHour / nightStartHour). Between syncs the time runs on here by itself; when
-- day <-> night switches, updatePace switches to the other speed immediately.
-- The time is only corrected if the difference is more than MAX_DRIFT_HOURS, so the
-- light doesn't jump on every sync.
-- Can be switched off with client.syncTimeOfDay = false (then everyone has their own time).
--
-- BeamNG counts the time of day from 0 to 1 starting at NOON: 0 = 12:00, 0.25 = 18:00,
-- 0.5 = 0:00, 0.75 = 6:00. Conversion happens only in toGame/fromGame.
--
-- UI window "SharedCareer menu" (ui/modules/apps/SharedCareer-Time): see the section
-- below. Every player can change the time and the day/night length there for everyone.
--
-- Pause menu: the environment pages (time, weather, simulation/slow motion, traffic) are
-- shown read-only by letting them read "restrictScenarios" = true during their call.
-- That is the game's built-in lock for scenarios.
-- Can be switched off with client.lockEnvironment = false.

local M = {}

local U

local MAX_DRIFT_HOURS = 0.05 -- 3 game minutes

local function config()
	local core = U.ext("sharedCareer_core")
	return core and core.getConfig()
end

local function careerActive()
	return career_career and type(career_career.isActive) == "function" and career_career.isActive() == true
end

--== Time of day ===============================================================

function M.toGame(hour)
	return ((tonumber(hour) - 12) / 24) % 1
end

function M.fromGame(t)
	return ((tonumber(t) * 24) + 12) % 24
end

-- Shortest distance between two times in hours (23:50 and 0:10 = 20 min).
local function hourDistance(a, b)
	local d = math.abs(a - b) % 24
	return math.min(d, 24 - d)
end
M.hourDistance = hourDistance

-- Speed for the current time: day and night have different day lengths (real seconds
-- for a whole day at this speed). Older servers only send dayLength.
local function lengthFor(msg, hour)
	local day, night = tonumber(msg.dayLengthDay), tonumber(msg.dayLengthNight)
	local dayStart, nightStart = tonumber(msg.dayStart), tonumber(msg.nightStart)
	if day and night and dayStart and nightStart then
		if hour >= dayStart and hour < nightStart then return day end
		return night
	end
	return tonumber(msg.dayLength) or 0
end
M.lengthFor = lengthFor

local lastMsg = nil

local function setTod(tod, changes)
	local newTod = {}
	for k, v in pairs(tod) do newTod[k] = v end
	for k, v in pairs(changes) do newTod[k] = v end
	local ok, err = pcall(core_environment.setTimeOfDay, newTod)
	if not ok then U.log("E", "env", "setting the time of day failed: " .. tostring(err)) end
	return ok
end

local function getTod()
	local env = core_environment
	if type(env) ~= "table" or type(env.getTimeOfDay) ~= "function" or type(env.setTimeOfDay) ~= "function" then
		return nil
	end
	local ok, tod = pcall(env.getTimeOfDay)
	if ok and type(tod) == "table" then return tod end
	return nil
end

local function syncEnabled()
	local cfg = config()
	return cfg ~= nil and cfg.syncTimeOfDay ~= false and U.isMP()
end

function M.applyTime(msg)
	if not syncEnabled() then return false end
	local hour = tonumber(msg.hour)
	local tod = getTod()
	if not hour or not tod then return false end
	lastMsg = msg
	local length = lengthFor(msg, hour)
	local play = msg.play == true and length > 0

	local current = tonumber(tod.time) and M.fromGame(tod.time) or nil
	local needsTime = current == nil or hourDistance(current, hour) > MAX_DRIFT_HOURS
	local needsPace = (tod.play == true) ~= play or (play and tonumber(tod.dayLength) ~= length)
	if not needsTime and not needsPace then return false end

	local changes = {play = play}
	if needsTime then changes.time = M.toGame(hour) end
	if play then changes.dayLength, changes.dayScale, changes.nightScale = length, 1, 1 end
	return setTod(tod, changes)
end

-- Every second: if day <-> night switches here, change to the other speed immediately,
-- without touching the time.
function M.updatePace()
	if not lastMsg or lastMsg.play ~= true or not syncEnabled() then return false end
	local tod = getTod()
	if not tod or tod.play ~= true or not tonumber(tod.time) then return false end
	local length = lengthFor(lastMsg, M.fromGame(tod.time))
	if length <= 0 or tonumber(tod.dayLength) == length then return false end
	return setTod(tod, {dayLength = length, dayScale = 1, nightScale = 1})
end

local function rxTime(data)
	local msg = U.decode(data)
	if not msg or not careerActive() then return end
	M.applyTime(msg)
	lastMsg = msg -- even if applyTime had nothing to change (for the UI window)
	if guihooks and type(guihooks.trigger) == "function" then
		guihooks.trigger("SharedCareerTime", M.uiState())
	end
end

--== Locking the pause menu ====================================================

local PAUSE_ENVIRONMENT = "ui_pause_providers_routeData_environment"
local ENVIRONMENT_PAGES = {
	"getEnvironmentData", "getEnvironmentWeatherData", "getEnvironmentSimulationData", "getEnvironmentTrafficData",
}

local function lockActive()
	local cfg = config()
	return cfg ~= nil and cfg.lockEnvironment ~= false and U.isMP() and careerActive()
end
M.lockActive = lockActive

local function makeRestricted(original)
	return function(...)
		local store = settings
		if not lockActive() or type(store) ~= "table" or type(store.getValue) ~= "function" then
			return original(...)
		end
		local getValue = store.getValue
		store.getValue = function(key, ...)
			if key == "restrictScenarios" then return true end
			return getValue(key, ...)
		end
		local results = U.pack(pcall(original, ...))
		store.getValue = getValue
		if not results[1] then error(results[2], 0) end
		return U.unpack(results, 2, results.n)
	end
end

local function makeReadOnlyTraffic(original)
	return function(payload, ...)
		if not lockActive() or type(payload) ~= "table" then return original(payload, ...) end
		local copy = {}
		for k, v in pairs(payload) do copy[k] = v end
		copy.editable = false
		return original(copy, ...)
	end
end

function M.ensurePauseLock()
	local pause = rawget(_G, PAUSE_ENVIRONMENT)
	if type(pause) ~= "table" then return end -- page not loaded yet; next second
	for _, name in ipairs(ENVIRONMENT_PAGES) do
		U.replace(pause, name, makeRestricted)
	end
	U.replace(pause, "requestEnvironmentTrafficPayload", makeReadOnlyTraffic)
end

--== UI window "SharedCareer menu" =============================================
-- ui/modules/apps/SharedCareer-Time/: shows the time and day/night, every player can
-- change the time and the day/night length. The window gets the state every second
-- (guihook "SharedCareerTime") and calls the ui* functions below to change things; they
-- go to the server (sc_timeControl). The server applies it and sends it to everyone.

local function uiState()
	local tod = getTod()
	local hour = tod and tonumber(tod.time) and M.fromGame(tod.time) or nil
	local state = {
		hour = hour,
		connected = U.isMP() and careerActive(),
		synced = syncEnabled() and lastMsg ~= nil,
		canControl = lastMsg ~= nil and lastMsg.canControl == true and syncEnabled(),
	}
	if lastMsg then
		state.dayMinutes = tonumber(lastMsg.dayMinutes)
		state.nightMinutes = tonumber(lastMsg.nightMinutes)
		state.running = lastMsg.play == true
		state.paused = lastMsg.paused == true
		local dayStart, nightStart = tonumber(lastMsg.dayStart) or 6, tonumber(lastMsg.nightStart) or 20
		if hour then
			state.isDay = hour >= dayStart and hour < nightStart
			-- real seconds until the next day <-> night switch
			local boundary = state.isDay and nightStart or dayStart
			local hoursLeft = (boundary - hour) % 24
			local length = lengthFor(lastMsg, hour)
			if state.running and length > 0 then state.secondsToSwitch = hoursLeft * length / 24 end
		end
	end
	-- "Traffic" / "Options" tabs of the menu
	local menu = U.ext("sharedCareer_menu")
	if menu then state.settings = menu.settingsState() end
	-- "Players" tab
	local players = U.ext("sharedCareer_players")
	if players then state.players = players.state() end
	-- fuel prices (fuel app)
	local fuel = U.ext("sharedCareer_fuel")
	if fuel then
		local ok, overview = pcall(fuel.overview)
		if ok then state.fuel = overview end
	end
	return state
end
M.uiState = uiState

local function pushUi()
	if guihooks and type(guihooks.trigger) == "function" then
		guihooks.trigger("SharedCareerTime", uiState())
	end
end

-- Called by the window when it opens, so it isn't empty until the next second.
function M.uiRequest()
	pushUi()
end

-- New settings from the server (someone changed something in the menu): show them right
-- away, not only on the next one-second tick. Called by core.lua (sc_configUpdate).
function M.onSettingsChanged()
	pushUi()
end

local function control(payload)
	if not (U.isMP() and careerActive()) then return end
	U.send("sc_timeControl", payload)
end

function M.uiSetHour(hour)
	hour = tonumber(hour)
	if not hour then return end
	control({action = "set", hour = hour % 24})
end

-- Relative to the current time (e.g. +1 / -1 hour).
function M.uiShiftHour(delta)
	local state = uiState()
	delta = tonumber(delta)
	if not state.hour or not delta then return end
	M.uiSetHour((state.hour + delta) % 24)
end

-- Pause the clock (true) or let it run (false) – for everyone.
function M.uiSetPaused(paused)
	control({action = "pause", paused = paused == true})
end

function M.uiSetLengths(dayMinutes, nightMinutes)
	dayMinutes, nightMinutes = tonumber(dayMinutes), tonumber(nightMinutes)
	if not dayMinutes or not nightMinutes then return end
	control({action = "lengths", dayMinutes = dayMinutes, nightMinutes = nightMinutes})
end

--== Hooks =====================================================================

local since = 1

function M.onUpdate(dtReal)
	since = since + (tonumber(dtReal) or 0)
	if since < 1 then return end
	since = 0
	if U.isMP() then
		M.ensurePauseLock()
		if careerActive() then M.updatePace() end
		pushUi()
	end
end

function M.onBeamMPServerLeave()
	lastMsg = nil
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	U.on("sc_time", rxTime)
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
