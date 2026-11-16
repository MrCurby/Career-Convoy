-- SharedCareer :: the players' UI layouts
--
-- Two jobs on join (after the career start):
--   A) remove Mileage leftovers (client.cleanupMileageApps)
--   B) add the apps "SharedCareer Menu" and "SharedCareer Fuel" to the career layout ONCE each
--      (client.addTimeApp). Afterwards the mod remembers that in settings/sharedCareer/state.json;
--      players who remove an app don't get it forced on them again.
--
-- A) Mileage leftovers:
-- Mileage writes its apps (mileageplayerlist, mileageoffers, mileagerace) directly into the
-- player's UI layouts (settings/ui_apps/layouts/**.uilayout.json in the user folder) and
-- replaces the BeamMP player list with its own. Without Mileage, red "Unknown app" boxes
-- are left over – even in single player, because these are the player's own layouts.
--
-- This extension cleans that up once per server visit:
--   * apps whose name starts with "mileage" are removed from the layouts
--   * BeamMP's own list (beammpPlayerListVue) takes the place of the Mileage player list,
--     if the layout doesn't have one yet
--   * everything else (own arrangement, other mods, BeamMP chat …) stays unchanged
--   * before the first change every file is backed up as <file>.sharedcareer-backup
-- Can be switched off with client.cleanupMileageApps = false.

local M = {}

local U

local LAYOUT_DIRS = {"/settings/ui_apps/layouts/", "settings/ui_apps/layouts/"}
local BACKUP_SUFFIX = ".sharedcareer-backup"
local PLAYER_LISTS = {beammpPlayerListVue = true, beammpPlayerListAngular = true}
local REPLACEMENT_LIST = "beammpPlayerListVue"

local done = false

--== B) SharedCareer apps into the career layout once ===========================
-- Every app is added exactly ONCE (flag in settings/sharedCareer/state.json);
-- players who remove it afterwards don't get it forced on them again.

local STATE_FILE = "settings/sharedCareer/state.json"
local CAREER_LAYOUT = "settings/ui_apps/layouts/default/career.uilayout.json"
local CAREER_ORIGINAL = "settings/ui_apps/originalLayouts/default/career.uilayout.json"
local APPS = {
	{
		appName = "sharedCareerTime", stateKey = "timeAppAdded", label = "SharedCareer menu",
		-- right, below the BeamMP player list (which reaches down to about 590 px)
		placement = {position = "absolute", right = "0px", top = "600px", width = "345px", height = "160px",
			left = "", bottom = ""},
	},
	{
		appName = "sharedCareerFuel", stateKey = "fuelAppAdded", label = "SharedCareer fuel prices",
		-- directly below the menu at the right edge, WITHOUT overlap: BeamNG's frame around an app
		-- catches clicks over its whole area. When both apps lay on top of each other (0.8.0–0.8.3),
		-- the menu's steering-wheel tab could no longer be clicked.
		placement = {position = "absolute", right = "0px", top = "760px", width = "345px", height = "160px",
			left = "", bottom = ""},
	},
	{
		appName = "sharedCareerPhone", stateKey = "phoneAppAdded", label = "SharedCareer phone",
		-- only the tab (below the fuel app): the phone itself opens on top of the page, so the app
		-- frame never blocks clicks elsewhere
		placement = {position = "absolute", right = "0px", top = "920px", width = "30px", height = "80px",
			left = "", bottom = ""},
	},
}
M.APPS = APPS

local function readState()
	local ok, state = pcall(jsonReadFile, STATE_FILE)
	return (ok and type(state) == "table") and state or {}
end

