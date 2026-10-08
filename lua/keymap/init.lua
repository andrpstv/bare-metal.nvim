-- RU-дубли ПЕРВЫМИ: обёртка vim.keymap.set должна стоять до всех map(),
-- иначе поздние (и buffer-local LSP) останутся только на EN.
require("keymap.ru").setup()
require("keymap.helpers")
require("keymap.pick")
require("keymap.go_assign")
require("keymap.statusline")

local map = vim.keymap.set
local cr = function(cmd)
	return ":" .. cmd .. "<CR>"
end

-- Голый <leader> — Nop, НО только когда which-key недоступен.
-- Причина условности (проверено в TUI): ЛЮБОЙ маппинг на голый <leader>
-- превращает его в which-key в исполняемый leaf — state.start выполняет Nop
-- сразу (is_nowait через `not timedout`), popup не показывается НИКОГДА.
-- Когда which-key активен, его buffer-local триггер (nowait) и так глотает
-- bare Space (дрейфа как `l` нет, недопечатанное ждёт следующий ключ).
-- Без which-key (не вендорен / в disabled_plugins) Nop нужен как раньше.
local function _which_key_active()
	local ok_m, manifest = pcall(require, "distro.manifest")
	local entry = ok_m and manifest.get and manifest.get("which-key.nvim") or nil
	if not entry then
		return false
	end
	local ok_l, loader = pcall(require, "distro.loader")
	if not (ok_l and loader.is_present and loader.is_present(entry)) then
		return false
	end
	local ok_s, settings = pcall(require, "core.settings")
	if ok_s and type(settings.disabled_plugins) == "table" then
		for _, d in ipairs(settings.disabled_plugins) do
			if d == "which-key.nvim" then
				return false
			end
		end
	end
	return true
end
if not _which_key_active() then
	map({ "n", "x" }, "<leader>", "<Nop>", { noremap = true, silent = true, desc = "leader prefix (no-op alone)" })
end

-- Гарды git-клавиш: gitsigns вешает их ЛОКАЛЬНО буферу и только в репо.
-- Вне репо сочетания проваливались в builtin (gp = paste поверх текста!).
-- Глобальные хинты ниже перекрываются настоящими buffer-local при аттаче.
local _nogit = "[git] not a git repo — open a file inside one (gitsigns maps attach per buffer)"
for _, lhs in ipairs({ "]g", "[g", "<leader>gs", "<leader>gr", "<leader>gR", "<leader>gp", "<leader>gb" }) do
	map("n", lhs, function()
		vim.notify(_nogit, vim.log.levels.WARN, { title = "git" })
	end, { noremap = true, silent = true, desc = "git: needs a git repo" })
end
for _, lhs in ipairs({ "<leader>gs", "<leader>gr" }) do
	map("x", lhs, function()
		vim.notify(_nogit, vim.log.levels.WARN, { title = "git" })
	end, { noremap = true, silent = true, desc = "git: needs a git repo" })
end

-- Package manager: distroManager (self-contained, curl-only, confirm-gated)
map("n", "<leader>ph", cr("Distro"), { noremap = true, silent = true, nowait = true, desc = "package: Show" })
map("n", "<leader>ps", cr("DistroCheck"), { noremap = true, silent = true, nowait = true, desc = "package: Check" })
map("n", "<leader>pu", cr("DistroUpdate"), { noremap = true, silent = true, nowait = true, desc = "package: Update" })
map("n", "<leader>pi", cr("DistroInstall"), { noremap = true, silent = true, nowait = true, desc = "package: Install" })
map("n", "<leader>pl", cr("DistroParsers"), { noremap = true, silent = true, nowait = true, desc = "package: Parsers" })
map("n", "<leader>pd", cr("DistroTools"), { noremap = true, silent = true, nowait = true, desc = "package: Tools" })
map("n", "<leader>px", cr("DistroClean"), { noremap = true, silent = true, nowait = true, desc = "package: Clean" })

-- Builtin & Plugin keymaps
require("keymap.completion")
require("keymap.editor")
require("keymap.go_tools")
require("keymap.lang")
require("keymap.tool")
require("keymap.ui")
require("keymap.dev")

-- Сносим ГЛОБАЛЬНЫЕ дефолты 0.11 (vim/_defaults.lua ставит их всегда,
-- не только в LSP-буферах): grn/grr/gri/gra/grt душат bare `gr`
-- ожиданием timeoutlen. Наши замены: gr/gi/ga/gy (pick), rename на <leader>rn.
-- Только на VimEnter: порядок загрузки дефолтов не гарантирован, ранний вызов
-- молча ничего не удаляет и лишь дублирует работу.
local function _del_lsp_defaults()
	-- grx тоже: забытый дефолт заставлял каждый gr ждать timeoutlen,
	-- а сам дублирует <leader>cl (codelens run).
	for _, lhs in ipairs({ "grn", "grr", "gri", "gra", "grt", "grx" }) do
		pcall(vim.keymap.del, "n", lhs)
	end
	pcall(vim.keymap.del, "x", "gra")
end
vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = _del_lsp_defaults,
})

-- User keymaps
local ok, def = pcall(require, "user.keymap.init")
if ok then
	require("modules.utils.keymap").replace(def)
end

-- Подсказка по leader. Индекс строится из живых маппингов, поэтому
-- буферные LSP-хоткеи (<leader>li, <leader>rn) в него попадают не сразу —
-- сбрасываем кэш на каждом LspAttach.
require("keymap.leader_help").setup()
vim.api.nvim_create_autocmd("LspAttach", {
	callback = function()
		require("keymap.leader_help").invalidate()
	end,
})
