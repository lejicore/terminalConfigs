local wezterm = require("wezterm")
local act = wezterm.action
--local layouts = ['top', 'right', 'column']
local layouts_name = { "top", "right", "column" }
local layouts = {}
local layouts_index = 0
--local l = require('layouts')

function getCommand(commandVar, ifnil)
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

local split = function(position, id)
	id = id or nil
	if id == nil then
		local _, _, _ = wezterm.run_child_process({ "wezterm", "cli", "split-pane", position })
	else
		local _, _, _ = wezterm.run_child_process({ "wezterm", "cli", "split-pane", position, "--move-pane-id", id })
	end
end

local right = function(args)
	id = args.id or nil
	first_split = args.first_split or nil
	pane = args.pane or nil
	print("first split is: " .. tostring(first_split))
	if id == nil then
		if #pane:tab():panes() <= 1 then
			--pane:split {direction = 'Right'}
			split("--right")
		else
			--pane:split {direction = 'Bottom'}
			split("--bottom")
		end
	else
		if first_split == true then
			--pane:split {direction = 'Right'}
			split("--right", id)
		else
			--pane:split {direction = 'Bottom'}
			split("--bottom", id)
		end
	end
end

local bottom = function(args)
	id = args.id or nil
	first_split = args.first_split or nil
	pane = args.pane or nil
	print("first split is" .. tostring(first_split))
	if id == nil then
		if #pane:tab():panes() <= 1 then
			split("--bottom")
		--pane:split {direction = 'Bottom'}
		else
			split("--right")
			--pane:split {direction = 'Right'}
		end
	else
		if first_split == true then
			split("--bottom", id)
		--pane:split {direction = 'Bottom'}
		else
			split("--right", id)
			--pane:split {direction = 'Right'}
		end
	end
end

local column = function(pane, id)
	id = args.id or nil
	pane = args.pane or nil
	if id == nil then
		split("--right")
	else
		split("--right", id)
	end
end
layouts["top"] = top
layouts["right"] = right
layouts["colulmn"] = colulmn

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
	local first_pane = true
	local first_split = true
	local tabs = pane:tab():window():tabs_with_info()
	--print(tabs)
	for _, v in ipairs(pane_ids) do
		local v_string = tostring(v)
		if first_pane == true then
			move(v)
			detect_tab(tabs, window, pane)
			first_pane = false
		else
			local panes_number = #pane:tab():panes()
			print("l'index est: " .. layout_index)
			layouts[layouts_name[layouts_index]]({ pane, v_string, first_split })
		end
		if first_split == true then
			first_split = false
		end
	end
end

local layout_incrementer = function()
	if layouts_index == #layouts_name then
		layouts_index = 0
	else
		layouts_index = layouts_index + 1
	end
	print("layouts_index = " .. tostring(layouts_index) .. " la longueur de la liste = " .. #layouts_name)
end
wezterm.on("flayouts", function(window, pane)
	--act.MoveTabRelative()
	--window:perform_action(wezterm.action.MoveTabRelative(-1), pane)
	--local _,tabs,_ = wezterm.run_child_process {"jq", "'.[]", "|", "select(.window_id==0)", "|", ".pane_id'"}
	print("tab id is: " .. pane:tab():tab_id())
	--print( pane:tab():panes_with_info() )
	print(pane:tab():window():tabs_with_info())
	local panes = pane:tab():panes()

	local pane_ids = {}
	for _, v in ipairs(panes) do
		print(v)
		local v_string = tostring(v)
		for pane_id in string.gmatch(v_string, "pane_id:(%d+)") do
			table.insert(pane_ids, pane_id)
		end
	end
	change_layout_bottom(pane_ids, pane, window)

	--local _,tabs,_ = wezterm.run_child_process {'/bin/bash $HOME/wez.sh', pane:tab():tab_id()}
	--local tabs = getCommand('/bin/bash $HOME/wez.sh', "deso")
	--print("tabs lists: " ..tabs)
	layout_incrementer()
end)

wezterm.on("make-layouts", function(window, pane)
	--local panes = pane:tab():panes()
	print("layouts tests")
	print(#pane:tab():panes())
	print(pane:tab():panes())
	print(pane:tab():panes_with_info())
	print("le nom est: " .. tostring(layouts_name[layouts_index] .. "son index est:" .. tostring(layouts_index)))
	layouts[layouts_name[layout_index]](pane)
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
	--local user = "user"
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
	window:set_right_status(wezterm.format({
		{ Attribute = { Underline = "Curly" } },
		{ Attribute = { Italic = true } },
		{ Text = layouts_name[layouts_index] .. " " .. panes_number .. " " .. os.getenv("USER") .. " " .. uname .. " " },
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
	color_scheme = "ChallengerDeep",
	window_background_opacity = 0.8,
	font_size = 12,
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
