-- Career-Convoy :: entry point of the client mod
--
-- BeamMP downloads this mod from the server on join; BeamNG runs this script.
--
-- Modules (lua/ge/extensions/careerConvoy/):
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
--   menu      settings in the Career-Convoy menu (traffic, options) – apply to everyone; menu key
--   players   Players tab (navigate, watch, teleport), status on name tags
--   fuel      shared fuel prices; fuel deliveries make stations cheaper for everyone
--   welcome   welcome dialog on join (with "Don't show again")
--   licenses  the license office: a career marker on the map, its card opens the license shop
--   nodegrab  node grabber in the career also in a vehicle / free camera (client.allowNodeGrabber)
--   rope      ropes between your vehicles: the core of the Tow and Straps apps (client.allowRopes)
--   ropeRemote  the remote for a rope's loose end (move it, where it would hook on): Tow, Straps
--   tow       the Tow app: rope and winch, move your own vehicles slowly by hand
--   straps    the Straps app: ratchet straps that hold a car on a trailer or truck
--   phone     the phone with its apps: Jobs (jobs.lua), Tow (tow.lua), Straps (straps.lua),
--             Fuel (fuel.lua)
--             (client.phone, key F4)
--   jobs      jobs: the shared job list and the Jobs app, for every job type (server.jobs)
--   towJobs   the towing jobs, a job type: broken-down cars towed to a repair shop
--   taxiJobs  the taxi jobs, a job type: a passenger at the roadside driven to a place on the map
--   speedLimit  the speed limit of the road you drive on, as a sign (bottom right)
--
-- Also in the mod: levels/west_coast_usa/.../garage_interactions/items.level.json –
-- larger zones at the garage computers (replaces the map file of the same name),
-- and the UI apps ui/modules/apps/CareerConvoy-Menu/ (Career-Convoy menu),
-- ui/modules/apps/CareerConvoy-Phone/ (the phone, own tab; its apps: Jobs, Tow, Straps, Fuel) and
-- ui/modules/apps/CareerConvoy-SpeedLimit/ (the speed limit sign).
--
--   cleanup   UI layouts: removes Mileage leftovers (red "Unknown app" boxes) and adds the
--             Career-Convoy apps to the career layout once
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

loadPersistent("careerConvoy/util")
loadPersistent("careerConvoy/protect")
loadPersistent("careerConvoy/traffic")
loadPersistent("careerConvoy/garage")
loadPersistent("careerConvoy/vehicles")
loadPersistent("careerConvoy/instability")
loadPersistent("careerConvoy/sendRate")
loadPersistent("careerConvoy/couplings")
loadPersistent("careerConvoy/money")
loadPersistent("careerConvoy/env")
loadPersistent("careerConvoy/menu")
loadPersistent("careerConvoy/players")
loadPersistent("careerConvoy/fuel")
loadPersistent("careerConvoy/welcome")
loadPersistent("careerConvoy/licenses")
loadPersistent("careerConvoy/nodegrab")
loadPersistent("careerConvoy/rope")
loadPersistent("careerConvoy/ropeRemote")
loadPersistent("careerConvoy/tow")
loadPersistent("careerConvoy/straps")
loadPersistent("careerConvoy/phone")
loadPersistent("careerConvoy/jobs")
loadPersistent("careerConvoy/towJobs")
loadPersistent("careerConvoy/taxiJobs")
loadPersistent("careerConvoy/speedLimit")
loadPersistent("careerConvoy/cleanup")
loadPersistent("careerConvoy/core")
