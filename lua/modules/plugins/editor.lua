local editor = {}

-- Минимум: treesitter (+textobjects), прыжки flash.
-- Автозакрытие скобок — встроенное (core.pairs, ноль плагинов).
-- Убрано: persisted (сессии -> :mksession), bufdel (-> :bd),
-- faster, mini.*, hop (дубль flash), highlight-colors (веб),
-- vim-cool (-> autocmd), suda, sleuth (-> editorconfig),
-- Comment (-> builtin gc), diffview, grug-far (-> fzf live_grep + :cdo).
editor["nvim-treesitter/nvim-treesitter"] = {
	lazy = true,
	build = function()
		if #vim.api.nvim_list_uis() > 0 then
			vim.api.nvim_command([[TSUpdate]])
		end
	end,
	event = "BufReadPre",
	config = require("editor.treesitter"),
	dependencies = {
		{ "nvim-treesitter/nvim-treesitter-textobjects" },
	},
}
editor["folke/flash.nvim"] = {
	lazy = true,
	event = { "CursorHold", "CursorHoldI" },
	config = require("editor.flash"),
}
editor["sindrets/diffview.nvim"] = {
	lazy = true,
	cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory", "DiffviewRefresh" },
	config = require("editor.diffview"),
	dependencies = {
		{ "nvim-lua/plenary.nvim", lazy = true },
	},
}

return editor
