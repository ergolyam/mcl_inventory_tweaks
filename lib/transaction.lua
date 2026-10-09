-- Synchronous, conservation-checked inventory transactions. No inventory
-- reference or destination is accepted from a formspec field.
return function(M)
local S = M.S
local core, U = M.core, M.util
local X = {undo_records = {}, blocked = {}, busy = {}}
M.transaction = X

local function physical_id(inv)
	local loc = inv:get_location()
	if loc.type == "player" or loc.type == "detached" then
		return loc.type .. ":" .. tostring(#loc.name) .. ":" .. loc.name
	elseif loc.type == "node" and loc.pos then
		return "node:" .. loc.pos.x .. "," .. loc.pos.y .. "," .. loc.pos.z
	end
	return nil
end

local function validate(player, endpoints)
	local ok, err = U.player_ok(player)
	if not ok then return false, err end
	local ids, physical, total = {}, {}, 0
	for _, ep in ipairs(endpoints) do
		if type(ep.id) ~= "string" or ids[ep.id] or not ep.inv or not ep.list then
			return false, S("The inventory adapter supplied an invalid or duplicate endpoint.")
		end
		ids[ep.id] = true
		local identity = physical_id(ep.inv)
		if not identity then return false, S("The inventory has no stable location.") end
		local physical_list = identity .. "/" .. #ep.list .. ":" .. ep.list
		if physical[physical_list] then return false, S("Two endpoints refer to the same inventory list.") end
		physical[physical_list] = true
		ep._physical_id = identity
		if X.blocked[ep.id] then return false, S("This inventory adapter is suspended after a callback error; consult the server log.") end
		if not ep.size or ep.size < 1 or ep.size ~= math.floor(ep.size) then return false, S("Invalid inventory size.") end
		total = total + ep.size
		if total > (M.config.max_slots or 512) then return false, S("This inventory exceeds the configured operation limit.") end
		local valid, result, reason = pcall(ep.validate, player)
		if not valid then
			U.log("error", "Adapter validation failed: " .. tostring(result))
			return false, S("The inventory adapter could not validate access.")
		end
		if not result then return false, reason or S("The inventory is no longer accessible.") end
		if ep.inv:get_size(ep.list) ~= ep.size then return false, S("The inventory size changed; reopen it.") end
	end
	return #endpoints > 0, S("No inventory was selected.")
end

local function snapshot(endpoints)
	local result = {}
	for i, ep in ipairs(endpoints) do
		local list = ep.inv:get_list(ep.list)
		if not list or #list ~= ep.size then return nil, S("The inventory is no longer available.") end
		result[i] = U.clone_list(list)
	end
	return result
end

local function unchanged(endpoints, expected)
	for i, ep in ipairs(endpoints) do
		if ep.inv:get_size(ep.list) ~= ep.size or not U.equal_list(ep.inv:get_list(ep.list), expected[i]) then return false end
	end
	return true
end

-- Retain items that stay in the same cell; route only the net surplus into
-- matching deficits. The flow graph also describes merges and full swaps.
local function flows(before, after)
	local sources, needs, source_order = {}, {}, {}
	for e, list in ipairs(before) do
		for i, old in ipairs(list) do
			local new = after[e][i]
			local keep = U.same(old, new) and math.min(old:get_count(), new:get_count()) or 0
			if old:get_count() > keep then
				local key = U.stack_key(old)
				if not sources[key] then sources[key] = {}; source_order[#source_order + 1] = key end
				sources[key][#sources[key] + 1] = {e = e, i = i, n = old:get_count() - keep, stack = old}
			end
			if new:get_count() > keep then
				local key = U.stack_key(new)
				needs[key] = needs[key] or {}
				needs[key][#needs[key] + 1] = {e = e, i = i, n = new:get_count() - keep}
			end
		end
	end
	local out = {}
	for _, key in ipairs(source_order) do
		local destinations, d = needs[key] or {}, 1
		for _, source in ipairs(sources[key]) do
			while source.n > 0 do
				local dest = destinations[d]
				if not dest then return nil, S("Unbalanced item flow.") end
				local n = math.min(source.n, dest.n)
				local stack = ItemStack(source.stack)
				stack:set_count(n)
				out[#out + 1] = {from = source.e, fi = source.i, to = dest.e, ti = dest.i, stack = stack, count = n}
				source.n, dest.n = source.n - n, dest.n - n
				if dest.n == 0 then d = d + 1 end
			end
		end
	end
	return out
end

local function info_copy(info)
	local out = {}
	for k, v in pairs(info) do out[k] = k == "stack" and ItemStack(v) or v end
	return out
end

local function callback_events(endpoints, graph)
	local events = {}
	for _, f in ipairs(graph) do
		local a, b = endpoints[f.from], endpoints[f.to]
		if a._physical_id == b._physical_id then
			events[#events + 1] = {ep = a, action = "move", count = f.count, info = {
				from_list = a.list, from_index = f.fi, to_list = b.list, to_index = f.ti, count = f.count,
			}}
		else
			events[#events + 1] = {ep = a, action = "take", count = f.count, info = {listname = a.list, index = f.fi, stack = f.stack}}
			events[#events + 1] = {ep = b, action = "put", count = f.count, info = {listname = b.list, index = f.ti, stack = f.stack}}
		end
	end
	return events
end

local function finite_inventory(player, event)
	local ep, info = event.ep, event.info
	-- Mineclonia's creative 64-stack callback expands external puts to a full
	-- stack. Reject before writing; switching the native selector to 1 restores
	-- finite transfers. This also protects undo after a creative deposit.
	if ep.kind == "player" and event.action == "put" and info.listname == "main"
		and core.is_creative_enabled(player:get_player_name())
		and player:get_meta():get_int("mcl_inventory:switch_stack") ~= 1 then
		return false, S("Set Mineclonia's creative stack-size button to 1 before moving storage items into your inventory.")
	end
	return true
end

local function permission(player, event)
	local ep, info = event.ep, event.info
	local function check(callback, ...)
		local ok, value = pcall(callback, ...)
		if not ok then
			U.log("error", "Permission callback for " .. ep.id .. " failed: " .. tostring(value))
			return false, S("An inventory permission callback failed; nothing was moved.")
		end
		if value == nil then return true end
		-- -1 means infinite/virtual stock in the engine. It cannot safely be
		-- reinterpreted as an ordinary finite transfer by this mod.
		if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge
			or value ~= math.floor(value) or value < event.count then
			return false, S("An inventory permission callback refused this operation.")
		end
		return true
	end
	if ep.kind == "player" then
		-- Deliberately honor every restrictive callback. The native engine's
		-- first non-nil return must not hide a later protection mod's refusal.
		for _, callback in ipairs(core.registered_allow_player_inventory_actions or {}) do
			local ok, err = check(callback, player, event.action, ep.inv, info_copy(info))
			if not ok then return false, err end
		end
	elseif ep.allow then
		return check(ep.allow, player, event.action, info_copy(info))
	else
		return false, S("This inventory has no permission adapter.")
	end
	return true
end

local function notify(player, events, endpoints)
	local problems = false
	local function call(ep, callback, ...)
		local ok, err = pcall(callback, ...)
		if not ok then
			problems = true
			X.blocked[ep.id] = true
			U.log("error", "Post-commit callback for " .. ep.id .. " failed: " .. tostring(err))
		end
	end
	for _, event in ipairs(events) do
		local ep = event.ep
		if ep.kind == "player" then
			for _, callback in ipairs(core.registered_on_player_inventory_actions or {}) do
				call(ep, callback, player, event.action, ep.inv, info_copy(event.info))
			end
		elseif ep.on then
			call(ep, ep.on, player, event.action, info_copy(event.info))
		end
	end
	local notified = {}
	for _, ep in ipairs(endpoints) do
		if ep.after_commit and not notified[ep._physical_id] then
			call(ep, ep.after_commit, player)
			notified[ep._physical_id] = true
		end
	end
	return problems
end

local function commit_inner(player, endpoints, desired, opts)
	local ok, err = validate(player, endpoints)
	if not ok then return false, err end
	local settings = M.preferences and M.preferences.get(player)
	local settings_error = M.preferences and M.preferences.recovery and M.preferences.recovery[player:get_player_name()]
	if settings_error then return false, settings_error end
	local before
	before, err = snapshot(endpoints)
	if not before then return false, err end
	if type(desired) ~= "table" or #desired ~= #before then return false, S("Invalid inventory plan.") end
	local after, changed = {}, false
	for e, list in ipairs(before) do
		if type(desired[e]) ~= "table" or #desired[e] ~= #list then return false, S("Inventory plans must preserve every list size.") end
		after[e] = U.clone_list(desired[e])
		for i, stack in ipairs(after[e]) do
			if not stack:equals(list[i]) then
				changed = true
				if not U.is_safe_stack(stack) or not U.is_safe_stack(list[i]) then
					return false, S("Unknown or oversized stacks must stay in their original slots.")
				end
			end
		end
	end
	if not changed then return true, false end
	ok, err = U.conserved(before, after)
	if not ok then return false, err end
	local graph
	graph, err = flows(before, after)
	if not graph then return false, err end
	local events = callback_events(endpoints, graph)
	-- Reject known virtual/infinite inventory behavior before invoking any
	-- third-party callback, including a source container's allow-take hook.
	for _, event in ipairs(events) do
		ok, err = finite_inventory(player, event)
		if not ok then return false, err end
	end
	for _, event in ipairs(events) do
		ok, err = permission(player, event)
		if not ok then return false, err end
	end
	-- Allow callbacks are arbitrary Lua and can mutate inventories or remove
	-- nodes. Never write the old plan over such synchronous side effects.
	ok, err = validate(player, endpoints)
	if not ok then return false, err end
	if not unchanged(endpoints, before) then return false, S("An inventory changed during permission checks; nothing was overwritten.") end
	if M.preferences then
		if M.preferences.get(player) ~= settings then
			return false, S("Your settings changed during permission checks; no items were moved.")
		end
		settings_error = M.preferences.recovery and M.preferences.recovery[player:get_player_name()]
		if settings_error then return false, settings_error end
	end
	-- Permission callbacks can change game mode or creative settings without
	-- touching items. Recheck that the same finite-transfer policy still holds.
	for _, event in ipairs(events) do
		ok, err = finite_inventory(player, event)
		if not ok then return false, err end
	end
	if M.refill then M.refill.cancel(player) end
	local name = player:get_player_name()
	X.undo_records[name] = nil
	-- No callbacks, deferred work or yields occur between these writes. On an
	-- exceptional adapter write failure, restore only our own untouched writes
	-- before notifying any external callback.
	for e, ep in ipairs(endpoints) do
		local wrote, error_text = pcall(ep.inv.set_list, ep.inv, ep.list, after[e])
		if not wrote or not U.equal_list(ep.inv:get_list(ep.list), after[e]) then
			local restored = true
			for j = 1, e do
				local previous = endpoints[j]
				local current = previous.inv:get_list(previous.list)
				if U.equal_list(current, after[j]) or U.equal_list(current, before[j]) then
					local success = pcall(previous.inv.set_list, previous.inv, previous.list, before[j])
					restored = success and U.equal_list(previous.inv:get_list(previous.list), before[j]) and restored
				else restored = false end
				X.blocked[previous.id] = true
			end
			U.log("error", "Inventory write failed at " .. ep.id .. "; restored=" .. tostring(restored) .. ": " .. tostring(error_text))
			return false, restored and S("The write failed and the original inventory was restored.")
				or S("An inventory adapter failed during writing. Stop using this inventory and check the server log.")
		end
	end
	local problems = notify(player, events, endpoints)
	if not unchanged(endpoints, after) then
		problems = true
		for _, ep in ipairs(endpoints) do X.blocked[ep.id] = true end
		U.log("warning", "An external callback changed a committed inventory; undo disabled and adapters suspended for " .. name)
	end
	if not problems and opts.undo ~= false and M.config.enable_undo ~= false then
		X.undo_records[name] = {endpoints = endpoints, before = before, after = after, time = U.now(), reason = opts.reason}
	end
	if opts.reason and not opts.quiet then U.log("action", name .. ": " .. opts.reason) end
	return true, true, problems and S("Items moved, but an external callback failed or changed the result. Undo was disabled; consult the server log.") or nil
end

function X.commit(player, endpoints, desired, opts)
	opts = opts or {}
	local name = player and player:get_player_name() or ""
	if X.busy[name] then return false, S("An inventory operation is already running.") end
	X.busy[name] = true
	local ok, success, detail, warning = pcall(commit_inner, player, endpoints, desired, opts)
	X.busy[name] = nil
	if not ok then
		U.log("error", "Inventory operation failed: " .. tostring(success))
		return false, S("An inventory adapter failed. See the server log for details.")
	end
	return success, detail, warning
end

function X.undo(player)
	local name = player:get_player_name()
	local record = X.undo_records[name]
	if not record then return false, S("There is no unchanged operation to undo.") end
	if U.now() - record.time > 120 then
		X.undo_records[name] = nil
		return false, S("Undo expired after two minutes.")
	end
	if not unchanged(record.endpoints, record.after) then
		X.undo_records[name] = nil
		return false, S("The inventory changed after that operation; undo would overwrite newer changes.")
	end
	local ok, changed, warning = X.commit(player, record.endpoints, record.before, {reason = "undo", undo = false})
	if ok then X.undo_records[name] = nil end
	return ok, changed, warning
end

function X.clear(player)
	X.undo_records[player:get_player_name()] = nil
end

core.register_on_leaveplayer(X.clear)
core.register_on_dieplayer(X.clear)
end
