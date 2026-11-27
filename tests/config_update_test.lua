-- Update test for the server config: installing a new version must take over new defaults,
-- keep values that were changed by hand and never throw a value away. At the end, DEFAULTS is
-- compared with the last release: a setting that is gone must be in RENAMED or REMOVED.
-- Run:  lua5.3 tests/config_update_test.lua

package.path = "./tests/?.lua;" .. package.path
local json = require("json")

local failures, passed = 0, 0
local function check(cond, msg)
	if cond then
		passed = passed + 1
	else
		failures = failures + 1
		print("FAILED: " .. msg)
	end
end

local logs = {}
local configFile = os.tmpname()
local profilesFile = os.tmpname()
os.remove(profilesFile)

local function write(path, text)
	local f = assert(io.open(path, "w"))
	f:write(text)
	f:close()
end
local function read(path)
	local f = io.open(path)
	if not f then
		return nil
	end
	local t = f:read("*a")
	f:close()
	return t
end

-- Loads main.lua fresh (like a server start). `patch` can change the source code
-- to simulate a future version with different defaults.
local function startServer(patch)
	logs = {}
	MP = {
		CreateTimer = function()
			return {
				GetCurrent = function()
					return 0
				end,
			}
		end,
		RegisterEvent = function() end,
		CreateEventTimer = function() end,
		TriggerClientEvent = function() end,
		SendChatMessage = function() end,
		IsPlayerConnected = function()
			return false
		end,
		GetPlayerName = function()
			return "x"
		end,
	}
	Util = { JsonEncode = json.encode, JsonDecode = json.decode }
	FS = {
		Exists = function()
			return true
		end,
		CreateDirectory = function() end,
	}
	local realPrint = print
	print = function(msg)
		table.insert(logs, tostring(msg))
	end
	local source = assert(io.open("Resources/Server/CareerConvoy/main.lua")):read("*a")
	source =
		source:gsub('local CONFIG_FILE = CONFIG_DIR %.%. "/config%.json"', 'local CONFIG_FILE = "' .. configFile .. '"')
	source = source:gsub(
		'local PROFILES_FILE = CONFIG_DIR %.%. "/profiles%.json"',
		'local PROFILES_FILE = "' .. profilesFile .. '"'
	)
	if patch then
		source = patch(source)
	end
	assert(load(source, "main.lua"))()
	onInit()
	print = realPrint
	return json.decode(read(configFile))
end

local function logged(pattern)
	for _, line in ipairs(logs) do
		if line:find(pattern, 1, true) then
			return true
		end
	end
	return false
end

--== 1. Update from an older version (its defaults are in _defaults) ==
write(
	configFile,
	json.encode({
		server = { dayMinutes = 45, nightMinutes = 30, paymentMax = 5000, dayLengthMinutes = 60 },
		client = { saveSuffix = "_wcusa", roadTraffic = 6 },
		_defaults = {
			server = { dayMinutes = 45, nightMinutes = 15, paymentMax = 1000000 },
			client = {
				roadTraffic = 6,
			},
		},
	})
)
local cfg = startServer()
check(cfg.server.dayMinutes == 50, "old default (45) automatically becomes the new one (50)")
check(cfg.server.nightMinutes == 30, "night length changed by hand (30) stays")
check(cfg.server.paymentMax == 5000, "changed maximum amount stays")
check(cfg.client.saveSuffix == "_wcusa", "save suffix stays (important for saves!)")
check(
	cfg.server.dayLengthMinutes == nil and cfg._retired["server.dayLengthMinutes"] == 60,
	"a setting this version doesn't know is kept under _retired"
)
check(logged("server.dayLengthMinutes = 60 (not used by this version)"), "console says which setting was retired")
check(cfg.server.trafficSignalSync == true, "new settings are added")
check(type(cfg._defaults) == "table" and cfg._defaults.server.dayMinutes == 50, "defaults are saved along")
check(logged("server.dayMinutes: 45 -> 50"), "console says what was changed")
check(not logged("nightMinutes"), "changed values are not reported")

--== 2. Restart without an update: nothing changes ==
cfg = startServer()
check(cfg.server.dayMinutes == 50 and cfg.server.nightMinutes == 30, "restart changes nothing")
check(cfg._retired["server.dayLengthMinutes"] == 60, "the retired value survives restarts")
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
f.client.addTimeApp = false -- name up to 0.14
write(configFile, json.encode(f))
cfg = startServer()
check(
	cfg.client.addApps == false and cfg.client.addTimeApp == nil,
	"client.addTimeApp = false becomes client.addApps = false"
)

--== 4b. A rename several versions later still finds the value under _retired ==
cfg = startServer(function(src)
	src = src:gsub("\t\tdayMinutes = 50,", "\t\tdayMinutes = 50,\n\t\tdayLength = 1,", 1)
	src = src:gsub("local RENAMED = {", 'local RENAMED = {\n\tserver = {dayLength = "dayLengthMinutes"},', 1)
	return src
end)
check(
	cfg.server.dayLength == 60 and (cfg._retired or {})["server.dayLengthMinutes"] == nil,
	"renamed later: server.dayLengthMinutes (60) from _retired becomes server.dayLength, and leaves _retired"
)

