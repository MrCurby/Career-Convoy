-- SharedCareer :: Mitspieler (Reiter "Players" im Menü, Status am Namensschild, Menü-Taste)
--
-- Reiter "Players":
--   Navigate  Wegmarkierung auf der Straße zu einem Spieler, folgt ihm, wenn er weiterfährt
--             (BeamMP: MPVehicleGE.groundmarkerFollowPlayer)
--   Watch     Kamera zu einem Spieler (BeamMP: focusCameraOnPlayer) – "Back" setzt dich
--             wieder in dein eigenes Fahrzeug. Solange du zuschaust, bleibt dein Traffic bei
--             deinem eigenen Auto statt der Kamera zu folgen.
--   Teleport  dein aktuelles Fahrzeug zum Spieler (BeamMP: teleportVehToPlayer); nur wenn der
--             Server es erlaubt (server.allowTeleport, Standard aus)
--
-- Status am Namensschild (client.showPlayerStatus): jeder Client meldet alle 2 s seinen
-- Status (sc_status: driving / walking / mission / loading); der Server schickt allen die
-- Liste (sc_players), und hier wird hinter den Namen der anderen z.B. "[Mission]" gesetzt.
--
-- Menü-Taste: über BeamMPs Tastenbelegung (MPKeybindsGE.addAction) – erscheint unter
-- Optionen → Steuerung → BeamMP und lässt sich dort umbelegen. Standard: F7.

local M = {}

local U

local STATUS_EVERY = 2
local SUFFIX_SOURCE = "sharedCareer"
local SUFFIX_TEXT = {mission = "[Mission]", walking = "[On foot]", loading = "[Loading]"}
local MENU_ACTION = "sharedCareerMenu"
local MENU_KEY = "f7"

local list = {}          -- {{id, name, status}, ...} vom Server
local sentStatus = nil
local sinceStatus = STATUS_EVERY
local navigating = nil   -- Name des Spielers, zu dem navigiert wird
local watching = nil     -- {name, ownVehId}
local suffixed = {}      -- Name -> gesetzter Text (zum Aufräumen)
local keyRegistered = false

local function mp()
	local m = rawget(_G, "MPVehicleGE")
	if type(m) == "table" then return m end
	return nil
end

local function config()
	local core = U.ext("sharedCareer_core")
	return core and core.getConfig()
end

local function myName()
	local cfg = rawget(_G, "MPConfig")
	return cfg and type(cfg.getNickname) == "function" and cfg.getNickname() or nil
end

local function careerActive()
	return career_career and type(career_career.isActive) == "function" and career_career.isActive() == true
end

--== eigener Status ============================================================

function M.currentStatus()
	if not careerActive() then return "loading" end
	local missions = rawget(_G, "gameplay_missions_missionManager")
	if missions and type(missions.getForegroundMissionId) == "function" then
		local ok, id = pcall(missions.getForegroundMissionId)
		if ok and id ~= nil then return "mission" end
	end
	local walk = rawget(_G, "gameplay_walk")
	if walk and type(walk.isWalking) == "function" then
		local ok, walking = pcall(walk.isWalking)
		if ok and walking then return "walking" end
	end
	return "driving"
end

local function sendStatus(force)
	local status = M.currentStatus()
	if status ~= sentStatus or force then
		sentStatus = status
		U.send("sc_status", {status = status})
	end
end

--== Namensschilder ============================================================

local function setSuffix(name, text)
	local m = mp()
	if not m or type(m.setPlayerNickSuffix) ~= "function" then return end
	-- Leerer Text statt nil: BeamMP würde bei nil "sharedCareer" als Text anzeigen.
	pcall(m.setPlayerNickSuffix, name, SUFFIX_SOURCE, text or "")
	if text and text ~= "" then suffixed[name] = text else suffixed[name] = nil end
end

local function applySuffixes()
	local cfg = config()
	local show = cfg and cfg.showPlayerStatus ~= false
	local me = myName()
	local seen = {}
	for _, p in ipairs(list) do
		if p.name ~= me then
			seen[p.name] = true
			local text = show and SUFFIX_TEXT[p.status] or ""
			if (suffixed[p.name] or "") ~= text then setSuffix(p.name, text) end
		end
	end
	for name in pairs(suffixed) do
		if not seen[name] then setSuffix(name, "") end
	end
end
M.applySuffixes = applySuffixes

