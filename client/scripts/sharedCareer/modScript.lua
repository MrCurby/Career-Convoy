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
--   money     money transfers between players (/pay)
--   env       time of day from the server, environment locked in the pause menu
--   menu      settings in the SharedCareer menu (traffic, options) – apply to everyone; menu key
--   players   Players tab (navigate, watch, teleport), status on name tags
--   fuel      shared fuel prices; fuel deliveries make stations cheaper for everyone
--   welcome   welcome dialog on join (with "Don't show again")
--   nodegrab  node grabber in the career also in a vehicle / free camera (client.allowNodeGrabber)
--   grab      rope and winch: move your own vehicles slowly by hand (Tow app, client.allowGrab)
--   phone     the phone with its apps: Tow (grab.lua), Fuel (fuel.lua) (client.phone, key F4)
--
-- Also in the mod: levels/west_coast_usa/.../garage_interactions/items.level.json –
-- larger zones at the garage computers (replaces the map file of the same name),
-- and the UI apps ui/modules/apps/SharedCareer-Menu/ (SharedCareer menu) and
-- ui/modules/apps/SharedCareer-Phone/ (the phone, own tab; its apps: Tow, Fuel).
--
--   cleanup   UI layouts: removes Mileage leftovers (red "Unknown app" boxes) and adds the
--             SharedCareer apps to the career layout once
--   core      join flow: get settings, start the career, report the result
--
-- Order matters: util first (all others use it), protect before core
-- (the protection must be in place before any career starts).
-- 'manual' keeps the extensions alive across map changes – the career keeps
-- switching levels and reloading its modules.

local function loadPersistent(path)
	load(path)
	setExtensionUnloadMode(path, 'manual')
end

loadPersistent('sharedCareer/util')
loadPersistent('sharedCareer/protect')
loadPersistent('sharedCareer/traffic')
loadPersistent('sharedCareer/garage')
loadPersistent('sharedCareer/vehicles')
loadPersistent('sharedCareer/money')
loadPersistent('sharedCareer/env')
loadPersistent('sharedCareer/menu')
loadPersistent('sharedCareer/players')
loadPersistent('sharedCareer/fuel')
loadPersistent('sharedCareer/welcome')
loadPersistent('sharedCareer/nodegrab')
loadPersistent('sharedCareer/grab')
loadPersistent('sharedCareer/phone')
loadPersistent('sharedCareer/cleanup')
loadPersistent('sharedCareer/core')
