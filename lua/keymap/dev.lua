-- keymap/dev — Phase-1 capabilities: terminal, test, replace, project, git UI, debug.
--
-- Модель префиксов (существующие семьи НЕ тронуты):
--   <leader>t*  run-цикл: ta (есть) + tt/ts/tv/te/tw (терминал) + tr/tc/tC/tb (тесты) + td (debug test)
--   <leader>d*  debug (dap): db/dB/dc/dn/di/do/dx/dl/dr/de/dw/df
--   <leader>sr  project replace (n — промпт, x — из выделения)
--   <leader>G   Neogit (gg занят go-get-missing)
--   <leader>w*  workspace/project: wp switch, ws save
-- Все тяжёлые модули требуются только по нажатию: цена старта ноль.

local map = vim.keymap.set

-- Terminal (dev.terminal, builtin :terminal, project-local persist)
map("n", "<leader>tt", function()
	require("dev.terminal").toggle()
end, { noremap = true, silent = true, desc = "terminal: Toggle project terminal (float)" })
map("n", "<leader>ts", function()
	require("dev.terminal").open("split")
end, { noremap = true, silent = true, desc = "terminal: Project terminal in split" })
map("n", "<leader>tv", function()
	require("dev.terminal").open("vsplit")
end, { noremap = true, silent = true, desc = "terminal: Project terminal in vsplit" })
map("n", "<leader>te", function()
	vim.ui.input({ prompt = "Run in project terminal: " }, function(cmd)
		if cmd and cmd ~= "" then
			require("dev.terminal").send(cmd, true)
		end
	end)
end, { noremap = true, silent = true, desc = "terminal: Send command to project terminal" })
map("n", "<leader>tw", function()
	require("dev.terminal").wipe()
end, { noremap = true, silent = true, desc = "terminal: Wipe project terminal (fresh shell next)" })
vim.api.nvim_create_user_command("TermToggle", function()
	require("dev.terminal").toggle()
end, { desc = "terminal: toggle project terminal" })
vim.api.nvim_create_user_command("TermSend", function(opts)
	if opts.args and opts.args ~= "" then
		require("dev.terminal").send(opts.args, true)
	end
end, { nargs = 1, desc = "terminal: send command to project terminal" })

-- Test (dev.test, `go test -json`; go.nvim команды остаются как были)
map("n", "<leader>tr", function()
	require("dev.test").rerun()
end, { noremap = true, silent = true, desc = "test: Rerun failed packages" })
map("n", "<leader>tc", function()
	require("dev.test").coverage()
end, { noremap = true, silent = true, desc = "test: Coverage (marks + %)" })
map("n", "<leader>tC", function()
	require("dev.test").coverage_clear()
end, { noremap = true, silent = true, desc = "test: Clear coverage marks" })
map("n", "<leader>tb", function()
	require("dev.test").bench()
end, { noremap = true, silent = true, desc = "test: Run benchmark (func under cursor, else package)" })
vim.api.nvim_create_user_command("TestBench", function()
	require("dev.test").bench()
end, { desc = "test: run benchmark (func under cursor, else package)" })
vim.api.nvim_create_user_command("TestOutput", function()
	require("dev.test").show_output()
end, { desc = "test: show raw output of last run" })
vim.api.nvim_create_user_command("TestCovClear", function()
	require("dev.test").coverage_clear()
end, { desc = "test: clear coverage marks" })

-- Replace (dev.replace, rg → quickfix → confirm → apply)
map("n", "<leader>sr", function()
	require("dev.replace").project()
end, { noremap = true, silent = true, desc = "search: Replace in project (preview in quickfix)" })
map("x", "<leader>sr", function()
	require("dev.replace").visual()
end, { noremap = true, silent = true, desc = "search: Replace selection in project" })

-- Project (dev.project; <leader>ss/sl остаются, формат сессий тот же)
map("n", "<leader>wp", function()
	require("dev.project").switch()
end, { noremap = true, silent = true, desc = "project: Switch project" })
map("n", "<leader>ws", function()
	require("dev.project").save()
end, { noremap = true, silent = true, desc = "project: Save session for project root" })
vim.api.nvim_create_user_command("ProjectSwitch", function()
	require("dev.project").switch()
end, { desc = "project: switch project" })
require("dev.project").wire()

-- Git UI: Neogit через cmd-stub лоадера (грузится по первому вызову).
map("n", "<leader>G", ":Neogit<CR>", { noremap = true, silent = true, desc = "git: Status UI (commit/push/pull/log)" })

-- Debug (dev.debug; dap грузится только по первому нажатию).
require("dev.debug").setup_keymaps()
