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
		-- Большие файлы не аттачим вообще: git diff + вотчеры на 10k+ строк
		-- вешают слабый ПК, а пользы ноль (там и так всё выключено).
		on_attach = function(bufnr)
			if vim.b[bufnr].large_file then
				return false
			end
			return mapping.gitsigns(bufnr)
		end,
		signcolumn = true,
		sign_priority = 6,
		update_debounce = 200,
		word_diff = false,
		current_line_blame = false,
		diff_opts = { internal = true },
		watch_gitdir = { follow_files = true, interval = 5000 },
	})
end
