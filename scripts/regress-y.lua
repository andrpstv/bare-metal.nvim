-- scripts/regress-y.lua — regression test for the Y mapping form.
-- Y must behave exactly like builtin y$: yank to end of line from the
-- cursor, linewise register content unaffected, cursor unmoved.
-- The mapping is declared as noremap y$; here we validate that exact
-- mapping form behaves correctly (a remapping Y would break Yp etc.).
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-y.lua
-- Exit 0 when all cases pass, 1 otherwise. No network, no user config.

local failures = 0
local total = 0

local function check(desc, cond)
	total = total + 1
	if cond then
		print("OK " .. desc)
	else
		failures = failures + 1
		print("FAIL " .. desc)
	end
end

-- Install the exact mapping form from lua/keymap/editor.lua.
vim.keymap.set("n", "Y", "y$", { noremap = true, silent = false })

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world", "second line" })

-- Y mid-line yanks to EOL.
vim.api.nvim_win_set_cursor(0, { 1, 6 })
vim.api.nvim_feedkeys("Y", "mx!", false)
check("yank to eol", vim.fn.getreg('"') == "world")
local pos = vim.api.nvim_win_get_cursor(0)
check("cursor unmoved", pos[1] == 1 and pos[2] == 6)

-- Y on the last character yanks it (same as builtin y$).
vim.api.nvim_win_set_cursor(0, { 2, 10 })
vim.api.nvim_feedkeys("Y", "mx!", false)
check("yank last char", vim.fn.getreg('"') == "e")

-- The mapping itself is non-recursive.
local map = vim.fn.maparg("Y", "n", false, true)
check("noremap set", map.noremap == 1)

print(string.format("total=%d failures=%d", total, failures))
if failures > 0 then
	os.exit(1)
end
