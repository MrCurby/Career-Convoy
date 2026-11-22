-- SharedCareer :: shared helpers (client)
--
--   VERSION          mod version; must match the server version (otherwise a warning dialog)
--   log              log line under "sharedCareer.<area>" in beamng.log
--   isMP             true on a BeamMP server (otherwise the mod does nothing)
--   careerActive     the career is running
--   saveCareer       save the running career at once (after money changed hands)
--   send / on        message to the server / handler for server messages
--   decode           read JSON safely (broken data -> nil instead of a crash)
--   toast            short notification in the game
--   ext              get an extension without loading it by accident
--   config           client settings from the server (core.lua), nil before they arrive
--   readState / writeState
--                    small file settings/sharedCareer/state.json on the player's PC
--                    (one-time flags, "Don't show again")
--   addKey           key binding via BeamMP (Options → Controls → BeamMP, rebindable)
--   profileName      profile name the way the game builds it (lower case, only a-z0-9)
--   replace / isOurs replace a game function safely without wrapping our own wrapper twice
--   translate        a game text key in the player's language (nil if there is no text for it)
--   facilities       the map's facilities (gas stations, garages, ...) from freeroam_facilities
--   facilityDoor     the middle of a facility's doors, or nil
--   takeRoute / setRoute / clearRoute
--                    the one route on the road; a new owner makes the old one drop theirs

local M = {}

M.VERSION = "0.31"

local unpack = table.unpack or unpack

function M.pack(...)
	return { n = select("#", ...), ... }
end
M.unpack = unpack

function M.log(level, tag, msg)
	log(level, "sharedCareer." .. tag, msg)
end

--- The career is running (in single player too; combine with isMP for the multiplayer career).
function M.careerActive()
	return career_career and type(career_career.isActive) == "function" and career_career.isActive() == true
end

--- Saves the running career at once (after money changed hands). Logs under `tag` if that fails.
function M.saveCareer(tag)
	local saveSystem = rawget(_G, "career_saveSystem")
	if not saveSystem or type(saveSystem.saveCurrent) ~= "function" then
		return false
	end
	local ok, err = pcall(saveSystem.saveCurrent)
	if not ok then
		M.log("E", tag, "saving failed: " .. tostring(err))
	end
	return ok
end

-- true while we are on a BeamMP server.
function M.isMP()
	local net = rawget(_G, "MPCoreNetwork")
	if type(net) ~= "table" or type(net.isMPSession) ~= "function" then
		return false
	end
	local ok, session = pcall(net.isMPSession)
	return ok and session == true
end

function M.decode(data)
	if type(data) ~= "string" or data == "" or data == "null" then
		return nil
	end
	local ok, value = pcall(jsonDecode, data)
	if ok and type(value) == "table" then
		return value
	end
	return nil
end

function M.send(event, value)
	if type(rawget(_G, "TriggerServerEvent")) ~= "function" then
		return
	end
	TriggerServerEvent(event, type(value) == "string" and value or jsonEncode(value or {}))
end

function M.on(event, handler)
	if type(rawget(_G, "AddEventHandler")) ~= "function" then
		return
	end
	AddEventHandler(event, handler)
end

function M.toast(kind, msg, seconds)
	if guihooks and type(guihooks.trigger) == "function" then
		guihooks.trigger("toastrMsg", {
			type = kind,
			title = "SharedCareer",
			msg = msg,
			config = { timeOut = (seconds or 5) * 1000 },
		})
	end
end

-- Look up an extension without loading it by accident (extensions has an __index that
-- loads missing extensions).
function M.ext(name)
	local m = (type(extensions) == "table" and rawget(extensions, name)) or rawget(_G, name)
	if type(m) == "table" then
		return m
	end
	return nil
end

--- Client settings from the server (nil until sc_config has arrived).
function M.config()
	local core = M.ext("sharedCareer_core")
	return core and core.getConfig()
end

