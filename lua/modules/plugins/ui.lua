local ui = {}

-- ui["goolord/alpha-nvim"] = {
-- 	lazy = true,
-- 	event = "BufWinEnter",
-- 	config = require("ui.alpha"),
-- }
ui["romgrk/barbar.nvim"] = {
	lazy = true,
	event = { "BufReadPre", "BufAdd", "BufNewFile" },
	dependencies = { "nvim-tree/nvim-web-devicons" },
}
ui["RRethy/base16-nvim"] = {
	lazy = false,
	priority = 1000,
}
ui["ramojus/mellifluous.nvim"] = {
	lazy = false,
	priority = 1000,
	config = function()
		require("mellifluous").setup({})
	end,
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
ui["b0o/incline.nvim"] = {
	lazy = true,
	event = { "BufWinEnter", "WinNew" },
	config = require("ui.incline"),
}
ui["nvim-lualine/lualine.nvim"] = {
	lazy = true,
	event = { "BufReadPost", "BufAdd", "BufNewFile" },
	config = require("ui.lualine"),
}
ui["karb94/neoscroll.nvim"] = {
	lazy = true,
	event = { "CursorHold", "CursorHoldI" },
	config = require("ui.neoscroll"),
}
ui["folke/paint.nvim"] = {
	lazy = true,
	event = { "CursorHold", "CursorHoldI" },
	config = require("ui.paint"),
}
ui["mrjones2014/smart-splits.nvim"] = {
	lazy = true,
	event = { "CursorHoldI", "CursorHold" },
	config = require("ui.splits"),
}
ui["folke/edgy.nvim"] = {
	lazy = true,
	event = { "CursorHold", "CursorHoldI" },
	config = require("ui.edgy"),
}
ui["folke/todo-comments.nvim"] = {
	lazy = true,
	event = { "CursorHold", "CursorHoldI" },
	config = require("ui.todo"),
	dependencies = "nvim-lua/plenary.nvim",
}
ui["dstein64/nvim-scrollview"] = {
	lazy = true,
	event = { "BufReadPost", "BufAdd", "BufNewFile" },
	config = require("ui.scrollview"),
}

return ui
