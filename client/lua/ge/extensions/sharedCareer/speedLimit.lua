-- SharedCareer :: speedLimit: the speed limit of the road you drive on, shown as a sign
--
-- The limit comes from the game's road network: the road nearest to you (map.findClosestRoad) and
-- the speedLimit of its link (m/s). Off the road (farther than ROAD_MARGIN m beyond its edge) or on
-- a road without one there is no limit. Taxi jobs use it too (limitAt, TOLERANCE: speeding).
--
-- The sign is the UI app ui/modules/apps/SharedCareer-SpeedLimit/ (cleanup.lua adds it to the
-- career layout once, bottom right). Every CHECK_EVERY s while you drive a vehicle (not on foot)
-- this sends it guihook SharedCareerSpeedLimit {kmh, mph, unit, over, taxi}, only when something changed:
--   kmh    the limit in km/h, rounded to 5 (nil: no sign)
--   mph    the limit in mph, rounded to 5
--   unit   "km/h" or "mph", by the game's setting for units (uiUnitLength: metric / imperial); the
--          player can pick the unit in the phone's Settings instead (the window chooses)
--   over   you drive faster than the limit x TOLERANCE (the sign warns; a taxi ride loses pay)
--   taxi   your job is a taxi ride (the player can show the sign only then: phone, Settings)
-- Whether the sign shows at all is the player's choice (phone, Settings: off, taxi rides, always)
-- and is kept by the window.

local M = {}

local U

local CHECK_EVERY = 0.25 -- s between two looks at the road
local ROAD_MARGIN = 3 -- m beyond a road's edge that still count as on it
local MS_TO = { ["km/h"] = 3.6, mph = 2.23694 } -- m/s in each unit

M.TOLERANCE = 1.15 -- faster than the limit x this is speeding

local since = 0
local shown = nil -- what the sign shows: "kmh|mph|unit|over|taxi"

--- The speed limit (m/s) of the road at p ({x, y, z}), or nil (off the road, or a road without one).
function M.limitAt(p)
	local ok, limit = pcall(function()
		local a, b, d = map.findClosestRoad(vec3(p.x, p.y, p.z))
		local nodes = a and b and map.getMap().nodes
		local n, m = nodes and nodes[a], nodes and nodes[b]
		if not (n and m) or (tonumber(d) or math.huge) > (tonumber(n.radius) or 0) + ROAD_MARGIN then
			return nil
		end
		local link = (n.links or {})[b] or (m.links or {})[a]
		return type(link) == "table" and tonumber(link.speedLimit) or nil
	end)
	return ok and limit and limit > 0 and limit or nil
end

--- The unit of the game's speedometer: "mph" with imperial units, else "km/h".
function M.unit()
	local ok, length = pcall(function()
		return settings.getValue("uiUnitLength")
	end)
	return ok and length == "imperial" and "mph" or "km/h"
end

-- The sign now: {kmh, mph, unit, over, taxi}, or {} (no sign: on foot, off the road, no limit known).
local function signNow()
	local veh = type(getPlayerVehicle) == "function" and getPlayerVehicle(0) or nil
	if not veh or U.modelOf(veh) == "unicycle" or not U.careerActive() then
		return {}
	end
	local p = U.vecOf(veh:getPosition())
	local limit = p and M.limitAt(p)
	if not limit then
		return {}
	end
	local unit = M.unit()
	local v = type(veh.getVelocity) == "function" and U.vecOf(veh:getVelocity())
	local speed = v and math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) or 0
	local jobs = U.ext("sharedCareer_jobs")
	local job = jobs and type(jobs.getActive) == "function" and jobs.getActive() or nil
	return {
		kmh = math.floor(limit * MS_TO["km/h"] / 5 + 0.5) * 5,
		mph = math.floor(limit * MS_TO.mph / 5 + 0.5) * 5,
		unit = unit,
		over = speed > limit * M.TOLERANCE,
		taxi = type(job) == "table" and type(job.type) == "table" and job.type.id == "taxi" and not job.paidAt,
	}
end

function M.onUpdate(dtReal)
	since = since + (tonumber(dtReal) or 0)
	if since < CHECK_EVERY or not U.isMP() then
		return
	end
	since = 0
	local ok, sign = pcall(signNow)
	if not ok then
		sign = {}
	end
	local key = tostring(sign.kmh)
		.. "|"
		.. tostring(sign.mph)
		.. "|"
		.. tostring(sign.unit)
		.. "|"
		.. tostring(sign.over)
		.. "|"
		.. tostring(sign.taxi)
	if key ~= shown and guihooks and type(guihooks.trigger) == "function" then
		shown = key
		guihooks.trigger("SharedCareerSpeedLimit", sign)
	end
end

--- The window asks for the sign when it opens.
function M.uiRequest()
	shown = nil
end

function M.onBeamMPServerLeave()
	shown = nil
	if guihooks and type(guihooks.trigger) == "function" then
		guihooks.trigger("SharedCareerSpeedLimit", {})
	end
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
end

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
