-- SharedCareer :: the SharedCareer menu (the window with the steering wheel)
--
-- The window is ui/modules/apps/SharedCareer-Menu/. This extension gives it its state: every
-- second and right after a change, guihook "SharedCareerState" with
--   time of day        env.lua (timeState; the time controls are there too)
--   "Traffic", "Options" tabs   the settings below (settingsState)
--   "Players" tab      players.lua
--   fuel prices        fuel.lua (for the Fuel app on the phone, which reads the same guihook)
--
-- Settings ("Traffic" and "Options" tabs): every player may change them; the server checks
-- the value, saves it and sends it to EVERYONE (sc_configUpdate) – so it applies everywhere
-- the same way.
--
-- What applies live:
--   Driving / parked cars per player        immediately (shows/hides cars from the pool,
--                                           see traffic.lua); more than the pool only on
--                                           the next join
--   AI driving style                        within 3 s (traffic.lua)
--   Collision with cars / players on foot   within 1 s (vehicles.lua)
--   Synced traffic lights, server limits    immediately (server)
--
-- Sends: sc_setSetting {key, value}.
--
-- Menu key (default F7, rebindable under Options → Controls → BeamMP): collapses/expands the
-- window (guihook "SharedCareerToggle").

local M = {}

local U

-- Keys the menu may change (must match the MENU_SETTINGS list on the server).
local KEYS = {
	["client.roadTraffic"] = true, ["client.parkedTraffic"] = true, ["client.trafficAggression"] = true,
	["client.remoteVehicleGhost"] = true, ["client.remoteUnicycleGhost"] = true,
	["server.trafficSignalSync"] = true, ["server.roadTrafficTotal"] = true, ["server.parkedTrafficTotal"] = true,
	["client.showPlayerStatus"] = true,
}

local KEY_ACTION = "sharedCareerMenu"
local KEY = "f7"
local keyRegistered = false

--- State for the window, or nil without server settings.
function M.settingsState()
	local cfg = U.config()
	if type(cfg) ~= "table" then return nil end
	local ui = type(cfg.ui) == "table" and cfg.ui or {}
	local traffic = U.ext("sharedCareer_traffic")
	local share = type(cfg.trafficShare) == "table" and cfg.trafficShare or {}
	return {
		canEdit = ui.allowPlayerSettings == true,
		roadTraffic = cfg.roadTraffic,
		parkedTraffic = cfg.parkedTraffic,
		trafficAggression = cfg.trafficAggression,
		remoteVehicleGhost = cfg.remoteVehicleGhost == true,
		remoteUnicycleGhost = cfg.remoteUnicycleGhost == true,
		showPlayerStatus = cfg.showPlayerStatus ~= false,
		trafficSignalSync = ui.trafficSignalSync ~= false,
		roadTrafficTotal = ui.roadTrafficTotal,
		parkedTrafficTotal = ui.parkedTrafficTotal,
		players = ui.players,
		-- what this player gets right now (server limit shared) and how far it goes live
		shareRoad = share.road, shareParked = share.parked,
		poolRoad = traffic and traffic.pool and traffic.pool.road or nil,
		poolParked = traffic and traffic.pool and traffic.pool.parked or nil,
	}
end

--- From the window: change a setting for everyone.
function M.uiSetSetting(key, value)
	if not KEYS[key] or not U.isMP() then return end
	U.send("sc_setSetting", {key = key, value = value})
end

--== Window state ================================================================

--- Everything the menu window (and the phone) shows.
function M.state()
	local env = U.ext("sharedCareer_env")
	local state = env and env.timeState() or {}
	state.connected = U.isMP() and U.careerActive()
	state.settings = M.settingsState()
	local players = U.ext("sharedCareer_players")
	if players then state.players = players.state() end
	local fuel = U.ext("sharedCareer_fuel")
	if fuel then
		local ok, overview = pcall(fuel.overview)
		if ok then state.fuel = overview end
	end
	return state
end

function M.push()
	if guihooks and type(guihooks.trigger) == "function" then
		guihooks.trigger("SharedCareerState", M.state())
	end
end

-- Called by the window when it opens, so it isn't empty until the next second.
function M.uiRequest()
	M.push()
end

-- New settings from the server (someone changed something in the menu): show them right
-- away, not only on the next one-second tick. Called by core.lua (sc_configUpdate) and
-- players.lua.
function M.onSettingsChanged()
	M.push()
end

local since = 1

function M.onUpdate(dtReal)
	since = since + (tonumber(dtReal) or 0)
	if since < 1 then return end
	since = 0
	if U.isMP() then M.push() end
end

--== Key =======================================================================

local function registerKey()
	if keyRegistered then return end
	keyRegistered = true
	U.addKey("menu", KEY_ACTION, {
		title = "SharedCareer: show/hide menu",
		desc = "Expands or collapses the SharedCareer menu",
		default = KEY,
		onDown = function()
			if guihooks then guihooks.trigger("SharedCareerToggle", {}) end
		end,
	})
end

function M.onCareerActive(active)
	if active and U.isMP() and U.config() then registerKey() end
end

function M.onBeamMPServerLeave()
	keyRegistered = false
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
