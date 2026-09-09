return function()
	local notify = require("notify")
	local settings = require("core.settings")
	local icons = {
		diagnostics = require("modules.utils.icons").get("diagnostics"),
		ui = require("modules.utils.icons").get("ui"),
	}

	require("modules.utils").load_plugin("notify", {
		stages = "fade",
		render = "default",
		fps = 20,
		timeout = 2000,
		minimum_width = 50,
		-- если включена прозрачность, делаем фон полностью прозрачным, иначе ставим мягкий цвет
		background_colour = settings.transparent_background and "#00000000" or "#1a1b26",
		icons = {
			ERROR = icons.diagnostics.Error,
			WARN = icons.diagnostics.Warning,
			INFO = icons.diagnostics.Information,
			DEBUG = icons.ui.Bug,
			TRACE = icons.ui.Pencil,
		},
		on_open = function(win)
			vim.api.nvim_set_option_value("winblend", 0, { scope = "local", win = win })
			vim.api.nvim_win_set_config(win, { zindex = 90 })
		end,
		level = "INFO",
	})

	vim.notify = notify
end
