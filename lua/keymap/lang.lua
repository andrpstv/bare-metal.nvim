local bind = require("keymap.bind")
local map_cr = bind.map_cr
local map_cmd = bind.map_cmd
local map_callback = bind.map_callback

local mappings = {
	plugins = {
		-- Go: go.nvim (дебаг через dlv в терминале, dap-плагины удалены)
		-- silent! у тестов: go.nvim спамит Press-ENTER при отсутствии теста,
		-- результат всё равно виден в quickfix.
		["n|<leader>gt"] = map_cr("silent! GoTestFunc"):with_noremap():with_silent():with_desc("go: Test function"),
		["n|<leader>ta"] = map_cr("silent! GoTest"):with_noremap():with_silent():with_desc("go: Test all"),
		["n|<leader>gf"] = map_cr("GoAlt"):with_noremap():with_silent():with_desc("go: Alternate file"),
		["n|<leader>ga"] = map_cr("GoAddTag"):with_noremap():with_silent():with_desc("go: Add struct tag"),
		["n|<leader>gx"] = map_cr("GoRmTag"):with_noremap():with_silent():with_desc("go: Remove struct tag"),
		["n|<leader>gm"] = map_cr("GoModTidy"):with_noremap():with_silent():with_desc("go: Mod tidy"),
		-- gF убран: его существование заставляло `gf` ждать timeoutlen.
		-- Fill struct теперь на <leader>fs.
		["n|<leader>fs"] = map_cr("GoFillStruct"):with_noremap():with_silent():with_desc("go: Fill struct"),
		-- GoIfErr на `ie` (if err), а НЕ на `e*`: любой <leader>eX
		-- заставляет bare <leader>e ждать timeoutlen. Так тоггл мгновенный.
		["n|<leader>ie"] = map_callback(function()
				if vim.bo.filetype == "go" then
					vim.cmd("GoIfErr")
				else
					vim.notify("GoIfErr works in Go files only", vim.log.levels.WARN)
				end
			end)
			:with_noremap()
			:with_silent()
			:with_desc("go: if err != nil"),
		-- Инсерт-версии НЕТ осознанно: любой маппинг на <leader> в инсерте
		-- заставляет КАЖДЫЙ пробел ждать timeoutlen (фриз при печати).
		-- В инсерте вместо этого сниппет: `ir` + Tab (friendly-snippets).
		-- Подставить возвращаемые значения в переменные: `f()` -> `x, err := f()`.
		["n|<leader>ar"] = map_callback(function()
				_go_assign_vars()
			end)
			:with_noremap()
			:with_silent()
			:with_desc("go: assign call results (x, err := f())"),
	},
}

bind.nvim_load_mapping(mappings.plugins)
