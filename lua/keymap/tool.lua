local bind = require("keymap.bind")
local map_cr = bind.map_cr
local map_callback = bind.map_callback

local mappings = {
	plugins = {
		-- Проводник: встроенный netrw, всегда от ГЛОБАЛЬНОГО pwd.
		-- getcwd(-1,-1) игнорирует window-local :lcd, которыми netrw
		-- сорит (keepdir), — поэтому мусорных "~" больше нет.
		-- После `cd` в netrw (DirChanged продвигает его в глобальный)
		-- здесь всегда только новый проект.
		["n|<leader>e"] = map_callback(function()
				vim.cmd.edit(vim.fn.fnameescape(vim.fn.getcwd(-1, -1)))
			end)
			:with_noremap()
			:with_silent()
			:with_desc("filebrowser: netrw at pwd"),

		-- Plugin: trouble
		["n|gt"] = map_cr("Trouble diagnostics toggle")
			:with_noremap()
			:with_silent()
			:with_desc("lsp: Toggle trouble list"),
		["n|<leader>lw"] = map_cr("Trouble diagnostics toggle")
			:with_noremap()
			:with_silent()
			:with_desc("lsp: Show workspace diagnostics"),
		["n|<leader>ld"] = map_cr("Trouble diagnostics toggle filter.buf=0")
			:with_noremap()
			:with_silent()
			:with_desc("lsp: Show document diagnostics"),

		-- Plugin: fzf-lua (через _fzf: догружает плагин, если спит)
		["n|<C-p>"] = map_callback(function()
				_fzf("commands")
			end)
			:with_noremap()
			:with_silent()
			:with_desc("tool: Command panel"),
		["n|<leader>fp"] = map_callback(function()
				_fzf("live_grep")
			end)
			:with_noremap()
			:with_silent()
			:with_desc("tool: Live grep (search in project)"),
		["n|<leader>ff"] = map_callback(function()
				_fzf("files")
			end)
			:with_noremap()
			:with_silent()
			:with_desc("tool: Find files"),
		["n|<leader>fb"] = map_callback(function()
				_fzf("buffers")
			end)
			:with_noremap()
			:with_silent()
			:with_desc("tool: Find buffers"),
		["n|<leader>fo"] = map_callback(function()
				_fzf("oldfiles")
			end)
			:with_noremap()
			:with_silent()
			:with_desc("tool: Recent files"),
		["n|<leader>fg"] = map_callback(function()
				_fzf("git_branches")
			end)
			:with_noremap()
			:with_silent()
			:with_desc("tool: Git branches"),
		["n|<leader>fr"] = map_callback(function()
				_fzf("resume")
			end)
			:with_noremap()
			:with_silent()
			:with_desc("tool: Resume last search"),
		["v|<leader>fs"] = map_callback(function()
				_fzf("grep_visual", function()
					return { search = require("fzf-lua.utils").get_visual_selection() }
				end)
			end)
			:with_noremap()
			:with_silent()
			:with_desc("tool: Find visual selection"),
	},
}

bind.nvim_load_mapping(mappings.plugins)
