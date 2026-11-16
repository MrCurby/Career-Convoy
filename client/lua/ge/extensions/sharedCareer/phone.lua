-- SharedCareer :: the phone (client.phone)
--
-- A phone in the game, the home for SharedCareer apps. The home screen shows the server time,
-- the number of players and the app grid. Apps so far: Tow (grab.lua) and Fuel (fuel.lua).
--
-- The UI is the app ui/modules/apps/SharedCareer-Phone/: a small tab with a phone icon at the
-- right screen edge (below the menu); the phone itself opens above it. Key: F4 by default
-- (BeamMP key bindings, rebindable under Options → Controls → BeamMP).
--
-- Apps: SharedCareer extensions register themselves here:
--   sharedCareer_phone.registerApp({id = "taxi", title = "Taxi", icon = "T", color = "#f5b800",
--                                   order = 10, onOpen = function() ... end, onClose = ...})
-- The phone shows every registered app on the home screen; a tap calls uiOpenApp(id), which
-- calls the app's onOpen; leaving the app (home, putting the phone away) calls uiCloseApp(id) ->
-- onClose. Apps are only listed while client.phone is on. Tow and Fuel have their own screens
-- in the phone window (app.html).
--
-- icon: a short text (letter), or the name of a built-in icon the window knows ("tow", "fuel").
--
-- guihooks: SharedCareerPhone {enabled, apps = [{id, title, icon, color}]} (state),
--           SharedCareerPhoneToggle (key). Time and players come with "SharedCareerState" (menu.lua).

local M = {}

local U

local ACTION = "sharedCareerPhone"
local KEY = "f4"

local apps = {}            -- id -> {id, title, icon, color, order, onOpen, onClose}
local keyRegistered = false

local function enabled()
	local core = U.ext("sharedCareer_core")
	local config = core and core.getConfig()
	return config ~= nil and config.phone ~= false
end

local function trigger(name, data)
	if guihooks and type(guihooks.trigger) == "function" then guihooks.trigger(name, data or {}) end
end

--- State for the phone window: on/off and the registered apps (sorted, without functions).
function M.state()
	local list = {}
	for _, app in pairs(apps) do
		table.insert(list, {id = app.id, title = app.title, icon = app.icon, color = app.color, order = app.order})
	end
	table.sort(list, function(a, b)
		if a.order ~= b.order then return a.order < b.order end
		return a.title < b.title
	end)
	return {enabled = enabled(), apps = list}
end

local function push()
	trigger("SharedCareerPhone", M.state())
end

--- Registers an app on the phone. def = {id, title, icon (short text), color, order, onOpen, onClose}.
function M.registerApp(def)
	if type(def) ~= "table" or type(def.id) ~= "string" or def.id == "" then return false end
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
	if not app or not enabled() then return false end
	if app.onOpen then
		local ok, err = pcall(app.onOpen)
		if not ok then U.log("E", "phone", "app '" .. tostring(id) .. "' failed to open: " .. tostring(err)) end
	end
	return true
end

--- The app was left (home screen, phone put away).
function M.uiCloseApp(id)
	local app = apps[id]
	if not app or not app.onClose then return end
	local ok, err = pcall(app.onClose)
	if not ok then U.log("E", "phone", "app '" .. tostring(id) .. "' failed to close: " .. tostring(err)) end
end

--== Key =========================================================================

local function registerKey()
	if keyRegistered then return end
	keyRegistered = true
	local keys = rawget(_G, "MPKeybindsGE")
	if type(keys) ~= "table" or type(keys.addAction) ~= "function" then
		U.log("W", "phone", "MPKeybindsGE.addAction not available – no phone key (BeamMP too old?)")
		return
	end
	local ok, err = pcall(keys.addAction, ACTION, {
		title = "SharedCareer: phone",
		desc = "Takes the phone out or puts it away",
		default = KEY,
		onDown = function()
			if enabled() then trigger("SharedCareerPhoneToggle") end
		end,
	})
	if not ok then U.log("E", "phone", "could not register the phone key: " .. tostring(err)) end
end

--== Hooks =======================================================================

function M.onCareerActive(active)
	if active and U.isMP() then
		registerKey()
		push()
	end
end

-- settings from the server changed (called by core.lua): phone on/off
function M.onConfigChanged()
	push()
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
