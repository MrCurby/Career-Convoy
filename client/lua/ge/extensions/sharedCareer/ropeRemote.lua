-- SharedCareer :: the remote for a rope's loose end – shared by the Tow and Straps apps
--
-- A rope (rope.lua) whose other end isn't on a vehicle yet has a loose end in the world: the Tow
-- app's anchor, or the end of a strap added by hand. The remote moves it, and shows where it
-- would hook on; the app only adds its own buttons and colors:
--
--   move      hold a button: forward/back and left/right as seen from the camera, up/down
--             (nudge / nudgeStop; the app's update calls move every frame). An app can keep the
--             end within `reach` m of where the rope is tied (a strap)
--   to view   the end goes to the middle of the view, at its distance from you (toView)
--   hook on   your vehicles near the end are asked where it would hook on (rope.lua, hook points):
--             a ring there with a dashed line from the end – green on a tow hitch, white elsewhere
--             – and rings on the tow hitches within a few meters, brighter as the end gets close.
--             The app offers "Hook on" (hookOnState, hookOn); nothing hooks on by itself
--   ground    an end above the ground gets a dashed drop line and a disc on the ground, so you can
--             tell where in the world it is (groundMarker)
--
-- The phone's buttons for it are one template, ui/modules/apps/SharedCareer-Phone/remote.html;
-- they call the open app's uiNudge, uiNudgeStop and uiToView.

local M = {}

local R, U

local NUDGE_SPEED = 1 -- m/s the end moves while a button is held
M.FINE = 0.25 -- fine mode: speed factor
local MIN_DISTANCE = 3 -- m, closest "to view" puts the end
local HITCH_NEAR = 3 -- m: closer than this, a hitch ring lights up

-- The remote's direction (f = forward, r = right, u = up) in the world, as seen from the camera.
local function nudgeVector(n)
	local f = R.viewDir() or { x = 0, y = 1, z = 0 }
	local len = math.sqrt(f.x * f.x + f.y * f.y)
	local fx, fy = 0, 1
	if len > 0.01 then
		fx, fy = f.x / len, f.y / len
	end
	local rx, ry = fy, -fx
	return { x = fx * n.f + rx * n.r, y = fy * n.f + ry * n.r, z = n.u }
end

-- p, pulled back to at most `reach` m from where the rope is tied (no reach: p)
local function withinReach(r, p, reach)
	local grip = reach and R.gripNow(r)
	if not grip then
		return p
	end
	local d = R.distance(grip, p)
	if d <= reach then
		return p
	end
	local k = reach / d
	return { x = grip.x + (p.x - grip.x) * k, y = grip.y + (p.y - grip.y) * k, z = grip.z + (p.z - grip.z) * k }
end

--- Hold a button: move the loose end (f = forward, r = right, u = up; -1..1). Not while it is on a
--- vehicle.
function M.nudge(r, f, right, u)
	if not r or r.anchorVeh then
		return
	end
	r.nudge = { f = tonumber(f) or 0, r = tonumber(right) or 0, u = tonumber(u) or 0 }
	r.since = 1
end

function M.nudgeStop(r)
	if not r then
		return
	end
	r.nudge = nil
	r.since = 1
end

--- Every frame, from the app's update: moves the loose end while a button is held, `factor` times
--- the normal speed (fine mode), at most `reach` m from where the rope is tied (nil: anywhere).
--- Sets r.moving and asks for the hook points while the end is loose.
function M.move(r, dt, factor, reach)
	if r.nudge and r.target and not r.anchorVeh then
		local v, s = nudgeVector(r.nudge), NUDGE_SPEED * (factor or 1) * dt
		r.target =
			withinReach(r, { x = r.target.x + v.x * s, y = r.target.y + v.y * s, z = r.target.z + v.z * s }, reach)
	end
	r.moving = r.nudge ~= nil
	r.wantHookPoints = not r.anchorVeh
end

--- The loose end to the middle of the view, at its current distance from you (at most `reach` m
--- from where the rope is tied). Returns true if it moved.
function M.toView(r, reach)
	if not r or not r.target or r.anchorVeh then
		return false
	end
	local cam, dir = R.cameraPos(), R.viewDir()
	if not cam or not dir then
		return false
	end
	local dist = math.max(MIN_DISTANCE, math.min(R.MAX_DISTANCE, R.distance(r.target, cam)))
	r.target = withinReach(r, { x = cam.x + dir.x * dist, y = cam.y + dir.y * dist, z = cam.z + dir.z * dist }, reach)
	r.payOutOnce = true
	r.since = 1
	return true
end

--- Where the end would hook on, for the app: {vehicle (name), hitch} or nil.
function M.hookOnState(r)
	local hp = R.hookPoint(r)
	return hp and { vehicle = hp.name, hitch = hp.hitch } or nil
end

--- Hook the end on where the ring shows. Returns true if there is such a point.
function M.hookOn(r)
	local hp = R.hookPoint(r)
	if not hp then
		return false
	end
	R.hook(r, hp.vid, hp.cid)
	return true
end

--== Drawing =========================================================================

-- The ground below a point (z), or nil: castRayStatic (static geometry and terrain) straight down.
-- The last answer is kept while the point stays where it is.
local GROUND_RANGE = 60 -- m
local groundCache = nil -- {x, y, z, ground}
local function groundBelow(p)
	local c = groundCache
	if c and math.abs(c.x - p.x) < 0.01 and math.abs(c.y - p.y) < 0.01 and math.abs(c.z - p.z) < 0.01 then
		return c.ground
	end
	local from = p.z + 0.05
	local hit = U.castRay(vec3(p.x, p.y, from), vec3(0, 0, -1), GROUND_RANGE)
	local ground = hit and from - hit
	groundCache = { x = p.x, y = p.y, z = p.z, ground = ground }
	return ground
end

local GROUND_MIN = 0.3 -- m above the ground before the marker shows
local DASH = 0.15 -- m: dash and gap of the drop line

--- A loose end above the ground: a dashed drop line to the ground and a disc there, in its color
--- {r, g, b}.
function M.groundMarker(p, rgb)
	local S = R.shapes
	local color = ColorF(rgb[1], rgb[2], rgb[3], 0.7)
	local g = groundBelow(p)
	if not g or p.z - g < GROUND_MIN then
		return
	end
	local z = p.z
	while z > g do
		local zEnd = math.max(g, z - DASH)
		S.line({ x = p.x, y = p.y, z = z }, { x = p.x, y = p.y, z = zEnd }, color)
		z = zEnd - DASH
	end
	local disc = ColorF(rgb[1], rgb[2], rgb[3], 0.3)
	if not S.cylinder({ x = p.x, y = p.y, z = g + 0.005 }, { x = p.x, y = p.y, z = g + 0.02 }, 0.3, disc) then
		S.line({ x = p.x - 0.3, y = p.y, z = g + 0.02 }, { x = p.x + 0.3, y = p.y, z = g + 0.02 }, color)
		S.line({ x = p.x, y = p.y - 0.3, z = g + 0.02 }, { x = p.x, y = p.y + 0.3, z = g + 0.02 }, color)
	end
end

--- The tow hitches near the loose end b (rings, brighter as it gets close) and the point where it
--- would hook on (a ring and a dashed line from b).
function M.drawHookPoints(r, b)
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

--== Hooks =========================================================================

function M.onExtensionLoaded()
	R, U = extensions.sharedCareer_rope, extensions.sharedCareer_util
end

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
