-- Server simulation: the BeamMP API is mocked, main.lua is loaded, flows are played through.
-- Run (Lua 5.3/5.4, like the BeamMP server):  lua5.3 tests/server_test.lua

package.path = "./tests/?.lua;" .. package.path
local json = require("json")
-- read the version from the code (only maintain util.lua/main.lua, see tools/bump.sh)
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
local accounts = {}   -- player id -> BeamMP account ID (nil = none)
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
	-- notifications end up in the same list as chat (for lastChat)
	SendNotification = function(to, msg, icon) table.insert(chats, {to = to, msg = msg, kind = "notify"}) end,
	ConfirmationDialog = function(to, title, body, buttons, interaction, warning)
		assert(type(buttons) == "table" and buttons[1].label, "dialog needs buttons")
		table.insert(dialogs, {to = to, title = title, body = body, warning = warning})
		table.insert(chats, {to = to, msg = title .. ": " .. body, kind = "dialog"})
		return true, ""
	end,
}
Util = {JsonEncode = json.encode, JsonDecode = json.decode}
FS = {Exists = function() return true end, CreateDirectory = function() end}

-- point the config path to a temp file
local source = assert(io.open("Resources/Server/SharedCareer/main.lua")):read("*a")
source = source:gsub('local CONFIG_FILE = CONFIG_DIR %.%. "/config%.json"', 'local CONFIG_FILE = "' .. tmp .. '"')
source = source:gsub('local PROFILES_FILE = CONFIG_DIR %.%. "/profiles%.json"', 'local PROFILES_FILE = "' .. tmpProfiles .. '"')
source = source:gsub('local FUEL_FILE = CONFIG_DIR %.%. "/fuelprices%.json"', 'local FUEL_FILE = "' .. tmpFuel .. '"')
assert(load(source, "main.lua"))()
onInit()

local failures, passed = 0, 0
local function check(cond, msg)
	if cond then passed = passed + 1 else failures = failures + 1; print("FAILED: " .. msg) end
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

-- dialogs go as sc_dialog to the player's menu window (not via BeamMP's dialog)
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

--== Join and settings ==
join(0, "Anna")
local cfg = lastTo(0, "sc_config")
check(cfg and cfg.trafficShare and cfg.trafficShare.road == 6, "first player gets 6 driving cars")
check(cfg.parkedTraffic == 8 and cfg.allowConsole == false, "client settings arrive")
check(cfg.trafficSimpleVehicles == true and cfg.simplifyRemoteVehicles == false, "simple-vehicle-Standardwerte")
check(cfg.trafficAggression == 0.2, "AI aggression is sent")

--== Traffic split: 4 players * 6 = 24 > 20 -> 5 per player ==
join(1, "Ben"); join(2, "Cem"); join(3, "Dana")
check(lastTo(3, "sc_config").trafficShare.road == 5, "4th player gets 5 (20/4)")
check(lastTo(0, "sc_traffic") and lastTo(0, "sc_traffic").road == 5, "existing players get a smaller share")
check(lastTo(0, "sc_traffic").parked == 6, "parked: 24/4 = 6")

--== Vehicle states ==
onVehicleSpawn(0, 0, "")
check(lastTo(1, "sc_vehStates")["0-0"].active == true, "spawn is distributed")
sc_vehActive(0, json.encode({id = "0-0", active = false}))
check(lastTo(1, "sc_vehStates")["0-0"].active == false, "hiding is distributed")
local before = countTo(2, "sc_vehStates")
sc_vehActive(1, json.encode({id = "0-0", active = true}))
check(countTo(2, "sc_vehStates") == before, "a remote vehicle must not be changed")
sc_vehMarks(0, json.encode({["0-0"] = true, ["1-5"] = true}))
local marks = lastTo(2, "sc_vehStates")
check(marks["0-0"].traffic == true and marks["1-5"] == nil, "traffic marks only for own vehicles")
sc_vehActive(0, "kaputt{")
check(true, "broken JSON is ignored")

