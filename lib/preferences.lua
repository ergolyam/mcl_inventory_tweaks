-- All personal configuration is server-side player metadata, versioned JSON.
return function(M)
local core, U, S = M.core, M.util, M.S
local P = {cache = {}, compiled = {}, recovery = {}}
M.preferences = P
local key = M.modname .. ":settings"
local recovery_key = M.modname .. ":settings_recovery"
local boolean_defaults = {
	keep_hotbar = true, auto_refill = true, refill_tools = true,
	tool_fallback = false, repair_switch = false, pickup_organize = false,
	reserve_hud = false, sounds = false,
}
local orders = {category = true, name = true, count = true, wear = true}
local layouts = {compact = true, columns = true, merge = true}
local legacy_building_rules = "A category:building\nB category:wood\nC category:stone"
local building_rules = "A category:building & !category:wood & !category:stone\nB category:wood\nC category:stone"

function P.defaults(player)
	local out = U.copy(boolean_defaults)
	out.version = 1
	out.active = 1
	out.repair_threshold = 90
	out.refill_filter = "*"
	out.profiles = {
		{name = "Everyday", rules = "", container_rules = "", large_container_rules = "", categories = "", locks = {}, order = "category", layout = "compact"},
		{name = "Mining", rules = "A1 group:pickaxe\nA2 group:shovel\nA3 group:axe\nA4 group:torch", container_rules = "", large_container_rules = "", categories = "", locks = {}, order = "category", layout = "compact"},
		{name = "Building", rules = building_rules, container_rules = "", large_container_rules = "", categories = "", locks = {}, order = "category", layout = "compact"},
	}
	-- Names become ordinary editable player data. Localize only newly created
	-- defaults; existing names must never be guessed from their English text.
	if player and core.get_player_information and core.get_translated_string then
		local info = core.get_player_information(player:get_player_name()) or {}
		local names = {S("Everyday"), S("Mining"), S("Building")}
		for i, text in ipairs(names) do
			local name = core.get_translated_string(info.lang_code or "", text)
			if #name > 0 and #name <= 32 and not name:find("[%c]") then out.profiles[i].name = name end
		end
	end
	return out
end

local function normalize(raw, player)
	local out = P.defaults(player)
	if type(raw) ~= "table" then return out end
	for name in pairs(boolean_defaults) do
		if type(raw[name]) == "boolean" then out[name] = raw[name] end
	end
	out.active = math.floor(U.clamp(raw.active, 1, 3, 1))
	out.repair_threshold = math.floor(U.clamp(raw.repair_threshold, 50, 99, 90))
	if type(raw.refill_filter) == "string" and #raw.refill_filter <= 512 then out.refill_filter = raw.refill_filter end
	if type(raw.profiles) == "table" then
		for i = 1, 3 do
			local src, dst = raw.profiles[i], out.profiles[i]
			if type(src) == "table" then
				if type(src.name) == "string" and #src.name > 0 and #src.name <= 32 then
					local name = src.name:gsub("[%c]", "")
					if #name > 0 then dst.name = name end
				end
				for _, field in ipairs({"rules", "container_rules", "large_container_rules", "categories"}) do
					if type(src[field]) == "string" and #src[field] <= 8192 then dst[field] = src[field] end
				end
				-- Repair only the exact old player preset. Names are editable and
				-- localized; custom rule text and storage rules must stay intact.
				if src.rules == legacy_building_rules then dst.rules = building_rules end
				if orders[src.order] then dst.order = src.order end
				-- Older profiles may still select the removed grouped-row mode.
				-- Change only that layout; retain names, rules and protection.
				if src.layout == "rows" then dst.layout = "compact"
				elseif layouts[src.layout] then dst.layout = src.layout end
				if type(src.locks) == "table" then
					for j = 1, 36 do
						local value = src.locks[tostring(j)] or src.locks[j]
						if value == 1 or value == 2 then dst.locks[tostring(j)] = value end
					end
				end
			end
		end
	end
	return out
end

local function integer(value, minimum, maximum)
	return type(value) == "number" and value == math.floor(value)
		and value >= minimum and value <= maximum
end

