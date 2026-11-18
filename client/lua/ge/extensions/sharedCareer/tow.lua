-- SharedCareer :: the Tow app – a rope with a winch, as a remote control
--
-- Built for moving vehicles that can't drive: drag one out of a ditch, pull it onto a tow truck,
-- tow it behind another car. One rope at a time (rope.lua, kind TOW); everything runs in the phone
-- app "Tow":
--
--   attach    where you look (middle of the view), or to one of your vehicles nearby (the point
--             of that vehicle closest to you). While the app is open, a blue ball shows where it
--             would attach
--   anchor    buttons forward/back/left/right (as seen from the camera) and up/down, hold to move;
--             "to my view" puts it in the middle of the view; fine mode = quarter speed
--   winch     haul in (pulls the vehicle slowly to the anchor) / stop (the vehicle hangs on the
--             rope) / pay out
--   hook on   the anchor can go onto another of your vehicles (also the one you sit in) – at any
--             point of it. Near a vehicle, the point where it would hook on shows as a ring with a
--             dashed line from the anchor (green on a tow hitch, white elsewhere) and the app
--             offers "Hook on"; nothing hooks on by itself. Rings also mark the tow hitches within a
--             few meters. Hooked on, the anchor moves with that vehicle: drive off and you tow on
--             the rope, or haul in with the winch "on" the tow truck. "Unhook" leaves the anchor
--             where it is. If the anchor vehicle is gone or reset, the anchor stays where it was
--   strength  30/60/100/150 % of the vehicle's weight
--   to road   the game's own recovery "Tow to road" for the vehicle on the rope, or without a rope
--             for the vehicle you look at; free of charge (see "Tow to the road" below)
--   remove
--
-- The rope only pulls when it is taut, never pushes; moving the anchor pays out rope, so the
-- vehicle only moves when the winch runs.
--
-- What you see, besides the rope itself (rope.lua):
--   anchor    a pin (post with a ball on top): white = resting, cyan = being moved, orange =
--             hauling in (the ball pulses), purple = paying out. Above the ground a dashed drop
--             line and a disc on the ground show where it is. On a vehicle: a ball on the point
--   winch gauge   above the anchor, while it hauls in: a small ring that always faces you and
--             fills with the winch's load (share of its pull limit), green -> yellow -> orange; at
--             the limit it blinks red. A small drum in its middle. With the Tow app open, a sign
--             above shows "Winch 72 %" (stopped: "Locked")
--
-- Server settings: client.allowRopes (on/off, with the Straps app), client.winchSpeed (m/s the
-- winch hauls in at most), client.winchStrength (the highest force limit a player may pick, in %
-- of the vehicle's weight), client.allowTowToRoad (on/off): the "Tow to the road" button.

local M = {}

local U, R

local MIN_DISTANCE = 3     -- m, closest "to my view" puts the anchor
local NUDGE_SPEED = 1      -- m/s the anchor moves while a remote button is held
local FINE = 0.25          -- fine mode: speed factor for the winch and the anchor
local NEARBY_RANGE = 60    -- m: vehicles listed in the Tow app
local APP_PUSH_EVERY = 0.2 -- s: how often the Tow app gets the state while it's open
local STRENGTHS = {30, 60, 100, 150} -- strength choices in the Tow app (% of the vehicle's weight)

local rope = nil           -- the tow rope (rope.lua), with nudge = {f, r, u} while a button is held
local fine = false         -- fine mode
local strengthPick = 60    -- the player's pick
local appOpen = false      -- the Tow app is open on the phone
local sinceAppPush = 0
local pushApp              -- defined with the app below

local function towToRoadAllowed()
	local c = U.config()
	return R.allowed() and c.allowTowToRoad == true
end

local function numberSetting(key, default, lo, hi)
	local c = U.config()
	local v = c and tonumber(c[key])
	if not v or v <= 0 then return default end
	return math.max(lo, math.min(hi, v))
end

-- m/s the winch hauls in at most, and the force limit in % of the vehicle's weight
local function winchSpeed() return numberSetting("winchSpeed", 1, 0.2, 5) end
local function maxStrength() return numberSetting("winchStrength", 150, 10, 150) end
local function winchStrength() return math.min(strengthPick, maxStrength()) end

-- The remote's direction (f = forward, r = right, u = up) in the world, as seen from the camera.
local function nudgeVector(n)
	local f = R.viewDir() or {x = 0, y = 1, z = 0}
	local len = math.sqrt(f.x * f.x + f.y * f.y)
	local fx, fy = 0, 1
	if len > 0.01 then fx, fy = f.x / len, f.y / len end
	local rx, ry = fy, -fx
	return {x = fx * n.f + rx * n.r, y = fy * n.f + ry * n.r, z = n.u}
end

--== The rope ======================================================================

-- every frame, before the rope goes to the vehicle: the remote moves the anchor, the settings
local function update(r, dt)
	if r.nudge and r.target and not r.anchorVeh then
		-- remote control: forward/back and left/right as seen from the camera, up/down
		local v, s = nudgeVector(r.nudge), NUDGE_SPEED * (fine and FINE or 1) * dt
		r.target = {x = r.target.x + v.x * s, y = r.target.y + v.y * s, z = r.target.z + v.z * s}
	end
	r.moving = r.nudge ~= nil
	r.speed = winchSpeed() * (fine and FINE or 1)
	r.strength = winchStrength()
	r.wantHookPoints = not r.anchorVeh
end

local drawEnd -- defined with the drawing below

local function attach(id, tieCommand)
	R.stopProbe()
	rope = R.create(R.TOW, id, tieCommand)
	rope.update = update
	rope.drawEnd = drawEnd
	rope.anchored = function(r)
		R.message("Hooked onto the " .. r.anchorVeh.name)
		pushApp()
	end
	rope.gone = function(r)
		if rope == r then rope = nil end
		pushApp()
	end
	rope.speed, rope.strength = winchSpeed(), winchStrength()
end

--- Removes the rope; with a text, the player is told why.
function M.release(text)
	R.release(rope, text)
end

--- Winch: 1 haul in, 0 stop, -1 pay out.
function M.setWinch(mode)
	if not rope then return false end
	mode = tonumber(mode) or 0
	rope.winch = mode > 0 and 1 or (mode < 0 and -1 or 0)
	rope.since = 1
	return true
end

-- Attach where you look (the middle of the view; the cursor is on the phone).
local function attachAtView()
	if not R.allowed() then
		R.message("Ropes are off on this server")
		return false
	end
	local cam, dir = R.cameraPos(), R.viewDir()
	local found = cam and dir and R.vehicleOnRay(cam, dir)
	local ok, err = R.canRope(found and found.veh, found and found.id)
	if not ok then
		R.message(err)
		return false
	end
	-- the vehicle ties the rope to the node closest to the aim line and reports it (onRopeTied)
	attach(found.id, function(rid)
		return string.format("sharedCareerVeh.ropeTieRay(%d, %d, %.3f, %.3f, %.3f, %.4f, %.4f, %.4f, %d, %.2f, %.1f)",
			rid, R.TOW, cam.x, cam.y, cam.z, dir.x, dir.y, dir.z, R.MAX_DISTANCE, winchSpeed(), winchStrength())
	end)
	return true
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
	v = ok and R.vecOf(v)
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
	if rope then
		local veh = be:getObjectByID(rope.veh)
		if not veh then return nil, "Vehicle not found" end
		return veh, rope.veh
	end
	local cam, dir = R.cameraPos(), R.viewDir()
	local found = cam and dir and R.vehicleOnRay(cam, dir)
	local ok, err = R.canRope(found and found.veh, found and found.id)
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
	if rope then M.release() end
	local ok, err = pcall(spawn.teleportToLastRoad, veh, {resetVehicle = false})
	if not ok then
		U.log("E", "tow", "tow to the road failed: " .. tostring(err))
		return false, "Towing to the road failed"
	end
	U.log("I", "tow", "vehicle " .. tostring(id) .. " towed to the road")
	return true
end

--== Drawing (the anchor's end; the rope itself: rope.lua) ===========================

-- anchor colors {r, g, b, a}
local ANCHOR_MOVING = {0.3, 0.9, 1, 0.9}
local ANCHOR_HAULING = {1, 0.55, 0.1, 0.9}
local ANCHOR_PAYING = {0.75, 0.55, 1, 0.9}
local HITCH_NEAR = 3       -- m: closer than this, a hitch ring lights up

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
	local S = R.shapes
	local color = ColorF(rgb[1], rgb[2], rgb[3], 0.7)
	local g = groundBelow(p)
	if not g or p.z - g < GROUND_MIN then return end
	local z = p.z
	while z > g do
		local zEnd = math.max(g, z - DASH)
		S.line({x = p.x, y = p.y, z = z}, {x = p.x, y = p.y, z = zEnd}, color)
		z = zEnd - DASH
	end
	local disc = ColorF(rgb[1], rgb[2], rgb[3], 0.3)
	if not S.cylinder({x = p.x, y = p.y, z = g + 0.005}, {x = p.x, y = p.y, z = g + 0.02}, 0.3, disc) then
		S.line({x = p.x - 0.3, y = p.y, z = g + 0.02}, {x = p.x + 0.3, y = p.y, z = g + 0.02}, color)
		S.line({x = p.x, y = p.y - 0.3, z = g + 0.02}, {x = p.x, y = p.y + 0.3, z = g + 0.02}, color)
	end
end

-- The tow hitches near the anchor (rings, brighter as the anchor gets close) and the point where
-- it would hook on (a ring and a dashed line from the anchor).
local function drawHookPoints(r, b)
	local S = R.shapes
	for vid, a in pairs(R.hookAnswers(r)) do
		local veh = be:getObjectByID(vid)
		for _, cid in ipairs(a.targets or {}) do
			local p = R.nodePos(veh, cid)
			if p then
				local near = math.max(0, math.min(1, 1 - (R.distance(p, b) - 0.7) / HITCH_NEAR))
				local color = ColorF(0.3 + 0.1 * near, 0.75 + 0.2 * near, 0.45, 0.25 + 0.4 * near)
				S.circle(p, 0.22, color)
			end
		end
	end
	local hp = R.hookPoint(r)
	if hp then
		S.hookPoint(hp.pos, hp.hitch)
		S.dashed(b, hp.pos, hp.hitch and ColorF(0.4, 0.95, 0.55, 0.8) or ColorF(1, 1, 1, 0.7))
	end
end

-- The winch gauge: a ring facing the camera that fills with the winch's load, a small drum inside.
local GAUGE_RADIUS = 0.2   -- m
local function winchGauge(p, strain)
	local S = R.shapes
	local f = R.viewDir()
	if not f then return end
	-- the camera's right and up, so the ring faces it
	local rx, ry = f.y, -f.x
	local rl = math.sqrt(rx * rx + ry * ry)
	if rl < 0.01 then rx, ry, rl = 1, 0, 1 end
	rx, ry = rx / rl, ry / rl
	local ux, uy, uz = ry * f.z, -rx * f.z, rx * f.y - ry * f.x -- right x forward
	local function at(angle, rad)
		local c, sn = math.sin(angle) * rad, math.cos(angle) * rad
		return {x = p.x + rx * c + ux * sn, y = p.y + ry * c + uy * sn, z = p.z + uz * sn}
	end
	local limit = strain >= 0.95
	local blink = limit and (0.55 + 0.45 * math.sin(R.clock() * 2 * math.pi * 2.5)) or 1
	local r, g, b = R.winchColor(strain)
	if limit then r, g, b = 1, 0.18, 0.12 end
	local back = ColorF(1, 1, 1, 0.25)
	local fill = ColorF(r, g, b, 0.95 * blink)
	local steps, filled = 24, math.floor(24 * math.min(1, strain) + 0.5)
	for i = 0, steps - 1 do
		local a0, a1 = i / steps * 2 * math.pi, (i + 1) / steps * 2 * math.pi
		S.line(at(a0, GAUGE_RADIUS), at(a1, GAUGE_RADIUS), back)
		if i < filled then
			S.line(at(a0, GAUGE_RADIUS * 0.92), at(a1, GAUGE_RADIUS * 0.92), fill)
			S.line(at(a0, GAUGE_RADIUS * 1.08), at(a1, GAUGE_RADIUS * 1.08), fill)
		end
	end
	-- the drum: a short barrel across the ring's middle
	local d = 0.07
	if not S.cylinder({x = p.x - rx * d, y = p.y - ry * d, z = p.z}, {x = p.x + rx * d, y = p.y + ry * d, z = p.z}, 0.045, fill) then
		S.line({x = p.x - rx * d, y = p.y - ry * d, z = p.z}, {x = p.x + rx * d, y = p.y + ry * d, z = p.z}, fill)
	end
end

function drawEnd(r, a, b, dt)
	local S = R.shapes
	local rgb = r.nudge and ANCHOR_MOVING or r.winch == 1 and ANCHOR_HAULING
		or r.winch == -1 and ANCHOR_PAYING or R.ANCHOR_RESTING
	local pulse = r.winch == 1 and not r.nudge and 1 + 0.25 * math.sin(R.clock() * 2 * math.pi * 1.5) or 1
	if r.anchorVeh then
		-- on a vehicle: a shackle on the point, no post and no ground marker
		S.ball(b, 0.08 * pulse, ColorF(rgb[1], rgb[2], rgb[3], rgb[4]))
	else
		S.pin(b, ColorF(rgb[1], rgb[2], rgb[3], rgb[4]), pulse)
		groundMarker(b, rgb)
		drawHookPoints(r, b)
	end
	-- the winch gauge above the anchor, while the winch hauls in
	local gaugeAt = {x = b.x, y = b.y, z = b.z + (r.anchorVeh and 0.45 or R.PIN_HEIGHT + 0.4)}
	if r.winch == 1 then winchGauge(gaugeAt, r.strain or 0) end
	if appOpen then
		local text = r.winch == 1 and string.format("Winch %d %%", math.floor((r.strain or 0) * 100 + 0.5))
			or (r.winch == -1 and "Paying out" or "Locked")
		S.sign({x = gaugeAt.x, y = gaugeAt.y, z = gaugeAt.z + 0.35}, text)
	end
end

--== Tow app (phone) =============================================================

-- own vehicles near the camera that can take a rope, nearest first (at most 6)
local function nearbyVehicles()
	local cam = R.cameraPos()
	if not cam then return {} end
	local list = {}
	local count = type(be.getObjectCount) == "function" and be:getObjectCount() or 0
	for i = 0, count - 1 do
		local veh = be:getObject(i)
		if veh and type(veh.getID) == "function" and type(veh.getPosition) == "function" then
			local id = veh:getID()
			if R.canRope(veh, id) then
				local d = R.distance(R.vecOf(veh:getPosition()), cam)
				if d <= NEARBY_RANGE then table.insert(list, {id = id, name = R.vehicleName(veh), distance = math.floor(d + 0.5)}) end
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
	local state = {allowed = R.allowed(), attached = rope ~= nil, fine = fine, towToRoad = towToRoadAllowed(),
		strength = winchStrength(), maxStrength = max, strengths = choices}
	if rope then
		local veh = be:getObjectByID(rope.veh)
		state.vehicle = veh and R.vehicleName(veh) or "?"
		state.winch = rope.winch
		state.moving = rope.nudge ~= nil
		state.strain = rope.strain or 0
		state.ropeLoad = rope.ropeLoad or 0
		state.slack = rope.slack ~= false
		state.stuck = R.stuck(rope)
		state.length = rope.length
		if rope.anchorVeh then
			state.anchorVehicle = rope.anchorVeh.name
			state.anchorHitch = rope.anchorVeh.hitch
		else
			local hp = R.hookPoint(rope)
			if hp then
				state.hookOn = {vehicle = hp.name, hitch = hp.hitch}
			end
		end
		local grip = R.gripNow(rope)
		if grip and rope.target then state.distance = R.distance(grip, rope.target) end
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
		R.stopProbe()
		if rope then rope.nudge = nil end
	end
	pushApp()
end

-- buttons of the Tow app
function M.uiAttachView() local ok = attachAtView(); pushApp(); return ok end
function M.uiAttachVehicle(id)
	if not R.allowed() then return false end
	id = tonumber(id)
	local veh = id and be:getObjectByID(id)
	local ok, err = R.canRope(veh, id)
	local cam = R.cameraPos()
	if not ok or not cam then
		R.message(err or "Vehicle not found")
		return false
	end
	attach(id, function(rid)
		return string.format("sharedCareerVeh.ropeTieNearest(%d, %d, %.3f, %.3f, %.3f, %.2f, %.1f)",
			rid, R.TOW, cam.x, cam.y, cam.z, winchSpeed(), winchStrength())
	end)
	pushApp()
	return true
end
function M.uiRelease() M.release(); pushApp() end
--- Hook the anchor onto the point the ring shows.
function M.uiHookOn()
	local hp = R.hookPoint(rope)
	if not hp then return false end
	R.hook(rope, hp.vid, hp.cid)
	return true
end
--- The anchor comes off its vehicle and stays where it is.
function M.uiUnhook() R.unhook(rope); pushApp() end
function M.uiTowToRoad()
	local ok, err = M.towToRoad()
	R.message(ok and "Back on the road" or err)
	pushApp()
	return ok
end
function M.uiWinch(mode) M.setWinch(mode); pushApp() end
function M.uiFine(on) fine = on == true; pushApp() end
--- Pull strength in % of the vehicle's weight (capped at the server's client.winchStrength).
function M.uiStrength(v)
	v = tonumber(v)
	if not v then return end
	strengthPick = math.max(10, math.min(150, v))
	if rope then rope.since = 1 end
	pushApp()
end
--- Remote control: move the anchor while a button is held (f = forward, r = right, u = up; -1..1).
--- Not while it is hooked onto a vehicle.
function M.uiNudge(f, r, u)
	if not rope or rope.anchorVeh then return end
	rope.nudge = {f = tonumber(f) or 0, r = tonumber(r) or 0, u = tonumber(u) or 0}
	rope.since = 1
	pushApp()
end
function M.uiNudgeStop()
	if not rope then return end
	rope.nudge = nil
	rope.since = 1
	pushApp()
end
--- Put the anchor in the middle of the view, at its current distance from you.
function M.uiAnchorToView()
	if not rope or not rope.target or rope.anchorVeh then return end
	local cam, dir = R.cameraPos(), R.viewDir()
	if not cam or not dir then return end
	local dist = math.max(MIN_DISTANCE, math.min(R.MAX_DISTANCE, R.distance(rope.target, cam)))
	rope.target = {x = cam.x + dir.x * dist, y = cam.y + dir.y * dist, z = cam.z + dir.z * dist}
	rope.payOutOnce = true
	rope.since = 1
	pushApp()
end

-- the Tow app on the phone
local function registerPhoneApp()
	local phone = U.ext("sharedCareer_phone")
	if not phone or type(phone.registerApp) ~= "function" then return end
	if R.allowed() then
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
	return rope ~= nil
end

--- The tow rope (rope.lua), or nil.
function M.rope() return rope end

--== Hooks =====================================================================

function M.onUpdate(dtReal)
	-- the preview of where a rope would attach, while the app is open and no rope is on
	if appOpen and not rope and R.allowed() then R.probe("tie") end
	if appOpen then
		sinceAppPush = sinceAppPush + (tonumber(dtReal) or 0)
		if sinceAppPush >= APP_PUSH_EVERY then
			sinceAppPush = 0
			pcall(pushApp)
		end
	end
end

function M.onCareerActive(active)
	if active and U.isMP() then registerPhoneApp() end
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	R = extensions.sharedCareer_rope
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
