local settings = {}

-- Set to false if you want to use HTTPS to update plugins and Treesitter parsers.
-- false здесь осознанно: существующие плагины склонированы по HTTPS,
-- по SSH (true) установка новых падает с Permission denied.
---@type boolean
settings["use_ssh"] = false

-- Set to false if you don't use Copilot.
---@type boolean
settings["use_copilot"] = false

-- Set to false if you don't want to format on save.
---@type boolean
settings["format_on_save"] = true

-- Format timeout in milliseconds.
---@type number
settings["format_timeout"] = 1000

-- Set to false to disable format notification.
---@type boolean
settings["format_notify"] = false

-- Set to true if you want to format ONLY the *changed lines* as defined by your version control system.
-- NOTE: This will only be respected if:
--  > The buffer is under version control (Git or Mercurial);
--  > Any server attached to the buffer supports the |DocumentRangeFormattingProvider| capability.
-- Otherwise, Neovim will fall back to formatting the whole buffer and issue a warning.
---@type boolean
settings["format_modifications_only"] = false

-- Filetypes in this list will skip LSP formatting if the value is true.
---@type table<string, boolean>
settings["formatter_block_list"] = {
	-- Example
	lua = false,
}

-- Servers in this list will skip formatting capabilities if the value is true.
---@type table<string, boolean>
settings["server_formatting_block_list"] = {
	clangd = true,
	lua_ls = true,
	ts_ls = true,
	["null-ls"] = true,
}

-- Directories where formatting on save is disabled.
-- NOTE: Strings may contain regular expressions (vim regex). |regexp|
-- NOTE: Directories are automatically normalized using |vim.fs.normalize()|.
---@type string[]
settings["format_disabled_dirs"] = {
	-- Example
	"~/format_disabled_dir",
}

-- Set to false to disable virtual lines for diagnostics.
-- You can still view diagnostics using trouble.nvim (`<leader>ld`).
---@type boolean
settings["diagnostics_virtual_lines"] = true

-- Set the minimum severity level of diagnostics to display.
-- Priority: `Error` > `Warning` > `Information` > `Hint`.
-- For example, if set to `Warning`, only warnings and errors will be shown.
-- NOTE: This only works when `diagnostics_virtual_lines` is true.
---@type "ERROR"|"WARN"|"INFO"|"HINT"
settings["diagnostics_level"] = "HINT"

-- List plugins to disable here (e.g., "Some-User/A-Repo").
---@type string[]
settings["disabled_plugins"] = {} 

-- Set to false if you don't use Neovim to open large files.
---@type boolean
settings["load_big_files_faster"] = true

-- Set to false to stop touching external git/lazygit configs.
-- When true, missing diff-color sections are appended to
-- ~/.gitconfig and a default lazygit theme is created on first start.
-- Default false: no side effects on foreign machines (opt-in).
---@type boolean
settings["sync_git_colors"] = false

-- Customize the global color palette here.
-- These settings will override the defaults during initialization.
-- Parameters will auto-complete as you type.
-- Example: { sky = "#04A5E5" }
---@type palette[]
settings["palette_overwrite"] = {
	green = "#5f8787",      -- additions (teal, like DapStopped)
	red = "#974b46",        -- deletions (keyword red)
	yellow = "#888888",     -- modifications (type gray)
}

-- Set the colorscheme here (black-metal khold, см. lua/themes/black-metal-khold.lua).
---@type string
settings["colorscheme"] = "khold"

-- Set to true if your terminal supports a transparent background.
---@type boolean
settings["transparent_background"] = false

-- Set the background mode here.
-- Useful for themes with both light and dark variants.
-- Valid values: `dark`, `light`.
---@type "dark"|"light"
settings["background"] = "dark"

-- Set the command for opening external URLs.
-- This is ignored on Windows and macOS, which use built-in handlers.
---@type string
settings["external_browser"] = "chrome-cli open"

