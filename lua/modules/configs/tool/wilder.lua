return function()
	local wilder = require("wilder")
	local icons = { ui = require("modules.utils.icons").get("ui") }

	wilder.set_option("use_python_remote_plugin", 0)
	wilder.set_option("pipeline", {
		wilder.branch(
			wilder.cmdline_pipeline({
				use_python = 0,
				fuzzy = 1,
			}),
			wilder.vim_search_pipeline(),
			{
				wilder.check(function(_, x)
					return x == ""
				end),
				wilder.history(),
				wilder.result({
					draw = {
						function(_, x)
							return icons.ui.Calendar .. x
						end,
					},
				}),
			}
		),
	})

	local popupmenu_renderer = wilder.popupmenu_renderer(wilder.popupmenu_border_theme({
		max_height = "30%",
		border = "rounded",
		highlights = {
			default = "Pmenu",
			border = "PmenuBorder",
			accent = wilder.make_hl("WilderAccent", "CmpItemAbbr", "CmpItemAbbrMatch"),
		},
		empty_message = wilder.popupmenu_empty_message_with_spinner(),
		highlighter = wilder.basic_highlighter(),
		left = {
			" ",
			wilder.popupmenu_devicons(),
			wilder.popupmenu_buffer_flags({
				flags = " a + ",
				icons = { ["+"] = icons.ui.Pencil, a = icons.ui.Indicator, h = icons.ui.File },
			}),
		},
		right = {
			" ",
			wilder.popupmenu_scrollbar(),
		},
	}))

	local wildmenu_renderer = wilder.wildmenu_renderer({
		apply_incsearch_fix = false,
		highlighter = wilder.basic_highlighter(),
		separator = " · ",
		left = { " ", wilder.wildmenu_spinner(), " " },
		right = { " ", wilder.wildmenu_index() },
	})

	wilder.set_option(
		"renderer",
		wilder.renderer_mux({
			[":"] = popupmenu_renderer,
			["/"] = wildmenu_renderer,
			substitute = wildmenu_renderer,
		})
	)

	require("modules.utils").load_plugin("wilder", { modes = { ":", "/", "?" } })
end
