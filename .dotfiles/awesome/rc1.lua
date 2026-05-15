-- awesome_mode: api-level=4:screen=on
-- If LuaRocks is installed, make sure that packages installed through it are
-- found (e.g. lgi). If LuaRocks is not installed, do nothing.
pcall(require, "luarocks.loader")

-- Standard awesome library
local volume_widget = require("awesome-wm-widgets.pactl-widget.volume")
local bluetooth = require("gobo.awesome.bluetooth") -- bluetooth widget for awesomeWM from this github repo:     https://github.com/gobolinux/gobo-awesome-bluetooth
local toggle_all_tags = require("my_modules.toggle_all_tags")
local statusbar = require("my_modules.statusbar")
local net_widgets = require("net_widgets")
local gears = require("gears")
local awful = require("awful")
require("awful.autofocus")
-- Widget and layout library
local wibox = require("wibox")
-- Theme handling library
local beautiful = require("beautiful")
-- Notification library
local naughty = require("naughty")
-- Declarative object management
local ruled = require("ruled")
local menubar = require("menubar")
local hotkeys_popup = require("awful.hotkeys_popup")
-- Enable hotkeys help widget for VIM and other apps
-- when client with a matching name is opened:
require("awful.hotkeys_popup.keys")

-- {{{ Error handling
-- Check if awesome encountered an error during startup and fell back to
-- another config (This code will only ever execute for the fallback config)
naughty.connect_signal("request::display_error", function(message, startup)
	naughty.notification({
		urgency = "critical",
		title = "Oops, an error happened" .. (startup and " during startup!" or "!"),
		message = message,
	})
end)
-- }}}

-- {{{ Variable definitions
-- Themes define colours, icons, font and wallpapers.
--beautiful.init(gears.filesystem.get_themes_dir() .. "default/theme.lua")
beautiful.init(gears.filesystem.get_configuration_dir() .. "theme.lua")

-- This is used later as the default terminal and editor to run.
terminal = "kitty"
editor = os.getenv("EDITOR") or "nano"
editor_cmd = terminal .. " -e " .. editor

-- Default modkey.
-- Usually, Mod4 is the key with a logo between Control and Alt.
-- If you do not like this or do not have such a key,
-- I suggest you to remap Mod4 to another key using xmodmap or other tools.
-- However, you can use another modifier like Mod1, but it may interact with others.
modkey = "Mod4"
-- }}}

-- {{{ Menu
-- Create a launcher widget and a main menu
myawesomemenu = {
	{
		"hotkeys",
		function()
			hotkeys_popup.show_help(nil, awful.screen.focused())
		end,
	},
	{ "manual", terminal .. " -e man awesome" },
	{ "edit config", editor_cmd .. " " .. awesome.conffile },
	{ "restart", awesome.restart },
	{
		"quit",
		function()
			awesome.quit()
		end,
	},
}

mymainmenu = awful.menu({
	items = {
		{ "awesome", myawesomemenu, beautiful.awesome_icon },
		{ "open terminal", terminal },
	},
})

mylauncher = awful.widget.launcher({ image = beautiful.awesome_icon, menu = mymainmenu })

-- Menubar configuration
menubar.utils.terminal = terminal -- Set the terminal for applications that require it
-- }}}

-- {{{ Tag layout
-- Table of layouts to cover with awful.layout.inc, order matters.
tag.connect_signal("request::default_layouts", function()
	awful.layout.append_default_layouts({
		awful.layout.suit.tile,
		awful.layout.suit.floating,
		awful.layout.suit.tile.left,
		awful.layout.suit.tile.bottom,
		awful.layout.suit.tile.top,
		awful.layout.suit.fair,
		awful.layout.suit.fair.horizontal,
		awful.layout.suit.spiral,
		awful.layout.suit.spiral.dwindle,
		awful.layout.suit.max,
		awful.layout.suit.max.fullscreen,
		awful.layout.suit.magnifier,
		awful.layout.suit.corner.nw,
	})
end)
-- }}}

