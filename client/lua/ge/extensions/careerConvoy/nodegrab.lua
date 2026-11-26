-- Career-Convoy :: node grabber in the career (client.allowNodeGrabber)
--
-- The career only allows the node grabber while walking. In a vehicle or in the free camera it
-- blocks it (career.lua, updateNodegrabberBlocking: input filter group
-- 'careerNodeGrabberActions'). With client.allowNodeGrabber = true this extension lifts exactly
-- that block again, right after the career sets it.
--
-- How: every change of the input filter fires the hook onActionFilterUpdated. The filter is
-- rebuilt from all groups that are still blocked (core/input/actionFilter.lua, updateFilters),
-- so lifting only the career's group keeps every other block in place – e.g. the vehicle
-- certification test (career/modules/vehiclePerformance.lua) still blocks the node grabber.
--
-- Switching it off again (or leaving the server) restores the career's own rule: blocked
-- unless walking.
--
-- Strength: the career's grab force is limited inside the engine (C++), not in Lua. Tested in
-- 0.8.10: passing up to 10x the strength to be.nodeGrabber:setStrength changed nothing, and the
-- single-player career is just as weak. So this extension only lifts the block, it can't make
-- the grabber stronger.

local M = {}

local U

local CAREER_GROUP = "careerNodeGrabberActions"
local GRAB_ACTION = "nodegrabberGrab"

local busy = false -- we change the filter ourselves: ignore the hook it fires
local lifted = false -- we lifted the career's block at least once
local left = false -- left the server: stay out until the next career start

local function filter()
	local f = extensions.core_input_actionFilter
	if type(f) == "table" and type(f.addAction) == "function" and type(f.isActionBlocked) == "function" then
		return f
	end
	return nil
end

local function allowed()
	local config = U and U.config()
	return config ~= nil and config.allowNodeGrabber == true
end

-- the career's own rule (career.lua): blocked in a vehicle or in the free camera
local function careerWouldBlock()
	local freeCam = core_camera
		and type(core_camera.getActiveGlobalCameraName) == "function"
		and core_camera.getActiveGlobalCameraName()
	local walking = gameplay_walk and type(gameplay_walk.isWalking) == "function" and gameplay_walk.isWalking()
	return freeCam ~= nil or not walking
end

local function setCareerBlock(blocked)
	local f = filter()
	if not f then
		return
	end
	busy = true
	local ok, err = pcall(f.addAction, 0, CAREER_GROUP, blocked)
	busy = false
	if not ok then
		U.log("E", "nodegrab", "could not change the input filter: " .. tostring(err))
	end
end

--- Lifts the career's block if the server allows the node grabber.
function M.update()
	if left or not U.isMP() or not allowed() or not U.careerActive() then
		return
	end
	local f = filter()
	if not f or not f.isActionBlocked(GRAB_ACTION) then
		return
	end
	setCareerBlock(false)
	if not lifted then
		lifted = true
		U.log("I", "nodegrab", "node grabber allowed in the career (server setting allowNodeGrabber)")
	end
end

--- Puts the career's own rule back (setting switched off, leaving the server).
local function restore()
	if not lifted then
		return
	end
	lifted = false
	if U.careerActive() and careerWouldBlock() then
		setCareerBlock(true)
	end
end

--== Hooks =====================================================================

function M.onActionFilterUpdated()
	if busy then
		return
	end
	M.update()
end

-- new settings from the server (called by core.lua)
function M.onConfigChanged()
	if allowed() then
		M.update()
	else
		restore()
	end
end

function M.onCareerActive(active)
	if active then
		left = false
		M.update()
	end
end

-- Leaving: other extensions still change the input filter while they clean up (e.g. core.lua
-- lifts its console block), which fires onActionFilterUpdated – `left` keeps us out of that.
function M.onBeamMPServerLeave()
	left = true
	restore()
end

function M.onExtensionLoaded()
	U = extensions.careerConvoy_util
end

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
