-- SharedCareer :: BeamMP server plugin
--
-- Shared career mode for BeamMP: everyone plays the normal BeamNG career in a shared
-- world, each with their own save on their own PC.
--
-- The server is the go-between and referee:
--   * sends every player the settings on join; then the client starts the career
--   * assigns a fixed profile name per BeamMP account (config/profiles.json)
--   * keeps the list of which vehicles are visible/hidden or traffic, and distributes it
--   * splits the traffic amount fairly across all players
--   * runs the clock (time of day, day and night at different speeds) and the traffic light cycle
--   * handles money transfers between players in two steps (debit first, then credit)
--   * keeps the shared list of towing jobs (beta): every job goes to one player, is paid once
--
-- Only the BeamMP server API (MP.*, Util.*, FS.*), no game code.
--
-- FILES (Resources/Server/SharedCareer/config/)
--   config.json    settings (see DEFAULTS below) + the defaults the file was written
--                  with (_defaults; for automatic updates)
--   profiles.json  BeamMP account ID -> profile name
--   fuelprices.json station discounts from fuel deliveries (station -> fuel -> %)
--   payouts.json   pay of finished towing jobs the player's client hasn't confirmed yet
--
-- SERVER CONSOLE COMMANDS
--   sc help                           short help
--   sc get                            show all settings
--   sc set <server|client>.<name> <value>
--                                     change a setting; it is saved and client.* is sent to
--                                     all players immediately. Without <value> = empty text.
--   sc time                           show the current time and the day/night length
--   sc time <HH:MM | hour>            set the time for everyone, e.g. sc time 18:30
--   sc time stop | start              pause the clock (time stands still) / let it run again
--   sc players                        players and whether their career is running
--   sc fuel | sc fuel reset           show station discounts / reset all of them
--   sc jobs | sc jobs reset           show the towing jobs / drop all of them (new ones follow)
--   sc reload                         read config.json again
--
-- CHAT COMMANDS (for players; they are not shown in the chat)
--   /pay <name> <amount>              send money to a player (part of the name is enough)
--   /players                          who is here, who is still loading
--   /schelp                           help
--
-- MESSAGES BETWEEN CLIENT AND SERVER (all JSON)
--   Client -> Server                  Server -> Client
--   sc_hello            {version}     sc_config / sc_configUpdate   client settings
--   sc_careerResult     {ok, reason,  sc_vehStates   {"<pid>-<vid>": {active, traffic}}
--                        profile}     sc_traffic     {road, parked}  new traffic share
--   sc_vehReport        {id: {active, sc_time        {hour, play, dayLength, dayLengthDay,
--                        traffic}}                    dayLengthNight, dayStart, nightStart,
--                                                     dayMinutes, nightMinutes, canControl}
--   sc_vehStatesRequest               sc_signals     traffic light cycle (seconds)
--   sc_damage           {id, damage}  sc_damage      {id, damage} a vehicle's damage | {id, cleared = true}
--   sc_damageRequest    {id}          sc_damageRequest {id}  (to the owner) send it again
--   sc_couplings        {list = [{a, an, b, bn}]}   sc_couplings {pid, list}  a player's couplings
--   sc_payDebitResult   {id, ok}      sc_payDebit / sc_payCredit   money transfer
--   sc_payCreditAck     {id}
--   sc_timeControl      {action = "set", hour} | {action = "lengths", dayMinutes, nightMinutes}
--                       | {action = "pause", paused = true|false}
--   sc_setSetting       {key = "client.roadTraffic", value}  (menu, allowed settings only)
--   sc_status           {status = driving|walking|mission|loading}
--   Server -> Client: sc_dialog {title, body, warning}  message as a dialog in the menu window
--   Server -> Client: sc_players {players = [{id, name, status}]}  (Players tab, name tags)
--   sc_fuelDelivered    {station, fuel, amount, stationName}  own fuel delivery to a station
--   Server -> Client: sc_fuelPrices {enabled, factors = {[station] = {gasoline = 0.9, ...}}}
--   Towing jobs (beta, see "Towing jobs" below):
--   sc_jobsRequest                    sc_jobs        {enabled, jobs = [job, with state "open" |
--   sc_jobOffer   {a new job}                         "taken" | "mine", takenBy (name)]}
--   sc_jobTake    {id}                sc_jobGenerate {}  please make up a new job (sc_jobOffer)
--   sc_jobDone    {id, pay}           sc_jobPaid     {payout, job, pay, vehicle}  credit this
--   sc_jobGiveUp  {id}                               (again until sc_jobPaidAck)
--   sc_jobPaidAck {payout}
--                       (from the SharedCareer menu window)

local VERSION = "0.21.2"
local TAG = "[SharedCareer] "

local CONFIG_DIR = "Resources/Server/SharedCareer/config"
local CONFIG_FILE = CONFIG_DIR .. "/config.json"

local MAX_PAYLOAD = 16384 -- bytes; larger client messages are ignored

