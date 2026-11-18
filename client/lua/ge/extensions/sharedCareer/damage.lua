-- SharedCareer :: other players' vehicles show the owner's damage
--
-- BeamMP only syncs parts that break off. How a body bends is worked out by every PC on its own:
-- when your friend drives through a car that only you see, his car crumples on your screen but
-- not on his. So the owner's damage counts, for every vehicle:
--   * own vehicles: once a crash is over (the damage hasn't changed for SETTLE seconds), the
--     vehicle sends its damage (sharedCareerVeh.damageSnapshot -> onSnapshot -> sc_damage)
--   * other players' vehicles: an incoming damage is applied (sharedCareerVeh.damageApply); a
--     vehicle that isn't spawned here yet gets it as soon as it is. If one got damage only here
--     (a crash only this PC saw), the owner is asked for his damage (sc_damageRequest), which
--     straightens it again. Parts that broke only here can't be mended: the vehicle is reset in
--     place (like BeamMP resets a remote vehicle) and gets the owner's damage again.
-- The damage numbers come from the game's map.objects[id].damage.
-- client.syncDamage = false turns it off.
--
-- Receives: sc_damage {id, damage = {n, d, b}}, sc_damageRequest {id}.
-- Sends: sc_damage, sc_damageRequest.

local M = {}

local U

local EVERY = 0.5          -- seconds between two checks
local SETTLE = 1.5         -- the damage didn't change this long: the crash is over
local ASK_EVERY = 10       -- at most one request per remote vehicle this often
local SEND_EVERY = 2       -- at most one snapshot per own vehicle this often on request
local RESET_EVERY = 5      -- at most one reset per remote vehicle this often
local AFTER_RESET = 0.5    -- seconds after a reset before the damage is applied again

local since = 0
-- own vehicles: game id -> {damage, at, sent, sentAt}
local own = {}
-- other players' vehicles: game id -> {damage, at, base, settling, askedAt, resetAt, waitUntil}
--   base: damage that matches the owner's (only more than that is a crash seen only here)
--   settling: the owner's damage was just applied; the body still bends into its shape, so the
--             damage it then shows becomes the new base
local remote = {}
-- server id -> the owner's damage {n, d, b}, as received last
local received = {}
-- game id -> the received table that was applied to it
local applied = {}

local function mp()
	local m = rawget(_G, "MPVehicleGE")
	if type(m) == "table" and type(m.getVehicles) == "function" then return m end
	return nil
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

local function apply(veh, gameId, damage)
	applied[gameId] = damage
	local st = remote[gameId]
	if st then st.settling = true end
	veh:queueLuaCommand(string.format("if sharedCareerVeh then sharedCareerVeh.damageApply(jsonDecode(%q)) end",
		jsonEncode(damage)))
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

-- other player's vehicle: apply the owner's damage, ask for it after a crash only seen here
local function checkRemote(serverId, gameId, veh, damage, now)
	local st = remote[gameId]
	if not st then
		st = {damage = damage or 0, at = now, base = damage or 0}
		remote[gameId] = st
	end
	if damage and damage ~= st.damage then st.damage, st.at = damage, now end
	if st.waitUntil and now < st.waitUntil then return end
	st.waitUntil = nil
	local wanted = received[serverId]
	if wanted and applied[gameId] ~= wanted then
		apply(veh, gameId, wanted)
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
		if veh and veh:getActive() then
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

-- own vehicle: its damage, as JSON {n, d, b}
function M.onSnapshot(gameId, json)
	local m = mp()
	if not m or not enabled() or not m.isOwn(gameId) then return end
	local serverId = serverIdOf(m, gameId)
	local damage = U.decode(json)
	if serverId and damage then U.send("sc_damage", {id = serverId, damage = damage}) end
end

-- other player's vehicle: a part broke only here, reset it in place
function M.onNeedsReset(gameId)
	local m = mp()
	local st = remote[gameId]
	local veh = be:getObjectByID(gameId)
	if not m or not st or not veh or m.isOwn(gameId) then return end
	local now = os.clockhp()
	if st.resetAt and now - st.resetAt < RESET_EVERY then return end
	st.resetAt, st.waitUntil = now, now + AFTER_RESET
	applied[gameId] = nil
	local pos = veh:getPosition()
	local rot = quatFromDir(-vec3(veh:getDirectionVector()), vec3(veh:getDirectionVectorUp()))
	veh:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
	veh:resetBrokenFlexMesh()
	U.log("I", "damage", "vehicle " .. tostring(gameId) .. " reset to take over its owner's damage")
end

--== From the server ============================================================

local function rxDamage(data)
	local msg = U.decode(data)
	if not msg or type(msg.id) ~= "string" or type(msg.damage) ~= "table" then return end
	received[msg.id] = msg.damage
end

-- someone saw our vehicle crash where we didn't: send its damage again
local function rxRequest(data)
	local msg = U.decode(data)
	local m = mp()
	if not msg or not m or not enabled() or type(msg.id) ~= "string" then return end
	local entry = m.getVehicles()[msg.id]
	local gameId = entry and entry.gameVehicleID
	local veh = gameId and m.isOwn(gameId) and be:getObjectByID(gameId)
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

-- a rebuilt vehicle is undamaged again: apply the owner's damage once more
function M.onVehicleSpawned(gameId)
	own[gameId], remote[gameId], applied[gameId] = nil, nil, nil
end

function M.onVehicleDestroyed(gameId)
	own[gameId], remote[gameId], applied[gameId] = nil, nil, nil
end

function M.onBeamMPServerLeave()
	own, remote, received, applied, since = {}, {}, {}, {}, 0
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	U.on("sc_damage", rxDamage)
	U.on("sc_damageRequest", rxRequest)
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
