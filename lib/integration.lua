-- Audited Mineclonia 0.123.1 adapters. Inventory contents are never stored in UI
-- sessions; endpoints always address the live server inventory.
return function(M)
	local S = M.S
	local core = M.core
	local I = {}
	M.integration = I
	local sessions, watching = {}, {}
	local serial, installed = 0, false
	local pending, native_show
	local native_close = {}
	local node_specs = {}
	local entity_names = {
		["mcl_boats:chest_boat"] = true,
		["mcl_minecarts:chest_minecart"] = true,
	}
	local function position(pos)
		-- Mineclonia APIs use vector methods (for example pos:add() in
		-- comparator updates). A plain table copy loses Luanti's metatable.
		return vector.copy(pos)
	end
	local function poskey(pos)
		return pos.x .. "," .. pos.y .. "," .. pos.z
	end
	local function formpos(pos)
		return pos.x .. "_" .. pos.y .. "_" .. pos.z
	end
	local function playername(player)
		return player and player.get_player_name and player:get_player_name()
	end
	local function distance(a, b)
		local x, y, z = a.x - b.x, a.y - b.y, a.z - b.z
		return math.sqrt(x*x + y*y + z*z)
	end
	local function finite(n)
		return type(n) == "number" and n == n and n > -math.huge and n < math.huge
	end
	local function stack_range(stack)
		local value = stack:get_meta():get_string("range")
		local def = stack:get_definition()
		local range = value ~= "" and tonumber(value) or (def and def.range)
		return finite(range) and range or -1
	end
	local function in_node_range(player, pos)
		local p = player:get_pos()
		if not p then return false end
		local props = player:get_properties() or {}
		local eye = vector.offset(p, 0, props.eye_height or 1.625, 0)
		local range = stack_range(player:get_wielded_item())
		if range < 0 then
			range = stack_range(player:get_inventory():get_stack("hand", 1))
		end
		if range < 0 then range = 4 end
		-- The same tolerance as Server::checkInteractDistance in Luanti 5.17.
		return distance(eye, pos) <= range + 2.6
	end
	local function log_warning(message)
		core.log("warning", "[mcl_inventory_tweaks] " .. message)
	end
	local function remove_watchers(ctx)
		for _, target in ipairs(ctx.targets or {}) do
			local key = poskey(target.pos)
			local watchers = watching[key]
			if watchers then
				watchers[ctx] = nil
				if not next(watchers) then watching[key] = nil end
			end
		end
	end
	-- suppress_native is used only when the real native quit callback is about
	-- to receive the same event. Final manager closes need explicit forwarding.
	function I.clear_context(player, suppress_native)
		local name = playername(player)
		local ctx = name and sessions[name]
		if not ctx then return end
		sessions[name] = nil
		ctx.closed = true
		remove_watchers(ctx)
		if not suppress_native and ctx.close_native then
			local ok, err = pcall(ctx.close_native, player, ctx.formname, {quit = true})
			if not ok then log_warning("Native container close failed: " .. tostring(err)) end
		end
		if not suppress_native and native_show then
			-- Never close an unrelated form or the manager with an empty form
			-- name. The exact old native window alone becomes stale here.
			native_show(name, ctx.formname, "")
		end
	end
	local function invalidate_position(pos)
		local watchers = watching[poskey(pos)]
		if not watchers then return end
		local list = {}
		for ctx in pairs(watchers) do list[#list+1] = ctx end
		for _, ctx in ipairs(list) do
			local player = core.get_player_by_name(ctx.owner)
			if player then
				I.clear_context(player)
			else
				ctx.closed = true
				sessions[ctx.owner] = nil
				remove_watchers(ctx)
			end
		end
	end
	local function context_targets_valid(player, ctx)
		if ctx.closed or sessions[playername(player)] ~= ctx or playername(player) ~= ctx.owner then
			return false, S("This container session has closed. Open the container again.")
		end
		local ok, err = M.util.player_ok(player)
		if not ok then return false, err end
		if M.util.now() - ctx.last_activity > (M.config.session_timeout or 1800) then
			return false, S("The container session has expired. Open it again.")
		end
		if ctx.entity then
			local ent = ctx.entity
			local object = ent.object
			local pos = object and object:get_pos()
			if not pos or object:get_luaentity() ~= ent or not entity_names[ent.name]
				or ent.name ~= ctx.entity_name or ent._inv_id ~= ctx.inventory_name
				or ent._inv_size ~= 27 or distance(player:get_pos(), pos) > 5 then
				return false, S("The storage entity is gone or out of reach.")
			end
			if core.detached_inventories[ctx.inventory_name] ~= ctx.detached_callbacks then
				return false, S("The storage entity inventory has been replaced.")
			end
			local inv = core.get_inventory({type = "detached", name = ctx.inventory_name})
			if not inv or inv:get_size("main") ~= 27 then
				return false, S("The storage entity inventory is unavailable.")
			end
			return true
		end
		for _, target in ipairs(ctx.targets) do
			local node = core.get_node_or_nil(target.pos)
			local spec = node and node_specs[node.name]
			if not spec or spec.family ~= target.family or spec.side ~= target.side
				or node.param2 ~= target.param2 then
				return false, S("The container has changed. Open it again.")
			end
			if not in_node_range(player, target.pos) then
				return false, S("The container is out of reach.")
			end
			if core.is_protected(target.pos, ctx.owner) then
				return false, S("This container is protected.")
			end
			if target.lid then
				local above = core.get_node_or_nil(vector.offset(target.pos, 0, 1, 0))
				local def = above and core.registered_nodes[above.name]
				if not def or (def.groups or {}).opaque == 1 then
					return false, S("The chest lid is blocked.")
				end
			end
			if not ctx.ender then
				local inv = core.get_inventory({type = "node", pos = target.pos})
				if not inv or inv:get_size("main") ~= 27 then
					return false, S("The container inventory is unavailable.")
				end
			end
		end
		if #ctx.targets == 2 then
			local left, right = ctx.targets[1], ctx.targets[2]
			local neighbor = mcl_util.get_double_container_neighbor_pos(left.pos, left.param2, "left")
			local reciprocal = mcl_util.get_double_container_neighbor_pos(right.pos, right.param2, "right")
			if not neighbor or not reciprocal or poskey(neighbor) ~= poskey(right.pos)
				or poskey(reciprocal) ~= poskey(left.pos) or left.family ~= right.family then
				return false, S("The double chest is no longer a matching pair.")
			end
		end
		if ctx.ender and player:get_inventory():get_size("enderchest") ~= 27 then
			return false, S("The ender chest inventory is unavailable.")
		end
		return true
	end
	function I.context_valid(player, ctx)
		if type(ctx) ~= "table" or ctx.kind ~= "container" then
			return false, S("Open a supported container first.")
		end
		return context_targets_valid(player, ctx)
	end
	function I.get_context(player)
		local ctx = sessions[playername(player)]
		if ctx then
			local ok = I.context_valid(player, ctx)
			if not ok then I.clear_context(player); return nil end
		end
		return ctx
	end
	function I.touch_context(player, ctx)
		local ok, err = I.context_valid(player, ctx)
		if not ok then return false, err end
		ctx.last_activity = M.util.now()
		return true
	end
	local function callback_args(fn, first, player, action, info)
		if action == "move" then
			return fn(first, info.from_list, info.from_index, info.to_list, info.to_index, info.count, player)
		end
		return fn(first, info.listname, info.index, ItemStack(info.stack), player)
	end
	local function action_count(action, info)
		return action == "move" and info.count or info.stack:get_count()
	end
	local function node_endpoint(ctx, target)
		local inv = core.get_inventory({type = "node", pos = target.pos})
		local inventory_id = "node:" .. poskey(target.pos)
		local ep = {id = inventory_id .. ":main", inventory_id = inventory_id,
			kind = "node", inv = inv, list = "main", size = 27, pos = position(target.pos)}
		ep.validate = function(player) return I.context_valid(player, ctx) end
		local function callback(prefix, player, action, info)
			local node = core.get_node_or_nil(target.pos)
			local def = node and core.registered_nodes[node.name]
			local fn = def and def[prefix .. action]
			if fn then return callback_args(fn, position(target.pos), player, action, info) end
			if prefix == "allow_metadata_inventory_" then return action_count(action, info) end
		end
		ep.allow = function(player, action, info)
			local value = callback("allow_metadata_inventory_", player, action, info)
			-- Unlike registered player allow callbacks, a native node allow
			-- callback must return a number. Only its absence defaults to count.
			return finite(value) and value or 0
		end
		ep.on = function(player, action, info)
			return callback("on_metadata_inventory_", player, action, info)
		end
		ep.after_commit = function()
			if mcl_redstone and mcl_redstone.update_comparators then
				mcl_redstone.update_comparators(position(target.pos))
			end
		end
		return ep
	end
	local function detached_endpoint(ctx)
		local inv = core.get_inventory({type = "detached", name = ctx.inventory_name})
		local id = "detached:" .. ctx.inventory_name
		local ep = {id = id .. ":main", inventory_id = id, kind = "detached", inv = inv,
			list = "main", size = 27, entity = ctx.entity}
		ep.validate = function(player) return I.context_valid(player, ctx) end
		ep.allow = function(player, action, info)
			local fn = ctx.detached_callbacks["allow_" .. action]
			if fn then
				local value = callback_args(fn, inv, player, action, info)
				return finite(value) and value or 0
			end
			return action_count(action, info)
		end
		ep.on = function(player, action, info)
			local fn = ctx.detached_callbacks["on_" .. action]
			if fn then return callback_args(fn, inv, player, action, info) end
		end
		ep.after_commit = function()
			mcl_entity_invs.save_inv(ctx.entity)
		end
		return ep
	end
	local function decorate(player, ctx)
		local container_y, player_y, x = 0.14, 4.49, 9.35
		if #ctx.endpoints == 2 then player_y = 8.24 end
		local coordinates, restore_coordinates = "", ""
		if ctx.entity then
			-- The native entity form uses legacy coordinates. In that mode a
			-- button's supplied height is ignored. Switch only the appended
			-- controls: the already parsed native size and lists stay untouched.
			container_y, player_y = 0.45, 5.00
			coordinates, restore_coordinates = "real_coordinates[true]", "real_coordinates[false]"
		end
		return ctx.original_formspec .. coordinates
			.. M.ui.toolbar(player, "container", {x = x, y = container_y, token = ctx.token})
			.. M.ui.toolbar(player, "player", {x = x, y = player_y, token = M.ui.player_token(player)})
			.. restore_coordinates
	end
	local function context_common(player, formname, formspec)
		serial = serial + 1
		local ctx = {kind = "container", owner = playername(player), formname = formname,
			token = tostring(serial), width = 9, targets = {}, endpoints = {}, original_formspec = formspec,
			last_activity = M.util.now(), active_formname = formname}
		ctx.validate = function(p) return I.context_valid(p, ctx) end
		ctx.refresh = function(p)
			local ok, err = I.touch_context(p, ctx)
			if not ok then I.clear_context(p); return false, err end
			ctx.active_formname = ctx.formname
			native_show(ctx.owner, ctx.formname, decorate(p, ctx))
			return true
		end
		return ctx
	end
	local function target_at(pos)
		local node = core.get_node_or_nil(pos)
		local spec = node and node_specs[node.name]
		if not spec then return end
		return {pos = position(pos), param2 = node.param2, family = spec.family,
			side = spec.side, lid = spec.lid}, spec
	end
	local function make_node_context(player, opening, formname, formspec)
		local target, spec = target_at(opening.pos)
		if not target or spec.family ~= opening.family or spec.side ~= opening.side then return end
		local ctx = context_common(player, formname, formspec)
		ctx.close_native = native_close[spec.close_kind]
		ctx.targets = {target}
		ctx.ender = spec.ender
		if spec.side == "left" or spec.side == "right" then
			local other_pos = mcl_util.get_double_container_neighbor_pos(target.pos, target.param2, spec.side)
			local other = other_pos and target_at(other_pos)
			if not other or other.family ~= target.family or other.param2 ~= target.param2
				or other.side ~= (spec.side == "left" and "right" or "left") then return end
			ctx.targets = spec.side == "left" and {target, other} or {other, target}
		end
		local meta = core.get_meta(ctx.targets[1].pos)
		local title = meta:get_string("name")
		ctx.title = title ~= "" and title or spec.title
		if ctx.ender then
			local ep = M.actions.player_endpoint(player, "enderchest")
			local validate = ep.validate
			ep.validate = function(p)
				local ok, err = I.context_valid(p, ctx)
				if not ok then return false, err end
				return validate(p)
			end
			ctx.endpoints = {ep}
		else
			for _, t in ipairs(ctx.targets) do ctx.endpoints[#ctx.endpoints+1] = node_endpoint(ctx, t) end
		end
		return ctx
	end
	local function make_entity_context(player, opening, formname, formspec)
		local ent = opening.entity
		if not ent or not entity_names[ent.name] or ent._inv_size ~= 27 or formname ~= ent._inv_id then return end
		local callbacks = core.detached_inventories[ent._inv_id]
		if not callbacks then return end
		local ctx = context_common(player, formname, formspec)
		ctx.entity, ctx.entity_name, ctx.inventory_name = ent, ent.name, ent._inv_id
		ctx.detached_callbacks = callbacks
		ctx.title = ent._inv_title or S("Storage")
		ctx.endpoints = {detached_endpoint(ctx)}
		return ctx
	end
	local function activate(player, ctx)
		if not ctx then return false end
		if sessions[ctx.owner] then I.clear_context(player) end
		sessions[ctx.owner] = ctx
		-- A protected container remains readable in Mineclonia. Refuse to attach
		-- actionable controls if this player cannot modify it.
		local ok = I.context_valid(player, ctx)
		if not ok then
			sessions[ctx.owner] = nil
			ctx.closed = true
			return false
		end
		for _, target in ipairs(ctx.targets) do
			local key = poskey(target.pos)
			watching[key] = watching[key] or {}
			watching[key][ctx] = true
		end
		return true
	end
	local function expected_form(spec, pos, player)
		if spec.ender then return "mcl_chests:ender_chest_" .. playername(player) end
		if spec.shulker then return "mcl_chests:mcl_inventory_tweaks_shulker_" .. formpos(pos) end
		return spec.form_prefix .. formpos(pos)
	end
	local function with_opening(opening, fn, ...)
		local previous = pending
		pending = opening
		local results = {pcall(fn, ...)}
		pending = previous
		if not results[1] then error(results[2], 0) end
		return unpack(results, 2)
	end
	local function wrap_node(name, spec)
		local def = core.registered_nodes[name]
		if not def or type(def.on_rightclick) ~= "function" then return end
		if not native_close[spec.close_kind] then
			log_warning("Skipping " .. name .. ": the native close callback is unavailable.")
			return
		end
		node_specs[name] = spec
		local old_rightclick, old_destruct, old_fields = def.on_rightclick, def.on_destruct, def.on_receive_fields
		local replacement = {}
		replacement.on_rightclick = function(pos, node, player, itemstack, pointed_thing)
			if not playername(player) then return old_rightclick(pos, node, player, itemstack, pointed_thing) end
			I.clear_context(player)
			local opening = {player = player, pos = position(pos), family = spec.family, side = spec.side,
				formname = expected_form(spec, pos, player)}
			local result = with_opening(opening, old_rightclick, pos, node, player, itemstack, pointed_thing)
			if spec.shulker then
				local formspec = core.get_meta(pos):get_string("formspec")
				if formspec:find("list[context;main;", 1, true) then
					local location = "nodemeta:" .. poskey(pos)
					formspec = formspec:gsub("list%[context;", "list[" .. location .. ";")
						:gsub("listring%[context;", "listring[" .. location .. ";")
					local ctx = make_node_context(player, opening, opening.formname, formspec)
					if activate(player, ctx) then native_show(playername(player), ctx.formname, decorate(player, ctx)) end
				end
			end
			return result
		end
		replacement.on_destruct = function(pos)
			invalidate_position(pos)
			if old_destruct then return old_destruct(pos) end
		end
		if spec.shulker then
			replacement.on_receive_fields = function(pos, formname, fields, player)
				-- Handle a close sent by the initial client node-form before our
				-- named replacement reached the client.
				local ctx = sessions[playername(player)]
				if fields.quit and ctx and ctx.targets[1] and poskey(ctx.targets[1].pos) == poskey(pos) then
					if ctx.active_formname ~= ctx.formname then return end
					I.clear_context(player, true)
					native_show(playername(player), ctx.formname, "")
				end
				if old_fields then return old_fields(pos, formname, fields, player) end
			end
		end
		core.override_item(name, replacement)
	end
	local function capture_closers()
		for _, fn in ipairs(core.registered_on_player_receive_fields or {}) do
			local origin = core.callback_origins and core.callback_origins[fn]
			if origin and origin.mod == "mcl_chests" then native_close.chests = fn end
			if origin and origin.mod == "mcl_barrels" then native_close.barrels = fn end
		end
		-- This audited node callback calls the same private chest-close routine
		-- for all chest types. It is also a fallback for origin-less embedders.
		if not native_close.chests then
			local ender = core.registered_nodes["mcl_chests:ender_chest_small"]
			if ender and ender.on_receive_fields then
				local close = ender.on_receive_fields
				native_close.chests = function(player, formname, fields)
					return close(nil, formname, fields, player)
				end
			end
		end
	end
	local function install_nodes()
		for _, base in ipairs({"chest", "trapped_chest", "trapped_chest_on"}) do
			local family = base == "chest" and "chest" or "trapped_chest"
			for _, side in ipairs({"small", "left", "right"}) do
				wrap_node("mcl_chests:" .. base .. "_" .. side, {
					family = family, side = side, lid = true, close_kind = "chests",
					form_prefix = "mcl_chests:" .. family .. "_", title = side == "small" and S("Chest") or S("Large Chest"),
				})
			end
		end
		wrap_node("mcl_chests:ender_chest_small", {family = "ender", side = "small", lid = true,
			ender = true, close_kind = "chests", title = S("Ender Chest")})
		for _, state in ipairs({"closed", "open"}) do
			wrap_node("mcl_barrels:barrel_" .. state, {family = "barrel", side = "small", close_kind = "barrels",
				form_prefix = "mcl_barrels:barrel_", title = S("Barrel")})
		end
		for _, color in ipairs({"white", "grey", "orange", "cyan", "magenta", "violet", "lightblue", "blue",
			"yellow", "brown", "green", "dark_green", "pink", "red", "dark_grey", "black"}) do
			wrap_node("mcl_chests:" .. color .. "_shulker_box_small", {family = "shulker:" .. color,
				side = "small", shulker = true, close_kind = "chests", title = S("Shulker Box")})
		end
	end
	local function install_entity_forms()
		if not rawget(_G, "mcl_entity_invs") or type(mcl_entity_invs.show_inv_form) ~= "function" then return end
		local original = mcl_entity_invs.show_inv_form
		mcl_entity_invs.show_inv_form = function(ent, player, text)
			if not ent or not entity_names[ent.name] or not playername(player) then return original(ent, player, text) end
			I.clear_context(player)
			return with_opening({player = player, entity = ent, formname = ent._inv_id}, original, ent, player, text)
		end
	end
	local function install_player_forms()
		if rawget(_G, "mcl_inventory") then
			for _, tab in ipairs(mcl_inventory.registered_survival_inventory_tabs or {}) do
				if tab.id == "main" and type(tab.build) == "function" then
					local build = tab.build
					tab.build = function(player)
						local formspec = build(player)
						if type(formspec) ~= "string" then return formspec end
						return formspec .. M.ui.toolbar(player, "player", {x = 9.35, y = 5.20, token = M.ui.player_token(player)})
					end
				end
			end
		end
		if rawget(_G, "mcl_player") and type(mcl_player.set_inventory_formspec) == "function" then
			local set = mcl_player.set_inventory_formspec
			mcl_player.set_inventory_formspec = function(player, formspec, priority)
				-- Decorate only the exact native creative personal-inventory layout
				-- at its own priority. Catalog/trash and horse screens pass through.
				if priority == 0 and type(formspec) == "string"
					and formspec:find("size[13,11.43]", 1, true)
					and formspec:find("list[current_player;main;0.375,3.375;9,3;9]", 1, true) then
					local prefix, suffix = formspec:match("^(.*)(container_end%[%]p?[%d%.]*)$")
					if prefix then
						formspec = prefix .. M.ui.toolbar(player, "player", {x = 9.35, y = 2.95,
							token = M.ui.player_token(player)}) .. suffix
					end
				end
				return set(player, formspec, priority)
			end
		end
	end
	function I.install()
		if installed then return end
		installed = true
		capture_closers()
		native_show = core.show_formspec
		core.show_formspec = function(name, formname, formspec)
			local player = core.get_player_by_name(name)
			local ctx = sessions[name]
			if formspec == "" then
				if ctx and (formname == "" or formname == ctx.formname or formname == ctx.active_formname) then
					I.clear_context(player)
				end
				return native_show(name, formname, formspec)
			end
			local opening = pending
			if player and opening and playername(opening.player) == name and formname == opening.formname then
				local newctx
				if opening.entity then newctx = make_entity_context(player, opening, formname, formspec)
				else newctx = make_node_context(player, opening, formname, formspec) end
				if activate(player, newctx) then return native_show(name, formname, decorate(player, newctx)) end
			elseif ctx then
				if formname:sub(1,21) == "mcl_inventory_tweaks:" then ctx.active_formname = formname
				else I.clear_context(player) end
			end
			return native_show(name, formname, formspec)
		end
		install_nodes()
		install_entity_forms()
		install_player_forms()
		core.register_on_player_receive_fields(function(player, formname, fields)
			local ctx = sessions[playername(player)]
			if ctx and (formname == ctx.formname or formname:sub(1,21) == "mcl_inventory_tweaks:")
				and formname ~= ctx.active_formname then
				-- A delayed quit from an older manager/native window must not
				-- close a newer container or reach its native close callback.
				return true
			end
			if fields.quit then
				if ctx and formname == ctx.formname then I.clear_context(player, true) end
				if ctx and formname:sub(1,21) == "mcl_inventory_tweaks:" then I.clear_context(player) end
				return false
			end
			if formname == "" then
				I.clear_context(player)
				-- Mineclonia's Creative handler rebuilds and reopens this form
				-- for every unconsumed non-quit packet. Stop after an owned
				-- toolbar action so it cannot replace the manager we just opened.
				return M.ui.handle_toolbar(player, fields, nil) or false
			elseif ctx and formname == ctx.formname then
				local ok = I.touch_context(player, ctx)
				if ok then return M.ui.handle_toolbar(player, fields, ctx) or false
				else I.clear_context(player) end
			end
			return false
		end)
		core.register_on_leaveplayer(function(player) I.clear_context(player) end)
		core.register_on_dieplayer(function(player) I.clear_context(player) end)
		core.register_on_respawnplayer(function(player) I.clear_context(player) end)
		core.register_on_dignode(function(pos) invalidate_position(pos) end)
		core.register_on_placenode(function(pos) invalidate_position(pos) end)
	end
	core.register_on_mods_loaded(I.install)
end
