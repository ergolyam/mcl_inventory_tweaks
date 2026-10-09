-- SPDX-License-Identifier: MIT
-- Refill equivalence is deliberately separate from sorting/merging equality.
-- A tool's original stack is never rewritten by this comparison.
return function(M)
local core, U = M.core, M.util
local I = {}
M.tool_identity = I

local CAPABILITIES = "tool_capabilities"
local HASH = "groupcaps_hash"
local HASTE = "mcl_potions:haste"
local FATIGUE = "mcl_potions:fatigue"

local function fields(stack)
	return (stack:get_meta():to_table() or {}).fields or {}
end

local function without_cache(stack)
	local clean = ItemStack(stack)
	local meta = clean:get_meta()
	meta:set_tool_capabilities(nil)
	meta:set_string(HASH, "")
	meta:set_string(HASTE, "")
	meta:set_string(FATIGUE, "")
	return clean
end

-- Mineclonia writes absent zero modifiers and canonical, finite set_float
-- values otherwise. Do not interpret raw metadata aliases or permissive
-- numeric strings as caches merely because get_float resolves them.
local function modifier(stack, raw, name, maximum)
	if raw == nil then return 0 end
	local value = tonumber(raw)
	if not value or value ~= value or value <= 0 or value == math.huge
		or maximum and value > maximum then return nil end
	local probe = ItemStack(stack)
	probe:get_meta():set_float(name, value)
	if fields(probe)[name] ~= raw then return nil end
	return value
end

local function matches_cache(original, generated)
	local actual = fields(generated)
	-- Exact raw JSON equality is intentional: a custom override, alias, stale
	-- hash or differently encoded value is retained unless its derivation is
	-- demonstrable using the game APIs active on this server.
	return original[CAPABILITIES] == actual[CAPABILITIES]
		and original[HASH] == actual[HASH]
end

local function normalized(stack, raw)
	local enchanting = rawget(_G, "mcl_enchanting")
	if type(enchanting) ~= "table" or type(enchanting.update_groupcaps) ~= "function" then return nil end
	local def = core.registered_items[stack:get_name()]
	if type(def.tool_capabilities) ~= "table" then return nil end
	local clean = without_cache(stack)
	local has_effect = raw[HASTE] ~= nil or raw[FATIGUE] ~= nil
	if has_effect then
		-- This is precisely the reset/groupcaps/effect order used by
		-- mcl_potions.update_haste_and_fatigue, rather than a reimplementation
		-- of enchantment or potion formulas. Effectful tools are group:tool=1.
		local potions = rawget(_G, "mcl_potions")
		if type(potions) ~= "table" or type(potions.apply_haste_fatigue) ~= "function"
			or core.get_item_group(stack:get_name(), "tool") ~= 1 then return nil end
		local haste = modifier(stack, raw[HASTE], HASTE)
		local fatigue = modifier(stack, raw[FATIGUE], FATIGUE, 1)
		if not haste or not fatigue then return nil end
		local generated = ItemStack(clean)
		enchanting.update_groupcaps(generated, true)
		local caps = potions.apply_haste_fatigue(generated:get_tool_capabilities(), haste, 1 - fatigue)
		if type(caps) ~= "table" then return nil end
		generated:get_meta():set_tool_capabilities(caps)
		if matches_cache(raw, generated) then return clean end
		return nil
	end

	-- Fresh enchanted tools have the full enchantment cache. Tools whose
	-- haste/fatigue effects ended can instead contain only rebuilt groupcaps.
	-- Accept either source-verified game path, always with an exact proof.
	if type(enchanting.load_enchantments) == "function" then
		local generated = ItemStack(clean)
		enchanting.load_enchantments(generated)
		if matches_cache(raw, generated) then return clean end
	end
	local generated = ItemStack(clean)
	enchanting.update_groupcaps(generated, true)
	if matches_cache(raw, generated) then return clean end
	return nil
end

function I.key(stack)
	if stack:is_empty() then return "" end
	local def = core.registered_items[stack:get_name()]
	local tool = def and def.type == "tool"
	local strict = U.stack_key(stack, tool)
	if not tool then return strict end
	local raw = fields(stack)
	if raw[CAPABILITIES] == nil and raw[HASH] == nil and raw[HASTE] == nil and raw[FATIGUE] == nil then
		return strict
	end
	-- Third-party metadata or optional/overridden APIs may be malformed.
	-- Failure only narrows eligible refill candidates; it cannot alter items.
	local ok, clean = pcall(normalized, stack, raw)
	return ok and clean and U.stack_key(clean, true) or strict
end

function I.equals(a, b)
	return I.key(a) == I.key(b)
end
end
