local map = vim.keymap.set

-- Проводник: встроенный netrw от папки ТЕКУЩЕГО файла
-- (курсор встаёт на файл — удобно создавать соседей через `%`).
-- Тоггл: из netrw возвращает ровно в тот файл, откуда открыли
-- (буфер запоминаем явно — alternate `#` слишком хрупкий).
-- К корню проекта (глобальный pwd) — на <leader>E.
map("n", "<leader>e", function()
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
end, { noremap = true, silent = true, desc = "filebrowser: netrw toggle at file" })
-- К корню проекта: netrw от глобального pwd.
-- getcwd(-1,-1) игнорирует window-local :lcd, которыми netrw сорит.
map("n", "<leader>E", function()
	vim.cmd.edit(vim.fn.fnameescape(vim.fn.getcwd(-1, -1)))
end, { noremap = true, silent = true, desc = "filebrowser: netrw at pwd" })

-- Plugin: trouble
map("n", "gt", ":Trouble diagnostics toggle<CR>", { noremap = true, silent = true, desc = "lsp: Toggle trouble list" })
map(
	"n",
	"<leader>lw",
	":Trouble diagnostics toggle<CR>",
	{ noremap = true, silent = true, desc = "lsp: Show workspace diagnostics" }
)
map(
	"n",
	"<leader>ld",
	":Trouble diagnostics toggle filter.buf=0<CR>",
	{ noremap = true, silent = true, desc = "lsp: Show document diagnostics" }
)

-- Plugin: telescope (plenary вендорен, rg ускоряет grep/files)
map("n", "<C-p>", function()
	_pick_extra("commands")
end, { noremap = true, silent = true, desc = "tool: Command panel" })
map("n", "<leader>fp", function()
	_pick("grep_live")
end, { noremap = true, silent = true, desc = "tool: Live grep (search in project)" })
map("n", "<leader>ff", function()
	_pick("files")
end, { noremap = true, silent = true, desc = "tool: Find files" })
map("n", "<leader>fb", function()
	_pick("buffers")
end, { noremap = true, silent = true, desc = "tool: Find buffers" })
map("n", "<leader>f/", function()
	_pick_extra("buf_lines", { scope = "current" })
end, { noremap = true, silent = true, desc = "tool: Fuzzy current buffer" })
map("n", "<leader>fo", function()
	_pick_extra("oldfiles")
end, { noremap = true, silent = true, desc = "tool: Recent files" })
map("n", "<leader>fh", function()
	_pick("help")
end, { noremap = true, silent = true, desc = "tool: Help tags" })
map("n", "<leader>fg", function()
	_pick_extra("git_branches")
end, { noremap = true, silent = true, desc = "tool: Git branches" })
map("n", "<leader>fw", function()
	_pick_lsp("workspace_symbol_live")
end, { noremap = true, silent = true, desc = "tool: Workspace symbols (types/funcs repo-wide)" })
map("n", "<leader>fr", function()
	_pick("resume")
end, { noremap = true, silent = true, desc = "tool: Resume last search" })
map("v", "<leader>fs", function()
	_pick_grep_visual()
end, { noremap = true, silent = true, desc = "tool: Find visual selection" })