--== Money transfer: success ==
check(onChatMessage(0, "Anna", "/pay Ben 500") == 1, "/pay is filtered out of the chat")
local debit = lastTo(0, "sc_payDebit")
check(debit and debit.amount == 500 and debit.to == "Ben", "sender is asked to debit")
sc_payDebitResult(0, json.encode({id = debit.id, ok = true}))
local credit = lastTo(1, "sc_payCredit")
check(credit and credit.amount == 500 and credit.from == "Anna", "receiver gets the credit")
sc_payCreditAck(1, json.encode({id = credit.id}))
check(lastChat(0):find("500") ~= nil, "sender gets a confirmation")

--== Money transfer: a different client cannot confirm for someone else ==
fakeTime = fakeTime + 10
onChatMessage(0, "Anna", "/pay ben 100")
local d2 = lastTo(0, "sc_payDebit")
local creditsBefore = countTo(1, "sc_payCredit")
sc_payDebitResult(1, json.encode({id = d2.id, ok = true}))
check(countTo(1, "sc_payCredit") == creditsBefore, "only the sender may report the debit")
sc_payDebitResult(0, json.encode({id = d2.id, ok = false, reason = "not enough money"}))
check(lastChat(0):find("not enough money") ~= nil, "rejected debit is reported")

--== Invalid input ==
fakeTime = fakeTime + 10
onChatMessage(0, "Anna", "/pay Ben -5"); check(lastChat(0):find("Invalid amount") ~= nil, "negative amount")
onChatMessage(0, "Anna", "/pay Ben 1.5"); check(lastChat(0):find("Invalid amount") ~= nil, "Kommabetrag")
onChatMessage(0, "Anna", "/pay Anna 5"); check(lastChat(0):find("yourself") ~= nil, "to yourself")
onChatMessage(0, "Anna", "/pay Zoe 5"); check(lastChat(0):find("No player") ~= nil, "unknown player")
check(onChatMessage(0, "Anna", "hallo") == nil, "normal chat stays")

--== Cooldown ==
fakeTime = fakeTime + 10
onChatMessage(0, "Anna", "/pay Ben 1")
local d3 = lastTo(0, "sc_payDebit")
sc_payDebitResult(0, json.encode({id = d3.id, ok = true}))
sc_payCreditAck(1, json.encode({id = lastTo(1, "sc_payCredit").id}))
local debits = countTo(0, "sc_payDebit")
onChatMessage(0, "Anna", "/pay Ben 1")
check(countTo(0, "sc_payDebit") == debits, "cooldown prevents spam")

--== Receiver leaves during the credit -> refund ==
fakeTime = fakeTime + 10
onChatMessage(0, "Anna", "/pay Cem 300")
local d4 = lastTo(0, "sc_payDebit")
sc_payDebitResult(0, json.encode({id = d4.id, ok = true}))
connected[2] = false
onPlayerDisconnect(2)
local refund = lastTo(0, "sc_payCredit")
check(refund and refund.refund == true and refund.amount == 300, "refund when the receiver leaves")

