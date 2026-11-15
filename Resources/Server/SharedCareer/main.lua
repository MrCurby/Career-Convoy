-- SharedCareer :: BeamMP-Server-Plugin
--
-- Gemeinsamer Karrieremodus für BeamMP: alle spielen die normale BeamNG-Karriere in einer
-- geteilten Welt, jeder mit seinem eigenen Spielstand auf dem eigenen PC.
--
-- Der Server ist Vermittler und Schiedsrichter:
--   * schickt jedem Spieler beim Join die Einstellungen; danach startet der Client die Karriere
--   * vergibt pro BeamMP-Account einen festen Profilnamen (config/profiles.json)
--   * führt die Liste, welche Fahrzeuge sichtbar/versteckt bzw. Traffic sind, und verteilt sie
--   * teilt die Traffic-Menge fair auf alle Spieler auf
--   * führt die Uhr (Tageszeit, Tag und Nacht verschieden schnell) und die Ampel-Schaltung
--   * wickelt Überweisungen zwischen Spielern in zwei Schritten ab (erst abbuchen, dann gutschreiben)
--
-- Nur BeamMP-Server-API (MP.*, Util.*, FS.*), kein Spielcode.
--
-- DATEIEN (Resources/Server/SharedCareer/config/)
--   config.json    Einstellungen (siehe DEFAULTS unten) + die Standardwerte, mit denen die
--                  Datei geschrieben wurde (_defaults; für automatische Updates)
--   profiles.json  BeamMP-Account-ID -> Profilname
--   fuelprices.json Rabatte der Tankstellen durch Spritlieferungen (Station -> Sorte -> %)
--
-- BEFEHLE IN DER SERVER-KONSOLE
--   sc help                           Kurzhilfe
--   sc get                            alle Einstellungen anzeigen
--   sc set <server|client>.<name> <wert>
--                                     Einstellung ändern; wird gespeichert und client.* sofort
--                                     an alle Spieler geschickt. Ohne <wert> = leerer Text.
--   sc time                           aktuelle Uhrzeit und Tag-/Nachtlänge anzeigen
--   sc time <HH:MM | Stunde>          Uhrzeit für alle setzen, z.B. sc time 18:30
--   sc time stop | start              Uhr anhalten (Uhrzeit bleibt stehen) / weiterlaufen lassen
--   sc players                        Spieler und ob ihre Karriere läuft
--   sc fuel | sc fuel reset           Rabatte der Tankstellen anzeigen / alle zurücksetzen
--   sc reload                         config.json neu einlesen
--
-- BEFEHLE IM CHAT (für Spieler; werden nicht im Chat angezeigt)
--   /pay <Name> <Betrag>              Geld an einen Spieler überweisen (Teilname reicht)
--   /players                          wer ist da, wer lädt noch
--   /schelp                           Hilfe
--
-- NACHRICHTEN ZWISCHEN CLIENT UND SERVER (alle JSON)
--   Client -> Server                  Server -> Client
--   sc_hello            {version}     sc_config / sc_configUpdate   Client-Einstellungen
--   sc_careerResult     {ok, reason,  sc_vehStates   {"<pid>-<vid>": {active, traffic}}
--                        profile}     sc_traffic     {road, parked}  neuer Traffic-Anteil
--   sc_vehActive        {id, active}  sc_time        {hour, play, dayLength, dayLengthDay,
--   sc_vehMarks         {id: bool}                    dayLengthNight, dayStart, nightStart,
--                                                     dayMinutes, nightMinutes, canControl}
--   sc_vehStatesRequest               sc_signals     Ampel-Takt (Sekunden)
--   sc_payDebitResult   {id, ok}      sc_payDebit / sc_payCredit   Überweisung
--   sc_payCreditAck     {id}
--   sc_timeControl      {action = "set", hour} | {action = "lengths", dayMinutes, nightMinutes}
--                       | {action = "pause", paused = true|false}
--   sc_setSetting       {key = "client.roadTraffic", value}  (Menü, nur erlaubte Einstellungen)
--   sc_status           {status = driving|walking|mission|loading}
--   Server -> Client: sc_dialog {title, body, warning}  Meldung als Dialog im Menü-Fenster
--   Server -> Client: sc_players {players = [{id, name, status}]}  (Reiter Players, Namensschilder)
--   sc_fuelDelivered    {station, fuel, amount, stationName}  eigene Spritlieferung an eine Tankstelle
--   Server -> Client: sc_fuelPrices {enabled, factors = {[station] = {gasoline = 0.9, ...}}}
--                       (aus dem UI-Fenster "SharedCareer Tageszeit")

local VERSION = "0.8.5"
local TAG = "[SharedCareer] "

local CONFIG_DIR = "Resources/Server/SharedCareer/config"
local CONFIG_FILE = CONFIG_DIR .. "/config.json"

local MAX_PAYLOAD = 16384 -- Bytes; größere Client-Nachrichten werden ignoriert

