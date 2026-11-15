-- SharedCareer :: Willkommensdialog beim Join
--
-- Ein paar Sekunden, nachdem die Karriere fertig geladen ist, zeigt das SharedCareer-Menü-Fenster
-- einen Dialog mit den wichtigsten Funktionen. Knöpfe:
--   "Got it"            schließt den Dialog (kommt beim nächsten Join wieder)
--   "Don't show again"  merkt sich das in settings/sharedCareer/state.json (welcomeHidden) auf
--                       diesem PC – der Dialog kommt nicht mehr
-- Außerdem zeigt es Meldungen des Servers (sc_dialog) als Dialog.
-- Ein Klick auf das Lenkrad-Logo im SharedCareer-Menü zeigt den Dialog jederzeit wieder (show(true)).
-- Server-Schalter: client.showWelcome = false zeigt ihn niemandem.

local M = {}

local U

local STATE_FILE = "settings/sharedCareer/state.json"
local DELAY = 3            -- Sekunden, nachdem die Karriere fertig geladen ist

local shownThisJoin = false
local pending = nil        -- Dialog, der noch auf einen Knopfdruck wartet (siehe openDialog)
local waitTime = 0         -- Sekunden seit "Karriere fertig geladen", solange der Dialog aussteht

local function readState()
	local ok, state = pcall(jsonReadFile, STATE_FILE)
	return (ok and type(state) == "table") and state or {}
end

local function config()
	local core = U.ext("sharedCareer_core")
	return core and core.getConfig()
end

local function careerActive()
	return career_career and type(career_career.isActive) == "function" and career_career.isActive() == true
end

M.TITLE = "Welcome to SharedCareer"

--- Inhalt des Willkommensdialogs (reiner Text, kein HTML – das Fenster setzt ihn zusammen).
function M.content()
	return {
		kind = "welcome",
		title = M.TITLE,
		intro = "You are playing the BeamNG career together with everyone on this server.",
		items = {
			{head = "Your own save:", text = "money, cars and progress are yours and stay on your PC."},
			{head = "Shared world:", text = "same traffic, time of day and traffic lights for everyone."},
			{head = "SharedCareer menu", text = "(steering wheel tab at the right edge, key F7): time of day, traffic amount, options and players – every change applies to everyone."},
			{head = "Players tab:", text = "navigate to friends or watch them; name tags show what they are doing."},
			{head = "Fuel prices", text = "(fuel pump tab): find the cheapest station. Deliver gasoline or diesel to a station and it gets cheaper for everyone."},
			{head = "Garage computers", text = "can be used from a few meters away."},
			{head = "Chat:", text = "/pay <name> <amount> sends money, /players, /schelp."},
		},
		outro = "Click the steering wheel in the menu to see this again.",
		buttons = {
			{label = "Don't show again", action = "never"},
			{label = "Got it", action = "ok", primary = true},
		},
	}
end

-- Dialoge zeigt das SharedCareer-Menü-Fenster selbst (guihook "SharedCareerDialog"), als Karte
-- in der Bildschirmmitte. BeamMPs Dialog (MPGameNetwork.spawnUiDialog) wird bewusst NICHT
-- benutzt: er greift auf die alte Angular-Oberfläche zu und landete in BeamNG 0.40 im
-- Hauptmenü statt einen Dialog zu zeigen (0.8.1).
--
-- Der Dialog bleibt in `pending`, bis ein Knopf gedrückt wird: Ist das Fenster gerade nicht zu
-- sehen (z.B. Hauptmenü offen, dort blendet BeamNG alle Apps aus), baut es sich später neu auf,
-- fragt per uiRequestDialog() nach und zeigt ihn dann (Fehler in 0.8.2).
local function openDialog(dialog)
	pending = dialog
	if guihooks and type(guihooks.trigger) == "function" then
		guihooks.trigger("SharedCareerDialog", dialog)
		return true
	end
	return false
