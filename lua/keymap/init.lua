require("keymap.helpers")
require("keymap.pick")
require("keymap.go_assign")
require("keymap.statusline")

local map = vim.keymap.set
local cr = function(cmd)
	return ":" .. cmd .. "<CR>"
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

-- Сносим ГЛОБАЛЬНЫЕ дефолты 0.11 (vim/_defaults.lua ставит их всегда,
-- не только в LSP-буферах): grn/grr/gri/gra/grt душат bare `gr`
-- ожиданием timeoutlen. Наши замены: gr/gi/ga/gy (pick), rename на <leader>rn.
-- Только на VimEnter: порядок загрузки дефолтов не гарантирован, ранний вызов
-- молча ничего не удаляет и лишь дублирует работу.
local function _del_lsp_defaults()
	for _, lhs in ipairs({ "grn", "grr", "gri", "gra", "grt" }) do
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
