-- Career-Convoy :: replays the timeline from tests/ui_test.js (random clicks on the real menu and
-- phone windows) against the real menu.lua and checks at every moment that the state is sent
-- exactly while something shows it, with fuel prices whenever the Fuel app is open.
--
-- Run: luajit tests/ui_replay.lua <timeline.json>   (tools/test.sh does it)
local FILE = arg[1]
local ROOT = (arg[0]:match("^(.*)/tests/[^/]*$")) or "."
local shownSince
package.path = ROOT .. "/tests/?.lua;" .. package.path
local json = require("json")
local f = assert(io.open(FILE))
local steps = json.decode(f:read("*a"))
f:close()
_G.log = function() end
_G.jsonEncode, _G.jsonDecode = json.encode, json.decode
_G.setExtensionUnloadMode = function() end
local pushes = {}
local clock = 0
_G.guihooks = {
	trigger = function(name, data)
		if name == "CareerConvoyState" then
			table.insert(pushes, { t = clock, fuel = data.fuel })
		end
	end,
}
_G.extensions = {}
_G.MPCoreNetwork = {
	isMPSession = function()
		return true
	end,
}
local U = dofile(ROOT .. "/client/lua/ge/extensions/careerConvoy/util.lua")
extensions.careerConvoy_util = U
local menu = dofile(ROOT .. "/client/lua/ge/extensions/careerConvoy/menu.lua")
menu.onExtensionLoaded()
_G.careerConvoy_menu = menu
local fuelCalls = 0
extensions.careerConvoy_fuel = {
	overview = function()
		fuelCalls = fuelCalls + 1
		return { stations = {} }
	end,
}
local DT = 0.05
local failed, passed = 0, 0
local function check(ok, msg)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		print("FAILED: " .. msg)
	end
end
local worstGap, silentPush, wrongFuel, staleView = 0, 0, 0, 0
local shown = steps[1].screen
local lastPush = 0
local function anyShown(s)
	return s.menu or s.phone
end
for i, step in ipairs(steps) do
	while clock + DT <= step.t + 1e-9 do
		clock = clock + DT
		local n = #pushes
		menu.onUpdate(DT)
		if #pushes > n then
			if not anyShown(shown) then
				silentPush = silentPush + 1
			end
			lastPush = clock
		elseif anyShown(shown) then
			-- something is on screen: never more than about a second without fresh state
			worstGap = math.max(worstGap, clock - math.max(lastPush, shownSince or 0))
		end
	end
	local before = #pushes
	for _, c in ipairs(step.calls) do
		if c:find("careerConvoy_menu") then
			assert(loadstring(c))()
		end
	end
	local was = shown
	shown = step.screen
	if anyShown(shown) and not anyShown(was) then
		shownSince = clock
	end
	if #pushes > before then
		lastPush = clock
	end
	-- a view that just appeared must have its data at once
	if (shown.menu and not was.menu) or (shown.phone and not was.phone) or (shown.fuel and not was.fuel) then
		if #pushes == before and not (anyShown(was) and (not shown.fuel or was.fuel)) then
			print(string.format("  no state at once at t=%.1f", clock))
			staleView = staleView + 1
		end
		if shown.fuel and not was.fuel and (#pushes == before or type(pushes[#pushes].fuel) ~= "table") then
			print(string.format("  Fuel app opened without prices at t=%.1f", clock))
			wrongFuel = wrongFuel + 1
		end
	end
	if #pushes > 0 and pushes[#pushes].t == clock then
		local p = pushes[#pushes]
		if shown.fuel and type(p.fuel) ~= "table" then
			wrongFuel = wrongFuel + 1
		end
	end
	-- Lua's view must never be "hidden" while it is on screen
	for _, v in ipairs({ "menu", "phone", "fuel" }) do
		if shown[v] and not menu.isVisible(v) then
			staleView = staleView + 1
			print("  " .. v .. " shown but not visible in Lua at t=" .. clock)
		end
	end
end
check(staleView == 0, "every view on screen is known in Lua at every moment (" .. staleView .. " misses)")
check(
	worstGap <= 1.1,
	string.format("something on screen: fresh state at least every second (worst gap %.2f s)", worstGap)
)
check(silentPush == 0, "nothing on screen: no state sent (" .. silentPush .. " pushes)")
check(wrongFuel == 0, "Fuel app on screen: every push carries prices (" .. wrongFuel .. " misses)")
print(
	string.format(
		"UI replay: %d ok, %d failed (%.0f s of clicks, %d pushes, %d fuel lists)",
		passed,
		failed,
		clock,
		#pushes,
		fuelCalls
	)
)
os.exit(failed == 0 and 0 or 1)
