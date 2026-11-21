-- SharedCareer :: the Straps app – ratchet straps that hold a car on a trailer or truck
--
-- A car on a flatbed or trailer slides off in the first curve. Straps hold it down: each one runs
-- from a point of the car to a point of the vehicle below it (rope.lua, kind STRAP). A strap has
-- no winch: when it is hooked on, the vehicle pulls it tight a little and it keeps that length
-- (sharedCareerVeh.lua, "Ropes"). Everything runs in the phone app "Straps":
--
--   Strap down   look at the car: four straps at once, one at each corner. The car names four
--                sturdy, low points at the corners of its body (strapCorners); your vehicles near
--                it each name the nearest sturdy point below every corner (hookBelow), and each
--                corner takes the nearest answer. A corner without one is left out
--                ("3 of 4 strapped"). Not twice on the same car
--   Add strap    one strap by hand, in two steps: 1. aim at the car with the middle of the view (a
--                blue ball shows where it is tied) -> "Here"; 2. move the strap's end with the
--                remote (ropeRemote.lua, the same as the Tow app's anchor; at most STRAP_REACH m
--                from the car) to the truck or trailer: a ring shows where it would hook on, with a
--                dashed line to it -> "Hook on". "Cancel" in between takes it off again
--   Tighten      pulls every strap tight like a very weak winch: it hauls in at TIGHTEN_SPEED until
--                it holds TIGHTEN_STRENGTH % of the car's weight, then it is locked again (or after
--                TIGHTEN_TIME s). A strap that is already that tight stays as it is
--   the list     every strap with a dot for its load (green, yellow, red); remove one, or all
--   Remove rope  while the tow rope (Tow app) is still on a strapped car: takes it off, so you
--                don't need to go back to the Tow app
-- The Tow app has its own "Strap down" (strapOnto): once the car on the rope is pulled up onto the
-- vehicle the rope is hooked on, it straps it onto that vehicle, without aiming.
--
-- What you see: straps are a wide yellow band (rope.lua) with a ratchet at the lower end – a
-- dark block with a yellow lever. They turn orange and red as their load gets close to breaking.
-- A strap comes off when one of the two vehicles is reset or removed, when the part it holds
-- tears off, or when it snaps.
--
-- Server setting: client.allowRopes (on/off, together with the Tow app).

local M = {}

local U, R, Remote

local STRAP_REACH = 3      -- m: a strap's end by hand stays this close to the car
local CARRIER_SEARCH = 12  -- m from the car: your vehicles this close are asked for points below it
local STRAP_WAIT = 0.5     -- s to wait for the vehicles' answers (Strap down)
local MAX_STRAPS = 16      -- straps at most, on all vehicles
local APP_PUSH_EVERY = 0.2 -- s: how often the app gets the state while it's open
local TIGHTEN_SPEED = 0.1  -- m/s Tighten hauls a strap in at most
local TIGHTEN_STRENGTH = 25 -- % of the car's weight: Tighten stops at this pull, per strap
local TIGHTEN_TIME = 6     -- s: Tighten stops after this long anyway
local TIGHT = 0.95         -- a strap's winch load (1 = TIGHTEN_STRENGTH) from which it counts as tight

local appOpen = false
local fine = false         -- fine mode for the remote
local sinceAppPush = 0
local clock = 0
local pick = nil           -- adding a strap by hand: {step = 1} or {step = 2, rope}
local tightenUntil = nil   -- Tighten runs until this clock time
local pending = nil        -- Strap down: {req, cargo, at, corners = {{cid, x, y, z}}, asked = {vid = true},
                           --  best = {[corner] = {vid, cid, d}}}
local nextReq = 1
local pushApp              -- defined with the app below

local function straps() return R.list(R.STRAP) end

local function strapCount(cargo)
	local n = 0
	for _, r in ipairs(straps()) do
		if cargo == nil or r.veh == cargo then n = n + 1 end
	end
	return n
end

--== Drawing ======================================================================

local LOOSE_END = {1, 0.78, 0.15}

