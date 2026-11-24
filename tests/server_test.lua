-- Server simulation: the BeamMP API is mocked, main.lua is loaded, flows are played through.
-- Run (Lua 5.3/5.4, like the BeamMP server):  lua5.3 tests/server_test.lua

package.path = "./tests/?.lua;" .. package.path
local json = require("json")
-- the version in the code ("dev"; a release stamps its own in, see tools/package.sh)
local VERSION = io.open("Resources/Server/SharedCareer/main.lua"):read("*a"):match('local VERSION = "(.-)"')

local tmp = os.tmpname()
os.remove(tmp)
local tmpProfiles = os.tmpname()
os.remove(tmpProfiles)
local tmpFuel = os.tmpname()
os.remove(tmpFuel)
local tmpPayouts = os.tmpname()
os.remove(tmpPayouts)
local tmpProgress = os.tmpname()
os.remove(tmpProgress)
local tmpLicenses = os.tmpname()
os.remove(tmpLicenses)

local sent = {} -- {to, event, data}
local chats = {} -- {to, msg}
local dropped = {}
local connected = {}
local names = {}
local fakeTime = 100
local accounts = {} -- player id -> BeamMP account ID (nil = none)
local guests = {} -- player id -> true
local dialogs = {} -- {to, title, body, warning}

MP = {
	CreateTimer = function()
		return {
			GetCurrent = function()
				return fakeTime
			end,
		}
	end,
	TriggerClientEvent = function(to, event, data)
		table.insert(sent, { to = to, event = event, data = data })
	end,
	SendChatMessage = function(to, msg)
		table.insert(chats, { to = to, msg = msg })
	end,
	IsPlayerConnected = function(id)
		return connected[id] == true
	end,
	GetPlayerName = function(id)
		return names[id]
	end,
	DropPlayer = function(id, why)
		table.insert(dropped, id)
	end,
	RegisterEvent = function() end,
	CreateEventTimer = function() end,
	GetPlayerIdentifiers = function(id)
		local t = { ip = "127.0.0.1" }
		if accounts[id] then
			t.beammp = tostring(accounts[id])
		end
		return t
	end,
	IsPlayerGuest = function(id)
		return guests[id] == true
	end,
	-- notifications end up in the same list as chat (for lastChat)
	SendNotification = function(to, msg, icon)
		table.insert(chats, { to = to, msg = msg, kind = "notify" })
	end,
	ConfirmationDialog = function(to, title, body, buttons, interaction, warning)
		assert(type(buttons) == "table" and buttons[1].label, "dialog needs buttons")
		table.insert(dialogs, { to = to, title = title, body = body, warning = warning })
		table.insert(chats, { to = to, msg = title .. ": " .. body, kind = "dialog" })
		return true, ""
	end,
}
Util = { JsonEncode = json.encode, JsonDecode = json.decode }
FS = {
	Exists = function()
		return true
	end,
	CreateDirectory = function() end,
}

-- point the config path to a temp file
local source = assert(io.open("Resources/Server/SharedCareer/main.lua")):read("*a")
source = source:gsub('local CONFIG_FILE = CONFIG_DIR %.%. "/config%.json"', 'local CONFIG_FILE = "' .. tmp .. '"')
source = source:gsub(
	'local PROFILES_FILE = CONFIG_DIR %.%. "/profiles%.json"',
	'local PROFILES_FILE = "' .. tmpProfiles .. '"'
)
source = source:gsub('local FUEL_FILE = CONFIG_DIR %.%. "/fuelprices%.json"', 'local FUEL_FILE = "' .. tmpFuel .. '"')
source =
	source:gsub('local PAYOUTS_FILE = CONFIG_DIR %.%. "/payouts%.json"', 'local PAYOUTS_FILE = "' .. tmpPayouts .. '"')
source = source:gsub(
	'local PROGRESS_FILE = CONFIG_DIR %.%. "/progress%.json"',
	'local PROGRESS_FILE = "' .. tmpProgress .. '"'
)
-- a job type of the tests with its own level rules (two tiers, more XP)
source = source:gsub(
	'local LICENSES_FILE = CONFIG_DIR %.%. "/licenses%.json"',
	'local LICENSES_FILE = "' .. tmpLicenses .. '"'
)
source = source:gsub(
	"local LEVEL_RULES_BY_TYPE = {}",
	"local LEVEL_RULES_BY_TYPE = {short = {tierLevel = {1, 2}, tierXp = {100, 200}}}"
)
assert(load(source, "main.lua"))()
onInit()

local failures, passed = 0, 0
local function check(cond, msg)
	if cond then
		passed = passed + 1
	else
		failures = failures + 1
		print("FAILED: " .. msg)
	end
end

local function lastTo(id, event)
	for i = #sent, 1, -1 do
		if sent[i].to == id and sent[i].event == event then
			return json.decode(sent[i].data)
		end
	end
end
local function countTo(id, event)
	local n = 0
	for _, s in ipairs(sent) do
		if s.to == id and s.event == event then
			n = n + 1
		end
	end
	return n
end
local function lastChat(id)
	for i = #chats, 1, -1 do
		if chats[i].to == id then
			return chats[i].msg
		end
	end
end

-- dialogs go as sc_dialog to the player's menu window (not via BeamMP's dialog)
local function lastDialog(id)
	return lastTo(id, "sc_dialog")
end

local function join(id, name, account)
	connected[id] = true
	names[id] = name
	accounts[id] = account == nil and (1000 + id) or (account ~= false and account or nil)
	onPlayerJoin(id)
	sc_hello(id, json.encode({ version = VERSION }))
	sc_careerResult(id, json.encode({ ok = true }))
end

--== Join and settings ==
join(0, "Anna")
local cfg = lastTo(0, "sc_config")
check(cfg and cfg.trafficShare and cfg.trafficShare.road == 6, "first player gets 6 driving cars")
check(cfg.parkedTraffic == 8 and cfg.allowConsole == false, "client settings arrive")
check(cfg.trafficSimpleVehicles == true and cfg.simplifyRemoteVehicles == false, "simple-vehicle-Standardwerte")
check(cfg.trafficAggression == 0.2, "AI aggression is sent")

--== Traffic split: 4 players * 6 = 24 > 20 -> 5 per player ==
join(1, "Ben")
join(2, "Cem")
join(3, "Dana")
check(lastTo(3, "sc_config").trafficShare.road == 5, "4th player gets 5 (20/4)")
check(lastTo(0, "sc_traffic") and lastTo(0, "sc_traffic").road == 5, "existing players get a smaller share")
check(lastTo(0, "sc_traffic").parked == 6, "parked: 24/4 = 6")

