local map = vim.keymap.set

-- insert mode jj/jk → normal mode
map("i", "jj", "<Esc>", { noremap = true, silent = true })
map("i", "jk", "<Esc>", { noremap = true, silent = true })

-- Builtins: Save & Quit
map("n", "<C-s>", ":<C-u>write<CR>", { noremap = true, silent = true, desc = "edit: Save file" })
map("n", "<C-q>", ":wq<CR>", { noremap = false, silent = false, desc = "edit: Save file and quit" })
map("n", "<A-S-q>", ":q!<CR>", { noremap = false, silent = false, desc = "edit: Force quit" })

-- Builtins: Insert mode
map("i", "<C-Enter>", "<Esc>o", { noremap = true, silent = false, desc = "Insert new line below" })
map("i", "<C-S-Enter>", "<Esc>O", { noremap = true, silent = false, desc = "Insert new line above" })
map("i", "<C-u>", "<C-G>u<C-U>", { noremap = true, silent = false, desc = "edit: Delete previous block" })
-- NOTE: этот маппинг затирается core.pairs (<C-h> стирает как <BS>,
-- так было и при autoclose). Уберёшь pairs — оживёт.
map("i", "<C-h>", "<Left>", { noremap = true, silent = false, desc = "edit: Move cursor to left" })
map("i", "<C-l>", "<Right>", { noremap = true, silent = false, desc = "edit: Move cursor to right" })
map("i", "<C-j>", "<Esc>ji", { noremap = true, silent = false, desc = "Move cursor down" })
map("i", "<C-k>", "<Esc>ki", { noremap = true, silent = false, desc = "Move cursor up" })
-- NOTE: i|<C-i> УДАЛЁН: в терминале <C-i> и <Tab> — один кейкод 9
-- (vim.keycode('<C-i>')==vim.keycode('<Tab>')), маппинг съедал Tab
-- и убивал cmp select_next. Для начала строки есть <C-a>/<Home>.
map("i", "<C-a>", "<ESC>$a", { noremap = true, silent = false, desc = "edit: Move cursor to line end" })
map("i", "<C-b>", "<Esc>bi", { noremap = true, silent = false, desc = "Move to beginning of word" })
map("i", "<C-e>", "<Esc>ei", { noremap = true, silent = false, desc = "Move to end of word" })
map("i", "<C-s>", "<Esc>:w<CR>", { noremap = false, silent = false, desc = "edit: Save file" })
map("i", "<C-q>", "<Esc>:wq<CR>", { noremap = false, silent = false, desc = "edit: Save file and quit" })

-- Builtins: Undo breakpoints (LazyVim) — гранулярный undo по знакам
map("i", ",", ",<C-g>u", { noremap = true, silent = false, desc = "edit: Undo breakpoint ," })
map("i", ".", ".<C-g>u", { noremap = true, silent = false, desc = "edit: Undo breakpoint ." })
map("i", ";", ";<C-g>u", { noremap = true, silent = false, desc = "edit: Undo breakpoint ;" })

-- Builtins: Command mode
map("c", "<C-b>", "<Left>", { noremap = true, silent = false, desc = "edit: Left" })
map("c", "<C-f>", "<Right>", { noremap = true, silent = false, desc = "edit: Right" })
map("c", "<C-a>", "<Home>", { noremap = true, silent = false, desc = "edit: Home" })
map("c", "<C-e>", "<End>", { noremap = true, silent = false, desc = "edit: End" })
map("c", "<C-d>", "<Del>", { noremap = true, silent = false, desc = "edit: Delete" })
map("c", "<C-h>", "<BS>", { noremap = true, silent = false, desc = "edit: Backspace" })
map(
	"c",
	"<C-t>",
	[[<C-R>=expand("%:p:h") . "/" <CR>]],
	{ noremap = true, silent = false, desc = "edit: Complete path of current file" }
)

