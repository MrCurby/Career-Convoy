-- SharedCareer :: Fahrzeug-Lua (läuft in jedem Fahrzeug)
--
-- Wird von der GE-Seite (vehicles.lua) per queueLuaCommand aufgerufen, um Kollisionen mit
-- diesem Fahrzeug an- oder auszuschalten (Ghost-Modus für Autos/Fußgänger anderer Spieler).

local M = {}

function M.setGhost(enabled)
	obj:setGhostEnabled(enabled and true or false)
end

return M
