local tool = {}

-- Минимум: fzf-lua (единственный пикер, нужен бинарник `fzf` в $PATH)
-- + trouble (список диагностик).
-- Проводник — встроенный netrw через :Ex.
-- Убрано: lazygit (-> :terminal lazygit), smartyank, toggleterm,
-- which-key, wilder (-> wildmenu), telescope-цепочка (11 плагинов),
-- fidget, dap-цепочка (-> dlv в терминале), codecompanion.
tool["ibhagwan/fzf-lua"] = {
	lazy = true,
	cmd = "FzfLua",
	-- NOTE: без `keys` осознанно: глобальные маппинги из keymap/tool.lua
	-- затирают lazy-loader, догрузка делается через _fzf() в keymap/helpers.lua.
	dependencies = {
		"nvim-tree/nvim-web-devicons",
	},
	config = require("tool.fzf"),
}
tool["folke/trouble.nvim"] = {
	lazy = true,
	cmd = { "Trouble", "TroubleToggle", "TroubleRefresh" },
	config = require("tool.trouble"),
}

return tool
