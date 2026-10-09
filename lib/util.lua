-- Small, side-effect-free helpers shared by the planners and commit layer.
return function(M)
local S = M.S
local core = M.core
local U = {}
M.util = U

function U.copy(value, seen)
	if type(value) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local out = {}
	seen[value] = out
	for k, v in pairs(value) do out[U.copy(k, seen)] = U.copy(v, seen) end
	return out
end

function U.clone_list(list)
	local out = {}
	for i = 1, #list do out[i] = ItemStack(list[i]) end
	return out
end

local function part(s)
	s = tostring(s)
	return #s .. ":" .. s
end

-- Metadata fields are raw strings. Length prefixes prevent ambiguous keys,
-- including for embedded NULs, escapes and legacy binary metadata. Never use
-- ItemStack:to_string() for equality: its metadata order is unspecified.
function U.stack_key(stack, ignore_wear)
	if stack:is_empty() then return "" end
	local fields = (stack:get_meta():to_table() or {}).fields or {}
	local keys = {}
	for key in pairs(fields) do keys[#keys + 1] = key end
	table.sort(keys)
	local out = {part(stack:get_name()), part(ignore_wear and 0 or stack:get_wear())}
	for _, key in ipairs(keys) do
		out[#out + 1] = part(key)
		out[#out + 1] = part(fields[key])
	end
	return table.concat(out)
end

function U.same(a, b)
	if a:is_empty() or b:is_empty() then return a:is_empty() and b:is_empty() end
	local ac, bc = ItemStack(a), ItemStack(b)
	ac:set_count(1)
	bc:set_count(1)
	return ac:equals(bc)
end

function U.equal_list(a, b)
	if not a or not b or #a ~= #b then return false end
	for i = 1, #a do if not a[i]:equals(b[i]) then return false end end
	return true
end

function U.is_safe_stack(stack)
	if stack:is_empty() then return true end
	return core.registered_items[stack:get_name()] ~= nil
		and stack:get_count() <= stack:get_stack_max()
		and stack:get_stack_max() > 0
end

function U.conserved(before, after)
	local counts = {}
	local function add(lists, sign)
		for _, list in ipairs(lists) do
			for _, stack in ipairs(list) do
				if not stack:is_empty() then
					local key = U.stack_key(stack)
					counts[key] = (counts[key] or 0) + sign * stack:get_count()
				end
			end
		end
	end
	add(before, 1)
	add(after, -1)
	for _, count in pairs(counts) do
		if count ~= 0 then return false, S("The operation would change item identity or quantity.") end
	end
	return true
end

function U.player_ok(player)
	if not player or not player.is_player or not player:is_player()
		or player.is_fake_player or not player:get_pos() then
		return false, S("A connected player is required.")
	end
	if player:get_hp() <= 0 then return false, S("Inventory automation is unavailable while dead.") end
	if player:get_meta():get_string("gamemode") == "spectator" then
		return false, S("Inventory automation is unavailable in spectator mode.")
	end
	if not core.check_player_privs(player:get_player_name(), {interact = true}) then
		return false, S("The interact privilege is required.")
	end
	if M.config.enabled == false then return false, S("Inventory Tweaks is disabled by this server.") end
	return true
end

function U.now()
	return core.get_us_time() / 1000000
end

function U.log(level, message)
	core.log(level, "[mcl_inventory_tweaks] " .. tostring(message))
end

function U.message(player, message)
	if player and message then
		core.chat_send_player(player:get_player_name(), "[Inventory Tweaks] " .. message)
	end
end

function U.clamp(value, minimum, maximum, default)
	value = tonumber(value)
	if not value or value ~= value then return default end
	return math.max(minimum, math.min(maximum, value))
end

function U.trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
end
