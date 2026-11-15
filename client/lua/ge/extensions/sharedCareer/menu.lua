-- SharedCareer :: Einstellungen im SharedCareer-Menü (Reiter "Traffic" und "Optionen")
--
-- Das UI-Fenster (ui/modules/apps/SharedCareer-Time) zeigt neben der Tageszeit auch diese
-- Einstellungen. Jeder Spieler kann sie ändern; der Server prüft den Wert, speichert ihn und
-- schickt ihn an ALLE (sc_configUpdate) – dadurch gilt er überall gleich.
--
-- Was live wirkt:
--   Fahrende / geparkte Autos pro Spieler   sofort (blendet Autos aus dem Vorrat ein/aus,
--                                           siehe traffic.lua); mehr als der Vorrat erst
--                                           beim nächsten Join
--   KI-Fahrstil                             innerhalb von 3 s (traffic.lua)
--   Kollision mit Autos / Fußgängern        innerhalb von 1 s (vehicles.lua)
--   Ampeln synchron, Server-Limits          sofort (Server)
--
-- Sendet: sc_setSetting {key, value}. Der Stand fürs Fenster kommt mit dem guihook
-- "SharedCareerTime" (env.lua ruft settingsState auf).

local M = {}

local U

-- Diese Schlüssel darf das Menü ändern (muss zur Liste MENU_SETTINGS im Server passen).
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

--- Stand fürs Fenster, oder nil ohne Server-Einstellungen.
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
		-- was dieser Spieler gerade bekommt (Server-Limit geteilt) und bis wohin es live geht
		shareRoad = share.road, shareParked = share.parked,
		poolRoad = traffic and traffic.pool and traffic.pool.road or nil,
		poolParked = traffic and traffic.pool and traffic.pool.parked or nil,
	}
end

--- Vom Fenster: eine Einstellung für alle ändern.
function M.uiSetSetting(key, value)
	if not KEYS[key] or not U.isMP() then return end
	U.send("sc_setSetting", {key = key, value = value})
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
