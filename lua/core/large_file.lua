-- Large files: detect early, enforce late (filetype is final only on BufReadPost).
local settings = require("core.settings")
local M = {}

-- Thresholds come from settings so the owner can retune without editing logic.
-- 0 (or nil) disables that dimension. See lua/core/settings.lua for rationale:
-- previous hardcoded 10000 lines let ~5000-line Go files through untouched.
local function max_lines()
	local n = tonumber(settings.large_file_max_lines)
	if n and n > 0 then
		return n
	end
	return math.huge
end

local function max_kb()
	local n = tonumber(settings.large_file_max_kb)
	if n and n > 0 then
		return n
	end
	return math.huge
end

--- Line-count check, shared by detect and enforce so the two never disagree.
--- >= (not >): a file of exactly the threshold counts as large.
local function over_line_limit(bufnr)
	return vim.api.nvim_buf_line_count(bufnr) >= max_lines()
end

-- Large file detection: disable expensive features over the size OR line limits
local function is_large_file(bufnr)
	local limit_kb = max_kb()
	local ok, stats = pcall(vim.uv.fs_stat, vim.api.nvim_buf_get_name(bufnr))
	if ok and stats and limit_kb < math.huge and stats.size > limit_kb * 1024 then
		return true
	end
	if over_line_limit(bufnr) then
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
	if not (vim.b[buf].large_file or over_line_limit(buf)) then
		return false
	end
	if not vim.b[buf].large_file then
		vim.b[buf].large_file = true
		vim.schedule(function()
			-- max_lines() может быть math.huge (порог выключен через 0) —
			-- %d по inf бросает ошибку, поэтому подставляем только конечное число.
			local lim = max_lines()
			local msg = "Large file detected: disabled LSP, Treesitter, undo"
			if lim < math.huge then
				msg = string.format("Large file detected (>=%d lines): disabled LSP, Treesitter, undo", lim)
			end
			vim.notify(msg, vim.log.levels.WARN, { title = "Large File" })
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
