-- SharedCareer :: Einstiegspunkt des Client-Mods
--
-- BeamMP lädt diesen Mod beim Join automatisch vom Server; BeamNG führt dieses Skript aus.
--
-- Module (lua/ge/extensions/sharedCareer/):
--   util      gemeinsame Hilfen (Logging, Server-Nachrichten, Funktionen sicher ersetzen)
--   protect   Schutz beim Karrierestart: fremde Autos werden nicht gelöscht
--   traffic   Traffic-Menge vom Server, simple vehicles, vorsichtigere KI
--   garage    Garage: keine doppelten Autos, sichtbarer Fußgänger, Computer aus der Nähe
--   vehicles  Autos der anderen: Sichtbarkeit, Namensschilder, Kollision (Ghost)
--   money     Überweisungen zwischen Spielern (/pay)
--   env       Tageszeit vom Server, Umwelt im Pausemenü gesperrt
--   menu      Einstellungen im SharedCareer-Menü (Traffic, Optionen) – gelten für alle
--   players   Reiter Players (Navigate, Watch, Teleport), Status am Namensschild, Menü-Taste
--   fuel      gemeinsame Spritpreise; Spritlieferungen machen Tankstellen für alle günstiger
--   welcome   Willkommensdialog beim Join (mit "Don't show again")
--
-- Außerdem im Mod: levels/west_coast_usa/.../garage_interactions/items.level.json –
-- größere Zonen an den Werkstatt-Computern (ersetzt die gleichnamige Datei der Karte),
-- und die UI-Apps ui/modules/apps/SharedCareer-Time/ (SharedCareer-Menü) und
-- ui/modules/apps/SharedCareer-Fuel/ (Tankstellen-Preise, eigene Lasche mit Zapfsäule).
--
--   cleanup   UI-Layouts: entfernt Mileage-Reste (rote "Unknown app"-Kästen) und setzt das
--             Tageszeit-Fenster einmalig ins Karriere-Layout
--   core      Ablauf beim Join: Einstellungen holen, Karriere starten, Ergebnis melden
--
-- Reihenfolge ist wichtig: util zuerst (alle anderen nutzen es), protect vor core
-- (der Schutz muss stehen, bevor irgendeine Karriere startet).
-- 'manual' hält die Erweiterungen über Kartenwechsel hinweg am Leben – die Karriere
-- wechselt ständig Level bzw. lädt ihre Module neu.

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
loadPersistent('sharedCareer/cleanup')
loadPersistent('sharedCareer/core')
