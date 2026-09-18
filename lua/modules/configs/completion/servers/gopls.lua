-- https://github.com/neovim/nvim-lspconfig/blob/master/lua/lspconfig/configs/gopls.lua
return {
	cmd = { "gopls" },
	filetypes = { "go", "gomod", "gosum", "gotmpl", "gohtmltmpl", "gotexttmpl" },
	flags = { allow_incremental_sync = true, debounce_text_changes = 150 },
	capabilities = {
		textDocument = {
			completion = {
				contextSupport = true,
				dynamicRegistration = true,
				completionItem = {
					commitCharactersSupport = true,
					deprecatedSupport = true,
					preselectSupport = true,
					insertReplaceSupport = true,
					labelDetailsSupport = true,
					snippetSupport = true,
					documentationFormat = { "markdown", "plaintext" },
					resolveSupport = {
						properties = {
							"documentation",
							"details",
							"additionalTextEdits",
						},
					},
				},
			},
		},
	},
	settings = {
		gopls = {
			gofumpt = true,
			staticcheck = true,
			semanticTokens = true,
			usePlaceholders = true,
			completeUnimported = true,
			symbolMatcher = "Fuzzy",
			buildFlags = { "-tags", "integration" },
			semanticTokenTypes = { string = false },
			directoryFilters = { "-.git", "-.vscode", "-.idea", "-node_modules" },
			analyses = {
				nilness = true,
				unusedparams = true,
				unusedwrite = true,
				useany = true,
			},
			codelenses = {
				generate = true,
				gc_details = true,
				test = true,
				tidy = true,
				vendor = true,
				regenerate_cgo = true,
				upgrade_dependency = true,
				organizeImports = true,
			},
		},
	},
}
