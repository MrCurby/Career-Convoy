-- SharedCareer :: shared fuel prices
--
-- Game (freeroam/facilities/fuelPrice.lua): every station has a base price per fuel type
-- (priceBaseline) and a random part that EVERY player rolls themselves when the map loads –
-- so everyone pays something different at the same station. setDisplayPrices() calculates the
-- prices and labels the price signs; career/modules/fuel.lua asks getFuelPrice when refueling.
--
-- SharedCareer:
--   * price = base price × factor from the server, without the random part -> everyone pays the same.
--   * The factors come from the server (sc_fuelPrices). Here priceBaseline/random part are set in
--     the station data and setDisplayPrices() is called: the game recalculates and labels the
--     signs itself.
--   * Fuel deliveries: career_modules_delivery_progress.onCargoDelivered gets wrapped.
--     Our own deliveries of gasoline/diesel to a station go to the server
--     (sc_fuelDelivered), which lowers the price of that fuel there for everyone.
-- Switch off: server.fuelEconomy = false (then the normal game prices apply).

local M = {}

local U

local factors = nil        -- {[station] = {[fuel] = factor}} from the server
local enabled = false
local originals = {}       -- [station][fuel] = {baseline, gain, bias}
local applyPending = false
local expected = {}        -- [station][fuel] = price the game should return after apply
local fallback = false     -- true if getFuelPrice had to be wrapped directly
local sinceCheck = 1

local function gasStations()
	local facilities = rawget(_G, "freeroam_facilities")
	if type(facilities) ~= "table" or type(facilities.getFacilities) ~= "function" then return nil end
	local level = type(getCurrentLevelIdentifier) == "function" and getCurrentLevelIdentifier() or nil
	if not level then return nil end
	local ok, data = pcall(facilities.getFacilities, level)
	if not ok or type(data) ~= "table" or type(data.gasStations) ~= "table" then return nil end
	return data.gasStations
end

--== Applying prices ===========================================================

--- Sets base price × factor (without the random part) in the station data and lets the game
--- recalculate prices and signs. Returns the number of changed prices.
function M.apply()
	local stations = gasStations()
	local priceModule = rawget(_G, "freeroam_facilities_fuelPrice")
	if not stations or type(priceModule) ~= "table" or type(priceModule.setDisplayPrices) ~= "function" then
		return 0
	end
	local changed = 0
	expected = {}
	for _, station in pairs(stations) do
		if type(station) == "table" and station.id and type(station.prices) == "table" then
			for fuel, p in pairs(station.prices) do
				if type(p) == "table" and tonumber(p.priceBaseline) then
					originals[station.id] = originals[station.id] or {}
					local o = originals[station.id][fuel]
					if not o then
						o = {baseline = p.priceBaseline, gain = p.priceRandomnessGain, bias = p.priceRandomnessBias}
						originals[station.id][fuel] = o
					end
					if enabled then
						local f = factors and factors[station.id] and tonumber(factors[station.id][fuel]) or 1
						p.priceBaseline = o.baseline * f
						p.priceRandomnessGain, p.priceRandomnessBias = nil, nil
						expected[station.id] = expected[station.id] or {}
						expected[station.id][fuel] = o.baseline * f
					else
						p.priceBaseline, p.priceRandomnessGain, p.priceRandomnessBias = o.baseline, o.gain, o.bias
					end
					changed = changed + 1
				end
			end
		end
	end
	if changed > 0 then
		local ok, err = pcall(priceModule.setDisplayPrices)
		if not ok then U.log("E", "fuel", "setDisplayPrices failed: " .. tostring(err)) end
		M.verify(priceModule)
	end
	return changed
end

-- Did the game take over the new prices? Not if getFacilities only returns a copy –
-- then getFuelPrice is wrapped directly (refueling correct, signs keep the old value).
local function makeGetFuelPrice(original)
	return function(stationId, fuelType, ...)
		if enabled and expected[stationId] and expected[stationId][fuelType] then
			return expected[stationId][fuelType]
		end
		return original(stationId, fuelType, ...)
	end
end

function M.verify(priceModule)
	if not enabled or fallback or type(priceModule.getFuelPrice) ~= "function" then return end
	for station, fuels in pairs(expected) do
		for fuel, price in pairs(fuels) do
			local ok, actual = pcall(priceModule.getFuelPrice, station, fuel)
			if ok and tonumber(actual) and math.abs(actual - price) > 0.0005 then
				fallback = true
				U.replace(priceModule, "getFuelPrice", makeGetFuelPrice)
				U.log("W", "fuel", "game did not take the new prices – using getFuelPrice fallback (price signs keep the old value)")
			end
			return
		end
	end
