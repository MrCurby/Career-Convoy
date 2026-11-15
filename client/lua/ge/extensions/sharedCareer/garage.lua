-- SharedCareer :: Garage, Computer und Laufen im Multiplayer
--
-- 1. Doppelte Autos beim Tunen/Teile einbauen/Lackieren
--    Die Garage baut ein Auto mit core_vehicles.replaceVehicle(model, opt, dasAuto) neu.
--    BeamMP ersetzt replaceVehicle durch eine eigene Version, die das genannte Auto
--    ignoriert und stattdessen getPlayerVehicle(0) neu baut. Am Garagen-Computer ist man
--    aber zu Fuß -> der Fußgänger (oder ein anderes Auto) wird zur Kopie, zwei Autos
--    stecken ineinander. Lösung: für die Dauer des einen Aufrufs liefert getPlayerVehicle(0)
--    genau das Auto, das die Garage gemeint hat.
--
-- 2. Unsichtbarer Fußgänger
--    Die Karriere spawnt den Unicycle ohne Mesh (im Singleplayer sieht einen ja keiner).
--    Im Multiplayer wird die sichtbare BeamMP-Variante genommen.
--
-- 3. Computermenü schließt sich von selbst
--    Das Menü schließt, wenn man >1 m von der Tür weg ist. Die Positions-Synchronisation
--    wackelt mehr als das. Der Radius wird für den Computer auf 25 m erweitert.
--    Außerdem wird man fürs Tunen/Teile/Lackieren ins angeklickte Auto gesetzt, weil
--    diese Menüs mit dem Auto arbeiten, in dem man sitzt.
--
-- 4. Computer aus der Nähe benutzen
--    Auf West Coast USA liefert der Mod vergrößerte Zonen der vier Werkstatt-Computer als
--    Kartendatei mit (client/levels/.../garage_interactions/items.level.json, erzeugt von
--    tools/zones/make_garage_zones.py aus dem BeamNG-Original). Die Zone reicht vom Computer
--    14 x 12 m in den Raum.
--    Zusätzlich (für andere Karten/Computer) vergrößert Abschnitt 4 unten Zonen im laufenden
--    Spiel auf mindestens client.computerAccessRange Meter.
--
-- Karriere-Module werden bei jedem Start neu geladen, deshalb wird jede Sekunde geprüft,
-- ob die Wrapper noch auf der aktuellen Tabelle sitzen.

local M = {}

local U

local CAREER_UNICYCLE = "vehicles/unicycle/without_mesh.pc"
local MP_UNICYCLE = "vehicles/unicycle/beammp_default.pc"
local COMPUTER_RANGE = 25
local CHECK_EVERY = 1

local sinceCheck = CHECK_EVERY
local rebuilding = false

--== 1. Garage-Neubau ==========================================================

local function ownCarId(veh)
	if veh == nil then return nil end
	local ok, id = pcall(function() return veh:getID() end)
	if not ok or type(id) ~= "number" then return nil end
	local mp = rawget(_G, "MPVehicleGE")
	if type(mp) ~= "table" or type(mp.isOwn) ~= "function" then return nil end
	if not mp.isOwn(id) then return nil end
	return id
end

-- Inventar-ID, wenn das Fahrzeug ein Auto aus der eigenen Karriere-Garage ist.
local function inventoryIdOf(veh)
	local inventory = career_modules_inventory
	if type(inventory) ~= "table" or type(inventory.getInventoryIdFromVehicleId) ~= "function" then return nil end
	local ok, id = pcall(function() return inventory.getInventoryIdFromVehicleId(veh:getID()) end)
	if ok then return id end
	return nil
end