--== Vehicle states ==
onVehicleSpawn(0, 0, "")
check(lastTo(1, "sc_vehStates")["0-0"].active == true, "spawn is distributed")
sc_vehReport(0, json.encode({ ["0-0"] = { active = false } }))
check(lastTo(1, "sc_vehStates")["0-0"].active == false, "hiding is distributed")
local before = countTo(2, "sc_vehStates")
sc_vehReport(1, json.encode({ ["0-0"] = { active = true } }))
check(countTo(2, "sc_vehStates") == before, "a remote vehicle must not be changed")
sc_vehReport(0, json.encode({ ["0-0"] = { active = false, traffic = true }, ["1-5"] = { traffic = true } }))
local marks = lastTo(2, "sc_vehStates")
check(
	marks["0-0"].traffic == true and marks["0-0"].active == false and marks["1-5"] == nil,
	"traffic marks only for own vehicles"
)
before = countTo(2, "sc_vehStates")
sc_vehReport(0, json.encode({ ["0-0"] = { active = false, traffic = true } }))
check(countTo(2, "sc_vehStates") == before, "an unchanged report is not distributed")
sc_vehReport(0, "broken{")
check(true, "broken JSON is ignored")

--== Couplings: passed on, kept for later players ==
sc_couplings(
	1,
	json.encode({ list = { { a = "1-7", an = 4, b = "1-8", bn = 9 }, { a = "2-1", an = 1, b = "2-2", bn = 2 } } })
)
local coup = lastTo(0, "sc_couplings")
check(
	coup and coup.pid == 1 and #coup.list == 1 and coup.list[1].an == 4,
	"couplings passed on, only with own vehicles"
)
check(countTo(1, "sc_couplings") == 0, "not back to the sender")
join(7, "Hugo")
check(lastTo(7, "sc_couplings") and lastTo(7, "sc_couplings").list[1].b == "1-8", "a player who joins later gets them")
connected[7] = false
onPlayerDisconnect(7)
sc_couplings(1, "broken{")
check(true, "broken JSON is ignored")

--== Money transfer: success ==
check(onChatMessage(0, "Anna", "/pay Ben 500") == 1, "/pay is filtered out of the chat")
local debit = lastTo(0, "sc_payDebit")
check(debit and debit.amount == 500 and debit.to == "Ben", "sender is asked to debit")
sc_payDebitResult(0, json.encode({ id = debit.id, ok = true }))
local credit = lastTo(1, "sc_payCredit")
check(credit and credit.amount == 500 and credit.from == "Anna", "receiver gets the credit")
sc_payCreditAck(1, json.encode({ id = credit.id }))
check(lastChat(0):find("500") ~= nil, "sender gets a confirmation")

--== Money transfer: a different client cannot confirm for someone else ==
fakeTime = fakeTime + 10
onChatMessage(0, "Anna", "/pay ben 100")
local d2 = lastTo(0, "sc_payDebit")
local creditsBefore = countTo(1, "sc_payCredit")
sc_payDebitResult(1, json.encode({ id = d2.id, ok = true }))
check(countTo(1, "sc_payCredit") == creditsBefore, "only the sender may report the debit")
sc_payDebitResult(0, json.encode({ id = d2.id, ok = false, reason = "not enough money" }))
check(lastChat(0):find("not enough money") ~= nil, "rejected debit is reported")

--== Invalid input ==
fakeTime = fakeTime + 10
onChatMessage(0, "Anna", "/pay Ben -5")
check(lastChat(0):find("Invalid amount") ~= nil, "negative amount")
onChatMessage(0, "Anna", "/pay Ben 1.5")
check(lastChat(0):find("Invalid amount") ~= nil, "Kommabetrag")
onChatMessage(0, "Anna", "/pay Anna 5")
check(lastChat(0):find("yourself") ~= nil, "to yourself")
onChatMessage(0, "Anna", "/pay Zoe 5")
check(lastChat(0):find("No player") ~= nil, "unknown player")
check(onChatMessage(0, "Anna", "hallo") == nil, "normal chat stays")

--== Cooldown ==
fakeTime = fakeTime + 10
onChatMessage(0, "Anna", "/pay Ben 1")
local d3 = lastTo(0, "sc_payDebit")
sc_payDebitResult(0, json.encode({ id = d3.id, ok = true }))
sc_payCreditAck(1, json.encode({ id = lastTo(1, "sc_payCredit").id }))
local debits = countTo(0, "sc_payDebit")
onChatMessage(0, "Anna", "/pay Ben 1")
check(countTo(0, "sc_payDebit") == debits, "cooldown prevents spam")

--== Receiver leaves during the credit -> refund ==
fakeTime = fakeTime + 10
onChatMessage(0, "Anna", "/pay Cem 300")
local d4 = lastTo(0, "sc_payDebit")
sc_payDebitResult(0, json.encode({ id = d4.id, ok = true }))
connected[2] = false
onPlayerDisconnect(2)
local refund = lastTo(0, "sc_payCredit")
check(refund and refund.refund == true and refund.amount == 300, "refund when the receiver leaves")

--== Credit without confirmation -> refund after the timeout ==
fakeTime = fakeTime + 10
onChatMessage(0, "Anna", "/pay Dana 50")
local d5 = lastTo(0, "sc_payDebit")
sc_payDebitResult(0, json.encode({ id = d5.id, ok = true }))
fakeTime = fakeTime + 31
sc_tick()
local r2 = lastTo(0, "sc_payCredit")
check(r2 and r2.id == d5.id and r2.refund == true, "refund after the timeout")
sc_payCreditAck(0, json.encode({ id = d5.id }))

--== Traffic grows again when players leave ==
check(lastTo(0, "sc_traffic").road == 6, "after leave: 3 players * 6 = 18 <= 20")

--== A player's vehicles disappear with them ==
onVehicleSpawn(3, 1, "")
connected[3] = false
onPlayerDisconnect(3)
sc_vehStatesRequest(0)
check(lastTo(0, "sc_vehStates")["3-1"] == nil, "vehicles of players who left are removed")

--== Console ==
check(onConsoleInput("sc set client.roadTraffic 3"):find("= 3") ~= nil, "set a setting")
check(lastTo(0, "sc_configUpdate").roadTraffic == 3, "live update to players")
check(onConsoleInput("sc set client.gibtsnicht 1"):find("Unknown setting") ~= nil, "unknown setting")
check(onConsoleInput("sc set server.allowPayments maybe"):find("Invalid value") ~= nil, "wrong type")
check(onConsoleInput("hallo") == nil, "other console commands stay untouched")

