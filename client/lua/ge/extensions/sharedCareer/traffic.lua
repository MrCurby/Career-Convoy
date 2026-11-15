-- SharedCareer :: traffic amount from the server
--
-- Every player spawns their own career traffic, and BeamMP shows it to everyone.
-- With 4 players with 10 cars each, 40 cars drive around. So the server splits a
-- total limit and sends every player their share.
--
-- The career (career/modules/playerDriving.lua) passes its amounts in one place:
--   gameplay_traffic.setupTrafficHelper(trafficAmount, trafficOptions, parkingAmount, ...)
-- That function is replaced for exactly one call, so the server amounts get through.
-- Everything else (police, fines, parking) stays game code.
--
-- Also:
--   * simple vehicles (client.trafficSimpleVehicles): traffic spawns as the simple model
--     "simple_traffic" – less load for everyone, because BeamMP sends exactly this model
--   * more careful AI (client.trafficAggression): see "More careful AI" below
--
-- Live changes (menu, players joining/leaving): setActiveAmount shows or hides cars from the
-- pool spawned at the start. Pool = share + client.trafficReserve. Less always works live,
-- more up to the pool size; anything above that applies on the next join.
--
-- Receives: sc_traffic {road, parked} – new share when players join or leave.

local M = {}

local U

local MAX = 50
local armed = nil -- {original, share}

-- Pool that was spawned at the career start: {road, parked}. Live, the amount can only be
-- raised up to this (setActiveAmount shows/hides cars from the pool); more would need new
-- vehicles that BeamMP would have to build on every PC at once (stutter).
-- See client.trafficReserve.
M.pool = nil

local function clamp(n)
	n = tonumber(n)
	if not n or n ~= n then return 0 end
	return math.floor(math.max(0, math.min(MAX, n)))
end

function M.amounts(config)
	local share = type(config) == "table" and config.trafficShare
	if type(share) ~= "table" then return nil end
	return clamp(share.road), clamp(share.parked)
end

local function disarm()
	if armed and gameplay_traffic and gameplay_traffic.setupTrafficHelper == armed.wrapper then
		gameplay_traffic.setupTrafficHelper = armed.original
	end
	armed = nil
end

--- Call before the career start.
function M.arm(config)
	disarm()
	local road, parked = M.amounts(config)
	if not road then return end
	if not gameplay_traffic or type(gameplay_traffic.setupTrafficHelper) ~= "function" then
		U.log("W", "traffic", "gameplay_traffic.setupTrafficHelper missing – server traffic not applied")
		return
	end
	local original = gameplay_traffic.setupTrafficHelper
	local entry = {original = original, since = os.clockhp()}
	entry.wrapper = function(trafficAmount, trafficOptions, parkingAmount, ...)
		disarm()
		local options = {}
		if type(trafficOptions) == "table" then
			for k, v in pairs(trafficOptions) do options[k] = v end
		end
		if road > 0 then options.police = options.police ~= false end
		-- Spawn traffic as "simple_traffic": less physics, smaller config, and because BeamMP
		-- sends the owner's config to everyone, simple on every player's PC.
		if type(config.trafficSimpleVehicles) == "boolean" then options.simpleVehs = config.trafficSimpleVehicles end
		-- Pool = share + reserve; the reserve stays hidden until someone sets more traffic
		-- in the menu.
		local reserve = clamp(config.trafficReserve)
		local poolRoad, poolParked = clamp(road + reserve), clamp(parked + reserve)
		U.log("I", "traffic", string.format("server traffic: %d driving, %d parked (pool %d / %d)",
			road, parked, poolRoad, poolParked))
		local ok, result = pcall(original, poolRoad, options, poolParked, ...)
		if ok then
			M.pool = {road = poolRoad, parked = poolParked}
			-- The career may set the active amounts from its own settings afterwards;
			-- one frame later we enforce the server values.
			M.pending = {road = road, parked = parked}
			return result
		end
		U.log("E", "traffic", "setupTrafficHelper with server amounts failed: " .. tostring(result))
		return original(trafficAmount, trafficOptions, parkingAmount, ...)
	end
	gameplay_traffic.setupTrafficHelper = entry.wrapper
	armed = entry
end

-- Sets the active amount; never more than the spawned pool.
function M.applyLive(road, parked)
	road, parked = clamp(road), clamp(parked)
	if M.pool then
		road, parked = math.min(road, M.pool.road), math.min(parked, M.pool.parked)
	end
	M.active = {road = road, parked = parked}
	if gameplay_traffic and type(gameplay_traffic.setActiveAmount) == "function" then
		pcall(gameplay_traffic.setActiveAmount, road)
	end
	if gameplay_parking and type(gameplay_parking.setActiveAmount) == "function" then
		pcall(gameplay_parking.setActiveAmount, parked)
	end
