local bind = require("keymap.bind")
local map_cr = bind.map_cr
local map_cu = bind.map_cu
local map_cmd = bind.map_cmd
local map_callback = bind.map_callback
local et = bind.escape_termcode

local mappings = {
	builtins = {
		-- Builtins: Save & Quit
		["n|<C-s>"] = map_cu("write"):with_noremap():with_silent():with_desc("edit: Save file"),
		["n|<C-q>"] = map_cr("wq"):with_desc("edit: Save file and quit"),
		["n|<A-S-q>"] = map_cr("q!"):with_desc("edit: Force quit"),

		-- Builtins: Insert mode
		["i|<C-Enter>"] = map_cmd("<Esc>o"):with_noremap():with_desc("Insert new line below"),
		["i|<C-S-Enter>"] = map_cmd("<Esc>O"):with_noremap():with_desc("Insert new line above"),
		["i|<C-u>"] = map_cmd("<C-G>u<C-U>"):with_noremap():with_desc("edit: Delete previous block"),
		-- NOTE: этот маппинг затирается core.pairs (<C-h> стирает как <BS>,
		-- так было и при autoclose). Уберёшь pairs — оживёт.
		["i|<C-h>"] = map_cmd("<Left>"):with_noremap():with_desc("edit: Move cursor to left"),
		["i|<C-l>"] = map_cmd("<Right>"):with_noremap():with_desc("edit: Move cursor to right"),
		["i|<C-j>"] = map_cmd("<Esc>ji"):with_noremap():with_desc("Move cursor down"),
		["i|<C-k>"] = map_cmd("<Esc>ki"):with_noremap():with_desc("Move cursor up"),
		-- NOTE: i|<C-i> УДАЛЁН: в терминале <C-i> и <Tab> — один кейкод 9
		-- (vim.keycode('<C-i>')==vim.keycode('<Tab>')), маппинг съедал Tab
		-- и убивал cmp select_next. Для начала строки есть <C-a>/<Home>.
		["i|<C-a>"] = map_cmd("<ESC>$a"):with_noremap():with_desc("edit: Move cursor to line end"),
		["i|<C-b>"] = map_cmd("<Esc>bi"):with_noremap():with_desc("Move to beginning of word"),
		["i|<C-e>"] = map_cmd("<Esc>ei"):with_noremap():with_desc("Move to end of word"),
		["i|<C-s>"] = map_cmd("<Esc>:w<CR>"):with_desc("edit: Save file"),
		["i|<C-q>"] = map_cmd("<Esc>:wq<CR>"):with_desc("edit: Save file and quit"),

		-- Builtins: Undo breakpoints (LazyVim) — гранулярный undo по знакам
		["i|,"] = map_cmd(",<C-g>u"):with_noremap():with_desc("edit: Undo breakpoint ,"),
		["i|."] = map_cmd(".<C-g>u"):with_noremap():with_desc("edit: Undo breakpoint ."),
		["i|;"] = map_cmd(";<C-g>u"):with_noremap():with_desc("edit: Undo breakpoint ;"),

		-- Builtins: Command mode
		["c|<C-b>"] = map_cmd("<Left>"):with_noremap():with_desc("edit: Left"),
		["c|<C-f>"] = map_cmd("<Right>"):with_noremap():with_desc("edit: Right"),
		["c|<C-a>"] = map_cmd("<Home>"):with_noremap():with_desc("edit: Home"),
		["c|<C-e>"] = map_cmd("<End>"):with_noremap():with_desc("edit: End"),
		["c|<C-d>"] = map_cmd("<Del>"):with_noremap():with_desc("edit: Delete"),
		["c|<C-h>"] = map_cmd("<BS>"):with_noremap():with_desc("edit: Backspace"),
		["c|<C-t>"] = map_cmd([[<C-R>=expand("%:p:h") . "/" <CR>]])
			:with_noremap()
			:with_desc("edit: Complete path of current file"),

		-- Builtins: Visual mode
		["v|J"] = map_cmd(":m '>+1<CR>gv=gv"):with_desc("edit: Move this line down"),
		["v|K"] = map_cmd(":m '<-2<CR>gv=gv"):with_desc("edit: Move this line up"),
		["v|<"] = map_cmd("<gv"):with_desc("edit: Decrease indent"),
		["v|>"] = map_cmd(">gv"):with_desc("edit: Increase indent"),
		["x|p"] = map_cmd('"_dP'):with_noremap():with_desc("edit: Paste without yanking"),

		-- Builtins: "Suckless" - named after r/suckless
		["n|Y"] = map_cmd("y$"):with_desc("edit: Yank text to EOL"),
		["n|D"] = map_cmd("d$"):with_desc("edit: Delete text to EOL"),
		["n|n"] = map_cmd("nzzzv"):with_noremap():with_desc("edit: Next search result"),
		["n|N"] = map_cmd("Nzzzv"):with_noremap():with_desc("edit: Prev search result"),
		["n|J"] = map_cmd("mzJ`z"):with_noremap():with_desc("edit: Join next line"),
		["n|<C-d>"] = map_cmd("<C-d>zz"):with_noremap():with_desc("edit: Scroll down + center"),
		["n|<C-u>"] = map_cmd("<C-u>zz"):with_noremap():with_desc("edit: Scroll up + center"),
		["n|<S-Tab>"] = map_cr("normal za"):with_noremap():with_silent():with_desc("edit: Toggle code fold"),
		["n|<Esc>"] = map_callback(function()
				_flash_esc_or_noh()
			end)
			:with_noremap()
			:with_silent()
			:with_desc("edit: Clear search highlight"),
		["n|<leader>o"] = map_cr("setlocal spell! spelllang=en_us"):with_desc("edit: Toggle spell check"),
		["n|<leader>x"] = map_callback(function()
				-- chmod есть только на POSIX; на Windows — понятный нотифай вместо E371.
				if vim.fn.has("win32") == 1 or vim.fn.executable("chmod") ~= 1 then
					vim.notify("chmod not available on this system", vim.log.levels.WARN, { title = "edit" })
					return
				end
				vim.cmd("!chmod +x %")
			end)
			:with_noremap()
			:with_silent()
			:with_desc("edit: chmod +x current file"),
		["n|<leader>S"] = map_cmd([[:%s/\<<C-r><C-w>\>/<C-r><C-w>/gI<Left><Left><Left>]])
			:with_noremap()
			:with_desc("edit: Substitute word under cursor"),
	},
	plugins = {
		-- Сессии: встроенные :mksession, файл — в data-dir (не мусорим в репо),
		-- имя — от текущей папки, у каждого проекта своя.
		["n|<leader>ss"] = map_callback(function()
				local dir = vim.fn.stdpath("data") .. "/sessions"
				vim.fn.mkdir(dir, "p")
				local name = dir .. "/" .. vim.fn.getcwd():gsub("[/\\:]", "%%") .. ".vim"
				vim.cmd("mksession! " .. vim.fn.fnameescape(name))
				vim.notify("[session] saved: " .. name, vim.log.levels.INFO)
			end)
			:with_noremap()
			:with_silent()
			:with_desc("session: Save"),
		["n|<leader>sl"] = map_callback(function()
				local dir = vim.fn.stdpath("data") .. "/sessions"
				local name = dir .. "/" .. vim.fn.getcwd():gsub("[/\\:]", "%%") .. ".vim"
				if vim.fn.filereadable(name) == 1 then
					vim.cmd("source " .. vim.fn.fnameescape(name))
				else
					vim.notify("[session] no session for this dir", vim.log.levels.WARN)
				end
			end)
			:with_noremap()
			:with_silent()
			:with_desc("session: Load"),
		-- Plugin: diffview.nvim (diff веток/коммитов/история файла)
		["n|<leader>gd"] = map_cr("DiffviewOpen"):with_silent():with_noremap():with_desc("git: Diff open"),
		["n|<leader>gD"] = map_cr("DiffviewClose"):with_silent():with_noremap():with_desc("git: Diff close"),
		["n|<leader>gh"] = map_cr("DiffviewFileHistory"):with_silent():with_noremap():with_desc("git: File history"),
	},
}

bind.nvim_load_mapping(mappings.builtins)
bind.nvim_load_mapping(mappings.plugins)
