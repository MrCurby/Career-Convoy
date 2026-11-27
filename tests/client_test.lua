-- Client tests: the BeamNG/BeamMP environment is mocked, the real mod files are loaded.
-- Run (LuaJIT, like in the game):  luajit tests/client_test.lua

package.path = "./tests/?.lua;" .. package.path
local json = require("json")
-- the version in the code ("dev"; a release stamps its own in, see tools/package.sh)
local VERSION = io.open("client/lua/ge/extensions/careerConvoy/util.lua"):read("*a"):match('M%.VERSION = "(.-)"')

local ROOT = "client/lua/ge/extensions/"
local clock = 0
local failures, passed = 0, 0
local function check(cond, msg)
	if cond then
		passed = passed + 1
	else
		failures = failures + 1
		print("FAILED: " .. msg)
	end
end

--== Game world mock ============================================================

local sentToServer, handlers, toasts, loadingScreens

local function newVehicle(id, jbeam)
	local v = { id = id, JBeam = jbeam or "pickup", active = true, dyn = {}, lua = {}, deleted = false }
	function v:getID()
		return self.id
	end
	function v:getActive()
		return self.active
	end
	function v:setActive(a)
		self.active = (a == 1 or a == true)
	end
	function v:delete()
		self.deleted = true
	end
	function v:setDynDataFieldbyName(k, _, val)
		self.dyn[k] = val
	end
	function v:getDynDataFieldbyName(k)
		return self.dyn[k]
	end
	function v:setField() end
	function v:queueLuaCommand(cmd)
		table.insert(self.lua, cmd)
	end
	return v
end

local world -- {objects = {veh...}, mp = {serverId -> entry}, own = {gameId=true}}

local function resetWorld()
	clock = 0
	sentToServer, handlers, toasts = {}, {}, {}
	_G.handlerNames = {} -- event -> name given to AddEventHandler
	loadingScreens = {}
	world = { objects = {}, mp = {}, own = {}, playerVeh = nil }

	_G.log = function() end
	_G.jsonEncode = json.encode
	_G.jsonDecode = json.decode
	_G.deepcopy = function(t)
		local c = {}
		for k, v in pairs(t) do
			c[k] = v
		end
		return c
	end
	_G.setExtensionUnloadMode = function() end
	os.clockhp = function()
		return clock
	end
	_G.FS = {
		fileExists = function()
			return true
		end,
	}
	_G.guihooks = {
		trigger = function(_, data)
			table.insert(toasts, data)
		end,
	}
	_G.TriggerServerEvent = function(event, data)
		table.insert(sentToServer, { event = event, data = data ~= "" and json.decode(data) or {} })
	end
	_G.AddEventHandler = function(event, fn, name)
		handlers[event] = fn
		_G.handlerNames[event] = name
	end
	_G.MPCoreNetwork = {
		isMPSession = function()
			return true
		end,
	}
	_G.MPConfig = {
		getNickname = function()
			return "John Doe_99"
		end,
	}
	_G.MPVehicleGE = {
		getVehicles = function()
			return world.mp
		end,
		isOwn = function(id)
			return world.own[id] == true
		end,
		getServerVehicleID = function(id)
			for sid, e in pairs(world.mp) do
				if e.gameVehicleID == id then
					return sid
				end
			end
		end,
	}
	_G.be = {
		getObjectCount = function()
			return #world.objects
		end,
		getObject = function(_, i)
			return world.objects[i + 1]
		end,
		getObjectByID = function(_, id)
			for _, v in ipairs(world.objects) do
				if v.id == id and not v.deleted then
					return v
				end
			end
		end,
		getPlayerVehicleID = function()
			return world.playerVeh
		end,
		enterVehicle = function(_, _, veh)
			world.playerVeh = veh.id
		end,
		enterNextVehicle = function() end,
	}
	-- be:getObject(i) is called with a colon
	local rawGet = be.getObject
	be.getObject = function(self, i)
		return rawGet(self, i)
	end
	_G.getPlayerVehicle = function(p)
		return be:getObjectByID(world.playerVeh)
	end
	_G.core_gamestate = {
		getLoadingStatus = function(tag)
			return loadingScreens[tag] == true
		end,
		requestExitLoadingScreen = function(tag)
			loadingScreens[tag] = nil
		end,
	}
	_G.gameplay_traffic = {
		getTrafficList = function()
			return {}
		end,
		setupTrafficHelper = function(road, opts, parked)
			world.trafficSetup = { road, opts, parked }
		end,
		setActiveAmount = function(n)
			world.activeRoad = n
		end,
		getTrafficData = function()
			return {}
		end,
	}
	_G.gameplay_parking = {
		setActiveAmount = function(n)
			world.activeParked = n
		end,
		getParkedCarsList = function()
			return {}
		end,
	}
	_G.core_vehicles = {
		removeAll = function()
			for _, v in ipairs(world.objects) do
				v:delete()
			end
		end,
		replaceVehicle = function(model, opt, other)
			-- This is how BeamMP's replacement behaves: rebuilds getPlayerVehicle(0), not "other"
			local target = getPlayerVehicle(0)
			world.rebuilt = target and target.id
			return target
		end,
		spawnNewVehicle = function(model, opt)
			world.spawned = { model, opt }
		end,
	}
	_G.career_career = nil
	_G.career_modules_playerAttributes = nil
	_G.career_modules_inventory = nil
	_G.career_saveSystem = {
		saveCurrent = function()
			world.saved = (world.saved or 0) + 1
		end,
	}
	_G.worldReadyState = 0
	local store = { trafficSimpleVehicles = false, simplifyRemoteVehicles = false, trafficAllowMods = true }
	_G.settings = {
		getValue = function(k)
			return store[k]
		end,
		setValue = function(k, v)
			store[k] = v
		end,
	}

	-- extension system
	local loaded = {}
	local order = {}
	_G.extensions = {}
	function extensions.getLoadedExtensionsNames()
		return order
	end
	function extensions.hookUpdate() end
	function extensions.hook(name, ...)
		for _, extName in ipairs(order) do
			local m = loaded[extName]
			if type(m[name]) == "function" then
				m[name](...)
			end
		end
	end
	_G.load = function(path)
		local name = path:gsub("/", "_")
		local m = assert(loadfile(ROOT .. path .. ".lua"))()
		loaded[name] = m
		extensions[name] = m
		_G[name] = m
		table.insert(order, name)
		if m.onExtensionLoaded then
			m.onExtensionLoaded()
		end
	end
	_G.registerExtension = function(name, m)
		loaded[name] = m
		extensions[name] = m
		_G[name] = m
		table.insert(order, name)
	end
	assert(loadfile("client/scripts/careerConvoy/modScript.lua"))()
end

local function addVehicle(gameId, serverId, own, jbeam)
	local v = newVehicle(gameId, jbeam)
	table.insert(world.objects, v)
	world.mp[serverId] = { gameVehicleID = gameId, jbeam = v.JBeam }
	if own then
		world.own[gameId] = true
	end
	return v
end

local function lastSent(event)
	for i = #sentToServer, 1, -1 do
		if sentToServer[i].event == event then
			return sentToServer[i].data
		end
	end
end

-- Career mock that behaves like career.lua (removeAll on activation).
local function installCareer(opts)
	opts = opts or {}
	local active = false
	_G.career_career = {
		startingOptions = {},
		isActive = function()
			return active
		end,
		createOrLoadCareerAndStart = function(name, folder, options)
			world.careerArgs = { name = name, folder = folder, options = options }
			if opts.fail then
				error("kaputt")
			end
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
				if not opts.trafficHang then
					loadingScreens.careerVehicles = nil
				end
			end
			return true
		end,
	}
	local money = opts.money or 1000
	local xp = { beamXP = 0, apmCommercial = 0 } -- the career's own XP attributes
	_G.career_modules_playerAttributes = {
		getAttribute = function(k)
			if k == "money" then
				return { value = money }
			end
			return xp[k] and { value = xp[k] } or nil
		end,
		addAttributes = function(change, reason)
			money = money + (change.money or 0)
			for k, v in pairs(change) do
				if xp[k] then
					xp[k] = xp[k] + v
				end
			end
			world.moneyLabel = type(reason) == "table" and reason.label or nil
		end,
		money = function()
			return money
		end,
		xp = function(k)
			return xp[k]
		end,
	}
end

local function update(dt)
	clock = clock + (dt or 0.1)
	extensions.hook("onUpdate", dt or 0.1)
end

local config = {
	saveSuffix = "_srv",
	trafficShare = { road = 4, parked = 3 },
	remoteVehicleGhost = true,
	remoteUnicycleGhost = true,
	allowConsole = false,
	serverVersion = VERSION,
	trafficSimpleVehicles = true,
	simplifyRemoteVehicles = true,
	trafficAllowMods = false,
}

--== 1. Join: career starts, remote cars survive ================================
resetWorld()
installCareer()
local mine = addVehicle(1, "0-0", true)
local theirs = addVehicle(2, "1-0", false)
extensions.hook("onWorldReadyState", 2)
check(lastSent("sc_hello") ~= nil, "hello sent after world ready")
handlers.sc_config(json.encode(config))
check(
	handlerNames.sc_config
		and handlerNames.sc_config:find("core.lua", 1, true)
		and handlerNames.sc_vehStates
		and handlerNames.sc_vehStates:find("vehicles.lua", 1, true),
	"each event handler is named after its own module, not util.lua"
)
check(world.careerArgs.name == "johndoe99srv", "profile name cleaned up: " .. tostring(world.careerArgs.name))
check(
	type(world.careerArgs.options) == "table" and world.careerArgs.options.startMode == "freshStart",
	"start options as a table with freshStart"
)
check(world.careerArgs.folder == false, "no fixed save folder")
check(theirs.deleted == false, "remote car survives the career start")
check(mine.deleted == true, "own old car is removed by the career")
check(world.trafficSetup[1] == 4 and world.trafficSetup[3] == 3, "server traffic passed to the career")
check(world.trafficSetup[2].simpleVehs == true, "traffic spawns as simple vehicles")
check(settings.getValue("trafficSimpleVehicles") == true, "game setting trafficSimpleVehicles set")
check(settings.getValue("simplifyRemoteVehicles") == true, "BeamMP setting simplifyRemoteVehicles set")
check(settings.getValue("trafficAllowMods") == false, "no mod cars in the traffic")
update()
check(world.activeRoad == 4, "server traffic overrides the career setting afterwards")
check(lastSent("sc_careerResult") and lastSent("sc_careerResult").ok == true, "success reported to the server")
update()
update()
local saved = core_vehicles.removeAll
check(saved ~= nil, "removeAll present")
core_vehicles.removeAll()
check(theirs.deleted == true, "after the start removeAll is the original again")

--== 1b. Profile name comes from the server (per account) =====================
resetWorld()
installCareer()
extensions.hook("onWorldReadyState", 2)
local cfgP = {}
for k, v in pairs(config) do
	cfgP[k] = v
end
cfgP.profileBase = "anna"
handlers.sc_config(json.encode(cfgP))
check(
	world.careerArgs.name == "annasrv",
	"server profile + suffix instead of BeamMP name: " .. tostring(world.careerArgs.name)
)
update()
check(lastSent("sc_careerResult").profile == "annasrv", "profile name reported to the server")

--== 2. Start hangs in the loading screen -> released after the timeout ==========
resetWorld()
installCareer({ trafficHang = true })
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
for _ = 1, 50 do
	update(0.1)
end
check(lastSent("sc_careerResult") == nil, "no result yet while the start is running")
for _ = 1, 600 do
	update(0.1)
end
check(loadingScreens.careerVehicles == nil, "hanging loading screen released")
check(lastSent("sc_careerResult").ok == true, "career was running -> success anyway")

--== 3. Start throws an error -> failure reported ================================
resetWorld()
installCareer({ fail = true })
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
registerExtension("career_modules_a", {
	onCareerActive = function()
		error("boom")
	end,
})
registerExtension("career_modules_b", {
	onCareerActive = function()
		ran.b = true
	end,
})
installCareer()
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
check(ran.b == true, "handler after the failing one still runs")
check(careerConvoy_protect.getFailures()[1] == "career_modules_a", "error is logged")
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
_G.career_modules_inventory = {
	getInventoryIdFromVehicleId = function(id)
		if id == 12 then
			return 7
		end
	end,
}
world.rebuilt = nil
check(
	core_vehicles.replaceVehicle("pickup", {}, remote) == nil and world.rebuilt == nil,
	"inventory car that isn't ours is not touched"
)
_G.career_modules_inventory = {
	getInventoryIdFromVehicleId = function()
		return nil
	end,
}
core_vehicles.replaceVehicle("pickup", {}, remote)
check(world.rebuilt == 10, "remote non-inventory cars go to BeamMP unchanged")
for _ = 1, 5 do
	update(1.1)
end
local depth = 0
local fn = core_vehicles.replaceVehicle
check(careerConvoy_util.isOurs(fn), "wrapper is in place")
-- A reloaded module (new function) is wrapped again, but never twice
core_vehicles.replaceVehicle = function(m, o, other)
	world.rebuilt = getPlayerVehicle(0).id
end
update(1.1)
local w1 = core_vehicles.replaceVehicle
update(1.1)
check(w1 == core_vehicles.replaceVehicle and careerConvoy_util.isOurs(w1), "no double wrapping")

-- unicycle visible
core_vehicles.spawnNewVehicle("unicycle", { config = "vehicles/unicycle/without_mesh.pc" })
check(world.spawned[2].config == "vehicles/unicycle/beammp_default.pc", "visible player on foot in MP")

--== 6b. Using computers from a distance ======================================
resetWorld()
installCareer()
local function V(x, y, z)
	return { x = x, y = y, z = z }
end
_G.vec3 = V
local sceneObjects = {
	servicestationGarageComputer_area_1 = { pos = V(0, 0, 0), scl = V(1.5, 1, 1) },
	servicestationGarageComputer_icon_1 = { pos = V(0, 0, 1), scl = V(1, 1, 1) },
	dealer_area_1 = { pos = V(50, 0, 0), scl = V(2, 2, 1) },
	dealer_icon_1 = { pos = V(50, 0, 1), scl = V(1, 1, 1) },
}
_G.scenetree = {
	findObject = function(name)
		local o = sceneObjects[name]
		if not o then
			return nil
		end
		return {
			getPosition = function()
				return V(o.pos.x, o.pos.y, o.pos.z)
			end,
			getScale = function()
				return o.scl
			end,
		}
	end,
}
-- Rebuild of the game class: setup builds the boxes once from the scene objects
local C = {}
function C:init()
	self.visible = true
end
function C:setup(cluster)
	self.cluster = cluster
	self.doors = {}
	for _, ntuple in ipairs(cluster.doors) do
		local area = scenetree.findObject(ntuple[1])
		local scl = area:getScale()
		table.insert(
			self.doors,
			{ areaPos = area:getPosition(), xVec = V(scl.x, 0, 0), yVec = V(0, scl.y, 0), zVec = V(0, 0, scl.z) }
		)
	end
end
function C:update()
	self.updated = true
end
local markerModule = {
	create = function()
		local o = setmetatable({}, C)
		C.__index = C
		o:init()
		return o
	end,
}
package.loaded["gameplay/markers/walkingMarker"] = markerModule
local function len(v)
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end
-- a marker the game built BEFORE our patch
local existing = markerModule.create()
existing:setup({ doors = { { "servicestationGarageComputer_area_1", "servicestationGarageComputer_icon_1" } } })
local dealer = markerModule.create()
dealer:setup({ doors = { { "dealer_area_1", "dealer_icon_1" } } })
extensions.hook("onWorldReadyState", 2)
local cfgC = {}
for k, v in pairs(config) do
	cfgC[k] = v
