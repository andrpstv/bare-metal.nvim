-- Go: go.nvim (дебаг через dlv в терминале, dap-плагины удалены)
-- silent! у тестов: go.nvim спамит Press-ENTER при отсутствии теста,
-- результат всё равно виден в quickfix.
local map = vim.keymap.set

-- gF убран: его существование заставляло `gf` ждать timeoutlen.
-- Fill struct теперь на <leader>fs.
map("n", "<leader>gt", ":silent! GoTestFunc<CR>", { noremap = true, silent = true, desc = "go: Test function" })
map("n", "<leader>ta", ":silent! GoTest<CR>", { noremap = true, silent = true, desc = "go: Test all" })
map("n", "<leader>gf", ":GoAlt<CR>", { noremap = true, silent = true, desc = "go: Alternate file" })
map("n", "<leader>ga", ":GoAddTag<CR>", { noremap = true, silent = true, desc = "go: Add struct tag" })
map("n", "<leader>gx", ":GoRmTag<CR>", { noremap = true, silent = true, desc = "go: Remove struct tag" })
map("n", "<leader>gm", ":GoModTidy<CR>", { noremap = true, silent = true, desc = "go: Mod tidy" })
map("n", "<leader>fs", ":GoFillStruct<CR>", { noremap = true, silent = true, desc = "go: Fill struct" })
-- GoIfErr на `ie` (if err), а НЕ на `e*`: любой <leader>eX
-- заставляет bare <leader>e ждать timeoutlen. Так тоггл мгновенный.
map("n", "<leader>ie", function()
	if vim.bo.filetype == "go" then
		vim.cmd("GoIfErr")
	else
		vim.notify("GoIfErr works in Go files only", vim.log.levels.WARN)
	end
end, { noremap = true, silent = true, desc = "go: if err != nil" })
-- Инсерт-версии НЕТ осознанно: любой маппинг на <leader> в инсерте
-- заставляет КАЖДЫЙ пробел ждать timeoutlen (фриз при печати).
-- В инсерте вместо этого сниппет: `ir` + Tab (friendly-snippets).
-- Подставить возвращаемые значения в переменные: `f()` -> `x, err := f()`.
map("n", "<leader>ar", function()
	_go_assign_vars()
end, { noremap = true, silent = true, desc = "go: assign call results (x, err := f())" })