end

local function rxFuelPrices(data)
	local msg = U.decode(data)
	if not msg then return end
	enabled = msg.enabled == true
	factors = type(msg.factors) == "table" and msg.factors or {}
	applyPending = true
end

--== Detecting deliveries ======================================================

local function fuelTypeOf(cargo)
	local t = tostring(cargo.materialType or ""):lower()
	if t:find("diesel", 1, true) then return "diesel" end
	if t:find("gasoline", 1, true) or t:find("petrol", 1, true) then return "gasoline" end
	return nil
end

--- Station ID (for the prices) for a delivery location (e.g. "apex_fuel").
function M.stationFor(deliveryFacId)
	local stations = gasStations()
	if not stations or type(deliveryFacId) ~= "string" then return nil end
	local name
	local generator = rawget(_G, "career_modules_delivery_generator")
	if generator and type(generator.getFacilityById) == "function" then
		local ok, fac = pcall(generator.getFacilityById, deliveryFacId)
		if ok and type(fac) == "table" then name = fac.name end
	end
	local stripped = deliveryFacId:gsub("_fuel$", ""):gsub("^fuel_", "")
	for _, s in pairs(stations) do
		if type(s) == "table" and s.id then
			if (name and s.name == name) or s.id == deliveryFacId or s.id == stripped then
				return s.id, s.name
			end
		end
	end
	return nil
end

local function translate(key)
	if type(key) ~= "string" then return nil end
	if type(translateLanguage) == "function" then
		local ok, text = pcall(translateLanguage, key, key)
		if ok and type(text) == "string" and text ~= key then return text end
	end
	return nil
end

--- Pick the fuel deliveries out of the delivered cargo items and report them.
function M.reportDelivered(cargoItems)
	if not enabled or type(cargoItems) ~= "table" then return end
	local totals = {} -- [station][fuel] = {amount, name}
	for _, cargo in ipairs(cargoItems) do
		local fuel = type(cargo) == "table" and fuelTypeOf(cargo)
		local facId = fuel and type(cargo.location) == "table" and cargo.location.facId
		if facId then
			local station, stationName = M.stationFor(facId)
			if station then
				totals[station] = totals[station] or {}
				local t = totals[station][fuel] or {amount = 0, name = translate(stationName)}
				t.amount = t.amount + (tonumber(cargo.slots) or 0)
				totals[station][fuel] = t
			else
				U.log("W", "fuel", "no gas station found for delivery facility " .. tostring(facId))
			end
		end
	end
	for station, fuels in pairs(totals) do
		for fuel, t in pairs(fuels) do
			if t.amount > 0 then
				U.log("I", "fuel", string.format("delivered %s %s to %s", tostring(t.amount), fuel, station))
				U.send("sc_fuelDelivered", {station = station, fuel = fuel, amount = t.amount, stationName = t.name})
			end
		end
	end
end

local function makeOnCargoDelivered(original)
	return function(cargoItems, ...)
		local results = U.pack(original(cargoItems, ...))
		if U.isMP() then
			local ok, err = pcall(M.reportDelivered, cargoItems)
			if not ok then U.log("E", "fuel", "fuel delivery check failed: " .. tostring(err)) end
		end
		return U.unpack(results, 1, results.n)
	end
end

local function ensurePatch()
	local progress = rawget(_G, "career_modules_delivery_progress")
	if type(progress) ~= "table" then return end
	local before = progress.onCargoDelivered
	U.replace(progress, "onCargoDelivered", makeOnCargoDelivered)
	-- If the game calls the function via extensions.hook: rebuild the hook cache.
	if progress.onCargoDelivered ~= before and type(extensions) == "table" and type(extensions.hookUpdate) == "function" then
		pcall(extensions.hookUpdate, "onCargoDelivered")
	end
end
M.ensurePatch = ensurePatch

--== Overview for the Fuel app on the phone =====================================
-- All stations with the current price per fuel type (as when refueling: getFuelPrice), discount
-- from deliveries, distance to the player. "Go" sets a route to the station.
-- Prices in the map's unit (West Coast: per US gallon, like on the signs).

local GALLON = 3.78541
local positions = {}      -- [station id] = {x, y, z, source}; only found positions are kept
local navigatingStation = nil
local sourcesLogged = false

