-- Server-Simulation: BeamMP-API nachgebaut, main.lua geladen, Abläufe durchgespielt.
-- Ausführen (Lua 5.3/5.4 wie der BeamMP-Server):  lua5.3 tests/server_test.lua

package.path = "./tests/?.lua;" .. package.path
local json = require("json")
-- Version aus dem Code lesen (nur util.lua/main.lua pflegen, siehe tools/bump.sh)
local VERSION = io.open("Resources/Server/SharedCareer/main.lua"):read("*a"):match('local VERSION = "(.-)"')

local tmp = os.tmpname()
os.remove(tmp)
local tmpProfiles = os.tmpname()
os.remove(tmpProfiles)
local tmpFuel = os.tmpname()
os.remove(tmpFuel)

local sent = {}       -- {to, event, data}
local chats = {}      -- {to, msg}
local dropped = {}
local connected = {}
local names = {}
local fakeTime = 100
local accounts = {}   -- player id -> BeamMP-Account-ID (nil = keiner)
local guests = {}     -- player id -> true
local dialogs = {}    -- {to, title, body, warning}

MP = {
	CreateTimer = function() return {GetCurrent = function() return fakeTime end} end,
	TriggerClientEvent = function(to, event, data) table.insert(sent, {to = to, event = event, data = data}) end,
	SendChatMessage = function(to, msg) table.insert(chats, {to = to, msg = msg}) end,
	IsPlayerConnected = function(id) return connected[id] == true end,
	GetPlayerName = function(id) return names[id] end,
	DropPlayer = function(id, why) table.insert(dropped, id) end,
	RegisterEvent = function() end,
	CreateEventTimer = function() end,
	GetPlayerIdentifiers = function(id)
		local t = {ip = "127.0.0.1"}
		if accounts[id] then t.beammp = tostring(accounts[id]) end
		return t
	end,
	IsPlayerGuest = function(id) return guests[id] == true end,
	-- Benachrichtigungen landen in derselben Liste wie Chat (für lastChat)
	SendNotification = function(to, msg, icon) table.insert(chats, {to = to, msg = msg, kind = "notify"}) end,
	ConfirmationDialog = function(to, title, body, buttons, interaction, warning)
		assert(type(buttons) == "table" and buttons[1].label, "Dialog braucht Knöpfe")
		table.insert(dialogs, {to = to, title = title, body = body, warning = warning})
		table.insert(chats, {to = to, msg = title .. ": " .. body, kind = "dialog"})
		return true, ""
	end,
}
Util = {JsonEncode = json.encode, JsonDecode = json.decode}
FS = {Exists = function() return true end, CreateDirectory = function() end}

-- Konfigurationspfad auf eine Temp-Datei umbiegen
local source = assert(io.open("Resources/Server/SharedCareer/main.lua")):read("*a")
source = source:gsub('local CONFIG_FILE = CONFIG_DIR %.%. "/config%.json"', 'local CONFIG_FILE = "' .. tmp .. '"')
source = source:gsub('local PROFILES_FILE = CONFIG_DIR %.%. "/profiles%.json"', 'local PROFILES_FILE = "' .. tmpProfiles .. '"')
source = source:gsub('local FUEL_FILE = CONFIG_DIR %.%. "/fuelprices%.json"', 'local FUEL_FILE = "' .. tmpFuel .. '"')
assert(load(source, "main.lua"))()
onInit()

local failures, passed = 0, 0
local function check(cond, msg)
	if cond then passed = passed + 1 else failures = failures + 1; print("FEHLER: " .. msg) end
end

local function lastTo(id, event)
	for i = #sent, 1, -1 do
		if sent[i].to == id and sent[i].event == event then return json.decode(sent[i].data) end
	end
end
local function countTo(id, event)
	local n = 0
	for _, s in ipairs(sent) do if s.to == id and s.event == event then n = n + 1 end end
	return n
end
local function lastChat(id)
	for i = #chats, 1, -1 do if chats[i].to == id then return chats[i].msg end end
end

-- Dialoge gehen als sc_dialog an das Menü-Fenster des Spielers (nicht über BeamMPs Dialog)
local function lastDialog(id)
	return lastTo(id, "sc_dialog")
end