local DEFAULTS = {
	server = {
		-- Überweisungen zwischen Spielern per Chat: /pay <Name> <Betrag>
		allowPayments = true,
		paymentMax = 1000000,
		paymentCooldownSeconds = 5,
		-- Spieler rauswerfen, wenn seine Karriere nicht startet (sonst Hinweis-Dialog)
		kickOnFailedStart = false,
		-- Ampeln für alle gleich schalten (Abgleich alle 10 s)
		trafficSignalSync = true,
		-- Tageszeit: Startzeit nach Serverstart (Stunde 0–24, z.B. 10.5 = 10:30).
		-- Tag (dayStartHour bis nightStartHour) und Nacht laufen unterschiedlich schnell:
		-- dayMinutes / nightMinutes = echte Minuten für den ganzen Tag- bzw. Nachtabschnitt.
		-- Eine der beiden auf 0 = Zeit steht still. Im Betrieb: sc time 18:30
		startHour = 10,
		dayMinutes = 50,
		nightMinutes = 5,
		dayStartHour = 6,
		nightStartHour = 20,
		-- Jeder Spieler darf Uhrzeit und Tag-/Nachtlänge über das UI-Fenster "SharedCareer
		-- Tageszeit" verstellen; es gilt sofort für alle. false = nur noch per Konsole (sc time).
		allowPlayerTimeControl = true,
		-- Jeder Spieler darf im SharedCareer-Menü (Reiter Traffic / Optionen) die dort
		-- angebotenen Einstellungen für alle ändern. false = nur noch per Konsole.
		allowPlayerSettings = true,
		-- "Teleport" im Reiter Players: das eigene Auto zu einem anderen Spieler springen lassen.
		-- Standardmäßig aus, weil es in der Karriere Fahrwege und Tankkosten umgeht.
		allowTeleport = false,
		-- Gemeinsame Spritpreise: alle zahlen an einer Tankstelle denselben Preis (ohne Zufall),
		-- und wer Benzin/Diesel dorthin liefert, macht diese Sorte dort für alle günstiger.
		fuelEconomy = true,
		fuelLitersPerStep = 1000,     -- so viele Liter ...
		fuelDiscountPerStep = 5,      -- ... machen die Sorte an der Station um so viele % günstiger
		fuelMaxDiscount = 30,         -- höchstens so viel % günstiger
		fuelRecoveryPercent = 1,      -- der Rabatt sinkt um so viele Prozentpunkte ...
		fuelRecoveryMinutes = 5,      -- ... alle so viele Minuten (Preis kehrt langsam zurück)
		-- Uhr angehalten: die Uhrzeit bleibt stehen, bis jemand "Weiter" drückt (Fenster) oder
		-- sc time start eingibt. Stopp: Fenster oder sc time stop.
		timePaused = false,
		-- Traffic für den ganzen Server (0 = kein Limit). Jeder Spieler bekommt
		-- client.roadTraffic / client.parkedTraffic, bis die Summe das Limit überschreitet;
		-- dann wird das Limit gleichmäßig aufgeteilt.
		roadTrafficTotal = 20,
		parkedTrafficTotal = 24,
	},
	client = {
		-- Wird an den Profilnamen gehängt, z.B. "_meinserver", damit jeder Server einen
		-- eigenen Spielstand bekommt. Leer = derselbe Spielstand auf jedem SharedCareer-Server.
		saveSuffix = "",
		-- Traffic, den JEDER Spieler spawnt (fahrend / geparkt, je 0–50). BeamMP zeigt ihn
		-- allen; die Server-Grenzen roadTrafficTotal / parkedTrafficTotal gelten zusätzlich.
		roadTraffic = 6,
		parkedTraffic = 8,
		-- Reserve: so viele Autos (fahrend und geparkt) spawnt jeder Spieler beim Join
		-- zusätzlich versteckt mit. Bis dahin lässt sich die Traffic-Menge im Menü LIVE
		-- erhöhen; mehr wirkt erst beim nächsten Join. Weniger geht immer live.
		-- Kostet etwas Ladezeit, weil BeamMP auch versteckte Autos bei allen baut.
		trafficReserve = 4,
		-- Autos anderer SPIELER ohne Kollision (true) oder mit (false). Gilt nicht für KI-Traffic:
		-- mit Traffic/geparkten Autos stößt man immer zusammen, egal wem sie gehören.
		remoteVehicleGhost = false,
		-- Andere Spieler, die zu Fuß unterwegs sind (Unicycle), ohne Kollision – so kann man
		-- niemanden aus Versehen umfahren
		remoteUnicycleGhost = true,
		-- Traffic als vereinfachte Fahrzeuge ("simple_traffic") spawnen. Weil BeamMP die
		-- Konfiguration des Besitzers an alle schickt, ist der Traffic dann überall einfach.
		trafficSimpleVehicles = true,
		-- Aggressivität der Traffic-KI, 0.05 (sehr vorsichtig) bis 1 (sehr aggressiv).
		-- Niedriger = bremst früher, hält mehr Abstand. 0 = Spielstandard, nicht verändern.
		-- Polizei ist ausgenommen. Live änderbar: sc set client.trafficAggression 0.15
		trafficAggression = 0.2,
		-- Garagen-Computer aus der Nähe benutzen: "Computer benutzen" erscheint schon in diesem
		-- Abstand (Meter, halbe Kantenlänge der Zone). 0 = Spielstandard (direkt davor). Max 30.
		computerAccessRange = 6,
		-- Tageszeit vom Server für alle gleich (sonst hat jeder seine eigene)
		syncTimeOfDay = true,
		-- Zeit, Wetter, Zeitlupe und Traffic im Pausemenü nur anzeigen, nicht verstellen
		lockEnvironment = true,
		-- Beim Join Mileage-Reste (rote "Unknown app"-Kästen) aus den UI-Layouts der Spieler
		-- entfernen und die BeamMP-Spielerliste zurückholen. Dateien werden vorher gesichert.
		cleanupMileageApps = true,
		-- Das Fenster "SharedCareer Tageszeit" beim ersten Join automatisch ins Karriere-Layout
		-- setzen (einmalig; wer es entfernt, bekommt es nicht wieder).
		addTimeApp = true,
		-- Status hinter dem Namen der Spieler: [Mission], [On foot], [Loading]
		showPlayerStatus = true,
		-- Willkommensdialog beim Join mit den wichtigsten Funktionen (jeder kann "Don't show again"
		-- wählen; ein Klick aufs Lenkrad-Logo im Menü zeigt ihn wieder)
		showWelcome = true,
		-- Zusätzlich die Autos der ANDEREN Spieler lokal vereinfacht bauen (BeamMP-Funktion,
		-- 17 Standardmodelle). Für schwache PCs; Autos sehen dann schlichter aus.
		simplifyRemoteVehicles = false,
		-- Lua-Konsole (Taste ^ bzw. ~) und Welteditor im Spiel erlauben. Aus = Schutz gegen
		-- Schummeln und versehentliches Kaputtmachen der geteilten Welt.
		allowConsole = false,
		allowWorldEditor = false,
	},
}

local Config

-- player_id -> {name, counted (hat Einstellungen bekommen), careerActive, startFailed,
--               account (BeamMP-ID oder nil), guest, profile, lastPaymentAt}
local players = {}
-- "<player_id>-<vehicle_id>" -> {active = bool, traffic = bool|nil}
local vehicleStates = {}
-- transfer id -> {from, to, fromName, toName, amount, stage, createdAt}
local transfers = {}
local transferSeq = 0
-- player_id -> {road, parked} zuletzt geschickter Traffic-Anteil
local sharesSent = {}

local clock = MP.CreateTimer()

local function now()
	return clock:GetCurrent()
end

--== Hilfen ====================================================================

local function log(msg)
	print(TAG .. msg)
end

local function encode(value)
	return Util.JsonEncode(value)
end

local function decodeTable(data)
	if type(data) ~= "string" or #data == 0 or #data > MAX_PAYLOAD then return nil end
	local ok, value = pcall(Util.JsonDecode, data)
	if ok and type(value) == "table" then return value end
	return nil
end

local function send(player_id, event, value)
	local data = type(value) == "string" and value or encode(value)
	MP.TriggerClientEvent(player_id, event, data)
end

local function chat(player_id, msg)
	MP.SendChatMessage(player_id, msg)
end

-- Einblendung im Spiel (BeamMP-Benachrichtigung). Funktioniert auch, wenn der Chat in der
-- Karriere nicht sichtbar ist. Ältere Server ohne MP.SendNotification: Chat.
local function notify(player_id, msg, icon)
	if type(MP.SendNotification) == "function" then
		local ok = pcall(MP.SendNotification, player_id, msg, icon or "info")
		if ok then return end
	end
	chat(player_id, msg)
end

-- Dialog mit OK-Knopf, für Dinge, die der Spieler nicht übersehen darf. Angezeigt vom
-- SharedCareer-Menü-Fenster (sc_dialog); dazu eine Einblendung, falls das Fenster gerade nicht
-- da ist (z.B. Karriere startet nicht). BeamMPs MP.ConfirmationDialog wird bewusst NICHT benutzt:
-- er führte in BeamNG 0.40 ins Hauptmenü statt einen Dialog zu zeigen.
local function dialog(player_id, title, body, warning)
	send(player_id, "sc_dialog", {title = title, body = body, warning = warning == true})
	notify(player_id, title .. ": " .. tostring(body):gsub("%s+", " "):sub(1, 200), warning and "warning" or "info")
end

local function isConnected(player_id)
	return players[player_id] ~= nil and MP.IsPlayerConnected(player_id)
end

local function playerName(player_id)
	local entry = players[player_id]
	return (entry and entry.name) or MP.GetPlayerName(player_id) or ("#" .. tostring(player_id))
end

local function clampInt(value, low, high)
	local n = tonumber(value)
	if not n or n ~= n then return low end
	return math.floor(math.max(low, math.min(high, n)))
end

--== Konfiguration =============================================================

