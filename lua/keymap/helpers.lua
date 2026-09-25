-- Small _G toggles used by keymaps (flash/noh, inlay-hint, virtlines, quickfix).
_G._flash_esc_or_noh = function()
	local flash_active, state = pcall(function()
		return require("flash.plugins.char").state
	end)
	if flash_active and state then
		state:hide()
	else
		pcall(vim.cmd.noh)
	end
end

_G._toggle_inlayhint = function()
	if #vim.lsp.get_clients({ bufnr = 0, method = "textDocument/inlayHint" }) == 0 then
		vim.notify("No inlay-hint client here", vim.log.levels.INFO, { title = "LSP Inlay Hint" })
		return
	end
	local is_enabled = vim.lsp.inlay_hint.is_enabled({ bufnr = 0 })
	vim.lsp.inlay_hint.enable(not is_enabled)
	vim.notify(
		(is_enabled and "Inlay hint disabled successfully" or "Inlay hint enabled successfully"),
		vim.log.levels.INFO,
		{ title = "LSP Inlay Hint" }
	)
end

_G._toggle_virtuallines = function()
	local current = vim.diagnostic.config().virtual_lines
	vim.diagnostic.config({ virtual_lines = not current })
	vim.notify(
		"Virtual lines are now " .. (current and "hidden" or "displayed"),
		vim.log.levels.INFO,
		{ title = "LSP Diagnostic" }
	)
end

-- Тоггл quickfix одним хоткеем вместо пары открыть/закрыть.
_G._toggle_qf = function()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.fn.getwininfo(win)[1].quickfix == 1 then
			vim.cmd("cclose")
			return
		end
	end
	vim.cmd("copen")
end
