-- Career-Convoy :: licenses: the license office and the licenses you own
--
--   licenses  the license office: a career marker (map, big map); its card opens the license shop
-- (gameplay_rawPois), so it looks and works like the career's own spots: a dot and ring on the
-- ground with a floating icon, an entry on the big map and the minimap, and the game's card with
-- a "Buy licenses" button when you walk in. The button opens the license shop, a dialog of the
-- Career-Convoy menu window (shown by welcome.lua).
-- The server keeps the licenses, their prices and who owns which (main.lua "Licenses"):
--   sc_licensesRequest        -> sc_licenses {list = [{id, name, price, jobType, owned, buying}], message}
--                                (also sent when your career starts)
--   sc_licenseBuy {license}   -> sc_licenseCharge {id, license, name, price}
--   debit the price, save     -> sc_licenseChargeResult {id, ok, reason}
-- has(id): whether you own a license. byJobType(): the licenses jobs need, for the Jobs app (a job
-- type with a license you don't own is greyed out there; the server refuses its jobs).
-- uiRoute(): the route to the license office.

local M = {}

local U

-- the license office per map
local OFFICES = {
	west_coast_usa = { x = -500.092, y = 566.508, z = 93.279 },
}
local POI = "careerConvoyLicenseOffice" -- id and type of the point of interest
local ICON = "poi_entrance_round" -- marker and big map pin (the game's icon atlas)
local LIST_ICON = "doorIn" -- big map list (the UI's icon font, other names than the atlas)
local NAME = "License Office"
local SHOP = "licenses" -- the dialog's kind

local list = nil -- the shop from the server (sc_licenses), nil until it arrived
local charged = {} -- purchase id -> true: a charge that arrives twice is only confirmed

local function welcome()
	return U.ext("careerConvoy_welcome")
end

--- Whether you own a license (id, e.g. "towing").
function M.has(id)
	for _, l in ipairs(list or {}) do
		if l.id == id then
			return l.owned == true
		end
	end
	return false
end

--- The licenses jobs need, by job type: {[jobType] = {name, owned}}; empty until the server sent them.
function M.byJobType()
	local out = {}
	for _, l in ipairs(list or {}) do
		if type(l.jobType) == "string" then
			out[l.jobType] = { name = l.name, owned = l.owned == true }
		end
	end
	return out
end

--- From the Jobs app: the route to the license office of this map.
function M.uiRoute()
	local level = type(getCurrentLevelIdentifier) == "function" and getCurrentLevelIdentifier() or nil
	local p = level and OFFICES[level]
	if p then
		U.setRoute("licenses", p)
	end
end

--== The shop ======================================================================

local function money(n)
	local s = tostring(math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return "$" .. s:gsub("^,", "")
end

--- The shop as a dialog of the menu window.
function M.shopDialog()
	local items = {}
	local cash = U.money()
	for _, l in ipairs(list or {}) do
		local item = { head = l.name }
		if l.owned then
			item.text, item.owned = "Owned", true
		elseif l.buying then
			item.text = "Buying…"
		else
			item.text, item.buy = money(l.price), l.id
			item.disabled = cash ~= nil and cash < l.price
		end
		table.insert(items, item)
	end
	return {
		kind = SHOP,
		title = NAME,
		intro = list == nil and "Loading…" or nil,
		items = items,
		buttons = { { label = "Close", action = "ok", primary = true } },
	}
end

local function showShop()
	local w = welcome()
	if w then
		w.open(M.shopDialog())
	end
end

function M.openShop()
	U.send("sc_licensesRequest", {})
	showShop()
end

--- From the window: "Buy" next to a license.
function M.uiBuy(id)
	if type(id) == "string" then
		U.send("sc_licenseBuy", { license = id })
	end
end

local function rxLicenses(data)
	local msg = U.decode(data)
	if not msg or type(msg.list) ~= "table" then
		return
	end
	list = msg.list
	local jobs = U.ext("careerConvoy_jobs")
	if jobs then
		jobs.refreshApp()
	end
	local w = welcome()
	if w and w.isOpen(SHOP) then
		showShop()
	end
	if type(msg.message) == "string" then
		U.toast("warning", msg.message)
	end
end

-- The server asks to pay for a license (like money.lua's debit).
local function rxCharge(data)
	local msg = U.decode(data)
	if not msg or type(msg.id) ~= "string" then
		return
	end
	if charged[msg.id] then
		U.send("sc_licenseChargeResult", { id = msg.id, ok = true })
		return
	end
	local price, cash = tonumber(msg.price), U.money()
	local reason = nil
	if not price or price < 0 then
		reason = "Invalid price."
	elseif not U.careerActive() or not cash then
		reason = "Your career is not running."
	elseif cash < price then
		reason = "Not enough money."
	end
	if reason then
		U.send("sc_licenseChargeResult", { id = msg.id, ok = false, reason = reason })
		return
	end
	career_modules_playerAttributes.addAttributes(
		{ money = -price },
		{ tags = { "gameplay" }, label = tostring(msg.name or "License") }
	)
	charged[msg.id] = true
	U.saveCareer("licenses")
	U.send("sc_licenseChargeResult", { id = msg.id, ok = true })
end

--== The marker ====================================================================

-- The game caches its points of interest; clearing makes it ask again (shows or hides ours).
local function refreshPois()
	local pois = rawget(_G, "gameplay_rawPois")
	if pois and type(pois.clear) == "function" then
		pois.clear()
	end
end

-- The game collects the points of interest of a map (markers, big map, minimap).
function M.onGetRawPoiListForLevel(level, elements)
	local p = OFFICES[level]
	if not p or not U.isMP() or not U.careerActive() then
		return
	end
	local pos = vec3(p.x, p.y, p.z)
	table.insert(elements, {
		id = POI,
		clusterType = "missionMarker",
		data = { type = POI, id = POI, date = 0 },
		markerInfo = {
			missionMarker = { pos = pos, rot = quat(0, 0, 0, 1), icon = ICON },
			bigmapMarker = {
				pos = pos,
				icon = ICON,
				cardIcon = LIST_ICON,
				name = NAME,
				description = "Buy licenses here.",
				previews = {},
			},
		},
	})
end

-- You stand in the marker: the game's card with a button.
function M.onActivityAcceptGatherData(elemData, activityData)
	for _, elem in ipairs(elemData) do
		if elem.type == POI then
			table.insert(activityData, {
				icon = ICON,
				heading = NAME,
				preheadings = { "Licenses" },
				sorting = { type = POI, id = POI },
				buttonLabel = "Buy licenses",
				buttonFun = M.openShop,
			})
		end
	end
end

--== Lifecycle =====================================================================

function M.onCareerActive()
	refreshPois()
end

function M.onBeamMPServerLeave()
	list = nil
	refreshPois()
end

function M.onExtensionLoaded()
	U = extensions.careerConvoy_util
	U.on("sc_licenses", rxLicenses)
	U.on("sc_licenseCharge", rxCharge)
end

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
