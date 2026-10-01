local settings = require("core.settings")
local global = require("core.global")
-- Create cache dir and data dirs
local createdir = function()
	local data_dirs = {
		global.cache_dir .. "/backup",
		global.cache_dir .. "/swap",
		global.cache_dir .. "/tags",
		global.cache_dir .. "/undo",
	}
	-- Подкаталоги проверяем ВСЕГДА, а не только когда нет самого cache_dir:
	-- иначе (типично на Windows, где кэш уже есть) undofile/backup молча
	-- остаются без каталога. Четыре isdirectory на boot — бесплатно.
	if vim.fn.isdirectory(global.cache_dir) == 0 then
		---@diagnostic disable-next-line: param-type-mismatch
		vim.fn.mkdir(global.cache_dir, "p")
	end
	for _, dir in pairs(data_dirs) do
		if vim.fn.isdirectory(dir) == 0 then
			vim.fn.mkdir(dir, "p")
		end
	end
end

local leader_map = function()
	vim.g.mapleader = " "
end

local gui_config = function()
	if next(settings.gui_config) then
		vim.api.nvim_set_option_value(
			"guifont",
			settings.gui_config.font_name .. ":h" .. settings.gui_config.font_size,
			{}
		)
	end
end

local neovide_config = function()
	for name, config in pairs(settings.neovide_config) do
		vim.g["neovide_" .. name] = config
	end
end

local clipboard_config = function()
	if global.is_mac then
		if vim.fn.executable("pbcopy") == 1 and vim.fn.executable("pbpaste") == 1 then
			vim.g.clipboard = {
				name = "macOS-clipboard",
				copy = { ["+"] = "pbcopy", ["*"] = "pbcopy" },
				paste = { ["+"] = "pbpaste", ["*"] = "pbpaste" },
				cache_enabled = 1,
			}
		end
	elseif global.is_wsl then
		if vim.fn.executable("win32yank.exe") == 1 then
			vim.g.clipboard = {
				name = "win32yank-wsl",
				copy = {
					["+"] = "win32yank.exe -i --crlf",
					["*"] = "win32yank.exe -i --crlf",
				},
				paste = {
					["+"] = "win32yank.exe -o --lf",
					["*"] = "win32yank.exe -o --lf",
				},
				cache_enabled = 1,
			}
		end
	elseif global.is_windows then
		-- Native Windows: win32yank or built-in clipboard
		if vim.fn.executable("win32yank.exe") == 1 then
			vim.g.clipboard = {
				name = "win32yank",
				copy = {
					["+"] = "win32yank.exe -i --crlf",
					["*"] = "win32yank.exe -i --crlf",
				},
				paste = {
					["+"] = "win32yank.exe -o --lf",
					["*"] = "win32yank.exe -o --lf",
				},
				cache_enabled = 1,
			}
		end
		-- else: let Neovim use built-in Win32 clipboard
	elseif global.is_linux then
		-- Plain Linux: prefer wl-copy, fall back to xclip/xsel, else builtin.
		if vim.fn.executable("wl-copy") == 1 and vim.fn.executable("wl-paste") == 1 then
			vim.g.clipboard = {
				name = "wayland-clipboard",
				copy = { ["+"] = "wl-copy", ["*"] = "wl-copy" },
				paste = { ["+"] = "wl-paste --no-newline", ["*"] = "wl-paste --no-newline" },
				cache_enabled = 1,
			}
		elseif vim.fn.executable("xclip") == 1 then
			vim.g.clipboard = {
				name = "xclip-clipboard",
				copy = { ["+"] = "xclip -selection clipboard", ["*"] = "xclip -selection primary" },
				paste = { ["+"] = "xclip -selection clipboard -o", ["*"] = "xclip -selection primary -o" },
				cache_enabled = 1,
			}
		elseif vim.fn.executable("xsel") == 1 then
			vim.g.clipboard = {
				name = "xsel-clipboard",
				copy = { ["+"] = "xsel --clipboard --input", ["*"] = "xsel --primary --input" },
				paste = { ["+"] = "xsel --clipboard --output", ["*"] = "xsel --primary --output" },
				cache_enabled = 1,
			}
		end
		-- else: builtin (may be dead without provider — :checkhealth will tell).
	end
end

