-- SharedCareer :: ropes between your vehicles and an anchor – the core of the Tow and Straps apps
--
-- The game's node grabber is weak in the career (the engine limits its force; a mod can't change
-- that). So SharedCareer has its own ropes, computed with physics inside the vehicle
-- (lua/vehicle/extensions/auto/sharedCareerVeh.lua, "Ropes"). This file keeps every rope that is
-- on, talks to the vehicles and draws the ropes. Two apps use it:
--   tow.lua     the Tow app: one rope with a winch, the anchor moved with a remote (kind TOW)
--   straps.lua  the Straps app: ratchet straps that hold a car on a trailer or truck (kind STRAP)
--
-- A rope (create) is tied to one of your vehicles; the vehicle picks the node and reports it
-- (onRopeTied). Its other end, the anchor, is a point in the world (a tow rope: the app moves it)
-- or a node on another of your vehicles (hook). An anchor on a vehicle moves with it: its
-- position and speed go to the roped vehicle every frame, the rope's pull comes back (onRopePull)
-- and goes on to the anchor vehicle (anchorPull), so it feels the load. Nothing hooks on by
-- itself: the app asks where it would hook on and the player decides.
--   hook points   for a tow rope (wantHookPoints): a few times per second your vehicles near the
--                 anchor are asked (anchorNear) for their tow hitches (shown as rings) and the
--                 point where the anchor would hook on – a tow hitch within 0.7 m, otherwise the
--                 nearest sturdy point within 0.5 m. hookPoint(r) gives the nearest one; the Tow
--                 app shows it as a ring with a dashed line and offers "Hook on"
--   preview       probe("tie") while an app wants to tie a rope where you look: a blue ball where
--                 it would go (tieProbe); probe("hook", except) while it wants to hook a strap on
--                 where you look: a ring on that point (hookProbe)
--
-- Staying in step with the vehicles:
--   * vehicle reset (onVehicleResetted, and the vehicle's own onReset) or removed: rope removed
--   * the anchor vehicle reset or removed: a tow rope's anchor stays where it was, a strap comes off
--   * no word from the vehicle for SILENT_LIMIT s of game time (its Lua was reloaded, or the tie
--     never answered): rope removed – a paused game doesn't count
--
-- What you see (debugDrawer, like the game's own markers):
--   rope      from the tie node to the anchor, a thin cylinder with a line inside (the line keeps
--             it visible from far away): grey = slack; when taut, the color shows the rope's own
--             load, measured against its breaking load (ropeLoad): its own color while it is safe
--             (a tow rope light, a strap yellow), yellow to orange when it gets high, red and
--             trembling near breaking. A slack rope sags (a curve as long as the rope); it
--             straightens smoothly when it is pulled taut. The rope end follows the tie node every
--             frame (veh:getNodePosition), not only when the vehicle reports
--             A tow rope running through the winch shows light marks that travel with it (towards
--             the anchor when it is hauled in); their speed is the rope's own, so they stand still
--             when the vehicle is stuck
--   grip      a small ball on the tie node, in the rope's color
--   the end   the app draws its own anchor (drawEnd): the Tow app a pin or a shackle, the Straps
--             app a ratchet
--   let go    when a rope comes off it doesn't just vanish: a taut rope snaps back to the anchor
--             with a short whip, a slack one drops; both fade out within a fraction of a second
--   flash     a growing ring where a rope just hooked on (green) or came off a vehicle (orange)
-- Balls, cylinders and the sign use debugDrawer:drawSphere/drawCylinder/drawTextAdvanced; if one
-- of them is missing or fails, that shape is drawn with lines (or left out, for the sign and the
-- rope's cylinder).
--
-- Only your own vehicles (incl. your own traffic): other players' vehicles are simulated on
-- their PCs, BeamMP would put them back immediately. Not the player on foot.
-- Server setting client.allowRopes switches ropes and straps on or off.

local M = {}

local U

M.TOW, M.STRAP = 0, 1 -- kinds of rope (the vehicle's KIND_TOW / KIND_STRAP)

M.MAX_DISTANCE = 120       -- m, how far away a vehicle can be roped
local SEND_EVERY = 1 / 30  -- s: how often the anchor is sent to the vehicle (on a vehicle: every frame)
local SILENT_LIMIT = 2     -- s of game time without word from the vehicle: the rope is gone
local MAX_STEP = 0.1       -- s: the longest frame a rope works with
local STUCK_AFTER = 2      -- s at the winch's limit: shown as "at the limit"
local PROBE_EVERY = 0.2    -- s: how often the preview asks the vehicle
local PROBE_KEEP = 0.5     -- s: how long a preview answer is shown
local PROBE_WANTED = 0.1   -- s: an app that stopped asking for the preview this long ago doesn't want it
local HOOK_ASK_EVERY = 0.2 -- s between two questions to the vehicles near a tow rope's anchor
local HOOK_SEARCH = 8      -- m from a vehicle's position: it is asked where the anchor would hook on
local HOOK_KEEP = 0.6      -- s an answer counts without a new one
local HOOK_REACH = 1       -- m: an answer whose point is farther from the anchor is old
local MESSAGE_AGAIN = 1    -- s: the same message again within this time is not shown twice
local ANCHOR_TELEPORT = 10 -- m/s: an anchor node faster than its vehicle by this much jumped

-- what the vehicle reports with onRopeLost(id, rid, reason), per kind
local LOST_MESSAGES = {
	[M.TOW] = {
		[0] = "Can't attach the rope there",
		[1] = "Vehicle reset – rope off",
		[2] = "Vehicle moved – rope off",
		[3] = "The part tore off – rope off",
		[4] = "The rope snapped",
		silent = "The rope came loose",
	},
	[M.STRAP] = {
		[0] = "Can't strap there",
		[1] = "Vehicle reset – strap off",
		[2] = "Vehicle moved – strap off",
		[3] = "The part tore off – strap off",
		[4] = "A strap snapped",
		silent = "A strap came loose",
	},
}

local ropes = {}           -- rid -> rope, see M.create
local nextId = 1
local clock = 0            -- s of real time, for pulsing shapes and the rope's speed
local letGo = {}           -- ropes that just came off, while they snap back or drop (see Drawing)
local flashes = {}         -- {pos, age, off}: a rope just hooked on (off: came off)
local probe = nil          -- {mode, id, x, y, z (tie) or cid, hitch (hook), age}
local probeWant = nil      -- {mode, except, at}: what the open app wants to preview
local sinceProbe = 0
local lastMessage = nil    -- {text, at}
local drawErrorLogged = false

local startLetGo           -- defined with the drawing below

--== Helpers (also for tow.lua and straps.lua) ====================================

function M.allowed()
	local c = U.config()
	return c ~= nil and c.allowRopes == true
end

function M.sendToVehicle(id, cmd)
	local veh = be:getObjectByID(id)
	if veh and type(veh.queueLuaCommand) == "function" then
		veh:queueLuaCommand("if sharedCareerVeh then " .. cmd .. " end")
	end
end
local sendToVehicle = M.sendToVehicle

local function vecOf(v)
	if v == nil then return nil end
	return {x = tonumber(v.x) or 0, y = tonumber(v.y) or 0, z = tonumber(v.z) or 0}
end
M.vecOf = vecOf

function M.cameraPos()
	if core_camera and type(core_camera.getPosition) == "function" then
		local ok, p = pcall(core_camera.getPosition)
		if ok and p then return vecOf(p) end
	end
	return nil
end

-- Camera view direction (unit vector) or nil.
function M.viewDir()
	if not (core_camera and type(core_camera.getForward) == "function") then return nil end
	local ok, f = pcall(core_camera.getForward)
	f = ok and vecOf(f)
	if not f then return nil end
	local len = math.sqrt(f.x * f.x + f.y * f.y + f.z * f.z)
	if len < 0.01 then return nil end
	return {x = f.x / len, y = f.y / len, z = f.z / len}
end

function M.distance(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- true if this game vehicle is ours (not another player's)
local function isOwnVehicle(gameId)
	local mp = rawget(_G, "MPVehicleGE")
	if type(mp) ~= "table" then return true end
	if type(mp.isOwn) == "function" and mp.isOwn(gameId) then return true end
	if type(mp.getVehicles) == "function" then
		for _, entry in pairs(mp.getVehicles() or {}) do
			if type(entry) == "table" and entry.gameVehicleID == gameId then
				return entry.isLocal == true
			end
		end
	end
	return true -- not registered with BeamMP yet: a fresh vehicle of ours
end

local function modelOf(veh)
	local model = veh.JBeam
	if model == nil and type(veh.getJBeamFilename) == "function" then model = veh:getJBeamFilename() end
	return model
end

-- Can a rope be tied to this vehicle (and can it be towed to the road)? Returns true, or false and
-- a message.
function M.canRope(veh, id)
	if not veh or type(veh.queueLuaCommand) ~= "function" then return false, "Look at one of your vehicles" end
	if modelOf(veh) == "unicycle" then return false, "Not on players on foot" end
	if not isOwnVehicle(id) then return false, "Only your own vehicles" end
	local freeCam = core_camera and type(core_camera.getActiveGlobalCameraName) == "function"
		and core_camera.getActiveGlobalCameraName()
	if id == be:getPlayerVehicleID(0) and not freeCam then
		return false, "Get out first (or use the free camera)"
	end
	return true
end

-- Can a rope's other end go onto this vehicle? One of your own (also the one you sit in), not the
-- one the rope is tied to (except), not a player on foot.
function M.canHold(veh, id, except)
	if not veh or type(veh.queueLuaCommand) ~= "function" or id == except then return false end
	return modelOf(veh) ~= "unicycle" and isOwnVehicle(id)
end

-- The vehicle closest to the aim line: {veh, id, t (distance along the line), miss (distance
-- from the line)}, or nil. accept(veh, id): only vehicles it says yes to. The ray cast itself
-- doesn't report vehicles in every game version, so we search the vehicles ourselves.
function M.vehicleOnRay(cam, dir, accept)
	local best = nil
	local count = type(be.getObjectCount) == "function" and be:getObjectCount() or 0
	for i = 0, count - 1 do
		local veh = be:getObject(i)
		if veh and type(veh.getPosition) == "function" and type(veh.getID) == "function"
			and (not accept or accept(veh, veh:getID())) then
			local p = vecOf(veh:getPosition())
			local rx, ry, rz = p.x - cam.x, p.y - cam.y, p.z - cam.z
			local t = rx * dir.x + ry * dir.y + rz * dir.z
			if t > 0.5 and t <= M.MAX_DISTANCE then
				local mx, my, mz = rx - dir.x * t, ry - dir.y * t, rz - dir.z * t
				local miss = math.sqrt(mx * mx + my * my + mz * mz)
				-- a vehicle counts as "pointed at" within a few meters of its center
				if miss <= math.max(3, 0.06 * t) and (not best or miss < best.miss) then
					best = {veh = veh, id = veh:getID(), t = t, miss = miss}
				end
			end
		end
	end
	return best
end

-- A node's position now: the vehicle's position + getNodePosition (relative to it), or nil.
function M.nodePos(veh, node)
	if not (veh and node and type(veh.getNodePosition) == "function" and type(veh.getPosition) == "function") then return nil end
	local ok, rel = pcall(veh.getNodePosition, veh, node)
	local base = vecOf(veh:getPosition())
	rel = ok and vecOf(rel)
	if not (rel and base) then return nil end
	return {x = base.x + rel.x, y = base.y + rel.y, z = base.z + rel.z}
end
local nodePos = M.nodePos

function M.vehicleName(veh)
	local model = tostring(modelOf(veh) or "vehicle")
	if core_vehicles and type(core_vehicles.getModel) == "function" then
		local ok, info = pcall(core_vehicles.getModel, model)
		local m = ok and type(info) == "table" and info.model
		if type(m) == "table" and m.Name then
			return m.Brand and (tostring(m.Brand) .. " " .. tostring(m.Name)) or tostring(m.Name)
		end
	end
	return (model:gsub("^%l", string.upper))
end

--- A toast; the same text again right away (several straps at once) is shown only once.
function M.message(text)
	if lastMessage and lastMessage.text == text and clock - lastMessage.at < MESSAGE_AGAIN then return end
	lastMessage = {text = text, at = clock}
	U.toast("info", text, 3)
end
local message = M.message

function M.clock() return clock end

--== Ropes =========================================================================

--- A new rope of `kind` on vehicle `id`. tieCommand(rid) returns the vehicle command that ties it
--- (ropeTieRay / ropeTieNearest / ropeTieNode). The rope (a table) is what the apps work with:
---   id, kind, veh            the rope id, its kind, the roped vehicle
---   grip, node               where it is tied (from onRopeTied / onRopeState), the tie node
---   target                   the anchor point; anchorVeh = {id, name, node, hitch} on a vehicle
---   winch, moving, speed, strength   set by the app (tow rope), sent to the vehicle
---   payOutOnce               the next message pays out rope to the anchor (it jumped)
---   strain, slack, length, rate, ropeLoad   from the vehicle
---   wantHookPoints           ask the vehicles near the anchor where it would hook on
---   hookAfterTie = {vid, cid}  hook on there once it is tied (Strap down)
--- and the app's callbacks: update(r, dt) every frame before it is sent, drawEnd(r, a, b, dt)
--- for the anchor's end, anchored(r) once hooked on, gone(r) when it is removed for any reason.
function M.create(kind, id, tieCommand)
	local r = {id = nextId, kind = kind, veh = id, since = SEND_EVERY, silent = 0, strain = 0, slack = true,
		stuckFor = 0, winch = 0, speed = 1, strength = 60}
	nextId = nextId + 1
	ropes[r.id] = r
	sendToVehicle(id, tieCommand(r.id))
	U.log("I", "rope", string.format("rope %d (%s) tied to vehicle %s", r.id, kind == M.STRAP and "strap" or "tow", tostring(id)))
	return r
end

function M.get(rid) return ropes[rid] end

--- All ropes of a kind, oldest first.
function M.list(kind)
	local out = {}
	for _, r in pairs(ropes) do
		if kind == nil or r.kind == kind then table.insert(out, r) end
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

--- Removes a rope; with a text, the player is told why.
function M.release(r, text)
	if not r or ropes[r.id] ~= r then return end
	sendToVehicle(r.veh, string.format("sharedCareerVeh.ropeRelease(%d)", r.id))
	if r.anchorVeh then sendToVehicle(r.anchorVeh.id, string.format("sharedCareerVeh.anchorRelease(%d)", r.id)) end
	if r.hookWanted then sendToVehicle(r.hookWanted.vid, string.format("sharedCareerVeh.anchorRelease(%d)", r.id)) end
	startLetGo(r)
	ropes[r.id] = nil
	if text then message(text) end
	U.log("D", "rope", "rope " .. r.id .. " removed" .. (text and (": " .. text) or ""))
	if r.gone then r.gone(r) end
end

function M.releaseAll(kind)
	for _, r in ipairs(M.list(kind)) do M.release(r) end
end

--- Hooks the rope's other end onto node cid of vehicle vid. The vehicle answers onAnchorNode.
function M.hook(r, vid, cid)
	if not r or r.anchorVeh then return end
	r.hookWanted = {vid = vid, cid = cid}
	sendToVehicle(vid, string.format("sharedCareerVeh.anchorHook(%d, %d)", r.id, cid))
end

--- The rope comes off its anchor vehicle; the anchor stays where it is, in the world.
function M.unhook(r, text)
	if not r or not r.anchorVeh then return end
	sendToVehicle(r.anchorVeh.id, string.format("sharedCareerVeh.anchorRelease(%d)", r.id))
	table.insert(flashes, {pos = r.target, age = 0, off = true})
	r.anchorVeh, r.anchorVel = nil, nil
	r.since = SEND_EVERY
	if text then message(text) end
end

-- The anchor vehicle is gone or was reset: a tow rope's anchor stays in the world, a strap comes off.
local function anchorLost(r, reset)
	if r.kind == M.STRAP then
		M.release(r, reset and "Vehicle reset – straps off" or "Straps off")
	else
		M.unhook(r, reset and "Anchor vehicle reset – anchor dropped" or "Anchor vehicle gone – anchor dropped")
	end
end

function M.stuck(r)
	return r ~= nil and (r.stuckFor or 0) >= STUCK_AFTER
end

--== Hook points near a tow rope's anchor ===========================================

-- A few times per second: ask your vehicles near the anchor where it would hook on (and where
-- their tow hitches are, for the rings).
local function askHookPoints(r, dt)
	if r.anchorVeh or not r.target then return end
	r.sinceHookAsk = (r.sinceHookAsk or HOOK_ASK_EVERY) + dt
	if r.sinceHookAsk < HOOK_ASK_EVERY then return end
	r.sinceHookAsk = 0
	local t = r.target
	local count = type(be.getObjectCount) == "function" and be:getObjectCount() or 0
	for i = 0, count - 1 do
		local veh = be:getObject(i)
		local id = veh and type(veh.getID) == "function" and veh:getID()
		local p = id and type(veh.getPosition) == "function" and vecOf(veh:getPosition())
		if p and M.canHold(veh, id, r.veh) and M.distance(p, t) <= HOOK_SEARCH then
			sendToVehicle(id, string.format("sharedCareerVeh.anchorNear(%d, %.3f, %.3f, %.3f)", r.id, t.x, t.y, t.z))
		end
	end
end

--- The vehicles' answers for the rope: {vid -> {targets = {cid...}, cid (or nil), hitch, at}}.
function M.hookAnswers(r)
	local out = {}
	for vid, a in pairs(r and r.hookPoints or {}) do
		if clock - a.at <= HOOK_KEEP and be:getObjectByID(vid) then out[vid] = a end
	end
	return out
end

--- Where the anchor would hook on now: {vid, cid, hitch, pos, d, name}, or nil.
function M.hookPoint(r)
	if not r or r.anchorVeh or not r.target then return nil end
	local best = nil
	for vid, a in pairs(M.hookAnswers(r)) do
		local veh = a.cid and be:getObjectByID(vid)
		local p = veh and nodePos(veh, a.cid)
		local d = p and M.distance(p, r.target)
		if d and d <= HOOK_REACH and (not best or d < best.d) then
			best = {vid = vid, cid = a.cid, hitch = a.hitch, pos = p, d = d, name = M.vehicleName(veh)}
		end
	end
	return best
end

--== One rope, every frame ===========================================================

-- The anchor node's speed: from its movement since the last frame (it includes the vehicle's
-- turning, which matters for a short strap), the vehicle's own speed when there is no last frame
-- or the node jumped.
local function anchorVelocity(r, av, p, dtSim)
	local vehVel = type(av.getVelocity) == "function" and vecOf(av:getVelocity()) or {x = 0, y = 0, z = 0}
	local prev = r.anchorVeh.prev
	r.anchorVeh.prev = p
	if not prev or dtSim <= 0 then return vehVel end
	local v = {x = (p.x - prev.x) / dtSim, y = (p.y - prev.y) / dtSim, z = (p.z - prev.z) / dtSim}
	if M.distance(v, vehVel) > ANCHOR_TELEPORT then return vehVel end
	return v
end

local function step(r, dt, dtSim)
	local veh = be:getObjectByID(r.veh)
	if not veh or not M.allowed() then
		M.release(r)
		return
	end
	r.silent = r.silent + dtSim
	if r.silent > SILENT_LIMIT then
		U.log("W", "rope", "no word from vehicle " .. tostring(r.veh) .. " for " .. SILENT_LIMIT .. " s")
		local texts = LOST_MESSAGES[r.kind]
		M.release(r, r.grip and texts.silent or texts[0])
		return
	end
	if r.winch == 1 and not r.slack and (r.strain or 0) > 0.95 then
		r.stuckFor = r.stuckFor + dt
	else
		r.stuckFor = 0
	end
	if r.update then r.update(r, dt) end
	if r.anchorVeh then
		-- the anchor rides on a vehicle: its node's position now and its speed, every frame
		local av = be:getObjectByID(r.anchorVeh.id)
		local p = av and nodePos(av, r.anchorVeh.node)
		if p then
			r.anchorVel = anchorVelocity(r, av, p, dtSim)
			r.target = p
			r.since = SEND_EVERY
		else
			anchorLost(r, false)
			if ropes[r.id] ~= r then return end
		end
	end
	if r.wantHookPoints then askHookPoints(r, dt) end
	r.since = r.since + dt
	-- nothing to send until the vehicle has reported where the rope is tied, and the anchor is known
	if r.since < SEND_EVERY or not (r.grip and r.target) then return end
	r.since = 0
	local t = r.target
	local paying = r.moving or r.payOutOnce
	r.payOutOnce = nil
	local v = r.anchorVeh and r.anchorVel or {x = 0, y = 0, z = 0}
	sendToVehicle(r.veh, string.format("sharedCareerVeh.ropeUpdate(%d, %.3f, %.3f, %.3f, %d, %d, %.2f, %.1f, %.3f, %.3f, %.3f, %d)",
		r.id, t.x, t.y, t.z, r.winch, paying and 1 or 0, r.speed, r.strength, v.x, v.y, v.z, r.anchorVeh and 1 or 0))
end

--== Replies from the vehicles =======================================================

function M.onRopeTied(id, rid, t, x, y, z, node)
	local r = ropes[rid]
	if not r or r.veh ~= id then return end
	r.grip = {x = x, y = y, z = z}
	r.node = tonumber(node)
	r.silent = 0
	-- a tow rope's anchor starts at the grip (rope slack) until it is moved
	if r.kind == M.TOW and not r.target then r.target = {x = x, y = y, z = z} end
	if r.hookAfterTie then
		M.hook(r, r.hookAfterTie.vid, r.hookAfterTie.cid)
		r.hookAfterTie = nil
	end
	U.log("D", "rope", string.format("rope %d tied at %.1f m", rid, tonumber(t) or 0))
end

function M.onRopeState(id, rid, x, y, z, strain, slack, length, ropeLoad)
	local r = ropes[rid]
	if not r or r.veh ~= id then return end
	r.grip = {x = x, y = y, z = z}
	r.silent = 0
	-- the winch's load while it hauls in (1 = its limit) and the rope's (1 = it breaks)
	r.strain = math.max(0, math.min(1, tonumber(strain) or 0))
	r.ropeLoad = math.max(0, math.min(1, tonumber(ropeLoad) or 0))
	r.slack = slack == 1 or slack == true
	-- how fast the rope runs through the winch (m/s, < 0 = hauled in), for the marks on the rope
	local newLength = tonumber(length)
	local elapsed = r.lengthAt and clock - r.lengthAt or 0
	if newLength and r.length and elapsed > 0.02 then
		r.rate = (newLength - r.length) / elapsed
		-- faster than the winch or the remote can run it: the anchor jumped ("to my view"), not a
		-- running rope
		if math.abs(r.rate) > math.max(r.speed or 1, 1) * 1.5 then r.rate = 0 end
	end
	r.length, r.lengthAt = newLength, clock
end

--- The vehicle took the rope off (reason: see LOST_MESSAGES).
function M.onRopeLost(id, rid, reason)
	local r = ropes[rid]
	if not r or r.veh ~= id then return end
	U.log("I", "rope", "vehicle " .. tostring(id) .. " lost rope " .. rid .. " (" .. tostring(reason) .. ")")
	M.release(r, LOST_MESSAGES[r.kind][tonumber(reason)] or LOST_MESSAGES[r.kind].silent)
end

--- The roped vehicle reports the rope's pull on the anchor (N): on to the anchor vehicle.
function M.onRopePull(id, rid, fx, fy, fz)
	local r = ropes[rid]
	if not r or r.veh ~= id or not r.anchorVeh then return end
	sendToVehicle(r.anchorVeh.id, string.format("sharedCareerVeh.anchorPull(%d, %.1f, %.1f, %.1f)",
		rid, tonumber(fx) or 0, tonumber(fy) or 0, tonumber(fz) or 0))
end

--- A vehicle near a tow rope's anchor: its tow hitches ("cid,cid,...") and its hook point (cid, -1 = none).
function M.onAnchorNear(id, rid, list, cid, hitch)
	local r = ropes[rid]
	if not r or r.anchorVeh then return end
	local nodes = {}
	for c in tostring(list or ""):gmatch("%d+") do table.insert(nodes, tonumber(c)) end
	cid = tonumber(cid)
	r.hookPoints = r.hookPoints or {}
	r.hookPoints[id] = {targets = nodes, cid = cid and cid >= 0 and cid or nil, hitch = hitch == 1 or hitch == true, at = clock}
end

--- The rope's other end is on a vehicle now (the answer to hook): it sits there from now on and
--- moves with it.
function M.onAnchorNode(id, rid, node, hitch)
	local r = ropes[rid]
	local veh = be:getObjectByID(id)
	if not r or r.anchorVeh or not r.hookWanted or r.hookWanted.vid ~= id or not M.canHold(veh, id, r.veh) then
		sendToVehicle(id, string.format("sharedCareerVeh.anchorRelease(%d)", rid))
		return
	end
	r.hookWanted = nil
	r.anchorVeh = {id = id, name = M.vehicleName(veh), node = tonumber(node), hitch = hitch == 1 or hitch == true}
	r.hookPoints = nil
	r.target = nodePos(veh, r.anchorVeh.node) or r.target
	r.payOutOnce = true -- a tow rope pays out to it (the hook point can be a little away)
	r.since = SEND_EVERY
	if r.target then table.insert(flashes, {pos = r.target, age = 0}) end
	U.log("I", "rope", string.format("rope %d on vehicle %s (%s)", rid, tostring(id), r.anchorVeh.hitch and "tow hitch" or "body"))
	if r.anchored then r.anchored(r) end
end

--- Preview: where a rope would be tied.
function M.onTieProbe(id, x, y, z)
	if probeWant and probeWant.mode == "tie" then probe = {mode = "tie", id = id, x = x, y = y, z = z, age = 0} end
end

--- Preview: where a strap would hook on.
function M.onHookProbe(id, cid, hitch)
	if probeWant and probeWant.mode == "hook" then
		probe = {mode = "hook", id = id, cid = tonumber(cid), hitch = hitch == 1 or hitch == true, age = 0}
	end
end

--== Preview ========================================================================

--- An open app wants the preview this frame: "tie" (where a rope would be tied where you look) or
--- "hook" (where a strap would hook on where you look; except: not on this vehicle).
function M.probe(mode, except)
	probeWant = {mode = mode, except = except, at = clock}
end

--- The app no longer wants the preview (closed, or the rope is on): it goes at once.
function M.stopProbe()
	probeWant, probe = nil, nil
end

--- The preview now: {mode, id, pos, cid, hitch} or nil.
function M.probeResult()
	if not probe then return nil end
	if probe.mode == "tie" then return {mode = "tie", id = probe.id, pos = {x = probe.x, y = probe.y, z = probe.z}} end
	local veh = be:getObjectByID(probe.id)
	local p = veh and nodePos(veh, probe.cid)
	if not p then return nil end
	return {mode = "hook", id = probe.id, pos = p, cid = probe.cid, hitch = probe.hitch}
end

local function updateProbe(dt)
	if probe then
		probe.age = probe.age + dt
		if probe.age > PROBE_KEEP or not probeWant or probe.mode ~= probeWant.mode then probe = nil end
	end
	if not probeWant or not M.allowed() then return end
	sinceProbe = sinceProbe + dt
	if sinceProbe < PROBE_EVERY then return end
	sinceProbe = 0
	-- the apps aim with the middle of the view (the cursor is on the phone)
	local cam, dir = M.cameraPos(), M.viewDir()
	if not (cam and dir) then return end
	local mode, except = probeWant.mode, probeWant.except
	local found = M.vehicleOnRay(cam, dir, function(veh, id)
		if mode == "tie" then return M.canRope(veh, id) end
		return M.canHold(veh, id, except)
	end)
	if not found then return end
	sendToVehicle(found.id, string.format("sharedCareerVeh.%s(%.3f, %.3f, %.3f, %.4f, %.4f, %.4f, %d)",
		mode == "tie" and "tieProbe" or "hookProbe", cam.x, cam.y, cam.z, dir.x, dir.y, dir.z, M.MAX_DISTANCE))
end

--== Drawing =========================================================================

local ROPE_SAFE = 0.4       -- share of the breaking load: up to here the rope keeps its own color
local ROPE_CRITICAL = 0.7  -- from here it is red and trembles
local COLORS = {[M.TOW] = {0.88, 0.84, 0.74}, [M.STRAP] = {1, 0.78, 0.15}}
local ROPE_HIGH = {1, 0.62, 0.12}
local ROPE_RED = {1, 0.15, 0.1}
local RADIUS = {[M.TOW] = 0.02, [M.STRAP] = 0.03} -- m

local function mix(a, b, f)
	return a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f
end

--- The rope's color for its load (share of its breaking load): its own color while safe, yellow
--- to orange when high, red near breaking. kind: TOW (default) or STRAP.
function M.ropeLoadColor(load, kind)
	local own = COLORS[kind or M.TOW]
	local l = math.max(0, math.min(1, tonumber(load) or 0))
	if l <= ROPE_SAFE then return own[1], own[2], own[3] end
	if l <= ROPE_CRITICAL then return mix(own, ROPE_HIGH, (l - ROPE_SAFE) / (ROPE_CRITICAL - ROPE_SAFE)) end
	return mix(ROPE_HIGH, ROPE_RED, math.min(1, (l - ROPE_CRITICAL) / (0.9 - ROPE_CRITICAL)))
end

--- The winch gauge's color for the winch's load (1 = its limit): green -> yellow -> orange.
function M.winchColor(strain)
	local s = math.max(0, math.min(1, tonumber(strain) or 0))
	if s < 0.6 then return mix({0.3, 0.9, 0.4}, {1, 0.85, 0.2}, s / 0.6) end
	return mix({1, 0.85, 0.2}, {1, 0.5, 0.1}, (s - 0.6) / 0.4)
end

local SLACK_COLOR = {0.7, 0.7, 0.7, 0.6}

--- Rope color {r, g, b, a}: grey when slack (taut = 0), the color of its load when taut (taut = 1),
--- blended in between.
function M.ropeColor(load, taut, kind)
	taut = math.max(0, math.min(1, tonumber(taut) or 0))
	local r, g, b = M.ropeLoadColor(load, kind)
	local s = SLACK_COLOR
	return s[1] + (r - s[1]) * taut, s[2] + (g - s[2]) * taut, s[3] + (b - s[3]) * taut, s[4] + (0.9 - s[4]) * taut
end

-- debugDrawer, ColorF and vec3 are engine/library globals: they may be provided lazily (not
-- visible to rawget) and ColorF/vec3 are constructors of type cdata/table, not "function" – so we
-- only check that they exist (0.10.1 checked rawget + "function" and never drew anything).
local canDrawCached = false -- only a positive result is kept; a negative one is checked again
local drawWarned = false
function M.canDraw()
	if canDrawCached then return true end
	local ok, dd, cf, v3 = pcall(function() return debugDrawer, ColorF, vec3 end)
	canDrawCached = ok and dd ~= nil and cf ~= nil and v3 ~= nil
	if canDrawCached then
		U.log("I", "rope", "drawing available (debugDrawer)")
	elseif not drawWarned then
		drawWarned = true
		U.log("W", "rope", "drawing not available: debugDrawer " .. tostring(dd) .. ", ColorF " .. tostring(cf)
			.. ", vec3 " .. tostring(v3))
	end
	return canDrawCached
end

-- The shapes, for the apps' own drawing too (M.shapes).
local shapes = {}
M.shapes = shapes

function shapes.line(a, b, color)
	debugDrawer:drawLine(vec3(a.x, a.y, a.z), vec3(b.x, b.y, b.z), color)
end
local line = shapes.line

local function cross(p, size, color)
	line({x = p.x - size, y = p.y, z = p.z}, {x = p.x + size, y = p.y, z = p.z}, color)
	line({x = p.x, y = p.y - size, z = p.z}, {x = p.x, y = p.y + size, z = p.z}, color)
	line({x = p.x, y = p.y, z = p.z - size}, {x = p.x, y = p.y, z = p.z + size}, color)
end

-- shapes beyond lines: tried once each; a failure is logged once and that shape falls back
local shapeBroken = {}
local function tryShape(name, fn)
	if shapeBroken[name] then return false end
	local ok, err = pcall(fn)
	if not ok then
		shapeBroken[name] = true
		U.log("W", "rope", "debugDrawer:" .. name .. " not available, using lines instead: " .. tostring(err))
	end
	return ok
end

--- Forget which shapes failed (tests; the game keeps the result for the session).
function M.resetShapes() shapeBroken = {} end

function shapes.cylinder(a, b, radius, color)
	return tryShape("drawCylinder", function()
		debugDrawer:drawCylinder(vec3(a.x, a.y, a.z), vec3(b.x, b.y, b.z), radius, color)
	end)
end
local cylinder = shapes.cylinder

function shapes.ball(p, radius, color)
	local ok = tryShape("drawSphere", function()
		debugDrawer:drawSphere(vec3(p.x, p.y, p.z), radius, color)
	end)
	if not ok then cross(p, radius * 1.6, color) end
end
local ball = shapes.ball

function shapes.sign(p, text)
	tryShape("drawTextAdvanced", function()
		local str = String and String(text) or text
		debugDrawer:drawTextAdvanced(vec3(p.x, p.y, p.z), str, ColorF(1, 1, 1, 1), true, false,
			ColorI(20, 20, 24, 190))
	end)
end

-- A flat circle (lines): hitch rings, hook points, flashes.
function shapes.circle(p, r, color)
	local prev = nil
	for i = 0, 16 do
		local a = i / 16 * 2 * math.pi
		local q = {x = p.x + math.cos(a) * r, y = p.y + math.sin(a) * r, z = p.z}
		if prev then line(prev, q, color) end
		prev = q
	end
end
local circle = shapes.circle

-- A dashed line from a to b.
function shapes.dashed(a, b, color)
	local steps = math.max(1, math.floor(M.distance(a, b) / 0.2))
	for i = 0, steps - 1, 2 do
		local f0, f1 = i / steps, math.min(1, (i + 1) / steps)
		line({x = a.x + (b.x - a.x) * f0, y = a.y + (b.y - a.y) * f0, z = a.z + (b.z - a.z) * f0},
			{x = a.x + (b.x - a.x) * f1, y = a.y + (b.y - a.y) * f1, z = a.z + (b.z - a.z) * f1}, color)
	end
end

M.PIN_HEIGHT = 0.6         -- m: the anchor's post, from the anchor point up
local PIN_BALL = 0.12      -- m: radius of the ball on top
function shapes.pin(p, color, pulse)
	local top = {x = p.x, y = p.y, z = p.z + M.PIN_HEIGHT}
	if not cylinder(p, top, 0.02, color) then line(p, top, color) end
	ball(top, PIN_BALL * (pulse or 1), color)
	ball(p, 0.05, color)
end
local pin = shapes.pin

-- A hook point: a ring with a ball, green on a tow hitch, white elsewhere; pulsing gently.
function shapes.hookPoint(p, hitch)
	local pulse = 1 + 0.15 * math.sin(clock * 2 * math.pi * 2)
	local color = hitch and ColorF(0.4, 0.95, 0.55, 0.95) or ColorF(1, 1, 1, 0.9)
	circle(p, 0.2 * pulse, color)
	ball(p, 0.07, color)
end

-- how deep a slack rope sags in the middle: a parabola over the horizontal span d whose length is
-- about the rope length L (L ~ d + 8 s^2 / 3d), at most half the rope (hanging straight down)
local SAG_SEGMENTS = 12
local SAG_RATE = 8         -- 1/s: how fast the drawn sag follows the rope
local SAG_MAX = 6          -- m
local FADE_RATE = 6        -- 1/s: how fast the rope color follows slack and taut
local LOAD_FALL = 1.5      -- per s: how fast the shown rope load falls back after a jolt
local TREMBLE = 0.06       -- m: how much a rope near breaking trembles
function M.sagDepth(span, horizontal, length)
	span, horizontal, length = tonumber(span) or 0, tonumber(horizontal) or 0, tonumber(length) or 0
	if span < 0.05 or length <= span then return 0 end
	local s = math.sqrt(3 * span * (length - span) / 8)
	s = math.min(s, length / 2, SAG_MAX)
	-- a steep rope hangs along itself rather than below it
	return s * math.max(0, math.min(1, horizontal / span))
end

-- a point on the rope from a (t = 0) to b (t = 1) that sags `sag` m in the middle (< 0: bulges up)
local function ropePoint(a, b, sag, t)
	return {x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t - 4 * sag * t * (1 - t)}
end

-- the rope: lines (visible from any distance) inside thin cylinders (its body up close)
local function rope(a, b, sag, color, radius)
	if math.abs(sag) < 0.02 then
		line(a, b, color)
		cylinder(a, b, radius, color)
		return
	end
	local prev = a
	for i = 1, SAG_SEGMENTS do
		local p = ropePoint(a, b, sag, i / SAG_SEGMENTS)
		line(prev, p, color)
		cylinder(prev, p, radius, color)
		prev = p
	end
end

-- Marks on a running rope: short light pieces every MARK_SPACING m, `phase` m along the rope from
-- the anchor (b); `visible` 0..1 fades them in and out.
local MARK_SPACING = 0.6   -- m
local MARK_LENGTH = 0.12   -- m
local MARK_MIN_RATE = 0.05 -- m/s: a slower rope shows no marks (the length comes rounded to cm)
local MARK_FULL_RATE = 0.15 -- m/s: from this speed on the marks are fully visible
local RATE_RATE = 4        -- 1/s: how fast the shown rope speed follows the reported one
local RATE_STALE = 0.4     -- s without a report: the rope counts as standing
local function winchMarks(a, b, sag, rgba, phase, visible)
	local span = M.distance(a, b)
	if span < MARK_SPACING then return end
	local color = ColorF(rgba[1] + (1 - rgba[1]) * 0.6, rgba[2] + (1 - rgba[2]) * 0.6, rgba[3] + (1 - rgba[3]) * 0.6,
		rgba[4] * visible)
	local s = phase % MARK_SPACING
	while s + MARK_LENGTH < span do
		local from, to = ropePoint(a, b, sag, 1 - (s + MARK_LENGTH) / span), ropePoint(a, b, sag, 1 - s / span)
		line(from, to, color)
		cylinder(from, to, RADIUS[M.TOW] * 1.8, color)
		s = s + MARK_SPACING
	end
end

-- Where the rope is tied, now: the tie node's position from the vehicle every frame
-- (veh:getNodePosition is relative to the vehicle's position), otherwise the last report. A
-- position far from the last report is not trusted (the vehicle reports 10 times per second).
local NODE_TRUST = 3       -- m
function M.gripNow(r)
	local reported = r and r.grip
	if not reported then return nil end
	local p = r.node and nodePos(be:getObjectByID(r.veh), r.node)
	if not p or M.distance(p, reported) > NODE_TRUST then return reported end
	return p
end

M.ANCHOR_RESTING = {1, 1, 1, 0.8}

-- Let go: the rope as it was last drawn, animated for a moment after it came off. A taut rope
-- snaps back to the anchor (its loose end flies there, the rope whips up and down), a slack one
-- drops (its loose end falls, the rope sags deeper); both fade out, a tow rope's anchor with them.
local SNAP_TIME = 0.35     -- s
local DROP_TIME = 0.6      -- s
local DROP_MAX = 1.5       -- m the loose end falls at most
local WHIP = 0.08          -- whip height per m of rope (at most WHIP_MAX)
local WHIP_MAX = 0.5       -- m
local GRAVITY = 9.81
local FLASH_TIME = 0.5     -- s of the hook-on flash

function startLetGo(r)
	local shown = r and r.shown
	if not shown then return end
	local snap = (r.shownTaut or 0) > 0.5
	table.insert(letGo, {a = shown.a, b = shown.b, rgba = shown.rgba, sag = shown.sag, snap = snap, age = 0,
		time = snap and SNAP_TIME or DROP_TIME, kind = r.kind, onVehicle = shown.onVehicle})
end

local function drawLetGo(g, dt)
	g.age = g.age + dt
	local f = g.age / g.time
	if f >= 1 then return false end
	local a, b, c = g.a, g.b, g.rgba
	local loose, sag
	if g.snap then
		local whip = math.min(WHIP_MAX, WHIP * M.distance(a, b))
		loose = ropePoint(a, b, 0, 1 - (1 - f) ^ 3) -- fast at first, then slowing down at the anchor
		sag = -whip * math.sin(f * math.pi * 3) * (1 - f)
	else
		local fall = math.min(DROP_MAX, 0.5 * GRAVITY * g.age * g.age)
		loose = {x = a.x, y = a.y, z = a.z - fall}
		sag = g.sag + fall / 2
	end
	local fade = 1 - f
	rope(loose, b, sag, ColorF(c[1], c[2], c[3], c[4] * fade), RADIUS[g.kind])
	if g.kind == M.TOW and not g.onVehicle then
		local rest = M.ANCHOR_RESTING
		pin(b, ColorF(rest[1], rest[2], rest[3], rest[4] * fade))
	end
	return true
end

-- A flash: a growing, fading ring.
local function drawFlash(fx, dt)
	fx.age = fx.age + dt
	local f = fx.age / FLASH_TIME
	if f >= 1 then return false end
	local color = fx.off and ColorF(1, 0.6, 0.15, 0.9 * (1 - f)) or ColorF(0.4, 1, 0.55, 0.9 * (1 - f))
	circle(fx.pos, 0.2 + 0.7 * f, color)
	circle(fx.pos, 0.1 + 0.35 * f, color)
	ball(fx.pos, 0.12 * (1 - f), color)
	return true
end

-- One rope: color by its load and slack, sag, trembling near breaking, marks while it runs.
local function drawRope(r, dt)
	-- color: the rope's load (a jump up shows at once, it fades back slowly so a short jolt is
	-- seen) and slack/taut, smoothly
	local k = 1 - math.exp(-FADE_RATE * dt)
	local taut = r.slack and 0 or 1
	local load = r.ropeLoad or 0
	r.shownLoad = math.max(load, (r.shownLoad or 0) - LOAD_FALL * dt)
	r.shownTaut = (r.shownTaut or taut) + (taut - (r.shownTaut or taut)) * k
	local rgba = {M.ropeColor(r.shownLoad, r.shownTaut, r.kind)}
	local color = ColorF(rgba[1], rgba[2], rgba[3], rgba[4])
	local a, b = M.gripNow(r), r.target
	local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
	local span = math.sqrt(dx * dx + dy * dy + dz * dz)
	local want = r.slack and M.sagDepth(span, math.sqrt(dx * dx + dy * dy), r.length) or 0
	local ks = 1 - math.exp(-SAG_RATE * dt)
	r.sag = (r.sag or want) + (want - (r.sag or want)) * ks
	-- near breaking the rope trembles
	local tremble = 0
	if r.shownLoad > ROPE_CRITICAL and not r.slack then
		tremble = TREMBLE * math.min(1, (r.shownLoad - ROPE_CRITICAL) / (1 - ROPE_CRITICAL)) * math.sin(clock * 2 * math.pi * 14)
	end
	rope(a, b, r.sag + tremble, color, RADIUS[r.kind])
	if r.kind == M.TOW then
		-- marks travelling with the rope while it runs through the winch
		local rate = clock - (r.lengthAt or clock) < RATE_STALE and r.rate or 0
		r.shownRate = (r.shownRate or 0) + ((rate or 0) - (r.shownRate or 0)) * (1 - math.exp(-RATE_RATE * dt))
		r.markPhase = (r.markPhase or 0) + r.shownRate * dt
		local speed = math.abs(r.shownRate)
		if speed >= MARK_MIN_RATE then
			winchMarks(a, b, r.sag, rgba, r.markPhase, math.min(1, speed / MARK_FULL_RATE))
		end
	end
	ball(a, r.kind == M.STRAP and 0.06 or 0.09, color)
	r.shown = {a = a, b = {x = b.x, y = b.y, z = b.z}, rgba = rgba, sag = r.sag, onVehicle = r.anchorVeh ~= nil}
	if r.drawEnd then r.drawEnd(r, a, b, dt) end
end

-- The preview: a blue ball where a rope would be tied, a hook point where a strap would hook on.
local function drawProbe()
	local p = M.probeResult()
	if not p then return end
	if p.mode == "tie" then
		ball(p.pos, 0.12 * (1 + 0.12 * math.sin(clock * 2 * math.pi)), ColorF(0.3, 0.8, 1, 0.45))
	else
		shapes.hookPoint(p.pos, p.hitch)
	end
end

function M.draw(dt)
	dt = math.max(0, tonumber(dt) or 0)
	clock = clock + dt
	if not next(ropes) and not probe and #letGo == 0 and #flashes == 0 then return end
	if not M.canDraw() then return end
	for i = #letGo, 1, -1 do
		if not drawLetGo(letGo[i], dt) then table.remove(letGo, i) end
	end
	for i = #flashes, 1, -1 do
		if not drawFlash(flashes[i], dt) then table.remove(flashes, i) end
	end
	for _, r in ipairs(M.list()) do
		if r.grip and r.target then drawRope(r, dt) end
	end
	drawProbe()
end

--== Hooks =========================================================================

function M.onUpdate(dtReal, dtSim)
	local dt = math.min(MAX_STEP, math.max(0, tonumber(dtReal) or 0))
	local dts = math.max(0, tonumber(dtSim) or dt)
	for _, r in ipairs(M.list()) do
		if ropes[r.id] == r then
			local ok, err = pcall(step, r, dt, dts)
			if not ok then
				U.log("E", "rope", "rope " .. r.id .. " failed: " .. tostring(err))
				M.release(r)
			end
		end
	end
	if probeWant and clock - probeWant.at > PROBE_WANTED then probeWant = nil end
	if U.isMP() then pcall(updateProbe, dt) end
	local ok, err = pcall(M.draw, tonumber(dtReal) or 0)
	if not ok and not drawErrorLogged then
		drawErrorLogged = true
		U.log("E", "rope", "drawing failed: " .. tostring(err))
	end
end

function M.onVehicleDestroyed(id)
	for _, r in ipairs(M.list()) do
		if r.veh == id then
			M.release(r)
		elseif r.anchorVeh and r.anchorVeh.id == id then
			anchorLost(r, false)
		end
	end
end

-- reset (R, recovery, a new config): the vehicle is somewhere else now, the old rope would pull it
-- back (the vehicle's own onReset drops it too)
function M.onVehicleResetted(id)
	for _, r in ipairs(M.list()) do
		if r.veh == id then
			M.release(r, LOST_MESSAGES[r.kind][1])
		elseif r.anchorVeh and r.anchorVeh.id == id then
			anchorLost(r, true)
		end
	end
end

function M.onBeamMPServerLeave()
	M.releaseAll()
	probe, probeWant = nil, nil
	letGo, flashes = {}, {}
end

function M.onConfigChanged()
	if not M.allowed() then M.releaseAll() end
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
