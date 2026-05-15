local wezterm = require("wezterm")
local act = wezterm.action
--local layouts = ['top', 'right', 'column']
local layouts_name = { "bottom", "right", "column" }
local layouts = {}
local layouts_index = 1
--local l = require('layouts')

local getCommand = function(commandVar, ifnil)
	local handle = io.popen(commandVar)
	local output = nil
	if handle then
		output = handle:read("*a")
		handle:close()
	else
		output = ifnil
	end
	return output
end

local move = function(id)
	local _, _, _ = wezterm.run_child_process({ "wezterm", "cli", "move-pane-to-new-tab", "--pane-id", id })
end

local split = function(position, id, percentage)
	id = id or nil
	if id == nil then
		local _, _, _ = wezterm.run_child_process({ "wezterm", "cli", "split-pane", position })
	else
		local _, _, _ = wezterm.run_child_process({
			"wezterm",
			"cli",
			"split-pane",
			position,
			"--move-pane-id",
			id,
			"--percent",
			percentage,
		})
	end
end

local right = function(args)
	print("entering")
	if args.id == nil then
		if #args.pane:tab():panes() <= 1 then
			--pane:split {direction = 'Right'}
			split("--right")
		else
			--pane:split {direction = 'Bottom'}
			split("--bottom")
		end
	else
		if args.first_split then
			print("OHHHH OUUUUIIIIIII")
			--pane:split {direction = 'Right'}
			split("--right", args.id, args.first_percentage)
		else
			print("OHHHH NOOOOON" .. tostring(args.first_split))
			--pane:split {direction = 'Bottom'}
			split("--bottom", args.id, args.percentage)
		end
	end
end

local bottom = function(args)
	if args.id == nil then
		if #args.pane:tab():panes() <= 1 then
			split("--bottom")
		--pane:split {direction = 'Bottom'}
		else
			split("--right")
			--pane:split {direction = 'Right'}
		end
	else
		if args.first_split then
			split("--bottom", args.id, args.first_percentage)
		--pane:split {direction = 'Bottom'}
		else
			split("--right", args.id, args.percentage)
			--pane:split {direction = 'Right'}
		end
	end
end

local column = function(args)
	print("column layout")
	if args.id == nil then
		split("--right")
	else
		split("--right", args.id, args.percentage)
	end
end
layouts["bottom"] = bottom
layouts["right"] = right
layouts["column"] = column

