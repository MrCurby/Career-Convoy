-- SharedCareer :: vehicle Lua (runs in every vehicle)
--
-- Called from the GE side via queueLuaCommand:
--   setGhost(enabled)              collisions with this vehicle on/off (vehicles.lua; ghost mode
--                                  for other players' cars / players on foot)
--   setAiTuning(gap, sightFactor)  traffic AI reacts earlier to obstacles (traffic.lua)
--
-- AI tuning: two values inside the game's lua/vehicle/ai.lua that have no official setter.
--   ego.race_time_gap      safety gap in seconds that the AI keeps to a vehicle on its path
--                          (game: 0.3 s). Larger = starts braking earlier, keeps more distance.
--   traffic.Rfl_fun(speed) how far ahead (meters) the AI checks its path for other vehicles
--                          (game: (speed + 10) * 3, clamped to 60..200 m). Larger factor = sees
--                          obstacles earlier.
-- Both live in local tables of ai.lua. They are found through the upvalues of the functions
-- in the `ai` module (Lua debug library), never by editing game files. If they can't be found
-- (a game update renamed them, or the debug library is unavailable), nothing is changed and
-- one line is logged. A value of 0 restores the game's own value.

local M = {}

local SEARCH_DEPTH = 4

function M.setGhost(enabled)
	obj:setGhostEnabled(enabled and true or false)
end

--== Finding the AI tables =====================================================

-- Walks the upvalues of all functions in the ai module (and of functions found there) and
-- returns the `ego` and `traffic` tables, or nil for the ones that weren't found.
local function findAiTables(aiModule)
	if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then return nil, nil end
	local ego, traffic
	local visited = {}
	local queue = {}
	for _, fn in pairs(aiModule) do
		if type(fn) == "function" and not visited[fn] then
			visited[fn] = true
			table.insert(queue, {fn, 1})
		end
	end
	local head = 1
	while head <= #queue and not (ego and traffic) do
		local fn, depth = queue[head][1], queue[head][2]
		head = head + 1
		local i = 1
		while true do
			local ok, name, value = pcall(debug.getupvalue, fn, i)
			if not ok or name == nil then break end
			if name == "ego" and type(value) == "table" and type(value.race_time_gap) == "number" then
				ego = value
			elseif name == "traffic" and type(value) == "table" and type(value.Rfl_fun) == "function" then
				traffic = value
			elseif type(value) == "function" and not visited[value] and depth < SEARCH_DEPTH then
				visited[value] = true
				table.insert(queue, {value, depth + 1})
			end
			i = i + 1
		end
	end
	return ego, traffic
end
M.findAiTables = findAiTables

--== Applying the values =======================================================

local original = nil   -- {gap, sight} = the game's values, remembered on first use
local warned = false

local function sightFunction(factor)
	local maxRange = math.max(200, math.min(300, 60 * factor))
	return function(speed)
		return math.max(60, math.min(maxRange, ((tonumber(speed) or 0) + 10) * factor))
	end
end

--- gap: safety gap in seconds (0 = game value). sightFactor: range factor (0 = game value).
--- Returns true if the AI tables were found.
function M.setAiTuning(gap, sightFactor)
	if type(ai) ~= "table" then return false end
	local ego, traffic = findAiTables(ai)
	if not ego or not traffic then
		if not warned then
			warned = true
			log("W", "sharedCareer.ai", "AI tuning not applied: ai.lua internals not found (game update?)")
		end
		return false
	end
	gap, sightFactor = tonumber(gap) or 0, tonumber(sightFactor) or 0
	if not original then
		original = {gap = ego.race_time_gap, sight = traffic.Rfl_fun}
		-- once per vehicle, so an in-game test can confirm it in beamng.log
		-- (pcall: only a log line, it must never stop the tuning itself)
		pcall(function()
			log("I", "sharedCareer.ai", string.format("AI tuning active: safety gap %.2f s -> %.2f s, sight range at 100 km/h %d m -> %d m",
				original.gap, gap > 0 and gap or original.gap, math.floor(original.sight(27.8) + 0.5),
				math.floor((sightFactor > 0 and sightFunction(sightFactor) or original.sight)(27.8) + 0.5)))
		end)
	end
	ego.race_time_gap = gap > 0 and gap or original.gap
	traffic.Rfl_fun = sightFactor > 0 and sightFunction(sightFactor) or original.sight
	return true
end

return M