--== Failed start ==
connected[5] = true
names[5] = "Eve"
onPlayerJoin(5)
sc_careerResult(5, json.encode({ ok = false, reason = "test" }))
check(#dropped == 0 and lastChat(5):find("test") ~= nil, "failed start: notice instead of kick (default)")

--== Save per account ==
check(
	lastTo(0, "sc_config").profileBase == "anna" and lastTo(0, "sc_config").isGuest == false,
	"profile from the name on the first join"
)
local pf = json.decode(assert(io.open(tmpProfiles)):read("*a"))
check(pf["1000"] == "anna", "mapping account -> profile saved")
-- Anna renames their account and comes back: same account -> same profile
connected[0] = false
onPlayerDisconnect(0)
join(0, "Anna_Neu", 1000)
check(lastTo(0, "sc_config").profileBase == "anna", "renaming keeps the save")
check(lastChat(0):find("save anna") ~= nil, "confirmation as a notification")
-- the same account a second time at once
connected[7] = true
names[7] = "AnnaZwei"
accounts[7] = 1000
onPlayerJoin(7)
local before7 = countTo(7, "sc_config")
sc_hello(7, json.encode({ version = VERSION }))
check(dropped[#dropped] == 7 and countTo(7, "sc_config") == before7, "the same account twice is refused")
connected[7] = false
onPlayerDisconnect(7)
-- guest
guests[8] = true
join(8, "guest4711", false)
check(
	lastTo(8, "sc_config").isGuest == true and lastTo(8, "sc_config").profileBase == "guest4711",
	"guest profile from the guest name"
)
check(lastDialog(8) and lastDialog(8).title:find("guest"), "guest gets a notice dialog")
connected[8] = false
onPlayerDisconnect(8)
-- version mismatch
connected[9] = true
names[9] = "Alt"
accounts[9] = 1009
onPlayerJoin(9)
sc_hello(9, json.encode({ version = "0.0.9" }))
check(
	lastDialog(9) and lastDialog(9).warning == true and lastDialog(9).body:find("0.0.9"),
	"version warning as a dialog"
)
connected[9] = false
onPlayerDisconnect(9)
check(#dialogs == 0, "BeamMP's ConfirmationDialog is not used (led to the main menu in 0.40)")
-- older servers without notifications: chat as a replacement
local savedNotify, savedDialog = MP.SendNotification, MP.ConfirmationDialog
MP.SendNotification, MP.ConfirmationDialog = nil, nil
local chatsBefore = #chats
connected[10] = true
names[10] = "Fallback"
accounts[10] = 1010
onPlayerJoin(10)
sc_hello(10, json.encode({ version = VERSION }))
sc_careerResult(10, json.encode({ ok = false, reason = "kaputt" }))
check(
	#chats > chatsBefore and chats[#chats].kind == nil and chats[#chats].msg:find("kaputt"),
	"without a dialog API the chat is used"
)
MP.SendNotification, MP.ConfirmationDialog = savedNotify, savedDialog
connected[10] = false
onPlayerDisconnect(10)

--== Time of day (day and night at different speeds) ==
-- default: day 6–20 h (14 h) in 50 min, night 20–6 h (10 h) in 5 min
local daySpeed, nightSpeed = 14 / 3000, 10 / 300
local t0 = lastTo(0, "sc_time")
check(t0 and t0.play == true, "time sent after the career start")
check(
	math.abs(t0.dayLengthDay - 24 / daySpeed) < 0.01 and math.abs(t0.dayLengthNight - 24 / nightSpeed) < 0.01,
	"day and night speed are sent along"
)
check(t0.dayLength == t0.dayLengthDay and t0.dayStart == 6 and t0.nightStart == 20, "10:00 = day speed")
check(onConsoleInput("sc time 18:30"):find("18:30") ~= nil, "sc time sets the time")
check(math.abs(lastTo(0, "sc_time").hour - 18.5) < 0.001, "new time to everyone immediately")
-- 1350 s: 1.5 h of day until 20:00, then the whole night (300 s), then day again
fakeTime = fakeTime + 1350
sc_timeTick()
local expected = 6 + (1350 - 1.5 / daySpeed - 300) * daySpeed
check(
	math.abs(lastTo(0, "sc_time").hour - expected) < 0.001,
	string.format(
		"clock calculates across day/night boundaries (%.3f instead of %.3f)",
		lastTo(0, "sc_time").hour,
		expected
	)
)
onConsoleInput("sc time 22:00")
check(lastTo(0, "sc_time").dayLength == lastTo(0, "sc_time").dayLengthNight, "at night the night speed applies")
fakeTime = fakeTime + 150 -- half a night = 5 h
sc_timeTick()
check(math.abs(lastTo(0, "sc_time").hour - 3) < 0.001, "night runs faster: 22:00 + 2.5 min = 3:00")
check(onConsoleInput("sc time"):find("night: 5 min") ~= nil, "sc time shows the day/night length")
onConsoleInput("sc set server.nightMinutes 0")
sc_timeTick()
local frozen = lastTo(0, "sc_time")
check(math.abs(frozen.hour - 3) < 0.001 and frozen.play == false, "changing the speed: no jump, 0 = stands still")
fakeTime = fakeTime + 500
check(onConsoleInput("sc time"):find("03:00") ~= nil, "a stopped clock stays stopped")
onConsoleInput("sc set server.nightMinutes 5")
check(onConsoleInput("sc time 25"):find("Time must be 0 to") ~= nil, "invalid time rejected")
onConsoleInput("sc set client.syncTimeOfDay false")
local beforeTick = countTo(0, "sc_time")
sc_timeTick()
check(countTo(0, "sc_time") == beforeTick, "switched off: no time messages")
onConsoleInput("sc set client.syncTimeOfDay true")

--== Time of day from the UI window (every player) ==
sc_timeTick()
local tp = lastTo(0, "sc_time")
check(
	tp.dayMinutes == 50 and tp.nightMinutes == 5 and tp.canControl == true,
	"window gets the lengths and the control permission"
)
fakeTime = fakeTime + 5
sc_timeControl(1, json.encode({ action = "set", hour = 7.5 }))
check(math.abs(lastTo(0, "sc_time").hour - 7.5) < 0.001, "player sets the time -> applies to everyone")
check(lastChat(0):find("Ben set the time to 07:30") ~= nil, "everyone sees who changed it")
local sentBefore = countTo(0, "sc_time")
sc_timeControl(1, json.encode({ action = "set", hour = 9 }))
check(countTo(0, "sc_time") == sentBefore, "at most one change per second")
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({ action = "lengths", dayMinutes = 40, nightMinutes = 10 }))
local tl = lastTo(0, "sc_time")
check(
	tl.dayMinutes == 40 and tl.nightMinutes == 10 and math.abs(tl.hour - 7.5) < 0.01,
	"lengths changed, time doesn't jump"
)
check(onConsoleInput("sc get"):find("server.dayMinutes = 40") ~= nil, "lengths are saved")
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({ action = "lengths", dayMinutes = 99999, nightMinutes = -3 }))
check(
	lastTo(0, "sc_time").dayMinutes == 600 and lastTo(0, "sc_time").nightMinutes == 1,
	"lengths are clamped (1–600 min)"
)
fakeTime = fakeTime + 2
sentBefore = countTo(0, "sc_time")
sc_timeControl(1, json.encode({ action = "set", hour = "abc" }))
sc_timeControl(1, "kaputt")
check(countTo(0, "sc_time") == sentBefore, "invalid input changes nothing")
onConsoleInput("sc set server.allowPlayerTimeControl false")
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({ action = "set", hour = 3 }))
check(
	math.abs(lastTo(0, "sc_time").hour - 3) > 0.5 and lastChat(1):find("Only the server owner") ~= nil,
	"switched off: console only"
)
check(lastTo(1, "sc_time").canControl == false, "window learns that control is off")
onConsoleInput("sc set server.allowPlayerTimeControl true")
onConsoleInput("sc set server.dayMinutes 50")
onConsoleInput("sc set server.nightMinutes 5")

--== Pausing / resuming the clock ==
fakeTime = fakeTime + 5
sc_timeControl(1, json.encode({ action = "set", hour = 12 }))
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({ action = "pause", paused = true }))
local tpz = lastTo(0, "sc_time")
check(
	tpz.paused == true and tpz.play == false and math.abs(tpz.hour - 12) < 0.05,
	"pause: clock stands at the current time"
)
check(lastChat(0):find("paused the clock") ~= nil, "everyone sees who paused it")
fakeTime = fakeTime + 600
sc_timeTick()
check(math.abs(lastTo(0, "sc_time").hour - tpz.hour) < 0.001, "paused: same time 10 min later")
check(onConsoleInput("sc get"):find("server.timePaused = true") ~= nil, "pause is saved")
check(onConsoleInput("sc time"):find("paused") ~= nil, "sc time shows paused")
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({ action = "pause", paused = false }))
local resumed = lastTo(0, "sc_time")
check(
	resumed.paused == false and resumed.play == true and math.abs(resumed.hour - tpz.hour) < 0.001,
	"resume: runs on from the same time"
)
fakeTime = fakeTime + 300
sc_timeTick()
check(lastTo(0, "sc_time").hour > tpz.hour + 0.1, "afterwards the clock runs again")
check(onConsoleInput("sc time stop"):find("paused") ~= nil and lastTo(0, "sc_time").paused == true, "sc time stop")
check(
	onConsoleInput("sc time start"):find("running again") ~= nil and lastTo(0, "sc_time").paused == false,
	"sc time start"
)