local function join(id, name, account)
	connected[id] = true
	names[id] = name
	accounts[id] = account == nil and (1000 + id) or (account ~= false and account or nil)
	onPlayerJoin(id)
	sc_hello(id, json.encode({version = VERSION}))
	sc_careerResult(id, json.encode({ok = true}))
end

--== Join und Einstellungen ==
join(0, "Anna")
local cfg = lastTo(0, "sc_config")
check(cfg and cfg.trafficShare and cfg.trafficShare.road == 6, "erster Spieler bekommt 6 fahrende Autos")
check(cfg.parkedTraffic == 8 and cfg.allowConsole == false, "Client-Einstellungen kommen an")
check(cfg.trafficSimpleVehicles == true and cfg.simplifyRemoteVehicles == false, "simple-vehicle-Standardwerte")
check(cfg.trafficAggression == 0.2, "KI-Aggressivität wird geschickt")

--== Traffic-Aufteilung: 4 Spieler * 6 = 24 > 20 -> 5 pro Spieler ==
join(1, "Ben"); join(2, "Cem"); join(3, "Dana")
check(lastTo(3, "sc_config").trafficShare.road == 5, "4. Spieler bekommt 5 (20/4)")
check(lastTo(0, "sc_traffic") and lastTo(0, "sc_traffic").road == 5, "bestehende Spieler bekommen kleineren Anteil")
check(lastTo(0, "sc_traffic").parked == 6, "geparkt: 24/4 = 6")

--== Fahrzeugzustände ==
onVehicleSpawn(0, 0, "")
check(lastTo(1, "sc_vehStates")["0-0"].active == true, "Spawn wird verteilt")
sc_vehActive(0, json.encode({id = "0-0", active = false}))
check(lastTo(1, "sc_vehStates")["0-0"].active == false, "Verstecken wird verteilt")
local before = countTo(2, "sc_vehStates")
sc_vehActive(1, json.encode({id = "0-0", active = true}))
check(countTo(2, "sc_vehStates") == before, "fremdes Fahrzeug darf nicht geändert werden")
sc_vehMarks(0, json.encode({["0-0"] = true, ["1-5"] = true}))
local marks = lastTo(2, "sc_vehStates")
check(marks["0-0"].traffic == true and marks["1-5"] == nil, "Traffic-Markierung nur für eigene")
sc_vehActive(0, "kaputt{")
check(true, "kaputtes JSON wird ignoriert")

--== Überweisung: Erfolg ==
check(onChatMessage(0, "Anna", "/pay Ben 500") == 1, "/pay wird aus dem Chat gefiltert")
local debit = lastTo(0, "sc_payDebit")
check(debit and debit.amount == 500 and debit.to == "Ben", "Absender soll abbuchen")
sc_payDebitResult(0, json.encode({id = debit.id, ok = true}))
local credit = lastTo(1, "sc_payCredit")
check(credit and credit.amount == 500 and credit.from == "Anna", "Empfänger bekommt Gutschrift")
sc_payCreditAck(1, json.encode({id = credit.id}))
check(lastChat(0):find("500") ~= nil, "Absender bekommt Bestätigung")

--== Überweisung: fremder Client kann nicht für jemand anderen bestätigen ==
fakeTime = fakeTime + 10
onChatMessage(0, "Anna", "/pay ben 100")
local d2 = lastTo(0, "sc_payDebit")
local creditsBefore = countTo(1, "sc_payCredit")
sc_payDebitResult(1, json.encode({id = d2.id, ok = true}))
check(countTo(1, "sc_payCredit") == creditsBefore, "nur der Absender darf die Abbuchung melden")
sc_payDebitResult(0, json.encode({id = d2.id, ok = false, reason = "not enough money"}))
check(lastChat(0):find("not enough money") ~= nil, "abgelehnte Abbuchung wird gemeldet")

--== Ungültige Eingaben ==
fakeTime = fakeTime + 10
onChatMessage(0, "Anna", "/pay Ben -5"); check(lastChat(0):find("Invalid amount") ~= nil, "negativer Betrag")
onChatMessage(0, "Anna", "/pay Ben 1.5"); check(lastChat(0):find("Invalid amount") ~= nil, "Kommabetrag")
onChatMessage(0, "Anna", "/pay Anna 5"); check(lastChat(0):find("yourself") ~= nil, "an sich selbst")
onChatMessage(0, "Anna", "/pay Zoe 5"); check(lastChat(0):find("No player") ~= nil, "unbekannter Spieler")
check(onChatMessage(0, "Anna", "hallo") == nil, "normaler Chat bleibt")

