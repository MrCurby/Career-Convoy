-- Client-Tests: BeamNG/BeamMP-Umgebung nachgebaut, die echten Mod-Dateien geladen.
-- Ausführen (LuaJIT wie im Spiel):  luajit tests/client_test.lua

package.path = "./tests/?.lua;" .. package.path
local json = require("json")

local ROOT = "client/lua/ge/extensions/"
local clock = 0
local failures, passed = 0, 0
local function check(cond, msg)
	if cond then passed = passed + 1 else failures = failures + 1; print("FEHLER: " .. msg) end
end

--== Spielwelt-Attrappe =========================================================

local sentToServer, handlers, toasts, loadingScreens

local function newVehicle(id, jbeam)
	local v = {id = id, JBeam = jbeam or "pickup", active = true, dyn = {}, lua = {}, deleted = false}
	function v:getID() return self.id end
	function v:getActive() return self.active end
	function v:setActive(a) self.active = (a == 1 or a == true) end
	function v:delete() self.deleted = true end
	function v:setDynDataFieldbyName(k, _, val) self.dyn[k] = val end
	function v:getDynDataFieldbyName(k) return self.dyn[k] end
	function v:setField() end
	function v:queueLuaCommand(cmd) table.insert(self.lua, cmd) end
	return v
end

local world -- {objects = {veh...}, mp = {serverId -> entry}, own = {gameId=true}}

local function resetWorld()
	clock = 0
	sentToServer, handlers, toasts = {}, {}, {}
	loadingScreens = {}
	world = {objects = {}, mp = {}, own = {}, playerVeh = nil}

	_G.log = function() end
	_G.jsonEncode = json.encode
	_G.jsonDecode = json.decode
	_G.deepcopy = function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
	_G.setExtensionUnloadMode = function() end
	os.clockhp = function() return clock end
	_G.FS = {fileExists = function() return true end}
	_G.guihooks = {trigger = function(_, data) table.insert(toasts, data) end}
	_G.TriggerServerEvent = function(event, data) table.insert(sentToServer, {event = event, data = data ~= "" and json.decode(data) or {}}) end
	_G.AddEventHandler = function(event, fn) handlers[event] = fn end
	_G.MPCoreNetwork = {isMPSession = function() return true end}
	_G.MPConfig = {getNickname = function() return "Max Mustermann_99" end}
	_G.MPVehicleGE = {
		getVehicles = function() return world.mp end,
		isOwn = function(id) return world.own[id] == true end,
		getServerVehicleID = function(id)
			for sid, e in pairs(world.mp) do if e.gameVehicleID == id then return sid end end
		end,
	}
	_G.be = {
		getObjectCount = function() return #world.objects end,
		getObject = function(_, i) return world.objects[i + 1] end,
		getObjectByID = function(_, id)
			for _, v in ipairs(world.objects) do if v.id == id and not v.deleted then return v end end
		end,
		getPlayerVehicleID = function() return world.playerVeh end,
		enterVehicle = function(_, _, veh) world.playerVeh = veh.id end,
		enterNextVehicle = function() end,
	}
	-- be:getObject(i) wird mit Doppelpunkt aufgerufen
	local rawGet = be.getObject
	be.getObject = function(self, i) return rawGet(self, i) end
	_G.getPlayerVehicle = function(p) return be:getObjectByID(world.playerVeh) end
	_G.core_gamestate = {
		getLoadingStatus = function(tag) return loadingScreens[tag] == true end,
		requestExitLoadingScreen = function(tag) loadingScreens[tag] = nil end,
	}
	_G.gameplay_traffic = {
		getTrafficList = function() return {} end,
		setupTrafficHelper = function(road, opts, parked) world.trafficSetup = {road, opts, parked} end,
		setActiveAmount = function(n) world.activeRoad = n end,
		getTrafficData = function() return {} end,
	}
	_G.gameplay_parking = {setActiveAmount = function(n) world.activeParked = n end, getParkedCarsList = function() return {} end}
	_G.core_vehicles = {
		removeAll = function() for _, v in ipairs(world.objects) do v:delete() end end,
		replaceVehicle = function(model, opt, other)
			-- So verhält sich BeamMPs Ersatz: baut getPlayerVehicle(0) neu, nicht "other"
			local target = getPlayerVehicle(0)
			world.rebuilt = target and target.id
			return target
		end,
		spawnNewVehicle = function(model, opt) world.spawned = {model, opt} end,
	}
	_G.career_career = nil
	_G.career_modules_playerAttributes = nil
	_G.career_modules_inventory = nil
	_G.career_saveSystem = {saveCurrent = function() world.saved = (world.saved or 0) + 1 end}
	_G.worldReadyState = 0
	local store = {trafficSimpleVehicles = false, simplifyRemoteVehicles = false}
	_G.settings = {
		getValue = function(k) return store[k] end,
		setValue = function(k, v) store[k] = v end,
	}

	-- Erweiterungssystem
	local loaded = {}
	local order = {}
	_G.extensions = {}
	function extensions.getLoadedExtensionsNames() return order end
	function extensions.hookUpdate() end
	function extensions.hook(name, ...)
		for _, extName in ipairs(order) do
			local m = loaded[extName]
			if type(m[name]) == "function" then m[name](...) end
		end
	end
	_G.load = function(path)
		local name = path:gsub("/", "_")
		local m = assert(loadfile(ROOT .. path .. ".lua"))()
		loaded[name] = m
		extensions[name] = m
		_G[name] = m
		table.insert(order, name)
		if m.onExtensionLoaded then m.onExtensionLoaded() end
	end
	_G.registerExtension = function(name, m)
		loaded[name] = m; extensions[name] = m; _G[name] = m; table.insert(order, name)
	end
	assert(loadfile("client/scripts/sharedCareer/modScript.lua"))()
end

local function addVehicle(gameId, serverId, own, jbeam)
	local v = newVehicle(gameId, jbeam)
	table.insert(world.objects, v)
	world.mp[serverId] = {gameVehicleID = gameId, jbeam = v.JBeam}
	if own then world.own[gameId] = true end
	return v
end

local function lastSent(event)
	for i = #sentToServer, 1, -1 do
		if sentToServer[i].event == event then return sentToServer[i].data end
	end
end

-- Karriere-Attrappe, die sich wie career.lua verhält (removeAll beim Aktivieren).
local function installCareer(opts)
	opts = opts or {}
	local active = false
	_G.career_career = {
		startingOptions = {},
		isActive = function() return active end,
		createOrLoadCareerAndStart = function(name, folder, options)
			world.careerArgs = {name = name, folder = folder, options = options}
			if opts.fail then error("kaputt") end
			extensions.hook("onBeforeCareerActivate")
			core_vehicles.removeAll() -- removeVehicles == true
			loadingScreens.careerActivate = true
			loadingScreens.careerVehicles = true
			gameplay_traffic.setupTrafficHelper(10, {}, 10)
			gameplay_traffic.setActiveAmount(10) -- die Karriere überschreibt mit eigenen Werten
			if not opts.hang then
				active = true
				extensions.hook("onCareerActive", true)
				loadingScreens.careerActivate = nil
				if not opts.trafficHang then loadingScreens.careerVehicles = nil end
			end
			return true
		end,
	}
	local money = opts.money or 1000
	_G.career_modules_playerAttributes = {
		getAttribute = function(k) return k == "money" and {value = money} or nil end,
		addAttributes = function(change) money = money + (change.money or 0) end,
		money = function() return money end,
	}
end

local function update(dt)
	clock = clock + (dt or 0.1)
	extensions.hook("onUpdate", dt or 0.1)
end

