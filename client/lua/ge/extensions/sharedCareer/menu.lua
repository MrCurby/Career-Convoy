-- SharedCareer :: the SharedCareer menu (the window with the steering wheel)
--
-- The window is ui/modules/apps/SharedCareer-Menu/. This extension gives it its state: every
-- second and right after a change, guihook "SharedCareerState" with
--   time of day        env.lua (timeState; the time controls are there too)
--   "Traffic", "Options" tabs   the settings below (settingsState)
--   "Players" tab      players.lua
--   fuel prices        fuel.lua (only while the Fuel app is open; the phone reads the same guihook)
-- The phone's home screen uses the same state (time, players, connection).
--
-- Only while someone looks: the windows report what is visible with uiVisible(view, on) –
--   "menu"   the menu is expanded
--   "phone"  the phone is out
--   "fuel"   the Fuel app is open on the phone
-- They report on every change and again every 2 s while visible; a view counts as visible for
-- VIEW_LEASE seconds after its last report. So a lost report or a reloaded extension fixes itself
-- within 2 s, and a window that vanished without saying so stops the updates after VIEW_LEASE.
-- Nothing visible: no state is built or sent. A view that becomes visible gets the state at once.
-- The prices at the pumps and on the signs don't depend on this (fuel.lua applies them itself).
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
	["client.roadTraffic"] = true,
	["client.parkedTraffic"] = true,
	["client.trafficAggression"] = true,
	["client.remoteVehicleGhost"] = true,
	["client.remoteUnicycleGhost"] = true,
	["server.trafficSignalSync"] = true,
	["server.roadTrafficTotal"] = true,
	["server.parkedTrafficTotal"] = true,
	["client.showPlayerStatus"] = true,
}

local KEY_ACTION = "sharedCareerMenu"
local KEY = "f7"
local keyRegistered = false

--- State for the window, or nil without server settings.
function M.settingsState()
	local cfg = U.config()
	if type(cfg) ~= "table" then
		return nil
	end
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
		shareRoad = share.road,
		shareParked = share.parked,
		poolRoad = traffic and traffic.pool and traffic.pool.road or nil,
		poolParked = traffic and traffic.pool and traffic.pool.parked or nil,
	}
end

--- From the window: change a setting for everyone.
function M.uiSetSetting(key, value)
	if not KEYS[key] or not U.isMP() then
		return
	end
	U.send("sc_setSetting", { key = key, value = value })
end

--== Window state ================================================================

--- Everything the menu window (and the phone) shows.
function M.state()
	local env = U.ext("sharedCareer_env")
	local state = env and env.timeState() or {}
	state.connected = U.isMP() and U.careerActive()
	state.settings = M.settingsState()
	local players = U.ext("sharedCareer_players")
	if players then
		state.players = players.state()
	end
	-- fuel: the station list while the Fuel app is open (nil = no stations on this map);
	-- false while it is closed, so the phone keeps its last list instead of an empty one
	if M.isVisible("fuel") then
		local fuel = U.ext("sharedCareer_fuel")
		if fuel then
			local ok, overview = pcall(fuel.overview)
			if ok then
				state.fuel = overview
			end
		end
	else
		state.fuel = false
	end
	return state
end

local function send()
	if guihooks and type(guihooks.trigger) == "function" then
		guihooks.trigger("SharedCareerState", M.state())
	end
end

--== Who looks =================================================================

local VIEW_LEASE = 5 -- s a view counts as visible after its last report (windows: every 2 s)
local VIEWS = { menu = true, phone = true, fuel = true }
local views = {} -- view -> seconds since its last report (only visible views)

function M.isVisible(view)
	return views[view] ~= nil
end

function M.anyVisible()
	return next(views) ~= nil
end

--- Sends the state if a window shows it right now.
function M.push()
	if M.anyVisible() then
		send()
	end
end

--- From the windows: view ("menu", "phone", "fuel") is visible (true) or not (false).
--- A view that becomes visible gets the state right away.
function M.uiVisible(view, on)
	if not VIEWS[view] then
		return
	end
	if on == true then
		local wasVisible = views[view] ~= nil
		views[view] = 0
		if not wasVisible then
			send()
		end
	else
		views[view] = nil
	end
end

-- Called by a window when it is (re)built, so it isn't empty until the next second.
function M.uiRequest()
	send()
end

-- New settings from the server (someone changed something in the menu): show them right
-- away, not only on the next one-second tick. Called by core.lua (sc_configUpdate) and
-- players.lua.
function M.onSettingsChanged()
	M.push()
end

local since = 1

function M.onUpdate(dtReal)
	local dt = tonumber(dtReal) or 0
	for view, age in pairs(views) do
		age = age + dt
		views[view] = age <= VIEW_LEASE and age or nil
	end
	since = since + dt
	if since < 1 then
		return
	end
	since = 0
	if U.isMP() then
		M.push()
	end
end

--== Key =======================================================================

local function registerKey()
	if keyRegistered then
		return
	end
	keyRegistered = true
	U.addKey("menu", KEY_ACTION, {
		title = "SharedCareer: show/hide menu",
		desc = "Expands or collapses the SharedCareer menu",
		default = KEY,
		onDown = function()
			if guihooks then
				guihooks.trigger("SharedCareerToggle", {})
			end
		end,
	})
end

function M.onCareerActive(active)
	if active and U.isMP() and U.config() then
		registerKey()
	end
end

function M.onBeamMPServerLeave()
	keyRegistered = false
	views = {}
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
end

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
