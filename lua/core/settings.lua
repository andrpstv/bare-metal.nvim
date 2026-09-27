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

-- Large-file guard (lua/core/large_file.lua). When a file hits either limit,
-- syntax/treesitter/LSP/undo/swap are turned off for that buffer.
--
-- Порог large-file детекта. Сравнение идёт через >=, так что файл ровно в
-- max_lines строк тоже считается большим. 0 отключает измерение по строкам
-- (по размеру в КБ детект продолжает работать).
--
-- Дефолт 10000 — исходное, до наследованное от хардкода значение.
-- ВНИМАНИЕ: снижение до 5000 обсуждалось как «быстрая победа», но это
-- ДЕГРАДАЦИЯ, а не оптимизация: порог не влияет на время старта, только на
-- открытие больших файлов, поэтому выигрыша в обмен нет, а файлы 5000–9999
-- строк теряют treesitter и LSP. Если 5000-строчные Go-файлы тормозят —
-- лечится точечно (см. docs/distro/10-largefile-analysis.md), а не порогом.
---@type integer
settings["large_file_max_lines"] = 10000

---@type integer
settings["large_file_max_kb"] = 1024

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

-- Отложить применение базовой темы на «после первого кадра».
-- Экономит ~6 мс синхронного sourcing (black-metal + 15 palette-модулей) на
-- старте, но на первом кадре возможна кратковременная вспышка дефолтной темы.
--
-- По умолчанию ВЫКЛЮЧЕНО: поведение по умолчанию не меняется побайтово, и
-- владелец включает сам и оценивает вспышку глазами.
-- Headless и nvim_list_uis() == 0 всегда применяют тему СИНХРОННО независимо от
-- флага (CI/скрипты/NVIM_DISTRO_SYNC).
---@type boolean
settings["defer_theme"] = false

-- Set to true if your terminal supports a transparent background.
---@type boolean
settings["transparent_background"] = false

-- Set the background mode here.
-- Useful for themes with both light and dark variants.
-- Valid values: `dark`, `light`.
--
-- ВНИМАНИЕ, скрытая связь с первым кадром. Это значение применяется
-- СИНХРОННО при старте (core/init.lua, до defer-темы), и именно оно держит
-- первый кадр тёмным. Комментарий в themes/black-metal-khold.lua про
-- «paint-critical: первый кадр тёмный» относится к НЕотложенному пути.
-- При settings.defer_theme = true базовая тема уезжает на таймер, и тёмный
-- первый кадр обеспечивает только эта строка. Если её когда-нибудь отложить
-- (например в turbo-режиме), появится белый флэш — проверено ревьюером, что
-- сейчас его нет именно синхронным background="dark". Не откладывать молча.
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

-- Пресет «слабое железо» одним переключателем (lua/core/weak_hw.lua).
-- ВКЛЮЧАЕТ: turbo (отложивание) + gopls_weak_hw + defer_theme + ослабление
-- treesitter (indent off, full_lines<=500) + gopls_debounce >= 250.
--
-- Это отказ от части фич ради отзывчивости, а не бесплатное ускорение.
-- По умолчанию false: пока выключен, ни один модуль пресета не читается и
-- поведение конфига побайтово прежнее. Читается лениво (vim.g.weak_hw /
-- NVIM_WEAK_HW=1), см. core/weak_hw.lua.
---@type boolean
settings["weak_hw"] = false

-- Оси пресета: false = ось не включается даже при weak_hw=true.
-- Оси: turbo, gopls, theme, treesitter, debounce. Отсутствующий ключ = включена.
---@type table<string, boolean>
settings["weak_hw_axes"] = {
	turbo = true,
	gopls = true,
	theme = true,
	treesitter = true,
	debounce = true,
}

-- Пресет «слабое железо» для gopls. Один переключатель вместо пяти правок.
-- Выключает САМЫЙ ДОРОГОЙ компонент — фоновые анализы сервера:
--   fieldalignment -> off, все 8 codelenses -> off (без перечисления),
--   semanticTokens -> off, completeUnimported -> off, debounce -> gopls_weak_hw_debounce.
--
-- Отдельный флаг, а не связка с turbo, потому что это разные оси: turbo про
-- ОТЛОЖИВАНИЕ (поведение то же, позже), пресет про СОДЕРЖАНИЕ работы сервера
-- (дешевле, но качество диагностики ниже). Смешивать их в один флаг значило бы
-- нельзя было получить одно без другого.
--
-- ВНИМАНИЕ: это отказ от фич, а не «ускорение». gd перестаёт подсказывать
-- выравнивание структур, codelenses исчезают.
--
-- Читается лениво — в lua/modules/configs/completion/servers/gopls.lua при
-- первой загрузке модуля (первый Go-буфер), НЕ на старте. Переключение
-- действует на будущие поднятия клиента; уже работающий сервер не меняется.
-- По умолчанию false: при выключенном флаге поведение побайтово прежнее.
---@type boolean
settings["gopls_weak_hw"] = false

-- Debounce для пресета выше (ms). Больше = реже пересчёт фоновых анализов.
---@type number
settings["gopls_weak_hw_debounce"] = 250

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

-- Проверять при старте, все ли парсеры из treesitter_deps на месте, и
-- предлагать доставить недостающие. Проверка читает только каталоги
-- (fs_scandir), сети не касается: скачивание остаётся за :DistroParsers,
-- где стоит подтверждение. 2000 мс после старта, чтобы не мешать инициализации.
-- Поставьте false, если парсеры ставит внешний процесс (образ/DevContainer).
---@type boolean
settings["parser_bootstrap"] = true

-- Показывать всплывающую подсказку с leader-хоткеями, когда начато сочетание
-- и введённый префикс ещё не совпадает ни с одним маппингом целиком.
-- Подсказка строится из живых маппингов, новых зависимостей не добавляет.
---@type boolean
settings["leader_help"] = true

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
-- One line per row of the picture, no trailing spaces.
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