-- Set the search backend here (единственный пикер — mini.pick, без внешних зависимостей).
---@type "pick"
settings["search_backend"] = "pick"

-- Set to false to disable LSP inlay hints.
---@type boolean
settings["lsp_inlayhints"] = true

-- Signature help window, codelens setup, treesitter indent.
-- NVIM_MINIMAL=1 forces all three off (see bottom overrides).
---@type boolean
settings["signature_enabled"] = true
---@type boolean
settings["codelens_enabled"] = true
---@type boolean
settings["treesitter_indent"] = true

-- LSPs to enable. Бинарники ставятся системно (go install / brew), без mason.
-- Full list: https://github.com/neovim/nvim-lspconfig/tree/master/lua/lspconfig/configs
---@type string[]
settings["lsp_deps"] = {
	"bashls",
	"lua_ls",
	"gopls",
}

-- gopls: debounce text changes (ms). 150 default; 250+ on weak PCs / huge repos.
---@type number
settings["gopls_debounce"] = 150

-- gopls: fieldalignment analysis (memory-layout holes). Expensive on weak PCs.
---@type boolean
settings["gopls_fieldalignment"] = true

-- gopls: codelens set. Disable unused ones on weak PCs (faster initialize,
-- fewer background requests). Keys: generate, gc_details, test, tidy, vendor,
-- regenerate_cgo, upgrade_dependency, organizeImports.
---@type table<string, boolean>
settings["gopls_codelenses"] = {
	generate = true,
	gc_details = true,
	test = true,
	tidy = true,
	vendor = true,
	regenerate_cgo = true,
	upgrade_dependency = true,
	organizeImports = true,
}

-- gopls: semantic tokens (overlaps treesitter highlight) and unimported
-- completion. Disabling either lightens gopls on weak PCs.
---@type boolean
settings["gopls_semantic_tokens"] = true
---@type boolean
settings["gopls_complete_unimported"] = true

-- Minimal mode (NVIM_MINIMAL=1 env): pager-like nvim. Disables inlay hints,
-- codelens setup, signature window and treesitter indent. Highlight stays.
-- Applied as overrides below (after user.settings merge).

-- Treesitter tiers (perf): full below full_lines, highlight-only below
-- lite_lines (vim indent, manual folds), off above. Override per buffer
-- with :TreesitterTier (cycles full/lite/off). See 09-async-startup.md B1.
---@type number
settings["treesitter_full_lines"] = 2000
---@type number
settings["treesitter_lite_lines"] = 10000

-- Treesitter parsers to install during bootstrap.
-- Full list: https://github.com/nvim-treesitter/nvim-treesitter#supported-languages
---@type string[]
settings["treesitter_deps"] = {
	"bash",
	"c",
	"cpp",
	"css",
	"go",
	"gomod",
	"html",
	"javascript",
	"json",
	"jsonc",
	"latex",
	"lua",
	"make",
	"markdown",
	"markdown_inline",
	"rust",
	"typescript",
	"vimdoc",
	"vue",
	"yaml",
}

-- GUI settings for clients like `neovide` or `neovim-qt`.
-- NOTE: Only the following GUI options are supported; others will be ignored.
---@type { font_name: string, font_size: number }
settings["gui_config"] = {
	font_name = "JetBrainsMono Nerd Font",
	font_size = 12,
}

-- Specific settings for `neovide`.
-- Remove the `neovide_` prefix (with trailing underscore) from all entries below.
-- Supported entries: https://neovide.dev/configuration.html
---@type table<string, boolean|number|string>
settings["neovide_config"] = {
	no_idle = false,
	input_ime = true,
	fullscreen = true,
	padding_left = 8,
	confirm_quit = true,
	cursor_vfx_mode = "torpedo",
	cursor_trail_size = 0.05,
	cursor_antialiasing = true,
	hide_mouse_when_typing = true,
	input_macos_alt_is_meta = false,
	cursor_animation_length = 0.03,
	cursor_vfx_particle_speed = 20.0,
	cursor_vfx_particle_density = 5.0,
}

