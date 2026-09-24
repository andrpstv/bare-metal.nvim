return function()
	local mapping = require("keymap.ui")

	require("modules.utils").load_plugin("gitsigns", {
		signs = {
			add = { text = "┃" },
			change = { text = "┃" },
			delete = { text = "_" },
			topdelete = { text = "‾" },
			changedelete = { text = "~" },
			untracked = { text = "┆" },
		},
		auto_attach = true,
		on_attach = mapping.gitsigns,
		signcolumn = true,
		sign_priority = 6,
		update_debounce = 100,
		word_diff = false,
		current_line_blame = false,
		diff_opts = { internal = true },
		watch_gitdir = { follow_files = true, interval = 2000 },
	})
end