local config = {saveSuffix = "_srv", trafficShare = {road = 4, parked = 3},
	remoteVehicleGhost = true, remoteUnicycleGhost = true, allowConsole = false, serverVersion = "0.8.4",
	trafficSimpleVehicles = true, simplifyRemoteVehicles = true}

--== 1. Join: Karriere startet, fremde Autos überleben ==========================
resetWorld()
installCareer()
local mine = addVehicle(1, "0-0", true)
local theirs = addVehicle(2, "1-0", false)
extensions.hook("onWorldReadyState", 2)
check(lastSent("sc_hello") ~= nil, "Hello nach World-Ready gesendet")
handlers.sc_config(json.encode(config))
check(world.careerArgs.name == "maxmustermann99srv", "Profilname bereinigt: " .. tostring(world.careerArgs.name))
check(type(world.careerArgs.options) == "table" and world.careerArgs.options.startMode == "freshStart",
	"Startoptionen als Tabelle mit freshStart")
check(world.careerArgs.folder == false, "kein fester Spielstand-Ordner")
check(theirs.deleted == false, "fremdes Auto überlebt Karrierestart")
check(mine.deleted == true, "eigenes altes Auto wird von der Karriere entfernt")
check(world.trafficSetup[1] == 4 and world.trafficSetup[3] == 3, "Server-Traffic an die Karriere übergeben")
check(world.trafficSetup[2].simpleVehs == true, "Traffic spawnt als simple vehicles")
check(settings.getValue("trafficSimpleVehicles") == true, "Spiel-Einstellung trafficSimpleVehicles gesetzt")
check(settings.getValue("simplifyRemoteVehicles") == true, "BeamMP-Einstellung simplifyRemoteVehicles gesetzt")
update()
check(world.activeRoad == 4, "Server-Traffic überschreibt die Karriere-Einstellung danach")
check(lastSent("sc_careerResult") and lastSent("sc_careerResult").ok == true, "Erfolg an Server gemeldet")
update(); update()
local saved = core_vehicles.removeAll
check(saved ~= nil, "removeAll vorhanden")
core_vehicles.removeAll()
check(theirs.deleted == true, "nach dem Start ist removeAll wieder das Original")

--== 1b. Profilname kommt vom Server (pro Account) ===========================
resetWorld()
installCareer()
extensions.hook("onWorldReadyState", 2)
local cfgP = {}
for k, v in pairs(config) do cfgP[k] = v end
cfgP.profileBase = "anna"
handlers.sc_config(json.encode(cfgP))
check(world.careerArgs.name == "annasrv", "Server-Profil + Suffix statt BeamMP-Name: " .. tostring(world.careerArgs.name))
update()
check(lastSent("sc_careerResult").profile == "annasrv", "Profilname an den Server gemeldet")

--== 2. Start hängt im Ladebildschirm -> Freigabe nach Timeout ==================
resetWorld()
installCareer({trafficHang = true})
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
for _ = 1, 50 do update(0.1) end
check(lastSent("sc_careerResult") == nil, "noch kein Ergebnis während der Start läuft")
for _ = 1, 600 do update(0.1) end
check(loadingScreens.careerVehicles == nil, "hängender Ladebildschirm freigegeben")
check(lastSent("sc_careerResult").ok == true, "Karriere lief -> trotzdem Erfolg")