local function rxPlayers(data)
	local msg = U.decode(data)
	if not msg or type(msg.players) ~= "table" then return end
	list = {}
	for _, p in ipairs(msg.players) do
		if type(p) == "table" and type(p.name) == "string" then
			table.insert(list, {id = p.id, name = p.name, status = p.status})
		end
	end
	if navigating then
		local still = false
		for _, p in ipairs(list) do if p.name == navigating then still = true end end
		if not still then M.uiStopNavigate() end
	end
	applySuffixes()
	local env = U.ext("sharedCareer_env")
	if env and env.onSettingsChanged then env.onSettingsChanged() end
end

--== Menü-Aktionen =============================================================

function M.uiNavigate(name)
	local m = mp()
	if not m or type(name) ~= "string" or type(m.groundmarkerFollowPlayer) ~= "function" then return end
	pcall(m.groundmarkerFollowPlayer, name)
	navigating = name
end

function M.uiStopNavigate()
	local m = mp()
	if m and type(m.groundmarkerFollowPlayer) == "function" then pcall(m.groundmarkerFollowPlayer, nil) end
	navigating = nil
end

local function pinTraffic(vehId)
	local traffic = rawget(_G, "gameplay_traffic")
	if not traffic or type(traffic.setFocus) ~= "function" then return end
	if vehId then pcall(traffic.setFocus, "vehicle", {vehId = vehId, auto = false})
	else pcall(traffic.setFocus) end
end

function M.uiWatch(name)
	local m = mp()
	if not m or type(name) ~= "string" or type(m.focusCameraOnPlayer) ~= "function" then return end
	local own = watching and watching.ownVehId or be:getPlayerVehicleID(0)
	watching = {name = name, ownVehId = own}
	pinTraffic(own) -- dein Traffic bleibt bei deinem Auto, nicht bei der Kamera
	pcall(m.focusCameraOnPlayer, name)
end

function M.uiBack()
	if not watching then return end
	local veh = watching.ownVehId and be:getObjectByID(watching.ownVehId)
	watching = nil
	pinTraffic(nil)
	if veh then be:enterVehicle(0, veh) end
end

function M.uiTeleport(name)
	local m = mp()
	local cfg = config()
	local allowed = cfg and type(cfg.ui) == "table" and cfg.ui.allowTeleport == true
	if not allowed or not m or type(name) ~= "string" or type(m.teleportVehToPlayer) ~= "function" then return end
	pcall(m.teleportVehToPlayer, name)
end

--- Stand für den Reiter "Players".
function M.state()
	local cfg = config()
	local me = myName()
	local out = {}
	for _, p in ipairs(list) do
		table.insert(out, {name = p.name, status = p.status, me = p.name == me})
	end
	return {
		list = out,
		navigating = navigating,
		watching = watching and watching.name or nil,
		canTeleport = cfg and type(cfg.ui) == "table" and cfg.ui.allowTeleport == true or false,
	}
end

--== Menü-Taste ================================================================

local function registerKey()
	if keyRegistered then return end
	local keys = rawget(_G, "MPKeybindsGE")
	if type(keys) ~= "table" or type(keys.addAction) ~= "function" then
		U.log("W", "players", "MPKeybindsGE.addAction not available – no menu hotkey (BeamMP too old?)")
		keyRegistered = true
		return
	end
	local ok, err = pcall(keys.addAction, MENU_ACTION, {
		title = "SharedCareer: show/hide menu",
		desc = "Expands or collapses the SharedCareer menu",
		default = MENU_KEY,
		onDown = function()
			if guihooks then guihooks.trigger("SharedCareerToggle", {}) end
		end,
	})
	if not ok then U.log("E", "players", "could not register menu hotkey: " .. tostring(err)) end
	keyRegistered = true
end

--== Hooks =====================================================================

function M.onUpdate(dtReal)
	if not U.isMP() or not config() then return end
	sinceStatus = sinceStatus + (tonumber(dtReal) or 0)
	if sinceStatus < STATUS_EVERY then return end
	sinceStatus = 0
	sendStatus(false)
end

function M.onCareerActive(active)
	if not active or not U.isMP() or not config() then return end
	registerKey()
	sendStatus(true)
end

function M.onConfigChanged()
	applySuffixes()
end

function M.onBeamMPServerLeave()
	list, sentStatus, navigating, watching, suffixed, keyRegistered = {}, nil, nil, nil, {}, false
	sinceStatus = STATUS_EVERY
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	U.on("sc_players", rxPlayers)
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
