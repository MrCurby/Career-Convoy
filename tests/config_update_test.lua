-- Update-Test für die Server-Config: Einspielen einer neuen Version muss neue Standardwerte
-- übernehmen, von Hand geänderte Werte aber behalten.
-- Ausführen:  lua5.3 tests/config_update_test.lua

package.path = "./tests/?.lua;" .. package.path
local json = require("json")

local failures, passed = 0, 0
local function check(cond, msg)
	if cond then passed = passed + 1 else failures = failures + 1; print("FEHLER: " .. msg) end
end

local logs = {}
local configFile = os.tmpname()
local profilesFile = os.tmpname()
os.remove(profilesFile)

local function write(path, text)
	local f = assert(io.open(path, "w")); f:write(text); f:close()
end
local function read(path)
	local f = io.open(path); if not f then return nil end
	local t = f:read("*a"); f:close(); return t
end

-- Lädt main.lua frisch (wie ein Serverstart). `patch` kann den Quelltext ändern,
-- um eine künftige Version mit anderen Standardwerten zu simulieren.
local function startServer(patch)
	logs = {}
	MP = {
		CreateTimer = function() return {GetCurrent = function() return 0 end} end,
		RegisterEvent = function() end, CreateEventTimer = function() end,
		TriggerClientEvent = function() end, SendChatMessage = function() end,
		IsPlayerConnected = function() return false end, GetPlayerName = function() return "x" end,
	}
	Util = {JsonEncode = json.encode, JsonDecode = json.decode}
	FS = {Exists = function() return true end, CreateDirectory = function() end}
	local realPrint = print
	print = function(msg) table.insert(logs, tostring(msg)) end
	local source = assert(io.open("Resources/Server/SharedCareer/main.lua")):read("*a")
	source = source:gsub('local CONFIG_FILE = CONFIG_DIR %.%. "/config%.json"', 'local CONFIG_FILE = "' .. configFile .. '"')
	source = source:gsub('local PROFILES_FILE = CONFIG_DIR %.%. "/profiles%.json"', 'local PROFILES_FILE = "' .. profilesFile .. '"')
	if patch then source = patch(source) end
	assert(load(source, "main.lua"))()
	onInit()
	print = realPrint
	return json.decode(read(configFile))
end

local function logged(pattern)
	for _, line in ipairs(logs) do if line:find(pattern, 1, true) then return true end end
	return false
end

--== 1. Update von 0.3.1 (Datei ohne _defaults) ==
write(configFile, json.encode({
	server = {dayMinutes = 45, nightMinutes = 30, paymentMax = 5000, dayLengthMinutes = 60},
	client = {saveSuffix = "_wcusa", roadTraffic = 6},
}))
local cfg = startServer()
check(cfg.server.dayMinutes == 50, "alter Standard (45) wird automatisch zum neuen (50)")
check(cfg.server.nightMinutes == 30, "von Hand geänderte Nachtlänge (30) bleibt")
check(cfg.server.paymentMax == 5000, "geänderter Höchstbetrag bleibt")
check(cfg.client.saveSuffix == "_wcusa", "Spielstand-Suffix bleibt (wichtig für Spielstände!)")
check(cfg.server.dayLengthMinutes == nil, "veraltete Einstellung verschwindet")
check(cfg.server.trafficSignalSync == true, "neue Einstellungen kommen dazu")
check(type(cfg._defaults) == "table" and cfg._defaults.server.dayMinutes == 50, "Standardwerte werden mitgespeichert")
check(logged("server.dayMinutes: 45 -> 50"), "Konsole sagt, was umgestellt wurde")
check(not logged("nightMinutes"), "Geändertes wird nicht gemeldet")

--== 2. Neustart ohne Update: nichts ändert sich ==
cfg = startServer()
check(cfg.server.dayMinutes == 50 and cfg.server.nightMinutes == 30, "Neustart ändert nichts")
check(not logged("Update:"), "Neustart: keine Update-Meldung")

--== 3. Künftiges Update ändert Standardwerte ==
-- Jemand stellt die Tageslänge per Konsole auf 55 (bleibt), roadTraffic steht auf Standard 6.
local f = json.decode(read(configFile))
f.server.dayMinutes = 55
write(configFile, json.encode(f))
cfg = startServer(function(src)
	src = src:gsub("dayMinutes = 50,", "dayMinutes = 40,", 1)
	src = src:gsub("roadTraffic = 6,", "roadTraffic = 8,", 1)
	return src
end)
check(cfg.server.dayMinutes == 55, "eigene Einstellung (55) übersteht das Update")
check(cfg.client.roadTraffic == 8, "unveränderter Wert bekommt den neuen Standard (6 -> 8)")
check(cfg._defaults.client.roadTraffic == 8, "neue Standardwerte gemerkt")

--== 4. Kaputte Datei wird nicht einfach überschrieben ==
write(configFile, "{ das ist kein json")
cfg = startServer()
check(read(configFile .. ".broken") == "{ das ist kein json", "kaputte Config wird als .broken gesichert")
check(cfg.server.dayMinutes == 50, "Server startet trotzdem mit Standardwerten")
os.remove(configFile .. ".broken")

os.remove(configFile)
os.remove(profilesFile)
print(string.format("Config-Update: %d ok, %d Fehler", passed, failures))
os.exit(failures == 0 and 0 or 1)
