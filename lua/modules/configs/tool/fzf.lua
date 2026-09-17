return function()
	require("modules.utils").load_plugin("fzf-lua", {
		winopts = {
			height = 0.85,
			width = 0.85,
			-- "builtin" вместо "bat": bat нет в системе, а builtin рисует
			-- превью самим nvim (подсветка через treesitter, зависимостей ноль).
			-- Хочешь bat — `brew install bat` и поменяй обратно.
			preview = { default = "builtin", delay = 50 },
		},
		keymap = {
			builtin = {
				["<C-d>"] = "preview-half-page-down",
				["<C-u>"] = "preview-half-page-up",
			},
			fzf = {
				["ctrl-q"] = "select-all+accept",
			},
		},
		lsp = {
			jump1 = true,
		},
	})
end
