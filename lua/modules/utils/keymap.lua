-- User keymap overrides. Plain specs over `vim.keymap.set`, no builder.
-- Format: `{ ["n|<leader>x"] = { rhs = "<Cmd>...<CR>" | function | false, opts = {...} } }`
-- `rhs = false` deletes the mapping. `opts.buffer = bufnr` scopes it to a buffer.
-- Multi-mode keys ("nv|ga") expand to `vim.keymap.set({ "n", "v" }, ...)`.
local M = {}

---Replace (or delete) keymaps described by plain specs.
---@param mapping table<string, { rhs: string|function|false, opts: table? }>
function M.replace(mapping)
	for key, spec in pairs(mapping or {}) do
		local modes, lhs = key:match("([^|]*)|?(.*)")
		local list = vim.split(modes, "")
		if spec == false or spec == "" then
			for _, m in ipairs(list) do
				pcall(vim.keymap.del, m, lhs)
			end
		elseif type(spec) == "table" then
			vim.keymap.set(list, lhs, spec.rhs or spec[1], spec.opts or spec[2] or {})
		end
	end
end

return M
