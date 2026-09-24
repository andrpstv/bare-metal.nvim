require("keymap.helpers")
local bind = require("keymap.bind")
local map_cr = bind.map_cr

local mappings = {
	core = {
		-- Package manager: distroManager (self-contained, curl-only, confirm-gated)
		["n|<leader>ph"] = map_cr("Distro"):with_silent():with_noremap():with_nowait():with_desc("package: Show"),
		["n|<leader>ps"] = map_cr("DistroCheck"):with_silent():with_noremap():with_nowait():with_desc("package: Check"),
		["n|<leader>pu"] = map_cr("DistroUpdate")
			:with_silent()
			:with_noremap()
			:with_nowait()
			:with_desc("package: Update"),
		["n|<leader>pi"] = map_cr("DistroInstall")
			:with_silent()
			:with_noremap()
			:with_nowait()
			:with_desc("package: Install"),
		["n|<leader>pl"] = map_cr("DistroParsers"):with_silent():with_noremap():with_nowait():with_desc("package: Parsers"),
		["n|<leader>pc"] = map_cr("DistroCheck"):with_silent():with_noremap():with_nowait():with_desc("package: Check"),
		["n|<leader>pd"] = map_cr("DistroTools"):with_silent():with_noremap():with_nowait():with_desc("package: Tools"),
		["n|<leader>pp"] = map_cr("DistroParsers")
			:with_silent()
			:with_noremap()
			:with_nowait()
			:with_desc("package: Parsers"),
		["n|<leader>pr"] = map_cr("DistroUpdate")
			:with_silent()
			:with_noremap()
			:with_nowait()
			:with_desc("package: Update"),
		["n|<leader>px"] = map_cr("DistroClean"):with_silent():with_noremap():with_nowait():with_desc("package: Clean"),
	},
}

bind.nvim_load_mapping(mappings.core)

-- Builtin & Plugin keymaps
require("keymap.completion")
require("keymap.editor")
require("keymap.lang")
require("keymap.tool")
require("keymap.ui")

-- Сносим ГЛОБАЛЬНЫЕ дефолты 0.11 (vim/_defaults.lua ставит их всегда,
-- не только в LSP-буферах): grn/grr/gri/gra/grt душат bare `gr`
-- ожиданием timeoutlen. Наши замены: gr/gi/ga/gy (pick), rename на <leader>rn.
-- Удаляем и сразу, и на VimEnter — порядок загрузки дефолтов не гарантирован.
local function _del_lsp_defaults()
	for _, lhs in ipairs({ "grn", "grr", "gri", "gra", "grt" }) do
		pcall(vim.keymap.del, "n", lhs)
	end
	pcall(vim.keymap.del, "x", "gra")
end
_del_lsp_defaults()
vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = _del_lsp_defaults,
})

-- User keymaps
local ok, def = pcall(require, "user.keymap.init")
if ok then
	require("modules.utils.keymap").replace(def)
end