-- the ratchet at the strap's lower end: a dark block along the strap, a yellow lever on it. A
-- loose end (adding a strap by hand) also gets the remote's ground marker and hook points.
local function drawEnd(r, a, b)
	local S = R.shapes
	if not r.anchorVeh then
		S.ball(b, 0.05, ColorF(LOOSE_END[1], LOOSE_END[2], LOOSE_END[3], 0.95))
		Remote.groundMarker(b, LOOSE_END)
		Remote.drawHookPoints(r, b)
	end
	local d = R.distance(a, b)
	if d < 0.01 then return end
	local k = math.min(0.15, d / 2) / d
	local top = {x = b.x + (a.x - b.x) * k, y = b.y + (a.y - b.y) * k, z = b.z + (a.z - b.z) * k}
	local body = ColorF(0.18, 0.18, 0.2, 0.95)
	if not S.cylinder(b, top, 0.05, body) then S.line(b, top, body) end
	S.ball(top, 0.035, ColorF(1, 0.78, 0.15, 0.95))
end

--== Straps ========================================================================

local function newStrap(cargo, tieCommand)
	local r = R.create(R.STRAP, cargo, tieCommand)
	r.drawEnd = drawEnd
	r.anchored = function(hooked)
		if pick and pick.rope == hooked then
			pick = nil
			hooked.update = nil
		end
		pushApp()
	end
	r.gone = function(gone)
		if pick and pick.rope == gone then pick = nil end
		pushApp()
	end
	return r
end

-- The car you look at, or nil and a message.
local function cargoInView()
	local cam, dir = R.cameraPos(), R.viewDir()
	local found = cam and dir and R.vehicleOnRay(cam, dir, function(veh, id) return R.canRope(veh, id) end)
	if not found then return nil, "Look at the car" end
	return found
end

-- Four straps at the corners of a car: onto `carrier` only, or with nil onto any of your vehicles
-- near it.
local function strapCar(cargo, carrier)
	if not R.allowed() then return false, "Ropes are off on this server" end
	if pending then return false end
	if strapCount(cargo) > 0 then return false, "Already strapped" end
	if strapCount() + 4 > MAX_STRAPS then return false, "Too many straps" end
	pending = {req = nextReq, cargo = cargo, carrier = carrier, at = clock, asked = {}, best = {}}
	nextReq = nextReq + 1
	R.sendToVehicle(cargo, string.format("sharedCareerVeh.strapCorners(%d)", pending.req))
	return true
end

--- Strap down: four straps at the corners of the car you look at.
function M.strapDown()
	if not R.allowed() then return false, "Ropes are off on this server" end
	local found, err = cargoInView()
	if not found then return false, err end
	return strapCar(found.id)
end

--- Strap a car down onto one vehicle (the Tow app: the car on the rope onto the vehicle the rope is
--- hooked on).
function M.strapOnto(cargo, carrier) return strapCar(cargo, carrier) end

--- The car has straps on.
function M.isStrapped(cargo) return strapCount(cargo) > 0 end

--- A Strap down is waiting for the vehicles' answers.
function M.busy() return pending ~= nil end