-- Set the dashboard startup image here.
-- Generate ASCII art with: https://github.com/TheZoraiz/ascii-image-converter
-- More info: https://github.com/ayamir/nvimdots/wiki/Issues#change-dashboard-startup-image
---@type string[]
settings["dashboard_image"] = {
	[[⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿]],
	[[⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠋⣠⣶⣾⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿]],
	[[⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣡⣾⣿⣿⣿⣿⣿⢿⣿⣿⣿⣿⣿⣿⣟⠻⣿⣿⣿⣿⣿⣿⣿⣿]],
	[[⣿⣿⣿⣿⣿⣿⣿⣿⡿⢫⣷⣿⣿⣿⣿⣿⣿⣿⣾⣯⣿⡿⢧⡚⢷⣌⣽⣿⣿⣿⣿⣿⣶⡌⣿⣿⣿⣿⣿⣿]],
	[[⣿⣿⣿⣿⣿⣿⣿⣿⠇⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣮⣇⣘⠿⢹⣿⣿⣿⣿⣿⣻⢿⣿⣿⣿⣿⣿]],
	[[⣿⣿⣿⣿⣿⣿⣿⣿⠀⢸⣿⣿⡇⣿⣿⣿⣿⣿⣿⣿⣿⡟⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣦⣻⣿⣿⣿⣿]],
	[[⣿⣿⣿⣿⣿⣿⣿⡇⠀⣬⠏⣿⡇⢻⣿⣿⣿⣿⣿⣿⣿⣷⣼⣿⣿⣸⣿⣿⣿⣿⣿⣿⣿⣿⣿⢻⣿⣿⣿⣿]],
	[[⣿⣿⣿⣿⣿⣿⣿⠀⠈⠁⠀⣿⡇⠘⡟⣿⣿⣿⣿⣿⣿⣿⣿⡏⠿⣿⣟⣿⣿⣿⣿⣿⣿⣿⣿⣇⣿⣿⣿⣿]],
	[[⣿⣿⣿⣿⣿⣿⡏⠀⠀⠐⠀⢻⣇⠀⠀⠹⣿⣿⣿⣿⣿⣿⣩⡶⠼⠟⠻⠞⣿⡈⠻⣟⢻⣿⣿⣿⣿⣿⣿⣿]],
	[[⣿⣿⣿⣿⣿⣿⡇⠀⠀⠀⠀⠀⢿⠀⡆⠀⠘⢿⢻⡿⣿⣧⣷⢣⣶⡃⢀⣾⡆⡋⣧⠙⢿⣿⣿⣟⣿⣿⣿⣿]],
	[[⣿⣿⣿⣿⣿⣿⡿⠀⠀⠀⠀⠀⠀⠀⡥⠂⡐⠀⠁⠑⣾⣿⣿⣾⣿⣿⣿⡿⣷⣷⣿⣧⣾⣿⣿⣿⣿⣿⣿⣿]],
	[[⣿⣿⡿⣿⣍⡴⠆⠀⠀⠀⠀⠀⠀⠀⠀⣼⣄⣀⣷⡄⣙⢿⣿⣿⣿⣿⣯⣶⣿⣿⢟⣾⣿⣿⢡⣿⣿⣿⣿⣿]],
	[[⣿⡏⣾⣿⣿⣿⣷⣦⠀⠀⠀⢀⡀⠀⠀⠠⣭⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠟⣡⣾⣿⣿⢏⣾⣿⣿⣿⣿⣿]],
	[[⣿⣿⣿⣿⣿⣿⣿⣿⡴⠀⠀⠀⠀⠀⠠⠀⠰⣿⣿⣿⣷⣿⠿⠿⣿⣿⣭⡶⣫⠔⢻⢿⢇⣾⣿⣿⣿⣿⣿⣿]],
	[[⣿⣿⣿⡿⢫⣽⠟⣋⠀⠀⠀⠀⣶⣦⠀⠀⠀⠈⠻⣿⣿⣿⣾⣿⣿⣿⣿⡿⣣⣿⣿⢸⣾⣿⣿⣿⣿⣿⣿⣿]],
	[[⡿⠛⣹⣶⣶⣶⣾⣿⣷⣦⣤⣤⣀⣀⠀⠀⠀⠀⠀⠀⠉⠛⠻⢿⣿⡿⠫⠾⠿⠋⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿]],
	[[⢀⣾⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣀⡆⣠⢀⣴⣏⡀⠀⠀⠀⠉⠀⠀⢀⣠⣰⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿]],
	[[⠿⠛⠛⠛⠛⠛⠛⠻⢿⣿⣿⣿⣿⣯⣟⠷⢷⣿⡿⠋⠀⠀⠀⠀⣵⡀⢠⡿⠋⢻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿]],
	[[⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠉⠛⢿⣿⣿⠂⠀⠀⠀⠀⠀⢀⣽⣿⣿⣿⣿⣿⣿⣿⣍⠛⠿⣿⣿⣿⣿⣿⣿]],
}