end

local function rxTraffic(data)
	local share = U.decode(data)
	if not share then return end
	local core = U.ext("sharedCareer_core")
	local config = core and core.getConfig()
	if config then config.trafficShare = share end
	M.applyLive(share.road, share.parked)
	U.log("I", "traffic", string.format("new traffic share: %d / %d", clamp(share.road), clamp(share.parked)))
end

--== More careful AI ===========================================================
-- The driving AI brakes later and follows closer the higher its aggression is
-- (0 = very careful, 1 = very aggressive). Traffic resets it itself on spawn and
-- respawn, so for our own traffic it is set to the server value regularly.
-- The police stay unchanged, otherwise chases don't work.
-- client.trafficAggression = 0 leaves the aggression alone.
--
-- Second lever (client.trafficGrip): the AI's estimate of its own tire grip
-- (ai.lua parameter staticFrictionCoefMult, game default 0.95). A lower estimate makes it
-- brake earlier and more gently at intersections and traffic lights (brake distance
-- = speed^2 / (2 g grip ...)) and drive through corners more slowly. Following distance to
-- cars ahead is still set by the aggression (ai.lua uses min(aggression, grip) there).
-- The game resets the parameters when the AI gets a new route, so it is re-sent
-- regularly together with the aggression. client.trafficGrip = 0 leaves it alone.

local AI_EVERY = 3
local sinceAi = AI_EVERY
local aiApplied = {} -- game id -> {value, at}
local AI_REFRESH = 10

local function isPolice(data)
	local role = type(data) == "table" and data.role
	local name = type(role) == "table" and role.name or data.roleName
	return name == "police"
end

-- Lua command for one traffic car, or nil if both levers are off.
local function aiCommand(aggression, grip)
	local parts = {}
	if aggression then
		table.insert(parts, string.format("if ai.setAggression then ai.setAggression(%.3f) end", aggression))
	end
	if grip then
		table.insert(parts, string.format("if ai.setParameters then ai.setParameters({staticFrictionCoefMult = %.3f}) end", grip))
	end
	if #parts == 0 then return nil end
	return "if ai then " .. table.concat(parts, " ") .. " end"
end
M.aiCommand = aiCommand

function M.applyAiCaution(now)
	local core = U.ext("sharedCareer_core")
	local config = core and core.getConfig()
	if not config then return end
	local aggression = tonumber(config.trafficAggression)
	aggression = (aggression and aggression > 0) and math.max(0.05, math.min(1, aggression)) or nil
	local grip = tonumber(config.trafficGrip)
	grip = (grip and grip > 0) and math.max(0.5, math.min(0.95, grip)) or nil
	local value = aiCommand(aggression, grip)
	if not value then return end
	if not gameplay_traffic or type(gameplay_traffic.getTrafficData) ~= "function" then return end
	local seen = {}
	for gameId, data in pairs(gameplay_traffic.getTrafficData() or {}) do
		if type(data) == "table" and data.isAi == true and not isPolice(data) and gameId ~= be:getPlayerVehicleID(0) then
			seen[gameId] = true
			local veh = be:getObjectByID(gameId)
			local last = aiApplied[gameId]
			if veh and (not last or last.value ~= value or now - last.at >= AI_REFRESH) then
				veh:queueLuaCommand(value)
				aiApplied[gameId] = {value = value, at = now}
			end
		end
	end
	for gameId in pairs(aiApplied) do
		if not seen[gameId] then aiApplied[gameId] = nil end
	end
end

function M.onVehicleResetted(gameId)
	aiApplied[gameId] = nil
end

function M.onVehicleSpawned(gameId)
	aiApplied[gameId] = nil
end

function M.onUpdate(dtReal)
	sinceAi = sinceAi + (tonumber(dtReal) or 0)
	if sinceAi >= AI_EVERY then
		sinceAi = 0
		if U.isMP() then
			local ok, err = pcall(M.applyAiCaution, os.clockhp())
			if not ok then U.log("E", "traffic", "AI setting failed: " .. tostring(err)) end
		end
	end
	if M.pending then
		local p = M.pending
		M.pending = nil
		M.applyLive(p.road, p.parked)
	end
	-- If the career never called the helper, don't leave it hooked forever.
	if armed and os.clockhp() - armed.since > 120 then disarm() end
end

function M.onBeamMPServerLeave()
	disarm()
	M.pool, M.active = nil, nil
	aiApplied = {}
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	U.on("sc_traffic", rxTraffic)
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
