-- SharedCareer :: welcome dialog on join
--
-- A few seconds after the career has finished loading, the SharedCareer menu window shows
-- a dialog with the most important features. Buttons:
--   "Got it"            closes the dialog (it comes back on the next join)
--   "Don't show again"  remembers that in settings/sharedCareer/state.json (welcomeHidden) on
--                       this PC – the dialog does not come back
-- It also shows messages from the server (sc_dialog) as a dialog.
-- Clicking the steering-wheel logo in the SharedCareer menu shows the dialog again at any time (show(true)).
-- Server switch: client.showWelcome = false shows it to nobody.

local M = {}

local U

local DELAY = 3 -- seconds after the career has finished loading

local shownThisJoin = false
local pending = nil -- dialog that is still waiting for a button press (see openDialog)
local waitTime = 0 -- seconds since "career finished loading" while the dialog is pending

M.TITLE = "Welcome to SharedCareer"

--- Content of the welcome dialog (plain text, no HTML – the window builds the layout).
function M.content()
	return {
		kind = "welcome",
		title = M.TITLE,
		intro = "Play the BeamNG career together.",
		items = {
			{ head = "Your save:", text = "money, cars and progress stay yours." },
			{ head = "One world:", text = "same traffic, time and traffic lights." },
			{ head = "Menu (F7):", text = "time, traffic, options, players." },
			{ head = "Phone (F4):", text = "Jobs, Tow and Fuel apps." },
			{ head = "Chat:", text = "/pay <name> <amount> sends money." },
		},
		outro = "Click the steering wheel in the menu to see this again.",
		buttons = {
			{ label = "Don't show again", action = "never" },
			{ label = "Got it", action = "ok", primary = true },
		},
	}
end

-- Dialogs are shown by the SharedCareer menu window itself (guihook "SharedCareerDialog"), as
-- a card in the middle of the screen. BeamMP's dialog (MPGameNetwork.spawnUiDialog) is
-- deliberately NOT used: it relies on the old Angular UI and in BeamNG 0.40 it opened the
-- main menu instead of showing a dialog (0.8.1).
--
-- The dialog stays in `pending` until a button is pressed: if the window is not visible
-- right now (e.g. main menu open, where BeamNG hides all apps), it rebuilds itself later,
-- asks via uiRequestDialog() and shows it then (bug in 0.8.2).
local function openDialog(dialog)
	pending = dialog
	if guihooks and type(guihooks.trigger) == "function" then
		guihooks.trigger("SharedCareerDialog", dialog)
		return true
	end
	return false
end

--- Shows the dialog. force = true: even if "Don't show again" was chosen (click on the logo).
function M.show(force)
	if not force then
		local cfg = U.config()
		if not cfg or cfg.showWelcome == false or U.readState().welcomeHidden then
			return false
		end
	end
	return openDialog(M.content())
end

--- Shows a dialog of another extension (e.g. the license shop).
function M.open(dialog)
	return openDialog(dialog)
end

--- Whether a dialog of this kind is open right now.
function M.isOpen(kind)
	return pending ~= nil and pending.kind == kind
end

--- From the window: a button in the dialog was pressed.
function M.uiDialogButton(kind, action)
	pending = nil
	if kind == "welcome" and action == "never" then
		M.sharedCareerWelcomeNever()
	end
end

--- From the window while it builds itself: send the open dialog (if any) again.
function M.uiRequestDialog()
	if pending and guihooks and type(guihooks.trigger) == "function" then
		guihooks.trigger("SharedCareerDialog", pending)
	end
end

--== Back into the game if the main menu is open ==============================
-- In BeamNG 0.40 you sometimes land in the main menu on join: the switch to the driving
-- screen from loading the map (BeamMP) and the one from the career start overlap, and
-- the game then goes to "menu" (beamng.log: "routeChangeComplete transition id mismatch",
-- then "Transition started: menu"). Once after the career start, switch back to "play".

local function currentRoute(router)
	for _, name in ipairs({ "getCurrentRoute", "getCurrentRouteName", "getRoute", "getCurrentState" }) do
		if type(router[name]) == "function" then
			local ok, r = pcall(router[name])
			if ok then
				if type(r) == "table" then
					r = r.name or r.path or r.route
				end
				if type(r) == "string" then
					return r
				end
			end
		end
	end
	return nil
end

function M.ensurePlayScreen()
	local router = U.ext("ui_router")
	if not router or type(router.navigate) ~= "function" then
		U.log("W", "welcome", "ui_router not available, cannot leave the main menu")
		return false
	end
	local route = currentRoute(router)
	if route and route ~= "menu" and route ~= "menu.mainmenu" then
		U.log("D", "welcome", "screen after career start: " .. route)
		return false
	end
	local ok, err = pcall(router.navigate, "play")
	U.log(
		ok and "I" or "E",
		"welcome",
		"switched to the driving screen (route was "
			.. tostring(route or "unknown")
			.. ")"
			.. (ok and "" or (": " .. tostring(err)))
	)
	return ok
end

--- Message from the server (guest notice, version mismatch, career does not start): as a dialog.
local function rxDialog(data)
	local msg = U.decode(data)
	if not msg or type(msg.title) ~= "string" then
		return
	end
	openDialog({
		kind = "server",
		title = msg.title,
		intro = tostring(msg.body or ""),
		items = {},
		warning = msg.warning == true,
		buttons = { { label = "OK", action = "ok", primary = true } },
	})
end

-- "Don't show again" button (reported by BeamMP via extensions.hook)
function M.sharedCareerWelcomeNever()
	local state = U.readState()
	state.welcomeHidden = true
	if U.writeState(state) then
		U.log("I", "welcome", "welcome dialog will not be shown again")
	end
end

--== Hooks =====================================================================

-- Only once the mod has reported the career as ready (all loading screens gone), then another
-- DELAY seconds. Earlier, the dialog would appear behind the loading screen and be closed
-- again on the switch to the driving screen (as in 0.8.0).
function M.onUpdate(dtReal)
	if shownThisJoin or not U.isMP() then
		return
	end
	local core = U.ext("sharedCareer_core")
	if not core or type(core.isReady) ~= "function" or not core.isReady() or not U.careerActive() then
		waitTime = 0
		return
	end
	waitTime = waitTime + (tonumber(dtReal) or 0)
	if waitTime < DELAY then
		return
	end
	shownThisJoin = true
	M.ensurePlayScreen()
	local shown = M.show(false)
	U.log(
		"I",
		"welcome",
		shown and "welcome dialog shown" or "welcome dialog skipped (don't show again / switched off)"
	)
end

function M.onBeamMPServerLeave()
	shownThisJoin, waitTime, pending = false, 0, nil
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	U.on("sc_dialog", rxDialog)
end

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
