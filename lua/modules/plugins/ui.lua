local ui = {}

-- Минимум: иконки (для fzf/trouble) + gitsigns.
-- Статуслайн/таблайн — встроенные, тема — встроенная (settings.colorscheme).
-- Убрано: barbar (-> :b/:bd), 3 сторонние темы, incline, lualine,
-- neoscroll, paint, smart-splits, edgy, todo-comments, scrollview.
ui["nvim-tree/nvim-web-devicons"] = {
	lazy = true,
}
ui["metalelf0/black-metal-theme-neovim"] = {
	lazy = false,
	priority = 1000,
	config = require("themes.black-metal-khold").setup,
}
ui["lewis6991/gitsigns.nvim"] = {
	lazy = true,
	event = { "CursorHold", "CursorHoldI" },
	config = require("ui.gitsigns"),
}

return ui