-- Where a gas station is: the middle of its pumps. In *.facilities.json each pump is a pair of
-- level object names {gameplay area, point of interest/icon}; both are placed at the pump.
-- freeroam_facilities.getAverageDoorPositionForFacility is meant for facilities with doors
-- (garages, dealers); for gas stations it returned the same point for every station (issue #1:
-- every station 1.1 km away, "Go" routed to nowhere). It's only used as a fallback, and only
-- if the point is believable: not the map origin and not shared with another station.
local function objectPosition(name)
	if type(name) ~= "string" or name == "" then return nil end
	local tree = rawget(_G, "scenetree")
	if not tree or type(tree.findObject) ~= "function" then return nil end
	local ok, obj = pcall(tree.findObject, name)
	if not ok or not obj then return nil end
	local okPos, p = pcall(function() return obj:getPosition() end)
	if okPos and p and tonumber(p.x) then return p end
	return nil
end

local function pumpPosition(station)
	if type(station.pumps) ~= "table" then return nil end
	local sx, sy, sz, n = 0, 0, 0, 0
	for _, pump in ipairs(station.pumps) do
		local p
		if type(pump) == "table" then
			p = objectPosition(pump[1]) or objectPosition(pump[2])
		else
			p = objectPosition(pump)
		end
		if p then
			sx, sy, sz, n = sx + p.x, sy + p.y, sz + p.z, n + 1
		end
	end
	if n == 0 then return nil end
	return {x = sx / n, y = sy / n, z = sz / n, source = "pumps"}
end

local doorPoints = nil    -- [station id] = believable door point; nil = not looked up yet

-- The door point of every station, once per map; points shared by two stations are dropped.
local function lookUpDoorPoints()
	if doorPoints then return doorPoints end
	local facilities = rawget(_G, "freeroam_facilities")
	if not facilities or type(facilities.getAverageDoorPositionForFacility) ~= "function" then return {} end
	local found, any = {}, false
	for _, station in pairs(gasStations() or {}) do
		if type(station) == "table" and station.id then
			local ok, p = pcall(facilities.getAverageDoorPositionForFacility, station)
			-- a vec3 in the game (LuaJIT cdata), a table in the tests: both have .x
			if ok and p and tonumber(p.x) then
				any = true
				-- the map origin is a placeholder, not a position
				if math.abs(p.x) + math.abs(p.y) + math.abs(p.z) >= 1 then
					found[station.id] = {x = p.x, y = p.y, z = p.z, source = "doors"}
				end
			end
		end
	end
	local shared = {}
	for id, p in pairs(found) do
		for other, q in pairs(found) do
			if id ~= other and math.abs(q.x - p.x) < 2 and math.abs(q.y - p.y) < 2 then shared[id] = true end
		end
	end
	for id in pairs(shared) do found[id] = nil end
	-- shortly after loading the game may not know any yet: then ask again next time
	if any then doorPoints = found end
	return found
end

local function doorPosition(station)
	return lookUpDoorPoints()[station.id]
end

-- Only remember positions that were found: shortly after loading the game may not know them
-- yet, then it is tried again next time.
local function stationPosition(station)
	if positions[station.id] then return positions[station.id] end
	local p = pumpPosition(station) or doorPosition(station)
	if p then positions[station.id] = p end
	return p
end

--- Where the stations' positions came from (for the log and the tests): {pumps, doors, none}.
function M.positionSources()
	local count = {pumps = 0, doors = 0, none = 0}
	for _, station in pairs(gasStations() or {}) do
		if type(station) == "table" and station.id then
			local p = stationPosition(station)
			local key = p and p.source or "none"
			count[key] = (count[key] or 0) + 1
		end
	end
	return count
end

local function unitFor(fuel)
	local levels = rawget(_G, "core_levels")
	local level = type(getCurrentLevelIdentifier) == "function" and getCurrentLevelIdentifier() or nil
	if levels and level and type(levels.getLevelByName) == "function" then
		local ok, info = pcall(levels.getLevelByName, level)
		if ok and type(info) == "table" and type(info.localUnits) == "table" and info.localUnits[fuel] == "gallonUS" then
			return "gal", GALLON
		end
	end
	return "l", 1
end

local function playerPosition()
	local veh = type(getPlayerVehicle) == "function" and getPlayerVehicle(0) or nil
	if veh then
		local ok, pos = pcall(function() return veh:getPosition() end)
		if ok then return pos end
	end
	return nil