-- Stored settings must be the complete version-1 schema that save() writes.
-- Display normalization remains bounded, but must never silently erase a
-- stored protection field and let automation proceed with different rules.
local function schema_error(raw)
	if type(raw) ~= "table" then return S("the stored JSON is not a settings object") end
	if raw.version ~= 1 then return S("the settings version is missing or unsupported") end
	for name in pairs(boolean_defaults) do
		if type(raw[name]) ~= "boolean" then return S("invalid or missing @1 setting", name) end
	end
	if not integer(raw.active, 1, 3) then return S("invalid active profile") end
	if not integer(raw.repair_threshold, 50, 99) then return S("invalid repair threshold") end
	if type(raw.refill_filter) ~= "string" or #raw.refill_filter > 512 then return S("invalid refill filter field") end
	if type(raw.profiles) ~= "table" then return S("invalid or missing profiles") end
	for index in pairs(raw.profiles) do
		if not integer(index, 1, 3) then return S("unexpected profile index") end
	end
	for i = 1, 3 do
		local profile = raw.profiles[i]
		if type(profile) ~= "table" then return S("invalid or missing profile @1", i) end
		if type(profile.name) ~= "string" or #profile.name == 0 or #profile.name > 32 or profile.name:find("[%c]") then
			return S("invalid name in profile @1", i)
		end
		for _, name in ipairs({"rules", "container_rules", "large_container_rules", "categories"}) do
			if type(profile[name]) ~= "string" or #profile[name] > 8192 then
				return S("invalid or missing @1 field in profile @2", name, i)
			end
		end
		-- Recognize rows only as a legacy saved value for normalize() above.
		-- All other schema checks still apply before automation is allowed.
		if not orders[profile.order] or (not layouts[profile.layout] and profile.layout ~= "rows") then
			return S("invalid sorting mode in profile @1", i)
		end
		if type(profile.locks) ~= "table" then return S("invalid or missing protected slots in profile @1", i) end
		for index, protection in pairs(profile.locks) do
			local number = type(index) == "string" and tonumber(index)
			if not integer(number, 1, 36) or tostring(number) ~= index or not integer(protection, 0, 2) then
				return S("invalid protected slot in profile @1", i)
			end
		end
		for index = 1, 36 do
			if not integer(profile.locks[tostring(index)], 0, 2) then return S("missing protected slot in profile @1", i) end
		end
	end
end

local function raw_field(meta, name)
	local fields = (meta:to_table() or {}).fields or {}
	return fields[name] or ""
end

local function recovery_message(reason)
	return S("Saved Inventory Tweaks settings need recovery: @1. Automation is paused. Open Settings to reset damaged settings with a backup.", reason)
end

local function clear_pending(player)
	if M.refill then M.refill.cancel(player) end
	if M.transaction and M.transaction.clear then M.transaction.clear(player) end
end

local function encode(value)
	-- Luanti writes an empty Lua table as JSON null, which parse_json drops.
	-- Encode an explicit value for every slot so absence cannot erase a lock.
	local stored = U.copy(value)
	for _, profile in ipairs(stored.profiles) do
		for index = 1, 36 do profile.locks[tostring(index)] = profile.locks[tostring(index)] or 0 end
	end
	local ok, encoded = pcall(core.write_json, stored)
	if not ok or type(encoded) ~= "string" or #encoded > 131072 then
		return nil, S("Settings could not be encoded; your previous settings were kept.")
	end
	return encoded
end

local function write_field(meta, name, value)
	local ok = pcall(function()
		meta:set_string(name, value)
		if raw_field(meta, name) ~= value then error("Metadata write was not retained") end
	end)
	return ok
end

local function restore_field(meta, name, value)
	local ok, actual = pcall(raw_field, meta, name)
	if ok and actual == value then return true end
	return write_field(meta, name, value)
end

function P.get(player)
	local name = player:get_player_name()
	if P.cache[name] then return P.cache[name] end
	local text = raw_field(player:get_meta(), key)
	local raw, reason
	if #text > 131072 then reason = S("the stored JSON exceeds 131072 bytes")
	elseif #text > 0 then
		local ok, value = pcall(core.parse_json, text)
		if not ok or type(value) ~= "table" then reason = S("the stored JSON is malformed")
		else raw, reason = value, schema_error(value) end
	end
	P.recovery[name] = reason and recovery_message(reason) or nil
	P.cache[name] = normalize(raw, player)
	if reason then clear_pending(player) end
	return P.cache[name]
end

function P.save(player, value)
	local name = player:get_player_name()
	P.get(player)
	if P.recovery[name] then return false, P.recovery[name] end
	value = normalize(value)
	local encoded, err = encode(value)
	if not encoded then return false, err end
	local meta = player:get_meta()
	local original = raw_field(meta, key)
	if not write_field(meta, key, encoded) then
		if not restore_field(meta, key, original) then
			P.recovery[name] = recovery_message(S("a metadata write failed and could not be rolled back"))
			P.compiled[name] = nil
			clear_pending(player)
			return false, P.recovery[name]
		end
		return false, S("Settings could not be written; your previous settings were kept.")
	end
	P.cache[name], P.compiled[name] = value, nil
	clear_pending(player)
	return true
