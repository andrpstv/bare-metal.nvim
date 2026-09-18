local bind = require("keymap.bind")
local map_cr = bind.map_cr
local map_callback = bind.map_callback

local mappings = {
	plugins = {
		-- Проводник: встроенный netrw от папки ТЕКУЩЕГО файла
		-- (курсор встаёт на файл — удобно создавать соседей через `%`).
		-- Тоггл: из netrw возвращает ровно в тот файл, откуда открыли
		-- (буфер запоминаем явно — alternate `#` слишком хрупкий).
		-- К корню проекта (глобальный pwd) — на <leader>E.
		["n|<leader>e"] = map_callback(function()
				if vim.bo.filetype == "netrw" then
					local back = vim.w.netrw_toggle_from
					if back and vim.api.nvim_buf_is_valid(back) then
						vim.cmd.buffer(back)
					elseif not pcall(vim.cmd, "b#") then
						vim.cmd("enew")
					end
				else
					vim.w.netrw_toggle_from = vim.api.nvim_get_current_buf()
					local dir = vim.fn.expand("%:p:h")
					if dir == "" then
						dir = vim.fn.getcwd(-1, -1)
					end
					local tail = vim.fn.expand("%:t")
					vim.cmd.edit(vim.fn.fnameescape(dir))
					if tail ~= "" then
						-- Откладываем: netrw сам позиционирует курсор после
						-- отрисовки (особенно в tree-виде), наш поиск должен
						-- идти строго после него. Регистр `/` не трогаем.
						local pat = tail:gsub("([^%w])", "%%%1") .. "$"
						vim.schedule(function()
							if vim.bo.filetype ~= "netrw" then
								return
							end
							local keep = vim.fn.getreg("/")
							pcall(vim.fn.search, pat, "w")
							vim.fn.setreg("/", keep)
						end)
					end
				end
			end)
			:with_noremap()
			:with_silent()
			:with_desc("filebrowser: netrw toggle at file"),
		-- К корню проекта: netrw от глобального pwd.
		-- getcwd(-1,-1) игнорирует window-local :lcd, которыми netrw сорит.
		["n|<leader>E"] = map_callback(function()
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
		["n|<leader>f/"] = map_callback(function()
				_fzf("blines")
			end)
			:with_noremap()
			:with_silent()
			:with_desc("tool: Fuzzy current buffer"),
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