--== Real time (the server's clock) ==
local realDate = os.date
local clockNow = { hour = 14, min = 15, sec = 36 }
os.date = function(fmt, ...)
	if fmt == "*t" then
		return { hour = clockNow.hour, min = clockNow.min, sec = clockNow.sec }
	end
	return realDate(fmt, ...)
end
fakeTime = fakeTime + 5
sc_timeControl(1, json.encode({ action = "pause", paused = true }))
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({ action = "realtime", on = true }))
local rt = lastTo(0, "sc_time")
check(rt.realtime == true and math.abs(rt.hour - 14.26) < 0.001, "real time: the server's clock for everyone")
check(
	rt.play == true
		and rt.paused == false
		and rt.dayLength == 86400
		and rt.dayLengthDay == 86400
		and rt.dayLengthNight == 86400,
	"real time: real speed, a pause no longer applies"
)
check(lastChat(0):find("Ben turned on real time") ~= nil, "everyone sees who turned on real time")
check(onConsoleInput("sc get"):find("server.realtimeSync = true") ~= nil, "real time is saved")
clockNow = { hour = 21, min = 0, sec = 0 }
sc_timeTick()
check(math.abs(lastTo(0, "sc_time").hour - 21) < 0.001, "real time: follows the clock on every sync")
fakeTime = fakeTime + 2
sentBefore = countTo(0, "sc_time")
sc_timeControl(1, json.encode({ action = "set", hour = 8 }))
check(
	math.abs(lastTo(0, "sc_time").hour - 21) < 0.001 and lastTo(1, "sc_time").realtime == true,
	"real time: setting a time from the window is ignored"
)
check(onConsoleInput("sc time"):find("real time") ~= nil, "sc time shows real time")
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({ action = "realtime", on = false }))
local off = lastTo(0, "sc_time")
check(
	off.realtime == false and off.play == true and math.abs(off.hour - 21) < 0.001,
	"real time off: runs on from the real time"
)
check(onConsoleInput("sc time real"):find("21:00") ~= nil and lastTo(0, "sc_time").realtime == true, "sc time real")
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({ action = "pause", paused = true }))
local rp = lastTo(0, "sc_time")
check(
	rp.realtime == false and rp.paused == true and math.abs(rp.hour - 21) < 0.001,
	"Pause ends real time, stops at the real time"
)
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({ action = "realtime", on = true }))
check(
	onConsoleInput("sc time 10:00"):find("10:00") ~= nil
		and lastTo(0, "sc_time").realtime == false
		and math.abs(lastTo(0, "sc_time").hour - 10) < 0.001,
	"sc time <HH:MM> ends real time"
)
os.date = realDate

--== Real time in a time zone (summer/winter time computed by the mod) ==
local realTime = os.time
local utcNow = 0
os.time = function(...)
	if select("#", ...) == 0 then
		return utcNow
	end
	return realTime(...)
end
onConsoleInput("sc time real")
local function zoneHour(zone, utc)
	onConsoleInput("sc set server.realtimeZone " .. zone)
	utcNow = utc
	sc_timeTick()
	return lastTo(0, "sc_time").hour
end
local function near(a, h, m)
	return math.abs(a - (h + m / 60)) < 0.001
end
local zoneCases = {
	-- zone, UTC second, expected local hour, minute, what
	{ "Europe/Berlin", 1768478400, 13, 0, "Berlin in winter: UTC+1" },
	{ "Europe/Berlin", 1782907200, 14, 0, "Berlin in summer: UTC+2" },
	{ "Europe/Berlin", 1774745940, 1, 59, "Berlin: one minute before summer time" },
	{ "Europe/Berlin", 1774746000, 3, 0, "Berlin: summer time starts (last Sunday of March)" },
	{ "Europe/Berlin", 1792889940, 2, 59, "Berlin: one minute before winter time" },
	{ "Europe/Berlin", 1792890000, 2, 0, "Berlin: winter time starts (last Sunday of October)" },
	{ "Europe/London", 1782907200, 13, 0, "London in summer: UTC+1" },
	{ "America/New_York", 1772953140, 1, 59, "New York: one minute before summer time" },
	{ "America/New_York", 1772953200, 3, 0, "New York: summer time starts (second Sunday of March)" },
	{ "America/New_York", 1793512740, 1, 59, "New York: one minute before winter time" },
	{ "America/New_York", 1793512800, 1, 0, "New York: winter time starts (first Sunday of November)" },
	{ "America/Phoenix", 1782907200, 5, 0, "Phoenix: no summer time" },
	{ "Australia/Sydney", 1768478400, 23, 0, "Sydney in January: summer time, UTC+11" },
	{ "Australia/Sydney", 1775318340, 2, 59, "Sydney: one minute before winter time" },
	{ "Australia/Sydney", 1775318400, 2, 0, "Sydney: winter time starts (first Sunday of April)" },
	{ "UTC+5:30", 1782907200, 17, 30, "UTC+5:30" },
	{ "UTC-3", 1768478400, 9, 0, "UTC-3" },
	{ "Europe/Berlin", 1835479800, 0, 30, "Berlin: leap day into March 1" },
}
for _, c in ipairs(zoneCases) do
	local h = zoneHour(c[1], c[2])
	check(near(h, c[3], c[4]), string.format("%s (%.3f)", c[5], h))
