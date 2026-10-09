-- Public actions accept live server contexts. All mutations use transactions.
return function(M)
local S = M.S
local core, U = M.core, M.util
local A = {last_action = {}}
M.actions = A
local valid_layout = {compact = true, columns = true, merge = true}

function A.gate(player)
	local ok, err = U.player_ok(player)
	if not ok then return false, err end
	M.preferences.get(player)
	local recovery = M.preferences.recovery and M.preferences.recovery[player:get_player_name()]
	if recovery then return false, recovery end
	local name, now = player:get_player_name(), U.now()
	if A.last_action[name] and now - A.last_action[name] < (M.config.cooldown or 0.15) then
		return false, S("Please wait a moment before the next inventory action.")
	end
	A.last_action[name] = now
	return true
end

function A.player_endpoint(player, list)
	list = list or "main"
	assert(list == "main" or list == "enderchest", "Only player storage lists are supported")
	local name = player:get_player_name()
	local inv = player:get_inventory()
	local size = list == "main" and 36 or 27
	return {
		id = "player:" .. name .. "/" .. list, inventory_id = "player:" .. name,
		kind = "player", inv = inv, list = list, owner = name, size = size,
		validate = function(actor)
			if actor ~= core.get_player_by_name(name) or actor:get_player_name() ~= name then return false, S("The player inventory is no longer available.") end
			local loc = inv:get_location()
			if loc.type ~= "player" or loc.name ~= name or inv:get_size(list) ~= size then return false, S("Unexpected player inventory layout.") end
			return U.player_ok(actor)
		end,
	}
end

local function result(player, endpoints, after, reason, message)
	local ok, changed, warning = M.transaction.commit(player, endpoints, after, {reason = reason})
	if not ok then return false, changed end
	if warning then return true, warning end
	if not changed then return true, S("Already organized; no items moved.") end
	return true, message or S("Inventory organized.")
end

function A.sort_player(player, layout)
	local ok, err = A.gate(player)
	if not ok then return false, err end
	local prefs = M.preferences.get(player)
	local profile = prefs.profiles[prefs.active]
	layout = layout or profile.layout
	if not valid_layout[layout] then return false, S("Unknown sorting mode.") end
	local cfg
	cfg, err = M.preferences.compile(player)
	if not cfg then return false, err end
	local locks
	locks, err = M.preferences.locks(player, "sort")
	if not locks then return false, err end
	local ep = A.player_endpoint(player)
	if ep.inv:get_size(ep.list) ~= ep.size then return false, S("Inventory Tweaks expects Mineclonia's 36-slot player inventory.") end
	local after
	after, err = M.sorting.plan(ep.inv:get_list(ep.list), {
		width = 9, slots = M.rules.grid(36, 9, true), layout = layout,
		order = profile.order, locked = locks, rules = cfg.rules, categories = cfg.categories,
	})
	if not after then return false, err end
	return result(player, {ep}, {after}, "sort player " .. layout)
end

local function context(player, ctx)
	if not ctx or not M.integration then return false, S("Open a supported storage container first.") end
	return M.integration.context_valid(player, ctx)
end