end

-- This explicit recovery action is the only operation allowed to replace a
-- damaged persisted schema. Back up exact original bytes before changing it.
function P.reset_damaged(player)
	local name = player:get_player_name()
	P.get(player)
	if not P.recovery[name] then return false, S("There are no damaged settings to reset.") end
	local value = P.defaults(player)
	local encoded, err = encode(value)
	if not encoded then return false, err end
	local meta = player:get_meta()
	local original = raw_field(meta, key)
	local prior_backup = raw_field(meta, recovery_key)
	if not write_field(meta, recovery_key, original) then
		restore_field(meta, recovery_key, prior_backup)
		return false, S("Damaged settings could not be backed up; the original settings were kept.")
	end
	if not write_field(meta, key, encoded) then
		restore_field(meta, key, original)
		-- Retain the successfully written exact backup even if a failed
		-- metadata provider also refuses the best-effort original restoration.
		return false, S("Settings reset failed. Automation remains paused; original settings are saved in the recovery backup.")
	end
	P.cache[name], P.compiled[name], P.recovery[name] = value, nil, nil
	clear_pending(player)
	return true, S("Damaged settings reset. The original data was preserved in the recovery backup.")
end

-- Compile lazily once per saved revision. A bad saved configuration blocks
-- automation instead of silently replacing the user's rules with defaults.
function P.compile(player)
	local name = player:get_player_name()
	local prefs = P.get(player)
	if P.recovery[name] then return nil, P.recovery[name] end
	if P.compiled[name] then return P.compiled[name].value, P.compiled[name].error end
	local profile = prefs.profiles[prefs.active]
	local cats, err = M.categories.compile(profile.categories)
	local rules, predicate
	if cats then
		rules, err = M.rules.compile(profile.rules, {size = 36, width = 9, player = true, categories = cats})
	end
	if rules then predicate, err = M.categories.selector(prefs.refill_filter, cats) end
	local result
	if predicate then result = {categories = cats, rules = rules, refill_filter = predicate} end
	P.compiled[name] = {value = result, error = err}
	return result, err
end

function P.locks(player, operation)
	local prefs = P.get(player)
	local cfg, err = P.compile(player)
	if not cfg then return nil, err end
	local locked, frozen = {}, {}
	local profile = prefs.profiles[prefs.active]
	for i = 1, 36 do
		local value = profile.locks[tostring(i)]
		if value == 2 or cfg.rules.frozen[i] then frozen[i] = true end
		if value == 1 or value == 2 or cfg.rules.locked[i] or frozen[i] then locked[i] = true end
		if operation ~= "refill" and prefs.keep_hotbar and i <= 9 then locked[i] = true end
	end
	return operation == "refill" and frozen or locked, frozen
end

function P.validate_edit(player, fields)
	local prefs = U.copy(P.get(player))
	local profile = prefs.profiles[prefs.active]
	for _, name in ipairs({"rules", "container_rules", "large_container_rules", "categories"}) do
		if fields[name] ~= nil then
			if type(fields[name]) ~= "string" or #fields[name] > 8192 then return nil, S("Rules and categories are limited to 8192 bytes each.") end
			profile[name] = fields[name]
		end
	end
	if fields.profile_name then
		local name = U.trim(fields.profile_name):gsub("[%c]", "")
		if #name == 0 or #name > 32 then return nil, S("Profile names must contain 1–32 bytes.") end
		profile.name = name
	end
	local cats, err = M.categories.compile(profile.categories)
	if not cats then return nil, err end
	local rules
	rules, err = M.rules.compile(profile.rules, {size = 36, width = 9, player = true, categories = cats})
	if not rules then return nil, err end
	for _, spec in ipairs({{"container_rules", 27}, {"large_container_rules", 54}}) do
		rules, err = M.rules.compile(profile[spec[1]], {size = spec[2], width = 9, player = false, categories = cats})
		if not rules then return nil, S("@1: @2", spec[1], err) end
	end
	local predicate
	predicate, err = M.categories.selector(prefs.refill_filter, cats)
	if not predicate then return nil, err end
	return prefs
end

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	P.cache[name], P.compiled[name], P.recovery[name] = nil, nil, nil
end)
end