end
check(onConsoleInput("sc time"):find("Europe/Berlin") ~= nil, "sc time names the time zone")
os.date = function(fmt, ...)
	if fmt == "*t" then
		return { hour = 7, min = 0, sec = 0 }
	end
	return realDate(fmt, ...)
end
check(near(zoneHour("Mars/Base", 1782907200), 7, 0), "unknown time zone: the server's local time")
onConsoleInput("sc set server.realtimeZone") -- no value = empty
sc_timeTick()
check(
	near(lastTo(0, "sc_time").hour, 7, 0) and onConsoleInput("sc time"):find("server clock") ~= nil,
	"no time zone: the server's local time"
)
os.date, os.time = realDate, realTime
onConsoleInput("sc time 10:00")

--== Settings from the SharedCareer menu ==
fakeTime = fakeTime + 5
local updatesBefore = countTo(0, "sc_configUpdate")
sc_setSetting(1, json.encode({ key = "client.roadTraffic", value = 9 }))
local cu = lastTo(0, "sc_configUpdate")
check(
	countTo(0, "sc_configUpdate") == updatesBefore + 1 and cu.roadTraffic == 9,
	"menu: driving cars -> applies to everyone"
)
check(
	type(cu.ui) == "table" and cu.ui.allowPlayerSettings == true and cu.ui.roadTrafficTotal ~= nil,
	"menu gets server values (ui)"
)
check(lastChat(0):find("Driving traffic per player") ~= nil, "everyone sees who changed what")
updatesBefore = countTo(0, "sc_configUpdate")
sc_setSetting(1, json.encode({ key = "client.parkedTraffic", value = 3 }))
check(countTo(0, "sc_configUpdate") == updatesBefore, "0.5 s lock against click spam")
fakeTime = fakeTime + 1
sc_setSetting(1, json.encode({ key = "client.roadTraffic", value = 500 }))
check(lastTo(0, "sc_configUpdate").roadTraffic == 50, "values are clamped (max 50)")
fakeTime = fakeTime + 1
sc_setSetting(1, json.encode({ key = "client.remoteVehicleGhost", value = true }))
check(lastTo(0, "sc_configUpdate").remoteVehicleGhost == true, "switch (collision off)")
fakeTime = fakeTime + 1
sc_setSetting(1, json.encode({ key = "client.remoteVehicleGhost", value = "ja" }))
sc_setSetting(1, json.encode({ key = "client.saveSuffix", value = "_hack" }))
sc_setSetting(1, json.encode({ key = "server.allowPlayerSettings", value = false }))
check(onConsoleInput("sc get"):find("_hack") == nil, "settings that aren't allowed are off-limits")
check(onConsoleInput("sc get"):find("server.allowPlayerSettings = true") ~= nil, "the menu can't unlock itself")
fakeTime = fakeTime + 1
sc_setSetting(1, json.encode({ key = "server.roadTrafficTotal", value = 8 }))
local cu2 = lastTo(0, "sc_configUpdate")
check(cu2.ui.roadTrafficTotal == 8 and cu2.trafficShare.road < 9, "server limit: shares are redistributed")
onConsoleInput("sc set server.allowPlayerSettings false")
fakeTime = fakeTime + 1
updatesBefore = countTo(0, "sc_configUpdate")
sc_setSetting(1, json.encode({ key = "client.roadTraffic", value = 2 }))
check(
	countTo(0, "sc_configUpdate") == updatesBefore and lastChat(1):find("Only the server owner") ~= nil,
	"switched off: menu changes nothing"
)
onConsoleInput("sc set server.allowPlayerSettings true")
onConsoleInput("sc set client.roadTraffic 3")
onConsoleInput("sc set client.remoteVehicleGhost false")
onConsoleInput("sc set server.roadTrafficTotal 20")

