local bind = require("keymap.bind")
local map_cr = bind.map_cr
local map_cmd = bind.map_cmd

local mappings = {
	plugins = {
		-- Go: go.nvim (дебаг через dlv в терминале, dap-плагины удалены)
		["n|<leader>gt"] = map_cr("GoTestFunc"):with_noremap():with_silent():with_desc("go: Test function"),
		["n|<leader>gT"] = map_cr("GoTest"):with_noremap():with_silent():with_desc("go: Test all"),
		["n|<leader>gf"] = map_cr("GoAlt"):with_noremap():with_silent():with_desc("go: Alternate file"),
		["n|<leader>ga"] = map_cr("GoAddTag"):with_noremap():with_silent():with_desc("go: Add struct tag"),
		["n|<leader>gx"] = map_cr("GoRmTag"):with_noremap():with_silent():with_desc("go: Remove struct tag"),
		["n|<leader>gm"] = map_cr("GoModTidy"):with_noremap():with_silent():with_desc("go: Mod tidy"),
		["n|<leader>gn"] = map_cmd("lua vim.lsp.buf.rename()"):with_noremap():with_silent():with_desc("go: Rename symbol"),
		["n|<leader>gi"] = map_cmd("lua vim.lsp.buf.code_action()"):with_noremap():with_silent():with_desc("go: Code action"),
		["n|<leader>gF"] = map_cr("GoFillStruct"):with_noremap():with_silent():with_desc("go: Fill struct"),
	},
}

bind.nvim_load_mapping(mappings.plugins)
