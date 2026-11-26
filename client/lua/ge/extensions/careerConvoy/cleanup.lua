-- Career-Convoy :: the players' UI layouts
--
-- Two jobs on join (after the career start):
--   A) remove Mileage leftovers (client.cleanupMileageApps)
--   B) add the apps "Career-Convoy Menu", "Career-Convoy Phone" and "Career-Convoy Speed Limit" to the
--      career layout ONCE each
--      (client.addApps). Afterwards the mod remembers that in settings/careerConvoy/state.json;
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
--   * before the first change every file is backed up as <file>.careerconvoy-backup
-- Can be switched off with client.cleanupMileageApps = false.

local M = {}

local U

local LAYOUT_DIRS = { "/settings/ui_apps/layouts/", "settings/ui_apps/layouts/" }
local BACKUP_SUFFIX = ".careerconvoy-backup"
local PLAYER_LISTS = { beammpPlayerListVue = true, beammpPlayerListAngular = true }
local REPLACEMENT_LIST = "beammpPlayerListVue"

local done = false

--== B) Career-Convoy apps into the career layout once ===========================
-- Every app is added exactly ONCE (flag in settings/careerConvoy/state.json);
-- players who remove it afterwards don't get it forced on them again.

local CAREER_LAYOUT = "settings/ui_apps/layouts/default/career.uilayout.json"
local CAREER_ORIGINAL = "settings/ui_apps/originalLayouts/default/career.uilayout.json"
local APPS = {
	{
		appName = "careerConvoyMenu",
		stateKey = "menuAppAdded",
		label = "Career-Convoy menu",
		-- right, below the BeamMP player list (which reaches down to about 590 px)
		placement = {
			position = "absolute",
			right = "0px",
			top = "600px",
			width = "345px",
			height = "190px",
			left = "",
			bottom = "",
		},
	},
	{
		appName = "careerConvoyPhone",
		stateKey = "phoneAppAdded",
		label = "Career-Convoy phone",
		-- only the tab, directly below the menu: the phone itself opens on top of the page, so the
		-- app frame never blocks clicks elsewhere. BeamNG's frame around an app catches clicks over
		-- its whole area – apps must never overlap (0.8.0–0.8.3: the steering-wheel tab couldn't be
		-- clicked).
		placement = {
			position = "absolute",
			right = "0px",
			top = "790px",
			width = "30px",
			height = "80px",
			left = "",
			bottom = "",
		},
	},
	{
		appName = "careerConvoySpeedLimit",
		stateKey = "speedLimitAppAdded",
		label = "Career-Convoy speed limit sign",
		-- bottom right, above the game's speedometer, left of the phone tab (never over it)
		placement = {
			position = "absolute",
			right = "40px",
			bottom = "300px",
			width = "100px",
			height = "110px",
			left = "",
			top = "",
		},
	},
}
M.APPS = APPS

--- Adds the Career-Convoy apps to the career layout if that never happened yet. Returns the
--- number of apps added now.
function M.addAppsOnce()
	local state = U.readState()
	local todo = {}
	for _, def in ipairs(APPS) do
		if not state[def.stateKey] then
			table.insert(todo, def)
		end
	end
	if #todo == 0 then
		return 0
	end
	-- The player's own career layout, otherwise the game's original as the base
	local okCustom, custom = pcall(jsonReadFile, CAREER_LAYOUT)
	local layout = okCustom and type(custom) == "table" and custom or nil
	if not layout then
		local okOrig, original = pcall(jsonReadFile, CAREER_ORIGINAL)
		layout = okOrig and type(original) == "table" and original or nil
	end
	if not layout or type(layout.apps) ~= "table" then
		U.log("W", "cleanup", "career layout not found – Career-Convoy apps not added")
		return 0
	end
	local present = {}
	for _, app in ipairs(layout.apps) do
		if type(app) == "table" and app.appName then
			present[app.appName] = true
		end
	end
	local added = {}
	for _, def in ipairs(todo) do
		if present[def.appName] then
			state[def.stateKey] = true -- already there (added by the player): just remember it
		else
			local app = { appName = def.appName, placement = {} }
			for k, v in pairs(def.placement) do
				app.placement[k] = v
			end
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
	U.writeState(state)
	return #added
