-- SharedCareer :: jobs (beta): the shared job list and the Jobs app, for every kind of job
--
-- The server keeps one list of jobs for everyone (server.jobs, see main.lua "Jobs"). This file is
-- what all jobs have in common. What a job is about comes from its job type, an extension that
-- registers itself here (registerType) – towJobs.lua (towing jobs) is the first one. A job type:
--   id               short name, sent with every job ("tow")
--   name             shown with the pay in the career's money history ("Towing job: <title>")
--   icon             the icon of its jobs in the Jobs app (a name the app knows, e.g. "tow")
--   steps            the steps of a job in the Jobs app, e.g. {"Pick up", "Tow", "Paid"}; the last
--                    one is reached when the pay arrives
--   generate()       makes up a job on this map: {title, pos, dest = {name, pos}, length, pay, data}
--                    (pos: where it starts; data: the type's own fields, the server passes them on),
--                    or nil and why not
--   tags(job)        short labels for the job in the app: {{text, kind}} (kind picks the color)
--   start(a)         the job is yours: a = {id, job}; the type keeps its own state in a
--   step(a, dt)      every CHECK_EVERY s until it is handed over; calls M.handOver(a, pay,
--                    deduction) when the job is done
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
--   making one up  when jobs are missing, the server asks one player (sc_jobGenerate); this
--                  client asks its job types in turn and sends the first job (sc_jobOffer)
--   taking         sc_jobTake, the server gives it to the first one; then the type's start() and
--                  the route to its status target (updated whenever the target changes)
--   giving up      sc_jobGiveUp; a job the server takes away (out of time, switched off) ends too
--   handing over   handOver -> sc_jobDone with the pay; without the server's answer within
--                  PAID_WAIT s the job ends here (a pay the server did book still arrives later)
--   the pay        sc_jobPaid: credited to the career (playerAttributes), the career is saved and
--                  the server gets sc_jobPaidAck; until then it sends the pay again (also after a
--                  crash or reconnect, see main.lua "Payouts"). Each payout is credited once. The
--                  type's stop() follows REMOVE_AFTER s later
--
-- Settings: server.jobs (on/off, also the Jobs app), server.jobsOpen, server.jobTimeoutMinutes,
-- server.jobPayMax (server); client.jobPay (factor on the pay, payFactor).

local M = {}

local U

local PAID_WAIT = 15          -- s for the server's answer to sc_jobDone; then the job ends here
local REMOVE_AFTER = 6        -- s after paying, the job ends (the type's stop())
local CHECK_EVERY = 0.25      -- s between two checks of the job
local PUSH_EVERY = 1          -- s between two app updates while the phone is out

local types = {}              -- id -> job type
local typeOrder = {}          -- ids, in the order they registered
local nextType = 1            -- the job type asked first when making up the next job
local list = {}               -- jobs from the server (sc_jobs)
local enabled = false
local active = nil            -- your job: {id, job, type, doneSent, doneAt, deduction, paidAt, route}
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

--- Makes up a new job: the job types are asked in turn, the first job wins. Returns the job (with
--- its type) or nil and why not.
function M.generate()
	local why = "no job types"
	for i = 0, #typeOrder - 1 do
		local id = typeOrder[(nextType - 1 + i) % #typeOrder + 1]
		local ok, job, err = pcall(types[id].generate)
		if ok and type(job) == "table" then
			nextType = nextType % #typeOrder + 1
			job.type = id
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

--- The job type: the job is done, with this pay (and the deduction from the job's pay, shown with
--- the pay). Sends it to the server once.
function M.handOver(a, pay, deduction)
	if a ~= active or a.doneSent then return end
	a.doneSent, a.doneAt, a.deduction = true, clock, tonumber(deduction) or 0
	U.send("sc_jobDone", {id = a.id, pay = pay})
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
	local mine = mineIn(list)
	if active and not active.doneSent and (not mine or mine.id ~= active.id) then
		-- taken away (out of time, switched off, given up elsewhere)
		endActive()
	end
	if mine and not active then startActive(mine) end
	M.registerApp()
	pushApp()
end

local function rxGenerate()
	if not enabled or not U.careerActive() then return end
	local job, why = M.generate()
	if job then
		U.send("sc_jobOffer", job)
	else
		U.log("W", "jobs", "could not make up a job: " .. tostring(why))
	end
end

-- A payout for a finished job: {payout, job, type, title, pay}. Credited and saved, then confirmed
-- (sc_jobPaidAck); without the confirmation the server sends it again (also after a reconnect).
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
	local label = (t and t.name or "Job") .. ": " .. (type(msg.title) == "string" and msg.title or "?")
	if pay > 0 then
		local ok, err = pcall(attributes.addAttributes, {money = pay}, {tags = {"gameplay"}, label = label})
		if not ok then
			U.log("E", "jobs", "could not credit the pay of job " .. tostring(msg.job) .. ": " .. tostring(err))
			return
		end
		U.saveCareer("jobs")
	end
	creditedPayouts[msg.payout] = true
	U.send("sc_jobPaidAck", {payout = msg.payout})
	local deduction = mine and active.deduction or 0
	U.toast("success", string.format("Job done: +$%d", pay)
		.. (deduction > 0 and string.format(" (−$%d damage)", deduction) or ""), 8)
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

--- State for the Jobs app.
function M.appState()
	local me = myPosition()
	local jobs = {}
	for _, job in ipairs(list) do
		local t = types[job.type]
		table.insert(jobs, {id = job.id, icon = t and t.icon or "?", title = job.title or "?", tags = tagsOf(job),
			dest = job.dest and job.dest.name or "?", length = job.length, pay = job.pay, state = job.state,
			takenBy = job.takenBy, distance = me and job.pos and dist2D(me, job.pos) or nil})
	end
	table.sort(jobs, function(a, b)
		if (a.state == "open") ~= (b.state == "open") then return a.state == "open" end
		return (a.distance or 1e12) < (b.distance or 1e12)
	end)
	local state = {enabled = enabled and serverAllows(), jobs = jobs}
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

function M.onCareerActive(on)
	if on and U.isMP() then
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
	active, list, enabled = nil, {}, false
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
