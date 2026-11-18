-- Client tests: the BeamNG/BeamMP environment is mocked, the real mod files are loaded.
-- Run (LuaJIT, like in the game):  luajit tests/client_test.lua

package.path = "./tests/?.lua;" .. package.path
local json = require("json")
-- read the version from the code (only maintain util.lua/main.lua, see tools/bump.sh)
local VERSION = io.open("client/lua/ge/extensions/sharedCareer/util.lua"):read("*a"):match('M%.VERSION = "(.-)"')

local ROOT = "client/lua/ge/extensions/"
local clock = 0
local failures, passed = 0, 0
local function check(cond, msg)
	if cond then passed = passed + 1 else failures = failures + 1; print("FAILED: " .. msg) end
end

--== Game world mock ============================================================

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
	_G.MPConfig = {getNickname = function() return "John Doe_99" end}
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
	-- be:getObject(i) is called with a colon
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
			-- This is how BeamMP's replacement behaves: rebuilds getPlayerVehicle(0), not "other"
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

	-- extension system
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

-- Career mock that behaves like career.lua (removeAll on activation).
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
			gameplay_traffic.setActiveAmount(10) -- the career overwrites with its own values
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
	remoteVehicleGhost = true, remoteUnicycleGhost = true, allowConsole = false, serverVersion = VERSION,
	trafficSimpleVehicles = true, simplifyRemoteVehicles = true}

--== 1. Join: career starts, remote cars survive ================================
resetWorld()
installCareer()
local mine = addVehicle(1, "0-0", true)
local theirs = addVehicle(2, "1-0", false)
extensions.hook("onWorldReadyState", 2)
check(lastSent("sc_hello") ~= nil, "hello sent after world ready")
handlers.sc_config(json.encode(config))
check(world.careerArgs.name == "johndoe99srv", "profile name cleaned up: " .. tostring(world.careerArgs.name))
check(type(world.careerArgs.options) == "table" and world.careerArgs.options.startMode == "freshStart",
	"start options as a table with freshStart")
check(world.careerArgs.folder == false, "no fixed save folder")
check(theirs.deleted == false, "remote car survives the career start")
check(mine.deleted == true, "own old car is removed by the career")
check(world.trafficSetup[1] == 4 and world.trafficSetup[3] == 3, "server traffic passed to the career")
check(world.trafficSetup[2].simpleVehs == true, "traffic spawns as simple vehicles")
check(settings.getValue("trafficSimpleVehicles") == true, "game setting trafficSimpleVehicles set")
check(settings.getValue("simplifyRemoteVehicles") == true, "BeamMP setting simplifyRemoteVehicles set")
update()
check(world.activeRoad == 4, "server traffic overrides the career setting afterwards")
check(lastSent("sc_careerResult") and lastSent("sc_careerResult").ok == true, "success reported to the server")
update(); update()
local saved = core_vehicles.removeAll
check(saved ~= nil, "removeAll present")
core_vehicles.removeAll()
check(theirs.deleted == true, "after the start removeAll is the original again")

--== 1b. Profile name comes from the server (per account) =====================
resetWorld()
installCareer()
extensions.hook("onWorldReadyState", 2)
local cfgP = {}
for k, v in pairs(config) do cfgP[k] = v end
cfgP.profileBase = "anna"
handlers.sc_config(json.encode(cfgP))
check(world.careerArgs.name == "annasrv", "server profile + suffix instead of BeamMP name: " .. tostring(world.careerArgs.name))
update()
check(lastSent("sc_careerResult").profile == "annasrv", "profile name reported to the server")

--== 2. Start hangs in the loading screen -> released after the timeout ==========
resetWorld()
installCareer({trafficHang = true})
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
for _ = 1, 50 do update(0.1) end
check(lastSent("sc_careerResult") == nil, "no result yet while the start is running")
for _ = 1, 600 do update(0.1) end
check(loadingScreens.careerVehicles == nil, "hanging loading screen released")
check(lastSent("sc_careerResult").ok == true, "career was running -> success anyway")