end
-- One-time corrections of apps that were already placed (each runs once per PC):
--   remove = true   the app no longer exists: take it out of the layout (otherwise BeamNG shows a
--                   red "Unknown app" box)
--   from / to       move it, but only if it is still where the mod put it
local MOVES = {
	-- 0.13.0: the fuel prices are an app on the phone now; the separate fuel window is gone
	{ stateKey = "fuelAppRetired", appName = "sharedCareerFuel", remove = true },
	-- ... and the phone tab takes its place directly below the menu
	{
		stateKey = "phoneTabUp",
		appName = "careerConvoyPhone",
		from = { right = "0px", top = "920px" },
		to = { top = "760px" },
	},
	-- 0.26.0: the menu is taller (the Time tab has the "Clock" row) ...
	{
		stateKey = "menuTaller",
		appName = "careerConvoyMenu",
		from = { right = "0px", top = "600px", height = "160px" },
		to = { height = "190px" },
	},
	-- ... and the phone tab moves down with it, so the two never overlap
	{
		stateKey = "phoneTabBelowTallerMenu",
		appName = "careerConvoyPhone",
		from = { right = "0px", top = "760px" },
		to = { top = "790px" },
	},
}

function M.moveAppsOnce()
	local state = U.readState()
	local todo = {}
	for _, mv in ipairs(MOVES) do
		if not state[mv.stateKey] then
			table.insert(todo, mv)
		end
	end
	if #todo == 0 then
		return 0
	end
	local ok, layout = pcall(jsonReadFile, CAREER_LAYOUT)
	if not ok or type(layout) ~= "table" or type(layout.apps) ~= "table" then
		return 0
	end
	local moved = 0
	for _, mv in ipairs(todo) do
		if mv.remove then
			for i = #layout.apps, 1, -1 do
				local app = layout.apps[i]
				if type(app) == "table" and app.appName == mv.appName then
					table.remove(layout.apps, i)
					moved = moved + 1
				end
			end
		end
		for _, app in ipairs(mv.remove and {} or layout.apps) do
			if type(app) == "table" and app.appName == mv.appName and type(app.placement) == "table" then
				local matches = true
				for k, v in pairs(mv.from) do
					if app.placement[k] ~= v then
						matches = false
					end
				end
				if matches then
					for k, v in pairs(mv.to) do
						app.placement[k] = v
					end
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
	U.writeState(state)
	if moved > 0 then
		U.log("I", "cleanup", "updated " .. moved .. " Career-Convoy app(s) in the career layout")
	end
	return moved
end

--== Renamed apps ================================================================
-- An app whose name changed would show up as a red "Unknown app" box in every layout that still
-- has the old name. Each rename runs once per PC, in all layout files.

local RENAMES = {
	-- 0.15.0: the menu does much more than the time of day
	{ stateKey = "menuAppRenamed", from = "sharedCareerTime", to = "careerConvoyMenu" },
	-- the mod was called SharedCareer before it became Career-Convoy
	{ stateKey = "menuAppRenamedToCareerConvoy", from = "sharedCareerMenu", to = "careerConvoyMenu" },
	{ stateKey = "phoneAppRenamedToCareerConvoy", from = "sharedCareerPhone", to = "careerConvoyPhone" },
	{ stateKey = "speedLimitAppRenamedToCareerConvoy", from = "sharedCareerSpeedLimit", to = "careerConvoySpeedLimit" },
}

--- Renames apps in a layout (the table is modified). Returns the number of changed apps.
function M.renameInLayout(layout, from, to)
	if type(layout) ~= "table" or type(layout.apps) ~= "table" then
		return 0
	end
	local hasNew = false
	for _, app in ipairs(layout.apps) do
		if type(app) == "table" and app.appName == to then
			hasNew = true
		end
	end
	local changed = 0
	for i = #layout.apps, 1, -1 do
		local app = layout.apps[i]
		if type(app) == "table" and app.appName == from then
			if hasNew then
				table.remove(layout.apps, i) -- the new one is already there: don't show it twice
			else
				app.appName = to
				hasNew = true
			end
			changed = changed + 1
		end
	end
	return changed
end

local function isMileageApp(name)
	return type(name) == "string" and name:lower():sub(1, 7) == "mileage"
end

--- Removes Mileage apps from a layout (the table is modified). Returns the number of
--- removed apps.
function M.cleanLayout(layout)
	if type(layout) ~= "table" or type(layout.apps) ~= "table" then
		return 0
	end
	local hasPlayerList = false
	for _, app in ipairs(layout.apps) do
		if type(app) == "table" and PLAYER_LISTS[app.appName] then
			hasPlayerList = true
		end
	end
	local kept, removed = {}, 0
	for _, app in ipairs(layout.apps) do
		local name = type(app) == "table" and app.appName or nil
		if isMileageApp(name) then
			removed = removed + 1
			-- The Mileage list had replaced the BeamMP list: put that back in the same place.
			if name:lower() == "mileageplayerlist" and not hasPlayerList then
				local replacement = {}
				for k, v in pairs(app) do
					replacement[k] = v
				end
				replacement.appName = REPLACEMENT_LIST
				replacement.settings = nil
				table.insert(kept, replacement)
				hasPlayerList = true
			end
		else
			table.insert(kept, app)
		end
	end
	if removed > 0 then
		layout.apps = kept
	end
	return removed