-- All answers are in (or the time is up): tie a strap at each corner that has a point below it.
local function finishStrapDown()
	local p = pending
	pending = nil
	local n = 0
	for i, c in ipairs(p.corners or {}) do
		local best = p.best[i]
		if best and be:getObjectByID(p.cargo) then
			local r = newStrap(p.cargo, function(rid)
				return string.format("sharedCareerVeh.ropeTieNode(%d, %d, %d)", rid, R.STRAP, c.cid)
			end)
			r.hookAfterTie = {vid = best.vid, cid = best.cid}
			n = n + 1
		end
	end
	if n == 0 then
		R.message("Nothing below to strap to")
	elseif n < #p.corners then
		R.message(string.format("%d of %d strapped", n, #p.corners))
	else
		R.message("Strapped down")
	end
	pushApp()
end

--- The car names its corners ("cid,x,y,z;..."): ask your vehicles near it for points below them.
function M.onStrapCorners(id, req, list)
	if not pending or pending.req ~= req or pending.cargo ~= id then return end
	local corners = {}
	for cid, x, y, z in tostring(list or ""):gmatch("(%d+),([-%d%.]+),([-%d%.]+),([-%d%.]+)") do
		table.insert(corners, {cid = tonumber(cid), x = tonumber(x), y = tonumber(y), z = tonumber(z)})
	end
	pending.corners = corners
	local cargo = be:getObjectByID(id)
	local at = cargo and type(cargo.getPosition) == "function" and R.vecOf(cargo:getPosition())
	if #corners == 0 or not at then
		pending = nil
		R.message("Can't strap this car")
		return
	end
	local text = {}
	for _, c in ipairs(corners) do table.insert(text, string.format("%.3f,%.3f,%.3f", c.x, c.y, c.z)) end
	local count = type(be.getObjectCount) == "function" and be:getObjectCount() or 0
	for i = 0, count - 1 do
		local veh = be:getObject(i)
		local vid = veh and type(veh.getID) == "function" and veh:getID()
		local p = vid and type(veh.getPosition) == "function" and R.vecOf(veh:getPosition())
		if p and (not pending.carrier or vid == pending.carrier) and R.canHold(veh, vid, id)
			and R.distance(p, at) <= CARRIER_SEARCH then
			pending.asked[vid] = true
			R.sendToVehicle(vid, string.format("sharedCareerVeh.hookBelow(%d, %q)", req, table.concat(text, ";")))
		end
	end
	if not next(pending.asked) then
		pending = nil
		R.message("Nothing below to strap to")
	end
end

--- A vehicle near the car names, per corner, its nearest point below it ("corner,cid,d;...").
function M.onHookBelow(id, req, list)
	if not pending or pending.req ~= req or not pending.asked[id] then return end
	pending.asked[id] = nil
	for i, cid, d in tostring(list or ""):gmatch("(%d+),(%d+),([%d%.]+)") do
		i, cid, d = tonumber(i), tonumber(cid), tonumber(d)
		local best = pending.best[i]
		if not best or d < best.d then pending.best[i] = {vid = id, cid = cid, d = d} end
	end
	if not next(pending.asked) then finishStrapDown() end
end

--- Adding a strap by hand: start (step 1, aim at the car).
function M.addStrap()
	if not R.allowed() then return false end
	if strapCount() >= MAX_STRAPS then return false, "Too many straps" end
	M.cancel()
	pick = {step = 1}
	return true
end

-- adding a strap by hand, step 2: the remote moves the strap's end, close to the car
local function moveEnd(r, dt)
	Remote.move(r, dt, fine and Remote.FINE or 1, STRAP_REACH)
end

--- "Here" (step 1): ties the strap to the car you look at; its end then hangs there for the remote.
function M.here()
	if not (pick and pick.step == 1) then return false end
	local found, err = cargoInView()
	if not found then return false, err end
	local cam, dir = R.cameraPos(), R.viewDir()
	local r = newStrap(found.id, function(rid)
		return string.format("sharedCareerVeh.ropeTieRay(%d, %d, %.3f, %.3f, %.3f, %.4f, %.4f, %.4f, %d)",
			rid, R.STRAP, cam.x, cam.y, cam.z, dir.x, dir.y, dir.z, R.MAX_DISTANCE)
	end)
	r.update = moveEnd
	pick = {step = 2, rope = r}
	R.stopProbe()
	return true
end

--- "Hook on" (step 2): the strap's end goes onto the point the ring shows.
function M.hookOn()
	if not (pick and pick.step == 2) then return false end
	if not Remote.hookOn(pick.rope) then return false, "Move it to your truck or trailer" end
	return true
end

--- Tighten: every strap hauls in like a very weak winch until it is tight.
function M.tighten()
	local any = false
	for _, r in ipairs(straps()) do
		if r.anchorVeh then
			r.winch, r.speed, r.strength, r.strain = 1, TIGHTEN_SPEED, TIGHTEN_STRENGTH, 0
			any = true
		end
	end
	tightenUntil = any and clock + TIGHTEN_TIME or nil
	return any
end

-- every frame while Tighten runs: a strap that is tight is locked again, all of them at the end
local function tightenStep()
	local running = false
	for _, r in ipairs(straps()) do
		if r.winch == 1 then
			if clock >= tightenUntil or (r.strain or 0) >= TIGHT then r.winch = 0 else running = true end
		end
	end
	if not running then tightenUntil = nil end
end

--- Stop adding a strap by hand; a strap tied in step 1 comes off again.
function M.cancel()
	if pick and pick.rope then
		local r = pick.rope
		pick = nil
		R.release(r)
	end
	pick = nil
end

--== Straps app (phone) ============================================================

-- The tow rope (Tow app), while it is on a car that has straps: then the Straps app offers to
-- take it off.
local function towRopeOnStrapped()
	local tow = U.ext("sharedCareer_tow")
	local r = tow and tow.rope()
	if r and strapCount(r.veh) > 0 then return r end
	return nil
end

--- State for the Straps app.
function M.appState()
	local state = {allowed = R.allowed(), step = pick and pick.step or 0, busy = pending ~= nil, straps = {},
		towRope = towRopeOnStrapped() ~= nil, fine = fine, tightening = tightenUntil ~= nil}
	if pick and pick.step == 2 then state.hookOn = Remote.hookOnState(pick.rope) end
	local n = 0
	for _, r in ipairs(straps()) do
		if r.anchorVeh then
			n = n + 1
			local veh = be:getObjectByID(r.veh)
			table.insert(state.straps, {id = r.id, n = n, vehicle = veh and R.vehicleName(veh) or "?",
				load = r.ropeLoad or 0, slack = r.slack ~= false})
		end
	end
	return state
end

function pushApp()
	if guihooks and type(guihooks.trigger) == "function" then guihooks.trigger("SharedCareerStraps", M.appState()) end
end

function M.setAppOpen(on)
	appOpen = on == true
	if not appOpen then
		M.cancel()
		R.stopProbe()
		fine = false
	end
	pushApp()
end

local function tell(ok, err)
	if not ok and err then R.message(err) end
	pushApp()
	return ok
end

-- buttons of the Straps app
function M.uiStrapDown() return tell(M.strapDown()) end
function M.uiAddStrap() return tell(M.addStrap()) end
function M.uiHere() return tell(M.here()) end
function M.uiHookOn() return tell(M.hookOn()) end
function M.uiTighten() return tell(M.tighten()) end
function M.uiFine(on) fine = on == true; pushApp() end
--- The remote (ropeRemote.lua, remote.html) for the strap's end while adding one by hand.
function M.uiNudge(f, r, u) if pick and pick.rope then Remote.nudge(pick.rope, f, r, u) end; pushApp() end
function M.uiNudgeStop() if pick and pick.rope then Remote.nudgeStop(pick.rope) end; pushApp() end
function M.uiToView() if pick and pick.rope then Remote.toView(pick.rope, STRAP_REACH) end; pushApp() end
function M.uiCancel() M.cancel(); pushApp() end
function M.uiRemove(rid) R.release(R.get(tonumber(rid))); pushApp() end
function M.uiRemoveAll() M.cancel(); R.releaseAll(R.STRAP); pushApp() end
--- The tow rope comes off the strapped car.
function M.uiRemoveRope()
	if towRopeOnStrapped() then U.ext("sharedCareer_tow").release() end
	pushApp()
end

local function registerPhoneApp()
	local phone = U.ext("sharedCareer_phone")
	if not phone or type(phone.registerApp) ~= "function" then return end
	if R.allowed() then
		phone.registerApp({id = "straps", title = "Straps", icon = "straps", color = "#c9971c", order = 11,
			onOpen = function() M.setAppOpen(true) end, onClose = function() M.setAppOpen(false) end})
	else
		phone.unregisterApp("straps")
		M.setAppOpen(false)
	end
end

function M.onConfigChanged()
	if not R.allowed() then
		M.cancel()
		pending, tightenUntil = nil, nil
	end
	registerPhoneApp()
end

--== Hooks =========================================================================

function M.onUpdate(dtReal)
	local dt = tonumber(dtReal) or 0
	clock = clock + dt
	if pending and clock - pending.at > STRAP_WAIT then
		if pending.corners then
			finishStrapDown()
		else
			pending = nil
			R.message("Can't strap this car")
			pushApp()
		end
	end
	if tightenUntil then tightenStep() end
	if appOpen and pick and pick.step == 1 then R.probe() end
	if appOpen then
		sinceAppPush = sinceAppPush + dt
		if sinceAppPush >= APP_PUSH_EVERY then
			sinceAppPush = 0
			pcall(pushApp)
		end
	end
end

function M.onCareerActive(active)
	if active and U.isMP() then registerPhoneApp() end
end

function M.onBeamMPServerLeave()
	pick, pending, tightenUntil = nil, nil, nil
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	R = extensions.sharedCareer_rope
	Remote = extensions.sharedCareer_ropeRemote
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
