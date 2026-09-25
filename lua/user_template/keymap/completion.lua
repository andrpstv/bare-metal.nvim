local mappings = {}

-- Place global keymaps here.
mappings["plug_map"] = {}

-- NOTE: This function is special! Keymaps defined here are ONLY effective in buffers with LSP(s) attached
-- NOTE: Make sure to include `buffer = buf` in opts to limit the scope of your mappings.
---@param buf number @The effective bufnr
mappings["lsp"] = function(buf)
	return {
		-- Example
		["n|K"] = { rhs = "<Cmd>Lspsaga hover_doc<CR>", opts = { buffer = buf, desc = "lsp: Show doc" } },
	}
end

return mappings
