-- SharedCareer :: settings in the SharedCareer menu ("Traffic" and "Options" tabs)
--
-- The UI window (ui/modules/apps/SharedCareer-Time) shows these settings next to the time
-- of day. Every player may change them; the server checks the value, saves it and sends
-- it to EVERYONE (sc_configUpdate) – so it applies everywhere the same way.
--
-- What applies live:
--   Driving / parked cars per player        immediately (shows/hides cars from the pool,
--                                           see traffic.lua); more than the pool only on
--                                           the next join
--   AI driving style                        within 3 s (traffic.lua)
--   Collision with cars / players on foot   within 1 s (vehicles.lua)
--   Synced traffic lights, server limits    immediately (server)
--
-- Sends: sc_setSetting {key, value}. The state for the window comes with the guihook
-- "SharedCareerTime" (env.lua calls settingsState).

local M = {}

local U

-- Keys the menu may change (must match the MENU_SETTINGS list on the server).
local KEYS = {
	["client.roadTraffic"] = true, ["client.parkedTraffic"] = true, ["client.trafficAggression"] = true,
	["client.remoteVehicleGhost"] = true, ["client.remoteUnicycleGhost"] = true,
	["server.trafficSignalSync"] = true, ["server.roadTrafficTotal"] = true, ["server.parkedTrafficTotal"] = true,
	["client.showPlayerStatus"] = true,
}

local function config()
	local core = U.ext("sharedCareer_core")
	return core and core.getConfig()
end

--- State for the window, or nil without server settings.
function M.settingsState()
	local cfg = config()
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

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
