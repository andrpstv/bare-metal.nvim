return function()
	require("completion.neoconf").setup()
	require("completion.mason").setup()
	require("completion.mason-lspconfig").setup()

	pcall(require, "user.configs.lsp")
end