--== 4c. A value of the wrong type is kept, not silently replaced ==
f = json.decode(read(configFile))
f.server.paymentMax = "lots"
write(configFile, json.encode(f))
cfg = startServer()
check(
	cfg.server.paymentMax == 1000000 and cfg._retired["server.paymentMax"] == "lots",
	"wrong type: default used, old value under _retired"
)
check(logged("server.paymentMax = lots (expected a number)"), "console says why")
f = json.decode(read(configFile))
f.server.paymentMax = 2500
write(configFile, json.encode(f))
cfg = startServer()
check(
	cfg.server.paymentMax == 2500 and (cfg._retired or {})["server.paymentMax"] == nil,
	"fixed by hand: the stale retired value goes"
)

--== 4d. A setting that is dropped and comes back gets its old value ==
f = json.decode(read(configFile))
f.server.allowTeleport = true
write(configFile, json.encode(f))
cfg = startServer(function(src)
	return (src:gsub("\t\tallowTeleport = false,\n", "", 1))
end)
check(cfg.server.allowTeleport == nil and cfg._retired["server.allowTeleport"] == true, "dropped: value under _retired")
cfg = startServer()
check(
	cfg.server.allowTeleport == true and (cfg._retired or {})["server.allowTeleport"] == nil,
	"back again: the old value (true) returns"
)

--== 5. A broken file is not simply overwritten ==
write(configFile, "{ this is not json")
cfg = startServer()
check(read(configFile .. ".broken") == "{ this is not json", "broken config is backed up as .broken")
check(cfg.server.dayMinutes == 50, "server starts anyway with defaults")
os.remove(configFile .. ".broken")

--== 6. No setting disappears by accident (compared with the last release) ==
-- The DEFAULTS, RENAMED and REMOVED tables are read straight from the source text.
local function tableIn(src, name)
	local block = src:match("\nlocal " .. name .. " = (%b{})")
	return block and assert(load("return " .. block, name, "t", {}))() or nil
end
local current = assert(io.open("Resources/Server/CareerConvoy/main.lua")):read("*a")
local now, renamed, removed = tableIn(current, "DEFAULTS"), tableIn(current, "RENAMED"), tableIn(current, "REMOVED")
check(now and renamed and removed, "DEFAULTS, RENAMED and REMOVED can be read from main.lua")
for section, names in pairs(renamed or {}) do
	for new, old in pairs(names) do
		check(
			now[section] and now[section][new] ~= nil and now[section][old] == nil,
			string.format("RENAMED %s.%s <- %s: the new name exists, the old one is gone", section, new, old)
		)
	end
end
for section, names in pairs(removed or {}) do
	for old in pairs(names) do
		check(
			not (now[section] and now[section][old] ~= nil),
			"REMOVED " .. section .. "." .. old .. " is not in DEFAULTS any more"
		)
	end
end
local tagPipe = io.popen('git describe --tags --abbrev=0 --match "v*" HEAD 2>/dev/null')
local tag = tagPipe and tagPipe:read("*l")
if tagPipe then
	tagPipe:close()
end
local oldSource
if tag and tag ~= "" then
	local showPipe = io.popen("git show " .. tag .. ":Resources/Server/CareerConvoy/main.lua 2>/dev/null")
	oldSource = showPipe and showPipe:read("*a")
	if showPipe then
		showPipe:close()
	end
end
local before = oldSource and oldSource ~= "" and tableIn(oldSource, "DEFAULTS")
if not before then
	-- the release workflow checks out the tags; locally a clone without tags just skips this
	check(os.getenv("CI") ~= "true", "last release found (git tags) to compare the settings with")
	print("Config update: no release tag found – settings history not compared")
else
	local renamedTo = {}
	for section, names in pairs(renamed or {}) do
		for new, old in pairs(names) do
			renamedTo[section .. "." .. old] = section .. "." .. new
		end
	end
	for section, names in pairs(before) do
		for key, value in pairs(names) do
			local name = section .. "." .. key
			local stillThere = now[section] and now[section][key]
			if stillThere == nil then
				check(
					renamedTo[name] or (removed[section] and removed[section][key]),
					name
						.. " is gone since "
						.. tag
						.. ": add it to RENAMED (new name -> old name) or REMOVED in main.lua"
				)
			else
				check(
					type(stillThere) == type(value),
					name
						.. " changed its type since "
						.. tag
						.. " ("
						.. type(value)
						.. " -> "
						.. type(stillThere)
						.. "): give it a new name and list it in RENAMED"
				)
			end
		end
	end
end

os.remove(configFile)
os.remove(profilesFile)
print(string.format("Config update: %d ok, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
