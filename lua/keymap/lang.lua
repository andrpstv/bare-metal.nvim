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
		["n|<leader>gT"] = map_cr("silent! GoTest"):with_noremap():with_silent():with_desc("go: Test all"),
		["n|<leader>gf"] = map_cr("GoAlt"):with_noremap():with_silent():with_desc("go: Alternate file"),
		["n|<leader>ga"] = map_cr("GoAddTag"):with_noremap():with_silent():with_desc("go: Add struct tag"),
		["n|<leader>gx"] = map_cr("GoRmTag"):with_noremap():with_silent():with_desc("go: Remove struct tag"),
		["n|<leader>gm"] = map_cr("GoModTidy"):with_noremap():with_silent():with_desc("go: Mod tidy"),
		["n|<leader>gF"] = map_cr("GoFillStruct"):with_noremap():with_silent():with_desc("go: Fill struct"),
		["n|<leader>ee"] = map_callback(function()
				if vim.bo.filetype == "go" then
					vim.cmd("GoIfErr")
				else
					vim.notify("GoIfErr works in Go files only", vim.log.levels.WARN)
				end
			end)
			:with_noremap()
			:with_silent()
			:with_desc("go: if err != nil"),
		-- Тот же GoIfErr из инсерта, без ухода в нормал руками.
		-- Побочка: после "␣e" в инсерте vim ждёт 300мс (timeoutlen),
		-- вдруг это начало маппинга, — мелкий лаг редких кейсов.
		["i|<leader>ee"] = map_cmd("<Esc>:GoIfErr<CR>a"):with_noremap():with_desc("go: if err != nil"),
	},
}

bind.nvim_load_mapping(mappings.plugins)