--== Position and money ===========================================================

--- {x, y, z} of a vec3 or table, or nil.
function M.vecOf(v)
	if v == nil then
		return nil
	end
	local ok, x, y, z = pcall(function()
		return v.x, v.y, v.z
	end)
	if not ok or not tonumber(x) then
		return nil
	end
	return { x = tonumber(x), y = tonumber(y) or 0, z = tonumber(z) or 0 }
end

--- Where you are: your vehicle (on foot: the unicycle), or the camera. {x, y, z} or nil.
function M.myPosition()
	local veh = type(getPlayerVehicle) == "function" and getPlayerVehicle(0) or nil
	if veh then
		local ok, p = pcall(function()
			return veh:getPosition()
		end)
		if ok and p then
			return M.vecOf(p)
		end
	end
	if core_camera and type(core_camera.getPosition) == "function" then
		local ok, p = pcall(core_camera.getPosition)
		if ok and p then
			return M.vecOf(p)
		end
	end
	return nil
end

--- Your career money, or nil without a running career.
function M.money()
	local attrs = rawget(_G, "career_modules_playerAttributes")
	if type(attrs) ~= "table" or type(attrs.getAttribute) ~= "function" then
		return nil
	end
	local attribute = attrs.getAttribute("money")
	return type(attribute) == "table" and tonumber(attribute.value) or nil
end

