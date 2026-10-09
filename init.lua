-- Inventory Tweaks for Mineclonia. Original server-side implementation.
local core = core
local modname = core.get_current_modname()
local path = core.get_modpath(modname)
local version = core.get_version().string or ""
local major, minor = version:match("^(%d+)%.(%d+)")
if not major or tonumber(major) < 5 or (tonumber(major) == 5 and tonumber(minor) < 17) then
	error("[inventory_tweaks] Luanti 5.17 or newer is required (running " .. version .. ").")
end
if not rawget(_G, "mcl_inventory") or not rawget(_G, "mcl_player") then
	error("[inventory_tweaks] This mod requires Mineclonia and its native inventory/player APIs.")
end

local function boolean(name, default)
	return core.settings:get_bool("inventory_tweaks." .. name, default)
end
local function number(name, default, minimum, maximum)
	local value = tonumber(core.settings:get("inventory_tweaks." .. name))
	if not value or value ~= value then return default end
	return math.max(minimum, math.min(maximum, value))
end

inventory_tweaks = {
	version = "1.0.3", core = core, path = path, S = core.get_translator(modname),
	config = {
		enabled = boolean("enabled", true),
		enable_refill = boolean("enable_refill", true),
		enable_transfers = boolean("enable_transfers", true),
		enable_undo = boolean("enable_undo", true),
		max_slots = math.floor(number("max_slots", 512, 90, 512)),
		cooldown = number("cooldown", 0.15, 0.05, 5),
		session_timeout = number("session_timeout", 1800, 60, 7200),
	},
}
if not inventory_tweaks.config.enabled then
	core.log("action", "[inventory_tweaks] Disabled by server setting.")
	return
end

for _, module in ipairs({
	"util", "tool_identity", "categories", "rules", "sort", "preferences", "transaction",
	"actions", "refill", "ui", "integration",
}) do
	dofile(path .. "/lib/" .. module .. ".lua")(inventory_tweaks)
end
core.log("action", "[inventory_tweaks] Loaded " .. inventory_tweaks.version .. " for Mineclonia.")
