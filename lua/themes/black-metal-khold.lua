local M = {}

M.plugin = "metalelf0/black-metal-theme-neovim"

M.setup = function()
	require("black-metal").setup({
		theme = "khold",
		comments = { italic = true },
		backgrounds = { "term", "float", "popup", "sidebar" },
		highlights = {
			["@module"] = { fg = "$fg" },
			["@lsp.type.module"] = { fg = "$fg" },
			["@lsp.type.namespace"] = { fg = "$fg" },
			["@keyword"] = { fg = "#974b46" },
			["@keyword.type"] = { fg = "#974b46" },
			["@keyword.return"] = { fg = "#974b46" },
			["@keyword.conditional"] = { fg = "#974b46" },
			["@keyword.operator"] = { fg = "#974b46" },
			["@keyword.exception"] = { fg = "#974b46" },
			Keyword = { fg = "#974b46" },
			Statement = { fg = "#974b46" },
			Conditional = { fg = "#974b46" },
			Exception = { fg = "#974b46" },
			Include = { fg = "$fg" },
			["@keyword.import"] = { fg = "$fg" },
			["@type"] = { fg = "#888888" },
			["@type.builtin"] = { fg = "#888888" },
			["@type.definition"] = { fg = "#888888" },
			["@lsp.type.type"] = { fg = "#888888" },
			["@lsp.type.class"] = { fg = "#888888" },
			["@lsp.type.struct"] = { fg = "#888888" },
			["@lsp.type.interface"] = { fg = "#888888" },
			["@lsp.type.enum"] = { fg = "#888888" },
			Type = { fg = "#888888" },
			DiagnosticError = { fg = "#af3a3a" },
			DiagnosticWarn = { fg = "#aaaaaa" },
			DiagnosticInfo = { fg = "#999999", fmt = "italic" },
			DiagnosticHint = { fg = "#888888", fmt = "italic" },
			DiagnosticUnderlineError = { sp = "#af3a3a", fmt = "underline" },
			DiagnosticUnderlineWarn = { sp = "#aaaaaa", fmt = "underline" },
			DiagnosticVirtualTextError = { fg = "#af3a3a" },
			DiagnosticVirtualTextWarn = { fg = "#aaaaaa" },
			DiagnosticVirtualTextInfo = { fg = "#999999" },
			DiagnosticVirtualTextHint = { fg = "#888888" },
			DapBreakpoint = { fg = "#af3a3a" },
			DapBreakpointCondition = { fg = "#af3a3a" },
			DapBreakpointRejected = { fg = "#888888" },
			DapStopped = { fg = "#5f8787" },
			DapLogPoint = { fg = "#aaaaaa" },
			Search = { fg = "#000000", bg = "#ffffff" },
			IncSearch = { fg = "#000000", bg = "#ffffff", fmt = "bold" },
			CurSearch = { fg = "#ffffff", bg = "#af3a3a", fmt = "bold" },
			Substitute = { fg = "#ffffff", bg = "#af3a3a" },
			-- Git signs
			GitSignsAdd = { fg = "#5f8787" },
			GitSignsChange = { fg = "#888888" },
			GitSignsDelete = { fg = "#974b46" },
		},
	})
	require("black-metal").load()
end

return M
