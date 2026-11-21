-- SharedCareer :: money transfers between players (client side)
--
-- Flow (the server drives it, see main.lua):
--   sc_payDebit  -> check own money, debit, save, sc_payDebitResult
--   sc_payCredit -> credit, sc_payCreditAck
-- Every transfer has an ID; a message that arrives twice is only acknowledged,
-- not booked a second time.

local M = {}

local U

local debited = {} -- id -> true
local credited = {} -- id -> true

local function money()
	local attrs = career_modules_playerAttributes
	if type(attrs) ~= "table" or type(attrs.getAttribute) ~= "function" then
		return nil
	end
	local attribute = attrs.getAttribute("money")
	return type(attribute) == "table" and tonumber(attribute.value) or nil
end

local function validAmount(n)
	n = tonumber(n)
	return n and n >= 1 and n == math.floor(n) and n or nil
end

local function rxDebit(data)
	local msg = U.decode(data)
	if not msg or type(msg.id) ~= "string" then
		return
	end
	local amount = validAmount(msg.amount)
	if debited[msg.id] then
		U.send("sc_payDebitResult", { id = msg.id, ok = true })
		return
	end
	local reason = nil
	local current = money()
	if not amount then
		reason = "invalid amount"
	elseif not U.careerActive() or not current then
		reason = "career not active"
	elseif current < amount then
		reason = "not enough money"
	end
	if reason then
		U.send("sc_payDebitResult", { id = msg.id, ok = false, reason = reason })
		return
	end
	career_modules_playerAttributes.addAttributes(
		{ money = -amount },
		{ tags = { "gameplay" }, label = "Payment to " .. tostring(msg.to) }
	)
	debited[msg.id] = true
	U.saveCareer("money")
	U.send("sc_payDebitResult", { id = msg.id, ok = true })
	U.toast("info", string.format("-$%d to %s", amount, tostring(msg.to)))
end

local function rxCredit(data)
	local msg = U.decode(data)
	if not msg or type(msg.id) ~= "string" then
		return
	end
	local amount = validAmount(msg.amount)
	if credited[msg.id] then
		U.send("sc_payCreditAck", { id = msg.id })
		return
	end
	if not amount or not U.careerActive() then
		return
	end -- no confirmation -> the server refunds
	local label = msg.refund and "Refund" or ("Payment from " .. tostring(msg.from))
	career_modules_playerAttributes.addAttributes({ money = amount }, { tags = { "gameplay" }, label = label })
	credited[msg.id] = true
	U.saveCareer("money")
	U.send("sc_payCreditAck", { id = msg.id })
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

M.onInit = function()
	setExtensionUnloadMode(M, "manual")
end

return M