local function flatten(endpoints)
	local out = {}
	for _, ep in ipairs(endpoints) do
		local list = ep.inv:get_list(ep.list)
		if not list or #list ~= ep.size then return nil, S("The container changed; reopen it.") end
		for _, stack in ipairs(list) do out[#out + 1] = ItemStack(stack) end
	end
	return out
end

local function split(list, endpoints)
	local out, offset = {}, 0
	for e, ep in ipairs(endpoints) do
		out[e] = {}
		for i = 1, ep.size do out[e][i] = ItemStack(list[offset + i]) end
		offset = offset + ep.size
	end
	return out
end

function A.container_config(player, size)
	local cfg, err = M.preferences.compile(player)
	if not cfg then return nil, err end
	local prefs = M.preferences.get(player)
	local profile = prefs.profiles[prefs.active]
	local text = size > 27 and profile.large_container_rules or profile.container_rules
	local rules
	rules, err = M.rules.compile(text or "", {size = size, width = 9, player = false, categories = cfg.categories})
	if not rules then return nil, err end
	local locks = U.copy(rules.locked)
	for i in pairs(rules.frozen) do locks[i] = true end
	return {rules = rules, locked = locks, categories = cfg.categories, order = profile.order}
end

function A.sort_container(player, ctx, layout)
	local ok, err = A.gate(player)
	if not ok then return false, err end
	ok, err = context(player, ctx)
	if not ok then return false, err end
	local prefs = M.preferences.get(player)
	layout = layout or prefs.profiles[prefs.active].layout
	if not valid_layout[layout] then return false, S("Unknown sorting mode.") end
	local before
	before, err = flatten(ctx.endpoints)
	if not before then return false, err end
	local cfg
	cfg, err = A.container_config(player, #before)
	if not cfg then return false, err end
	local after
	after, err = M.sorting.plan(before, {
		width = 9, slots = M.rules.grid(#before, 9, false), layout = layout,
		order = cfg.order, locked = cfg.locked, rules = cfg.rules, categories = cfg.categories,
	})
	if not after then return false, err end
	return result(player, ctx.endpoints, split(after, ctx.endpoints), "sort container " .. layout, S("Container organized."))
end

function A.transfer(player, ctx, action)
	if M.config.enable_transfers == false then return false, S("Bulk transfers are disabled by this server.") end
	local modes = {deposit_all = true, deposit_matching = true, take_all = true, take_matching = true, restock = true}
	if not modes[action] then return false, S("Unknown transfer action.") end
	local ok, err = A.gate(player)
	if not ok then return false, err end
	ok, err = context(player, ctx)
	if not ok then return false, err end
	local ep = A.player_endpoint(player)
	local player_list = ep.inv:get_list(ep.list)
	if not player_list or #player_list ~= 36 then return false, S("Unexpected player inventory layout.") end
	local storage
	storage, err = flatten(ctx.endpoints)
	if not storage then return false, err end
	local cfg
	cfg, err = A.container_config(player, #storage)
	if not cfg then return false, err end
	local player_locks
	player_locks, err = M.preferences.locks(player, action == "restock" and "refill" or "transfer")
	if not player_locks then return false, err end
	local deposit = action == "deposit_all" or action == "deposit_matching"
	local source, target = deposit and player_list or storage, deposit and storage or player_list
	local source_locks, target_locks = deposit and player_locks or cfg.locked, deposit and cfg.locked or player_locks
	local src, dst, moved = M.sorting.transfer(source, target, {
		source_locked = source_locks, target_locked = target_locks,
		source_slots = M.rules.grid(#source, 9, deposit), target_slots = M.rules.grid(#target, 9, not deposit),
		matching = action == "deposit_matching" or action == "take_matching",
		fill_only = action == "restock",
	})
	if not src then return false, dst end
	local endpoints = {ep}
	for _, target_ep in ipairs(ctx.endpoints) do endpoints[#endpoints + 1] = target_ep end
	local after = {deposit and src or dst}
	for _, list in ipairs(split(deposit and dst or src, ctx.endpoints)) do after[#after + 1] = list end
	return result(player, endpoints, after, action, S("@1 items moved. Items that did not fit stayed in place.", tostring(moved)))
end

-- Top up occupied hotbar cells from the backpack. A manual refill never
-- guesses which item belongs in an empty slot and never alters a frozen cell.
function A.refill_hotbar(player)
	local ok, err = A.gate(player)
	if not ok then return false, err end
	local locked
	locked, err = M.preferences.locks(player, "refill")
	if not locked then return false, err end
	local ep = A.player_endpoint(player)
	local list = ep.inv:get_list("main")
	if not list or #list ~= 36 then return false, S("Unexpected player inventory layout.") end
	local source, target, sl, tl = {}, {}, {}, {}
	for i = 1, 9 do target[i] = ItemStack(list[i]); tl[i] = locked[i] end
	for i = 10, 36 do source[i - 9] = ItemStack(list[i]); sl[i - 9] = locked[i] end
	local src, dst, moved = M.sorting.transfer(source, target, {source_locked = sl, target_locked = tl, fill_only = true})
	if not src then return false, dst end
	local after = U.clone_list(list)
	for i = 1, 9 do after[i] = dst[i] end
	for i = 10, 36 do after[i] = src[i - 9] end
	return result(player, {ep}, {after}, "refill hotbar", S("@1 items moved into existing hotbar stacks.", tostring(moved)))
end

-- Equalize existing compatible stacks without changing their positions.
function A.balance(player)
	local ok, err = A.gate(player)
	if not ok then return false, err end
	local locked
	locked, err = M.preferences.locks(player, "sort")
	if not locked then return false, err end
	local ep = A.player_endpoint(player)
	local list = ep.inv:get_list("main")
	if not list or #list ~= 36 then return false, S("Unexpected player inventory layout.") end
	local after, groups = U.clone_list(list), {}
	for i, stack in ipairs(list) do
		if not locked[i] and not stack:is_empty() and U.is_safe_stack(stack) then
			local key = U.stack_key(stack)
			groups[key] = groups[key] or {slots = {}, count = 0}
			local group = groups[key]
			group.slots[#group.slots + 1] = i
			group.count = group.count + stack:get_count()
		end
	end
	for _, group in pairs(groups) do
		local n = #group.slots
		local base, extra = math.floor(group.count / n), group.count % n
		for j, index in ipairs(group.slots) do after[index]:set_count(base + (j <= extra and 1 or 0)) end
	end
	return result(player, {ep}, {after}, "balance backpack stacks", S("Existing compatible stacks balanced."))
end

function A.undo(player)
	local ok, err = A.gate(player)
	if not ok then return false, err end
	local changed, warning
	ok, changed, warning = M.transaction.undo(player)
	return ok, ok and (warning or S("Last operation undone.")) or changed
end

core.register_on_leaveplayer(function(player) A.last_action[player:get_player_name()] = nil end)
end