local function makeReplaceVehicle(original)
	return function(modelName, opt, otherVeh, ...)
		-- Wir selbst stecken evtl. mehrfach in der Kette (BeamMP wickelt uns, wir wickeln
		-- BeamMP). Nur die äußerste Ebene macht etwas.
		if rebuilding or not U.isMP() then return original(modelName, opt, otherVeh, ...) end
		local id = ownCarId(otherVeh)
		if not id then
			if otherVeh ~= nil and inventoryIdOf(otherVeh) ~= nil then
				-- Ein Auto, das BeamMP nicht als unseres kennt: nicht anfassen, sonst entsteht
				-- eine Kopie, die die Garage nicht kennt.
				U.log("W", "garage", "refused to rebuild a vehicle that is not ours")
				U.toast("warning", "This car is not linked to you on the server and was not changed.", 8)
				return nil
			end
			return original(modelName, opt, otherVeh, ...)
		end
		local previous = rawget(_G, "getPlayerVehicle")
		local real = previous or getPlayerVehicle
		rawset(_G, "getPlayerVehicle", function(player, ...)
			if player == 0 then return otherVeh end
			return real(player, ...)
		end)
		rebuilding = true
		local results = U.pack(xpcall(original, debug.traceback, modelName, opt, otherVeh, ...))
		rebuilding = false
		rawset(_G, "getPlayerVehicle", previous)
		if not results[1] then
			U.log("E", "garage", "rebuild of vehicle " .. id .. " failed: " .. tostring(results[2]))
			error(results[2], 0)
		end
		return U.unpack(results, 2, results.n)
	end
end

--== 2. Sichtbarer Fußgänger ===================================================

local function makeSpawnNewVehicle(original)
	return function(modelName, opt, ...)
		if U.isMP() and modelName == "unicycle" and type(opt) == "table" and opt.config == CAREER_UNICYCLE
				and FS:fileExists(MP_UNICYCLE) then
			opt = deepcopy(opt)
			opt.config = MP_UNICYCLE
		end
		return original(modelName, opt, ...)
	end
end

--== 3. Computer-Reichweite ====================================================

local function withWideTether(fn, ...)
	local tether = career_modules_tether
	if type(tether) ~= "table" then return fn(...) end
	local door, sphere = tether.startDoorTether, tether.startSphereTether
	local function widen(start)
		if type(start) ~= "function" then return start end
		return function(target, range, ...)
			if type(range) == "number" and range < COMPUTER_RANGE then range = COMPUTER_RANGE end
			return start(target, range, ...)
		end
	end
	tether.startDoorTether, tether.startSphereTether = widen(door), widen(sphere)
	local results = U.pack(pcall(fn, ...))
	tether.startDoorTether, tether.startSphereTether = door, sphere
	if not results[1] then error(results[2], 0) end
	return U.unpack(results, 2, results.n)
end

-- Das Auto, für das zuletzt am Computer ein Knopf gedrückt wurde.
local clickedInventoryId = nil

local function makeOpenMenu(original)
	return function(...)
		clickedInventoryId = nil
		if not U.isMP() then return original(...) end
		return withWideTether(original, ...)
	end
end

local function makeButtonCallback(original)
	return function(buttonId, inventoryId, ...)
		clickedInventoryId = inventoryId
		return original(buttonId, inventoryId, ...)
	end
end

-- Tuning, Teile und Lackieren arbeiten mit dem Fahrzeug, in dem man sitzt. Am Computer
-- ist man zu Fuß, also setzen wir den Spieler ins angeklickte Auto.
local function enterMenuVehicle()
	if not U.isMP() then return end
	local inventory = career_modules_inventory
	local inventoryId = clickedInventoryId
	clickedInventoryId = nil
	if type(inventory) ~= "table" or not inventoryId then return end
	local vehId = inventory.getVehicleIdFromInventoryId and inventory.getVehicleIdFromInventoryId(inventoryId)
	local veh = vehId and be:getObjectByID(vehId)
	if not veh or veh.JBeam == "unicycle" or be:getPlayerVehicleID(0) == vehId then return end
	if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() then
		gameplay_walk.getInVehicle(veh)
	else
		be:enterVehicle(0, veh)
	end
end

M.onCareerTuningStarted = enterMenuVehicle
M.onPartShoppingStarted = enterMenuVehicle
M.onVehiclePaintingUiOpened = enterMenuVehicle

--== Wrapper aktuell halten ====================================================

--== 4. Computer aus der Nähe benutzen =========================================
-- "Computer benutzen" erscheint, wenn man zu Fuß in der Zone vor dem Computer steht
-- (gameplay/markers/walkingMarker.lua). Die Zone ist ein Kasten, den C:setup einmal aus dem
-- Szenenobjekt "<name>Computer_area_<n>" berechnet (door.xVec/yVec/zVec = halbe Kanten)
-- und jeden Frame gegen den Spieler prüft.
-- Wir hängen uns in die KLASSE des Markers: vor jeder Methode werden die Kästen von
-- Computer-Zonen auf mindestens client.computerAccessRange Meter (halbe Kante) vergrößert.
-- Methoden werden über die Metatabelle nachgeschlagen, also wirkt das auch auf Marker,
-- die schon vorher gebaut wurden. Andere Marker (Händler, Lieferungen) bleiben unverändert.
-- Keine Kartendatei wird ersetzt.

