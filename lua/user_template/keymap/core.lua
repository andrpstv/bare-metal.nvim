-- Global keymap overrides. Plain specs over `vim.keymap.set`, no builder.
-- Merged into one table by user.keymap.init (tbl_extend, later files win).
-- Format per entry: `{ ["n|<leader>x"] = { rhs = "<Cmd>...<CR>" | function | false, opts = {...} } }`
-- `false` (whole spec) deletes the mapping. `opts.buffer = bufnr` scopes to a buffer.
-- Multi-mode keys ("nv|ga") expand to set({ "n", "v" }, ...).
-- Full contract: lua/modules/utils/keymap.lua (M.replace).
return {}
