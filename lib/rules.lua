-- SPDX-License-Identifier: MIT
-- Classic-style visual grid addresses, compiled to real inventory indices.
return function(M)
	local S = M.S
	local R = {}
	M.rules = R
	R.limits = { text = 8192, lines = 64, slots = 512, width = 32 }

	local function integer(value, minimum, maximum)
		return type(value) == "number" and value == math.floor(value)
			and value >= minimum and value <= maximum
	end

	local function dimensions(size, width, player)
		if not integer(size, 1, R.limits.slots) or not integer(width, 1, R.limits.width) then
			return nil, S("Invalid inventory dimensions.")
		end
		if player and (size < width or size % width ~= 0) then
			return nil, S("Player inventory must contain complete rows and a hotbar.")
		end
		return true
	end

	local function row_name(row)
		local name = ""
		repeat
			local digit = (row - 1) % 26
			name = string.char(65 + digit) .. name
			row = math.floor((row - 1) / 26)
		until row == 0
		return name
	end

	local function row_number(name)
		if #name > 2 then return nil end
		local number = 0
		for i = 1, #name do
			local ch = name:upper():byte(i)
			if ch < 65 or ch > 90 then return nil end
			number = number * 26 + ch - 64
		end
		return number > 0 and number or nil
	end

	function R.grid(size, width, player)
		local ok, err = dimensions(size, width, player)
		if not ok then return nil, err end
		local result = {}
		if player then
			for i = width + 1, size do result[#result + 1] = i end
			for i = 1, width do result[#result + 1] = i end
		else
			for i = 1, size do result[i] = i end
		end
		return result
	end

	function R.slot_label(index, size, width, player)
		local ok = dimensions(size, width, player)
		if not ok or not integer(index, 1, size) then return nil end
		local visual = index
		if player then visual = index <= width and size - width + index or index - width end
		return row_name(math.floor((visual - 1) / width) + 1) .. tostring((visual - 1) % width + 1)
	end

	local function directed(first, last, fn)
		local step = first <= last and 1 or -1
		for i = first, last, step do fn(i) end
	end

	local function target(spec, grid, width)
		if type(spec) ~= "string" or #spec > 32 then return nil, S("Invalid slot target.") end
		local vertical, reverse = false, false
		-- Lowercase suffixes are unambiguous even for containers with row R or V.
		for _ = 1, 2 do
			local suffix = spec:sub(-1)
			if suffix == "r" and not reverse then reverse, spec = true, spec:sub(1, -2)
			elseif suffix == "v" and not vertical then vertical, spec = true, spec:sub(1, -2)
			else break end
		end
		local rows, result, invalid = math.ceil(#grid / width), {}, false
		local function add(row, col)
			local value = row and col and grid[(row - 1) * width + col]
			if not row or not col or row < 1 or row > rows or col < 1 or col > width or not value then
				invalid = true
			else result[#result + 1] = value end
		end
		local ar, ac, br, bc = spec:match("^([A-Za-z]+)(%d+)%-([A-Za-z]+)(%d+)$")
		if ar then
			ar, br, ac, bc = row_number(ar), row_number(br), tonumber(ac), tonumber(bc)
			if not ar or not br or ar > rows or br > rows or ac < 1 or ac > width or bc < 1 or bc > width then
				return nil, S("Rectangle is outside this inventory.")
			end
			if vertical then directed(ac, bc, function(col) directed(ar, br, function(row) add(row, col) end) end)
			else directed(ar, br, function(row) directed(ac, bc, function(col) add(row, col) end) end) end
		else
			if vertical then return nil, S("The v suffix is only used with a rectangle.") end
			local row, col = spec:match("^([A-Za-z]+)(%d+)$")
			if row then add(row_number(row), tonumber(col))
			elseif spec:match("^[A-Za-z]+$") then
				row = row_number(spec)
				if not row or row > rows then return nil, S("Row is outside this inventory.") end
				for column = 1, width do
					if grid[(row - 1) * width + column] then add(row, column) end
				end
			elseif spec:match("^%d+$") then
				col = tonumber(spec)
				if col < 1 or col > width then return nil, S("Column is outside this inventory.") end
				for r = rows, 1, -1 do if grid[(r - 1) * width + col] then add(r, col) end end
			else return nil, S("Expected a slot, row, column, or rectangle: @1", spec) end
		end
		if invalid or #result == 0 then return nil, S("Target includes a slot outside this inventory.") end
		if reverse then
			for i = 1, math.floor(#result / 2) do
				local other = #result - i + 1
				result[i], result[other] = result[other], result[i]
			end
		end
		return result
	end

	function R.compile(text, options)
		options = options or {}
		if text == nil then text = "" end
		if type(text) ~= "string" or #text > R.limits.text then
			return nil, S("Sorting rules are limited to @1 bytes.", tostring(R.limits.text))
		end
		local size, width = options.size or 36, options.width or 9
		local grid, err = R.grid(size, width, options.player)
		if not grid then return nil, err end
		local compiled = { placements = {}, locked = {}, frozen = {}, fallback = {},
			size = size, width = width, player = not not options.player, text = text }
		local fallback_seen, count, lineno = {}, 0, 0
		local function fallback_add(slots)
			for _, slot in ipairs(slots) do
				if not fallback_seen[slot] then
					compiled.fallback[#compiled.fallback + 1], fallback_seen[slot] = slot, true
				end
			end
		end
		for line in (text .. "\n"):gmatch("([^\n]*)\n") do
			lineno = lineno + 1
			line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
			if line ~= "" then
				count = count + 1
				if count > R.limits.lines then return nil, S("At most @1 sorting rules are allowed.", tostring(R.limits.lines)) end
				local address, selector = line:match("^(%S+)%s+(.+)$")
				if not address then return nil, S("Rule line @1: expected TARGET SELECTOR.", tostring(lineno)) end
				local slots, target_err = target(address, grid, width)
				if not slots then return nil, S("Rule line @1: @2", tostring(lineno), target_err) end
				local special = selector:upper():gsub("^/", "")
				if special == "LOCKED" or special == "FROZEN" then
					for _, slot in ipairs(slots) do
						compiled.locked[slot] = true
						if special == "FROZEN" then compiled.frozen[slot] = true end
					end
				elseif special == "OTHER" then fallback_add(slots)
				else
					local predicate, selector_err = M.categories.selector(selector, options.categories)
					if not predicate then return nil, S("Rule line @1: @2", tostring(lineno), selector_err) end
					compiled.placements[#compiled.placements + 1] = { slots = slots, predicate = predicate,
						selector = selector, line = lineno }
				end
			end
		end
		fallback_add(grid)
		return compiled
	end
end
