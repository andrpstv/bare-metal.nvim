local M = {}

M.plugin = "metalelf0/black-metal-theme-neovim"

M.setup = function()
	-- Бленды в эстетике темы (считаем её же Util; фолбэк — руками).
	local blend_ok, Util = pcall(require, "black-metal.util")
	local function blend(fg, coeff, bg, fallback)
		if blend_ok and Util.blend then
			local ok, res = pcall(Util.blend, fg, coeff, bg)
			if ok and res then
				return res
			end
		end
		return fallback
	end
	require("black-metal").setup({
		theme = "khold",
		comments = { italic = true },
		backgrounds = { "term", "float", "popup", "sidebar" },
		-- term_colors ВЫКЛЮЧЕНЫ осознанно: в палитре khold перепутаны
		-- имена (diag_red — teal, diag_green — red), иначе в :terminal
		-- красный/зелёный поменяны местами (git diff врёт).
		term_colors = false,
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
			-- Diff: в палитре перепутаны diag_red/diag_green, поэтому
			-- added светился красным, а deleted — зелёным. Правим явно
			-- в тех же пропорциях бленда, что у темы.
			DiffAdd = { bg = blend("#5f8787", 0.3, "#000000", "#1d2929") },
			DiffDelete = { bg = blend("#974b46", 0.4, "#000000", "#3c1e1c") },
			ErrorMsg = { fg = "#af3a3a", fmt = "bold" },
			SpellBad = { sp = "#af3a3a", fmt = "undercurl" },
			SpellCap = { sp = "#af3a3a", fmt = "undercurl" },
			SpellLocal = { sp = "#888888", fmt = "undercurl" },
			SpellRare = { sp = "#888888", fmt = "undercurl" },
			debugPC = { fg = "#af3a3a" },
			debugBreakpoint = { fg = "#af3a3a" },
			-- Git signs: полный набор (иначе Ln/Nr/Cul-варианты берут
			-- инвертированные diag_* из темы).
			GitSignsAdd = { fg = "#5f8787" },
			GitSignsAddLn = { fg = "#5f8787" },
			GitSignsAddNr = { fg = "#5f8787" },
			GitSignsAddCul = { fg = "#5f8787" },
			GitSignsChange = { fg = "#888888" },
			GitSignsChangeLn = { fg = "#888888" },
			GitSignsChangeNr = { fg = "#888888" },
			GitSignsChangeCul = { fg = "#888888" },
			GitSignsDelete = { fg = "#974b46" },
			GitSignsDeleteLn = { fg = "#974b46" },
			GitSignsDeleteNr = { fg = "#974b46" },
			GitSignsDeleteCul = { fg = "#974b46" },
			-- Diffview: статусы файлов (M/D/?) в правильных цветах.
			DiffviewStatusDeleted = { fg = "#974b46" },
			DiffviewStatusUnknown = { fg = "#974b46" },
			DiffviewStatusBroken = { fg = "#974b46" },
			DiffviewStatusAdded = { fg = "#c1c1c1" },
			DapBreakpoint = { fg = "#af3a3a" },
			DapBreakpointCondition = { fg = "#af3a3a" },
			DapBreakpointRejected = { fg = "#888888" },
			DapStopped = { fg = "#5f8787" },
			DapLogPoint = { fg = "#aaaaaa" },
			Search = { fg = "#000000", bg = "#ffffff" },
			IncSearch = { fg = "#000000", bg = "#ffffff", fmt = "bold" },
			CurSearch = { fg = "#ffffff", bg = "#af3a3a", fmt = "bold" },
			Substitute = { fg = "#ffffff", bg = "#af3a3a" },
		},
	})
	require("black-metal").load()
end

return M
