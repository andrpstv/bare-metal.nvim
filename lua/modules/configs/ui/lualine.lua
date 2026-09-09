return function()
	local function diff_source()
		local gitsigns = vim.b.gitsigns_status_dict
		if gitsigns then
			return {
				added = gitsigns.added,
				modified = gitsigns.changed,
				removed = gitsigns.removed,
			}
		end
		return nil
	end

	local mode_names = {
		n = "NOR",
		no = "NOR",
		v = "VIS",
		V = "Vl",
		["\22"] = "Vb",
		s = "SEL",
		S = "SEl",
		i = "INS",
		R = "REP",
		c = "CMD",
		["!"] = "!",
		t = "TER",
	}

	local mode_colors = {
		n = "#974b46",
		i = "#c1c1c1",
		v = "#af3a3a",
		V = "#af3a3a",
		["\22"] = "#af3a3a",
		c = "#5f8787",
		s = "#5f8787",
		S = "#5f8787",
		["\19"] = "#5f8787",
		R = "#974b46",
		r = "#974b46",
		["!"] = "#974b46",
		t = "#c1c1c1",
	}

	local function mode_color()
		local mode = vim.fn.mode()
		return { fg = "#000000", bg = mode_colors[mode] or "#974b46", gui = "bold" }
	end

	require("lualine").setup({
		options = {
			icons_enabled = true,
			theme = {
				normal = { a = { fg = "#505050", bg = "#000000", gui = "bold" }, b = { fg = "#c1c1c1", bg = "#000000" }, c = { fg = "#c1c1c1", bg = "#000000" } },
				insert = { a = { fg = "#000000", bg = "#c1c1c1", gui = "bold" }, b = { fg = "#c1c1c1", bg = "#000000" }, c = { fg = "#c1c1c1", bg = "#000000" } },
				visual = { a = { fg = "#000000", bg = "#974b46", gui = "bold" }, b = { fg = "#c1c1c1", bg = "#000000" }, c = { fg = "#c1c1c1", bg = "#000000" } },
				replace = { a = { fg = "#000000", bg = "#5f8787", gui = "bold" }, b = { fg = "#c1c1c1", bg = "#000000" }, c = { fg = "#c1c1c1", bg = "#000000" } },
				command = { a = { fg = "#000000", bg = "#5f8787", gui = "bold" }, b = { fg = "#c1c1c1", bg = "#000000" }, c = { fg = "#c1c1c1", bg = "#000000" } },
				inactive = { a = { fg = "#505050", bg = "#000000" }, b = { fg = "#505050", bg = "#000000" }, c = { fg = "#505050", bg = "#000000" } },
			},
			disabled_filetypes = { statusline = { "alpha", "neo-tree" } },
			component_separators = "",
			section_separators = "",
		},
		sections = {
			lualine_a = {
				{
					function()
						return " " .. (mode_names[vim.fn.mode(1)] or vim.fn.mode(1)) .. " "
					end,
				},
			},
			lualine_b = {
				{
					"filetype",
					colored = true,
					icon_only = true,
					separator = "",
					padding = { left = 1, right = 0 },
				},
				{
					"filename",
					path = 1,
					symbols = { modified = " [+]", readonly = " [-]", unnamed = "[No Name]" },
					padding = { left = 0, right = 1 },
				},
			},
			lualine_c = {},
			lualine_x = {},
			lualine_y = {
				{
					"diagnostics",
					sources = { "nvim_diagnostic" },
					sections = { "error", "warn", "info", "hint" },
					symbols = {
						error = "",
						warn = "",
						info = "",
						hint = "",
					},
				},
				{
					function()
						local names = {}
						for _, server in pairs(vim.lsp.get_clients({ bufnr = 0 })) do
							table.insert(names, server.name)
						end
						return "[" .. table.concat(names, " ") .. "]"
					end,
					cond = function()
						return #vim.lsp.get_clients({ bufnr = 0 }) > 0
					end,
				},
			},
			lualine_z = {
				{
					function()
						return "%5(%l:%c%)"
					end,
				},
				{
					"branch",
					icon = { " ", color = { bold = true } },
				},
				{
					"diff",
					source = diff_source,
					symbols = {
						added = "+",
						modified = "~",
						removed = "-",
					},
					padding = { left = 0, right = 0 },
					fmt = function(_, ctx)
						local stats = ctx.value
						if not stats then
							return ""
						end
						local parts = {}
						if stats.added and stats.added > 0 then
							table.insert(parts, "+" .. stats.added)
						end
						if stats.removed and stats.removed > 0 then
							table.insert(parts, "-" .. stats.removed)
						end
						if stats.modified and stats.modified > 0 then
							table.insert(parts, "~" .. stats.modified)
						end
						if #parts > 0 then
							return "(" .. table.concat(parts) .. ")"
						end
						return ""
					end,
				},
				{
					function()
						local lines = vim.fn.line("$")
						local suffix = { "b", "k", "M", "G", "T" }
						local fsize = vim.fn.getfsize(vim.api.nvim_buf_get_name(0))
						fsize = (fsize < 0 and 0) or fsize
						local size
						if fsize < 1024 then
							size = fsize .. suffix[1]
						else
							local i = math.floor((math.log(fsize) / math.log(1024)))
							size = string.format("%.2g%s", fsize / math.pow(1024, i), suffix[i + 1])
						end
						return "(" .. lines .. "l " .. size .. ")"
					end,
				},
			},
		},
		inactive_sections = {
			lualine_a = {},
			lualine_b = {},
			lualine_c = { "filename" },
			lualine_x = { "location" },
			lualine_y = {},
			lualine_z = {},
		},
		tabline = {},
		extensions = {},
	})
end