--== 3. Start throws an error -> failure reported ================================
resetWorld()
installCareer({fail = true})
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
local result = lastSent("sc_careerResult")
check(result and result.ok == false and tostring(result.reason):find("kaputt"), "error is reported")
check(core_vehicles.removeAll ~= nil and #toasts > 0, "player sees an error message")

--== 4. Career module only arrives later ========================================
resetWorld()
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
check(world.careerArgs == nil, "waits for career_career")
installCareer()
update()
check(world.careerArgs ~= nil, "starts as soon as career_career exists")

--== 5. A broken onCareerActive handler doesn't stop the others ==================
resetWorld()
local ran = {}
registerExtension("career_modules_a", {onCareerActive = function() error("boom") end})
registerExtension("career_modules_b", {onCareerActive = function() ran.b = true end})
installCareer()
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
check(ran.b == true, "handler after the failing one still runs")
check(sharedCareer_protect.getFailures()[1] == "career_modules_a", "error is logged")
update()
local ok = pcall(extensions.hook, "onCareerActive", true)
check(not ok, "after the start the protection is gone again (game behavior unchanged)")

--== 6. Garage: the right car is rebuilt ========================================
resetWorld()
installCareer()
local walker = addVehicle(10, "0-1", true, "unicycle")
local car = addVehicle(11, "0-2", true)
local remote = addVehicle(12, "1-3", false)
world.playerVeh = 10
update(1.1) -- patches are installed
core_vehicles.replaceVehicle("pickup", {}, car)
check(world.rebuilt == 11, "the named car was rebuilt, not the player on foot (was " .. tostring(world.rebuilt) .. ")")
check(getPlayerVehicle(0).id == 10, "getPlayerVehicle back to normal afterwards")
_G.career_modules_inventory = {getInventoryIdFromVehicleId = function(id) if id == 12 then return 7 end end}
world.rebuilt = nil
check(core_vehicles.replaceVehicle("pickup", {}, remote) == nil and world.rebuilt == nil,
	"inventory car that isn't ours is not touched")
_G.career_modules_inventory = {getInventoryIdFromVehicleId = function() return nil end}
core_vehicles.replaceVehicle("pickup", {}, remote)
check(world.rebuilt == 10, "remote non-inventory cars go to BeamMP unchanged")
for _ = 1, 5 do update(1.1) end
local depth = 0
local fn = core_vehicles.replaceVehicle
check(sharedCareer_util.isOurs(fn), "wrapper is in place")
-- A reloaded module (new function) is wrapped again, but never twice
core_vehicles.replaceVehicle = function(m, o, other) world.rebuilt = getPlayerVehicle(0).id end
update(1.1)
local w1 = core_vehicles.replaceVehicle
update(1.1)
check(w1 == core_vehicles.replaceVehicle and sharedCareer_util.isOurs(w1), "no double wrapping")

-- unicycle visible
core_vehicles.spawnNewVehicle("unicycle", {config = "vehicles/unicycle/without_mesh.pc"})
check(world.spawned[2].config == "vehicles/unicycle/beammp_default.pc", "visible player on foot in MP")

--== 6b. Using computers from a distance ======================================
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
-- Rebuild of the game class: setup builds the boxes once from the scene objects
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
-- a marker the game built BEFORE our patch
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
check(existing.updated == true, "original method still runs")
check(len(existing.doors[1].xVec) == 6 and len(existing.doors[1].yVec) == 6, "computer zone enlarged to 6 m (old marker)")
check(len(existing.doors[1].zVec) == 2.5, "zone high enough for stairs/ramps")
check(len(dealer.doors[1].xVec) == 2, "other zones (dealers) stay unchanged")
-- new marker after the patch
local fresh = markerModule.create()
fresh:setup({doors = {{"servicestationGarageComputer_area_1", "servicestationGarageComputer_icon_1"}}})
fresh:update()
check(len(fresh.doors[1].xVec) == 6, "new markers are enlarged too")
-- live to 0 -> original back
cfgC.computerAccessRange = 0
handlers.sc_configUpdate(json.encode(cfgC))
existing:update()
check(len(existing.doors[1].xVec) == 1.5 and len(existing.doors[1].yVec) == 1, "0 restores the original size")
-- no double wrapping
local f1 = C.update
update(1.1); update(1.1)
check(C.update == f1, "marker methods not wrapped twice")
package.loaded["gameplay/markers/walkingMarker"] = nil

--== 7. Vehicle visibility ======================================================
resetWorld()
installCareer()
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
local own = addVehicle(20, "0-5", true)
local other = addVehicle(21, "1-5", false)
extensions.hook("onVehicleSpawned", 21)
update(1.1)
check(other.dyn.ignoreTraffic == "true", "remote car is ignored by our own traffic")

-- Regression: own traffic that BeamMP hasn't registered yet (isOwn == false) must
-- NOT be marked as remote – otherwise the traffic stands still.
local freshTraffic = newVehicle(30)
table.insert(world.objects, freshTraffic)
extensions.hook("onVehicleSpawned", 30)
update(1.1)
check(freshTraffic.dyn.ignoreTraffic == nil, "freshly spawned own traffic stays drivable")
-- BeamMP lists the car as local, the server confirmation (isOwn) is still missing
world.mp["0-9"] = {gameVehicleID = 30, jbeam = "simple_traffic", isLocal = true}
update(1.1)
check(freshTraffic.dyn.ignoreTraffic == nil, "local, not yet confirmed car stays drivable")
world.own[30] = true
update(1.1)
check(freshTraffic.dyn.ignoreTraffic == nil, "confirmed own car stays drivable")
handlers.sc_vehStates(json.encode({["1-5"] = {active = false, traffic = true}}))
check(other.active == false, "car hidden by the server gets hidden")
check(world.mp["1-5"].hideNametag == true, "name tag hidden")
handlers.sc_vehStates(json.encode({["1-5"] = {active = true, traffic = false}}))
check(other.active == true and world.mp["1-5"].hideNametag == false, "visible again")
own:setActive(0)
extensions.hook("onVehicleActiveChanged", 20, false)
update(0.1)
local msg = lastSent("sc_vehReport")
check(msg and msg["0-5"] and msg["0-5"].active == false, "own hiding sent to the server at once")
own.dyn = {}
own.isTraffic = "true"
update(1.1)
check(lastSent("sc_vehReport") and lastSent("sc_vehReport")["0-5"].traffic == true, "own traffic car marked")
-- Regression: traffic reserve hidden right after its spawn, before BeamMP gave it a server id.
-- The hide event comes too early; the regular report must still tell the others.
do
local reserve = newVehicle(31)
table.insert(world.objects, reserve)
reserve:setActive(0)
extensions.hook("onVehicleActiveChanged", 31, false)
update(0.1)
world.mp["0-10"] = {gameVehicleID = 31, jbeam = "simple_traffic"}
world.own[31] = true
update(1.1)
msg = lastSent("sc_vehReport")
check(msg and msg["0-10"] and msg["0-10"].active == false, "car hidden before its server id: reported hidden later")
local reportsBefore = #sentToServer
update(1.1)
check(#sentToServer == reportsBefore, "nothing changed: no report")
update(10)
msg = lastSent("sc_vehReport")
check(msg and msg["0-10"] and msg["0-5"], "all own cars are reported again every few seconds")
end
local ghostCmd = other.lua[#other.lua]
check(ghostCmd and ghostCmd:find("setGhost%(true%)"), "ghost according to the server setting")
-- a fellow player's traffic: always collides, even if player cars don't
local remoteTraffic = addVehicle(22, "1-6", false)
handlers.sc_vehStates(json.encode({["1-6"] = {active = true, traffic = true}}))
update(1.1)
local lastGhost = remoteTraffic.lua[#remoteTraffic.lua]
check(lastGhost and lastGhost:find("setGhost%(false%)"), "other players' traffic always collides")
check(other.lua[#other.lua]:find("setGhost%(true%)"), "player car stays without collision (setting)")
-- if a car is only marked as traffic later, it switches to collision
local laterTraffic = addVehicle(23, "1-7", false)
handlers.sc_vehStates(json.encode({["1-7"] = {active = true}}))
update(1.1)
check(laterTraffic.lua[#laterTraffic.lua]:find("setGhost%(true%)"), "unmarked remote car: player setting")
handlers.sc_vehStates(json.encode({["1-7"] = {active = true, traffic = true}}))
update(1.1)
check(laterTraffic.lua[#laterTraffic.lua]:find("setGhost%(false%)"), "after the traffic mark: collision")
check(other.dyn.trafficClearRadius == "40", "our traffic keeps clear of another player")
check(remoteTraffic.dyn.trafficClearRadius == "", "another player's traffic: no clear radius")
check(laterTraffic.dyn.trafficClearRadius == "", "clear radius removed once the car is marked as traffic")
check(own.dyn.trafficClearRadius == nil, "own cars: no clear radius")

--== 7b. More careful AI ========================================================
resetWorld()
installCareer()
extensions.hook("onWorldReadyState", 2)
local cfgAi = {}
for k, v in pairs(config) do cfgAi[k] = v end
cfgAi.trafficAggression = 0.2
cfgAi.trafficGrip = 0.85
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
local function grip(v)
	for i = #v.lua, 1, -1 do
		local x = v.lua[i]:match("staticFrictionCoefMult = ([%d%.]+)")
		if x then return tonumber(x) end
	end
end
-- runs the last AI command in a fake vehicle Lua and returns what it called
local function lastAiCommand(v)
	for i = #v.lua, 1, -1 do
		if v.lua[i]:find("ai%.set") then return v.lua[i], i end
	end
end
local function runInVehicle(v)
	local calls = {}
	local env = {ai = {
		setAggression = function(x) calls.aggression = x end,
		setParameters = function(t) calls.params = t end,
	}}
	local fn = assert(loadstring((lastAiCommand(v))))
	setfenv(fn, env)
	fn()
	return calls
end
check(aggr(carA) == 0.2, "traffic gets a more careful aggression")
check(grip(carA) == 0.85, "traffic gets a lower grip estimate (brakes earlier)")
local calls = runInVehicle(carA)
check(calls.aggression == 0.2 and calls.params and calls.params.staticFrictionCoefMult == 0.85
	and next(calls.params, next(calls.params)) == nil,
	"the command runs in the vehicle and only sets staticFrictionCoefMult")
check(grip(cop) == nil, "police grip stays unchanged")
check(aggr(cop) == nil, "police stay unchanged")
check(aggr(mineAi) == nil, "the player's car is not touched")
local n = aggrCount(carA)
update(3.1)
check(aggrCount(carA) == n, "no spam: not resent on every check")
cfgAi.trafficAggression = 0.1
handlers.sc_configUpdate(json.encode(cfgAi))
update(3.1)
check(aggr(carA) == 0.1, "live change from the server applies")
cfgAi.trafficGrip = 0.2
handlers.sc_configUpdate(json.encode(cfgAi))
update(3.1)
check(grip(carA) == 0.5, "grip is clamped to at least 0.5 (the AI would crawl otherwise)")
cfgAi.trafficGrip = 0.85
cfgAi.trafficAggression = 0
handlers.sc_configUpdate(json.encode(cfgAi))
n = aggrCount(carA)
update(3.1); update(10)
check(aggrCount(carA) == n, "0 = aggression is not changed")
check(grip(carA) == 0.85 and runInVehicle(carA).aggression == nil, "grip still applies on its own")
cfgAi.trafficGrip = 0
handlers.sc_configUpdate(json.encode(cfgAi))
local _, lastIndex = lastAiCommand(carA)
update(3.1); update(10)
check(select(2, lastAiCommand(carA)) == lastIndex, "both 0 = AI is not touched at all")

--== 7b2. AI reacts earlier (vehicle side, ai.lua internals) =================
-- Rebuild of the relevant structure of the game's lua/vehicle/ai.lua: `ego` and `traffic` are
-- local tables, only reachable as upvalues of local functions, which are called by the module.
local function makeFakeAi()
	local ego = {race_time_gap = 0.3, race_catchAgg = 1, race_brakeAgg = 0}
	local traffic = {Rfl_fun = function(v) return math.max(60, math.min(200, (v + 10) * 3)) end}
	local function planAhead() return traffic.Rfl_fun(ego.speed or 0) end   -- nested level 2
	local function update() return planAhead() end                          -- nested level 1
	local mod = {}
	mod.update = function() return update() end
	mod.setAggression = function() end
	return mod, ego, traffic
end
local vehLogs = {}
local savedLog = _G.log
_G.log = function(level, tag, msg) table.insert(vehLogs, level .. " " .. tostring(msg)) end
local fakeAi, fakeEgo, fakeTraffic = makeFakeAi()
_G.ai = fakeAi
local veh = dofile("client/lua/vehicle/extensions/auto/sharedCareerVeh.lua")
local gameSight = fakeTraffic.Rfl_fun
check(veh.setAiTuning(1.0, 5) == true, "AI tables found through nested upvalues")
check(fakeEgo.race_time_gap == 1.0, "safety gap set to 1 s (game 0.3 s)")
check(fakeTraffic.Rfl_fun(28) == 190 and fakeTraffic.Rfl_fun(0) == 60 and fakeTraffic.Rfl_fun(100) == 300,
	"sight range: (speed + 10) * 5, between 60 and 300 m")
check(gameSight(28) == 114, "for comparison: the game sees 114 m at 100 km/h")
check(#vehLogs == 1 and vehLogs[1]:find("0.30 s %-> 1.00 s") and vehLogs[1]:find("113 m %-> 189 m"),
	"first apply is logged with old and new values: " .. tostring(vehLogs[1]))
veh.setAiTuning(1.0, 5)
check(fakeEgo.race_time_gap == 1.0 and fakeTraffic.Rfl_fun(28) == 190, "applying again changes nothing")
check(veh.setAiTuning(0, 0) == true and fakeEgo.race_time_gap == 0.3 and fakeTraffic.Rfl_fun == gameSight,
	"0 restores the game's values")
veh.setAiTuning(0.8, 0)
check(fakeEgo.race_time_gap == 0.8 and fakeTraffic.Rfl_fun == gameSight, "each value can be switched on its own")
-- a game update that renames the internals: nothing changes, one log line
_G.ai = {update = function() return 1 end}
veh = dofile("client/lua/vehicle/extensions/auto/sharedCareerVeh.lua")
vehLogs = {}
check(veh.setAiTuning(1.0, 5) == false and veh.setAiTuning(1.0, 5) == false, "internals not found: nothing changed")
check(#vehLogs == 1 and vehLogs[1]:find("not found"), "internals not found: logged once")
-- debug library not available: nothing changed
fakeAi, fakeEgo = makeFakeAi()
_G.ai = fakeAi
veh = dofile("client/lua/vehicle/extensions/auto/sharedCareerVeh.lua")
local savedDebug = _G.debug
_G.debug = nil
local okNoDebug = veh.setAiTuning(1.0, 5)
_G.debug = savedDebug
check(okNoDebug == false and fakeEgo.race_time_gap == 0.3, "without the debug library: nothing changed")
_G.ai, _G.log = nil, savedLog

-- GE side: the command includes the tuning for traffic, not for police
resetWorld()
installCareer()
extensions.hook("onWorldReadyState", 2)
local cfgT = {}
for k, v in pairs(config) do cfgT[k] = v end
cfgT.trafficAggression, cfgT.trafficReactionGap, cfgT.trafficSightRange = 0.2, 1.0, 5
handlers.sc_config(json.encode(cfgT))
local carT = addVehicle(50, "0-50", true)
local copT = addVehicle(51, "0-51", true)
gameplay_traffic.getTrafficData = function()
	return {[50] = {isAi = true}, [51] = {isAi = true, role = {name = "police"}}}
end
update(3.1)
local function tuningCmd(v)
	for i = #v.lua, 1, -1 do
		local g, r = v.lua[i]:match("setAiTuning%(([%d%.]+), ([%d%.]+)%)")
		if g then return tonumber(g), tonumber(r) end
	end
end
local tg, tr = tuningCmd(carT)
check(tg == 1.0 and tr == 5, "traffic gets the reaction gap and sight range")
check(tuningCmd(copT) == nil, "police AI is not tuned")
cfgT.trafficReactionGap, cfgT.trafficSightRange = 9, 0
handlers.sc_configUpdate(json.encode(cfgT))
update(3.1)
tg, tr = tuningCmd(carT)
check(tg == 3 and tr == 0, "values are clamped (gap max 3 s), 0 = game value")

--== 7b3. Node grabber in the career ==========================================
-- Rebuild of the game's core/input/actionFilter.lua: groups, rebuild from all blocked groups,
-- hook onActionFilterUpdated after every change.
local function makeActionFilter()
	local groups, blockedGroups, blocked = {}, {}, {}
	local f = {}
	function f.setGroup(name, actions) groups[name] = actions end
	function f.addAction(filterId, name, filtered)
		blockedGroups[filterId] = blockedGroups[filterId] or {}
		blockedGroups[filterId][name] = filtered
		blocked[filterId] = {}
		for g, on in pairs(blockedGroups[filterId]) do
			if on then
				for _, a in ipairs(groups[g] or {g}) do blocked[filterId][a] = true end
			end
		end
		extensions.hook("onActionFilterUpdated")
	end
	function f.isActionBlocked(a)
		for _, actions in pairs(blocked) do if actions[a] then return true end end
		return false
	end
	return f
end
local NODE_ACTIONS = {"nodegrabberGrab", "nodegrabberRender", "nodegrabberStrength"}
local walking, freeCam = false, nil
-- the career's own rule (career.lua updateNodegrabberBlocking)
local function careerUpdateNodegrabber()
	local block = career_career.isActive() and (freeCam ~= nil or not walking)
	core_input_actionFilter.setGroup("careerNodeGrabberActions", NODE_ACTIONS)
	core_input_actionFilter.addAction(0, "careerNodeGrabberActions", block)
end
local function joinForNodegrab(allow)
	resetWorld()
	installCareer()
	_G.core_input_actionFilter = makeActionFilter()
	extensions.core_input_actionFilter = core_input_actionFilter
	_G.gameplay_walk = {isWalking = function() return walking end}
	_G.core_camera = {getActiveGlobalCameraName = function() return freeCam end}
	extensions.hook("onWorldReadyState", 2)
	local c = {}
	for k, v in pairs(config) do c[k] = v end
	c.allowNodeGrabber = allow
	handlers.sc_config(json.encode(c))
	update()
	return c
end
local function grabBlocked() return core_input_actionFilter.isActionBlocked("nodegrabberGrab") end

walking, freeCam = false, nil
local cfgN = joinForNodegrab(false)
careerUpdateNodegrabber()
check(grabBlocked(), "switched off: the career blocks the node grabber in a vehicle (game rule)")
walking = true; careerUpdateNodegrabber()
check(not grabBlocked(), "switched off: allowed while walking (game rule)")

walking, freeCam = false, nil
cfgN = joinForNodegrab(true)
careerUpdateNodegrabber()
check(not grabBlocked(), "allowed: node grabber works in a vehicle")
freeCam = "free"; careerUpdateNodegrabber()
check(not grabBlocked(), "allowed: node grabber works in the free camera")
freeCam = nil
-- the certification test blocks it with its own group: that block stays
local nodeErrors = {}
local quietLog = _G.log
_G.log = function(level, tag, msg) if level == "E" then table.insert(nodeErrors, tostring(msg)) end end
core_input_actionFilter.setGroup("certificationBlockedActions", {"nodegrabberGrab"})
core_input_actionFilter.addAction(0, "certificationBlockedActions", true)
careerUpdateNodegrabber()
_G.log = quietLog
check(grabBlocked(), "the vehicle certification test still blocks it")
check(#nodeErrors == 0, "no errors while another block stays (no endless loop): " .. tostring(nodeErrors[1]))
core_input_actionFilter.addAction(0, "certificationBlockedActions", false)
check(not grabBlocked(), "after the certification test it works again")
-- switched off live -> the career's rule is back
cfgN.allowNodeGrabber = false
handlers.sc_configUpdate(json.encode(cfgN))
check(grabBlocked(), "switched off live: blocked in a vehicle again")
careerUpdateNodegrabber()
check(grabBlocked(), "switched off live: the mod no longer lifts the block")
cfgN.allowNodeGrabber = true
handlers.sc_configUpdate(json.encode(cfgN))
check(not grabBlocked(), "switched on live: allowed immediately")
-- leaving the server restores the career's rule
extensions.hook("onBeamMPServerLeave")
check(grabBlocked(), "leaving the server: blocked in a vehicle again")
_G.core_input_actionFilter, _G.gameplay_walk, _G.core_camera = nil, nil, nil
extensions.core_input_actionFilter = nil

--== 7b4. Our own node grabber: vehicle side (forces) =========================
-- Rigid-body rebuild of a vehicle in the vehicle Lua: nodes with mass that all move together,
-- gravity, and a flat ground at z = 0 that the lowest node can't go through. Like in the game, the
-- rope runs at the physics rate (onPhysicsStep, 2000 per second) and updateGFX at 60 per second.
do
	local function vec3(x, y, z) return {x = x, y = y, z = z} end
	-- f: forces of this physics step (applyForceVector); frameF: forces for the whole frame
	-- (applyForceVectorTime, set in updateGFX)
	local body = {p = {x = 0, y = 0, z = 0}, v = {x = 0, y = 0, z = 0}, f = {x = 0, y = 0, z = 0},
		frameF = {x = 0, y = 0, z = 0}, forces = {}, ge = {}}
	-- 2 t car: 20 nodes, chassis nodes heavy (180 kg), panel nodes light (20 kg)
	local nodes, rel = {}, {}
	for i = 0, 19 do
		local heavy = i < 10
		nodes[i] = {cid = i}
		rel[i] = {x = (i % 5) - 2, y = (i % 2) * 1.6 - 0.8, z = heavy and 0.3 or 1.2, m = heavy and 180 or 20}
	end
	local function addForce(cid, f, frame)
		local into = frame and body.frameF or body.f
		into.x, into.y, into.z = into.x + f.x, into.y + f.y, into.z + f.z
		body.forces[cid] = (body.forces[cid] or 0) + math.sqrt(f.x * f.x + f.y * f.y + f.z * f.z)
	end
	local hookOn = false
	local function makeEnv(withHook)
		local env = {
			v = {data = {nodes = nodes}},
			vec3 = vec3,
			enablePhysicsStepHook = withHook and function() hookOn = true end or nil,
			obj = {
				getNodeMass = function(_, cid) return rel[cid].m end,
				getAbsNodePosition = function(_, cid)
					return vec3(body.p.x + rel[cid].x, body.p.y + rel[cid].y, body.p.z + rel[cid].z)
				end,
				getNodeVelocityVector = function() return vec3(body.v.x, body.v.y, body.v.z) end,
				getId = function() return 77 end,
				queueGameEngineLua = function(_, cmd) table.insert(body.ge, cmd) end,
				applyForceVector = function(_, cid, f) addForce(cid, f) end,
				applyForceVectorTime = function(_, cid, f, dt) addForce(cid, f, true) end,
			},
		}
		if not withHook then env.enablePhysicsStepHook = false end -- not offered by this game
		return setmetatable(env, {__index = function(_, k) if k == "enablePhysicsStepHook" then return nil end return _G[k] end})
	end
	local function loadVeh(withHook)
		local chunk = assert(loadfile("client/lua/vehicle/extensions/auto/sharedCareerVeh.lua"))
		setfenv(chunk, makeEnv(withHook))
		return chunk()
	end
	local veh = loadVeh(true)
	local MASS, WEIGHT = 2000, 2000 * 9.81
	local PHYS = 1 / 2000
	local GFX_EVERY = 33       -- physics steps per frame (about 60 fps)
	local steps = 0
	-- moves the body by the forces in body.f for dt
	local function integrate(dt)
		local fx, fy, fz = body.f.x + body.frameF.x, body.f.y + body.frameF.y, body.f.z + body.frameF.z
		-- handbrake (body.brake, N): the vehicle only moves once the pull is stronger
		local fhx, fhy = fx, fy
		if body.brake and body.p.z < 0.01 then
			local vh = math.sqrt(body.v.x ^ 2 + body.v.y ^ 2)
			local fh = math.sqrt(fhx ^ 2 + fhy ^ 2)
			if vh < 0.05 and fh <= body.brake then
				fhx, fhy, body.v.x, body.v.y = 0, 0, 0, 0
			elseif vh < 0.05 then
				-- breaking loose: sliding friction against the pull
				fhx, fhy = fhx - fhx / fh * body.brake * 0.8, fhy - fhy / fh * body.brake * 0.8
			else
				fhx, fhy = fhx - body.v.x / vh * body.brake * 0.8, fhy - body.v.y / vh * body.brake * 0.8
			end
		end
		body.v.x = body.v.x + fhx / MASS * dt
		body.v.y = body.v.y + fhy / MASS * dt
		body.v.z = body.v.z + (fz / MASS - 9.81) * dt
		-- ground: it can't sink below it; on the ground the wheels have a little rolling resistance
		if body.p.z + body.v.z * dt < 0 then body.v.z = 0 end
		if body.p.z < 0.01 then
			body.v.x, body.v.y = body.v.x * (1 - 0.5 * dt), body.v.y * (1 - 0.5 * dt)
		end
		body.p.x = body.p.x + body.v.x * dt
		body.p.y = body.p.y + body.v.y * dt
		body.p.z = math.max(0, body.p.z + body.v.z * dt)
	end
	-- seconds of game time; watch(): called after every physics step
	local function run(seconds, watch)
		for _ = 1, math.floor(seconds / PHYS + 0.5) do
			body.f = {x = 0, y = 0, z = 0}
			veh.onPhysicsStep(PHYS)
			if watch then watch() end
			integrate(PHYS)
			steps = steps + 1
			if steps % GFX_EVERY == 0 then
				body.frameF = {x = 0, y = 0, z = 0}
				veh.updateGFX(GFX_EVERY * PHYS)
			end
		end
	end
	local function speed() return math.sqrt(body.v.x ^ 2 + body.v.y ^ 2 + body.v.z ^ 2) end
	-- grab where you point: a ray from x = 10 along -x at the height/side of the upper right
	-- panel nodes; the front-most node on it is at x = 2
	check(veh.handGrabRay(10, 0.8, 1.2, -1, 0, 0, 120, 1, 60) == true, "vehicle side: grabbed via the aim ray")
	check(hookOn, "a rope switches on the physics-step hook (the rope runs 2000 times per second)")
	local reply = body.ge[#body.ge] or ""
	local rt, rx = reply:match("onGrip%(77, ([%d%.]+), ([-%d%.]+),")
	check(reply:find("sharedCareer_grab.onGrip") and math.abs(tonumber(rt) - 8) < 0.01 and math.abs(tonumber(rx) - 2) < 0.01,
		"grabs the node you point at (front-most on the ray) and reports grip and distance: " .. reply)
	veh.handRelease()
	body.ge = {}
	veh.handProbe(10, 0.8, 1.2, -1, 0, 0, 120)
	check((body.ge[1] or ""):find("onProbe%(77, 2%.000, 0%.800, 1%.200%)"), "preview: reports where it would grab")
	check(veh.handGrab(2, 0.8, 0.3, 1, 60) == true, "vehicle side: nodes around the grab point are taken")
	-- in the game a frame can come right after the grab, before the first physics step (the first dev build crashed
	-- the vehicle's Lua there: the rope had no length yet)
	body.ge = {}
	local frameOk, frameErr = pcall(veh.updateGFX, 1 / 60)
	check(frameOk and veh.handInfo() ~= nil, "a frame before the first physics step: no error (" .. tostring(frameErr) .. ")")
	local info = veh.handInfo()
	check(#info.nodes >= 4 and #info.nodes <= 24 and info.vehMass == MASS, "grip of 4-24 nodes, vehicle mass known")
	local function lastState()
		local st = body.ge[#body.ge] or ""
		local strain, slack, len = st:match("onHandState%(77, [-%d%.]+, [-%d%.]+, [-%d%.]+, ([%d%.]+), (%d), ([%d%.]+), [%d%.]+%)")
		return tonumber(strain), tonumber(slack), tonumber(len)
	end
	local function lost()
		local st = body.ge[#body.ge] or ""
		return tonumber(st:match("onHandLost%(77, (%d+)%)"))
	end
	-- how far the rope is stretched now (m)
	local function stretch()
		local h = veh.handInfo()
		local t = {x = body.p.x + rel[h.tie].x, y = body.p.y + rel[h.tie].y, z = body.p.z + rel[h.tie].z}
		return math.sqrt((h.ax - t.x) ^ 2 + (h.ay - t.y) ^ 2 + (h.az - t.z) ^ 2) - h.length
	end
	-- attached: the anchor is at the grip, the rope is slack, no force
	run(0.5)
	check(math.abs(body.p.x) < 0.001 and math.abs(body.p.y) < 0.001, "rope attached: the vehicle doesn't move by itself")
	-- move the anchor 5 m to the side (moving, winch off): rope is paid out, the vehicle stays
	for i = 1, 30 do
		veh.handRope(2, 0.8 + 5 * i / 30, 0.3, 0, 1)
		run(1 / 30)
	end
	run(1)
	local _, slack, len = lastState()
	check(math.abs(body.p.y) < 0.01 and slack == 1 and math.abs(len - 5) < 0.1,
		string.format("moving the anchor pays out rope, the vehicle stays (y = %.3f, rope %.1f m)", body.p.y, len or -1))
	-- anchor placed, winch on: pulled slowly towards the anchor
	veh.handRope(2, 5.8, 0.3, 1, 0)
	local maxSpeed = 0
	body.forces = {}
	run(3, function() maxSpeed = math.max(maxSpeed, speed()) end)
	check(maxSpeed <= 1.05 and maxSpeed > 0.8, string.format("winch pulls slowly: at most 1 m/s (%.2f)", maxSpeed))
	check(body.p.y > 1.8 and body.p.y < 3.6, string.format("after 3 s about 2-3 m pulled (%.1f m)", body.p.y))
	local heavyF, lightF = 0, 0
	for cid, f in pairs(body.forces) do
		if rel[cid].m >= 180 then heavyF = heavyF + f else lightF = lightF + f end
	end
	check(heavyF > 5 * lightF, "the force goes mostly to the heavy nodes (no bent panels)")
	local endSpeed = nil
	run(8, function()
		local h = veh.handInfo()
		if not endSpeed and h.length <= 0.6 then endSpeed = speed() end
	end)
	check(endSpeed and endSpeed < 0.5, string.format("the winch slows down towards the end (%.2f m/s)", endSpeed or -1))
	-- a rope can't brake: the vehicle rolls on past the anchor and is caught by the short rope
	check(math.abs(body.p.y - 5) <= 0.6 and speed() < 0.05,
		string.format("rolled on, caught by the rope at most 0.5 m past the anchor (%.2f m)", body.p.y))
	local strainNow = lastState()
	check(strainNow and strainNow < 0.3, "strain low when it's easy (" .. tostring(strainNow) .. ")")
	-- winch off: the rope keeps its length; a rope never pushes
	veh.handRope(2, 5.8, 0.3, 0, 0)
	run(2)
	body.v = {x = 0, y = 0, z = 0}
	local gy = body.p.y + 0.8
	veh.handRope(2, gy + 3, 0.3, 0, 1)   -- move the anchor 3 m away: rope paid out to 3 m
	run(0.5)
	veh.handRope(2, gy + 1, 0.3, 0, 0)   -- anchor placed 1 m from the grip: shorter than the rope
	local yHold = body.p.y
	body.f = {x = 0, y = 0, z = 0}
	veh.onPhysicsStep(PHYS)
	check(body.f.x == 0 and body.f.y == 0 and body.f.z == 0, "a slack rope doesn't push")
	run(1)
	check(math.abs(body.p.y - yHold) < 0.05, "winch off, rope slack: nothing moves")
	-- lifting: anchor high above, winch on; 60 % of the weight can't float the whole car
	veh.handRope(body.p.x + 2, body.p.y + 0.8, 4, 1, 0)
	run(6)
	check(body.p.z < 0.05, string.format("60 %% of the weight doesn't lift the whole vehicle (z = %.2f)", body.p.z))
	local strainLift = lastState()
	check(strainLift and strainLift > 0.95, "strain reported back: at the limit while lifting (" .. tostring(strainLift) .. ")")
	local peak = 0
	run(0.5, function() peak = math.max(peak, math.sqrt(body.f.x ^ 2 + body.f.y ^ 2 + body.f.z ^ 2)) end)
	check(peak <= WEIGHT * 0.6 * 1.05, string.format("the winch stalls at 60 %% of the weight (%.0f N)", peak))
	-- 150 %: it lifts, as fast as the motor manages under the load
	local ax, ay = body.p.x + 2, body.p.y + 0.8
	veh.handRope(ax, ay, 4, 1, 0, 1, 150)
	local z0 = body.p.z
	run(4)
	local liftSpeed = (body.p.z - z0) / 4
	check(body.p.z > 0.6 and liftSpeed < 0.6,
		string.format("with 150 %% it lifts the vehicle, the motor slower under the load (z = %.2f, %.2f m/s)", body.p.z, liftSpeed))
	-- winch stopped: the vehicle hangs still, the rope stiff (a few cm), no springing up and down
	veh.handRope(ax, ay, 4, 0, 0, 1, 150)
	run(0.5)
	local lo, hi = math.huge, -math.huge
	run(2, function() lo, hi = math.min(lo, body.p.z), math.max(hi, body.p.z) end)
	check(hi - lo < 0.01, string.format("winch stopped: the vehicle hangs still, no bouncing (%.3f m up and down)", hi - lo))
	check(stretch() > 0 and stretch() < 0.05, string.format("the rope stretches only a few cm under the weight (%.3f m)", stretch()))
	-- pay out: the rope gets longer at the winch speed, the lifted vehicle comes down
	veh.handRope(ax, ay, 4, -1, 0, 1, 150)
	local zStart, dropFastest = body.p.z, 0
	run(0.6, function() dropFastest = math.max(dropFastest, -body.v.z) end)
	local _, _, lenBefore = lastState()
	run(1, function() dropFastest = math.max(dropFastest, -body.v.z) end)
	local _, _, lenAfter = lastState()
	check(lenBefore and lenAfter and lenAfter - lenBefore > 0.9 and lenAfter - lenBefore < 1.1,
		string.format("pay out: the drum speeds up, then the rope gets 1 m/s longer (%.2f -> %.2f m)", lenBefore or -1, lenAfter or -1))
	check(veh.handInfo() ~= nil and body.p.z < zStart - 0.5 and dropFastest < 1.15,
		string.format("the hanging vehicle comes down with the rope, it doesn't drop into it (at most %.2f m/s)", dropFastest))
	-- stopped, the drum is locked: even with 30 % (far less than the vehicle's weight) it holds
	veh.handRope(ax, ay, 4, 1, 0, 1, 150)
	run(3)
	veh.handRope(ax, ay, 4, 0, 0, 1, 30)
	local zHang, fastest = body.p.z, 0
	run(2, function() fastest = math.max(fastest, -body.v.z) end)
	check(zHang > 0.5 and math.abs(body.p.z - zHang) < 0.03 and veh.handInfo() ~= nil,
		string.format("stopped, the drum is locked: the strength doesn't matter, it holds the hanging vehicle (%.2f -> %.2f m)", zHang, body.p.z))
	veh.handRelease()
	body.f = {x = 0, y = 0, z = 0}
	body.frameF = {x = 0, y = 0, z = 0}
	veh.onPhysicsStep(PHYS)
	veh.updateGFX(1 / 60)
	check(body.f.x == 0 and body.f.y == 0 and body.f.z == 0 and body.frameF.x == 0 and body.frameF.y == 0
		and body.frameF.z == 0 and veh.handInfo() == nil, "released: no force any more")
	run(3)
	-- the rope snaps on a shock load: a vehicle driving away from a taut rope; a gentle jerk holds
	local function tautRope(away)
		body.p, body.v, body.ge = {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0}, {}
		veh.handGrab(2, 0.8, 0.3, 1, 60)
		veh.handRope(2, 4.8, 0.3, 0, 0, 1, 60)   -- anchor 4 m away, rope as long as that
		run(0.2)
		body.v = {x = 0, y = -away, z = 0}
		run(1)
	end
	tautRope(0.5)
	check(veh.handInfo() ~= nil and body.p.y > -0.4, string.format("a gentle jerk (0.5 m/s): the rope holds (y = %.2f)", body.p.y))
	veh.handRelease()
	tautRope(4)
	check(veh.handInfo() == nil and lost() == 4, "a hard jerk (4 m/s): the rope snaps and says so (onHandLost 4)")
	-- handbrake on (static friction = 50 % of the weight): 60 % pulls it loose, 30 % can't
	body.p, body.v = {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0}
	body.brake = WEIGHT * 0.5
	veh.handGrab(2, 0.8, 0.3, 1, 60)
	veh.handRope(2, 4.8, 0.3, 1, 0, 1, 60)   -- anchor 4 m away, winch hauling in
	run(5)
	check(body.p.y > 0.5, string.format("handbrake on, 60 %%: the winch pulls it loose (%.2f m)", body.p.y))
	veh.handRelease()
	body.p, body.v = {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0}
	veh.handGrab(2, 0.8, 0.3, 1, 30)
	veh.handRope(2, 4.8, 0.3, 1, 0, 1, 30)
	run(5)
	local strain30 = lastState()
	check(body.p.y < 0.01 and strain30 and strain30 > 0.95,
		string.format("30 %% against a 50 %% handbrake: the winch stalls, strain at the limit (%.2f)", strain30 or -1))
	veh.handRelease()
	body.brake = nil
	-- a game without the physics-step hook: the rope runs once per frame, softer, but still works
	veh = loadVeh(false)
	body.p, body.v, body.ge = {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0}, {}
	veh.handGrab(2, 0.8, 0.3, 1, 60)
	veh.handRope(2, 4.8, 0.3, 1, 0, 1, 60)
	local fastestFrame = 0
	for _ = 1, 180 do
		body.f, body.frameF = {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0}
		veh.updateGFX(1 / 60)
		for _ = 1, GFX_EVERY do integrate(PHYS) end
		fastestFrame = math.max(fastestFrame, speed())
	end
	check(body.p.y > 1.5 and fastestFrame < 1.1,
		string.format("without the physics step: pulled once per frame, still steady (%.2f m, at most %.2f m/s)", body.p.y, fastestFrame))
	veh.handRelease()
	-- an error in the physics step (e.g. a changed game function): logged once, the rope goes on per
	-- frame instead of taking the vehicle down
	veh = loadVeh(true)
	local env = getfenv(veh.onPhysicsStep)
	local logged = {}
	env.log = function(level, area, msg) table.insert(logged, level .. " " .. msg) end
	env.obj.applyForceVector = function() error("applyForceVector changed") end
	body.p, body.v, body.ge = {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0}, {}
	veh.handGrab(2, 0.8, 0.3, 1, 60)
	veh.handRope(2, 4.8, 0.3, 1, 0, 1, 60)
	local ok = pcall(run, 3)
	check(ok and #logged == 1 and logged[1]:find("^E .*applyForceVector changed") and body.p.y > 1,
		string.format("an error in the physics step is logged once, the rope goes on per frame (%d logs, %.2f m)", #logged, body.p.y))
	env.obj.applyForceVector = function(_, cid, f) addForce(cid, f) end
	veh.handRelease()
end

--== 7b5. Our own node grabber: GE side (picking, anchor, Tow app) ===========
resetWorld()
installCareer()
local grabKeys = {}
_G.MPKeybindsGE = {addAction = function(name, def) grabKeys[name] = def end}
extensions.hook("onWorldReadyState", 2)
local cfgG = {}
for k, v in pairs(config) do cfgG[k] = v end
cfgG.allowGrab, cfgG.grabSpeed, cfgG.grabStrength, cfgG.allowTowToRoad = true, 1, 150, true
handlers.sc_config(json.encode(cfgG))
update()
local function placedVeh(id, x, y, z, jbeam, remote)
	local v = addVehicle(id, (remote and "7-" or "0-") .. id, not remote, jbeam)
	v.p = {x = x, y = y, z = z}
	v.getPosition = function(self) return self.p end
	return v
end
-- last hand command sent to a vehicle: name and numbers
local function lastHand(v)
	for i = #v.lua, 1, -1 do
		local name, args = v.lua[i]:match("sharedCareerVeh%.(hand%a+)%(([^)]*)%)")
		if name then
			local nums = {}
			for n in args:gmatch("[-%d%.]+") do table.insert(nums, tonumber(n)) end
			return name, nums
		end
	end
end
-- the vehicle's rope report (onHandState), repeated 10 times per second like the vehicle does
local alive = nil
local function handState(...)
	alive = {...}
	sharedCareer_grab.onHandState(...)
end
local function frames(seconds, dt)
	dt = dt or 1 / 60
	for i = 1, math.floor(seconds / dt + 0.5) do
		if alive and i % 6 == 0 and sharedCareer_grab.isHolding() then sharedCareer_grab.onHandState(unpack(alive)) end
		extensions.hook("onUpdate", dt)
	end
end
local cam = {x = 0, y = 0, z = 2}
local fwd = nil
_G.core_camera = {getPosition = function() return cam end, getForward = function() return fwd end}
local truck = placedVeh(60, 10, 0, 1)
local ropeKeys = 0
for keyName in pairs(grabKeys) do if keyName:find("Grab") then ropeKeys = ropeKeys + 1 end end
check(ropeKeys == 0, "no keys for the rope: everything runs in the Tow app")
-- attach where I look: the view ray passes the truck
fwd = {x = 1, y = 0, z = -0.1}
check(sharedCareer_grab.uiAttachView(), "attach where I look")
local name, a = lastHand(truck)
check(sharedCareer_grab.isHolding() and name == "handGrabRay", "rope attached: the view ray is sent to the vehicle")
check(a and a[1] == 0 and a[2] == 0 and a[3] == 2 and a[4] > 0.99 and a[7] == 120 and a[8] == 1 and a[9] == 60,
	"camera position, view direction, speed 1 m/s and strength 60 % sent along")
frames(0.2)
check(lastHand(truck) == "handGrabRay", "nothing is sent until the vehicle reports where the rope is tied")
-- the vehicle reports where it grabbed: the anchor starts there
sharedCareer_grab.onGrip(60, 9.0, 9, 0, 1)
handState(60, 9, 0, 1, 0, 1, 0)
frames(0.1)
name, a = lastHand(truck)
check(name == "handRope" and a[1] == 9 and a[2] == 0 and a[3] == 1 and a[4] == 0 and a[5] == 0,
	"anchor starts at the grip; winch off, not moving")
local sent = #truck.lua
frames(1)
check(#truck.lua - sent >= 25 and #truck.lua - sent <= 35, "rope state sent about 30 times per second")
-- looking around: the anchor stays
fwd = {x = 0, y = 1, z = 0}
frames(0.2)
name, a = lastHand(truck)
check(a[1] == 9 and a[2] == 0, "looking around: the anchor stays where it is")
-- winch on
sharedCareer_grab.uiWinch(1)
frames(0.1)
name, a = lastHand(truck)
check(a[4] == 1, "winch on")
-- move the anchor 4 m towards you with the remote (seen from the camera: x is forward)
fwd = {x = 1, y = 0, z = 0}
sharedCareer_grab.uiNudge(-1, 0, 0)
frames(4)
sharedCareer_grab.uiNudgeStop()
frames(0.1)
name, a = lastHand(truck)
check(math.abs(a[1] - 5) < 0.1 and a[2] == 0 and a[5] == 0, string.format("anchor moved with the remote (x = %.2f)", a[1]))
-- settings change live
cfgG.grabSpeed, cfgG.grabStrength = 0.5, 200
handlers.sc_configUpdate(json.encode(cfgG))
frames(0.1)
name, a = lastHand(truck)
check(a[6] == 0.5 and a[7] == 60, "settings applied live; the player's pick (60 %) stays")
-- pull strength picked in the Tow app, capped at the server's maximum
sharedCareer_grab.uiStrength(150)
frames(0.1)
name, a = lastHand(truck)
local st = sharedCareer_grab.appState()
check(a[7] == 150 and st.strength == 150 and st.maxStrength == 150 and #st.strengths == 4,
	"Tow app: 150 % picked, sent to the vehicle right away")
cfgG.grabStrength = 100
handlers.sc_configUpdate(json.encode(cfgG))
frames(0.1)
name, a = lastHand(truck)
st = sharedCareer_grab.appState()
check(a[7] == 100 and st.strength == 100 and #st.strengths == 3 and st.strengths[3] == 100,
	"server maximum 100 %: the pick is capped, 150 % is not offered")
cfgG.grabStrength = 80
handlers.sc_configUpdate(json.encode(cfgG))
st = sharedCareer_grab.appState()
check(st.strengths[#st.strengths] == 80 and st.strength == 80, "odd server maximum (80 %) is offered as its own choice")
sharedCareer_grab.uiStrength(60)
cfgG.grabSpeed, cfgG.grabStrength = 1, 150
handlers.sc_configUpdate(json.encode(cfgG))
-- drawing: rope grey when slack, the color of the rope's own load when taut (its color while safe,
-- orange when high, red near breaking); anchor color shows the state. (Looking nowhere here: the
-- winch gauge, which faces the camera, is tested on its own below.)
fwd = nil
local drawn = {}
-- like in the game: ColorF and vec3 are callable constructors, not Lua functions (0.10.1 bug)
_G.ColorF = setmetatable({}, {__call = function(_, r, g, b, alpha) return {r = r, g = g, b = b, a = alpha} end})
_G.vec3 = setmetatable({}, {__call = function(_, x, y, z) return {x = x, y = y, z = z} end})
_G.debugDrawer = {drawLine = function(_, p1, p2, c) table.insert(drawn, {p1 = p1, p2 = p2, c = c}) end}
local function near(x, want) return math.abs(x - want) < 0.02 end
handState(60, 9, 0, 1, 0.1, 0, 4, 0.1)
frames(0.5)
drawn = {}
frames(1 / 60)
check(#drawn == 11 and drawn[1].p1.x == 9 and near(drawn[1].c.r, 0.88) and near(drawn[1].c.g, 0.84),
	"taut rope (lines only): line, grip and pin as crosses, in the rope's own color while it is safe")
check(drawn[5].c.r == 1 and drawn[5].c.g < 0.6, "winch running: orange anchor")
handState(60, 9, 0, 1, 1, 0, 4, 0.1)
frames(0.5)
drawn = {}
frames(1 / 60)
check(near(drawn[1].c.r, 0.88) and near(drawn[1].c.g, 0.84), "the winch at its limit: no danger for the rope, its color stays")
handState(60, 9, 0, 1, 1, 0, 4, 0.55)
drawn = {}
frames(1 / 60)
check(drawn[1].c.g < 0.8 and drawn[1].c.g > 0.62 and drawn[1].c.r > 0.9, string.format("high rope load: orange (g = %.2f)", drawn[1].c.g))
handState(60, 9, 0, 1, 1, 0, 4, 0.95)
drawn = {}
frames(1 / 60)
check(drawn[1].c.r > 0.99 and drawn[1].c.g < 0.3, "near breaking: red")
local lines = {}
for _ = 1, 6 do
	drawn = {}
	frames(1 / 60)
	lines[#drawn] = true
end
local trembles = 0
for _ in pairs(lines) do trembles = trembles + 1 end
check(trembles > 1, "near breaking: the rope trembles")
-- a short jolt: the next report is low again, the red fades back slowly so it is seen
handState(60, 9, 0, 1, 1, 0, 4, 0.1)
drawn = {}
frames(0.2)
check(drawn[1].c.g < 0.6, "a jolt stays visible for a moment")
frames(1)
drawn = {}
frames(1 / 60)
check(near(drawn[1].c.g, 0.84), "then the rope's own color again")
sharedCareer_grab.uiWinch(0)
handState(60, 9, 0, 1, 0, 1, 4)
frames(1)
drawn = {}
frames(1 / 60)
check(near(drawn[1].c.r, 0.7) and near(drawn[1].c.g, 0.7) and drawn[#drawn - 2].c.r == 1 and drawn[#drawn - 2].c.g == 1,
	"slack rope: grey line (faded); winch off: white anchor")
sharedCareer_grab.uiNudge(0, 0, 0)
drawn = {}
frames(1 / 60)
check(drawn[#drawn - 2].c.b > 0.9 and drawn[#drawn - 2].c.r < 0.5, "moving the anchor: cyan anchor")
sharedCareer_grab.uiNudgeStop()
do
-- sag: a slack rope is drawn as a curve below the straight line, a taut one straight
check(sharedCareer_grab.sagDepth(4, 4, 4) == 0 and sharedCareer_grab.sagDepth(4, 4, 3) == 0,
	"sag: none when the rope is as long as the distance or shorter")
local s5 = sharedCareer_grab.sagDepth(4, 4, 5)
check(math.abs(s5 - math.sqrt(1.5)) < 1e-6 and 4 + 8 * s5 ^ 2 / 12 == 5, "sag: parabola about as long as the rope")
check(sharedCareer_grab.sagDepth(4, 0, 6) == 0 and sharedCareer_grab.sagDepth(4, 2, 6) < sharedCareer_grab.sagDepth(4, 4, 6),
	"sag: a steep rope hangs along itself")
check(sharedCareer_grab.sagDepth(10, 10, 60) == 6, "sag: limited")
local function lowest()
	local z = math.huge
	for _, d in ipairs(drawn) do z = math.min(z, d.p2.z) end
	return z
end
handState(60, 9, 0, 1, 0, 1, 30)   -- slack, rope much longer than the distance
drawn = {}
frames(1 / 60)
local curve = #drawn
frames(1)
drawn = {}
frames(1 / 60)
local deep = lowest()
check(curve > 7 and deep < 1 - 0.5, string.format("slack rope sags (%d lines, lowest %.2f)", curve, deep))
handState(60, 9, 0, 1, 0.5, 0, 4)  -- pulled taut
drawn = {}
frames(1 / 60)
local midway = #drawn > 11 and lowest() > deep
frames(1)
drawn = {}
frames(1 / 60)
check(midway and #drawn == 11, "taut again: the curve straightens smoothly, then a straight line")
-- with spheres, cylinders and text: grip ball, anchor pin, sign only while the Tow app is open
local shapes = {}
local lineOnly = _G.debugDrawer
_G.String = function(t) return {str = t} end
_G.ColorI = function(r, g, b, a) return {r = r, g = g, b = b, a = a} end
_G.debugDrawer = {
	drawLine = function(_, p1, p2, c) table.insert(shapes, {kind = "line", c = c}) end,
	drawSphere = function(_, p, r, c) table.insert(shapes, {kind = "sphere", p = p, r = r, c = c}) end,
	drawCylinder = function(_, a, b, r, c) table.insert(shapes, {kind = "cylinder", a = a, b = b, c = c}) end,
	drawTextAdvanced = function(_, p, t, c) table.insert(shapes, {kind = "text", p = p, t = t.str}) end,
}
local function count(kind)
	local n = 0
	for _, x in ipairs(shapes) do if x.kind == kind then n = n + 1 end end
	return n
end
local function find(kind)
	for _, x in ipairs(shapes) do if x.kind == kind then return x end end
end
sharedCareer_grab.resetShapes()
shapes = {}
frames(1 / 60)
check(count("line") == 1 and count("sphere") == 3 and count("cylinder") == 2 and count("text") == 0,
	string.format("shapes: rope (line + cylinder), grip ball, pin (post + 2 balls), no sign with the app closed (%d/%d/%d/%d)",
		count("line"), count("sphere"), count("cylinder"), count("text")))
local post = shapes[#shapes - 2]
check(post.kind == "cylinder" and post.b.z > post.a.z + 0.5, "anchor pin: a post standing up from the anchor")
check(find("cylinder").a.x == 9 and math.abs(find("cylinder").b.x - 5) < 0.1, "rope: a cylinder from the grip to the anchor")
sharedCareer_grab.setAppOpen(true)
shapes = {}
frames(1 / 60)
local sg = find("text")
check(sg and sg.t == "Locked", "Tow app open, winch stopped: the sign says it is locked (" .. tostring(sg and sg.t) .. ")")
sharedCareer_grab.uiWinch(1)
shapes = {}
frames(1 / 60)
sg = find("text")
check(sg and sg.t:find("^Winch %d+ %%"), "hauling in: the sign shows the winch's load (" .. tostring(sg and sg.t) .. ")")
sharedCareer_grab.uiWinch(0)
sharedCareer_grab.setAppOpen(false)
-- winch hauling in: the pin's ball pulses
sharedCareer_grab.uiWinch(1)
local radii = {}
for _ = 1, 20 do
	shapes = {}
	frames(1 / 30)
	local biggest = 0
	for _, x in ipairs(shapes) do if x.kind == "sphere" then biggest = math.max(biggest, x.r) end end
	radii[#radii + 1] = biggest
end
local lo, hi = math.huge, 0
for _, r in ipairs(radii) do lo, hi = math.min(lo, r), math.max(hi, r) end
check(hi - lo > 0.03, string.format("winch hauling in: the anchor ball pulses (%.3f-%.3f)", lo, hi))
sharedCareer_grab.uiWinch(0)
-- a missing shape falls back to lines, without errors
_G.debugDrawer.drawSphere = nil
shapes = {}
frames(1 / 60)
check(count("sphere") == 0 and count("line") > 6 and count("cylinder") == 2, "no drawSphere: balls drawn as crosses")
_G.debugDrawer, _G.String, _G.ColorI = lineOnly, nil, nil
sharedCareer_grab.resetShapes()
-- the winch gauge above the anchor: a ring facing the camera that fills with the winch's load
fwd = {x = 1, y = 0, z = 0}
local function gauge()
	drawn = {}
	frames(1 / 60)
	local ring, filled, red = 0, 0, 0
	for _, d in ipairs(drawn) do
		local midZ = (d.p1.z + d.p2.z) / 2
		if math.abs(d.p1.x - d.p2.x) < 1e-6 and midZ > 1.7 and midZ < 2.3 then -- a ring in the y-z plane, facing +x
			ring = ring + 1
			if d.c.a > 0.3 then filled = filled + 1 end
			if d.c.r > 0.99 and d.c.g < 0.3 then red = red + 1 end -- red blinks: counted by color
		end
	end
	return ring, filled, red
end
sharedCareer_grab.uiWinch(1)
handState(60, 9, 0, 1, 0.5, 0, 4, 0.1)
frames(0.3)
local ring, filled, red = gauge()
check(ring >= 24 and filled >= 20 and filled <= 28 and red == 0,
	string.format("winch at half its limit: the gauge is half full (%d of 48 lines filled)", filled))
handState(60, 9, 0, 1, 1, 0, 4, 0.1)
ring, filled, red = gauge()
check(red >= 46, "winch at its limit: the gauge is full and red (it blinks)")
sharedCareer_grab.uiWinch(0)
handState(60, 9, 0, 1, 0, 1, 4, 0)
ring = gauge()
check(ring == 0, "rope slack and the winch stopped: no gauge")
fwd = nil
end
-- winch marks: light marks travel with the rope while it runs through the winch, at its speed
do
local function dist(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end
local function marks()
	local out = {}
	for _, d in ipairs(drawn) do
		if math.abs(dist(d.p1, d.p2) - 0.12) < 0.01 then table.insert(out, d) end
	end
	return out
end
-- distance of the mark nearest to the anchor (the rope line ends at the anchor)
local function markPhase()
	local anchor, best = drawn[1].p2, math.huge
	for _, d in ipairs(marks()) do best = math.min(best, dist(d.p2, anchor)) end
	return best
end
-- the vehicle reports a rope that gets shorter (rate < 0) or longer, 10 times per second
local function runRope(rate, seconds)
	alive = nil
	local length = 4
	for _ = 1, seconds * 10 do
		length = length + rate * 0.1
		sharedCareer_grab.onHandState(60, 9, 0, 1, 0.5, 0, length)
		frames(0.1)
	end
	drawn = {}
	frames(1 / 60)
	local before = markPhase()
	drawn = {}
	frames(1 / 60)
	local moved = (markPhase() - before + 0.3) % 0.6 - 0.3
	return #marks(), moved
end
local n, moved = runRope(-0.5, 1)
check(n >= 4 and moved < -0.003, string.format("hauling in: marks on the rope travel to the anchor (%d marks, %.4f m)", n, moved))
n, moved = runRope(0.5, 1)
check(n >= 4 and moved > 0.003, string.format("paying out: the marks travel to the vehicle (%d marks, %.4f m)", n, moved))
n = runRope(0, 1.5)
check(n == 0, "the rope stands (stuck, or the winch stopped): no marks")
n = runRope(-30, 1)
check(n == 0, "the rope length jumps (anchor to my view): no racing marks")
handState(60, 9, 0, 1, 0.5, 0, 4)
end
-- let go: a taut rope snaps back to the anchor and fades out, then nothing is drawn
do
frames(0.5)
drawn = {}
frames(1 / 60)
local anchorAt = drawn[1].p2
sharedCareer_grab.uiRelease()
check(not sharedCareer_grab.isHolding() and lastHand(truck) == "handRelease", "remove rope: handRelease sent")
drawn = {}
frames(1 / 60)
local snapStart = drawn[1]
frames(0.1)
drawn = {}
frames(1 / 60)
local function toAnchor(d) return math.abs(d.p1.x - anchorAt.x) + math.abs(d.p1.y - anchorAt.y) + math.abs(d.p1.z - anchorAt.z) end
check(snapStart and drawn[1] and toAnchor(drawn[1]) < toAnchor(snapStart) - 1 and drawn[1].c.a < snapStart.c.a,
	"let go (taut): the loose end snaps back to the anchor and fades out")
frames(0.5)
drawn = {}
frames(1 / 60)
check(#drawn == 0, "let go: gone after a moment")
end
-- staying in step with the vehicle: every way the rope can be lost ends in a clean release
do
local function lastToast()
	for i = #toasts, 1, -1 do if toasts[i].msg then return toasts[i].msg end end
	return ""
end
local function attachTruck()
	alive = nil
	fwd = {x = 1, y = 0, z = -0.1}
	sharedCareer_grab.uiAttachView()
	sharedCareer_grab.onGrip(60, 9.0, 9, 0, 1, 7)
	handState(60, 9, 0, 1, 0, 1, 0)
end
fwd = {x = 1, y = 0, z = -0.1}
alive = nil
sharedCareer_grab.uiAttachView()
frames(2.5)
check(not sharedCareer_grab.isHolding() and lastToast():find("Can't attach"),
	"the vehicle never reports a grip: released after 2 s, with a message")
attachTruck()
alive = nil
frames(1.5)
check(sharedCareer_grab.isHolding(), "a short silence is fine")
frames(1)
check(not sharedCareer_grab.isHolding() and lastToast():find("came loose"),
	"no word from the vehicle for 2 s (its Lua was reloaded): released")
attachTruck()
alive = nil
for _ = 1, 300 do extensions.hook("onUpdate", 1 / 60, 0) end
check(sharedCareer_grab.isHolding(), "game paused (no game time): the watchdog waits")
attachTruck()
sharedCareer_grab.onHandLost(60, 1)
check(not sharedCareer_grab.isHolding() and lastToast():find("reset"), "the vehicle drops the rope after a reset: released")
attachTruck()
sharedCareer_grab.onHandLost(60, 3)
check(not sharedCareer_grab.isHolding() and lastToast():find("tore off"), "a torn-off part: released with its own message")
attachTruck()
sharedCareer_grab.onHandLost(60, 4)
check(not sharedCareer_grab.isHolding() and lastToast():find("snapped"), "the rope snapped (overload): released with its own message")
attachTruck()
sharedCareer_grab.onHandLost(61, 1)
check(sharedCareer_grab.isHolding(), "another vehicle's report doesn't touch the rope")
extensions.hook("onVehicleResetted", 60)
check(not sharedCareer_grab.isHolding() and lastHand(truck) == "handRelease", "vehicle reset (R): rope removed")
-- a hitch: the anchor remote moves at most MAX_STEP worth
attachTruck()
frames(0.1)
fwd = {x = 1, y = 0, z = 0}
sharedCareer_grab.uiNudge(1, 0, 0)
frames(1, 1)
sharedCareer_grab.uiNudgeStop()
frames(0.1)
local _, h = lastHand(truck)
check(h and math.abs(h[1] - 9.1) < 0.02, string.format("a 1 s hitch moves the anchor only 0.1 m (x = %.2f)", h and h[1] or -1))
-- the rope end follows the tie node every frame, not only on the reports
truck.getNodePosition = function(_, cid) return cid == 7 and {x = -0.5, y = 0.2, z = 0} or nil end
truck.p = {x = 10, y = 0, z = 1}
drawn = {}
frames(1 / 60)
check(math.abs(drawn[1].p1.x - 9.5) < 1e-6 and math.abs(drawn[1].p1.y - 0.2) < 1e-6,
	"rope drawn from the tie node's position now (vehicle position + getNodePosition)")
truck.getNodePosition = function() return {x = 400, y = 0, z = 0} end
drawn = {}
frames(1 / 60)
check(drawn[1].p1.x == 9, "an implausible node position falls back to the last report")
truck.getNodePosition = nil
-- at the limit for a while (while hauling in): shown in the Tow app and on the sign
sharedCareer_grab.uiWinch(1)
handState(60, 9, 0, 1, 1, 0, 4)
frames(1)
check(not sharedCareer_grab.appState().stuck, "at the limit for a moment: not stuck yet")
frames(1.5)
check(sharedCareer_grab.appState().stuck, "at the limit for 2 s: the Tow app says so")
handState(60, 9, 0, 1, 0.3, 0, 4)
frames(0.2)
check(not sharedCareer_grab.appState().stuck, "it pulls easier again: no longer stuck")
handState(60, 9, 0, 1, 1, 0, 4)
sharedCareer_grab.uiWinch(0)
frames(2.5)
check(not sharedCareer_grab.appState().stuck, "stopped (locked): never stuck")
-- a floating anchor: dashed drop line and a disc on the ground (castRayStatic)
_G.castRayStatic = function(from, dir, range) return from.z - 0 end   -- ground at z = 0
sharedCareer_grab.uiNudge(0, 0, 1)
frames(1)
sharedCareer_grab.uiNudgeStop()
drawn = {}
frames(1 / 60)
local drops = 0
for _, d in ipairs(drawn) do
	if math.abs(d.p1.x - d.p2.x) < 1e-9 and math.abs(d.p1.y - d.p2.y) < 1e-9 and d.p2.z < 1 and d.p2.z >= 0 then drops = drops + 1 end
end
check(drops >= 4, "anchor 2 m above the ground: dashed drop line (" .. drops .. " dashes)")
local lowestDrop = math.huge
for _, d in ipairs(drawn) do lowestDrop = math.min(lowestDrop, d.p2.z) end
check(math.abs(lowestDrop) < 0.05, "the drop line reaches the ground")
_G.castRayStatic = nil
-- let go of a slack rope: its loose end drops and the rope fades out
handState(60, 9, 0, 1, 0, 1, 4)
frames(1)
sharedCareer_grab.uiRelease()
drawn = {}
frames(1 / 60)
local dropStart = drawn[1]
frames(0.3)
drawn = {}
frames(1 / 60)
check(dropStart and drawn[1] and drawn[1].p1.z < dropStart.p1.z - 0.2 and drawn[1].c.a < dropStart.c.a,
	"let go (slack): the loose end drops and the rope fades out")
frames(0.5)
alive = nil
end
-- preview: only while the Tow app is open (not just on foot); it aims with the view
local walkingNow = true
_G.gameplay_walk = {isWalking = function() return walkingNow end}
fwd = {x = 1, y = 0, z = -0.1}
local function probeCount(from)
	local c = 0
	for i = from + 1, #truck.lua do if truck.lua[i]:find("handProbe") then c = c + 1 end end
	return c
end
local before = #truck.lua
frames(1)
check(probeCount(before) == 0, "on foot without the Tow app: no preview")
sharedCareer_grab.setAppOpen(true)
before = #truck.lua
frames(1)
local probes = probeCount(before)
check(probes >= 4 and probes <= 6, "Tow app open: the vehicle is asked where the rope would attach (" .. probes .. "x per second)")
sharedCareer_grab.onProbe(60, 9, 0, 1)
drawn = {}
frames(1 / 60)
check(#drawn == 3 and drawn[1].c.b > 0.9, "preview: a blue cross where the rope would attach")
sharedCareer_grab.setAppOpen(false)
drawn = {}
frames(1 / 60)
check(#drawn == 0, "Tow app closed: preview gone")
fwd = nil
-- Tow app on the phone
local towApp
for _, app in ipairs(sharedCareer_phone.state().apps) do if app.id == "tow" then towApp = app end end
check(towApp and towApp.title == "Tow" and towApp.icon == "tow", "the Tow app is on the phone")
sharedCareer_phone.uiOpenApp("tow")
local appSt = sharedCareer_grab.appState()
check(appSt.allowed and not appSt.attached and #appSt.nearby >= 1 and appSt.nearby[1].id == 60
	and appSt.nearby[1].name == "Pickup", "not attached: own vehicles nearby are listed (" .. tostring(appSt.nearby[1] and appSt.nearby[1].name) .. ")")
for _, v in ipairs(appSt.nearby) do check(v.id ~= 61 and v.id ~= 62, "no other players' vehicles or players on foot in the list") end
-- attach from the list: at the vehicle's point closest to you
check(sharedCareer_grab.uiAttachVehicle(60) and lastHand(truck) == "handGrabNearest", "attach from the list: rope at the closest point")
sharedCareer_grab.onGrip(60, 9, 9, 0, 1)
handState(60, 9, 0, 1, 0, 1, 0)
appSt = sharedCareer_grab.appState()
check(appSt.attached and appSt.vehicle == "Pickup" and appSt.winch == 0, "app shows the roped vehicle, winch stopped")
-- remote control: hold "forward" -> the anchor moves away (seen from the camera), rope pays out
fwd = {x = 1, y = 0, z = 0}
sharedCareer_grab.uiNudge(1, 0, 0)
frames(1)
name, a = lastHand(truck)
check(math.abs(a[1] - 10) < 0.1 and a[5] == 1, string.format("hold forward: anchor 1 m/s away, rope pays out (x = %.2f)", a[1]))
sharedCareer_grab.uiNudge(0, 1, 0)
frames(1)
name, a = lastHand(truck)
check(math.abs(a[2] + 1) < 0.1, string.format("hold right: anchor 1 m to the right (y = %.2f)", a[2]))
sharedCareer_grab.uiNudge(0, 0, 1)
sharedCareer_grab.uiFine(true)
frames(1)
name, a = lastHand(truck)
check(math.abs(a[3] - 1.25) < 0.05 and a[6] == 0.25, string.format("fine mode: up at a quarter speed, winch quarter speed (z = %.2f)", a[3]))
sharedCareer_grab.uiFine(false)
sharedCareer_grab.uiNudgeStop()
frames(0.2)
name, a = lastHand(truck)
check(a[5] == 0, "button released: anchor stays, rope no longer pays out")
-- winch: haul in / stop / pay out
sharedCareer_grab.uiWinch(1)
frames(0.1)
check(select(2, lastHand(truck))[4] == 1, "winch: haul in")
sharedCareer_grab.uiWinch(-1)
frames(0.1)
check(select(2, lastHand(truck))[4] == -1, "winch: pay out")
sharedCareer_grab.uiWinch(0)
frames(0.1)
check(select(2, lastHand(truck))[4] == 0, "winch: stop")
-- anchor to the middle of the view at its distance
fwd = {x = 0, y = 1, z = 0}
sharedCareer_grab.uiAnchorToView()
frames(1 / 60)
name, a = lastHand(truck)
check(math.abs(a[1]) < 0.1 and a[2] > 3 and a[5] == 1, "anchor to my view: placed in the middle of the view, rope pays out once")
frames(0.1)
check(select(2, lastHand(truck))[5] == 0, "... only once")
sharedCareer_grab.uiRelease()
check(not sharedCareer_grab.isHolding() and lastHand(truck) == "handRelease", "remove rope from the app")
-- tow to the road: the game's own recovery (damage stays), free, for the vehicle on the rope
local towed = {}
_G.spawn = {teleportToLastRoad = function(veh, opts) table.insert(towed, {id = veh:getID(), opts = opts}) end}
local towToasts = {}
local realToast = sharedCareer_util.toast
sharedCareer_util.toast = function(_, msg) table.insert(towToasts, msg) end
check(sharedCareer_grab.appState().towToRoad == true, "Tow app: tow to the road offered")
fwd = {x = -1, y = -1, z = 0}
check(not sharedCareer_grab.uiTowToRoad() and #towed == 0 and towToasts[#towToasts]:find("Look at"),
	"tow to the road without a rope: needs a vehicle in view")
fwd = {x = 1, y = 0, z = -0.1}
check(sharedCareer_grab.uiTowToRoad() and #towed == 1 and towed[1].id == 60 and towed[1].opts.resetVehicle == false,
	"tow to the road without a rope: the vehicle you look at")
towed = {}
sharedCareer_grab.uiAttachView()
truck.getVelocity = function() return {x = 5, y = 0, z = 0} end
check(not sharedCareer_grab.uiTowToRoad() and #towed == 0 and towToasts[#towToasts]:find("Stop the vehicle"),
	"tow to the road: not while the vehicle moves")
truck.getVelocity = function() return {x = 0.1, y = 0, z = 0} end
_G.gameplay_traffic = {getTrafficData = function() return {[60] = {pursuit = {mode = 1}}} end}
check(not sharedCareer_grab.uiTowToRoad() and #towed == 0 and towToasts[#towToasts]:find("police"),
	"tow to the road: not during a police chase")
_G.gameplay_traffic = {getTrafficData = function() return {[60] = {pursuit = {mode = 0}}} end}
check(sharedCareer_grab.uiTowToRoad() and #towed == 1 and towed[1].id == 60 and towed[1].opts.resetVehicle == false,
	"tow to the road with a rope: the vehicle on the rope, damage kept")
check(not sharedCareer_grab.isHolding() and lastHand(truck) == "handRelease", "tow to the road: the rope comes off")
sharedCareer_grab.uiAttachView()
cfgG.allowTowToRoad = false
handlers.sc_configUpdate(json.encode(cfgG))
check(sharedCareer_grab.appState().towToRoad == false and not sharedCareer_grab.uiTowToRoad() and #towed == 1,
	"tow to the road switched off on the server")
cfgG.allowTowToRoad = true
handlers.sc_configUpdate(json.encode(cfgG))
sharedCareer_grab.release()
truck.getVelocity, fwd = nil, nil
_G.spawn, _G.gameplay_traffic = nil, nil
sharedCareer_util.toast = realToast
sharedCareer_phone.uiCloseApp("tow")
fwd = nil
-- switched off on the server: the app leaves the phone
cfgG.allowGrab = false
handlers.sc_configUpdate(json.encode(cfgG))
local stillThere = false
for _, app in ipairs(sharedCareer_phone.state().apps) do if app.id == "tow" then stillThere = true end end
check(not stillThere, "grabbing switched off: the Tow app leaves the phone")
cfgG.allowGrab = true
handlers.sc_configUpdate(json.encode(cfgG))
_G.gameplay_walk, _G.debugDrawer, _G.ColorF, _G.vec3 = nil, nil, nil, nil
-- the last toast message (the Tow app's state goes through the same guihooks mock)
local function lastToast()
	for i = #toasts, 1, -1 do if toasts[i].msg then return toasts[i].msg end end
	return ""
end
-- the vehicle you sit in can't be grabbed (the camera would move with it)
fwd = {x = 1, y = 0, z = -0.1}
world.playerVeh = 60
toasts = {}
sharedCareer_grab.uiAttachView()
check(not sharedCareer_grab.isHolding() and lastToast():find("Get out"), "the vehicle you are in can't be grabbed")
core_camera.getActiveGlobalCameraName = function() return "free" end
sharedCareer_grab.uiAttachView()
check(sharedCareer_grab.isHolding(), "from the free camera it can")
sharedCareer_grab.release()
core_camera.getActiveGlobalCameraName = nil
world.playerVeh = nil
-- refusals (attach where I look)
local function tryGrab(dir)
	fwd = dir
	toasts = {}
	sharedCareer_grab.uiAttachView()
	local held = sharedCareer_grab.isHolding()
	sharedCareer_grab.release()
	return held, lastToast()
end
placedVeh(61, -10, 10, 1, nil, true)
local held, msg = tryGrab({x = -1, y = 1, z = -0.1})
check(not held and msg:find("your own"), "another player's vehicle can't be grabbed")
placedVeh(62, 0, -10, 1, "unicycle")
held, msg = tryGrab({x = 0, y = -1, z = -0.1})
check(not held and msg:find("on foot"), "a player on foot can't be grabbed")
held, msg = tryGrab({x = -1, y = -1, z = 0})
check(not held and msg:find("Look at"), "no vehicle in view: hint")
held, msg = tryGrab(nil)
check(not held, "no view direction: nothing attached")
cfgG.allowGrab = false
handlers.sc_configUpdate(json.encode(cfgG))
held, msg = tryGrab({x = 1, y = 0, z = -0.1})
check(not held and msg:find("off on this server"), "switched off on the server: no grabbing")
cfgG.allowGrab = true
handlers.sc_configUpdate(json.encode(cfgG))
fwd = {x = 1, y = 0, z = -0.1}
sharedCareer_grab.uiAttachView()
cfgG.allowGrab = false
handlers.sc_configUpdate(json.encode(cfgG))
frames(0.05)
check(not sharedCareer_grab.isHolding() and lastHand(truck) == "handRelease", "switched off while holding: lets go")
fwd = nil
_G.core_camera, _G.MPKeybindsGE = nil, nil

--== 7b6. Phone ===============================================================
resetWorld()
installCareer()
local phoneKey
_G.MPKeybindsGE = {addAction = function(name, def) if name == "sharedCareerPhone" then phoneKey = def end end}
local phoneHooks = {}
_G.guihooks = {trigger = function(name, data) table.insert(phoneHooks, {name = name, data = data}) end}
extensions.hook("onWorldReadyState", 2)
local cfgP = {}
for k, v in pairs(config) do cfgP[k] = v end
cfgP.phone, cfgP.allowGrab = true, true
handlers.sc_config(json.encode(cfgP))
update()
local function lastPhone(name)
	for i = #phoneHooks, 1, -1 do if phoneHooks[i].name == name then return phoneHooks[i].data end end
end
check(phoneKey and phoneKey.default == "f4" and phoneKey.title:find("phone"), "phone key registered via BeamMP (F4)")
local st = lastPhone("SharedCareerPhone")
check(st and st.enabled == true and #st.apps == 2 and st.apps[1].id == "tow" and st.apps[2].id == "fuel",
	"phone on, with the built-in apps Tow and Fuel")
phoneHooks = {}
phoneKey.onDown()
check(lastPhone("SharedCareerPhoneToggle") ~= nil, "F4 takes the phone out / puts it away")
-- apps register themselves (for later): sorted by order, then title; no functions in the window state
local opened = 0
check(sharedCareer_phone.registerApp({id = "taxi", title = "Taxi", icon = "T", color = "#e0a800", order = 20,
	onOpen = function() opened = opened + 1 end}), "an app can register")
sharedCareer_phone.registerApp({id = "jobs", title = "Jobs", order = 10})
sharedCareer_phone.registerApp({id = "bank", title = "Bank", order = 10, onOpen = function() error("boom") end})
check(not sharedCareer_phone.registerApp({title = "no id"}), "an app without an id is refused")
st = lastPhone("SharedCareerPhone")
local ids = {}
for _, app in ipairs(st.apps) do table.insert(ids, app.id) end
check(table.concat(ids, ",") == "bank,jobs,tow,fuel,taxi", "apps sorted by order, then title: " .. table.concat(ids, ","))
check(st.apps[2].icon == "J" and st.apps[2].color == "#ff6600" and st.apps[1].onOpen == nil,
	"defaults for icon and color; no functions sent to the window")
check(sharedCareer_phone.uiOpenApp("taxi") == true and opened == 1, "a tap opens the app")
check(sharedCareer_phone.uiOpenApp("bank") == true, "an app that fails to open doesn't break the phone")
check(sharedCareer_phone.uiOpenApp("nope") == false, "unknown app: nothing happens")
sharedCareer_phone.unregisterApp("bank")
check(#lastPhone("SharedCareerPhone").apps == 4, "an app can be removed again")
-- switched off on the server: hidden, key does nothing, apps don't open
cfgP.phone = false
handlers.sc_configUpdate(json.encode(cfgP))
check(lastPhone("SharedCareerPhone").enabled == false, "switched off: the window hides the phone")
phoneHooks = {}
phoneKey.onDown()
check(lastPhone("SharedCareerPhoneToggle") == nil, "switched off: F4 does nothing")
check(sharedCareer_phone.uiOpenApp("taxi") == false and opened == 1, "switched off: apps don't open")
_G.MPKeybindsGE = nil

--== 7c. Time of day and pause menu ==========================================
resetWorld()
installCareer()
local env = sharedCareer_env
check(env.toGame(12) == 0 and env.toGame(18) == 0.25 and env.toGame(0) == 0.5 and env.toGame(6) == 0.75,
	"conversion hour -> BeamNG (0 = noon)")
check(env.fromGame(0.75) == 6 and env.hourDistance(23.9, 0.1) < 0.21, "conversion back and distance across midnight")
local tod = {time = env.toGame(9), play = false, dayLength = 1800, azimuthOverride = 0}
local setCalls = 0
_G.core_environment = {
	getTimeOfDay = function() return tod end,
	setTimeOfDay = function(t) setCalls = setCalls + 1; tod = t end,
}
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
handlers.sc_time(json.encode({hour = 18, dayLength = 3600, play = true}))
check(math.abs(tod.time - 0.25) < 1e-9 and tod.play == true and tod.dayLength == 3600, "server time applied")
check(tod.azimuthOverride == 0, "other time settings are kept")
local calls = setCalls
handlers.sc_time(json.encode({hour = 18.02, dayLength = 3600, play = true}))
check(setCalls == calls, "small difference (1 min) -> no jump")
handlers.sc_time(json.encode({hour = 20, dayLength = 3600, play = true}))
check(setCalls == calls + 1 and math.abs(env.fromGame(tod.time) - 20) < 1e-9, "large difference is corrected")
local cfgT = {}
for k, v in pairs(config) do cfgT[k] = v end
cfgT.syncTimeOfDay = false
handlers.sc_configUpdate(json.encode(cfgT))
calls = setCalls
handlers.sc_time(json.encode({hour = 3, dayLength = 3600, play = true}))
check(setCalls == calls, "switched off -> the player keeps their time")

-- day/night speed: at the switch at 20:00 the client switches by itself
cfgT.syncTimeOfDay = true
handlers.sc_configUpdate(json.encode(cfgT))
local msgDN = {hour = 19.99, play = true, dayLength = 4628, dayLengthDay = 4628, dayLengthNight = 2160, dayStart = 6, nightStart = 20}
handlers.sc_time(json.encode(msgDN))
check(tod.dayLength == 4628 and tod.play == true, "day speed during the day")
check(env.lengthFor(msgDN, 23) == 2160 and env.lengthFor(msgDN, 5.9) == 2160 and env.lengthFor(msgDN, 6) == 4628,
	"day/night boundaries correct")
tod.time = env.toGame(20.01) -- the game ran past 20:00 by itself
update(1.1)
check(tod.dayLength == 2160, "night speed from 20:00, without a server message")
check(math.abs(env.fromGame(tod.time) - 20.01) < 1e-6, "switching does not change the time")
calls = setCalls
update(1.1)
check(setCalls == calls, "no constant resetting")

-- UI window: state and control
local uiEvents = {}
_G.guihooks = {trigger = function(name, data) if name == "SharedCareerState" then table.insert(uiEvents, data) end end}
sharedCareer_menu.onBeamMPServerLeave() -- nothing visible
handlers.sc_time(json.encode({hour = 19.5, play = true, dayLength = 3600, dayLengthDay = 3600, dayLengthNight = 720,
	dayStart = 6, nightStart = 20, dayMinutes = 50, nightMinutes = 5, canControl = true}))
update(1.1); update(1.1)
check(#uiEvents == 0, "menu collapsed, phone away: no state built or sent (neither on news nor every second)")
sharedCareer_menu.uiVisible("menu", true)
check(#uiEvents == 1, "menu expanded: the state comes at once")
local ui = uiEvents[#uiEvents]
check(ui and ui.connected and ui.canControl and ui.isDay == true, "window gets the state (day, may control)")
check(ui and math.abs(ui.secondsToSwitch - 0.5 * 3600 / 24) < 1, "time until night correct (0.5 h = 75 s)")
check(ui.dayMinutes == 50 and ui.nightMinutes == 5, "lengths for the window")
local n = #uiEvents
update(1.1)
check(#uiEvents > n, "window is updated every second")
env.uiShiftHour(1)
local ctl = lastSent("sc_timeControl")
check(ctl and ctl.action == "set" and math.abs(ctl.hour - 20.5) < 0.01, "+1 h goes to the server")
env.uiShiftHour(-21)
check(math.abs(lastSent("sc_timeControl").hour - 22.5) < 0.01, "calculating across midnight")
env.uiSetLengths(45, 10)
ctl = lastSent("sc_timeControl")
check(ctl.action == "lengths" and ctl.dayMinutes == 45 and ctl.nightMinutes == 10, "lengths go to the server")

-- clock paused
env.uiSetPaused(true)
check(lastSent("sc_timeControl").action == "pause" and lastSent("sc_timeControl").paused == true, "pause goes to the server")
handlers.sc_time(json.encode({hour = 15, play = false, paused = true, dayLength = 0, dayStart = 6, nightStart = 20,
	dayMinutes = 50, nightMinutes = 5, canControl = true}))
check(tod.play == false and math.abs(env.fromGame(tod.time) - 15) < 1e-6, "paused: game clock stands at 15:00")
check(uiEvents[#uiEvents].paused == true, "window knows the clock is paused")
local setsPaused = setCalls
update(1.1); update(1.1)
check(setCalls == setsPaused, "paused: no speed switching")

do
local menu = sharedCareer_menu
-- who looks: reports with a lease (windows report every 2 s while visible)
local function pushesDuring(seconds, beat)
	local before, t, sinceBeat = #uiEvents, 0, 0
	while t < seconds - 1e-9 do
		update(0.5)
		t, sinceBeat = t + 0.5, sinceBeat + 0.5
		if beat and sinceBeat >= 2 then sinceBeat = 0; beat() end
	end
	return #uiEvents - before
end
menu.onBeamMPServerLeave()
menu.uiVisible("menu", true)
local kept = pushesDuring(10, function() menu.uiVisible("menu", true) end)
check(kept >= 9 and kept <= 11, "menu reports every 2 s: the state keeps coming every second (" .. kept .. " in 10 s)")
check(menu.isVisible("menu") and not menu.isVisible("phone") and not menu.isVisible("fuel"), "only the menu counts as visible")
local repeated = #uiEvents
menu.uiVisible("menu", true)
check(#uiEvents == repeated, "a repeated report sends nothing extra")
local tail = pushesDuring(5)
check(tail >= 4 and menu.isVisible("menu"), "no report for 5 s: still visible (lease)")
local afterLease = pushesDuring(1)
check(not menu.isVisible("menu"), "no report for more than 5 s: no longer visible")
check(pushesDuring(5) == 0, "a window that vanished without a word: no more updates")
menu.uiVisible("menu", true)
check(menu.isVisible("menu") and uiEvents[#uiEvents] ~= nil, "visible again: state at once")
menu.uiVisible("menu", false)
check(pushesDuring(3) == 0, "menu collapsed: updates stop at once")
handlers.sc_time(json.encode({hour = 15, play = false, paused = true, dayLength = 0, dayStart = 6, nightStart = 20,
	dayMinutes = 50, nightMinutes = 5, canControl = true}))
check(pushesDuring(0) == 0 and #uiEvents == repeated + tail + afterLease + 1, "news from the server while nothing is visible: not sent")
-- the phone's home screen (time, players) keeps the state coming, without fuel prices
local before = #uiEvents
menu.uiVisible("phone", true)
check(#uiEvents == before + 1 and uiEvents[#uiEvents].fuel == false and uiEvents[#uiEvents].hour ~= nil,
	"phone out: state at once, fuel = false (Fuel app closed)")
check(pushesDuring(2) >= 1 and uiEvents[#uiEvents].fuel == false, "phone out: every second, still without the station list")
check(uiEvents[#uiEvents].dayStart == 6 and uiEvents[#uiEvents].nightStart == 20,
	"phone out: day and night start for the home screen's bar")
-- the Fuel app open: fuel prices at once (nil: this test map has no gas stations)
local fuelAsked = 0
local realOverview = sharedCareer_fuel.overview
sharedCareer_fuel.overview = function() fuelAsked = fuelAsked + 1; return {stations = {{id = "apex"}}} end
before = #uiEvents
menu.uiVisible("fuel", true)
check(#uiEvents == before + 1 and type(uiEvents[#uiEvents].fuel) == "table" and fuelAsked == 1,
	"Fuel app open: prices at once")
local asked = fuelAsked
pushesDuring(3, function() menu.uiVisible("phone", true); menu.uiVisible("fuel", true) end)
check(fuelAsked - asked >= 2 and type(uiEvents[#uiEvents].fuel) == "table", "Fuel app open: prices every second")
menu.uiVisible("fuel", false)
asked = fuelAsked
pushesDuring(3, function() menu.uiVisible("phone", true) end)
check(fuelAsked == asked and uiEvents[#uiEvents].fuel == false, "Fuel app closed: no prices computed, phone still updated")
sharedCareer_fuel.overview = function() return nil end
menu.uiVisible("fuel", true)
check(uiEvents[#uiEvents].fuel == nil, "Fuel app open on a map without stations: fuel = nil (empty list, not false)")
sharedCareer_fuel.overview = function() error("broken") end
menu.uiVisible("fuel", false); menu.uiVisible("fuel", true)
check(uiEvents[#uiEvents].hour ~= nil and uiEvents[#uiEvents].fuel == nil, "a fuel error doesn't break the rest of the state")
sharedCareer_fuel.overview = realOverview
-- odd reports are ignored; uiRequest (window rebuilt) always answers; leaving the server resets
before = #uiEvents
menu.uiVisible("radio", true)
check(#uiEvents == before and not menu.isVisible("radio"), "unknown view: ignored")
menu.uiVisible("menu", "yes")
check(not menu.isVisible("menu"), "a report that isn't true counts as not visible")
menu.onBeamMPServerLeave()
check(not menu.anyVisible() and pushesDuring(2) == 0, "leaving the server: nothing visible")
menu.uiRequest()
check(#uiEvents == before + 1, "a rebuilt window asks and gets the state, even if nothing reported yet")
end

-- pause menu lock
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
	"time/weather locked in the pause menu")
check(settings.getValue("restrictScenarios") ~= true, "lock only applies during the page, not globally")
pause.requestEnvironmentTrafficPayload({editable = true})
check(seen.editable == false, "traffic page read-only")
cfgT.lockEnvironment = false
cfgT.syncTimeOfDay = true
handlers.sc_configUpdate(json.encode(cfgT))
check(pause.getEnvironmentData().locked == false, "lockEnvironment = false unlocks the menu")
_G.ui_pause_providers_routeData_environment = nil
_G.core_environment = nil

--== 7d. Cleaning up Mileage leftovers =======================================
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
check(table.concat(names, ",") == "tacho2,beammpChat,beammpPlayerListVue", "Mileage apps gone, BeamMP player list back: " .. table.concat(names, ","))
check(career.apps[3].placement.top == "240px", "BeamMP list in place of the Mileage list")
local free = files["/settings/ui_apps/layouts/default/freeroam.uilayout.json"]
check(#free.apps == 1 and free.apps[1].appName == "beammpPlayerListVue", "no duplicate player list")
check(files["/settings/ui_apps/layouts/default/career.uilayout.json.sharedcareer-backup"].apps[3].appName == "mileageplayerlist",
	"original is backed up first")
check(files["/settings/ui_apps/layouts/default/eigenes.uilayout.json.sharedcareer-backup"] == nil,
	"unchanged layouts are not touched")
check(#toasts > toastsBefore, "player gets a notice")
check(sharedCareer_cleanup.run() == 0, "second run finds nothing")
-- switched off
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
check(lastSent("sc_careerResult") and lastSent("sc_careerResult").ok == true and findCalls == 0, "switched off: cleanup does not run")

--== 7e. SharedCareer apps into the career layout once ========================
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
local function hasMenuApp(layout)
	for _, a in ipairs(layout and layout.apps or {}) do if a.appName == "sharedCareerMenu" then return true end end
	return false
end
-- 1) player without an own career layout: original + window
joinWith({[ORIGINAL] = {apps = {{appName = "tacho2"}}, title = "career"}})
check(hasMenuApp(files[CUSTOM]) and files[CUSTOM].apps[1].appName == "tacho2", "window added to the career layout (from the original)")
check(files[CUSTOM].apps[2].placement.top == "600px", "placed right, below the player list")
check(files["settings/sharedCareer/state.json"].menuAppAdded == true, "remembered: already added")
local phoneApp
for _, a in ipairs(files[CUSTOM].apps) do if a.appName == "sharedCareerPhone" then phoneApp = a end end
check(phoneApp and phoneApp.placement.top == "760px" and phoneApp.placement.width == "30px"
	and files["settings/sharedCareer/state.json"].phoneAppAdded == true,
	"phone tab added once, directly below the menu, only as big as the tab")
-- 2) player removes it again -> NOT added again on the next join
local removedLayout = {apps = {{appName = "tacho2"}}}
joinWith({[CUSTOM] = removedLayout, ["settings/sharedCareer/state.json"] = {menuAppAdded = true}})
check(not hasMenuApp(files[CUSTOM]), "removed window is not forced back")
-- 3) own layout is kept, a backup is created
joinWith({[CUSTOM] = {apps = {{appName = "meineApp"}}}})
check(files[CUSTOM].apps[1].appName == "meineApp" and hasMenuApp(files[CUSTOM]), "own layout stays, window is added")
check(files[CUSTOM .. ".sharedcareer-backup"].apps[1].appName == "meineApp", "backup of the own layout")
-- 4) already there (added by the player) -> not twice
joinWith({[CUSTOM] = {apps = {{appName = "sharedCareerMenu"}}}})
local menuCount, phoneCount = 0, 0
for _, a in ipairs(files[CUSTOM].apps) do
	if a.appName == "sharedCareerMenu" then menuCount = menuCount + 1 end
	if a.appName == "sharedCareerPhone" then phoneCount = phoneCount + 1 end
end
check(menuCount == 1 and phoneCount == 1, "menu not duplicated, phone tab is added")
-- phone: own flag – players who remove the phone tab don't get it back
joinWith({[CUSTOM] = {apps = {{appName = "sharedCareerMenu"}}},
	["settings/sharedCareer/state.json"] = {menuAppAdded = true, phoneAppAdded = true, fuelAppRetired = true, phoneTabUp = true}})
local phoneBack = 0
for _, a in ipairs(files[CUSTOM].apps) do if a.appName == "sharedCareerPhone" then phoneBack = phoneBack + 1 end end
check(phoneBack == 0, "removed phone tab is not forced back")
-- update from 0.12: the separate fuel window is gone (it's on the phone now) -> taken out once,
-- and the phone tab moves up to its place, directly below the menu
joinWith({[CUSTOM] = {apps = {{appName = "sharedCareerMenu", placement = {right = "0px", top = "600px"}},
	{appName = "sharedCareerFuel", placement = {right = "0px", top = "760px"}},
	{appName = "sharedCareerPhone", placement = {right = "0px", top = "920px"}}}},
	["settings/sharedCareer/state.json"] = {menuAppAdded = true, fuelAppAdded = true, phoneAppAdded = true}})
local names, phoneTop = {}, nil
for _, a in ipairs(files[CUSTOM].apps) do
	table.insert(names, a.appName)
	if a.appName == "sharedCareerPhone" then phoneTop = a.placement.top end
end
check(table.concat(names, ",") == "sharedCareerMenu,sharedCareerPhone",
	"old fuel window removed from the layout (no red 'Unknown app' box): " .. table.concat(names, ","))
check(phoneTop == "760px" and files[CUSTOM].apps[1].placement.top == "600px", "phone tab moved up below the menu; menu stays")
local st = files["settings/sharedCareer/state.json"]
check(st.fuelAppRetired == true and st.phoneTabUp == true, "both changes remembered (only once)")
-- the player moved the phone tab somewhere else -> it stays there
joinWith({[CUSTOM] = {apps = {{appName = "sharedCareerPhone", placement = {right = "120px", top = "300px"}}}},
	["settings/sharedCareer/state.json"] = {menuAppAdded = true, phoneAppAdded = true}})
check(files[CUSTOM].apps[1].placement.right == "120px" and files[CUSTOM].apps[1].placement.top == "300px",
	"the player's own position stays")
-- 0.15.0: the menu app was renamed sharedCareerTime -> sharedCareerMenu
do
	local OTHER = "settings/ui_apps/layouts/default/freeroam.uilayout.json"
	local oldMenu = {appName = "sharedCareerTime", placement = {right = "0px", top = "650px"}}
	joinWith({}) -- fresh file mocks
	files[CUSTOM] = {apps = {{appName = "tacho2"}, oldMenu, {appName = "sharedCareerPhone"}}}
	files[OTHER] = {apps = {{appName = "sharedCareerTime"}, {appName = "sharedCareerMenu"}}}
	files["settings/sharedCareer/state.json"] = {timeAppAdded = true, phoneAppAdded = true}
	FS.findFiles = function(_, dir) return dir == "settings/ui_apps/layouts/" and {CUSTOM, OTHER} or {} end
	check(sharedCareer_cleanup.renameAppsOnce() == 2, "rename: one in the career layout, one duplicate elsewhere")
	local names = {}
	for _, a in ipairs(files[CUSTOM].apps) do table.insert(names, a.appName) end
	check(table.concat(names, ",") == "tacho2,sharedCareerMenu,sharedCareerPhone" and files[CUSTOM].apps[2].placement.top == "650px",
		"career layout: renamed in place, the player's position stays (" .. table.concat(names, ",") .. ")")
	check(#files[OTHER].apps == 1 and files[OTHER].apps[1].appName == "sharedCareerMenu", "other layout: the old duplicate is removed")
	local st = files["settings/sharedCareer/state.json"]
	check(st.menuAppRenamed == true and st.menuAppAdded == true and st.timeAppAdded == nil,
		"state: rename remembered, old flag timeAppAdded becomes menuAppAdded")
	check(sharedCareer_cleanup.addAppsOnce() == 0, "a menu the player once removed isn't added back after the rename")
	files[CUSTOM] = {apps = {{appName = "sharedCareerTime"}}}
	check(sharedCareer_cleanup.renameAppsOnce() == 0 and files[CUSTOM].apps[1].appName == "sharedCareerTime", "rename runs only once")
end
-- 5) switched off
joinWith({[ORIGINAL] = {apps = {}}}, {addApps = false})
check(files[CUSTOM] == nil, "addApps = false: nothing added")
-- 6) no layout found -> nothing broken, try again later
joinWith({})
check((files["settings/sharedCareer/state.json"] or {}).menuAppAdded == nil and lastSent("sc_careerResult").ok == true,
	"without a layout: career starts, retry next time")

--== 7f. Menu: live traffic with reserve ======================================
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
check(world.trafficSetup[1] == 8 and world.trafficSetup[3] == 7, "pool = share + reserve (4+4 / 3+4) spawned")
check(activeRoad == 4 and activeParked == 3, "only the share active, reserve hidden")
-- someone sets more in the menu: the server sends a new share
cfgM.trafficShare = {road = 7, parked = 2}
handlers.sc_configUpdate(json.encode(cfgM))
check(activeRoad == 7 and activeParked == 2, "live more/less within the pool")
cfgM.trafficShare = {road = 20, parked = 20}
handlers.sc_configUpdate(json.encode(cfgM))
check(activeRoad == 8 and activeParked == 7, "more than the pool: limited (rest on the next join)")
-- menu updated immediately when someone else changes something
local menuPushes = {}
_G.guihooks = {trigger = function(name, data) if name == "SharedCareerState" then table.insert(menuPushes, data) end end}
sharedCareer_menu.uiVisible("menu", false)
cfgM.roadTraffic = 8
handlers.sc_configUpdate(json.encode(cfgM))
check(#menuPushes == 0, "menu collapsed: another player's change is not sent to it")
sharedCareer_menu.uiVisible("menu", true)
check(#menuPushes == 1 and menuPushes[1].settings.roadTraffic == 8, "expanding the menu: it shows the current value at once")
menuPushes = {}
cfgM.roadTraffic = 9
handlers.sc_configUpdate(json.encode(cfgM))
check(#menuPushes == 1 and menuPushes[1].settings.roadTraffic == 9, "menu shows another player's change immediately (without the 1 s tick)")
local st = sharedCareer_menu.settingsState()
check(st.poolRoad == 8 and st.poolParked == 7 and st.canEdit == true and st.shareRoad == 20, "menu knows pool and share")
sharedCareer_menu.uiSetSetting("client.roadTraffic", 9)
check(lastSent("sc_setSetting").key == "client.roadTraffic" and lastSent("sc_setSetting").value == 9, "menu sends a setting")
local n2 = #sentToServer
sharedCareer_menu.uiSetSetting("client.saveSuffix", "x")
check(#sentToServer == n2, "menu only sends allowed settings")

--== 7g. Players tab, name tags and the menu key =============================
resetWorld()
installCareer()
local mpCalls = {}
MPVehicleGE.groundmarkerFollowPlayer = function(name) table.insert(mpCalls, {"nav", name}) end
MPVehicleGE.focusCameraOnPlayer = function(name) table.insert(mpCalls, {"watch", name}) end
MPVehicleGE.teleportVehToPlayer = function(name) table.insert(mpCalls, {"tp", name}) end
local suffixes = {}
MPVehicleGE.setPlayerNickSuffix = function(name, src, text) suffixes[name] = {src = src, text = text} end
local keyAction
_G.MPKeybindsGE = {addAction = function(name, def) if name == "sharedCareerMenu" then keyAction = {name = name, def = def} end end}
local toggled = 0
_G.guihooks = {trigger = function(n) if n == "SharedCareerToggle" then toggled = toggled + 1 end end}
local cfgPl = {}
for k, v in pairs(config) do cfgPl[k] = v end
cfgPl.ui = {allowTeleport = false}
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(cfgPl))
update()
check(keyAction and keyAction.def.default == "f7" and keyAction.def.title:find("SharedCareer"), "menu key via BeamMP (F7)")
keyAction.def.onDown()
check(toggled == 1, "key collapses/expands the menu")
check(lastSent("sc_status") and lastSent("sc_status").status == "driving", "own status reported")
_G.gameplay_missions_missionManager = {getForegroundMissionId = function() return "m1" end}
update(2.1)
check(lastSent("sc_status").status == "mission", "mission is detected")
handlers.sc_players(json.encode({players = {{id = 0, name = "John Doe_99", status = "mission"},
	{id = 1, name = "Ben", status = "mission"}, {id = 2, name = "Eve", status = "driving"}}}))
check(suffixes["Ben"] and suffixes["Ben"].text == "[Mission]" and suffixes["Ben"].src == "sharedCareer", "name tag: [Mission]")
check(suffixes["John Doe_99"] == nil, "own name tag unchanged")
handlers.sc_players(json.encode({players = {{id = 1, name = "Ben", status = "driving"}}}))
check(suffixes["Ben"].text == "", "status gone -> suffix removed (empty text, not nil)")
local ps = sharedCareer_players.state()
check(#ps.list == 1 and ps.canTeleport == false, "Players state for the menu")
sharedCareer_players.uiNavigate("Ben")
check(mpCalls[#mpCalls][1] == "nav" and mpCalls[#mpCalls][2] == "Ben" and sharedCareer_players.state().navigating == "Ben", "Navigate")
sharedCareer_players.uiStopNavigate()
check(mpCalls[#mpCalls][2] == nil and sharedCareer_players.state().navigating == nil, "stop navigation")
-- a job route after navigating to a player: following stops, or BeamMP puts the route back to the player
do
	local routes = {}
	_G.vec3 = function(x, y, z) return {x = x, y = y, z = z} end
	_G.core_groundMarkers = {setPath = function(p) table.insert(routes, p or false) end}
	sharedCareer_players.uiNavigate("Ben")
	sharedCareer_util.setRoute("jobs", {x = 7, y = 8, z = 9})
	check(mpCalls[#mpCalls][1] == "nav" and mpCalls[#mpCalls][2] == nil and sharedCareer_players.state().navigating == nil,
		"job route: following the player stops")
	check(routes[#routes] and routes[#routes].x == 7, "job route: route goes to the job")
	local before = #routes
	sharedCareer_players.uiStopNavigate()
	sharedCareer_util.clearRoute("fuel")
	check(#routes == before, "others don't clear the job route")
	sharedCareer_players.uiNavigate("Ben")
	sharedCareer_util.clearRoute("jobs")
	check(#routes == before and sharedCareer_players.state().navigating == "Ben", "job end keeps following the player")
	sharedCareer_players.uiStopNavigate()
	_G.vec3, _G.core_groundMarkers = nil, nil
end
local own = addVehicle(50, "0-50", true)
world.playerVeh = 50
local focus = {}
gameplay_traffic.setFocus = function(kind, opt) table.insert(focus, {kind, opt}) end
sharedCareer_players.uiWatch("Ben")
check(mpCalls[#mpCalls][1] == "watch" and focus[#focus][2].vehId == 50, "Watch: traffic stays around the own car")
world.playerVeh = 999
sharedCareer_players.uiBack()
check(world.playerVeh == 50 and focus[#focus][1] == nil, "Back: back into the own car")
local nCalls = #mpCalls
sharedCareer_players.uiTeleport("Ben")
check(#mpCalls == nCalls, "teleport forbidden if the server doesn't allow it")
cfgPl.ui.allowTeleport = true
handlers.sc_configUpdate(json.encode(cfgPl))
sharedCareer_players.uiTeleport("Ben")
check(mpCalls[#mpCalls][1] == "tp", "teleport allowed -> done")
cfgPl.showPlayerStatus = false
handlers.sc_players(json.encode({players = {{id = 1, name = "Ben", status = "walking"}}}))
handlers.sc_configUpdate(json.encode(cfgPl))
check(suffixes["Ben"].text == "", "status on name tags can be switched off")
_G.gameplay_missions_missionManager = nil
_G.MPKeybindsGE = nil

--== 7h. Shared fuel prices ==================================================
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
	-- rebuild of freeroam/facilities/fuelPrice.lua: base price + random part, signs, getFuelPrice
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
	freeroam_facilities_fuelPrice.setDisplayPrices() -- like when the map loads: rolled
	return signs
end

local signs = setupFuelWorld(false)
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
update()
handlers.sc_fuelPrices(json.encode({enabled = true, factors = {apex = {diesel = 0.9}}}))
update()
local fp = freeroam_facilities_fuelPrice
check(math.abs(fp.getFuelPrice("apex", "gasoline") - 1.5) < 1e-9, "without delivery: base price without random part (same for everyone)")
check(math.abs(fp.getFuelPrice("apex", "diesel") - 1.44) < 1e-9, "diesel 10 % cheaper (1.6 × 0.9)")
check(signs["apex/diesel"] == "1.440", "price sign shows the new price")
-- overview for the fuel app
_G.core_levels = {getLevelByName = function() return {localUnits = {gasoline = "gallonUS", diesel = "gallonUS"}} end}
freeroam_facilities.getAverageDoorPositionForFacility = function(st) return {x = 300, y = 400, z = 0} end
local meVeh = addVehicle(60, "0-60", true)
function meVeh:getPosition() return {x = 0, y = 0, z = 0} end
world.playerVeh = 60
-- before loading: no position yet -> must not remember "no position" permanently
local realPos = freeroam_facilities.getAverageDoorPositionForFacility
freeroam_facilities.getAverageDoorPositionForFacility = function() return nil end
check(sharedCareer_fuel.overview().stations[1].canNavigate == false, "position not known yet")
freeroam_facilities.getAverageDoorPositionForFacility = realPos
local ov = sharedCareer_fuel.overview()
local apexOv = ov and ov.stations[1]
check(apexOv and apexOv.id == "apex" and apexOv.fuels.diesel.unit == "gal", "overview: station with prices (map unit)")
check(math.abs(apexOv.fuels.diesel.price - 1.44 * 3.78541) < 1e-6 and apexOv.fuels.diesel.discount == 10, "price per gallon and discount")
check(apexOv.fuels.gasoline.discount == 0, "gasoline without discount")
check(math.abs(apexOv.distance - 500) < 1e-6 and apexOv.canNavigate == true, "distance to the player (500 m)")
local pathSet = "unset"
_G.core_groundMarkers = {setPath = function(pos) pathSet = pos end}
_G.vec3 = function(x, y, z) return {x = x, y = y, z = z} end
sharedCareer_fuel.uiNavigate("apex")
check(type(pathSet) == "table" and pathSet.x == 300 and sharedCareer_fuel.overview().navigating == "apex", "Go: route to the station")
sharedCareer_fuel.uiStopNavigate()
check(pathSet == nil and sharedCareer_fuel.overview().navigating == nil, "Stop: route off")
-- issue #1: the door function gives the same point for every gas station -> use the pumps
do
	local stationsNow = freeroam_facilities.getFacilities("west_coast_usa").gasStations
	stationsNow[1].pumps = {{"apex_pump_area_1", "apex_pump_icon_1"}, {"apex_pump_area_2", "apex_pump_icon_2"}}
	table.insert(stationsNow, {id = "trilobit", name = "Trilobit",
		pumps = {{"tri_pump_area_1", "tri_pump_icon_1"}},
		prices = {gasoline = {priceBaseline = 1.4, priceRandomnessGain = 0.2, priceRandomnessBias = 0.5}}})
	table.insert(stationsNow, {id = "nodeolin", name = "Nodeolin", pumps = {},
		prices = {gasoline = {priceBaseline = 1.45, priceRandomnessGain = 0.2, priceRandomnessBias = 0.5}}})
	freeroam_facilities_fuelPrice.setDisplayPrices()
	local objects = {
		apex_pump_area_1 = {x = 1000, y = 0, z = 10}, apex_pump_area_2 = {x = 1010, y = 0, z = 10},
		tri_pump_icon_1 = {x = 0, y = -2000, z = 20},   -- only the icon exists
	}
	local oldTree = _G.scenetree
	_G.scenetree = {findObject = function(name)
		local p = objects[name]
		return p and {getPosition = function() return p end} or nil
	end}
	freeroam_facilities.getAverageDoorPositionForFacility = function() return {x = 300, y = 400, z = 0} end
	sharedCareer_fuel.forgetPositions()
	local byId = {}
	for _, st in ipairs(sharedCareer_fuel.overview().stations) do byId[st.id] = st end
	check(byId.apex and math.abs(byId.apex.distance - 1005) < 1e-6, "issue #1: position = middle of the pumps (1005 m)")
	check(byId.trilobit and math.abs(byId.trilobit.distance - 2000) < 1e-6, "pump icon used when its area isn't there")
	check(byId.nodeolin and byId.nodeolin.distance == nil and byId.nodeolin.canNavigate == false,
		"no pumps found: the door point is shared by several stations, so it isn't used")
	local src = sharedCareer_fuel.positionSources()
	check(src.pumps == 2 and src.doors == 0 and src.none == 1, "position sources: 2 pumps, 1 unknown")
	_G.core_groundMarkers = {setPath = function(pos) pathSet = pos end}
	sharedCareer_fuel.uiNavigate("apex")
	check(type(pathSet) == "table" and pathSet.x == 1005 and pathSet.z == 10, "Go: route to the pumps, at their height")
	-- a believable door point of its own is still used as a fallback
	freeroam_facilities.getAverageDoorPositionForFacility = function(st)
		return st.id == "nodeolin" and {x = 0, y = 700, z = 5} or {x = 300, y = 400, z = 0}
	end
	sharedCareer_fuel.forgetPositions()
	byId = {}
	for _, st in ipairs(sharedCareer_fuel.overview().stations) do byId[st.id] = st end
	check(byId.nodeolin.distance == 700 and byId.apex.distance > 1000, "fallback: a station's own door point")
	-- the map origin is a placeholder, not a position
	freeroam_facilities.getAverageDoorPositionForFacility = function() return {x = 0, y = 0, z = 0} end
	sharedCareer_fuel.forgetPositions()
	byId = {}
	for _, st in ipairs(sharedCareer_fuel.overview().stations) do byId[st.id] = st end
	check(byId.nodeolin.distance == nil, "door point at the map origin is ignored")
	_G.scenetree = oldTree
	table.remove(stationsNow); table.remove(stationsNow); stationsNow[1].pumps = nil
	freeroam_facilities.getAverageDoorPositionForFacility = realPos
	sharedCareer_fuel.forgetPositions()
end
_G.core_levels, _G.core_groundMarkers = nil, nil

-- detecting deliveries
_G.career_modules_delivery_generator = {getFacilityById = function(id)
	if id == "apex_fuel" then return {name = "levels.wcusa.gasStationPoints.apex.title"} end
end}
local deliveredCalls = 0
_G.career_modules_delivery_progress = {onCargoDelivered = function(items) deliveredCalls = deliveredCalls + 1 end}
update(1.1)
career_modules_delivery_progress.onCargoDelivered({
	{materialType = "diesel", slots = 1500, location = {facId = "apex_fuel"}},
	{materialType = "diesel", slots = 500, location = {facId = "apex_fuel"}},
	{materialType = nil, slots = 1, location = {facId = "apex_fuel"}},            -- parcel
	{materialType = "gasoline", slots = 300, location = {facId = "farm_storage"}}, -- no gas station
})
check(deliveredCalls == 1, "original game function still runs")
local fd = lastSent("sc_fuelDelivered")
check(fd and fd.station == "apex" and fd.fuel == "diesel" and fd.amount == 2000, "diesel delivery to Apex reported (summed up)")
local nWrap = career_modules_delivery_progress.onCargoDelivered
update(1.1)
check(career_modules_delivery_progress.onCargoDelivered == nWrap, "not wrapped twice")
-- the server switches it off -> original prices (with random part) back
handlers.sc_fuelPrices(json.encode({enabled = false, factors = {}}))
update()
local g = fp.getFuelPrice("apex", "gasoline")
check(g >= 1.4 and g <= 1.6 and freeroam_facilities.getFacilities().gasStations[1].prices.gasoline.priceRandomnessGain == 0.2,
	"switched off: game prices as before")

-- the game only returns copies of the data -> fallback via getFuelPrice
setupFuelWorld(true)
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
update()
handlers.sc_fuelPrices(json.encode({enabled = true, factors = {apex = {diesel = 0.8}}}))
update()
check(math.abs(freeroam_facilities_fuelPrice.getFuelPrice("apex", "diesel") - 1.28) < 1e-9, "fallback: refueling at the right price")
_G.freeroam_facilities, _G.freeroam_facilities_fuelPrice = nil, nil
_G.career_modules_delivery_progress, _G.career_modules_delivery_generator = nil, nil

--== 7i. Welcome dialog ======================================================
local function welcomeJoin(stateFile, cfgChange)
	resetWorld()
	installCareer()
	local wfiles = {["settings/sharedCareer/state.json"] = stateFile}
	_G.jsonReadFile = function(path) return wfiles[path] and json.decode(json.encode(wfiles[path])) or nil end
	_G.jsonWriteFile = function(path, data) wfiles[path] = json.decode(json.encode(data)); return true end
	_G.FS = {fileExists = function() return false end, findFiles = function() return {} end}
	local dialogs = {}
	-- the dialog comes via the UI (guihook "SharedCareerDialog"); BeamMP's dialog must never be used
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
check(#dialogs == 0, "dialog not immediately (only after loading)")
for _ = 1, 50 do update(0.1) end
check(#dialogs == 1 and dialogs[1].title == "Welcome to SharedCareer", "welcome dialog after a few seconds")
check(#navigated == 1 and navigated[1] == "play", "main menu after the career start -> back into the game")
_G.ui_router.getCurrentRoute = function() return "play" end
navigated = {}
check(sharedCareer_welcome.ensurePlayScreen() == false and #navigated == 0, "already in the game: don't switch")
_G.ui_router = nil
check(dialogs[1].buttons[1].action == "never" and dialogs[1].buttons[1].label == "Don't show again", "button 'Don't show again'")
local allText = ""
for _, it in ipairs(dialogs[1].items) do allText = allText .. it.head .. " " .. it.text .. " " end
check(allText:find("F7") and allText:find("F4") and allText:find("/pay"), "lists the most important features")
for _ = 1, 50 do update(0.1) end
check(#dialogs == 1, "only once per join")
-- Regression 0.8.2: the window was hidden (main menu) and rebuilds itself -> dialog back
sharedCareer_welcome.uiRequestDialog()
check(#dialogs == 2 and dialogs[2].title == "Welcome to SharedCareer", "rebuilt window gets the open dialog")
-- player clicks "Don't show again" in the window
sharedCareer_welcome.uiDialogButton("welcome", "never")
check(wfiles["settings/sharedCareer/state.json"].welcomeHidden == true, "choice is saved")
sharedCareer_welcome.uiRequestDialog()
check(#dialogs == 2, "no open dialog after a button press")
-- next join: no dialog any more
dialogs = welcomeJoin({welcomeHidden = true})
for _ = 1, 60 do update(0.1) end
check(#dialogs == 0, "no dialog after 'Don't show again'")
sharedCareer_welcome.show(true)
check(#dialogs == 1, "click on the logo shows it anyway")
-- Regression 0.8.0: loading screen still open -> dialog only once it is gone
resetWorld()
installCareer({trafficHang = true})
local hangDialogs = {}
_G.jsonReadFile = function() return nil end
_G.jsonWriteFile = function() return true end
_G.FS = {fileExists = function() return false end, findFiles = function() return {} end}
_G.guihooks = {trigger = function(name, data) if name == "SharedCareerDialog" then table.insert(hangDialogs, data) end end}
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
for _ = 1, 300 do update(0.1) end -- 30 s: loading screen "careerVehicles" still hangs
check(#hangDialogs == 0, "no dialog while the loading screen is open")
for _ = 1, 400 do update(0.1) end -- the mod releases the loading screen after 60 s, then +3 s
check(#hangDialogs == 1, "dialog after the loading screen")
-- the server switches it off
dialogs = welcomeJoin(nil, {showWelcome = false})
for _ = 1, 60 do update(0.1) end
check(#dialogs == 0, "showWelcome = false: no dialog")
-- message from the server (e.g. guest notice) appears as a dialog in the window
handlers.sc_dialog(json.encode({title = "SharedCareer: you are playing as a guest", body = "Your progress...", warning = false}))
check(#dialogs == 1 and dialogs[1].kind == "server" and dialogs[1].title:find("guest") and dialogs[1].buttons[1].label == "OK",
	"server message as a dialog in the window")
_G.MPGameNetwork = nil

--== 7j. Damage: the owner's damage counts =====================================
;(function()
	resetWorld()
	installCareer()
	extensions.hook("onWorldReadyState", 2)
	handlers.sc_config(json.encode(config))
	local objects = {}
	_G.map = {objects = objects}
	local vecMeta = {}
	vecMeta.__index = {length = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end}
	vecMeta.__unm = function(a) return setmetatable({x = -a.x, y = -a.y, z = -a.z}, vecMeta) end
	_G.vec3 = function(x, y, z)
		if type(x) == "table" then x, y, z = x.x, x.y, x.z end
		return setmetatable({x = x, y = y, z = z}, vecMeta)
	end
	_G.quatFromDir = function() return {x = 0, y = 0, z = 0, w = 1} end
	local function remoteCar(gameId, serverId)
		local car = addVehicle(gameId, serverId, false)
		car.speed = 0
		car.getVelocity = function(self) return vec3(self.speed, 0, 0) end
		car.getPosition = function() return {x = 1, y = 2, z = 3} end
		car.getDirectionVector = function() return {x = 0, y = 1, z = 0} end
		car.getDirectionVectorUp = function() return {x = 0, y = 0, z = 1} end
		car.setPositionRotation = function(self, x, y, z) self.resetAt = {x, y, z} end
		car.resetBrokenFlexMesh = function(self) self.flexReset = true end
		objects[gameId] = {damage = 0}
		return car
	end
	local function hasCmd(v, pattern)
		for _, cmd in ipairs(v.lua) do if cmd:find(pattern) then return true end end
		return false
	end
	local function wait(seconds)
		for _ = 1, math.ceil(seconds / 0.6) do update(0.6) end
	end
	handlers.sc_vehStates(json.encode({["1-5"] = {active = true, traffic = false}, ["1-6"] = {active = true, traffic = false},
		["1-8"] = {active = true, traffic = true}}))
	local mine = addVehicle(40, "0-5", true)
	objects[40] = {damage = 0}
	local theirs = remoteCar(41, "1-5")

	-- own vehicle: sends its damage once the crash is over, only once
	wait(1.2)
	check(not hasCmd(mine, "damageSnapshot"), "undamaged own vehicle: nothing sent")
	objects[40].damage = 800
	update(0.6)
	check(not hasCmd(mine, "damageSnapshot"), "damage still changing: not yet")
	wait(1.8)
	check(hasCmd(mine, "damageSnapshot"), "crash over: the own vehicle sends its damage")
	mine.lua = {}
	wait(1.8)
	check(not hasCmd(mine, "damageSnapshot"), "the same damage is sent only once")
	sharedCareer_damage.onSnapshot(40, '{"nn":2,"bn":3,"n":[0,0,1,0],"d":[1,0.5,0.1],"b":[2]}')
	local msg = lastSent("sc_damage")
	check(msg and msg.id == "0-5" and msg.damage.bn == 3 and msg.damage.b[1] == 2, "own damage goes to the server")
	sentToServer = {}
	sharedCareer_damage.onSnapshot(40, '{"nn":2,"bn":3,"n":[0,0,1,0],"d":[1,0.5,0.1],"b":[2]}')
	check(lastSent("sc_damage") == nil, "the same damage is not sent twice")
	sharedCareer_damage.onSnapshot(41, '{"nn":2,"bn":3,"n":[],"d":[],"b":[]}')
	check(lastSent("sc_damage") == nil, "never sends the damage of someone else's vehicle")

	-- the owner's damage: loaded only while the car stands still
	local damage = {nn = 2, bn = 3, n = {0, 0, 1, 0}, d = {1, 0.5, 0.1}, b = {}}
	theirs.speed = 10
	handlers.sc_damage(json.encode({id = "1-5", damage = damage}))
	wait(3)
	check(not hasCmd(theirs, "damageLoad"), "driving: the damage waits")
	theirs.speed = 0.1
	update(0.6)
	check(not hasCmd(theirs, "damageLoad"), "just stopped: still waits a moment")
	wait(1.2)
	check(hasCmd(theirs, "damageLoad%(jsonDecode"), "standing still: the owner's damage is loaded")
	theirs.lua = {}
	wait(1.2)
	check(not hasCmd(theirs, "damageLoad"), "the same damage is loaded once")
	sharedCareer_damage.onReadyToLoad(41)
	check(theirs.resetAt and theirs.resetAt[1] == 1 and theirs.flexReset, "ready to load: reset in place")
	mine.resetAt = nil
	sharedCareer_damage.onReadyToLoad(40)
	check(mine.resetAt == nil, "never resets an own vehicle")

	-- arrives before the vehicle is spawned here: loaded once it is
	handlers.sc_damage(json.encode({id = "1-6", damage = damage}))
	update(0.6)
	local late = remoteCar(42, "1-6")
	wait(1.8)
	check(hasCmd(late, "damageLoad"), "damage for a vehicle spawned later: loaded once it's here")
	-- a new vehicle under the same server id: the old damage is forgotten
	handlers.sc_damage(json.encode({id = "1-6", cleared = true}))
	extensions.hook("onVehicleSpawned", 42)
	late.lua = {}
	wait(1.8)
	check(not hasCmd(late, "damageLoad"), "cleared damage: nothing loaded")

	-- traffic is left alone
	handlers.sc_damage(json.encode({id = "1-8", damage = damage}))
	local traffic = remoteCar(43, "1-8")
	wait(1.8)
	check(not hasCmd(traffic, "damageLoad"), "another player's traffic: damage not loaded")
	local ownTraffic = addVehicle(44, "0-9", true)
	ownTraffic.isTraffic = "true"
	objects[44] = {damage = 0}
	update(1.1)
	objects[44].damage = 900
	wait(2.4)
	check(not hasCmd(ownTraffic, "damageSnapshot"), "own traffic: damage not sent")

	-- crashed only here: ask the owner once the crash is over, not again right away
	wait(2)
	sentToServer = {}
	objects[41].damage = 300
	wait(2.4)
	msg = lastSent("sc_damageRequest")
	check(msg and msg.id == "1-5", "crashed only here: the owner is asked for his damage")
	sentToServer = {}
	objects[41].damage = 400
	wait(2.4)
	check(lastSent("sc_damageRequest") == nil, "not asked again within a few seconds")

	-- someone asks for our damage
	mine.lua = {}
	update(3)
	handlers.sc_damageRequest(json.encode({id = "0-5"}))
	check(hasCmd(mine, "damageSnapshot"), "asked for our damage: sent again")
	theirs.lua = {}
	handlers.sc_damageRequest(json.encode({id = "1-5"}))
	check(not hasCmd(theirs, "damageSnapshot"), "a request for someone else's vehicle is ignored")

	-- turned off on the server
	local off = {}
	for k, v in pairs(config) do off[k] = v end
	off.syncDamage = false
	handlers.sc_config(json.encode(off))
	mine.lua = {}
	objects[40].damage = 2000
	wait(2.4)
	check(not hasCmd(mine, "damageSnapshot"), "client.syncDamage = false: nothing is sent")
	_G.map, _G.vec3, _G.quatFromDir = nil, nil, nil
end)()

--== 7k. Damage: vehicle side ====================================================
;(function()
	local vecMeta = {}
	local function vec(x, y, z) return setmetatable({x = x, y = y, z = z}, vecMeta) end
	vecMeta.__index = {
		dot = function(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end,
		cross = function(a, b) return vec(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end,
	}
	vecMeta.__add = function(a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
	vecMeta.__mul = function(a, k) return vec(a.x * k, a.y * k, a.z * k) end
	-- 2 nodes, 4 beams: 0 fine, 1 bent, 2 broken, 3 a tire beam (moves by design, never sent)
	local nodes = {[0] = {cid = 0}, [1] = {cid = 1}}
	local beams = {[0] = {cid = 0}, [1] = {cid = 1}, [2] = {cid = 2}, [3] = {cid = 3, wheelID = 0}}
	local pos = {[0] = vec(0, 0, 0), [1] = vec(0, 2, 0.5)} -- owner faces +y: node 1 is 2 m ahead
	local rest = {[0] = 1, [1] = 1, [2] = 1, [3] = 1}
	local broken = {}
	local recorded = {}
	local dir, up = vec(0, 1, 0), vec(0, 0, 1)
	local ge, setPos, setLen, broke, deformed, committed = {}, {}, {}, {}, {}, 0
	local env = setmetatable({
		v = {data = {nodes = nodes, beams = beams}},
		jsonEncode = json.encode,
		beamstate = {deformedBeams = recorded, onBeamDeformed = function(cid, ratio) deformed[cid] = ratio end},
		obj = {
			getId = function() return 90 end,
			queueGameEngineLua = function(_, cmd) table.insert(ge, cmd) end,
			getDirectionVector = function() return dir end,
			getDirectionVectorUp = function() return up end,
			getNodePosition = function(_, cid) return pos[cid] end,
			setNodePosition = function(_, cid, p) setPos[cid] = p end,
			beamIsBroken = function(_, cid) return broken[cid] == true end,
			getBeamRestLength = function(_, cid) return rest[cid] end,
			setBeamLength = function(_, cid, len) setLen[cid] = len end,
			breakBeam = function(_, cid) broke[cid] = true end,
			commitLoad = function() committed = committed + 1 end,
		},
	}, {__index = _G})
	local chunk = assert(loadfile("client/lua/vehicle/extensions/auto/sharedCareerVeh.lua"))
	setfenv(chunk, env)
	local veh = chunk()
	veh.updateGFX(0.016) -- first frame: the undamaged rest lengths are read
	rest[1], broken[2], recorded[1] = 0.8, true, 0.2 -- the crash
	rest[0] = 1.002 -- settling of a healthy car: not bent
	rest[3] = 0.9   -- the tire
	veh.damageSnapshot()
	local raw = ge[#ge] and ge[#ge]:match('onSnapshot%(90, "(.*)"%)')
	local snap = raw and json.decode((raw:gsub('\\"', '"')))
	check(snap and snap.nn == 2 and snap.bn == 4, "snapshot: node and beam counts")
	check(snap and snap.n[5] == 1 and snap.n[6] == 0 and snap.n[7] == 2 and snap.n[8] == 0.5,
		"snapshot: node position in the vehicle's frame (right, forward, up)")
	check(snap and snap.d[1] == 1 and snap.d[2] == 0.8 and snap.d[3] == 0.2 and #snap.d == 3 and snap.b[1] == 2,
		"snapshot: only the bent body beam with its length and recorded deformation, and the broken beam")

	-- another PC, where the car faces +x: the shape is turned with it
	dir = vec(1, 0, 0)
	ge = {}
	veh.damageLoad(snap)
	check(ge[1] and ge[1]:find("sharedCareer_damage.onReadyToLoad%(90%)"), "takes the damage and asks for a reset")
	veh.updateGFX(0.016)
	check(committed == 0 and next(setPos) == nil, "nothing changes before the reset")
	veh.onReset()
	veh.updateGFX(0.016)
	local p = setPos[1]
	check(p and math.abs(p.x - 2) < 1e-9 and math.abs(p.y) < 1e-9 and math.abs(p.z - 0.5) < 1e-9,
		"after the reset: node placed in this car's frame")
	check(setLen[1] == 0.8 and math.abs(deformed[1] - 0.2) < 1e-6 and broke[2] and committed == 1,
		"bent beam, its deformation and the broken beam loaded, then committed")
	committed = 0
	veh.updateGFX(0.016)
	check(committed == 0, "loaded only once")
	-- a damage whose reset doesn't come is dropped, never loaded on a later reset
	veh.damageLoad(snap)
	for _ = 1, 150 do veh.updateGFX(0.016) end
	committed = 0
	veh.onReset()
	veh.updateGFX(0.016)
	check(committed == 0, "no reset within 2 s: the damage is dropped")
	-- another vehicle build: ignored
	ge = {}
	veh.damageLoad({nn = 3, bn = 4, n = {}, d = {}, b = {}})
	check(#ge == 0, "different node count: ignored")
end)()

--== 8. Money ===================================================================
resetWorld()
installCareer({money = 1000})
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
handlers.sc_payDebit(json.encode({id = "a", amount = 5000, to = "Ben"}))
check(lastSent("sc_payDebitResult").ok == false and career_modules_playerAttributes.money() == 1000,
	"not enough money -> nothing debited")
handlers.sc_payDebit(json.encode({id = "b", amount = 300, to = "Ben"}))
check(lastSent("sc_payDebitResult").ok == true and career_modules_playerAttributes.money() == 700, "abgebucht")
check((world.saved or 0) >= 1, "saved after debit")
handlers.sc_payDebit(json.encode({id = "b", amount = 300, to = "Ben"}))
check(career_modules_playerAttributes.money() == 700, "duplicate message doesn't debit twice")
handlers.sc_payCredit(json.encode({id = "c", amount = 50, from = "Ben"}))
handlers.sc_payCredit(json.encode({id = "c", amount = 50, from = "Ben"}))
check(career_modules_playerAttributes.money() == 750, "credit exactly once")
check(lastSent("sc_payCreditAck").id == "c", "credit confirmed")
handlers.sc_payDebit(json.encode({id = "d", amount = -100, to = "Ben"}))
check(lastSent("sc_payDebitResult").ok == false and career_modules_playerAttributes.money() == 750,
	"negative amount rejected")

--== 9. Leaving the server resets everything ====================================
extensions.hook("onBeamMPServerLeave")
check(sharedCareer_core.getConfig() == nil and not sharedCareer_core.isStarted(), "state reset")
check(settings.getValue("trafficSimpleVehicles") == false and settings.getValue("simplifyRemoteVehicles") == false,
	"the player's own settings restored")

--== 10. Towing jobs (beta) =====================================================
-- (in a function of its own: the main chunk is at Lua's limit of 200 local variables)
;(function()
	resetWorld()
	installCareer({money = 1000})
	extensions.hook("onWorldReadyState", 2)
	local cfgJ = json.decode(json.encode(config))
	cfgJ.ui, cfgJ.jobPay, cfgJ.phone = {jobs = true}, 1, true
	handlers.sc_config(json.encode(cfgJ))
	update()
	_G.vec3 = function(x, y, z) return {x = x, y = y, z = z} end
	_G.quatFromDir = function(d) return {dir = d} end
	_G.getCurrentLevelIdentifier = function() return "west_coast_usa" end
	_G.castRayStatic = nil
	local paths = {}
	_G.core_groundMarkers = {setPath = function(p) table.insert(paths, p or false) end}
	-- a straight road along x (nodes every 100 m, 4 m half width) and a dirt track that may not be used
	local nodes = {}
	for i = 0, 50 do nodes["n" .. i] = {pos = vec3(i * 100, 0, 10), radius = 4, links = {}} end
	for i = 0, 49 do
		nodes["n" .. i].links["n" .. (i + 1)] = {drivability = 1}
		nodes["n" .. (i + 1)].links["n" .. i] = {drivability = 1}
	end
	nodes.dirt = {pos = vec3(0, 3000, 10), radius = 4, links = {dirt2 = {drivability = 0.2}}}
	nodes.dirt2 = {pos = vec3(100, 3000, 10), radius = 4, links = {dirt = {drivability = 0.2}}}
	_G.map = {getMap = function() return {nodes = nodes} end}
	local doors = {belasco = {x = 4000, y = 50, z = 10}, home = {x = 0, y = 40, z = 10}}
	_G.freeroam_facilities = {
		getFacilities = function() return {garages = {{id = "belasco", name = "Belasco Auto"}, {id = "home", name = "Home Garage"}}, gasStations = {}} end,
		getAverageDoorPositionForFacility = function(f) return doors[f.id] end,
	}
	_G.jsonReadFile = function(path) if path:find("deliveryVehicles") then return {junkerVehFilter = {filter = {}}} end end
	_G.util_configListGenerator = {
		getEligibleVehicles = function() return {} end,
		getRandomVehicleInfos = function() return {{model_key = "fullsize", key = "base", Brand = "Gavril", Name = "Grand Marshal"}} end,
	}
	local me = addVehicle(70, "0-70", true)
	me.p = {x = 0, y = -20, z = 10}
	function me:getPosition() return self.p end
	world.playerVeh = 70
	local spawnedVeh
	core_vehicles.spawnNewVehicle = function(model, opt)
		spawnedVeh = addVehicle(80, "0-80", true, model)
		spawnedVeh.p = {x = opt.pos.x, y = opt.pos.y, z = opt.pos.z}
		spawnedVeh.v = {x = 0, y = 0, z = 0}
		function spawnedVeh:getPosition() return self.p end
		function spawnedVeh:getVelocity() return self.v end
		world.spawned = {model, opt}
		return spawnedVeh
	end
	local function lastCmd(v) return v.lua[#v.lua] or "" end
	local function lastToastMsg()
		for i = #toasts, 1, -1 do if toasts[i].msg then return toasts[i].msg end end
		return ""
	end
	local jobs = sharedCareer_jobs

	-- making up a job: on a normal road, off the road, far from every vehicle, a shop 0.8-6 km away
	check(jobs.payFor(1000, false) == 270 and jobs.payFor(1000, true) == 340, "pay: $150 + $120 per km, a flat tire pays 25 % more")
	handlers.sc_jobGenerate("")
	check(lastSent("sc_jobOffer") == nil, "before the server's job list (jobs on?) no job is made up")
	handlers.sc_jobs(json.encode({enabled = true, jobs = {}}))
	handlers.sc_jobGenerate("")
	local offer = lastSent("sc_jobOffer")
	check(offer and offer.vehicle.model == "fullsize" and offer.vehicle.config == "base" and offer.vehicle.name == "Gavril Grand Marshal",
		"made up a job with an old car from the career's delivery filter")
	local okAll = true
	for _ = 1, 60 do
		local job = jobs.generate()
		local destDist = math.sqrt((job.dest.pos.x - job.pos.x) ^ 2 + (job.dest.pos.y - job.pos.y) ^ 2)
		if math.abs(math.abs(job.pos.y) - 5.8) > 1e-6 or job.pos.x < 350 or destDist < 800 or destDist > 6000
			or job.pay ~= jobs.payFor(job.length, job.flatTire) then
			okAll = false
		end
	end
	check(okAll, "places: always beside the road (5.8 m from its middle), never near a vehicle or on a dirt track; shop 0.8-6 km away")
	cfgJ.jobPay = 2
	handlers.sc_configUpdate(json.encode(cfgJ))
	check(jobs.payFor(1000, false) == 540, "client.jobPay doubles the pay")
	cfgJ.jobPay = 1
	handlers.sc_configUpdate(json.encode(cfgJ))
	local sentBefore = #sentToServer
	local realFacilities = freeroam_facilities.getFacilities
	freeroam_facilities.getFacilities = function() return {} end
	handlers.sc_jobGenerate("")
	check(#sentToServer == sentBefore, "no repair shops on the map: no job")
	freeroam_facilities.getFacilities = realFacilities

	-- the list arrives: the Jobs app (beta) is on the phone
	local job = {id = 7, vehicle = {model = "fullsize", config = "base", name = "Gavril Grand Marshal"}, flatTire = true,
		pos = {x = 2000, y = -5.8, z = 10}, dir = {x = 1, y = 0}, dest = {name = "Belasco Auto", pos = doors.belasco},
		length = 2600, pay = 600}
	local function sendList(state)
		local j = json.decode(json.encode(job))
		j.state = state
		handlers.sc_jobs(json.encode({enabled = true, jobs = state and {j} or {}}))
	end
	sendList("open")
	local jobsApp
	for _, app in ipairs(sharedCareer_phone.state().apps) do if app.id == "jobs" then jobsApp = app end end
	check(jobsApp and jobsApp.beta == true and jobsApp.title == "Jobs", "the Jobs app is on the phone, marked as beta")
	local st = jobs.appState()
	check(st.enabled and #st.jobs == 1 and st.jobs[1].state == "open" and math.abs(st.jobs[1].distance - 2000) < 20,
		"the app lists the job with its distance from you")
	jobs.uiTake(7)
	check(lastSent("sc_jobTake").id == 7, "take: asks the server")
	sendList("mine")
	check(jobs.getActive() and paths[#paths].x == 2000, "the job is yours: route to the breakdown")
	-- far away: nothing spawned yet; within 400 m it appears there, broken down
	for _ = 1, 10 do update(0.1) end
	check(world.spawned == nil, "far away: the vehicle isn't there yet")
	me.p = {x = 1700, y = -20, z = 10}
	for _ = 1, 3 do update(0.1) end
	check(world.spawned and world.spawned[1] == "fullsize" and world.spawned[2].config == "base" and world.spawned[2].pos.x == 2000
		and world.spawned[2].autoEnterVehicle == false and world.spawned[2].rot, "within 400 m: the vehicle appears at its place")
	check(lastCmd(spawnedVeh):find("jobBreakDown%(true%)"), "it breaks down, with the flat tire of the job")
	local cmds = #spawnedVeh.lua
	for _ = 1, 35 do update(0.1) end
	check(#spawnedVeh.lua > cmds and lastCmd(spawnedVeh):find("jobBreakDown"), "no answer from the vehicle: broken down again")
	jobs.onJobBrokenDown(80, 100)
	-- close to it: the route goes to the shop
	me.p = {x = 1990, y = -20, z = 10}
	for _ = 1, 3 do update(0.1) end
	check(paths[#paths].x == 4000 and jobs.appState().active.phase == "toDestination", "near the vehicle: route to the repair shop")
	-- a reset repairs it: broken down again
	cmds = #spawnedVeh.lua
	extensions.hook("onVehicleResetted", 80)
	check(#spawnedVeh.lua == cmds + 1 and lastCmd(spawnedVeh):find("jobBreakDown%(true%)"), "reset (R): broken down again")
	jobs.onJobBrokenDown(80, 100)
	-- at the shop: someone inside doesn't count; standing still and empty for 3 s does
	spawnedVeh.p = {x = 4005, y = 52, z = 10}
	world.playerVeh = 80
	for _ = 1, 50 do update(0.1) end
	check(lastSent("sc_jobDone") == nil, "somebody sits in it: not handed over")
	world.playerVeh = 70
	spawnedVeh.v = {x = 2, y = 0, z = 0}
	for _ = 1, 50 do update(0.1) end
	check(lastSent("sc_jobDone") == nil, "still rolling: not handed over")
	spawnedVeh.v = {x = 0, y = 0, z = 0}
	for _ = 1, 35 do update(0.1) end
	check(lastCmd(spawnedVeh):find("jobReportDamage"), "standing still in the zone for 3 s: the vehicle is asked for its damage")
	jobs.onJobDamage(80, 100 + 20000)
	update(0.3)
	local done = lastSent("sc_jobDone")
	check(done and done.id == 7 and done.pay == 450, "new damage costs part of the pay (half the max: 25 %, $600 -> $450)")
	-- paid by the server: money in the career, the vehicle goes away a few seconds later
	local payout = json.encode({payout = "p-7", job = 7, pay = 450, vehicle = "Gavril Grand Marshal"})
	local realIsActive = career_career.isActive
	career_career.isActive = function() return false end
	handlers.sc_jobPaid(payout)
	check(career_modules_playerAttributes.money() == 1000 and lastSent("sc_jobPaidAck") == nil,
		"career not running (loading): not credited, not confirmed, the server sends it again")
	career_career.isActive = realIsActive
	local savesBefore = world.saved or 0
	handlers.sc_jobPaid(payout)
	check(career_modules_playerAttributes.money() == 1450 and lastToastMsg():find("%+%$450") and lastToastMsg():find("%$150 damage"),
		"paid: +$450 in the career, the deduction is shown")
	check((world.saved or 0) == savesBefore + 1 and lastSent("sc_jobPaidAck").payout == "p-7",
		"the career is saved, then the server gets the confirmation")
	local function acks()
		local n = 0
		for _, s in ipairs(sentToServer) do if s.event == "sc_jobPaidAck" then n = n + 1 end end
		return n
	end
	local acksBefore = acks()
	handlers.sc_jobPaid(payout)
	check(career_modules_playerAttributes.money() == 1450 and acks() == acksBefore + 1, "sent again: only confirmed, paid once")
	sendList(nil)
	check(jobs.getActive() ~= nil and not spawnedVeh.deleted, "the server drops the job: the vehicle stays a moment")
	for _ = 1, 70 do update(0.1) end
	check(spawnedVeh.deleted and jobs.getActive() == nil, "a few seconds after paying the vehicle is removed")

	-- no answer from the server after the drop-off: the job ends here after 15 s
	job.id = 10
	sendList("mine")
	me.p = {x = 1990, y = -20, z = 10}
	for _ = 1, 3 do update(0.1) end
	local unpaid = spawnedVeh
	jobs.onJobBrokenDown(80, 0)
	update(0.3)
	unpaid.p = {x = 4005, y = 52, z = 10}
	for _ = 1, 40 do update(0.1) end
	jobs.onJobDamage(80, 0)
	update(0.3)
	check(lastSent("sc_jobDone").id == 10 and jobs.getActive() ~= nil, "handed over, waiting for the server")
	for _ = 1, 160 do update(0.1) end
	check(jobs.getActive() == nil and unpaid.deleted and lastToastMsg():find("No answer"), "no answer within 15 s: ended here")
	-- a vehicle removed right away (server's vehicle limit): not spawned again at once, the player is told
	job.id = 11
	sendList("mine")
	for _ = 1, 3 do update(0.1) end
	local refused = spawnedVeh
	refused.deleted = true
	update(0.3)
	check(lastToastMsg():find("vehicle limit"), "removed right away: the player hears why")
	local firstRetry = spawnedVeh
	for _ = 1, 50 do update(0.1) end
	check(spawnedVeh == firstRetry, "not spawned again within 10 s")
	for _ = 1, 60 do update(0.1) end
	check(spawnedVeh ~= firstRetry, "spawned again after 10 s")
	jobs.uiGiveUp()

	-- giving up: the vehicle goes, the server is told
	job.id = 8
	sendList("mine")
	me.p = {x = 1900, y = -20, z = 10}
	for _ = 1, 3 do update(0.1) end
	local second = spawnedVeh
	jobs.uiGiveUp()
	check(lastSent("sc_jobGiveUp").id == 8 and second.deleted and jobs.getActive() == nil, "give up: vehicle removed, server told")
	-- a job taken away by the server (out of time): ended here too
	job.id = 9
	sendList("mine")
	for _ = 1, 3 do update(0.1) end
	local third = spawnedVeh
	sendList("open")
	check(jobs.getActive() == nil and third.deleted, "taken away by the server: ended, vehicle removed")
	-- switched off on the server: the app goes away
	cfgJ.ui.jobs = false
	handlers.sc_configUpdate(json.encode(cfgJ))
	local still = false
	for _, app in ipairs(sharedCareer_phone.state().apps) do if app.id == "jobs" then still = true end end
	check(not still, "switched off on the server: no Jobs app")
	-- a payout sent again after a reconnect is only confirmed, not credited twice
	jobs.onBeamMPServerLeave()
	acksBefore = acks()
	handlers.sc_jobPaid(payout)
	check(career_modules_playerAttributes.money() == 1450 and acks() == acksBefore + 1,
		"after a reconnect: a payout sent again is only confirmed")
	_G.map, _G.freeroam_facilities, _G.jsonReadFile, _G.util_configListGenerator, _G.core_groundMarkers = nil, nil, nil, nil, nil
end)()

-- the vehicle side: breaking down and reporting the damage
;(function()
	local calls, ge = {}, {}
	local env = setmetatable({
		powertrain = {getDevices = function()
			return {
				{type = "combustionEngine", disable = function() table.insert(calls, "engine off") end},
				{type = "gearbox", disable = function() table.insert(calls, "gearbox!") end},
			}
		end},
		controller = {mainController = {shiftToGearIndex = function(i) table.insert(calls, "gear " .. i) end}},
		input = {event = function(name, v) table.insert(calls, name .. " " .. v) end},
		electrics = {set_warn_signal = function(on) table.insert(calls, "hazard " .. tostring(on)) end},
		beamstate = {damage = 1234.5, deflateRandomTire = function() table.insert(calls, "flat") end},
		obj = {getId = function() return 80 end, queueGameEngineLua = function(_, cmd) table.insert(ge, cmd) end},
	}, {__index = _G})
	local chunk = assert(loadfile("client/lua/vehicle/extensions/auto/sharedCareerVeh.lua"))
	setfenv(chunk, env)
	local veh = chunk()
	veh.jobBreakDown(true)
	local all = table.concat(calls, ", ")
	check(all == "engine off, gear 0, parkingbrake 0, hazard true, flat",
		"breakdown: engine off, neutral, parking brake off, hazard lights, flat tire (" .. all .. ")")
	check(ge[#ge]:find("sharedCareer_jobs.onJobBrokenDown%(80, 1234%.5%)"), "reports the damage so far")
	veh.jobReportDamage()
	check(ge[#ge]:find("onJobDamage%(80, 1234%.5%)"), "reports the damage at the drop-off")
	env.powertrain, env.controller, env.electrics = nil, nil, nil
	calls = {}
	local ok = pcall(veh.jobBreakDown, false)
	check(ok and table.concat(calls, ", ") == "parkingbrake 0", "missing parts of a vehicle: breaks down without them")
end)()

--== 11. Rope anchor on a vehicle (tow hitch) ======================================
-- vehicle side: a roped car pulled by an anchor that drives off; the anchor vehicle's hitch and pull
;(function()
	local function vec(x, y, z) return {x = x, y = y, z = z} end
	-- the roped car: rigid, 2 t, 20 nodes like in 7b4
	local body = {p = vec(0, 0, 0), v = vec(0, 0, 0), f = vec(0, 0, 0), ge = {}}
	local nodes, rel = {}, {}
	for i = 0, 19 do
		local heavy = i < 10
		nodes[i] = {cid = i}
		rel[i] = {x = (i % 5) - 2, y = (i % 2) * 1.6 - 0.8, z = heavy and 0.3 or 1.2, m = heavy and 180 or 20}
	end
	local env = setmetatable({
		v = {data = {nodes = nodes}}, vec3 = vec, enablePhysicsStepHook = function() end,
		obj = {
			getNodeMass = function(_, cid) return rel[cid].m end,
			getAbsNodePosition = function(_, cid) return vec(body.p.x + rel[cid].x, body.p.y + rel[cid].y, body.p.z + rel[cid].z) end,
			getNodeVelocityVector = function() return vec(body.v.x, body.v.y, body.v.z) end,
			getId = function() return 77 end,
			queueGameEngineLua = function(_, cmd) table.insert(body.ge, cmd) end,
			applyForceVector = function(_, cid, f) body.f.x, body.f.y, body.f.z = body.f.x + f.x, body.f.y + f.y, body.f.z + f.z end,
			applyForceVectorTime = function(_, cid, f) body.f.x, body.f.y, body.f.z = body.f.x + f.x, body.f.y + f.y, body.f.z + f.z end,
		},
	}, {__index = _G})
	local chunk = assert(loadfile("client/lua/vehicle/extensions/auto/sharedCareerVeh.lua"))
	setfenv(chunk, env)
	local veh = chunk()
	local MASS, PHYS = 2000, 1 / 2000
	-- grip on the front (y = 0.8 side, chassis height); the anchor (a pickup's hitch) 5 m ahead in +y
	veh.handGrab(0, 0.8, 0.3, 1, 60)
	local anchor = vec(0, 5.8, 0.3)
	local anchorV = vec(0, 0, 0)
	local function sendAnchor(moving) veh.handRope(anchor.x, anchor.y, anchor.z, 0, moving and 1 or 0, 1, 60, anchorV.x, anchorV.y, anchorV.z, 1) end
	sendAnchor(true) -- fixed to the hitch: pays out to it once
	local snapped, peak, lastPull = false, 0, nil
	local function run(seconds)
		for i = 1, math.floor(seconds / PHYS + 0.5) do
			body.f = vec(0, 0, 0)
			veh.onPhysicsStep(PHYS)
			peak = math.max(peak, math.abs(body.f.y))
			body.v.y = body.v.y + body.f.y / MASS * PHYS
			body.v.y = body.v.y * (1 - 0.3 * PHYS) -- rolling resistance
			body.p.y = body.p.y + body.v.y * PHYS
			anchor.y = anchor.y + anchorV.y * PHYS
			if i % 33 == 0 then
				veh.updateGFX(33 * PHYS)
				for _, cmd in ipairs(body.ge) do
					if cmd:find("onHandLost") then snapped = true end
					local fy = cmd:match("onRopePull%(77, [-%d%.]+, ([-%d%.]+),")
					if fy then lastPull = tonumber(fy) end
				end
				body.ge = {}
				if veh.handInfo() then sendAnchor(false) end -- the GE side, every frame
			end
		end
	end
	run(0.5)
	check(veh.handInfo() and math.abs(veh.handInfo().length - 5) < 0.05 and math.abs(body.v.y) < 0.01,
		"anchor fixed to a vehicle: the rope pays out to its hitch, nothing moves yet")
	-- the pickup drives off: speeds up to 3 m/s within 2 s
	for _ = 1, 20 do
		anchorV.y = math.min(3, anchorV.y + 0.15)
		run(0.1)
	end
	run(3)
	check(not snapped and math.abs(body.v.y - 3) < 0.2, string.format("towing: the car follows the pickup on the rope (%.2f m/s)", body.v.y))
	check(peak < 4 * MASS * 9.81, string.format("drove off gently: no jolt that snaps the rope (peak %.0f N)", peak))
	check(lastPull and lastPull < -50, string.format("the pull on the pickup is reported every frame, towards the car (%.0f N)", lastPull or 0))
	-- moving anchor + no extrapolation would jerk: between two messages the anchor moves on by itself
	local ax = veh.handInfo().ay
	veh.onPhysicsStep(PHYS * 100)
	check(veh.handInfo().ay > ax, "between two messages the anchor moves on at the vehicle's speed")
	-- a hard start from standstill to 8 m/s at once: the rope snaps
	anchorV.y = 8
	sendAnchor(false)
	run(1)
	check(snapped and veh.handInfo() == nil, "the pickup jerks off at 8 m/s: the rope snaps")
end)()
-- vehicle side: holding the anchor (hooks on near a tow hitch or touching the body, pull applied, it
-- stops by itself)
;(function()
	local nodes = {[0] = {cid = 0}, {cid = 1}, {cid = 2, couplerTag = "tow_hitch"}, {cid = 3}}
	local pos = {[0] = {x = 0, y = 0, z = 0}, {x = 0, y = -2, z = 0.5}, {x = 0, y = -2.6, z = 0.4}, {x = 0, y = 2, z = 0.5}}
	local forces, ge = {}, {}
	local env = setmetatable({
		v = {data = {nodes = nodes}}, vec3 = function(x, y, z) return {x = x, y = y, z = z} end,
		enablePhysicsStepHook = function() end,
		obj = {
			getNodeMass = function() return 50 end,
			getAbsNodePosition = function(_, cid) return pos[cid] end,
			getId = function() return 5 end,
			queueGameEngineLua = function(_, cmd) table.insert(ge, cmd) end,
			applyForceVector = function(_, cid, f) table.insert(forces, f) end,
		},
	}, {__index = _G})
	local chunk = assert(loadfile("client/lua/vehicle/extensions/auto/sharedCareerVeh.lua"))
	setfenv(chunk, env)
	local veh = chunk()
	local function said(pattern)
		for _, cmd in ipairs(ge) do if cmd:find(pattern) then return true end end
		return false
	end
	-- 3 m away: the hitch is reported for the rings, nothing hooks on
	veh.anchorNear(0, -5.6, 0.4, 1)
	check(said('onAnchorTargets%(5, "2"%)') and not said("onAnchorNode") and veh.anchorInfo() == nil,
		"anchor 3 m from the hitch: it's shown, nothing hooks on")
	-- 0.5 m from the hitch: hooks on there
	ge = {}
	veh.anchorNear(0, -3.1, 0.4, 1)
	check(said("onAnchorNode%(5, 2, 1%)") and veh.anchorInfo().node == 2, "anchor 0.5 m from the tow hitch: it hooks on there")
	veh.anchorRelease()
	-- not allowed to hook on (right after "Detach"): only the rings
	ge = {}
	veh.anchorNear(0, -3.1, 0.4, 0)
	check(not said("onAnchorNode") and veh.anchorInfo() == nil, "not allowed to hook on (just detached): nothing happens")
	-- no hitch: only when it touches the body (0.3 m)
	nodes[2].couplerTag = nil
	ge = {}
	veh.anchorNear(0, 2.5, 0.5, 1)
	check(not said("onAnchorNode") and said('onAnchorTargets%(5, ""%)'), "no hitch, 0.5 m from the body: nothing")
	veh.anchorNear(0, 2.2, 0.5, 1)
	check(said("onAnchorNode%(5, 3, 0%)"), "touching the body (0.2 m): hooks onto that point")
	nodes[2].couplerTag = "tow_hitch"
	veh.anchorNear(0, -3.1, 0.4, 1)
	veh.anchorPull(0, -1000, 0)
	forces = {}
	veh.onPhysicsStep(1 / 2000)
	local fy = 0
	for _, f in ipairs(forces) do fy = fy + f.y end
	check(math.abs(fy + 1000) < 1e-6 and #forces >= 2, "the rope's pull is applied to the anchor vehicle, spread over its nodes")
	veh.updateGFX(0.3)
	forces = {}
	veh.onPhysicsStep(1 / 2000)
	check(#forces == 0, "no new pull for 0.25 s: it stops by itself")
	veh.anchorPull(0, -1000, 0)
	veh.anchorRelease()
	forces = {}
	veh.onPhysicsStep(1 / 2000)
	check(#forces == 0 and veh.anchorInfo() == nil, "released: nothing pulls any more")
end)()
-- GE side: the anchor hooks onto a vehicle near it, follows it, the pull goes on to it, detach
;(function()
	resetWorld()
	installCareer()
	extensions.hook("onWorldReadyState", 2)
	local cfgA = json.decode(json.encode(config))
	cfgA.allowGrab, cfgA.grabSpeed, cfgA.grabStrength = true, 1, 150
	handlers.sc_config(json.encode(cfgA))
	update()
	_G.ColorF = setmetatable({}, {__call = function(_, r, g, b, a) return {r = r, g = g, b = b, a = a} end})
	_G.vec3 = setmetatable({}, {__call = function(_, x, y, z) return {x = x, y = y, z = z} end})
	local drawn = {}
	_G.debugDrawer = {drawLine = function(_, p1, p2, c) table.insert(drawn, {p1 = p1, p2 = p2, c = c}) end}
	local function placed(id, x, y, z, remote, jbeam)
		local v = addVehicle(id, (remote and "7-" or "0-") .. id, not remote, jbeam)
		v.p = {x = x, y = y, z = z}
		v.vel = {x = 0, y = 0, z = 0}
		v.getPosition = function(self) return self.p end
		v.getVelocity = function(self) return self.vel end
		v.getNodePosition = function(self, cid) return cid == 2 and {x = 0, y = -2.6, z = 0.4} or {x = 0, y = 0, z = 0} end
		return v
	end
	local function lastCall(v, fn)
		for i = #v.lua, 1, -1 do
			local args = v.lua[i]:match("sharedCareerVeh%." .. fn .. "%(([^)]*)%)")
			if args then
				local nums = {}
				for n in args:gmatch("[-%d%.]+") do table.insert(nums, tonumber(n)) end
				return nums
			end
		end
	end
	-- frames, with the roped car reporting like in the game (otherwise the watchdog drops the rope)
	local function frames(n)
		for _ = 1, n do
			if sharedCareer_grab.isHolding() then sharedCareer_grab.onHandState(60, 0, 1, 0.5, 0, 1, 7) end
			extensions.hook("onUpdate", 1 / 60)
		end
	end
	_G.core_camera = {getPosition = function() return {x = 0, y = -10, z = 2} end, getForward = function() return {x = 0, y = 1, z = 0} end}
	local car = placed(60, 0, 0, 0.5)
	local pickup = placed(61, 0, 10, 0.5)
	local remote = placed(62, 0, 9, 0.5, true)
	local walker = placed(63, 0, 9.5, 0, false, "unicycle")
	check(sharedCareer_grab.uiAttachVehicle(60), "rope on the car")
	sharedCareer_grab.onGrip(60, 5, 0, 1, 0.5, 7)
	sharedCareer_grab.onHandState(60, 0, 1, 0.5, 0, 1, 1)
	frames(15)
	check(lastCall(pickup, "anchorNear") == nil, "the anchor far from other vehicles: nobody is asked")
	-- move the anchor towards the pickup (as with the remote): it asks the vehicles near it
	sharedCareer_grab.uiAnchorToView()
	for _ = 1, 40 do
		sharedCareer_grab.uiNudge(1, 0, 0)
		frames(6)
		sharedCareer_grab.onHandState(60, 0, 1, 0.5, 0, 1, 8)
	end
	local ask = lastCall(pickup, "anchorNear")
	check(ask and ask[4] == 0, "moving the anchor near the pickup: its hitches are asked for, but it doesn't hook on while held")
	check(sharedCareer_grab.onAnchorNode(61, 2, 1) == nil and sharedCareer_grab.appState().anchorVehicle == nil,
		"an answer while the button is held is refused")
	sharedCareer_grab.uiNudgeStop()
	frames(2)
	ask = lastCall(pickup, "anchorNear")
	check(ask and ask[4] == 1, "let go: asked at once whether it hooks on")
	check(lastCall(car, "anchorNear") == nil and lastCall(remote, "anchorNear") == nil and lastCall(walker, "anchorNear") == nil,
		"not asked: the roped car, another player's vehicle, a player on foot")
	-- the pickup names its hitch: rings are drawn there, green as the anchor comes close
	sharedCareer_grab.onAnchorTargets(61, "2")
	drawn = {}
	frames(1)
	local ringNear = false
	for _, d in ipairs(drawn) do
		if math.abs(d.p1.y - 7.4) < 0.3 and math.abs(d.p1.z - 0.9) < 0.3 and d.c.g > 0.7 then ringNear = true end
	end
	check(ringNear, "a green ring at the pickup's tow hitch")
	-- it hooks on: the anchor rides on the hitch from now on
	sharedCareer_grab.onAnchorNode(61, 2, 1)
	local st = sharedCareer_grab.appState()
	check(st.anchorVehicle and st.anchorHitch == true, "the anchor hooked onto the pickup's tow hitch")
	pickup.vel = {x = 0, y = 2, z = 0}
	for _ = 1, 3 do frames(1) sharedCareer_grab.onHandState(60, 0, 1, 0.5, 0, 1, 7) end
	local a = lastCall(car, "handRope")
	check(a and a[2] == 7.4 and a[9] == 2 and a[11] == 1, "the anchor sits on the hitch, with the pickup's speed, every frame")
	local before = #car.lua
	frames(1)
	check(#car.lua == before + 1, "anchor on a vehicle: sent every frame")
	pickup.p = {x = 0, y = 12, z = 0.5}
	frames(1)
	check(lastCall(car, "handRope")[2] == 9.4, "the anchor moves with the pickup")
	sharedCareer_grab.onRopePull(60, 0, -1500, 0)
	local pull = lastCall(pickup, "anchorPull")
	check(pull and pull[2] == -1500, "the rope's pull goes on to the pickup")
	-- hooked on: a short tap does nothing, holding pulls it off (the pickup stands)
	pickup.vel = {x = 0, y = 0, z = 0}
	sharedCareer_grab.uiNudge(-1, 0, 0)
	frames(15)
	st = sharedCareer_grab.appState()
	check(st.anchorVehicle and st.pullProgress > 0.3 and st.pullProgress < 0.6 and st.moving == false,
		string.format("holding an arrow while hooked on: it tugs, the pull-off fills (%.2f)", st.pullProgress or -1))
	sharedCareer_grab.uiNudgeStop()
	frames(30)
	check(sharedCareer_grab.appState().anchorVehicle and sharedCareer_grab.appState().pullProgress == 0, "let go too early: still hooked on")
	pickup.vel = {x = 0, y = 3, z = 0}
	sharedCareer_grab.uiNudge(-1, 0, 0)
	frames(60)
	st = sharedCareer_grab.appState()
	check(st.anchorVehicle and st.pullBlocked == true, "the pickup drives: it can't be pulled off (the app says to stop first)")
	sharedCareer_grab.uiNudgeStop()
	pickup.vel = {x = 0, y = 0, z = 0}
	local hookedAt = lastCall(car, "handRope")[2]
	local cmdsBefore = #pickup.lua
	sharedCareer_grab.uiNudge(-1, 0, 0)
	frames(45)
	st = sharedCareer_grab.appState()
	local released = false
	for i = cmdsBefore + 1, #pickup.lua do if pickup.lua[i]:find("anchorRelease") then released = true end end
	check(st.anchorVehicle == nil and released, "held for 0.6 s: it pops off the hitch")
	frames(30)
	check(lastCall(car, "handRope")[2] < hookedAt - 0.5, "still held: it moves on, off the hitch")
	-- back to the hitch and let go: it hooks on there again
	sharedCareer_grab.uiNudge(1, 0, 0)
	frames(36)
	sharedCareer_grab.uiNudgeStop()
	frames(2)
	ask = lastCall(pickup, "anchorNear")
	check(ask and ask[4] == 1, "let go near the hitch it came from: it may hook on there again")
	sharedCareer_grab.onAnchorNode(61, 2, 1)
	check(sharedCareer_grab.appState().anchorVehicle, "hooked on again")
	-- a second answer while hooked on: refused, the other vehicle lets go
	local other = placed(64, 3, 12, 0.5)
	sharedCareer_grab.onAnchorNode(64, 2, 1)
	check(sharedCareer_grab.appState().anchorVehicle and other.lua[#other.lua]:find("anchorRelease"),
		"already hooked on: another vehicle's answer is refused")
	-- detach: the anchor stays; it doesn't hook on again right there, only after moving away
	sharedCareer_grab.uiAnchorDetach()
	frames(1)
	a = lastCall(car, "handRope")
	check(a[11] == 0 and a[9] == 0 and pickup.lua[#pickup.lua]:find("anchorRelease"), "detach: the anchor stays put, the pickup is told")
	frames(15)
	ask = lastCall(pickup, "anchorNear")
	check(ask and ask[4] == 0 and sharedCareer_grab.appState().unarmed, "after Detach it doesn't hook on by itself")
	sharedCareer_grab.onAnchorNode(61, 2, 1)
	check(sharedCareer_grab.appState().anchorVehicle == nil, "an answer anyway is refused")
	-- a tiny nudge and let go: it hooks on again, even on the same hitch
	sharedCareer_grab.uiNudge(0, 0, 1)
	frames(2)
	sharedCareer_grab.uiNudgeStop()
	frames(2)
	ask = lastCall(pickup, "anchorNear")
	check(ask and ask[4] == 1 and not sharedCareer_grab.appState().unarmed, "moved once and let go: it may hook on again, also right there")
	-- the middle button while hooked on: off at once, into the view, may hook on there
	sharedCareer_grab.onAnchorNode(61, 2, 1)
	sharedCareer_grab.uiAnchorToView()
	check(sharedCareer_grab.appState().anchorVehicle == nil and not sharedCareer_grab.appState().unarmed,
		"the middle button: off at once, placed in the view, it may hook on there")
	-- the pickup is reset: the anchor stays where it was
	sharedCareer_grab.onAnchorNode(61, 2, 1)
	extensions.hook("onVehicleResetted", 61)
	check(sharedCareer_grab.appState().anchorVehicle == nil and pickup.lua[#pickup.lua]:find("anchorRelease"),
		"the pickup is reset: the anchor comes off it and stays in the world")
	sharedCareer_grab.uiRelease()
	check(not sharedCareer_grab.isHolding(), "rope removed")
	_G.core_camera, _G.debugDrawer = nil, nil
end)()

print(string.format("Client: %d ok, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
