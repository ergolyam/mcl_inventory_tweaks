-- SPDX-License-Identifier: MIT
-- Declarative, bounded item classification. Nothing entered here is executable.
return function(M)
	local S = M.S
	local core = M.core or core
	local C = {}
	M.categories = C

	local LIMIT = { text = 8192, lines = 64, expression = 1024,
		alternatives = 16, clauses = 16, atoms = 512, depth = 8 }
	C.limits = LIMIT

	local function trim(s)
		return (s:gsub("^%s+", ""):gsub("%s+$", ""))
	end

	local function split(s, delimiter)
		local out, start = {}, 1
		while true do
			local i = s:find(delimiter, start, true)
			out[#out + 1] = trim(s:sub(start, i and i - 1 or #s))
			if not i then return out end
			start = i + #delimiter
		end
	end

	local function identifier(s)
		return #s > 0 and #s <= 48 and s:match("^[a-z][a-z0-9_]*$") ~= nil
	end

	-- Luanti item names are byte strings. A small glob matcher avoids exposing
	-- Lua patterns or a backtracking regular-expression implementation to players.
	local function glob_match(pattern, value)
		local p, v, star, restart = 1, 1, nil, nil
		while v <= #value do
			local ch = pattern:sub(p, p)
			if ch == "?" or ch == value:sub(v, v) then
				p, v = p + 1, v + 1
			elseif ch == "*" then
				star, restart, p = p, v, p + 1
			elseif star then
				restart = restart + 1
				p, v = star + 1, restart
			else
				return false
			end
		end
		while pattern:sub(p, p) == "*" do p = p + 1 end
		return p > #pattern
	end

	local function atom(text)
		local negate = false
		if text:sub(1, 1) == "!" then
			negate, text = true, trim(text:sub(2))
		end
		if text == "" or #text > 192 or text:find("!", 1, true) then
			return nil, S("Invalid or empty selector.")
		end
		if text == "*" then return { kind = "all", negate = negate } end
		local prefix, value = text:match("^([a-z]+):(.*)$")
		if prefix == "group" then
			if #value == 0 or #value > 64 or not value:match("^[a-zA-Z0-9_]+$") then
				return nil, S("Invalid group name: @1", value)
			end
			return { kind = "group", value = value, negate = negate }
		elseif prefix == "type" then
			if value ~= "node" and value ~= "tool" and value ~= "craftitem" then
				return nil, S("Type must be node, tool, or craftitem.")
			end
			return { kind = "type", value = value, negate = negate }
		elseif prefix == "category" or not text:find(":", 1, true) then
			value = (prefix == "category" and value or text):lower()
			if not identifier(value) then return nil, S("Invalid category name: @1", value) end
			return { kind = "category", value = value, negate = negate }
		end
		-- Punctuation other than the two documented wildcards is rejected.
		if not text:match("^[a-z0-9_*?]+:[a-zA-Z0-9_*?]+$") then
			return nil, S("Expected an item name, group, type, category, or item glob: @1", text)
		end
		return { kind = (text:find("*", 1, true) or text:find("?", 1, true))
			and "glob" or "item", value = text, negate = negate }
	end

	local function expression(text, budget)
		if type(text) ~= "string" or #text == 0 or #text > LIMIT.expression then
			return nil, S("Selector must contain 1 to @1 bytes.", tostring(LIMIT.expression))
		end
		local alternatives = split(text, "|")
		if #alternatives > LIMIT.alternatives then return nil, S("Too many selector alternatives.") end
		local result = {}
		for _, alternative in ipairs(alternatives) do
			local clauses = split(alternative, "&")
			if #clauses > LIMIT.clauses then return nil, S("Too many selector clauses.") end
			local compiled = {}
			for _, clause in ipairs(clauses) do
				local entry, err = atom(clause)
				if not entry then return nil, err end
				budget.count = budget.count + 1
				if budget.count > LIMIT.atoms then return nil, S("Too many selectors in this configuration.") end
				compiled[#compiled + 1] = entry
			end
			result[#result + 1] = compiled
		end
		return result
	end

	-- The order is intentionally specific before broad. Mineclonia's actual
	-- declarative groups, not item-name fragments, define these categories.
	local builtins = {
		{ "sword", "group:sword" },
		{ "pickaxe", "group:pickaxe" },
		{ "axe", "group:axe" },
		{ "shovel", "group:shovel" },
		{ "hoe", "group:hoe" },
		{ "shears", "group:shears" },
		{ "weapon", "group:weapon" },
		{ "tool", "group:tool | type:tool & !group:armor & !group:horse_armor" },
		{ "armor", "group:armor | group:horse_armor" },
		{ "ammo", "group:ammo" },
		{ "potion", "group:_mcl_potion" },
		{ "food", "group:food & !group:_mcl_potion" },
		{ "torch", "group:torch" },
		{ "book", "group:book" },
		{ "dye", "group:dye" },
		{ "transport", "group:transport | group:boat | group:minecart | group:rail" },
		{ "container", "group:container | group:shulker_box" },
		{ "wood", "group:tree | group:wood | group:wood_slab | group:wood_stairs" },
		{ "stone", "group:stone | group:cobble | group:stonebrick | group:sandstone" },
		{ "plant", "group:plant | group:sapling | group:flower | group:seed" },
		{ "redstone", "group:redstone_wire | group:redstone_torch | group:button | group:pressure_plate | group:piston | group:hopper" },
		{ "building", "group:building_block" },
		{ "decoration", "group:deco_block" },
		{ "brewing", "group:brewitem | group:brewing_ingredient" },
		{ "crafting", "group:craftitem" },
		{ "blocks", "type:node" },
		{ "other", "*" },
	}
	C.builtins = {}
	for _, entry in ipairs(builtins) do C.builtins[#C.builtins + 1] = entry[1] end

	local evaluate
	local function match_category(entry, name, definition, compiled, memo)
		if memo[entry] ~= nil then return memo[entry] or nil end
		local rank = evaluate(entry.alternatives, name, definition, compiled, memo)
		memo[entry] = rank or false
		return rank
	end

	evaluate = function(alternatives, name, definition, compiled, memo)
		for subrank, clauses in ipairs(alternatives) do
			local matches = true
			for _, clause in ipairs(clauses) do
				local yes
				if clause.kind == "all" then yes = true
				elseif clause.kind == "item" then yes = name == clause.value
				elseif clause.kind == "glob" then yes = glob_match(clause.value, name)
				elseif clause.kind == "group" then
					local group = definition and definition.groups and definition.groups[clause.value]
					yes = type(group) == "number" and group > 0
				elseif clause.kind == "type" then
					yes = definition and definition.type == (clause.value == "craftitem" and "craft" or clause.value)
				elseif clause.kind == "category" then
					yes = match_category(compiled.by_name[clause.value], name, definition, compiled, memo) ~= nil
				end
				yes = not not yes
				if clause.negate then yes = not yes end
				if not yes then matches = false; break end
			end
			if matches then return subrank end
		end
	end

	local function validate_references(compiled)
		local visiting, depths = {}, {}
		local visit
		visit = function(entry)
			if visiting[entry] then return nil, S("Category cycle involving @1", entry.name) end
			if depths[entry] then return depths[entry] end
			visiting[entry] = true
			local depth = 1
			for _, clauses in ipairs(entry.alternatives) do
				for _, clause in ipairs(clauses) do
					if clause.kind == "category" then
						local target = compiled.by_name[clause.value]
						if not target then return nil, S("Unknown category: @1", clause.value) end
						local child, err = visit(target)
						if not child then return nil, err end
						depth = math.max(depth, child + 1)
						if depth > LIMIT.depth then return nil, S("Category nesting exceeds @1.", tostring(LIMIT.depth)) end
					end
				end
			end
			visiting[entry], depths[entry] = nil, depth
			return depth
		end
		for _, entry in ipairs(compiled.ordered) do
			local ok, err = visit(entry)
			if not ok then return nil, err end
		end
		return true
	end

	function C.compile(text)
		if text == nil then text = "" end
		if type(text) ~= "string" or #text > LIMIT.text then
			return nil, S("Category text is limited to @1 bytes.", tostring(LIMIT.text))
		end
		local compiled = { ordered = {}, by_name = {}, text = text }
		local reserved, budget = {}, { count = 0 }
		for _, entry in ipairs(builtins) do reserved[entry[1]] = true end
		local lineno, count = 0, 0
		for line in (text .. "\n"):gmatch("([^\n]*)\n") do
			lineno = lineno + 1
			line = trim((line:gsub("#.*$", "")))
			if line ~= "" then
				count = count + 1
				if count > LIMIT.lines then return nil, S("At most @1 custom categories are allowed.", tostring(LIMIT.lines)) end
				local name, spec = line:match("^([%w_]+)%s*=%s*(.-)%s*$")
				name = name and name:lower()
				if not name or not identifier(name) then return nil, S("Category line @1: expected name = selector.", tostring(lineno)) end
				if reserved[name] or compiled.by_name[name] then return nil, S("Category line @1: duplicate or reserved name @2.", tostring(lineno), name) end
				local alternatives, err = expression(spec, budget)
				if not alternatives then return nil, S("Category line @1: @2", tostring(lineno), err) end
				local entry = { name = name, alternatives = alternatives, line = lineno }
				compiled.ordered[#compiled.ordered + 1], compiled.by_name[name] = entry, entry
			end
		end
		for _, builtin in ipairs(builtins) do
			local entry = { name = builtin[1], alternatives = assert(expression(builtin[2], {count = 0})), builtin = true }
			compiled.ordered[#compiled.ordered + 1], compiled.by_name[entry.name] = entry, entry
		end
		local ok, err = validate_references(compiled)
		if not ok then return nil, err end
		return compiled
	end

	local default = assert(C.compile(""))
	C.default = default

	function C.selector(text, compiled)
		compiled = compiled or default
		if type(compiled) ~= "table" or type(compiled.by_name) ~= "table" then
			return nil, S("Invalid compiled categories.")
		end
		local alternatives, err = expression(text, { count = 0 })
		if not alternatives then return nil, err end
		for _, clauses in ipairs(alternatives) do
			for _, clause in ipairs(clauses) do
				if clause.kind == "category" and not compiled.by_name[clause.value] then
					return nil, S("Unknown category: @1", clause.value)
				end
			end
		end
		return function(stack, memo)
			if stack:is_empty() then return false end
			local name = stack:get_name()
			local subrank = evaluate(alternatives, name, core.registered_items[name], compiled, memo or {})
			return subrank ~= nil, subrank
		end
	end

	function C.rank(stack, compiled, memo)
		compiled, memo = compiled or default, memo or {}
		if stack:is_empty() then return math.huge, math.huge, "other" end
		local name = stack:get_name()
		local definition = core.registered_items[name]
		for rank, entry in ipairs(compiled.ordered) do
			local subrank = match_category(entry, name, definition, compiled, memo)
			if subrank then return rank, subrank, entry.name end
		end
		return math.huge, math.huge, "other"
	end
end
