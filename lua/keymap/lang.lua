-- Go: go.nvim (дебаг — dlv в терминале; DAP-стек вырезан как неиспользуемый).
-- silent! у тестов: go.nvim спамит Press-ENTER при отсутствии теста,
-- результат всё равно виден в quickfix.
local map = vim.keymap.set

-- gF убран: его существование заставляло `gf` ждать timeoutlen.
-- Fill struct теперь на <leader>fs.
-- Тесты — через dev.test (`go test -json`: падения в quickfix, итог нотифаем,
-- last_failed для <leader>tr, :TestOutput). Раньше здесь были :GoTestFunc/:GoTest
-- (go.nvim): связка ta→tr была разорвана — tr отвечал "nothing failed yet",
-- т.к. last_failed наполняет только dev.test-движок. Команды :GoTest/:GoTestFunc
-- остаются доступны напрямую; кеймапы ведут на единый движок.
map("n", "<leader>gt", function()
	require("dev.test").run("func")
end, { noremap = true, silent = true, desc = "test: Run test under cursor" })
map("n", "<leader>ta", function()
	require("dev.test").run("all")
end, { noremap = true, silent = true, desc = "test: Run all tests" })
map("n", "<leader>at", function()
	require("dev.test").run("all")
end, { noremap = true, silent = true, desc = "test: Run all tests (alias)" })
-- Запуск/сборка пакета ТЕКУЩЕГО ФАЙЛА: свой движок (dev.build) вместо
-- голых :GoRun/:GoBuild — те без аргументов выполняют `go run|build` в CWD
-- (корне проекта), а не в пакете (падало "no Go files" на nested-пакетах).
-- Команды :GoRun/:GoBuild остаются доступны напрямую.
map("n", "<leader>rr", function()
	require("dev.build").run()
end, { noremap = true, silent = true, desc = "go: Run package" })
map("n", "<leader>rb", function()
	require("dev.build").build()
end, { noremap = true, silent = true, desc = "go: Build package" })
map("n", "<leader>gf", ":GoAlt<CR>", { noremap = true, silent = true, desc = "go: Alternate file" })
map("n", "<leader>ga", ":GoAddTag<CR>", { noremap = true, silent = true, desc = "go: Add struct tag" })
map("n", "<leader>gx", ":GoRmTag<CR>", { noremap = true, silent = true, desc = "go: Remove struct tag" })
map("n", "<leader>gm", function()
	-- NOT :GoModTidy: go.nvim sends the current .go buffer URI to
	-- gopls.tidy (expects go.mod URIs, 2s timeout) and silently no-ops
	-- on real modules. Real `go mod tidy` with feedback instead.
	require("dev.gomod").tidy()
end, { noremap = true, silent = true, desc = "go: Mod tidy" })
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
