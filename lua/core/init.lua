local settings = require("core.settings")
local global = require("core.global")
-- Create cache dir and data dirs
local createdir = function()
	local data_dirs = {
		global.cache_dir .. "/backup",
		global.cache_dir .. "/session",
		global.cache_dir .. "/swap",
		global.cache_dir .. "/tags",
		global.cache_dir .. "/undo",
	}
	-- Only check whether cache_dir exists, this would be enough.
	if vim.fn.isdirectory(global.cache_dir) == 0 then
		---@diagnostic disable-next-line: param-type-mismatch
		vim.fn.mkdir(global.cache_dir, "p")
		for _, dir in pairs(data_dirs) do
			if vim.fn.isdirectory(dir) == 0 then
				vim.fn.mkdir(dir, "p")
			end
		end
	end
end

local leader_map = function()
	vim.g.mapleader = " "
	-- NOTE:
	--  > Uncomment the following if you're using a <leader> other than <Space>, and you wish
	--  > to disable advancing one character by pressing <Space> in normal/visual mode.
	-- vim.api.nvim_set_keymap("n", " ", "", { noremap = true })
	-- vim.api.nvim_set_keymap("x", " ", "", { noremap = true })
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

		local basecmd = "-NoLogo -MTA -ExecutionPolicy RemoteSigned"
		local ctrlcmd = "-Command [console]::InputEncoding = [console]::OutputEncoding = [System.Text.Encoding]::UTF8"
		local set_opts = vim.api.nvim_set_option_value
		set_opts("shell", vim.fn.executable("pwsh") == 1 and "pwsh" or "powershell", {})
		set_opts("shellcmdflag", string.format("%s %s;", basecmd, ctrlcmd), {})
		set_opts("shellredir", "-RedirectStandardOutput %s -NoNewWindow -Wait", {})
		set_opts("shellpipe", "2>&1 | Out-File -Encoding UTF8 %s; exit $LastExitCode", {})
		set_opts("shellquote", "", {})
		set_opts("shellxquote", "", {})
	end
end

local git_sync_colors = function()
	if not settings.sync_git_colors then
		return
	end
	if vim.fn.executable("git") ~= 1 then
		return
	end

	local green = settings.palette_overwrite.green or "#5f8787"
	local red = settings.palette_overwrite.red or "#974b46"
	local is_windows = vim.fn.has("win32") == 1

	-- git config path
	local gitconfig
	if is_windows then
		gitconfig = vim.fn.expand("$USERPROFILE") .. "/.gitconfig"
	else
		gitconfig = vim.fn.expand("~/.gitconfig")
	end

	local content = ""
	if vim.fn.filereadable(gitconfig) == 1 then
		content = vim.fn.readfile(gitconfig, "\n")
		if type(content) == "table" then
			content = table.concat(content, "\n")
		end
	end

	if not content:match("%[color \"diff\"%]") then
		local snippet = string.format(
			'\n[color "diff"]\n\told = %s\n\tnew = %s\n\tfuncold = %s\n\tfuncnew = %s',
			red, green, red, green
		)
		local f = io.open(gitconfig, "a")
		if f then
			f:write(snippet)
			f:close()
		end
	end

	-- lazygit config path
	local lg_dir
	if is_windows then
		lg_dir = vim.fn.expand("$APPDATA") .. "/lazygit"
	else
		lg_dir = vim.fn.expand("~/.config/lazygit")
	end

	if vim.fn.isdirectory(lg_dir) == 0 then
		vim.fn.mkdir(lg_dir, "p")
	end
	local lg_config = lg_dir .. "/config.yml"
	if vim.fn.filereadable(lg_config) == 0 then
		local yaml = string.format(
			[[os:
  editPreset: "nvim-remote"
gui:
  theme:
    activeBorderColor:
      - "%s"
      - "bold"
    inactiveBorderColor:
      - "#589ed7"
    selectedLineBgColor:
      - "#2d3f76"
    unstagedChangesColor:
      - "%s"
  nerdFontsVersion: "3"
git:
  diff:
    colorAdded: "%s"
    colorModified: "#888888"
    colorRemoved: "%s"
]],
			green, red, green, red
		)
		local f = io.open(lg_config, "w")
		if f then
			f:write(yaml)
			f:close()
		end
	end
end

local load_core = function()
	createdir()
	leader_map()

	gui_config()
	neovide_config()
	clipboard_config()
	shell_config()
	git_sync_colors()

	require("core.options")
	require("core.event")
	require("core.pack")
	require("keymap")
	-- pairs СТРОГО после keymap: <C-h> и <BS> делят поведение стирания,
	-- наш хендлер должен побеждать `i|<C-h> -> <Left>` из keymap/editor.lua.
	-- Так же было со старым autoclose: он грузился по InsertEnter, т.е. позже всех.
	require("core.pairs").setup()
	require("modules.configs.completion.formatting").configure_format_on_save()
	require("modules.configs.ui.theme")()
	-- khold — dark-only: background=light сносит colors_name в nil.
	if settings.background == "light" and settings.colorscheme == "khold" then
		vim.notify("[core] khold has no light variant — forcing dark", vim.log.levels.WARN)
		vim.api.nvim_set_option_value("background", "dark", {})
	else
		vim.api.nvim_set_option_value("background", settings.background, {})
	end
	-- На тупых терминалах 24-битный цвет ломает вывод — откатываемся ПОСЛЕ темы:
	-- тема (black-metal) включает termguicolors=true безусловно и затирала ранний гард.
	-- Плюс screen/tmux без truecolor.
	local term = vim.env.TERM or ""
	if term == "dumb" or (vim.env.NO_COLOR or "") ~= "" or term:match("^screen") then
		vim.api.nvim_set_option_value("termguicolors", false, {})
	end

	vim.api.nvim_create_user_command("ConfigHealth", function()
		vim.cmd("checkhealth core")
	end, { desc = "config: environment preflight (binaries, LSP, theme, keys)" })
end

-- netrw НЕ отключаем: встроенный проводник доступен через :Ex / :Vex.
load_core()
