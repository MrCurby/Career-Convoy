-- SharedCareer :: entry point of the client mod
--
-- BeamMP downloads this mod from the server on join; BeamNG runs this script.
--
-- Modules (lua/ge/extensions/sharedCareer/):
--   util      shared helpers (logging, server messages, replacing functions safely)
--   protect   protection during the career start: other players' cars are not deleted
--   traffic   traffic amount from the server, simple vehicles, more careful AI
--   garage    garage: no duplicate cars, visible player on foot, computers from a distance
--   vehicles  other players' cars: visibility, name tags, collision (ghost)
--   instability  physics glitches: invalid sync values blocked, a glitch shown
--   sendRate  your parked cars and far traffic send their position less often
--   couplings trailers and dollies stay coupled on every PC
--   money     money transfers between players (/pay)
--   env       time of day from the server, environment locked in the pause menu
--   menu      settings in the SharedCareer menu (traffic, options) – apply to everyone; menu key
--   players   Players tab (navigate, watch, teleport), status on name tags
--   fuel      shared fuel prices; fuel deliveries make stations cheaper for everyone
--   welcome   welcome dialog on join (with "Don't show again")
--   licenses  the license office: a circle on the map, F opens the license shop
--   nodegrab  node grabber in the career also in a vehicle / free camera (client.allowNodeGrabber)
--   rope      ropes between your vehicles: the core of the Tow and Straps apps (client.allowRopes)
--   ropeRemote  the remote for a rope's loose end (move it, where it would hook on): Tow, Straps
--   tow       the Tow app: rope and winch, move your own vehicles slowly by hand
--   straps    the Straps app: ratchet straps that hold a car on a trailer or truck
--   phone     the phone with its apps: Jobs (jobs.lua), Tow (tow.lua), Straps (straps.lua),
--             Fuel (fuel.lua)
--             (client.phone, key F4)
--   jobs      jobs (beta): the shared job list and the Jobs app, for every job type (server.jobs)
--   towJobs   the towing jobs, the first job type: broken-down cars towed to a repair shop
--
-- Also in the mod: levels/west_coast_usa/.../garage_interactions/items.level.json –
-- larger zones at the garage computers (replaces the map file of the same name),
-- and the UI apps ui/modules/apps/SharedCareer-Menu/ (SharedCareer menu) and
-- ui/modules/apps/SharedCareer-Phone/ (the phone, own tab; its apps: Jobs, Tow, Straps, Fuel).
--
--   cleanup   UI layouts: removes Mileage leftovers (red "Unknown app" boxes) and adds the
--             SharedCareer apps to the career layout once
--   core      join flow: get settings, start the career, report the result
--
-- Order matters: util first (all others use it), jobs before the job types (they register
-- there), protect before core
-- (the protection must be in place before any career starts).
-- 'manual' keeps the extensions alive across map changes – the career keeps
-- switching levels and reloading its modules.

local function loadPersistent(path)
	load(path)
	setExtensionUnloadMode(path, "manual")
end

loadPersistent("sharedCareer/util")
loadPersistent("sharedCareer/protect")
loadPersistent("sharedCareer/traffic")
loadPersistent("sharedCareer/garage")
loadPersistent("sharedCareer/vehicles")
loadPersistent("sharedCareer/instability")
loadPersistent("sharedCareer/sendRate")
loadPersistent("sharedCareer/couplings")
loadPersistent("sharedCareer/money")
loadPersistent("sharedCareer/env")
loadPersistent("sharedCareer/menu")
loadPersistent("sharedCareer/players")
loadPersistent("sharedCareer/fuel")
loadPersistent("sharedCareer/welcome")
loadPersistent("sharedCareer/licenses")
loadPersistent("sharedCareer/nodegrab")
loadPersistent("sharedCareer/rope")
loadPersistent("sharedCareer/ropeRemote")
loadPersistent("sharedCareer/tow")
loadPersistent("sharedCareer/straps")
loadPersistent("sharedCareer/phone")
loadPersistent("sharedCareer/jobs")
loadPersistent("sharedCareer/towJobs")
loadPersistent("sharedCareer/cleanup")
loadPersistent("sharedCareer/core")