local DEFAULTS = {
	server = {
		-- money transfers between players via chat: /pay <name> <amount>
		allowPayments = true,
		paymentMax = 1000000,
		paymentCooldownSeconds = 5,
		-- kick a player whose career doesn't start (otherwise a notice dialog)
		kickOnFailedStart = false,
		-- same traffic light cycle for everyone (synced every 10 s)
		trafficSignalSync = true,
		-- Time of day: start time after a server start (hour 0–24, e.g. 10.5 = 10:30).
		-- Day (dayStartHour to nightStartHour) and night run at different speeds:
		-- dayMinutes / nightMinutes = real minutes for the whole day or night part.
		-- Either one at 0 = time stands still. While running: sc time 18:30
		startHour = 10,
		dayMinutes = 50,
		nightMinutes = 5,
		dayStartHour = 6,
		nightStartHour = 20,
		-- Every player may change the time and the day/night length in the SharedCareer menu;
		-- it applies to everyone immediately. false = console only (sc time).
		allowPlayerTimeControl = true,
		-- Every player may change the settings offered in the SharedCareer menu (Traffic /
		-- Options tabs) for everyone. false = console only.
		allowPlayerSettings = true,
		-- "Teleport" in the Players tab: jump with your own car to another player.
		-- Off by default, because in a career it skips driving and fuel costs.
		allowTeleport = false,
		-- Shared fuel prices: everyone pays the same price at a station (no random part),
		-- and whoever delivers gasoline/diesel there makes that fuel cheaper there for everyone.
		fuelEconomy = true,
		fuelLitersPerStep = 1000,     -- this many liters ...
		fuelDiscountPerStep = 5,      -- ... make the fuel at that station this many % cheaper
		fuelMaxDiscount = 30,         -- at most this many % cheaper
		fuelRecoveryPercent = 1,      -- the discount drops by this many percentage points ...
		fuelRecoveryMinutes = 5,      -- ... every this many minutes (the price slowly returns)
		-- Clock paused: the time stands still until someone presses "Resume" (window) or types
		-- sc time start. Pause: window or sc time stop.
		timePaused = false,
		-- Traffic for the whole server (0 = no limit). Every player gets
		-- client.roadTraffic / client.parkedTraffic until the sum exceeds the limit;
		-- then the limit is split evenly.
		roadTrafficTotal = 20,
		parkedTrafficTotal = 24,
		-- Towing jobs (beta): broken-down cars at the roadside, taken in the Jobs app on the phone
		-- and towed to a repair shop. One list for everyone, every job goes to one player.
		jobs = true,
		jobsOpen = 3,              -- this many open jobs at most (new ones are made up as needed)
		jobTimeoutMinutes = 30,    -- a taken job is open again after this many minutes
		jobPayMax = 5000,          -- the highest pay of one job, in $
	},
	client = {
		-- Appended to the profile name, e.g. "_myserver", so that every server gets its own
		-- save. Empty = the same save on every SharedCareer server.
		saveSuffix = "",
		-- Traffic that EVERY player spawns (driving / parked, 0–50 each). BeamMP shows it to
		-- everyone; the server limits roadTrafficTotal / parkedTrafficTotal apply on top.
		roadTraffic = 6,
		parkedTraffic = 8,
		-- Reserve: every player spawns this many extra cars (driving and parked) hidden on
		-- join. Up to that, the traffic amount can be raised LIVE in the menu; more only
		-- applies on the next join. Less always works live.
		-- Costs some loading time, because BeamMP builds hidden cars on every PC too.
		trafficReserve = 4,
		-- Other PLAYERS' cars without collision (true) or with (false). Does not apply to AI traffic:
		-- traffic/parked cars always collide, no matter who owns them.
		remoteVehicleGhost = false,
		-- Other players on foot (unicycle) without collision – so nobody can run anyone
		-- over by accident
		remoteUnicycleGhost = true,
		-- Other players' vehicles show the damage their owner sees (BeamMP itself only syncs
		-- parts that break off). The owner sends it once a crash is over.
		syncDamage = true,
		-- Spawn traffic as simplified vehicles ("simple_traffic"). Because BeamMP sends the
		-- owner's config to everyone, the traffic is then simple everywhere.
		trafficSimpleVehicles = true,
		-- Aggression of the traffic AI, 0.05 (very careful) to 1 (very aggressive).
		-- Lower = brakes earlier, keeps more distance. 0 = game default, don't change.
		-- The police are excluded. Can be changed live: sc set client.trafficAggression 0.15
		trafficAggression = 0.2,
		-- How much grip the traffic AI thinks its tires have (game default 0.95, range 0.5–0.95).
		-- Lower = brakes earlier and more gently at intersections and traffic lights, and takes
		-- corners more slowly. 0 = leave the game's value alone. Police are excluded.
		trafficGrip = 0.85,
		-- Traffic AI reacts earlier to vehicles on its path, without driving slower:
		-- safety gap in seconds (game 0.3, range 0.3–3) and how far ahead it looks:
		-- (speed + 10) * factor meters (game factor 3, range 3–8). 0 = game value.
		trafficReactionGap = 1.0,
		trafficSightRange = 5,
		-- Use garage computers from a distance: "Use computer" already appears at this
		-- distance (meters, half edge length of the zone). 0 = game default (right in front). Max 30.
		computerAccessRange = 6,
		-- same time of day from the server for everyone (otherwise everyone has their own)
		syncTimeOfDay = true,
		-- time, weather, slow motion and traffic in the pause menu are display-only
		lockEnvironment = true,
		-- On join, remove Mileage leftovers (red "Unknown app" boxes) from the players' UI
		-- layouts and bring back the BeamMP player list. Files are backed up first.
		cleanupMileageApps = true,
		-- Add the SharedCareer menu and the phone tab to the career layout automatically on the
		-- first join (once; players who remove them don't get them back).
		addApps = true,
		-- status after the players' names: [Mission], [On foot], [Loading]
		showPlayerStatus = true,
		-- welcome dialog on join with the most important features (everyone can choose "Don't show
		-- again"; a click on the steering-wheel logo in the menu shows it again)
		showWelcome = true,
		-- Additionally build the OTHER players' cars as simplified models locally (BeamMP feature,
		-- 17 standard models). For weak PCs; cars then look plainer.
		simplifyRemoteVehicles = false,
		-- Allow the Lua console (key ^ or ~) and the world editor in the game. Off = protection
		-- against cheating and against accidentally breaking the shared world.
		allowConsole = false,
		allowWorldEditor = false,
		-- Node grabber (grab and pull vehicles with the mouse) also in a vehicle and in the free
		-- camera. The normal career only allows it while walking. Makes cheating easy (flip cars,
		-- push cargo), but handy among friends. false = the career's own rule.
		allowNodeGrabber = true,
		-- Ropes with physics on the phone: the Tow app (rope and winch: move your own vehicles slowly,
		-- e.g. onto a tow truck) and the Straps app (hold a car on a trailer or truck). Own vehicles only.
		allowRopes = true,
		-- The phone (key F4, tab at the right screen edge) with the Jobs, Tow, Straps and Fuel apps.
		phone = true,
		-- How fast the winch in the Tow app hauls in at most, in m/s (0.2–5).
		winchSpeed = 1,
		-- Highest pull strength a player may pick in the Tow app, in % of the vehicle's weight
		-- (10–150). Below 100 you can lift one end and drag or push the vehicle, but not float it.
		winchStrength = 150,
		-- "Tow to the road" in the Tow app: the game's own recovery (puts the vehicle on the last
		-- road it drove on, the damage stays), free instead of the career's $75.
		allowTowToRoad = true,
		-- Pay of towing jobs: factor on the base pay (1 = normal, 2 = double).
		jobPay = 1,
	},
}