-- {{{ Wallpaper
screen.connect_signal("request::wallpaper", function(s)
	gears.wallpaper.maximized(gears.filesystem.get_configuration_dir() .. "wall2.jpg", s) --WAITING FOR A FIX IN THE NEW AWFUL API so have to use instead of the snippet below

	--[[ awful.wallpaper {
        screen = s,
        widget = {
            {
                --image     = beautiful.wallpaper,
                image     = "~/Downloads/wall2.jpg",
                upscale   = true,
                downscale = true,
                horizontal_fit_policy = "fit",
                vertical_fit_policy = "fit",
                widget    = wibox.widget.imagebox,
            },
            valign = "center",
            halign = "center",
            tiled  = false,
            widget = wibox.container.tile,
        }
    } ]]
end)
-- }}}

-- {{{ Wibar

-- Keyboard map indicator and switcher
mykeyboardlayout = awful.widget.keyboardlayout()

-- Create a textclock widget
mytextclock = wibox.widget.textclock()

mytextbox = wibox.widget.textbox(" | ")
mywidget = awful.widget.watch([[ bash -c "sensors | grep temp1"]], 15)
fete_text_box = wibox.widget.textbox(" | Bonne fête aux ")
fete_widget = awful.widget.watch([[ bash -c "jq -r '.name' ~/scripts/fete/day.json" ]])

net_wireless = net_widgets.wireless({ interface = "wlp8s0" })
net_wired = net_widgets.indicator({})

net_internet = net_widgets.internet({ indent = 0, timeout = 5 })

screen.connect_signal("request::desktop_decoration", function(s)
	-- Each screen has its own tag table.
	awful.tag({ "A", "W", "E", "S", "O", "M", "E", "W", "M" }, s, awful.layout.layouts[1])

	-- Create a promptbox for each screen
	s.mypromptbox = awful.widget.prompt()

	-- Create an imagebox widget which will contain an icon indicating which layout we're using.
	-- We need one layoutbox per screen.
	s.mylayoutbox = awful.widget.layoutbox({
		screen = s,
		buttons = {
			awful.button({}, 1, function()
				awful.layout.inc(1)
			end),
			awful.button({}, 3, function()
				awful.layout.inc(-1)
			end),
			awful.button({}, 4, function()
				awful.layout.inc(-1)
			end),
			awful.button({}, 5, function()
				awful.layout.inc(1)
			end),
		},
	})

	-- Create a taglist widget
	s.mytaglist = awful.widget.taglist({
		screen = s,
		filter = awful.widget.taglist.filter.all,
		buttons = {
			awful.button({}, 1, function(t)
				t:view_only()
			end),
			awful.button({ modkey }, 1, function(t)
				if client.focus then
					client.focus:move_to_tag(t)
				end
			end),
			awful.button({}, 3, awful.tag.viewtoggle),
			awful.button({ modkey }, 3, function(t)
				if client.focus then
					client.focus:toggle_tag(t)
				end
			end),
			awful.button({}, 4, function(t)
				awful.tag.viewprev(t.screen)
			end),
			awful.button({}, 5, function(t)
				awful.tag.viewnext(t.screen)
			end),
		},
	})

	-- Create a tasklist widget
	s.mytasklist = awful.widget.tasklist({
		screen = s,
		filter = awful.widget.tasklist.filter.currenttags,
		buttons = {
			awful.button({}, 1, function(c)
				c:activate({ context = "tasklist", action = "toggle_minimization" })
			end),
			awful.button({}, 3, function()
				awful.menu.client_list({ theme = { width = 250 } })
			end),
			awful.button({}, 4, function()
				awful.client.focus.byidx(-1)
			end),
			awful.button({}, 5, function()
				awful.client.focus.byidx(1)
			end),
		},
	})

	-- Create the wibox
	s.mywibox = awful.wibar({
		position = "top",
		screen = s,
		widget = {
			layout = wibox.layout.align.horizontal,
			{ -- Left widgets
				layout = wibox.layout.fixed.horizontal,
				--mylauncher,   --ITS THE CORNER LEFT BUTTON
				s.mytaglist,
				s.mypromptbox,
			},
			s.mytasklist, -- Middle widget
			{ -- Right widgets
				layout = wibox.layout.fixed.horizontal,
				mykeyboardlayout,
				wibox.widget.systray(),
				mytextclock,
				fete_text_box,
				fete_widget,
				mytextbox,
				net_wireless,
				net_wired,
				net_internet,
				mytextbox,
				volume_widget(),
				mytextbox,
				bluetooth.new(),
				s.mylayoutbox,
			},
		},
	})
end)

-- }}}