--== 3. Start wirft Fehler -> Fehlschlag gemeldet ================================
resetWorld()
installCareer({fail = true})
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
local result = lastSent("sc_careerResult")
check(result and result.ok == false and tostring(result.reason):find("kaputt"), "Fehler wird gemeldet")
check(core_vehicles.removeAll ~= nil and #toasts > 0, "Spieler sieht Fehlermeldung")

--== 4. Karriere-Modul kommt erst später ========================================
resetWorld()
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
check(world.careerArgs == nil, "wartet auf career_career")
installCareer()
update()
check(world.careerArgs ~= nil, "startet sobald career_career da ist")

--== 5. Ein kaputter onCareerActive-Handler stoppt die anderen nicht =============
resetWorld()
local ran = {}
registerExtension("career_modules_a", {onCareerActive = function() error("boom") end})
registerExtension("career_modules_b", {onCareerActive = function() ran.b = true end})
installCareer()
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
check(ran.b == true, "Handler nach dem fehlerhaften läuft trotzdem")
check(sharedCareer_protect.getFailures()[1] == "career_modules_a", "Fehler wird protokolliert")
update()
local ok = pcall(extensions.hook, "onCareerActive", true)
check(not ok, "nach dem Start ist der Schutz wieder weg (Spielverhalten unverändert)")

--== 6. Garage: das richtige Auto wird neu gebaut ================================
resetWorld()
installCareer()
local walker = addVehicle(10, "0-1", true, "unicycle")
local car = addVehicle(11, "0-2", true)
local remote = addVehicle(12, "1-3", false)
world.playerVeh = 10
update(1.1) -- Patches werden angelegt
core_vehicles.replaceVehicle("pickup", {}, car)
check(world.rebuilt == 11, "genanntes Auto neu gebaut, nicht der Fußgänger (war " .. tostring(world.rebuilt) .. ")")
check(getPlayerVehicle(0).id == 10, "getPlayerVehicle danach wieder normal")
_G.career_modules_inventory = {getInventoryIdFromVehicleId = function(id) if id == 12 then return 7 end end}
world.rebuilt = nil
check(core_vehicles.replaceVehicle("pickup", {}, remote) == nil and world.rebuilt == nil,
	"Inventar-Auto, das nicht uns gehört, wird nicht angefasst")
_G.career_modules_inventory = {getInventoryIdFromVehicleId = function() return nil end}
core_vehicles.replaceVehicle("pickup", {}, remote)
check(world.rebuilt == 10, "fremde Nicht-Inventar-Autos gehen unverändert an BeamMP")
for _ = 1, 5 do update(1.1) end
local depth = 0
local fn = core_vehicles.replaceVehicle
check(sharedCareer_util.isOurs(fn), "Wrapper sitzt")
-- Neu geladenes Modul (neue Funktion) wird wieder eingewickelt, aber nie doppelt
core_vehicles.replaceVehicle = function(m, o, other) world.rebuilt = getPlayerVehicle(0).id end
update(1.1)
local w1 = core_vehicles.replaceVehicle
update(1.1)
check(w1 == core_vehicles.replaceVehicle and sharedCareer_util.isOurs(w1), "kein doppeltes Einwickeln")

-- Unicycle sichtbar
core_vehicles.spawnNewVehicle("unicycle", {config = "vehicles/unicycle/without_mesh.pc"})
check(world.spawned[2].config == "vehicles/unicycle/beammp_default.pc", "sichtbarer Fußgänger im MP")

--== 6b. Computer aus der Nähe benutzen =======================================
resetWorld()
installCareer()
local function V(x, y, z) return {x = x, y = y, z = z} end
_G.vec3 = V
local sceneObjects = {
	servicestationGarageComputer_area_1 = {pos = V(0, 0, 0), scl = V(1.5, 1, 1)},
	servicestationGarageComputer_icon_1 = {pos = V(0, 0, 1), scl = V(1, 1, 1)},
	dealer_area_1 = {pos = V(50, 0, 0), scl = V(2, 2, 1)},
	dealer_icon_1 = {pos = V(50, 0, 1), scl = V(1, 1, 1)},
}
_G.scenetree = {findObject = function(name)
	local o = sceneObjects[name]
	if not o then return nil end
	return {getPosition = function() return V(o.pos.x, o.pos.y, o.pos.z) end, getScale = function() return o.scl end}
end}
-- Nachbau der Spielklasse: setup baut die Kästen einmal aus den Szenenobjekten
local C = {}
function C:init() self.visible = true end
function C:setup(cluster)
	self.cluster = cluster
	self.doors = {}
	for _, ntuple in ipairs(cluster.doors) do
		local area = scenetree.findObject(ntuple[1])
		local scl = area:getScale()
		table.insert(self.doors, {areaPos = area:getPosition(), xVec = V(scl.x, 0, 0), yVec = V(0, scl.y, 0), zVec = V(0, 0, scl.z)})
	end
end
function C:update() self.updated = true end
local markerModule = {create = function() local o = setmetatable({}, C); C.__index = C; o:init(); return o end}
package.loaded["gameplay/markers/walkingMarker"] = markerModule
local function len(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end
-- Ein Marker, den das Spiel schon VOR unserem Patch gebaut hat
local existing = markerModule.create()
existing:setup({doors = {{"servicestationGarageComputer_area_1", "servicestationGarageComputer_icon_1"}}})
local dealer = markerModule.create()
dealer:setup({doors = {{"dealer_area_1", "dealer_icon_1"}}})
extensions.hook("onWorldReadyState", 2)
local cfgC = {}
for k, v in pairs(config) do cfgC[k] = v end
cfgC.computerAccessRange = 6
handlers.sc_config(json.encode(cfgC))
update(1.1)
existing:update(); dealer:update()
check(existing.updated == true, "Original-Methode läuft weiter")
check(len(existing.doors[1].xVec) == 6 and len(existing.doors[1].yVec) == 6, "Computer-Zone auf 6 m vergrößert (alter Marker)")
check(len(existing.doors[1].zVec) == 2.5, "Zone hoch genug für Treppen/Rampen")
check(len(dealer.doors[1].xVec) == 2, "andere Zonen (Händler) bleiben unverändert")
-- neuer Marker nach dem Patch
local fresh = markerModule.create()
fresh:setup({doors = {{"servicestationGarageComputer_area_1", "servicestationGarageComputer_icon_1"}}})
fresh:update()
check(len(fresh.doors[1].xVec) == 6, "neue Marker werden auch vergrößert")
-- live auf 0 -> Original zurück
cfgC.computerAccessRange = 0
handlers.sc_configUpdate(json.encode(cfgC))
existing:update()
check(len(existing.doors[1].xVec) == 1.5 and len(existing.doors[1].yVec) == 1, "0 stellt die Originalgröße wieder her")
-- kein doppeltes Einwickeln
local f1 = C.update
update(1.1); update(1.1)
check(C.update == f1, "Marker-Methoden nicht doppelt eingewickelt")
package.loaded["gameplay/markers/walkingMarker"] = nil

--== 7. Fahrzeug-Sichtbarkeit ===================================================
resetWorld()
installCareer()
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
local own = addVehicle(20, "0-5", true)
local other = addVehicle(21, "1-5", false)
extensions.hook("onVehicleSpawned", 21)
update(1.1)
check(other.dyn.ignoreTraffic == "true", "fremdes Auto wird vom eigenen Traffic ignoriert")

-- Regression: eigener Traffic, den BeamMP noch nicht registriert hat (isOwn == false),
-- darf NICHT als fremd markiert werden – sonst steht der Traffic still.
local freshTraffic = newVehicle(30)
table.insert(world.objects, freshTraffic)
extensions.hook("onVehicleSpawned", 30)
update(1.1)
check(freshTraffic.dyn.ignoreTraffic == nil, "frisch gespawnter eigener Traffic bleibt fahrbereit")
-- BeamMP trägt das Auto als lokal ein, die Server-Bestätigung (isOwn) fehlt noch
world.mp["0-9"] = {gameVehicleID = 30, jbeam = "simple_traffic", isLocal = true}
update(1.1)
check(freshTraffic.dyn.ignoreTraffic == nil, "lokales, noch unbestätigtes Auto bleibt fahrbereit")
world.own[30] = true
update(1.1)
check(freshTraffic.dyn.ignoreTraffic == nil, "bestätigtes eigenes Auto bleibt fahrbereit")
handlers.sc_vehStates(json.encode({["1-5"] = {active = false, traffic = true}}))
check(other.active == false, "vom Server verstecktes Auto wird versteckt")
check(world.mp["1-5"].hideNametag == true, "Namensschild versteckt")
handlers.sc_vehStates(json.encode({["1-5"] = {active = true, traffic = false}}))
check(other.active == true and world.mp["1-5"].hideNametag == false, "wieder sichtbar")
extensions.hook("onVehicleActiveChanged", 20, false)
local msg = lastSent("sc_vehActive")
check(msg and msg.id == "0-5" and msg.active == false, "eigenes Verstecken an Server")
own.dyn = {}
own.isTraffic = "true"
update(1.1)
check(lastSent("sc_vehMarks") and lastSent("sc_vehMarks")["0-5"] == true, "eigenes Traffic-Auto markiert")
local ghostCmd = other.lua[#other.lua]
check(ghostCmd and ghostCmd:find("setGhost%(true%)"), "Ghost nach Server-Einstellung")
-- Traffic eines Mitspielers: immer mit Kollision, auch wenn Spieler-Autos ohne sind
local remoteTraffic = addVehicle(22, "1-6", false)
handlers.sc_vehStates(json.encode({["1-6"] = {active = true, traffic = true}}))
update(1.1)
local lastGhost = remoteTraffic.lua[#remoteTraffic.lua]
check(lastGhost and lastGhost:find("setGhost%(false%)"), "Traffic anderer Spieler hat immer Kollision")
check(other.lua[#other.lua]:find("setGhost%(true%)"), "Spieler-Auto bleibt ohne Kollision (Einstellung)")
-- wird ein Auto erst später als Traffic markiert, wechselt es auf Kollision
local laterTraffic = addVehicle(23, "1-7", false)
handlers.sc_vehStates(json.encode({["1-7"] = {active = true}}))
update(1.1)
check(laterTraffic.lua[#laterTraffic.lua]:find("setGhost%(true%)"), "unmarkiertes fremdes Auto: Spieler-Einstellung")
handlers.sc_vehStates(json.encode({["1-7"] = {active = true, traffic = true}}))
update(1.1)
check(laterTraffic.lua[#laterTraffic.lua]:find("setGhost%(false%)"), "nach Traffic-Markierung: Kollision")

--== 7b. Vorsichtigere KI ======================================================
resetWorld()
installCareer()
extensions.hook("onWorldReadyState", 2)
local cfgAi = {}
for k, v in pairs(config) do cfgAi[k] = v end
cfgAi.trafficAggression = 0.2
handlers.sc_config(json.encode(cfgAi))
local carA = addVehicle(40, "0-40", true)
local cop = addVehicle(41, "0-41", true)
local mineAi = addVehicle(42, "0-42", true)
world.playerVeh = 42
gameplay_traffic.getTrafficData = function()
	return {[40] = {isAi = true}, [41] = {isAi = true, role = {name = "police"}}, [42] = {isAi = true}}
end
update(3.1)
local function aggr(v)
	for i = #v.lua, 1, -1 do
		local x = v.lua[i]:match("setAggression%(([%d%.]+)%)")
		if x then return tonumber(x) end
	end
end
local function aggrCount(v)
	local c = 0
	for _, cmd in ipairs(v.lua) do if cmd:find("setAggression") then c = c + 1 end end
	return c
end
check(aggr(carA) == 0.2, "Traffic bekommt vorsichtigere Aggressivität")
check(aggr(cop) == nil, "Polizei bleibt unverändert")
check(aggr(mineAi) == nil, "das Auto des Spielers wird nicht angefasst")
local n = aggrCount(carA)
update(3.1)
check(aggrCount(carA) == n, "kein Spam: nicht jede Prüfung neu gesendet")
cfgAi.trafficAggression = 0.1
handlers.sc_configUpdate(json.encode(cfgAi))
update(3.1)
check(aggr(carA) == 0.1, "Live-Änderung vom Server greift")
cfgAi.trafficAggression = 0
handlers.sc_configUpdate(json.encode(cfgAi))
n = aggrCount(carA)
update(3.1); update(10)
check(aggrCount(carA) == n, "0 = KI wird nicht verändert")

--== 7c. Tageszeit und Pausemenü =============================================
resetWorld()
installCareer()
local env = sharedCareer_env
check(env.toGame(12) == 0 and env.toGame(18) == 0.25 and env.toGame(0) == 0.5 and env.toGame(6) == 0.75,
	"Umrechnung Stunde -> BeamNG (0 = Mittag)")
check(env.fromGame(0.75) == 6 and env.hourDistance(23.9, 0.1) < 0.21, "Rückrechnung und Abstand über Mitternacht")
local tod = {time = env.toGame(9), play = false, dayLength = 1800, azimuthOverride = 0}
local setCalls = 0
_G.core_environment = {
	getTimeOfDay = function() return tod end,
	setTimeOfDay = function(t) setCalls = setCalls + 1; tod = t end,
}
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
handlers.sc_time(json.encode({hour = 18, dayLength = 3600, play = true}))
check(math.abs(tod.time - 0.25) < 1e-9 and tod.play == true and tod.dayLength == 3600, "Server-Uhrzeit übernommen")
check(tod.azimuthOverride == 0, "andere Zeit-Einstellungen bleiben erhalten")
local calls = setCalls
handlers.sc_time(json.encode({hour = 18.02, dayLength = 3600, play = true}))
check(setCalls == calls, "kleine Abweichung (1 min) -> kein Sprung")
handlers.sc_time(json.encode({hour = 20, dayLength = 3600, play = true}))
check(setCalls == calls + 1 and math.abs(env.fromGame(tod.time) - 20) < 1e-9, "große Abweichung wird korrigiert")
local cfgT = {}
for k, v in pairs(config) do cfgT[k] = v end
cfgT.syncTimeOfDay = false
handlers.sc_configUpdate(json.encode(cfgT))
calls = setCalls
handlers.sc_time(json.encode({hour = 3, dayLength = 3600, play = true}))
check(setCalls == calls, "abgeschaltet -> Uhrzeit bleibt beim Spieler")

-- Tag/Nacht-Tempo: beim Wechsel um 20 Uhr stellt der Client selbst um
cfgT.syncTimeOfDay = true
handlers.sc_configUpdate(json.encode(cfgT))
local msgDN = {hour = 19.99, play = true, dayLength = 4628, dayLengthDay = 4628, dayLengthNight = 2160, dayStart = 6, nightStart = 20}
handlers.sc_time(json.encode(msgDN))
check(tod.dayLength == 4628 and tod.play == true, "tagsüber Tagestempo")
check(env.lengthFor(msgDN, 23) == 2160 and env.lengthFor(msgDN, 5.9) == 2160 and env.lengthFor(msgDN, 6) == 4628,
	"Tag/Nacht-Grenzen richtig")
tod.time = env.toGame(20.01) -- Spiel ist selbst über 20 Uhr gelaufen
update(1.1)
check(tod.dayLength == 2160, "ab 20 Uhr Nachttempo, ohne Server-Nachricht")
check(math.abs(env.fromGame(tod.time) - 20.01) < 1e-6, "Umstellen verändert die Uhrzeit nicht")
calls = setCalls
update(1.1)
check(setCalls == calls, "kein ständiges Neusetzen")

-- UI-Fenster: Stand und Steuerung
local uiEvents = {}
_G.guihooks = {trigger = function(name, data) if name == "SharedCareerTime" then table.insert(uiEvents, data) end end}
handlers.sc_time(json.encode({hour = 19.5, play = true, dayLength = 3600, dayLengthDay = 3600, dayLengthNight = 720,
	dayStart = 6, nightStart = 20, dayMinutes = 50, nightMinutes = 5, canControl = true}))
local ui = uiEvents[#uiEvents]
check(ui and ui.connected and ui.canControl and ui.isDay == true, "Fenster bekommt Stand (Tag, darf steuern)")
check(ui and math.abs(ui.secondsToSwitch - 0.5 * 3600 / 24) < 1, "Zeit bis zur Nacht richtig (0,5 Std = 75 s)")
check(ui.dayMinutes == 50 and ui.nightMinutes == 5, "Längen fürs Fenster")
local n = #uiEvents
update(1.1)
check(#uiEvents > n, "Fenster wird jede Sekunde aktualisiert")
env.uiShiftHour(1)
local ctl = lastSent("sc_timeControl")
check(ctl and ctl.action == "set" and math.abs(ctl.hour - 20.5) < 0.01, "+1 Std geht an den Server")
env.uiShiftHour(-21)
check(math.abs(lastSent("sc_timeControl").hour - 22.5) < 0.01, "Rechnen über Mitternacht")
env.uiSetLengths(45, 10)
ctl = lastSent("sc_timeControl")
check(ctl.action == "lengths" and ctl.dayMinutes == 45 and ctl.nightMinutes == 10, "Längen gehen an den Server")

-- Uhr angehalten
env.uiSetPaused(true)
check(lastSent("sc_timeControl").action == "pause" and lastSent("sc_timeControl").paused == true, "Stopp geht an den Server")
handlers.sc_time(json.encode({hour = 15, play = false, paused = true, dayLength = 0, dayStart = 6, nightStart = 20,
	dayMinutes = 50, nightMinutes = 5, canControl = true}))
check(tod.play == false and math.abs(env.fromGame(tod.time) - 15) < 1e-6, "angehalten: Spieluhr steht bei 15 Uhr")
check(uiEvents[#uiEvents].paused == true, "Fenster weiß, dass die Uhr steht")
local setsPaused = setCalls
update(1.1); update(1.1)
check(setCalls == setsPaused, "angehalten: kein Tempo-Umstellen")

-- Pausemenü-Sperre
local seen = {}
_G.ui_pause_providers_routeData_environment = {
	getEnvironmentData = function() return {locked = settings.getValue("restrictScenarios") == true} end,
	getEnvironmentWeatherData = function() return {locked = settings.getValue("restrictScenarios") == true} end,
	requestEnvironmentTrafficPayload = function(p) seen.editable = p.editable end,
}
handlers.sc_configUpdate(json.encode(config))
update(1.1)
local pause = ui_pause_providers_routeData_environment
check(pause.getEnvironmentData().locked == true and pause.getEnvironmentWeatherData().locked == true,
	"Zeit/Wetter im Pausemenü gesperrt")
check(settings.getValue("restrictScenarios") ~= true, "Sperre gilt nur während der Seite, nicht global")
pause.requestEnvironmentTrafficPayload({editable = true})
check(seen.editable == false, "Traffic-Seite nur lesbar")
cfgT.lockEnvironment = false
cfgT.syncTimeOfDay = true
handlers.sc_configUpdate(json.encode(cfgT))
check(pause.getEnvironmentData().locked == false, "lockEnvironment = false gibt das Menü frei")
_G.ui_pause_providers_routeData_environment = nil
_G.core_environment = nil

--== 7d. Mileage-Reste aufräumen =============================================
resetWorld()
installCareer()
local files = {}
local function deep(t) return json.decode(json.encode(t)) end
_G.FS = {
	fileExists = function(_, path) return files[path] ~= nil end,
	findFiles = function(_, dir, pattern)
		local out = {}
		for path in pairs(files) do
			if path:sub(1, #dir) == dir and path:match("%.uilayout%.json$") then table.insert(out, path) end
		end
		table.sort(out)
		return out
	end,
}
_G.jsonReadFile = function(path) return files[path] and deep(files[path]) or nil end
_G.jsonWriteFile = function(path, data) files[path] = deep(data); return true end
local listPlacement = {right = "0px", top = "240px", width = "300px", height = "560px"}
files["/settings/ui_apps/layouts/default/career.uilayout.json"] = {apps = {
	{appName = "tacho2"},
	{appName = "beammpChat"},
	{appName = "mileageplayerlist", placement = listPlacement},
	{appName = "mileageoffers"},
	{appName = "mileagerace"},
}}
files["/settings/ui_apps/layouts/default/freeroam.uilayout.json"] = {apps = {
	{appName = "beammpPlayerListVue"}, {appName = "mileageplayerlist"},
}}
files["/settings/ui_apps/layouts/default/eigenes.uilayout.json"] = {apps = {{appName = "tacho2"}}}
local toastsBefore = #toasts
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
local career = files["/settings/ui_apps/layouts/default/career.uilayout.json"]
local names = {}
for _, app in ipairs(career.apps) do names[#names + 1] = app.appName end
check(table.concat(names, ",") == "tacho2,beammpChat,beammpPlayerListVue", "Mileage-Apps weg, BeamMP-Spielerliste zurück: " .. table.concat(names, ","))
check(career.apps[3].placement.top == "240px", "BeamMP-Liste an der Stelle der Mileage-Liste")
local free = files["/settings/ui_apps/layouts/default/freeroam.uilayout.json"]
check(#free.apps == 1 and free.apps[1].appName == "beammpPlayerListVue", "keine doppelte Spielerliste")
check(files["/settings/ui_apps/layouts/default/career.uilayout.json.sharedcareer-backup"].apps[3].appName == "mileageplayerlist",
	"Original wird vorher gesichert")
check(files["/settings/ui_apps/layouts/default/eigenes.uilayout.json.sharedcareer-backup"] == nil,
	"unveränderte Layouts werden nicht angefasst")
check(#toasts > toastsBefore, "Spieler bekommt Hinweis")
check(sharedCareer_cleanup.run() == 0, "zweiter Lauf findet nichts mehr")
-- abgeschaltet
resetWorld()
installCareer()
local findCalls = 0
_G.FS = {fileExists = function() return false end, findFiles = function() findCalls = findCalls + 1; return {} end}
local cfgOff = {}
for k, v in pairs(config) do cfgOff[k] = v end
cfgOff.cleanupMileageApps = false
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(cfgOff))
update()
check(lastSent("sc_careerResult") and lastSent("sc_careerResult").ok == true and findCalls == 0, "abgeschaltet: Aufräumen läuft nicht")

--== 7e. Tageszeit-Fenster einmalig ins Karriere-Layout ======================
local function joinWith(filesInit, cfgChange)
	resetWorld()
	installCareer()
	files = filesInit
	_G.FS = {
		fileExists = function(_, path) return files[path] ~= nil end,
		findFiles = function() return {} end,
	}
	_G.jsonReadFile = function(path) return files[path] and deep(files[path]) or nil end
	_G.jsonWriteFile = function(path, data) files[path] = deep(data); return true end
	local c = {}
	for k, v in pairs(config) do c[k] = v end
	for k, v in pairs(cfgChange or {}) do c[k] = v end
	extensions.hook("onWorldReadyState", 2)
	handlers.sc_config(json.encode(c))
	update()
end
local CUSTOM = "settings/ui_apps/layouts/default/career.uilayout.json"
local ORIGINAL = "settings/ui_apps/originalLayouts/default/career.uilayout.json"
local function hasTimeApp(layout)
	for _, a in ipairs(layout and layout.apps or {}) do if a.appName == "sharedCareerTime" then return true end end
	return false
end
-- 1) Spieler ohne eigenes Karriere-Layout: Original + Fenster
joinWith({[ORIGINAL] = {apps = {{appName = "tacho2"}}, title = "career"}})
check(hasTimeApp(files[CUSTOM]) and files[CUSTOM].apps[1].appName == "tacho2", "Fenster ins Karriere-Layout (aus Original)")
check(files[CUSTOM].apps[2].placement.top == "600px", "Platz rechts unter der Spielerliste")
check(files["settings/sharedCareer/state.json"].timeAppAdded == true, "gemerkt: schon hinzugefügt")
-- 2) Spieler entfernt es wieder -> beim nächsten Join NICHT erneut
local removedLayout = {apps = {{appName = "tacho2"}}}
joinWith({[CUSTOM] = removedLayout, ["settings/sharedCareer/state.json"] = {timeAppAdded = true}})
check(not hasTimeApp(files[CUSTOM]), "entferntes Fenster wird nicht wieder aufgedrängt")
-- 3) eigenes Layout bleibt erhalten, Sicherung wird angelegt
joinWith({[CUSTOM] = {apps = {{appName = "meineApp"}}}})
check(files[CUSTOM].apps[1].appName == "meineApp" and hasTimeApp(files[CUSTOM]), "eigenes Layout bleibt, Fenster kommt dazu")
check(files[CUSTOM .. ".sharedcareer-backup"].apps[1].appName == "meineApp", "Sicherung des eigenen Layouts")
-- 4) schon vorhanden (selbst hinzugefügt) -> nicht doppelt
joinWith({[CUSTOM] = {apps = {{appName = "sharedCareerTime"}}}})
local timeCount, fuelCount = 0, 0
for _, a in ipairs(files[CUSTOM].apps) do
	if a.appName == "sharedCareerTime" then timeCount = timeCount + 1 end
	if a.appName == "sharedCareerFuel" then fuelCount = fuelCount + 1 end
end
check(timeCount == 1 and fuelCount == 1, "Menü nicht doppelt, Fuel-App kommt dazu")
-- Fuel-App: eigener Merker – wer nur die Fuel-App entfernt, bekommt sie nicht wieder
joinWith({[CUSTOM] = {apps = {{appName = "sharedCareerTime"}}},
	["settings/sharedCareer/state.json"] = {timeAppAdded = true, fuelAppAdded = true}})
check(#files[CUSTOM].apps == 1, "entfernte Fuel-App wird nicht wieder aufgedrängt")
-- Update von 0.7.1: Menü schon da (Merker gesetzt), Fuel-App noch nie -> wird einmal ergänzt
joinWith({[CUSTOM] = {apps = {{appName = "sharedCareerTime"}}},
	["settings/sharedCareer/state.json"] = {timeAppAdded = true}})
local fuelApp
for _, a in ipairs(files[CUSTOM].apps) do if a.appName == "sharedCareerFuel" then fuelApp = a end end
check(fuelApp and fuelApp.placement.right == "0px" and files["settings/sharedCareer/state.json"].fuelAppAdded == true,
	"Fuel-App beim Update einmal an den rechten Rand gesetzt")
-- Layout aus 0.7.2: Fuel-App 350 px links vom Menü -> einmal an den Rand verschieben
joinWith({[CUSTOM] = {apps = {{appName = "sharedCareerTime", placement = {right = "0px", top = "600px"}},
	{appName = "sharedCareerFuel", placement = {right = "350px", top = "600px"}}}},
	["settings/sharedCareer/state.json"] = {timeAppAdded = true, fuelAppAdded = true}})
check(files[CUSTOM].apps[2].placement.right == "0px" and files[CUSTOM].apps[2].placement.top == "760px",
	"alte Fuel-Position (350 px) an den Rand, unter das Menü verschoben")
check(files[CUSTOM].apps[1].placement.top == "600px", "Menü bleibt, wo es ist")
-- Layout aus 0.8.0–0.8.3: Fuel-App genau über dem Menü (verdeckte die Lenkrad-Lasche) -> darunter
joinWith({[CUSTOM] = {apps = {{appName = "sharedCareerTime", placement = {right = "0px", top = "600px"}},
	{appName = "sharedCareerFuel", placement = {right = "0px", top = "600px"}}}},
	["settings/sharedCareer/state.json"] = {timeAppAdded = true, fuelAppAdded = true, fuelAppAtEdge = true}})
check(files[CUSTOM].apps[2].placement.top == "760px" and files["settings/sharedCareer/state.json"].fuelAppBelowMenu == true,
	"Fuel-App liegt nicht mehr über dem Menü")
check(files["settings/sharedCareer/state.json"].fuelAppAtEdge == true, "Verschieben gemerkt (nur einmal)")
-- selbst verschoben (nicht 350 px) -> bleibt, wo der Spieler sie hingestellt hat
joinWith({[CUSTOM] = {apps = {{appName = "sharedCareerFuel", placement = {right = "120px", top = "300px"}}}},
	["settings/sharedCareer/state.json"] = {timeAppAdded = true, fuelAppAdded = true}})
check(files[CUSTOM].apps[1].placement.right == "120px", "eigene Position des Spielers bleibt")
-- 5) abgeschaltet
joinWith({[ORIGINAL] = {apps = {}}}, {addTimeApp = false})
check(files[CUSTOM] == nil, "addTimeApp = false: nichts hinzugefügt")
-- 6) kein Layout gefunden -> nichts kaputt, später erneut versuchen
joinWith({})
check(files["settings/sharedCareer/state.json"] == nil and lastSent("sc_careerResult").ok == true,
	"ohne Layout: Karriere startet, Versuch beim nächsten Mal")

--== 7f. Menü: Traffic live mit Reserve ======================================
resetWorld()
installCareer()
local activeRoad, activeParked
gameplay_traffic.setActiveAmount = function(n) activeRoad = n end
gameplay_parking.setActiveAmount = function(n) activeParked = n end
local cfgM = {}
for k, v in pairs(config) do cfgM[k] = v end
cfgM.trafficReserve = 4
cfgM.roadTraffic, cfgM.parkedTraffic = 4, 3
cfgM.ui = {allowPlayerSettings = true, roadTrafficTotal = 20, players = 1}
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(cfgM))
update()
check(world.trafficSetup[1] == 8 and world.trafficSetup[3] == 7, "Vorrat = Anteil + Reserve (4+4 / 3+4) gespawnt")
check(activeRoad == 4 and activeParked == 3, "aktiv nur der Anteil, Reserve versteckt")
-- jemand stellt im Menü mehr ein: Server schickt neuen Anteil
cfgM.trafficShare = {road = 7, parked = 2}
handlers.sc_configUpdate(json.encode(cfgM))
check(activeRoad == 7 and activeParked == 2, "live mehr/weniger innerhalb des Vorrats")
cfgM.trafficShare = {road = 20, parked = 20}
handlers.sc_configUpdate(json.encode(cfgM))
check(activeRoad == 8 and activeParked == 7, "mehr als der Vorrat: begrenzt (Rest beim nächsten Join)")
-- Menü sofort aktualisiert, wenn jemand anderes etwas ändert
local menuPushes = {}
_G.guihooks = {trigger = function(name, data) if name == "SharedCareerTime" then table.insert(menuPushes, data) end end}
cfgM.roadTraffic = 9
handlers.sc_configUpdate(json.encode(cfgM))
check(#menuPushes == 1 and menuPushes[1].settings.roadTraffic == 9, "Menü zeigt Änderung eines anderen sofort (ohne Sekundentakt)")
local st = sharedCareer_menu.settingsState()
check(st.poolRoad == 8 and st.poolParked == 7 and st.canEdit == true and st.shareRoad == 20, "Menü kennt Vorrat und Anteil")
sharedCareer_menu.uiSetSetting("client.roadTraffic", 9)
check(lastSent("sc_setSetting").key == "client.roadTraffic" and lastSent("sc_setSetting").value == 9, "Menü sendet Einstellung")
local n2 = #sentToServer
sharedCareer_menu.uiSetSetting("client.saveSuffix", "x")
check(#sentToServer == n2, "Menü sendet nur erlaubte Einstellungen")

--== 7g. Players: Navigate, Watch, Teleport, Status, Namensschilder, Taste ====
resetWorld()
installCareer()
local mpCalls = {}
MPVehicleGE.groundmarkerFollowPlayer = function(name) table.insert(mpCalls, {"nav", name}) end
MPVehicleGE.focusCameraOnPlayer = function(name) table.insert(mpCalls, {"watch", name}) end
MPVehicleGE.teleportVehToPlayer = function(name) table.insert(mpCalls, {"tp", name}) end
local suffixes = {}
MPVehicleGE.setPlayerNickSuffix = function(name, src, text) suffixes[name] = {src = src, text = text} end
local keyAction
_G.MPKeybindsGE = {addAction = function(name, def) keyAction = {name = name, def = def} end}
local toggled = 0
_G.guihooks = {trigger = function(n) if n == "SharedCareerToggle" then toggled = toggled + 1 end end}
local cfgPl = {}
for k, v in pairs(config) do cfgPl[k] = v end
cfgPl.ui = {allowTeleport = false}
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(cfgPl))
update()
check(keyAction and keyAction.def.default == "f7" and keyAction.def.title:find("SharedCareer"), "Menü-Taste über BeamMP (F7)")
keyAction.def.onDown()
check(toggled == 1, "Taste klappt das Menü ein/aus")
check(lastSent("sc_status") and lastSent("sc_status").status == "driving", "eigener Status gemeldet")
_G.gameplay_missions_missionManager = {getForegroundMissionId = function() return "m1" end}
update(2.1)
check(lastSent("sc_status").status == "mission", "Mission wird erkannt")
handlers.sc_players(json.encode({players = {{id = 0, name = "Max Mustermann_99", status = "mission"},
	{id = 1, name = "Ben", status = "mission"}, {id = 2, name = "Eve", status = "driving"}}}))
check(suffixes["Ben"] and suffixes["Ben"].text == "[Mission]" and suffixes["Ben"].src == "sharedCareer", "Namensschild: [Mission]")
check(suffixes["Max Mustermann_99"] == nil, "eigenes Namensschild unverändert")
handlers.sc_players(json.encode({players = {{id = 1, name = "Ben", status = "driving"}}}))
check(suffixes["Ben"].text == "", "Status weg -> Zusatz entfernt (leerer Text, nicht nil)")
local ps = sharedCareer_players.state()
check(#ps.list == 1 and ps.canTeleport == false, "Players-Stand fürs Menü")
sharedCareer_players.uiNavigate("Ben")
check(mpCalls[#mpCalls][1] == "nav" and mpCalls[#mpCalls][2] == "Ben" and sharedCareer_players.state().navigating == "Ben", "Navigate")
sharedCareer_players.uiStopNavigate()
check(mpCalls[#mpCalls][2] == nil and sharedCareer_players.state().navigating == nil, "Navigation beenden")
local own = addVehicle(50, "0-50", true)
world.playerVeh = 50
local focus = {}
gameplay_traffic.setFocus = function(kind, opt) table.insert(focus, {kind, opt}) end
sharedCareer_players.uiWatch("Ben")
check(mpCalls[#mpCalls][1] == "watch" and focus[#focus][2].vehId == 50, "Watch: Traffic bleibt beim eigenen Auto")
world.playerVeh = 999
sharedCareer_players.uiBack()
check(world.playerVeh == 50 and focus[#focus][1] == nil, "Back: zurück ins eigene Auto")
local nCalls = #mpCalls
sharedCareer_players.uiTeleport("Ben")
check(#mpCalls == nCalls, "Teleport verboten, wenn Server es nicht erlaubt")
cfgPl.ui.allowTeleport = true
handlers.sc_configUpdate(json.encode(cfgPl))
sharedCareer_players.uiTeleport("Ben")
check(mpCalls[#mpCalls][1] == "tp", "Teleport erlaubt -> ausgeführt")
cfgPl.showPlayerStatus = false
handlers.sc_players(json.encode({players = {{id = 1, name = "Ben", status = "walking"}}}))
handlers.sc_configUpdate(json.encode(cfgPl))
check(suffixes["Ben"].text == "", "Status am Namensschild abschaltbar")
_G.gameplay_missions_missionManager = nil
_G.MPKeybindsGE = nil

--== 7h. Gemeinsame Spritpreise ==============================================
local function setupFuelWorld(copyEachCall)
	resetWorld()
	installCareer()
	local stationsData = {
		{id = "apex", name = "levels.wcusa.gasStationPoints.apex.title",
			prices = {gasoline = {priceBaseline = 1.5, priceRandomnessGain = 0.2, priceRandomnessBias = 0.5},
				diesel = {priceBaseline = 1.6, priceRandomnessGain = 0.2, priceRandomnessBias = 0.5}}},
	}
	local function deep(t) return json.decode(json.encode(t)) end
	_G.getCurrentLevelIdentifier = function() return "west_coast_usa" end
	_G.freeroam_facilities = {getFacilities = function()
		return {gasStations = copyEachCall and deep(stationsData) or stationsData}
	end}
	-- Nachbau von freeroam/facilities/fuelPrice.lua: Grundpreis + Zufall, Schilder, getFuelPrice
	local cached = {}
	local signs = {}
	_G.freeroam_facilities_fuelPrice = {
		setDisplayPrices = function()
			cached = {}
			for _, v in pairs(freeroam_facilities.getFacilities("west_coast_usa").gasStations) do
				cached[v.id] = {}
				for fuel, p in pairs(v.prices) do
					local price = p.priceBaseline
					if p.priceRandomnessGain and p.priceRandomnessBias then
						price = price + p.priceRandomnessGain * (math.random() - p.priceRandomnessBias)
					end
					cached[v.id][fuel] = price
					signs[v.id .. "/" .. fuel] = string.format("%.3f", price)
				end
			end
			return true
		end,
		getFuelPrice = function(id, fuel) return cached[id] and cached[id][fuel] end,
	}
	freeroam_facilities_fuelPrice.setDisplayPrices() -- wie beim Laden der Karte: gewürfelt
	return signs
end

local signs = setupFuelWorld(false)
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
update()
handlers.sc_fuelPrices(json.encode({enabled = true, factors = {apex = {diesel = 0.9}}}))
update()
local fp = freeroam_facilities_fuelPrice
check(math.abs(fp.getFuelPrice("apex", "gasoline") - 1.5) < 1e-9, "ohne Lieferung: Grundpreis ohne Zufall (für alle gleich)")
check(math.abs(fp.getFuelPrice("apex", "diesel") - 1.44) < 1e-9, "Diesel 10 % günstiger (1.6 × 0.9)")
check(signs["apex/diesel"] == "1.440", "Preisschild zeigt den neuen Preis")
-- Übersicht im Menü (Reiter Fuel)
_G.core_levels = {getLevelByName = function() return {localUnits = {gasoline = "gallonUS", diesel = "gallonUS"}} end}
freeroam_facilities.getAverageDoorPositionForFacility = function(st) return {x = 300, y = 400, z = 0} end
local meVeh = addVehicle(60, "0-60", true)
function meVeh:getPosition() return {x = 0, y = 0, z = 0} end
world.playerVeh = 60
-- vor dem Laden: noch keine Position -> darf sich nicht dauerhaft "keine Position" merken
local realPos = freeroam_facilities.getAverageDoorPositionForFacility
freeroam_facilities.getAverageDoorPositionForFacility = function() return nil end
check(sharedCareer_fuel.overview().stations[1].canNavigate == false, "Position noch unbekannt")
freeroam_facilities.getAverageDoorPositionForFacility = realPos
local ov = sharedCareer_fuel.overview()
local apexOv = ov and ov.stations[1]
check(apexOv and apexOv.id == "apex" and apexOv.fuels.diesel.unit == "gal", "Übersicht: Tankstelle mit Preisen (Einheit der Karte)")
check(math.abs(apexOv.fuels.diesel.price - 1.44 * 3.78541) < 1e-6 and apexOv.fuels.diesel.discount == 10, "Preis pro Gallone und Rabatt")
check(apexOv.fuels.gasoline.discount == 0, "Benzin ohne Rabatt")
check(math.abs(apexOv.distance - 500) < 1e-6 and apexOv.canNavigate == true, "Entfernung zum Spieler (500 m)")
local pathSet = "unset"
_G.core_groundMarkers = {setPath = function(pos) pathSet = pos end}
_G.vec3 = function(x, y, z) return {x = x, y = y, z = z} end
sharedCareer_fuel.uiNavigate("apex")
check(type(pathSet) == "table" and pathSet.x == 300 and sharedCareer_fuel.overview().navigating == "apex", "Go: Navigation zur Tankstelle")
sharedCareer_fuel.uiStopNavigate()
check(pathSet == nil and sharedCareer_fuel.overview().navigating == nil, "Stop: Navigation aus")
_G.core_levels, _G.core_groundMarkers = nil, nil

-- Lieferung erkennen
_G.career_modules_delivery_generator = {getFacilityById = function(id)
	if id == "apex_fuel" then return {name = "levels.wcusa.gasStationPoints.apex.title"} end
end}
local deliveredCalls = 0
_G.career_modules_delivery_progress = {onCargoDelivered = function(items) deliveredCalls = deliveredCalls + 1 end}
update(1.1)
career_modules_delivery_progress.onCargoDelivered({
	{materialType = "diesel", slots = 1500, location = {facId = "apex_fuel"}},
	{materialType = "diesel", slots = 500, location = {facId = "apex_fuel"}},
	{materialType = nil, slots = 1, location = {facId = "apex_fuel"}},            -- Paket
	{materialType = "gasoline", slots = 300, location = {facId = "farm_storage"}}, -- keine Tankstelle
})
check(deliveredCalls == 1, "Original-Spielfunktion läuft weiter")
local fd = lastSent("sc_fuelDelivered")
check(fd and fd.station == "apex" and fd.fuel == "diesel" and fd.amount == 2000, "Diesel-Lieferung an Apex gemeldet (zusammengezählt)")
local nWrap = career_modules_delivery_progress.onCargoDelivered
update(1.1)
check(career_modules_delivery_progress.onCargoDelivered == nWrap, "nicht doppelt eingewickelt")
-- Server schaltet ab -> Originalpreise (mit Zufall) zurück
handlers.sc_fuelPrices(json.encode({enabled = false, factors = {}}))
update()
local g = fp.getFuelPrice("apex", "gasoline")
check(g >= 1.4 and g <= 1.6 and freeroam_facilities.getFacilities().gasStations[1].prices.gasoline.priceRandomnessGain == 0.2,
	"abgeschaltet: Spielpreise wie vorher")

-- Spiel liefert nur Kopien der Daten -> Notlösung über getFuelPrice
setupFuelWorld(true)
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
update()
handlers.sc_fuelPrices(json.encode({enabled = true, factors = {apex = {diesel = 0.8}}}))
update()
check(math.abs(freeroam_facilities_fuelPrice.getFuelPrice("apex", "diesel") - 1.28) < 1e-9, "Notlösung: Tanken zum richtigen Preis")
_G.freeroam_facilities, _G.freeroam_facilities_fuelPrice = nil, nil
_G.career_modules_delivery_progress, _G.career_modules_delivery_generator = nil, nil

--== 7i. Willkommensdialog ===================================================
local function welcomeJoin(stateFile, cfgChange)
	resetWorld()
	installCareer()
	local wfiles = {["settings/sharedCareer/state.json"] = stateFile}
	_G.jsonReadFile = function(path) return wfiles[path] and json.decode(json.encode(wfiles[path])) or nil end
	_G.jsonWriteFile = function(path, data) wfiles[path] = json.decode(json.encode(data)); return true end
	_G.FS = {fileExists = function() return false end, findFiles = function() return {} end}
	local dialogs = {}
	-- Dialog kommt über die Oberfläche (guihook "SharedCareerDialog"); BeamMPs Dialog darf nie benutzt werden
	_G.MPGameNetwork = {spawnUiDialog = function() error("BeamMP dialog must not be used") end}
	_G.guihooks = {trigger = function(name, data) if name == "SharedCareerDialog" then table.insert(dialogs, data) end end}
	local c = {}
	for k, v in pairs(config) do c[k] = v end
	for k, v in pairs(cfgChange or {}) do c[k] = v end
	extensions.hook("onWorldReadyState", 2)
	handlers.sc_config(json.encode(c))
	update()
	return dialogs, wfiles
end
local navigated = {}
_G.ui_router = {navigate = function(r) table.insert(navigated, r) end, getCurrentRoute = function() return {name = "menu"} end}
local dialogs, wfiles = welcomeJoin(nil)
check(#dialogs == 0, "Dialog nicht sofort (erst nach dem Laden)")
for _ = 1, 50 do update(0.1) end
check(#dialogs == 1 and dialogs[1].title == "Welcome to SharedCareer", "Willkommensdialog nach ein paar Sekunden")
check(#navigated == 1 and navigated[1] == "play", "Hauptmenü nach dem Karrierestart -> zurück ins Spiel")
_G.ui_router.getCurrentRoute = function() return "play" end
navigated = {}
check(sharedCareer_welcome.ensurePlayScreen() == false and #navigated == 0, "schon im Spiel: nichts umschalten")
_G.ui_router = nil
check(dialogs[1].buttons[1].action == "never" and dialogs[1].buttons[1].label == "Don't show again", "Knopf 'Don't show again'")
local allText = ""
for _, it in ipairs(dialogs[1].items) do allText = allText .. it.head .. " " .. it.text .. " " end
check(allText:find("F7") and allText:find("Fuel prices") and allText:find("/pay"), "listet die wichtigsten Funktionen")
for _ = 1, 50 do update(0.1) end
check(#dialogs == 1, "nur einmal pro Join")
-- Regression 0.8.2: Fenster war ausgeblendet (Hauptmenü) und baut sich neu auf -> Dialog wieder da
sharedCareer_welcome.uiRequestDialog()
check(#dialogs == 2 and dialogs[2].title == "Welcome to SharedCareer", "neu aufgebautes Fenster bekommt den offenen Dialog")
-- Spieler klickt "Don't show again" im Fenster
sharedCareer_welcome.uiDialogButton("welcome", "never")
check(wfiles["settings/sharedCareer/state.json"].welcomeHidden == true, "Wahl wird gespeichert")
sharedCareer_welcome.uiRequestDialog()
check(#dialogs == 2, "nach Knopfdruck kein offener Dialog mehr")
-- nächster Join: kein Dialog mehr
dialogs = welcomeJoin({welcomeHidden = true})
for _ = 1, 60 do update(0.1) end
check(#dialogs == 0, "nach 'Don't show again' kein Dialog mehr")
sharedCareer_welcome.show(true)
check(#dialogs == 1, "Klick aufs Logo zeigt ihn trotzdem")
-- Regression 0.8.0: Ladebildschirm noch offen -> Dialog erst, wenn er weg ist
resetWorld()
installCareer({trafficHang = true})
local hangDialogs = {}
_G.jsonReadFile = function() return nil end
_G.jsonWriteFile = function() return true end
_G.FS = {fileExists = function() return false end, findFiles = function() return {} end}
_G.guihooks = {trigger = function(name, data) if name == "SharedCareerDialog" then table.insert(hangDialogs, data) end end}
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
for _ = 1, 300 do update(0.1) end -- 30 s: Ladebildschirm "careerVehicles" hängt noch
check(#hangDialogs == 0, "kein Dialog, solange der Ladebildschirm offen ist")
for _ = 1, 400 do update(0.1) end -- Mod gibt den Ladebildschirm nach 60 s frei, dann +3 s
check(#hangDialogs == 1, "Dialog nach dem Ladebildschirm")
-- Server schaltet ihn ab
dialogs = welcomeJoin(nil, {showWelcome = false})
for _ = 1, 60 do update(0.1) end
check(#dialogs == 0, "showWelcome = false: kein Dialog")
-- Meldung des Servers (z.B. Gast-Hinweis) erscheint als Dialog im Fenster
handlers.sc_dialog(json.encode({title = "SharedCareer: you are playing as a guest", body = "Your progress...", warning = false}))
check(#dialogs == 1 and dialogs[1].kind == "server" and dialogs[1].title:find("guest") and dialogs[1].buttons[1].label == "OK",
	"Server-Meldung als Dialog im Fenster")
_G.MPGameNetwork = nil

--== 8. Geld ====================================================================
resetWorld()
installCareer({money = 1000})
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
handlers.sc_payDebit(json.encode({id = "a", amount = 5000, to = "Ben"}))
check(lastSent("sc_payDebitResult").ok == false and career_modules_playerAttributes.money() == 1000,
	"zu wenig Geld -> nichts abgebucht")
handlers.sc_payDebit(json.encode({id = "b", amount = 300, to = "Ben"}))
check(lastSent("sc_payDebitResult").ok == true and career_modules_playerAttributes.money() == 700, "abgebucht")
check((world.saved or 0) >= 1, "nach Abbuchung gespeichert")
handlers.sc_payDebit(json.encode({id = "b", amount = 300, to = "Ben"}))
check(career_modules_playerAttributes.money() == 700, "doppelte Nachricht bucht nicht doppelt ab")
handlers.sc_payCredit(json.encode({id = "c", amount = 50, from = "Ben"}))
handlers.sc_payCredit(json.encode({id = "c", amount = 50, from = "Ben"}))
check(career_modules_playerAttributes.money() == 750, "Gutschrift genau einmal")
check(lastSent("sc_payCreditAck").id == "c", "Gutschrift bestätigt")
handlers.sc_payDebit(json.encode({id = "d", amount = -100, to = "Ben"}))
check(lastSent("sc_payDebitResult").ok == false and career_modules_playerAttributes.money() == 750,
	"negativer Betrag abgelehnt")

--== 9. Server verlassen setzt alles zurück =====================================
extensions.hook("onBeamMPServerLeave")
check(sharedCareer_core.getConfig() == nil and not sharedCareer_core.isStarted(), "Zustand zurückgesetzt")
check(settings.getValue("trafficSimpleVehicles") == false and settings.getValue("simplifyRemoteVehicles") == false,
	"eigene Einstellungen des Spielers wiederhergestellt")

print(string.format("Client: %d ok, %d Fehler", passed, failures))
os.exit(failures == 0 and 0 or 1)