-- Self-contained distro source: GitHub codeload by default, corporate mirror when enabled.
-- Precedence: session (:DistroMirror) > distro-mirror.local.json > env > these defaults.
-- Env: DISTRO_MIRROR=1, DISTRO_MIRROR_URL (template), DISTRO_MIRROR_ARGS (space-separated),
--      DISTRO_MIRROR_TOKEN (never logged, never stored on disk).
-- Template placeholders: {owner} {repo} {ref} {branch} {token}.
-- Safety: only https:// sources are accepted; if allowed_hosts is non-empty, any
-- resolved host outside the list is REFUSED (protects against typos/hijacks).
---@type { enabled: boolean, url_template: string, extra_args: string[], token_env: string, allowed_hosts: string[], allow_http: boolean }
settings["distro_mirror"] = {
	enabled = false,
	url_template = "",
	extra_args = {},
	token_env = "DISTRO_MIRROR_TOKEN",
	allowed_hosts = {},
	allow_http = false,
}

-- Async startup streaming (variant A): heavy plugins load after first paint
-- (scheduled) + idle preload. `false` restores byte-identical synchronous boot.
---@type boolean
settings["distro_defer"] = true

-- Set it to false if you don't use AI chat functionality.
---@type boolean
settings["use_chat"] = false

-- Set the language to use for AI chat response here.
--- @type string
settings["chat_lang"] = "English"

-- Set environment variable here to read API key for AI chat.
-- or you can set it to a command that reads the API key from your password manager.
-- e.g. "cmd:op read op://personal/OpenAI/credential --no-new
--- @type string
settings["chat_api_key"] = "CODE_COMPANION_KEY"

-- Set the chat models here and use the first entry as default model.
-- We use `openrouter` as the chat model provider by default (No vested interest).
-- You need to register an account on openrouter and generate an api key.
-- We read the api key by reading the env variable: `CODE_COMPANION_KEY`.
-- All available models can be found here: https://openrouter.ai/models.
--- @type string[]
settings["chat_models"] = {
	-- free models
	"moonshotai/kimi-k2:free", -- default
	"qwen/qwen3-coder:free",
	"deepseek/deepseek-chat-v3-0324:free",
	"deepseek/deepseek-r1:free",
	"google/gemma-3-27b-it:free",
	-- paid models
	"openai/codex-mini",
	"openai/gpt-4.1-mini",
	"google/gemini-2.5-flash-lite",
	"google/gemini-2.5-flash",
	"anthropic/claude-3.7-sonnet",
	"anthropic/claude-sonnet-4",
}

return (function()
	local merged = require("modules.utils").extend_config(settings, "user.settings")
	if vim.env.NVIM_MINIMAL == "1" then
		merged.lsp_inlayhints = false
		merged.signature_enabled = false
		merged.codelens_enabled = false
		merged.treesitter_indent = false
	end
	return merged
end)()