local shell_config = function()
	if global.is_windows then
		if not (vim.fn.executable("pwsh") == 1 or vim.fn.executable("powershell") == 1) then
			vim.notify(
				[[
Failed to setup terminal config

PowerShell is either not installed, missing from PATH, or not executable;
cmd.exe will be used instead for `:!` (shell bang) and toggleterm.nvim.

You're recommended to install PowerShell for better experience.]],
				vim.log.levels.WARN,
				{ title = "[core] Runtime Warning" }
			)
			return
		end

		-- -NoProfile: иначе каждый :!/:grep/:make тащит полный профиль
		-- пользователя (oh-my-posh и т.п.), а болтливый профиль ломает
		-- перенаправленный вывод. -NonInteractive: без промптов в :!.
		local basecmd = "-NoLogo -MTA -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned"
		local ctrlcmd = "-Command [console]::InputEncoding = [console]::OutputEncoding = [System.Text.Encoding]::UTF8"
		local set_opts = vim.api.nvim_set_option_value
		set_opts("shell", vim.fn.executable("pwsh") == 1 and "pwsh" or "powershell", {})
		set_opts("shellcmdflag", string.format("%s %s;", basecmd, ctrlcmd), {})
		-- %s в кавычках: %TEMP% вида C:\Users\First Last\... с пробелами
		-- иначе разваливает редирект.
		set_opts("shellredir", '-RedirectStandardOutput "%s" -NoNewWindow -Wait', {})
		set_opts("shellpipe", '2>&1 | Out-File -Encoding UTF8 "%s"; exit $LastExitCode', {})
		set_opts("shellquote", "", {})
		set_opts("shellxquote", "", {})
		-- Прямые слэши в путях для внешних команд: telescope/plenary/netrw-gx
		-- и половина плагинов ждут forward slashes даже на Windows.
		set_opts("shellslash", true, {})
	end
end

-- Синхронизация git/lazygit цветов diff вынесена в lua/core/git_colors.lua
-- (опциональная фича, opt-in; по умолчанию выключена и на старт не влияет).
-- Чтобы выпилить фичу: удалить этот модуль + вызов в load_core ниже.

local load_core = function()
	createdir()
	leader_map()

	gui_config()
	neovide_config()
	clipboard_config()
	shell_config()
	-- Опциональная фича (sync_git_colors, по умолчанию false). Проверка флага
	-- ЗДЕСЬ: при выключенной фиче модуль вообще не грузится и старт за него
	-- не платит. Точка удаления фичи — эти 4 строки + lua/core/git_colors.lua.
	if settings.sync_git_colors then
		require("core.git_colors").schedule()
	end

	require("core.options")
	require("core.event")
	require("core.distro").setup()
	require("keymap")
	-- pairs СТРОГО после keymap: <C-h> и <BS> делят поведение стирания,
	-- наш хендлер должен побеждать `i|<C-h> -> <Left>` из keymap/editor.lua.
	-- Так же было со старым autoclose: он грузился по InsertEnter, т.е. позже всех.
	-- PERF_DEFER (D): pairs + format_on_save не нужны до первого Insert/Write —
	-- откладываем на schedule. vim.schedule отрабатывает раньше первого ввода,
	-- поэтому немедленный :w после open работает. Headless — синхронно
	-- (:Format команда должна существовать для скриптов). Без флага — как было.
	local ok_perf, perf_mod = pcall(require, "core.perf")
	local defer_on = ok_perf and perf_mod.defer_on and perf_mod.defer_on() or false
	if defer_on then
		vim.schedule(function()
			require("core.pairs").setup()
		end)
		vim.schedule(function()
			require("modules.configs.completion.formatting").configure_format_on_save()
		end)
	else
		require("core.pairs").setup()
		require("modules.configs.completion.formatting").configure_format_on_save()
	end
	require("modules.configs.ui.theme")()
	-- khold — dark-only: background=light сносит colors_name в nil.
	if settings.background == "light" and settings.colorscheme == "khold" then
		vim.notify("[core] khold has no light variant — forcing dark", vim.log.levels.WARN)
		vim.api.nvim_set_option_value("background", "dark", {})
	else
		vim.api.nvim_set_option_value("background", settings.background, {})
	end
	-- На тупых терминалах 24-битный цвет ломает вывод. Гард обязан отрабатывать
	-- ПОСЛЕ темы: black-metal включает termguicolors=true безусловно и затирал
	-- ранний гард (уже чинили один раз). Логика живёт в core.term_guard, потому
	-- что load() вызывается дважды — на базовой и на кастомной теме — и при
	-- отложенном применении (settings.defer_theme) событие ColorScheme уже не
	-- помогает: кастомный проход приезжает позже. Поэтому ниже гард зовётся ещё
	-- и явно из themes/black-metal-khold.lua после каждого load().
	require("core.term_guard").enforce()
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("TermGuicolorsGuard", { clear = true }),
		desc = "core: re-apply termguicolors guard on manual :colorscheme",
		callback = function()
			require("core.term_guard").enforce()
		end,
	})

	vim.api.nvim_create_user_command("ConfigHealth", function()
		vim.cmd("checkhealth core")
	end, { desc = "config: environment preflight (binaries, LSP, theme, keys)" })
	vim.api.nvim_create_user_command("Tutor", function()
		vim.cmd("edit " .. vim.fn.stdpath("config") .. "/tutor/intro.tutor")
	end, { desc = "config: interactive hotkey tour (russian)" })
	require("core.perf").setup()
	-- Стартер-хинт: голый `nvim` без аргументов и без парсеров встречает
	-- пустым буфером. Одна подсказка вместо мёртвой тишины; после установки
	-- парсеров условие гаснет само, сентинел-файл не нужен.
	vim.api.nvim_create_autocmd("VimEnter", {
		group = vim.api.nvim_create_augroup("StarterHint", { clear = true }),
		once = true,
		desc = "core: first-run hint on empty startup",
		callback = function()
			if vim.fn.argc() ~= 0 then
				return
			end
			local buf = vim.api.nvim_get_current_buf()
			if vim.api.nvim_buf_get_name(buf) ~= "" then
				return
			end
			if vim.api.nvim_buf_line_count(buf) ~= 1 then
				return
			end
			if vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] ~= "" then
				return
			end
			local ok_ts, ts = pcall(require, "distro.treesitter")
			if not ok_ts or #ts.missing_langs() == 0 then
				return
			end
			-- Отказался один раз — не нагибаем (та же политика, что в bootstrap).
			if vim.uv.fs_stat(ts.decline_marker()) then
				return
			end
			vim.notify(
				"First run: syntax-highlight parsers are missing.\n"
					.. "1) :ConfigHealth — environment check\n"
					.. "2) :DistroParsers --all — highlighting (needs a C compiler)\n"
					.. "3) :DistroSetup — install plugins and tools (one confirm)\n"
					.. "4) :Tutor — 15-minute hotkey tour",
				vim.log.levels.INFO,
				{ title = "[setup]" }
			)
		end,
	})
end

-- netrw НЕ отключаем: встроенный проводник доступен через :Ex / :Vex.
load_core()