-- Builtins: Visual mode
map("v", "J", ":m '>+1<CR>gv=gv", { noremap = false, silent = false, desc = "edit: Move this line down" })
map("v", "K", ":m '<-2<CR>gv=gv", { noremap = false, silent = false, desc = "edit: Move this line up" })
map("v", "<", "<gv", { noremap = false, silent = false, desc = "edit: Decrease indent" })
map("v", ">", ">gv", { noremap = false, silent = false, desc = "edit: Increase indent" })
map("x", "p", '"_dP', { noremap = true, silent = false, desc = "edit: Paste without yanking" })

-- Builtins: "Suckless" - named after r/suckless
map("n", "Y", "y$", { noremap = false, silent = false, desc = "edit: Yank text to EOL" })
map("n", "D", "d$", { noremap = false, silent = false, desc = "edit: Delete text to EOL" })
map("n", "n", "nzzzv", { noremap = true, silent = false, desc = "edit: Next search result" })
map("n", "N", "Nzzzv", { noremap = true, silent = false, desc = "edit: Prev search result" })
map("n", "J", "mzJ`z", { noremap = true, silent = false, desc = "edit: Join next line" })
map("n", "<C-d>", "<C-d>zz", { noremap = true, silent = false, desc = "edit: Scroll down + center" })
map("n", "<C-u>", "<C-u>zz", { noremap = true, silent = false, desc = "edit: Scroll up + center" })
map("n", "<S-Tab>", ":normal za<CR>", { noremap = true, silent = true, desc = "edit: Toggle code fold" })
map("n", "<Esc>", function()
	_flash_esc_or_noh()
end, { noremap = true, silent = true, desc = "edit: Clear search highlight" })
map("n", "<leader>o", ":setlocal spell! spelllang=en_us<CR>", { noremap = false, silent = false, desc = "edit: Toggle spell check" })
map("n", "<leader>x", function()
	-- chmod есть только на POSIX; на Windows — понятный нотифай вместо E371.
	if vim.fn.has("win32") == 1 or vim.fn.executable("chmod") ~= 1 then
		vim.notify("chmod not available on this system", vim.log.levels.WARN, { title = "edit" })
		return
	end
	vim.cmd("!chmod +x %")
end, { noremap = true, silent = true, desc = "edit: chmod +x current file" })
map(
	"n",
	"<leader>S",
	[[:%s/\<<C-r><C-w>\>/<C-r><C-w>/gI<Left><Left><Left>]],
	{ noremap = true, silent = false, desc = "edit: Substitute word under cursor" }
)

-- Сессии: встроенные :mksession, файл — в data-dir (не мусорим в репо),
-- имя — от текущей папки, у каждого проекта своя.
map("n", "<leader>ss", function()
	local dir = vim.fn.stdpath("data") .. "/sessions"
	vim.fn.mkdir(dir, "p")
	local name = dir .. "/" .. vim.fn.getcwd():gsub("[/\\:]", "%%") .. ".vim"
	vim.cmd("mksession! " .. vim.fn.fnameescape(name))
	vim.notify("[session] saved: " .. name, vim.log.levels.INFO)
end, { noremap = true, silent = true, desc = "session: Save" })
map("n", "<leader>sl", function()
	local dir = vim.fn.stdpath("data") .. "/sessions"
	local name = dir .. "/" .. vim.fn.getcwd():gsub("[/\\:]", "%%") .. ".vim"
	if vim.fn.filereadable(name) == 1 then
		vim.cmd("source " .. vim.fn.fnameescape(name))
	else
		vim.notify("[session] no session for this dir", vim.log.levels.WARN)
	end
end, { noremap = true, silent = true, desc = "session: Load" })
-- Plugin: diffview.nvim (diff веток/коммитов/история файла)
map("n", "<leader>gd", ":DiffviewOpen<CR>", { noremap = true, silent = true, desc = "git: Diff open" })
map("n", "<leader>gD", ":DiffviewClose<CR>", { noremap = true, silent = true, desc = "git: Diff close" })
map("n", "<leader>gh", ":DiffviewFileHistory<CR>", { noremap = true, silent = true, desc = "git: File history" })