--== Cooldown ==
fakeTime = fakeTime + 10
onChatMessage(0, "Anna", "/pay Ben 1")
local d3 = lastTo(0, "sc_payDebit")
sc_payDebitResult(0, json.encode({id = d3.id, ok = true}))
sc_payCreditAck(1, json.encode({id = lastTo(1, "sc_payCredit").id}))
local debits = countTo(0, "sc_payDebit")
onChatMessage(0, "Anna", "/pay Ben 1")
check(countTo(0, "sc_payDebit") == debits, "Cooldown verhindert Spam")

--== Empfänger geht während Gutschrift -> Rückbuchung ==
fakeTime = fakeTime + 10
onChatMessage(0, "Anna", "/pay Cem 300")
local d4 = lastTo(0, "sc_payDebit")
sc_payDebitResult(0, json.encode({id = d4.id, ok = true}))
connected[2] = false
onPlayerDisconnect(2)
local refund = lastTo(0, "sc_payCredit")
check(refund and refund.refund == true and refund.amount == 300, "Rückbuchung wenn Empfänger geht")

--== Gutschrift ohne Bestätigung -> Rückbuchung nach Timeout ==
fakeTime = fakeTime + 10
onChatMessage(0, "Anna", "/pay Dana 50")
local d5 = lastTo(0, "sc_payDebit")
sc_payDebitResult(0, json.encode({id = d5.id, ok = true}))
fakeTime = fakeTime + 31
sc_tick()
local r2 = lastTo(0, "sc_payCredit")
check(r2 and r2.id == d5.id and r2.refund == true, "Rückbuchung nach Timeout")
sc_payCreditAck(0, json.encode({id = d5.id}))

--== Traffic wächst wieder, wenn Spieler gehen ==
check(lastTo(0, "sc_traffic").road == 6, "nach Leave: 3 Spieler * 6 = 18 <= 20")

--== Fahrzeuge eines Spielers verschwinden mit ihm ==
onVehicleSpawn(3, 1, "")
connected[3] = false
onPlayerDisconnect(3)
sc_vehStatesRequest(0)
check(lastTo(0, "sc_vehStates")["3-1"] == nil, "Fahrzeuge von gegangenen Spielern entfernt")

--== Konsole ==
check(onConsoleInput("sc set client.roadTraffic 3"):find("= 3") ~= nil, "Einstellung setzen")
check(lastTo(0, "sc_configUpdate").roadTraffic == 3, "Live-Update an Spieler")
check(onConsoleInput("sc set client.gibtsnicht 1"):find("Unknown setting") ~= nil, "unbekannte Einstellung")
check(onConsoleInput("sc set server.allowPayments vielleicht"):find("Invalid value") ~= nil, "falscher Typ")
check(onConsoleInput("hallo") == nil, "fremde Konsolenbefehle bleiben unberührt")

