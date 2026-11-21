-- SharedCareer :: other players (Players tab in the menu, status on name tags)
--
-- Players tab:
--   Navigate  route on the road to a player, follows them when they drive on
--             (BeamMP: MPVehicleGE.groundmarkerFollowPlayer)
--   Watch     camera to a player (BeamMP: focusCameraOnPlayer) – "Back" puts you back
--             into your own vehicle. While you watch, your traffic stays around your own
--             car instead of following the camera.
--   Teleport  your current vehicle to the player (BeamMP: teleportVehToPlayer); only if the
--             server allows it (server.allowTeleport, off by default)
--
-- Status on name tags (client.showPlayerStatus): every client reports its status every 2 s
-- (sc_status: driving / walking / mission / loading); the server sends the list to everyone
-- (sc_players), and here e.g. "[Mission]" is put after the other players' names.

local M = {}

local U

local STATUS_EVERY = 2
local SUFFIX_SOURCE = "sharedCareer"
local SUFFIX_TEXT = { mission = "[Mission]", walking = "[On foot]", loading = "[Loading]" }

local list = {} -- {{id, name, status}, ...} from the server
local sentStatus = nil
local sinceStatus = STATUS_EVERY
local navigating = nil -- name of the player we navigate to
local watching = nil -- {name, ownVehId}
local suffixed = {} -- name -> text that was set (for cleaning up)

local function mp()
	local m = rawget(_G, "MPVehicleGE")
	if type(m) == "table" then
		return m
	end
	return nil
end

local function myName()
	local cfg = rawget(_G, "MPConfig")
	return cfg and type(cfg.getNickname) == "function" and cfg.getNickname() or nil
end

--== own status ================================================================

function M.currentStatus()
	if not U.careerActive() then
		return "loading"
	end
	local missions = rawget(_G, "gameplay_missions_missionManager")
	if missions and type(missions.getForegroundMissionId) == "function" then
		local ok, id = pcall(missions.getForegroundMissionId)
		if ok and id ~= nil then
			return "mission"
		end
	end
	local walk = rawget(_G, "gameplay_walk")
	if walk and type(walk.isWalking) == "function" then
		local ok, walking = pcall(walk.isWalking)
		if ok and walking then
			return "walking"
		end
	end
	return "driving"
end

local function sendStatus(force)
	local status = M.currentStatus()
	if status ~= sentStatus or force then
		sentStatus = status
		U.send("sc_status", { status = status })
	end
end

--== name tags =================================================================

local function setSuffix(name, text)
	local m = mp()
	if not m or type(m.setPlayerNickSuffix) ~= "function" then
		return
	end
	-- Empty text instead of nil: with nil BeamMP would show "sharedCareer" as the text.
	pcall(m.setPlayerNickSuffix, name, SUFFIX_SOURCE, text or "")
	if text and text ~= "" then
		suffixed[name] = text
	else
		suffixed[name] = nil
	end
end

local function applySuffixes()
	local cfg = U.config()
	local show = cfg and cfg.showPlayerStatus ~= false
	local me = myName()
	local seen = {}
	for _, p in ipairs(list) do
		if p.name ~= me then
			seen[p.name] = true
			local text = show and SUFFIX_TEXT[p.status] or ""
			if (suffixed[p.name] or "") ~= text then
				setSuffix(p.name, text)
			end
		end
	end
	for name in pairs(suffixed) do
		if not seen[name] then
			setSuffix(name, "")
		end
	end
end
M.applySuffixes = applySuffixes

local function rxPlayers(data)
	local msg = U.decode(data)
	if not msg or type(msg.players) ~= "table" then
		return
	end
	list = {}
	for _, p in ipairs(msg.players) do
		if type(p) == "table" and type(p.name) == "string" then
			table.insert(list, { id = p.id, name = p.name, status = p.status })
		end
	end
	if navigating then
		local still = false
		for _, p in ipairs(list) do
			if p.name == navigating then
				still = true
			end
		end
		if not still then
			M.uiStopNavigate()
		end
	end
	applySuffixes()
	local menu = U.ext("sharedCareer_menu")
	if menu then
		menu.onSettingsChanged()
	end
end

--== menu actions ==============================================================

function M.uiNavigate(name)
	local m = mp()
	if not m or type(name) ~= "string" or type(m.groundmarkerFollowPlayer) ~= "function" then
		return
	end
	U.takeRoute("players")
	pcall(m.groundmarkerFollowPlayer, name)
	navigating = name
end

local function stopFollowing()
	local m = mp()
	if navigating and m and type(m.groundmarkerFollowPlayer) == "function" then
		pcall(m.groundmarkerFollowPlayer, nil)
	end
	navigating = nil
end

function M.uiStopNavigate()
	stopFollowing()
	U.clearRoute("players")
end

-- A job or a gas station got the route: stop following the player, or BeamMP puts it back.
function M.onRouteLost()
	stopFollowing()
end

local function pinTraffic(vehId)
	local traffic = rawget(_G, "gameplay_traffic")
	if not traffic or type(traffic.setFocus) ~= "function" then
		return
	end
	if vehId then
		pcall(traffic.setFocus, "vehicle", { vehId = vehId, auto = false })
	else
		pcall(traffic.setFocus)
	end
end

function M.uiWatch(name)
	local m = mp()
	if not m or type(name) ~= "string" or type(m.focusCameraOnPlayer) ~= "function" then
		return
	end
	local own = watching and watching.ownVehId or be:getPlayerVehicleID(0)
	watching = { name = name, ownVehId = own }
	pinTraffic(own) -- your traffic stays around your car, not around the camera
	pcall(m.focusCameraOnPlayer, name)
end

function M.uiBack()
	if not watching then
		return
	end
	local veh = watching.ownVehId and be:getObjectByID(watching.ownVehId)
	watching = nil
	pinTraffic(nil)
	if veh then
		be:enterVehicle(0, veh)
	end
end

function M.uiTeleport(name)
	local m = mp()
	local cfg = U.config()
	local allowed = cfg and type(cfg.ui) == "table" and cfg.ui.allowTeleport == true
	if not allowed or not m or type(name) ~= "string" or type(m.teleportVehToPlayer) ~= "function" then
		return
	end
	pcall(m.teleportVehToPlayer, name)
end

--- State for the Players tab.
function M.state()
	local cfg = U.config()
	local me = myName()
	local out = {}
	for _, p in ipairs(list) do
		table.insert(out, { name = p.name, status = p.status, me = p.name == me })
	end
	return {
		list = out,
		navigating = navigating,
		watching = watching and watching.name or nil,
		canTeleport = cfg and type(cfg.ui) == "table" and cfg.ui.allowTeleport == true or false,
	}
end

--== Hooks =====================================================================

function M.onUpdate(dtReal)
	if not U.isMP() or not U.config() then
		return
	end
	sinceStatus = sinceStatus + (tonumber(dtReal) or 0)
	if sinceStatus < STATUS_EVERY then
		return
	end
	sinceStatus = 0
	sendStatus(false)
end

function M.onCareerActive(active)
	if not active or not U.isMP() or not U.config() then
		return
	end
	sendStatus(true)
end

function M.onConfigChanged()
	applySuffixes()
end

function M.onBeamMPServerLeave()
	list, sentStatus, navigating, watching, suffixed = {}, nil, nil, nil, {}
	sinceStatus = STATUS_EVERY
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	U.on("sc_players", rxPlayers)
end

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
