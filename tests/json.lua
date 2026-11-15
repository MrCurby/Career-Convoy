-- Minimal JSON encoder/decoder for the tests (replaces Util.JsonEncode / jsonEncode).
local json = {}

local function isArray(t)
	local n = 0
	for k in pairs(t) do
		if type(k) ~= "number" then return false end
		n = n + 1
	end
	return n > 0 and n == #t
end

local function esc(s)
	return '"' .. s:gsub('[%c"\\]', function(c)
		return string.format("\\u%04x", c:byte())
	end) .. '"'
end

function json.encode(v)
	local t = type(v)
	if t == "nil" then return "null" end
	if t == "boolean" then return tostring(v) end
	if t == "number" then
		if v == math.floor(v) and math.abs(v) < 2^53 then return string.format("%d", v) end
		return string.format("%.14g", v)
	end
	if t == "string" then return esc(v) end
	if t == "table" then
		local out = {}
		if isArray(v) then
			for _, x in ipairs(v) do table.insert(out, json.encode(x)) end
			return "[" .. table.concat(out, ",") .. "]"
		end
		for k, x in pairs(v) do table.insert(out, esc(tostring(k)) .. ":" .. json.encode(x)) end
		return "{" .. table.concat(out, ",") .. "}"
	end
	error("cannot " .. t .. " encode")
end

function json.decode(s)
	local pos = 1
	local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
	local value
	local function str()
		local out = {}
		pos = pos + 1
		while true do
			local c = s:sub(pos, pos)
			if c == "" then error("end inside a string") end
			if c == '"' then pos = pos + 1; break end
			if c == "\\" then
				local n = s:sub(pos + 1, pos + 1)
				if n == "u" then
					local code = tonumber(s:sub(pos + 2, pos + 5), 16)
					table.insert(out, utf8 and utf8.char(code) or string.char(code % 256))
					pos = pos + 6
				else
					local map = {n = "\n", t = "\t", r = "\r", b = "\b", f = "\f"}
					table.insert(out, map[n] or n)
					pos = pos + 2
				end
			else
				table.insert(out, c)
				pos = pos + 1
			end
		end
		return table.concat(out)
	end
	value = function()
		ws()
		local c = s:sub(pos, pos)
		if c == "{" then
			local t = {}
			pos = pos + 1
			ws()
			if s:sub(pos, pos) == "}" then pos = pos + 1; return t end
			while true do
				ws()
				local k = str()
				ws()
				assert(s:sub(pos, pos) == ":", "':' expected")
				pos = pos + 1
				t[k] = value()
				ws()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == "}" then return t end
				assert(d == ",", "',' expected")
			end
		elseif c == "[" then
			local t = {}
			pos = pos + 1
			ws()
			if s:sub(pos, pos) == "]" then pos = pos + 1; return t end
			while true do
				table.insert(t, value())
				ws()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == "]" then return t end
				assert(d == ",", "',' expected")
			end
		elseif c == '"' then
			return str()
		elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
		elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
		elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
		end
		local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
		if not num or num == "" then error("invalid JSON at " .. pos) end
		pos = pos + #num
		return tonumber(num)
	end
	local result = value()
	ws()
	if pos <= #s then error("Restdaten") end
	return result
end

return json
