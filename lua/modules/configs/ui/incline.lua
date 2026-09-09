return function()
	require("incline").setup({
		render = function(props)
			local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(props.buf), ":t")
			local win_num = vim.api.nvim_win_get_number(props.win)
			local modified = vim.bo[props.buf].modified

			local status = modified and "[+]" or ""
			local status_color = modified and "#af3a3a" or nil

			return {
				{ " " .. filename .. " ", guifg = "#aaaaaa" },
				{ status .. " ", guifg = status_color },
				{ " " .. win_num .. " ", guifg = "#000000", guibg = "#974b46" },
			}
		end,
		hide = { cursorline = true },
		window = {
			padding = 0,
			margin = { horizontal = 0, vertical = 0 },
		},
	})
end
