-- SharedCareer :: shared helpers (client)
--
--   VERSION          mod version; must match the server version (otherwise a warning dialog)
--   log              log line under "sharedCareer.<area>" in beamng.log
--   isMP             true on a BeamMP server (otherwise the mod does nothing)
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

local M = {}

M.VERSION = "0.15.1"

local unpack = table.unpack or unpack

function M.pack(...)
	return {n = select("#", ...), ...}
end
M.unpack = unpack

function M.log(level, tag, msg)
	log(level, "sharedCareer." .. tag, msg)
end

--- The career is running (in single player too; combine with isMP for the multiplayer career).
function M.careerActive()
	return career_career and type(career_career.isActive) == "function" and career_career.isActive() == true
end

-- true while we are on a BeamMP server.
function M.isMP()
	local net = rawget(_G, "MPCoreNetwork")
	if type(net) ~= "table" or type(net.isMPSession) ~= "function" then return false end
	local ok, session = pcall(net.isMPSession)
	return ok and session == true
end

function M.decode(data)
	if type(data) ~= "string" or data == "" or data == "null" then return nil end
	local ok, value = pcall(jsonDecode, data)
	if ok and type(value) == "table" then return value end
	return nil
end

function M.send(event, value)
	if type(rawget(_G, "TriggerServerEvent")) ~= "function" then return end
	TriggerServerEvent(event, type(value) == "string" and value or jsonEncode(value or {}))
end

function M.on(event, handler)
	if type(rawget(_G, "AddEventHandler")) ~= "function" then return end
	AddEventHandler(event, handler)
end

function M.toast(kind, msg, seconds)
	if guihooks and type(guihooks.trigger) == "function" then
		guihooks.trigger("toastrMsg", {
			type = kind, title = "SharedCareer", msg = msg,
			config = {timeOut = (seconds or 5) * 1000},
		})
	end
end

-- Look up an extension without loading it by accident (extensions has an __index that
-- loads missing extensions).
function M.ext(name)
	local m = (type(extensions) == "table" and rawget(extensions, name)) or rawget(_G, name)
	if type(m) == "table" then return m end
	return nil
end

--- Client settings from the server (nil until sc_config has arrived).
function M.config()
	local core = M.ext("sharedCareer_core")
	return core and core.getConfig()
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
			if state[new] == nil then state[new] = state[old] end
			state[old] = nil
		end
	end
	return state
end

--- Writes the state file. Returns true if it worked; logs the error otherwise.
function M.writeState(state)
	local ok, err = pcall(jsonWriteFile, STATE_FILE, state, true)
	if not ok then M.log("E", "util", "could not write " .. STATE_FILE .. ": " .. tostring(err)) end
	return ok
end

--== Keys ========================================================================

--- Registers a key via BeamMP's key bindings (MPKeybindsGE.addAction). def = {title, desc,
--- default, onDown, onUp}. Returns true if it worked; logs under `tag` otherwise.
function M.addKey(tag, action, def)
	local keys = rawget(_G, "MPKeybindsGE")
	if type(keys) ~= "table" or type(keys.addAction) ~= "function" then
		M.log("W", tag, "MPKeybindsGE.addAction not available – no key '" .. tostring(def.title) .. "' (BeamMP too old?)")
		return false
	end
	local ok, err = pcall(keys.addAction, action, def)
	if not ok then M.log("E", tag, "could not register the key '" .. tostring(def.title) .. "': " .. tostring(err)) end
	return ok
end

-- Profile name from the BeamMP name. The game itself lowercases, keeps only a-z0-9 and
-- appends a number on a collision – that would make the name differ from PC to PC.
-- So we do it deterministically up front.
function M.profileName(nickname, suffix)
	local name = string.lower(tostring(nickname or "") .. tostring(suffix or ""))
	name = name:gsub("[^a-z0-9]", "")
	if name == "" then name = "sharedcareer" end
	return name
end

--== Replacing functions without wrapping twice ===============================
-- Career modules are reloaded on every career start (new table). A wrapper therefore has
-- to be checked regularly and set again on the current table. So that we never wrap our
-- own wrapper again (stack overflow after a few levels), all wrappers are remembered in a
-- weak table.

local ours = setmetatable({}, {__mode = "k"})

function M.isOurs(fn)
	return type(fn) == "function" and ours[fn] == true
end

-- Replaces module[fnName] with makeWrapper(original). Returns true if the function is
-- now our wrapper (newly set or already before).
function M.replace(module, fnName, makeWrapper)
	if type(module) ~= "table" or type(module[fnName]) ~= "function" then return false end
	if ours[module[fnName]] then return true end
	local wrapper = makeWrapper(module[fnName])
	ours[wrapper] = true
	module[fnName] = wrapper
	return true
end

return M
