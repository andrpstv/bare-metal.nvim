local bind = require("keymap.bind")
local map_cr = bind.map_cr
local map_cmd = bind.map_cmd

local mappings = {
	plugins = {
		-- Plugin: render-markdown.nvim
		["n|<F1>"] = map_cr("RenderMarkdown toggle")
			:with_noremap()
			:with_silent()
			:with_desc("tool: toggle markdown preview within nvim"),
		-- Plugin: MarkdownPreview
		["n|<F12>"] = map_cr("MarkdownPreviewToggle"):with_noremap():with_silent():with_desc("tool: Preview markdown"),

		-- Go: go.nvim
		["n|<leader>gt"] = map_cr("GoTestFunc"):with_noremap():with_silent():with_desc("go: Test function"),
		["n|<leader>gT"] = map_cr("GoTest"):with_noremap():with_silent():with_desc("go: Test all"),
		["n|<leader>gf"] = map_cr("GoAlt"):with_noremap():with_silent():with_desc("go: Alternate file"),
		["n|<leader>ga"] = map_cr("GoAddTag"):with_noremap():with_silent():with_desc("go: Add struct tag"),
		["n|<leader>gx"] = map_cr("GoRmTag"):with_noremap():with_silent():with_desc("go: Remove struct tag"),
		["n|<leader>gB"] = map_cr("GoBreakToggle"):with_noremap():with_silent():with_desc("go: Toggle breakpoint"),
		["n|<leader>gN"] = map_cr("GoDebug"):with_noremap():with_silent():with_desc("go: Debug"),
		["n|<leader>gS"] = map_cr("GoDbgStop"):with_noremap():with_silent():with_desc("go: Stop debug"),
		["n|<leader>gm"] = map_cr("GoModTidy"):with_noremap():with_silent():with_desc("go: Mod tidy"),
		["n|<leader>gn"] = map_cmd("lua vim.lsp.buf.rename()"):with_noremap():with_silent():with_desc("go: Rename symbol"),
		["n|<leader>gi"] = map_cmd("lua vim.lsp.buf.code_action()"):with_noremap():with_silent():with_desc("go: Code action"),
		["n|<leader>gF"] = map_cr("GoFillStruct"):with_noremap():with_silent():with_desc("go: Fill struct"),
	},
}

bind.nvim_load_mapping(mappings.plugins)
