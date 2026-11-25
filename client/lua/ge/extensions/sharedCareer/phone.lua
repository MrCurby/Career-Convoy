-- SharedCareer :: the phone (client.phone)
--
-- A phone in the game, the home for SharedCareer apps. The home screen shows the server time,
-- how long until day or night (with a bar), the number of players and the app grid. Apps so far:
-- Jobs (jobs.lua), Tow (tow.lua), Straps (straps.lua), Fuel (fuel.lua) and Settings (the phone's
-- own: wallpaper and app icons, kept by the window on this PC; registered here).
--
-- The UI is the app ui/modules/apps/SharedCareer-Phone/: a small tab with a phone icon at the
-- right screen edge (below the menu); the phone itself opens above it. Key: F4 by default
-- (BeamMP key bindings, rebindable under Options → Controls → BeamMP).
-- Game menus (pause menu, map, garage, ...): the phone is put away when one opens, and the key
-- only puts it away while one is open (the game reports every screen with onUiChangedState).
--
-- Apps: SharedCareer extensions register themselves here:
--   sharedCareer_phone.registerApp({id = "taxi", title = "Taxi", icon = "T", color = "#f5b800",
--                                   order = 10, onOpen = function() ... end, onClose = ...})
-- The phone shows every registered app on the home screen; a tap calls uiOpenApp(id), which
-- calls the app's onOpen; leaving the app (home, putting the phone away) calls uiCloseApp(id) ->
-- onClose. Apps are only listed while client.phone is on. Jobs, Tow, Straps, Fuel and Settings have
-- their own screens in the phone window (apps/<id>.html).
--
-- icon: the name of an icon in ui/sharedCareer/icons.svg ("jobs", "tow", ...), else a short text (letter).
-- color: the icon's color with the "Colors" app icons (Settings); the other icon themes don't use it.
--
-- Calls: an extension can ring the phone (ring, e.g. taxiJobs.lua: a ride nearby while you are on
-- duty). The phone comes out and shows the call (title, two lines, Accept / Decline) until it is
-- answered (uiAnswer), the caller hangs up (hangUp) or it rings out after RING_SECONDS. Its
-- onAnswer(accepted, missed) learns which; "Accept" also opens the app (and page) the call names.
-- One call at a time, only while you drive (no game menu open).
--
-- guihooks: SharedCareerPhone {enabled, apps = [{id, title, icon, color}]} (state),
--           SharedCareerPhoneToggle (key), SharedCareerPhoneAway (a game menu is open),
--           SharedCareerPhoneCall {call = {id, title, text, detail, icon, seconds, open = {app, page}}}
--           (a call rings; without call: it is over).
--           Time and players come with "SharedCareerState" (menu.lua).

local M = {}

local U

local ACTION = "sharedCareerPhone"
local KEY = "f4"
local RING_SECONDS = 15 -- s a call rings before it counts as missed

local apps = {} -- id -> {id, title, icon, color, order, onOpen, onClose}
local keyRegistered = false
local screen = "play" -- the game's current screen (UI route), from onUiChangedState
local call = nil -- the call that rings: {id, title, text, detail, icon, open, onAnswer, left}

local function enabled()
	local config = U.config()
	return config ~= nil and config.phone ~= false
end

local function trigger(name, data)
	if guihooks and type(guihooks.trigger) == "function" then
		guihooks.trigger(name, data or {})
	end
end

--- State for the phone window: on/off and the registered apps (sorted, without functions).
function M.state()
	local list = {}
	for _, app in pairs(apps) do
		table.insert(list, { id = app.id, title = app.title, icon = app.icon, color = app.color, order = app.order })
	end
	table.sort(list, function(a, b)
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.title < b.title
	end)
	return { enabled = enabled(), apps = list }
end

local function push()
	trigger("SharedCareerPhone", M.state())
end

--- Registers an app on the phone. def = {id, title, icon (icon name or short text), color, order, onOpen, onClose}.
function M.registerApp(def)
	if type(def) ~= "table" or type(def.id) ~= "string" or def.id == "" then
		return false
	end
	apps[def.id] = {
		id = def.id,
		title = tostring(def.title or def.id),
		icon = tostring(def.icon or string.upper(def.id:sub(1, 1))),
		color = type(def.color) == "string" and def.color or "#ff6600",
		order = tonumber(def.order) or 100,
		onOpen = type(def.onOpen) == "function" and def.onOpen or nil,
		onClose = type(def.onClose) == "function" and def.onClose or nil,
	}
	push()
	return true
