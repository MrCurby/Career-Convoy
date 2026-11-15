-- SharedCareer :: Überweisungen zwischen Spielern (Client-Seite)
--
-- Ablauf (der Server steuert, siehe main.lua):
--   sc_payDebit  -> eigenes Geld prüfen, abbuchen, speichern, sc_payDebitResult
--   sc_payCredit -> gutschreiben, sc_payCreditAck
-- Jede Überweisung hat eine ID; eine doppelt ankommende Nachricht wird nur bestätigt,
-- nicht ein zweites Mal gebucht.

local M = {}

local U

local debited = {}  -- id -> true
local credited = {} -- id -> true

local function money()
	local attrs = career_modules_playerAttributes
	if type(attrs) ~= "table" or type(attrs.getAttribute) ~= "function" then return nil end
	local attribute = attrs.getAttribute("money")
	return type(attribute) == "table" and tonumber(attribute.value) or nil
end

local function careerActive()
	return career_career and type(career_career.isActive) == "function" and career_career.isActive() == true
end

local function save()
	if career_saveSystem and type(career_saveSystem.saveCurrent) == "function" then
		local ok, err = pcall(career_saveSystem.saveCurrent)
		if not ok then U.log("E", "money", "saving failed: " .. tostring(err)) end
	end
end

local function validAmount(n)
	n = tonumber(n)
	return n and n >= 1 and n == math.floor(n) and n or nil
end

local function rxDebit(data)
	local msg = U.decode(data)
	if not msg or type(msg.id) ~= "string" then return end
	local amount = validAmount(msg.amount)
	if debited[msg.id] then
		U.send("sc_payDebitResult", {id = msg.id, ok = true})
		return
	end
	local reason = nil
	local current = money()
	if not amount then
		reason = "invalid amount"
	elseif not careerActive() or not current then
		reason = "career not active"
	elseif current < amount then
		reason = "not enough money"
	end
	if reason then
		U.send("sc_payDebitResult", {id = msg.id, ok = false, reason = reason})
		return
	end
	career_modules_playerAttributes.addAttributes({money = -amount},
		{tags = {"gameplay"}, label = "Payment to " .. tostring(msg.to)})
	debited[msg.id] = true
	save()
	U.send("sc_payDebitResult", {id = msg.id, ok = true})
	U.toast("info", string.format("-$%d to %s", amount, tostring(msg.to)))
end

local function rxCredit(data)
	local msg = U.decode(data)
	if not msg or type(msg.id) ~= "string" then return end
	local amount = validAmount(msg.amount)
	if credited[msg.id] then
		U.send("sc_payCreditAck", {id = msg.id})
		return
	end
	if not amount or not careerActive() then return end -- keine Bestätigung -> Server bucht zurück
	local label = msg.refund and "Refund" or ("Payment from " .. tostring(msg.from))
	career_modules_playerAttributes.addAttributes({money = amount}, {tags = {"gameplay"}, label = label})
	credited[msg.id] = true
	save()
	U.send("sc_payCreditAck", {id = msg.id})
	U.toast("success", string.format("+$%d – %s", amount, label))
end

function M.onBeamMPServerLeave()
	debited, credited = {}, {}
end

function M.onExtensionLoaded()
	U = extensions.sharedCareer_util
	U.on("sc_payDebit", rxDebit)
	U.on("sc_payCredit", rxCredit)
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