end

local function layoutFiles()
	local files, seen = {}, {}
	if not FS or type(FS.findFiles) ~= "function" then
		return files
	end
	for _, dir in ipairs(LAYOUT_DIRS) do
		local ok, found = pcall(function()
			return FS:findFiles(dir, "*.uilayout.json", -1, true, false)
		end)
		if ok and type(found) == "table" then
			for _, path in ipairs(found) do
				local key = tostring(path):gsub("^/", "")
				if not seen[key] then
					seen[key] = true
					table.insert(files, path)
				end
			end
		end
		if #files > 0 then
			break
		end
	end
	return files
end

function M.renameAppsOnce()
	local state = U.readState()
	local todo = {}
	for _, rn in ipairs(RENAMES) do
		if not state[rn.stateKey] then
			table.insert(todo, rn)
		end
	end
	if #todo == 0 then
		return 0
	end
	local paths, seen = {}, {}
	for _, path in ipairs(layoutFiles()) do
		paths[#paths + 1] = path
		seen[tostring(path):gsub("^/", "")] = true
	end
	if not seen[CAREER_LAYOUT] then
		paths[#paths + 1] = CAREER_LAYOUT
	end
	local total = 0
	for _, path in ipairs(paths) do
		local ok, layout = pcall(jsonReadFile, path)
		if ok and type(layout) == "table" then
			local changed = 0
			for _, rn in ipairs(todo) do
				changed = changed + M.renameInLayout(layout, rn.from, rn.to)
			end
			if changed > 0 then
				if pcall(jsonWriteFile, path, layout, true) then
					total = total + changed
				else
					U.log("E", "cleanup", "could not write " .. tostring(path))
				end
			end
		end
	end
	for _, rn in ipairs(todo) do
		state[rn.stateKey] = true
	end
	U.writeState(state)
	if total > 0 then
		U.log("I", "cleanup", "renamed " .. total .. " Career-Convoy app(s) in the UI layouts")
	end
	return total
end

local function notifyLayouts()
	local apps = rawget(_G, "ui_apps")
	if type(apps) == "table" then
		for _, fn in ipairs({ "notifyLayoutsChanged", "requestUIAppsData" }) do
			if type(apps[fn]) == "function" then
				pcall(apps[fn])
				return
			end
		end
	end
	if guihooks then
		guihooks.trigger("UiAppLayoutsChanged")
	end
end

--- Cleans up all layout files. Returns the number of removed apps.
function M.run()
	local total, files = 0, 0
	for _, path in ipairs(layoutFiles()) do
		local ok, layout = pcall(jsonReadFile, path)
		if ok and type(layout) == "table" then
			local removed = M.cleanLayout(layout)
			if removed > 0 then
				-- Back up only the first time, so the backup stays the original from before Career-Convoy.
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

-- After the career start (then the layout files exist and the UI is ready).
function M.onCareerActive(active)
	local cfg = U.config()
	if not active or done or not cfg or not U.isMP() then
		return
	end
	done = true
	local changed = false
	if cfg.cleanupMileageApps ~= false then
		local ok, removed = pcall(M.run)
		if not ok then
			U.log("E", "cleanup", "cleanup failed: " .. tostring(removed))
		end
	end
	local okRename, renamed = pcall(M.renameAppsOnce)
	if not okRename then
		U.log("E", "cleanup", "renaming Career-Convoy apps failed: " .. tostring(renamed))
	elseif renamed > 0 then
		changed = true
	end
	local okMove, moved = pcall(M.moveAppsOnce)
	if not okMove then
		U.log("E", "cleanup", "moving Career-Convoy apps failed: " .. tostring(moved))
	elseif moved > 0 then
		changed = true
	end
	if cfg.addApps ~= false then
		local ok, added = pcall(M.addAppsOnce)
		if not ok then
			U.log("E", "cleanup", "Career-Convoy apps: " .. tostring(added))
		elseif added > 0 then
			changed = true
		end
	end
	if changed then
		notifyLayouts()
	end
end

function M.onBeamMPServerLeave()
	done = false
end

function M.onExtensionLoaded()
	U = extensions.careerConvoy_util
end

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