-- {{{ Mouse bindings
awful.mouse.append_global_mousebindings({
	awful.button({}, 3, function()
		mymainmenu:toggle()
	end),
	awful.button({}, 4, awful.tag.viewprev),
	awful.button({}, 5, awful.tag.viewnext),
})
-- }}}

-- {{{ Key bindings

local popme = function()
	local notification_widgets = {}
	local notest = function(n)
		--[[ local myscreen = awful.screen.focused()
  myscreen.mywibox.visible = not myscreen.mywibox.visible ]]
		naughty.notification({ message = "YEN A PLEIN " })
		--notification_widgets[#notification_widgets+1] = wibox.widget.textbox(n.title)
		--naughty.notification{message='YEN A PLEIN '.. tostring(n.title)}
	end
	-- local notifications = naughty.active
	--
	-- local notification_widgets = {}
	-- for i, notification in pairs(notifications) do
	--   notification_widgets[i] = wibox.widget.textbox(notification.title)
	-- end
	--naughty.notification{message='YEN A PLEIN '.. tostring(notifications[2].title)}

	local layout = wibox.layout.fixed.vertical()
	local wig = wibox.widget({ spacing = 20, spacing_widget = wibox.widget.separator, layout = layout })
	for _, widget in pairs(notification_widgets) do
		layout:add(widget)
	end
	local popup = awful.popup({
		widget = wig,
		bg = "#6e0dd0",
		fg = "#000",
		border_color = "#cc00ff",
		border_width = 2,
		ontop = true,
		placement = awful.placement.center,
		shape = gears.shape.rounded_rect,
		hide_on_right_click = true,
	})
	return popup
end
local popup = nil
local popTest = function()
	if popup == nil then
		popup = popme()
		naughty.notification({ title = "c'est comment ?", message = "CA DEMARRE SA MERE LA GITANE" })
	elseif popup.visible then
		popup.visible = false
		naughty.notificatin({ title = "c'est comment ?", message = "c'est pas on :3 " })
	elseif not popup.visible then
		--popup.visible = true
		popup = popme()
		naughty.notification({ title = "c'est comment ?", message = "CEST FUCKING ON" })
	end
end

naughty.connect_signal("added", function(notification)
	if notification.title == "debug" then
		local myscreen = awful.screen.focused()
		myscreen.mywibox.visible = not myscreen.mywibox.visible
	end
end)
--[[ naughty.connect_signal("added", function(notification)
  naughty.notification{message='YEN A PLEIN '}
end) ]]

-- General Awesome keys
--[[ local popmee = function ()
local popup = awful.popup {
    widget = awful.widget.tasklist {
        screen   = screen[1],
        filter   = awful.widget.tasklist.filter.allscreen,
        buttons  = tasklist_buttons,
        style    = {
            shape = gears.shape.rounded_rect,
        },
        layout   = {
            spacing = 5,
            forced_num_rows = 2,
            layout = wibox.layout.grid.horizontal
        },
        widget_template = {
            {
                {
                    id     = 'clienticon',
                    widget = awful.widget.clienticon,
                },
                margins = 4,
                widget  = wibox.container.margin,
            },
            id              = 'background_role',
            forced_width    = 48,
            forced_height   = 48,
            widget          = wibox.container.background,
            create_callback = function(self, c, index, objects) --luacheck: no unused
                self:get_children_by_id('clienticon')[1].client = c
            end,
        },
    },
    border_color = '#777777',
    border_width = 2,
    ontop        = true,
    placement    = awful.placement.centered,
    shape        = gears.shape.rounded_rect,
    hide_on_right_click = true
}
return popup
end ]]

awful.keyboard.append_global_keybindings({
	awful.key({}, "XF86AudioLowerVolume", function()
		volume_widget:dec(5)
	end, { description = "Lower volume", group = "Benji" }),
	awful.key({}, "XF86AudioMute", function()
		volume_widget:toggle()
	end, { description = "Toggle Mute", group = "Benji" }),
	awful.key({}, "XF86AudioRaiseVolume", function()
		volume_widget:inc(5)
	end, { description = "Raise volume", group = "Benji" }),
	awful.key({ modkey, "Control" }, "b", function()
		popTest()
	end, { description = "Pop Test", group = "Benji" }),
	awful.key({ modkey }, "s", hotkeys_popup.show_help, { description = "show help", group = "awesome" }),
	awful.key({ modkey }, "w", function()
		mymainmenu:show()
	end, { description = "show main menu", group = "awesome" }),
	awful.key({ modkey, "Control" }, "r", awesome.restart, { description = "reload awesome", group = "awesome" }),
	awful.key({ modkey, "Shift" }, "q", awesome.quit, { description = "quit awesome", group = "awesome" }),
	awful.key({ modkey }, "x", function()
		awful.prompt.run({
			prompt = "Run Lua code: ",
			textbox = awful.screen.focused().mypromptbox.widget,
			exe_callback = awful.util.eval,
			history_path = awful.util.get_cache_dir() .. "/history_eval",
		})
	end, { description = "lua execute prompt", group = "awesome" }),
	awful.key({ modkey }, "Return", function()
		awful.spawn(terminal)
	end, { description = "open a terminal", group = "launcher" }),
	--we change the basic prompt to dmenu launcher
	--[[ awful.key({ modkey },            "r",     function () awful.screen.focused().mypromptbox:run() end,
              {description = "run prompt", group = "launcher"}), ]]
	awful.key({ modkey }, "r", function()
		awful.util.spawn("dmenu_run")
	end, { description = "run dmenu", group = "launcher" }),
	awful.key({ modkey }, "p", function()
		menubar.show()
	end, { description = "show the menubar", group = "launcher" }),
})

-- Tags related keybindings
awful.keyboard.append_global_keybindings({
	awful.key({ modkey, "Shift" }, "x", function()
		toggle_all_tags.toggle_view_all_tags()
	end, { description = "Toggle all tags on the active one", group = "tag" }),
	awful.key({ modkey }, "b", function()
		statusbar.toggleStatusBarVisibility()
	end, { description = "toggle keep on top", group = "tag" }),
	awful.key({ modkey }, "Left", awful.tag.viewprev, { description = "view previous", group = "tag" }),
	awful.key({ modkey }, "Right", awful.tag.viewnext, { description = "view next", group = "tag" }),
	awful.key({ modkey }, "Escape", awful.tag.history.restore, { description = "go back", group = "tag" }),
})

-- Focus related keybindings
awful.keyboard.append_global_keybindings({
	awful.key({ modkey }, "j", function()
		awful.client.focus.byidx(1)
	end, { description = "focus next by index", group = "client" }),
	awful.key({ modkey }, "k", function()
		awful.client.focus.byidx(-1)
	end, { description = "focus previous by index", group = "client" }),
	awful.key({ modkey }, "Tab", function()
		awful.client.focus.history.previous()
		if client.focus then
			client.focus:raise()
		end
	end, { description = "go back", group = "client" }),
	awful.key({ modkey, "Control", "Shift" }, "j", function()
		awful.screen.focus_relative(1)
	end, { description = "focus the next screen", group = "screen" }),
	awful.key({ modkey, "Control", "Shift" }, "k", function()
		awful.screen.focus_relative(-1)
	end, { description = "focus the previous screen", group = "screen" }),
	awful.key({ modkey, "Control" }, "n", function()
		local c = awful.client.restore()
		-- Focus restored client
		if c then
			c:activate({ raise = true, context = "key.unminimize" })
		end
	end, { description = "restore minimized", group = "client" }),
})

-- Layout related keybindings
awful.keyboard.append_global_keybindings({
	awful.key({ modkey, "Shift" }, "j", function()
		awful.client.swap.byidx(1)
	end, { description = "swap with next client by index", group = "client" }),
	awful.key({ modkey, "Shift" }, "k", function()
		awful.client.swap.byidx(-1)
	end, { description = "swap with previous client by index", group = "client" }),
	awful.key({ modkey }, "u", awful.client.urgent.jumpto, { description = "jump to urgent client", group = "client" }),
	awful.key({ modkey }, "l", function()
		awful.tag.incmwfact(0.05)
	end, { description = "increase master width factor", group = "layout" }),
	awful.key({ modkey }, "h", function()
		awful.tag.incmwfact(-0.05)
	end, { description = "decrease master width factor", group = "layout" }),
	awful.key({ modkey, "Control" }, "j", function()
		awful.client.incwfact(0.05)
	end, { description = "increase client height factor", group = "layout" }),
	awful.key({ modkey, "Control" }, "k", function()
		awful.client.incwfact(-0.05)
	end, { description = "decrease client height factor", group = "layout" }),
	awful.key({ modkey, "Shift" }, "h", function()
		awful.tag.incnmaster(1, nil, true)
	end, { description = "increase the number of master clients", group = "layout" }),
	awful.key({ modkey, "Shift" }, "l", function()
		awful.tag.incnmaster(-1, nil, true)
	end, { description = "decrease the number of master clients", group = "layout" }),
	awful.key({ modkey, "Control" }, "h", function()
		awful.tag.incncol(1, nil, true)
	end, { description = "increase the number of columns", group = "layout" }),
	awful.key({ modkey, "Control" }, "l", function()
		awful.tag.incncol(-1, nil, true)
	end, { description = "decrease the number of columns", group = "layout" }),
	awful.key({ modkey }, "space", function()
		awful.layout.inc(1)
	end, { description = "select next", group = "layout" }),
	awful.key({ modkey, "Shift" }, "space", function()
		awful.layout.inc(-1)
	end, { description = "select previous", group = "layout" }),
})

awful.keyboard.append_global_keybindings({
	awful.key({
		modifiers = { modkey },
		keygroup = "numrow",
		description = "only view tag",
		group = "tag",
		on_press = function(index)
			local screen = awful.screen.focused()
			local tag = screen.tags[index]
			if tag then
				tag:view_only()
			end
		end,
	}),
	awful.key({
		modifiers = { modkey, "Control" },
		keygroup = "numrow",
		description = "toggle tag",
		group = "tag",
		on_press = function(index)
			local screen = awful.screen.focused()
			local tag = screen.tags[index]
			if tag then
				awful.tag.viewtoggle(tag)
			end
		end,
	}),
	awful.key({
		modifiers = { modkey, "Shift" },
		keygroup = "numrow",
		description = "move focused client to tag",
		group = "tag",
		on_press = function(index)
			if client.focus then
				local tag = client.focus.screen.tags[index]
				if tag then
					client.focus:move_to_tag(tag)
				end
			end
		end,
	}),
	awful.key({
		modifiers = { modkey, "Control", "Shift" },
		keygroup = "numrow",
		description = "toggle focused client on tag",
		group = "tag",
		on_press = function(index)
			if client.focus then
				local tag = client.focus.screen.tags[index]
				if tag then
					client.focus:toggle_tag(tag)
				end
			end
		end,
	}),
	awful.key({
		modifiers = { modkey },
		keygroup = "numpad",
		description = "select layout directly",
		group = "layout",
		on_press = function(index)
			local t = awful.screen.focused().selected_tag
			if t then
				t.layout = t.layouts[index] or t.layout
			end
		end,
	}),
})

client.connect_signal("request::default_mousebindings", function()
	awful.mouse.append_client_mousebindings({
		awful.button({}, 1, function(c)
			c:activate({ context = "mouse_click" })
		end),
		awful.button({ modkey }, 1, function(c)
			c:activate({ context = "mouse_click", action = "mouse_move" })
		end),
		awful.button({ modkey }, 3, function(c)
			c:activate({ context = "mouse_click", action = "mouse_resize" })
		end),
	})
end)

local no_fullscreen = true
local claimed_fullscreen_rule = { class = { "firefox", "vlc" } }
awful.client.set_claimed_fullscreen(claimed_fullscreen_rule)
client.disconnect_signal("request::geometry", awful.ewmh.geometry)
client.connect_signal("request::geometry", function(c, context, ...)
	-- -- Create a notification with the client size
	-- naughty.notification({
	--   title = "Client size",
	--   message = "Width: " .. c.width .. "\nHeight: " .. c.height .. "\ncontext: " .. context,
	--   timeout = 5, -- Notification will disappear after 5 seconds
	--   urgency = "low"
	-- })

	local tmp_rule = awful.client.get_claimed_fullscreen()
	local i = 0
	while i < #tmp_rule do
		local string = table.unpack(tmp_rule, i)
		naughty.notification({ title = "mes regles", message = tostring(string) })
	end
	-- naughty.notification{title="fake fullscreen", message="Width: " .. c.width .. "\nHeight: " .. c.height}
	-- c.border_width = 0
	if not no_fullscreen or context ~= "fullscreen" or not awful.rules.match_any(c, claimed_fullscreen_rule) then
		naughty.notification({ title = "fake fullscreen", message = "Width: " .. c.width .. "\nHeight: " .. c.height })
		c.floating = false
		awful.ewmh.geometry(c, context, ...)
	end
	if no_fullscreen and awful.rules.match_any(c, claimed_fullscreen_rule) then
		c.floating = false
	end
	--print(context)
	-- if c.maximized then
	--   c.border_width = 0
	-- elseif c.maximized or c.client_mazimize_horizontal or c.client_mazimize_vertical and not c.fullscreen then
	--   c.border_width = beautiful.border_width
	-- elseif c.maximized or c.client_mazimize_horizontal or c.client_mazimize_vertical and c.fullscreen then
	--   c.border_width = 0
	--
	-- end
end)

client.connect_signal("request::default_keybindings", function()
	awful.keyboard.append_client_keybindings({
		awful.key({ modkey, "Shift" }, "p", function()
			no_fullscreen = not no_fullscreen
			naughty.notification({ title = "Claimed fullscreen ?", message = tostring(no_fullscreen) })
		end, { description = "Claim fullscreen client", group = "Benji" }),
		awful.key({ modkey, "Shift" }, "s", function()
			local c = client.focus
			if c then
				c.sticky = not c.sticky
			end
		end, { description = "toggle sticky client", group = "client" }),
		awful.key({ modkey }, "f", function(c)
			c.fullscreen = not c.fullscreen
			c:raise()
		end, { description = "toggle fullscreen", group = "client" }),
		awful.key({ modkey, "Shift" }, "c", function(c)
			c:kill()
		end, { description = "close", group = "client" }),
		awful.key(
			{ modkey, "Control" },
			"space",
			awful.client.floating.toggle,
			{ description = "toggle floating", group = "client" }
		),
		awful.key({ modkey, "Control" }, "Return", function(c)
			c:swap(awful.client.getmaster())
		end, { description = "move to master", group = "client" }),
		awful.key({ modkey }, "o", function(c)
			c:move_to_screen()
		end, { description = "move to screen", group = "client" }),
		awful.key({ modkey }, "t", function(c)
			c.ontop = not c.ontop
		end, { description = "toggle keep on top", group = "client" }),
		awful.key({ modkey }, "n", function(c)
			-- The client currently has the input focus, so it cannot be
			-- minimized, since minimized clients can't have the focus.
			c.minimized = true
		end, { description = "minimize", group = "client" }),
		awful.key({ modkey }, "m", function(c)
			c.maximized = not c.maximized
			c:raise()
		end, { description = "(un)maximize", group = "client" }),
		awful.key({ modkey, "Control" }, "m", function(c)
			c.maximized_vertical = not c.maximized_vertical
			c:raise()
		end, { description = "(un)maximize vertically", group = "client" }),
		awful.key({ modkey, "Shift" }, "m", function(c)
			c.maximized_horizontal = not c.maximized_horizontal
			c:raise()
		end, { description = "(un)maximize horizontally", group = "client" }),
		awful.key({ modkey, "Shift" }, "Next", function(c)
			c:relative_move(20, 20, -40, -40)
		end),
		awful.key({ modkey, "Shift" }, "Prior", function(c)
			c:relative_move(-20, -20, 40, 40)
		end),
	})
end)

-- }}}

-- {{{ Rules
-- Rules to apply to new clients.
ruled.client.connect_signal("request::rules", function()
	-- All clients will match this rule.
	ruled.client.append_rule({
		id = "global",
		rule = {},
		properties = {
			focus = awful.client.focus.filter,
			raise = true,
			screen = awful.screen.preferred,
			placement = awful.placement.no_overlap + awful.placement.no_offscreen,
		},
		callback = awful.client.setslave, --set new clients as slave instead of spawning at maste area
	})

	-- Floating clients.
	ruled.client.append_rule({
		id = "floating",
		rule_any = {
			instance = { "copyq", "pinentry", "DTA" }, --DTA = firefox addon DownThemAll
			class = {
				"Arandr",
				"Blueman-manager",
				"Gpick",
				"Kruler",
				"Sxiv",
				"Wpa_gui",
				"veromix",
				"xtightvncviewer",
				"Tilda",
				"org.gnome.Nautilus",
			},
			-- Note that the name property shown in xprop might be set slightly after creation of the client
			-- and the name shown there might not match defined rules here.
			name = {
				"Event Tester", -- xev.
			},
			role = {
				"AlarmWindow", -- Thunderbird's calendar.
				"ConfigManager", -- Thunderbird's about:config.
				"pop-up", -- e.g. Google Chrome's (detached) Developer Tools.
			},
		},
		properties = { floating = true },
	})

	-- Add titlebars to normal clients and dialogs
	ruled.client.append_rule({
		id = "titlebars",
		rule_any = { type = { "normal", "dialog" } },
		properties = { titlebars_enabled = false },
	})

	-- Set Firefox to always map on the tag named "2" on screen 1.
	-- ruled.client.append_rule {
	--     rule       = { class = "Firefox"     },
	--     properties = { screen = 1, tag = "2" }
	-- }

	ruled.client.append_rule({
		rule = { class = "Xephyr" },
		properties = { screen = 1, tag = "W" },
	})
end)
-- }}}

-- {{{ Titlebars
-- Add a titlebar if titlebars_enabled is set to true in the rules.
client.connect_signal("request::titlebars", function(c)
	-- buttons for the titlebar
	local buttons = {
		awful.button({}, 1, function()
			c:activate({ context = "titlebar", action = "mouse_move" })
		end),
		awful.button({}, 3, function()
			c:activate({ context = "titlebar", action = "mouse_resize" })
		end),
	}

	awful.titlebar(c).widget = {
		{ -- Left
			awful.titlebar.widget.iconwidget(c),
			buttons = buttons,
			layout = wibox.layout.fixed.horizontal,
		},
		{ -- Middle
			{ -- Title
				halign = "center",
				widget = awful.titlebar.widget.titlewidget(c),
			},
			buttons = buttons,
			layout = wibox.layout.flex.horizontal,
		},
		{ -- Right
			awful.titlebar.widget.floatingbutton(c),
			awful.titlebar.widget.maximizedbutton(c),
			awful.titlebar.widget.stickybutton(c),
			awful.titlebar.widget.ontopbutton(c),
			awful.titlebar.widget.closebutton(c),
			layout = wibox.layout.fixed.horizontal(),
		},
		layout = wibox.layout.align.horizontal,
	}
end)
-- }}}

-- {{{ Notifications

ruled.notification.connect_signal("request::rules", function()
	-- All notifications will match this rule.
	ruled.notification.append_rule({
		rule = {},
		properties = {
			screen = awful.screen.preferred,
			implicit_timeout = 5,
		},
	})
end)

naughty.connect_signal("request::display", function(n)
	naughty.layout.box({ notification = n })
end)

-- }}}

-- Enable sloppy focus, so that focus follows mouse.
client.connect_signal("mouse::enter", function(c)
	c:activate({ context = "mouse_enter", raise = false })
end)

function set_max_screen_size(c, s)
	-- local focused_screen = awful.screen.focused()
	-- c.width = focused_screen.geometry.width
	-- c.height = focused_screen.geometry.height
	for s = 1, screen.count() do
		local screen_geometry = screen[s].workarea
		local available_width = screen_geometry.width
		local available_height = screen_geometry.height

		--Print the available screen space for each screen
		--naughty.notification{title="available space?" ,message="Screen " .. s .. ": " .. available_width .. "x" .. available_height}
		return screen_geometry
	end
end

-- No borders when rearranging only 1 non-floating or maximized client
screen.connect_signal("arrange", function(s)
	-- Create a notification with the client size
	local only_one = #s.tiled_clients == 1

	for _, c in pairs(s.clients) do
		if only_one and not c.floating or c.maximized then
			c.border_width = 0
		--   local screen_geometry = set_max_screen_size(c)
		--   if not not screen_geometry then
		--   c.border_width = screen_geometry.width
		--   c.border_height = screen_geometry.height
		-- end
		-- elseif not only_one and not c.floating and c.maximized then
		--     c.border_width = 0
		--     local screen_geometry = set_max_screen_size(c)
		--     if not not screen_geometry then
		--     c.border_width = screen_geometry.width
		--     c.border_height = screen_geometry.height
		--   end
		-- elseif only_one and c.maximized then
		--   c.border_width = 0
		-- elseif only_one and c.maximized and awful.rules.match_any(c, claimed_fullscreen_rule) then
		--   c.border_width = 0
		-- elseif only_one and awful.rules.match_any(c, claimed_fullscreen_rule) then
		--   naughty.notification{title="fullscreen", message="Width: " .. c.width .. "\nHeight: " .. c.height}
		--   local screen_geometry = set_max_screen_size(c)
		--   if not not screen_geometry then
		--   c.width = 2560
		--   c.height = 1600
		-- end
		-- elseif not only_one and awful.rules.match_any(c, claimed_fullscreen_rule) then
		--   local screen_geometry = set_max_screen_size(c)
		--   --c.border_width = 0
		--   c.border_width = beautiful.border_width -- your border width
		elseif not only_one and not c.maximized then
			c.border_width = beautiful.border_width -- your border width
		end
	end
end)

--awful.spawn.with_shell('feh --bg-scale ~/Downloads/wall2.jpg')
--awful.spawn.with_shell('tilda')
--awful.spawn.with_shell('sudo systemctl start NetworkManager.service')
--awful.spawn.with_shell('nm-applet')
--awful.spawn.with_shell('nitrogen --restore')
--awful.spawn.with_shell('nvidia-settings --assign CurrentMetaMode="nvidia-auto-select +0+0 { ForceFullCompositionPipeline = On }"')

--[[ awful.spawn.with_shell('nvidia-settings -assign CurrentMetaMode="nvidia-settings --assign CurrentMetaMode="DP-0: 2560x1600+0+0 { ForceFullCompositionPipeline = On }"')  --actually have to specify the display for the composition or it fails
awful.spawn.with_shell('setxkbmap -layout us -variant altgr-intl -option nodeadkeys')
awful.spawn.with_shell('~/.config/volumeicon/restart_volumeicon')
awful.spawn.with_shell('picom --fade-in-step=1 --fade-out-step=1 --fade-delta=0') ]]

--autorun programs
local autorun = true
local autorunApps = {
	"setxkbmap -layout us -variant altgr-intl -option nodeadkeys",
	--'~/.config/volumeicon/restart_volumeicon',
	--'picom --fade-in-step=1 --fade-out-step=1 --fade-delta=0 --inactive-opacity=1 -b',
	--'sudo systemctl start bluetooth.service',
	--'nvidia-settings -assign CurrentMetaMode="nvidia-settings --assign CurrentMetaMode="DP-0: 2560x1600+0+0 { ForceFullCompositionPipeline = On }"',
}
if autorun then
	for app = 1, #autorunApps do
		awful.spawn.with_shell(autorunApps[app])
	end
end
