-- SPDX-License-Identifier: MIT
-- Pure inventory plans. Actual writes and native callback checks live in transaction.lua.
return function(M)
	local S = M.S
	local U, Sorting = M.util, {}
	M.sorting = Sorting
	local MAX_SLOTS = 512
	local layouts = { compact = true, columns = true, merge = true }
	local orders = { category = true, name = true, count = true, wear = true }

	local function integer(n, low, high)
		return type(n) == "number" and n == math.floor(n) and n >= low and n <= high
	end

	local function list_size(list)
		if type(list) ~= "table" then return nil, S("Inventory must be a list.") end
		local size = #list
		if size > MAX_SLOTS then return nil, S("Inventory exceeds @1 slots.", tostring(MAX_SLOTS)) end
		for key in pairs(list) do
			if not integer(key, 1, size) then return nil, S("Inventory list must be a dense array.") end
		end
		for i = 1, size do
			if list[i] == nil then return nil, S("Inventory list must be a dense array.") end
			local ok, result = pcall(ItemStack, list[i])
			if not ok or not result then return nil, S("Invalid item stack at slot @1.", tostring(i)) end
		end
		return size
	end

	local function slot_order(given, size)
		if given == nil then
			local result = {}
			for i = 1, size do result[i] = i end
			return result
		end
		if type(given) ~= "table" or #given > size then return nil, S("Invalid slot order.") end
		local result, seen = {}, {}
		for key in pairs(given) do
			if not integer(key, 1, #given) then return nil, S("Slot order must be a dense array.") end
		end
		for position = 1, #given do
			local index = given[position]
			if not integer(index, 1, size) or seen[index] then return nil, S("Slot order contains an invalid or repeated index.") end
			result[#result + 1], seen[index] = index, true
		end
		return result
	end

	local function copy_locks(set, size, result)
		if set == nil then return true end
		if type(set) ~= "table" then return nil, S("Protected slots must be a set.") end
		for index, locked in pairs(set) do
			if not integer(index, 1, size) then return nil, S("Protected slot is outside this inventory.") end
			if locked then result[index] = true end
		end
		return true
	end

	local function stack_with_count(sample, count)
		local result = ItemStack(sample)
		result:set_count(count)
		return result
	end

	local function safe(stack)
		return U.is_safe_stack(stack)
	end

	local function records(before, slots, fixed, categories)
		local ordered, by_key = {}, {}
		for _, slot in ipairs(slots) do
			local stack = before[slot]
			if not fixed[slot] and not stack:is_empty() then
				local key = U.stack_key(stack)
				local record = by_key[key]
				if not record then
					local memo = {}
					local rank, subrank = M.categories.rank(stack, categories, memo)
					record = { key = key, sample = ItemStack(stack), total = 0, remaining = 0,
						maximum = stack:get_stack_max(), positions = {}, name = stack:get_name(),
						wear = stack:get_wear(), rank = rank, subrank = subrank, memo = memo }
					ordered[#ordered + 1], by_key[key] = record, record
				end
				record.total = record.total + stack:get_count()
				record.remaining = record.total
				record.positions[#record.positions + 1] = slot
			end
		end
		return ordered
	end

	local function comparator(order)
		return function(a, b)
			if order == "category" then
				if a.rank ~= b.rank then return a.rank < b.rank end
				if a.subrank ~= b.subrank then return a.subrank < b.subrank end
			elseif order == "count" and a.total ~= b.total then return a.total > b.total
			elseif order == "wear" and a.wear ~= b.wear then return a.wear < b.wear end
			if a.name ~= b.name then return a.name < b.name end
			if a.wear ~= b.wear then return a.wear < b.wear end
			return a.key < b.key
		end
	end

	local function traversal(slots, width, columns)
		if not columns then return slots end
		local result = {}
		for col = 1, width do
			for row = 0, math.ceil(#slots / width) - 1 do
				local slot = slots[row * width + col]
				if slot then result[#result + 1] = slot end
			end
		end
		return result
	end

	-- Give each identity complete columns when there is enough room. The
	-- trial never changes records or the output. A crowded inventory falls back
	-- to column-first compaction, rather than losing any items.
	local function band_destinations(groups, slots, width, free)
		local bands = {}
		for col = 1, width do
			local band = {}
			for row = 0, math.ceil(#slots / width) - 1 do
				local slot = slots[row * width + col]
				if slot and free[slot] then band[#band + 1] = slot end
			end
			if #band > 0 then bands[#bands + 1] = band end
		end
		local result, band_index = {}, 1
		for _, group in ipairs(groups) do
			local needed = math.ceil(group.remaining / group.maximum)
			if needed > 0 then
				local destinations = {}
				while needed > 0 do
					local band = bands[band_index]
					if not band then return nil end
					band_index = band_index + 1
					for _, slot in ipairs(band) do
						if needed == 0 then break end
						destinations[#destinations + 1], needed = slot, needed - 1
					end
				end
				result[#result + 1] = { group = group, slots = destinations }
			end
		end
		return result
	end

	function Sorting.plan(list, options)
		options = options or {}
		local size, err = list_size(list)
		if not size then return nil, err end
		local layout, order = options.layout or "compact", options.order or "category"
		if not layouts[layout] or not orders[order] then return nil, S("Unknown sorting layout or order.") end
		local width = options.width or 9
		if not integer(width, 1, 32) then return nil, S("Invalid inventory width.") end
		local slots, slot_err = slot_order(options.slots, size)
		if not slots then return nil, slot_err end
		local before, result = U.clone_list(list), U.clone_list(list)
		local fixed, selected = {}, {}
		local ok, lock_err = copy_locks(options.locked, size, fixed)
		if not ok then return nil, lock_err end
		local rules = options.rules
		if rules then
			if type(rules) ~= "table" or rules.size ~= size or rules.width ~= width
				or type(rules.placements) ~= "table" or type(rules.fallback) ~= "table" then
				return nil, S("Sorting rules do not match this inventory.")
			end
			ok, lock_err = copy_locks(rules.locked, size, fixed)
			if not ok then return nil, lock_err end
			ok, lock_err = copy_locks(rules.frozen, size, fixed)
			if not ok then return nil, lock_err end
		end
		for _, slot in ipairs(slots) do
			selected[slot] = true
			if not safe(before[slot]) then fixed[slot] = true end
		end
		local groups = records(before, slots, fixed, options.categories)
		if layout == "merge" then
			for _, group in ipairs(groups) do
				for _, slot in ipairs(group.positions) do
					local count = math.min(group.remaining, group.maximum)
					result[slot] = stack_with_count(group.sample, count)
					group.remaining = group.remaining - count
				end
			end
			if not U.conserved({before}, {result}) then return nil, S("Stack compaction failed its item-conservation check.") end
			return result
		end
		local compare = comparator(order)
		table.sort(groups, compare)
		local free = {}
		for _, slot in ipairs(slots) do
			if not fixed[slot] then result[slot], free[slot] = ItemStack(""), true end
		end
		local function place(group, slot)
			local count = math.min(group.remaining, group.maximum)
			result[slot], free[slot] = stack_with_count(group.sample, count), nil
			group.remaining = group.remaining - count
		end
		if rules then
			for _, rule in ipairs(rules.placements) do
				local candidates = {}
				for _, group in ipairs(groups) do
					if group.remaining > 0 then
						local matches, subrank = rule.predicate(group.sample, group.memo)
						if matches then candidates[#candidates + 1] = { group = group, rank = subrank or 1 } end
					end
				end
				table.sort(candidates, function(a, b)
					if a.rank ~= b.rank then return a.rank < b.rank end
					return compare(a.group, b.group)
				end)
				local candidate = 1
				for _, slot in ipairs(rule.slots) do
					if selected[slot] and free[slot] then
						while candidates[candidate] and candidates[candidate].group.remaining == 0 do candidate = candidate + 1 end
						if not candidates[candidate] then break end
						place(candidates[candidate].group, slot)
					end
				end
			end
		end
		local bands
		if layout == "columns" then
			bands = band_destinations(groups, slots, width, free)
		end
		if bands then
			for _, band in ipairs(bands) do
				for _, slot in ipairs(band.slots) do place(band.group, slot) end
			end
		else
			local destinations, seen = {}, {}
			local function append(indices)
				for _, slot in ipairs(indices) do
					if free[slot] and not seen[slot] then
						destinations[#destinations + 1], seen[slot] = slot, true
					end
				end
			end
			-- Explicit fallback addresses are respected for compact sorting.
			-- The column button keeps its visible geometric meaning.
			if layout == "compact" and rules then append(rules.fallback) end
			append(traversal(slots, width, layout == "columns"))
			local destination = 1
			for _, group in ipairs(groups) do
				while group.remaining > 0 do
					local slot = destinations[destination]
					if not slot then return nil, S("There is not enough space for a safe sorting plan.") end
					place(group, slot)
					destination = destination + 1
				end
			end
		end
		if not U.conserved({before}, {result}) then return nil, S("Sorting failed its item-conservation check.") end
		return result
	end

	function Sorting.transfer(source, target, options)
		options = options or {}
		if source == target then return nil, S("Source and destination must be different inventories.") end
		local source_size, err = list_size(source)
		if not source_size then return nil, err end
		local target_size, target_err = list_size(target)
		if not target_size then return nil, target_err end
		local from_slots, from_err = slot_order(options.source_slots, source_size)
		if not from_slots then return nil, from_err end
		local to_slots, to_err = slot_order(options.target_slots, target_size)
		if not to_slots then return nil, to_err end
		local source_locked, target_locked = {}, {}
		local ok, lock_err = copy_locks(options.source_locked, source_size, source_locked)
		if not ok then return nil, lock_err end
		ok, lock_err = copy_locks(options.target_locked, target_size, target_locked)
		if not ok then return nil, lock_err end
		local before_from, before_to = U.clone_list(source), U.clone_list(target)
		local from, to = U.clone_list(before_from), U.clone_list(before_to)
		local existing = {}
		if options.matching then
			for _, stack in ipairs(to) do
				if not stack:is_empty() then existing[U.stack_key(stack)] = true end
			end
		end
		local moved = 0
		for _, from_index in ipairs(from_slots) do
			local stack = from[from_index]
			if not source_locked[from_index] and not stack:is_empty() and safe(stack)
				and (not options.matching or existing[U.stack_key(stack)]) then
				local remaining = stack:get_count()
				-- Fill every compatible partial stack before occupying an empty cell.
				for _, to_index in ipairs(to_slots) do
					if remaining == 0 then break end
					local destination = to[to_index]
					if not target_locked[to_index] and not destination:is_empty() and safe(destination)
						and U.same(stack, destination) then
						local count = math.min(remaining, destination:get_stack_max() - destination:get_count())
						if count > 0 then
							destination:set_count(destination:get_count() + count)
							remaining, moved = remaining - count, moved + count
						end
					end
				end
				if not options.fill_only then
					for _, to_index in ipairs(to_slots) do
						if remaining == 0 then break end
						if not target_locked[to_index] and to[to_index]:is_empty() then
							local count = math.min(remaining, stack:get_stack_max())
							to[to_index] = stack_with_count(stack, count)
							remaining, moved = remaining - count, moved + count
						end
					end
				end
				stack:set_count(remaining)
			end
		end
		if not U.conserved({before_from, before_to}, {from, to}) then return nil, S("Transfer failed its item-conservation check.") end
		return from, to, moved
	end
end
