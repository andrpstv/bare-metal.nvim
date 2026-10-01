-- LSP-buffer keymap overrides. Two slots, both optional:
--   plug_map: plain specs merged into the GLOBAL table by user.keymap.init.
--   lsp(buf): function returning buffer-local specs, applied on every LspAttach
--             (keymap/completion.lua calls user.keymap.completion.lsp(buf)).
--   NOTE: lsp() specs MUST include `buffer = buf` in opts to stay buffer-local.
local mappings = {}

mappings["plug_map"] = {}

---@param buf number @The effective bufnr
mappings["lsp"] = function(buf)
	return {
		-- Example (buffer-local hover replacement):
		-- ["n|K"] = { rhs = vim.lsp.buf.hover, opts = { buffer = buf, desc = "lsp: Show doc" } },
	}
end

return mappings
