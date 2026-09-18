local bind = require("keymap.bind")
local map_cr = bind.map_cr
local map_callback = bind.map_callback

local mappings = {
	fmt = {
		["n|<A-f>"] = map_cr("FormatToggle"):with_noremap():with_silent():with_desc("formatter: Toggle format on save"),
		["n|<A-S-f>"] = map_cr("Format"):with_noremap():with_silent():with_desc("formatter: Format buffer manually"),
	},
}
bind.nvim_load_mapping(mappings.fmt)

--- The following code allows this file to be exported ---
---    for use with LSP lazy-loaded keymap bindings    ---

local M = {}

---@param buf integer
function M.lsp(buf)
	local map = {
		-- LSP-related keymaps, ONLY effective in buffers with LSP(s) attached.
		-- Списки результатов — встроенка + quickfix (дефолты grr/gri/gra тоже работают).
		-- Пикер fzf — только там, где нужен выбор с превью (definitions, symbols).
		["n|<leader>li"] = map_cr("LspInfo"):with_silent():with_buffer(buf):with_desc("lsp: Info"),
		["n|<leader>lr"] = map_cr("LspRestart"):with_silent():with_buffer(buf):with_nowait():with_desc("lsp: Restart"),
		["n|go"] = map_cr("Trouble symbols toggle win.position=right")
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Toggle outline"),
		["n|gto"] = map_callback(function()
				_fzf("lsp_document_symbols")
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Document symbols"),
		["n|g["] = map_callback(function()
				vim.diagnostic.jump({ count = -1, float = true })
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Prev diagnostic"),
		["n|g]"] = map_callback(function()
				vim.diagnostic.jump({ count = 1, float = true })
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Next diagnostic"),
		["n|<leader>lx"] = map_callback(function()
				vim.diagnostic.open_float()
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Line diagnostic"),
		["n|gs"] = map_callback(function()
			vim.lsp.buf.signature_help()
		end):with_desc("lsp: Signature help"),
		["n|gr"] = map_callback(function()
				vim.lsp.buf.rename()
			end)
			:with_silent()
			:with_nowait()
			:with_buffer(buf)
			:with_desc("lsp: Rename"),
		["n|K"] = map_callback(function()
				vim.lsp.buf.hover()
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Show doc"),
		["nv|ga"] = map_callback(function()
				vim.lsp.buf.code_action()
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Code action (vim.ui.select)"),
		["n|gd"] = map_callback(function()
				_fzf("lsp_definitions", { jump1 = true })
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Goto definition"),
		["n|gD"] = map_callback(function()
				vim.lsp.buf.declaration()
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Goto declaration"),
		["n|gh"] = map_callback(function()
				vim.lsp.buf.references()
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: References to quickfix"),
		["n|gH"] = map_cr("Trouble lsp_references toggle")
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: References in Trouble (preview, Enter jumps)"),
		["n|gm"] = map_callback(function()
				vim.lsp.buf.implementation()
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Implementations to quickfix"),
		["n|gM"] = map_cr("Trouble lsp_implementations toggle")
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Implementations in Trouble (preview, Enter jumps)"),
		["n|gci"] = map_callback(function()
				_fzf("lsp_incoming_calls")
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Show incoming calls"),
		["n|gco"] = map_callback(function()
				_fzf("lsp_outgoing_calls")
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Show outgoing calls"),
		["n|<leader>lv"] = map_callback(function()
				_toggle_virtuallines()
			end)
			:with_noremap()
			:with_silent()
			:with_desc("lsp: Toggle virtual lines"),
		["n|<leader>lh"] = map_callback(function()
				_toggle_inlayhint()
			end)
			:with_noremap()
			:with_silent()
			:with_desc("lsp: Toggle inlay hints"),
	}
	bind.nvim_load_mapping(map)

	local ok, user_mappings = pcall(require, "user.keymap.completion")
	if ok and type(user_mappings.lsp) == "function" then
		require("modules.utils.keymap").replace(user_mappings.lsp(buf))
	end
end

return M
