return function()
	local icons = { ui = require("modules.utils.icons").get("ui", true) }
	local actions = require("glance").actions
	local settings = require("core.settings")

	require("modules.utils").load_plugin("glance", {
		height = 20,
		zindex = 50,
		preview_win_opts = {
			cursorline = true,
			number = true,
			wrap = false, -- ускоряем рендер
		},
		border = {
			enable = settings.transparent_background,
			top_char = "―",
			bottom_char = "―",
		},
		list = {
			position = "right",
			width = 0.33,
			max_results = 200, -- ограничение для ускорения
		},
		folds = {
			folded = false, -- отключаем автофолды
			fold_closed = icons.ui.ArrowClosed,
			fold_open = icons.ui.ArrowOpen,
		},
		indent_lines = { enable = false }, -- ускоряем рендер
		winbar = { enable = true },
		mappings = {
			list = {
				["k"] = actions.previous,
				["j"] = actions.next,
				["<Up>"] = actions.previous,
				["<Down>"] = actions.next,
				["<CR>"] = actions.jump,
				["v"] = actions.jump_vsplit,
				["s"] = actions.jump_split,
				["t"] = actions.jump_tab,
				["[]"] = actions.enter_win("preview"),
				["q"] = actions.close,
			},
			preview = {
				["[]"] = actions.enter_win("list"),
			},
		},
		hooks = {
			before_open = function(results, open, _, method)
				-- асинхронный notify, чтобы UI не лагал
				if #results == 0 or (#results == 1 and method == "references") then
					vim.schedule(function()
						vim.notify(
							#results == 0
								and "This method is not supported by any server for this buffer"
								or "The identifier under cursor is the only one found",
							vim.log.levels.WARN,
							{ title = "Glance" }
						)
					end)
				else
					open(results)
				end
			end,
		},
	})
end