end
cfgC.computerAccessRange = 6
handlers.sc_config(json.encode(cfgC))
update(1.1)
existing:update()
dealer:update()
check(existing.updated == true, "original method still runs")
check(
	len(existing.doors[1].xVec) == 6 and len(existing.doors[1].yVec) == 6,
	"computer zone enlarged to 6 m (old marker)"
)
check(len(existing.doors[1].zVec) == 2.5, "zone high enough for stairs/ramps")
check(len(dealer.doors[1].xVec) == 2, "other zones (dealers) stay unchanged")
-- new marker after the patch
local fresh = markerModule.create()
fresh:setup({ doors = { { "servicestationGarageComputer_area_1", "servicestationGarageComputer_icon_1" } } })
fresh:update()
check(len(fresh.doors[1].xVec) == 6, "new markers are enlarged too")
-- live to 0 -> original back
cfgC.computerAccessRange = 0
handlers.sc_configUpdate(json.encode(cfgC))
existing:update()
check(len(existing.doors[1].xVec) == 1.5 and len(existing.doors[1].yVec) == 1, "0 restores the original size")
-- no double wrapping
local f1 = C.update
update(1.1)
update(1.1)
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
world.mp["0-9"] = { gameVehicleID = 30, jbeam = "simple_traffic", isLocal = true }
update(1.1)
check(freshTraffic.dyn.ignoreTraffic == nil, "local, not yet confirmed car stays drivable")
world.own[30] = true
update(1.1)
check(freshTraffic.dyn.ignoreTraffic == nil, "confirmed own car stays drivable")
handlers.sc_vehStates(json.encode({ ["1-5"] = { active = false, traffic = true } }))
check(other.active == false, "car hidden by the server gets hidden")
check(world.mp["1-5"].hideNametag == true, "name tag hidden")
handlers.sc_vehStates(json.encode({ ["1-5"] = { active = true, traffic = false } }))
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
	world.mp["0-10"] = { gameVehicleID = 31, jbeam = "simple_traffic" }
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
handlers.sc_vehStates(json.encode({ ["1-6"] = { active = true, traffic = true } }))
update(1.1)
local lastGhost = remoteTraffic.lua[#remoteTraffic.lua]
check(lastGhost and lastGhost:find("setGhost%(false%)"), "other players' traffic always collides")
check(other.lua[#other.lua]:find("setGhost%(true%)"), "player car stays without collision (setting)")
-- if a car is only marked as traffic later, it switches to collision
local laterTraffic = addVehicle(23, "1-7", false)
handlers.sc_vehStates(json.encode({ ["1-7"] = { active = true } }))
update(1.1)
check(laterTraffic.lua[#laterTraffic.lua]:find("setGhost%(true%)"), "unmarked remote car: player setting")
handlers.sc_vehStates(json.encode({ ["1-7"] = { active = true, traffic = true } }))
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
for k, v in pairs(config) do
	cfgAi[k] = v
end
cfgAi.trafficAggression = 0.2
cfgAi.trafficGrip = 0.85
handlers.sc_config(json.encode(cfgAi))
local carA = addVehicle(40, "0-40", true)
local cop = addVehicle(41, "0-41", true)
local mineAi = addVehicle(42, "0-42", true)
world.playerVeh = 42
gameplay_traffic.getTrafficData = function()
	return { [40] = { isAi = true }, [41] = { isAi = true, role = { name = "police" } }, [42] = { isAi = true } }
end
update(3.1)
local function aggr(v)
	for i = #v.lua, 1, -1 do
		local x = v.lua[i]:match("setAggression%(([%d%.]+)%)")
		if x then
			return tonumber(x)
		end
	end
end
local function aggrCount(v)
	local c = 0
	for _, cmd in ipairs(v.lua) do
		if cmd:find("setAggression") then
			c = c + 1
		end
	end
	return c
end
local function grip(v)
	for i = #v.lua, 1, -1 do
		local x = v.lua[i]:match("staticFrictionCoefMult = ([%d%.]+)")
		if x then
			return tonumber(x)
		end
	end
end
-- runs the last AI command in a fake vehicle Lua and returns what it called
local function lastAiCommand(v)
	for i = #v.lua, 1, -1 do
		if v.lua[i]:find("ai%.set") then
			return v.lua[i], i
		end
	end
end
local function runInVehicle(v)
	local calls = {}
	local env = {
		ai = {
			setAggression = function(x)
				calls.aggression = x
			end,
			setParameters = function(t)
				calls.params = t
			end,
		},
	}
	local fn = assert(loadstring((lastAiCommand(v))))
	setfenv(fn, env)
	fn()
	return calls
end
check(aggr(carA) == 0.2, "traffic gets a more careful aggression")
check(grip(carA) == 0.85, "traffic gets a lower grip estimate (brakes earlier)")
local calls = runInVehicle(carA)
check(
	calls.aggression == 0.2
		and calls.params
		and calls.params.staticFrictionCoefMult == 0.85
		and next(calls.params, next(calls.params)) == nil,
	"the command runs in the vehicle and only sets staticFrictionCoefMult"
)
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
update(3.1)
update(10)
check(aggrCount(carA) == n, "0 = aggression is not changed")
check(grip(carA) == 0.85 and runInVehicle(carA).aggression == nil, "grip still applies on its own")
cfgAi.trafficGrip = 0
handlers.sc_configUpdate(json.encode(cfgAi))
local _, lastIndex = lastAiCommand(carA)
update(3.1)
update(10)
check(select(2, lastAiCommand(carA)) == lastIndex, "both 0 = AI is not touched at all")

--== 7b2. AI reacts earlier (vehicle side, ai.lua internals) =================
-- Rebuild of the relevant structure of the game's lua/vehicle/ai.lua: `ego` and `traffic` are
-- local tables, only reachable as upvalues of local functions, which are called by the module.
local function makeFakeAi()
	local ego = { race_time_gap = 0.3, race_catchAgg = 1, race_brakeAgg = 0 }
	local traffic = {
		Rfl_fun = function(v)
			return math.max(60, math.min(200, (v + 10) * 3))
		end,
	}
	local function planAhead()
		return traffic.Rfl_fun(ego.speed or 0)
	end -- nested level 2
	local function update()
		return planAhead()
	end -- nested level 1
	local mod = {}
	mod.update = function()
		return update()
	end
	mod.setAggression = function() end
	return mod, ego, traffic
end
local vehLogs = {}
local savedLog = _G.log
_G.log = function(level, tag, msg)
	table.insert(vehLogs, level .. " " .. tostring(msg))
end
local fakeAi, fakeEgo, fakeTraffic = makeFakeAi()
_G.ai = fakeAi
local veh = dofile("client/lua/vehicle/extensions/auto/careerConvoyVeh.lua")
local gameSight = fakeTraffic.Rfl_fun
check(veh.setAiTuning(1.0, 5) == true, "AI tables found through nested upvalues")
check(fakeEgo.race_time_gap == 1.0, "safety gap set to 1 s (game 0.3 s)")
check(
	fakeTraffic.Rfl_fun(28) == 190 and fakeTraffic.Rfl_fun(0) == 60 and fakeTraffic.Rfl_fun(100) == 300,
	"sight range: (speed + 10) * 5, between 60 and 300 m"
)
check(gameSight(28) == 114, "for comparison: the game sees 114 m at 100 km/h")
check(
	#vehLogs == 1 and vehLogs[1]:find("0.30 s %-> 1.00 s") and vehLogs[1]:find("113 m %-> 189 m"),
	"first apply is logged with old and new values: " .. tostring(vehLogs[1])
)
veh.setAiTuning(1.0, 5)
check(fakeEgo.race_time_gap == 1.0 and fakeTraffic.Rfl_fun(28) == 190, "applying again changes nothing")
check(
	veh.setAiTuning(0, 0) == true and fakeEgo.race_time_gap == 0.3 and fakeTraffic.Rfl_fun == gameSight,
	"0 restores the game's values"
)
veh.setAiTuning(0.8, 0)
check(fakeEgo.race_time_gap == 0.8 and fakeTraffic.Rfl_fun == gameSight, "each value can be switched on its own")
-- a game update that renames the internals: nothing changes, one log line
_G.ai = {
	update = function()
		return 1
	end,
}
veh = dofile("client/lua/vehicle/extensions/auto/careerConvoyVeh.lua")
vehLogs = {}
check(veh.setAiTuning(1.0, 5) == false and veh.setAiTuning(1.0, 5) == false, "internals not found: nothing changed")
check(#vehLogs == 1 and vehLogs[1]:find("not found"), "internals not found: logged once")
-- debug library not available: nothing changed
fakeAi, fakeEgo = makeFakeAi()
_G.ai = fakeAi
veh = dofile("client/lua/vehicle/extensions/auto/careerConvoyVeh.lua")
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
for k, v in pairs(config) do
	cfgT[k] = v
end
cfgT.trafficAggression, cfgT.trafficReactionGap, cfgT.trafficSightRange = 0.2, 1.0, 5
handlers.sc_config(json.encode(cfgT))
local carT = addVehicle(50, "0-50", true)
local copT = addVehicle(51, "0-51", true)
gameplay_traffic.getTrafficData = function()
	return { [50] = { isAi = true }, [51] = { isAi = true, role = { name = "police" } } }
end
update(3.1)
local function tuningCmd(v)
	for i = #v.lua, 1, -1 do
		local g, r = v.lua[i]:match("setAiTuning%(([%d%.]+), ([%d%.]+)%)")
		if g then
			return tonumber(g), tonumber(r)
		end
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
	function f.setGroup(name, actions)
		groups[name] = actions
	end
	function f.addAction(filterId, name, filtered)
		blockedGroups[filterId] = blockedGroups[filterId] or {}
		blockedGroups[filterId][name] = filtered
		blocked[filterId] = {}
		for g, on in pairs(blockedGroups[filterId]) do
			if on then
				for _, a in ipairs(groups[g] or { g }) do
					blocked[filterId][a] = true
				end
			end
		end
		extensions.hook("onActionFilterUpdated")
	end
	function f.isActionBlocked(a)
		for _, actions in pairs(blocked) do
			if actions[a] then
				return true
			end
		end
		return false
	end
	return f
end
local NODE_ACTIONS = { "nodegrabberGrab", "nodegrabberRender", "nodegrabberStrength" }
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
	_G.gameplay_walk = {
		isWalking = function()
			return walking
		end,
	}
	_G.core_camera = {
		getActiveGlobalCameraName = function()
			return freeCam
		end,
	}
	extensions.hook("onWorldReadyState", 2)
	local c = {}
	for k, v in pairs(config) do
		c[k] = v
	end
	c.allowNodeGrabber = allow
	handlers.sc_config(json.encode(c))
	update()
	return c
end
local function grabBlocked()
	return core_input_actionFilter.isActionBlocked("nodegrabberGrab")
end

walking, freeCam = false, nil
local cfgN = joinForNodegrab(false)
careerUpdateNodegrabber()
check(grabBlocked(), "switched off: the career blocks the node grabber in a vehicle (game rule)")
walking = true
careerUpdateNodegrabber()
check(not grabBlocked(), "switched off: allowed while walking (game rule)")

walking, freeCam = false, nil
cfgN = joinForNodegrab(true)
careerUpdateNodegrabber()
check(not grabBlocked(), "allowed: node grabber works in a vehicle")
freeCam = "free"
careerUpdateNodegrabber()
check(not grabBlocked(), "allowed: node grabber works in the free camera")
freeCam = nil
-- the certification test blocks it with its own group: that block stays
local nodeErrors = {}
local quietLog = _G.log
_G.log = function(level, tag, msg)
	if level == "E" then
		table.insert(nodeErrors, tostring(msg))
	end
end
core_input_actionFilter.setGroup("certificationBlockedActions", { "nodegrabberGrab" })
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

--== 7b4. Ropes: vehicle side (forces) =========================================
-- Rigid-body rebuild of a vehicle in the vehicle Lua: nodes with mass that all move together,
-- gravity, and a flat ground at z = 0 that the lowest node can't go through. Like in the game, the
-- rope runs at the physics rate (onPhysicsStep, 2000 per second) and updateGFX at 60 per second.
do
	local function vec3(x, y, z)
		return { x = x, y = y, z = z }
	end
	-- f: forces of this physics step (applyForceVector); frameF: forces for the whole frame
	-- (applyForceVectorTime, set in updateGFX)
	local body = {
		p = { x = 0, y = 0, z = 0 },
		v = { x = 0, y = 0, z = 0 },
		f = { x = 0, y = 0, z = 0 },
		frameF = { x = 0, y = 0, z = 0 },
		forces = {},
		ge = {},
	}
	-- 2 t car: 20 nodes, chassis nodes heavy (180 kg), panel nodes light (20 kg)
	local nodes, rel = {}, {}
	for i = 0, 19 do
		local heavy = i < 10
		nodes[i] = { cid = i }
		rel[i] = { x = (i % 5) - 2, y = (i % 2) * 1.6 - 0.8, z = heavy and 0.3 or 1.2, m = heavy and 180 or 20 }
	end
	local function addForce(cid, f, frame)
		local into = frame and body.frameF or body.f
		into.x, into.y, into.z = into.x + f.x, into.y + f.y, into.z + f.z
		body.forces[cid] = (body.forces[cid] or 0) + math.sqrt(f.x * f.x + f.y * f.y + f.z * f.z)
	end
	local hookOn = false
	local function makeEnv(withHook)
		local env = {
			v = { data = { nodes = nodes } },
			vec3 = vec3,
			enablePhysicsStepHook = withHook and function()
				hookOn = true
			end or nil,
			obj = {
				getNodeMass = function(_, cid)
					return rel[cid].m
				end,
				getAbsNodePosition = function(_, cid)
					return vec3(body.p.x + rel[cid].x, body.p.y + rel[cid].y, body.p.z + rel[cid].z)
				end,
				getNodeVelocityVector = function()
					return vec3(body.v.x, body.v.y, body.v.z)
				end,
				getId = function()
					return 77
				end,
				queueGameEngineLua = function(_, cmd)
					table.insert(body.ge, cmd)
				end,
				applyForceVector = function(_, cid, f)
					addForce(cid, f)
				end,
				applyForceVectorTime = function(_, cid, f, dt)
					addForce(cid, f, true)
				end,
			},
		}
		if not withHook then
			env.enablePhysicsStepHook = false
		end -- not offered by this game
		return setmetatable(env, {
			__index = function(_, k)
				if k == "enablePhysicsStepHook" then
					return nil
				end
				return _G[k]
			end,
		})
	end
	local function loadVeh(withHook)
		local chunk = assert(loadfile("client/lua/vehicle/extensions/auto/careerConvoyVeh.lua"))
		setfenv(chunk, makeEnv(withHook))
		return chunk()
	end
	local veh = loadVeh(true)
	local MASS, WEIGHT = 2000, 2000 * 9.81
	local PHYS = 1 / 2000
	local GFX_EVERY = 33 -- physics steps per frame (about 60 fps)
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
		if body.p.z + body.v.z * dt < 0 then
			body.v.z = 0
		end
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
			body.f = { x = 0, y = 0, z = 0 }
			veh.onPhysicsStep(PHYS)
			if watch then
				watch()
			end
			integrate(PHYS)
			steps = steps + 1
			if steps % GFX_EVERY == 0 then
				body.frameF = { x = 0, y = 0, z = 0 }
				veh.updateGFX(GFX_EVERY * PHYS)
			end
		end
	end
	local function speed()
		return math.sqrt(body.v.x ^ 2 + body.v.y ^ 2 + body.v.z ^ 2)
	end
	-- tie where you point: a ray from x = 10 along -x at the height/side of the upper right
	-- panel nodes; the front-most node on it is at x = 2
	check(veh.ropeTieRay(1, 0, 10, 0.8, 1.2, -1, 0, 0, 120, 1, 60) == true, "vehicle side: tied via the aim ray")
	check(hookOn, "a rope switches on the physics-step hook (the rope runs 2000 times per second)")
	local reply = body.ge[#body.ge] or ""
	local rt, rx = reply:match("onRopeTied%(77, 1, ([%d%.]+), ([-%d%.]+),")
	check(
		reply:find("careerConvoy_rope.onRopeTied")
			and math.abs(tonumber(rt) - 8) < 0.01
			and math.abs(tonumber(rx) - 2) < 0.01,
		"ties to the node you point at (front-most on the ray) and reports grip and distance: " .. reply
	)
	veh.ropeRelease(1)
	body.ge = {}
	veh.tieProbe(10, 0.8, 1.2, -1, 0, 0, 120)
	check((body.ge[1] or ""):find("onTieProbe%(77, 2%.000, 0%.800, 1%.200%)"), "preview: reports where it would tie")
	check(veh.ropeTie(1, 0, 2, 0.8, 0.3, 1, 60) == true, "vehicle side: nodes around the tie point are taken")
	-- in the game a frame can come right after tying, before the first physics step (the first dev build crashed
	-- the vehicle's Lua there: the rope had no length yet)
	body.ge = {}
	local frameOk, frameErr = pcall(veh.updateGFX, 1 / 60)
	check(
		frameOk and veh.ropeInfo(1) ~= nil,
		"a frame before the first physics step: no error (" .. tostring(frameErr) .. ")"
	)
	local info = veh.ropeInfo(1)
	check(#info.nodes >= 4 and #info.nodes <= 24 and info.vehMass == MASS, "grip of 4-24 nodes, vehicle mass known")
	local function lastState()
		local st = body.ge[#body.ge] or ""
		local strain, slack, len =
			st:match("onRopeState%(77, 1, [-%d%.]+, [-%d%.]+, [-%d%.]+, ([%d%.]+), (%d), ([%d%.]+), [%d%.]+%)")
		return tonumber(strain), tonumber(slack), tonumber(len)
	end
	local function lost()
		local st = body.ge[#body.ge] or ""
		return tonumber(st:match("onRopeLost%(77, 1, (%d+)%)"))
	end
	-- how far the rope is stretched now (m)
	local function stretch()
		local h = veh.ropeInfo(1)
		local t = { x = body.p.x + rel[h.tie].x, y = body.p.y + rel[h.tie].y, z = body.p.z + rel[h.tie].z }
		return math.sqrt((h.ax - t.x) ^ 2 + (h.ay - t.y) ^ 2 + (h.az - t.z) ^ 2) - h.length
	end
	-- attached: the anchor is at the grip, the rope is slack, no force
	run(0.5)
	check(
		math.abs(body.p.x) < 0.001 and math.abs(body.p.y) < 0.001,
		"rope attached: the vehicle doesn't move by itself"
	)
	-- move the anchor 5 m to the side (moving, winch off): rope is paid out, the vehicle stays
	for i = 1, 30 do
		veh.ropeUpdate(1, 2, 0.8 + 5 * i / 30, 0.3, 0, 1)
		run(1 / 30)
	end
	run(1)
	local _, slack, len = lastState()
	check(
		math.abs(body.p.y) < 0.01 and slack == 1 and math.abs(len - 5) < 0.1,
		string.format("moving the anchor pays out rope, the vehicle stays (y = %.3f, rope %.1f m)", body.p.y, len or -1)
	)
	-- anchor placed, winch on: pulled slowly towards the anchor
	veh.ropeUpdate(1, 2, 5.8, 0.3, 1, 0)
	local maxSpeed = 0
	body.forces = {}
	run(3, function()
		maxSpeed = math.max(maxSpeed, speed())
	end)
	check(maxSpeed <= 1.05 and maxSpeed > 0.8, string.format("winch pulls slowly: at most 1 m/s (%.2f)", maxSpeed))
	check(body.p.y > 1.8 and body.p.y < 3.6, string.format("after 3 s about 2-3 m pulled (%.1f m)", body.p.y))
	local heavyF, lightF = 0, 0
	for cid, f in pairs(body.forces) do
		if rel[cid].m >= 180 then
			heavyF = heavyF + f
		else
			lightF = lightF + f
		end
	end
	check(heavyF > 5 * lightF, "the force goes mostly to the heavy nodes (no bent panels)")
	local endSpeed = nil
	run(8, function()
		local h = veh.ropeInfo(1)
		if not endSpeed and h.length <= 0.6 then
			endSpeed = speed()
		end
	end)
	check(endSpeed and endSpeed < 0.5, string.format("the winch slows down towards the end (%.2f m/s)", endSpeed or -1))
	-- a rope can't brake: the vehicle rolls on past the anchor and is caught by the short rope
	check(
		math.abs(body.p.y - 5) <= 0.6 and speed() < 0.05,
		string.format("rolled on, caught by the rope at most 0.5 m past the anchor (%.2f m)", body.p.y)
	)
	local strainNow = lastState()
	check(strainNow and strainNow < 0.3, "strain low when it's easy (" .. tostring(strainNow) .. ")")
	-- winch off: the rope keeps its length; a rope never pushes
	veh.ropeUpdate(1, 2, 5.8, 0.3, 0, 0)
	run(2)
	body.v = { x = 0, y = 0, z = 0 }
	local gy = body.p.y + 0.8
	veh.ropeUpdate(1, 2, gy + 3, 0.3, 0, 1) -- move the anchor 3 m away: rope paid out to 3 m
	run(0.5)
	veh.ropeUpdate(1, 2, gy + 1, 0.3, 0, 0) -- anchor placed 1 m from the grip: shorter than the rope
	local yHold = body.p.y
	body.f = { x = 0, y = 0, z = 0 }
	veh.onPhysicsStep(PHYS)
	check(body.f.x == 0 and body.f.y == 0 and body.f.z == 0, "a slack rope doesn't push")
	run(1)
	check(math.abs(body.p.y - yHold) < 0.05, "winch off, rope slack: nothing moves")
	-- lifting: anchor high above, winch on; 60 % of the weight can't float the whole car
	veh.ropeUpdate(1, body.p.x + 2, body.p.y + 0.8, 4, 1, 0)
	run(6)
	check(body.p.z < 0.05, string.format("60 %% of the weight doesn't lift the whole vehicle (z = %.2f)", body.p.z))
	local strainLift = lastState()
	check(
		strainLift and strainLift > 0.95,
		"strain reported back: at the limit while lifting (" .. tostring(strainLift) .. ")"
	)
	local peak = 0
	run(0.5, function()
		peak = math.max(peak, math.sqrt(body.f.x ^ 2 + body.f.y ^ 2 + body.f.z ^ 2))
	end)
	check(peak <= WEIGHT * 0.6 * 1.05, string.format("the winch stalls at 60 %% of the weight (%.0f N)", peak))
	-- 150 %: it lifts, as fast as the motor manages under the load
	local ax, ay = body.p.x + 2, body.p.y + 0.8
	veh.ropeUpdate(1, ax, ay, 4, 1, 0, 1, 150)
	local z0 = body.p.z
	run(4)
	local liftSpeed = (body.p.z - z0) / 4
	check(
		body.p.z > 0.6 and liftSpeed < 0.6,
		string.format(
			"with 150 %% it lifts the vehicle, the motor slower under the load (z = %.2f, %.2f m/s)",
			body.p.z,
			liftSpeed
		)
	)
	-- winch stopped: the vehicle hangs still, the rope stiff (a few cm), no springing up and down
	veh.ropeUpdate(1, ax, ay, 4, 0, 0, 1, 150)
	run(0.5)
	local lo, hi = math.huge, -math.huge
	run(2, function()
		lo, hi = math.min(lo, body.p.z), math.max(hi, body.p.z)
	end)
	check(
		hi - lo < 0.01,
		string.format("winch stopped: the vehicle hangs still, no bouncing (%.3f m up and down)", hi - lo)
	)
	check(
		stretch() > 0 and stretch() < 0.05,
		string.format("the rope stretches only a few cm under the weight (%.3f m)", stretch())
	)
	-- pay out: the rope gets longer at the winch speed, the lifted vehicle comes down
	veh.ropeUpdate(1, ax, ay, 4, -1, 0, 1, 150)
	local zStart, dropFastest = body.p.z, 0
	run(0.6, function()
		dropFastest = math.max(dropFastest, -body.v.z)
	end)
	local _, _, lenBefore = lastState()
	run(1, function()
		dropFastest = math.max(dropFastest, -body.v.z)
	end)
	local _, _, lenAfter = lastState()
	check(
		lenBefore and lenAfter and lenAfter - lenBefore > 0.9 and lenAfter - lenBefore < 1.1,
		string.format(
			"pay out: the drum speeds up, then the rope gets 1 m/s longer (%.2f -> %.2f m)",
			lenBefore or -1,
			lenAfter or -1
		)
	)
	check(
		veh.ropeInfo(1) ~= nil and body.p.z < zStart - 0.5 and dropFastest < 1.15,
		string.format(
			"the hanging vehicle comes down with the rope, it doesn't drop into it (at most %.2f m/s)",
			dropFastest
		)
	)
	-- stopped, the drum is locked: even with 30 % (far less than the vehicle's weight) it holds
	veh.ropeUpdate(1, ax, ay, 4, 1, 0, 1, 150)
	run(3)
	veh.ropeUpdate(1, ax, ay, 4, 0, 0, 1, 30)
	local zHang, fastest = body.p.z, 0
	run(2, function()
		fastest = math.max(fastest, -body.v.z)
	end)
	check(
		zHang > 0.5 and math.abs(body.p.z - zHang) < 0.03 and veh.ropeInfo(1) ~= nil,
		string.format(
			"stopped, the drum is locked: the strength doesn't matter, it holds the hanging vehicle (%.2f -> %.2f m)",
			zHang,
			body.p.z
		)
	)
	veh.ropeRelease(1)
	body.f = { x = 0, y = 0, z = 0 }
	body.frameF = { x = 0, y = 0, z = 0 }
	veh.onPhysicsStep(PHYS)
	veh.updateGFX(1 / 60)
	check(
		body.f.x == 0
			and body.f.y == 0
			and body.f.z == 0
			and body.frameF.x == 0
			and body.frameF.y == 0
			and body.frameF.z == 0
			and veh.ropeInfo(1) == nil,
		"released: no force any more"
	)
	run(3)
	-- the rope snaps on a shock load: a vehicle driving away from a taut rope; a gentle jerk holds
	local function tautRope(away)
		body.p, body.v, body.ge = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, {}
		veh.ropeTie(1, 0, 2, 0.8, 0.3, 1, 60)
		veh.ropeUpdate(1, 2, 4.8, 0.3, 0, 0, 1, 60) -- anchor 4 m away, rope as long as that
		run(0.2)
		body.v = { x = 0, y = -away, z = 0 }
		run(1)
	end
	tautRope(0.5)
	check(
		veh.ropeInfo(1) ~= nil and body.p.y > -0.4,
		string.format("a gentle jerk (0.5 m/s): the rope holds (y = %.2f)", body.p.y)
	)
	veh.ropeRelease(1)
	tautRope(4)
	check(veh.ropeInfo(1) == nil and lost() == 4, "a hard jerk (4 m/s): the rope snaps and says so (onRopeLost 4)")
	-- handbrake on (static friction = 50 % of the weight): 60 % pulls it loose, 30 % can't
	body.p, body.v = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }
	body.brake = WEIGHT * 0.5
	veh.ropeTie(1, 0, 2, 0.8, 0.3, 1, 60)
	veh.ropeUpdate(1, 2, 4.8, 0.3, 1, 0, 1, 60) -- anchor 4 m away, winch hauling in
	run(5)
	check(body.p.y > 0.5, string.format("handbrake on, 60 %%: the winch pulls it loose (%.2f m)", body.p.y))
	veh.ropeRelease(1)
	body.p, body.v = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }
	veh.ropeTie(1, 0, 2, 0.8, 0.3, 1, 30)
	veh.ropeUpdate(1, 2, 4.8, 0.3, 1, 0, 1, 30)
	run(5)
	local strain30 = lastState()
	check(
		body.p.y < 0.01 and strain30 and strain30 > 0.95,
		string.format("30 %% against a 50 %% handbrake: the winch stalls, strain at the limit (%.2f)", strain30 or -1)
	)
	veh.ropeRelease(1)
	body.brake = nil
	-- a game without the physics-step hook: the rope runs once per frame, softer, but still works
	veh = loadVeh(false)
	body.p, body.v, body.ge = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, {}
	veh.ropeTie(1, 0, 2, 0.8, 0.3, 1, 60)
	veh.ropeUpdate(1, 2, 4.8, 0.3, 1, 0, 1, 60)
	local fastestFrame = 0
	for _ = 1, 180 do
		body.f, body.frameF = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }
		veh.updateGFX(1 / 60)
		for _ = 1, GFX_EVERY do
			integrate(PHYS)
		end
		fastestFrame = math.max(fastestFrame, speed())
	end
	check(
		body.p.y > 1.5 and fastestFrame < 1.1,
		string.format(
			"without the physics step: pulled once per frame, still steady (%.2f m, at most %.2f m/s)",
			body.p.y,
			fastestFrame
		)
	)
	veh.ropeRelease(1)
	-- an error in the physics step (e.g. a changed game function): logged once, the rope goes on per
	-- frame instead of taking the vehicle down
	veh = loadVeh(true)
	local env = getfenv(veh.onPhysicsStep)
	local logged = {}
	env.log = function(level, area, msg)
		table.insert(logged, level .. " " .. msg)
	end
	env.obj.applyForceVector = function()
		error("applyForceVector changed")
	end
	body.p, body.v, body.ge = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, {}
	veh.ropeTie(1, 0, 2, 0.8, 0.3, 1, 60)
	veh.ropeUpdate(1, 2, 4.8, 0.3, 1, 0, 1, 60)
	local ok = pcall(run, 3)
	check(
		ok and #logged == 1 and logged[1]:find("^E .*applyForceVector changed") and body.p.y > 1,
		string.format(
			"an error in the physics step is logged once, the rope goes on per frame (%d logs, %.2f m)",
			#logged,
			body.p.y
		)
	)
	env.obj.applyForceVector = function(_, cid, f)
		addForce(cid, f)
	end
	veh.ropeRelease(1)
end

--== 7b5. Ropes: GE side (picking, anchor, Tow app) ============================
resetWorld()
installCareer()
local ropeKeysSeen = {}
_G.MPKeybindsGE = {
	addAction = function(name, def)
		ropeKeysSeen[name] = def
	end,
}
extensions.hook("onWorldReadyState", 2)
local cfgG = {}
for k, v in pairs(config) do
	cfgG[k] = v
end
cfgG.allowRopes, cfgG.winchSpeed, cfgG.winchStrength, cfgG.allowTowToRoad = true, 1, 150, true
handlers.sc_config(json.encode(cfgG))
update()
local function placedVeh(id, x, y, z, jbeam, remote)
	local v = addVehicle(id, (remote and "7-" or "0-") .. id, not remote, jbeam)
	v.p = { x = x, y = y, z = z }
	v.getPosition = function(self)
		return self.p
	end
	return v
end
-- the id of the tow rope (the vehicle reports with it)
function rid() -- global: the test file is at its limit of 200 locals
	local r = careerConvoy_tow.rope()
	return r and r.id or -1
end
-- last rope command sent to a vehicle: name and numbers, without the rope id (and the kind of a tie)
local function lastHand(v)
	for i = #v.lua, 1, -1 do
		local name, args = v.lua[i]:match("careerConvoyVeh%.(rope%a+)%(([^)]*)%)")
		if name then
			local nums = {}
			for n in args:gmatch("[-%d%.]+") do
				table.insert(nums, tonumber(n))
			end
			table.remove(nums, 1)
			if name:find("^ropeTie") then
				table.remove(nums, 1)
			end
			return name, nums
		end
	end
end
-- the vehicle's rope report (onRopeState), repeated 10 times per second like the vehicle does
local alive = nil
local function handState(id, ...)
	alive = { id, ... }
	careerConvoy_rope.onRopeState(id, rid(), ...)
end
local function frames(seconds, dt)
	dt = dt or 1 / 60
	for i = 1, math.floor(seconds / dt + 0.5) do
		if alive and i % 6 == 0 and careerConvoy_tow.isHolding() then
			careerConvoy_rope.onRopeState(alive[1], rid(), unpack(alive, 2))
		end
		extensions.hook("onUpdate", dt)
	end
end
local cam = { x = 0, y = 0, z = 2 }
local fwd = nil
_G.core_camera = {
	getPosition = function()
		return cam
	end,
	getForward = function()
		return fwd
	end,
}
local truck = placedVeh(60, 10, 0, 1)
local ropeKeys = 0
for keyName in pairs(ropeKeysSeen) do
	if keyName:find("Grab") or keyName:find("Rope") then
		ropeKeys = ropeKeys + 1
	end
end
check(ropeKeys == 0, "no keys for the rope: everything runs in the Tow app")
-- attach where I look: the view ray passes the truck
fwd = { x = 1, y = 0, z = -0.1 }
check(careerConvoy_tow.uiAttachView(), "attach where I look")
local name, a = lastHand(truck)
check(careerConvoy_tow.isHolding() and name == "ropeTieRay", "rope attached: the view ray is sent to the vehicle")
check(
	a and a[1] == 0 and a[2] == 0 and a[3] == 2 and a[4] > 0.99 and a[7] == 120 and a[8] == 1 and a[9] == 60,
	"camera position, view direction, speed 1 m/s and strength 60 % sent along"
)
frames(0.2)
check(lastHand(truck) == "ropeTieRay", "nothing is sent until the vehicle reports where the rope is tied")
-- the vehicle reports where it tied the rope: the anchor starts there
careerConvoy_rope.onRopeTied(60, rid(), 9.0, 9, 0, 1)
handState(60, 9, 0, 1, 0, 1, 0)
frames(0.1)
name, a = lastHand(truck)
check(
	name == "ropeUpdate" and a[1] == 9 and a[2] == 0 and a[3] == 1 and a[4] == 0 and a[5] == 0,
	"anchor starts at the grip; winch off, not moving"
)
local sent = #truck.lua
frames(1)
check(#truck.lua - sent >= 25 and #truck.lua - sent <= 35, "rope state sent about 30 times per second")
-- looking around: the anchor stays
fwd = { x = 0, y = 1, z = 0 }
frames(0.2)
name, a = lastHand(truck)
check(a[1] == 9 and a[2] == 0, "looking around: the anchor stays where it is")
-- winch on
careerConvoy_tow.uiWinch(1)
frames(0.1)
name, a = lastHand(truck)
check(a[4] == 1, "winch on")
-- move the anchor 4 m towards you with the remote (seen from the camera: x is forward)
fwd = { x = 1, y = 0, z = 0 }
careerConvoy_tow.uiNudge(-1, 0, 0)
frames(4)
careerConvoy_tow.uiNudgeStop()
frames(0.1)
name, a = lastHand(truck)
check(
	math.abs(a[1] - 5) < 0.1 and a[2] == 0 and a[5] == 0,
	string.format("anchor moved with the remote (x = %.2f)", a[1])
)
-- settings change live
cfgG.winchSpeed, cfgG.winchStrength = 0.5, 200
handlers.sc_configUpdate(json.encode(cfgG))
frames(0.1)
name, a = lastHand(truck)
check(a[6] == 0.5 and a[7] == 60, "settings applied live; the player's pick (60 %) stays")
-- pull strength picked in the Tow app, capped at the server's maximum
careerConvoy_tow.uiStrength(150)
frames(0.1)
name, a = lastHand(truck)
local st = careerConvoy_tow.appState()
check(
	a[7] == 150 and st.strength == 150 and st.maxStrength == 150 and #st.strengths == 4,
	"Tow app: 150 % picked, sent to the vehicle right away"
)
cfgG.winchStrength = 100
handlers.sc_configUpdate(json.encode(cfgG))
frames(0.1)
name, a = lastHand(truck)
st = careerConvoy_tow.appState()
check(
	a[7] == 100 and st.strength == 100 and #st.strengths == 3 and st.strengths[3] == 100,
	"server maximum 100 %: the pick is capped, 150 % is not offered"
)
cfgG.winchStrength = 80
handlers.sc_configUpdate(json.encode(cfgG))
st = careerConvoy_tow.appState()
check(st.strengths[#st.strengths] == 80 and st.strength == 80, "odd server maximum (80 %) is offered as its own choice")
careerConvoy_tow.uiStrength(60)
cfgG.winchSpeed, cfgG.winchStrength = 1, 150
handlers.sc_configUpdate(json.encode(cfgG))
-- drawing: rope grey when slack, the color of the rope's own load when taut (its color while safe,
-- orange when high, red near breaking); anchor color shows the state. (Looking nowhere here: the
-- winch gauge, which faces the camera, is tested on its own below.)
fwd = nil
local drawn = {}
-- like in the game: ColorF and vec3 are callable constructors, not Lua functions (0.10.1 bug)
_G.ColorF = setmetatable({}, {
	__call = function(_, r, g, b, alpha)
		return { r = r, g = g, b = b, a = alpha }
	end,
})
_G.vec3 = setmetatable({}, {
	__call = function(_, x, y, z)
		return { x = x, y = y, z = z }
	end,
})
_G.debugDrawer = {
	drawLine = function(_, p1, p2, c)
		table.insert(drawn, { p1 = p1, p2 = p2, c = c })
	end,
}
local function near(x, want)
	return math.abs(x - want) < 0.02
end
handState(60, 9, 0, 1, 0.1, 0, 4, 0.1)
frames(0.5)
drawn = {}
frames(1 / 60)
check(
	#drawn == 11 and drawn[1].p1.x == 9 and near(drawn[1].c.r, 0.88) and near(drawn[1].c.g, 0.84),
	"taut rope (lines only): line, grip and pin as crosses, in the rope's own color while it is safe"
)
check(drawn[5].c.r == 1 and drawn[5].c.g < 0.6, "winch running: orange anchor")
handState(60, 9, 0, 1, 1, 0, 4, 0.1)
frames(0.5)
drawn = {}
frames(1 / 60)
check(
	near(drawn[1].c.r, 0.88) and near(drawn[1].c.g, 0.84),
	"the winch at its limit: no danger for the rope, its color stays"
)
handState(60, 9, 0, 1, 1, 0, 4, 0.55)
drawn = {}
frames(1 / 60)
check(
	drawn[1].c.g < 0.8 and drawn[1].c.g > 0.62 and drawn[1].c.r > 0.9,
	string.format("high rope load: orange (g = %.2f)", drawn[1].c.g)
)
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
for _ in pairs(lines) do
	trembles = trembles + 1
end
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
careerConvoy_tow.uiWinch(0)
handState(60, 9, 0, 1, 0, 1, 4)
frames(1)
drawn = {}
frames(1 / 60)
check(
	near(drawn[1].c.r, 0.7) and near(drawn[1].c.g, 0.7) and drawn[#drawn - 2].c.r == 1 and drawn[#drawn - 2].c.g == 1,
	"slack rope: grey line (faded); winch off: white anchor"
)
careerConvoy_tow.uiNudge(0, 0, 0)
drawn = {}
frames(1 / 60)
check(drawn[#drawn - 2].c.b > 0.9 and drawn[#drawn - 2].c.r < 0.5, "moving the anchor: cyan anchor")
careerConvoy_tow.uiNudgeStop()
do
	-- sag: a slack rope is drawn as a curve below the straight line, a taut one straight
	check(
		careerConvoy_rope.sagDepth(4, 4, 4) == 0 and careerConvoy_rope.sagDepth(4, 4, 3) == 0,
		"sag: none when the rope is as long as the distance or shorter"
	)
	local s5 = careerConvoy_rope.sagDepth(4, 4, 5)
	check(math.abs(s5 - math.sqrt(1.5)) < 1e-6 and 4 + 8 * s5 ^ 2 / 12 == 5, "sag: parabola about as long as the rope")
	check(
		careerConvoy_rope.sagDepth(4, 0, 6) == 0
			and careerConvoy_rope.sagDepth(4, 2, 6) < careerConvoy_rope.sagDepth(4, 4, 6),
		"sag: a steep rope hangs along itself"
	)
	check(careerConvoy_rope.sagDepth(10, 10, 60) == 6, "sag: limited")
	local function lowest()
		local z = math.huge
		for _, d in ipairs(drawn) do
			z = math.min(z, d.p2.z)
		end
		return z
	end
	handState(60, 9, 0, 1, 0, 1, 30) -- slack, rope much longer than the distance
	drawn = {}
	frames(1 / 60)
	local curve = #drawn
	frames(1)
	drawn = {}
	frames(1 / 60)
	local deep = lowest()
	check(curve > 7 and deep < 1 - 0.5, string.format("slack rope sags (%d lines, lowest %.2f)", curve, deep))
	handState(60, 9, 0, 1, 0.5, 0, 4) -- pulled taut
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
	_G.String = function(t)
		return { str = t }
	end
	_G.ColorI = function(r, g, b, a)
		return { r = r, g = g, b = b, a = a }
	end
	_G.debugDrawer = {
		drawLine = function(_, p1, p2, c)
			table.insert(shapes, { kind = "line", c = c })
		end,
		drawSphere = function(_, p, r, c)
			table.insert(shapes, { kind = "sphere", p = p, r = r, c = c })
		end,
		drawCylinder = function(_, a, b, r, c)
			table.insert(shapes, { kind = "cylinder", a = a, b = b, c = c })
		end,
		drawTextAdvanced = function(_, p, t, c)
			table.insert(shapes, { kind = "text", p = p, t = t.str })
		end,
	}
	local function count(kind)
		local n = 0
		for _, x in ipairs(shapes) do
			if x.kind == kind then
				n = n + 1
			end
		end
		return n
	end
	local function find(kind)
		for _, x in ipairs(shapes) do
			if x.kind == kind then
				return x
			end
		end
	end
	careerConvoy_rope.resetShapes()
	shapes = {}
	frames(1 / 60)
	check(
		count("line") == 1 and count("sphere") == 3 and count("cylinder") == 2 and count("text") == 0,
		string.format(
			"shapes: rope (line + cylinder), grip ball, pin (post + 2 balls), no sign with the app closed (%d/%d/%d/%d)",
			count("line"),
			count("sphere"),
			count("cylinder"),
			count("text")
		)
	)
	local post = shapes[#shapes - 2]
	check(post.kind == "cylinder" and post.b.z > post.a.z + 0.5, "anchor pin: a post standing up from the anchor")
	check(
		find("cylinder").a.x == 9 and math.abs(find("cylinder").b.x - 5) < 0.1,
		"rope: a cylinder from the grip to the anchor"
	)
	careerConvoy_tow.setAppOpen(true)
	shapes = {}
	frames(1 / 60)
	local sg = find("text")
	check(
		sg and sg.t == "Locked",
		"Tow app open, winch stopped: the sign says it is locked (" .. tostring(sg and sg.t) .. ")"
	)
	careerConvoy_tow.uiWinch(1)
	shapes = {}
	frames(1 / 60)
	sg = find("text")
	check(
		sg and sg.t:find("^Winch %d+ %%"),
		"hauling in: the sign shows the winch's load (" .. tostring(sg and sg.t) .. ")"
	)
	careerConvoy_tow.uiWinch(0)
	careerConvoy_tow.setAppOpen(false)
	-- winch hauling in: the pin's ball pulses
	careerConvoy_tow.uiWinch(1)
	local radii = {}
	for _ = 1, 20 do
		shapes = {}
		frames(1 / 30)
		local biggest = 0
		for _, x in ipairs(shapes) do
			if x.kind == "sphere" then
				biggest = math.max(biggest, x.r)
			end
		end
		radii[#radii + 1] = biggest
	end
	local lo, hi = math.huge, 0
	for _, r in ipairs(radii) do
		lo, hi = math.min(lo, r), math.max(hi, r)
	end
	check(hi - lo > 0.03, string.format("winch hauling in: the anchor ball pulses (%.3f-%.3f)", lo, hi))
	careerConvoy_tow.uiWinch(0)
	-- a missing shape falls back to lines, without errors
	_G.debugDrawer.drawSphere = nil
	shapes = {}
	frames(1 / 60)
	check(
		count("sphere") == 0 and count("line") > 6 and count("cylinder") == 2,
		"no drawSphere: balls drawn as crosses"
	)
	_G.debugDrawer, _G.String, _G.ColorI = lineOnly, nil, nil
	careerConvoy_rope.resetShapes()
	-- the winch gauge above the anchor: a ring facing the camera that fills with the winch's load
	fwd = { x = 1, y = 0, z = 0 }
	local function gauge()
		drawn = {}
		frames(1 / 60)
		local ring, filled, red = 0, 0, 0
		for _, d in ipairs(drawn) do
			local midZ = (d.p1.z + d.p2.z) / 2
			if math.abs(d.p1.x - d.p2.x) < 1e-6 and midZ > 1.7 and midZ < 2.3 then -- a ring in the y-z plane, facing +x
				ring = ring + 1
				if d.c.a > 0.3 then
					filled = filled + 1
				end
				if d.c.r > 0.99 and d.c.g < 0.3 then
					red = red + 1
				end -- red blinks: counted by color
			end
		end
		return ring, filled, red
	end
	careerConvoy_tow.uiWinch(1)
	handState(60, 9, 0, 1, 0.5, 0, 4, 0.1)
	frames(0.3)
	local ring, filled, red = gauge()
	check(
		ring >= 24 and filled >= 20 and filled <= 28 and red == 0,
		string.format("winch at half its limit: the gauge is half full (%d of 48 lines filled)", filled)
	)
	handState(60, 9, 0, 1, 1, 0, 4, 0.1)
	ring, filled, red = gauge()
	check(red >= 46, "winch at its limit: the gauge is full and red (it blinks)")
	careerConvoy_tow.uiWinch(0)
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
			if math.abs(dist(d.p1, d.p2) - 0.12) < 0.01 then
				table.insert(out, d)
			end
		end
		return out
	end
	-- distance of the mark nearest to the anchor (the rope line ends at the anchor)
	local function markPhase()
		local anchor, best = drawn[1].p2, math.huge
		for _, d in ipairs(marks()) do
			best = math.min(best, dist(d.p2, anchor))
		end
		return best
	end
	-- the vehicle reports a rope that gets shorter (rate < 0) or longer, 10 times per second
	local function runRope(rate, seconds)
		alive = nil
		local length = 4
		for _ = 1, seconds * 10 do
			length = length + rate * 0.1
			careerConvoy_rope.onRopeState(60, rid(), 9, 0, 1, 0.5, 0, length)
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
	check(
		n >= 4 and moved < -0.003,
		string.format("hauling in: marks on the rope travel to the anchor (%d marks, %.4f m)", n, moved)
	)
	n, moved = runRope(0.5, 1)
	check(
		n >= 4 and moved > 0.003,
		string.format("paying out: the marks travel to the vehicle (%d marks, %.4f m)", n, moved)
	)
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
	careerConvoy_tow.uiRelease()
	check(not careerConvoy_tow.isHolding() and lastHand(truck) == "ropeRelease", "remove rope: ropeRelease sent")
	drawn = {}
	frames(1 / 60)
	local snapStart = drawn[1]
	frames(0.1)
	drawn = {}
	frames(1 / 60)
	local function toAnchor(d)
		return math.abs(d.p1.x - anchorAt.x) + math.abs(d.p1.y - anchorAt.y) + math.abs(d.p1.z - anchorAt.z)
	end
	check(
		snapStart and drawn[1] and toAnchor(drawn[1]) < toAnchor(snapStart) - 1 and drawn[1].c.a < snapStart.c.a,
		"let go (taut): the loose end snaps back to the anchor and fades out"
	)
	frames(0.5)
	drawn = {}
	frames(1 / 60)
	check(#drawn == 0, "let go: gone after a moment")
end
-- staying in step with the vehicle: every way the rope can be lost ends in a clean release
do
	local function lastToast()
		for i = #toasts, 1, -1 do
			if toasts[i].msg then
				return toasts[i].msg
			end
		end
		return ""
	end
	local function attachTruck()
		alive = nil
		fwd = { x = 1, y = 0, z = -0.1 }
		careerConvoy_tow.uiAttachView()
		careerConvoy_rope.onRopeTied(60, rid(), 9.0, 9, 0, 1, 7)
		handState(60, 9, 0, 1, 0, 1, 0)
	end
	fwd = { x = 1, y = 0, z = -0.1 }
	alive = nil
	careerConvoy_tow.uiAttachView()
	frames(2.5)
	check(
		not careerConvoy_tow.isHolding() and lastToast():find("Can't attach"),
		"the vehicle never reports a grip: released after 2 s, with a message"
	)
	attachTruck()
	alive = nil
	frames(1.5)
	check(careerConvoy_tow.isHolding(), "a short silence is fine")
	frames(1)
	check(
		not careerConvoy_tow.isHolding() and lastToast():find("came loose"),
		"no word from the vehicle for 2 s (its Lua was reloaded): released"
	)
	attachTruck()
	alive = nil
	for _ = 1, 300 do
		extensions.hook("onUpdate", 1 / 60, 0)
	end
	check(careerConvoy_tow.isHolding(), "game paused (no game time): the watchdog waits")
	attachTruck()
	careerConvoy_rope.onRopeLost(60, rid(), 1)
	check(
		not careerConvoy_tow.isHolding() and lastToast():find("reset"),
		"the vehicle drops the rope after a reset: released"
	)
	attachTruck()
	careerConvoy_rope.onRopeLost(60, rid(), 3)
	check(
		not careerConvoy_tow.isHolding() and lastToast():find("tore off"),
		"a torn-off part: released with its own message"
	)
	attachTruck()
	careerConvoy_rope.onRopeLost(60, rid(), 4)
	check(
		not careerConvoy_tow.isHolding() and lastToast():find("snapped"),
		"the rope snapped (overload): released with its own message"
	)
	attachTruck()
	careerConvoy_rope.onRopeLost(61, rid(), 1)
	check(careerConvoy_tow.isHolding(), "another vehicle's report doesn't touch the rope")
	extensions.hook("onVehicleResetted", 60)
	check(not careerConvoy_tow.isHolding() and lastHand(truck) == "ropeRelease", "vehicle reset (R): rope removed")
	-- a hitch: the anchor remote moves at most MAX_STEP worth
	attachTruck()
	frames(0.1)
	fwd = { x = 1, y = 0, z = 0 }
	careerConvoy_tow.uiNudge(1, 0, 0)
	frames(1, 1)
	careerConvoy_tow.uiNudgeStop()
	frames(0.1)
	local _, h = lastHand(truck)
	check(
		h and math.abs(h[1] - 9.1) < 0.02,
		string.format("a 1 s hitch moves the anchor only 0.1 m (x = %.2f)", h and h[1] or -1)
	)
	-- the rope end follows the tie node every frame, not only on the reports
	truck.getNodePosition = function(_, cid)
		return cid == 7 and { x = -0.5, y = 0.2, z = 0 } or nil
	end
	truck.p = { x = 10, y = 0, z = 1 }
	drawn = {}
	frames(1 / 60)
	check(
		math.abs(drawn[1].p1.x - 9.5) < 1e-6 and math.abs(drawn[1].p1.y - 0.2) < 1e-6,
		"rope drawn from the tie node's position now (vehicle position + getNodePosition)"
	)
	truck.getNodePosition = function()
		return { x = 400, y = 0, z = 0 }
	end
	drawn = {}
	frames(1 / 60)
	check(drawn[1].p1.x == 9, "an implausible node position falls back to the last report")
	truck.getNodePosition = nil
	-- at the limit for a while (while hauling in): shown in the Tow app and on the sign
	careerConvoy_tow.uiWinch(1)
	handState(60, 9, 0, 1, 1, 0, 4)
	frames(1)
	check(not careerConvoy_tow.appState().stuck, "at the limit for a moment: not stuck yet")
	frames(1.5)
	check(careerConvoy_tow.appState().stuck, "at the limit for 2 s: the Tow app says so")
	handState(60, 9, 0, 1, 0.3, 0, 4)
	frames(0.2)
	check(not careerConvoy_tow.appState().stuck, "it pulls easier again: no longer stuck")
	handState(60, 9, 0, 1, 1, 0, 4)
	careerConvoy_tow.uiWinch(0)
	frames(2.5)
	check(not careerConvoy_tow.appState().stuck, "stopped (locked): never stuck")
	-- a floating anchor: dashed drop line and a disc on the ground (castRayStatic)
	_G.castRayStatic = function(from, dir, range)
		return from.z - 0
	end -- ground at z = 0
	careerConvoy_tow.uiNudge(0, 0, 1)
	frames(1)
	careerConvoy_tow.uiNudgeStop()
	drawn = {}
	frames(1 / 60)
	local drops = 0
	for _, d in ipairs(drawn) do
		if math.abs(d.p1.x - d.p2.x) < 1e-9 and math.abs(d.p1.y - d.p2.y) < 1e-9 and d.p2.z < 1 and d.p2.z >= 0 then
			drops = drops + 1
		end
	end
	check(drops >= 4, "anchor 2 m above the ground: dashed drop line (" .. drops .. " dashes)")
	local lowestDrop = math.huge
	for _, d in ipairs(drawn) do
		lowestDrop = math.min(lowestDrop, d.p2.z)
	end
	check(math.abs(lowestDrop) < 0.05, "the drop line reaches the ground")
	_G.castRayStatic = nil
	-- let go of a slack rope: its loose end drops and the rope fades out
	handState(60, 9, 0, 1, 0, 1, 4)
	frames(1)
	careerConvoy_tow.uiRelease()
	drawn = {}
	frames(1 / 60)
	local dropStart = drawn[1]
	frames(0.3)
	drawn = {}
	frames(1 / 60)
	check(
		dropStart and drawn[1] and drawn[1].p1.z < dropStart.p1.z - 0.2 and drawn[1].c.a < dropStart.c.a,
		"let go (slack): the loose end drops and the rope fades out"
	)
	frames(0.5)
	alive = nil
end
-- preview: only while the Tow app is open (not just on foot); it aims with the view
local walkingNow = true
_G.gameplay_walk = {
	isWalking = function()
		return walkingNow
	end,
}
fwd = { x = 1, y = 0, z = -0.1 }
local function probeCount(from)
	local c = 0
	for i = from + 1, #truck.lua do
		if truck.lua[i]:find("tieProbe") then
			c = c + 1
		end
	end
	return c
end
local before = #truck.lua
frames(1)
check(probeCount(before) == 0, "on foot without the Tow app: no preview")
careerConvoy_tow.setAppOpen(true)
before = #truck.lua
frames(1)
local probes = probeCount(before)
check(
	probes >= 4 and probes <= 6,
	"Tow app open: the vehicle is asked where the rope would attach (" .. probes .. "x per second)"
)
careerConvoy_rope.onTieProbe(60, 9, 0, 1)
drawn = {}
frames(1 / 60)
check(#drawn == 3 and drawn[1].c.b > 0.9, "preview: a blue cross where the rope would attach")
careerConvoy_tow.setAppOpen(false)
drawn = {}
frames(1 / 60)
check(#drawn == 0, "Tow app closed: preview gone")
fwd = nil
-- Tow app on the phone
local towApp
for _, app in ipairs(careerConvoy_phone.state().apps) do
	if app.id == "tow" then
		towApp = app
	end
end
check(towApp and towApp.title == "Tow" and towApp.icon == "tow", "the Tow app is on the phone")
careerConvoy_phone.uiOpenApp("tow")
local appSt = careerConvoy_tow.appState()
check(
	appSt.allowed
		and not appSt.attached
		and #appSt.nearby >= 1
		and appSt.nearby[1].id == 60
		and appSt.nearby[1].name == "Pickup",
	"not attached: own vehicles nearby are listed (" .. tostring(appSt.nearby[1] and appSt.nearby[1].name) .. ")"
)
for _, v in ipairs(appSt.nearby) do
	check(v.id ~= 61 and v.id ~= 62, "no other players' vehicles or players on foot in the list")
end
-- attach from the list: at the vehicle's point closest to you
check(
	careerConvoy_tow.uiAttachVehicle(60) and lastHand(truck) == "ropeTieNearest",
	"attach from the list: rope at the closest point"
)
careerConvoy_rope.onRopeTied(60, rid(), 9, 9, 0, 1)
handState(60, 9, 0, 1, 0, 1, 0)
appSt = careerConvoy_tow.appState()
check(appSt.attached and appSt.vehicle == "Pickup" and appSt.winch == 0, "app shows the roped vehicle, winch stopped")
-- remote control: hold "forward" -> the anchor moves away (seen from the camera), rope pays out
fwd = { x = 1, y = 0, z = 0 }
careerConvoy_tow.uiNudge(1, 0, 0)
frames(1)
name, a = lastHand(truck)
check(
	math.abs(a[1] - 10) < 0.1 and a[5] == 1,
	string.format("hold forward: anchor 1 m/s away, rope pays out (x = %.2f)", a[1])
)
careerConvoy_tow.uiNudge(0, 1, 0)
frames(1)
name, a = lastHand(truck)
check(math.abs(a[2] + 1) < 0.1, string.format("hold right: anchor 1 m to the right (y = %.2f)", a[2]))
careerConvoy_tow.uiNudge(0, 0, 1)
careerConvoy_tow.uiFine(true)
frames(1)
name, a = lastHand(truck)
check(
	math.abs(a[3] - 1.25) < 0.05 and a[6] == 0.25,
	string.format("fine mode: up at a quarter speed, winch quarter speed (z = %.2f)", a[3])
)
careerConvoy_tow.uiFine(false)
careerConvoy_tow.uiNudgeStop()
frames(0.2)
name, a = lastHand(truck)
check(a[5] == 0, "button released: anchor stays, rope no longer pays out")
-- winch: haul in / stop / pay out
careerConvoy_tow.uiWinch(1)
frames(0.1)
check(select(2, lastHand(truck))[4] == 1, "winch: haul in")
careerConvoy_tow.uiWinch(-1)
frames(0.1)
check(select(2, lastHand(truck))[4] == -1, "winch: pay out")
careerConvoy_tow.uiWinch(0)
frames(0.1)
check(select(2, lastHand(truck))[4] == 0, "winch: stop")
-- anchor to the middle of the view at its distance
fwd = { x = 0, y = 1, z = 0 }
careerConvoy_tow.uiToView()
frames(1 / 60)
name, a = lastHand(truck)
check(
	math.abs(a[1]) < 0.1 and a[2] > 3 and a[5] == 1,
	"anchor to my view: placed in the middle of the view, rope pays out once"
)
frames(0.1)
check(select(2, lastHand(truck))[5] == 0, "... only once")
careerConvoy_tow.uiRelease()
check(not careerConvoy_tow.isHolding() and lastHand(truck) == "ropeRelease", "remove rope from the app")
-- tow to the road: the game's own recovery (damage stays), free, for the vehicle on the rope
local towed = {}
_G.spawn = {
	teleportToLastRoad = function(veh, opts)
		table.insert(towed, { id = veh:getID(), opts = opts })
	end,
}
local towToasts = {}
local realToast = careerConvoy_util.toast
careerConvoy_util.toast = function(_, msg)
	table.insert(towToasts, msg)
end
check(careerConvoy_tow.appState().towToRoad == true, "Tow app: tow to the road offered")
fwd = { x = -1, y = -1, z = 0 }
check(
	not careerConvoy_tow.uiTowToRoad() and #towed == 0 and towToasts[#towToasts]:find("Look at"),
	"tow to the road without a rope: needs a vehicle in view"
)
fwd = { x = 1, y = 0, z = -0.1 }
check(
	careerConvoy_tow.uiTowToRoad() and #towed == 1 and towed[1].id == 60 and towed[1].opts.resetVehicle == false,
	"tow to the road without a rope: the vehicle you look at"
)
towed = {}
careerConvoy_tow.uiAttachView()
truck.getVelocity = function()
	return { x = 5, y = 0, z = 0 }
end
check(
	not careerConvoy_tow.uiTowToRoad() and #towed == 0 and towToasts[#towToasts]:find("Stop the vehicle"),
	"tow to the road: not while the vehicle moves"
)
truck.getVelocity = function()
	return { x = 0.1, y = 0, z = 0 }
end
_G.gameplay_traffic = {
	getTrafficData = function()
		return { [60] = { pursuit = { mode = 1 } } }
	end,
}
check(
	not careerConvoy_tow.uiTowToRoad() and #towed == 0 and towToasts[#towToasts]:find("police"),
	"tow to the road: not during a police chase"
)
_G.gameplay_traffic = {
	getTrafficData = function()
		return { [60] = { pursuit = { mode = 0 } } }
	end,
}
check(
	careerConvoy_tow.uiTowToRoad() and #towed == 1 and towed[1].id == 60 and towed[1].opts.resetVehicle == false,
	"tow to the road with a rope: the vehicle on the rope, damage kept"
)
check(not careerConvoy_tow.isHolding() and lastHand(truck) == "ropeRelease", "tow to the road: the rope comes off")
careerConvoy_tow.uiAttachView()
cfgG.allowTowToRoad = false
handlers.sc_configUpdate(json.encode(cfgG))
check(
	careerConvoy_tow.appState().towToRoad == false and not careerConvoy_tow.uiTowToRoad() and #towed == 1,
	"tow to the road switched off on the server"
)
cfgG.allowTowToRoad = true
handlers.sc_configUpdate(json.encode(cfgG))
-- flip upright: only for a vehicle on its roof or side; the game's own "Flip upright", damage kept
do
	local flipped = {}
	_G.spawn.safeTeleport = function(veh, pos, rot, a1, a2, a3, a4, resetVehicle)
		table.insert(flipped, { id = veh:getID(), rot = rot, reset = resetVehicle })
	end
	_G.quatFromDir = function(d)
		return { dir = d }
	end
	truck.getDirectionVector = function()
		return { x = 1, y = 0, z = 0 }
	end
	truck.getDirectionVectorUp = function()
		return { x = 0, y = 0, z = 1 }
	end
	check(
		careerConvoy_tow.appState().flip == false
			and not careerConvoy_tow.uiFlipUpright()
			and #flipped == 0
			and towToasts[#towToasts]:find("wheels"),
		"flip upright: not for a vehicle on its wheels (no button)"
	)
	truck.getDirectionVectorUp = function()
		return { x = 0, y = 0.2, z = -0.98 }
	end
	check(careerConvoy_tow.appState().flip == true, "on its roof: the Tow app offers Flip upright")
	check(
		careerConvoy_tow.uiFlipUpright()
			and #flipped == 1
			and flipped[1].id == 60
			and flipped[1].reset == false
			and flipped[1].rot.dir.x == 1
			and towToasts[#towToasts] == "On its wheels",
		"flipped where it is, facing the same way, damage kept"
	)
	check(not careerConvoy_tow.isHolding(), "flip upright: the rope comes off")
	truck.getDirectionVector, truck.getDirectionVectorUp, _G.quatFromDir = nil, nil, nil
end
careerConvoy_tow.release()
truck.getVelocity, fwd = nil, nil
_G.spawn, _G.gameplay_traffic = nil, nil
careerConvoy_util.toast = realToast
careerConvoy_phone.uiCloseApp("tow")
fwd = nil
-- switched off on the server: the app leaves the phone
cfgG.allowRopes = false
handlers.sc_configUpdate(json.encode(cfgG))
local stillThere = false
for _, app in ipairs(careerConvoy_phone.state().apps) do
	if app.id == "tow" then
		stillThere = true
	end
end
check(not stillThere, "ropes switched off: the Tow app leaves the phone")
cfgG.allowRopes = true
handlers.sc_configUpdate(json.encode(cfgG))
_G.gameplay_walk, _G.debugDrawer, _G.ColorF, _G.vec3 = nil, nil, nil, nil
-- the last toast message (the Tow app's state goes through the same guihooks mock)
local function lastToast()
	for i = #toasts, 1, -1 do
		if toasts[i].msg then
			return toasts[i].msg
		end
	end
	return ""
end
-- the vehicle you sit in can't be roped (the camera would move with it)
fwd = { x = 1, y = 0, z = -0.1 }
world.playerVeh = 60
toasts = {}
careerConvoy_tow.uiAttachView()
check(not careerConvoy_tow.isHolding() and lastToast():find("Get out"), "the vehicle you are in can't be roped")
core_camera.getActiveGlobalCameraName = function()
	return "free"
end
careerConvoy_tow.uiAttachView()
check(careerConvoy_tow.isHolding(), "from the free camera it can")
careerConvoy_tow.release()
core_camera.getActiveGlobalCameraName = nil
world.playerVeh = nil
-- refusals (attach where I look)
local function tryRope(dir)
	fwd = dir
	toasts = {}
	careerConvoy_tow.uiAttachView()
	local held = careerConvoy_tow.isHolding()
	careerConvoy_tow.release()
	return held, lastToast()
end
placedVeh(61, -10, 10, 1, nil, true)
local held, msg = tryRope({ x = -1, y = 1, z = -0.1 })
check(not held and msg:find("your own"), "another player's vehicle can't be roped")
placedVeh(62, 0, -10, 1, "unicycle")
held, msg = tryRope({ x = 0, y = -1, z = -0.1 })
check(not held and msg:find("on foot"), "a player on foot can't be roped")
held, msg = tryRope({ x = -1, y = -1, z = 0 })
check(not held and msg:find("Look at"), "no vehicle in view: hint")
held, msg = tryRope(nil)
check(not held, "no view direction: nothing attached")
cfgG.allowRopes = false
handlers.sc_configUpdate(json.encode(cfgG))
held, msg = tryRope({ x = 1, y = 0, z = -0.1 })
check(not held and msg:find("off on this server"), "switched off on the server: no ropes")
cfgG.allowRopes = true
handlers.sc_configUpdate(json.encode(cfgG))
fwd = { x = 1, y = 0, z = -0.1 }
careerConvoy_tow.uiAttachView()
cfgG.allowRopes = false
handlers.sc_configUpdate(json.encode(cfgG))
frames(0.05)
check(not careerConvoy_tow.isHolding() and lastHand(truck) == "ropeRelease", "switched off while holding: lets go")
fwd = nil
_G.core_camera, _G.MPKeybindsGE = nil, nil

--== 7b6. Phone ===============================================================
resetWorld()
installCareer()
local phoneKey
_G.MPKeybindsGE = {
	addAction = function(name, def)
		if name == "careerConvoyPhone" then
			phoneKey = def
		end
	end,
}
local phoneHooks = {}
_G.guihooks = {
	trigger = function(name, data)
		table.insert(phoneHooks, { name = name, data = data })
	end,
}
extensions.hook("onWorldReadyState", 2)
local cfgP = {}
for k, v in pairs(config) do
	cfgP[k] = v
end
cfgP.phone, cfgP.allowRopes = true, true
handlers.sc_config(json.encode(cfgP))
update()
local function lastPhone(name)
	for i = #phoneHooks, 1, -1 do
		if phoneHooks[i].name == name then
			return phoneHooks[i].data
		end
	end
end
check(phoneKey and phoneKey.default == "f4" and phoneKey.title:find("phone"), "phone key registered via BeamMP (F4)")
local st = lastPhone("CareerConvoyPhone")
check(
	st
		and st.enabled == true
		and #st.apps == 5
		and st.apps[1].id == "tow"
		and st.apps[2].id == "straps"
		and st.apps[3].id == "fuel"
		and st.apps[4].id == "apps"
		and st.apps[5].id == "settings",
	"phone on, with the built-in apps Tow, Straps and Fuel, then Apps, Settings last"
)
phoneHooks = {}
phoneKey.onDown()
check(lastPhone("CareerConvoyPhoneToggle") ~= nil, "F4 takes the phone out / puts it away")
-- game menus: opening one puts the phone away; F4 there only puts it away, never takes it out
phoneHooks = {}
careerConvoy_phone.onUiChangedState("pause", "play")
check(lastPhone("CareerConvoyPhoneAway") ~= nil, "a game menu opens: the phone goes away")
phoneHooks = {}
phoneKey.onDown()
check(
	lastPhone("CareerConvoyPhoneAway") ~= nil and lastPhone("CareerConvoyPhoneToggle") == nil,
	"F4 in a game menu: puts the phone away, doesn't take it out"
)
_G.ui_menuManager = {
	getGameplayRoute = function()
		return "mission.play"
	end,
}
phoneHooks = {}
careerConvoy_phone.onUiChangedState("mission.play", "pause")
check(lastPhone("CareerConvoyPhoneAway") == nil, "back to driving (a mission's screen): the phone stays")
phoneKey.onDown()
check(lastPhone("CareerConvoyPhoneToggle") ~= nil, "F4 while driving a mission: takes the phone out")
_G.ui_menuManager = nil
careerConvoy_phone.onUiChangedState("play", "mission.play")
-- apps register themselves (for later): sorted by order, then title; no functions in the window state
local opened = 0
check(
	careerConvoy_phone.registerApp({
		id = "taxi",
		title = "Taxi",
		icon = "T",
		color = "#e0a800",
		order = 20,
		onOpen = function()
			opened = opened + 1
		end,
	}),
	"an app can register"
)
careerConvoy_phone.registerApp({ id = "jobs", title = "Jobs", order = 10 })
careerConvoy_phone.registerApp({
	id = "bank",
	title = "Bank",
	order = 10,
	onOpen = function()
		error("boom")
	end,
})
check(not careerConvoy_phone.registerApp({ title = "no id" }), "an app without an id is refused")
st = lastPhone("CareerConvoyPhone")
local ids = {}
for _, app in ipairs(st.apps) do
	table.insert(ids, app.id)
end
check(
	table.concat(ids, ",") == "bank,jobs,tow,straps,fuel,taxi,apps,settings",
	"apps sorted by order, then title: " .. table.concat(ids, ",")
)
check(
	st.apps[2].icon == "J" and st.apps[2].color == "#ff6600" and st.apps[1].onOpen == nil,
	"defaults for icon and color; no functions sent to the window"
)
check(careerConvoy_phone.uiOpenApp("taxi") == true and opened == 1, "a tap opens the app")
check(careerConvoy_phone.uiOpenApp("bank") == true, "an app that fails to open doesn't break the phone")
check(careerConvoy_phone.uiOpenApp("nope") == false, "unknown app: nothing happens")
careerConvoy_phone.unregisterApp("bank")
check(#lastPhone("CareerConvoyPhone").apps == 7, "an app can be unregistered again")
-- Apps app: remove and install apps, kept in state.json; Apps and Settings always stay
do
	local saved = {}
	local readFile, writeFile = _G.jsonReadFile, _G.jsonWriteFile
	_G.jsonReadFile = function(path)
		return saved[path]
	end
	_G.jsonWriteFile = function(path, data)
		saved[path] = data
		return true
	end
	local function appIn(id)
		for _, app in ipairs(lastPhone("CareerConvoyPhone").apps) do
			if app.id == id then
				return app
			end
		end
	end
	check(careerConvoy_phone.uiInstall("taxi", false) == true, "an app can be removed")
	local stateFile = saved["settings/careerConvoy/state.json"]
	check(
		appIn("taxi").installed == false and stateFile and stateFile.removedApps[1] == "taxi",
		"removed: off the home screen, kept in state.json"
	)
	check(careerConvoy_phone.uiOpenApp("taxi") == true and opened == 2, "a removed app can still be opened")
	check(
		careerConvoy_phone.uiInstall("settings", false) == false
			and careerConvoy_phone.uiInstall("apps", false) == false
			and appIn("settings").installed
			and appIn("apps").installed
			and not appIn("settings").removable,
		"Apps and Settings can't be removed"
	)
	check(careerConvoy_phone.uiInstall("nope", false) == false, "unknown app: nothing happens")
	careerConvoy_phone.uiInstall("taxi", true)
	check(
		appIn("taxi").installed == true and #saved["settings/careerConvoy/state.json"].removedApps == 0,
		"installed again: back on the home screen"
	)
	local removedCalls = 0
	careerConvoy_phone.registerApp({
		id = "radio",
		title = "Radio",
		onRemove = function()
			removedCalls = removedCalls + 1
		end,
	})
	careerConvoy_phone.uiInstall("radio", false)
	careerConvoy_phone.uiInstall("radio", false)
	check(removedCalls == 1, "removing an app calls its onRemove once")
	careerConvoy_phone.uiInstall("radio", true)
	careerConvoy_phone.unregisterApp("radio")
	_G.jsonReadFile, _G.jsonWriteFile = readFile, writeFile
end
-- switched off on the server: hidden, key does nothing, apps don't open
cfgP.phone = false
handlers.sc_configUpdate(json.encode(cfgP))
check(lastPhone("CareerConvoyPhone").enabled == false, "switched off: the window hides the phone")
phoneHooks = {}
phoneKey.onDown()
check(lastPhone("CareerConvoyPhoneToggle") == nil, "switched off: F4 does nothing")
check(careerConvoy_phone.uiOpenApp("taxi") == false and opened == 2, "switched off: apps don't open")
_G.MPKeybindsGE = nil

--== 7c. Time of day and pause menu ==========================================
resetWorld()
installCareer()
local env = careerConvoy_env
check(
	env.toGame(12) == 0 and env.toGame(18) == 0.25 and env.toGame(0) == 0.5 and env.toGame(6) == 0.75,
	"conversion hour -> BeamNG (0 = noon)"
)
check(env.fromGame(0.75) == 6 and env.hourDistance(23.9, 0.1) < 0.21, "conversion back and distance across midnight")
local tod = { time = env.toGame(9), play = false, dayLength = 1800, azimuthOverride = 0 }
local setCalls = 0
_G.core_environment = {
	getTimeOfDay = function()
		return tod
	end,
	setTimeOfDay = function(t)
		setCalls = setCalls + 1
		tod = t
	end,
}
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
handlers.sc_time(json.encode({ hour = 18, dayLength = 3600, play = true }))
check(math.abs(tod.time - 0.25) < 1e-9 and tod.play == true and tod.dayLength == 3600, "server time applied")
check(tod.azimuthOverride == 0, "other time settings are kept")
local calls = setCalls
handlers.sc_time(json.encode({ hour = 18.02, dayLength = 3600, play = true }))
check(setCalls == calls, "small difference (1 min) -> no jump")
handlers.sc_time(json.encode({ hour = 20, dayLength = 3600, play = true }))
check(setCalls == calls + 1 and math.abs(env.fromGame(tod.time) - 20) < 1e-9, "large difference is corrected")
local cfgT = {}
for k, v in pairs(config) do
	cfgT[k] = v
end
cfgT.syncTimeOfDay = false
handlers.sc_configUpdate(json.encode(cfgT))
calls = setCalls
handlers.sc_time(json.encode({ hour = 3, dayLength = 3600, play = true }))
check(setCalls == calls, "switched off -> the player keeps their time")

-- day/night speed: at the switch at 20:00 the client switches by itself
cfgT.syncTimeOfDay = true
handlers.sc_configUpdate(json.encode(cfgT))
local msgDN = {
	hour = 19.99,
	play = true,
	dayLength = 4628,
	dayLengthDay = 4628,
	dayLengthNight = 2160,
	dayStart = 6,
	nightStart = 20,
}
handlers.sc_time(json.encode(msgDN))
check(tod.dayLength == 4628 and tod.play == true, "day speed during the day")
check(
	env.lengthFor(msgDN, 23) == 2160 and env.lengthFor(msgDN, 5.9) == 2160 and env.lengthFor(msgDN, 6) == 4628,
	"day/night boundaries correct"
)
tod.time = env.toGame(20.01) -- the game ran past 20:00 by itself
update(1.1)
check(tod.dayLength == 2160, "night speed from 20:00, without a server message")
check(math.abs(env.fromGame(tod.time) - 20.01) < 1e-6, "switching does not change the time")
calls = setCalls
update(1.1)
check(setCalls == calls, "no constant resetting")

-- UI window: state and control
local uiEvents = {}
_G.guihooks = {
	trigger = function(name, data)
		if name == "CareerConvoyState" then
			table.insert(uiEvents, data)
		end
	end,
}
careerConvoy_menu.onBeamMPServerLeave() -- nothing visible
handlers.sc_time(json.encode({
	hour = 19.5,
	play = true,
	dayLength = 3600,
	dayLengthDay = 3600,
	dayLengthNight = 720,
	dayStart = 6,
	nightStart = 20,
	dayMinutes = 50,
	nightMinutes = 5,
	canControl = true,
}))
update(1.1)
update(1.1)
check(#uiEvents == 0, "menu collapsed, phone away: no state built or sent (neither on news nor every second)")
careerConvoy_menu.uiVisible("menu", true)
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
-- the server drops a second change within 1 s: quick clicks wait and are sent one by one
do
	local function sentCount(event)
		local n = 0
		for _, sent in ipairs(sentToServer) do
			if sent.event == event then
				n = n + 1
			end
		end
		return n
	end
	local sentControls = sentCount("sc_timeControl")
	env.uiShiftHour(1)
	check(sentCount("sc_timeControl") == sentControls, "second +1 h right away: waits instead of getting lost")
	update(0.5)
	check(sentCount("sc_timeControl") == sentControls, "still waiting before the gap is over")
	update(1)
	check(
		sentCount("sc_timeControl") == sentControls + 1 and math.abs(lastSent("sc_timeControl").hour - 21.5) < 0.01,
		"then sent; +1 h, +1 h add up to +2 h before the server answered"
	)
	update(1.4)
	env.uiSetHour(7)
	env.uiSetHour(12)
	env.uiSetHour(23)
	check(math.abs(lastSent("sc_timeControl").hour - 7) < 0.01, "Morning goes out at once")
	update(1.4)
	update(1.4)
	check(
		math.abs(lastSent("sc_timeControl").hour - 23) < 0.01 and sentCount("sc_timeControl") == sentControls + 3,
		"Noon, then Night while waiting: only Night is sent"
	)
end
env.uiShiftHour(-21)
update(1.4)
check(math.abs(lastSent("sc_timeControl").hour - 2) < 0.01, "calculating across midnight")
env.uiSetLengths(45, 10)
update(1.4)
ctl = lastSent("sc_timeControl")
check(ctl.action == "lengths" and ctl.dayMinutes == 45 and ctl.nightMinutes == 10, "lengths go to the server")

-- clock paused
update(1.4)
careerConvoy_menu.uiVisible("menu", true) -- the open window reports every 2 s
env.uiSetPaused(true)
check(
	lastSent("sc_timeControl").action == "pause" and lastSent("sc_timeControl").paused == true,
	"pause goes to the server"
)
handlers.sc_time(json.encode({
	hour = 15,
	play = false,
	paused = true,
	dayLength = 0,
	dayStart = 6,
	nightStart = 20,
	dayMinutes = 50,
	nightMinutes = 5,
	canControl = true,
}))
check(tod.play == false and math.abs(env.fromGame(tod.time) - 15) < 1e-6, "paused: game clock stands at 15:00")
check(uiEvents[#uiEvents].paused == true, "window knows the clock is paused")
local setsPaused = setCalls
update(1.1)
update(1.1)
check(setCalls == setsPaused, "paused: no speed switching")

-- real time (the server's clock)
update(1.4)
careerConvoy_menu.uiVisible("menu", true) -- the open window reports every 2 s
env.uiSetRealtime(true)
check(
	lastSent("sc_timeControl").action == "realtime" and lastSent("sc_timeControl").on == true,
	"real time goes to the server"
)
handlers.sc_time(json.encode({
	hour = 21.5,
	play = true,
	paused = false,
	realtime = true,
	dayLength = 86400,
	dayLengthDay = 86400,
	dayLengthNight = 86400,
	dayStart = 6,
	nightStart = 20,
	dayMinutes = 50,
	nightMinutes = 5,
	canControl = true,
}))
check(
	tod.play == true and tod.dayLength == 86400 and math.abs(env.fromGame(tod.time) - 21.5) < 1e-6,
	"real time: game clock at the server's time, real speed"
)
check(uiEvents[#uiEvents].realtime == true, "window knows real time is on")
handlers.sc_time(json.encode({
	hour = 15,
	play = false,
	paused = true,
	dayLength = 0,
	dayStart = 6,
	nightStart = 20,
	dayMinutes = 50,
	nightMinutes = 5,
	canControl = true,
}))

do
	local menu = careerConvoy_menu
	-- who looks: reports with a lease (windows report every 2 s while visible)
	local function pushesDuring(seconds, beat)
		local before, t, sinceBeat = #uiEvents, 0, 0
		while t < seconds - 1e-9 do
			update(0.5)
			t, sinceBeat = t + 0.5, sinceBeat + 0.5
			if beat and sinceBeat >= 2 then
				sinceBeat = 0
				beat()
			end
		end
		return #uiEvents - before
	end
	menu.onBeamMPServerLeave()
	menu.uiVisible("menu", true)
	local kept = pushesDuring(10, function()
		menu.uiVisible("menu", true)
	end)
	check(
		kept >= 9 and kept <= 11,
		"menu reports every 2 s: the state keeps coming every second (" .. kept .. " in 10 s)"
	)
	check(
		menu.isVisible("menu") and not menu.isVisible("phone") and not menu.isVisible("fuel"),
		"only the menu counts as visible"
	)
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
	handlers.sc_time(json.encode({
		hour = 15,
		play = false,
		paused = true,
		dayLength = 0,
		dayStart = 6,
		nightStart = 20,
		dayMinutes = 50,
		nightMinutes = 5,
		canControl = true,
	}))
	check(
		pushesDuring(0) == 0 and #uiEvents == repeated + tail + afterLease + 1,
		"news from the server while nothing is visible: not sent"
	)
	-- the phone's home screen (time, players) keeps the state coming, without fuel prices
	local before = #uiEvents
	menu.uiVisible("phone", true)
	check(
		#uiEvents == before + 1 and uiEvents[#uiEvents].fuel == false and uiEvents[#uiEvents].hour ~= nil,
		"phone out: state at once, fuel = false (Fuel app closed)"
	)
	check(
		pushesDuring(2) >= 1 and uiEvents[#uiEvents].fuel == false,
		"phone out: every second, still without the station list"
	)
	check(
		uiEvents[#uiEvents].dayStart == 6 and uiEvents[#uiEvents].nightStart == 20,
		"phone out: day and night start for the home screen's bar"
	)
	-- the Fuel app open: fuel prices at once (nil: this test map has no gas stations)
	local fuelAsked = 0
	local realOverview = careerConvoy_fuel.overview
	careerConvoy_fuel.overview = function()
		fuelAsked = fuelAsked + 1
		return { stations = { { id = "apex" } } }
	end
	before = #uiEvents
	menu.uiVisible("fuel", true)
	check(
		#uiEvents == before + 1 and type(uiEvents[#uiEvents].fuel) == "table" and fuelAsked == 1,
		"Fuel app open: prices at once"
	)
	local asked = fuelAsked
	pushesDuring(3, function()
		menu.uiVisible("phone", true)
		menu.uiVisible("fuel", true)
	end)
	check(fuelAsked - asked >= 2 and type(uiEvents[#uiEvents].fuel) == "table", "Fuel app open: prices every second")
	menu.uiVisible("fuel", false)
	asked = fuelAsked
	pushesDuring(3, function()
		menu.uiVisible("phone", true)
	end)
	check(
		fuelAsked == asked and uiEvents[#uiEvents].fuel == false,
		"Fuel app closed: no prices computed, phone still updated"
	)
	careerConvoy_fuel.overview = function()
		return nil
	end
	menu.uiVisible("fuel", true)
	check(
		uiEvents[#uiEvents].fuel == nil,
		"Fuel app open on a map without stations: fuel = nil (empty list, not false)"
	)
	careerConvoy_fuel.overview = function()
		error("broken")
	end
	menu.uiVisible("fuel", false)
	menu.uiVisible("fuel", true)
	check(
		uiEvents[#uiEvents].hour ~= nil and uiEvents[#uiEvents].fuel == nil,
		"a fuel error doesn't break the rest of the state"
	)
	careerConvoy_fuel.overview = realOverview
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
	getEnvironmentData = function()
		return { locked = settings.getValue("restrictScenarios") == true }
	end,
	getEnvironmentWeatherData = function()
		return { locked = settings.getValue("restrictScenarios") == true }
	end,
	requestEnvironmentTrafficPayload = function(p)
		seen.editable = p.editable
	end,
}
handlers.sc_configUpdate(json.encode(config))
update(1.1)
local pause = ui_pause_providers_routeData_environment
check(
	pause.getEnvironmentData().locked == true and pause.getEnvironmentWeatherData().locked == true,
	"time/weather locked in the pause menu"
)
check(settings.getValue("restrictScenarios") ~= true, "lock only applies during the page, not globally")
pause.requestEnvironmentTrafficPayload({ editable = true })
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
local function deep(t)
	return json.decode(json.encode(t))
end
_G.FS = {
	fileExists = function(_, path)
		return files[path] ~= nil
	end,
	findFiles = function(_, dir, pattern)
		local out = {}
		for path in pairs(files) do
			if path:sub(1, #dir) == dir and path:match("%.uilayout%.json$") then
				table.insert(out, path)
			end
		end
		table.sort(out)
		return out
	end,
}
_G.jsonReadFile = function(path)
	return files[path] and deep(files[path]) or nil
end
_G.jsonWriteFile = function(path, data)
	files[path] = deep(data)
	return true
end
local listPlacement = { right = "0px", top = "240px", width = "300px", height = "560px" }
files["/settings/ui_apps/layouts/default/career.uilayout.json"] = {
	apps = {
		{ appName = "tacho2" },
		{ appName = "beammpChat" },
		{ appName = "mileageplayerlist", placement = listPlacement },
		{ appName = "mileageoffers" },
		{ appName = "mileagerace" },
	},
}
files["/settings/ui_apps/layouts/default/freeroam.uilayout.json"] =
	{ apps = {
		{ appName = "beammpPlayerListVue" },
		{ appName = "mileageplayerlist" },
	} }
files["/settings/ui_apps/layouts/default/eigenes.uilayout.json"] = { apps = { { appName = "tacho2" } } }
local toastsBefore = #toasts
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
local career = files["/settings/ui_apps/layouts/default/career.uilayout.json"]
local names = {}
for _, app in ipairs(career.apps) do
	names[#names + 1] = app.appName
end
check(
	table.concat(names, ",") == "tacho2,beammpChat,beammpPlayerListVue",
	"Mileage apps gone, BeamMP player list back: " .. table.concat(names, ",")
)
check(career.apps[3].placement.top == "240px", "BeamMP list in place of the Mileage list")
local free = files["/settings/ui_apps/layouts/default/freeroam.uilayout.json"]
check(#free.apps == 1 and free.apps[1].appName == "beammpPlayerListVue", "no duplicate player list")
check(
	files["/settings/ui_apps/layouts/default/career.uilayout.json.careerconvoy-backup"].apps[3].appName
		== "mileageplayerlist",
	"original is backed up first"
)
check(
	files["/settings/ui_apps/layouts/default/eigenes.uilayout.json.careerconvoy-backup"] == nil,
	"unchanged layouts are not touched"
)
check(#toasts > toastsBefore, "player gets a notice")
check(careerConvoy_cleanup.run() == 0, "second run finds nothing")
-- switched off
resetWorld()
installCareer()
local findCalls = 0
_G.FS = {
	fileExists = function()
		return false
	end,
	findFiles = function()
		findCalls = findCalls + 1
		return {}
	end,
}
local cfgOff = {}
for k, v in pairs(config) do
	cfgOff[k] = v
end
cfgOff.cleanupMileageApps = false
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(cfgOff))
update()
check(
	lastSent("sc_careerResult") and lastSent("sc_careerResult").ok == true and findCalls == 0,
	"switched off: cleanup does not run"
)

--== 7e. Career-Convoy apps into the career layout once ========================
local function joinWith(filesInit, cfgChange)
	resetWorld()
	installCareer()
	files = filesInit
	_G.FS = {
		fileExists = function(_, path)
			return files[path] ~= nil
		end,
		findFiles = function()
			return {}
		end,
	}
	_G.jsonReadFile = function(path)
		return files[path] and deep(files[path]) or nil
	end
	_G.jsonWriteFile = function(path, data)
		files[path] = deep(data)
		return true
	end
	local c = {}
	for k, v in pairs(config) do
		c[k] = v
	end
	for k, v in pairs(cfgChange or {}) do
		c[k] = v
	end
	extensions.hook("onWorldReadyState", 2)
	handlers.sc_config(json.encode(c))
	update()
end
local CUSTOM = "settings/ui_apps/layouts/default/career.uilayout.json"
local ORIGINAL = "settings/ui_apps/originalLayouts/default/career.uilayout.json"
local function hasMenuApp(layout)
	for _, a in ipairs(layout and layout.apps or {}) do
		if a.appName == "careerConvoyMenu" then
			return true
		end
	end
	return false
end
-- 1) player without an own career layout: original + window
joinWith({ [ORIGINAL] = { apps = { { appName = "tacho2" } }, title = "career" } })
check(
	hasMenuApp(files[CUSTOM]) and files[CUSTOM].apps[1].appName == "tacho2",
	"window added to the career layout (from the original)"
)
check(
	files[CUSTOM].apps[2].placement.top == "600px" and files[CUSTOM].apps[2].placement.height == "190px",
	"placed right, below the player list"
)
check(files["settings/careerConvoy/state.json"].menuAppAdded == true, "remembered: already added")
local phoneApp
for _, a in ipairs(files[CUSTOM].apps) do
	if a.appName == "careerConvoyPhone" then
		phoneApp = a
	end
end
check(
	phoneApp
		and phoneApp.placement.top == "790px"
		and phoneApp.placement.width == "30px"
		and files["settings/careerConvoy/state.json"].phoneAppAdded == true,
	"phone tab added once, directly below the menu, only as big as the tab"
)
do
	local signApp
	for _, a in ipairs(files[CUSTOM].apps) do
		if a.appName == "careerConvoySpeedLimit" then
			signApp = a
		end
	end
	check(
		signApp
			and signApp.placement.right == "40px"
			and signApp.placement.bottom == "300px"
			and signApp.placement.top == ""
			and files["settings/careerConvoy/state.json"].speedLimitAppAdded == true,
		"speed limit sign added once, bottom right, left of the phone tab"
	)
end
-- 2) player removes it again -> NOT added again on the next join
local removedLayout = { apps = { { appName = "tacho2" } } }
joinWith({ [CUSTOM] = removedLayout, ["settings/careerConvoy/state.json"] = { menuAppAdded = true } })
check(not hasMenuApp(files[CUSTOM]), "removed window is not forced back")
-- 3) own layout is kept, a backup is created
joinWith({ [CUSTOM] = { apps = { { appName = "meineApp" } } } })
check(files[CUSTOM].apps[1].appName == "meineApp" and hasMenuApp(files[CUSTOM]), "own layout stays, window is added")
check(files[CUSTOM .. ".careerconvoy-backup"].apps[1].appName == "meineApp", "backup of the own layout")
-- 4) already there (added by the player) -> not twice
joinWith({ [CUSTOM] = { apps = { { appName = "careerConvoyMenu" } } } })
local menuCount, phoneCount = 0, 0
for _, a in ipairs(files[CUSTOM].apps) do
	if a.appName == "careerConvoyMenu" then
		menuCount = menuCount + 1
	end
	if a.appName == "careerConvoyPhone" then
		phoneCount = phoneCount + 1
	end
end
check(menuCount == 1 and phoneCount == 1, "menu not duplicated, phone tab is added")
-- phone: own flag – players who remove the phone tab don't get it back
joinWith({
	[CUSTOM] = { apps = { { appName = "careerConvoyMenu" } } },
	["settings/careerConvoy/state.json"] = {
		menuAppAdded = true,
		phoneAppAdded = true,
		fuelAppRetired = true,
		phoneTabUp = true,
		menuTaller = true,
		phoneTabBelowTallerMenu = true,
	},
})
local phoneBack = 0
for _, a in ipairs(files[CUSTOM].apps) do
	if a.appName == "careerConvoyPhone" then
		phoneBack = phoneBack + 1
	end
end
check(phoneBack == 0, "removed phone tab is not forced back")
-- update from 0.12: the separate fuel window is gone (it's on the phone now) -> taken out once,
-- and the phone tab moves up to its place, directly below the menu
joinWith({
	[CUSTOM] = {
		apps = {
			{ appName = "careerConvoyMenu", placement = { right = "0px", top = "600px", height = "300px" } },
			{ appName = "sharedCareerFuel", placement = { right = "0px", top = "760px" } },
			{ appName = "careerConvoyPhone", placement = { right = "0px", top = "920px" } },
		},
	},
	["settings/careerConvoy/state.json"] = {
		menuAppAdded = true,
		fuelAppAdded = true,
		phoneAppAdded = true,
		speedLimitAppAdded = true,
	},
})
local names, phoneTop = {}, nil
for _, a in ipairs(files[CUSTOM].apps) do
	table.insert(names, a.appName)
	if a.appName == "careerConvoyPhone" then
		phoneTop = a.placement.top
	end
end
check(
	table.concat(names, ",") == "careerConvoyMenu,careerConvoyPhone",
	"old fuel window removed from the layout (no red 'Unknown app' box): " .. table.concat(names, ",")
)
check(
	phoneTop == "790px"
		and files[CUSTOM].apps[1].placement.top == "600px"
		and files[CUSTOM].apps[1].placement.height == "300px",
	"phone tab moved up below the menu; a menu the player resized keeps its size"
)
local st = files["settings/careerConvoy/state.json"]
check(
	st.fuelAppRetired == true and st.phoneTabUp == true and st.menuTaller == true and st.phoneTabBelowTallerMenu == true,
	"all changes remembered (only once)"
)
-- update from 0.25: the menu gets taller, the phone tab moves down with it
joinWith({
	[CUSTOM] = {
		apps = {
			{
				appName = "careerConvoyMenu",
				placement = { right = "0px", top = "600px", width = "345px", height = "160px" },
			},
			{
				appName = "careerConvoyPhone",
				placement = { right = "0px", top = "760px", width = "30px", height = "80px" },
			},
		},
	},
	["settings/careerConvoy/state.json"] = {
		menuAppAdded = true,
		phoneAppAdded = true,
		fuelAppRetired = true,
		phoneTabUp = true,
	},
})
check(
	files[CUSTOM].apps[1].placement.height == "190px" and files[CUSTOM].apps[2].placement.top == "790px",
	"menu taller, phone tab right below it"
)
-- the player moved the phone tab somewhere else -> it stays there
joinWith({
	[CUSTOM] = { apps = { { appName = "careerConvoyPhone", placement = { right = "120px", top = "300px" } } } },
	["settings/careerConvoy/state.json"] = { menuAppAdded = true, phoneAppAdded = true },
})
check(
	files[CUSTOM].apps[1].placement.right == "120px" and files[CUSTOM].apps[1].placement.top == "300px",
	"the player's own position stays"
)
-- 0.15.0: the menu app was renamed sharedCareerTime -> careerConvoyMenu
do
	local OTHER = "settings/ui_apps/layouts/default/freeroam.uilayout.json"
	local oldMenu = { appName = "sharedCareerTime", placement = { right = "0px", top = "650px" } }
	joinWith({}) -- fresh file mocks
	files[CUSTOM] = { apps = { { appName = "tacho2" }, oldMenu, { appName = "careerConvoyPhone" } } }
	files[OTHER] = { apps = { { appName = "sharedCareerTime" }, { appName = "careerConvoyMenu" } } }
	files["settings/careerConvoy/state.json"] = { timeAppAdded = true, phoneAppAdded = true, speedLimitAppAdded = true }
	FS.findFiles = function(_, dir)
		return dir == "settings/ui_apps/layouts/" and { CUSTOM, OTHER } or {}
	end
	check(careerConvoy_cleanup.renameAppsOnce() == 2, "rename: one in the career layout, one duplicate elsewhere")
	local names = {}
	for _, a in ipairs(files[CUSTOM].apps) do
		table.insert(names, a.appName)
	end
	check(
		table.concat(names, ",") == "tacho2,careerConvoyMenu,careerConvoyPhone"
			and files[CUSTOM].apps[2].placement.top == "650px",
		"career layout: renamed in place, the player's position stays (" .. table.concat(names, ",") .. ")"
	)
	check(
		#files[OTHER].apps == 1 and files[OTHER].apps[1].appName == "careerConvoyMenu",
		"other layout: the old duplicate is removed"
	)
	local st = files["settings/careerConvoy/state.json"]
	check(
		st.menuAppRenamed == true and st.menuAppAdded == true and st.timeAppAdded == nil,
		"state: rename remembered, old flag timeAppAdded becomes menuAppAdded"
	)
	check(careerConvoy_cleanup.addAppsOnce() == 0, "a menu the player once removed isn't added back after the rename")
	files[CUSTOM] = { apps = { { appName = "sharedCareerTime" } } }
	check(
		careerConvoy_cleanup.renameAppsOnce() == 0 and files[CUSTOM].apps[1].appName == "sharedCareerTime",
		"rename runs only once"
	)
end
-- the mod was called SharedCareer: its state file and apps take the new names, nothing comes twice
do
	joinWith({}) -- fresh file mocks
	local OLD_STATE, STATE = "settings/sharedCareer/state.json", "settings/careerConvoy/state.json"
	files[STATE] = nil
	files[OLD_STATE] = { menuAppAdded = true, phoneAppAdded = true, speedLimitAppAdded = true, menuAppRenamed = true }
	FS.removeFile = function(_, path)
		files[path] = nil
	end
	files[CUSTOM] = {
		apps = {
			{ appName = "sharedCareerMenu", placement = { right = "0px", top = "600px" } },
			{ appName = "sharedCareerPhone" },
			{ appName = "sharedCareerSpeedLimit" },
		},
	}
	FS.findFiles = function(_, dir)
		return dir == "settings/ui_apps/layouts/" and { CUSTOM } or {}
	end
	check(careerConvoy_cleanup.renameAppsOnce() == 3, "the three apps renamed")
	local names = {}
	for _, a in ipairs(files[CUSTOM].apps) do
		table.insert(names, a.appName)
	end
	check(
		table.concat(names, ",") == "careerConvoyMenu,careerConvoyPhone,careerConvoySpeedLimit"
			and files[CUSTOM].apps[1].placement.top == "600px",
		"apps keep their place under the new names (" .. table.concat(names, ",") .. ")"
	)
	check(files[OLD_STATE] == nil and files[STATE] and files[STATE].menuAppAdded == true, "state file moved")
	check(careerConvoy_cleanup.addAppsOnce() == 0, "no app added twice after the rename")
end
-- 5) switched off
joinWith({ [ORIGINAL] = { apps = {} } }, { addApps = false })
check(files[CUSTOM] == nil, "addApps = false: nothing added")
-- 6) no layout found -> nothing broken, try again later
joinWith({})
check(
	(files["settings/careerConvoy/state.json"] or {}).menuAppAdded == nil and lastSent("sc_careerResult").ok == true,
	"without a layout: career starts, retry next time"
)

--== 7f. Menu: live traffic with reserve ======================================
resetWorld()
installCareer()
local activeRoad, activeParked
gameplay_traffic.setActiveAmount = function(n)
	activeRoad = n
end
gameplay_parking.setActiveAmount = function(n)
	activeParked = n
end
local cfgM = {}
for k, v in pairs(config) do
	cfgM[k] = v
end
cfgM.trafficReserve = 4
cfgM.roadTraffic, cfgM.parkedTraffic = 4, 3
cfgM.ui = { allowPlayerSettings = true, roadTrafficTotal = 20, players = 1 }
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(cfgM))
update()
check(world.trafficSetup[1] == 8 and world.trafficSetup[3] == 7, "pool = share + reserve (4+4 / 3+4) spawned")
check(activeRoad == 4 and activeParked == 3, "only the share active, reserve hidden")
-- someone sets more in the menu: the server sends a new share
cfgM.trafficShare = { road = 7, parked = 2 }
handlers.sc_configUpdate(json.encode(cfgM))
check(activeRoad == 7 and activeParked == 2, "live more/less within the pool")
cfgM.trafficShare = { road = 20, parked = 20 }
handlers.sc_configUpdate(json.encode(cfgM))
check(activeRoad == 8 and activeParked == 7, "more than the pool: limited (rest on the next join)")
-- menu updated immediately when someone else changes something
local menuPushes = {}
_G.guihooks = {
	trigger = function(name, data)
		if name == "CareerConvoyState" then
			table.insert(menuPushes, data)
		end
	end,
}
careerConvoy_menu.uiVisible("menu", false)
cfgM.roadTraffic = 8
handlers.sc_configUpdate(json.encode(cfgM))
check(#menuPushes == 0, "menu collapsed: another player's change is not sent to it")
careerConvoy_menu.uiVisible("menu", true)
check(
	#menuPushes == 1 and menuPushes[1].settings.roadTraffic == 8,
	"expanding the menu: it shows the current value at once"
)
menuPushes = {}
cfgM.roadTraffic = 9
handlers.sc_configUpdate(json.encode(cfgM))
check(
	#menuPushes == 1 and menuPushes[1].settings.roadTraffic == 9,
	"menu shows another player's change immediately (without the 1 s tick)"
)
local st = careerConvoy_menu.settingsState()
check(
	st.poolRoad == 8 and st.poolParked == 7 and st.canEdit == true and st.shareRoad == 20,
	"menu knows pool and share"
)
careerConvoy_menu.uiSetSetting("client.roadTraffic", 9)
check(
	lastSent("sc_setSetting").key == "client.roadTraffic" and lastSent("sc_setSetting").value == 9,
	"menu sends a setting"
)
local n2 = #sentToServer
careerConvoy_menu.uiSetSetting("client.saveSuffix", "x")
check(#sentToServer == n2, "menu only sends allowed settings");

--== 7f2. Missions hide the traffic instead of deleting it =====================
(function()
	resetWorld()
	installCareer()
	local frozen, unfrozen
	gameplay_traffic.freezeState = function(options)
		frozen = options
		return "traffic", "police", "parking"
	end
	gameplay_traffic.unfreezeState = function(t, p, k, options)
		unfrozen = { t, p, k, options }
	end
	gameplay_traffic.getTrafficData = function()
		return { [70] = { isAi = true }, [71] = { isAi = true }, [73] = { isAi = false } }
	end
	gameplay_parking.getParkedCarsList = function()
		return { 72 }
	end
	extensions.hook("onWorldReadyState", 2)
	handlers.sc_config(json.encode(config))
	update()
	local car = addVehicle(70, "0-70", true)
	local pooled = addVehicle(71, "0-71", true)
	pooled.active = false
	local parked = addVehicle(72, "0-72", true)
	local player = addVehicle(73, "0-73", true)
	local t, p, k = gameplay_traffic.freezeState({ despawnVehicles = true, exceptVehicleId = 73 })
	check(
		frozen.despawnVehicles == false and frozen.exceptVehicleId == 73 and t == "traffic" and k == "parking",
		"mission start: the game keeps the cars (not deleted), its state comes back"
	)
	check(
		not car.deleted and car.active == false and parked.active == false and player.active == true,
		"mission start: traffic and parked cars hidden, the player's car stays"
	)
	gameplay_traffic.unfreezeState("traffic", "police", "parking", { respawnVehicles = true })
	check(
		car.active == true and parked.active == true and pooled.active == false,
		"mission end: shown again; a car the pool hid stays hidden"
	)
	check(unfrozen[1] == "traffic" and unfrozen[4].respawnVehicles == false, "mission end: nothing spawned again")
	gameplay_traffic.freezeState({ despawnVehicles = false })
	check(frozen.despawnVehicles == false and car.active == true, "a freeze that deletes nothing: left to the game")
	gameplay_traffic.freezeState({ despawnVehicles = true, exceptVehicleId = 73 })
	extensions.hook("onBeamMPServerLeave")
	check(car.active == true, "leaving the server during a mission: the cars are shown again")
end)()

--== 7g. Players tab, name tags and the menu key =============================
resetWorld()
installCareer()
local mpCalls = {}
MPVehicleGE.groundmarkerFollowPlayer = function(name)
	table.insert(mpCalls, { "nav", name })
end
MPVehicleGE.focusCameraOnPlayer = function(name)
	table.insert(mpCalls, { "watch", name })
end
MPVehicleGE.teleportVehToPlayer = function(name)
	table.insert(mpCalls, { "tp", name })
end
local suffixes = {}
MPVehicleGE.setPlayerNickSuffix = function(name, src, text)
	suffixes[name] = { src = src, text = text }
end
local keyAction
_G.MPKeybindsGE = {
	addAction = function(name, def)
		if name == "careerConvoyMenu" then
			keyAction = { name = name, def = def }
		end
	end,
}
local toggled = 0
_G.guihooks = {
	trigger = function(n)
		if n == "CareerConvoyToggle" then
			toggled = toggled + 1
		end
	end,
}
local cfgPl = {}
for k, v in pairs(config) do
	cfgPl[k] = v
end
cfgPl.ui = { allowTeleport = false }
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(cfgPl))
update()
check(
	keyAction and keyAction.def.default == "f7" and keyAction.def.title:find("Career-Convoy", 1, true),
	"menu key via BeamMP (F7)"
)
keyAction.def.onDown()
check(toggled == 1, "key collapses/expands the menu")
check(lastSent("sc_status") and lastSent("sc_status").status == "driving", "own status reported")
_G.gameplay_missions_missionManager = {
	getForegroundMissionId = function()
		return "m1"
	end,
}
update(2.1)
check(lastSent("sc_status").status == "mission", "mission is detected")
handlers.sc_players(json.encode({
	players = {
		{ id = 0, name = "John Doe_99", status = "mission" },
		{ id = 1, name = "Ben", status = "mission" },
		{ id = 2, name = "Eve", status = "driving" },
	},
}))
check(
	suffixes["Ben"] and suffixes["Ben"].text == "[Mission]" and suffixes["Ben"].src == "careerConvoy",
	"name tag: [Mission]"
)
check(suffixes["John Doe_99"] == nil, "own name tag unchanged")
handlers.sc_players(json.encode({ players = { { id = 1, name = "Ben", status = "driving" } } }))
check(suffixes["Ben"].text == "", "status gone -> suffix removed (empty text, not nil)")
local ps = careerConvoy_players.state()
check(#ps.list == 1 and ps.canTeleport == false, "Players state for the menu")
careerConvoy_players.uiNavigate("Ben")
check(
	mpCalls[#mpCalls][1] == "nav" and mpCalls[#mpCalls][2] == "Ben" and careerConvoy_players.state().navigating == "Ben",
	"Navigate"
)
careerConvoy_players.uiStopNavigate()
check(mpCalls[#mpCalls][2] == nil and careerConvoy_players.state().navigating == nil, "stop navigation")
-- a job route after navigating to a player: following stops, or BeamMP puts the route back to the player
do
	local routes = {}
	_G.vec3 = function(x, y, z)
		return { x = x, y = y, z = z }
	end
	_G.core_groundMarkers = {
		setPath = function(p)
			table.insert(routes, p or false)
		end,
	}
	careerConvoy_players.uiNavigate("Ben")
	careerConvoy_util.setRoute("jobs", { x = 7, y = 8, z = 9 })
	check(
		mpCalls[#mpCalls][1] == "nav" and mpCalls[#mpCalls][2] == nil and careerConvoy_players.state().navigating == nil,
		"job route: following the player stops"
	)
	check(routes[#routes] and routes[#routes].x == 7, "job route: route goes to the job")
	local before = #routes
	careerConvoy_players.uiStopNavigate()
	careerConvoy_util.clearRoute("fuel")
	check(#routes == before, "others don't clear the job route")
	careerConvoy_players.uiNavigate("Ben")
	careerConvoy_util.clearRoute("jobs")
	check(#routes == before and careerConvoy_players.state().navigating == "Ben", "job end keeps following the player")
	careerConvoy_players.uiStopNavigate()
	_G.vec3, _G.core_groundMarkers = nil, nil
end
local own = addVehicle(50, "0-50", true)
world.playerVeh = 50
local focus = {}
gameplay_traffic.setFocus = function(kind, opt)
	table.insert(focus, { kind, opt })
end
careerConvoy_players.uiWatch("Ben")
check(mpCalls[#mpCalls][1] == "watch" and focus[#focus][2].vehId == 50, "Watch: traffic stays around the own car")
world.playerVeh = 999
careerConvoy_players.uiBack()
check(world.playerVeh == 50 and focus[#focus][1] == nil, "Back: back into the own car")
local nCalls = #mpCalls
careerConvoy_players.uiTeleport("Ben")
check(#mpCalls == nCalls, "teleport forbidden if the server doesn't allow it")
cfgPl.ui.allowTeleport = true
handlers.sc_configUpdate(json.encode(cfgPl))
careerConvoy_players.uiTeleport("Ben")
check(mpCalls[#mpCalls][1] == "tp", "teleport allowed -> done")
cfgPl.showPlayerStatus = false
handlers.sc_players(json.encode({ players = { { id = 1, name = "Ben", status = "walking" } } }))
handlers.sc_configUpdate(json.encode(cfgPl))
check(suffixes["Ben"].text == "", "status on name tags can be switched off")
_G.gameplay_missions_missionManager = nil
_G.MPKeybindsGE = nil

--== 7h. Shared fuel prices ==================================================
local function setupFuelWorld(copyEachCall)
	resetWorld()
	installCareer()
	local stationsData = {
		{
			id = "apex",
			name = "levels.wcusa.gasStationPoints.apex.title",
			prices = {
				gasoline = { priceBaseline = 1.5, priceRandomnessGain = 0.2, priceRandomnessBias = 0.5 },
				diesel = { priceBaseline = 1.6, priceRandomnessGain = 0.2, priceRandomnessBias = 0.5 },
			},
		},
	}
	local function deep(t)
		return json.decode(json.encode(t))
	end
	_G.getCurrentLevelIdentifier = function()
		return "west_coast_usa"
	end
	_G.freeroam_facilities = {
		getFacilities = function()
			return { gasStations = copyEachCall and deep(stationsData) or stationsData }
		end,
	}
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
		getFuelPrice = function(id, fuel)
			return cached[id] and cached[id][fuel]
		end,
	}
	freeroam_facilities_fuelPrice.setDisplayPrices() -- like when the map loads: rolled
	return signs
end

local signs = setupFuelWorld(false)
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
update()
handlers.sc_fuelPrices(json.encode({ enabled = true, factors = { apex = { diesel = 0.9 } } }))
update()
local fp = freeroam_facilities_fuelPrice
check(
	math.abs(fp.getFuelPrice("apex", "gasoline") - 1.5) < 1e-9,
	"without delivery: base price without random part (same for everyone)"
)
check(math.abs(fp.getFuelPrice("apex", "diesel") - 1.44) < 1e-9, "diesel 10 % cheaper (1.6 × 0.9)")
check(signs["apex/diesel"] == "1.440", "price sign shows the new price")
-- overview for the fuel app
_G.core_levels = {
	getLevelByName = function()
		return { localUnits = { gasoline = "gallonUS", diesel = "gallonUS" } }
	end,
}
freeroam_facilities.getAverageDoorPositionForFacility = function(st)
	return { x = 300, y = 400, z = 0 }
end
local meVeh = addVehicle(60, "0-60", true)
function meVeh:getPosition()
	return { x = 0, y = 0, z = 0 }
end
world.playerVeh = 60
-- before loading: no position yet -> must not remember "no position" permanently
local realPos = freeroam_facilities.getAverageDoorPositionForFacility
freeroam_facilities.getAverageDoorPositionForFacility = function()
	return nil
end
check(careerConvoy_fuel.overview().stations[1].canNavigate == false, "position not known yet")
freeroam_facilities.getAverageDoorPositionForFacility = realPos
local ov = careerConvoy_fuel.overview()
local apexOv = ov and ov.stations[1]
check(apexOv and apexOv.id == "apex" and apexOv.fuels.diesel.unit == "gal", "overview: station with prices (map unit)")
check(
	math.abs(apexOv.fuels.diesel.price - 1.44 * 3.78541) < 1e-6 and apexOv.fuels.diesel.discount == 10,
	"price per gallon and discount"
)
check(apexOv.fuels.gasoline.discount == 0, "gasoline without discount")
check(math.abs(apexOv.distance - 500) < 1e-6 and apexOv.canNavigate == true, "distance to the player (500 m)")
local pathSet = "unset"
_G.core_groundMarkers = {
	setPath = function(pos)
		pathSet = pos
	end,
}
_G.vec3 = function(x, y, z)
	return { x = x, y = y, z = z }
end
careerConvoy_fuel.uiNavigate("apex")
check(
	type(pathSet) == "table" and pathSet.x == 300 and careerConvoy_fuel.overview().navigating == "apex",
	"Go: route to the station"
)
careerConvoy_fuel.uiStopNavigate()
check(pathSet == nil and careerConvoy_fuel.overview().navigating == nil, "Stop: route off")
-- issue #1: the door function gives the same point for every gas station -> use the pumps
do
	local stationsNow = freeroam_facilities.getFacilities("west_coast_usa").gasStations
	stationsNow[1].pumps = { { "apex_pump_area_1", "apex_pump_icon_1" }, { "apex_pump_area_2", "apex_pump_icon_2" } }
	table.insert(stationsNow, {
		id = "trilobit",
		name = "Trilobit",
		pumps = { { "tri_pump_area_1", "tri_pump_icon_1" } },
		prices = { gasoline = { priceBaseline = 1.4, priceRandomnessGain = 0.2, priceRandomnessBias = 0.5 } },
	})
	table.insert(stationsNow, {
		id = "nodeolin",
		name = "Nodeolin",
		pumps = {},
		prices = { gasoline = { priceBaseline = 1.45, priceRandomnessGain = 0.2, priceRandomnessBias = 0.5 } },
	})
	freeroam_facilities_fuelPrice.setDisplayPrices()
	local objects = {
		apex_pump_area_1 = { x = 1000, y = 0, z = 10 },
		apex_pump_area_2 = { x = 1010, y = 0, z = 10 },
		tri_pump_icon_1 = { x = 0, y = -2000, z = 20 }, -- only the icon exists
	}
	local oldTree = _G.scenetree
	_G.scenetree = {
		findObject = function(name)
			local p = objects[name]
			return p and {
				getPosition = function()
					return p
				end,
			} or nil
		end,
	}
	freeroam_facilities.getAverageDoorPositionForFacility = function()
		return { x = 300, y = 400, z = 0 }
	end
	careerConvoy_fuel.forgetPositions()
	local byId = {}
	for _, st in ipairs(careerConvoy_fuel.overview().stations) do
		byId[st.id] = st
	end
	check(byId.apex and math.abs(byId.apex.distance - 1005) < 1e-6, "issue #1: position = middle of the pumps (1005 m)")
	check(byId.trilobit and math.abs(byId.trilobit.distance - 2000) < 1e-6, "pump icon used when its area isn't there")
	check(
		byId.nodeolin and byId.nodeolin.distance == nil and byId.nodeolin.canNavigate == false,
		"no pumps found: the door point is shared by several stations, so it isn't used"
	)
	local src = careerConvoy_fuel.positionSources()
	check(src.pumps == 2 and src.doors == 0 and src.none == 1, "position sources: 2 pumps, 1 unknown")
	_G.core_groundMarkers = {
		setPath = function(pos)
			pathSet = pos
		end,
	}
	careerConvoy_fuel.uiNavigate("apex")
	check(type(pathSet) == "table" and pathSet.x == 1005 and pathSet.z == 10, "Go: route to the pumps, at their height")
	-- a believable door point of its own is still used as a fallback
	freeroam_facilities.getAverageDoorPositionForFacility = function(st)
		return st.id == "nodeolin" and { x = 0, y = 700, z = 5 } or { x = 300, y = 400, z = 0 }
	end
	careerConvoy_fuel.forgetPositions()
	byId = {}
	for _, st in ipairs(careerConvoy_fuel.overview().stations) do
		byId[st.id] = st
	end
	check(byId.nodeolin.distance == 700 and byId.apex.distance > 1000, "fallback: a station's own door point")
	-- the map origin is a placeholder, not a position
	freeroam_facilities.getAverageDoorPositionForFacility = function()
		return { x = 0, y = 0, z = 0 }
	end
	careerConvoy_fuel.forgetPositions()
	byId = {}
	for _, st in ipairs(careerConvoy_fuel.overview().stations) do
		byId[st.id] = st
	end
	check(byId.nodeolin.distance == nil, "door point at the map origin is ignored")
	_G.scenetree = oldTree
	table.remove(stationsNow)
	table.remove(stationsNow)
	stationsNow[1].pumps = nil
	freeroam_facilities.getAverageDoorPositionForFacility = realPos
	careerConvoy_fuel.forgetPositions()
end
_G.core_levels, _G.core_groundMarkers = nil, nil

-- detecting deliveries
_G.career_modules_delivery_generator = {
	getFacilityById = function(id)
		if id == "apex_fuel" then
			return { name = "levels.wcusa.gasStationPoints.apex.title" }
		end
	end,
}
local deliveredCalls = 0
_G.career_modules_delivery_progress = {
	onCargoDelivered = function(items)
		deliveredCalls = deliveredCalls + 1
	end,
}
update(1.1)
career_modules_delivery_progress.onCargoDelivered({
	{ materialType = "diesel", slots = 1500, location = { facId = "apex_fuel" } },
	{ materialType = "diesel", slots = 500, location = { facId = "apex_fuel" } },
	{ materialType = nil, slots = 1, location = { facId = "apex_fuel" } }, -- parcel
	{ materialType = "gasoline", slots = 300, location = { facId = "farm_storage" } }, -- no gas station
})
check(deliveredCalls == 1, "original game function still runs")
local fd = lastSent("sc_fuelDelivered")
check(
	fd and fd.station == "apex" and fd.fuel == "diesel" and fd.amount == 2000,
	"diesel delivery to Apex reported (summed up)"
)
local nWrap = career_modules_delivery_progress.onCargoDelivered
update(1.1)
check(career_modules_delivery_progress.onCargoDelivered == nWrap, "not wrapped twice")
-- the server switches it off -> original prices (with random part) back
handlers.sc_fuelPrices(json.encode({ enabled = false, factors = {} }))
update()
local g = fp.getFuelPrice("apex", "gasoline")
check(
	g >= 1.4
		and g <= 1.6
		and freeroam_facilities.getFacilities().gasStations[1].prices.gasoline.priceRandomnessGain == 0.2,
	"switched off: game prices as before"
)

-- the game only returns copies of the data -> fallback via getFuelPrice
setupFuelWorld(true)
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
update()
handlers.sc_fuelPrices(json.encode({ enabled = true, factors = { apex = { diesel = 0.8 } } }))
update()
check(
	math.abs(freeroam_facilities_fuelPrice.getFuelPrice("apex", "diesel") - 1.28) < 1e-9,
	"fallback: refueling at the right price"
)
_G.freeroam_facilities, _G.freeroam_facilities_fuelPrice = nil, nil
_G.career_modules_delivery_progress, _G.career_modules_delivery_generator = nil, nil

--== 7i. Welcome dialog ======================================================
local function welcomeJoin(stateFile, cfgChange)
	resetWorld()
	installCareer()
	local wfiles = { ["settings/careerConvoy/state.json"] = stateFile }
	_G.jsonReadFile = function(path)
		return wfiles[path] and json.decode(json.encode(wfiles[path])) or nil
	end
	_G.jsonWriteFile = function(path, data)
		wfiles[path] = json.decode(json.encode(data))
		return true
	end
	_G.FS = {
		fileExists = function()
			return false
		end,
		findFiles = function()
			return {}
		end,
	}
	local dialogs = {}
	-- the dialog comes via the UI (guihook "CareerConvoyDialog"); BeamMP's dialog must never be used
	_G.MPGameNetwork = {
		spawnUiDialog = function()
			error("BeamMP dialog must not be used")
		end,
	}
	_G.guihooks = {
		trigger = function(name, data)
			if name == "CareerConvoyDialog" then
				table.insert(dialogs, data)
			end
		end,
	}
	local c = {}
	for k, v in pairs(config) do
		c[k] = v
	end
	for k, v in pairs(cfgChange or {}) do
		c[k] = v
	end
	extensions.hook("onWorldReadyState", 2)
	handlers.sc_config(json.encode(c))
	update()
	return dialogs, wfiles
end
local navigated = {}
_G.ui_router = {
	navigate = function(r)
		table.insert(navigated, r)
	end,
	getCurrentRoute = function()
		return { name = "menu" }
	end,
}
local dialogs, wfiles = welcomeJoin(nil)
check(#dialogs == 0, "dialog not immediately (only after loading)")
for _ = 1, 50 do
	update(0.1)
end
check(#dialogs == 1 and dialogs[1].title == "Welcome to Career-Convoy", "welcome dialog after a few seconds")
check(#navigated == 1 and navigated[1] == "play", "main menu after the career start -> back into the game")
_G.ui_router.getCurrentRoute = function()
	return "play"
end
navigated = {}
check(careerConvoy_welcome.ensurePlayScreen() == false and #navigated == 0, "already in the game: don't switch")
_G.ui_router = nil
check(
	dialogs[1].buttons[1].action == "never" and dialogs[1].buttons[1].label == "Don't show again",
	"button 'Don't show again'"
)
local allText = ""
for _, it in ipairs(dialogs[1].items) do
	allText = allText .. it.head .. " " .. it.text .. " "
end
check(allText:find("F7") and allText:find("F4") and allText:find("/pay"), "lists the most important features")
for _ = 1, 50 do
	update(0.1)
end
check(#dialogs == 1, "only once per join")
-- Regression 0.8.2: the window was hidden (main menu) and rebuilds itself -> dialog back
careerConvoy_welcome.uiRequestDialog()
check(#dialogs == 2 and dialogs[2].title == "Welcome to Career-Convoy", "rebuilt window gets the open dialog")
-- player clicks "Don't show again" in the window
careerConvoy_welcome.uiDialogButton("welcome", "never")
check(wfiles["settings/careerConvoy/state.json"].welcomeHidden == true, "choice is saved")
careerConvoy_welcome.uiRequestDialog()
check(#dialogs == 2, "no open dialog after a button press")
-- next join: no dialog any more
dialogs = welcomeJoin({ welcomeHidden = true })
for _ = 1, 60 do
	update(0.1)
end
check(#dialogs == 0, "no dialog after 'Don't show again'")
careerConvoy_welcome.show(true)
check(#dialogs == 1, "click on the logo shows it anyway")
-- Regression 0.8.0: loading screen still open -> dialog only once it is gone
resetWorld()
installCareer({ trafficHang = true })
local hangDialogs = {}
_G.jsonReadFile = function()
	return nil
end
_G.jsonWriteFile = function()
	return true
end
_G.FS = {
	fileExists = function()
		return false
	end,
	findFiles = function()
		return {}
	end,
}
_G.guihooks = {
	trigger = function(name, data)
		if name == "CareerConvoyDialog" then
			table.insert(hangDialogs, data)
		end
	end,
}
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
for _ = 1, 300 do
	update(0.1)
end -- 30 s: loading screen "careerVehicles" still hangs
check(#hangDialogs == 0, "no dialog while the loading screen is open")
for _ = 1, 400 do
	update(0.1)
end -- the mod releases the loading screen after 60 s, then +3 s
check(#hangDialogs == 1, "dialog after the loading screen")
-- the server switches it off
dialogs = welcomeJoin(nil, { showWelcome = false })
for _ = 1, 60 do
	update(0.1)
end
check(#dialogs == 0, "showWelcome = false: no dialog")
-- message from the server (e.g. guest notice) appears as a dialog in the window
handlers.sc_dialog(
	json.encode({ title = "Career-Convoy: you are playing as a guest", body = "Your progress...", warning = false })
)
check(
	#dialogs == 1
		and dialogs[1].kind == "server"
		and dialogs[1].title:find("guest")
		and dialogs[1].buttons[1].label == "OK",
	"server message as a dialog in the window"
)
_G.MPGameNetwork = nil

--== 7j. Other players' vehicles survive a pause and invalid sync values ==========
(function()
	local calls = {}
	local speed = 1
	_G.positionVE = {
		setGameSpeed = function(v)
			speed = v
		end,
		updateGFX = function(dt)
			table.insert(calls, "gfx " .. dt .. " at speed " .. speed)
		end,
		onPhysicsStep = function(dt)
			table.insert(calls, "phys")
		end,
		getVehicleRotation = function()
			table.insert(calls, "send at speed " .. speed)
		end,
		onReset = function()
			table.insert(calls, "reset")
		end,
	}
	local refreshed = {}
	local savedExt = _G.extensions
	_G.extensions = {
		hookUpdate = function(name)
			refreshed[name] = true
		end,
	}
	local guard = assert(loadfile("client/lua/vehicle/extensions/auto/careerConvoySyncGuard.lua"))()
	guard.onExtensionLoaded()
	check(refreshed.updateGFX and refreshed.onPhysicsStep, "hook lists refreshed after wrapping")
	positionVE.updateGFX(0.016)
	check(calls[#calls] == "gfx 0.016 at speed 1", "running: positionVE works as before")
	calls = {}
	positionVE.setGameSpeed(0)
	check(speed == 1 and calls[1] == "reset", "paused: positionVE never gets a speed of 0, prediction starts fresh")
	positionVE.updateGFX(0.016)
	positionVE.onPhysicsStep(0.0005)
	check(#calls == 1, "paused: no prediction and no physics step")
	positionVE.getVehicleRotation()
	check(calls[2] == "send at speed 0" and speed == 1, "paused: own vehicle reports standing still")
	positionVE.setGameSpeed(0 / 0)
	check(speed == 1, "an invalid speed is never passed on")
	calls = {}
	positionVE.setGameSpeed(0.5)
	check(speed == 0.5 and calls[1] == "reset", "resumed (slow motion): real speed, prediction starts fresh")
	positionVE.updateGFX(0)
	check(#calls == 1, "a frame without time is skipped")
	positionVE.updateGFX(0.016)
	check(calls[2] == "gfx 0.016 at speed 0.5", "resumed: positionVE works again")
	local wrapped = positionVE.updateGFX
	guard.updateGFX(0.016)
	check(positionVE.updateGFX == wrapped, "installed only once")
	-- velocityVE: corrections with invalid values never reach the physics
	local applied = {}
	_G.velocityVE = {}
	for _, name in ipairs({ "addVelocity", "setVelocity", "addAngularVelocity", "setAngularVelocity" }) do
		velocityVE[name] = function(...)
			table.insert(applied, { name, ... })
		end
	end
	local logged = {}
	local savedLog = _G.log
	_G.log = function(_, tag, msg)
		table.insert(logged, tag .. ": " .. msg)
	end
	guard.updateGFX(0.016)
	velocityVE.addAngularVelocity(1, 2, 3, 0.1, 0.2, 0.3)
	velocityVE.setAngularVelocity(1, 2, 3, 0.1, 0.2, 0.3, 1, 0)
	check(#applied == 2, "valid corrections pass")
	applied = {}
	local nan, inf = 0 / 0, math.huge
	velocityVE.setAngularVelocity(nan, nan, nan, 0.03, 0.05, 0.08, 1, 0)
	velocityVE.addVelocity(1, -inf, 0)
	velocityVE.setVelocity(1, 2, inf)
	velocityVE.addAngularVelocity(1, 2, 3, nan, 0, 0)
	check(#applied == 0, "corrections with NaN or infinite values are dropped")
	guard.updateGFX(1.1)
	check(#logged == 1 and logged[1]:find("dropped 4"), "dropped corrections are logged once: " .. tostring(logged[1]))
	guard.updateGFX(1.1)
	check(#logged == 1, "nothing dropped: no log line")
	local wrappedVel = velocityVE.addVelocity
	guard.updateGFX(0.016)
	check(velocityVE.addVelocity == wrappedVel, "velocity guard installed only once")
	_G.log = savedLog
	_G.positionVE, _G.velocityVE, _G.extensions = nil, nil, savedExt
	local ok = pcall(guard.updateGFX, 0.016)
	check(ok, "without BeamMP: nothing happens")
end)();

--== 7j2. Physics glitches: invalid placements blocked, a glitch is shown ==========
(function()
	resetWorld()
	installCareer()
	extensions.hook("onWorldReadyState", 2)
	handlers.sc_config(json.encode(config))
	local function vec(x, y, z)
		return { x = x, y = y, z = z }
	end
	local function place(v, speed)
		v.getDirectionVector = function()
			return vec(0, 1, 0)
		end
		v.getDirectionVectorUp = function()
			return vec(0, 0, 1)
		end
		v.getVelocity = function()
			return vec(speed or 0, 0, 0)
		end
	end
	addVehicle(70, "0-1", true, "hopper")
	local parked = addVehicle(71, "0-2", true, "simple_traffic")
	parked.isParked = "true"
	local theirs = addVehicle(80, "1-1", false, "simple_traffic")
	place(theirs)
	world.mp["1-1"].ownerName = "Borian"
	world.playerVeh = 70
	local mine = world.objects[#world.objects - 2]
	place(mine, 5)
	mine.getPosition = function()
		return vec(0, 0, 0)
	end
	theirs.getPosition = function()
		return vec(3, 4, 0)
	end
	update(1.1)
	extensions.hook("onVehicleResetted", 70)
	clock = clock + 0.4
	-- a glitch: your car, your parked car and Borian's car at once
	toasts = {}
	local beammp = { instabilityHandled = true } -- BeamMP handles it; Career-Convoy leaves it so
	extensions.hook("onInstabilityDetected", 80, {})
	extensions.hook("onInstabilityDetected", 70, beammp)
	extensions.hook("onInstabilityDetected", 70, {})
	extensions.hook("onInstabilityDetected", 71, {})
	check(beammp.instabilityHandled == true, "BeamMP's handling is left as it is")
	check(#toasts == 0, "no toast before the glitch is over")
	clock = clock + 0.6
	update(0.1)
	check(
		#toasts == 1 and toasts[1].msg == "Physics glitch (also Borian)",
		"one toast per glitch: " .. tostring(toasts[1] and toasts[1].msg)
	)
	local glitch = lastSent("sc_glitch")
	local car
	for _, c in ipairs(glitch and glitch.mine or {}) do
		if c.model == "hopper" then
			car = c
		end
	end
	check(
		glitch and #glitch.mine == 2 and glitch.total == 3 and glitch.others[1] == "Borian",
		"the glitch goes to the server: your two vehicles, Borian named"
	)
	check(
		car
			and car.kind == "player"
			and car.speed == 18
			and car.reset == 0.4
			and car.near == 5
			and car.nearOwner == "Borian"
			and car.nearHidden == false
			and car.coupled == false,
		"with what happened just before: speed, reset, nearest other player: " .. json.encode(car or {})
	)
	-- only traffic and other players' cars hit: no toast
	toasts = {}
	world.playerVeh = nil
	clock = clock + 5
	extensions.hook("onInstabilityDetected", 80, {})
	extensions.hook("onInstabilityDetected", 71, {})
	clock = clock + 0.6
	update(0.1)
	check(#toasts == 0, "only traffic and other players' cars: no toast")
	check(lastSent("sc_glitch").mine[1].kind == "parked", "your parked car's glitch is reported as parked")

	-- BeamMP sets another player's car in place: only with valid values
	local placed = {}
	_G.positionGE = {
		setPositionRotationVelocity = function(id, d)
			table.insert(placed, id)
		end,
	}
	update(1.1)
	local function data(changes)
		local d = {
			pos = vec(1, 2, 3),
			vel = vec(4, 0, 0),
			rvel = vec(0, 0, 0.1),
			vehVel = vec(4, 0, 0),
			rot = { x = 0, y = 0, z = 0, w = 1 },
		}
		for k, v in pairs(changes or {}) do
			d[k] = v
		end
		return d
	end
	positionGE.setPositionRotationVelocity(80, data())
	check(#placed == 1, "a valid placement passes")
	positionGE.setPositionRotationVelocity(80, data({ vel = vec(0 / 0, 0, 0) }))
	positionGE.setPositionRotationVelocity(80, data({ rot = { x = 0, y = 0, z = 0, w = 0 } }))
	place(theirs, math.huge)
	positionGE.setPositionRotationVelocity(80, data())
	check(#placed == 1, "invalid values, a broken rotation or an already broken car: dropped")
	local logged = {}
	local realLog = careerConvoy_util.log
	careerConvoy_util.log = function(_, tag, msg)
		table.insert(logged, msg)
	end
	clock = clock + 11
	update(1.1)
	careerConvoy_util.log = realLog
	check(
		logged[1] and logged[1]:find("blocked 3 placement") and logged[1]:find("Borian"),
		"dropped placements logged: " .. tostring(logged[1])
	)
	_G.positionGE = nil
	extensions.hook("onBeamMPServerLeave")
end)();

--== 7j3. Parked cars and far traffic send their position less often ============
(function()
	resetWorld()
	installCareer()
	extensions.hook("onWorldReadyState", 2)
	handlers.sc_config(json.encode(config))
	local function at(v, x, speed)
		v.getPosition = function()
			return { x = x, y = 0, z = 0 }
		end
		v.getVelocity = function()
			return { x = speed or 0, y = 0, z = 0 }
		end
	end
	local mine = addVehicle(90, "0-1", true, "hopper")
	at(mine, 0, 20)
	local parked = addVehicle(91, "0-2", true, "simple_traffic")
	parked.isParked = "true"
	at(parked, 10)
	local nearTraffic = addVehicle(92, "0-3", true, "simple_traffic")
	nearTraffic.isTraffic = "true"
	at(nearTraffic, 100, 15)
	local farTraffic = addVehicle(93, "0-4", true, "simple_traffic")
	farTraffic.isTraffic = "true"
	at(farTraffic, 2000, 15)
	local hidden = addVehicle(94, "0-5", true, "simple_traffic")
	hidden.isTraffic = "true"
	hidden.active = false
	at(hidden, 3000)
	local theirs = addVehicle(95, "1-1", false, "pickup")
	at(theirs, 150)
	world.playerVeh = 90
	local sent = {}
	_G.positionGE = {
		sendVehiclePosRot = function(data, id)
			sent[id] = (sent[id] or 0) + 1
		end,
	}
	update(1.1)
	-- BeamMP asks every car 50 times a second for 2 seconds
	for _ = 1, 100 do
		clock = clock + 0.02
		for _, id in ipairs({ 90, 91, 92, 93, 94 }) do
			positionGE.sendVehiclePosRot("{}", id)
		end
	end
	check(sent[90] == 100, "the car you drive sends every position")
	check(sent[92] == 100, "traffic near another player sends every position")
	check(sent[91] and sent[91] <= 3, "a still parked car: about once a second (" .. tostring(sent[91]) .. ")")
	check(sent[93] and sent[93] >= 3 and sent[93] <= 5, "far traffic: twice a second (" .. tostring(sent[93]) .. ")")
	check(sent[94] == nil, "a hidden car sends no position")
	-- a parked car that is hit sends every position at once
	at(parked, 10, 3)
	update(0.3)
	sent[91] = 0
	for _ = 1, 10 do
		clock = clock + 0.02
		positionGE.sendVehiclePosRot("{}", 91)
	end
	check(sent[91] == 10, "a parked car that moves sends every position")
	-- a hidden car shown again sends at once
	hidden.active = true
	update(0.3)
	sent[94] = 0
	positionGE.sendVehiclePosRot("{}", 94)
	check(sent[94] == 1, "a hidden car shown again sends at once")
	_G.positionGE = nil
	extensions.hook("onBeamMPServerLeave")
end)();

--== 7k. Trailers stay coupled on every PC =====================================
(function()
	resetWorld()
	installCareer()
	extensions.hook("onWorldReadyState", 2)
	handlers.sc_config(json.encode(config))
	local function at(v, x)
		v.getPosition = function()
			return { x = x, y = 0, z = 0 }
		end
	end
	local truck = addVehicle(50, "0-1", true)
	at(truck, 0)
	local trailer = addVehicle(51, "0-2", true)
	at(trailer, 5)
	local theirTruck = addVehicle(60, "1-1", false)
	at(theirTruck, 100)
	local theirTrailer = addVehicle(61, "1-2", false)
	at(theirTrailer, 105)
	local function hasCmd(v, pattern)
		for _, cmd in ipairs(v.lua) do
			if cmd:find(pattern) then
				return true
			end
		end
		return false
	end
	local function wait(seconds)
		for _ = 1, math.ceil(seconds / 1.1) do
			update(1.1)
		end
	end

	-- own coupling: reported at once, with server ids and node ids
	extensions.hook("onCouplerAttached", 50, 51, 7, 3)
	update(1.1)
	local msg = lastSent("sc_couplings")
	check(
		msg
			and #msg.list == 1
			and msg.list[1].a == "0-1"
			and msg.list[1].an == 7
			and msg.list[1].b == "0-2"
			and msg.list[1].bn == 3,
		"own coupling reported (server ids, node ids)"
	)
	sentToServer = {}
	update(1.1)
	check(lastSent("sc_couplings") == nil, "unchanged: not sent again right away")
	extensions.hook("onCouplerDetached", 50, 51, 7, 3)
	update(1.1)
	msg = lastSent("sc_couplings")
	check(msg and #msg.list == 0, "own decoupling reported")

	-- another player's coupling that is missing here: tried from one side, then the other
	handlers.sc_couplings(json.encode({ pid = 1, list = { { a = "1-2", an = 3, b = "1-1", bn = 7 } } }))
	update(1.1)
	check(
		hasCmd(theirTruck, "toggleCouplerState%(.*_nodetag..:7") and hasCmd(theirTruck, "state..:true"),
		"missing coupling: coupled with BeamMP's coupling, first side"
	)
	wait(2.2)
	check(hasCmd(theirTrailer, "toggleCouplerState%(.*_nodetag..:3"), "still missing: tried from the other side")
	theirTruck.lua, theirTrailer.lua = {}, {}
	extensions.hook("onCouplerAttached", 61, 60, 3, 7) -- it holds (seen from the other side)
	wait(3.3)
	check(
		not hasCmd(theirTruck, "toggleCouplerState") and not hasCmd(theirTrailer, "toggleCouplerState"),
		"coupled here: no more tries"
	)
	-- the owner no longer reports it: undone
	handlers.sc_couplings(json.encode({ pid = 1, list = {} }))
	update(1.1)
	check(hasCmd(theirTruck, "state..:false"), "the owner decoupled: undone here")
	-- coupled here just now, before the owner's report arrived: not undone at once
	extensions.hook("onCouplerDetached", 60, 61, 7, 3)
	theirTruck.lua = {}
	extensions.hook("onCouplerAttached", 60, 61, 7, 3)
	update(1.1)
	check(not hasCmd(theirTruck, "state..:false"), "just coupled here: time for the owner's report")
	wait(4.4)
	check(hasCmd(theirTruck, "state..:false"), "still no owner reports it: undone")
	-- too far apart: no try
	theirTruck.lua = {}
	extensions.hook("onCouplerDetached", 60, 61, 7, 3)
	at(theirTrailer, 200)
	handlers.sc_couplings(json.encode({ pid = 1, list = { { a = "1-1", an = 7, b = "1-2", bn = 3 } } }))
	wait(3.3)
	check(
		not hasCmd(theirTruck, "toggleCouplerState") and not hasCmd(theirTrailer, "state..:true"),
		"vehicles far apart: no try"
	)
	-- a reset forgets the vehicle's couplings, so they are tried again
	at(theirTrailer, 105)
	extensions.hook("onCouplerAttached", 60, 61, 7, 3)
	extensions.hook("onVehicleResetted", 61)
	theirTruck.lua, theirTrailer.lua = {}, {}
	wait(3.3)
	check(hasCmd(theirTruck, "state..:true") or hasCmd(theirTrailer, "state..:true"), "after a reset: coupled again")
	-- couplings with one of our own vehicles are left to our physics
	theirTruck.lua = {}
	handlers.sc_couplings(json.encode({ pid = 1, list = { { a = "1-1", an = 7, b = "0-2", bn = 3 } } }))
	wait(3.3)
	check(not hasCmd(theirTruck, "toggleCouplerState%(.*_nodetag..:7.*true"), "coupling to an own vehicle: left alone")
end)()

--== 8. Money ===================================================================
resetWorld()
installCareer({ money = 1000 })
extensions.hook("onWorldReadyState", 2)
handlers.sc_config(json.encode(config))
handlers.sc_payDebit(json.encode({ id = "a", amount = 5000, to = "Ben" }))
check(
	lastSent("sc_payDebitResult").ok == false and career_modules_playerAttributes.money() == 1000,
	"not enough money -> nothing debited"
)
handlers.sc_payDebit(json.encode({ id = "b", amount = 300, to = "Ben" }))
check(lastSent("sc_payDebitResult").ok == true and career_modules_playerAttributes.money() == 700, "abgebucht")
check((world.saved or 0) >= 1, "saved after debit")
handlers.sc_payDebit(json.encode({ id = "b", amount = 300, to = "Ben" }))
check(career_modules_playerAttributes.money() == 700, "duplicate message doesn't debit twice")
handlers.sc_payCredit(json.encode({ id = "c", amount = 50, from = "Ben" }))
handlers.sc_payCredit(json.encode({ id = "c", amount = 50, from = "Ben" }))
check(career_modules_playerAttributes.money() == 750, "credit exactly once")
check(lastSent("sc_payCreditAck").id == "c", "credit confirmed")
handlers.sc_payDebit(json.encode({ id = "d", amount = -100, to = "Ben" }))
check(
	lastSent("sc_payDebitResult").ok == false and career_modules_playerAttributes.money() == 750,
	"negative amount rejected"
)

--== 9. Leaving the server resets everything ====================================
extensions.hook("onBeamMPServerLeave")
check(careerConvoy_core.getConfig() == nil and not careerConvoy_core.isStarted(), "state reset")
check(
	settings.getValue("trafficSimpleVehicles") == false
		and settings.getValue("simplifyRemoteVehicles") == false
		and settings.getValue("trafficAllowMods") == true,
	"the player's own settings restored"
);

--== 10. Jobs: towing jobs, and a job type of the tests =======================
-- (in a function of its own: the main chunk is at Lua's limit of 200 local variables)
(function()
	resetWorld()
	installCareer({ money = 1000 })
	extensions.hook("onWorldReadyState", 2)
	local cfgJ = json.decode(json.encode(config))
	cfgJ.ui, cfgJ.jobPay, cfgJ.phone = { jobs = true }, 1, true
	handlers.sc_config(json.encode(cfgJ))
	update()
	_G.vec3 = function(x, y, z)
		return { x = x, y = y, z = z }
	end
	_G.quatFromDir = function(d, up)
		world.spawnedUp = up
		return { dir = d, up = up }
	end
	_G.getCurrentLevelIdentifier = function()
		return "west_coast_usa"
	end
	-- the world: flat ground at z = 10; walls along the road, by side (y = +1 / -1): their distance
	-- from the middle of the road
	local walls = {}
	_G.castRayStatic = function(from, dir, range)
		if dir.z < 0 then
			return from.z - 10
		end
		local wall = dir.y ~= 0 and walls[dir.y > 0 and 1 or -1]
		return wall and math.min(range, wall - math.abs(from.y)) or range
	end
	local paths = {}
	_G.core_groundMarkers = {
		setPath = function(p)
			table.insert(paths, p or false)
		end,
	}
	-- a straight road along x (nodes every 100 m, 4 m half width, speed limit 20 m/s) and a dirt track
	-- that may not be used
	local nodes = {}
	for i = 0, 50 do
		nodes["n" .. i] = { pos = vec3(i * 100, 0, 10), radius = 4, links = {} }
	end
	for i = 0, 49 do
		nodes["n" .. i].links["n" .. (i + 1)] = { drivability = 1, speedLimit = 20 }
		nodes["n" .. (i + 1)].links["n" .. i] = { drivability = 1, speedLimit = 20 }
	end
	nodes.dirt = { pos = vec3(0, 3000, 10), radius = 4, links = { dirt2 = { drivability = 0.2 } } }
	nodes.dirt2 = { pos = vec3(100, 3000, 10), radius = 4, links = { dirt = { drivability = 0.2 } } }
	-- the way by road: from the node of the straight road nearest to the start to the one nearest
	-- to the target, along it
	local pathSearches = 0
	local function nearestNode(p)
		return math.max(0, math.min(50, math.floor(p.x / 100 + 0.5)))
	end
	_G.map = {
		getMap = function()
			return { nodes = nodes }
		end,
		getPointToPointPath = function(a, b)
			pathSearches = pathSearches + 1
			local ia, ib = nearestNode(a), nearestNode(b)
			local path = {}
			for i = ia, ib, ia <= ib and 1 or -1 do
				table.insert(path, "n" .. i)
			end
			return path
		end,
		findClosestRoad = function(p)
			local i = math.max(0, math.min(49, math.floor(p.x / 100)))
			return "n" .. i, "n" .. (i + 1), math.abs(p.y)
		end,
		getPathLen = function(path)
			local len = 0
			for i = 2, #path do
				len = len + math.abs(nodes[path[i]].pos.x - nodes[path[i - 1]].pos.x)
			end
			return len
		end,
	}
	local doors = { belasco = { x = 4000, y = 50, z = 10 }, home = { x = 0, y = 40, z = 10 } }
	_G.freeroam_facilities = {
		getFacilities = function()
			return {
				garages = { { id = "belasco", name = "Belasco Auto" }, { id = "home", name = "Home Garage" } },
				gasStations = {},
			}
		end,
		getAverageDoorPositionForFacility = function(f)
			return doors[f.id]
		end,
	}
	_G.jsonReadFile = function(path)
		if path:find("deliveryVehicles") then
			return { junkerVehFilter = { filter = {} } }
		end
	end
	_G.util_configListGenerator = {
		getEligibleVehicles = function()
			return {}
		end,
		getRandomVehicleInfos = function()
			-- every second draw an old pickup while world.junkerTrucks is on
			world.draws = (world.draws or 0) + 1
			if world.junkerTrucks and world.draws % 2 == 0 then
				return {
					{
						model_key = "pickup",
						key = "old",
						Brand = "Gavril",
						Name = "D-Series",
						["Body Style"] = "Pickup",
						Type = "Truck",
					},
				}
			end
			return { { model_key = "fullsize", key = "base", Brand = "Gavril", Name = "Grand Marshal" } }
		end,
	}
	local me = addVehicle(70, "0-70", true)
	me.p = { x = 0, y = -20, z = 10 }
	function me:getPosition()
		return self.p
	end
	world.playerVeh = 70
	local spawnedVeh
	core_vehicles.spawnNewVehicle = function(model, opt)
		spawnedVeh = addVehicle(80, "0-80", true, model)
		spawnedVeh.p = { x = opt.pos.x, y = opt.pos.y, z = opt.pos.z }
		spawnedVeh.v = { x = 0, y = 0, z = 0 }
		function spawnedVeh:getPosition()
			return self.p
		end
		function spawnedVeh:getVelocity()
			return self.v
		end
		world.spawned = { model, opt }
		return spawnedVeh
	end
	local function lastCmd(v)
		return v.lua[#v.lua] or ""
	end
	local function lastToastMsg()
		for i = #toasts, 1, -1 do
			if toasts[i].msg then
				return toasts[i].msg
			end
		end
		return ""
	end
	local jobs, tow = careerConvoy_jobs, careerConvoy_towJobs

	-- making up a job: on a normal road, off the road, far from every vehicle, a shop 0.8-6 km away
	check(
		tow.payFor(1000, false) == 270 and tow.payFor(1000, true) == 340,
		"pay: $150 + $120 per km, a flat tire pays 25 % more"
	)
	handlers.sc_jobGenerate(json.encode({ type = "tow" }))
	check(lastSent("sc_jobOffer") == nil, "before the server's job list (jobs on?) no job is made up")
	handlers.sc_jobs(json.encode({ enabled = true, jobs = {} }))
	handlers.sc_jobGenerate(json.encode({ type = "tow" }))
	local offer = lastSent("sc_jobOffer")
	check(
		offer
			and offer.type == "tow"
			and offer.title == "Gavril Grand Marshal"
			and offer.data.vehicle.model == "fullsize"
			and offer.data.vehicle.config == "base",
		"made up a towing job with an old car from the career's delivery filter"
	)
	world.junkerTrucks = true
	local trucks = { 0, 0 }
	for tier = 1, 2 do
		for _ = 1, 200 do
			if tow.generate(tier).data.vehicle.model == "pickup" then
				trucks[tier] = trucks[tier] + 1
			end
		end
	end
	world.junkerTrucks = false
	check(
		trucks[1] == 0 and trucks[2] > 3 and trucks[2] < 60,
		"trucks from the delivery filter: never in tier 1, now and then in tier 2 (" .. table.concat(trucks, "/") .. ")"
	)
	local styles =
		{ fullsize = { model = { Name = "Grand Marshal" }, configs = { base = { ["Body Style"] = "Sedan" } } } }
	core_vehicles.getModel = function(model)
		return styles[model]
	end
	local styled = tow.generate(1).title
	styles.fullsize.model["Body Style"] = "Full-size"
	local fromModel = tow.generate(1).title
	core_vehicles.getModel = nil
	check(
		styled == "Sedan" and fromModel == "Full-size",
		"the job's title: the body style of the model, else of its config"
	)
	-- the kind of vehicle (the job's icon): from the body style, else the type; a car if nothing fits
	world.junkerTrucks = true
	local kinds = {}
	for _ = 1, 400 do
		local d = tow.generate(3).data
		kinds[d.vehicle.model .. ":" .. tostring(d.kind)] = true
	end
	world.junkerTrucks = false
	check(
		kinds["fullsize:car"]
			and kinds["pickup:pickup"]
			and kinds["van:van"]
			and kinds["roamer:suv"]
			and not kinds["fullsize:nil"],
		"each job knows its kind of vehicle: car, pickup, van, suv"
	)
	core_vehicles.getModel = function(model)
		local types = {
			bus = { ["Body Style"] = "Bus", Type = "Truck" },
			semi = { ["Body Style"] = "Semi Truck", Type = "Truck" },
			mini = { ["Body Style"] = "Minivan", Type = "Car" },
			cross = { ["Body Style"] = "Crossover" },
			pick = { ["Body Style"] = "Pickup", Type = "Truck" },
			boxy = { Type = "Truck" },
			coupe = { ["Body Style"] = "Coupe", Type = "Car" },
		}
		return types[model] and { model = types[model] }
	end
	local iconOk = true
	for model, want in pairs({
		bus = "bus",
		semi = "truck",
		mini = "van",
		cross = "suv",
		pick = "pickup",
		boxy = "truck",
		coupe = "car",
	}) do
		local icon = tow.iconOf({ data = { kind = tow.vehicleKind(model) } })
		if icon ~= want then
			iconOk = false
			print("  " .. model .. ": " .. tostring(icon))
		end
	end
	core_vehicles.getModel = nil
	check(
		iconOk and tow.iconOf({ data = {} }) == nil and tow.iconOf({ data = { kind = "boat" } }) == nil,
		"the icons by kind: bus, truck, van, suv, pickup, car; none for an unknown kind"
	)
	check(offer.tier == 1, "the server asked for no tier: tier 1")
	local okAll, lengthOk = true, true
	for i = 1, 80 do
		local tier = (i - 1) % 4 + 1
		local job = tow.generate(tier)
		local destDist = math.sqrt((job.dest.pos.x - job.pos.x) ^ 2 + (job.dest.pos.y - job.pos.y) ^ 2)
		if
			math.abs(math.abs(job.pos.y) - 5.8) > 1e-6
			or job.pos.x < 350
			or destDist < 400
			or job.pay ~= tow.payFor(job.length, job.data.flatTire, tier)
		then
			okAll = false
		end
		local road = jobs.driveDistance(job.pos, job.dest.pos)
		if not road or job.length ~= math.floor(road / 10 + 0.5) * 10 then
			lengthOk = false
		end
	end
	check(
		okAll,
		"places: always beside the road (5.8 m from its middle), never near a vehicle or on a dirt track; a shop away from it"
	)
	check(lengthOk, "the length of the tow: the way by road to the shop")
	-- a tunnel: a wall right of the road (as you drive along x): the car stands on the left, facing
	-- the other way; walls on both sides: no place there; no ground beside the road: none either
	walls[-1] = 6
	local leftOk = true
	for _ = 1, 20 do
		local job = tow.generate(1)
		if not (job and job.pos.y == 5.8 and job.pos.z == 10 and job.data.dir.x == -1) then
			leftOk = false
		end
	end
	check(leftOk, "a wall on the right: the car stands on the left side, facing the other way")
	walls[1] = 6
	local none, why = tow.generate(1)
	check(none == nil and why == "no free place found", "walls on both sides (a tunnel): no place there")
	walls = {}
	local cast = _G.castRayStatic
	_G.castRayStatic = function(from, dir, range)
		return dir.z < 0 and range or cast(from, dir, range)
	end
	check(tow.generate(1) == nil, "no ground beside the road: no place there")
	_G.castRayStatic = cast
	local getPath = map.getPointToPointPath
	map.getPointToPointPath = function()
		return {}
	end
	local noWay = tow.generate(1)
	map.getPointToPointPath = getPath
	local straight = math.sqrt((noWay.dest.pos.x - noWay.pos.x) ^ 2 + (noWay.dest.pos.y - noWay.pos.y) ^ 2)
	check(noWay.length == math.floor(straight * 1.3 / 10 + 0.5) * 10, "no way by road: the straight line x 1.3")
	local crashes, flats, heavies = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }
	local speedsOk = true
	for tier = 1, 4 do
		for _ = 1, 100 do
			local d = tow.generate(tier).data
			local c = d.crash
			if d.flatTire then
				flats[tier] = flats[tier] + 1
			end
			if d.heavy then
				heavies[tier] = heavies[tier] + 1
			end
			if c then
				crashes[tier] = crashes[tier] + 1
				if c.speed < 2.5 or c.speed > 14 then
					speedsOk = false
				end
			end
		end
	end
	check(
		crashes[1] == 0 and crashes[2] > 10 and crashes[2] < 50 and crashes[4] > 50 and speedsOk,
		"crashes: never in tier 1, sometimes in tier 2, mostly in tier 4 (" .. table.concat(crashes, "/") .. ")"
	)
	check(
		heavies[1] == 0
			and heavies[2] == 0
			and heavies[3] > 30
			and heavies[3] < 70
			and heavies[4] > 50
			and heavies[4] < 90,
		"heavy vehicles: none in tiers 1-2, often in tier 3, mostly but not always in tier 4 ("
			.. table.concat(heavies, "/")
			.. ")"
	)
	check(
		flats[1] < 25 and flats[4] > 30 and flats[4] < 70 and flats[1] < flats[4],
		"flat tires: rare in tier 1, often in tier 4, not always (" .. table.concat(flats, "/") .. ")"
	)
	local crashJob = { data = { crash = { kind = "roof", speed = 5 }, flatTire = true } }
	check(
		tow.tags(crashJob)[1].text == "On its roof"
			and tow.tags({ data = { crash = { kind = "front", speed = 9 } } })[1].text == "Crash"
			and tow.tags(crashJob)[2].text == "Flat tire",
		'a crash shows as "Crash" or "On its roof" instead of the engine failure'
	)
	local faultsOk, crashEngineOk, seen = true, true, {}
	for tier = 1, 4 do
		for _ = 1, 100 do
			local d = tow.generate(tier).data
			if type(d.faults) ~= "table" or #d.faults == 0 then
				faultsOk = false
			end
			if d.crash and not (#d.faults == 1 and d.faults[1] == "engine") then
				crashEngineOk = false
			end
			for _, f in ipairs(d.faults or {}) do
				seen[f] = true
			end
		end
	end
	check(
		faultsOk
			and seen.engine
			and seen.clutch
			and seen.gearbox
			and seen.radiator
			and seen.oilpan
			and seen.windshield
			and seen.taillights,
		"faults: always at least one; every kind comes up"
	)
	check(crashEngineOk, "a crash always has a broken engine, nothing else")
	local tags = tow.tags({ data = { faults = { "windshield", "taillights" }, heavy = true } })
	check(
		#tags == 3
			and tags[1].text == "Broken windshield"
			and tags[2].text == "Broken taillights"
			and tags[3].text == "Heavy",
		"each fault shows as its own tag, in order"
	)
	check(#tow.tags({ data = { faults = { "engine", "nonsense" } } }) == 1, "an unknown fault shows no tag")
	tags = tow.tags({ data = { faults = { "clutch", "gearbox", "radiator", "oilpan" } } })
	check(
		#tags == 4
			and tags[1].text == "Broken clutch"
			and tags[2].text == "Broken gearbox"
			and tags[3].text == "Broken radiator"
			and tags[4].text == "Oil leak"
			and tags[4].kind == "oilpan",
		"clutch, gearbox, radiator and oil pan show as tags"
	)
	check(
		tow.payFor(1000, false, 2) == 350 and tow.payFor(1000, false, 4) == 590,
		"a higher tier pays more (x1.3, x2.2)"
	)
	handlers.sc_jobGenerate(json.encode({ type = "tow", tier = 3 }))
	offer = lastSent("sc_jobOffer")
	check(offer.type == "tow" and offer.tier == 3, "the server asks for tier 3: a tier 3 tow")
	cfgJ.jobPay = 2
	handlers.sc_configUpdate(json.encode(cfgJ))
	check(tow.payFor(1000, false) == 540, "client.jobPay doubles the pay")
	cfgJ.jobPay = 1
	handlers.sc_configUpdate(json.encode(cfgJ))
	local sentBefore = #sentToServer
	local realFacilities = freeroam_facilities.getFacilities
	freeroam_facilities.getFacilities = function()
		return {}
	end
	handlers.sc_jobGenerate(json.encode({ type = "tow" }))
	check(#sentToServer == sentBefore, "no repair shops on the map: no job")
	freeroam_facilities.getFacilities = realFacilities

	-- the list arrives: the Jobs app is on the phone
	local job = {
		id = 7,
		type = "tow",
		title = "Gavril Grand Marshal",
		pos = { x = 2000, y = -5.8, z = 10 },
		dest = { name = "Belasco Auto", pos = doors.belasco },
		length = 2600,
		pay = 600,
		xp = 70,
		data = {
			vehicle = { model = "fullsize", config = "base" },
			kind = "car",
			flatTire = true,
			faults = { "engine" },
			dir = { x = 1, y = 0 },
		},
	}
	local function sendList(state)
		local j = json.decode(json.encode(job))
		j.state = state
		handlers.sc_jobs(json.encode({ enabled = true, jobs = state and { j } or {} }))
	end
	sendList("open")
	local jobsApp
	for _, app in ipairs(careerConvoy_phone.state().apps) do
		if app.id == "jobs" then
			jobsApp = app
		end
	end
	check(jobsApp and jobsApp.title == "Jobs", "the Jobs app is on the phone")
	local st = jobs.appState()
	local first = st.sections[1] and st.sections[1].groups[1].jobs[1]
	check(
		st.enabled
			and st.open == 1
			and first.state == "open"
			and math.abs(first.distance - 2025.8) < 0.01
			and first.pay == 600
			and first.xp == 70,
		"the app lists the job with its distance by road from you (20 m to the road, 2 km along it, 5.8 m off it), its pay and XP"
	)
	-- licenses: the app greys out the job types you have no license for, "Route" leads to the office
	check(next(st.licenses) == nil, "no licenses from the server yet: nothing greyed out")
	local trigger, pushed = guihooks.trigger, false
	guihooks.trigger = function(name)
		pushed = pushed or name == "CareerConvoyJobs"
	end
	handlers.sc_licenses(json.encode({
		list = {
			{ id = "towing", name = "Towing License", price = 5000, jobType = "tow", owned = false },
			{ id = "taxi", name = "Taxi License", price = 5000, jobType = "taxi", owned = true },
		},
	}))
	guihooks.trigger = trigger
	st = jobs.appState()
	check(
		st.licenses.tow.name == "Towing License"
			and st.licenses.tow.owned == false
			and st.licenses.taxi.owned == true
			and pushed,
		"the Jobs app learns which licenses its job types need and which you own, at once"
	)
	careerConvoy_licenses.uiRoute()
	check(paths[#paths] and math.abs(paths[#paths].x + 500.092) < 0.01, '"Route" leads to the license office')
	handlers.sc_licenses(json.encode({
		list = { { id = "towing", name = "Towing License", price = 5000, jobType = "tow", owned = true } },
	}))
	check(jobs.appState().licenses.tow.owned == true, "license bought: the jobs are no longer greyed out")
	local searches = pathSearches
	me.p = { x = 30, y = -20, z = 10 }
	local near = jobs.appState().sections[1].groups[1].jobs[1].distance
	me.p = { x = 300, y = -20, z = 10 }
	local farther = jobs.appState().sections[1].groups[1].jobs[1].distance
	me.p = { x = 0, y = -20, z = 10 }
	jobs.appState()
	check(
		near == first.distance and pathSearches == searches + 2 and math.abs(farther - 1725.8) < 0.01,
		"moved a little: the same distance, no new search; moved 300 m: searched again"
	)
	check(
		first.icon == "car"
			and first.title == "Gavril Grand Marshal"
			and #first.tags == 2
			and first.tags[2].text == "Flat tire",
		"its icon (the kind of vehicle), title and tags come from the towing job type"
	)
	job.data.kind = nil
	sendList("open")
	check(jobs.appState().sections[1].groups[1].jobs[1].icon == "tow", "a job without a kind of vehicle: the tow icon")
	job.data.kind = "car"
	sendList("open")
	-- the jobs by level: yours first (the hardest at the top), then the locked ones (the nearest first)
	local function listed(minLevel, locked, id)
		local j = json.decode(json.encode(job))
		j.id, j.state, j.minLevel, j.locked = id, "open", minLevel, locked
		return j
	end
	searches = pathSearches
	handlers.sc_jobs(json.encode({
		enabled = true,
		jobs = {
			listed(1, false, 1),
			listed(8, true, 2),
			listed(3, false, 3),
			listed(5, true, 4),
			listed(3, false, 5),
		},
		levels = { tow = { level = 4, xp = 600, from = 520, to = 800 } },
	}))
	local firstUpdate = pathSearches - searches
	st = jobs.appState()
	local unknown = 0
	for _, g in ipairs(st.sections[1].groups) do
		for _, j in ipairs(g.jobs) do
			if j.distance == nil then
				unknown = unknown + 1
			end
		end
	end
	check(
		firstUpdate == 4 and pathSearches - searches == 5 and unknown == 0,
		"at most 4 searches for the way by road per update; the fifth job comes with the next one"
	)
	st = jobs.appState()
	local sec = st.sections[1]
	local order = {}
	for _, g in ipairs(sec.groups) do
		table.insert(order, g.minLevel .. (g.locked and "L" or "") .. ":" .. #g.jobs)
	end
	check(
		#st.sections == 1 and sec.type == "tow" and sec.name == "Towing" and sec.icon == "tow",
		"a section for the towing jobs"
	)
	check(
		table.concat(order, " ") == "3:2 1:1 5L:1 8L:1" and st.open == 3 and sec.open == 3,
		"in it the groups by level: level 3, level 1, then locked 5 and 8"
	)
	check(
		sec.level.level == 4 and math.abs(sec.level.share - 80 / 280) < 1e-9 and sec.level.toGo == 200,
		"your towing level: 4, the ring part way, 200 XP to go"
	)
	-- the levels go with the career save, and come back from it before the server's list
	local saved = {}
	_G.career_saveSystem.jsonWriteFileSafe = function(path, data)
		saved[path] = json.decode(json.encode(data))
		return true
	end
	extensions.hook("onSetProfile", "/saves/slot1", "ben")
	extensions.hook("onSaveCurrentProfile", "/saves/slot1")
	check(
		saved["/saves/slot1/career/careerConvoyJobLevels.json"].levels.tow.level == 4,
		"saving the career: a copy of the levels goes with it"
	)
	jobs.onBeamMPServerLeave()
	local readFile = _G.jsonReadFile
	_G.jsonReadFile = function(path)
		return saved[path] or readFile(path)
	end
	extensions.hook("onCareerActive", true)
	check(
		jobs.appState().sections[1].level.level == 4,
		"next career start: the saved levels show until the server's list comes"
	)
	_G.jsonReadFile, _G.career_saveSystem.jsonWriteFileSafe = readFile, nil
	sendList("open")
	jobs.uiTake(7)
	check(lastSent("sc_jobTake").id == 7, "take: asks the server")
	sendList("mine")
	check(
		jobs.getActive() and paths[#paths].x == 2000 and jobs.appState().active.xp == 70,
		"the job is yours: route to the breakdown; its XP show on it"
	)
	-- far away: nothing spawned yet; within 400 m it appears there, broken down
	for _ = 1, 10 do
		update(0.1)
	end
	check(world.spawned == nil, "far away: the vehicle isn't there yet")
	me.p = { x = 1700, y = -20, z = 10 }
	for _ = 1, 3 do
		update(0.1)
	end
	check(
		world.spawned
			and world.spawned[1] == "fullsize"
			and world.spawned[2].config == "base"
			and world.spawned[2].pos.x == 2000
			and world.spawned[2].autoEnterVehicle == false
			and world.spawned[2].rot,
		"within 400 m: the vehicle appears at its place"
	)
	check(
		lastCmd(spawnedVeh):find("jobBreakDown%(true, {engine = true}%)"),
		"it breaks down, with the flat tire and the faults of the job"
	)
	local cmds = #spawnedVeh.lua
	for _ = 1, 35 do
		update(0.1)
	end
	check(
		#spawnedVeh.lua > cmds and lastCmd(spawnedVeh):find("jobBreakDown"),
		"no answer from the vehicle: broken down again"
	)
	tow.onJobBrokenDown(80, 100)
	local a = jobs.appState().active
	check(
		a.step == 0 and a.text == "to the Gavril Grand Marshal" and a.steps[1] == "Pick up" and a.hint,
		"step 1: drive to it"
	)
	-- close to it: the route goes to the shop
	me.p = { x = 1990, y = -20, z = 10 }
	for _ = 1, 3 do
		update(0.1)
	end
	check(paths[#paths].x == 4000 and jobs.appState().active.step == 1, "near the vehicle: route to the repair shop")
	check(lastCmd(spawnedVeh):find("jobCoolDown%(%)"), "near the vehicle: its engine may cool down")
	-- a reset repairs it: broken down again
	cmds = #spawnedVeh.lua
	extensions.hook("onVehicleResetted", 80)
	check(
		#spawnedVeh.lua == cmds + 1
			and lastCmd(spawnedVeh):find("jobBreakDown%(true, {engine = true}%); careerConvoyVeh.jobCoolDown%(%)"),
		"reset (R): broken down again; the player is there, so the engine isn't kept hot"
	)
	tow.onJobBrokenDown(80, 100)
	-- at the shop: someone inside doesn't count; standing still and empty for 3 s does
	spawnedVeh.p = { x = 4005, y = 52, z = 10 }
	world.playerVeh = 80
	for _ = 1, 50 do
		update(0.1)
	end
	check(lastSent("sc_jobDone") == nil, "somebody sits in it: not handed over")
	world.playerVeh = 70
	spawnedVeh.v = { x = 2, y = 0, z = 0 }
	for _ = 1, 50 do
		update(0.1)
	end
	check(lastSent("sc_jobDone") == nil, "still rolling: not handed over")
	spawnedVeh.v = { x = 0, y = 0, z = 0 }
	for _ = 1, 35 do
		update(0.1)
	end
	check(
		lastCmd(spawnedVeh):find("jobReportDamage"),
		"standing still in the zone for 3 s: the vehicle is asked for its damage"
	)
	tow.onJobDamage(80, 100 + 20000)
	update(0.3)
	local done = lastSent("sc_jobDone")
	check(done and done.id == 7 and done.share == 0.75, "new damage costs part of the pay (half the max: 25 %)")
	-- paid by the server: money in the career, the vehicle goes away a few seconds later
	local payout = json.encode({
		payout = "p-7",
		job = 7,
		type = "tow",
		title = "Gavril Grand Marshal",
		pay = 450,
		deduction = 150,
		xp = 30,
	})
	local realIsActive = career_career.isActive
	career_career.isActive = function()
		return false
	end
	handlers.sc_jobPaid(payout)
	check(
		career_modules_playerAttributes.money() == 1000 and lastSent("sc_jobPaidAck") == nil,
		"career not running (loading): not credited, not confirmed, the server sends it again"
	)
	career_career.isActive = realIsActive
	local savesBefore = world.saved or 0
	_G.career_branches = {
		getSortedBranches = function()
			return {
				{ id = "motorsport", attributeKey = "apmMotorsport", pathId = "apm/motorsport" },
				{ id = "apmCommercial", attributeKey = "apmCommercial", pathId = "apm/commercial" },
			}
		end,
	}
	handlers.sc_jobPaid(payout)
	_G.career_branches = nil
	check(
		career_modules_playerAttributes.money() == 1450
			and lastToastMsg():find("%+%$450")
			and lastToastMsg():find(" · Damage$"),
		"paid: +$450 in the career, a short hint for the deduction"
	)
	check(
		world.moneyLabel == "Towing job: Gavril Grand Marshal" and jobs.appState().active.step == 2,
		"in the money history as a towing job; the last step (paid)"
	)
	check(
		lastToastMsg():find("%+30 XP")
			and career_modules_playerAttributes.xp("beamXP") == 30
			and career_modules_playerAttributes.xp("apmCommercial") == 30,
		"the XP are shown and go to the career's BeamXP and its commercial branch (found by its path id)"
	)
	check(
		(world.saved or 0) == savesBefore + 1 and lastSent("sc_jobPaidAck").payout == "p-7",
		"the career is saved, then the server gets the confirmation"
	)
	local function acks()
		local n = 0
		for _, s in ipairs(sentToServer) do
			if s.event == "sc_jobPaidAck" then
				n = n + 1
			end
		end
		return n
	end
	local acksBefore = acks()
	handlers.sc_jobPaid(payout)
	check(
		career_modules_playerAttributes.money() == 1450 and acks() == acksBefore + 1,
		"sent again: only confirmed, paid once"
	)
	sendList(nil)
	check(jobs.getActive() ~= nil and not spawnedVeh.deleted, "the server drops the job: the vehicle stays a moment")
	for _ = 1, 70 do
		update(0.1)
	end
	check(spawnedVeh.deleted and jobs.getActive() == nil, "a few seconds after paying the vehicle is removed")

	-- no answer from the server after the drop-off: the job ends here after 15 s
	job.id = 10
	sendList("mine")
	me.p = { x = 1990, y = -20, z = 10 }
	for _ = 1, 3 do
		update(0.1)
	end
	local unpaid = spawnedVeh
	tow.onJobBrokenDown(80, 0)
	update(0.3)
	unpaid.p = { x = 4005, y = 52, z = 10 }
	for _ = 1, 40 do
		update(0.1)
	end
	tow.onJobDamage(80, 0)
	update(0.3)
	check(lastSent("sc_jobDone").id == 10 and jobs.getActive() ~= nil, "handed over, waiting for the server")
	for _ = 1, 160 do
		update(0.1)
	end
	check(
		jobs.getActive() == nil and unpaid.deleted and lastToastMsg():find("No answer"),
		"no answer within 15 s: ended here"
	)
	-- a vehicle removed right away (server's vehicle limit): not spawned again at once, the player is told
	job.id = 11
	sendList("mine")
	for _ = 1, 3 do
		update(0.1)
	end
	local refused = spawnedVeh
	refused.deleted = true
	update(0.3)
	check(lastToastMsg():find("vehicle limit"), "removed right away: the player hears why")
	local firstRetry = spawnedVeh
	for _ = 1, 50 do
		update(0.1)
	end
	check(spawnedVeh == firstRetry, "not spawned again within 10 s")
	for _ = 1, 60 do
		update(0.1)
	end
	check(spawnedVeh ~= firstRetry, "spawned again after 10 s")
	jobs.uiGiveUp()

	-- a crash: the car falls from the air, tilted, and breaks down only once it lies still
	job.id, job.data.crash = 12, { kind = "roof", speed = 5 }
	sendList("mine")
	me.p = { x = 1700, y = -20, z = 10 }
	for _ = 1, 3 do
		update(0.1)
	end
	local opt = world.spawned[2]
	check(
		opt.cling == false
			and opt.safeSpawn == false
			and opt.pos.z > 10 + 3 + 1.2
			and opt.pos.z < 10 + 3 + 1.4
			and opt.rot.dir.z
			and math.abs(opt.rot.dir.z) < 1e-9,
		"a crash: spawned in the air (high enough to hit the ground at 5 m/s), not stuck to the ground"
	)
	local up = world.spawnedUp
	check(up and up.z < -0.99, "on its roof: spawned upside down")
	local crashed = spawnedVeh
	crashed.v = { x = 0, y = 0, z = -5 }
	for _ = 1, 30 do
		update(0.1)
	end
	check(not lastCmd(crashed):find("jobBreakDown"), "still falling and rolling: no breakdown yet")
	crashed.v = { x = 0, y = 0, z = 0 }
	crashed.p = { x = 2003, y = -6, z = 10 }
	for _ = 1, 30 do
		update(0.1)
	end
	check(lastCmd(crashed):find("jobBreakDown"), "lying still for 2 s: now it breaks down (the crash isn't new damage)")
	jobs.uiGiveUp()
	-- a crash that lands too far away (down a slope): removed, it comes back as a breakdown
	job.id = 13
	sendList("mine")
	for _ = 1, 3 do
		update(0.1)
	end
	local rolled = spawnedVeh
	rolled.v = { x = 0, y = 0, z = 0 }
	rolled.p = { x = 2060, y = -40, z = -2 }
	for _ = 1, 30 do
		update(0.1)
	end
	check(
		rolled.deleted
			and spawnedVeh ~= rolled
			and world.spawned[2].cling == true
			and world.spawned[2].safeSpawn == true
			and lastCmd(spawnedVeh):find("jobBreakDown"),
		"landed too far away: removed, spawned again at once as a breakdown on the ground"
	)
	jobs.uiGiveUp()
	job.data.crash = nil

	-- giving up: the vehicle goes, the server is told
	job.id = 8
	sendList("mine")
	me.p = { x = 1900, y = -20, z = 10 }
	for _ = 1, 3 do
		update(0.1)
	end
	local second = spawnedVeh
	jobs.uiGiveUp()
	check(
		lastSent("sc_jobGiveUp").id == 8 and second.deleted and jobs.getActive() == nil,
		"give up: vehicle removed, server told"
	)
	-- a job taken away by the server (out of time): ended here too
	job.id = 9
	sendList("mine")
	for _ = 1, 3 do
		update(0.1)
	end
	local third = spawnedVeh
	sendList("open")
	check(jobs.getActive() == nil and third.deleted, "taken away by the server: ended, vehicle removed")
	-- another job type: the core works without anything of the towing jobs
	local calls = {}
	local test = {
		id = "test",
		name = "Test",
		icon = "T",
		steps = { "Go", "Paid" },
		generate = function()
			return {
				title = "Box",
				pos = { x = 10, y = 0, z = 0 },
				dest = { name = "Depot", pos = { x = 20, y = 0, z = 0 } },
				length = 10,
				pay = 100,
				data = { weight = 3 },
			}
		end,
		tags = function(j)
			return { { text = j.data.weight .. " t", kind = "load" } }
		end,
		start = function(a)
			table.insert(calls, "start")
			a.left = 2
		end,
		step = function(a)
			a.left = a.left - 1
			if a.left <= 0 then
				jobs.handOver(a, 0.9)
			end
		end,
		status = function()
			return { step = 0, text = "to the depot", short = "Bring the box", target = { x = 20, y = 0, z = 0 } }
		end,
		stop = function()
			table.insert(calls, "stop")
		end,
	}
	jobs.registerType(test)
	local made = jobs.generate("test", 2)
	local none, why = jobs.generate("nope", 1)
	check(
		made.type == "test" and made.tier == 2 and none == nil and why == "unknown job type nope",
		"making up a job: by the job type the server asks for; an unknown one makes none"
	)
	local tj = {
		id = 20,
		type = "test",
		title = "Box",
		pos = { x = 10, y = 0, z = 0 },
		dest = { name = "Depot", pos = { x = 20, y = 0, z = 0 } },
		length = 10,
		pay = 100,
		data = { weight = 3 },
		state = "mine",
	}
	handlers.sc_jobs(json.encode({ enabled = true, jobs = { tj } }))
	st = jobs.appState()
	check(
		calls[1] == "start"
			and paths[#paths].x == 20
			and st.active.icon == "T"
			and st.active.tags[1].text == "3 t"
			and st.active.short == "Bring the box",
		"a test job: started, route to its target, its texts in the app"
	)
	for _ = 1, 10 do
		update(0.1)
	end
	check(lastSent("sc_jobDone").id == 20 and lastSent("sc_jobDone").share == 0.9, "the job type hands it over")
	handlers.sc_jobPaid(
		json.encode({ payout = "p-20", job = 20, type = "test", title = "Box", pay = 90, deduction = 10 })
	)
	check(world.moneyLabel == "Test job: Box" and lastToastMsg():find("Damage"), "paid, named after its job type")
	for _ = 1, 70 do
		update(0.1)
	end
	check(calls[2] == "stop" and jobs.getActive() == nil, "a few seconds later the job ends: the type cleans up")
	handlers.sc_jobs(json.encode({
		enabled = true,
		jobs = {
			{ id = 21, type = "unknown", title = "?", pos = tj.pos, dest = tj.dest, pay = 1, state = "open" },
			{ id = 22, type = "unknown", title = "?", pos = tj.pos, dest = tj.dest, pay = 1, state = "mine" },
			{ id = 23, type = "test", title = "Box", pos = tj.pos, dest = tj.dest, pay = 1, state = "open" },
		},
		levels = {
			tow = { level = 4, xp = 600, from = 520, to = 800 },
			test = { level = 2, xp = 150, from = 100, to = 283 },
		},
	}))
	st = jobs.appState()
	check(
		jobs.getActive() == nil
			and #st.sections == 3
			and st.sections[1].type == "tow"
			and st.sections[2].type == "test"
			and st.sections[2].level.level == 2
			and st.sections[3].type == "unknown"
			and st.sections[3].groups[1].jobs[1].icon == "?",
		"a section per job type, each with its own level; a type this client doesn't know: last, listed, not started"
	)
	-- switched off on the server: the app goes away
	cfgJ.ui.jobs = false
	handlers.sc_configUpdate(json.encode(cfgJ))
	local still = false
	for _, app in ipairs(careerConvoy_phone.state().apps) do
		if app.id == "jobs" then
			still = true
		end
	end
	check(not still, "switched off on the server: no Jobs app")
	-- a payout sent again after a reconnect is only confirmed, not credited twice
	jobs.onBeamMPServerLeave()
	acksBefore = acks()
	local moneyBefore = career_modules_playerAttributes.money()
	handlers.sc_jobPaid(payout)
	check(
		career_modules_playerAttributes.money() == moneyBefore and acks() == acksBefore + 1,
		"after a reconnect: a payout sent again is only confirmed"
	)

	--== Taxi jobs ==
	local taxi = careerConvoy_taxiJobs
	cfgJ.ui.jobs = true
	handlers.sc_configUpdate(json.encode(cfgJ))
	extensions.hook("onCareerActive", true)
	local told = lastSent("sc_jobsRequest")
	check(
		told and table.concat(told.types, ",") == "tow,taxi,test",
		"the client tells the server its job types: towing, taxi (and the test one)"
	)
	handlers.sc_jobs(json.encode({ enabled = true, jobs = {} }))
	world.playerVeh = 70
	me.p = { x = 0, y = -20, z = 10 }
	-- making one up: a passenger beside the road, a place of the map, the pay by the way by road
	check(
		taxi.payFor(1000, false, 1) == 140
			and taxi.payFor(1000, true, 1) == 210
			and taxi.payFor(1000, false, 4) == 210
			and taxi.payFor(1000, false, 1, 3) == 180
			and taxi.payFor(1000, false, 1, 5) == 220,
		"taxi pay: $60 + $80 per km; a VIP pays 50 % more, tier 4 50 % more, 15 % for every passenger after the first"
	)
	handlers.sc_jobGenerate(json.encode({ type = "taxi", tier = 2 }))
	offer = lastSent("sc_jobOffer")
	check(
		offer
			and offer.type == "taxi"
			and offer.tier == 2
			and (offer.title == "Passenger" or offer.title == "VIP")
			and math.abs(math.abs(offer.pos.y) - 5.8) < 1e-6
			and offer.length == jobs.roadLength(offer.pos, offer.dest.pos)
			and offer.pay == taxi.payFor(offer.length, offer.data.vip, 2, offer.data.passengers),
		"the server asks for a taxi job: a passenger beside the road, a ride by road to a place, its pay"
	)
	check(
		offer.data.face and offer.data.face.x == 0 and offer.data.face.y * offer.pos.y < 0,
		"the passenger looks towards the road"
	)
	-- a town: a grid of streets (10 x 10 junctions, 50 m apart) next to the long road; like the
	-- game, each link is kept at one of its ends only
	local realGetMap = map.getMap
	local townNodes = {}
	for name, n in pairs(nodes) do
		townNodes[name] = n
	end
	local function street(i, j)
		return "t" .. i .. "_" .. j
	end
	for i = 0, 9 do
		for j = 0, 9 do
			townNodes[street(i, j)] = { pos = vec3(6000 + i * 50, 2000 + j * 50, 10), radius = 4, links = {} }
		end
	end
	for i = 0, 9 do
		for j = 0, 9 do
			for _, d in ipairs({ { 1, 0 }, { 0, 1 } }) do
				local a, b = street(i, j), street(i + d[1], j + d[2])
				if townNodes[b] then
					townNodes[a].links[b] = { drivability = 1 }
				end
			end
		end
	end
	map.getMap = function()
		return { nodes = townNodes }
	end
	check(
		jobs.inTown({ x = 6200, y = 2200 }) and not jobs.inTown({ x = 2000, y = 0 }),
		"a town: where road junctions are dense"
	)
	local inTown, outside = 0, 0
	for _ = 1, 20 do
		local spot = jobs.randomRoadside(true)
		inTown = inTown + (spot and jobs.inTown(spot.pos) and 1 or 0)
		spot = jobs.randomRoadside(false)
		outside = outside + (spot and not jobs.inTown(spot.pos) and 1 or 0)
	end
	check(inTown == 20 and outside == 20, "a place beside the road in town, or outside it, as asked")
	local startsInTown = 0
	math.randomseed(3)
	for _ = 1, 100 do
		local ride = taxi.generate(1)
		startsInTown = startsInTown + (ride and jobs.inTown(ride.pos) and 1 or 0)
	end
	check(startsInTown >= 45 and startsInTown <= 75, "most taxi rides start in town, the others outside")
	map.getMap = realGetMap
	local vips = { 0, 0 }
	for i, tier in ipairs({ 1, 4 }) do
		for _ = 1, 100 do
			local j = taxi.generate(tier)
			if j.data.vip then
				vips[i] = vips[i] + 1
			end
			if j.title ~= (j.data.vip and "VIP" or "Passenger") then
				vips[i] = -1000
			end
		end
	end
	check(
		vips[1] == 0 and vips[2] > 25 and vips[2] < 75,
		"VIPs: never in tier 1, about half in tier 4 (" .. table.concat(vips, "/") .. ")"
	)
	check(
		#taxi.tags({ data = { vip = false } }) == 0 and taxi.tags({ data = { vip = true } })[1].text == "VIP",
		"a VIP shows as a tag"
	)
	freeroam_facilities.getFacilities = function()
		return {}
	end
	local toStreet = taxi.generate(1)
	freeroam_facilities.getFacilities = realFacilities
	check(
		toStreet
			and toStreet.dest.name == "Country road"
			and math.abs(math.abs(toStreet.dest.pos.y) - 5.8) < 1e-6
			and math.abs(toStreet.dest.pos.x - toStreet.pos.x) >= 600
			and math.abs(toStreet.dest.pos.x - toStreet.pos.x) <= 2000,
		"no places on the map: a ride to a street, as far away as the tier says"
	)
	-- mostly to a street, named after a place nearby; else to a place
	local streets, toPlaces, named = 0, 0, true
	math.randomseed(11)
	for _ = 1, 60 do
		local ride = taxi.generate(1)
		local street = ride and math.abs(math.abs(ride.dest.pos.y) - 5.8) < 1e-6
		if street then
			streets = streets + 1
			local nearBelasco = jobs.dist2D(ride.dest.pos, doors.belasco) <= 400
			local nearHome = jobs.dist2D(ride.dest.pos, doors.home) <= 400
			named = named
				and ride.dest.name
					== (nearBelasco and "Near Belasco Auto" or nearHome and "Near Home Garage" or "Country road")
		elseif ride then
			toPlaces = toPlaces + 1
		end
	end
	check(
		streets >= 35 and toPlaces >= 5 and named,
		'rides mostly to streets ("Near Belasco Auto", "Country road"), some to places'
	)
	-- a higher level: longer rides and more passengers
	local function rides(tier)
		local inRange, people, count = 0, 0, 0
		local range = ({ { 600, 2000 }, nil, nil, { 3000, 7000 } })[tier]
		for _ = 1, 40 do
			local ride = taxi.generate(tier)
			if ride then
				local d = jobs.dist2D(ride.pos, ride.dest.pos)
				inRange = inRange + (d >= range[1] and d <= range[2] and 1 or 0)
				people = people + ride.data.passengers
				count = count + 1
			end
		end
		return inRange / count, people / count
	end
	local shortShare, fewPeople = rides(1)
	local longShare, morePeople = rides(4)
	check(
		shortShare == 1 and longShare == 1 and morePeople > fewPeople + 0.5,
		"level 1: rides of 0.6-2 km; level 8: of 3-7 km, with more passengers"
	)
	-- doing it: pick up the passenger, drive to the place, a smooth ride pays all
	local ride = {
		id = 30,
		type = "taxi",
		title = "Passenger",
		pos = { x = 2000, y = -5.8, z = 10 },
		dest = { name = "Belasco Auto", pos = doors.belasco },
		length = 2000,
		pay = 400,
		data = { vip = false, passengers = 3 },
		state = "mine",
	}
	-- the game's figure at the roadside and its seat occupants (a dummy in the taxi)
	local figures = {}
	_G.createObject = function(class)
		local o = { class = class }
		function o:setPosRot(x, y, z)
			self.pos = { x = x, y = y, z = z }
		end
		function o:registerObject()
			figures[#figures + 1] = self
		end
		function o:delete()
			self.deleted = true
		end
		return o
	end
	local seatClaims = {}
	local seatList = { { seatId = "FL", isDriver = true }, { seatId = "FR" }, { seatId = "RL" } }
	_G.gameplay_seatOccupants = {
		getSeats = function(id)
			local out = {}
			for _, seat in ipairs(id == 70 and seatList or {}) do
				local claim = seatClaims[seat.seatId]
				out[#out + 1] = {
					seatId = seat.seatId,
					isDriver = seat.isDriver == true,
					occupied = claim ~= nil,
					occupantType = claim,
				}
			end
			return out
		end,
		setDummyOccupant = function(id, seatId)
			seatClaims[seatId] = "dummy"
			return true
		end,
		clearDummyOccupant = function(id, seatId)
			seatClaims[seatId] = nil
			return true
		end,
	}
	handlers.sc_jobs(json.encode({ enabled = true, jobs = { ride } }))
	check(
		#figures == 3
			and figures[1].class == "TSStatic"
			and figures[1].shapeName:find("traffic_character", 1, true)
			and figures[2].pos.x == 2000
			and math.abs(figures[1].pos.x - figures[3].pos.x) > 1
			and figures[1].pos.y == figures[3].pos.y
			and not figures[1].deleted,
		"the job is yours: three passengers stand side by side along the road"
	)
	st = jobs.appState()
	check(
		jobs.getActive()
			and paths[#paths].x == 2000
			and st.active.short == "Pick up the passengers"
			and st.active.steps[2] == "Drive",
		"the job is yours: the route leads to the passenger"
	)
	local walker = addVehicle(91, "0-91", true, "unicycle")
	walker.p = { x = 2002, y = -8, z = 10 }
	function walker:getPosition()
		return self.p
	end
	world.playerVeh = 91
	for _ = 1, 30 do
		update(0.1)
	end
	check(
		jobs.appState().active.step == 0 and jobs.appState().active.hint == "Pick them up in a car.",
		"on foot next to them: they don't get in"
	)
	world.playerVeh = 70
	me.p = { x = 2003, y = -9, z = 10 }
	me.v = { x = 0, y = 0, z = 0 }
	function me:getVelocity()
		return self.v
	end
	_G.map.objects = { [70] = { damage = 100 } }
	for _ = 1, 25 do
		update(0.1)
	end
	check(
		jobs.appState().active.step == 0 and jobs.appState().active.hint == "Too few seats. Take a bigger car.",
		"three passengers, two free seats: they don't get in"
	)
	table.insert(seatList, { seatId = "RR" })
	for _ = 1, 25 do
		update(0.1)
	end
	st = jobs.appState()
	check(
		st.active.step == 1 and paths[#paths].x == 4000 and lastToastMsg() == "Passengers in: drive to Belasco Auto",
		"stopped next to them in a car: they get in, the route leads to the place"
	)
	check(
		figures[1].deleted
			and figures[3].deleted
			and #figures == 3
			and seatClaims.RL == "dummy"
			and seatClaims.RR == "dummy"
			and seatClaims.FR == "dummy"
			and not seatClaims.FL,
		"they get in: gone from the roadside, dummies on the rear seats and, the rear full, the front one"
	)
	seatClaims.RL = nil -- the game took one out (the taxi rebuilt in the garage)
	for _ = 1, 25 do
		update(0.1)
	end
	check(seatClaims.RL == "dummy" and seatClaims.RR == "dummy", "a dummy taken out: they sit down again")
	-- a bumpy road: the taxi shakes from frame to frame, but that is no jolt
	for i = 1, 40 do
		me.v = { x = 0, y = 0, z = (i % 2 == 0) and 1.5 or -1.5 }
		update(0.02)
	end
	me.v = { x = 0, y = 0, z = 0 }
	update(0.02)
	check(jobs.getActive().jolts == 0, "a bumpy road: no jolt")
	-- a tight turn at 40 km/h (11 m/s around 10 m: 12 m/s^2 sideways): no jolt
	for i = 1, 22 do -- speeding up gently first
		me.v = { x = i * 0.5, y = 0, z = 0 }
		update(0.1)
	end
	for i = 1, 30 do
		local t = i * 0.05 * 1.1
		me.v = { x = 11 * math.cos(t), y = 11 * math.sin(t), z = 0 }
		update(0.05)
	end
	check(jobs.getActive().jolts == 0, "a tight turn: no jolt")
	local turned = me.v
	for i = 21, 0, -1 do -- and slowing down gently
		me.v = { x = turned.x * i / 22, y = turned.y * i / 22, z = 0 }
		update(0.1)
	end
	for _ = 1, 10 do
		update(0.1)
	end
	-- a hard stop is a jolt: once, not again right after
	me.v = { x = 15, y = 0, z = 0 }
	update(0.6)
	me.v = { x = 0, y = 0, z = 0 }
	update(0.6)
	me.v = { x = 15, y = 0, z = 0 }
	update(0.6)
	me.v = { x = 0, y = 0, z = 0 }
	update(0.6)
	local active = jobs.getActive()
	check(active.jolts == 1 and lastToastMsg() == "Drive smoother!", "a hard stop is one jolt")
	st = jobs.appState()
	check(
		st.active.stars == 4 and st.active.payNow == 380 and st.active.pay == 400,
		"the app shows it at once: 4 stars, the pay as it is now ($380 of $400)"
	)
	-- speeding: on the road (limit 20 m/s), more than 10 % over it: after 2 s they complain, after
	-- 7 s it costs; staying too fast, both again every 10 s
	me.p = { x = 2500, y = -2, z = 10 }
	-- the speed limit sign learns that this is a taxi ride (the player may show it only then)
	local rideSign
	local trigger1 = guihooks.trigger
	guihooks.trigger = function(name, data)
		if name == "CareerConvoySpeedLimit" then
			rideSign = data
		end
		return trigger1(name, data)
	end
	careerConvoy_speedLimit.uiRequest()
	update(0.3)
	guihooks.trigger = trigger1
	check(rideSign and rideSign.kmh and rideSign.taxi == true, "on a taxi ride: the speed limit sign knows it")
	local function speedTo(v)
		while math.abs(me.v.x - v) > 1e-9 do
			me.v = { x = me.v.x + math.max(-1.5, math.min(1.5, v - me.v.x)), y = 0, z = 0 }
			update(0.3)
		end
	end
	local function drive(seconds)
		for _ = 1, math.floor(seconds / 0.3 + 0.5) do
			update(0.3)
		end
	end
	speedTo(21.5)
	drive(4)
	check(active.speeding == 0 and active.jolts == 1, "up to 10 % over the limit: fine (speeding up gently is no jolt)")
	speedTo(25.5)
	me.p.y = -12
	drive(4)
	check(active.speeding == 0, "off the road: no speed limit")
	me.p.y = -2
	drive(1.5)
	check(active.speeding == 0, "too fast, but not for 2 s yet: nothing")
	drive(1)
	check(
		active.speeding == 0 and lastToastMsg() == "Slow down, please!",
		"too fast for 2 s: the passengers complain, it costs nothing yet"
	)
	drive(4)
	check(active.speeding == 0, "still too fast, but less than 5 s after they complained: free")
	drive(1)
	check(active.speeding == 1 and lastToastMsg() == "Too fast! Less pay.", "5 s after they complained: it costs")
	drive(5)
	check(active.speeding == 1 and lastToastMsg() == "Slow down, please!", "staying too fast: they complain again")
	drive(5)
	check(active.speeding == 2, "10 s after the first: it costs again")
	speedTo(0)
	check(active.jolts == 1, "slowing down gently is no jolt")
	world.playerVeh = nil
	check(jobs.appState().active.short == "Back to your taxi", "out of the taxi: back to it")
	world.playerVeh = 70
	_G.map.objects[70].damage = 4100
	me.p = { x = 4002, y = 48, z = 10 }
	for _ = 1, 30 do
		update(0.1)
	end
	local done = lastSent("sc_jobDone")
	check(
		done and done.id == 30 and math.abs(done.share - 0.8) < 1e-9 and done.tip == 0,
		"standing in the ring: handed over; a jolt, speeding twice and new damage cost 20 % of the pay: 3 stars, no tip"
	)
	check(next(seatClaims) == nil and #figures == 3, "at the place: the dummies get out")
	_G.createObject, _G.gameplay_seatOccupants = nil, nil
	check(
		taxi.starsFor(0) == 5
			and taxi.starsFor(0.05) == 4
			and taxi.starsFor(0.1) == 4
			and taxi.starsFor(0.15) == 3
			and taxi.starsFor(0.3) == 2
			and taxi.starsFor(0.5) == 1,
		"stars: 5 for a smooth ride, one less for about every 10 % it cost"
	)
	check(
		taxi.tipFor(5) == 0.15 and taxi.tipFor(4) == 0.05 and taxi.tipFor(3) == 0 and taxi.tipFor(5, true) == 0.25,
		"a tip: 15 % for 5 stars, 5 % for 4, none below; a VIP tips more"
	)
	handlers.sc_jobPaid(json.encode({
		payout = "p-30",
		job = 30,
		type = "taxi",
		title = "Passenger",
		pay = 360,
		deduction = 40,
	}))
	check(
		world.moneyLabel == "Taxi job: Passenger" and lastToastMsg() == "Job done: +$360 · Rough ride",
		'taxi pay: one total and "Rough ride", not "Damage"'
	)
	handlers.sc_jobPaid(json.encode({
		payout = "p-31",
		job = 31,
		type = "taxi",
		title = "VIP",
		pay = 575,
		deduction = 0,
		tip = 75,
		xp = 40,
	}))
	check(
		lastToastMsg() == "Job done: +$575 · +40 XP · Smooth ride bonus +$75",
		"a tip: one total, the tip with its amount"
	)
	handlers.sc_jobPaid(json.encode({
		payout = "p-32",
		job = 32,
		type = "taxi",
		title = "Passenger",
		pay = 231,
		deduction = 11,
		tip = 12,
		xp = 38,
	}))
	check(
		lastToastMsg() == "Job done: +$231 · +38 XP · Smooth ride bonus +$12",
		"a tip and a deduction: one total, the tip with its amount"
	)
	handlers.sc_jobPaid(json.encode({
		payout = "p-33",
		job = 33,
		type = "taxi",
		title = "Passenger",
		pay = 200,
		deduction = 10,
		tip = 10,
		xp = 30,
	}))
	check(lastToastMsg() == "Job done: +$200 · +30 XP · Smooth ride bonus +$10", "a small tip shows too")
	check(
		math.abs(taxi.penalty({ job = { data = { vip = true } }, jolts = 1, speeding = 1 }) - 0.2) < 1e-9
			and taxi.penalty({ job = { data = {} }, rough = true }) == 0.5
			and taxi.penalty({ job = { data = {} }, jolts = 30 }) == 0.5,
		"a VIP: jolts and speeding cost twice as much; a reset costs half; never more than half"
	)
	-- passengers: 1..5, a higher tier makes a group more likely
	local function share(tier, n)
		math.randomseed(7)
		local hits = 0
		for _ = 1, 2000 do
			hits = hits + (taxi.rollPassengers(tier) == n and 1 or 0)
		end
		return hits / 2000
	end
	check(share(1, 1) > 0.7 and share(1, 3) == 0, "tier 1: mostly one passenger, never three")
	check(
		share(4, 1) > 0.2 and share(4, 5) > 0.05 and share(4, 5) < 0.2 and share(4, 6) == 0,
		"tier 4: still often one passenger, sometimes five, never more"
	)
	check(
		taxi.passengersOf({ data = { passengers = 3 } }) == 3
			and taxi.passengersOf({ data = {} }) == 1
			and taxi.passengersOf({ data = { passengers = 9 } }) == 5,
		"a ride has 1..5 passengers"
	)
	check(
		taxi.tags({ data = { passengers = 3 } })[1].text == "3 people"
			and #taxi.tags({ data = { passengers = 1 } }) == 0,
		'a group shows "3 people" in the app'
	)
	local function seatsText(rear, front, n)
		return table.concat(taxi.spreadSeats(rear, front, n), ",")
	end
	check(
		seatsText({ "RL", "RM", "RR" }, { "FR" }, 2) == "RL,RR"
			and seatsText({ "RL", "RM", "RR" }, { "FR" }, 1) == "RM"
			and seatsText({ "RL", "RR" }, { "FR" }, 1) == "RR"
			and seatsText({ "RL", "RM", "RR" }, { "FR" }, 4) == "RL,RM,RR,FR"
			and seatsText({ "R1L", "R1R", "R2L", "R2R" }, {}, 2) == "R1R,R2R",
		"passengers spread evenly over the rear seats; the front seat only when the rear is full"
	)

	-- calls: only while on duty, the nearest ride rings the phone; not nagging
	local phone = careerConvoy_phone
	local rings = {} -- what the phone window got: a call, or false when it ended
	local trigger0 = guihooks.trigger
	guihooks.trigger = function(name, data)
		if name == "CareerConvoyPhoneCall" then
			table.insert(rings, data.call or false)
		end
		return trigger0(name, data)
	end
	local function wait(seconds)
		for _ = 1, math.floor(seconds / 0.5 + 0.5) do
			update(0.5)
		end
	end
	local function lastRing()
		return rings[#rings]
	end
	local function rideAt(id, x)
		return {
			id = id,
			type = "taxi",
			title = "Passenger",
			pos = { x = x, y = -5.8, z = 10 },
			dest = { name = "Belasco Auto", pos = doors.belasco },
			length = 2000,
			pay = 300,
			data = { vip = false },
			state = "open",
		}
	end
	local function listRides(...)
		handlers.sc_jobs(json.encode({
			enabled = true,
			jobs = { ... },
			levels = { taxi = { level = 1, xp = 0, from = 0, to = 100 } },
		}))
	end
	wait(8)
	handlers.sc_licenses(json.encode({
		list = { { id = "taxi", name = "Taxi License", price = 5000, jobType = "taxi", owned = true } },
	}))
	me.p = { x = 2000, y = -2, z = 10 }
	listRides(rideAt(41, 2600), rideAt(42, 4500))
	local function taxiSection()
		for _, sec in ipairs(jobs.appState().sections) do
			if sec.type == "taxi" then
				return sec
			end
		end
	end
	wait(6)
	check(
		jobs.getActive() == nil and #rings == 0 and taxiSection().duty == false and not taxi.isOnDuty(),
		"off duty (on every join): no calls; the app shows the switch off"
	)
	jobs.uiDuty("taxi", true)
	check(
		taxiSection().duty == true and lastToastMsg() == "On duty: rides will call you",
		'"On duty": the switch is on'
	)
	wait(4)
	local ring = lastRing()
	check(
		ring
			and ring.title == "Ride request"
			and ring.text == "1 person to Belasco Auto"
			and ring.detail == "600 m away · $300"
			and ring.icon == "taxi"
			and ring.open.app == "jobs"
			and ring.open.page == "taxi"
			and phone.ringing(),
		"on duty: the nearest ride rings the phone (the one 2.5 km away doesn't)"
	)
	phone.uiAnswer(false)
	local ringsAfter = #rings
	wait(60)
	check(
		lastRing() == false and #rings == ringsAfter,
		"declined: the call ends; that ride doesn't call again, and nothing else is near"
	)
	me.p = { x = 4000, y = -2, z = 10 }
	wait(4)
	check(
		lastRing() and lastRing().text == "1 person to Belasco Auto" and phone.ringing(),
		"nearer to another ride: it calls"
	)
	wait(16)
	check(lastRing() == false and not phone.ringing() and taxi.isOnDuty(), "not answered: it rings out, still on duty")
	listRides(rideAt(41, 2600), rideAt(42, 4500), rideAt(43, 3600))
	wait(30)
	check(lastRing() == false, "after a missed call: a pause before the next")
	wait(20)
	check(lastRing() and phone.ringing(), "after the pause: the next ride calls")
	wait(16)
	check(
		not taxi.isOnDuty() and lastToastMsg() == "Off duty: calls missed" and taxiSection().duty == false,
		"two calls missed in a row: off duty"
	)
	jobs.uiDuty("taxi", true)
	listRides(rideAt(44, 4300))
	wait(4)
	check(phone.ringing(), "on duty again: a new ride calls")
	listRides()
	wait(3)
	check(lastRing() == false and not phone.ringing(), "someone else took the ride: the call hangs up")
	listRides(rideAt(45, 4200))
	wait(4)
	phone.uiAnswer(true)
	check(lastSent("sc_jobTake").id == 45 and lastRing() == false, '"Accept": the ride is taken')
	jobs.uiDuty("taxi", false)
	check(not taxi.isOnDuty() and lastToastMsg() == "Off duty", "switched off: off duty")
	-- a group calls only when your vehicle has a seat for each; the app lists it anyway
	local group = rideAt(46, 4200)
	group.data.passengers = 3
	listRides(group)
	jobs.uiDuty("taxi", true)
	wait(6)
	check(
		not phone.ringing() and #jobs.openJobsOf("taxi") == 1,
		"a group of three: listed, but no call in a vehicle whose seats can't be counted"
	)
	local seats = { { seatId = "FL", isDriver = true }, { seatId = "FR" }, { seatId = "RL" } }
	_G.gameplay_seatOccupants = {
		getSeats = function()
			return seats
		end,
		setDummyOccupant = function()
			return true
		end,
	}
	wait(4)
	check(not phone.ringing(), "a group of three, two free seats: no call")
	table.insert(seats, { seatId = "RR" })
	wait(4)
	check(
		phone.ringing() and lastRing().text == "3 people to Belasco Auto",
		"a seat for each: the group calls, saying how many they are"
	)
	phone.uiAnswer(false)
	jobs.uiDuty("taxi", false)
	-- calls only while you sit in a vehicle of your own
	listRides(rideAt(47, 4250))
	local friend = addVehicle(92, "1-92", false)
	world.playerVeh = 92 -- watching another player in their car
	jobs.uiDuty("taxi", true)
	wait(6)
	check(not phone.ringing(), "in another player's car: no calls")
	world.playerVeh = 91 -- on foot
	wait(4)
	check(not phone.ringing(), "on foot: no calls")
	world.playerVeh = 70
	wait(4)
	check(phone.ringing(), "back in your own car: the ride calls")
	phone.uiAnswer(false)
	jobs.uiDuty("taxi", false)
	friend.deleted = true
	_G.gameplay_seatOccupants = nil
	jobs.uiDuty("taxi", true)
	phone.uiInstall("jobs", false)
	check(not taxi.isOnDuty() and taxiSection().duty == false, "Jobs app removed: off duty")
	phone.uiInstall("jobs", true)
	check(not taxi.isOnDuty(), "installed again: still off duty until switched on")

	--== The speed limit sign (speedLimit.lua) ==
	local signs = {}
	guihooks.trigger = function(name, data)
		if name == "CareerConvoySpeedLimit" then
			table.insert(signs, data)
		end
		return trigger0(name, data)
	end
	local units = "metric"
	_G.settings = {
		getValue = function(key)
			return key == "uiUnitLength" and units or nil
		end,
	}
	local function sign()
		return signs[#signs]
	end
	world.playerVeh = 70
	me.p, me.v = { x = 3000, y = -2, z = 10 }, { x = 0, y = 0, z = 0 }
	careerConvoy_speedLimit.uiRequest() -- the window opens: it asks for the sign
	wait(1)
	check(
		sign().kmh == 70
			and sign().mph == 45
			and sign().unit == "km/h"
			and sign().over == false
			and sign().taxi == false,
		"on the road: its limit (20 m/s) in km/h and mph, rounded to 5; the game's unit; no taxi ride"
	)
	local count = #signs
	wait(2)
	check(#signs == count, "nothing changed: nothing sent")
	me.v = { x = 21.5, y = 0, z = 0 }
	wait(1)
	check(#signs == count and sign().over == false, "up to 10 % over the limit: no warning")
	me.v = { x = 22.5, y = 0, z = 0 }
	wait(1)
	check(sign().over == true, "more than 10 % over: the sign warns")
	units = "imperial"
	me.v = { x = 0, y = 0, z = 0 }
	wait(1)
	check(sign().mph == 45 and sign().unit == "mph" and sign().over == false, "imperial units: the game's unit is mph")
	me.p.y = -12
	wait(1)
	check(sign().kmh == nil, "off the road: no sign")
	me.p.y = -2
	world.playerVeh = 91
	wait(1)
	check(sign().kmh == nil, "on foot: no sign")
	world.playerVeh = 70
	_G.settings = nil
	guihooks.trigger = trigger0
	jobs.onBeamMPServerLeave()
	_G.map, _G.freeroam_facilities, _G.jsonReadFile, _G.util_configListGenerator, _G.core_groundMarkers =
		nil, nil, nil, nil, nil
	_G.castRayStatic = nil
end)();

-- the vehicle side: breaking down and reporting the damage
(function()
	local calls, ge = {}, {}
	local env = setmetatable({
		powertrain = {
			getDevices = function()
				return {
					{
						type = "combustionEngine",
						disable = function()
							table.insert(calls, "engine off")
						end,
					},
					{
						type = "gearbox",
						disable = function()
							table.insert(calls, "gearbox!")
						end,
					},
				}
			end,
		},
		controller = {
			mainController = {
				shiftToGearIndex = function(i)
					table.insert(calls, "gear " .. i)
				end,
			},
		},
		input = {
			event = function(name, v)
				table.insert(calls, name .. " " .. v)
			end,
		},
		electrics = {
			values = { ignitionLevel = 0, hazard_enabled = 0 },
			set_warn_signal = function(on)
				table.insert(calls, "hazard " .. tostring(on))
			end,
			setIgnitionLevel = function(l)
				table.insert(calls, "ignition " .. l)
			end,
		},
		beamstate = {
			damage = 1234.5,
			deflateRandomTire = function()
				table.insert(calls, "flat")
			end,
		},
		obj = {
			getId = function()
				return 80
			end,
			queueGameEngineLua = function(_, cmd)
				table.insert(ge, cmd)
			end,
		},
	}, { __index = _G })
	local chunk = assert(loadfile("client/lua/vehicle/extensions/auto/careerConvoyVeh.lua"))
	setfenv(chunk, env)
	local veh = chunk()
	veh.jobBreakDown(true, { engine = true })
	local all = table.concat(calls, ", ")
	check(
		all == "engine off, gear 0, parkingbrake 1, ignition 2, hazard true, flat",
		"breakdown: engine off, ignition on, neutral, parking brake on, hazard lights, flat tire (" .. all .. ")"
	)
	check(ge[#ge]:find("careerConvoy_towJobs.onJobBrokenDown%(80, 1234%.5%)"), "reports the damage so far")
	veh.jobReportDamage()
	check(ge[#ge]:find("onJobDamage%(80, 1234%.5%)"), "reports the damage at the drop-off")
	-- other faults: the engine keeps running, the windshield and tail lights break
	local broken = {}
	env.beamstate.onBeamDeformed = function(cid)
		table.insert(broken, cid)
	end
	env.v = {
		data = {
			beams = {
				{ cid = 1, deformGroup = "windshield_break" },
				{ cid = 2, deformGroup = "tailgatelight_R" },
				{ cid = 3, deformGroup = "headlight_L" },
				{ cid = 4 },
			},
		},
	}
	calls = {}
	veh.jobBreakDown(false, { windshield = true })
	all = table.concat(calls, ", ")
	check(
		all == "gear 0, parkingbrake 1, ignition 2, hazard true" and #broken == 1 and broken[1] == 1,
		"broken windshield: the engine keeps running, only the windshield breaks; ignition and hazard lights on ("
			.. all
			.. ")"
	)
	-- the game turns the ignition off right after the spawn: ignition and hazard lights on again
	local values = env.electrics.values
	values.ignitionLevel, values.hazard_enabled = 2, 1
	calls = {}
	veh.updateGFX(0.1)
	check(#calls == 0, "ignition and hazard lights on: left alone (the blinking isn't restarted)")
	values.ignitionLevel, values.hazard_enabled = 0, 0
	veh.updateGFX(0.1)
	check(table.concat(calls, ", ") == "ignition 2, hazard true", "turned off by the game: on again")
	for _ = 1, 110 do
		veh.updateGFX(0.1)
	end
	calls = {}
	veh.updateGFX(0.1)
	check(#calls == 0, "after 10 s: the player may turn them off")
	veh.onReset()
	veh.updateGFX(0.1)
	check(table.concat(calls, ", ") == "ignition 2, hazard true", "after a reset: on again")
	broken = {}
	veh.jobBreakDown(false, { taillights = true })
	check(#broken == 1 and broken[1] == 2, "broken tail lights: only the tail lights break")
	-- powertrain faults: clutch, gearbox, radiator, oil pan
	local tracked, leaks = {}, {}
	env.damageTracker = {
		setDamage = function(group, name, value)
			tracked[group .. "." .. name] = value
		end,
	}
	local engine = {
		type = "combustionEngine",
		name = "mainEngine",
		disable = function()
			table.insert(calls, "engine off")
		end,
		thermals = {
			applyDeformGroupDamageRadiator = function(x)
				leaks.radiator = x
			end,
			applyDeformGroupDamageOilpan = function(x)
				leaks.oilpan = x
			end,
		},
	}
	local clutch = { type = "frictionClutch", name = "clutch", damageLockTorqueCoef = 1 }
	local gearbox = {
		type = "manualGearbox",
		name = "gearbox",
		onBreak = function(self)
			self.isBroken = true
		end,
	}
	local devices = { engine, clutch, gearbox, { type = "electricMotor", name = "rearMotor" } }
	env.powertrain = {
		getDevices = function()
			return devices
		end,
	}
	calls = {}
	veh.jobBreakDown(false, { clutch = true })
	check(
		clutch.damageLockTorqueCoef < 0.1
			and clutch.clutchPermanentlyDamaged
			and not gearbox.isBroken
			and tracked["powertrain.clutch"]
			and not table.concat(calls, ", "):find("engine off"),
		"broken clutch: it no longer grips, the gearbox and engine stay whole"
	)
	veh.jobBreakDown(false, { gearbox = true })
	check(gearbox.isBroken and tracked["powertrain.gearbox"], "broken gearbox: the game's own break")
	gearbox.isBroken, devices = false, { engine, gearbox }
	veh.jobBreakDown(false, { clutch = true })
	check(gearbox.isBroken, "no friction clutch (automatic): the gearbox breaks instead")
	local thermals = engine.thermals
	thermals.coolantTemperature, thermals.engineBlockTemperature = 60, 60
	thermals.cylinderWallTemperature, thermals.oilTemperature = 60, 130
	veh.updateGFX(0.1)
	check(thermals.coolantTemperature == 60, "a whole radiator: the engine isn't warmed")
	veh.jobBreakDown(false, { radiator = true })
	check(leaks.radiator and leaks.radiator > 0 and not leaks.oilpan, "broken radiator: only the coolant leaks")
	veh.updateGFX(0.1)
	check(
		thermals.coolantTemperature >= 95
			and thermals.engineBlockTemperature == thermals.coolantTemperature
			and thermals.cylinderWallTemperature == thermals.coolantTemperature
			and thermals.oilTemperature == 130,
		"broken radiator: the engine is kept hot so it steams (never cooled down)"
	)
	veh.jobCoolDown()
	thermals.coolantTemperature = 60
	veh.updateGFX(0.1)
	check(thermals.coolantTemperature == 60, "the player is there: the engine cools down")
	veh.jobBreakDown(false, { radiator = true })
	veh.onReset()
	thermals.coolantTemperature = 60
	veh.updateGFX(0.1)
	check(thermals.coolantTemperature == 60, "after a reset: no longer kept hot")
	veh.jobBreakDown(false, { oilpan = true })
	check(
		leaks.oilpan and leaks.oilpan > 0 and not table.concat(calls, ", "):find("engine off"),
		"oil leak: the oil leaks, the engine keeps running"
	)
	env.damageTracker = nil
	env.beamstate.onBeamDeformed, env.v = nil, nil
	env.powertrain, env.controller, env.electrics = nil, nil, nil
	calls = {}
	local ok = pcall(veh.jobBreakDown, false)
	check(ok and table.concat(calls, ", ") == "parkingbrake 1", "missing parts of a vehicle: breaks down without them")
end)();

--== 11. Ropes on two vehicles: the anchor on a vehicle, straps =====================
-- vehicle side: a roped car pulled by an anchor that drives off; the anchor vehicle's hitch and pull
(function()
	local function vec(x, y, z)
		return { x = x, y = y, z = z }
	end
	-- the roped car: rigid, 2 t, 20 nodes like in 7b4
	local body = { p = vec(0, 0, 0), v = vec(0, 0, 0), f = vec(0, 0, 0), ge = {} }
	local nodes, rel = {}, {}
	for i = 0, 19 do
		local heavy = i < 10
		nodes[i] = { cid = i }
		rel[i] = { x = (i % 5) - 2, y = (i % 2) * 1.6 - 0.8, z = heavy and 0.3 or 1.2, m = heavy and 180 or 20 }
	end
	local env = setmetatable({
		v = { data = { nodes = nodes } },
		vec3 = vec,
		enablePhysicsStepHook = function() end,
		obj = {
			getNodeMass = function(_, cid)
				return rel[cid].m
			end,
			getAbsNodePosition = function(_, cid)
				return vec(body.p.x + rel[cid].x, body.p.y + rel[cid].y, body.p.z + rel[cid].z)
			end,
			getNodeVelocityVector = function()
				return vec(body.v.x, body.v.y, body.v.z)
			end,
			getId = function()
				return 77
			end,
			queueGameEngineLua = function(_, cmd)
				table.insert(body.ge, cmd)
			end,
			applyForceVector = function(_, cid, f)
				body.f.x, body.f.y, body.f.z = body.f.x + f.x, body.f.y + f.y, body.f.z + f.z
			end,
			applyForceVectorTime = function(_, cid, f)
				body.f.x, body.f.y, body.f.z = body.f.x + f.x, body.f.y + f.y, body.f.z + f.z
			end,
		},
	}, { __index = _G })
	local chunk = assert(loadfile("client/lua/vehicle/extensions/auto/careerConvoyVeh.lua"))
	setfenv(chunk, env)
	local veh = chunk()
	local MASS, PHYS = 2000, 1 / 2000
	-- grip on the front (y = 0.8 side, chassis height); the anchor (a pickup's hitch) 5 m ahead in +y
	veh.ropeTie(1, 0, 0, 0.8, 0.3, 1, 60)
	local anchor = vec(0, 5.8, 0.3)
	local anchorV = vec(0, 0, 0)
	local function sendAnchor(moving)
		veh.ropeUpdate(1, anchor.x, anchor.y, anchor.z, 0, moving and 1 or 0, 1, 60, anchorV.x, anchorV.y, anchorV.z, 1)
	end
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
					if cmd:find("onRopeLost") then
						snapped = true
					end
					local fy = cmd:match("onRopePull%(77, 1, [-%d%.]+, ([-%d%.]+),")
					if fy then
						lastPull = tonumber(fy)
					end
				end
				body.ge = {}
				if veh.ropeInfo(1) then
					sendAnchor(false)
				end -- the GE side, every frame
			end
		end
	end
	run(0.5)
	check(
		veh.ropeInfo(1) and math.abs(veh.ropeInfo(1).length - 5) < 0.05 and math.abs(body.v.y) < 0.01,
		"anchor fixed to a vehicle: the rope pays out to its hitch, nothing moves yet"
	)
	-- the pickup drives off: speeds up to 3 m/s within 2 s
	for _ = 1, 20 do
		anchorV.y = math.min(3, anchorV.y + 0.15)
		run(0.1)
	end
	run(3)
	check(
		not snapped and math.abs(body.v.y - 3) < 0.2,
		string.format("towing: the car follows the pickup on the rope (%.2f m/s)", body.v.y)
	)
	check(peak < 4 * MASS * 9.81, string.format("drove off gently: no jolt that snaps the rope (peak %.0f N)", peak))
	check(
		lastPull and lastPull < -50,
		string.format("the pull on the pickup is reported every frame, towards the car (%.0f N)", lastPull or 0)
	)
	-- moving anchor + no extrapolation would jerk: between two messages the anchor moves on by itself
	local ax = veh.ropeInfo(1).ay
	veh.onPhysicsStep(PHYS * 100)
	check(veh.ropeInfo(1).ay > ax, "between two messages the anchor moves on at the vehicle's speed")
	-- a hard start from standstill to 8 m/s at once: the rope snaps
	anchorV.y = 8
	sendAnchor(false)
	run(1)
	check(snapped and veh.ropeInfo(1) == nil, "the pickup jerks off at 8 m/s: the rope snaps")
end)();
-- vehicle side: a strap on a car standing on a truck – pulled tight once when hooked on, it holds
-- the car while both drive, and never pulls before it is hooked on
(function()
	local function vec(x, y, z)
		return { x = x, y = y, z = z }
	end
	local body = { p = vec(0, 0, 0), v = vec(0, 0, 0), f = vec(0, 0, 0), ge = {} }
	local nodes, rel = {}, {}
	for i = 0, 19 do
		local heavy = i < 10
		nodes[i] = { cid = i }
		rel[i] = { x = (i % 5) - 2, y = (i % 2) * 1.6 - 0.8, z = heavy and 0.3 or 1.2, m = heavy and 180 or 20 }
	end
	local env = setmetatable({
		v = { data = { nodes = nodes } },
		vec3 = vec,
		enablePhysicsStepHook = function() end,
		obj = {
			getNodeMass = function(_, cid)
				return rel[cid].m
			end,
			getAbsNodePosition = function(_, cid)
				return vec(body.p.x + rel[cid].x, body.p.y + rel[cid].y, body.p.z + rel[cid].z)
			end,
			getNodeVelocityVector = function()
				return vec(body.v.x, body.v.y, body.v.z)
			end,
			getId = function()
				return 78
			end,
			queueGameEngineLua = function(_, cmd)
				table.insert(body.ge, cmd)
			end,
			applyForceVector = function(_, cid, f)
				body.f.x, body.f.y, body.f.z = body.f.x + f.x, body.f.y + f.y, body.f.z + f.z
			end,
			applyForceVectorTime = function(_, cid, f)
				body.f.x, body.f.y, body.f.z = body.f.x + f.x, body.f.y + f.y, body.f.z + f.z
			end,
		},
	}, { __index = _G })
	local chunk = assert(loadfile("client/lua/vehicle/extensions/auto/careerConvoyVeh.lua"))
	setfenv(chunk, env)
	local veh = chunk()
	local WEIGHT, PHYS = 2000 * 9.81, 1 / 2000
	-- two ropes on one vehicle at once: a strap (rope 3) and a tow rope (rope 4)
	check(veh.ropeTieNode(3, 1, 0) and veh.ropeInfo(3).kind == 1, "a strap is tied at the node it is given")
	check((body.ge[#body.ge] or ""):find("careerConvoy_rope.onRopeTied%(78, 3, "), "... and reported with its rope id")
	veh.ropeTie(4, 0, 2, 0.8, 1.2, 1, 60)
	check(veh.ropeInfo(3) and veh.ropeInfo(4) and veh.ropeInfo(4).kind == 0, "a vehicle holds several ropes at once")
	veh.ropeRelease(4)
	check(veh.ropeInfo(3) and not veh.ropeInfo(4), "removing one leaves the other")
	-- not hooked on yet: no pull, but it reports (the GE side's watchdog waits for that)
	body.f, body.ge = vec(0, 0, 0), {}
	veh.onPhysicsStep(PHYS)
	veh.updateGFX(0.2)
	check(
		body.f.z == 0 and (body.ge[#body.ge] or ""):find("onRopeState%(78, 3, "),
		"a strap not hooked on: no pull, it reports anyway"
	)
	-- hooked on 1 m below its corner (the truck's deck), the truck standing
	local corner = rel[0]
	local anchor = vec(corner.x, corner.y, corner.z - 1)
	veh.ropeUpdate(3, anchor.x, anchor.y, anchor.z, -1, 1, 1, 60, 0, 0, 0, 1)
	body.f = vec(0, 0, 0)
	veh.onPhysicsStep(PHYS)
	check(
		veh.ropeInfo(3).winch == 0 and math.abs(veh.ropeInfo(3).length - 0.988) < 1e-6,
		string.format("hooked on: pulled tight by 1.2 cm, never pays out (%.3f m)", veh.ropeInfo(3).length)
	)
	check(
		body.f.z < -0.25 * WEIGHT and body.f.z > -0.35 * WEIGHT,
		string.format("a tight strap pulls the car down with about a third of its weight (%.0f N)", body.f.z)
	)
	-- both drive at 20 m/s; the GE side sends the anchor every frame, it moves on between messages
	body.v = vec(0, 20, 0)
	local lo, hi, lost = math.huge, 0, false
	for i = 1, 4000 do
		body.f = vec(0, 0, 0)
		veh.onPhysicsStep(PHYS)
		body.p.y = body.p.y + body.v.y * PHYS
		if i > 100 then
			lo, hi = math.min(lo, -body.f.z), math.max(hi, -body.f.z)
		end
		if i % 33 == 0 then
			veh.updateGFX(33 * PHYS)
			for _, cmd in ipairs(body.ge) do
				if cmd:find("onRopeLost") then
					lost = true
				end
			end
			body.ge = {}
			veh.ropeUpdate(3, anchor.x, body.p.y + corner.y, anchor.z, 0, 0, 1, 60, 0, 20, 0, 1)
		end
	end
	check(
		not lost and lo > 0.2 * WEIGHT and hi < 0.4 * WEIGHT,
		string.format("driving: the strap holds steady, no jolts (%.0f-%.0f N)", lo, hi)
	)
	-- Tighten: a slack strap (its anchor 10 cm closer) hauls in like a very weak winch until it holds
	-- the pull it was given (25 % of the weight), then it stands
	body.v = vec(0, 0, 0)
	local y = body.p.y + corner.y
	veh.ropeUpdate(3, anchor.x, y, anchor.z + 0.1, 1, 0, 0.1, 25, 0, 0, 0, 1)
	for i = 1, 2000 * 3 do
		body.f = vec(0, 0, 0)
		veh.onPhysicsStep(PHYS)
	end
	local tight = veh.ropeInfo(3)
	check(
		tight.length < 0.89 and -body.f.z > 0.2 * WEIGHT and -body.f.z < 0.3 * WEIGHT,
		string.format(
			"Tighten: hauled in until it holds a quarter of the weight (%.3f m, %.0f N)",
			tight.length,
			-body.f.z
		)
	)
	local held = tight.length
	for i = 1, 2000 do
		veh.onPhysicsStep(PHYS)
	end
	check(
		math.abs(veh.ropeInfo(3).length - held) < 0.002,
		"... then the weak winch stalls and the strap stays that tight"
	)
	veh.ropeUpdate(3, anchor.x, y, anchor.z + 0.1, 0, 0, 0.1, 25, 0, 0, 0, 1)
	for i = 1, 200 do
		veh.onPhysicsStep(PHYS)
	end
	check(math.abs(veh.ropeInfo(3).length - held) < 0.002, "Tighten over: the strap keeps its length")
	-- a vehicle reset drops every rope
	body.ge = {}
	veh.onReset()
	check(
		veh.ropeInfo(3) == nil and (body.ge[1] or ""):find("onRopeLost%(78, 3, 1%)"),
		"reset: the strap comes off and says so"
	)
end)();
-- vehicle side: holding the other end (where it would hook on, hooking on by request, the pull,
-- several ropes at once)
(function()
	local nodes = { [0] = { cid = 0 }, { cid = 1 }, { cid = 2, couplerTag = "tow_hitch" }, { cid = 3 }, { cid = 4 } }
	local pos = {
		[0] = { x = 0, y = 0, z = 0 },
		{ x = 0, y = -2, z = 0.5 },
		{ x = 0, y = -2.6, z = 0.4 },
		{ x = 0, y = 2, z = 0.5 },
		{ x = 0, y = 2.35, z = 0.5 },
	}
	local forces, ge = {}, {}
	local env = setmetatable({
		v = { data = { nodes = nodes } },
		vec3 = function(x, y, z)
			return { x = x, y = y, z = z }
		end,
		enablePhysicsStepHook = function() end,
		obj = {
			-- node 4 is a light one (a mirror)
			getNodeMass = function(_, cid)
				return cid == 4 and 1 or 50
			end,
			getAbsNodePosition = function(_, cid)
				return pos[cid]
			end,
			getId = function()
				return 5
			end,
			queueGameEngineLua = function(_, cmd)
				table.insert(ge, cmd)
			end,
			applyForceVector = function(_, cid, f)
				table.insert(forces, f)
			end,
		},
	}, { __index = _G })
	local chunk = assert(loadfile("client/lua/vehicle/extensions/auto/careerConvoyVeh.lua"))
	setfenv(chunk, env)
	local veh = chunk()
	local function said(pattern)
		for _, cmd in ipairs(ge) do
			if cmd:find(pattern) then
				return true
			end
		end
		return false
	end
	-- 3 m away: the hitch is reported for the rings, no hook point
	veh.anchorNear(1, 0, -5.6, 0.4)
	check(
		said('onAnchorNear%(5, 1, "2", %-1, 0%)') and veh.anchorInfo(1) == nil,
		"anchor 3 m from the hitch: shown, no hook point"
	)
	-- 0.5 m from the hitch: that's the hook point, but nothing hooks on by itself
	ge = {}
	veh.anchorNear(1, 0, -3.1, 0.4)
	check(
		said('onAnchorNear%(5, 1, "2", 2, 1%)') and veh.anchorInfo(1) == nil and not said("onAnchorNode"),
		"anchor 0.5 m from the tow hitch: it is the hook point; nothing hooks on by itself"
	)
	-- no hitch near: any sturdy point within 0.5 m; a light one (node 4) is passed over
	ge = {}
	veh.anchorNear(1, 0, 2.6, 0.5)
	check(said('onAnchorNear%(5, 1, "2", 4, 0%)'), "only a light point within 0.5 m: that one, better than nothing")
	ge = {}
	veh.anchorNear(1, 0, 2.38, 0.5)
	check(
		said('onAnchorNear%(5, 1, "2", 3, 0%)'),
		"a sturdy point in reach wins over a closer light one (mirror, panel)"
	)
	ge = {}
	veh.anchorNear(1, 0, 6, 0.5)
	check(said('onAnchorNear%(5, 1, "", %-1, 0%)'), "nothing within 0.5 m: no hook point")
	-- hooked on by request, two ropes at once
	ge = {}
	check(
		veh.anchorHook(1, 3) and said("onAnchorNode%(5, 1, 3, 0%)") and veh.anchorInfo(1).node == 3,
		"hook on: rope 1 on node 3"
	)
	check(veh.anchorHook(2, 2) and said("onAnchorNode%(5, 2, 2, 1%)"), "rope 2 on the tow hitch, at the same time")
	check(not veh.anchorHook(3, 99), "a node the vehicle doesn't have: nothing")
	veh.anchorPull(1, 0, -1000, 0)
	veh.anchorPull(2, 0, -500, 0)
	forces = {}
	veh.onPhysicsStep(1 / 2000)
	local fy = 0
	for _, f in ipairs(forces) do
		fy = fy + f.y
	end
	check(
		math.abs(fy + 1500) < 1e-6 and #forces >= 4,
		"both ropes' pull is applied to the vehicle, spread over its nodes"
	)
	veh.updateGFX(0.3)
	forces = {}
	veh.onPhysicsStep(1 / 2000)
	check(#forces == 0, "no new pull for 0.25 s: it stops by itself")
	veh.anchorPull(1, 0, -1000, 0)
	veh.anchorPull(2, 0, -500, 0)
	veh.anchorRelease(1)
	forces = {}
	veh.onPhysicsStep(1 / 2000)
	fy = 0
	for _, f in ipairs(forces) do
		fy = fy + f.y
	end
	check(
		veh.anchorInfo(1) == nil and veh.anchorInfo(2) and math.abs(fy + 500) < 1e-6,
		"rope 1 released: only rope 2 pulls"
	)
end)();
-- vehicle side: Strap down – the load's corners, and the points below them on the truck
(function()
	local function vehicleEnv(id, nodeList, masses, refs, ge)
		local nodes, pos = {}, {}
		for i, n in ipairs(nodeList) do
			nodes[i - 1] = { cid = i - 1 }
			pos[i - 1] = { x = n[1], y = n[2], z = n[3] }
		end
		local env = setmetatable({
			v = { data = { nodes = nodes, refNodes = refs and { [0] = refs } or nil } },
			vec3 = function(x, y, z)
				return { x = x, y = y, z = z }
			end,
			obj = {
				getNodeMass = function(_, cid)
					return masses and masses[cid] or 20
				end,
				getAbsNodePosition = function(_, cid)
					return pos[cid]
				end,
				getId = function()
					return id
				end,
				queueGameEngineLua = function(_, cmd)
					table.insert(ge, cmd)
				end,
			},
		}, { __index = _G })
		local chunk = assert(loadfile("client/lua/vehicle/extensions/auto/careerConvoyVeh.lua"))
		setfenv(chunk, env)
		return chunk()
	end
	-- the car, facing +y: a box from x -0.9..0.9, y -2..2, z 1..2.2 (on a deck at z = 0.9); nodes
	-- 0-2 are the reference nodes (ref, back, left), 3-10 the corners low and high, 11 a light one
	-- sticking out at the front left bottom (a spoiler)
	local ge = {}
	local car = vehicleEnv(70, {
		{ 0, 0, 1.5 },
		{ 0, -1, 1.5 },
		{ -1, 0, 1.5 },
		{ -0.9, 2, 1 },
		{ 0.9, 2, 1 },
		{ -0.9, -2, 1 },
		{ 0.9, -2, 1 },
		{ -0.9, 2, 2.2 },
		{ 0.9, 2, 2.2 },
		{ -0.9, -2, 2.2 },
		{ 0.9, -2, 2.2 },
		{ -1, 2.3, 1 },
	}, { [11] = 1 }, { ref = 0, back = 1, left = 2 }, ge)
	car.strapCorners(7)
	local list = (ge[1] or ""):match('onStrapCorners%(70, 7, "(.-)"%)')
	local cids = {}
	for cid in tostring(list):gmatch("(%d+),[-%d%.]+,[-%d%.]+,[-%d%.]+") do
		table.insert(cids, tonumber(cid))
	end
	check(
		ge[1] and ge[1]:find("^if careerConvoy_straps then") and table.concat(cids, ",") == "3,4,5,6",
		"the car names its four low corners: front left, front right, back left, back right (" .. tostring(list) .. ")"
	)
	-- no reference nodes: no corners
	ge = {}
	vehicleEnv(71, { { 0, 0, 0 } }, nil, nil, ge).strapCorners(8)
	check((ge[1] or ""):find('onStrapCorners%(71, 8, ""%)'), "no reference nodes: no corners, it says so")
	-- the truck: deck nodes at z = 0.9 below the corners, one far away, one above the car
	ge = {}
	local truck = vehicleEnv(
		72,
		{ { -0.9, 2, 0.9 }, { 0.9, 2.2, 0.85 }, { -1, -1.9, 0.9 }, { 5, 5, 0.9 }, { 0.9, -2, 3 } },
		nil,
		nil,
		ge
	)
	truck.hookBelow(7, "-0.9,2,1;0.9,2,1;-0.9,-2,1;0.9,-2,1")
	check(
		(ge[1] or ""):find('onHookBelow%(72, 7, "1,0,0%.100;2,1,0%.250;3,2,0%.173;4,2,1%.905"%)'),
		"the truck names the nearest point below each corner; the one above the car and the far one don't count: "
			.. tostring(ge[1])
	)
	for k in pairs(ge) do
		ge[k] = nil
	end
	truck.hookBelow(9, "20,20,1")
	check((ge[1] or ""):find('onHookBelow%(72, 9, ""%)'), "a corner with nothing in reach: no answer for it")
end)();
-- GE side: the anchor near a vehicle shows where it would hook on; "Hook on" hooks it on there, it
-- follows the vehicle, the pull goes on to it; "Unhook"
(function()
	resetWorld()
	installCareer()
	extensions.hook("onWorldReadyState", 2)
	local cfgA = json.decode(json.encode(config))
	cfgA.allowRopes, cfgA.winchSpeed, cfgA.winchStrength = true, 1, 150
	handlers.sc_config(json.encode(cfgA))
	update()
	_G.ColorF = setmetatable({}, {
		__call = function(_, r, g, b, a)
			return { r = r, g = g, b = b, a = a }
		end,
	})
	_G.vec3 = setmetatable({}, {
		__call = function(_, x, y, z)
			return { x = x, y = y, z = z }
		end,
	})
	local drawn = {}
	_G.debugDrawer = {
		drawLine = function(_, p1, p2, c)
			table.insert(drawn, { p1 = p1, p2 = p2, c = c })
		end,
	}
	local function placed(id, x, y, z, remote, jbeam)
		local v = addVehicle(id, (remote and "7-" or "0-") .. id, not remote, jbeam)
		v.p = { x = x, y = y, z = z }
		v.vel = { x = 0, y = 0, z = 0 }
		v.getPosition = function(self)
			return self.p
		end
		v.getVelocity = function(self)
			return self.vel
		end
		v.getNodePosition = function(self, cid)
			return cid == 2 and { x = 0, y = -2.6, z = 0.4 } or { x = 0, y = 0, z = 0 }
		end
		return v
	end
	local function lastCall(v, fn)
		for i = #v.lua, 1, -1 do
			local args = v.lua[i]:match("careerConvoyVeh%." .. fn .. "%(([^)]*)%)")
			if args then
				local nums = {}
				for n in args:gmatch("[-%d%.]+") do
					table.insert(nums, tonumber(n))
				end
				return nums
			end
		end
	end
	-- frames, with the roped car reporting like in the game (otherwise the watchdog drops the rope)
	local function frames(n, each)
		for _ = 1, n do
			if careerConvoy_tow.isHolding() then
				careerConvoy_rope.onRopeState(60, rid(), 0, 1, 0.5, 0, 1, 7)
			end
			if each then
				each()
			end
			extensions.hook("onUpdate", 1 / 60, 1 / 60)
		end
	end
	_G.core_camera = {
		getPosition = function()
			return { x = 0, y = -10, z = 2 }
		end,
		getForward = function()
			return { x = 0, y = 1, z = 0 }
		end,
	}
	local car = placed(60, 0, 0, 0.5)
	local pickup = placed(61, 0, 10, 0.5)
	local remote = placed(62, 0, 9, 0.5, true)
	local walker = placed(63, 0, 9.5, 0, false, "unicycle")
	check(careerConvoy_tow.uiAttachVehicle(60), "rope on the car")
	careerConvoy_rope.onRopeTied(60, rid(), 5, 0, 1, 0.5, 7)
	frames(15)
	check(lastCall(pickup, "anchorNear") == nil, "the anchor far from other vehicles: nobody is asked")
	-- the anchor near the pickup's hitch (it sits at y = 7.4): the pickup is asked, the others not
	careerConvoy_tow.rope().target = { x = 0, y = 7.7, z = 0.9 }
	frames(15)
	local ask = lastCall(pickup, "anchorNear")
	check(ask and ask[1] == rid() and ask[3] == 7.7, "the anchor near the pickup: it is asked where it would hook on")
	check(
		lastCall(car, "anchorNear") == nil
			and lastCall(remote, "anchorNear") == nil
			and lastCall(walker, "anchorNear") == nil,
		"not asked: the roped car, another player's vehicle, a player on foot"
	)
	check(careerConvoy_tow.appState().hookOn == nil, "no answer yet: no Hook on")
	-- the pickup answers: its hitch is the hook point – a green ring there, a dashed line to it
	careerConvoy_rope.onAnchorNear(61, rid(), "2", 2, 1)
	drawn = {}
	frames(1)
	local ringAt, guide = false, 0
	for _, d in ipairs(drawn) do
		if math.abs(d.p1.y - 7.4) < 0.3 and math.abs(d.p1.z - 0.9) < 0.3 and d.c.g > 0.9 then
			ringAt = true
		end
		if math.abs(d.p1.x) < 1e-6 and math.abs(d.p2.x) < 1e-6 and d.p1.y > 7.39 and d.p2.y < 7.71 and d.c.g > 0.9 then
			guide = guide + 1
		end
	end
	check(ringAt and guide >= 1, "the hook point: a green ring on the hitch and a dashed line from the anchor")
	local st = careerConvoy_tow.appState()
	check(
		st.hookOn and st.hookOn.hitch == true and st.hookOn.vehicle == "Pickup" and st.anchorVehicle == nil,
		"the app offers Hook on (onto the pickup's tow hitch)"
	)
	frames(30, function()
		careerConvoy_rope.onAnchorNear(61, rid(), "2", 2, 1)
	end)
	check(
		careerConvoy_tow.appState().anchorVehicle == nil and lastCall(pickup, "anchorHook") == nil,
		"it doesn't hook on by itself"
	)
	-- an answer nobody asked for is refused
	careerConvoy_rope.onAnchorNode(61, rid(), 2, 1)
	check(
		careerConvoy_tow.appState().anchorVehicle == nil and pickup.lua[#pickup.lua]:find("anchorRelease"),
		"an unasked hook-on is refused"
	)
	-- Hook on
	check(careerConvoy_tow.uiHookOn(), "Hook on")
	local hook = lastCall(pickup, "anchorHook")
	check(hook and hook[1] == rid() and hook[2] == 2, "Hook on: the pickup is told to take the rope at its hitch")
	local other = placed(64, 3, 12, 0.5)
	careerConvoy_rope.onAnchorNode(64, rid(), 2, 1)
	check(
		careerConvoy_tow.appState().anchorVehicle == nil and other.lua[#other.lua]:find("anchorRelease"),
		"another vehicle's answer is refused"
	)
	careerConvoy_rope.onAnchorNode(61, rid(), 2, 1)
	st = careerConvoy_tow.appState()
	check(
		st.anchorVehicle == "Pickup" and st.anchorHitch == true and st.hookOn == nil,
		"hooked onto the pickup's tow hitch"
	)
	-- it follows the pickup, with the speed of the hitch
	frames(1, function()
		pickup.p = { x = 0, y = pickup.p.y + 2 / 60, z = 0.5 }
	end)
	frames(3, function()
		pickup.p = { x = 0, y = pickup.p.y + 2 / 60, z = 0.5 }
	end)
	local a = lastCall(car, "ropeUpdate")
	check(
		a and a[1] == rid() and math.abs(a[3] - (pickup.p.y - 2.6)) < 0.05 and math.abs(a[10] - 2) < 0.01 and a[12] == 1,
		string.format("the anchor rides on the hitch, with its speed (%.2f m/s), every frame", a and a[10] or -1)
	)
	local before = #car.lua
	frames(1)
	check(#car.lua == before + 1, "anchor on a vehicle: sent every frame")
	-- the pickup turns: the hitch moves sideways though the pickup's own speed doesn't say so
	pickup.vel = { x = 0, y = 2, z = 0 }
	frames(3, function()
		pickup.p = { x = pickup.p.x + 1 / 60, y = pickup.p.y + 2 / 60, z = 0.5 }
	end)
	a = lastCall(car, "ropeUpdate")
	check(math.abs(a[9] - 1) < 0.01, "the hitch's own speed, from its movement (turning)")
	-- a teleport is not a speed
	frames(1, function()
		pickup.p = { x = 0, y = pickup.p.y + 50, z = 0.5 }
	end)
	a = lastCall(car, "ropeUpdate")
	check(math.abs(a[10] - 2) < 0.01 and math.abs(a[9]) < 0.01, "the hitch jumped: the pickup's own speed instead")
	careerConvoy_rope.onRopePull(60, rid(), 0, -1500, 0)
	local pull = lastCall(pickup, "anchorPull")
	check(pull and pull[1] == rid() and pull[3] == -1500, "the rope's pull goes on to the pickup")
	-- hooked on, the remote doesn't move it
	local hookedAt = careerConvoy_tow.rope().target
	careerConvoy_tow.uiNudge(-1, 0, 0)
	frames(30)
	careerConvoy_tow.uiNudgeStop()
	check(
		careerConvoy_tow.appState().anchorVehicle and not careerConvoy_tow.appState().moving,
		"hooked on: the arrows do nothing"
	)
	-- Unhook: the anchor stays where it is, the pickup is told
	careerConvoy_tow.uiUnhook()
	local told = pickup.lua[#pickup.lua]:find("anchorRelease") ~= nil
	frames(1)
	a = lastCall(car, "ropeUpdate")
	check(told and a[12] == 0 and a[10] == 0, "Unhook: the pickup is told, the anchor no longer rides on it")
	check(
		careerConvoy_tow.appState().anchorVehicle == nil and math.abs(a[3] - careerConvoy_tow.rope().target.y) < 0.01,
		"unhooked: it rests in the world"
	)
	-- the remote moves it again
	careerConvoy_tow.uiNudge(-1, 0, 0)
	frames(30)
	careerConvoy_tow.uiNudgeStop()
	check(careerConvoy_tow.rope().target.y < hookedAt.y - 0.3, "unhooked: the arrows move it again")
	-- hooked on again, then the pickup is reset: the anchor stays where it was
	careerConvoy_tow.rope().target = { x = 0, y = pickup.p.y - 2.4, z = 0.9 }
	frames(15)
	careerConvoy_rope.onAnchorNear(61, rid(), "2", 2, 1)
	careerConvoy_tow.uiHookOn()
	careerConvoy_rope.onAnchorNode(61, rid(), 2, 1)
	check(careerConvoy_tow.appState().anchorVehicle, "hooked on again")
	extensions.hook("onVehicleResetted", 61)
	check(
		careerConvoy_tow.appState().anchorVehicle == nil and pickup.lua[#pickup.lua]:find("anchorRelease"),
		"the pickup is reset: the anchor comes off it and stays in the world"
	)
	careerConvoy_tow.uiRelease()
	check(not careerConvoy_tow.isHolding(), "rope removed")
	_G.core_camera, _G.debugDrawer = nil, nil
end)();
-- GE side: the Straps app – Strap down, a strap by hand, the list
(function()
	resetWorld()
	installCareer()
	extensions.hook("onWorldReadyState", 2)
	local cfgS = json.decode(json.encode(config))
	cfgS.allowRopes = true
	handlers.sc_config(json.encode(cfgS))
	update()
	_G.ColorF = setmetatable({}, {
		__call = function(_, r, g, b, a)
			return { r = r, g = g, b = b, a = a }
		end,
	})
	_G.vec3 = setmetatable({}, {
		__call = function(_, x, y, z)
			return { x = x, y = y, z = z }
		end,
	})
	local drawn = {}
	_G.debugDrawer = {
		drawLine = function(_, p1, p2, c)
			table.insert(drawn, { p1 = p1, p2 = p2, c = c })
		end,
	}
	local messages = {}
	local realToast = careerConvoy_util.toast
	careerConvoy_util.toast = function(_, msg)
		table.insert(messages, msg)
	end
	-- truck nodes 11-14 on its deck (z = 0.9), relative to its position
	local deck = {
		[11] = { x = -0.9, y = 2, z = 0.4 },
		[12] = { x = 0.9, y = 2, z = 0.4 },
		[13] = { x = -0.9, y = -2, z = 0.4 },
		[14] = { x = 0.9, y = -2, z = 0.4 },
		[20] = { x = 0, y = -8, z = 0.4 },
	}
	local function placed(id, x, y, z, remote, jbeam, nodes)
		local v = addVehicle(id, (remote and "7-" or "0-") .. id, not remote, jbeam)
		v.p = { x = x, y = y, z = z }
		v.getPosition = function(self)
			return self.p
		end
		v.getVelocity = function()
			return { x = 0, y = 0, z = 0 }
		end
		v.getNodePosition = function(_, cid)
			return (nodes or {})[cid] or { x = 0, y = 0, z = 0 }
		end
		return v
	end
	local function calls(v, fn)
		local out = {}
		for _, cmd in ipairs(v.lua) do
			local args = cmd:match("careerConvoyVeh%." .. fn .. "%((.*)%) end$")
			if args then
				local nums = {}
				for n in args:gmatch("[-%d%.]+") do
					table.insert(nums, tonumber(n))
				end
				table.insert(out, { nums = nums, text = args })
			end
		end
		return out
	end
	local function last(v, fn)
		local all = calls(v, fn)
		return all[#all]
	end
	local function frames(n)
		for _ = 1, n do
			for _, r in ipairs(careerConvoy_rope.list()) do
				careerConvoy_rope.onRopeState(r.veh, r.id, 0, 0, 1, 0, 0, 1, 0.1)
			end
			extensions.hook("onUpdate", 1 / 60, 1 / 60)
		end
	end
	_G.core_camera = {
		getPosition = function()
			return { x = 0, y = -10, z = 3 }
		end,
		getForward = function()
			return { x = 0, y = 1, z = -0.15 }
		end,
	}
	local car = placed(70, 0, 0, 1.5)
	local truck = placed(71, 0, 0, 0.5, false, nil, deck)
	local remote = placed(72, 0, 3, 0.5, true)
	local walker = placed(73, 2, 0, 0, false, "unicycle")
	local straps = careerConvoy_straps
	local app
	for _, x in ipairs(careerConvoy_phone.state().apps) do
		if x.id == "straps" then
			app = x
		end
	end
	check(app and app.title == "Straps" and app.icon == "straps", "the Straps app is on the phone")
	careerConvoy_phone.uiOpenApp("straps")
	-- Strap down: the car you look at names its corners
	check(straps.uiStrapDown(), "Strap down")
	local ask = last(car, "strapCorners")
	check(ask and straps.appState().busy, "the car is asked for its corners")
	local req = ask.nums[1]
	straps.onStrapCorners(70, req, "1,-0.9,2,1;2,0.9,2,1;3,-0.9,-2,1;4,0.9,-2,1")
	local below = last(truck, "hookBelow")
	check(
		below and below.nums[1] == req and below.text:find('"%-0%.900,2%.000,1%.000;'),
		"the truck below is asked for points under them"
	)
	check(
		#calls(remote, "hookBelow") == 0 and #calls(walker, "hookBelow") == 0 and #calls(car, "hookBelow") == 0,
		"not asked: another player's vehicle, a player on foot, the car itself"
	)
	-- the truck answers for three corners: three straps, tied at the corners
	straps.onHookBelow(71, req, "1,11,0.1;2,12,0.1;3,13,0.1")
	local ties = calls(car, "ropeTieNode")
	check(
		#ties == 3 and ties[1].nums[2] == 1 and ties[1].nums[3] == 1 and ties[3].nums[3] == 3,
		"three straps tied at the corners that have a point below them"
	)
	check(messages[#messages] == "3 of 4 strapped" and not straps.appState().busy, "the player is told: 3 of 4")
	check(#straps.appState().straps == 0, "not hooked on yet: not in the list")
	-- tied: each is hooked onto its point on the truck
	for _, t in ipairs(ties) do
		careerConvoy_rope.onRopeTied(70, t.nums[1], 0, 0, 0, 1, t.nums[3])
	end
	local hooks = calls(truck, "anchorHook")
	check(
		#hooks == 3 and hooks[1].nums[1] == ties[1].nums[1] and hooks[1].nums[2] == 11,
		"each strap is hooked onto its point on the truck"
	)
	for _, h in ipairs(hooks) do
		careerConvoy_rope.onAnchorNode(71, h.nums[1], h.nums[2], 0)
	end
	local st = straps.appState()
	check(#st.straps == 3 and st.straps[1].n == 1 and st.straps[1].vehicle == "Pickup", "the list shows three straps")
	local before = #car.lua
	frames(1)
	local up = last(car, "ropeUpdate")
	check(#car.lua - before == 3 and up.nums[12] == 1, "hooked straps: their anchors go to the car every frame")
	-- drawn: yellow straps with a ratchet
	drawn = {}
	frames(1)
	local yellow = 0
	for _, d in ipairs(drawn) do
		if d.c.r > 0.95 and d.c.g > 0.7 and d.c.b < 0.3 then
			yellow = yellow + 1
		end
	end
	check(yellow >= 3, "the straps are drawn yellow (" .. yellow .. " lines)")
	-- not twice on the same car
	messages = {}
	check(not straps.uiStrapDown() and messages[1] == "Already strapped", "Strap down again: already strapped")
	-- the truck is reset: all straps come off, the player is told once
	messages = {}
	extensions.hook("onVehicleResetted", 71)
	check(
		#careerConvoy_rope.list() == 0 and #messages == 1 and messages[1]:find("straps off"),
		"truck reset: all straps off, one message"
	)
	-- nothing below the car: nothing strapped
	straps.uiStrapDown()
	req = last(car, "strapCorners").nums[1]
	straps.onStrapCorners(70, req, "1,-0.9,2,1;2,0.9,2,1")
	straps.onHookBelow(71, req, "")
	check(
		#careerConvoy_rope.list() == 0 and messages[#messages] == "Nothing below to strap to",
		"no points below: nothing strapped"
	)
	-- no answer from the car: given up after a moment
	straps.uiStrapDown()
	frames(40)
	check(
		not straps.appState().busy and messages[#messages] == "Can't strap this car",
		"no answer from the car: given up"
	)
	-- by hand: 1. aim at the car (a blue ball shows where), Here
	check(straps.uiAddStrap() and straps.appState().step == 1, "Add strap: step 1")
	frames(20)
	check(#calls(car, "tieProbe") >= 1, "step 1: the car you look at shows where the strap would be tied")
	check(straps.uiHere() and straps.appState().step == 2, "Here: the strap is tied to the car, step 2")
	local tie = last(car, "ropeTieRay")
	check(tie and tie.nums[2] == 1, "tied where you look, as a strap")
	local strapId = tie.nums[1]
	careerConvoy_rope.onRopeTied(70, strapId, 5, 0.9, 2, 1, 4)
	-- 2. the remote moves the strap's end; the car doesn't feel it until it is hooked on
	local updatesBefore = #calls(car, "ropeUpdate")
	local strapRope = careerConvoy_rope.get(strapId)
	check(strapRope.target and strapRope.target.z == 1, "the strap's end starts where it is tied")
	straps.uiNudge(0, 0, -1)
	frames(30)
	straps.uiNudgeStop()
	check(
		math.abs(strapRope.target.z - 0.5) < 0.02,
		string.format("hold Down: the end goes down (%.2f)", strapRope.target.z)
	)
	check(#calls(car, "ropeUpdate") == updatesBefore, "a loose strap end isn't sent to the car: it doesn't pull")
	check(
		#calls(truck, "anchorNear") >= 1 and #calls(car, "anchorNear") == 0,
		"the truck is asked where it would hook on, not the car"
	)
	straps.uiNudge(1, 0, 0)
	frames(400)
	straps.uiNudgeStop()
	local grip = careerConvoy_rope.gripNow(strapRope)
	check(careerConvoy_rope.distance(grip, strapRope.target) <= 3.01, "the end stays within 3 m of the car")
	messages = {}
	check(
		not straps.uiHookOn() and messages[1] == "Move it to your truck or trailer",
		"nowhere to hook on: Hook on says so"
	)
	-- next to the truck's deck: it shows where it would hook on
	strapRope.target = { x = 0.9, y = 2, z = 1.1 }
	careerConvoy_rope.onAnchorNear(71, strapId, "", 12, 0)
	st = straps.appState()
	check(st.step == 2 and st.hookOn and st.hookOn.hitch == false, "near the deck: Hook on is offered")
	check(straps.uiHookOn(), "Hook on")
	check(
		last(truck, "anchorHook").nums[1] == strapId and last(truck, "anchorHook").nums[2] == 12,
		"the strap hooks onto that point"
	)
	careerConvoy_rope.onAnchorNode(71, strapId, 12, 0)
	check(straps.appState().step == 0 and #straps.appState().straps == 1, "hooked on: done, the strap is in the list")
	frames(1)
	check(
		#calls(car, "ropeUpdate") > updatesBefore and last(car, "ropeUpdate").nums[5] == 0,
		"hooked on: the car feels it, no winch"
	)
	-- a strap's pull on the truck comes late (through the GE side): passed on smoothed, so it can't
	-- rock the trailer; the steady load gets through
	for _ = 1, 60 do
		careerConvoy_rope.onRopePull(70, strapId, 0, 0, -3000)
		extensions.hook("onUpdate", 1 / 60, 1 / 60)
	end
	check(math.abs(last(truck, "anchorPull").nums[4] + 3000) < 1, "a steady strap pull reaches the truck in full")
	careerConvoy_rope.onRopePull(70, strapId, 0, 0, -9000)
	local jolt = last(truck, "anchorPull").nums[4]
	check(
		jolt < -3000 and jolt > -3600,
		string.format("a sudden jolt reaches it only a little in one frame (%.0f N)", jolt)
	)
	-- the truck's speed for the strap is smoothed too: a shake of the deck doesn't come through
	for _ = 1, 60 do
		truck.p = { x = 0, y = truck.p.y + 2 / 60, z = 0.5 }
		frames(1)
	end
	check(math.abs(last(car, "ropeUpdate").nums[10] - 2) < 0.05, "the truck drives at 2 m/s: the strap's anchor too")
	truck.p = { x = 0, y = truck.p.y + 2 / 60, z = 0.55 }
	frames(1)
	local vz = last(car, "ropeUpdate").nums[11]
	check(
		vz > 0.2 and vz < 1.0,
		string.format("the deck jumps 5 cm in a frame (3 m/s): the anchor follows smoothed (%.2f m/s)", vz)
	)
	truck.p = { x = 0, y = truck.p.y, z = 0.5 }
	frames(60)
	-- Tighten: the straps haul in like a very weak winch until they are tight
	check(straps.uiTighten() and straps.appState().tightening, "Tighten")
	extensions.hook("onUpdate", 1 / 60, 1 / 60)
	local up = last(car, "ropeUpdate").nums
	check(up[5] == 1 and up[7] == 0.1 and up[8] == 25, "Tighten: winch on, slow and weak (0.1 m/s, 25 %)")
	careerConvoy_rope.onRopeState(70, strapId, 0, 0, 1, 1, 0, 1, 0.1)
	extensions.hook("onUpdate", 1 / 60, 1 / 60)
	extensions.hook("onUpdate", 1 / 60, 1 / 60)
	check(last(car, "ropeUpdate").nums[5] == 0 and not straps.appState().tightening, "tight: the strap is locked again")
	straps.uiTighten()
	frames(60 * 7)
	check(
		last(car, "ropeUpdate").nums[5] == 0 and not straps.appState().tightening,
		"never tight: Tighten stops after a few seconds"
	)
	-- Cancel in step 2 takes the half-done strap off again
	straps.uiAddStrap()
	frames(2)
	straps.uiHere()
	local second = last(car, "ropeTieRay").nums[1]
	straps.uiCancel()
	check(
		straps.appState().step == 0
			and last(car, "ropeRelease").nums[1] == second
			and careerConvoy_rope.get(second) == nil,
		"Cancel: the half-done strap comes off"
	)
	-- remove one, remove all
	straps.uiRemove(strapId)
	check(
		#straps.appState().straps == 0
			and last(car, "ropeRelease").nums[1] == strapId
			and last(truck, "anchorRelease").nums[1] == strapId,
		"remove a strap: both vehicles are told"
	)
	straps.uiStrapDown()
	req = last(car, "strapCorners").nums[1]
	straps.onStrapCorners(70, req, "1,-0.9,2,1;2,0.9,2,1;3,-0.9,-2,1;4,0.9,-2,1")
	straps.onHookBelow(71, req, "1,11,0.1;2,12,0.1;3,13,0.1;4,14,0.1")
	check(
		messages[#messages] == "Strapped down" and #careerConvoy_rope.list(careerConvoy_rope.STRAP) == 4,
		"four corners: strapped down"
	)
	straps.uiRemoveAll()
	check(#careerConvoy_rope.list() == 0, "Remove all")
	-- the tow rope and the straps live side by side: a car hauled up onto the truck is strapped down
	-- from the Tow app, onto the truck the rope is hooked on only
	local tow = careerConvoy_tow
	local other = placed(74, 3, 0, 0.5)
	check(tow.uiAttachVehicle(70), "tow rope on the car")
	local towId = tow.rope().id
	careerConvoy_rope.onRopeTied(70, towId, 0, 0, 2, 1.5, 5)
	check(not tow.appState().strapDown, "not hooked on yet: no Strap down")
	careerConvoy_rope.hook(tow.rope(), 71, 11)
	careerConvoy_rope.onAnchorNode(71, towId, 11, 0)
	tow.setWinch(1)
	frames(1)
	check(tow.rope().length == 1 and not tow.appState().strapDown, "winch hauling in: no Strap down")
	tow.setWinch(0)
	check(tow.appState().strapDown, "pulled up and stopped: Strap down")
	check(tow.uiStrapDown(), "Strap down from the Tow app")
	req = last(car, "strapCorners").nums[1]
	straps.onStrapCorners(70, req, "1,-0.9,2,1;2,0.9,2,1;3,-0.9,-2,1;4,0.9,-2,1")
	check(
		last(truck, "hookBelow").nums[1] == req and #calls(other, "hookBelow") == 0,
		"only the truck the rope is hooked on is asked"
	)
	straps.onHookBelow(71, req, "1,11,0.1;2,12,0.1;3,13,0.1;4,14,0.1")
	for _, t in ipairs(calls(car, "ropeTieNode")) do
		careerConvoy_rope.onRopeTied(70, t.nums[1], 0, 0, 0, 1, t.nums[3])
	end
	check(straps.isStrapped(70) and not tow.appState().strapDown, "strapped: the button is gone")
	-- the Straps app takes the tow rope off
	check(straps.appState().towRope, "Straps app: Remove rope")
	straps.uiRemoveRope()
	check(
		tow.rope() == nil and not straps.appState().towRope and #careerConvoy_rope.list(careerConvoy_rope.STRAP) == 4,
		"Remove rope: the rope is off, the straps stay"
	)
	straps.uiRemoveAll()
	careerConvoy_phone.uiCloseApp("straps")
	careerConvoy_util.toast = realToast
	_G.core_camera, _G.debugDrawer = nil, nil
end)();
-- the drop-off zone: a column standing on the ground (also on a slope), the rays only once
(function()
	local J = careerConvoy_jobs
	local getVeh = _G.getPlayerVehicle
	_G.getPlayerVehicle = nil
	_G.core_camera = {
		getPosition = function()
			return { x = 0, y = -30, z = 12 }
		end,
	}
	_G.ColorF = function(r, g, b, a)
		return { r = r, g = g, b = b, a = a }
	end
	_G.vec3 = setmetatable({}, {
		__call = function(_, x, y, z)
			return { x = x, y = y, z = z }
		end,
	})
	-- the ground rises 0.1 m for every m along x: 10 m at the zone's middle
	_G.ColorI = function() end
	local rays = 0
	_G.castRayStatic = function(from, dir)
		rays = rays + 1
		return from.z - (10 + from.x * 0.1)
	end
	local cylinders, texts = {}, {}
	_G.debugDrawer = {
		drawCylinder = function(_, a, b, r, c)
			table.insert(cylinders, { a = a, b = b, r = r, c = c })
		end,
		drawTextAdvanced = function(_, _, text)
			table.insert(texts, text)
		end,
	}
	J.drawDropOff({ x = 0, y = 0, z = 10 }, 12, "Shop")
	local wall = cylinders[1]
	check(
		wall.r == 12 and wall.a.z < 8.8 and wall.b.z > 12,
		"drop-off zone: the column reaches below the lowest ground"
	)
	local foot = cylinders[8] -- after the 7 shells: the ring at the foot, its first piece at x = 12
	check(
		math.abs(foot.a.x - 12) < 1e-6 and math.abs(foot.a.z - 11.25) < 1e-6,
		"drop-off zone: the ring at its foot lies on the ground"
	)
	check(wall.c.b == 1 and texts[1] == "Drop-off \194\183 Shop", "drop-off zone: blue, with the place's name")
	local first = rays
	cylinders, texts = {}, {}
	J.drawDropOff({ x = 0, y = 0, z = 10 }, 12, "Shop", 1.4)
	check(rays == first, "drop-off zone: the ground is looked for only once")
	check(cylinders[1].c.g == 0.9 and texts[1] == "Drop-off \194\183 2 s", "drop-off zone: green, counting down")
	local outside = cylinders[1].c.a
	_G.core_camera.getPosition = function()
		return { x = 1, y = 0, z = 12 }
	end
	cylinders = {}
	J.drawDropOff({ x = 0, y = 0, z = 10 }, 12, "Shop")
	check(cylinders[1].c.a < outside * 0.5, "drop-off zone: faint with the camera inside")
	_G.castRayStatic, _G.debugDrawer, _G.core_camera, _G.ColorI, _G.getPlayerVehicle = nil, nil, nil, nil, getVeh
end)()

print(string.format("Client: %d ok, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
