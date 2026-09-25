-- https://github.com/neovim/nvim-lspconfig/blob/master/lua/lspconfig/configs/gopls.lua
local settings = require("core.settings")
local cl = settings.gopls_codelenses or {}
return {
	-- PERF: штатный root_dir lspconfig дергает `go env` 2-4 раза на каждый аттач;
	-- заменяем чистым поиском маркеров без внешних процессов.
	root_dir = function(bufnr, on_dir)
		local f = vim.api.nvim_buf_get_name(bufnr)
		on_dir(vim.fs.root(f, { "go.work", "go.mod", ".git" }) or vim.fn.getcwd())
	end,
	cmd = { "gopls" },
	filetypes = { "go", "gomod", "gosum", "gotmpl", "gohtmltmpl", "gotexttmpl" },
	flags = { allow_incremental_sync = true, debounce_text_changes = settings.gopls_debounce or 150 },
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
			-- PERF: staticcheck на больших файлах заметно утяжеляет диагностику gopls.
			staticcheck = false,
			semanticTokens = settings.gopls_semantic_tokens ~= false,
			usePlaceholders = true,
			completeUnimported = settings.gopls_complete_unimported ~= false,
			symbolMatcher = "Fuzzy",
			buildFlags = { "-tags", "integration" },
			semanticTokenTypes = { string = false },
			directoryFilters = { "-.git", "-.vscode", "-.idea", "-node_modules" },
			analyses = {
				nilness = true,
				unusedparams = true,
				unusedwrite = true,
				useany = true,
				-- Дорогой memory-анализ: выключается через settings.gopls_fieldalignment.
				fieldalignment = settings.gopls_fieldalignment ~= false,
				httpresponse = true, -- незакрытые http response body
			},
			codelenses = {
				generate = cl.generate ~= false,
				gc_details = cl.gc_details ~= false,
				test = cl.test ~= false,
				tidy = cl.tidy ~= false,
				vendor = cl.vendor ~= false,
				regenerate_cgo = cl.regenerate_cgo ~= false,
				upgrade_dependency = cl.upgrade_dependency ~= false,
				organizeImports = cl.organizeImports ~= false,
			},
		},
	},
}