end

--- Zeigt den Dialog. force = true: auch wenn "Don't show again" gewählt wurde (Klick aufs Logo).
function M.show(force)
	if not force then
		local cfg = config()
		if not cfg or cfg.showWelcome == false or readState().welcomeHidden then return false end
	end
	return openDialog(M.content())
end

--- Vom Fenster: ein Knopf im Dialog wurde gedrückt.
function M.uiDialogButton(kind, action)
	pending = nil
	if kind == "welcome" and action == "never" then M.sharedCareerWelcomeNever() end
end

--- Vom Fenster beim Aufbau: offenen Dialog (falls vorhanden) noch einmal schicken.
function M.uiRequestDialog()
	if pending and guihooks and type(guihooks.trigger) == "function" then
		guihooks.trigger("SharedCareerDialog", pending)
	end
end

--== Zurück ins Spiel, falls das Hauptmenü offen ist ==========================
-- In BeamNG 0.40 landet man beim Join manchmal im Hauptmenü: Der Wechsel auf den Fahr-
-- bildschirm vom Kartenladen (BeamMP) und der vom Karrierestart überschneiden sich, das
-- Spiel geht dann auf "menu" (beamng.log: "routeChangeComplete transition id mismatch",
-- danach "Transition started: menu"). Einmal nach dem Karrierestart zurück auf "play".

local function currentRoute(router)
	for _, name in ipairs({"getCurrentRoute", "getCurrentRouteName", "getRoute", "getCurrentState"}) do
		if type(router[name]) == "function" then
			local ok, r = pcall(router[name])
			if ok then
				if type(r) == "table" then r = r.name or r.path or r.route end
				if type(r) == "string" then return r end
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
	U.log(ok and "I" or "E", "welcome", "switched to the driving screen (route was " .. tostring(route or "unknown") .. ")"
		.. (ok and "" or (": " .. tostring(err))))
	return ok
end

--- Meldung vom Server (Gast-Hinweis, Version passt nicht, Karriere startet nicht): als Dialog.
local function rxDialog(data)
	local msg = U.decode(data)
	if not msg or type(msg.title) ~= "string" then return end
	openDialog({
		kind = "server", title = msg.title, intro = tostring(msg.body or ""), items = {},
		warning = msg.warning == true,
		buttons = {{label = "OK", action = "ok", primary = true}},
	})
end

-- Knopf "Don't show again" (von BeamMP über extensions.hook gemeldet)
function M.sharedCareerWelcomeNever()
	local state = readState()
	state.welcomeHidden = true
	local ok, err = pcall(jsonWriteFile, STATE_FILE, state, true)
	if ok then U.log("I", "welcome", "welcome dialog will not be shown again")
	else U.log("E", "welcome", "could not save the welcome setting: " .. tostring(err)) end
end


--== Hooks =====================================================================

-- Erst wenn der Mod die Karriere als fertig gemeldet hat (alle Ladebildschirme weg), dann noch
-- DELAY Sekunden. Vorher würde der Dialog hinter dem Ladebildschirm erscheinen und beim Wechsel
-- auf den Fahrbildschirm wieder geschlossen (so in 0.8.0).
function M.onUpdate(dtReal)
	if shownThisJoin or not U.isMP() then return end
	local core = U.ext("sharedCareer_core")
	if not core or type(core.isReady) ~= "function" or not core.isReady() or not careerActive() then
		waitTime = 0
		return
	end
	waitTime = waitTime + (tonumber(dtReal) or 0)
	if waitTime < DELAY then return end
	shownThisJoin = true
	M.ensurePlayScreen()
	local shown = M.show(false)
	U.log("I", "welcome", shown and "welcome dialog shown" or "welcome dialog skipped (don't show again / switched off)")
end

function M.onBeamMPServerLeave()
	shownThisJoin, waitTime, pending = false, 0, nil
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	U.on("sc_dialog", rxDialog)
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
