-- scripts/regress-external.lua — external-change sync policy + watcher lifecycle.
-- Covers core.external without a full config, TUI, LSP, or network:
--   * conflict policy: clean buffers may auto-reload, modified never;
--   * watch() starts a watcher for a real file, is idempotent, skips
--     non-file buffers (empty name, buftype, directory);
--   * buffers are unwatched on cleanup; handles die with their buffer
--     (no leaks across watch/unwatch cycles);
--   * setup() registers the checktime safety net (BufEnter/CursorHold/
--     FocusGained) and the FileChangedShellPost reporter.
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-external.lua
-- Exit 0 when all cases pass, 1 otherwise.

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

local ok, ext = pcall(require, "core.external")
check("core.external requires cleanly", ok and type(ext) == "table")
if not ok then
	print("LOAD-ERR: " .. tostring(ext):sub(1, 160))
	print(string.format("total=%d failures=%d", total, failures))
	os.exit(1)
end

-- Distro default (core/options.lua sets autoread=true); -u NONE leaves it
-- off, and without it :checktime only prompts instead of reloading.
vim.o.autoread = true
ext.setup()

-- 1. Conflict policy (pure).
check("clean buffer may auto-reload", ext.should_reload(false) == true)
check("modified buffer never auto-reloads", ext.should_reload(true) == false)
-- Stale v:fcs_reason (it is global): only the real state may produce a warning.
check("conflict reported for a modified buffer", ext.post_report("conflict", true, true) == "conflict")
check("stale 'conflict' on a clean reload is silent", ext.post_report("conflict", false, true) == nil)
check("deleted reported when the file is gone", ext.post_report("deleted", false, false) == "deleted")
check("stale 'deleted' with the file present is silent", ext.post_report("deleted", false, true) == nil)
check("plain reload is silent", ext.post_report("", false, true) == nil)

-- 2. Watcher lifecycle on a real temp file.
local tmp = vim.fn.tempname()
vim.fn.writefile({ "v1" }, tmp)
vim.cmd("edit " .. vim.fn.fnameescape(tmp))
local buf = vim.api.nvim_get_current_buf()
check("watch() accepts a file buffer", ext.watch(buf) == true)
check("buffer is watched", ext._test_watched(buf) == true)
check("watch() is idempotent", ext.watch(buf) == true)
check("exactly one watcher", ext._test_count() == 1)

-- Non-file buffers are skipped.
local scratch = vim.api.nvim_create_buf(false, true)
check("watch() skips buftype=nofile", ext.watch(scratch) == false)
local unnamed = vim.api.nvim_create_buf(true, false)
check("watch() skips unnamed buffer", ext.watch(unnamed) == false)
check("no watcher leaked by skips", ext._test_count() == 1)

-- 3. External modification auto-reloads a clean buffer (no :checktime).
-- NOTE: settle 1s after :edit first — a write in the same tick as watcher
-- registration can race the OS event arm (observed on macOS: immediate
-- same-process writes report zero fs events). Real agent writes always
-- arrive long after BufReadPost, so the settle mirrors production, not a
-- workaround. Writes go through a child process: that is the actual
-- "external agent" path (same-process io.open would also work, but the
-- child is the faithful fixture).
vim.wait(1000)
vim.system({ "sh", "-c", "printf v2-external > " .. vim.fn.shellescape(tmp) }):wait()
local reloaded = vim.wait(5000, function()
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	return lines[1] == "v2-external"
end, 50)
check("clean buffer auto-reloads on external write", reloaded)
check(
	"reloaded content matches disk",
	vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "v2-external"
)

-- 4. Modified buffer is protected: external write must NOT clobber it.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "LOCAL-EDIT" })
check("buffer shows modified", vim.bo[buf].modified == true)
vim.system({ "sh", "-c", "printf v3-external > " .. vim.fn.shellescape(tmp) }):wait()
vim.wait(2500)
local kept = vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "LOCAL-EDIT"
check("modified buffer keeps local edits", kept)
check("modified flag survives external write", vim.bo[buf].modified == true)

-- 5. Cleanup: handles die with the buffer, counts return to zero.
vim.api.nvim_buf_delete(buf, { force = true })
local drained = vim.wait(2000, function()
	return ext._test_count() == 0
end, 50)
check("watcher cleaned up with buffer", drained)
check("count back to zero", ext._test_count() == 0)

-- 6. setup() registered the safety net (idempotent: run twice, one group).
ext.setup()
local function has_autocmd(event, pat)
	local found = false
	for _, ac in ipairs(vim.api.nvim_get_autocmds({ group = "ExternalSync", event = event })) do
		if not pat or (ac.pattern or ""):find(pat, 1, true) then
			found = true
		end
	end
	return found
end
check("checktime net on BufEnter", has_autocmd("BufEnter"))
check("checktime net on CursorHold", has_autocmd("CursorHold"))
check("checktime net on FocusGained", has_autocmd("FocusGained"))
check("FileChangedShellPost reporter present", has_autocmd("FileChangedShellPost"))
check("watcher starter on BufReadPost", has_autocmd("BufReadPost"))
check("watcher cleanup on BufWipeout", has_autocmd("BufWipeout"))

ext._test_reset()
vim.fn.delete(tmp)
pcall(vim.api.nvim_buf_delete, scratch, { force = true })
pcall(vim.api.nvim_buf_delete, unnamed, { force = true })

print(string.format("total=%d failures=%d", total, failures))
if failures > 0 then
	os.exit(1)
end