local Config
local Retired = {} -- "section.name" -> value of settings this version doesn't use (see mergeConfig)

-- player_id -> {name, counted (has received settings), careerActive, startFailed,
--               account (BeamMP ID or nil), guest, profile, lastPaymentAt}
local players = {}
-- "<player_id>-<vehicle_id>" -> {active = bool, traffic = bool|nil}
local vehicleStates = {}
-- "<player_id>-<vehicle_id>" -> the last sc_damage message (JSON) of that vehicle
local damageStates = {}
-- player_id -> the last sc_couplings message (JSON, with pid) of that player
local couplingStates = {}
-- transfer id -> {from, to, fromName, toName, amount, stage, createdAt}
local transfers = {}
local transferSeq = 0
-- player_id -> {road, parked} traffic share sent last
local sharesSent = {}
-- towing jobs: id -> job (see "Towing jobs")
local jobs = {}
local jobSeq = 0

local clock = MP.CreateTimer()

local function now()
	return clock:GetCurrent()
end

--== Helpers ===================================================================

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

-- Notification in the game (BeamMP notification). Also works when the chat isn't visible
-- in the career. Older servers without MP.SendNotification: chat.
local function notify(player_id, msg, icon)
	if type(MP.SendNotification) == "function" then
		local ok = pcall(MP.SendNotification, player_id, msg, icon or "info")
		if ok then return end
	end
	chat(player_id, msg)
end