--- Adds the SharedCareer apps to the career layout if that never happened yet. Returns the
--- number of apps added now.
function M.addAppsOnce()
	local state = readState()
	local todo = {}
	for _, def in ipairs(APPS) do
		if not state[def.stateKey] then table.insert(todo, def) end
	end
	if #todo == 0 then return 0 end
	-- The player's own career layout, otherwise the game's original as the base
	local okCustom, custom = pcall(jsonReadFile, CAREER_LAYOUT)
	local layout = okCustom and type(custom) == "table" and custom or nil
	if not layout then
		local okOrig, original = pcall(jsonReadFile, CAREER_ORIGINAL)
		layout = okOrig and type(original) == "table" and original or nil
	end
	if not layout or type(layout.apps) ~= "table" then
		U.log("W", "cleanup", "career layout not found – SharedCareer apps not added")
		return 0
	end
	local present = {}
	for _, app in ipairs(layout.apps) do
		if type(app) == "table" and app.appName then present[app.appName] = true end
	end
	local added = {}
	for _, def in ipairs(todo) do
		if present[def.appName] then
			state[def.stateKey] = true -- already there (added by the player): just remember it
		else
			local app = {appName = def.appName, placement = {}}
			for k, v in pairs(def.placement) do app.placement[k] = v end
			table.insert(layout.apps, app)
			table.insert(added, def)
		end
	end
	if #added > 0 then
		if okCustom and type(custom) == "table" and not FS:fileExists(CAREER_LAYOUT .. BACKUP_SUFFIX) then
			jsonWriteFile(CAREER_LAYOUT .. BACKUP_SUFFIX, custom, true)
		end
		if not pcall(jsonWriteFile, CAREER_LAYOUT, layout, true) then
			U.log("E", "cleanup", "could not write " .. CAREER_LAYOUT)
			return 0
		end
		for _, def in ipairs(added) do
			state[def.stateKey] = true
			U.log("I", "cleanup", def.label .. " added to the career layout")
		end
	end
	jsonWriteFile(STATE_FILE, state, true)
	return #added
end
-- One-time corrections of apps that were already placed: 0.7.2 put the fuel app 350 px to the
-- left of the menu – collapsed, its tab floated in the middle of the screen. Now at the edge.
local MOVES = {
	{stateKey = "fuelAppAtEdge", appName = "sharedCareerFuel", from = {right = "350px"}, to = {right = "0px", top = "600px"}},
	-- 0.8.0–0.8.3: fuel app exactly on top of the menu -> covered the steering-wheel tab. Move it below.
	{stateKey = "fuelAppBelowMenu", appName = "sharedCareerFuel", from = {right = "0px", top = "600px"}, to = {top = "760px"}},
}

function M.moveAppsOnce()
	local state = readState()
	local todo = {}
	for _, mv in ipairs(MOVES) do
		if not state[mv.stateKey] then table.insert(todo, mv) end
	end
	if #todo == 0 then return 0 end
	local ok, layout = pcall(jsonReadFile, CAREER_LAYOUT)
	if not ok or type(layout) ~= "table" or type(layout.apps) ~= "table" then return 0 end
	local moved = 0
	for _, mv in ipairs(todo) do
		for _, app in ipairs(layout.apps) do
			if type(app) == "table" and app.appName == mv.appName and type(app.placement) == "table" then
				local matches = true
				for k, v in pairs(mv.from) do if app.placement[k] ~= v then matches = false end end
				if matches then
					for k, v in pairs(mv.to) do app.placement[k] = v end
					moved = moved + 1
				end
			end
		end
		state[mv.stateKey] = true
	end
	if moved > 0 and not pcall(jsonWriteFile, CAREER_LAYOUT, layout, true) then
		U.log("E", "cleanup", "could not write " .. CAREER_LAYOUT)
		return 0
	end
	jsonWriteFile(STATE_FILE, state, true)
	if moved > 0 then U.log("I", "cleanup", "moved " .. moved .. " SharedCareer app(s) to their new position") end
	return moved
end

-- old name (tests, older callers)
M.addTimeAppOnce = function() return M.addAppsOnce() > 0 end

local function isMileageApp(name)
	return type(name) == "string" and name:lower():sub(1, 7) == "mileage"
end