--== Fehlgeschlagener Start ==
connected[5] = true; names[5] = "Eve"; onPlayerJoin(5)
sc_careerResult(5, json.encode({ok = false, reason = "test"}))
check(#dropped == 0 and lastChat(5):find("test") ~= nil, "Fehlstart: Hinweis statt Kick (Standard)")

--== Spielstand pro Account ==
check(lastTo(0, "sc_config").profileBase == "anna" and lastTo(0, "sc_config").isGuest == false,
	"Profil aus dem Namen beim ersten Join")
local pf = json.decode(assert(io.open(tmpProfiles)):read("*a"))
check(pf["1000"] == "anna", "Zuordnung Account -> Profil gespeichert")
-- Anna benennt sich um und kommt wieder: gleicher Account -> gleiches Profil
connected[0] = false; onPlayerDisconnect(0)
join(0, "Anna_Neu", 1000)
check(lastTo(0, "sc_config").profileBase == "anna", "Umbenennen behält den Spielstand")
check(lastChat(0):find("save anna") ~= nil, "Bestätigung als Einblendung")
-- Derselbe Account ein zweites Mal gleichzeitig
connected[7] = true; names[7] = "AnnaZwei"; accounts[7] = 1000; onPlayerJoin(7)
local before7 = countTo(7, "sc_config")
sc_hello(7, json.encode({version = VERSION}))
check(dropped[#dropped] == 7 and countTo(7, "sc_config") == before7, "gleicher Account doppelt wird abgelehnt")
connected[7] = false; onPlayerDisconnect(7)
-- Gast
guests[8] = true
join(8, "guest4711", false)
check(lastTo(8, "sc_config").isGuest == true and lastTo(8, "sc_config").profileBase == "guest4711", "Gast-Profil nach Gastname")
check(lastDialog(8) and lastDialog(8).title:find("guest"), "Gast bekommt Hinweis-Dialog")
connected[8] = false; onPlayerDisconnect(8)
-- Version passt nicht
connected[9] = true; names[9] = "Alt"; accounts[9] = 1009; onPlayerJoin(9)
sc_hello(9, json.encode({version = "0.0.9"}))
check(lastDialog(9) and lastDialog(9).warning == true and lastDialog(9).body:find("0.0.9"), "Versions-Warnung als Dialog")
connected[9] = false; onPlayerDisconnect(9)
check(#dialogs == 0, "BeamMPs ConfirmationDialog wird nicht benutzt (führte in 0.40 ins Hauptmenü)")
-- Ältere Server ohne Benachrichtigungen: Chat als Ersatz
local savedNotify, savedDialog = MP.SendNotification, MP.ConfirmationDialog
MP.SendNotification, MP.ConfirmationDialog = nil, nil
local chatsBefore = #chats
connected[10] = true; names[10] = "Fallback"; accounts[10] = 1010; onPlayerJoin(10)
sc_hello(10, json.encode({version = VERSION}))
sc_careerResult(10, json.encode({ok = false, reason = "kaputt"}))
check(#chats > chatsBefore and chats[#chats].kind == nil and chats[#chats].msg:find("kaputt"), "ohne Dialog-API kommt Chat")
MP.SendNotification, MP.ConfirmationDialog = savedNotify, savedDialog
connected[10] = false; onPlayerDisconnect(10)

--== Tageszeit (Tag und Nacht verschieden schnell) ==
-- Standard: Tag 6–20 Uhr (14 Std) in 50 min, Nacht 20–6 Uhr (10 Std) in 5 min
local daySpeed, nightSpeed = 14 / 3000, 10 / 300
local t0 = lastTo(0, "sc_time")
check(t0 and t0.play == true, "Uhrzeit nach Karrierestart geschickt")
check(math.abs(t0.dayLengthDay - 24 / daySpeed) < 0.01 and math.abs(t0.dayLengthNight - 24 / nightSpeed) < 0.01,
	"Tages- und Nachttempo werden mitgeschickt")
check(t0.dayLength == t0.dayLengthDay and t0.dayStart == 6 and t0.nightStart == 20, "10 Uhr = Tagestempo")
check(onConsoleInput("sc time 18:30"):find("18:30") ~= nil, "sc time setzt die Uhrzeit")
check(math.abs(lastTo(0, "sc_time").hour - 18.5) < 0.001, "neue Uhrzeit sofort an alle")
-- 1350 s: 1,5 Std Tag bis 20 Uhr, dann die ganze Nacht (300 s), dann wieder Tag
fakeTime = fakeTime + 1350
sc_timeTick()
local expected = 6 + (1350 - 1.5 / daySpeed - 300) * daySpeed
check(math.abs(lastTo(0, "sc_time").hour - expected) < 0.001,
	string.format("Uhr rechnet über Tag/Nacht-Grenzen (%.3f statt %.3f)", lastTo(0, "sc_time").hour, expected))
onConsoleInput("sc time 22:00")
check(lastTo(0, "sc_time").dayLength == lastTo(0, "sc_time").dayLengthNight, "nachts gilt das Nachttempo")
fakeTime = fakeTime + 150 -- halbe Nacht = 5 Std
sc_timeTick()
check(math.abs(lastTo(0, "sc_time").hour - 3) < 0.001, "Nacht läuft schneller: 22 Uhr + 2,5 min = 3 Uhr")
check(onConsoleInput("sc time"):find("night: 5 min") ~= nil, "sc time zeigt Tag/Nacht-Dauer")
onConsoleInput("sc set server.nightMinutes 0")
sc_timeTick()
local frozen = lastTo(0, "sc_time")
check(math.abs(frozen.hour - 3) < 0.001 and frozen.play == false, "Tempo ändern: kein Sprung, 0 = steht still")
fakeTime = fakeTime + 500
check(onConsoleInput("sc time"):find("03:00") ~= nil, "stehende Uhr bleibt stehen")
onConsoleInput("sc set server.nightMinutes 5")
check(onConsoleInput("sc time 25"):find("Time must be 0 to") ~= nil, "ungültige Uhrzeit abgelehnt")
onConsoleInput("sc set client.syncTimeOfDay false")
local beforeTick = countTo(0, "sc_time")
sc_timeTick()
check(countTo(0, "sc_time") == beforeTick, "abgeschaltet: keine Uhrzeit-Nachrichten")
onConsoleInput("sc set client.syncTimeOfDay true")

--== Tageszeit aus dem UI-Fenster (jeder Spieler) ==
sc_timeTick()
local tp = lastTo(0, "sc_time")
check(tp.dayMinutes == 50 and tp.nightMinutes == 5 and tp.canControl == true, "Fenster bekommt Längen und Steuer-Erlaubnis")
fakeTime = fakeTime + 5
sc_timeControl(1, json.encode({action = "set", hour = 7.5}))
check(math.abs(lastTo(0, "sc_time").hour - 7.5) < 0.001, "Spieler stellt Uhrzeit -> gilt für alle")
check(lastChat(0):find("Ben set the time to 07:30") ~= nil, "alle sehen, wer verstellt hat")
local sentBefore = countTo(0, "sc_time")
sc_timeControl(1, json.encode({action = "set", hour = 9}))
check(countTo(0, "sc_time") == sentBefore, "höchstens eine Änderung pro Sekunde")
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({action = "lengths", dayMinutes = 40, nightMinutes = 10}))
local tl = lastTo(0, "sc_time")
check(tl.dayMinutes == 40 and tl.nightMinutes == 10 and math.abs(tl.hour - 7.5) < 0.01, "Längen geändert, Uhrzeit springt nicht")
check(onConsoleInput("sc get"):find("server.dayMinutes = 40") ~= nil, "Längen werden gespeichert")
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({action = "lengths", dayMinutes = 99999, nightMinutes = -3}))
check(lastTo(0, "sc_time").dayMinutes == 600 and lastTo(0, "sc_time").nightMinutes == 1, "Längen werden begrenzt (1–600 min)")
fakeTime = fakeTime + 2
sentBefore = countTo(0, "sc_time")
sc_timeControl(1, json.encode({action = "set", hour = "abc"}))
sc_timeControl(1, "kaputt")
check(countTo(0, "sc_time") == sentBefore, "ungültige Eingaben ändern nichts")
onConsoleInput("sc set server.allowPlayerTimeControl false")
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({action = "set", hour = 3}))
check(math.abs(lastTo(0, "sc_time").hour - 3) > 0.5 and lastChat(1):find("Only the server owner") ~= nil, "abgeschaltet: nur noch per Konsole")
check(lastTo(1, "sc_time").canControl == false, "Fenster erfährt, dass Steuern aus ist")
onConsoleInput("sc set server.allowPlayerTimeControl true")
onConsoleInput("sc set server.dayMinutes 50")
onConsoleInput("sc set server.nightMinutes 5")

--== Uhr anhalten / weiterlaufen ==
fakeTime = fakeTime + 5
sc_timeControl(1, json.encode({action = "set", hour = 12}))
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({action = "pause", paused = true}))
local tpz = lastTo(0, "sc_time")
check(tpz.paused == true and tpz.play == false and math.abs(tpz.hour - 12) < 0.05, "Stopp: Uhr steht bei der aktuellen Uhrzeit")
check(lastChat(0):find("paused the clock") ~= nil, "alle sehen, wer angehalten hat")
fakeTime = fakeTime + 600
sc_timeTick()
check(math.abs(lastTo(0, "sc_time").hour - tpz.hour) < 0.001, "angehalten: 10 min später gleiche Uhrzeit")
check(onConsoleInput("sc get"):find("server.timePaused = true") ~= nil, "Stopp wird gespeichert")
check(onConsoleInput("sc time"):find("paused") ~= nil, "sc time zeigt angehalten")
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({action = "pause", paused = false}))
local resumed = lastTo(0, "sc_time")
check(resumed.paused == false and resumed.play == true and math.abs(resumed.hour - tpz.hour) < 0.001, "Weiter: läuft ab derselben Uhrzeit")
fakeTime = fakeTime + 300
sc_timeTick()
check(lastTo(0, "sc_time").hour > tpz.hour + 0.1, "danach läuft die Uhr wieder")
check(onConsoleInput("sc time stop"):find("paused") ~= nil and lastTo(0, "sc_time").paused == true, "sc time stop")
check(onConsoleInput("sc time start"):find("running again") ~= nil and lastTo(0, "sc_time").paused == false, "sc time start")