end

function M.unregisterApp(id)
	if apps[id] then
		apps[id] = nil
		push()
	end
end

--== From the window =============================================================

--- The window asks for the state when it opens.
function M.uiRequest()
	push()
end

--- A tap on an app icon.
function M.uiOpenApp(id)
	local app = apps[id]
	if not app or not enabled() then
		return false
	end
	if app.onOpen then
		local ok, err = pcall(app.onOpen)
		if not ok then
			U.log("E", "phone", "app '" .. tostring(id) .. "' failed to open: " .. tostring(err))
		end
	end
	return true
end

--- The app was left (home screen, phone put away).
function M.uiCloseApp(id)
	local app = apps[id]
	if not app or not app.onClose then
		return
	end
	local ok, err = pcall(app.onClose)
	if not ok then
		U.log("E", "phone", "app '" .. tostring(id) .. "' failed to close: " .. tostring(err))
	end
end

-- Driving (no game menu open): "play", or the screen the game drives on right now (e.g. a mission's).
local function driving()
	if screen == "play" then
		return true
	end
	local menus = U.ext("ui_menuManager")
	return menus ~= nil and type(menus.getGameplayRoute) == "function" and screen == menus.getGameplayRoute()
end

--== Calls =========================================================================

local function pushCall()
	trigger("SharedCareerPhoneCall", {
		call = call and {
			id = call.id,
			title = call.title,
			text = call.text,
			detail = call.detail,
			icon = call.icon,
			seconds = RING_SECONDS,
			open = call.open,
		} or nil,
	})
end

-- The call is over: the phone stops ringing, the caller learns how it ended.
local function endCall(accepted, missed)
	local c = call
	call = nil
	pushCall()
	if c and c.onAnswer then
		local ok, err = pcall(c.onAnswer, accepted, missed)
		if not ok then
			U.log("E", "phone", "call '" .. tostring(c.id) .. "' failed: " .. tostring(err))
		end
	end
end

--- Rings the phone: def = {id, title, text, detail, icon, open = {app, page} (opened on Accept),
--- onAnswer = function(accepted, missed)}. Returns false (nothing rings) while another call rings,
--- the phone is off or a game menu is open.
function M.ring(def)
	if call or not enabled() or not driving() or type(def) ~= "table" or type(def.id) ~= "string" then
		return false
	end
	call = {
		id = def.id,
		title = tostring(def.title or "Call"),
		text = def.text and tostring(def.text) or nil,
		detail = def.detail and tostring(def.detail) or nil,
		icon = def.icon and tostring(def.icon) or "phone",
		open = type(def.open) == "table" and def.open or nil,
		onAnswer = type(def.onAnswer) == "function" and def.onAnswer or nil,
		left = RING_SECONDS,
	}
	pushCall()
	return true
end

--- The caller hangs up (e.g. someone else took the ride): the call ends, onAnswer is not called.
function M.hangUp(id)
	if call and call.id == id then
		call = nil
		pushCall()
	end
end

--- Whether a call rings.
function M.ringing()
	return call ~= nil
end

--- From the window: "Accept" (true) or "Decline" (false).
function M.uiAnswer(accept)
	if call then
		endCall(accept == true, false)
	end
end

--== Key and game menus ==========================================================

local function registerKey()
	if keyRegistered then
		return
	end
	keyRegistered = true
	U.addKey("phone", ACTION, {
		title = "SharedCareer: phone",
		desc = "Takes the phone out or puts it away",
		default = KEY,
		onDown = function()
			if not enabled() then
				return
			end
			trigger(driving() and "SharedCareerPhoneToggle" or "SharedCareerPhoneAway")
		end,
	})
end

--== Hooks =======================================================================

function M.onUpdate(dtReal)
	if call then
		call.left = call.left - (tonumber(dtReal) or 0)
		if call.left <= 0 then
			endCall(false, true)
		end
	end
end

function M.onBeamMPServerLeave()
	call = nil
end

function M.onCareerActive(active)
	if active and U.isMP() then
		registerKey()
		push()
	end
end

-- the game switched screens: put the phone away when a game menu opens
function M.onUiChangedState(toState)
	screen = type(toState) == "string" and toState or "play"
	if not driving() then
		trigger("SharedCareerPhoneAway")
	end
end

-- settings from the server changed (called by core.lua): phone on/off
function M.onConfigChanged()
	push()
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	M.registerApp({ id = "settings", title = "Settings", icon = "settings", color = "#6e7581", order = 1000 })
end

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
