-- SharedCareer :: jobs (beta): the shared job list and the Jobs app, for every kind of job
--
-- The server keeps one list of jobs for everyone (server.jobs, see main.lua "Jobs"). This file is
-- what all jobs have in common. What a job is about comes from its job type, an extension that
-- registers itself here (registerType) – towJobs.lua (towing jobs) is the first one. A job type:
--   id               short name, sent with every job ("tow")
--   name             its name in the Jobs app ("Towing") and in the money history ("Towing job: <title>")
--   icon             the icon of its jobs in the Jobs app (a name the app knows, e.g. "tow")
--   branch           optional: the career branch whose XP a job also gives ("labourer"), next to
--                    the game's BeamXP – only if the career has that attribute
--   steps            the steps of a job in the Jobs app, e.g. {"Pick up", "Tow", "Paid"}; the last
--                    one is reached when the pay arrives
--   generate(tier)   makes up a job of this tier (1 easy .. 4 hard, see main.lua "Job levels") on
--                    this map: {title, pos, dest = {name, pos}, length, pay, data} (pos: where it
--                    starts; pay: at level 1; data: the type's own fields, the server passes them
--                    on), or nil and why not
--   tags(job)        short labels for the job in the app: {{text, kind}} (kind picks the color)
--   start(a)         the job is yours: a = {id, job}; the type keeps its own state in a
--   step(a, dt)      every CHECK_EVERY s until it is handed over; calls M.handOver(a, share) when
--                    the job is done (share: how much of the pay was earned, 0..1 – less after
--                    damage, for example; the server turns it into money and XP)
--   status(a)        {step (0-based index into steps), text (Jobs app), short (the job strip),
--                    target (pos: the route and the distance in the app), from (pos the distance
--                    is measured from; default: you), hint (optional), inZone (optional)}
--   stop(a)          the job ends here (paid, given up, taken away, no answer): clean up
--   draw(a)          optional, every frame: markers in the world
--   vehicleReset(a, id)  optional: a vehicle was reset (R)
-- (Not named like the game's hooks – onUpdate, onVehicleResetted, ... – the game calls those on
-- every extension.)
--
-- Common to all jobs:
--   making one up  when jobs are missing, the server asks one player for a job of a tier
--                  (sc_jobGenerate {type, tier}); this client asks that job type (without one: its
--                  job types in turn) and sends the job (sc_jobOffer)
--   levels         every player has a level per job type; the server keeps it and decides (main.lua
--                  "Job levels"): which tiers you can take, your pay, the XP. The Jobs app has a
--                  section per job type with your level in it and its jobs by level, the ones you
--                  can't take yet at the bottom.
--                  The last levels the server sent are kept in the career save (LEVELS_FILE), to
--                  show them before the server's list has arrived
--   taking         sc_jobTake, the server gives it to the first one; then the type's start() and
--                  the route to its status target (updated whenever the target changes)
--   giving up      sc_jobGiveUp; a job the server takes away (out of time, switched off) ends too
--   handing over   handOver -> sc_jobDone with the share; without the server's answer within
--                  PAID_WAIT s the job ends here (a pay the server did book still arrives later)
--   the pay        sc_jobPaid: credited to the career (playerAttributes), the career is saved and
--                  the server gets sc_jobPaidAck; until then it sends the pay again (also after a
--                  crash or reconnect, see main.lua "Payouts"). Each payout is credited once, with
--                  the job's XP also as the game's BeamXP (and branch XP). The type's stop()
--                  follows REMOVE_AFTER s later
--
-- Settings: server.jobs (on/off, also the Jobs app), server.jobsOpen, server.jobTimeoutMinutes,
-- server.jobPayMax (server); client.jobPay (factor on the pay, payFactor).

local M = {}

local U

