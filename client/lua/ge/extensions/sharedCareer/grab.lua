-- SharedCareer :: our own node grabber as a rope with a winch – move vehicles slowly, by hand
--
-- The game's node grabber is weak in the career (the engine limits its force; a mod can't change
-- that). This is our own, built for moving vehicles that can't drive, e.g. onto a tow truck.
-- It is used only through the phone app "Tow" (phone.lua), as a remote control:
--
--   attach    where you look (middle of the view), or to one of your vehicles nearby (the point
--             of that vehicle closest to you)
--   anchor    buttons forward/back/left/right (as seen from the camera) and up/down, hold to move;
--             "to my view" puts it in the middle of the view; fine mode = quarter speed
--   winch     haul in (pulls the vehicle slowly to the anchor) / stop (the vehicle hangs on the
--             rope) / pay out
--   anchor on a vehicle   bring the anchor to a tow hitch of another of your vehicles (also the
--             one you sit in) and let go of the remote – or back that vehicle up to the resting
--             anchor – and it hooks on by itself (within 0.7 m of a hitch, or touching the body: then
--             on that point). It hooks on when you let go, never while you hold a button, so you can
--             move past hitches. Rings show the hitches near the anchor; they light up as it gets
--             close ("Let go to hook on" over the anchor), a green flash shows it hooked on. The
--             anchor then moves with that vehicle – drive off and you tow on the rope, or haul in with
--             the winch "on" the tow truck. Its position and speed go to the roped vehicle every
--             frame, the rope's pull comes back (onRopePull) and goes on to the anchor vehicle
--             (anchorPull), so it feels the load.
--             Off again: hold an arrow for PULL_OFF s (a ring fills, the anchor tugs; a short tap does
--             nothing) and it pops off (an orange flash) and moves on while you hold – let go at
--             another hitch (or the same one) and it hooks on there. Not while the anchor vehicle
--             drives faster than PULL_MAX_SPEED. The middle button pops it off at once and puts it
--             in the view. "Detach" in the Tow app leaves it where it is and it doesn't hook on by
--             itself until you moved it once. If the anchor vehicle is gone or reset, the anchor
--             stays where it was
--   strength  30/60/100/150 % of the vehicle's weight
--   to road  the game's own recovery "Tow to road" for the vehicle on the rope, or without a rope
--             for the vehicle you look at; free of charge (see "Tow to the road" below)
--   remove
-- The blue preview of where a rope would attach only shows while the Tow app is open.
--
-- The rope only pulls when it is taut, never pushes; moving the anchor pays out rope, so the
-- vehicle only moves when the winch runs.
--
-- The force itself is computed in the vehicle (sharedCareerVeh.handGrabRay / handGrabNearest /
-- handRope / handRelease in lua/vehicle/extensions/auto/sharedCareerVeh.lua). Here we only pick
-- the vehicle and send the view ray and the anchor. The vehicle ties the rope to the node closest
-- to the ray (the rope goes where you look at the vehicle) and reports back: onGrip (tie node,
-- its position and distance), onHandState (tie position, winch load, slack, rope length, rope
-- load, 10 times per second), onHandLost (the rope came off: reset, teleported, part torn off, rope snapped, nothing
-- to grab),
-- onProbe (preview). The rope state only goes to the vehicle once it has reported its grip.
--
-- Staying in step with the vehicle:
--   * vehicle reset (onVehicleResetted, and the vehicle's own onReset) or removed: rope removed
--   * no word from the vehicle for SILENT_LIMIT s of game time (its Lua was reloaded, or the grab
--     never answered): rope removed – a paused game doesn't count
--   * a long frame (a hitch) moves the anchor at most MAX_STEP s worth
--
-- What you see (debugDrawer, like the game's own markers):
--   rope      from the tie node to the anchor, a thin cylinder with a line inside (the line keeps
--             it visible from far away): grey = slack; when taut, the color shows the rope's own
--             load, measured against its breaking load (ropeLoad): rope-colored while it is safe,
--             yellow to orange when it gets high, red and trembling near breaking. The winch at its
--             limit is no danger for the rope, so it doesn't color it (see "winch gauge"). A slack rope sags (a curve as long as the rope); it straightens
--             smoothly when it is pulled taut. The rope end follows the tie node every frame
--             (veh:getNodePosition), not only when the vehicle reports
--             While the rope runs through the winch (hauling in, paying out, or paying out while
--             the anchor moves), light marks on it travel with the rope: towards the anchor when
--             it is hauled in, towards the vehicle when it pays out. Their speed is the rope's own
--             (from the reported rope length), so they stand still when the vehicle is stuck
--   let go    when the rope comes off (removed, reset, torn loose, vehicle gone) it doesn't just
--             vanish: a taut rope snaps back to the anchor with a short whip, a slack one drops;
--             both fade out within a fraction of a second, and the anchor with them
--   winch gauge   above the anchor (where the portable winch sits), while it hauls in: a small
--             ring that always faces you and fills with the winch's load (share of its pull limit),
--             green -> yellow -> orange; at the limit it blinks red. A small drum in its middle.
--             With the Tow app open, a sign above shows "Winch 72 %" (stopped: "Locked")
--   grip      a small ball on the tie node, in the rope's color
--   anchor    a pin (post with a ball on top): white = resting, cyan = being moved, orange =
--             hauling in (the ball pulses), purple = paying out. Above the ground a dashed drop
--             line and a disc on the ground show where it is. While the Tow app is open, a sign
--             above it shows "Anchor · <distance to the grip>" and "at the limit" when the rope
--             has pulled at its limit for STUCK_AFTER s
--   preview   while the Tow app is open, looking at one of your vehicles: a see-through, gently
--             pulsing ball where the rope would attach
-- Balls, cylinders and the sign use debugDrawer:drawSphere/drawCylinder/drawTextAdvanced; if one
-- of them is missing or fails, that shape is drawn with lines (or left out, for the sign and the
-- rope's cylinder). The ground comes from castRayStatic; without it there is no ground marker.
--
-- Only your own vehicles (incl. your own traffic): other players' vehicles are simulated on
-- their PCs, BeamMP would put them back immediately. Not the player on foot.
-- Server settings: client.allowGrab (on/off), client.grabSpeed (m/s the winch hauls in at most),
-- client.grabStrength (the highest force limit a player may pick, in % of the vehicle's weight).
-- Each player picks the strength in the Tow app (30/60/100/150 %, capped at client.grabStrength).
-- client.allowTowToRoad (on/off): the "Tow to the road" button.

local M = {}

local U

local MAX_DISTANCE = 120   -- m, how far away a vehicle can be grabbed
local MIN_DISTANCE = 3     -- m, closest "to my view" puts the anchor
local SEND_EVERY = 1 / 30  -- s: how often the target point is sent to the vehicle

local PROBE_EVERY = 0.2    -- s: how often the preview asks the vehicle where it would grab
local PROBE_KEEP = 0.5     -- s: how long a preview answer is shown

local NUDGE_SPEED = 1      -- m/s the anchor moves while a remote button is held
local FINE = 0.25          -- fine mode: speed factor for the winch and the anchor
local NEARBY_RANGE = 60    -- m: vehicles listed in the Tow app
local APP_PUSH_EVERY = 0.2 -- s: how often the Tow app gets the state while it's open

local SILENT_LIMIT = 2     -- s of game time without word from the vehicle: the rope is gone
local MAX_STEP = 0.1       -- s: the longest frame the anchor remote works with
local STUCK_AFTER = 2      -- s at the force limit: shown as "at the limit"

-- what the vehicle reports with onHandLost(id, reason)
local LOST_MESSAGES = {
	[0] = "Can't attach the rope there",
	[1] = "Vehicle reset – rope off",
	[2] = "Vehicle moved – rope off",
	[3] = "The part tore off – rope off",
	[4] = "The rope snapped",
}

local held = nil           -- {id, since, silent, node (tie node), grip = {x, y, z}, target (= anchor),
                           --  strain, slack, stuckFor, winch (1 haul in, 0 stop, -1 pay out), placed,
                           --  nudge, length, lengthAt, rate, ropeLoad, shownLoad, shownTaut, sag, shownRate,
                           --  markPhase, shown (what was drawn last: for the let-go animation),
                           --  anchorVeh = {id, name, node, hitch} (anchor on a vehicle),
                           --  snapTargets = {[vehicle id] = {nodes, at}} (tow hitches near the
                           --  anchor), sinceSnap, unarmed (detached: no hooking on until moved),
                           --  pull = {n, t} (an arrow held while hooked on: pulling it off),
                           --  pullBlocked (the anchor vehicle drives: no pulling off)}
local fine = false         -- fine mode (Tow app)
local STRENGTHS = {30, 60, 100, 150} -- strength choices in the Tow app (% of the vehicle's weight)
local strengthPick = 60    -- the player's pick in the Tow app
local appOpen = false      -- the Tow app is open on the phone
local sinceAppPush = 0
local probe = nil          -- {id, x, y, z, age}
local sinceProbe = 0
local drawErrorLogged = false
local letGo = nil          -- the rope that just came off, while it snaps back or drops (see Drawing)
local clock = 0            -- s of real time, for the pulsing balls and the rope's speed
local pushApp              -- defined with the Tow app below
local anchorPoint          -- defined with "Anchor on a vehicle" below
local nudgeVector          -- defined before M.step below
local vehicleName          -- defined with the Tow app below
local startLetGo           -- defined with the drawing below

local function allowed()
	local c = U.config()
	return c ~= nil and c.allowGrab == true
end

local function towToRoadAllowed()
	local c = U.config()
	return allowed() and c.allowTowToRoad == true
end

local function numberSetting(key, default, lo, hi)
	local c = U.config()
	local v = c and tonumber(c[key])
	if not v or v <= 0 then return default end
	return math.max(lo, math.min(hi, v))
end

-- m/s the grip moves at most, and the force limit in % of the vehicle's weight
local function grabSpeed() return numberSetting("grabSpeed", 1, 0.2, 5) end
local function maxStrength() return numberSetting("grabStrength", 150, 10, 150) end
local function grabStrength() return math.min(strengthPick, maxStrength()) end

local function sendToVehicle(id, cmd)
	local veh = be:getObjectByID(id)
	if veh and type(veh.queueLuaCommand) == "function" then
		veh:queueLuaCommand("if sharedCareerVeh then " .. cmd .. " end")
	end
end

local function vecOf(v)
	if v == nil then return nil end
	return {x = tonumber(v.x) or 0, y = tonumber(v.y) or 0, z = tonumber(v.z) or 0}
end

local function cameraPos()
	if core_camera and type(core_camera.getPosition) == "function" then
		local ok, p = pcall(core_camera.getPosition)
		if ok and p then return vecOf(p) end
	end
	return nil
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

local function message(text)
	U.toast("info", text, 3)
end

--== Grabbing ==================================================================

--- Removes the rope; with a text, the player is told why.
function M.release(text)
	if not held then return end
	sendToVehicle(held.id, "sharedCareerVeh.handRelease()")
	if held.anchorVeh then sendToVehicle(held.anchorVeh.id, "sharedCareerVeh.anchorRelease()") end
	startLetGo(held)
	held = nil
	if text then message(text) end
	U.log("D", "grab", "vehicle released" .. (text and (": " .. text) or ""))
end

--- Winch: 1 haul in, 0 stop, -1 pay out.
function M.setWinch(mode)
	if not held then return false end
	mode = tonumber(mode) or 0
	held.winch = mode > 0 and 1 or (mode < 0 and -1 or 0)
	held.since = SEND_EVERY
	return true
end

-- Camera view direction (unit vector) or nil.
local function viewDir()
	if not (core_camera and type(core_camera.getForward) == "function") then return nil end
	local ok, f = pcall(core_camera.getForward)
	f = ok and vecOf(f)
	if not f then return nil end
	local len = math.sqrt(f.x * f.x + f.y * f.y + f.z * f.z)
	if len < 0.01 then return nil end
	return {x = f.x / len, y = f.y / len, z = f.z / len}
end

-- The vehicle closest to the aim line: {veh, id, t (distance along the line), miss (distance
-- from the line)}, or nil. The ray cast itself doesn't report vehicles in every game version,
-- so we search the vehicles ourselves.
local function vehicleOnRay(cam, dir)
	local best = nil
	local count = type(be.getObjectCount) == "function" and be:getObjectCount() or 0
	for i = 0, count - 1 do
		local veh = be:getObject(i)
		if veh and type(veh.getPosition) == "function" and type(veh.getID) == "function" then
			local p = vecOf(veh:getPosition())
			local rx, ry, rz = p.x - cam.x, p.y - cam.y, p.z - cam.z
			local t = rx * dir.x + ry * dir.y + rz * dir.z
			if t > 0.5 and t <= MAX_DISTANCE then
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
M.vehicleOnRay = vehicleOnRay

-- Can a rope go on this vehicle (and can it be towed to the road)? Returns true, or false and a
-- message.
local function canRope(veh, id)
	if not veh or type(veh.queueLuaCommand) ~= "function" then return false, "Look at one of your vehicles" end
	local model = veh.JBeam
	if model == nil and type(veh.getJBeamFilename) == "function" then model = veh:getJBeamFilename() end
	if model == "unicycle" then return false, "Not on players on foot" end
	if not isOwnVehicle(id) then return false, "Only your own vehicles" end
	local freeCam = core_camera and type(core_camera.getActiveGlobalCameraName) == "function"
		and core_camera.getActiveGlobalCameraName()
	if id == be:getPlayerVehicleID(0) and not freeCam then
		return false, "Get out first (or use the free camera)"
	end
	return true
end

local function startRope(id, dist, cmd)
	held = {id = id, since = SEND_EVERY, silent = 0, strain = 0, slack = true, stuckFor = 0, winch = 0,
		placed = false}
	probe = nil
	letGo = nil
	sendToVehicle(id, cmd)
	U.log("I", "grab", string.format("rope attached to vehicle %s at %.1f m", tostring(id), dist))
end

-- Attach where you look (the middle of the view; the cursor is on the phone).
local function attachAtView()
	if not allowed() then
		message("Ropes are off on this server")
		return false
	end
	local cam, dir = cameraPos(), viewDir()
	local found = cam and dir and vehicleOnRay(cam, dir)
	local ok, err = canRope(found and found.veh, found and found.id)
	if not ok then
		message(err)
		return false
	end
	-- the vehicle grabs the node closest to the aim line and reports it back (onGrip)
	startRope(found.id, found.t, string.format("sharedCareerVeh.handGrabRay(%.3f, %.3f, %.3f, %.4f, %.4f, %.4f, %d, %.2f, %.1f)",
			cam.x, cam.y, cam.z, dir.x, dir.y, dir.z, MAX_DISTANCE, grabSpeed(), grabStrength()))
	return true
end

-- One step (every frame): while a remote button is held, the anchor moves; the rope state goes
-- to the vehicle about 30 times per second. dtSim: game time (0 while paused), for the watchdog.
--== Anchor on a vehicle ===========================================================

-- A node's position now: the vehicle's position + getNodePosition (relative to it), or nil.
function anchorPoint(veh, node)
	if not (veh and node and type(veh.getNodePosition) == "function" and type(veh.getPosition) == "function") then return nil end
	local ok, rel = pcall(veh.getNodePosition, veh, node)
	local base = vecOf(veh:getPosition())
	rel = ok and vecOf(rel)
	if not (rel and base) then return nil end
	return {x = base.x + rel.x, y = base.y + rel.y, z = base.z + rel.z}
end

-- Can the anchor hook onto this vehicle? One of your own (also the one you sit in), not the roped
-- one, not a player on foot.
local function canAnchor(veh, id)
	if not held or not veh or type(veh.queueLuaCommand) ~= "function" or id == held.id then return false end
	local model = veh.JBeam
	if model == nil and type(veh.getJBeamFilename) == "function" then model = veh:getJBeamFilename() end
	return model ~= "unicycle" and isOwnVehicle(id)
end

local SNAP_EVERY = 0.2      -- s between two questions to the vehicles near the anchor
local SNAP_SEARCH = 8      -- m from a vehicle's position: it is asked whether the anchor hooks on
local PULL_OFF = 0.6        -- s an arrow is held before the anchor pops off its vehicle
local PULL_MAX_SPEED = 1   -- m/s: an anchor vehicle driving faster can't have it pulled off
local POP_DISTANCE = 0.35  -- m the anchor jumps off the hitch in the arrow's direction
local TARGETS_KEEP = 0.6   -- s the rings of a vehicle's hitches stay without a new answer
local snapFx = nil         -- {pos, age, off}: the flash where the anchor just hooked on (off: popped off)

-- A few times per second: ask your vehicles near the anchor whether it hooks on (and where their
-- tow hitches are, for the rings).
local function askSnap(dt)
	if held.anchorVeh or not held.target or not held.grip then return end
	held.sinceSnap = (held.sinceSnap or SNAP_EVERY) + dt
	if held.sinceSnap < SNAP_EVERY then return end
	held.sinceSnap = 0
	local t = held.target
	-- it hooks on only when nobody holds a button (it hooks on when you let go) and not right
	-- after "Detach" (until you moved it once)
	local canSnap = not held.nudge and not held.unarmed
	local count = type(be.getObjectCount) == "function" and be:getObjectCount() or 0
	for i = 0, count - 1 do
		local veh = be:getObject(i)
		local id = veh and type(veh.getID) == "function" and veh:getID()
		local p = id and type(veh.getPosition) == "function" and vecOf(veh:getPosition())
		if p and canAnchor(veh, id) then
			local dx, dy, dz = p.x - t.x, p.y - t.y, p.z - t.z
			if dx * dx + dy * dy + dz * dz <= SNAP_SEARCH * SNAP_SEARCH then
				sendToVehicle(id, string.format("sharedCareerVeh.anchorNear(%.3f, %.3f, %.3f, %d)", t.x, t.y, t.z,
					canSnap and 1 or 0))
			end
		end
	end
end

--- A vehicle near the anchor names its tow hitches ("cid,cid,..."), for the rings.
function M.onAnchorTargets(id, list)
	if not held or held.anchorVeh then return end
	local nodes = {}
	for cid in tostring(list or ""):gmatch("%d+") do table.insert(nodes, tonumber(cid)) end
	held.snapTargets = held.snapTargets or {}
	held.snapTargets[id] = #nodes > 0 and {nodes = nodes, at = clock} or nil
end

--- The anchor hooked onto a vehicle (its tow hitch, or the point it touches): it sits there from
--- now on and moves with it (the rope pays out to it).
function M.onAnchorNode(id, node, hitch)
	local veh = be:getObjectByID(id)
	if not held or held.anchorVeh or held.nudge or held.unarmed or not canAnchor(veh, id) then
		sendToVehicle(id, "sharedCareerVeh.anchorRelease()")
		return
	end
	held.anchorVeh = {id = id, name = vehicleName(veh), node = tonumber(node), hitch = hitch == 1 or hitch == true}
	held.snapTargets = nil
	held.placed = true
	held.payOutOnce = true
	held.since = SEND_EVERY
	snapFx = {pos = anchorPoint(veh, held.anchorVeh.node) or held.target, age = 0}
	message("Hooked onto the " .. held.anchorVeh.name)
	U.log("I", "grab", string.format("anchor on vehicle %s (%s)", tostring(id), held.anchorVeh.hitch and "tow hitch" or "body"))
	pushApp()
end

--- The anchor comes off its vehicle and stays where it is, in the world. moving: the player
--- pulled it off and moves it on (it may hook on again when let go); otherwise ("Detach", the
--- vehicle gone or reset) it doesn't hook on by itself until moved once.
function M.detachAnchor(text, moving)
	if not held or not held.anchorVeh then return end
	sendToVehicle(held.anchorVeh.id, "sharedCareerVeh.anchorRelease()")
	held.anchorVeh, held.pull, held.pullBlocked = nil, nil, nil
	held.unarmed = not moving
	held.since = SEND_EVERY
	if text then message(text) end
	pushApp()
end

--- The roped vehicle reports the rope's pull on the anchor (N): on to the anchor vehicle.
function M.onRopePull(id, fx, fy, fz)
	if not held or held.id ~= id or not held.anchorVeh then return end
	sendToVehicle(held.anchorVeh.id, string.format("sharedCareerVeh.anchorPull(%.1f, %.1f, %.1f)",
		tonumber(fx) or 0, tonumber(fy) or 0, tonumber(fz) or 0))
end

-- The remote's direction (f = forward, r = right, u = up) in the world, as seen from the camera.
function nudgeVector(n)
	local f = viewDir() or {x = 0, y = 1, z = 0}
	local len = math.sqrt(f.x * f.x + f.y * f.y)
	local fx, fy = 0, 1
	if len > 0.01 then fx, fy = f.x / len, f.y / len end
	local rx, ry = fy, -fx
	return {x = fx * n.f + rx * n.r, y = fy * n.f + ry * n.r, z = n.u}
end

function M.step(dt, dtSim)
	if not held then return end
	dt = math.min(MAX_STEP, math.max(0, tonumber(dt) or 0))
	local veh = be:getObjectByID(held.id)
	if not veh or not allowed() then
		M.release()
		return
	end
	held.silent = held.silent + math.max(0, tonumber(dtSim) or dt)
	if held.silent > SILENT_LIMIT then
		U.log("W", "grab", "no word from vehicle " .. tostring(held.id) .. " for " .. SILENT_LIMIT .. " s")
		M.release(held.grip and "The rope came loose" or LOST_MESSAGES[0])
		return
	end
	if held.winch == 1 and not held.slack and (held.strain or 0) > 0.95 then
		held.stuckFor = held.stuckFor + dt
	else
		held.stuckFor = 0
	end
	local anchorVel = nil
	if held.anchorVeh then
		-- the anchor rides on a vehicle: its node's position now, the vehicle's speed
		local av = be:getObjectByID(held.anchorVeh.id)
		local p = av and anchorPoint(av, held.anchorVeh.node)
		if p then
			held.target = p
			anchorVel = type(av.getVelocity) == "function" and vecOf(av:getVelocity()) or {x = 0, y = 0, z = 0}
			held.since = SEND_EVERY -- every frame
		else
			M.detachAnchor("Anchor vehicle gone – anchor dropped")
		end
	end
	if held.pull and held.anchorVeh then
		-- an arrow held while hooked on: after PULL_OFF s it pops off (not while the vehicle drives)
		local speed = 0
		if anchorVel then speed = math.sqrt(anchorVel.x ^ 2 + anchorVel.y ^ 2 + anchorVel.z ^ 2) end
		held.pullBlocked = speed > PULL_MAX_SPEED
		if held.pullBlocked then
			held.pull.t = 0
		else
			held.pull.t = held.pull.t + dt
			if held.pull.t >= PULL_OFF then
				local n, from = held.pull.n, held.target
				local v = nudgeVector(n)
				snapFx = {pos = {x = from.x, y = from.y, z = from.z}, age = 0, off = true}
				M.detachAnchor(nil, true)
				-- off the hitch in the arrow's direction, and on as long as the arrow is held
				held.target = {x = from.x + v.x * POP_DISTANCE, y = from.y + v.y * POP_DISTANCE, z = from.z + v.z * POP_DISTANCE}
				held.nudge = n
				anchorVel = nil
			end
		end
	end
	if held.nudge and held.target and not held.anchorVeh then
		-- remote control: forward/back and left/right as seen from the camera, up/down
		local v, step = nudgeVector(held.nudge), NUDGE_SPEED * (fine and FINE or 1) * dt
		held.target = {x = held.target.x + v.x * step, y = held.target.y + v.y * step, z = held.target.z + v.z * step}
	end
	askSnap(dt)
	held.since = held.since + dt
	-- nothing to send until the vehicle has reported where the rope is tied
	if held.since < SEND_EVERY or not (held.grip and held.target) then return end
	held.since = 0
	local t = held.target
	local paying = held.nudge ~= nil or held.payOutOnce
	held.payOutOnce = nil
	local v = anchorVel or {x = 0, y = 0, z = 0}
	sendToVehicle(held.id, string.format("sharedCareerVeh.handRope(%.3f, %.3f, %.3f, %d, %d, %.2f, %.1f, %.3f, %.3f, %.3f, %d)",
		t.x, t.y, t.z, held.winch, paying and 1 or 0, grabSpeed() * (fine and FINE or 1), grabStrength(),
		v.x, v.y, v.z, anchorVel and 1 or 0))
end

--== Tow to the road =============================================================
-- For a vehicle the rope can't free (e.g. wrapped around a lamp post) – the one on the rope, or
-- without a rope the one you look at (picked like "attach where I look"): the game's own recovery
-- "Tow to road" (core/recoveryPrompt.lua, towToRoad) puts it on the last road it drove on and keeps
-- the damage – spawn.teleportToLastRoad(veh, {resetVehicle = false}). The career charges $75 for
-- it (free with roadside assistance); here it is free. Like in the game, only while the vehicle is
-- (nearly) standing still and not in a police chase.

local TOW_MAX_SPEED = 2 -- m/s: the vehicle must be slower than this

local function speedOf(veh)
	if type(veh.getVelocity) ~= "function" then return 0 end
	local ok, v = pcall(veh.getVelocity, veh)
	v = ok and vecOf(v)
	if not v then return 0 end
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

-- true if the police chase this vehicle (the traffic system's pursuit data)
local function inPursuit(id)
	local traffic = rawget(_G, "gameplay_traffic")
	if type(traffic) ~= "table" or type(traffic.getTrafficData) ~= "function" then return false end
	local ok, data = pcall(traffic.getTrafficData)
	local entry = ok and type(data) == "table" and data[id]
	local pursuit = type(entry) == "table" and entry.pursuit
	return type(pursuit) == "table" and (tonumber(pursuit.mode) or 0) > 0
end

-- The vehicle to tow: the one on the rope, otherwise the one in the middle of the view.
-- Returns veh, id, or nil and a message.
local function towTarget()
	if held then
		local veh = be:getObjectByID(held.id)
		if not veh then return nil, "Vehicle not found" end
		return veh, held.id
	end
	local cam, dir = cameraPos(), viewDir()
	local found = cam and dir and vehicleOnRay(cam, dir)
	local ok, err = canRope(found and found.veh, found and found.id)
	if not ok then return nil, err end
	return found.veh, found.id
end

--- Puts the vehicle on the rope (or the one you look at) on the last road it drove on.
--- Returns true, or false and a message.
function M.towToRoad()
	if not towToRoadAllowed() then return false, "Off on this server" end
	local veh, id = towTarget()
	if not veh then return false, id end
	if not (spawn and type(spawn.teleportToLastRoad) == "function") then
		return false, "Not available in this game version"
	end
	if inPursuit(id) then return false, "Not during a police chase" end
	if speedOf(veh) > TOW_MAX_SPEED then return false, "Stop the vehicle first" end
	if held then M.release() end
	local ok, err = pcall(spawn.teleportToLastRoad, veh, {resetVehicle = false})
	if not ok then
		U.log("E", "grab", "tow to the road failed: " .. tostring(err))
		return false, "Towing to the road failed"
	end
	U.log("I", "grab", "vehicle " .. tostring(id) .. " towed to the road")
	return true
end

--== Replies from the vehicle ====================================================

function M.onGrip(id, t, x, y, z, node)
	if not held or held.id ~= id then return end
	held.grip = {x = x, y = y, z = z}
	held.node = tonumber(node)
	held.silent = 0
	-- the anchor starts at the grip (rope slack) until it is moved
	if not held.placed then held.target = {x = x, y = y, z = z} end
	U.log("D", "grab", string.format("vehicle reported its grip at %.1f m", tonumber(t) or 0))
end

function M.onHandState(id, x, y, z, strain, slack, length, ropeLoad)
	if not held or held.id ~= id then return end
	held.grip = {x = x, y = y, z = z}
	held.silent = 0
	-- the winch's load while it hauls in (1 = its limit) and the rope's (1 = it breaks)
	held.strain = math.max(0, math.min(1, tonumber(strain) or 0))
	held.ropeLoad = math.max(0, math.min(1, tonumber(ropeLoad) or 0))
	held.slack = slack == 1 or slack == true
	-- how fast the rope runs through the winch (m/s, < 0 = hauled in), for the marks on the rope
	local newLength = tonumber(length)
	local elapsed = held.lengthAt and clock - held.lengthAt or 0
	if newLength and held.length and elapsed > 0.02 then
		held.rate = (newLength - held.length) / elapsed
		-- faster than the winch or the remote can run it: the anchor jumped ("to my view"), not a
		-- running rope
		if math.abs(held.rate) > math.max(grabSpeed(), NUDGE_SPEED) * 1.5 then held.rate = 0 end
	end
	held.length, held.lengthAt = newLength, clock
end

--- The vehicle took the rope off (reason: see LOST_MESSAGES).
function M.onHandLost(id, reason)
	if not held or held.id ~= id then return end
	startLetGo(held)
	held = nil
	message(LOST_MESSAGES[tonumber(reason)] or "The rope came loose")
	U.log("I", "grab", "vehicle " .. tostring(id) .. " lost the rope (" .. tostring(reason) .. ")")
	pushApp()
end

function M.onProbe(id, x, y, z)
	probe = {id = id, x = x, y = y, z = z, age = 0}
end

--== Drawing =====================================================================

local ROPE_SAFE = 0.4       -- share of the breaking load: up to here the rope keeps its own color
local ROPE_CRITICAL = 0.7  -- from here it is red and trembles
local ROPE_COLOR = {0.88, 0.84, 0.74}
local ROPE_HIGH = {1, 0.62, 0.12}
local ROPE_RED = {1, 0.15, 0.1}

local function mix(a, b, f)
	return a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f
end

--- The rope's color for its load (share of its breaking load): its own color while safe, yellow
--- to orange when high, red near breaking.
function M.ropeLoadColor(load)
	local l = math.max(0, math.min(1, tonumber(load) or 0))
	if l <= ROPE_SAFE then return ROPE_COLOR[1], ROPE_COLOR[2], ROPE_COLOR[3] end
	if l <= ROPE_CRITICAL then return mix(ROPE_COLOR, ROPE_HIGH, (l - ROPE_SAFE) / (ROPE_CRITICAL - ROPE_SAFE)) end
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
function M.ropeColor(load, taut)
	taut = math.max(0, math.min(1, tonumber(taut) or 0))
	local r, g, b = M.ropeLoadColor(load)
	local s = SLACK_COLOR
	return s[1] + (r - s[1]) * taut, s[2] + (g - s[2]) * taut, s[3] + (b - s[3]) * taut, s[4] + (0.9 - s[4]) * taut
end

-- debugDrawer, ColorF and vec3 are engine/library globals: they may be provided lazily (not
-- visible to rawget) and ColorF/vec3 are constructors of type cdata/table, not "function" – so we
-- only check that they exist (0.10.1 checked rawget + "function" and never drew anything).
local canDrawCached = false -- only a positive result is kept; a negative one is checked again
local drawWarned = false
local function canDraw()
	if canDrawCached then return true end
	local ok, dd, cf, v3 = pcall(function() return debugDrawer, ColorF, vec3 end)
	canDrawCached = ok and dd ~= nil and cf ~= nil and v3 ~= nil
	if canDrawCached then
		U.log("I", "grab", "drawing available (debugDrawer)")
	elseif not drawWarned then
		drawWarned = true
		U.log("W", "grab", "drawing not available: debugDrawer " .. tostring(dd) .. ", ColorF " .. tostring(cf)
			.. ", vec3 " .. tostring(v3))
	end
	return canDrawCached
end

local function line(a, b, color)
	debugDrawer:drawLine(vec3(a.x, a.y, a.z), vec3(b.x, b.y, b.z), color)
end

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
		U.log("W", "grab", "debugDrawer:" .. name .. " not available, using lines instead: " .. tostring(err))
	end
	return ok
end

--- Forget which shapes failed (tests; the game keeps the result for the session).
function M.resetShapes() shapeBroken = {} end

local function cylinder(a, b, radius, color)
	return tryShape("drawCylinder", function()
		debugDrawer:drawCylinder(vec3(a.x, a.y, a.z), vec3(b.x, b.y, b.z), radius, color)
	end)
end

local function ball(p, radius, color)
	local ok = tryShape("drawSphere", function()
		debugDrawer:drawSphere(vec3(p.x, p.y, p.z), radius, color)
	end)
	if not ok then cross(p, radius * 1.6, color) end
end

-- how deep a slack rope sags in the middle: a parabola over the horizontal span d whose length is
-- about the rope length L (L ~ d + 8 s^2 / 3d), at most half the rope (hanging straight down)
local SAG_SEGMENTS = 12
local SAG_RATE = 8         -- 1/s: how fast the drawn sag follows the rope
local SAG_MAX = 6          -- m
local FADE_RATE = 6        -- 1/s: how fast the rope color follows slack and taut
local LOAD_FALL = 1.5      -- per s: how fast the shown rope load falls back after a jolt
local TREMBLE = 0.06       -- m: how much a rope near breaking trembles
local ROPE_RADIUS = 0.02   -- m
function M.sagDepth(span, horizontal, length)
	span, horizontal, length = tonumber(span) or 0, tonumber(horizontal) or 0, tonumber(length) or 0
	if span < 0.05 or length <= span then return 0 end
	local s = math.sqrt(3 * span * (length - span) / 8)
	s = math.min(s, length / 2, SAG_MAX)
	-- a steep rope hangs along itself rather than below it
	return s * math.max(0, math.min(1, horizontal / span))
end

-- one piece of rope: a line (visible from any distance) inside a thin cylinder (its body up close)
local function strand(a, b, color)
	line(a, b, color)
	cylinder(a, b, ROPE_RADIUS, color)
end

-- a point on the rope from a (t = 0) to b (t = 1) that sags `sag` m in the middle (< 0: bulges up)
local function ropePoint(a, b, sag, t)
	return {x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t - 4 * sag * t * (1 - t)}
end

local function rope(a, b, sag, color)
	if math.abs(sag) < 0.02 then
		strand(a, b, color)
		return
	end
	local prev = a
	for i = 1, SAG_SEGMENTS do
		local p = ropePoint(a, b, sag, i / SAG_SEGMENTS)
		strand(prev, p, color)
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
	local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
	local span = math.sqrt(dx * dx + dy * dy + dz * dz)
	if span < MARK_SPACING then return end
	local color = ColorF(rgba[1] + (1 - rgba[1]) * 0.6, rgba[2] + (1 - rgba[2]) * 0.6, rgba[3] + (1 - rgba[3]) * 0.6,
		rgba[4] * visible)
	local s = phase % MARK_SPACING
	while s + MARK_LENGTH < span do
		local from, to = ropePoint(a, b, sag, 1 - (s + MARK_LENGTH) / span), ropePoint(a, b, sag, 1 - s / span)
		line(from, to, color)
		cylinder(from, to, ROPE_RADIUS * 1.8, color)
		s = s + MARK_SPACING
	end
end

local PIN_HEIGHT = 0.6     -- m: the anchor's post, from the anchor point up
local PIN_BALL = 0.12      -- m: radius of the ball on top
local function pin(p, color, pulse)
	local top = {x = p.x, y = p.y, z = p.z + PIN_HEIGHT}
	if not cylinder(p, top, 0.02, color) then line(p, top, color) end
	ball(top, PIN_BALL * (pulse or 1), color)
	ball(p, 0.05, color)
end

-- The ground below a point (z), or nil: castRayStatic (static geometry and terrain) straight down.
-- The last answer is kept while the point stays where it is.
local GROUND_RANGE = 60    -- m
local groundCache = nil    -- {x, y, z, ground}
local function groundBelow(p)
	local c = groundCache
	if c and math.abs(c.x - p.x) < 0.01 and math.abs(c.y - p.y) < 0.01 and math.abs(c.z - p.z) < 0.01 then
		return c.ground
	end
	local ground = nil
	local ok, cast = pcall(function() return castRayStatic end)
	if ok and type(cast) == "function" then
		local from = p.z + 0.05
		local hitOk, hit = pcall(cast, vec3(p.x, p.y, from), vec3(0, 0, -1), GROUND_RANGE)
		hit = hitOk and tonumber(hit)
		if hit and hit >= 0 and hit < GROUND_RANGE then ground = from - hit end
	end
	groundCache = {x = p.x, y = p.y, z = p.z, ground = ground}
	return ground
end

-- A floating anchor: a dashed drop line to the ground and a disc there, so you can tell where in
-- the world it is.
local GROUND_MIN = 0.3     -- m above the ground before the marker shows
local DASH = 0.15          -- m: dash and gap of the drop line
local function groundMarker(p, rgb)
	local color = ColorF(rgb[1], rgb[2], rgb[3], 0.7)
	local g = groundBelow(p)
	if not g or p.z - g < GROUND_MIN then return end
	local z = p.z
	while z > g do
		local zEnd = math.max(g, z - DASH)
		line({x = p.x, y = p.y, z = z}, {x = p.x, y = p.y, z = zEnd}, color)
		z = zEnd - DASH
	end
	local disc = ColorF(rgb[1], rgb[2], rgb[3], 0.3)
	if not cylinder({x = p.x, y = p.y, z = g + 0.005}, {x = p.x, y = p.y, z = g + 0.02}, 0.3, disc) then
		line({x = p.x - 0.3, y = p.y, z = g + 0.02}, {x = p.x + 0.3, y = p.y, z = g + 0.02}, color)
		line({x = p.x, y = p.y - 0.3, z = g + 0.02}, {x = p.x, y = p.y + 0.3, z = g + 0.02}, color)
	end
end

local function sign(p, text)
	tryShape("drawTextAdvanced", function()
		local str = String and String(text) or text
		debugDrawer:drawTextAdvanced(vec3(p.x, p.y, p.z), str, ColorF(1, 1, 1, 1), true, false,
			ColorI(20, 20, 24, 190))
	end)
end

-- A flat circle (lines), for the hitch rings and the hook-on flash.
local function circle(p, r, color)
	local prev = nil
	for i = 0, 16 do
		local a = i / 16 * 2 * math.pi
		local q = {x = p.x + math.cos(a) * r, y = p.y + math.sin(a) * r, z = p.z}
		if prev then line(prev, q, color) end
		prev = q
	end
end

local HITCH_NEAR = 3       -- m: closer than this, a hitch ring lights up and a guide line shows
local HOOK_RANGE = 0.7     -- m: this close to a hitch it hooks on (the vehicle's HITCH_SNAP)
local SNAP_FX_TIME = 0.5   -- s of the hook-on flash

-- The tow hitches near the anchor: a ring and a ball each, brighter (and pulsing) as the anchor
-- gets close, and a dashed guide line from the anchor to the nearest one.
local function drawHitches(b)
	if not held.snapTargets then return nil end
	local nearest, nearestD = nil, math.huge
	for id, t in pairs(held.snapTargets) do
		local veh = clock - t.at <= TARGETS_KEEP and be:getObjectByID(id)
		for _, cid in ipairs(veh and t.nodes or {}) do
			local p = anchorPoint(veh, cid)
			if p then
				local dx, dy, dz = p.x - b.x, p.y - b.y, p.z - b.z
				local d = math.sqrt(dx * dx + dy * dy + dz * dz)
				local near = math.max(0, math.min(1, 1 - (d - 0.7) / HITCH_NEAR))
				local pulse = near > 0.6 and (1 + 0.2 * math.sin(clock * 2 * math.pi * 2.5)) or 1
				local color = ColorF(0.3 + 0.1 * near, 0.75 + 0.2 * near, 0.45, 0.35 + 0.55 * near)
				circle(p, 0.22 * pulse, color)
				ball(p, 0.06 + 0.04 * near, color)
				if d < nearestD then nearest, nearestD = p, d end
			end
		end
	end
	if nearest and nearestD <= HITCH_NEAR then
		local color = ColorF(0.4, 0.95, 0.55, 0.8)
		if nearestD <= HOOK_RANGE and held.nudge then
			-- it hooks on when you let go: say so over the anchor
			sign({x = b.x, y = b.y, z = b.z + PIN_HEIGHT + 0.35}, "Let go to hook on")
		end
		local steps = math.max(1, math.floor(nearestD / 0.2))
		for i = 0, steps - 1, 2 do
			local f0, f1 = i / steps, math.min(1, (i + 1) / steps)
			line({x = b.x + (nearest.x - b.x) * f0, y = b.y + (nearest.y - b.y) * f0, z = b.z + (nearest.z - b.z) * f0},
				{x = b.x + (nearest.x - b.x) * f1, y = b.y + (nearest.y - b.y) * f1, z = b.z + (nearest.z - b.z) * f1}, color)
		end
	end
end

-- The flash where the anchor just hooked on: a growing, fading ring.
local function drawSnapFx(dt)
	snapFx.age = snapFx.age + dt
	local f = snapFx.age / SNAP_FX_TIME
	if f >= 1 then
		snapFx = nil
		return
	end
	local color = snapFx.off and ColorF(1, 0.6, 0.15, 0.9 * (1 - f)) or ColorF(0.4, 1, 0.55, 0.9 * (1 - f))
	circle(snapFx.pos, 0.2 + 0.7 * f, color)
	circle(snapFx.pos, 0.1 + 0.35 * f, color)
	ball(snapFx.pos, 0.12 * (1 - f), color)
end

-- Where the rope is tied, now: the tie node's position from the vehicle every frame
-- (veh:getNodePosition is relative to the vehicle's position), otherwise the last report. A
-- position far from the last report is not trusted (the vehicle reports 10 times per second).
local NODE_TRUST = 3       -- m
local function gripNow()
	local reported = held and held.grip
	if not reported then return nil end
	local veh = held.node and be:getObjectByID(held.id)
	if not (veh and type(veh.getNodePosition) == "function" and type(veh.getPosition) == "function") then
		return reported
	end
	local ok, rel = pcall(veh.getNodePosition, veh, held.node)
	local base = vecOf(veh:getPosition())
	rel = ok and vecOf(rel)
	if not (rel and base) then return reported end
	local p = {x = base.x + rel.x, y = base.y + rel.y, z = base.z + rel.z}
	local dx, dy, dz = p.x - reported.x, p.y - reported.y, p.z - reported.z
	if dx * dx + dy * dy + dz * dz > NODE_TRUST * NODE_TRUST then return reported end
	return p
end

local function stuck()
	return held ~= nil and (held.stuckFor or 0) >= STUCK_AFTER
end

-- anchor colors {r, g, b, a}
local ANCHOR_RESTING = {1, 1, 1, 0.8}
local ANCHOR_MOVING = {0.3, 0.9, 1, 0.9}
local ANCHOR_HAULING = {1, 0.55, 0.1, 0.9}
local ANCHOR_PAYING = {0.75, 0.55, 1, 0.9}

-- Let go: the rope as it was last drawn, animated for a moment after it came off. A taut rope
-- snaps back to the anchor (its loose end flies there, the rope whips up and down), a slack one
-- drops (its loose end falls, the rope sags deeper); both fade out, the anchor with them.
local SNAP_TIME = 0.35     -- s
local DROP_TIME = 0.6      -- s
local DROP_MAX = 1.5       -- m the loose end falls at most
local WHIP = 0.08          -- whip height per m of rope (at most WHIP_MAX)
local WHIP_MAX = 0.5       -- m
local GRAVITY = 9.81

function startLetGo(h)
	local shown = h and h.shown
	if not shown then
		letGo = nil
		return
	end
	local snap = (h.shownTaut or 0) > 0.5
	letGo = {a = shown.a, b = shown.b, rgba = shown.rgba, sag = shown.sag, snap = snap, age = 0,
		time = snap and SNAP_TIME or DROP_TIME}
end

local function drawLetGo(dt)
	local g = letGo
	g.age = g.age + dt
	local f = g.age / g.time
	if f >= 1 then
		letGo = nil
		return
	end
	local a, b, c = g.a, g.b, g.rgba
	local loose, sag
	if g.snap then
		local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
		local whip = math.min(WHIP_MAX, WHIP * math.sqrt(dx * dx + dy * dy + dz * dz))
		loose = ropePoint(a, b, 0, 1 - (1 - f) ^ 3) -- fast at first, then slowing down at the anchor
		sag = -whip * math.sin(f * math.pi * 3) * (1 - f)
	else
		local fall = math.min(DROP_MAX, 0.5 * GRAVITY * g.age * g.age)
		loose = {x = a.x, y = a.y, z = a.z - fall}
		sag = g.sag + fall / 2
	end
	local fade = 1 - f
	rope(loose, b, sag, ColorF(c[1], c[2], c[3], c[4] * fade))
	pin(b, ColorF(ANCHOR_RESTING[1], ANCHOR_RESTING[2], ANCHOR_RESTING[3], ANCHOR_RESTING[4] * fade))
end

-- The winch gauge: a ring facing the camera that fills with the winch's load, a small drum inside.
local GAUGE_RADIUS = 0.2   -- m
local function winchGauge(p, strain)
	local f = viewDir()
	if not f then return end
	-- the camera's right and up, so the ring faces it
	local rx, ry = f.y, -f.x
	local rl = math.sqrt(rx * rx + ry * ry)
	if rl < 0.01 then rx, ry, rl = 1, 0, 1 end
	rx, ry = rx / rl, ry / rl
	local ux, uy, uz = ry * f.z, -rx * f.z, rx * f.y - ry * f.x -- right x forward
	local function at(angle, r)
		local c, sn = math.sin(angle) * r, math.cos(angle) * r
		return {x = p.x + rx * c + ux * sn, y = p.y + ry * c + uy * sn, z = p.z + uz * sn}
	end
	local limit = strain >= 0.95
	local blink = limit and (0.55 + 0.45 * math.sin(clock * 2 * math.pi * 2.5)) or 1
	local r, g, b = M.winchColor(strain)
	if limit then r, g, b = 1, 0.18, 0.12 end
	local back = ColorF(1, 1, 1, 0.25)
	local fill = ColorF(r, g, b, 0.95 * blink)
	local steps, filled = 24, math.floor(24 * math.min(1, strain) + 0.5)
	for i = 0, steps - 1 do
		local a0, a1 = i / steps * 2 * math.pi, (i + 1) / steps * 2 * math.pi
		line(at(a0, GAUGE_RADIUS), at(a1, GAUGE_RADIUS), back)
		if i < filled then
			line(at(a0, GAUGE_RADIUS * 0.92), at(a1, GAUGE_RADIUS * 0.92), fill)
			line(at(a0, GAUGE_RADIUS * 1.08), at(a1, GAUGE_RADIUS * 1.08), fill)
		end
	end
	-- the drum: a short barrel across the ring's middle
	local d = 0.07
	if not cylinder({x = p.x - rx * d, y = p.y - ry * d, z = p.z}, {x = p.x + rx * d, y = p.y + ry * d, z = p.z}, 0.045, fill) then
		line({x = p.x - rx * d, y = p.y - ry * d, z = p.z}, {x = p.x + rx * d, y = p.y + ry * d, z = p.z}, fill)
	end
end

function M.draw(dt)
	dt = math.max(0, tonumber(dt) or 0)
	clock = clock + dt
	if not (held and held.grip and held.target) and not probe and not letGo and not snapFx then return end
	if not canDraw() then return end
	if letGo then drawLetGo(dt) end
	if snapFx then drawSnapFx(dt) end
	if held and held.grip and held.target then
		-- color: the rope's load (a jump up shows at once, it fades back slowly so a short jolt is
		-- seen) and slack/taut, smoothly
		local k = 1 - math.exp(-FADE_RATE * dt)
		local taut = held.slack and 0 or 1
		local load = held.ropeLoad or 0
		held.shownLoad = math.max(load, (held.shownLoad or 0) - LOAD_FALL * dt)
		held.shownTaut = (held.shownTaut or taut) + (taut - (held.shownTaut or taut)) * k
		local rgba = {M.ropeColor(held.shownLoad, held.shownTaut)}
		local color = ColorF(rgba[1], rgba[2], rgba[3], rgba[4])
		local a, b = gripNow(), held.target
		local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
		local span = math.sqrt(dx * dx + dy * dy + dz * dz)
		local want = held.slack and M.sagDepth(span, math.sqrt(dx * dx + dy * dy), held.length) or 0
		local ks = 1 - math.exp(-SAG_RATE * dt)
		held.sag = (held.sag or want) + (want - (held.sag or want)) * ks
		-- near breaking the rope trembles
		local tremble = 0
		if held.shownLoad > ROPE_CRITICAL and not held.slack then
			tremble = TREMBLE * math.min(1, (held.shownLoad - ROPE_CRITICAL) / (1 - ROPE_CRITICAL)) * math.sin(clock * 2 * math.pi * 14)
		end
		rope(a, b, held.sag + tremble, color)
		-- marks travelling with the rope while it runs through the winch
		local rate = clock - (held.lengthAt or clock) < RATE_STALE and held.rate or 0
		held.shownRate = (held.shownRate or 0) + ((rate or 0) - (held.shownRate or 0)) * (1 - math.exp(-RATE_RATE * dt))
		held.markPhase = (held.markPhase or 0) + held.shownRate * dt
		local speed = math.abs(held.shownRate)
		if speed >= MARK_MIN_RATE then
			winchMarks(a, b, held.sag, rgba, held.markPhase, math.min(1, speed / MARK_FULL_RATE))
		end
		ball(a, 0.09, color)
		held.shown = {a = a, b = {x = b.x, y = b.y, z = b.z}, rgba = rgba, sag = held.sag}
		local rgb = held.nudge and ANCHOR_MOVING or held.winch == 1 and ANCHOR_HAULING
			or held.winch == -1 and ANCHOR_PAYING or ANCHOR_RESTING
		local pulse = held.winch == 1 and not held.nudge
			and 1 + 0.25 * math.sin(clock * 2 * math.pi * 1.5) or 1
		if held.anchorVeh then
			-- on a vehicle: a shackle on its hitch, no post and no ground marker. While an arrow is
			-- held: it tugs in that direction and an orange ring fills until it pops off
			local p = b
			if held.pull and not held.pullBlocked then
				local v, k = nudgeVector(held.pull.n), math.min(1, held.pull.t / PULL_OFF)
				local tug = 0.05 * k * (1 + 0.6 * math.sin(clock * 2 * math.pi * 9))
				p = {x = b.x + v.x * tug, y = b.y + v.y * tug, z = b.z + v.z * tug}
				local steps = math.max(1, math.floor(16 * k))
				local ringColor = ColorF(1, 0.6, 0.15, 0.95)
				for i = 0, steps - 1 do
					local a0, a1 = i / 16 * 2 * math.pi, (i + 1) / 16 * 2 * math.pi
					line({x = b.x + math.cos(a0) * 0.25, y = b.y + math.sin(a0) * 0.25, z = b.z},
						{x = b.x + math.cos(a1) * 0.25, y = b.y + math.sin(a1) * 0.25, z = b.z}, ringColor)
				end
			end
			ball(p, 0.08 * pulse, ColorF(rgb[1], rgb[2], rgb[3], rgb[4]))
		else
			pin(b, ColorF(rgb[1], rgb[2], rgb[3], rgb[4]), pulse)
			groundMarker(b, rgb)
			drawHitches(b)
		end
		-- the winch gauge above the anchor, while the winch hauls in
		local gaugeAt = {x = b.x, y = b.y, z = b.z + (held.anchorVeh and 0.45 or PIN_HEIGHT + 0.4)}
		if held.winch == 1 then winchGauge(gaugeAt, held.strain or 0) end
		if appOpen then
			local text = held.winch == 1 and string.format("Winch %d %%", math.floor((held.strain or 0) * 100 + 0.5))
				or (held.winch == -1 and "Paying out" or "Locked")
			sign({x = gaugeAt.x, y = gaugeAt.y, z = gaugeAt.z + 0.35}, text)
		end
	elseif probe then
		ball(probe, 0.12 * (1 + 0.12 * math.sin(clock * 2 * math.pi)), ColorF(0.3, 0.8, 1, 0.45))
	end
end

-- the preview (where a rope would attach) only shows while the Tow app is open
local function previewWanted()
	return appOpen and not held and allowed()
end

function M.updatePreview(dt)
	if probe then
		probe.age = probe.age + dt
		if probe.age > PROBE_KEEP then probe = nil end
	end
	if not previewWanted() then
		probe = nil
		return
	end
	sinceProbe = sinceProbe + dt
	if sinceProbe < PROBE_EVERY then return end
	sinceProbe = 0
	-- the Tow app attaches where you look (the cursor is on the phone)
	local cam, dir = cameraPos(), viewDir()
	local found = cam and dir and vehicleOnRay(cam, dir)
	if not found or not canRope(found.veh, found.id) then return end
	sendToVehicle(found.id, string.format("sharedCareerVeh.handProbe(%.3f, %.3f, %.3f, %.4f, %.4f, %.4f, %d)",
		cam.x, cam.y, cam.z, dir.x, dir.y, dir.z, MAX_DISTANCE))
end

--== Tow app (phone) =============================================================

function vehicleName(veh)
	local model = veh.JBeam
	if model == nil and type(veh.getJBeamFilename) == "function" then model = veh:getJBeamFilename() end
	model = tostring(model or "vehicle")
	if core_vehicles and type(core_vehicles.getModel) == "function" then
		local ok, info = pcall(core_vehicles.getModel, model)
		local m = ok and type(info) == "table" and info.model
		if type(m) == "table" and m.Name then
			return m.Brand and (tostring(m.Brand) .. " " .. tostring(m.Name)) or tostring(m.Name)
		end
	end
	return (model:gsub("^%l", string.upper))
end

-- own vehicles near the camera that can take a rope, nearest first (at most 6)
local function nearbyVehicles()
	local cam = cameraPos()
	if not cam then return {} end
	local list = {}
	local count = type(be.getObjectCount) == "function" and be:getObjectCount() or 0
	for i = 0, count - 1 do
		local veh = be:getObject(i)
		if veh and type(veh.getID) == "function" and type(veh.getPosition) == "function" then
			local id = veh:getID()
			if canRope(veh, id) then
				local p = vecOf(veh:getPosition())
				local dx, dy, dz = p.x - cam.x, p.y - cam.y, p.z - cam.z
				local d = math.sqrt(dx * dx + dy * dy + dz * dz)
				if d <= NEARBY_RANGE then table.insert(list, {id = id, name = vehicleName(veh), distance = math.floor(d + 0.5)}) end
			end
		end
	end
	table.sort(list, function(a, b) return a.distance < b.distance end)
	while #list > 6 do table.remove(list) end
	return list
end

--- State for the Tow app.
function M.appState()
	local max = maxStrength()
	local choices = {}
	for _, v in ipairs(STRENGTHS) do
		if v <= max then table.insert(choices, v) end
	end
	if #choices == 0 or choices[#choices] < max then table.insert(choices, math.floor(max + 0.5)) end
	local state = {allowed = allowed(), attached = held ~= nil, fine = fine, towToRoad = towToRoadAllowed(),
		strength = grabStrength(), maxStrength = max, strengths = choices}
	if held then
		local veh = be:getObjectByID(held.id)
		state.vehicle = veh and vehicleName(veh) or "?"
		state.winch = held.winch
		state.moving = held.nudge ~= nil
		state.strain = held.strain or 0
		state.ropeLoad = held.ropeLoad or 0
		state.slack = held.slack ~= false
		state.stuck = stuck()
		state.length = held.length
		if held.anchorVeh then
			state.anchorVehicle = held.anchorVeh.name
			state.anchorHitch = held.anchorVeh.hitch
			state.pullProgress = held.pull and math.min(1, held.pull.t / PULL_OFF) or 0
			state.pullBlocked = held.pullBlocked == true
		end
		state.unarmed = held.unarmed == true
		local grip = gripNow()
		if grip and held.target then
			local dx, dy, dz = held.target.x - grip.x, held.target.y - grip.y, held.target.z - grip.z
			state.distance = math.sqrt(dx * dx + dy * dy + dz * dz)
		end
	else
		state.nearby = nearbyVehicles()
	end
	return state
end

function pushApp()
	if guihooks and type(guihooks.trigger) == "function" then guihooks.trigger("SharedCareerTow", M.appState()) end
end

function M.setAppOpen(on)
	appOpen = on == true
	if not appOpen then
		probe = nil
		if held then held.nudge = nil end
	end
	pushApp()
end

-- buttons of the Tow app
function M.uiAttachView() local ok = attachAtView(); pushApp(); return ok end
function M.uiAttachVehicle(id)
	if not allowed() then return false end
	id = tonumber(id)
	local veh = id and be:getObjectByID(id)
	local ok, err = canRope(veh, id)
	local cam = cameraPos()
	if not ok or not cam then
		message(err or "Vehicle not found")
		return false
	end
	local p = vecOf(veh:getPosition())
	local dx, dy, dz = p.x - cam.x, p.y - cam.y, p.z - cam.z
	startRope(id, math.sqrt(dx * dx + dy * dy + dz * dz), string.format("sharedCareerVeh.handGrabNearest(%.3f, %.3f, %.3f, %.2f, %.1f)",
			cam.x, cam.y, cam.z, grabSpeed(), grabStrength()))
	pushApp()
	return true
end
function M.uiRelease() M.release(); pushApp() end
function M.uiAnchorDetach() M.detachAnchor(); pushApp() end
function M.uiTowToRoad()
	local ok, err = M.towToRoad()
	message(ok and "Back on the road" or err)
	pushApp()
	return ok
end
function M.uiWinch(mode) M.setWinch(mode); pushApp() end
function M.uiFine(on) fine = on == true; pushApp() end
--- Pull strength in % of the vehicle's weight (capped at the server's client.grabStrength).
function M.uiStrength(v)
	v = tonumber(v)
	if not v then return end
	strengthPick = math.max(10, math.min(150, v))
	if held then held.since = SEND_EVERY end
	pushApp()
end
--- Remote control: move the anchor while a button is held (f = forward, r = right, u = up; -1..1).
function M.uiNudge(f, r, u)
	if not held then return end
	local n = {f = tonumber(f) or 0, r = tonumber(r) or 0, u = tonumber(u) or 0}
	if held.anchorVeh then
		-- hooked on: holding pulls it off (see M.step)
		held.pull = {n = n, t = 0}
	else
		held.nudge = n
		held.unarmed = nil -- moved once: it may hook on again when let go
		held.placed = true
		held.since = SEND_EVERY
	end
	pushApp()
end
function M.uiNudgeStop()
	if not held then return end
	held.nudge, held.pull, held.pullBlocked = nil, nil, nil
	held.sinceSnap = SNAP_EVERY -- let go: ask at once whether it hooks on
	held.since = SEND_EVERY
	pushApp()
end
--- Put the anchor in the middle of the view, at its current distance from you.
function M.uiAnchorToView()
	if not held or not held.target then return end
	if held.anchorVeh then M.detachAnchor(nil, true) end
	held.unarmed = nil
	local cam, dir = cameraPos(), viewDir()
	if not cam or not dir then return end
	local dx, dy, dz = held.target.x - cam.x, held.target.y - cam.y, held.target.z - cam.z
	local dist = math.max(MIN_DISTANCE, math.min(MAX_DISTANCE, math.sqrt(dx * dx + dy * dy + dz * dz)))
	held.target = {x = cam.x + dir.x * dist, y = cam.y + dir.y * dist, z = cam.z + dir.z * dist}
	held.placed = true
	held.payOutOnce = true
	held.since = SEND_EVERY
	pushApp()
end

-- the Tow app on the phone
local function registerPhoneApp()
	local phone = U.ext("sharedCareer_phone")
	if not phone or type(phone.registerApp) ~= "function" then return end
	if allowed() then
		phone.registerApp({id = "tow", title = "Tow", icon = "tow", color = "#e8730c", order = 10,
			onOpen = function() M.setAppOpen(true) end, onClose = function() M.setAppOpen(false) end})
	else
		phone.unregisterApp("tow")
		M.setAppOpen(false)
	end
end

function M.onConfigChanged()
	registerPhoneApp()
end

function M.isHolding()
	return held ~= nil
end

--== Hooks =====================================================================

function M.onUpdate(dtReal, dtSim)
	if held then
		local ok, err = pcall(M.step, dtReal, dtSim)
		if not ok then
			U.log("E", "grab", "grab failed: " .. tostring(err))
			M.release()
		end
	elseif U.isMP() then
		pcall(M.updatePreview, tonumber(dtReal) or 0)
	end
	if appOpen then
		sinceAppPush = sinceAppPush + (tonumber(dtReal) or 0)
		if sinceAppPush >= APP_PUSH_EVERY then
			sinceAppPush = 0
			pcall(pushApp)
		end
	end
	local ok, err = pcall(M.draw, tonumber(dtReal) or 0)
	if not ok and not drawErrorLogged then
		drawErrorLogged = true
		U.log("E", "grab", "drawing failed: " .. tostring(err))
	end
end

function M.onCareerActive(active)
	if active and U.isMP() then
		registerPhoneApp()
	end
end

function M.onVehicleDestroyed(id)
	if held and held.id == id then M.release() end
	if held and held.anchorVeh and held.anchorVeh.id == id then
		M.detachAnchor("Anchor vehicle gone – anchor dropped")
	end
end

-- reset (R, recovery, a new config): the vehicle is somewhere else now, the old rope would pull it
-- back (the vehicle's own onReset drops it too)
function M.onVehicleResetted(id)
	if held and held.id == id then M.release(LOST_MESSAGES[1]) end
	-- the anchor vehicle was reset: it is somewhere else now, the anchor stays where it was
	if held and held.anchorVeh and held.anchorVeh.id == id then
		M.detachAnchor("Anchor vehicle reset – anchor dropped")
	end
end

function M.onBeamMPServerLeave()
	M.release()
	probe = nil
	letGo = nil
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
