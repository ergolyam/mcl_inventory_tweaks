-- Event-driven replacement. An empty slot without a witnessed use is never
-- sufficient evidence. This module never repairs or creates an item.
return function(M)
local core, U = M.core, M.util
local R = {generation = {}, pending = {}, hud = {}, sequence = 0}
M.refill = R

local function pack(...)
	return {n = select("#", ...), ...}
end

function R.cancel(player)
	if not player or not player.get_player_name then return end
	local name = player:get_player_name()
	R.generation[name] = (R.generation[name] or 0) + 1
	R.pending[name] = nil
end

local function usable(player)
	return M.config.enable_refill ~= false and U.player_ok(player)
		and not core.is_creative_enabled(player:get_player_name())
end

function R.begin(player, before)
	if not usable(player) then return nil end
	local prefs = M.preferences.get(player)
	if not prefs.auto_refill and not prefs.repair_switch then return nil end
	local inv = player:get_inventory()
	if inv:get_size("main") ~= 36 then return nil end
	local index = player:get_wield_index()
	if index < 1 or index > 9 then return nil end
	before = ItemStack(before or player:get_wielded_item())
	if before:is_empty() or not U.is_safe_stack(before) then return nil end
	-- Offhand/custom use callbacks must not refill the selected main slot.
	if not U.same(before, inv:get_stack("main", index)) then return nil end
	local name = player:get_player_name()
	R.sequence = R.sequence + 1
	return {name = name, index = index, before = before, generation = R.generation[name] or 0, sequence = R.sequence, time = U.now()}
end

local function is_tool(stack)
	return not stack:is_empty() and stack:get_definition().type == "tool"
end

local function needs_work(prefs, before, after, residue)
	if after:is_empty() then
		return prefs.auto_refill and (not is_tool(before) or prefs.refill_tools), "depleted"
	elseif residue and after:equals(residue) and not U.same(before, after) then
		return prefs.auto_refill, "returned_container"
	elseif prefs.repair_switch and is_tool(after) and after:get_wear() > before:get_wear()
		and after:get_wear() >= prefs.repair_threshold * 65535 / 100 then
		return true, "repair"
	end
	return false
end

function R.finish(player, ticket, after)
	if not ticket or not usable(player) then return false end
	if ticket.name ~= player:get_player_name() or ticket.index ~= player:get_wield_index()
		or ticket.generation ~= (R.generation[ticket.name] or 0) then return false end
	local ok, stack = pcall(ItemStack, after)
	if not ok then return false end
	local needed, kind = needs_work(M.preferences.get(player), ticket.before, stack, ticket.residue)
	if not needed then return false end
	local list = player:get_inventory():get_list("main")
	if not list or #list ~= 36 then return false end
	ticket.expected = U.clone_list(list)
	ticket.expected[ticket.index] = ItemStack(stack)
	ticket.kind = kind
	R.pending[ticket.name] = ticket
	core.after(0, function() R.process(ticket) end)
	return true
end

local function family(stack)
	for _, group in ipairs({"pickaxe", "sword", "axe", "shovel", "hoe", "shears"}) do
		if core.get_item_group(stack:get_name(), group) > 0 then return group end
	end
	return nil
end