local PAID_WAIT = 15          -- s for the server's answer to sc_jobDone; then the job ends here
local REMOVE_AFTER = 6        -- s after paying, the job ends (the type's stop())
local CHECK_EVERY = 0.25      -- s between two checks of the job
local PUSH_EVERY = 1          -- s between two app updates while the phone is out
local LEVELS_FILE = "/career/sharedCareerJobLevels.json" -- in the career save: a copy of your levels

local types = {}              -- id -> job type
local typeOrder = {}          -- ids, in the order they registered
local nextType = 1            -- the job type asked first when making up the next job
local list = {}               -- jobs from the server (sc_jobs)
local levels = {}             -- your levels from the server: type -> {level, xp, from, to}
local enabled = false
local active = nil            -- your job: {id, job, type, doneSent, doneAt, paidAt, route}
                              -- and the type's own fields
-- payout ids already credited: a payout the server sends again is only confirmed. Kept when leaving
-- the server, so a payout sent again after a reconnect isn't credited twice.
local creditedPayouts = {}
local clock = 0
local sinceCheck, sincePush = 0, 0
local pushApp                 -- defined with the app below

--== Helpers for the job types ====================================================

--- {x, y, z} of a vec3 or table, or nil.
function M.vecOf(v)
	if v == nil then return nil end
	local ok, x, y, z = pcall(function() return v.x, v.y, v.z end)
	if not ok or not tonumber(x) then return nil end
	return {x = tonumber(x), y = tonumber(y) or 0, z = tonumber(z) or 0}
end
local vecOf = M.vecOf

function M.dist2D(a, b)
	local dx, dy = a.x - b.x, a.y - b.y
	return math.sqrt(dx * dx + dy * dy)
end
local dist2D = M.dist2D

--- Where you are: your vehicle, or the camera.
function M.myPosition()
	local veh = type(getPlayerVehicle) == "function" and getPlayerVehicle(0) or nil
	if veh then
		local ok, p = pcall(function() return veh:getPosition() end)
		if ok and p then return vecOf(p) end
	end
	if core_camera and type(core_camera.getPosition) == "function" then
		local ok, p = pcall(core_camera.getPosition)
		if ok and p then return vecOf(p) end
	end
	return nil
end
local myPosition = M.myPosition

--- client.jobPay: the server's factor on every pay (0..10, default 1).
function M.payFactor()
	local c = U.config()
	local f = c and tonumber(c.jobPay)
	if not f or f < 0 then return 1 end
	return math.min(f, 10)
end

function M.sendToVehicle(id, cmd)
	local veh = id and be:getObjectByID(id)
	if veh and type(veh.queueLuaCommand) == "function" then
		veh:queueLuaCommand("if sharedCareerVeh then " .. cmd .. " end")
	end
end

local function serverAllows()
	local c = U.config()
	return c ~= nil and type(c.ui) == "table" and c.ui.jobs == true
end

local function navigate(pos)
	if pos then U.setRoute("jobs", pos) else U.clearRoute("jobs") end
end

--== Job types =====================================================================

--- A job type registers itself (see the top of this file for what it brings).
function M.registerType(t)
	if type(t) ~= "table" or type(t.id) ~= "string" then return end
	if not types[t.id] then table.insert(typeOrder, t.id) end
	types[t.id] = t
end

-- The job type's status of your job.
local function statusOf(a)
	local ok, s = pcall(a.type.status, a)
	if ok and type(s) == "table" then return s end
	return {step = 0, text = "", short = ""}
end

--== Making up a job ===============================================================

--- Makes up a new job of a tier (default 1): by that job type, or without one by the job types in
--- turn (the first job wins). Returns the job (with its type and tier) or nil and why not.
function M.generate(tier, kind)
	tier = math.max(1, math.floor(tonumber(tier) or 1))
	local order = typeOrder
	if kind ~= nil then order = types[kind] and {kind} or {} end
	local why = kind and ("unknown job type " .. tostring(kind)) or "no job types"
	for i = 0, #order - 1 do
		local id = kind or order[(nextType - 1 + i) % #order + 1]
		local ok, job, err = pcall(types[id].generate, tier)
		if ok and type(job) == "table" then
			if not kind then nextType = nextType % #typeOrder + 1 end
			job.type, job.tier = id, tier
			return job
		end
		why = id .. ": " .. tostring(ok and err or job)
	end
	return nil, why
end

--== Your job ======================================================================

-- The job ends here: the type cleans up, no route.
local function endActive()
	if not active then return end
	local a = active
	active = nil
	pcall(a.type.stop, a)
	navigate(nil)
end

local function startActive(job)
	local t = types[job.type]
	if not t then
		U.log("W", "jobs", "job " .. tostring(job.id) .. " has an unknown type: " .. tostring(job.type))
		return
	end
	active = {id = job.id, job = job, type = t}
	local ok, err = pcall(t.start, active)
	if not ok then U.log("E", "jobs", "job start failed: " .. tostring(err)) end
	active.route = statusOf(active).target
	navigate(active.route)
end

--- The job type: the job is done, and this share of the pay was earned (0..1). Sends it to the
--- server once; the server works out your pay (with your level bonus) and the XP.
function M.handOver(a, share)
	if a ~= active or a.doneSent then return end
	a.doneSent, a.doneAt = true, clock
	U.send("sc_jobDone", {id = a.id, share = math.max(0, math.min(1, tonumber(share) or 1))})
end

-- One check of your job (every CHECK_EVERY s).
function M.step(dt)
	if not active then return end
	if active.paidAt then
		if clock - active.paidAt >= REMOVE_AFTER then
			endActive()
			pushApp()
		end
		return
	end
	if active.doneSent and clock - active.doneAt >= PAID_WAIT then
		U.log("W", "jobs", "no answer from the server to job " .. tostring(active.id) .. " – ended here")
		U.toast("warning", "No answer from the server – job ended", 6)
		endActive()
		pushApp()
		return
	end
	if not active.doneSent then active.type.step(active, dt) end
	-- the route follows the type's target
	local target = active and not active.paidAt and statusOf(active).target
	if active and target ~= active.route then
		active.route = target
		navigate(target)
	end
end

--== Messages from the server ======================================================

local function mineIn(jobs)
	for _, job in ipairs(jobs) do
		if job.state == "mine" then return job end
	end
end

local function rxJobs(data)
	local msg = U.decode(data)
	if not msg then return end
	enabled = msg.enabled == true
	list = type(msg.jobs) == "table" and msg.jobs or {}
	if type(msg.levels) == "table" then levels = msg.levels end
	local mine = mineIn(list)
	if active and not active.doneSent and (not mine or mine.id ~= active.id) then
		-- taken away (out of time, switched off, given up elsewhere)
		endActive()
	end
	if mine and not active then startActive(mine) end
	M.registerApp()
	pushApp()
end

local function rxGenerate(data)
	if not enabled or not U.careerActive() then return end
	local msg = U.decode(data) or {}
	local job, why = M.generate(msg.tier, type(msg.type) == "string" and msg.type or nil)
	if job then
		U.send("sc_jobOffer", job)
	else
		U.log("W", "jobs", "could not make up a job: " .. tostring(why))
	end
end

-- A payout for a finished job: {payout, job, type, title, pay, deduction, xp}. Credited and saved,
-- then confirmed (sc_jobPaidAck); without the confirmation the server sends it again (also after a
-- reconnect). The XP also go to the career: BeamXP and the job type's branch, if the career has them.
local function rxPaid(data)
	local msg = U.decode(data)
	local pay = msg and tonumber(msg.pay)
	if not msg or type(msg.payout) ~= "string" or not pay or pay < 0 then return end
	if creditedPayouts[msg.payout] then
		U.send("sc_jobPaidAck", {payout = msg.payout})
		return
	end
	local attributes = rawget(_G, "career_modules_playerAttributes")
	if not U.careerActive() or not attributes or type(attributes.addAttributes) ~= "function" then return end
	local mine = active ~= nil and active.id == msg.job
	local t = types[msg.type]
	local label = (t and (t.name .. " job") or "Job") .. ": " .. (type(msg.title) == "string" and msg.title or "?")
	local xp = math.max(0, math.floor(tonumber(msg.xp) or 0))
	local change = {money = pay}
	local function has(key)
		local ok, value = pcall(function() return type(attributes.getAttribute) == "function" and attributes.getAttribute(key) end)
		return ok and value ~= nil and value ~= false
	end
	if xp > 0 then
		if has("beamXP") then change.beamXP = xp end
		if t and type(t.branch) == "string" and has(t.branch) then change[t.branch] = xp end
	end
	if pay > 0 or xp > 0 then
		local ok, err = pcall(attributes.addAttributes, change, {tags = {"gameplay"}, label = label})
		if not ok then
			U.log("E", "jobs", "could not credit the pay of job " .. tostring(msg.job) .. ": " .. tostring(err))
			return
		end
		U.saveCareer("jobs")
	end
	creditedPayouts[msg.payout] = true
	U.send("sc_jobPaidAck", {payout = msg.payout})
	local deduction = math.max(0, math.floor(tonumber(msg.deduction) or 0))
	U.toast("success", string.format("Job done: +$%d", pay)
		.. (deduction > 0 and string.format(" (−$%d damage)", deduction) or "")
		.. (xp > 0 and string.format(" · +%d XP", xp) or ""), 8)
	if mine then
		active.paidAt = clock
		active.route = nil
		navigate(nil)
	end
	pushApp()
end

--== Jobs app (phone) ============================================================

local appOpen = false

local function tagsOf(job)
	local t = types[job.type]
	local ok, tags = pcall(function() return t and t.tags and t.tags(job) end)
	return ok and type(tags) == "table" and tags or {}
end

-- Your level in a job type for the app: {level, share (0..1 of the way to the next level), toGo
-- (XP to the next level; nil at the top)}, or nil before the server has sent it.
local function levelForApp(id)
	local lv = levels[id]
	if type(lv) ~= "table" or not tonumber(lv.level) then return nil end
	local xp, from, to = tonumber(lv.xp) or 0, tonumber(lv.from) or 0, tonumber(lv.to)
	return {level = math.floor(lv.level), share = to and to > from and math.max(0, math.min(1, (xp - from) / (to - from))) or 1,
		toGo = to and math.max(0, math.ceil(to - xp)) or nil}
end

-- One job of the list, for the app.
local function jobForApp(job, me)
	local t = types[job.type]
	return {id = job.id, icon = t and t.icon or "?", title = job.title or "?", tags = tagsOf(job),
		dest = job.dest and job.dest.name or "?", length = job.length, pay = job.pay, state = job.state,
		takenBy = job.takenBy, locked = job.locked == true, minLevel = math.max(1, math.floor(tonumber(job.minLevel) or 1)),
		distance = me and job.pos and dist2D(me, job.pos) or nil}
end

-- A job type's jobs in groups by the level they need: the ones you can take first, the hardest at
-- the top; the ones you can't take yet at the bottom, the nearest level first.
local function levelGroups(jobs)
	local byLevel, groups = {}, {}
	for _, j in ipairs(jobs) do
		local key = j.minLevel .. (j.locked and "L" or "")
		if not byLevel[key] then
			byLevel[key] = {minLevel = j.minLevel, locked = j.locked, open = 0, jobs = {}}
			table.insert(groups, byLevel[key])
		end
		table.insert(byLevel[key].jobs, j)
		if j.state == "open" then byLevel[key].open = byLevel[key].open + 1 end
	end
	for _, g in ipairs(groups) do
		table.sort(g.jobs, function(a, b)
			if (a.state == "open") ~= (b.state == "open") then return a.state == "open" end
			return (a.distance or 1e12) < (b.distance or 1e12)
		end)
	end
	table.sort(groups, function(a, b)
		if a.locked ~= b.locked then return not a.locked end
		if a.locked then return a.minLevel < b.minLevel end
		return a.minLevel > b.minLevel
	end)
	return groups
end

--- State for the Jobs app: a section per job type (in the order they registered; job types this
--- client doesn't know last) with your level in it and its jobs in groups by level (levelGroups).
--- Your own job is not in the list, it has its own card.
function M.appState()
	local me = myPosition()
	local byType, order = {}, {}
	local function section(id)
		if not byType[id] then
			local t = types[id]
			byType[id] = {type = id, name = t and t.name or id, icon = t and t.icon or "?", level = levelForApp(id), jobs = {}}
			table.insert(order, id)
		end
		return byType[id]
	end
	for _, id in ipairs(typeOrder) do
		if levels[id] then section(id) end
	end
	for _, job in ipairs(list) do
		if job.state ~= "mine" and type(job.type) == "string" then table.insert(section(job.type).jobs, jobForApp(job, me)) end
	end
	local rank = {}
	for i, id in ipairs(typeOrder) do rank[id] = i end
	table.sort(order, function(a, b)
		if (rank[a] ~= nil) ~= (rank[b] ~= nil) then return rank[a] ~= nil end
		if rank[a] then return rank[a] < rank[b] end
		return a < b
	end)
	local sections, open = {}, 0
	for _, id in ipairs(order) do
		local sec = byType[id]
		sec.groups, sec.open = levelGroups(sec.jobs), 0
		sec.jobs = nil
		for _, g in ipairs(sec.groups) do
			if not g.locked then sec.open = sec.open + g.open end
		end
		open = open + sec.open
		table.insert(sections, sec)
	end
	local state = {enabled = enabled and serverAllows(), sections = sections, open = open}
	if active then
		local job, s = active.job, statusOf(active)
		local steps = active.type.steps or {}
		local from = s.from or me
		state.active = {id = job.id, icon = active.type.icon, title = job.title, tags = tagsOf(job), dest = job.dest.name,
			pay = job.pay, steps = steps, step = active.paidAt and math.max(0, #steps - 1) or (s.step or 0),
			phase = active.paidAt and "paid" or (active.doneSent and "checking" or "running"),
			text = s.text, short = s.short, hint = s.hint, inZone = s.inZone == true,
			distance = from and s.target and dist2D(from, s.target) or nil}
	end
	return state
end

function pushApp()
	if guihooks and type(guihooks.trigger) == "function" then guihooks.trigger("SharedCareerJobs", M.appState()) end
end

function M.setAppOpen(on)
	appOpen = on == true
	pushApp()
end

function M.registerApp()
	local phone = U.ext("sharedCareer_phone")
	if not phone or type(phone.registerApp) ~= "function" then return end
	if serverAllows() then
		phone.registerApp({id = "jobs", title = "Jobs", icon = "jobs", color = "#2d6fd8", order = 5, beta = true,
			onOpen = function() M.setAppOpen(true) end, onClose = function() M.setAppOpen(false) end})
	else
		phone.unregisterApp("jobs")
		appOpen = false
	end
end

-- buttons of the Jobs app
function M.uiTake(id)
	if active then
		U.toast("warning", "Finish your job first", 4)
		return
	end
	U.send("sc_jobTake", {id = tonumber(id)})
end

function M.uiGiveUp()
	if not active or active.doneSent then return end
	U.send("sc_jobGiveUp", {id = active.id})
	endActive()
	U.toast("info", "Job given up", 4)
	pushApp()
end

function M.uiNavigate()
	if not active or active.paidAt then return end
	local target = statusOf(active).target
	active.route = target
	navigate(target)
end

function M.uiRequest() pushApp() end

function M.getActive() return active end

--== Hooks =======================================================================

function M.onUpdate(dtReal)
	local dt = tonumber(dtReal) or 0
	clock = clock + dt
	if not active and not appOpen then return end
	sinceCheck = sinceCheck + dt
	if sinceCheck >= CHECK_EVERY then
		local stepDt = sinceCheck
		sinceCheck = 0
		local ok, err = pcall(M.step, stepDt)
		if not ok then U.log("E", "jobs", "job check failed: " .. tostring(err)) end
	end
	sincePush = sincePush + dt
	if sincePush >= PUSH_EVERY then
		sincePush = 0
		local menu = U.ext("sharedCareer_menu")
		if appOpen or (menu and menu.isVisible("phone")) then pcall(pushApp) end
	end
	if active and not active.paidAt and active.type.draw then pcall(active.type.draw, active) end
end

function M.onVehicleResetted(id)
	if active and not active.paidAt and active.type.vehicleReset then
		pcall(active.type.vehicleReset, active, id)
	end
end

-- The career save's folder, or nil.
local function savePath()
	local saveSystem = rawget(_G, "career_saveSystem")
	if not saveSystem or type(saveSystem.getCurrentSaveSlot) ~= "function" then return nil end
	local ok, _, path = pcall(saveSystem.getCurrentSaveSlot)
	return ok and type(path) == "string" and path or nil
end

-- The game saves the career: a copy of your levels goes with it.
function M.onSaveCurrentSaveSlot(currentSavePath)
	if type(currentSavePath) ~= "string" or not next(levels) or type(jsonWriteFile) ~= "function" then return end
	local ok, err = pcall(jsonWriteFile, currentSavePath .. LEVELS_FILE, {version = 1, levels = levels}, true)
	if not ok then U.log("W", "jobs", "could not save the job levels: " .. tostring(err)) end
end

function M.onCareerActive(on)
	if on and U.isMP() then
		-- the copy in the save, until the server's list arrives
		local path = savePath()
		if path and not next(levels) and type(jsonReadFile) == "function" then
			local ok, saved = pcall(jsonReadFile, path .. LEVELS_FILE)
			if ok and type(saved) == "table" and type(saved.levels) == "table" then levels = saved.levels end
		end
		M.registerApp()
		U.send("sc_jobsRequest", "")
	end
end

function M.onConfigChanged()
	M.registerApp()
	pushApp()
end

function M.onBeamMPServerLeave()
	navigate(nil)
	active, list, levels, enabled = nil, {}, {}, false
	appOpen = false
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	U.on("sc_jobs", rxJobs)
	U.on("sc_jobGenerate", rxGenerate)
	U.on("sc_jobPaid", rxPaid)
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