-- Dialog with an OK button, for things the player must not miss. Shown by the
-- SharedCareer menu window (sc_dialog); plus a notification in case the window isn't
-- there right now (e.g. the career doesn't start). BeamMP's MP.ConfirmationDialog is
-- deliberately NOT used: in BeamNG 0.40 it led to the main menu instead of showing a dialog.
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

--== Configuration =============================================================

local function readFile(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local text = f:read("*a")
	f:close()
	return text
end

-- Writes `value` as readable JSON to a file in the config folder. Returns true if it worked.
local function writeJson(path, value)
	if FS and FS.CreateDirectory and not FS.Exists(CONFIG_DIR) then FS.CreateDirectory(CONFIG_DIR) end
	local text = encode(value)
	if Util.JsonPrettify then text = Util.JsonPrettify(text) end
	local f = io.open(path, "w")
	if not f then
		log("Could not write " .. path)
		return false
	end
	f:write(text)
	f:close()
	return true
end

-- Besides the settings, the file contains the defaults it was last written with
-- (_defaults). From that, loadConfig recognizes after an update which values are still
-- on the old default (-> they get the new one) and which someone changed (-> they stay).
-- That way simply installing an update is enough.
local function saveConfig()
	return writeJson(CONFIG_FILE, {server = Config.server, client = Config.client,
		_retired = next(Retired) and Retired or nil, _defaults = DEFAULTS, _version = VERSION})
end

--== Settings across versions ===================================================
-- On every start the loaded config.json is merged with DEFAULTS:
--   * a new setting gets its default
--   * a value still on the default of the version that wrote the file (_defaults) moves to the
--     new default; a value someone changed stays
--   * nothing is thrown away: a setting this version doesn't know (removed or renamed), or a
--     value of the wrong type, is kept in config.json under _retired ("section.name" -> value)
--     and reported on the console. A rename (RENAMED) takes its value from there too, even
--     several versions later, and so does a setting that comes back under its old name.
-- tests/config_update_test.lua compares DEFAULTS with the last release: a setting that is gone
-- must be listed in RENAMED (new name -> old name) or REMOVED, so no value is lost by accident.

-- settings that were renamed: new name -> old name (the old value is taken over once)
local RENAMED = {
	client = {
		addApps = "addTimeApp", -- 0.15.0
		allowRopes = "allowGrab", winchSpeed = "grabSpeed", winchStrength = "grabStrength", -- 0.22.0
	},
}

-- settings that were dropped on purpose: name -> why (their values stay under _retired)
local REMOVED = {
	server = {},
	client = {},
}

local function wasDefault(section, key, value, recorded)
	local rec = type(recorded) == "table" and type(recorded[section]) == "table" and recorded[section] or nil
	return rec ~= nil and rec[key] ~= nil and rec[key] == value
end

-- Merges the loaded file with DEFAULTS (see above). Returns the settings, the retired values,
-- the list of settings that moved to a new default and the list of newly retired ones.
local function mergeConfig(loaded)
	loaded = type(loaded) == "table" and loaded or {}
	local retired = {}
	if type(loaded._retired) == "table" then
		for name, value in pairs(loaded._retired) do retired[name] = value end
	end
	local result, updated, newlyRetired = {}, {}, {}
	local function retire(name, value, why)
		retired[name] = value
		table.insert(newlyRetired, string.format("%s = %s (%s)", name, tostring(value), why))
	end
	for section, defaults in pairs(DEFAULTS) do
		result[section] = {}
		local values = type(loaded[section]) == "table" and loaded[section] or {}
		local renamedFrom = {}
		for key, default in pairs(defaults) do
			local value = values[key]
			local oldKey = (RENAMED[section] or {})[key]
			if oldKey then
				renamedFrom[oldKey] = true
				local oldName = section .. "." .. oldKey
				if value == nil then value = values[oldKey] end
				if value == nil then value = retired[oldName] end
				retired[oldName] = nil
			end
			-- a setting that comes back gets its old value
			local name = section .. "." .. key
			if value == nil and retired[name] ~= nil and type(retired[name]) == type(default) then value = retired[name] end
			if value ~= nil and type(value) ~= type(default) then
				retire(name, value, "expected a " .. type(default))
				value = nil
			end
			if value == nil then
				result[section][key] = default
			elseif value ~= default and wasDefault(section, key, value, loaded._defaults) then
				result[section][key] = default
				table.insert(updated, string.format("%s.%s: %s -> %s", section, key, tostring(value), tostring(default)))
			else
				result[section][key] = value
			end
			if value ~= nil then retired[name] = nil end
		end
		for key, value in pairs(values) do
			if defaults[key] == nil and not renamedFrom[key] then
				retire(section .. "." .. key, value, "not used by this version")
			end
		end
	end
	table.sort(updated)
	table.sort(newlyRetired)
	return result, retired, updated, newlyRetired
end

local function loadConfig()
	local loaded = nil
	local text = readFile(CONFIG_FILE)
	if text then
		local ok, value = pcall(Util.JsonDecode, text)
		if ok and type(value) == "table" then
			loaded = value
		else
			-- Don't just overwrite a broken file: back it up so nothing gets lost.
			local backup = CONFIG_FILE .. ".broken"
			local f = io.open(backup, "w")
			if f then f:write(text); f:close() end
			log("config.json is not valid JSON – saved as config.json.broken, using default settings")
		end
	end
	local updated, newlyRetired
	Config, Retired, updated, newlyRetired = mergeConfig(loaded)
	if #updated > 0 then
		log("Update: " .. #updated .. " setting(s) moved to the new default (values you changed are kept):")
		for _, line in ipairs(updated) do log("  " .. line) end
	end
	if #newlyRetired > 0 then
		log("Update: " .. #newlyRetired .. " setting(s) this version doesn't use, kept in config.json under _retired:")
		for _, line in ipairs(newlyRetired) do log("  " .. line) end
	end
	saveConfig() -- new settings and defaults show up in the file automatically this way
end

--== Save game mapping =========================================================
-- The saves live locally on every PC; their name comes from the server. So that a rename
-- on BeamMP doesn't "lose" the save, the server remembers the profile name from the first
-- join per BeamMP account (config/profiles.json). Existing profiles simply keep working.
-- Guests have no account: their profile is tied to the guest name.
--

local PROFILES_FILE = CONFIG_DIR .. "/profiles.json"
local profiles = {} -- BeamMP account ID (string) -> profile name

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
	writeJson(PROFILES_FILE, next(profiles) and profiles or {})
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

-- Profile name for this player (without the server suffix; the client appends that).
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

--== Traffic shares ============================================================
-- Every player spawns their own traffic, and BeamMP shows it to everyone. So it doesn't get
-- too crowded with many players, there is a limit for the whole server
-- (server.roadTrafficTotal / parkedTrafficTotal). Up to the limit everyone gets the full
-- amount (client.roadTraffic / parkedTraffic); above it the limit is split evenly;
-- leftover cars go to the lowest player IDs. When the number of players changes, everyone
-- gets their new share immediately (sc_traffic).

-- Players who have already received settings, sorted by ID.
local function careerPlayerIds()
	local ids = {}
	for id, entry in pairs(players) do
		if entry.counted then table.insert(ids, id) end
	end
	table.sort(ids)
	return ids
end

-- A player's share: perPlayer each, until all together exceed `total`.
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

-- {road, parked} for this player.
local function trafficShareFor(player_id)
	local ids = careerPlayerIds()
	return {
		road = shareOf(Config.client.roadTraffic, Config.server.roadTrafficTotal, ids, player_id),
		parked = shareOf(Config.client.parkedTraffic, Config.server.parkedTrafficTotal, ids, player_id),
	}
end

-- Sends every player with a running career their new share if it changed.
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

--== Vehicle states ============================================================
-- The career often hides your own cars (garage, dealer, missions, the traffic reserve); BeamMP
-- doesn't sync that. So every client reports its own cars regularly (visible, traffic);
-- the server keeps the list (vehicleStates) and sends only real changes to everyone else.
-- New players get the whole list on join.

-- A client may only report its own vehicles ("<its player_id>-<vehicle_id>").
local function ownsVehicle(player_id, serverVehicleID)
	if type(serverVehicleID) ~= "string" then return false end
	local owner = serverVehicleID:match("^(%d+)%-%d+$")
	return owner ~= nil and tonumber(owner) == tonumber(player_id)
end

-- Sends states to everyone (except `except`, usually the sender).
local function broadcastStates(states, except)
	local data = encode(states)
	for id in pairs(players) do
		if id ~= except and MP.IsPlayerConnected(id) then
			MP.TriggerClientEvent(id, "sc_vehStates", data)
		end
	end
end

--== Time of day ===============================================================
-- The server runs the clock: timeState.hour was valid at time timeState.at. Day and night
-- run at their own speed (game hours per real second); the clock is computed ahead piece by
-- piece up to the next boundary (day start / night start). Players sync every 30 s and
-- switch to the other speed themselves when day/night changes.

local timeState = nil

-- {dayStart, nightStart, daySpeed, nightSpeed} or nil when time stands still.
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
		daySpeed = dayHours / (dayMin * 60),     -- game hours per real second
		nightSpeed = nightHours / (nightMin * 60),
	}
end

local function isDay(hour, ph)
	return hour >= ph.dayStart and hour < ph.nightStart
end

-- Time after `seconds` real seconds starting at `hour`.
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

-- Before changing the speed: pin the current time, otherwise it jumps.
local function rebaseTime()
	setHour(currentHour())
end

-- dayLength = length of a whole day in real seconds at the respective speed
-- (that's how BeamNG calculates); depending on the time, the client uses dayLengthDay or -Night.
local function timePayload()
	local ph = timePhases()
	local hour = currentHour()
	-- For the UI window: configured lengths and whether players may control them.
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

-- Pause/resume the clock. Pin the current time first, so it stops exactly there
-- or runs on from there.
local function setPaused(paused)
	if (Config.server.timePaused == true) == paused then return false end
	rebaseTime()
	Config.server.timePaused = paused
	saveConfig()
	return true
end

-- New time/lengths immediately to all players with a running career.
local function sendTimeToAll()
	for id, entry in pairs(players) do
		if entry.careerActive and MP.IsPlayerConnected(id) then sendTime(id) end
	end
end

--== Settings for one player ===================================================
-- What the client gets (sc_config on join, sc_configUpdate on changes): all client.*
-- settings, its traffic share, and under "ui" the server values that the SharedCareer
-- menu shows.

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
		jobs = Config.server.jobs == true,
		players = count,
	}
	return settings
end

-- New settings to everyone who is already playing.
local function sendSettingsToAll()
	for id, entry in pairs(players) do
		if entry.counted and MP.IsPlayerConnected(id) then
			local settings = settingsFor(id)
			sharesSent[id] = settings.trafficShare
			send(id, "sc_configUpdate", settings)
		end
	end
end

--== Fuel prices (shared economy) ==============================================
-- discounts[station][fuel] = discount in percent (0..fuelMaxDiscount). Station = ID of the
-- gas station as in the game (freeroam_facilities gasStations), fuel = "gasoline" | "diesel".
-- Saved in config/fuelprices.json, sent to everyone as sc_fuelPrices {enabled, factors}.
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
	writeJson(FUEL_FILE, next(fuelDiscounts) and fuelDiscounts or {})
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

-- A client reports its own fuel delivery: {station, fuel, amount, stationName?}
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

-- Every second: discounts drop slowly (prices return to the normal price).
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


--== Towing jobs (beta) =========================================================
-- The server keeps one list for everyone; the clients make the jobs up (they know the map: road
-- network, repair shops, vehicles) when the server asks one of them (sc_jobGenerate). A job goes
-- to the first player who takes it, is paid once (a payout, see "Payouts of towing jobs") and is
-- open again if that player leaves, gives up or runs out of time.
-- job = {id, vehicle = {model, config, name}, flatTire, pos = {x, y, z}, dir = {x, y},
--        dest = {name, pos = {x, y, z}}, length (m), pay, takenBy (player id), takenAt}
local JOB_ASK_EVERY = 15       -- s between two requests for a new job
local JOB_TEXT_MAX = 128
local jobAskedAt = -math.huge

local function jobsEnabled()
	return Config.server.jobs == true
end

local function vecOf(v, withZ)
	if type(v) ~= "table" then return nil end
	local x, y, z = tonumber(v.x), tonumber(v.y), tonumber(v.z)
	if not x or not y or x ~= x or y ~= y or (withZ and (not z or z ~= z)) then return nil end
	if math.abs(x) > 1e6 or math.abs(y) > 1e6 or (z and math.abs(z) > 1e6) then return nil end
	return {x = x, y = y, z = z}
end

local function text(v)
	if type(v) ~= "string" or v == "" then return nil end
	return v:sub(1, JOB_TEXT_MAX)
end

local function openJobCount()
	local n = 0
	for _, job in pairs(jobs) do if not job.takenBy then n = n + 1 end end
	return n
end

local function jobFor(job, player_id)
	return {id = job.id, vehicle = job.vehicle, flatTire = job.flatTire, pos = job.pos, dir = job.dir,
		dest = job.dest, length = job.length, pay = job.pay,
		state = job.takenBy == nil and "open" or (job.takenBy == player_id and "mine" or "taken"),
		takenBy = job.takenBy and playerName(job.takenBy) or nil}
end

local function jobsPayload(player_id)
	local list = {}
	if jobsEnabled() then
		for _, job in pairs(jobs) do table.insert(list, jobFor(job, player_id)) end
		table.sort(list, function(a, b) return a.id < b.id end)
	end
	return {enabled = jobsEnabled(), jobs = list}
end

local function sendJobs(player_id)
	send(player_id, "sc_jobs", jobsPayload(player_id))
end

local function sendJobsToAll()
	for id, entry in pairs(players) do
		if entry.careerActive and MP.IsPlayerConnected(id) then sendJobs(id) end
	end
end

local function reopenJob(job, why)
	local taker = job.takenBy
	job.takenBy, job.takenAt = nil, nil
	log(string.format("job %d is open again (%s)", job.id, why))
	if taker and MP.IsPlayerConnected(taker) then notify(taker, "Towing job cancelled: " .. why, "warning") end
end

function sc_jobsRequest(player_id)
	local entry = players[player_id]
	if entry and entry.careerActive then sendJobs(player_id) end
end

-- A client made up a job (after sc_jobGenerate).
function sc_jobOffer(player_id, data)
	local entry = players[player_id]
	local msg = decodeTable(data)
	if not entry or not entry.careerActive or not msg or not jobsEnabled() then return end
	if openJobCount() >= math.max(0, tonumber(Config.server.jobsOpen) or 3) then return end
	local v, dest = msg.vehicle, msg.dest
	local pos, dir = vecOf(msg.pos, true), vecOf(msg.dir)
	local destPos = type(dest) == "table" and vecOf(dest.pos, true)
	local model = type(v) == "table" and text(v.model)
	local length, pay = tonumber(msg.length), tonumber(msg.pay)
	if not (pos and dir and destPos and model and length and pay) or length ~= length or pay ~= pay then return end
	jobSeq = jobSeq + 1
	local job = {
		id = jobSeq,
		vehicle = {model = model, config = text(v.config), name = text(v.name) or model},
		flatTire = msg.flatTire == true,
		pos = pos, dir = dir,
		dest = {name = text(dest.name) or "Repair shop", pos = destPos},
		length = math.max(0, math.min(1e5, length)),
		pay = math.floor(math.max(0, math.min(tonumber(Config.server.jobPayMax) or 5000, pay)) + 0.5),
	}
	jobs[job.id] = job
	log(string.format("new towing job %d: %s to %s, $%d", job.id, job.vehicle.name, job.dest.name, job.pay))
	sendJobsToAll()
end

function sc_jobTake(player_id, data)
	local entry = players[player_id]
	local msg = decodeTable(data)
	local job = msg and jobs[tonumber(msg.id)]
	if not entry or not entry.careerActive or not job or not jobsEnabled() then return end
	if job.takenBy then
		if job.takenBy ~= player_id then notify(player_id, playerName(job.takenBy) .. " took that job first") end
		sendJobs(player_id)
		return
	end
	for _, other in pairs(jobs) do
		if other.takenBy == player_id then
			notify(player_id, "Finish your job first", "warning")
			sendJobs(player_id)
			return
		end
	end
	job.takenBy, job.takenAt = player_id, now()
	log(string.format("%s took towing job %d", playerName(player_id), job.id))
	sendJobsToAll()
end

function sc_jobGiveUp(player_id, data)
	local msg = decodeTable(data)
	local job = msg and jobs[tonumber(msg.id)]
	if not job or job.takenBy ~= player_id then return end
	job.takenBy, job.takenAt = nil, nil
	log(string.format("%s gave up towing job %d", playerName(player_id), job.id))
	sendJobsToAll()
end

--== Payouts of towing jobs ===================================================
-- A finished job becomes a payout for the taker's save (profile). It is kept in
-- config/payouts.json and sent (sc_jobPaid) until that player's client confirms that it credited
-- and saved it (sc_jobPaidAck): every PAYOUT_RESEND s while they play, and at once on their next
-- career start. So a crash, a lost connection or a loading screen never costs the pay; the
-- client credits each payout id only once.
-- payout = {id (string, unique across server restarts), job (job id), pay, profile, vehicle, sentAt}
local PAYOUTS_FILE = CONFIG_DIR .. "/payouts.json"
local PAYOUT_RESEND = 10
local payouts = {}
local payoutSeq = 0

local function savePayouts()
	local stored = {}
	for id, p in pairs(payouts) do
		stored[id] = {job = p.job, pay = p.pay, profile = p.profile, vehicle = p.vehicle}
	end
	writeJson(PAYOUTS_FILE, stored)
end

local function loadPayouts()
	local raw = readFile(PAYOUTS_FILE)
	if not raw then return end
	local ok, value = pcall(Util.JsonDecode, raw)
	if not ok or type(value) ~= "table" then
		local f = io.open(PAYOUTS_FILE .. ".broken", "w")
		if f then f:write(raw); f:close() end
		log("payouts.json is not valid JSON – saved as payouts.json.broken, open towing payouts are not sent")
		return
	end
	payouts = {}
	for id, p in pairs(value) do
		local pay = type(p) == "table" and tonumber(p.pay)
		if type(id) == "string" and pay and pay >= 0 and type(p.profile) == "string" then
			payouts[id] = {id = id, job = tonumber(p.job), pay = pay, profile = p.profile, vehicle = text(p.vehicle)}
		end
	end
end

local function sendPayout(player_id, p)
	p.sentAt = now()
	send(player_id, "sc_jobPaid", {payout = p.id, job = p.job, pay = p.pay, vehicle = p.vehicle})
end

-- Sends this player every payout of their save that is still open.
local function deliverPayouts(player_id)
	local entry = players[player_id]
	if not entry or not entry.careerActive or not entry.profile then return end
	for _, p in pairs(payouts) do
		if p.profile == entry.profile then sendPayout(player_id, p) end
	end
end

-- Every second: payouts without confirmation go out again.
local function payoutsTick()
	if not next(payouts) then return end
	local byProfile = {}
	for id, entry in pairs(players) do
		if entry.careerActive and entry.profile and MP.IsPlayerConnected(id) then byProfile[entry.profile] = id end
	end
	for _, p in pairs(payouts) do
		local id = byProfile[p.profile]
		if id and now() - (p.sentAt or -math.huge) >= PAYOUT_RESEND then sendPayout(id, p) end
	end
end

-- The client credited and saved a payout: {payout}
function sc_jobPaidAck(player_id, data)
	local entry = players[player_id]
	local msg = decodeTable(data)
	local p = msg and type(msg.payout) == "string" and payouts[msg.payout]
	if not entry or not p or p.profile ~= entry.profile then return end
	payouts[p.id] = nil
	savePayouts()
	log(string.format("%s received $%d for towing job %s", playerName(player_id), p.pay, tostring(p.job)))
end

-- The vehicle is at the repair shop: {id, pay} (pay after the deduction for new damage). Paid once,
-- at most the job's pay.
function sc_jobDone(player_id, data)
	local entry = players[player_id]
	local msg = decodeTable(data)
	local job = msg and jobs[tonumber(msg.id)]
	if not entry or not job or job.takenBy ~= player_id then return end
	local pay = math.floor(math.max(0, math.min(job.pay, tonumber(msg.pay) or job.pay)) + 0.5)
	jobs[job.id] = nil
	payoutSeq = payoutSeq + 1
	local p = {id = string.format("%d-%d-%d", os.time(), job.id, payoutSeq), job = job.id, pay = pay,
		profile = entry.profile or sanitizeProfile(playerName(player_id)), vehicle = job.vehicle.name}
	payouts[p.id] = p
	savePayouts()
	sendPayout(player_id, p)
	log(string.format("%s finished towing job %d: $%d", playerName(player_id), job.id, pay))
	for id, e in pairs(players) do
		if e.careerActive and MP.IsPlayerConnected(id) and id ~= player_id then
			notify(id, string.format("%s towed a %s to %s", playerName(player_id), job.vehicle.name, job.dest.name), "local_shipping")
		end
	end
	sendJobsToAll()
end

-- Every second: taken jobs that ran out of time are open again; if jobs are missing, one
-- player (in turn) is asked to make one up.
local function jobsTick()
	if not jobsEnabled() then return end
	local timeout = math.max(1, tonumber(Config.server.jobTimeoutMinutes) or 30) * 60
	local changed = false
	for _, job in pairs(jobs) do
		if job.takenBy and now() - job.takenAt > timeout then
			reopenJob(job, "out of time")
			changed = true
		end
	end
	if changed then sendJobsToAll() end
	if openJobCount() >= math.max(0, tonumber(Config.server.jobsOpen) or 3) then return end
	if now() - jobAskedAt < JOB_ASK_EVERY then return end
	local ids = {}
	for id, entry in pairs(players) do
		if entry.careerActive and MP.IsPlayerConnected(id) then table.insert(ids, id) end
	end
	if #ids == 0 then return end
	table.sort(ids)
	jobAskedAt = now()
	send(ids[(jobSeq + math.floor(now())) % #ids + 1], "sc_jobGenerate", {})
end

local function jobsLeave(player_id)
	local changed = false
	for _, job in pairs(jobs) do
		if job.takenBy == player_id then
			reopenJob(job, playerName(player_id) .. " left")
			changed = true
		end
	end
	if changed then sendJobsToAll() end
end

--== Player list (Players tab, status on name tags) ============================
-- Every client reports its status (sc_status); the server sends the list to everyone
-- (sc_players) on join, career start, status change and leave.
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

--== Events from the client ====================================================

-- The client is ready (map loaded) and wants the settings.
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

	-- The same account twice at the same time would save into the same profile.
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
	for _, damage in pairs(damageStates) do MP.TriggerClientEvent(player_id, "sc_damage", damage) end
	for _, couplings in pairs(couplingStates) do MP.TriggerClientEvent(player_id, "sc_couplings", couplings) end
	-- On a full server the others get their smaller share immediately.
	updateTrafficShares()
	broadcastPlayers()
end

-- Result of the career start: {ok = true} or {ok = false, reason = "..."}
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
		sendJobs(player_id)
		deliverPayouts(player_id)
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

-- The sender's own vehicles: {["<pid>-<vid>"] = {active = bool, traffic = bool}, ...}
function sc_vehReport(player_id, data)
	local report = decodeTable(data)
	if not report then return end
	local changed = {}
	for id, reported in pairs(report) do
		local state = vehicleStates[id]
		if type(reported) == "table" and state and ownsVehicle(player_id, id) then
			local differs = false
			if type(reported.active) == "boolean" and state.active ~= reported.active then
				state.active, differs = reported.active, true
			end
			if type(reported.traffic) == "boolean" and state.traffic ~= reported.traffic then
				state.traffic, differs = reported.traffic, true
			end
			if differs then changed[id] = state end
		end
	end
	if next(changed) then broadcastStates(changed, player_id) end
end

function sc_vehStatesRequest(player_id)
	if players[player_id] then send(player_id, "sc_vehStates", vehicleStates) end
end

--== Damage ====================================================================
-- BeamMP only syncs parts that break off. So every owner sends the damage of its vehicles once a
-- crash is over (sc_damage, see damage.lua); the server passes it on and keeps the latest one per
-- vehicle for players who join later. A player whose copy of a vehicle crashed where the owner's
-- didn't asks the owner for it (sc_damageRequest).

function sc_damage(player_id, data)
	local msg = decodeTable(data)
	if not msg or type(msg.damage) ~= "table" or not ownsVehicle(player_id, msg.id) or not vehicleStates[msg.id] then return end
	damageStates[msg.id] = data
	for id in pairs(players) do
		if id ~= player_id and MP.IsPlayerConnected(id) then MP.TriggerClientEvent(id, "sc_damage", data) end
	end
end

-- A new, rebuilt or deleted vehicle has no damage: the others forget the old one (the server id
-- may be used again for another vehicle).
local function clearDamage(id)
	if not damageStates[id] then return end
	damageStates[id] = nil
	local data = encode({id = id, cleared = true})
	for pid in pairs(players) do
		if MP.IsPlayerConnected(pid) then MP.TriggerClientEvent(pid, "sc_damage", data) end
	end
end

function sc_damageRequest(player_id, data)
	local msg = decodeTable(data)
	local owner = msg and type(msg.id) == "string" and tonumber(msg.id:match("^(%d+)%-%d+$"))
	if owner and owner ~= tonumber(player_id) and players[owner] and MP.IsPlayerConnected(owner) then
		send(owner, "sc_damageRequest", {id = msg.id})
	end
end

--== Couplings ===================================================================
-- BeamMP sends a coupling (trailer, dolly) only once; copies that miss it stay uncoupled. Every
-- client reports the couplings of its own vehicles (sc_couplings, see couplings.lua); the server
-- passes each player's list on and keeps it for players who join later.

local function broadcastCouplings(player_id, data)
	for id in pairs(players) do
		if id ~= player_id and MP.IsPlayerConnected(id) then MP.TriggerClientEvent(id, "sc_couplings", data) end
	end
end

-- {list = {{a = "<pid>-<vid>", an = node, b = "<pid>-<vid>", bn = node}, ...}}: every coupling
-- must involve one of the sender's vehicles
function sc_couplings(player_id, data)
	local msg = decodeTable(data)
	if not msg or type(msg.list) ~= "table" then return end
	local list = {}
	for _, p in ipairs(msg.list) do
		if type(p) == "table" and tonumber(p.an) and tonumber(p.bn)
			and (ownsVehicle(player_id, p.a) or ownsVehicle(player_id, p.b))
			and type(p.a) == "string" and type(p.b) == "string" then
			table.insert(list, {a = p.a, an = tonumber(p.an), b = p.b, bn = tonumber(p.bn)})
		end
	end
	local out = encode({pid = player_id, list = list})
	couplingStates[player_id] = out
	broadcastCouplings(player_id, out)
end

-- Control from the SharedCareer menu window (every player, if allowed):
--   {action = "set", hour = 0..24}                               set the time for everyone
--   {action = "lengths", dayMinutes = 1..600, nightMinutes = 1..600}  day/night length
--   {action = "pause", paused = true|false}                       pause / resume the clock
-- At most one change per second and player; everyone gets a notification.
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
		rebaseTime() -- pin the time, only the speed changes
		Config.server.dayMinutes, Config.server.nightMinutes = day, night
		saveConfig()
		log(string.format("%s sets day/night to %d/%d min", playerName(player_id), day, night))
		sendTimeToAll()
		notifyAll(string.format("%s: day %d min, night %d min", playerName(player_id), day, night), "schedule")
	end
end

--== Money transfers ===========================================================
-- 1. /pay in chat -> server checks -> sender gets sc_payDebit
-- 2. sender client checks its money, debits, answers sc_payDebitResult
-- 3. server -> receiver gets sc_payCredit and confirms with sc_payCreditAck
-- If the receiver disappears before that, the sender gets the money back.

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
				-- The sender never answered: nothing was debited (or they are gone).
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

--== Chat and console commands =================================================
-- Chat: /pay, /players, /schelp (or /help). If the function returns 1, BeamMP doesn't show
-- the message in the chat. Normal chat messages stay untouched.
-- Console: everything starting with "sc" (see the overview at the top of the file).

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
	"  sc jobs | sc jobs reset             show towing jobs / drop all of them",
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

-- "sc set": check the value (same type as the default), save it and make it effective.
-- client.*: immediately to all players (sc_configUpdate). Exception: saveSuffix only applies
-- on the next join, because the profile is chosen at the career start.
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
	if section == "server" and key:sub(1, 3) == "job" then sendJobsToAll() end
	-- Live update for everyone who is already playing (also contains the new traffic shares).
	-- Start options like saveSuffix only apply on the next join.
	sendSettingsToAll()
	return path .. " = " .. tostring(value)
end

--== Settings from the SharedCareer menu =======================================
-- Only these settings may be changed by a player in the menu (if server.allowPlayerSettings);
-- each applies to everyone immediately. Values are checked and clamped.
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
	elseif sub == "jobs" then
		if words[3] and words[3]:lower() == "reset" then
			jobs = {}
			sendJobsToAll()
			return "Towing jobs dropped (new ones follow)"
		end
		local lines = {}
		for _, job in pairs(jobs) do
			table.insert(lines, string.format("  #%d %s to %s, %.1f km, $%d%s", job.id, job.vehicle.name, job.dest.name,
				job.length / 1000, job.pay, job.takenBy and (" – taken by " .. playerName(job.takenBy)) or " – open"))
		end
		for _, p in pairs(payouts) do
			table.insert(lines, string.format("  payout $%d for %s to save %s – not confirmed yet", p.pay,
				tostring(p.vehicle), p.profile))
		end
		table.sort(lines)
		if #lines == 0 then return "Towing jobs: none" .. (jobsEnabled() and "" or " (switched off)") end
		return "Towing jobs:\n" .. table.concat(lines, "\n")
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

--== BeamMP events =============================================================
-- Triggered by BeamMP itself (join, leave, vehicles).

-- Connection established; the career only starts after sc_hello / sc_careerResult.
function onPlayerJoin(player_id)
	players[player_id] = {name = MP.GetPlayerName(player_id), careerActive = false}
end

-- Clean up: vehicle states, open transfers (refund if needed), traffic shares.
function onPlayerDisconnect(player_id)
	local prefix = tostring(player_id) .. "-"
	for id in pairs(vehicleStates) do
		if id:sub(1, #prefix) == prefix then vehicleStates[id] = nil end
	end
	for id in pairs(damageStates) do
		if id:sub(1, #prefix) == prefix then damageStates[id] = nil end
	end
	for id, transfer in pairs(transfers) do
		if transfer.to == player_id and transfer.stage == "credit" then
			refund(transfer, transfer.toName .. " left the server.")
		elseif transfer.from == player_id then
			-- Sender gone: in stage "debit" nothing has been credited yet -> discard.
			-- In stage "credit" the credit continues normally.
			if transfer.stage ~= "credit" then transfers[id] = nil end
		end
	end
	if couplingStates[player_id] then
		couplingStates[player_id] = nil
		broadcastCouplings(player_id, encode({pid = player_id, list = {}}))
	end
	jobsLeave(player_id)
	players[player_id] = nil
	sharesSent[player_id] = nil
	updateTrafficShares()
	broadcastPlayers()
end

-- New vehicle: visible; the owner reports afterwards whether it is traffic.
function onVehicleSpawn(player_id, vehicle_id, data)
	local id = player_id .. "-" .. vehicle_id
	vehicleStates[id] = {active = true}
	clearDamage(id)
	broadcastStates({[id] = vehicleStates[id]})
end

-- A newly built car is active again, for everyone.
function onVehicleEdited(player_id, vehicle_id, data)
	local id = player_id .. "-" .. vehicle_id
	local state = vehicleStates[id] or {}
	state.active = true
	clearDamage(id) -- a rebuilt vehicle is undamaged
	vehicleStates[id] = state
	broadcastStates({[id] = state})
end

function onVehicleDeleted(player_id, vehicle_id)
	vehicleStates[player_id .. "-" .. vehicle_id] = nil
	clearDamage(player_id .. "-" .. vehicle_id)
end

--== Timers ====================================================================
-- sc_signalTick every 10 s (traffic lights), sc_timeTick every 30 s (time of day),
-- sc_tick every second (time limits for transfers, fuel discounts, towing jobs).

function sc_signalTick()
	if not Config.server.trafficSignalSync then return end
	local data = tostring(now())
	for id, entry in pairs(players) do
		if entry.careerActive and MP.IsPlayerConnected(id) then
			MP.TriggerClientEvent(id, "sc_signals", data)
		end
	end
end

-- Time sync every 30 s; in between, the day runs on by itself on every player's PC.
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
	jobsTick()
	payoutsTick()
end

function onInit()
	loadConfig()
	loadProfiles()
	loadFuel()
	loadPayouts()

	MP.RegisterEvent("onPlayerJoin", "onPlayerJoin")
	MP.RegisterEvent("onPlayerDisconnect", "onPlayerDisconnect")
	MP.RegisterEvent("onVehicleSpawn", "onVehicleSpawn")
	MP.RegisterEvent("onVehicleEdited", "onVehicleEdited")
	MP.RegisterEvent("onVehicleDeleted", "onVehicleDeleted")
	MP.RegisterEvent("onChatMessage", "onChatMessage")
	MP.RegisterEvent("onConsoleInput", "onConsoleInput")

	MP.RegisterEvent("sc_hello", "sc_hello")
	MP.RegisterEvent("sc_careerResult", "sc_careerResult")
	MP.RegisterEvent("sc_vehReport", "sc_vehReport")
	MP.RegisterEvent("sc_damage", "sc_damage")
	MP.RegisterEvent("sc_damageRequest", "sc_damageRequest")
	MP.RegisterEvent("sc_couplings", "sc_couplings")
	MP.RegisterEvent("sc_vehStatesRequest", "sc_vehStatesRequest")
	MP.RegisterEvent("sc_timeControl", "sc_timeControl")
	MP.RegisterEvent("sc_setSetting", "sc_setSetting")
	MP.RegisterEvent("sc_status", "sc_status")
	MP.RegisterEvent("sc_fuelDelivered", "sc_fuelDelivered")
	MP.RegisterEvent("sc_payDebitResult", "sc_payDebitResult")
	MP.RegisterEvent("sc_payCreditAck", "sc_payCreditAck")
	MP.RegisterEvent("sc_jobsRequest", "sc_jobsRequest")
	MP.RegisterEvent("sc_jobOffer", "sc_jobOffer")
	MP.RegisterEvent("sc_jobTake", "sc_jobTake")
	MP.RegisterEvent("sc_jobGiveUp", "sc_jobGiveUp")
	MP.RegisterEvent("sc_jobDone", "sc_jobDone")
	MP.RegisterEvent("sc_jobPaidAck", "sc_jobPaidAck")

	MP.RegisterEvent("sc_signalTick", "sc_signalTick")
	MP.RegisterEvent("sc_tick", "sc_tick")
	MP.RegisterEvent("sc_timeTick", "sc_timeTick")
	MP.CreateEventTimer("sc_signalTick", 10000)
	MP.CreateEventTimer("sc_tick", 1000)
	MP.CreateEventTimer("sc_timeTick", 30000)

	log("Version " .. VERSION .. " loaded. Console: sc help")
end
