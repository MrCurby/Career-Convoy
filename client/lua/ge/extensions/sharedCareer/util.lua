-- SharedCareer :: gemeinsame Hilfsfunktionen (Client)
--
--   VERSION          Mod-Version; muss zur Server-Version passen (sonst Warn-Dialog)
--   log              Logzeile unter "sharedCareer.<bereich>" in der beamng.log
--   isMP             true auf einem BeamMP-Server (sonst tut der Mod nichts)
--   send / on        Nachricht an den Server / Empfänger für Server-Nachrichten
--   decode           JSON sicher lesen (kaputte Daten -> nil statt Absturz)
--   toast            kurze Einblendung im Spiel
--   ext              Erweiterung holen, ohne sie versehentlich zu laden
--   profileName      Profilname wie das Spiel ihn bildet (klein, nur a-z0-9)
--   replace / isOurs Spielfunktion sicher ersetzen, ohne den eigenen Wrapper doppelt zu wickeln

local M = {}

M.VERSION = "0.8.4"

local unpack = table.unpack or unpack

function M.pack(...)
	return {n = select("#", ...), ...}
end
M.unpack = unpack

function M.log(level, tag, msg)
	log(level, "sharedCareer." .. tag, msg)
end

-- true, wenn wir gerade auf einem BeamMP-Server sind.
function M.isMP()
	local net = rawget(_G, "MPCoreNetwork")
	if type(net) ~= "table" or type(net.isMPSession) ~= "function" then return false end
	local ok, session = pcall(net.isMPSession)
	return ok and session == true
end

function M.decode(data)
	if type(data) ~= "string" or data == "" or data == "null" then return nil end
	local ok, value = pcall(jsonDecode, data)
	if ok and type(value) == "table" then return value end
	return nil
end

function M.send(event, value)
	if type(rawget(_G, "TriggerServerEvent")) ~= "function" then return end
	TriggerServerEvent(event, type(value) == "string" and value or jsonEncode(value or {}))
end

function M.on(event, handler)
	if type(rawget(_G, "AddEventHandler")) ~= "function" then return end
	AddEventHandler(event, handler)
end

function M.toast(kind, msg, seconds)
	if guihooks and type(guihooks.trigger) == "function" then
		guihooks.trigger("toastrMsg", {
			type = kind, title = "SharedCareer", msg = msg,
			config = {timeOut = (seconds or 5) * 1000},
		})
	end
end

-- Lookup einer Erweiterung, ohne sie dabei versehentlich zu laden (extensions hat einen
-- __index, der fehlende Erweiterungen nachlädt).
function M.ext(name)
	local m = (type(extensions) == "table" and rawget(extensions, name)) or rawget(_G, name)
	if type(m) == "table" then return m end
	return nil
end

-- Profilname aus dem BeamMP-Namen. Das Spiel macht selbst lowercase + nur a-z0-9 und
-- hängt bei Kollision eine Nummer an – das würde den Namen je nach PC unterschiedlich
-- machen. Deshalb hier deterministisch vorab.
function M.profileName(nickname, suffix)
	local name = string.lower(tostring(nickname or "") .. tostring(suffix or ""))
	name = name:gsub("[^a-z0-9]", "")
	if name == "" then name = "sharedcareer" end
	return name
end

--== Funktionen ersetzen, ohne doppelt zu wickeln =============================
-- Karriere-Module werden bei jedem Karrierestart neu geladen (neue Tabelle). Ein Wrapper
-- muss deshalb regelmäßig geprüft und auf der aktuellen Tabelle neu gesetzt werden. Damit
-- wir dabei nicht unseren eigenen Wrapper erneut einwickeln (Stack Overflow nach ein paar
-- Leveln), merken wir uns alle Wrapper in einer schwachen Tabelle.

local ours = setmetatable({}, {__mode = "k"})

function M.isOurs(fn)
	return type(fn) == "function" and ours[fn] == true
end

-- Ersetzt module[fnName] durch makeWrapper(original). Gibt true zurück, wenn die Funktion
-- jetzt unser Wrapper ist (neu gesetzt oder schon vorher).
function M.replace(module, fnName, makeWrapper)
	if type(module) ~= "table" or type(module[fnName]) ~= "function" then return false end
	if ours[module[fnName]] then return true end
	local wrapper = makeWrapper(module[fnName])
	ours[wrapper] = true
	module[fnName] = wrapper
	return true
end

return M