local MIN_HEIGHT = 2.5

local function accessRange()
	local core = U.ext("sharedCareer_core")
	local config = core and core.getConfig()
	local r = config and tonumber(config.computerAccessRange)
	if not r or r <= 0 or not U.isMP() then return 0 end
	return math.min(r, 30)
end

local function vlen(v)
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function atLeast(v, minLen)
	local len = vlen(v)
	if len <= 0 or len >= minLen then return v end
	local f = minLen / len
	return vec3(v.x * f, v.y * f, v.z * f)
end

local function sameSpot(a, b)
	return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z) < 0.05
end

local function isComputerArea(name)
	return type(name) == "string" and name:lower():find("computer", 1, true) ~= nil
end

-- Bringt die Computer-Kästen eines Markers auf den aktuellen Radius (oder zurück auf Original).
local function widenMarker(self)
	if type(self) ~= "table" or type(self.doors) ~= "table" or type(self.cluster) ~= "table" then return end
	local range = accessRange()
	if self.scRange == range then return end
	self.scRange = range
	for _, ntuple in ipairs(self.cluster.doors or {}) do
		local name = type(ntuple) == "table" and ntuple[1]
		if isComputerArea(name) then
			local area = scenetree.findObject(name)
			local pos = area and area:getPosition()
			for _, door in ipairs(self.doors) do
				if pos and door.areaPos and sameSpot(door.areaPos, pos) then
					door.scOriginal = door.scOriginal or {x = door.xVec, y = door.yVec, z = door.zVec}
					local o = door.scOriginal
					if range > 0 then
						door.xVec, door.yVec, door.zVec = atLeast(o.x, range), atLeast(o.y, range), atLeast(o.z, MIN_HEIGHT)
					else
						door.xVec, door.yVec, door.zVec = o.x, o.y, o.z
					end
				end
			end
		end
	end
end
M.widenMarker = widenMarker

local markerClass, markerKey, markerModule = nil, nil, nil

local function findMarkerClass()
	-- Schon gefunden und das Modul ist unverändert geladen: nichts suchen.
	if markerKey and package.loaded[markerKey] == markerModule and markerClass then return markerClass end
	for key, mod in pairs(package.loaded) do
		if type(key) == "string" and key:find("markers/walkingMarker", 1, true) and type(mod) == "table" then
			markerKey, markerModule = key, mod
			if type(mod.setup) == "function" then return mod end
			if type(mod.create) == "function" then
				local ok, instance = pcall(mod.create)
				local class = ok and type(instance) == "table" and getmetatable(instance)
				if type(class) == "table" and type(class.setup) == "function" then return class end
			end
		end
	end
	return nil
end

local function ensureMarkerPatch()
	local class = findMarkerClass()
	if not class then return end -- Spiel hat die Marker noch nicht geladen; nächste Sekunde
	if class ~= markerClass then
		markerClass = class
		U.log("I", "garage", "computer range: walkingMarker found")
	end
	for name, fn in pairs(class) do
		if type(fn) == "function" and name ~= "init" and name ~= "__index" and not U.isOurs(fn) then
			U.replace(class, name, function(original)
				return function(self, ...)
					local ok, err = pcall(widenMarker, self)
					if not ok then U.log("E", "garage", "computer range: " .. tostring(err)) end
					return original(self, ...)
				end
			end)
		end
	end
end
M.ensureMarkerPatch = ensureMarkerPatch

local function ensurePatches()
	U.replace(core_vehicles, "replaceVehicle", makeReplaceVehicle)
	U.replace(core_vehicles, "spawnNewVehicle", makeSpawnNewVehicle)
	U.replace(career_modules_computer, "openMenu", makeOpenMenu)
	U.replace(career_modules_computer, "computerButtonCallback", makeButtonCallback)
	ensureMarkerPatch()
end
M.ensurePatches = ensurePatches

function M.onUpdate(dtReal)
	sinceCheck = sinceCheck + (tonumber(dtReal) or 0)
	if sinceCheck < CHECK_EVERY then return end
	sinceCheck = 0
	if U.isMP() then ensurePatches() end
end

function M.onCareerActive()
	if U.isMP() then ensurePatches() end
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
