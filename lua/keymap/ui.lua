local bind = require("keymap.bind")
local map_cr = bind.map_cr
local map_cu = bind.map_cu
local map_cmd = bind.map_cmd
local map_callback = bind.map_callback

local mappings = {
	builtins = {
		-- Builtins: Buffer
		["n|<leader>bn"] = map_cu("enew"):with_noremap():with_silent():with_desc("buffer: New"),

		-- Builtins: Quickfix (пара к LSP-флоу на встроенке: grr/gri/gh/gm)
		["n|]q"] = map_cr("cnext"):with_noremap():with_silent():with_desc("quickfix: Next"),
		["n|[q"] = map_cr("cprev"):with_noremap():with_silent():with_desc("quickfix: Previous"),
		["n|<leader>qq"] = map_cr("copen"):with_noremap():with_silent():with_desc("quickfix: Open"),
		["n|<leader>qc"] = map_cr("cclose"):with_noremap():with_silent():with_desc("quickfix: Close"),
		["n|[b"] = map_cr("bprevious"):with_noremap():with_silent():with_desc("buffer: Previous"),
		["n|]b"] = map_cr("bnext"):with_noremap():with_silent():with_desc("buffer: Next"),

		-- Builtins: Split
		["n|<leader>sv"] = map_cr("vsplit"):with_noremap():with_silent():with_desc("split: Vertical"),
		["n|<leader>sh"] = map_cr("split"):with_noremap():with_silent():with_desc("split: Horizontal"),
		["n|<leader>sc"] = map_cr("close"):with_noremap():with_silent():with_desc("split: Close"),

		-- Builtins: Terminal
		["t|<C-w>h"] = map_cmd("<Cmd>wincmd h<CR>"):with_silent():with_noremap():with_desc("window: Focus left"),
		["t|<C-w>l"] = map_cmd("<Cmd>wincmd l<CR>"):with_silent():with_noremap():with_desc("window: Focus right"),
		["t|<C-w>j"] = map_cmd("<Cmd>wincmd j<CR>"):with_silent():with_noremap():with_desc("window: Focus down"),
		["t|<C-w>k"] = map_cmd("<Cmd>wincmd k<CR>"):with_silent():with_noremap():with_desc("window: Focus up"),

		-- Builtins: Tabpage
		["n|tn"] = map_cr("tabnew"):with_noremap():with_silent():with_desc("tab: Create a new tab"),
		["n|tk"] = map_cr("tabnext"):with_noremap():with_silent():with_desc("tab: Move to next tab"),
		["n|tj"] = map_cr("tabprevious"):with_noremap():with_silent():with_desc("tab: Move to previous tab"),
		["n|to"] = map_cr("tabonly"):with_noremap():with_silent():with_desc("tab: Only keep current tab"),
	},
	plugins = {
		-- Буферы: встроенные :bnext/:bprevious/:bd (barbar удалён)
		["n|<A-q>"] = map_cr("bd"):with_noremap():with_silent():with_desc("buffer: Close current"),

		-- Окна: встроенные <C-w> (smart-splits удалён)
		["n|<C-h>"] = map_cmd("<C-w>h"):with_silent():with_noremap():with_desc("window: Focus left"),
		["n|<C-j>"] = map_cmd("<C-w>j"):with_silent():with_noremap():with_desc("window: Focus down"),
		["n|<C-k>"] = map_cmd("<C-w>k"):with_silent():with_noremap():with_desc("window: Focus up"),
		["n|<C-l>"] = map_cmd("<C-w>l"):with_silent():with_noremap():with_desc("window: Focus right"),
	},
}

bind.nvim_load_mapping(mappings.builtins)
bind.nvim_load_mapping(mappings.plugins)

--- The following code enables this file to be exported ---
---  for use with gitsigns lazy-loaded keymap bindings  ---

local M = {}

function M.gitsigns(bufnr)
	local gitsigns = require("gitsigns")
	local map = {
		["n|]g"] = map_callback(function()
				if vim.wo.diff then
					return "]g"
				end
				vim.schedule(function()
					gitsigns.nav_hunk("next")
				end)
				return "<Ignore>"
			end)
			:with_buffer(bufnr)
			:with_noremap()
			:with_expr()
			:with_desc("git: Goto next hunk"),
		["n|[g"] = map_callback(function()
				if vim.wo.diff then
					return "[g"
				end
				vim.schedule(function()
					gitsigns.nav_hunk("prev")
				end)
				return "<Ignore>"
			end)
			:with_buffer(bufnr)
			:with_noremap()
			:with_expr()
			:with_desc("git: Goto prev hunk"),
		["n|<leader>gs"] = map_callback(function()
				gitsigns.stage_hunk()
			end)
			:with_buffer(bufnr)
			:with_noremap()
			:with_desc("git: Toggle staging/unstaging of hunk"),
		["v|<leader>gs"] = map_callback(function()
				gitsigns.stage_hunk({ vim.fn.line("."), vim.fn.line("v") })
			end)
			:with_buffer(bufnr)
			:with_noremap()
			:with_desc("git: Toggle staging/unstaging of selected hunk"),
		["n|<leader>gr"] = map_callback(function()
				gitsigns.reset_hunk()
			end)
			:with_buffer(bufnr)
			:with_noremap()
			:with_desc("git: Reset hunk"),
		["v|<leader>gr"] = map_callback(function()
				gitsigns.reset_hunk({ vim.fn.line("."), vim.fn.line("v") })
			end)
			:with_buffer(bufnr)
			:with_noremap()
			:with_desc("git: Reset hunk"),
		["n|<leader>gR"] = map_callback(function()
				gitsigns.reset_buffer()
			end)
			:with_buffer(bufnr)
			:with_noremap()
			:with_desc("git: Reset buffer"),
		["n|<leader>gp"] = map_callback(function()
				gitsigns.preview_hunk()
			end)
			:with_buffer(bufnr)
			:with_noremap()
			:with_desc("git: Preview hunk"),
		["n|<leader>gb"] = map_callback(function()
				gitsigns.blame_line({ full = true })
			end)
			:with_buffer(bufnr)
			:with_noremap()
			:with_desc("git: Blame line"),
		-- Text objects
		["ox|ih"] = map_callback(function()
				gitsigns.select_hunk()
			end)
			:with_buffer(bufnr)
			:with_noremap(),
	}
	bind.nvim_load_mapping(map)
end

return M
