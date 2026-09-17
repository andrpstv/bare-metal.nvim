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
		vim.g.clipboard = {
			name = "macOS-clipboard",
			copy = { ["+"] = "pbcopy", ["*"] = "pbcopy" },
			paste = { ["+"] = "pbpaste", ["*"] = "pbpaste" },
			cache_enabled = 0,
		}
	elseif global.is_wsl then
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
			cache_enabled = 0,
		}
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
				cache_enabled = 0,
			}
		end
		-- else: let Neovim use built-in Win32 clipboard
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
	require("modules.configs.completion.formatting").configure_format_on_save()
	require("modules.configs.ui.theme")()
	vim.api.nvim_set_option_value("background", settings.background, {})
end

-- netrw НЕ отключаем: встроенный проводник доступен через :Ex / :Vex.
load_core()