--== Route (the game's navigation on the road) ==================================
-- There is only one route. Who set it last owns it: players.lua (following a player),
-- jobs.lua, fuel.lua. The owner before is told with onRouteLost() and drops its route –
-- otherwise BeamMP's player following would keep putting the route back to the player.

local routeOwner = nil -- extension short name, e.g. "jobs"

--- `owner` takes the route over; the owner before gets onRouteLost().
function M.takeRoute(owner)
	local before = routeOwner
	routeOwner = owner
	if before and before ~= owner then
		local ext = M.ext("sharedCareer_" .. before)
		if ext and type(ext.onRouteLost) == "function" then
			ext.onRouteLost()
		end
	end
end

--- `owner` sets the route to pos ({x, y, z}); false if the game has no navigation.
function M.setRoute(owner, pos)
	local markers = rawget(_G, "core_groundMarkers")
	if not markers or type(markers.setPath) ~= "function" then
		return false
	end
	M.takeRoute(owner)
	local ok, err = pcall(markers.setPath, vec3(pos.x, pos.y, pos.z))
	if not ok then
		M.log("E", owner, "setting the route failed: " .. tostring(err))
	end
	return ok
end

--- Clears the route, but only if `owner` still owns it (not a route someone else set since).
function M.clearRoute(owner)
	if routeOwner ~= owner then
		return
	end
	routeOwner = nil
	local markers = rawget(_G, "core_groundMarkers")
	if markers and type(markers.setPath) == "function" then
		pcall(markers.setPath, nil)
	end
end

--== Game texts and map facilities ==============================================

--- A game text key (e.g. a facility name) in the player's language, nil without a text for it.
function M.translate(key)
	if type(key) ~= "string" then
		return nil
	end
	if type(translateLanguage) == "function" then
		local ok, text = pcall(translateLanguage, key, key)
		if ok and type(text) == "string" and text ~= key then
			return text
		end
	end
	return nil
end

--- The facilities of the current map ({gasStations = {...}, garages = {...}, ...}), or nil.
function M.facilities()
	local facilities = rawget(_G, "freeroam_facilities")
	if type(facilities) ~= "table" or type(facilities.getFacilities) ~= "function" then
		return nil
	end
	local level = type(getCurrentLevelIdentifier) == "function" and getCurrentLevelIdentifier() or nil
	if not level then
		return nil
	end
	local ok, data = pcall(facilities.getFacilities, level)
	if not ok or type(data) ~= "table" then
		return nil
	end
	return data
end

--- The middle of a facility's doors {x, y, z}, or nil (also for the map origin, which the game
--- returns as a placeholder while it doesn't know the doors yet).
function M.facilityDoor(facility)
	local facilities = rawget(_G, "freeroam_facilities")
	if not facilities or type(facilities.getAverageDoorPositionForFacility) ~= "function" then
		return nil
	end
	local ok, p = pcall(facilities.getAverageDoorPositionForFacility, facility)
	-- a vec3 in the game (LuaJIT cdata), a table in the tests: both have .x
	if not ok or not p or not tonumber(p.x) then
		return nil
	end
	if math.abs(p.x) + math.abs(p.y) + math.abs(p.z) < 1 then
		return nil
	end
	return { x = p.x, y = p.y, z = p.z }
end

--== state.json =================================================================

local STATE_FILE = "settings/sharedCareer/state.json"

-- flags in state.json that were renamed: old -> new (taken over once on reading)
local STATE_RENAMED = {
	timeAppAdded = "menuAppAdded", -- 0.15.0: the menu app was called sharedCareerTime
}

--- The state file as a table (empty if it is missing or broken), with renamed flags migrated.
function M.readState()
	local ok, state = pcall(jsonReadFile, STATE_FILE)
	state = (ok and type(state) == "table") and state or {}
	for old, new in pairs(STATE_RENAMED) do
		if state[old] ~= nil then
			if state[new] == nil then
				state[new] = state[old]
			end
			state[old] = nil
		end
	end
	return state
end

--- Writes the state file. Returns true if it worked; logs the error otherwise.
function M.writeState(state)
	local ok, err = pcall(jsonWriteFile, STATE_FILE, state, true)
	if not ok then
		M.log("E", "util", "could not write " .. STATE_FILE .. ": " .. tostring(err))
	end
	return ok
end

--== Keys ========================================================================

--- Registers a key via BeamMP's key bindings (MPKeybindsGE.addAction). def = {title, desc,
--- default, onDown, onUp}. Returns true if it worked; logs under `tag` otherwise.
function M.addKey(tag, action, def)
	local keys = rawget(_G, "MPKeybindsGE")
	if type(keys) ~= "table" or type(keys.addAction) ~= "function" then
		M.log(
			"W",
			tag,
			"MPKeybindsGE.addAction not available – no key '" .. tostring(def.title) .. "' (BeamMP too old?)"
		)
		return false
	end
	local ok, err = pcall(keys.addAction, action, def)
	if not ok then
		M.log("E", tag, "could not register the key '" .. tostring(def.title) .. "': " .. tostring(err))
	end
	return ok
end

-- Profile name from the BeamMP name. The game itself lowercases, keeps only a-z0-9 and
-- appends a number on a collision – that would make the name differ from PC to PC.
-- So we do it deterministically up front.
function M.profileName(nickname, suffix)
	local name = string.lower(tostring(nickname or "") .. tostring(suffix or ""))
	name = name:gsub("[^a-z0-9]", "")
	if name == "" then
		name = "sharedcareer"
	end
	return name
end

--== Replacing functions without wrapping twice ===============================
-- Career modules are reloaded on every career start (new table). A wrapper therefore has
-- to be checked regularly and set again on the current table. So that we never wrap our
-- own wrapper again (stack overflow after a few levels), all wrappers are remembered in a
-- weak table.

local ours = setmetatable({}, { __mode = "k" })

function M.isOurs(fn)
	return type(fn) == "function" and ours[fn] == true
end

-- Replaces module[fnName] with makeWrapper(original). Returns true if the function is
-- now our wrapper (newly set or already before).
function M.replace(module, fnName, makeWrapper)
	if type(module) ~= "table" or type(module[fnName]) ~= "function" then
		return false
	end
	if ours[module[fnName]] then
		return true
	end
	local wrapper = makeWrapper(module[fnName])
	ours[wrapper] = true
	module[fnName] = wrapper
	return true
end

return M
