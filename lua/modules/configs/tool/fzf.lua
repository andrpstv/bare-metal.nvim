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
		-- Превью: не подсвечивать treesitter файлы >100KB (сгенерированные
		-- монстры tailscale вешают открытие), подсветка с задержкой 30мс —
		-- сначала текст, потом краска. Лимит превью 2MB.
		previewers = {
			builtin = {
				syntax_limit_b = 1024 * 100,
				syntax_delay = 30,
				limit_b = 1024 * 1024 * 2,
			},
		},
	})
end
