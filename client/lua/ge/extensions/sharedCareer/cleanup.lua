-- SharedCareer :: UI-Layouts der Spieler
--
-- Zwei Aufgaben beim Join (nach dem Karrierestart):
--   A) Mileage-Reste entfernen (client.cleanupMileageApps)
--   B) Die Apps "SharedCareer Menu" und "SharedCareer Fuel" je EINMAL ins Karriere-Layout setzen
--      (client.addTimeApp). Danach merkt sich der Mod das in settings/sharedCareer/state.json;
--      wer eine App entfernt, bekommt sie nicht wieder aufgedrängt.
--
-- A) Mileage-Reste:
-- Mileage schreibt seine Apps (mileageplayerlist, mileageoffers, mileagerace) direkt in die
-- UI-Layouts des Spielers (settings/ui_apps/layouts/**.uilayout.json im Benutzerordner) und
-- ersetzt dabei die BeamMP-Spielerliste durch seine eigene. Ohne Mileage bleiben davon rote
-- "Unknown app"-Kästen übrig – auch im Einzelspieler, weil es die eigenen Layouts sind.
--
-- Diese Erweiterung räumt das einmal pro Server-Besuch auf:
--   * Apps, deren Name mit "mileage" beginnt, werden aus den Layouts entfernt
--   * an die Stelle der Mileage-Spielerliste kommt wieder BeamMPs eigene Liste
--     (beammpPlayerListVue), falls das Layout noch keine hat
--   * alles andere (eigene Anordnung, andere Mods, BeamMP-Chat …) bleibt unverändert
--   * vor der ersten Änderung wird jede Datei als <datei>.sharedcareer-backup gesichert
-- Abschaltbar mit client.cleanupMileageApps = false.

local M = {}

local U

local LAYOUT_DIRS = {"/settings/ui_apps/layouts/", "settings/ui_apps/layouts/"}
local BACKUP_SUFFIX = ".sharedcareer-backup"
local PLAYER_LISTS = {beammpPlayerListVue = true, beammpPlayerListAngular = true}
local REPLACEMENT_LIST = "beammpPlayerListVue"

local done = false

--== B) SharedCareer-Apps einmalig ins Karriere-Layout ==========================
-- Jede App wird genau EINMAL hinzugefügt (Merker in settings/sharedCareer/state.json);
-- wer sie danach entfernt, bekommt sie nicht wieder aufgedrängt.

local STATE_FILE = "settings/sharedCareer/state.json"
local CAREER_LAYOUT = "settings/ui_apps/layouts/default/career.uilayout.json"
local CAREER_ORIGINAL = "settings/ui_apps/originalLayouts/default/career.uilayout.json"
local APPS = {
	{
		appName = "sharedCareerTime", stateKey = "timeAppAdded", label = "SharedCareer menu",
		-- rechts, unter der BeamMP-Spielerliste (die reicht bis ca. 590 px)
		placement = {position = "absolute", right = "0px", top = "600px", width = "345px", height = "160px",
			left = "", bottom = ""},
	},
	{
		appName = "sharedCareerFuel", stateKey = "fuelAppAdded", label = "SharedCareer fuel prices",
		-- direkt unter dem Menü am rechten Rand, OHNE Überlappung: BeamNGs Rahmen um eine App
		-- fängt Klicks auf seiner ganzen Fläche ab. Lagen beide Apps übereinander (0.8.0–0.8.3),
		-- ließ sich die Lenkrad-Lasche des Menüs nicht mehr anklicken.
		placement = {position = "absolute", right = "0px", top = "760px", width = "345px", height = "160px",
			left = "", bottom = ""},
	},
}
M.APPS = APPS

local function readState()
	local ok, state = pcall(jsonReadFile, STATE_FILE)
	return (ok and type(state) == "table") and state or {}
end

--- Setzt die SharedCareer-Apps ins Karriere-Layout, soweit noch nie geschehen. Gibt die Anzahl
--- jetzt hinzugefügter Apps zurück.
function M.addAppsOnce()
	local state = readState()
	local todo = {}
	for _, def in ipairs(APPS) do
		if not state[def.stateKey] then table.insert(todo, def) end
	end
	if #todo == 0 then return 0 end
	-- Eigenes Karriere-Layout des Spielers, sonst das Original des Spiels als Grundlage
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
			state[def.stateKey] = true -- schon da (selbst hinzugefügt): nur merken
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
-- Einmalige Korrekturen an schon gesetzten Apps: 0.7.2 stellte die Fuel-App 350 px links
-- neben das Menü – eingeklappt schwebte ihre Lasche mitten im Bild. Jetzt an den Rand.
local MOVES = {
	{stateKey = "fuelAppAtEdge", appName = "sharedCareerFuel", from = {right = "350px"}, to = {right = "0px", top = "600px"}},
	-- 0.8.0–0.8.3: Fuel-App genau über dem Menü -> verdeckte die Lenkrad-Lasche. Darunter setzen.
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

-- alter Name (Tests, ältere Aufrufe)
M.addTimeAppOnce = function() return M.addAppsOnce() > 0 end

local function isMileageApp(name)
	return type(name) == "string" and name:lower():sub(1, 7) == "mileage"
end

--- Entfernt Mileage-Apps aus einem Layout (Tabelle wird verändert). Gibt die Anzahl
--- entfernter Apps zurück.
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
			-- Die Mileage-Liste hatte die BeamMP-Liste ersetzt: diese an derselben Stelle zurück.
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

--- Räumt alle Layout-Dateien auf. Gibt die Anzahl entfernter Apps zurück.
function M.run()
	local total, files = 0, 0
	for _, path in ipairs(layoutFiles()) do
		local ok, layout = pcall(jsonReadFile, path)
		if ok and type(layout) == "table" then
			local removed = M.cleanLayout(layout)
			if removed > 0 then
				-- Sicherung nur beim ersten Mal, damit sie das Original von vor SharedCareer bleibt.
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

-- Nach dem Karrierestart (dann sind die Layout-Dateien da und die Oberfläche bereit).
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
