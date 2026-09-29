local global = require("core.global")

local function load_options()
	local options = {
		autoread = true,
		autowrite = true,
		backspace = "indent,eol,start",
		backup = false,
		backupdir = global.cache_dir .. "/backup//,.",
		backupskip = "/tmp/*,$TMPDIR/*,$TMP/*,$TEMP/*,*/shm/*,/private/var/*,.vault.vim",
		breakat = [[\ \	;:,!?@*-+/]],
		clipboard = "unnamedplus",
		cmdheight = 1, -- 0, 1, 2
		cmdwinheight = 5,
		complete = ".,w,b,k,kspell",
		completeopt = "fuzzy,menuone,noselect,popup",
		cursorcolumn = false,
		cursorline = false,
		diffopt = "filler,iwhite,internal,linematch:60,algorithm:patience",
		directory = global.cache_dir .. "/swap//",
		display = "lastline",
		encoding = "utf-8",
		equalalways = false,
		errorbells = true,
		fileencodings = "ucs-bom,utf-8,default,big5,latin1",
		fileformats = "unix,mac,dos",
		foldlevelstart = 99,
		-- grepformat НЕ задаётся здесь намеренно: он зависит от grepprg, который
		-- выбирается ниже (rg vs платформенный дефолт). Значение ставится
		-- ПОСЛЕ цикла extend_config, иначе цикл перезапишет его этой таблицей.
		-- grepprg НЕ задаётся, если нет rg: платформенный дефолт Neovim
		-- корректен на каждой ОС (grep на *nix, findstr на Windows). Старый
		-- фолбэк "grep -n $* /dev/null" ломал :grep на Windows: /dev/null там
		-- не существует, а шелл — cmd.exe. См. условие ниже, после таблицы.
		helpheight = 12,
		hidden = true,
		history = 2000,
		ignorecase = true,
		inccommand = "nosplit",
		incsearch = true,
		infercase = true,
		jumpoptions = "stack,view",
		laststatus = 3,
		list = true,
		listchars = "tab:»·,nbsp:+,trail:·,extends:→,precedes:←",
		magic = true,
		mousescroll = "ver:3,hor:6",
		previewheight = 12,
		-- Do NOT adjust the following option (pumblend) if you're using transparent background
		pumblend = 0,
		pumheight = 15,
		redrawtime = 1500,
		ruler = true,
		scrolloff = 3,
		sessionoptions = "buffers,curdir,folds,help,tabpages,winpos,winsize",
		shada = "!,'500,<50,@100,s10,h",
		shiftround = true,
		shortmess = "aoOTcF",
		showbreak = "↳  ",
		showcmd = true, -- видеть набранный префикс (leader) в cmdline
		showmode = false,
		showtabline = 2,
		sidescrolloff = 5,
		smartcase = true,
		smarttab = true,
		smoothscroll = true,
		spellfile = global.vim_path .. "/spell/en.utf-8.add",
		splitbelow = true,
		splitkeep = "cursor",
		splitright = true,
		startofline = false,
		swapfile = false,
		switchbuf = "usetab,uselast",
		termguicolors = true,
		timeout = true,
		timeoutlen = 300,
		ttimeout = true,
		ttimeoutlen = 0,
		undodir = global.cache_dir .. "/undo//",
		-- Please do NOT set `updatetime` to above 500, otherwise most plugins may not function correctly
		-- PERF: 200 -> 1000: CursorHold-пачки (gitsigns/flash, git-спавны) в 5 раз реже.
		-- Откат одной строкой, если swap/crash-recovery критичен.
		updatetime = 1000,
		viewoptions = "folds,cursor,curdir,slash,unix",
		virtualedit = "block",
		visualbell = true,
		whichwrap = "h,l,<,>,[,],~",
		wildignore = ".git,.hg,.svn,*.pyc,*.o,*.out,*.jpg,*.jpeg,*.png,*.gif,*.zip,**/tmp/**,*.DS_Store,**/node_modules/**,**/bower_modules/**",
		wildignorecase = true,
		-- Do NOT adjust the following option (winblend) if you're using transparent background
		winblend = 0,
		winminwidth = 10,
		winwidth = 30,
		wrapscan = true,
		writebackup = true,
		-- bw local --
		autoindent = true,
		breakindentopt = "shift:2,min:20",
		concealcursor = "niv",
		conceallevel = 0,
		expandtab = true,
		foldenable = true,
		formatoptions = "1jcroql",
		linebreak = true,
		linespace = 0,
		number = true,
		relativenumber = true,
		shiftwidth = 4,
		signcolumn = "yes",
		softtabstop = 4,
		synmaxcol = 2500,
		tabstop = 4,
		textwidth = 80,
		undofile = true,
		wrap = false,
	}

	local function isempty(s)
		return s == nil or s == ""
	end
	local function use_if_defined(val, fallback)
		return val ~= nil and val or fallback
	end

	-- Custom python provider
	local conda_prefix = vim.env.CONDA_PREFIX
	local is_win = vim.fn.has("win32") == 1
	local python_bin = is_win and "/python.exe" or "/bin/python"
	local python3_bin = is_win and "/python.exe" or "/bin/python"
	if not isempty(conda_prefix) then
		vim.g.python_host_prog = use_if_defined(vim.g.python_host_prog, conda_prefix .. python_bin)
		vim.g.python3_host_prog = use_if_defined(vim.g.python3_host_prog, conda_prefix .. python3_bin)
	else
		vim.g.python_host_prog = use_if_defined(vim.g.python_host_prog, "python")
		vim.g.python3_host_prog = use_if_defined(vim.g.python3_host_prog, is_win and "python" or "python3")
	end

	-- Ставим grepprg только когда rg реально есть. Без rg оставляем
	-- платформенный дефолт Neovim: на *nix это grep, на Windows — findstr.
	-- Это работает и без E149, и на любой ОС.
	local merged = require("modules.utils").extend_config(options, "user.options")
	for name, value in pairs(merged) do
		vim.api.nvim_set_option_value(name, value, {})
	end

	-- ВАЖНО: этот блок идёт ПОСЛЕ цикла выше. grepformat обязан соответствовать
	-- ИТОГОВОМУ grepprg, а цикл extend_config перезаписывает любые значения,
	-- заданные в таблице options. Раньше grepformat ставился ДО цикла, и цикл
	-- молча возвращал "%f:%l:%c:%m" — ветка с %f:%l:%m была мёртвым кодом,
	-- и :grep ломался везде, где нет rg (findstr на Windows, grep -n на *nix).
	local user_overrides_grepformat = merged.grepformat ~= nil
	-- rg --vimgrep печатает file:line:col:match → нужен %c.
	-- Платформенный дефолт без rg (findstr на Windows, grep -n на *nix) печатает
	-- file:line:text, колонки НЕТ → %c разъезжается. Поэтому %f:%l:%m.
	if vim.fn.executable("rg") == 1 then
		vim.api.nvim_set_option_value("grepprg", "rg --hidden --vimgrep --smart-case --", {})
		if not user_overrides_grepformat then
			vim.api.nvim_set_option_value("grepformat", "%f:%l:%c:%m", {})
		end
	elseif not user_overrides_grepformat then
		vim.api.nvim_set_option_value("grepformat", "%f:%l:%m", {})
	end
end

-- Newtrw liststyle: 0 thin, 1 long, 2 wide, 3 tree
-- https://medium.com/usevim/the-netrw-style-options-3ebe91d42456
vim.g.netrw_liststyle = 1

load_options()
