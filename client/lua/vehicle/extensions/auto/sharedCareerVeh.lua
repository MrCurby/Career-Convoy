-- SharedCareer :: vehicle Lua (runs in every vehicle)
--
-- Called from the GE side (vehicles.lua) via queueLuaCommand to switch collisions with
-- this vehicle on or off (ghost mode for other players' cars / players on foot).

local M = {}

function M.setGhost(enabled)
	obj:setGhostEnabled(enabled and true or false)
end

return M