local detect_tab = function(tabs, window, pane)
	local index = 0
	for _, v in ipairs(tabs) do
		print("is active? " .. tostring(v.is_active))
		if v.is_active == true then
			print("C EST LA BONNNNNE TAB son id est: " .. tostring(v.index))
			if v.is_active == true then
				print("C EST LA BONNNNNE TAB son id est: " .. v.index)
			end
			index = v.index
		end
	end
	local step = tabs[#tabs].index - index + 1
	print("the step is: " .. tostring(step))
	window:perform_action(wezterm.action.ActivateTabRelative(step), pane)
	window:perform_action(wezterm.action.MoveTabRelative(-step), pane)
end

local change_layout_bottom = function(pane_ids, pane, window)
	local args = { pane = pane, first_split = true, percentage = 100, first_percentage = 50 }
	local available_space = 100
	local size = #pane_ids
	local gap = 0
	local first_pane = true
	local tabs = pane:tab():window():tabs_with_info()
	for _, v in ipairs(pane_ids) do
		local v_string = tostring(v)
		if first_pane then
			print("ya moa dabord")
			move(v)
			detect_tab(tabs, window, pane)
			first_pane = false
		else
			print(
				"pourcentage vaut: "
					.. args.percentage
					.. " nombres de panes: "
					.. size
					.. " le gap est de : "
					.. gap
					.. " la taille disponible est de: "
					.. available_space
			)
			gap = math.floor(available_space / size)
			if args.percentage > 50 then
				args.percentage = available_space - gap
			end
			size = size - 1
			args.id = v_string
			layouts[layouts_name[layouts_index]](args)
			print("que les panes ids: " .. tostring(#pane_ids))
			--available_space = available_space - args.percentage
			--layouts[layouts_name[1]](args)
			if args.first_split == true then
				args.first_split = false
			end
		end
	end
end

local layout_incrementer = function()
	--layout_index = (layouts_index == #layouts_name) and 1 or layouts_index +1
	if layouts_index == #layouts_name then
		layouts_index = 1
	else
		layouts_index = layouts_index + 1
		-- print("layouts_index = "..tostring(layouts_index).. " la longueur de la liste = " ..#layouts_name)
		-- print(layouts_name[1])
	end
end
wezterm.on("flayouts", function(window, pane)
	--act.MoveTabRelative()
	--window:perform_action(wezterm.action.MoveTabRelative(-1), pane)
	--local _,tabs,_ = wezterm.run_child_process {"jq", "'.[]", "|", "select(.window_id==0)", "|", ".pane_id'"}
	print("tab id is: " .. pane:tab():tab_id())
	print(pane:tab():panes_with_info())
	--print(pane:tab():window():tabs_with_info())
	local panes = pane:tab():panes()

	local pane_ids = {}
	for _, v in ipairs(panes) do
		--print(v)
		local v_string = tostring(v)
		for pane_id in string.gmatch(v_string, "pane_id:(%d+)") do
			table.insert(pane_ids, pane_id)
		end
	end
	-- width_cell = pane:tab():panes_with_info()[1].width
	-- height_cell = pane:tab():panes_with_info()[1].height
	for _, v in ipairs(pane_ids) do
		print("les ids sont: " .. tostring(v))
	end
	change_layout_bottom(pane_ids, pane, window)

	--local _,tabs,_ = wezterm.run_child_process {'/bin/bash $HOME/wez.sh', pane:tab():tab_id()}
	--local tabs = getCommand('/bin/bash $HOME/wez.sh', "deso")
	--print("tabs lists: " ..tabs)
	layout_incrementer()
	--print("First Spawn " .. tostring(width_cell) .." ".. tostring(height_cell) )
end)

wezterm.on("make-layouts", function(_, pane)
	print(pane:tab():panes_with_info())
	local layout = layouts[layouts_name[layouts_index]]
	if layout then
		layout({ pane = pane })
	else
		print("MEGA ERROR: ")
		print(layouts_name)
		print(layouts_index)
	end
end)

wezterm.on("update-status", function(window, pane)
	-- demonstrates shelling out to get some external status.
	-- wezterm will parse escape sequences output by the
	-- child process and include them in the status area, too.
	--local success, stdout, stderr = wezterm.run_child_process { 'jq', '-r', '.name', '~/scripts/fete/day.json' }
	--local success, user, stderr = wezterm.run_child_process {'echo',os.getenv('USER')}
	-- user = string.gsub(user, "\n", "")
	-- print(string.format("%s %s %s", stdout, success, stderr))
	local command = "jq -r '.name' $HOME/scripts/fete/day.json"

	if pane == nil then
		return
	end
	if pane:tab() == nil then
		return
	end
	if pane:tab():panes() == nil then
		return
	end
	local panes_number
	if #pane:tab():panes() then
		panes_number = tostring(#pane:tab():panes())
	else
		panes_number = "oncpa"
	end

	--local output = getCommand(command, "dulamour")
	--local  success1, uname1, stderr = wezterm.run_child_process { 'uname', '-a', '|', 'cut', '-d', "' '", '-f2,3' }
	--print("the uname1 is: "..uname1.. "and success is: "..tostring(success1))
	local command1 = "uname -a | cut -d' ' -f2,3"
	--local command2= "echo $USER"
	local uname = getCommand(command1, "Oxidow")
	uname = string.gsub(uname, "\n", "")
	local fete = getCommand(command, "lamour")
	fete = string.gsub(fete, "\n", "")

	local success_date, date, stderr_date = wezterm.run_child_process({ "date" })
	if success_date then
		date = wezterm.strftime("%A %H:%M:%S %d-%m-%Y")
	else
		print(stderr_date)
	end

	-- However, if all you need is to format the date/time, then:

	-- Make it italic and underlined
	if not layouts_name[layouts_index] then
		return
	end
	window:set_right_status(wezterm.format({
		{ Attribute = { Underline = "Curly" } },
		{ Attribute = { Italic = true } },
		{
			Text = layouts_name[layouts_index]
				.. " "
				.. tostring(layouts_index)
				.. " "
				.. panes_number
				.. " "
				.. os.getenv("USER")
				.. " "
				.. uname
				.. " ",
		},
		{ Foreground = { AnsiColor = "Purple" } },
		{ Text = date .. " " },
		{ Foreground = { AnsiColor = "Lime" } },
		{ Text = string.format("bonne fête aux %s", fete) },
		-- {Text=date},
		-- {Text=user},
		-- {Text=fete},
		--{Text=date.. " bonne fete aux " ..fete.. " ".. user},
	}))
end)
return {
	--color_scheme = "tokyonight-storm",
	enable_kitty_keyboard = true,
	enable_kitty_graphics = true,
	color_scheme = "ChallengerDeep",
	hide_tab_bar_if_only_one_tab = true,
	window_background_opacity = 0.8,
	--font = wezterm.font 'Fira Code Regular Nerd Font Complete',
	font = wezterm.font("FiraCode Nerd Font", { weight = "Regular", stretch = "Normal", style = "Normal" }),
	harfbuzz_features = {
		"cv13",
		"ss01",
		"cv06",
		"ss07",
		"ss09",
		"cv27",
		"cv28",
		"ss06",
		"ss10",
		"cv25",
		"cv01",
		"cv02",
		"cv14",
		"cv16",
		"cv31",
		"cv29",
		"cv30",
		"ss05",
	},
	font_size = 14,
	tab_bar_at_bottom = true,
	window_padding = {
		left = 0,
		right = 0,
		top = 0,
		bottom = 0,
	},
	--leader = { key = 'a', mods = 'CTRL', timeout_milliseconds=1000},
	keys = {
		{ key = "k", mods = "CTRL|SHIFT", action = act.ActivatePaneDirection("Prev") },
		{ key = "j", mods = "CTRL|SHIFT", action = act.ActivatePaneDirection("Next") },
		{ key = "[", mods = "CTRL|SUPER", action = act.ActivatePaneDirection("Prev") },
		{ key = "]", mods = "CTRL|SUPER", action = act.ActivatePaneDirection("Next") },
		{ key = "w", mods = "SHIFT|CTRL", action = act.CloseCurrentPane({ confirm = true }) },
		--{ key = 'Enter', mods = 'CTRL|SHIFT', action = act.SplitHorizontal{ domain =  'CurrentPaneDomain' } },
		{ key = "|", mods = "CTRL|SHIFT", action = act.SplitVertical({ domain = "CurrentPaneDomain" }) },
		{ key = "DownArrow", mods = "SHIFT", action = act.ScrollToPrompt(1) },
		{ key = "UpArrow", mods = "SHIFT", action = act.ScrollToPrompt(-1) },
		--{ key = 'm', mods = 'SHIFT|CTRL', action =  l.layout()},
		{ key = "Enter", mods = "SHIFT|CTRL", action = wezterm.action({ EmitEvent = "make-layouts" }) },
		{ key = "b", mods = "SHIFT|CTRL", action = wezterm.action({ EmitEvent = "flayouts" }) },
	},
}
