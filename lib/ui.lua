-- Native formspec controls; no client mod, key binding or texture download.
return function(M)
local core, U, S = M.core, M.util, M.S
local UI = {states = {}, player_tokens = {}, sequence = 0}
local settings_field = "__" .. M.modname .. "_settings"
M.ui = UI
local F = core.formspec_escape
local tabs = {{"organize", S("Organize")}, {"slots", S("Protected slots")}, {"rules", S("Rules & profiles")}, {"settings", S("Settings")}, {"help", S("Help")}}
local orders = {"category", "name", "count", "wear"}
local order_labels = {S("Category"), S("Item identifier"), S("Total quantity"), S("Wear (least first)")}
local layouts = {"compact", "columns", "merge"}
local rule_keys = {"rules", "container_rules", "large_container_rules"}
local threshold_values = {50, 75, 80, 85, 90, 95, 98, 99}
local help_topics = {
	{id = "protection", title = S("Slot protection"), blocks = {
		{text = S("Click a slot to cycle Free → Locked → Frozen. Changes save immediately.")},
		{heading = S("Locked"), symbol = "L", text = S("Keeps the slot unchanged during sorting, balancing and bulk moves. Player slots can still be refilled.")},
		{heading = S("Frozen"), symbol = "F", text = S("Excludes the slot from all Inventory Tweaks item actions.")},
		{heading = S("Hotbar safeguard"), symbol = "H", text = S("Marks the separate hotbar safeguard. Turn off the hotbar checkbox to let sorting arrange those slots.")},
		{heading = S("Protection set by rules"), text = S("If a slot is protected by a rule, edit that rule in Rules & profiles. Clearing a grid setting does not remove rule protection.")},
		{text = S("Sorting leaves empty protected slots empty. You can still move items manually. Protected storage cells are excluded from Restock.")},
	}, links = {"rules"}},
	{id = "rules", title = S("Sorting rules"), blocks = {
		{heading = S("Choose the inventory"), text = S("Player: A–C are backpack rows and D is the hotbar. Storage: A–C for 27 slots, A–F for 54 slots. Columns are numbered 1–9.")},
		{heading = S("Write one rule per line"), text = S("A1 selects one slot, B a whole row, and C1-C3 a range. Lines starting with # are comments."), code = "A1 group:pickaxe\nB category:wood\nC1-C3 category:stone\nD /LOCKED\nD9 /FROZEN"},
		{heading = S("Priority and overflow"), text = S("Earlier rules take matching items first. Remaining items use later rules, then free cells. Rules do not reserve unused slots. Protected slots take priority. Merge stacks does not apply placement rules.")},
		{heading = S("Building example"), text = S("Wood and stone also match category:building. Exclude them from A so that B receives wood, C receives stone, and A receives other building blocks."), code = "A category:building & !category:wood & !category:stone\nB category:wood\nC category:stone"},
	}, links = {"categories", "profiles"}},
	{id = "categories", title = S("Categories"), blocks = {
		{heading = S("Match items"), text = S("Use an item identifier, a group, or a category:"), code = "mcl_core:stone\ngroup:pickaxe\ncategory:food"},
		{heading = S("Combine selectors"), text = S("Use & for all conditions, | for either alternative, and ! to exclude. & applies within each alternative. * matches everything; inside an item identifier, * matches any text and ? one character.")},
		{heading = S("Create a category"), text = S("Write one name = selector definition per line, then use category:name in a rule."), code = "supplies = group:torch | category:food"},
		{text = S("Use the category in a rule:"), code = "A category:supplies"},
		{text = S("Names start with a lowercase letter and use lowercase letters, digits or underscores. Built-in names cannot be replaced.")},
		{text = S("Custom categories come first in Category sorting, in their written order. Items can match more than one category.")},
	}, links = {"rules", "refill"}},
	{id = "profiles", title = S("Profiles"), blocks = {
		{text = S("Choose a profile at the top. Each profile keeps its own name, player and storage rules, categories, slot protection, sort order and default layout.")},
		{heading = S("Save or discard editor changes"), text = S("Save rules saves the active profile's name, categories and all three rule targets. Discard edits restores that profile's saved editor contents.")},
		{text = S("Drafts survive navigation within this window, including Help and profile changes. Closing the window discards unsaved drafts.")},
		{heading = S("What saves immediately"), text = S("Checkboxes, grid protection, sort order and layout save immediately. The hotbar safeguard, refill filter and other Settings options are shared across profiles.")},
	}, links = {"rules"}},
	{id = "refill", title = S("Refill filter"), blocks = {
		{text = S("Enter a selector without a slot address. It limits automatic replacement and repair switching.")},
		{heading = S("Filter examples"), text = S("* allows any item. The other examples allow tools or food, or building blocks."), code = "*\ncategory:tool | category:food\ngroup:building_block"},
		{text = S("Use Save filter to apply your changes, or Discard edits to restore the saved filter. Manual Refill hotbar and Restock actions do not use this filter.")},
		{heading = S("Using custom categories"), text = S("The filter is shared across profiles. Define any category it names in every profile where you use it. If a profile reports an unknown category, switch back to a valid profile or save *.")},
	}, links = {"categories"}},
}
local help_by_id = {}
for _, topic in ipairs(help_topics) do help_by_id[topic.id] = topic end