--== Credit without confirmation -> refund after the timeout ==
fakeTime = fakeTime + 10
onChatMessage(0, "Anna", "/pay Dana 50")
local d5 = lastTo(0, "sc_payDebit")
sc_payDebitResult(0, json.encode({id = d5.id, ok = true}))
fakeTime = fakeTime + 31
sc_tick()
local r2 = lastTo(0, "sc_payCredit")
check(r2 and r2.id == d5.id and r2.refund == true, "refund after the timeout")
sc_payCreditAck(0, json.encode({id = d5.id}))

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
connected[5] = true; names[5] = "Eve"; onPlayerJoin(5)
sc_careerResult(5, json.encode({ok = false, reason = "test"}))
check(#dropped == 0 and lastChat(5):find("test") ~= nil, "failed start: notice instead of kick (default)")

--== Save per account ==
check(lastTo(0, "sc_config").profileBase == "anna" and lastTo(0, "sc_config").isGuest == false,
	"profile from the name on the first join")
local pf = json.decode(assert(io.open(tmpProfiles)):read("*a"))
check(pf["1000"] == "anna", "mapping account -> profile saved")
-- Anna renames their account and comes back: same account -> same profile
connected[0] = false; onPlayerDisconnect(0)
join(0, "Anna_Neu", 1000)
check(lastTo(0, "sc_config").profileBase == "anna", "renaming keeps the save")
check(lastChat(0):find("save anna") ~= nil, "confirmation as a notification")
-- the same account a second time at once
connected[7] = true; names[7] = "AnnaZwei"; accounts[7] = 1000; onPlayerJoin(7)
local before7 = countTo(7, "sc_config")
sc_hello(7, json.encode({version = VERSION}))
check(dropped[#dropped] == 7 and countTo(7, "sc_config") == before7, "the same account twice is refused")
connected[7] = false; onPlayerDisconnect(7)
-- guest
guests[8] = true
join(8, "guest4711", false)
check(lastTo(8, "sc_config").isGuest == true and lastTo(8, "sc_config").profileBase == "guest4711", "guest profile from the guest name")
check(lastDialog(8) and lastDialog(8).title:find("guest"), "guest gets a notice dialog")
connected[8] = false; onPlayerDisconnect(8)
-- version mismatch
connected[9] = true; names[9] = "Alt"; accounts[9] = 1009; onPlayerJoin(9)
sc_hello(9, json.encode({version = "0.0.9"}))
check(lastDialog(9) and lastDialog(9).warning == true and lastDialog(9).body:find("0.0.9"), "version warning as a dialog")
connected[9] = false; onPlayerDisconnect(9)
check(#dialogs == 0, "BeamMP's ConfirmationDialog is not used (led to the main menu in 0.40)")
-- older servers without notifications: chat as a replacement
local savedNotify, savedDialog = MP.SendNotification, MP.ConfirmationDialog
MP.SendNotification, MP.ConfirmationDialog = nil, nil
local chatsBefore = #chats
connected[10] = true; names[10] = "Fallback"; accounts[10] = 1010; onPlayerJoin(10)
sc_hello(10, json.encode({version = VERSION}))
sc_careerResult(10, json.encode({ok = false, reason = "kaputt"}))
check(#chats > chatsBefore and chats[#chats].kind == nil and chats[#chats].msg:find("kaputt"), "without a dialog API the chat is used")
MP.SendNotification, MP.ConfirmationDialog = savedNotify, savedDialog
connected[10] = false; onPlayerDisconnect(10)

--== Time of day (day and night at different speeds) ==
-- default: day 6–20 h (14 h) in 50 min, night 20–6 h (10 h) in 5 min
local daySpeed, nightSpeed = 14 / 3000, 10 / 300
local t0 = lastTo(0, "sc_time")
check(t0 and t0.play == true, "time sent after the career start")
check(math.abs(t0.dayLengthDay - 24 / daySpeed) < 0.01 and math.abs(t0.dayLengthNight - 24 / nightSpeed) < 0.01,
	"day and night speed are sent along")
check(t0.dayLength == t0.dayLengthDay and t0.dayStart == 6 and t0.nightStart == 20, "10:00 = day speed")
check(onConsoleInput("sc time 18:30"):find("18:30") ~= nil, "sc time sets the time")
check(math.abs(lastTo(0, "sc_time").hour - 18.5) < 0.001, "new time to everyone immediately")
-- 1350 s: 1.5 h of day until 20:00, then the whole night (300 s), then day again
fakeTime = fakeTime + 1350
sc_timeTick()
local expected = 6 + (1350 - 1.5 / daySpeed - 300) * daySpeed
check(math.abs(lastTo(0, "sc_time").hour - expected) < 0.001,
	string.format("clock calculates across day/night boundaries (%.3f instead of %.3f)", lastTo(0, "sc_time").hour, expected))
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
check(tp.dayMinutes == 50 and tp.nightMinutes == 5 and tp.canControl == true, "window gets the lengths and the control permission")
fakeTime = fakeTime + 5
sc_timeControl(1, json.encode({action = "set", hour = 7.5}))
check(math.abs(lastTo(0, "sc_time").hour - 7.5) < 0.001, "player sets the time -> applies to everyone")
check(lastChat(0):find("Ben set the time to 07:30") ~= nil, "everyone sees who changed it")
local sentBefore = countTo(0, "sc_time")
sc_timeControl(1, json.encode({action = "set", hour = 9}))
check(countTo(0, "sc_time") == sentBefore, "at most one change per second")
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({action = "lengths", dayMinutes = 40, nightMinutes = 10}))
local tl = lastTo(0, "sc_time")
check(tl.dayMinutes == 40 and tl.nightMinutes == 10 and math.abs(tl.hour - 7.5) < 0.01, "lengths changed, time doesn't jump")
check(onConsoleInput("sc get"):find("server.dayMinutes = 40") ~= nil, "lengths are saved")
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({action = "lengths", dayMinutes = 99999, nightMinutes = -3}))
check(lastTo(0, "sc_time").dayMinutes == 600 and lastTo(0, "sc_time").nightMinutes == 1, "lengths are clamped (1–600 min)")
fakeTime = fakeTime + 2
sentBefore = countTo(0, "sc_time")
sc_timeControl(1, json.encode({action = "set", hour = "abc"}))
sc_timeControl(1, "kaputt")
check(countTo(0, "sc_time") == sentBefore, "invalid input changes nothing")
onConsoleInput("sc set server.allowPlayerTimeControl false")
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({action = "set", hour = 3}))
check(math.abs(lastTo(0, "sc_time").hour - 3) > 0.5 and lastChat(1):find("Only the server owner") ~= nil, "switched off: console only")
check(lastTo(1, "sc_time").canControl == false, "window learns that control is off")
onConsoleInput("sc set server.allowPlayerTimeControl true")
onConsoleInput("sc set server.dayMinutes 50")
onConsoleInput("sc set server.nightMinutes 5")

--== Pausing / resuming the clock ==
fakeTime = fakeTime + 5
sc_timeControl(1, json.encode({action = "set", hour = 12}))
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({action = "pause", paused = true}))
local tpz = lastTo(0, "sc_time")
check(tpz.paused == true and tpz.play == false and math.abs(tpz.hour - 12) < 0.05, "pause: clock stands at the current time")
check(lastChat(0):find("paused the clock") ~= nil, "everyone sees who paused it")
fakeTime = fakeTime + 600
sc_timeTick()
check(math.abs(lastTo(0, "sc_time").hour - tpz.hour) < 0.001, "paused: same time 10 min later")
check(onConsoleInput("sc get"):find("server.timePaused = true") ~= nil, "pause is saved")
check(onConsoleInput("sc time"):find("paused") ~= nil, "sc time shows paused")
fakeTime = fakeTime + 2
sc_timeControl(1, json.encode({action = "pause", paused = false}))
local resumed = lastTo(0, "sc_time")
check(resumed.paused == false and resumed.play == true and math.abs(resumed.hour - tpz.hour) < 0.001, "resume: runs on from the same time")
fakeTime = fakeTime + 300
sc_timeTick()
check(lastTo(0, "sc_time").hour > tpz.hour + 0.1, "afterwards the clock runs again")
check(onConsoleInput("sc time stop"):find("paused") ~= nil and lastTo(0, "sc_time").paused == true, "sc time stop")
check(onConsoleInput("sc time start"):find("running again") ~= nil and lastTo(0, "sc_time").paused == false, "sc time start")

--== Settings from the SharedCareer menu ==
fakeTime = fakeTime + 5
local updatesBefore = countTo(0, "sc_configUpdate")
sc_setSetting(1, json.encode({key = "client.roadTraffic", value = 9}))
local cu = lastTo(0, "sc_configUpdate")
check(countTo(0, "sc_configUpdate") == updatesBefore + 1 and cu.roadTraffic == 9, "menu: driving cars -> applies to everyone")
check(type(cu.ui) == "table" and cu.ui.allowPlayerSettings == true and cu.ui.roadTrafficTotal ~= nil, "menu gets server values (ui)")
check(lastChat(0):find("Driving traffic per player") ~= nil, "everyone sees who changed what")
updatesBefore = countTo(0, "sc_configUpdate")
sc_setSetting(1, json.encode({key = "client.parkedTraffic", value = 3}))
check(countTo(0, "sc_configUpdate") == updatesBefore, "0.5 s lock against click spam")
fakeTime = fakeTime + 1
sc_setSetting(1, json.encode({key = "client.roadTraffic", value = 500}))
check(lastTo(0, "sc_configUpdate").roadTraffic == 50, "values are clamped (max 50)")
fakeTime = fakeTime + 1
sc_setSetting(1, json.encode({key = "client.remoteVehicleGhost", value = true}))
check(lastTo(0, "sc_configUpdate").remoteVehicleGhost == true, "switch (collision off)")
fakeTime = fakeTime + 1
sc_setSetting(1, json.encode({key = "client.remoteVehicleGhost", value = "ja"}))
sc_setSetting(1, json.encode({key = "client.saveSuffix", value = "_hack"}))
sc_setSetting(1, json.encode({key = "server.allowPlayerSettings", value = false}))
check(onConsoleInput("sc get"):find("_hack") == nil, "settings that aren't allowed are off-limits")
check(onConsoleInput("sc get"):find("server.allowPlayerSettings = true") ~= nil, "the menu can't unlock itself")
fakeTime = fakeTime + 1
sc_setSetting(1, json.encode({key = "server.roadTrafficTotal", value = 8}))
local cu2 = lastTo(0, "sc_configUpdate")
check(cu2.ui.roadTrafficTotal == 8 and cu2.trafficShare.road < 9, "server limit: shares are redistributed")
onConsoleInput("sc set server.allowPlayerSettings false")
fakeTime = fakeTime + 1
updatesBefore = countTo(0, "sc_configUpdate")
sc_setSetting(1, json.encode({key = "client.roadTraffic", value = 2}))
check(countTo(0, "sc_configUpdate") == updatesBefore and lastChat(1):find("Only the server owner") ~= nil, "switched off: menu changes nothing")
onConsoleInput("sc set server.allowPlayerSettings true")
onConsoleInput("sc set client.roadTraffic 3")
onConsoleInput("sc set client.remoteVehicleGhost false")
onConsoleInput("sc set server.roadTrafficTotal 20")

--== Player list and status ==
local pl = lastTo(0, "sc_players")
check(pl and #pl.players >= 2 and pl.players[1].name == "Anna_Neu", "player list to everyone (sorted)")
sc_status(1, json.encode({status = "mission"}))
local benEntry
for _, p in ipairs(lastTo(0, "sc_players").players) do if p.name == "Ben" then benEntry = p end end
check(benEntry and benEntry.status == "mission", "status is sent to everyone")
local plCount = countTo(0, "sc_players")
sc_status(1, json.encode({status = "mission"}))
sc_status(1, json.encode({status = "hacker"}))
check(countTo(0, "sc_players") == plCount, "only changes and only valid statuses")
check(lastTo(0, "sc_config") == nil or lastTo(0, "sc_configUpdate").ui.allowTeleport == false, "teleport off by default")

--== Fuel prices ==
local fp = lastTo(0, "sc_fuelPrices")
check(fp and fp.enabled == true, "fuel prices sent at the career start")
sc_fuelDelivered(1, json.encode({station = "apex", fuel = "diesel", amount = 2000, stationName = "Apex"}))
fp = lastTo(0, "sc_fuelPrices")
check(fp and math.abs(fp.factors.apex.diesel - 0.9) < 1e-9, "2000 l diesel -> diesel at Apex 10 % cheaper (for everyone)")
check(lastChat(0):find("Ben delivered 2000 l of diesel to Apex") ~= nil, "everyone sees the delivery")
check(fp.factors.apex.gasoline == nil, "gasoline stays unchanged")
sc_fuelDelivered(1, json.encode({station = "apex", fuel = "diesel", amount = 50000}))
check(math.abs(lastTo(0, "sc_fuelPrices").factors.apex.diesel - 0.7) < 1e-9, "at most 30 % discount")
local fpCount = countTo(0, "sc_fuelPrices")
sc_fuelDelivered(1, json.encode({station = "apex", fuel = "kerosin", amount = 1000}))
sc_fuelDelivered(1, json.encode({station = "apex", fuel = "diesel", amount = -5}))
sc_fuelDelivered(1, json.encode({station = "", fuel = "diesel", amount = 100}))
check(countTo(0, "sc_fuelPrices") == fpCount, "invalid deliveries change nothing")
-- recovery: 1 percentage point less discount every 5 min
for _ = 1, 300 do sc_tick() end
check(math.abs(lastTo(0, "sc_fuelPrices").factors.apex.diesel - 0.71) < 1e-9, "1 % more expensive after 5 min (return to the normal price)")
-- saved
local fuelFile = io.open(tmpFuel)
check(fuelFile ~= nil and json.decode(fuelFile:read("*a")).apex.diesel == 29, "discounts are saved")
if fuelFile then fuelFile:close() end
check(onConsoleInput("sc fuel"):find("apex diesel: %-29") ~= nil, "sc fuel shows discounts")
check(onConsoleInput("sc fuel reset"):find("reset") ~= nil and next(lastTo(0, "sc_fuelPrices").factors) == nil, "sc fuel reset")
onConsoleInput("sc set server.fuelEconomy false")
check(lastTo(0, "sc_fuelPrices").enabled == false, "switching off applies immediately")
fpCount = countTo(0, "sc_fuelPrices")
sc_fuelDelivered(1, json.encode({station = "apex", fuel = "gasoline", amount = 1000}))
check(countTo(0, "sc_fuelPrices") == fpCount, "switched off: deliveries change nothing")
onConsoleInput("sc set server.fuelEconomy true")

--== Towing jobs (beta) ==
do
	local function offer(from, pay)
		sc_jobOffer(from, json.encode({vehicle = {model = "fullsize", config = "base", name = "Gavril Grand Marshal"},
			flatTire = true, pos = {x = 100, y = 200, z = 10}, dir = {x = 1, y = 0},
			dest = {name = "Belasco Auto", pos = {x = 1100, y = 200, z = 12}}, length = 1300, pay = pay or 480}))
	end
	local function jobsOf(id) return lastTo(id, "sc_jobs") end
	onConsoleInput("sc jobs reset")
	check(jobsOf(0) and jobsOf(0).enabled == true and #jobsOf(0).jobs == 0, "jobs list sent to everyone (empty after reset)")
	check(lastTo(0, "sc_configUpdate").ui.jobs == true, "the clients know that jobs are on")
	-- missing jobs: one player is asked to make one up, not more often than every 15 s
	local asked = countTo(0, "sc_jobGenerate") + countTo(1, "sc_jobGenerate")
	fakeTime = fakeTime + 100
	sc_tick(); sc_tick()
	check(countTo(0, "sc_jobGenerate") + countTo(1, "sc_jobGenerate") == asked + 1, "one player asked for a new job")
	offer(0)
	local list = jobsOf(1).jobs
	check(#list == 1 and list[1].state == "open" and list[1].pay == 480 and list[1].dest.name == "Belasco Auto"
		and list[1].flatTire == true, "a made-up job goes to everyone")
	local id = list[1].id
	offer(0); offer(1)
	offer(0) -- fourth: more than server.jobsOpen (3)
	check(#jobsOf(1).jobs == 3, "at most server.jobsOpen open jobs")
	local before = #jobsOf(1).jobs
	sc_jobOffer(0, json.encode({vehicle = {model = "x"}, pos = {x = "a"}}))
	sc_jobOffer(0, "broken{")
	check(#jobsOf(1).jobs == before, "invalid offers are ignored")
	onConsoleInput("sc jobs reset")
	offer(0, 999999)
	check(jobsOf(0).jobs[1].pay == 5000, "the pay is capped at server.jobPayMax")
	onConsoleInput("sc jobs reset")
	offer(0)
	id = jobsOf(0).jobs[1].id
	-- taking: the first one gets it, the others see it as taken
	sc_jobTake(1, json.encode({id = id}))
	check(jobsOf(1).jobs[1].state == "mine" and jobsOf(0).jobs[1].state == "taken" and jobsOf(0).jobs[1].takenBy == "Ben",
		"Ben takes the job: his, taken for the others")
	sc_jobTake(0, json.encode({id = id}))
	check(jobsOf(1).jobs[1].state == "mine" and lastChat(0):find("took that job first") ~= nil, "a second player can't take it")
	offer(0)
	local second = jobsOf(1).jobs[2].id
	sc_jobTake(1, json.encode({id = second}))
	check(jobsOf(1).jobs[2].state == "open" and lastChat(1):find("first") ~= nil, "one job at a time")
	-- done: paid once, only to the taker, at most the job's pay
	sc_jobDone(0, json.encode({id = id, pay = 480}))
	check(lastTo(0, "sc_jobPaid") == nil, "someone else can't finish it")
	sc_jobDone(1, json.encode({id = id, pay = 999999}))
	local paid = lastTo(1, "sc_jobPaid")
	check(paid and paid.id == id and paid.pay == 480, "finished: paid to Ben, at most the job's pay")
	check(lastChat(0):find("Ben towed a Gavril Grand Marshal to Belasco Auto") ~= nil, "the others hear about it")
	local paidCount = countTo(1, "sc_jobPaid")
	sc_jobDone(1, json.encode({id = id, pay = 480}))
	check(countTo(1, "sc_jobPaid") == paidCount and #jobsOf(1).jobs == 1, "paid once; the job is gone")
	sc_jobDone(1, json.encode({id = second, pay = 100}))
	check(countTo(1, "sc_jobPaid") == paidCount, "a job that isn't yours isn't paid")
	-- give up / time out / leave: open again
	sc_jobTake(1, json.encode({id = second}))
	sc_jobGiveUp(1, json.encode({id = second}))
	check(jobsOf(0).jobs[1].state == "open", "given up: open again")
	sc_jobTake(1, json.encode({id = second}))
	fakeTime = fakeTime + 31 * 60
	sc_tick()
	check(jobsOf(0).jobs[1].state == "open" and lastChat(1):find("out of time") ~= nil, "out of time after 30 min: open again")
	check(onConsoleInput("sc jobs"):find("Gavril Grand Marshal to Belasco Auto") ~= nil, "sc jobs lists them")
	onConsoleInput("sc set server.jobs false")
	check(jobsOf(0).enabled == false and #jobsOf(0).jobs == 0 and lastTo(0, "sc_configUpdate").ui.jobs == false,
		"switched off: no jobs for anyone, at once")
	offer(0)
	sc_jobTake(1, json.encode({id = second}))
	check(#jobsOf(0).jobs == 0, "switched off: no new jobs")
	onConsoleInput("sc set server.jobs true")
	join(5, "Eve")
	check(jobsOf(5) and jobsOf(5).enabled == true, "a player who joins gets the jobs")
	sc_jobTake(5, json.encode({id = second}))
	connected[5] = false
	onPlayerDisconnect(5)
	check(jobsOf(0).jobs[1].state == "open", "the taker leaves: open again")
end

--== Config was saved and is valid JSON ==
local saved = json.decode(assert(io.open(tmp)):read("*a"))
check(saved.client.roadTraffic == 3 and saved.server.paymentMax == 1000000, "config.json saved")
os.remove(tmp)
os.remove(tmpProfiles)
os.remove(tmpFuel)

print(string.format("Server: %d ok, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