--- Removes Mileage apps from a layout (the table is modified). Returns the number of
--- removed apps.
function M.cleanLayout(layout)
	if type(layout) ~= "table" or type(layout.apps) ~= "table" then return 0 end
	local hasPlayerList = false
	for _, app in ipairs(layout.apps) do
		if type(app) == "table" and PLAYER_LISTS[app.appName] then hasPlayerList = true end
	end
	local kept, removed = {}, 0
	for _, app in ipairs(layout.apps) do
		local name = type(app) == "table" and app.appName or nil
		if isMileageApp(name) then
			removed = removed + 1
			-- The Mileage list had replaced the BeamMP list: put that back in the same place.
			if name:lower() == "mileageplayerlist" and not hasPlayerList then
				local replacement = {}
				for k, v in pairs(app) do replacement[k] = v end
				replacement.appName = REPLACEMENT_LIST
				replacement.settings = nil
				table.insert(kept, replacement)
				hasPlayerList = true
			end
		else
			table.insert(kept, app)
		end
	end
	if removed > 0 then layout.apps = kept end
	return removed
end

local function layoutFiles()
	local files, seen = {}, {}
	if not FS or type(FS.findFiles) ~= "function" then return files end
	for _, dir in ipairs(LAYOUT_DIRS) do
		local ok, found = pcall(function() return FS:findFiles(dir, "*.uilayout.json", -1, true, false) end)
		if ok and type(found) == "table" then
			for _, path in ipairs(found) do
				local key = tostring(path):gsub("^/", "")
				if not seen[key] then
					seen[key] = true
					table.insert(files, path)
				end
			end
		end
		if #files > 0 then break end
	end
	return files
end

local function notifyLayouts()
	local apps = rawget(_G, "ui_apps")
	if type(apps) == "table" then
		for _, fn in ipairs({"notifyLayoutsChanged", "requestUIAppsData"}) do
			if type(apps[fn]) == "function" then
				pcall(apps[fn])
				return
			end
		end
	end
	if guihooks then guihooks.trigger("UiAppLayoutsChanged") end
end

--- Cleans up all layout files. Returns the number of removed apps.
function M.run()
	local total, files = 0, 0
	for _, path in ipairs(layoutFiles()) do
		local ok, layout = pcall(jsonReadFile, path)
		if ok and type(layout) == "table" then
			local removed = M.cleanLayout(layout)
			if removed > 0 then
				-- Back up only the first time, so the backup stays the original from before SharedCareer.
				if not FS:fileExists(path .. BACKUP_SUFFIX) then
					local original = jsonReadFile(path)
					jsonWriteFile(path .. BACKUP_SUFFIX, original, true)
				end
				local wrote = pcall(jsonWriteFile, path, layout, true)
				if wrote then
					total = total + removed
					files = files + 1
				else
					U.log("E", "cleanup", "could not write " .. tostring(path))
				end
			end
		end
	end
	if total > 0 then
		U.log("I", "cleanup", string.format("removed %d Mileage app(s) from %d layout(s)", total, files))
		U.toast("info", "Removed Mileage leftovers from your UI layouts (" .. total .. ")", 6)
		notifyLayouts()
	end
	return total
end

local function config()
	local core = U.ext("sharedCareer_core")
	return core and core.getConfig()
end

-- After the career start (then the layout files exist and the UI is ready).
function M.onCareerActive(active)
	local cfg = config()
	if not active or done or not cfg or not U.isMP() then return end
	done = true
	local changed = false
	if cfg.cleanupMileageApps ~= false then
		local ok, removed = pcall(M.run)
		if not ok then U.log("E", "cleanup", "cleanup failed: " .. tostring(removed)) end
	end
	local okMove, moved = pcall(M.moveAppsOnce)
	if not okMove then U.log("E", "cleanup", "moving SharedCareer apps failed: " .. tostring(moved))
	elseif moved > 0 then changed = true end
	if cfg.addTimeApp ~= false then
		local ok, added = pcall(M.addAppsOnce)
		if not ok then U.log("E", "cleanup", "SharedCareer apps: " .. tostring(added))
		elseif added > 0 then changed = true end
	end
	if changed then notifyLayouts() end
end

function M.onBeamMPServerLeave()
	done = false
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
