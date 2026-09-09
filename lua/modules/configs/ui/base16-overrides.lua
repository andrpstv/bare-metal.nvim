return function()
	vim.api.nvim_create_autocmd("ColorScheme", {
		pattern = "*",
		callback = function()
			if vim.g.colors_name ~= "base16-vesper" then
				return
			end

			local overrides = {
				Comment = { fg = "#6a737d", italic = true },
				Keyword = { fg = "#c586c0", bold = true },
				Conditional = { fg = "#c586c0", bold = true },
				Repeat = { fg = "#c586c0", bold = true },
				Function = { fg = "#dcdcaa" },
				Variable = { fg = "#9cdcfe" },
				Property = { fg = "#9cdcfe" },
				Operator = { fg = "#d4d4d4" },
				String = { fg = "#ce9178" },
				Number = { fg = "#b5cea8" },
				Boolean = { fg = "#569cd6" },
				Type = { fg = "#4ec9b0" },
				Constant = { fg = "#4fc1ff" },
				Identifier = { fg = "#9cdcfe" },
				Special = { fg = "#ce9178" },
				Parameter = { fg = "#9cdcfe" },

				["@keyword"] = { link = "Keyword" },
				["@keyword.return"] = { fg = "#c586c0", bold = true },
				["@keyword.function"] = { fg = "#c586c0" },
				["@keyword.conditional"] = { link = "Keyword" },
				["@keyword.repeat"] = { link = "Keyword" },
				["@keyword.operator"] = { fg = "#d4d4d4" },
				["@keyword.import"] = { fg = "#c586c0" },
				["@function"] = { link = "Function" },
				["@function.builtin"] = { fg = "#dcdcaa" },
				["@type"] = { link = "Type" },
				["@type.builtin"] = { fg = "#4ec9b0" },
				["@string"] = { link = "String" },
				["@string.escape"] = { fg = "#d7ba7d" },
				["@number"] = { link = "Number" },
				["@boolean"] = { link = "Boolean" },
				["@constant"] = { link = "Constant" },
				["@constant.builtin"] = { fg = "#4fc1ff" },
				["@variable"] = { link = "Variable" },
				["@variable.builtin"] = { fg = "#4fc1ff" },
				["@variable.parameter"] = { fg = "#9cdcfe" },
				["@property"] = { link = "Property" },
				["@operator"] = { link = "Operator" },
				["@punctuation"] = { fg = "#d4d4d4" },
				["@punctuation.bracket"] = { fg = "#d4d4d4" },
				["@punctuation.delimiter"] = { fg = "#d4d4d4" },
				["@constructor"] = { fg = "#dcdcaa" },

				["@lsp.type.variable"] = { link = "@variable" },
				["@lsp.type.property"] = { link = "@property" },
				["@lsp.type.function"] = { link = "@function" },
				["@lsp.type.type"] = { link = "@type" },
				["@lsp.type.keyword"] = { link = "@keyword" },
				["@lsp.type.parameter"] = { link = "@variable.parameter" },
				["@lsp.mod.declaration"] = {},

				DiagnosticError = { fg = "#f44747" },
				DiagnosticWarn = { fg = "#cca700" },
				DiagnosticInfo = { fg = "#75beff" },
				DiagnosticHint = { fg = "#c586c0" },

				diffAdd = { fg = "#6a9955" },
				diffDelete = { fg = "#f44747" },
				diffChange = { fg = "#cca700" },

				StatusLine = { bg = "#252526", fg = "#cccccc" },
			}

			for group, opts in pairs(overrides) do
				vim.api.nvim_set_hl(0, group, opts)
			end
		end,
	})

	vim.defer_fn(function()
		if vim.g.colors_name and vim.g.colors_name == "base16-vesper" then
			vim.cmd("colorscheme base16-vesper")
		end
	end, 100)
end