local function readFile(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local text = f:read("*a")
	f:close()
	return text
end

-- Die Datei enthält neben den Einstellungen die Standardwerte, mit denen sie zuletzt
-- geschrieben wurde (_defaults). Daran erkennt loadConfig nach einem Update, welche Werte
-- noch auf dem alten Standard stehen (-> bekommen den neuen) und welche jemand geändert hat
-- (-> bleiben). So reicht es, ein Update einfach einzuspielen.
local function saveConfig()
	if FS and FS.CreateDirectory and not FS.Exists(CONFIG_DIR) then FS.CreateDirectory(CONFIG_DIR) end
	local text = encode({server = Config.server, client = Config.client, _defaults = DEFAULTS, _version = VERSION})
	if Util.JsonPrettify then text = Util.JsonPrettify(text) end
	local f = io.open(CONFIG_FILE, "w")
	if not f then
		log("Could not write " .. CONFIG_FILE)
		return false
	end
	f:write(text)
	f:close()
	return true
end

-- Standardwerte früherer Versionen, für Config-Dateien ohne _defaults (bis 0.3.1).
local OLD_DEFAULTS = {
	server = {dayMinutes = {45}, nightMinutes = {15}},
}

local function wasDefault(section, key, value, recorded)
	local rec = type(recorded) == "table" and type(recorded[section]) == "table" and recorded[section] or nil
	if rec and rec[key] ~= nil then return rec[key] == value end
	for _, old in ipairs((OLD_DEFAULTS[section] or {})[key] or {}) do
		if old == value then return true end
	end
	return false
end

-- Übernimmt die geladenen Werte; ein Wert, der noch auf dem alten Standard steht, bekommt
-- den neuen Standard. Gibt die Liste der so aktualisierten Einstellungen zurück.
local function mergeConfig(loaded)
	local result, updated = {}, {}
	for section, defaults in pairs(DEFAULTS) do
		result[section] = {}
		local values = type(loaded) == "table" and type(loaded[section]) == "table" and loaded[section] or {}
		for key, default in pairs(defaults) do
			local value = values[key]
			if type(value) ~= type(default) then
				result[section][key] = default
			elseif value ~= default and wasDefault(section, key, value, loaded and loaded._defaults) then
				result[section][key] = default
				table.insert(updated, string.format("%s.%s: %s -> %s", section, key, tostring(value), tostring(default)))
			else
				result[section][key] = value
			end
		end
	end
	table.sort(updated)
	return result, updated
end

local function loadConfig()
	local loaded = nil
	local text = readFile(CONFIG_FILE)
	if text then
		local ok, value = pcall(Util.JsonDecode, text)
		if ok and type(value) == "table" then
			loaded = value
		else
			-- Kaputte Datei nicht einfach überschreiben: sichern, damit nichts verloren geht.
			local backup = CONFIG_FILE .. ".broken"
			local f = io.open(backup, "w")
			if f then f:write(text); f:close() end
			log("config.json is not valid JSON – saved as config.json.broken, using default settings")
		end
	end
	local updated
	Config, updated = mergeConfig(loaded)
	if #updated > 0 then
		log("Update: " .. #updated .. " setting(s) moved to the new default (values you changed are kept):")
		for _, line in ipairs(updated) do log("  " .. line) end
	end
	saveConfig() -- neue Einstellungen und Standardwerte erscheinen so automatisch in der Datei
end

--== Spielstand-Zuordnung ======================================================
-- Die Spielstände liegen lokal auf jedem PC; ihr Name kommt vom Server. Damit eine
-- Namensänderung bei BeamMP nicht den Spielstand "verliert", merkt sich der Server pro
-- BeamMP-Account den Profilnamen vom ersten Join (config/profiles.json). Bestehende
-- Profile laufen so einfach weiter. Gäste haben keinen Account: ihr Profil hängt am
-- Gastnamen.

local PROFILES_FILE = CONFIG_DIR .. "/profiles.json"
local profiles = {} -- BeamMP-Account-ID (string) -> Profilname

local function sanitizeProfile(name)
	local s = string.lower(tostring(name or "")):gsub("[^a-z0-9]", "")
	if s == "" then s = "sharedcareer" end
	return s
end

local function loadProfiles()
	local text = readFile(PROFILES_FILE)
	if not text then return end
	local ok, value = pcall(Util.JsonDecode, text)
	if ok and type(value) == "table" then
		profiles = {}
		for account, name in pairs(value) do
			if type(name) == "string" then profiles[tostring(account)] = sanitizeProfile(name) end
		end
	else
		log("profiles.json is not valid JSON – it will be rewritten on the next join")
	end
end

local function saveProfiles()
	local text = encode(next(profiles) and profiles or {})
	if Util.JsonPrettify then text = Util.JsonPrettify(text) end
	local f = io.open(PROFILES_FILE, "w")
	if not f then
		log("Could not write " .. PROFILES_FILE)
		return
	end
	f:write(text)
	f:close()
end

-- {account = "<id>"|nil, guest = bool}
local function identityOf(player_id)
	local guest = false
	if type(MP.IsPlayerGuest) == "function" then
		local ok, value = pcall(MP.IsPlayerGuest, player_id)
		guest = ok and value == true
	end
	local account = nil
	if type(MP.GetPlayerIdentifiers) == "function" then
		local ok, ids = pcall(MP.GetPlayerIdentifiers, player_id)
		if ok and type(ids) == "table" and ids.beammp ~= nil then
			account = tostring(ids.beammp):match("^%d+$")
		end
	end
	if guest then account = nil end
	return {account = account, guest = guest or account == nil}
end

-- Profilname für diesen Spieler (ohne Server-Suffix; das hängt der Client an).
local function profileFor(player_id, identity)
	if identity.account then
		local known = profiles[identity.account]
		if known then return known end
		local name = sanitizeProfile(playerName(player_id))
		profiles[identity.account] = name
		saveProfiles()
		return name
	end
	return sanitizeProfile(playerName(player_id))
end

--== Traffic-Anteile ===========================================================
-- Jeder Spieler spawnt eigenen Traffic, und BeamMP zeigt ihn allen. Damit es bei vielen
-- Spielern nicht zu voll wird, gilt eine Grenze für den ganzen Server
-- (server.roadTrafficTotal / parkedTrafficTotal). Bis zur Grenze bekommt jeder die volle
-- Menge (client.roadTraffic / parkedTraffic), darüber wird die Grenze gleichmäßig geteilt;
-- übrige Autos gehen an die niedrigsten Spieler-IDs. Ändert sich die Spielerzahl, bekommen
-- alle sofort ihren neuen Anteil (sc_traffic).

-- Spieler, die schon Einstellungen bekommen haben, nach ID sortiert.
local function careerPlayerIds()
	local ids = {}
	for id, entry in pairs(players) do
		if entry.counted then table.insert(ids, id) end
	end
	table.sort(ids)
	return ids
end

-- Anteil eines Spielers: perPlayer pro Kopf, bis alle zusammen `total` überschreiten.
local function shareOf(perPlayer, total, ids, player_id)
	perPlayer = clampInt(perPlayer, 0, 50)
	total = clampInt(total, 0, 400)
	local n = #ids
	if total == 0 or n == 0 or perPlayer * n <= total then return perPlayer end
	local each = math.floor(total / n)
	local spare = total - each * n
	for i, id in ipairs(ids) do
		if id == player_id then return math.min(perPlayer, each + (i <= spare and 1 or 0)) end
	end
	return math.min(perPlayer, each)
end

-- {road, parked} für diesen Spieler.
local function trafficShareFor(player_id)
	local ids = careerPlayerIds()
	return {
		road = shareOf(Config.client.roadTraffic, Config.server.roadTrafficTotal, ids, player_id),
		parked = shareOf(Config.client.parkedTraffic, Config.server.parkedTrafficTotal, ids, player_id),
	}
end

-- Schickt jedem Spieler mit laufender Karriere seinen neuen Anteil, wenn er sich geändert hat.
local function updateTrafficShares()
	for _, id in ipairs(careerPlayerIds()) do
		local share = trafficShareFor(id)
		local last = sharesSent[id]
		if isConnected(id) and last and (last.road ~= share.road or last.parked ~= share.parked) then
			sharesSent[id] = share
			send(id, "sc_traffic", share)
		end
	end
end

--== Fahrzeugzustände ==========================================================
-- Die Karriere versteckt eigene Autos oft (Garage, Händler, Missionen); BeamMP überträgt das
-- nicht. Jeder Client meldet daher Verstecken/Zeigen und welche seiner Autos Traffic sind;
-- der Server führt die Liste (vehicleStates) und verteilt Änderungen an alle anderen.
-- Neue Spieler bekommen die ganze Liste beim Join.

-- Ein Client darf nur seine eigenen Fahrzeuge melden ("<seine player_id>-<vehicle_id>").
local function ownsVehicle(player_id, serverVehicleID)
	if type(serverVehicleID) ~= "string" then return false end
	local owner = serverVehicleID:match("^(%d+)%-%d+$")
	return owner ~= nil and tonumber(owner) == tonumber(player_id)
end

-- Schickt Zustände an alle (außer `except`, meist der Absender selbst).
local function broadcastStates(states, except)
	local data = encode(states)
	for id in pairs(players) do
		if id ~= except and MP.IsPlayerConnected(id) then
			MP.TriggerClientEvent(id, "sc_vehStates", data)
		end
	end
end

--== Tageszeit =================================================================
-- Der Server führt die Uhr: timeState.hour galt zum Zeitpunkt timeState.at. Tag und Nacht
-- laufen mit eigenem Tempo (Spielstunden pro echter Sekunde); die Uhr wird stückweise
-- bis zur nächsten Grenze (Tagesbeginn / Nachtbeginn) vorgerechnet. Die Spieler gleichen
-- alle 30 s ab und stellen beim Wechsel Tag/Nacht selbst auf das andere Tempo um.

local timeState = nil

-- {dayStart, nightStart, daySpeed, nightSpeed} oder nil, wenn die Zeit steht.
local function timePhases()
	local dayStart = tonumber(Config.server.dayStartHour) or 6
	local nightStart = tonumber(Config.server.nightStartHour) or 20
	if not (dayStart >= 0 and dayStart < nightStart and nightStart < 24) then dayStart, nightStart = 6, 20 end
	local dayMin = tonumber(Config.server.dayMinutes) or 0
	local nightMin = tonumber(Config.server.nightMinutes) or 0
	if dayMin <= 0 or nightMin <= 0 then return nil end
	local dayHours, nightHours = nightStart - dayStart, 24 - (nightStart - dayStart)
	return {
		dayStart = dayStart, nightStart = nightStart,
		daySpeed = dayHours / (dayMin * 60),     -- Spielstunden pro echter Sekunde
		nightSpeed = nightHours / (nightMin * 60),
	}
end

local function isDay(hour, ph)
	return hour >= ph.dayStart and hour < ph.nightStart
end

-- Uhrzeit nach `seconds` echten Sekunden ab `hour`.
local function advance(hour, seconds, ph)
	hour = hour % 24
	local guard = 0
	while seconds > 0 and guard < 1000 do
		guard = guard + 1
		local day = isDay(hour, ph)
		local speed = day and ph.daySpeed or ph.nightSpeed
		local boundary = day and ph.nightStart or ph.dayStart
		local untilBoundary = (boundary - hour) % 24
		if untilBoundary == 0 then untilBoundary = 24 end
		local needed = untilBoundary / speed
		if seconds < needed then return (hour + seconds * speed) % 24 end
		seconds = seconds - needed
		hour = boundary % 24
	end
	return hour
end

local function currentHour()
	if not timeState then timeState = {hour = (tonumber(Config.server.startHour) or 10) % 24, at = now()} end
	local ph = timePhases()
	if not ph or Config.server.timePaused == true then return timeState.hour end
	return advance(timeState.hour, now() - timeState.at, ph)
end

local function setHour(hour)
	timeState = {hour = hour % 24, at = now()}
end

-- Vor einer Änderung des Tempos: aktuelle Uhrzeit festhalten, sonst springt sie.
local function rebaseTime()
	setHour(currentHour())
end

-- dayLength = Länge eines ganzen Tages in echten Sekunden bei dem jeweiligen Tempo
-- (so rechnet BeamNG); der Client nimmt je nach Uhrzeit dayLengthDay oder -Night.
local function timePayload()
	local ph = timePhases()
	local hour = currentHour()
	-- Für das UI-Fenster: eingestellte Längen und ob Spieler steuern dürfen.
	local paused = Config.server.timePaused == true
	local extra = {
		dayMinutes = tonumber(Config.server.dayMinutes) or 0,
		nightMinutes = tonumber(Config.server.nightMinutes) or 0,
		canControl = Config.server.allowPlayerTimeControl == true,
		paused = paused,
	}
	local payload
	if not ph or paused then
		payload = {hour = hour, play = false, dayLength = 0,
			dayStart = tonumber(Config.server.dayStartHour) or 6, nightStart = tonumber(Config.server.nightStartHour) or 20}
	else
		local lenDay, lenNight = 24 / ph.daySpeed, 24 / ph.nightSpeed
		payload = {
			hour = hour, play = true,
			dayLength = isDay(hour, ph) and lenDay or lenNight,
			dayLengthDay = lenDay, dayLengthNight = lenNight,
			dayStart = ph.dayStart, nightStart = ph.nightStart,
		}
	end
	for k, v in pairs(extra) do payload[k] = v end
	return payload
end

local function sendTime(player_id)
	if Config.client.syncTimeOfDay ~= true then return end
	send(player_id, "sc_time", timePayload())
end

local function formatHour(hour)
	local h = math.floor(hour)
	local m = math.floor((hour - h) * 60 + 0.5)
	if m == 60 then h, m = (h + 1) % 24, 0 end
	return string.format("%02d:%02d", h, m)
end

local TIME_KEYS = {dayMinutes = true, nightMinutes = true, dayStartHour = true, nightStartHour = true, timePaused = true}

-- Uhr anhalten/weiterlaufen lassen. Vorher die aktuelle Uhrzeit festhalten, damit sie
-- genau dort stehen bleibt bzw. von dort weiterläuft.
local function setPaused(paused)
	if (Config.server.timePaused == true) == paused then return false end
	rebaseTime()
	Config.server.timePaused = paused
	saveConfig()
	return true
end

-- Neue Uhrzeit/Längen sofort an alle Spieler mit laufender Karriere.
local function sendTimeToAll()
	for id, entry in pairs(players) do
		if entry.careerActive and MP.IsPlayerConnected(id) then sendTime(id) end
	end
end

--== Einstellungen für einen Spieler ===========================================
-- Was der Client bekommt (sc_config beim Join, sc_configUpdate bei Änderungen): alle
-- client.*-Einstellungen, sein Traffic-Anteil, und unter "ui" die Server-Werte, die das
-- SharedCareer-Menü anzeigt.

local function settingsFor(player_id)
	local settings = {}
	for key, value in pairs(Config.client) do settings[key] = value end
	settings.trafficShare = trafficShareFor(player_id)
	settings.serverVersion = VERSION
	local entry = players[player_id]
	if entry then
		settings.profileBase = entry.profile
		settings.isGuest = entry.guest
	end
	local count = 0
	for _, e in pairs(players) do if e.counted then count = count + 1 end end
	settings.ui = {
		roadTrafficTotal = Config.server.roadTrafficTotal,
		parkedTrafficTotal = Config.server.parkedTrafficTotal,
		trafficSignalSync = Config.server.trafficSignalSync,
		allowPlayerSettings = Config.server.allowPlayerSettings == true,
		allowTeleport = Config.server.allowTeleport == true,
		players = count,
	}
	return settings
end

-- Neue Einstellungen an alle, die schon spielen.
local function sendSettingsToAll()
	for id, entry in pairs(players) do
		if entry.counted and MP.IsPlayerConnected(id) then
			local settings = settingsFor(id)
			sharesSent[id] = settings.trafficShare
			send(id, "sc_configUpdate", settings)
		end
	end
end

--== Spritpreise (gemeinsame Wirtschaft) =======================================
-- discounts[station][fuel] = Rabatt in Prozent (0..fuelMaxDiscount). Station = ID der
-- Tankstelle wie im Spiel (freeroam_facilities gasStations), fuel = "gasoline" | "diesel".
-- Gespeichert in config/fuelprices.json, an alle als sc_fuelPrices {enabled, factors}.
local FUEL_FILE = CONFIG_DIR .. "/fuelprices.json"
local FUEL_TYPES = {gasoline = true, diesel = true}
local fuelDiscounts = {}
local fuelRecoveryElapsed = 0

local function loadFuel()
	local text = readFile(FUEL_FILE)
	if not text then return end
	local ok, value = pcall(Util.JsonDecode, text)
	if not ok or type(value) ~= "table" then log("fuelprices.json is not valid JSON – starting with normal prices") return end
	fuelDiscounts = {}
	for station, fuels in pairs(value) do
		if type(fuels) == "table" then
			for fuel, d in pairs(fuels) do
				if FUEL_TYPES[fuel] and tonumber(d) and tonumber(d) > 0 then
					fuelDiscounts[station] = fuelDiscounts[station] or {}
					fuelDiscounts[station][fuel] = tonumber(d)
				end
			end
		end
	end
end

local function saveFuel()
	local text = encode(next(fuelDiscounts) and fuelDiscounts or {})
	if Util.JsonPrettify then text = Util.JsonPrettify(text) end
	local f = io.open(FUEL_FILE, "w")
	if not f then log("Could not write " .. FUEL_FILE) return end
	f:write(text)
	f:close()
end

local function fuelPayload()
	local factors = {}
	for station, fuels in pairs(fuelDiscounts) do
		factors[station] = {}
		for fuel, d in pairs(fuels) do factors[station][fuel] = 1 - d / 100 end
	end
	return {enabled = Config.server.fuelEconomy == true, factors = factors}
end

local function sendFuel(player_id)
	send(player_id, "sc_fuelPrices", fuelPayload())
end

local function sendFuelToAll()
	local data = encode(fuelPayload())
	for id, entry in pairs(players) do
		if entry.careerActive and MP.IsPlayerConnected(id) then MP.TriggerClientEvent(id, "sc_fuelPrices", data) end
	end
end

-- Ein Client meldet eine eigene Spritlieferung: {station, fuel, amount, stationName?}
local FUEL_MAX_AMOUNT = 100000
function sc_fuelDelivered(player_id, data)
	local entry = players[player_id]
	local msg = decodeTable(data)
	if not entry or not entry.careerActive or not msg or Config.server.fuelEconomy ~= true then return end
	local station, fuel, amount = msg.station, msg.fuel, tonumber(msg.amount)
	if type(station) ~= "string" or #station == 0 or #station > 64 or not FUEL_TYPES[fuel] then return end
	if not amount or amount ~= amount or amount <= 0 then return end
	amount = math.min(amount, FUEL_MAX_AMOUNT)
	local perStep = math.max(1, tonumber(Config.server.fuelLitersPerStep) or 1000)
	local maxD = math.max(0, math.min(90, tonumber(Config.server.fuelMaxDiscount) or 30))
	local add = amount / perStep * (tonumber(Config.server.fuelDiscountPerStep) or 5)
	fuelDiscounts[station] = fuelDiscounts[station] or {}
	local before = fuelDiscounts[station][fuel] or 0
	local after = math.min(maxD, before + add)
	fuelDiscounts[station][fuel] = after
	saveFuel()
	sendFuelToAll()
	local name = type(msg.stationName) == "string" and msg.stationName ~= "" and msg.stationName:sub(1, 64) or station
	log(string.format("%s delivered %d l %s to %s: discount %.1f%% -> %.1f%%", playerName(player_id), amount, fuel, station, before, after))
	for id, e in pairs(players) do
		if e.careerActive and MP.IsPlayerConnected(id) then
			notify(id, string.format("%s delivered %d l of %s to %s – %s there is now %d%% cheaper",
				playerName(player_id), math.floor(amount + 0.5), fuel, name, fuel, math.floor(after + 0.5)), "local_gas_station")
		end
	end
end

-- Jede Sekunde: Rabatte sinken langsam (Preise kehren zum Normalpreis zurück).
local function fuelRecoveryTick(dt)
	if Config.server.fuelEconomy ~= true or not next(fuelDiscounts) then return end
	fuelRecoveryElapsed = fuelRecoveryElapsed + dt
	local every = math.max(0.1, tonumber(Config.server.fuelRecoveryMinutes) or 5) * 60
	if fuelRecoveryElapsed < every then return end
	fuelRecoveryElapsed = 0
	local step = math.max(0, tonumber(Config.server.fuelRecoveryPercent) or 1)
	if step == 0 then return end
	for station, fuels in pairs(fuelDiscounts) do
		for fuel, d in pairs(fuels) do
			fuels[fuel] = d - step > 0.01 and d - step or nil
		end
		if not next(fuels) then fuelDiscounts[station] = nil end
	end
	saveFuel()
	sendFuelToAll()
end

--== Spielerliste (Reiter "Players", Status am Namensschild) =====================
-- Jeder Client meldet seinen Status (sc_status); der Server schickt allen die Liste
-- (sc_players) bei Join, Karrierestart, Statuswechsel und Verlassen.
local PLAYER_STATUS = {driving = true, walking = true, mission = true, loading = true}

local function broadcastPlayers()
	local list = {}
	for id, entry in pairs(players) do
		if entry.counted then
			table.insert(list, {id = id, name = playerName(id),
				status = entry.careerActive and (entry.status or "driving") or "loading"})
		end
	end
	table.sort(list, function(a, b) return a.id < b.id end)
	local data = encode({players = list})
	for id, entry in pairs(players) do
		if entry.counted and MP.IsPlayerConnected(id) then MP.TriggerClientEvent(id, "sc_players", data) end
	end
end

function sc_status(player_id, data)
	local entry = players[player_id]
	local msg = decodeTable(data)
	if not entry or not msg or not PLAYER_STATUS[msg.status] then return end
	if entry.status == msg.status then return end
	entry.status = msg.status
	broadcastPlayers()
end

--== Ereignisse vom Client =====================================================

-- Der Client ist bereit (Karte geladen) und will die Einstellungen.
function sc_hello(player_id, data)
	local entry = players[player_id]
	if not entry then return end
	local hello = decodeTable(data) or {}
	if hello.version and hello.version ~= VERSION then
		log(string.format("%s uses client version %s, server is %s", playerName(player_id),
			tostring(hello.version), VERSION))
		dialog(player_id, "SharedCareer: version mismatch",
			string.format("Your mod is version %s, the server runs %s. Please fully restart BeamNG " ..
				"and reconnect, otherwise errors may occur.", tostring(hello.version), VERSION), true)
	end

	-- Derselbe Account zweimal gleichzeitig würde in dasselbe Profil speichern.
	local identity = identityOf(player_id)
	if identity.account then
		for id, other in pairs(players) do
			if id ~= player_id and other.account == identity.account and MP.IsPlayerConnected(id) then
				log(playerName(player_id) .. " refused: this account is already connected as " .. playerName(id))
				MP.DropPlayer(player_id, "SharedCareer: this BeamMP account is already on the server.")
				return
			end
		end
	end
	entry.account = identity.account
	entry.guest = identity.guest
	entry.profile = profileFor(player_id, identity)

	entry.counted = true
	local settings = settingsFor(player_id)
	sharesSent[player_id] = settings.trafficShare
	send(player_id, "sc_config", settings)
	send(player_id, "sc_vehStates", vehicleStates)
	-- Bei vollem Server bekommen die anderen sofort ihren kleineren Anteil.
	updateTrafficShares()
	broadcastPlayers()
end

-- Ergebnis des Karrierestarts: {ok = true} oder {ok = false, reason = "..."}
function sc_careerResult(player_id, data)
	local entry = players[player_id]
	local result = decodeTable(data)
	if not entry or not result then return end
	if result.ok == true then
		entry.careerActive = true
		entry.startFailed = false
		local profile = type(result.profile) == "string" and result.profile:sub(1, 64) or entry.profile
		log(playerName(player_id) .. " started their career (profile " .. tostring(profile) ..
			(entry.guest and ", guest" or "") .. ")")
		if entry.guest then
			dialog(player_id, "SharedCareer: you are playing as a guest",
				"Your progress is saved under the guest name \"" .. playerName(player_id) .. "\". " ..
				"With a different guest name you start over. For a permanent save, " ..
				"log in with a BeamMP account.", false)
		else
			notify(player_id, "SharedCareer: career loaded (save " .. tostring(profile) .. ")", "check")
		end
		sendTime(player_id)
		sendFuel(player_id)
		broadcastPlayers()
	else
		entry.careerActive = false
		entry.startFailed = true
		local reason = tostring(result.reason or "unbekannt"):sub(1, 200)
		log(playerName(player_id) .. ": career start failed: " .. reason)
		if Config.server.kickOnFailedStart then
			MP.DropPlayer(player_id, "SharedCareer: career could not start")
		else
			dialog(player_id, "SharedCareer: career could not start",
				reason .. "\n\nPlease disconnect and reconnect. If that does not help, " ..
				"send the server owner your beamng.log.", true)
		end
	end
end

-- Ein eigenes Fahrzeug wurde versteckt/gezeigt: {id = "<pid>-<vid>", active = bool}
function sc_vehActive(player_id, data)
	local msg = decodeTable(data)
	if not msg or type(msg.active) ~= "boolean" or not ownsVehicle(player_id, msg.id) then return end
	local state = vehicleStates[msg.id]
	if not state then return end
	if state.active == msg.active then return end
	state.active = msg.active
	broadcastStates({[msg.id] = state}, player_id)
end

-- Welche eigenen Fahrzeuge Traffic/geparkt sind: {["<pid>-<vid>"] = bool, ...}
function sc_vehMarks(player_id, data)
	local marks = decodeTable(data)
	if not marks then return end
	local changed = {}
	for id, mark in pairs(marks) do
		local state = vehicleStates[id]
		if type(mark) == "boolean" and state and ownsVehicle(player_id, id) and state.traffic ~= mark then
			state.traffic = mark
			changed[id] = state
		end
	end
	if next(changed) then broadcastStates(changed, player_id) end
end

function sc_vehStatesRequest(player_id)
	if players[player_id] then send(player_id, "sc_vehStates", vehicleStates) end
end

-- Steuerung aus dem UI-Fenster "SharedCareer Tageszeit" (jeder Spieler, wenn erlaubt):
--   {action = "set", hour = 0..24}                               Uhrzeit für alle setzen
--   {action = "lengths", dayMinutes = 1..600, nightMinutes = 1..600}  Tag-/Nachtlänge
--   {action = "pause", paused = true|false}                       Uhr anhalten / weiterlaufen
-- Höchstens eine Änderung pro Sekunde und Spieler; alle bekommen eine Einblendung.
local TIME_CONTROL_COOLDOWN = 1
local LENGTH_MIN, LENGTH_MAX = 1, 600

local function notifyAll(msg, icon)
	for id, entry in pairs(players) do
		if entry.careerActive and MP.IsPlayerConnected(id) then notify(id, msg, icon) end
	end
end

function sc_timeControl(player_id, data)
	local entry = players[player_id]
	local msg = decodeTable(data)
	if not entry or not entry.careerActive or not msg then return end
	if Config.server.allowPlayerTimeControl ~= true then
		notify(player_id, "Only the server owner can change the time of day on this server.", "warning")
		sendTime(player_id)
		return
	end
	local t = now()
	if entry.lastTimeControl and t - entry.lastTimeControl < TIME_CONTROL_COOLDOWN then return end
	entry.lastTimeControl = t

	if msg.action == "set" then
		local hour = tonumber(msg.hour)
		if not hour or hour ~= hour or hour < 0 or hour > 24 then return end
		setHour(hour % 24)
		log(playerName(player_id) .. " sets the time to " .. formatHour(hour % 24))
		sendTimeToAll()
		notifyAll(playerName(player_id) .. " set the time to " .. formatHour(hour % 24), "schedule")
	elseif msg.action == "pause" then
		local paused = msg.paused == true
		if not setPaused(paused) then sendTime(player_id) return end
		log(playerName(player_id) .. (paused and " pauses the clock at " or " resumes the clock at ") .. formatHour(currentHour()))
		sendTimeToAll()
		notifyAll(playerName(player_id) .. (paused and " paused the clock (" or " resumed the clock (") ..
			formatHour(currentHour()) .. ")", "schedule")
	elseif msg.action == "lengths" then
		local day, night = tonumber(msg.dayMinutes), tonumber(msg.nightMinutes)
		if not day or not night or day ~= day or night ~= night then return end
		day = math.floor(math.max(LENGTH_MIN, math.min(LENGTH_MAX, day)) + 0.5)
		night = math.floor(math.max(LENGTH_MIN, math.min(LENGTH_MAX, night)) + 0.5)
		if day == Config.server.dayMinutes and night == Config.server.nightMinutes then return end
		rebaseTime() -- Uhrzeit festhalten, nur das Tempo ändert sich
		Config.server.dayMinutes, Config.server.nightMinutes = day, night
		saveConfig()
		log(string.format("%s sets day/night to %d/%d min", playerName(player_id), day, night))
		sendTimeToAll()
		notifyAll(string.format("%s: day %d min, night %d min", playerName(player_id), day, night), "schedule")
	end
end

--== Überweisungen =============================================================
-- 1. /pay im Chat -> Server prüft -> Absender bekommt sc_payDebit
-- 2. Absender-Client prüft sein Geld, bucht ab, antwortet sc_payDebitResult
-- 3. Server -> Empfänger bekommt sc_payCredit und bestätigt mit sc_payCreditAck
-- Fällt der Empfänger vorher weg, bekommt der Absender das Geld zurück.

local TRANSFER_TIMEOUT = 30

local function findPlayer(query)
	query = tostring(query or ""):lower()
	if query == "" then return nil, "No player name given." end
	local asId = tonumber(query)
	if asId and players[asId] then return asId end
	local exact, partial = nil, {}
	for id in pairs(players) do
		local name = playerName(id):lower()
		if name == query then exact = id end
		if name:sub(1, #query) == query then table.insert(partial, id) end
	end
	if exact then return exact end
	if #partial == 1 then return partial[1] end
	if #partial > 1 then return nil, "Several players match \"" .. query .. "\"." end
	return nil, "No player \"" .. query .. "\" found."
end

local function refund(transfer, why)
	transfer.stage = "refunding"
	if isConnected(transfer.from) then
		send(transfer.from, "sc_payCredit", {
			id = transfer.id, amount = transfer.amount, from = transfer.toName, refund = true,
		})
		notify(transfer.from, "Payment to " .. transfer.toName .. " refunded: " .. why, "warning")
	else
		log("Refund of $" .. transfer.amount .. " to " .. transfer.fromName .. " not possible (offline)")
		transfers[transfer.id] = nil
	end
end

local function startPayment(player_id, targetQuery, amountText)
	if not Config.server.allowPayments then
		notify(player_id, "Payments are switched off on this server.")
		return
	end
	local sender = players[player_id]
	if not sender or not sender.careerActive then
		notify(player_id, "Your career is not running yet.")
		return
	end
	local amount = tonumber(amountText)
	if not amount or amount ~= math.floor(amount) or amount < 1 or amount > Config.server.paymentMax then
		notify(player_id, "Invalid amount. Allowed: 1 to " .. Config.server.paymentMax .. " (whole dollars).")
		return
	end
	local target, err = findPlayer(targetQuery)
	if not target then
		notify(player_id, err)
		return
	end
	if target == player_id then
		notify(player_id, "You cannot send money to yourself.")
		return
	end
	if not players[target].careerActive then
		notify(player_id, playerName(target) .. " has not started their career yet.")
		return
	end
	local t = now()
	if sender.lastPaymentAt and t - sender.lastPaymentAt < Config.server.paymentCooldownSeconds then
		notify(player_id, "Please wait a moment before the next payment.")
		return
	end
	for _, transfer in pairs(transfers) do
		if transfer.from == player_id then
			notify(player_id, "Your last payment is still in progress.")
			return
		end
	end
	sender.lastPaymentAt = t
	transferSeq = transferSeq + 1
	local id = string.format("%d-%d", math.floor(t * 1000), transferSeq)
	transfers[id] = {
		id = id, from = player_id, to = target, amount = amount, stage = "debit", createdAt = t,
		fromName = playerName(player_id), toName = playerName(target),
	}
	send(player_id, "sc_payDebit", {id = id, amount = amount, to = playerName(target)})
end

function sc_payDebitResult(player_id, data)
	local msg = decodeTable(data)
	if not msg or type(msg.id) ~= "string" then return end
	local transfer = transfers[msg.id]
	if not transfer or transfer.from ~= player_id or transfer.stage ~= "debit" then return end
	if msg.ok ~= true then
		transfers[msg.id] = nil
		notify(player_id, "Payment cancelled: " .. tostring(msg.reason or "not enough money"))
		return
	end
	if not isConnected(transfer.to) then
		refund(transfer, "Recipient is offline.")
		return
	end
	transfer.stage = "credit"
	transfer.createdAt = now()
	send(transfer.to, "sc_payCredit", {id = transfer.id, amount = transfer.amount, from = transfer.fromName})
end

function sc_payCreditAck(player_id, data)
	local msg = decodeTable(data)
	if not msg or type(msg.id) ~= "string" then return end
	local transfer = transfers[msg.id]
	if not transfer then return end
	if transfer.stage == "credit" and transfer.to == player_id then
		transfers[msg.id] = nil
		log(string.format("Payment: %s -> %s $%d", transfer.fromName, transfer.toName, transfer.amount))
		notify(transfer.from, string.format("Sent $%d to %s.", transfer.amount, transfer.toName), "check")
	elseif transfer.stage == "refunding" and transfer.from == player_id then
		transfers[msg.id] = nil
	end
end

local function checkTransfers()
	local t = now()
	for id, transfer in pairs(transfers) do
		if t - transfer.createdAt > TRANSFER_TIMEOUT then
			if transfer.stage == "debit" then
				-- Absender hat nie geantwortet: es wurde nichts abgebucht (oder er ist weg).
				transfers[id] = nil
			elseif transfer.stage == "credit" then
				refund(transfer, "Recipient did not confirm.")
				transfer.createdAt = t
			else
				transfers[id] = nil
			end
		end
	end
end

--== Chat- und Konsolenbefehle =================================================
-- Chat: /pay, /players, /schelp (bzw. /help). Gibt die Funktion 1 zurück, zeigt BeamMP die
-- Nachricht nicht im Chat an. Normale Chat-Nachrichten bleiben unberührt.
-- Konsole: alles, was mit "sc" beginnt (siehe Übersicht am Dateianfang).

local CHAT_HELP = "SharedCareer: /pay <name> <amount> – send money | /players – player list | /schelp – this help"

local CONSOLE_HELP = table.concat({
	"SharedCareer %s – commands:",
	"  sc get                              show all settings",
	"  sc set <server|client>.<name> <value> change a setting (live, saved)",
	"  sc time                             show time and day/night length",
	"  sc time <HH:MM>                     set the time for everyone, e.g. sc time 18:30",
	"  sc time stop | start                pause / resume the clock",
	"  sc players                          players and career status",
	"  sc fuel | sc fuel reset             show fuel discounts / reset all to normal",
	"  sc reload                           reload config.json",
	"  examples: sc set client.trafficAggression 0.15 | sc set server.nightMinutes 5",
	"            sc set client.saveSuffix   (no value = empty)",
}, "\n")

function onChatMessage(player_id, name, message)
	if type(message) ~= "string" then return end
	local cmd, rest = message:match("^%s*/(%S+)%s*(.-)%s*$")
	if not cmd then return end
	cmd = cmd:lower()
	if cmd == "pay" then
		local target, amount = rest:match("^(.-)%s+(%S+)$")
		if not target then
			chat(player_id, "Usage: /pay <name> <amount>")
		else
			startPayment(player_id, target, amount)
		end
		return 1
	elseif cmd == "players" then
		local parts = {}
		for id in pairs(players) do
			local entry = players[id]
			table.insert(parts, playerName(id) .. (entry.careerActive and "" or " (loading)"))
		end
		chat(player_id, "Players: " .. table.concat(parts, ", "))
		return 1
	elseif cmd == "schelp" or cmd == "help" then
		chat(player_id, CHAT_HELP)
		return 1
	end
end

-- "sc set": Wert prüfen (Typ wie der Standardwert), speichern und wirksam machen.
-- client.*: sofort an alle Spieler (sc_configUpdate). Ausnahme: saveSuffix gilt erst beim
-- nächsten Join, weil das Profil beim Karrierestart gewählt wird.
local function setSetting(path, valueText)
	local section, key = tostring(path):match("^(%a+)%.(%w+)$")
	if not section or not Config[section] or Config[section][key] == nil then
		return "Unknown setting: " .. tostring(path)
	end
	local old = Config[section][key]
	local value
	if type(old) == "boolean" then
		if valueText == "true" then value = true elseif valueText == "false" then value = false end
	elseif type(old) == "number" then
		value = tonumber(valueText)
	else
		value = valueText or ""
	end
	if value == nil then return "Invalid value for " .. path .. " (expected " .. type(old) .. ")" end
	if section == "server" and TIME_KEYS[key] then rebaseTime() end
	Config[section][key] = value
	saveConfig()
	if section == "server" and key:sub(1, 4) == "fuel" then sendFuelToAll() end
	-- Live-Update für alle, die schon spielen (enthält auch die neuen Traffic-Anteile).
	-- Startoptionen wie saveSuffix wirken erst beim nächsten Join.
	sendSettingsToAll()
	return path .. " = " .. tostring(value)
end

--== Einstellungen aus dem SharedCareer-Menü =====================================
-- Nur diese Einstellungen darf ein Spieler im Menü ändern (wenn server.allowPlayerSettings);
-- jede gilt sofort für alle. Werte werden geprüft und begrenzt.
local MENU_SETTINGS = {
	["client.roadTraffic"]         = {kind = "int",  min = 0, max = 50, label = "Driving traffic per player"},
	["client.parkedTraffic"]       = {kind = "int",  min = 0, max = 50, label = "Parked cars per player"},
	["client.trafficAggression"]   = {kind = "num",  min = 0.05, max = 1, label = "AI driving style"},
	["client.remoteVehicleGhost"]  = {kind = "bool", label = "Other players' cars without collision (AI traffic always collides)"},
	["client.remoteUnicycleGhost"] = {kind = "bool", label = "Players on foot without collision"},
	["server.trafficSignalSync"]   = {kind = "bool", label = "Synced traffic lights"},
	["server.roadTrafficTotal"]    = {kind = "int",  min = 0, max = 400, label = "Server limit driving traffic"},
	["server.parkedTrafficTotal"]  = {kind = "int",  min = 0, max = 400, label = "Server limit parked cars"},
	["client.showPlayerStatus"]    = {kind = "bool", label = "Player status on name tags"},
}
local MENU_COOLDOWN = 0.5

local function onOff(v) return v and "on" or "off" end

function sc_setSetting(player_id, data)
	local entry = players[player_id]
	local msg = decodeTable(data)
	if not entry or not entry.careerActive or not msg or type(msg.key) ~= "string" then return end
	local def = MENU_SETTINGS[msg.key]
	if not def then return end
	if Config.server.allowPlayerSettings ~= true then
		notify(player_id, "Only the server owner can change settings on this server.", "warning")
		return
	end
	local t = now()
	if entry.lastSetting and t - entry.lastSetting < MENU_COOLDOWN then return end
	entry.lastSetting = t

	local value = msg.value
	if def.kind == "bool" then
		if type(value) ~= "boolean" then return end
	else
		value = tonumber(value)
		if not value or value ~= value then return end
		value = math.max(def.min, math.min(def.max, value))
		if def.kind == "int" then value = math.floor(value + 0.5) else value = math.floor(value * 100 + 0.5) / 100 end
	end
	local section, key = msg.key:match("^(%a+)%.(%w+)$")
	if Config[section][key] == value then return end
	setSetting(msg.key, tostring(value))
	local shown = def.kind == "bool" and onOff(value) or tostring(value)
	log(string.format("%s: %s = %s", playerName(player_id), msg.key, shown))
	for id, e in pairs(players) do
		if e.careerActive and MP.IsPlayerConnected(id) then
			notify(id, string.format("%s: %s → %s", playerName(player_id), def.label, shown), "settings")
		end
	end
end

function onConsoleInput(input)
	local words = {}
	for word in tostring(input):gmatch("%S+") do table.insert(words, word) end
	if not words[1] or words[1]:lower() ~= "sc" then return end
	local sub = (words[2] or "help"):lower()
	if sub == "set" then
		return setSetting(words[3], words[4])
	elseif sub == "get" then
		local lines = {}
		for _, section in ipairs({"server", "client"}) do
			local keys = {}
			for key in pairs(Config[section]) do table.insert(keys, key) end
			table.sort(keys)
			for _, key in ipairs(keys) do
				table.insert(lines, section .. "." .. key .. " = " .. tostring(Config[section][key]))
			end
		end
		return table.concat(lines, "\n")
	elseif sub == "time" then
		local arg = words[3] and words[3]:lower()
		if arg == "stop" or arg == "start" then
			setPaused(arg == "stop")
			sendTimeToAll()
			return arg == "stop" and ("Clock paused at " .. formatHour(currentHour()))
				or ("Clock running again from " .. formatHour(currentHour()))
		end
		if words[3] then
			local hour = tonumber((words[3]:gsub(",", ".")))
			local hh, mm = words[3]:match("^(%d+):(%d+)$")
			if hh then hour = tonumber(hh) + tonumber(mm) / 60 end
			if not hour or hour < 0 or hour >= 24 then return "Time must be 0 to 23.99 or HH:MM, e.g. sc time 18:30" end
			setHour(hour)
			sendTimeToAll()
			return "Time for everyone: " .. formatHour(hour)
		end
		local ph = timePhases()
		if Config.server.timePaused == true then return "Time: " .. formatHour(currentHour()) .. " (paused – sc time start)" end
		if not ph then return "Time: " .. formatHour(currentHour()) .. " (stopped)" end
		return string.format("Time: %s (day %s–%s: %s min, night: %s min)", formatHour(currentHour()),
			formatHour(ph.dayStart), formatHour(ph.nightStart), tostring(Config.server.dayMinutes),
			tostring(Config.server.nightMinutes))
	elseif sub == "fuel" then
		if words[3] and words[3]:lower() == "reset" then
			fuelDiscounts = {}
			saveFuel()
			sendFuelToAll()
			return "Fuel prices reset to normal at all stations"
		end
		local lines = {}
		for station, fuels in pairs(fuelDiscounts) do
			for fuel, d in pairs(fuels) do table.insert(lines, string.format("  %s %s: -%.1f%%", station, fuel, d)) end
		end
		table.sort(lines)
		if #lines == 0 then return "Fuel prices: normal everywhere" .. (Config.server.fuelEconomy and "" or " (fuel economy off)") end
		return "Fuel discounts:\n" .. table.concat(lines, "\n")
	elseif sub == "reload" then
		loadConfig()
		return "Configuration reloaded"
	elseif sub == "players" then
		local lines = {}
		for id, entry in pairs(players) do
			table.insert(lines, string.format("%d %s career=%s", id, playerName(id), tostring(entry.careerActive)))
		end
		return #lines > 0 and table.concat(lines, "\n") or "No players"
	end
	return string.format(CONSOLE_HELP, VERSION)
end

--== BeamMP-Ereignisse =========================================================
-- Von BeamMP selbst ausgelöst (Join, Verlassen, Fahrzeuge).

-- Verbindung steht; die Karriere startet erst nach sc_hello / sc_careerResult.
function onPlayerJoin(player_id)
	players[player_id] = {name = MP.GetPlayerName(player_id), careerActive = false}
end

-- Aufräumen: Fahrzeugzustände, offene Überweisungen (ggf. Rückbuchung), Traffic-Anteile.
function onPlayerDisconnect(player_id)
	local prefix = tostring(player_id) .. "-"
	for id in pairs(vehicleStates) do
		if id:sub(1, #prefix) == prefix then vehicleStates[id] = nil end
	end
	for id, transfer in pairs(transfers) do
		if transfer.to == player_id and transfer.stage == "credit" then
			refund(transfer, transfer.toName .. " left the server.")
		elseif transfer.from == player_id then
			-- Absender weg: in Stufe "debit" wurde noch nichts gutgeschrieben -> verwerfen.
			-- In Stufe "credit" läuft die Gutschrift normal weiter.
			if transfer.stage ~= "credit" then transfers[id] = nil end
		end
	end
	players[player_id] = nil
	sharesSent[player_id] = nil
	updateTrafficShares()
	broadcastPlayers()
end

-- Neues Fahrzeug: sichtbar; der Besitzer meldet danach, ob es Traffic ist.
function onVehicleSpawn(player_id, vehicle_id, data)
	local id = player_id .. "-" .. vehicle_id
	vehicleStates[id] = {active = true}
	broadcastStates({[id] = vehicleStates[id]})
end

-- Ein neu gebautes Auto ist wieder aktiv, bei allen.
function onVehicleEdited(player_id, vehicle_id, data)
	local id = player_id .. "-" .. vehicle_id
	local state = vehicleStates[id] or {}
	state.active = true
	vehicleStates[id] = state
	broadcastStates({[id] = state})
end

function onVehicleDeleted(player_id, vehicle_id)
	vehicleStates[player_id .. "-" .. vehicle_id] = nil
end

--== Timer =====================================================================
-- sc_signalTick alle 10 s (Ampeln), sc_timeTick alle 30 s (Tageszeit),
-- sc_tick jede Sekunde (Zeitlimits für Überweisungen).

function sc_signalTick()
	if not Config.server.trafficSignalSync then return end
	local data = tostring(now())
	for id, entry in pairs(players) do
		if entry.careerActive and MP.IsPlayerConnected(id) then
			MP.TriggerClientEvent(id, "sc_signals", data)
		end
	end
end

-- Tageszeit-Abgleich alle 30 s; dazwischen läuft der Tag bei jedem Spieler selbst weiter.
function sc_timeTick()
	if Config.client.syncTimeOfDay ~= true then return end
	local data = encode(timePayload())
	for id, entry in pairs(players) do
		if entry.careerActive and MP.IsPlayerConnected(id) then
			MP.TriggerClientEvent(id, "sc_time", data)
		end
	end
end

function sc_tick()
	checkTransfers()
	fuelRecoveryTick(1)
end

function onInit()
	loadConfig()
	loadProfiles()
	loadFuel()

	MP.RegisterEvent("onPlayerJoin", "onPlayerJoin")
	MP.RegisterEvent("onPlayerDisconnect", "onPlayerDisconnect")
	MP.RegisterEvent("onVehicleSpawn", "onVehicleSpawn")
	MP.RegisterEvent("onVehicleEdited", "onVehicleEdited")
	MP.RegisterEvent("onVehicleDeleted", "onVehicleDeleted")
	MP.RegisterEvent("onChatMessage", "onChatMessage")
	MP.RegisterEvent("onConsoleInput", "onConsoleInput")

	MP.RegisterEvent("sc_hello", "sc_hello")
	MP.RegisterEvent("sc_careerResult", "sc_careerResult")
	MP.RegisterEvent("sc_vehActive", "sc_vehActive")
	MP.RegisterEvent("sc_vehMarks", "sc_vehMarks")
	MP.RegisterEvent("sc_vehStatesRequest", "sc_vehStatesRequest")
	MP.RegisterEvent("sc_timeControl", "sc_timeControl")
	MP.RegisterEvent("sc_setSetting", "sc_setSetting")
	MP.RegisterEvent("sc_status", "sc_status")
	MP.RegisterEvent("sc_fuelDelivered", "sc_fuelDelivered")
	MP.RegisterEvent("sc_payDebitResult", "sc_payDebitResult")
	MP.RegisterEvent("sc_payCreditAck", "sc_payCreditAck")

	MP.RegisterEvent("sc_signalTick", "sc_signalTick")
	MP.RegisterEvent("sc_tick", "sc_tick")
	MP.RegisterEvent("sc_timeTick", "sc_timeTick")
	MP.CreateEventTimer("sc_signalTick", 10000)
	MP.CreateEventTimer("sc_tick", 1000)
	MP.CreateEventTimer("sc_timeTick", 30000)

	log("Version " .. VERSION .. " loaded. Console: sc help")
end
