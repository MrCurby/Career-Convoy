-- SharedCareer :: licenses: the license office and the licenses you own
--
-- At the license office (OFFICES: a point per map) a circle lies on the ground. Walk into it and a
-- hint says to press F (KEY, rebindable under Options → Controls → BeamMP); F opens the license
-- shop, a dialog of the SharedCareer menu window (shown by welcome.lua).
-- The server keeps the licenses, their prices and who owns which (main.lua "Licenses"):
--   sc_licensesRequest        -> sc_licenses {list = [{id, name, price, owned, buying}], message}
--   sc_licenseBuy {license}   -> sc_licenseCharge {id, license, name, price}
--   debit the price, save     -> sc_licenseChargeResult {id, ok, reason}
-- has(id): whether you own a license (for features that need one).

local M = {}

local U

-- the license office per map: where the circle lies
local OFFICES = {
	west_coast_usa = { x = -500.092, y = 566.508, z = 93.279 },
}
local RADIUS = 2 -- m: the circle
local DRAW_RANGE = 80 -- m: the circle is drawn this close
local KEY_ACTION = "sharedCareerLicenses"
local KEY = "f"
local SHOP = "licenses" -- the dialog's kind

local list = nil -- the shop from the server (sc_licenses), nil until it arrived
local inside = false
local keyRegistered = false
local charged = {} -- purchase id -> true: a charge that arrives twice is only confirmed

local function office()
	local level = type(getCurrentLevelIdentifier) == "function" and getCurrentLevelIdentifier() or nil
	return level and OFFICES[level] or nil
end

local function walking()
	local walk = rawget(_G, "gameplay_walk")
	return walk ~= nil and type(walk.isWalking) == "function" and walk.isWalking() == true
end

local function welcome()
	return U.ext("sharedCareer_welcome")
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
		title = "License Office",
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

--== The circle ====================================================================

local function draw(p)
	if not (debugDrawer and ColorF and vec3) then
		return
	end
	local r, g, b = 1, 0.6, 0.1
	if inside then
		r, g, b = 0.3, 0.9, 0.45
	end
	debugDrawer:drawCylinder(vec3(p.x, p.y, p.z + 0.02), vec3(p.x, p.y, p.z + 0.08), RADIUS, ColorF(r, g, b, 0.25))
	local label = "License Office"
	debugDrawer:drawTextAdvanced(
		vec3(p.x, p.y, p.z + 2.2),
		String and String(label) or label,
		ColorF(1, 1, 1, 1),
		true,
		false,
		ColorI(20, 20, 24, 190)
	)
end

function M.onUpdate()
	if not U.isMP() or not U.careerActive() then
		inside = false
		return
	end
	local p, me = office(), U.myPosition()
	if not p or not me then
		inside = false
		return
	end
	local dx, dy = me.x - p.x, me.y - p.y
	local d = math.sqrt(dx * dx + dy * dy)
	local now = walking() and d <= RADIUS and math.abs(me.z - p.z) < 3
	if now and not inside then
		U.toast("info", "Press F to buy licenses")
	end
	inside = now
	if d <= DRAW_RANGE then
		draw(p)
	end
end

--== Key ===========================================================================

local function registerKey()
	if keyRegistered then
		return
	end
	keyRegistered = true
	U.addKey("licenses", KEY_ACTION, {
		title = "SharedCareer: license office",
		desc = "Opens the license shop at the license office",
		default = KEY,
		onDown = function()
			if inside then
				M.openShop()
			end
		end,
	})
end

function M.onCareerActive(active)
	if active and U.isMP() and U.config() then
		registerKey()
	end
end

function M.onBeamMPServerLeave()
	list, inside, keyRegistered = nil, false, false
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	U.on("sc_licenses", rxLicenses)
	U.on("sc_licenseCharge", rxCharge)
end

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