local function choose(player, ticket, list, frozen, cfg, prefs)
	local original = ticket.kind == "repair" and list[ticket.index] or ticket.before
	local tool = is_tool(original)
	local original_key = M.tool_identity.key(original)
	local original_family = prefs.tool_fallback and tool and family(original)
	local candidates = {}
	for i = 10, 36 do
		local stack = list[i]
		if not frozen[i] and not stack:is_empty() and U.is_safe_stack(stack) and cfg.refill_filter(stack) then
			local exact = M.tool_identity.key(stack) == original_key
			local fallback = ticket.kind ~= "repair" and original_family and is_tool(stack) and family(stack) == original_family
			local healthy = ticket.kind ~= "repair" or (stack:get_wear() < prefs.repair_threshold * 65535 / 100 and stack:get_wear() < original:get_wear())
			if (exact or fallback) and healthy then
				candidates[#candidates + 1] = {index = i, exact = exact, wear = stack:get_wear(), count = stack:get_count()}
			end
		end
	end
	table.sort(candidates, function(a, b)
		if a.exact ~= b.exact then return a.exact end
		-- Consume a small spare stack first; use a worn spare tool first. A
		-- repair switch excludes every spare already at the warning threshold.
		if tool and a.wear ~= b.wear then return a.wear > b.wear end
		if not tool and a.count ~= b.count then return a.count < b.count end
		return a.index < b.index
	end)
	return candidates[1] and candidates[1].index
end

function R.process(ticket)
	if not ticket or R.pending[ticket.name] ~= ticket then return false end
	R.pending[ticket.name] = nil
	local player = core.get_player_by_name(ticket.name)
	if not usable(player) or player:get_wield_index() ~= ticket.index
		or (R.generation[ticket.name] or 0) ~= ticket.generation or U.now() - ticket.time > 2 then return false end
	local prefs = M.preferences.get(player)
	local list = player:get_inventory():get_list("main")
	if not U.equal_list(list, ticket.expected) then return false end
	local needed, kind = needs_work(prefs, ticket.before, list[ticket.index], ticket.residue)
	if not needed or kind ~= ticket.kind then return false end
	local cfg = M.preferences.compile(player)
	if not cfg or not cfg.refill_filter(ticket.before) then return false end
	local frozen = M.preferences.locks(player, "refill")
	if not frozen or frozen[ticket.index] then return false end
	local source = choose(player, ticket, list, frozen, cfg, prefs)
	if not source then return false end
	local after = U.clone_list(list)
	after[ticket.index] = ItemStack(list[source])
	after[source] = ItemStack(list[ticket.index])
	local ok, changed = M.transaction.commit(player, {M.actions.player_endpoint(player)}, {after}, {
		reason = "automatic " .. ticket.kind .. " replacement", undo = false, quiet = true,
	})
	if ok and changed and prefs.sounds then core.sound_play("mesecons_button_push", {to_player = ticket.name, gain = 0.15}, true) end
	return ok and changed or false
end

-- An explicit hook for a server mod with a custom use path. Call only after
-- actual use, pass the pre-use stack and the stack the engine will retain.
function R.notify_use(player, before, after)
	-- Unlike begin(), use has already occurred, so inspect the prior stack
	-- directly; the caller is trusted server code, never a client field.
	if not usable(player) then return false end
	before = ItemStack(before)
	if before:is_empty() or not U.is_safe_stack(before) then return false end
	local name = player:get_player_name()
	local index = player:get_wield_index()
	if index < 1 or index > 9 then return false end
	R.sequence = R.sequence + 1
	local ticket = {name = name, index = index, before = before, generation = R.generation[name] or 0, sequence = R.sequence, time = U.now()}
	return R.finish(player, ticket, after)
end

-- Keep new pickups out of the hotbar without reorganizing existing items.
function R.pickup(player, before, picked)
	if not player or not U.player_ok(player) or not M.preferences.get(player).pickup_organize then return false end
	local prefs = M.preferences.get(player)
	local cfg = M.preferences.compile(player)
	if not cfg or not before or #before ~= 36 then return false end
	local inv = player:get_inventory()
	local current = inv:get_list("main")
	if not current or #current ~= 36 then return false end
	local frozen = M.preferences.locks(player, "refill")
	local locked = M.preferences.locks(player, "sort")
	if not frozen or not locked then return false end
	local after, changed = U.clone_list(current), false
	local profile = prefs.profiles[prefs.active]
	for i = 1, 9 do
		local stack = after[i]
		local explicit_lock = profile.locks[tostring(i)] or cfg.rules.locked[i] or cfg.rules.frozen[i]
		if before[i]:is_empty() and not stack:is_empty() and i ~= player:get_wield_index()
			and not explicit_lock and not frozen[i] and U.same(stack, picked) and U.is_safe_stack(stack) then
			local destinations, seen = {}, {}
			local function add(index)
				if index > 9 and index <= 36 and not seen[index] and not locked[index] then
					seen[index] = true; destinations[#destinations + 1] = index
				end
			end
			for _, rule in ipairs(cfg.rules.placements) do
				if rule.predicate(stack) then for _, index in ipairs(rule.slots) do add(index) end end
			end
			for index = 10, 36 do add(index) end
			for pass = 1, 2 do
				for _, target in ipairs(destinations) do
					local dst = after[target]
					if not stack:is_empty() and U.is_safe_stack(dst)
						and ((pass == 1 and not dst:is_empty() and U.same(stack, dst)) or (pass == 2 and dst:is_empty())) then
						local amount = math.min(stack:get_count(), stack:get_stack_max() - dst:get_count())
						if amount > 0 then
							if dst:is_empty() then dst = ItemStack(stack); dst:set_count(amount)
							else dst:set_count(dst:get_count() + amount) end
							stack:take_item(amount)
							after[target], changed = dst, true
						end
					end
				end
			end
		end
	end
	if not changed then return false end
	local expected = U.clone_list(current)
	local name, generation = player:get_player_name(), R.generation[player:get_player_name()] or 0
	core.after(0, function()
		local actor = core.get_player_by_name(name)
		if not actor or not U.player_ok(actor) or (R.generation[name] or 0) ~= generation
			or not U.equal_list(actor:get_inventory():get_list("main"), expected) then return end
		M.transaction.commit(actor, {M.actions.player_endpoint(actor)}, {after}, {reason = "organize new pickup", undo = false, quiet = true})
	end)
	return true
end

local function returned_stack(output, player)
	if output[1] == nil then return player:get_wielded_item() end
	local ok, stack = pcall(ItemStack, output[1])
	return ok and stack or nil
end

function R.install()
	if R.installed then return end
	R.installed = true
	-- Existing callbacks retain every argument and return value. No wear,
	-- hunger, enchantment, placement or container behavior is reimplemented.
	for name, def in pairs(core.registered_items) do
		local overrides = {}
		for _, field in ipairs({"on_use", "on_place", "on_secondary_use"}) do
			local original = def[field]
			if type(original) == "function" then
				overrides[field] = function(stack, player, ...)
					local ticket = R.begin(player, stack)
					local out = pack(original(stack, player, ...))
					if ticket then
						local after = returned_stack(out, player)
						if after then R.finish(player, ticket, after) end
					end
					return unpack(out, 1, out.n)
				end
			end
		end
		if type(def.on_drop) == "function" then
			local original_drop = def.on_drop
			overrides.on_drop = function(stack, player, ...)
				R.cancel(player)
				return original_drop(stack, player, ...)
			end
		end
		if next(overrides) then core.override_item(name, overrides) end
	end
	if core.node_dig then
		local original = core.node_dig
		core.node_dig = function(pos, node, player)
			local ticket = R.begin(player)
			local out = pack(original(pos, node, player))
			if ticket then R.finish(player, ticket, player:get_wielded_item()) end
			return unpack(out, 1, out.n)
		end
	end
	if core.do_item_eat then
		local original = core.do_item_eat
		core.do_item_eat = function(hp, replacement, stack, player, ...)
			local ticket = R.begin(player, stack)
			-- Only the explicitly declared result of the witnessed eat path is
			-- eligible. The result is preserved in the spare's old slot during
			-- the swap; arbitrary nonempty wield items are never displaced.
			if ticket and ticket.before:get_count() == 1 then
				local valid, residue = pcall(ItemStack, replacement)
				if valid and not residue:is_empty() and U.is_safe_stack(residue) then ticket.residue = residue end
			end
			local out = pack(original(hp, replacement, stack, player, ...))
			if ticket then
				local after = returned_stack(out, player)
				if after then R.finish(player, ticket, after) end
			end
			return unpack(out, 1, out.n)
		end
	end
	if core.item_drop then
		local original = core.item_drop
		core.item_drop = function(stack, player, ...)
			R.cancel(player)
			return original(stack, player, ...)
		end
	end
	if core.item_pickup then
		local original = core.item_pickup
		core.item_pickup = function(stack, player, ...)
			local before, picked
			if player and player.is_player and player:is_player() and M.preferences.get(player).pickup_organize then
				before, picked = player:get_inventory():get_list("main"), ItemStack(stack)
			end
			local out = pack(original(stack, player, ...))
			if before then R.pickup(player, before, picked) end
			return unpack(out, 1, out.n)
		end
	end
	local mobs = rawget(_G, "mcl_mobs")
	if mobs and mobs.mob_class and mobs.mob_class.on_punch then
		local original = mobs.mob_class.on_punch
		mobs.mob_class.on_punch = function(self, player, ...)
			local ticket = R.begin(player)
			local out = pack(original(self, player, ...))
			if ticket then R.finish(player, ticket, player:get_wielded_item()) end
			return unpack(out, 1, out.n)
		end
	end
end

core.register_on_mods_loaded(R.install)
core.register_on_player_inventory_action(function(player) R.cancel(player) end)
core.register_on_dieplayer(R.cancel)
core.register_on_respawnplayer(function(player) R.cancel(player) end)
core.register_on_leaveplayer(function(player)
	R.cancel(player)
	local name = player:get_player_name()
	R.generation[name], R.hud[name] = nil, nil
end)

-- Player combat wear is applied by the engine after punch callbacks. Require
-- the witnessed attack AND unchanged other inventory cells before observing
-- the resulting wield stack. Never infer a break from a later polling tick.
if core.register_on_punchplayer then
	core.register_on_punchplayer(function(_, hitter)
		local ticket = R.begin(hitter)
		if not ticket or not is_tool(ticket.before) then return end
		local before = hitter:get_inventory():get_list("main")
		core.after(0, function()
			local player = core.get_player_by_name(ticket.name)
			if not player or ticket.index ~= player:get_wield_index() or ticket.generation ~= (R.generation[ticket.name] or 0) then return end
			local current = player:get_inventory():get_list("main")
			if not current or #current ~= 36 then return end
			for i = 1, 36 do if i ~= ticket.index and not current[i]:equals(before[i]) then return end end
			R.finish(player, ticket, current[ticket.index])
		end)
	end)
end

function R.update_hud(player)
	local name, prefs = player:get_player_name(), M.preferences.get(player)
	local state = R.hud[name]
	if not prefs.reserve_hud or not U.player_ok(player) then
		if state then player:hud_remove(state.id); R.hud[name] = nil end
		return
	end
	local selected, count = player:get_wielded_item(), 0
	local frozen = M.preferences.locks(player, "refill")
	if frozen and not frozen[player:get_wield_index()] and not selected:is_empty() then
		local selected_key = M.tool_identity.key(selected)
		for i, stack in ipairs(player:get_inventory():get_list("main") or {}) do
			if i >= 10 and i <= 36 and not frozen[i] and U.is_safe_stack(stack)
				and M.tool_identity.key(stack) == selected_key then count = count + stack:get_count() end
		end
	end
	local text = count > 0 and (M.S("Reserve: @1", tostring(count))) or ""
	if not state then
		state = {id = player:hud_add({type = "text", position = {x = 0.5, y = 1}, offset = {x = 0, y = -90},
			alignment = {x = 0, y = 0}, number = 0xFFFFFF, text = text, z_index = 10}), text = text}
		R.hud[name] = state
	elseif state.text ~= text then player:hud_change(state.id, "text", text); state.text = text end
end

local elapsed = 0
core.register_globalstep(function(dt)
	elapsed = elapsed + dt
	if elapsed < 0.5 then return end
	elapsed = 0
	for _, player in ipairs(core.get_connected_players()) do
		if R.hud[player:get_player_name()] or M.preferences.get(player).reserve_hud then R.update_hud(player) end
	end
end)
end