--== Einstellungen aus dem SharedCareer-Menü ==
fakeTime = fakeTime + 5
local updatesBefore = countTo(0, "sc_configUpdate")
sc_setSetting(1, json.encode({key = "client.roadTraffic", value = 9}))
local cu = lastTo(0, "sc_configUpdate")
check(countTo(0, "sc_configUpdate") == updatesBefore + 1 and cu.roadTraffic == 9, "Menü: fahrende Autos -> gilt für alle")
check(type(cu.ui) == "table" and cu.ui.allowPlayerSettings == true and cu.ui.roadTrafficTotal ~= nil, "Menü bekommt Server-Werte (ui)")
check(lastChat(0):find("Driving traffic per player") ~= nil, "alle sehen, wer was geändert hat")
updatesBefore = countTo(0, "sc_configUpdate")
sc_setSetting(1, json.encode({key = "client.parkedTraffic", value = 3}))
check(countTo(0, "sc_configUpdate") == updatesBefore, "Sperre 0,5 s gegen Klick-Spam")
fakeTime = fakeTime + 1
sc_setSetting(1, json.encode({key = "client.roadTraffic", value = 500}))
check(lastTo(0, "sc_configUpdate").roadTraffic == 50, "Werte werden begrenzt (max 50)")
fakeTime = fakeTime + 1
sc_setSetting(1, json.encode({key = "client.remoteVehicleGhost", value = true}))
check(lastTo(0, "sc_configUpdate").remoteVehicleGhost == true, "Schalter (Kollision aus)")
fakeTime = fakeTime + 1
sc_setSetting(1, json.encode({key = "client.remoteVehicleGhost", value = "ja"}))
sc_setSetting(1, json.encode({key = "client.saveSuffix", value = "_hack"}))
sc_setSetting(1, json.encode({key = "server.allowPlayerSettings", value = false}))
check(onConsoleInput("sc get"):find("_hack") == nil, "nicht freigegebene Einstellungen sind tabu")
check(onConsoleInput("sc get"):find("server.allowPlayerSettings = true") ~= nil, "Menü kann sich nicht selbst freischalten")
fakeTime = fakeTime + 1
sc_setSetting(1, json.encode({key = "server.roadTrafficTotal", value = 8}))
local cu2 = lastTo(0, "sc_configUpdate")
check(cu2.ui.roadTrafficTotal == 8 and cu2.trafficShare.road < 9, "Server-Limit: Anteile werden neu verteilt")
onConsoleInput("sc set server.allowPlayerSettings false")
fakeTime = fakeTime + 1
updatesBefore = countTo(0, "sc_configUpdate")
sc_setSetting(1, json.encode({key = "client.roadTraffic", value = 2}))
check(countTo(0, "sc_configUpdate") == updatesBefore and lastChat(1):find("Only the server owner") ~= nil, "abgeschaltet: Menü ändert nichts")
onConsoleInput("sc set server.allowPlayerSettings true")
onConsoleInput("sc set client.roadTraffic 3")
onConsoleInput("sc set client.remoteVehicleGhost false")
onConsoleInput("sc set server.roadTrafficTotal 20")