local function nonce(prefix)
	UI.sequence = UI.sequence + 1
	return prefix .. tostring(UI.sequence)
end

function UI.player_token(player)
	local name = player:get_player_name()
	UI.player_tokens[name] = UI.player_tokens[name] or nonce("p")
	return UI.player_tokens[name]
end

local function label(x, y, text)
	return ("label[%g,%g;%s]"):format(x, y, F(text))
end

local function button(x, y, w, h, name, text, tooltip)
	local out = ("button[%g,%g;%g,%g;%s;%s]"):format(x, y, w, h, name, F(text))
	if tooltip then out = out .. "tooltip[" .. name .. ";" .. F(tooltip) .. "]" end
	return out
end

local function readonly(x, y, w, h, text)
	return ("textarea[%g,%g;%g,%g;;;%s]"):format(x, y, w, h, F(text))
end

local function dropdown(x, y, w, name, values, selected)
	local escaped = {}
	for i, value in ipairs(values) do escaped[i] = F(value) end
	return ("dropdown[%g,%g;%g,0.55;%s;%s;%d;true]"):format(x, y, w, name, table.concat(escaped, ","), selected)
end

local function index_of(list, value)
	for i, item in ipairs(list) do if item == value then return i end end
	return 1
end

-- Resolve first so translated markup is escaped as text, not interpreted as
-- new tags by the client. Colors and actions belong to the trusted renderer.
local function help_plain(player, text)
	local info = core.get_player_information(player:get_player_name()) or {}
	local translated = core.get_translated_string(info.lang_code or "", text)
	return core.hypertext_escape(core.strip_colors(translated))
end

local help_style = '<global color="#323232" background="none" margin="6" valign="top">'
	.. '<tag name="action" color="#24567A" hovercolor="#173D59">'
local help_link_style = '<global color="#323232" background="none" margin="0" valign="middle">'
	.. '<tag name="action" color="#24567A" hovercolor="#173D59">'

local function help_action(player, name, text)
	-- Use the native u tag: Luanti 5.17 does not retain a custom tag's
	-- underline="true" value through its generic style-attribute parser.
	return '<action name="' .. name .. '"><u>' .. help_plain(player, text) .. '</u></action>'
end

local function help_link(player, x, y, w, h, topic)
	local markup = help_link_style .. help_action(player, topic, S("Help: @1", help_by_id[topic].title))
	return ("hypertext[%g,%g;%g,%g;it_help_link_%s;%s]"):format(x, y, w, h, topic, F(markup))
end

