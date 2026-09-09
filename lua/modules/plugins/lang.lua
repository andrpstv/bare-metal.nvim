local lang = {}

lang["kevinhwang91/nvim-bqf"] = {
	lazy = true,
	ft = "qf",
	config = require("lang.bqf"),
	dependencies = {
		{ "junegunn/fzf", build = ":call fzf#install()" },
	},
}
lang["ray-x/go.nvim"] = {
	lazy = true,
	ft = { "go", "gomod", "gosum" },
	build = ":GoInstallBinaries",
	config = require("lang.go"),
	dependencies = "ray-x/guihua.lua",
}
lang["mrcjkb/rustaceanvim"] = {
	lazy = true,
	ft = "rust",
	version = "*",
	init = require("lang.rust"),
	dependencies = "nvim-lua/plenary.nvim",
}
lang["Saecki/crates.nvim"] = {
	lazy = true,
	event = "BufReadPost Cargo.toml",
	config = require("lang.crates"),
	dependencies = "nvim-lua/plenary.nvim",
}
lang["MeanderingProgrammer/render-markdown.nvim"] = {
	lazy = true,
	ft = { "markdown", "codecompanion" },
	config = require("lang.render-markdown"),
}
lang["iamcco/markdown-preview.nvim"] = {
	lazy = true,
	ft = "markdown",
	build = ":call mkdp#util#install()",
}
lang["mfussenegger/nvim-lint"] = {
	lazy = true,
	event = { "BufReadPost", "BufNewFile" },
	config = require("lang.lint"),
}

lang["obsidian-nvim/obsidian.nvim"] = {
	lazy = true,
	cmd = "Obsidian",
	dependencies = {
		"nvim-lua/plenary.nvim",
	},
	config = require("lang.obsidian"),
}

lang["uga-rosa/translate.nvim"] = {
	lazy = true,
	cmd = { "Translate" },
	keys = {
		{ "<leader>tr", ":Translate ru<CR>", mode = "n", desc = "Translate word to Russian" },
		{ "<leader>tr", ":Translate ru<CR>", mode = "v", desc = "Translate selection to Russian" },
	},
	config = function()
		require("translate").setup({
			default = {
				command = "google",
			},
		})
	end,
}

return lang
