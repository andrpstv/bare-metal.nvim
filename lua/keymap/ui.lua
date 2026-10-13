local map = vim.keymap.set

-- Builtins: Buffer
map("n", "<leader>bn", ":<C-u>enew<CR>", { noremap = true, silent = true, desc = "buffer: New" })

-- Builtins: Quickfix (пара к LSP-флоу на встроенке: gr/gi)
-- Переход + тающий значок «⟶ 3/17»: в длинном списке видно, где ты (dev.fx.badge).
local function qf_step(cmd)
	return function()
		local ok, err = pcall(vim.cmd, vim.v.count1 .. cmd)
		if not ok then
			vim.notify((tostring(err):gsub("^.-:E", "E")), vim.log.levels.WARN)
			return
		end
		local q = vim.fn.getqflist({ idx = 0, size = 0 })
		require("dev.fx").badge(0, { { "⟶ ", "FxBadge2" }, { tostring(q.idx), "FxBadge1" }, { "/" .. q.size, "FxBadge2" } })
	end
end
map("n", "]q", qf_step("cnext"), { noremap = true, silent = true, desc = "quickfix: Next" })
map("n", "[q", qf_step("cprev"), { noremap = true, silent = true, desc = "quickfix: Previous" })
map("n", "<leader>q", function()
	_toggle_qf()
end, { noremap = true, silent = true, desc = "quickfix: Toggle" })
map("n", "[b", ":bprevious<CR>", { noremap = true, silent = true, desc = "buffer: Previous" })
map("n", "]b", ":bnext<CR>", { noremap = true, silent = true, desc = "buffer: Next" })

-- Builtins: Split
map("n", "<leader>sv", ":vsplit<CR>", { noremap = true, silent = true, desc = "split: Vertical" })
map("n", "<leader>sh", ":split<CR>", { noremap = true, silent = true, desc = "split: Horizontal" })
map("n", "<leader>sc", ":close<CR>", { noremap = true, silent = true, desc = "split: Close" })

-- Builtins: Terminal
map("t", "<C-w>h", "<Cmd>wincmd h<CR>", { noremap = true, silent = true, desc = "window: Focus left" })
map("t", "<C-w>l", "<Cmd>wincmd l<CR>", { noremap = true, silent = true, desc = "window: Focus right" })
map("t", "<C-w>j", "<Cmd>wincmd j<CR>", { noremap = true, silent = true, desc = "window: Focus down" })
map("t", "<C-w>k", "<Cmd>wincmd k<CR>", { noremap = true, silent = true, desc = "window: Focus up" })
-- Из терминала (opencode, команды) — одним аккордом обратно в код: выйти
-- в normal и прыгнуть в предыдущее окно. C-o в terminal-mode свободен
-- (в normal не трогаем: там это jumplist-назад, святое).
map("t", "<C-o>", function()
	-- Float иначе остаётся поверх кода: прячем (job жив); split/vsplit — как раньше
	vim.cmd("stopinsert")
	if not require("dev.terminal").hide_float() then
		vim.cmd("wincmd p")
	end
end, { noremap = true, silent = true, desc = "terminal: back to code (previous window)" })

-- Builtins: Tabpage. На <leader>t*: голые tn/tk/tj/to перехватывали till-motion
-- (t+n открывал таб вместо прыжка к "n"), молча ломая базовый моушен.
map("n", "<leader>tn", ":tabnew<CR>", { noremap = true, silent = true, desc = "tab: Create a new tab" })
map("n", "<leader>tk", ":tabnext<CR>", { noremap = true, silent = true, desc = "tab: Move to next tab" })
map("n", "<leader>tj", ":tabprevious<CR>", { noremap = true, silent = true, desc = "tab: Move to previous tab" })
map("n", "<leader>to", ":tabonly<CR>", { noremap = true, silent = true, desc = "tab: Only keep current tab" })

-- Буферы: встроенные :bnext/:bprevious/:bd (barbar удалён)
map("n", "<A-q>", ":bd<CR>", { noremap = true, silent = true, desc = "buffer: Close current" })

-- Окна: встроенные <C-w> (smart-splits удалён)
map("n", "<C-h>", "<C-w>h", { noremap = true, silent = true, desc = "window: Focus left" })
map("n", "<C-j>", "<C-w>j", { noremap = true, silent = true, desc = "window: Focus down" })
map("n", "<C-k>", "<C-w>k", { noremap = true, silent = true, desc = "window: Focus up" })
map("n", "<C-l>", "<C-w>l", { noremap = true, silent = true, desc = "window: Focus right" })

--- The following code enables this file to be exported ---
---  for use with gitsigns lazy-loaded keymap bindings  ---

local M = {}

function M.gitsigns(bufnr)
	local gitsigns = require("gitsigns")
	map("n", "]g", function()
		if vim.wo.diff then
			return "]g"
		end
		vim.schedule(function()
			gitsigns.nav_hunk("next")
		end)
		return "<Ignore>"
	end, { buffer = bufnr, noremap = true, expr = true, desc = "git: Goto next hunk" })
	map("n", "[g", function()
		if vim.wo.diff then
			return "[g"
		end
		vim.schedule(function()
			gitsigns.nav_hunk("prev")
		end)
		return "<Ignore>"
	end, { buffer = bufnr, noremap = true, expr = true, desc = "git: Goto prev hunk" })
	map("n", "<leader>gs", function()
		gitsigns.stage_hunk()
	end, { buffer = bufnr, noremap = true, desc = "git: Toggle staging/unstaging of hunk" })
	map("x", "<leader>gs", function()
		gitsigns.stage_hunk({ vim.fn.line("."), vim.fn.line("v") })
	end, { buffer = bufnr, noremap = true, desc = "git: Toggle staging/unstaging of selected hunk" })
	map("n", "<leader>gr", function()
		gitsigns.reset_hunk()
	end, { buffer = bufnr, noremap = true, desc = "git: Reset hunk" })
	map("x", "<leader>gr", function()
		gitsigns.reset_hunk({ vim.fn.line("."), vim.fn.line("v") })
	end, { buffer = bufnr, noremap = true, desc = "git: Reset hunk" })
	map("n", "<leader>gR", function()
		gitsigns.reset_buffer()
	end, { buffer = bufnr, noremap = true, desc = "git: Reset buffer" })
	map("n", "<leader>gp", function()
		gitsigns.preview_hunk()
	end, { buffer = bufnr, noremap = true, desc = "git: Preview hunk" })
	map("n", "<leader>gb", function()
		gitsigns.blame_line({ full = true })
	end, { buffer = bufnr, noremap = true, desc = "git: Blame line" })
	map("n", "<leader>gB", function()
		gitsigns.toggle_current_line_blame()
	end, { buffer = bufnr, noremap = true, desc = "git: Toggle inline blame" })
	-- Text objects
	map({ "o", "x" }, "ih", function()
		gitsigns.select_hunk()
	end, { buffer = bufnr, noremap = true, desc = "git: hunk text-object" })
end

return M