--== Spielerliste und Status ==
local pl = lastTo(0, "sc_players")
check(pl and #pl.players >= 2 and pl.players[1].name == "Anna_Neu", "Spielerliste an alle (sortiert)")
sc_status(1, json.encode({status = "mission"}))
local benEntry
for _, p in ipairs(lastTo(0, "sc_players").players) do if p.name == "Ben" then benEntry = p end end
check(benEntry and benEntry.status == "mission", "Status wird an alle verteilt")
local plCount = countTo(0, "sc_players")
sc_status(1, json.encode({status = "mission"}))
sc_status(1, json.encode({status = "hacker"}))
check(countTo(0, "sc_players") == plCount, "nur Änderungen und nur gültige Status")
check(lastTo(0, "sc_config") == nil or lastTo(0, "sc_configUpdate").ui.allowTeleport == false, "Teleport standardmäßig aus")

--== Spritpreise ==
local fp = lastTo(0, "sc_fuelPrices")
check(fp and fp.enabled == true, "Spritpreise beim Karrierestart geschickt")
sc_fuelDelivered(1, json.encode({station = "apex", fuel = "diesel", amount = 2000, stationName = "Apex"}))
fp = lastTo(0, "sc_fuelPrices")
check(fp and math.abs(fp.factors.apex.diesel - 0.9) < 1e-9, "2000 l Diesel -> Diesel bei Apex 10 % günstiger (für alle)")
check(lastChat(0):find("Ben delivered 2000 l of diesel to Apex") ~= nil, "alle sehen die Lieferung")
check(fp.factors.apex.gasoline == nil, "Benzin bleibt unverändert")
sc_fuelDelivered(1, json.encode({station = "apex", fuel = "diesel", amount = 50000}))
check(math.abs(lastTo(0, "sc_fuelPrices").factors.apex.diesel - 0.7) < 1e-9, "höchstens 30 % Rabatt")
local fpCount = countTo(0, "sc_fuelPrices")
sc_fuelDelivered(1, json.encode({station = "apex", fuel = "kerosin", amount = 1000}))
sc_fuelDelivered(1, json.encode({station = "apex", fuel = "diesel", amount = -5}))
sc_fuelDelivered(1, json.encode({station = "", fuel = "diesel", amount = 100}))
check(countTo(0, "sc_fuelPrices") == fpCount, "ungültige Lieferungen ändern nichts")
-- Erholung: alle 5 min 1 Prozentpunkt weniger Rabatt
for _ = 1, 300 do sc_tick() end
check(math.abs(lastTo(0, "sc_fuelPrices").factors.apex.diesel - 0.71) < 1e-9, "nach 5 min 1 % teurer (Rückkehr zum Normalpreis)")
-- gespeichert
local fuelFile = io.open(tmpFuel)
check(fuelFile ~= nil and json.decode(fuelFile:read("*a")).apex.diesel == 29, "Rabatte werden gespeichert")
if fuelFile then fuelFile:close() end
check(onConsoleInput("sc fuel"):find("apex diesel: %-29") ~= nil, "sc fuel zeigt Rabatte")
check(onConsoleInput("sc fuel reset"):find("reset") ~= nil and next(lastTo(0, "sc_fuelPrices").factors) == nil, "sc fuel reset")
onConsoleInput("sc set server.fuelEconomy false")
check(lastTo(0, "sc_fuelPrices").enabled == false, "abschalten wirkt sofort")
fpCount = countTo(0, "sc_fuelPrices")
sc_fuelDelivered(1, json.encode({station = "apex", fuel = "gasoline", amount = 1000}))
check(countTo(0, "sc_fuelPrices") == fpCount, "abgeschaltet: Lieferungen ändern nichts")
onConsoleInput("sc set server.fuelEconomy true")

--== Config wurde gespeichert und ist gültiges JSON ==
local saved = json.decode(assert(io.open(tmp)):read("*a"))
check(saved.client.roadTraffic == 3 and saved.server.paymentMax == 1000000, "config.json gespeichert")
os.remove(tmp)
os.remove(tmpProfiles)
os.remove(tmpFuel)

print(string.format("Server: %d ok, %d Fehler", passed, failures))
os.exit(failures == 0 and 0 or 1)