--== Player list and status ==
local pl = lastTo(0, "sc_players")
check(pl and #pl.players >= 2 and pl.players[1].name == "Anna_Neu", "player list to everyone (sorted)")
sc_status(1, json.encode({ status = "mission" }))
local benEntry
for _, p in ipairs(lastTo(0, "sc_players").players) do
	if p.name == "Ben" then
		benEntry = p
	end
end
check(benEntry and benEntry.status == "mission", "status is sent to everyone")
local plCount = countTo(0, "sc_players")
sc_status(1, json.encode({ status = "mission" }))
sc_status(1, json.encode({ status = "hacker" }))
check(countTo(0, "sc_players") == plCount, "only changes and only valid statuses")
check(
	lastTo(0, "sc_config") == nil or lastTo(0, "sc_configUpdate").ui.allowTeleport == false,
	"teleport off by default"
)

--== Fuel prices ==
local fp = lastTo(0, "sc_fuelPrices")
check(fp and fp.enabled == true, "fuel prices sent at the career start")
sc_fuelDelivered(1, json.encode({ station = "apex", fuel = "diesel", amount = 2000, stationName = "Apex" }))
fp = lastTo(0, "sc_fuelPrices")
check(
	fp and math.abs(fp.factors.apex.diesel - 0.9) < 1e-9,
	"2000 l diesel -> diesel at Apex 10 % cheaper (for everyone)"
)
check(lastChat(0):find("Ben delivered 2000 l of diesel to Apex") ~= nil, "everyone sees the delivery")
check(fp.factors.apex.gasoline == nil, "gasoline stays unchanged")
sc_fuelDelivered(1, json.encode({ station = "apex", fuel = "diesel", amount = 50000 }))
check(math.abs(lastTo(0, "sc_fuelPrices").factors.apex.diesel - 0.7) < 1e-9, "at most 30 % discount")
local fpCount = countTo(0, "sc_fuelPrices")
sc_fuelDelivered(1, json.encode({ station = "apex", fuel = "kerosin", amount = 1000 }))
sc_fuelDelivered(1, json.encode({ station = "apex", fuel = "diesel", amount = -5 }))
sc_fuelDelivered(1, json.encode({ station = "", fuel = "diesel", amount = 100 }))
check(countTo(0, "sc_fuelPrices") == fpCount, "invalid deliveries change nothing")
-- recovery: 1 percentage point less discount every 5 min
for _ = 1, 300 do
	sc_tick()
end
check(
	math.abs(lastTo(0, "sc_fuelPrices").factors.apex.diesel - 0.71) < 1e-9,
	"1 % more expensive after 5 min (return to the normal price)"
)
-- saved
local fuelFile = io.open(tmpFuel)
check(fuelFile ~= nil and json.decode(fuelFile:read("*a")).apex.diesel == 29, "discounts are saved")
if fuelFile then
	fuelFile:close()
end
check(onConsoleInput("sc fuel"):find("apex diesel: %-29") ~= nil, "sc fuel shows discounts")
check(
	onConsoleInput("sc fuel reset"):find("reset") ~= nil and next(lastTo(0, "sc_fuelPrices").factors) == nil,
	"sc fuel reset"
)
onConsoleInput("sc set server.fuelEconomy false")
check(lastTo(0, "sc_fuelPrices").enabled == false, "switching off applies immediately")
fpCount = countTo(0, "sc_fuelPrices")
sc_fuelDelivered(1, json.encode({ station = "apex", fuel = "gasoline", amount = 1000 }))
check(countTo(0, "sc_fuelPrices") == fpCount, "switched off: deliveries change nothing")
onConsoleInput("sc set server.fuelEconomy true")

--== Licenses ==
-- buying one: the server asks the client to pay, the client says ok
local function giveLicense(id, license)
	sc_licenseBuy(id, json.encode({ license = license }))
	local charge = lastTo(id, "sc_licenseCharge")
	sc_licenseChargeResult(id, json.encode({ id = charge.id, ok = true }))
end
do
	sc_licensesRequest(1)
	local shop = {}
	for _, l in ipairs(lastTo(1, "sc_licenses").list) do
		shop[l.id] = l
	end
	check(
		shop.towing and shop.towing.jobType == "tow" and shop.towing.price == 5000 and not shop.towing.owned,
		"the shop: a Towing License for tow jobs, $5,000"
	)
	check(
		shop.taxi and shop.taxi.jobType == "taxi" and shop.taxi.price == 5000 and shop.taxi.name == "Taxi License",
		"the shop: a Taxi License for taxi jobs, $5,000"
	)
	giveLicense(1, "taxi")
	local owned = {}
	for _, l in ipairs(lastTo(1, "sc_licenses").list) do
		owned[l.id] = l.owned
	end
	check(owned.taxi == true and owned.towing == false, "Ben buys the Taxi License: only that one is his")
end

--== Jobs ==
do
	local function offer(from, pay, tier)
		sc_jobOffer(
			from,
			json.encode({
				type = "tow",
				tier = tier or 1,
				title = "Gavril Grand Marshal",
				pos = { x = 100, y = 200, z = 10 },
				dest = { name = "Belasco Auto", pos = { x = 1100, y = 200, z = 12 } },
				length = 1300,
				pay = pay or 480,
				data = { vehicle = { model = "fullsize", config = "base" }, flatTire = true, dir = { x = 1, y = 0 } },
			})
		)
	end
	local function jobsOf(id)
		return lastTo(id, "sc_jobs")
	end
	onConsoleInput("sc jobs reset")
	check(
		jobsOf(0) and jobsOf(0).enabled == true and #jobsOf(0).jobs == 0,
		"jobs list sent to everyone (empty after reset)"
	)
	check(lastTo(0, "sc_configUpdate").ui.jobs == true, "the clients know that jobs are on")
	-- missing jobs: one player whose client has the job type is asked to make one up, not more often
	-- than every 5 s
	local asked = countTo(0, "sc_jobGenerate") + countTo(1, "sc_jobGenerate")
	fakeTime = fakeTime + 100
	sc_tick()
	check(
		countTo(0, "sc_jobGenerate") + countTo(1, "sc_jobGenerate") == asked,
		"no client has told its job types yet: nobody is asked"
	)
	-- as in the game: a client tells its job types when its career starts, before it reports the
	-- start (sc_careerResult); they count all the same
	onPlayerDisconnect(0)
	onPlayerJoin(0)
	sc_hello(0, json.encode({ version = VERSION }))
	sc_jobsRequest(0, json.encode({ types = { "tow" } }))
	sc_careerResult(0, json.encode({ ok = true }))
	check(jobsOf(0).levels.tow.level == 1, "a job type a client has: everyone sees their level in it")
	fakeTime = fakeTime + 100
	sc_tick()
	sc_tick()
	check(countTo(0, "sc_jobGenerate") + countTo(1, "sc_jobGenerate") == asked + 1, "one player asked for a new job")
	local ask = lastTo(0, "sc_jobGenerate") or lastTo(1, "sc_jobGenerate")
	check(ask.type == "tow" and ask.tier == 1, "a towing job of tier 1")
	offer(0)
	local list = jobsOf(1).jobs
	check(
		#list == 1
			and list[1].state == "open"
			and list[1].pay == 480
			and list[1].xp == 40
			and list[1].dest.name == "Belasco Auto"
			and list[1].type == "tow"
			and list[1].title == "Gavril Grand Marshal"
			and list[1].data.flatTire == true
			and list[1].data.vehicle.model == "fullsize"
			and list[1].tier == 1
			and list[1].minLevel == 1
			and not list[1].locked,
		"a made-up job goes to everyone, with its type's own fields and its tier"
	)
	check(
		jobsOf(1).levels.tow.level == 1 and jobsOf(1).levels.tow.to == 100,
		"everyone starts at level 1 (100 XP to level 2)"
	)
	local id = list[1].id
	offer(0)
	offer(1)
	offer(0) -- fourth: more than server.jobsOpen (3)
	check(#jobsOf(1).jobs == 3, "at most server.jobsOpen open jobs of a tier")
	offer(0, nil, 9)
	check(#jobsOf(1).jobs == 3, "a tier that doesn't exist is ignored")
	onConsoleInput("sc jobs reset")
	sc_jobOffer(0, json.encode({ type = "tow", title = "x", pos = { x = "a" } }))
	sc_jobOffer(0, "broken{")
	local valid = {
		type = "tow",
		tier = 1,
		title = "x",
		pos = { x = 1, y = 2, z = 3 },
		dest = { pos = { x = 4, y = 5, z = 6 } },
		length = 1,
		pay = 1,
	}
	local function without(key, value)
		local o = {}
		for k, v in pairs(valid) do
			o[k] = v
		end
		o[key] = value
		return json.encode(o)
	end
	sc_jobOffer(0, without("type", nil))
	sc_jobOffer(0, without("type", "no spaces"))
	sc_jobOffer(0, without("title", nil))
	sc_jobOffer(0, without("tier", nil))
	sc_jobOffer(0, without("data", { text = string.rep("x", 3000) }))
	check(
		#jobsOf(1).jobs == 0,
		"invalid offers are ignored (also without a type, tier or title, or with too much data)"
	)
	sc_jobOffer(0, without("data", nil))
	check(
		#jobsOf(1).jobs == 1 and jobsOf(1).jobs[1].dest.name == "Destination",
		"a job without own fields or a destination name is fine"
	)
	onConsoleInput("sc jobs reset")
	offer(0, 999999)
	check(jobsOf(0).jobs[1].pay == 5000, "the pay is capped at server.jobPayMax")
	onConsoleInput("sc jobs reset")
	offer(0)
	id = jobsOf(0).jobs[1].id
	-- a tow job needs the Towing License
	sc_jobTake(1, json.encode({ id = id }))
	check(
		jobsOf(1).jobs[1].state == "open" and lastChat(1):find("Needs the Towing License") ~= nil,
		"without the Towing License: Ben can't take a tow job and hears why"
	)
	giveLicense(0, "towing")
	giveLicense(1, "towing")
	-- taking: the first one gets it, the others see it as taken
	sc_jobTake(1, json.encode({ id = id }))
	check(
		jobsOf(1).jobs[1].state == "mine" and jobsOf(0).jobs[1].state == "taken" and jobsOf(0).jobs[1].takenBy == "Ben",
		"Ben takes the job: his, taken for the others"
	)
	sc_jobTake(0, json.encode({ id = id }))
	check(
		jobsOf(1).jobs[1].state == "mine" and lastChat(0):find("took that job first") ~= nil,
		"a second player can't take it"
	)
	offer(0)
	local second = jobsOf(1).jobs[2].id
	sc_jobTake(1, json.encode({ id = second }))
	check(jobsOf(1).jobs[2].state == "open" and lastChat(1):find("first") ~= nil, "one job at a time")
	-- done: paid once, only to the taker, at most the job's pay
	sc_jobDone(0, json.encode({ id = id, share = 1 }))
	check(lastTo(0, "sc_jobPaid") == nil, "someone else can't finish it")
	sc_jobDone(1, json.encode({ id = id, share = 7 }))
	local paid = lastTo(1, "sc_jobPaid")
	check(
		paid
			and paid.job == id
			and paid.pay == 480
			and type(paid.payout) == "string"
			and paid.deduction == 0
			and paid.type == "tow"
			and paid.title == "Gavril Grand Marshal",
		"finished: paid to Ben, at most the job's pay (a share above 1 counts as 1)"
	)
	check(paid.xp == 40 and jobsOf(1).levels.tow.xp == 40, "a tier-1 job gives 40 XP")
	check(lastChat(0):find("Ben brought the Gavril Grand Marshal to Belasco Auto") ~= nil, "the others hear about it")
	local function storedPayouts()
		local f = io.open(tmpPayouts)
		if not f then
			return {}
		end
		local stored = json.decode(f:read("*a"))
		f:close()
		return stored
	end
	check(
		storedPayouts()[paid.payout]
			and storedPayouts()[paid.payout].pay == 480
			and storedPayouts()[paid.payout].profile == "ben",
		"the payout is saved until Ben's client confirms it (survives a server restart)"
	)
	local paidCount = countTo(1, "sc_jobPaid")
	sc_jobDone(1, json.encode({ id = id, share = 1 }))
	check(countTo(1, "sc_jobPaid") == paidCount and #jobsOf(1).jobs == 1, "paid once; the job is gone")
	sc_jobDone(1, json.encode({ id = second, share = 1 }))
	check(countTo(1, "sc_jobPaid") == paidCount, "a job that isn't yours isn't paid")
	-- no confirmation: sent again every 10 s, to Ben only
	fakeTime = fakeTime + 5
	sc_tick()
	check(countTo(1, "sc_jobPaid") == paidCount, "not sent again within 10 s")
	fakeTime = fakeTime + 6
	sc_tick()
	check(
		countTo(1, "sc_jobPaid") == paidCount + 1 and lastTo(1, "sc_jobPaid").payout == paid.payout,
		"not confirmed: sent again"
	)
	check(
		onConsoleInput("sc jobs"):find("payout %$480 for Gavril Grand Marshal to save ben") ~= nil,
		"sc jobs shows open payouts"
	)
	sc_jobPaidAck(0, json.encode({ payout = paid.payout }))
	check(storedPayouts()[paid.payout] ~= nil, "someone else can't confirm it")
	-- Ben drops before confirming: it waits for him and comes on his next career start
	connected[1] = false
	onPlayerDisconnect(1)
	fakeTime = fakeTime + 60
	sc_tick()
	join(1, "Ben")
	check(
		countTo(1, "sc_jobPaid") == paidCount + 2 and lastTo(1, "sc_jobPaid").payout == paid.payout,
		"Ben comes back: the open payout arrives at once"
	)
	sc_jobPaidAck(1, json.encode({ payout = paid.payout }))
	check(next(storedPayouts()) == nil, "confirmed: the payout is done")
	fakeTime = fakeTime + 60
	sc_tick()
	check(countTo(1, "sc_jobPaid") == paidCount + 2, "confirmed: not sent again")
	sc_jobPaidAck(1, json.encode({ payout = paid.payout }))
	sc_jobPaidAck(1, "broken{")
	check(true, "a second or broken confirmation is ignored")
	-- give up / time out / leave: open again
	sc_jobTake(1, json.encode({ id = second }))
	sc_jobGiveUp(1, json.encode({ id = second }))
	check(jobsOf(0).jobs[1].state == "open", "given up: open again")
	sc_jobTake(1, json.encode({ id = second }))
	fakeTime = fakeTime + 31 * 60
	sc_tick()
	check(
		jobsOf(0).jobs[1].state == "open" and lastChat(1):find("out of time") ~= nil,
		"out of time after 30 min: open again"
	)
	check(onConsoleInput("sc levels"):find("ben tow: level 1, 40 XP, 1 done") ~= nil, "sc levels lists the job levels")
	check(onConsoleInput("sc jobs"):find("Gavril Grand Marshal to Belasco Auto") ~= nil, "sc jobs lists them")
	onConsoleInput("sc set server.jobs false")
	check(
		jobsOf(0).enabled == false and #jobsOf(0).jobs == 0 and lastTo(0, "sc_configUpdate").ui.jobs == false,
		"switched off: no jobs for anyone, at once"
	)
	offer(0)
	sc_jobTake(1, json.encode({ id = second }))
	check(#jobsOf(0).jobs == 0, "switched off: no new jobs")
	onConsoleInput("sc set server.jobs true")
	join(5, "Eve")
	giveLicense(5, "towing")
	check(jobsOf(5) and jobsOf(5).enabled == true, "a player who joins gets the jobs")
	sc_jobTake(5, json.encode({ id = second }))
	connected[5] = false
	onPlayerDisconnect(5)
	check(jobsOf(0).jobs[1].state == "open", "the taker leaves: open again")
end

--== Job levels ==
do
	local function jobsOf(id)
		return lastTo(id, "sc_jobs")
	end
	local function offer(tier, pay)
		sc_jobOffer(
			0,
			json.encode({
				type = "tow",
				tier = tier,
				title = "Car " .. tier,
				pos = { x = 1, y = 2, z = 3 },
				dest = { name = "Shop", pos = { x = 4, y = 5, z = 6 } },
				length = 1000,
				pay = pay or 1000,
			})
		)
	end
	local function findJob(id, tier)
		for _, j in ipairs(jobsOf(id).jobs) do
			if j.tier == tier and j.state == "open" then
				return j
			end
		end
	end
	local function finish(id, tier, share)
		onConsoleInput("sc jobs reset")
		offer(tier)
		local j = findJob(id, tier)
		sc_jobTake(id, json.encode({ id = j.id }))
		sc_jobDone(id, json.encode({ id = j.id, share = share or 1 }))
		local paid = lastTo(id, "sc_jobPaid")
		sc_jobPaidAck(id, json.encode({ payout = paid.payout }))
		return paid
	end
	onConsoleInput("sc levels reset ben")
	check(jobsOf(1).levels.tow.level == 1 and jobsOf(1).levels.tow.xp == 0, "sc levels reset: Ben is back at level 1")
	-- a job of a higher tier: listed, locked, can't be taken
	onConsoleInput("sc jobs reset")
	offer(2)
	local j = findJob(1, 2)
	check(j and j.locked and j.minLevel == 3, "a tier-2 job: locked for Ben (needs level 3)")
	sc_jobTake(1, json.encode({ id = j.id }))
	check(findJob(1, 2) and lastChat(1):find("Needs level 3") ~= nil, "taking it is refused, Ben hears why")
	-- damage costs XP too: half the pay, half the XP
	local paid = finish(1, 1, 0.5)
	check(paid.pay == 500 and paid.deduction == 500 and paid.xp == 20, "half the pay earned: half the XP")
	-- levelling up: level 3 opens tier 2, the pay grows with the level
	for _ = 1, 7 do
		paid = finish(1, 1)
	end
	local lv = jobsOf(1).levels.tow
	check(lv.level == 3 and lv.xp == 300 and lv.from == 283, "300 XP: level 3")
	check(lastChat(1):find("Level 3") ~= nil, "Ben hears that new jobs are open")
	onConsoleInput("sc jobs reset")
	offer(2)
	j = findJob(1, 2)
	check(
		j and not j.locked and j.pay == 1100 and findJob(0, 2).pay == 1000,
		"tier 2 open for Ben; he sees his pay with +10 % (level 3), the others the normal pay"
	)
	paid = finish(1, 2)
	check(paid.pay == 1100 and paid.xp == 70, "paid with his bonus; a tier-2 job gives 70 XP")
	-- enough jobs for everyone: tier 1 and every player's highest tier are kept stocked
	onConsoleInput("sc jobs reset")
	local before = countTo(0, "sc_jobGenerate") + countTo(1, "sc_jobGenerate")
	local tiers = {}
	for _ = 1, 8 do
		fakeTime = fakeTime + 6
		sc_tick()
		local ask = (countTo(0, "sc_jobGenerate") >= countTo(1, "sc_jobGenerate")) and lastTo(0, "sc_jobGenerate")
			or lastTo(1, "sc_jobGenerate")
		local now = countTo(0, "sc_jobGenerate") + countTo(1, "sc_jobGenerate")
		if now > before then
			before = now
			table.insert(tiers, ask.tier)
			offer(ask.tier)
		end
	end
	local count = { 0, 0, 0, 0 }
	for _, job in ipairs(jobsOf(0).jobs) do
		count[job.tier] = count[job.tier] + 1
	end
	check(
		count[1] == 3 and count[2] == 3 and count[3] == 0 and #tiers == 6,
		"three open jobs of tier 1 (everyone) and of tier 2 (Ben's highest), made up in turn"
	)
	-- a low tier gives less XP to a strong player
	for _ = 1, 15 do
		finish(1, 2)
	end
	check(jobsOf(1).levels.tow.level >= 5, "Ben reaches level 5 (tier 3)")
	offer(1)
	local shown = findJob(1, 1).xp
	paid = finish(1, 1)
	check(shown == 20 and paid.xp == 20, "a tier-1 job two tiers below his: half the XP, shown on the job before")
	-- a job type with its own rules (two tiers, from level 1 and 2; 100 XP for tier 1); levels apart
	local function offerShort(tier)
		sc_jobOffer(
			0,
			json.encode({
				type = "short",
				tier = tier,
				title = "Box",
				pos = { x = 1, y = 2, z = 3 },
				dest = { name = "Depot", pos = { x = 4, y = 5, z = 6 } },
				length = 100,
				pay = 100,
			})
		)
	end
	onConsoleInput("sc jobs reset")
	offerShort(3)
	offerShort(2)
	local short
	for _, sj in ipairs(jobsOf(1).jobs) do
		if sj.type == "short" then
			short = sj
		end
	end
	check(
		#jobsOf(1).jobs == 1 and short.minLevel == 2 and short.locked and jobsOf(1).levels.short.level == 1,
		"own rules: no tier 3, tier 2 from level 2 – and Ben starts this job type at level 1"
	)
	offerShort(1)
	for _, sj in ipairs(jobsOf(1).jobs) do
		if sj.tier == 1 then
			short = sj
		end
	end
	sc_jobTake(1, json.encode({ id = short.id }))
	sc_jobDone(1, json.encode({ id = short.id, share = 1 }))
	sc_jobPaidAck(1, json.encode({ payout = lastTo(1, "sc_jobPaid").payout }))
	check(
		lastTo(1, "sc_jobPaid").xp == 100 and jobsOf(1).levels.short.level == 2 and jobsOf(1).levels.tow.level >= 5,
		"100 XP: level 2 in this job type; the towing level stays as it was"
	)
	-- a job type only one client has (a taxi job): asked from that one; a job type and tier that
	-- gets no job (no place for it on the map) waits 30 s, the others go on
	onConsoleInput("sc jobs reset")
	sc_jobsRequest(1, json.encode({ types = { "tow", "taxi", "no-way", 5 } }))
	check(
		jobsOf(1).levels.taxi and jobsOf(1).levels["no-way"] == nil,
		"Ben's client has taxi jobs; a job type that isn't a word is dropped"
	)
	local function asks(id)
		return countTo(id, "sc_jobGenerate")
	end
	local taxiAsks, others = 0, 0
	for _ = 1, 12 do
		local before = { asks(0), asks(1) }
		fakeTime = fakeTime + 6
		sc_tick()
		for id = 0, 1 do
			if asks(id) > before[id + 1] then
				local a = lastTo(id, "sc_jobGenerate")
				if a.type == "taxi" then
					taxiAsks = taxiAsks + 1
					check(id == 1, "a taxi job is asked from Ben, whose client has them")
				else
					others = others + 1
					offer(a.tier)
				end
			end
		end
	end
	check(
		taxiAsks >= 2 and taxiAsks <= 3 and others >= 6 and #jobsOf(0).jobs == others,
		"no taxi job comes: asked again only every 30 s, the towing jobs are made meanwhile ("
			.. taxiAsks
			.. "/"
			.. others
			.. ")"
	)
	-- the levels survive a restart of the server
	local f = assert(io.open(tmpProgress))
	local stored = json.decode(f:read("*a"))
	f:close()
	check(
		stored.profiles.ben.tow.xp == jobsOf(1).levels.tow.xp
			and #stored.profiles.ben.tow.history == 20
			and stored.profiles.ben.tow.stats.done > 20,
		"progress.json keeps XP, stats and the last 20 jobs"
	)
end

--== Config was saved and is valid JSON ==
local saved = json.decode(assert(io.open(tmp)):read("*a"))
check(saved.client.roadTraffic == 3 and saved.server.paymentMax == 1000000, "config.json saved")
os.remove(tmp)
os.remove(tmpProfiles)
os.remove(tmpFuel)
os.remove(tmpPayouts)
os.remove(tmpProgress)

print(string.format("Server: %d ok, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
