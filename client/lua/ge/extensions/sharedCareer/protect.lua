-- SharedCareer :: protection during the career start
--
-- Problem 1: career.lua cleans up the world on activation as if you were alone:
--   * removeVehicles == true  -> core_vehicles.removeAll()  (deletes ALL vehicles)
--   * otherwise               -> removeNonTrafficVehicles(), only spares IDs from
--                                gameplay_traffic.getTrafficList() and parked cars
-- In multiplayer those are the other players' cars. Both paths are intercepted here for
-- the duration of the start: removeAll only deletes our own vehicles, and the "safe"
-- list additionally contains all remote vehicles.
--
-- The protection is set in the onBeforeCareerActivate hook, which career.lua fires at the
-- very beginning of activateCareer. That way it works on every path into the career (join,
-- loading from the pause menu), even when activateCareer is called locally inside.
--
-- Problem 2: onCareerActive is sent to all modules without error protection. If one
-- throws, the following ones don't run any more (e.g. insurance without data). So during
-- the start every handler gets an xpcall around it.

local M = {}

local U -- sharedCareer_util

local PROTECTION_MAX_SECONDS = 60
local GUARD_MAX_SECONDS = 120

local protection = nil -- {remote = {[gameId]=true}, since, originals...}
local guard = nil -- {since, wrapped = {[module] = {original, wrapper}}}

--== remote vehicles ===========================================================

local function remoteVehicleIds()
	local remote = {}
	local mp = rawget(_G, "MPVehicleGE")
	if type(mp) ~= "table" or type(mp.getVehicles) ~= "function" then
		return remote
	end
	for _, vehicle in pairs(mp.getVehicles() or {}) do
		local id = vehicle.gameVehicleID
		if id and id ~= -1 and not mp.isOwn(id) then
			remote[id] = true
		end
	end
	return remote
end

local function installProtection()
	if protection then
		return
	end
	local remote = remoteVehicleIds()
	protection = { remote = remote, since = os.clockhp() }

	if gameplay_traffic and type(gameplay_traffic.getTrafficList) == "function" then
		local original = gameplay_traffic.getTrafficList
		protection.getTrafficList = original
		gameplay_traffic.getTrafficList = function(...)
			-- New table: the game returns its live list and appends entries to it afterwards.
			-- If we wrote into that list, it would be broken afterwards.
			local safe = {}
			local list = original(...)
			if type(list) == "table" then
				for _, id in ipairs(list) do
					table.insert(safe, id)
				end
			end
			for id in pairs(remote) do
				table.insert(safe, id)
			end
			return safe
		end
	end

	if core_vehicles and type(core_vehicles.removeAll) == "function" then
		protection.removeAll = core_vehicles.removeAll
		core_vehicles.removeAll = function()
			local spared = 0
			for i = be:getObjectCount() - 1, 0, -1 do
				local obj = be:getObject(i)
				local id = obj and obj:getID()
				if id then
					if remote[id] then
						spared = spared + 1
					else
						obj:delete()
					end
				end
			end
			U.log("I", "protect", "career start: spared " .. spared .. " vehicle(s) of other players")
		end
	end
	local n = 0
	for _ in pairs(remote) do
		n = n + 1
	end
	U.log("D", "protect", "protection active for " .. n .. " vehicle(s) of other players")
end

local function removeProtection()
	if not protection then
		return
	end
	if protection.getTrafficList and gameplay_traffic then
		gameplay_traffic.getTrafficList = protection.getTrafficList
	end
	if protection.removeAll and core_vehicles then
		core_vehicles.removeAll = protection.removeAll
	end
	protection = nil
end

--== protecting onCareerActive =================================================

local failures = {}

local function wrapHandlers()
	local ext = extensions
	if type(ext) ~= "table" or type(ext.getLoadedExtensionsNames) ~= "function" then
		return
	end
	for _, name in ipairs(ext.getLoadedExtensionsNames() or {}) do
		local m = rawget(ext, name) or rawget(_G, name)
		local original = type(m) == "table" and rawget(m, "onCareerActive")
		if type(original) == "function" and not guard.wrapped[m] then
			local wrapper = function(...)
				local ok, err = xpcall(original, debug.traceback, ...)
				if not ok then
					table.insert(failures, name)
					U.log(
						"E",
						"protect",
						name .. ".onCareerActive failed (the other handlers still run): " .. tostring(err)
					)
				end
			end
			guard.wrapped[m] = { original = original, wrapper = wrapper }
			m.onCareerActive = wrapper
		end
	end
	-- The hook cache has to be rebuilt, otherwise it keeps calling the old functions.
	if type(ext.hookUpdate) == "function" then
		ext.hookUpdate("onCareerActive")
	end
end

local function unwrapHandlers()
	if not guard then
		return
	end
	for m, entry in pairs(guard.wrapped) do
		if rawget(m, "onCareerActive") == entry.wrapper then
			m.onCareerActive = entry.original
		end
	end
	guard.wrapped = {}
	if type(extensions) == "table" and type(extensions.hookUpdate) == "function" then
		extensions.hookUpdate("onCareerActive")
	end
end

-- extensions.hook is replaced for the duration of the start: exactly when "onCareerActive"
-- is sent out, all career modules are loaded – that's when they get wrapped.
local function installGuard()
	if guard then
		return
	end
	local ext = extensions
	if type(ext) ~= "table" or type(ext.hook) ~= "function" then
		return
	end
	guard = { since = os.clockhp(), wrapped = {}, originalHook = ext.hook }
	local current = guard
	guard.hook = function(funcName, ...)
		if funcName ~= "onCareerActive" or guard ~= current then
			return current.originalHook(funcName, ...)
		end
		failures = {}
		wrapHandlers()
		return current.originalHook(funcName, ...)
	end
	ext.hook = guard.hook
end

local function removeGuard()
	if not guard then
		return
	end
	unwrapHandlers()
	if extensions.hook == guard.hook then
		extensions.hook = guard.originalHook
	end
	guard = nil
end

--== Hooks =====================================================================

function M.onBeforeCareerActivate()
	if not U.isMP() then
		return
	end
	installProtection()
	installGuard()
end

-- Runs itself as one of the onCareerActive handlers; the wrappers are removed afterwards.
function M.onCareerActive(active)
	removeProtection()
	-- Remove only in the next frame: we are in the middle of the hook loop right now.
	if guard then
		guard.removeNextFrame = true
	end
end

--- Runs fn with the protection active. Returns (true, results...) or (false, error).
function M.run(fn, ...)
	installProtection()
	installGuard()
	local args = U.pack(...)
	local results = U.pack(xpcall(function()
		return fn(U.unpack(args, 1, args.n))
	end, debug.traceback))
	-- On a level change onCareerActive only comes later; the protection then stays until
	-- then (or until the timeout). On an error it is removed immediately.
	if not results[1] then
		removeProtection()
		removeGuard()
	end
	return U.unpack(results, 1, results.n)
end

function M.getFailures()
	local out = {}
	for i, name in ipairs(failures) do
		out[i] = name
	end
	return out
end

function M.onUpdate()
	if guard and guard.removeNextFrame then
		removeGuard()
	end
	local t = os.clockhp()
	if protection and t - protection.since > PROTECTION_MAX_SECONDS then
		U.log("W", "protect", "protection removed after timeout")
		removeProtection()
	end
	if guard and t - guard.since > GUARD_MAX_SECONDS then
		removeGuard()
	end
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
end

function M.onExtensionUnloaded()
	removeProtection()
	removeGuard()
end

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