end

--- State for the Fuel app on the phone, or nil without stations.
function M.overview()
	local stations = gasStations()
	local priceModule = rawget(_G, "freeroam_facilities_fuelPrice")
	if not stations or type(priceModule) ~= "table" or type(priceModule.getFuelPrice) ~= "function" then return nil end
	local me = playerPosition()
	local list = {}
	for _, station in pairs(stations) do
		if type(station) == "table" and station.id and type(station.prices) == "table" then
			local entry = {id = station.id, name = translate(station.name) or station.id, fuels = {}}
			for fuel in pairs(station.prices) do
				local ok, price = pcall(priceModule.getFuelPrice, station.id, fuel)
				if ok and tonumber(price) then
					local unit, mult = unitFor(fuel)
					local f = enabled and factors and factors[station.id] and tonumber(factors[station.id][fuel]) or 1
					entry.fuels[fuel] = {price = price * mult, unit = unit,
						discount = math.floor((1 - f) * 100 + 0.5)}
				end
			end
			local pos = stationPosition(station)
			if pos and me then
				local dx, dy = pos.x - me.x, pos.y - me.y
				entry.distance = math.sqrt(dx * dx + dy * dy)
			end
			entry.canNavigate = pos ~= nil
			if next(entry.fuels) then table.insert(list, entry) end
		end
	end
	if not sourcesLogged and #list > 0 then
		local c = M.positionSources()
		if c.pumps + c.doors > 0 then
			sourcesLogged = true
			U.log("I", "fuel", string.format("gas station positions: %d from pumps, %d from doors, %d unknown",
				c.pumps, c.doors, c.none))
		end
	end
	return {stations = list, navigating = navigatingStation, enabled = enabled}
end

function M.uiNavigate(stationId)
	local stations = gasStations()
	local markers = rawget(_G, "core_groundMarkers")
	if not stations or not markers or type(markers.setPath) ~= "function" then return end
	for _, station in pairs(stations) do
		if type(station) == "table" and station.id == stationId then
			local pos = stationPosition(station)
			if pos then
				local ok, err = pcall(markers.setPath, vec3(pos.x, pos.y, pos.z))
				if ok then navigatingStation = stationId
				else U.log("E", "fuel", "navigation to gas station failed: " .. tostring(err)) end
			end
			return
		end
	end
end

function M.uiStopNavigate()
	local markers = rawget(_G, "core_groundMarkers")
	if markers and type(markers.setPath) == "function" then pcall(markers.setPath, nil) end
	navigatingStation = nil
end

--== Hooks =====================================================================

function M.onUpdate(dtReal)
	if not U.isMP() then return end
	sinceCheck = sinceCheck + (tonumber(dtReal) or 0)
	if applyPending and U.careerActive() then
		applyPending = false
		local n = M.apply()
		if n == 0 then applyPending = true end -- map/stations not ready yet
	end
	if sinceCheck >= 1 then
		sinceCheck = 0
		if U.careerActive() then ensurePatch() end
	end
end

--- Look the station positions up again (new map).
function M.forgetPositions()
	positions, doorPoints, sourcesLogged = {}, nil, false
end

-- After loading a map the game rolls the prices again: apply them again afterwards.
function M.onClientStartMission()
	originals = {}
	M.forgetPositions()
	navigatingStation = nil
	applyPending = factors ~= nil
end

-- The fuel prices are an app on the phone (phone.lua); its screen is in the phone window and
-- gets the data with "SharedCareerState" (menu.lua -> M.overview, only while the app is open).
-- The prices at the pumps and on the signs are set by M.apply above, independent of the app.
local function registerPhoneApp()
	local phone = U.ext("sharedCareer_phone")
	if phone and type(phone.registerApp) == "function" then
		phone.registerApp({id = "fuel", title = "Fuel", icon = "fuel", color = "#2a9d55", order = 20})
	end
end

function M.onCareerActive(active)
	if active then
		applyPending = factors ~= nil
		if U.isMP() then
			ensurePatch()
			registerPhoneApp()
		end
	end
end

function M.onBeamMPServerLeave()
	if factors then
		enabled = false
		pcall(M.apply) -- original prices back
	end
	factors, enabled, originals, applyPending = nil, false, {}, false
	positions, doorPoints, sourcesLogged, navigatingStation = {}, nil, false, nil
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	U.on("sc_fuelPrices", rxFuelPrices)
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
