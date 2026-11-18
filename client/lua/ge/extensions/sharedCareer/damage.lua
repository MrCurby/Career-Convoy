-- SharedCareer :: other players' vehicles show the owner's damage
--
-- BeamMP only syncs parts that break off. How a body bends is worked out by every PC on its own:
-- when your friend drives through a car that only you see, his car crumples on your screen but
-- not on his. So the owner's damage counts, for player vehicles (never traffic or parked cars):
--   * own vehicles: once a crash is over (the damage hasn't changed for SETTLE seconds), the
--     vehicle sends its damage (sharedCareerVeh.damageSnapshot -> onSnapshot -> sc_damage)
--   * other players' vehicles: the owner's damage is loaded the way the game loads a saved
--     vehicle, and only while the car stands still (STILL_SPEED for STILL_TIME seconds): changing
--     the shape of a moving car makes its physics blow up. The vehicle takes the damage
--     (sharedCareerVeh.damageLoad), asks to be reset in place (onReadyToLoad, like BeamMP resets a
--     remote vehicle) and takes the owner's shape right after the reset. A vehicle that isn't
--     spawned here yet, or doesn't stand still, gets it later.
--   * a crash only this PC saw (the damage of another player's vehicle grows here without a new
--     damage from its owner): the owner is asked for his damage (sc_damageRequest), which then
--     replaces the one seen here
-- The damage numbers come from the game's map.objects[id].damage.
-- client.syncDamage = false turns it off.
--
-- Receives: sc_damage {id, damage = {nn, bn, n, d, b}} or {id, cleared = true}, sc_damageRequest {id}.
-- Sends: sc_damage, sc_damageRequest.

local M = {}

local U

local EVERY = 0.5          -- seconds between two checks
local SETTLE = 1.5         -- the damage didn't change this long: the crash is over
local STILL_SPEED = 0.5    -- m/s: below this another player's vehicle counts as standing still
local STILL_TIME = 1       -- seconds it must stand still before its damage is loaded
local ASK_EVERY = 10       -- at most one request per remote vehicle this often
local SEND_EVERY = 2       -- at most one snapshot per own vehicle this often on request

local since = 0
-- own vehicles: game id -> {damage, at, sent, sentAt}
local own = {}
-- other players' vehicles: game id -> {damage, at, base, settling, askedAt, stillSince}
--   base: damage that matches the owner's (only more than that is a crash seen only here)
--   settling: the owner's damage was just loaded; the damage the car then shows becomes the new base
local remote = {}
-- server id -> the owner's damage, as received last
local received = {}
-- game id -> the received damage that was loaded into it
local loaded = {}

local function mp()
	local m = rawget(_G, "MPVehicleGE")
	if type(m) == "table" and type(m.getVehicles) == "function" then return m end
	return nil
end

local function isPlayerVehicle(serverId)
	local vehicles = extensions.sharedCareer_vehicles
	return vehicles ~= nil and vehicles.isPlayerVehicle(serverId)
end

local function enabled()
	local cfg = U.config()
	return U.isMP() and cfg ~= nil and cfg.syncDamage ~= false
end

local function damageOf(gameId)
	local objects = rawget(_G, "map") and map.objects
	local data = type(objects) == "table" and objects[gameId]
	return type(data) == "table" and tonumber(data.damage) or nil
end

local function serverIdOf(m, gameId)
	for serverId, entry in pairs(m.getVehicles()) do
		if entry.gameVehicleID == gameId then return serverId end
	end
	return nil
end

local function requestSnapshot(veh)
	veh:queueLuaCommand("if sharedCareerVeh then sharedCareerVeh.damageSnapshot() end")
end

-- own vehicle: send its damage once the crash is over
local function checkOwn(gameId, veh, damage, now)
	local st = own[gameId]
	if not st then
		st = {damage = damage, at = now, sent = 0}
		own[gameId] = st
	end
	if damage ~= st.damage then st.damage, st.at = damage, now end
	if st.sent ~= st.damage and now - st.at >= SETTLE then
		st.sent, st.sentAt = st.damage, now
		requestSnapshot(veh)
	end
end

-- other player's vehicle: load the owner's damage once it stands still, ask for it after a crash
-- only seen here
local function checkRemote(serverId, gameId, veh, damage, now)
	local st = remote[gameId]
	if not st then
		st = {damage = damage or 0, at = now, base = damage or 0}
		remote[gameId] = st
	end
	if damage and damage ~= st.damage then st.damage, st.at = damage, now end
	local vel = veh:getVelocity()
	if vel and vel:length() < STILL_SPEED then
		st.stillSince = st.stillSince or now
	else
		st.stillSince = nil
	end
	local wanted = received[serverId]
	if wanted and loaded[gameId] ~= wanted then
		if st.stillSince and now - st.stillSince >= STILL_TIME then
			loaded[gameId] = wanted
			st.settling = true
			veh:queueLuaCommand(string.format("if sharedCareerVeh then sharedCareerVeh.damageLoad(jsonDecode(%q)) end",
				jsonEncode(wanted)))
		end
		return
	end
	if st.settling then
		if now - st.at >= SETTLE then st.base, st.settling = st.damage, nil end
		return
	end
	if st.damage > st.base and now - st.at >= SETTLE and (not st.askedAt or now - st.askedAt >= ASK_EVERY) then
		st.askedAt, st.base = now, st.damage
		U.send("sc_damageRequest", {id = serverId})
	end
end

local function check(now)
	local m = mp()
	if not m then return end
	local seen = {}
	for serverId, entry in pairs(m.getVehicles()) do
		local gameId = entry.gameVehicleID
		local veh = gameId and gameId ~= -1 and be:getObjectByID(gameId)
		if veh and veh:getActive() and isPlayerVehicle(serverId) then
			seen[gameId] = true
			local damage = damageOf(gameId)
			if m.isOwn(gameId) then
				if damage then checkOwn(gameId, veh, damage, now) end
			elseif entry.isLocal ~= true then
				checkRemote(serverId, gameId, veh, damage, now)
			end
		end
	end
	for gameId in pairs(own) do if not seen[gameId] then own[gameId] = nil end end
	for gameId in pairs(remote) do if not seen[gameId] then remote[gameId] = nil end end
end
M.check = check

--== From the vehicles ==========================================================

-- own vehicle: its damage, as JSON
function M.onSnapshot(gameId, json)
	local m = mp()
	if not m or not enabled() or not m.isOwn(gameId) then return end
	local serverId = serverIdOf(m, gameId)
	local damage = U.decode(json)
	if serverId and damage and isPlayerVehicle(serverId) then U.send("sc_damage", {id = serverId, damage = damage}) end
end

-- other player's vehicle took the damage and stands still: reset it in place, it takes the
-- owner's shape right after
function M.onReadyToLoad(gameId)
	local m = mp()
	local veh = be:getObjectByID(gameId)
	if not m or not veh or m.isOwn(gameId) or not remote[gameId] then return end
	local pos = veh:getPosition()
	local rot = quatFromDir(-vec3(veh:getDirectionVector()), vec3(veh:getDirectionVectorUp()))
	veh:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
	veh:resetBrokenFlexMesh()
end

--== From the server ============================================================

local function rxDamage(data)
	local msg = U.decode(data)
	if not msg or type(msg.id) ~= "string" then return end
	if msg.cleared then
		received[msg.id] = nil -- a new or rebuilt vehicle: undamaged
	elseif type(msg.damage) == "table" then
		received[msg.id] = msg.damage -- loaded by check() once the vehicle is here and stands still
	end
end

-- someone saw our vehicle crash where we didn't: send its damage again
local function rxRequest(data)
	local msg = U.decode(data)
	local m = mp()
	if not msg or not m or not enabled() or type(msg.id) ~= "string" then return end
	local entry = m.getVehicles()[msg.id]
	local gameId = entry and entry.gameVehicleID
	local veh = gameId and m.isOwn(gameId) and isPlayerVehicle(msg.id) and be:getObjectByID(gameId)
	if not veh then return end
	local now = os.clockhp()
	local st = own[gameId]
	if st and st.sentAt and now - st.sentAt < SEND_EVERY then return end
	if st then st.sentAt = now end
	requestSnapshot(veh)
end

--== Hooks =====================================================================

function M.onUpdate(dtReal)
	since = since + (tonumber(dtReal) or 0)
	if since < EVERY then return end
	since = 0
	if not enabled() then return end
	local ok, err = pcall(check, os.clockhp())
	if not ok then U.log("E", "damage", "damage sync failed: " .. tostring(err)) end
end

-- a rebuilt vehicle is undamaged again: load the owner's damage once more
function M.onVehicleSpawned(gameId)
	own[gameId], remote[gameId], loaded[gameId] = nil, nil, nil
end

function M.onVehicleDestroyed(gameId)
	own[gameId], remote[gameId], loaded[gameId] = nil, nil, nil
end

function M.onBeamMPServerLeave()
	own, remote, received, loaded, since = {}, {}, {}, {}, 0
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	U.on("sc_damage", rxDamage)
	U.on("sc_damageRequest", rxRequest)
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
