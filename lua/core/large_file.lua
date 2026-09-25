-- Large files: detect early, enforce late (filetype is final only on BufReadPost).
local M = {}
-- Large file detection: disable expensive features for files > 1MB or > 10k lines
local function is_large_file(bufnr)
	local max_size = 1024 * 1024 -- 1MB
	local max_lines = 10000
	local ok, stats = pcall(vim.uv.fs_stat, vim.api.nvim_buf_get_name(bufnr))
	if ok and stats and stats.size > max_size then
		return true
	end
	if vim.api.nvim_buf_line_count(bufnr) > max_lines then
		return true
	end
	return false
end

vim.api.nvim_create_autocmd({ "BufReadPre", "BufNewFile" }, {
	group = vim.api.nvim_create_augroup("LargeFileDetect", { clear = true }),
	callback = function(args)
		if is_large_file(args.buf) then
			vim.b[args.buf].large_file = true
			-- Disable expensive features (foldmethod is window-local: vim.wo, not vim.bo)
			vim.bo[args.buf].syntax = "off"
			vim.bo[args.buf].filetype = "off"
			vim.bo[args.buf].swapfile = false
			vim.bo[args.buf].undofile = false
			pcall(function()
				vim.wo[0][0].foldmethod = "manual"
				vim.wo[0][0].cursorline = false
				vim.wo[0][0].cursorcolumn = false
				vim.wo[0][0].foldenable = false
				vim.wo[0][0].list = false
				vim.wo[0][0].spell = false
			end)
			-- Disable LSP for this buffer
			vim.b[args.buf].lsp_disable = true
			-- Notify once
			vim.schedule(function()
				vim.notify("Large file detected: disabled syntax, LSP, Treesitter, swap, undo", vim.log.levels.WARN, { title = "Large File" })
			end)
		end
	end,
})

---Enforce large-file restrictions. Call from BufReadPost; returns true when large
---(caller must return early and skip mark-restore etc.).
---@param buf integer
---@return boolean
function M.enforce(buf)
	if not (vim.b[buf].large_file or vim.api.nvim_buf_line_count(buf) > 10000) then
		return false
	end
	if not vim.b[buf].large_file then
		vim.b[buf].large_file = true
		vim.schedule(function()
			vim.notify("Large file detected (>10k lines): disabled LSP, Treesitter, undo", vim.log.levels.WARN, { title = "Large File" })
		end)
	end
	vim.b[buf].lsp_disable = true
	pcall(function()
		vim.bo[buf].filetype = "off"
		vim.bo[buf].swapfile = false
		vim.bo[buf].undofile = false
	end)
	pcall(function()
		vim.wo[0][0].foldmethod = "manual"
	end)
	-- Уже прицепившийся treesitter (FileType отработал раньше нас) — остановить.
	pcall(vim.treesitter.stop, buf)
	-- Клиенты, успевшие аттачнуться до нас — открепить сразу.
	for _, c in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
		pcall(vim.lsp.buf_detach_client, buf, c.id)
	end
	return true
end

return M
