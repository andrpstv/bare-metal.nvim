return function()
	vim.api.nvim_create_autocmd("FileType", {
		pattern = "markdown",
		callback = function()
			vim.opt_local.conceallevel = 2
		end,
	})
	require("obsidian").setup({
		legacy_commands = false,
		workspaces = {
			{
				name = "personal",
				path = "~/obsidian-vault",
			},
		},
		picker = {
			name = "telescope.nvim",
		},
		daily_notes = {
			folder = "dailies",
			date_format = "%Y-%m-%d",
		},
		lsp = {
			name = "obsidian-ls",
		},
	})
end