function UI.toolbar(player, scope, opts)
	opts = opts or {}
	local token = opts.token or UI.player_token(player)
	local x, y = opts.x or 9.35, opts.y or 5.2
	local out = {( "box[%g,%g;1.5,0.32;#C6C6C6]" ):format(x - 0.03, y - 0.01)}
	local controls = {
		{"compact", "Z", S("Sort and merge compatible stacks")},
		{"columns", "||", S("Sort in grouped columns")},
		{"settings", "...", S("Inventory and chests settings / more actions")},
	}
	for i, control in ipairs(controls) do
		local name = "it_" .. scope .. "_" .. control[1] .. "_" .. token
		out[#out + 1] = button(x + (i - 1) * 0.5, y, 0.45, 0.30, name, control[2], control[3])
	end
	return table.concat(out)
end

local function sound(player)
	if M.preferences.get(player).sounds then core.sound_play("mesecons_button_push", {to_player = player:get_player_name(), gain = 0.15}, true) end
end

function UI.handle_toolbar(player, fields, ctx)
	if fields.quit or not U.player_ok(player) then return false end
	if ctx and not M.integration.context_valid(player, ctx) then return false end
	local requested
	for _, scope in ipairs({"player", "container"}) do
		local token = scope == "player" and UI.player_token(player) or (ctx and ctx.token)
		if token then
			for _, action in ipairs({"compact", "columns", "settings"}) do
				if fields["it_" .. scope .. "_" .. action .. "_" .. token] then
					if requested then return false end -- ambiguous forged multi-action packet
					requested = {scope = scope, action = action}
				end
			end
		end
	end
	if not requested then return false end
	if requested.action == "settings" then UI.show(player, "organize", ctx); return true end
	local ok, message
	if requested.scope == "player" then ok, message = M.actions.sort_player(player, requested.action)
	else ok, message = M.actions.sort_container(player, ctx, requested.action) end
	if not ok then U.message(player, message) else sound(player) end
	return true
end

local function draft_for(state, prefs)
	local active = prefs.active
	if not state.drafts[active] then state.drafts[active] = U.copy(prefs.profiles[active]) end
	return state.drafts[active]
end

local function player_grid(player, y)
	local bg = rawget(_G, "mcl_formspec") and mcl_formspec.get_itemslot_bg_v4
	local out = {bg and bg(1.3, y, 9, 3) or "", "list[current_player;main;1.3," .. y .. ";9,3;9]"}
	out[#out + 1] = bg and bg(1.3, y + 3.95, 9, 1) or ""
	out[#out + 1] = "list[current_player;main;1.3," .. (y + 3.95) .. ";9,1;]"
	return table.concat(out)
end

local function organize(player, state, prefs)
	local out = {label(0.45, 2.15, S("Your inventory"))}
	for i, spec in ipairs({
		{"compact", S("Sort"), S("Merge compatible stacks and sort by the selected order.")},
		{"columns", S("Columns"), S("Group identical items into columns when space allows.")},
		{"merge", S("Merge stacks"), S("Fill partial stacks without rearranging other items.")},
	}) do
		out[#out + 1] = button(0.45 + (i - 1) * 4.35, 2.4, 4.05, 0.55, "it_sort_" .. spec[1], spec[2], spec[3])
	end
	out[#out + 1] = button(0.45, 3.08, 3, 0.55, "it_refill", S("Refill hotbar"), S("Top up existing hotbar stacks from the backpack; frozen slots are excluded."))
	out[#out + 1] = button(3.7, 3.08, 3, 0.55, "it_balance", S("Balance stacks"), S("Even quantities in existing compatible stacks without moving their slots."))
	out[#out + 1] = button(6.95, 3.08, 3, 0.55, "it_undo", S("Undo last action"), S("Available for two minutes while every affected inventory is unchanged and accessible."))
	out[#out + 1] = dropdown(10.2, 3.08, 3, "it_order", order_labels, index_of(orders, prefs.profiles[prefs.active].order))
	local valid = state.ctx and M.integration.context_valid(player, state.ctx)
	if valid then
		out[#out + 1] = readonly(0.45, 3.78, 12.75, 0.45, S("Open storage: @1", state.ctx.title or S("Container")))
		local specs = {
			{"storage_sort", S("Sort storage")},
			{"deposit_all", S("Deposit all"), S("Move unprotected items into storage.")},
			{"deposit_matching", S("Deposit matching"), S("Move matching stacks already present in storage.")},
			{"take_all", S("Take all"), S("Take items into available unprotected slots.")},
			{"restock", S("Restock"), S("Top up your existing stacks from storage, including the hotbar.")},
		}
		for i, spec in ipairs(specs) do out[#out + 1] = button(0.45 + (i - 1) * 2.6, 4.28, 2.4, 0.55, "it_" .. spec[1], spec[2], spec[3]) end
		out[#out + 1] = button(0.45, 4.98, 2.4, 0.55, "it_take_matching", S("Take matching"), S("Take matching stacks already present in your inventory."))
	else
		out[#out + 1] = readonly(0.45, 3.9, 12.75, 0.5, S("No storage selected."))
	end
	out[#out + 1] = player_grid(player, 5.78)
	return table.concat(out)
end

-- Native item descriptions may contain nested translation escapes. Resolve an
-- oversized description before truncating, and cut only at a UTF-8 boundary.
local function short_description(player, item)
	local text = item:get_short_description()
	if #text <= 160 then return text end
	local info = core.get_player_information(player:get_player_name()) or {}
	text = core.strip_colors(core.get_translated_string(info.lang_code or "", text))
	if #text <= 160 then return text end
	local boundary = 158 -- Leave three bytes for the ellipsis.
	while boundary > 1 do
		local byte = text:byte(boundary)
		if byte < 128 or byte >= 192 then break end
		boundary = boundary - 1
	end
	return text:sub(1, boundary - 1) .. "…"
end

local function slots(player, state, prefs)
	local out = {readonly(0.45, 2.05, 12.7, 0.78, S("Click a slot to change its protection."))}
	out[#out + 1] = "checkbox[0.5,3.0;it_keep_hotbar;" .. F(core.colorize("#323232", S("Keep the hotbar out of sorting and bulk transfers"))) .. ";" .. tostring(prefs.keep_hotbar) .. "]"
	out[#out + 1] = "tooltip[it_keep_hotbar;" .. F(S("Preserve hotbar slots during sorting and bulk transfers. Refill can still top up existing stacks.")) .. "]"
	local cfg = M.preferences.compile(player)
	local profile = prefs.profiles[prefs.active]
	for visual, i in ipairs(M.rules.grid(36, 9, true)) do
		local row, col = math.floor((visual - 1) / 9), (visual - 1) % 9
		local x, y = 1.3 + col * 1.25, 3.8 + row * 1.35 + (row == 3 and 0.28 or 0)
		local value = profile.locks[tostring(i)] or 0
		local from_rule = cfg and (cfg.rules.frozen[i] and 2 or cfg.rules.locked[i] and 1)
		local effective = math.max(value, from_rule or 0)
		local marker = effective == 2 and "F" or effective == 1 and "L" or (i <= 9 and prefs.keep_hotbar and "H" or "")
		local color = marker == "F" and "#5D89B7" or marker ~= "" and "#B38C42" or "#888888"
		local item = player:get_inventory():get_stack("main", i)
		local name = "it_lock_" .. i
		out[#out + 1] = ("box[%g,%g;1.1,1.1;%s]"):format(x - 0.05, y - 0.05, color)
		out[#out + 1] = "style[" .. name .. ";border=false;bgimg=;bgimg_pressed=;textcolor=#FFFFFF]"
		out[#out + 1] = ("item_image_button[%g,%g;1,1;%s;%s;%s]"):format(x, y, F(item:get_name()), name, marker)
		local title = S("@1 — @2", M.rules.slot_label(i, 36, 9, true),
			marker == "F" and S("Frozen") or marker == "L" and S("Locked") or marker == "H" and S("Hotbar safeguard") or S("Free"))
		if from_rule then title = S("@1 (set by a rule)", title) end
		if not item:is_empty() then title = title .. "\n" .. S("@1 × @2", short_description(player, item), item:get_count()) end
		out[#out + 1] = "tooltip[" .. name .. ";" .. F(title) .. "]"
	end
	for row = 1, 4 do out[#out + 1] = label(0.55, 4.3 + (row - 1) * 1.35 + (row == 4 and 0.28 or 0), string.char(64 + row)) end
	out[#out + 1] = help_link(player, 0.55, 9.65, 12.5, 0.8, "protection")
	return table.concat(out)
end

local function rules_page(player, state, prefs)
	local draft = draft_for(state, prefs)
	local key = rule_keys[state.rule_target]
	return table.concat({
		"field[0.5,2.55;6.2,0.58;it_profile_name;" .. F(S("Profile name")) .. ";" .. F(draft.name) .. "]field_close_on_enter[it_profile_name;false]",
		dropdown(6.95, 2.55, 6.15, "it_rule_target", {S("Player inventory"), S("Storage (27 slots)"), S("Double chest (54 slots)")}, state.rule_target),
		"textarea[0.5,3.6;6.05,5.95;it_rules;" .. F(S("Placement and protection rules")) .. ";" .. F(draft[key] or "") .. "]",
		"textarea[6.95,3.6;6.15,5.95;it_categories;" .. F(S("Custom categories")) .. ";" .. F(draft.categories) .. "]",
		help_link(player, 0.5, 9.55, 6.05, 0.52, "rules"),
		help_link(player, 6.95, 9.55, 6.15, 0.52, "categories"),
		help_link(player, 0.5, 10.09, 12.6, 0.5, "profiles"),
		button(0.5, 10.66, 3.0, 0.55, "it_save_rules", S("Save rules")),
		button(3.75, 10.66, 3.0, 0.55, "it_discard_rules", S("Discard edits")),
		readonly(7.0, 10.6, 6.1, 0.65, S("Only saved, validated rules take effect.")),
	})
end

local setting_rows = {
	{"auto_refill", S("Automatically replace used-up stacks"), S("Replace a used-up stack from your backpack.")},
	{"refill_tools", S("Replace broken tools"), S("Replace a broken tool with a spare from your backpack.")},
	{"tool_fallback", S("Allow another material of the same tool type"), S("Allow a different material when no matching tool is available. Enchantments may differ.")},
	{"repair_switch", S("Switch worn tools before they break"), S("Swap a worn tool for a healthier spare and keep the old tool.")},
	{"pickup_organize", S("Keep new pickups out of unused hotbar slots"), S("Move new items from unused hotbar slots into the backpack.")},
	{"reserve_hud", S("Show held-item reserve counter"), S("Show how many matching items are available in your backpack.")},
	{"sounds", S("Play a quiet click after an action"), S("Play a quiet click when an action succeeds.")},
}

local function settings_page(player, state, prefs)
	local out = {readonly(0.45, 2.05, 12.7, 0.5, S("Settings are personal and saved on this server."))}
	for i, row in ipairs(setting_rows) do
		local y = 2.9 + (i - 1) * 0.68
		out[#out + 1] = ("checkbox[0.6,%g;it_%s;%s;%s]tooltip[it_%s;%s]"):format(y, row[1], F(core.colorize("#323232", row[2])), tostring(prefs[row[1]]), row[1], F(row[3]))
	end
	local threshold_labels = {}
	for i, value in ipairs(threshold_values) do threshold_labels[i] = S("@1% worn", value) end
	out[#out + 1] = label(0.6, 8.55, S("Repair switch threshold"))
	out[#out + 1] = dropdown(5.3, 8.25, 3.1, "it_threshold", threshold_labels, index_of(threshold_values, prefs.repair_threshold))
	out[#out + 1] = "tooltip[it_threshold;" .. F(S("Switch when tool wear reaches this percentage.")) .. "]"
	out[#out + 1] = dropdown(9.0, 8.25, 4.1, "it_layout", {S("Default: compact"), S("Default: columns"), S("Default: merge only")}, index_of(layouts, prefs.profiles[prefs.active].layout))
	local filter = state.refill_filter_draft == nil and prefs.refill_filter or state.refill_filter_draft
	out[#out + 1] = "field[0.6,9.55;6.8,0.6;it_refill_filter;" .. F(S("Automatic replacement filter")) .. ";" .. F(filter) .. "]field_close_on_enter[it_refill_filter;false]"
	out[#out + 1] = "tooltip[it_refill_filter;" .. F(S("Choose which items can be replaced automatically.")) .. "]"
	out[#out + 1] = button(7.75, 9.55, 2.5, 0.6, "it_save_filter", S("Save filter"))
	out[#out + 1] = button(10.5, 9.55, 2.6, 0.6, "it_discard_filter", S("Discard edits"))
	out[#out + 1] = help_link(player, 0.6, 10.35, 12.5, 0.7, "refill")
	return table.concat(out)
end

local function return_tab(state)
	for _, tab in ipairs(tabs) do
		if tab[1] == state.help_return and tab[1] ~= "help" then return tab[1], tab[2] end
	end
	return tabs[1][1], tabs[1][2]
end

local function help_page(player, state)
	local selected, titles = 1, {}
	local topic = help_by_id[state.help_topic] or help_by_id.rules
	for i, entry in ipairs(help_topics) do
		titles[i] = entry.title
		if entry == topic then selected = i end
	end
	local paragraphs = {help_style .. '<big><b>' .. help_plain(player, topic.title) .. '</b></big>'}
	for _, block in ipairs(topic.blocks) do
		local parts = {}
		if block.heading then
			parts[#parts + 1] = '<b>' .. (block.symbol and block.symbol .. ' — ' or '')
				.. help_plain(player, block.heading) .. '</b>'
		end
		if block.text then parts[#parts + 1] = help_plain(player, block.text) end
		if block.code then parts[#parts + 1] = '<mono>' .. core.hypertext_escape(block.code) .. '</mono>' end
		paragraphs[#paragraphs + 1] = table.concat(parts, "\n")
	end
	local links = {}
	for _, target in ipairs(topic.links) do
		links[#links + 1] = help_action(player, target, S("Help: @1", help_by_id[target].title))
	end
	paragraphs[#paragraphs + 1] = table.concat(links, "\n")
	local _, back_title = return_tab(state)
	local back = help_link_style .. help_action(player, "return", S("Back to @1", back_title))
	return table.concat({
		label(0.55, 2.2, S("Help topic")),
		dropdown(0.55, 2.47, 12.55, "it_help_topic", titles, selected),
		"hypertext[0.55,3.22;12.55,7.48;it_help_body;" .. F(table.concat(paragraphs, "\n\n")) .. "]",
		"hypertext[0.55,10.8;12.55,0.5;it_help_return;" .. F(back) .. "]",
	})
end

function UI.render(player, state)
	local prefs = M.preferences.get(player)
	local recovery = M.preferences.recovery and M.preferences.recovery[player:get_player_name()]
	local native = rawget(_G, "mcl_vars")
	local styles = native and native.gui_nonbg or "style_type[label,textarea,checkbox,field;textcolor=#313131]"
	local out = {
		"formspec_version[6]size[13.6,12.15]no_prepend[]", styles,
		"bgcolor[#00000080;true]background9[0,0;13.6,12.15;mcl_base_textures_background9.png;false;7]",
		label(0.45, 0.5, S("Inventory and chests settings")), label(7.45, 0.5, S("Profile")),
		dropdown(9.0, 0.22, 4.15, "it_profile", {prefs.profiles[1].name, prefs.profiles[2].name, prefs.profiles[3].name}, prefs.active),
		"tooltip[it_profile;" .. F(S("Each profile keeps its own rules, categories and slot protection.")) .. "]",
	}
	for i, tab in ipairs(tabs) do
		local name = "it_tab_" .. tab[1]
		if state.tab == tab[1] then out[#out + 1] = "style[" .. name .. ";bgcolor=#999999]" end
		out[#out + 1] = button(0.45 + (i - 1) * 2.6, 1.12, 2.4, 0.65, name, tab[2])
	end
	if recovery then
		out[#out + 1] = readonly(0.55, 2.2, 12.5, 1.3,
			S("Saved settings could not be loaded safely. Sorting, transfers, undo and replacement are paused so damaged slot protection cannot be ignored."))
		out[#out + 1] = readonly(0.55, 3.7, 12.5, 1.9, recovery)
		out[#out + 1] = readonly(0.55, 6.0, 12.5, 1.8,
			S("Your original saved data has not been overwritten. Reset creates the three default profiles and default personal settings. The previous raw data is retained in server-side player metadata for administrator recovery."))
		out[#out + 1] = button(0.55, 8.3, 5.0, 0.65, "it_reset_damaged", S("Reset damaged settings"))
	elseif state.tab == "organize" then out[#out + 1] = organize(player, state, prefs)
	elseif state.tab == "slots" then out[#out + 1] = slots(player, state, prefs)
	elseif state.tab == "rules" then out[#out + 1] = rules_page(player, state, prefs)
	elseif state.tab == "settings" then out[#out + 1] = settings_page(player, state, prefs)
	else out[#out + 1] = help_page(player, state) end
	local notice = state.notice
	if not notice and not recovery then
		local compiled, error_text = M.preferences.compile(player)
		if not compiled then notice = S("Settings error: @1 Check Rules & profiles or the refill filter.", error_text) end
	end
	if notice then out[#out + 1] = readonly(0.45, 11.34, 8.65, 0.6, notice) end
	out[#out + 1] = button(9.25, 11.38, 1.8, 0.55, "it_back", state.ctx and S("Back to storage") or S("Inventory"))
	out[#out + 1] = "button_exit[11.3,11.38;1.85,0.55;it_done;" .. F(S("Done")) .. "]"
	return table.concat(out)
end

local function redraw(player, state)
	core.show_formspec(player:get_player_name(), state.formname, UI.render(player, state))
end

function UI.show(player, tab, ctx)
	local ok, err = U.player_ok(player)
	if not ok then U.message(player, err); return false end
	local valid_tab = false
	for _, item in ipairs(tabs) do if item[1] == tab then valid_tab = true end end
	tab = valid_tab and tab or "organize"
	local token = nonce("m")
	local state = {token = token, formname = M.modname .. ":manager_" .. token, tab = tab, ctx = ctx,
		rule_target = 1, drafts = {}, help_topic = "rules", help_return = "organize"}
	UI.states[player:get_player_name()] = state
	redraw(player, state)
	return true
end

local function capture_draft(state, prefs, fields)
	if state.tab == "settings" and fields.it_refill_filter ~= nil then
		if type(fields.it_refill_filter) ~= "string" or #fields.it_refill_filter > 512 then return false end
		state.refill_filter_draft = fields.it_refill_filter
	end
	if state.tab ~= "rules" then return true end
	local draft = draft_for(state, prefs)
	for _, spec in ipairs({{"it_rules", rule_keys[state.rule_target]}, {"it_categories", "categories"}, {"it_profile_name", "name"}}) do
		local value = fields[spec[1]]
		if value ~= nil then
			if type(value) ~= "string" or #value > (spec[2] == "name" and 32 or 8192) then return false end
			draft[spec[2]] = value
		end
	end
	return true
end

local help_sources = {protection = "slots", rules = "rules", categories = "rules", profiles = "rules", refill = "settings"}

-- Native hypertext actions submit "action:<name>". Keep their destinations
-- fixed, reuse the current editor session, and never fall through to a save or
-- item action when a help event is present (including malformed combinations).
local function help_navigation(state, fields)
	local requests, invalid, destination, back = 0, false, nil, false
	if fields.it_tab_help then
		requests = requests + 1
		destination = help_by_id[state.help_topic] and state.help_topic or "rules"
	end
	for key, value in pairs(fields) do
		if key:sub(1, 8) == "it_help_" and key ~= "it_help_topic" then
			requests = requests + 1
			local contextual = key:match("^it_help_link_(%a+)$")
			if contextual and help_sources[contextual] == state.tab and value == "action:" .. contextual then
				destination = contextual
			elseif key == "it_help_return" and state.tab == "help" and value == "action:return" then
				back = true
			elseif key == "it_help_body" and state.tab == "help" then
				local target = value:match("^action:(%a+)$")
				local topic = help_by_id[state.help_topic] or help_by_id.rules
				local allowed = false
				for _, link in ipairs(topic.links) do if link == target then allowed = true end end
				if allowed then destination = target else invalid = true end
			else invalid = true end
		end
	end
	if fields.it_help_topic then
		local selected = tonumber(fields.it_help_topic)
		if state.tab ~= "help" or not selected or selected ~= math.floor(selected) or not help_topics[selected] then
			requests, invalid = requests + 1, true
		elseif help_topics[selected].id ~= state.help_topic then
			requests, destination = requests + 1, help_topics[selected].id
		end
		-- An unchanged dropdown index accompanies other native button events.
	end
	if requests == 0 then return false end
	if requests == 1 and not invalid then
		if back then state.tab = return_tab(state)
		else
			if state.tab ~= "help" then state.help_return = state.tab end
			state.tab, state.help_topic = "help", destination
		end
	end
	return true
end

function UI.receive(player, formname, fields)
	local name = player:get_player_name()
	if fields[settings_field] and not fields.quit then
		-- Consume our settings-icon event after opening its menu. A native
		-- settings refresh from submitted dropdown fields must not replace it.
		return UI.show(player, "settings", M.integration and M.integration.get_context(player)) or false
	end
	local state = UI.states[name]
	if not state or formname ~= state.formname then return false end
	if fields.quit then
		UI.states[name] = nil
		if M.integration then M.integration.clear_context(player) end
		return false
	end
	local ok, err = U.player_ok(player)
	if not ok then state.notice = err; redraw(player, state); return false end
	local total = 0
	for key, value in pairs(fields) do
		if type(key) ~= "string" or type(value) ~= "string" then return false end
		total = total + #key + #value
		if total > 24000 then return false end
	end
	local prefs = U.copy(M.preferences.get(player))
	if not capture_draft(state, prefs, fields) then state.notice = S("An editor field exceeded its size limit."); redraw(player, state); return false end
	if state.ctx and M.integration.touch_context then M.integration.touch_context(player, state.ctx) end
	state.notice = nil
	local recovery = M.preferences.recovery and M.preferences.recovery[name]
	if not recovery and help_navigation(state, fields) then redraw(player, state); return false end
	if fields.it_back then
		if state.ctx then
			ok, err = state.ctx.refresh(player)
			if ok then UI.states[name] = nil; return false end
			state.notice = err
		else
			UI.states[name] = nil
			if mcl_inventory and mcl_inventory.show_inventory then mcl_inventory.show_inventory(player) end
			return false
		end
	end
	if recovery then
		if fields.it_reset_damaged then
			ok, err = M.preferences.reset_damaged(player)
			if ok then
				state.drafts, state.refill_filter_draft, state.tab = {}, nil, "settings"
				state.notice = S("Default settings restored. The previous raw data was saved for administrator recovery.")
			else state.notice = err end
		end
		redraw(player, state)
		return false
	end
	local profile_index = tonumber(fields.it_profile)
	if profile_index and profile_index == math.floor(profile_index) and profile_index >= 1 and profile_index <= 3 and profile_index ~= prefs.active then
		prefs.active = profile_index
		ok, err = M.preferences.save(player, prefs)
		state.notice = ok and S("Profile selected.") or err
		redraw(player, state)
		return false
	end
	for _, tab in ipairs(tabs) do if fields["it_tab_" .. tab[1]] then state.tab = tab[1]; break end end
	local target = tonumber(fields.it_rule_target)
	if target and target == math.floor(target) and rule_keys[target] then state.rule_target = target end
	local settings_changed = false
	local keep_hotbar = fields.it_keep_hotbar
	if keep_hotbar == "true" or keep_hotbar == "false" then
		local selected = keep_hotbar == "true"
		if selected ~= prefs.keep_hotbar then prefs.keep_hotbar = selected; settings_changed = true end
	end
	for _, row in ipairs(setting_rows) do
		local value = fields["it_" .. row[1]]
		if value == "true" or value == "false" then
			local selected = value == "true"
			if selected ~= prefs[row[1]] then prefs[row[1]] = selected; settings_changed = true end
		end
	end
	for _, spec in ipairs({{"it_order", orders, "order"}, {"it_layout", layouts, "layout"}}) do
		local selected = tonumber(fields[spec[1]])
		if selected and spec[2][selected] and prefs.profiles[prefs.active][spec[3]] ~= spec[2][selected] then
			prefs.profiles[prefs.active][spec[3]] = spec[2][selected]; settings_changed = true
		end
	end
	local threshold = tonumber(fields.it_threshold)
	if threshold and threshold_values[threshold] and prefs.repair_threshold ~= threshold_values[threshold] then
		prefs.repair_threshold = threshold_values[threshold]; settings_changed = true
	end
	if settings_changed then
		ok, err = M.preferences.save(player, prefs)
		state.notice = ok and S("Settings saved.") or err
	end
	if fields.it_save_filter then
		local text = state.refill_filter_draft or fields.it_refill_filter
		local categories = M.categories.compile(prefs.profiles[prefs.active].categories)
		local predicate, reason
		if type(text) == "string" and #text <= 512 and categories then predicate, reason = M.categories.selector(text, categories) end
		if predicate then
			prefs.refill_filter = text
			ok, err = M.preferences.save(player, prefs)
			if ok then state.refill_filter_draft = nil end
			state.notice = ok and S("Refill filter saved.") or err
		else state.notice = reason or S("Invalid refill selector (maximum 512 bytes).") end
	elseif fields.it_discard_filter then
		state.refill_filter_draft = nil; state.notice = S("Unsaved refill filter discarded.")
	end
	if fields.it_save_rules then
		local draft = draft_for(state, prefs)
		local value, reason = M.preferences.validate_edit(player, {rules = draft.rules, container_rules = draft.container_rules,
			large_container_rules = draft.large_container_rules, categories = draft.categories, profile_name = draft.name})
		if value then ok, err = M.preferences.save(player, value); state.notice = ok and S("Rules saved and validated.") or err
		else state.notice = reason end
	elseif fields.it_discard_rules then
		state.drafts[prefs.active] = nil; state.notice = S("Unsaved rule edits discarded.")
	end
	for i = 1, 36 do
		if fields["it_lock_" .. i] and state.tab == "slots" then
			local cfg = M.preferences.compile(player)
			if cfg and (cfg.rules.locked[i] or cfg.rules.frozen[i]) then state.notice = S("This slot is protected by a rule. Edit that rule to change it.")
			else
				local locks = prefs.profiles[prefs.active].locks
				local value = ((locks[tostring(i)] or 0) + 1) % 3
				locks[tostring(i)] = value ~= 0 and value or nil
				ok, err = M.preferences.save(player, prefs); state.notice = ok and S("Slot protection saved.") or err
			end
			break
		end
	end
	local action, requested = nil, 0
	local function request(field, fn)
		if fields[field] then action = fn; requested = requested + 1 end
	end
	for _, layout in ipairs(layouts) do local mode = layout; request("it_sort_" .. layout, function() return M.actions.sort_player(player, mode) end) end
	request("it_refill", function() return M.actions.refill_hotbar(player) end)
	request("it_balance", function() return M.actions.balance(player) end)
	request("it_undo", function() return M.actions.undo(player) end)
	request("it_storage_sort", function() return M.actions.sort_container(player, state.ctx) end)
	for _, transfer in ipairs({"deposit_all", "deposit_matching", "take_all", "take_matching", "restock"}) do
		local mode = transfer; request("it_" .. transfer, function() return M.actions.transfer(player, state.ctx, mode) end)
	end
	if requested == 1 then ok, state.notice = action(); if ok then sound(player) end
	elseif requested > 1 then state.notice = S("Choose one inventory action at a time.") end
	redraw(player, state)
	return false
end

core.register_on_player_receive_fields(UI.receive)
core.register_on_mods_loaded(function()
	if mcl_player and mcl_player.register_player_settings_button then
		mcl_player.register_player_settings_button({field = settings_field, icon = "mcl_player_settings.png",
			description = S("Inventory Tweaks"), priority = 10})
	end
end)
core.register_chatcommand("inv", {
	params = "[sort|columns|merge|refill|undo|settings]",
	description = S("Open Inventory Tweaks or organize your inventory"), privs = {interact = true},
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, S("A connected player is required.") end
		param = U.trim(param)
		if param == "" or param == "settings" then
			UI.show(player, param == "settings" and "settings" or "organize", M.integration and M.integration.get_context(player))
			return true
		elseif param == "sort" then return M.actions.sort_player(player)
		elseif param == "columns" or param == "merge" then return M.actions.sort_player(player, param)
		elseif param == "refill" then return M.actions.refill_hotbar(player)
		elseif param == "undo" then return M.actions.undo(player) end
		return false, S("Use /inv, /inv sort, /inv columns, /inv merge, /inv refill, /inv undo or /inv settings.")
	end,
})
core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	UI.states[name], UI.player_tokens[name] = nil, nil
end)
core.register_on_dieplayer(function(player) UI.states[player:get_player_name()] = nil end)
end
