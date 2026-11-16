-- Update test for the server config: installing a new version must take over new defaults
-- but keep values that were changed by hand.
-- Run:  lua5.3 tests/config_update_test.lua

package.path = "./tests/?.lua;" .. package.path
local json = require("json")

local failures, passed = 0, 0
local function check(cond, msg)
	if cond then passed = passed + 1 else failures = failures + 1; print("FAILED: " .. msg) end
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

-- Loads main.lua fresh (like a server start). `patch` can change the source code
-- to simulate a future version with different defaults.
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

--== 1. Update from 0.3.1 (file without _defaults) ==
write(configFile, json.encode({
	server = {dayMinutes = 45, nightMinutes = 30, paymentMax = 5000, dayLengthMinutes = 60},
	client = {saveSuffix = "_wcusa", roadTraffic = 6},
}))
local cfg = startServer()
check(cfg.server.dayMinutes == 50, "old default (45) automatically becomes the new one (50)")
check(cfg.server.nightMinutes == 30, "night length changed by hand (30) stays")
check(cfg.server.paymentMax == 5000, "changed maximum amount stays")
check(cfg.client.saveSuffix == "_wcusa", "save suffix stays (important for saves!)")
check(cfg.server.dayLengthMinutes == nil, "obsolete setting disappears")
check(cfg.server.trafficSignalSync == true, "new settings are added")
check(type(cfg._defaults) == "table" and cfg._defaults.server.dayMinutes == 50, "defaults are saved along")
check(logged("server.dayMinutes: 45 -> 50"), "console says what was changed")
check(not logged("nightMinutes"), "changed values are not reported")

--== 2. Restart without an update: nothing changes ==
cfg = startServer()
check(cfg.server.dayMinutes == 50 and cfg.server.nightMinutes == 30, "restart changes nothing")
check(not logged("Update:"), "restart: no update message")

--== 3. A future update changes defaults ==
-- Someone sets the day length to 55 via the console (stays), roadTraffic is on default 6.
local f = json.decode(read(configFile))
f.server.dayMinutes = 55
write(configFile, json.encode(f))
cfg = startServer(function(src)
	src = src:gsub("dayMinutes = 50,", "dayMinutes = 40,", 1)
	src = src:gsub("roadTraffic = 6,", "roadTraffic = 8,", 1)
	return src
end)
check(cfg.server.dayMinutes == 55, "own setting (55) survives the update")
check(cfg.client.roadTraffic == 8, "unchanged value gets the new default (6 -> 8)")
check(cfg._defaults.client.roadTraffic == 8, "new defaults remembered")

--== 4. A renamed setting takes over the old value ==
f = json.decode(read(configFile))
f.client.addApps = nil
f.client.addTimeApp = false   -- name up to 0.14
write(configFile, json.encode(f))
cfg = startServer()
check(cfg.client.addApps == false and cfg.client.addTimeApp == nil, "client.addTimeApp = false becomes client.addApps = false")

--== 5. A broken file is not simply overwritten ==
write(configFile, "{ this is not json")
cfg = startServer()
check(read(configFile .. ".broken") == "{ this is not json", "broken config is backed up as .broken")
check(cfg.server.dayMinutes == 50, "server starts anyway with defaults")
os.remove(configFile .. ".broken")

os.remove(configFile)
os.remove(profilesFile)
print(string.format("Config update: %d ok, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
