local editor = {}

-- Минимум: treesitter (+textobjects), прыжки flash, автозакрытие скобок.
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
editor["m4xshen/autoclose.nvim"] = {
	lazy = true,
	event = "InsertEnter",
	config = require("editor.autoclose"),
}

return editor
