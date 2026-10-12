-- core.external: automatic external-change synchronization (IDE-like).
--
-- Problem: 'autoread' alone only reloads when Neovim happens to run
-- :checktime, and this distro only ran it on FocusGained. An AI agent (or
-- git checkout, go generate, background formatter) modifying an open file
-- while the user stays in the same window left a stale buffer with no
-- indication, until the user switched focus or ran :checktime manually.
--
-- Solution (hybrid, no new dependencies, no project-wide polling):
--   1. Event-driven: one libuv fs_event watcher per open file buffer.
--      Fires in milliseconds on local filesystems; debounced (300ms) so
--      rapid agent rewrites cause a single :checktime, not a reload loop.
--   2. Safety net: checktime on BufEnter / CursorHold / CursorHoldI /
--      FocusGained covers watcher failures (rename races, EMFILE, network
--      mounts) without any timer or polling loop of our own.
--
-- Conflict policy (never silently destroy work):
--   * Buffer WITHOUT unsaved changes + external change -> auto-reload,
--     silently (same as stock autoread; a reload is the expected IDE
--     behavior, and per-reload notifications would spam during rapid
--     agent writes).
--   * Buffer WITH unsaved changes + external change -> NEVER auto-reload,
--     NEVER auto-overwrite. One throttled warning per buffer (5s window)
--     telling the user to resolve manually (:w! to keep ours, :e! to take
--     theirs). Stock FileChangedShell already prompts; we only add the
--     explicit warning so it cannot pass unnoticed, and we never set
--     v:fcs_choice to "load" for a modified buffer.
--   * Deleted/renamed on disk -> stock prompt + an explicit warning
--     (FileChangedShellPost), buffer kept so nothing is lost.
--
-- Bounds: at most 256 watched buffers (LRU-ish: beyond that, new buffers
-- rely on the checktime net only); all handles/timers die on BufDelete /
-- BufWipeout / VimLeavePre. No watcher survives its buffer.
--
-- Offline-first: pure libuv + autocmds, no executables, no network.

local M = {}

local DEBOUNCE_MS = 300
local NOTIFY_MS = 5000
local MAX_WATCHERS = 256

-- bufnr -> { event, timer, path, restarts }
local watchers = {}
local watcher_count = 0
-- bufnr -> last conflict/deleted notify time (hrtime ns)
local last_notify = {}
local failed_once_notified = false

local function hrtime_ms()
	return math.floor(vim.uv.hrtime() / 1000000)
end

local function throttled_notify(buf, level, msg, title)
	local now = vim.uv.hrtime()
	if now - (last_notify[buf] or 0) < NOTIFY_MS * 1000000 then
		return
	end
	last_notify[buf] = now
	vim.notify(msg, level, { title = title or "[sync]" })
end

--- Pure conflict policy, unit-testable: may an external change auto-reload?
---@param modified boolean whether the buffer has unsaved edits
---@return boolean reload allowed
function M.should_reload(modified)
	return not modified
end

local function is_watchable(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	if vim.bo[buf].buftype ~= "" then
		return false
	end
	local name = vim.api.nvim_buf_get_name(buf)
	if name == "" then
		return false
	end
	-- Non-file URIs (diffview://, oil://, fugitive://): same rule as LSP
	-- extras in modules.utils.is_file_buffer.
	local scheme = name:match("^([%w%.%+%-]+)://")
	if scheme ~= nil and scheme ~= "file" then
		return false
	end
	if vim.fn.isdirectory(name) == 1 then
		return false
	end
	return true
end

local function cleanup(buf)
	local w = watchers[buf]
	if not w then
		return
	end
	watchers[buf] = nil
	last_notify[buf] = nil
	watcher_count = watcher_count - 1
	pcall(function()
		if w.timer then
			w.timer:stop()
			w.timer:close()
		end
	end)
	pcall(function()
		if w.event then
			w.event:stop()
			w.event:close()
		end
	end)
end

-- Restart a watcher after an atomic (rename-based) save: the old handle
-- follows the old inode and would go deaf to further changes.
local function restart_watcher(buf, path)
	local w = watchers[buf]
	if not w then
		return
	end
	pcall(function()
		w.event:stop()
		w.event:close()
	end)
	local ev, err = vim.uv.new_fs_event()
	if not ev then
		cleanup(buf)
		return
	end
	w.event = ev
	local ok = pcall(function()
		w.event:start(path, {}, vim.schedule_wrap(function(s_err, _, events)
			M._on_fs_event(buf, s_err, events)
		end))
	end)
	if not ok or err then
		cleanup(buf)
	end
end

--- fs_event callback (scheduled). Debounces rapid agent rewrites into a
--- single checktime; never reloads a modified buffer itself (checktime +
--- autoread does the reload, FileChangedShell prompts on conflict).
---@param buf integer
function M._on_fs_event(buf, fs_err, events)
	if fs_err then
		-- Watcher-level failure (deleted file reports this way too):
		-- fall back to the checktime net, which handles deletion prompts.
		cleanup(buf)
		return
	end
	if not vim.api.nvim_buf_is_valid(buf) then
		cleanup(buf)
		return
	end
	local w = watchers[buf]
	if not w then
		return
	end
	if events and events.rename then
		-- Atomic replace: re-arm on the new inode first so we don't go deaf.
		vim.defer_fn(function()
			if watchers[buf] then
				restart_watcher(buf, w.path)
			end
		end, DEBOUNCE_MS)
	end
	if w.timer then
		w.timer:stop()
	else
		w.timer = vim.uv.new_timer()
		if not w.timer then
			return
		end
	end
	w.timer:start(DEBOUNCE_MS, 0, function()
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(buf) then
				cleanup(buf)
				return
			end
			if not M.should_reload(vim.bo[buf].modified) then
				throttled_notify(
					buf,
					vim.log.levels.WARN,
					"File changed on disk, but the buffer has unsaved edits — not reloaded. "
						.. "Resolve manually: :w! keeps your edits, :e! takes the disk version.",
					"[sync]"
				)
				return
			end
			-- checktime {buf}: stat + autoread reload without touching windows.
			pcall(vim.cmd, "checktime " .. buf)
		end)
	end)
end

--- Start watching a buffer's file. Idempotent; bounded by MAX_WATCHERS.
---@param buf integer
function M.watch(buf)
	if watchers[buf] then
		return true
	end
	if not is_watchable(buf) then
		return false
	end
	if watcher_count >= MAX_WATCHERS then
		-- Soft degradation: the checktime net below still covers this buffer.
		return false
	end
	local path = vim.api.nvim_buf_get_name(buf)
	local ev = vim.uv.new_fs_event()
	if not ev then
		return false
	end
	local ok = pcall(function()
		ev:start(path, {}, vim.schedule_wrap(function(fs_err, _, events)
			M._on_fs_event(buf, fs_err, events)
		end))
	end)
	if not ok then
		pcall(function()
			ev:stop()
			ev:close()
		end)
		if not failed_once_notified then
			failed_once_notified = true
			vim.notify(
				"[sync] filesystem watcher unavailable — external changes still sync on buffer switch/idle (checktime net)",
				vim.log.levels.INFO,
				{ title = "[sync]" }
			)
		end
		return false
	end
	watchers[buf] = { event = ev, timer = nil, path = path }
	watcher_count = watcher_count + 1
	return true
end

function M.setup()
	local grp = vim.api.nvim_create_augroup("ExternalSync", { clear = true })

	-- Safety net: cheap mtime stats at lifecycle points, no polling loop.
	-- (FocusGained already exists in _wins; repeating it here keeps the
	-- whole sync policy in one auditable place — checktime is idempotent.)
	vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI" }, {
		group = grp,
		pattern = "*",
		desc = "sync: pick up external changes on focus/enter/idle",
		callback = function()
			pcall(vim.cmd, "checktime")
		end,
	})

	-- Event-driven fast path: watch every file buffer, unwatch on close.
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
		group = grp,
		pattern = "*",
		desc = "sync: watch file for external changes",
		callback = function(args)
			M.watch(args.buf)
		end,
	})
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = grp,
		pattern = "*",
		desc = "sync: stop watcher with its buffer",
		callback = function(args)
			cleanup(args.buf)
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = grp,
		pattern = "*",
		desc = "sync: stop all watchers on exit",
		callback = function()
			for buf in pairs(watchers) do
				cleanup(buf)
			end
		end,
	})

	-- Tell the user about the cases autoread cannot resolve silently:
	-- deletions and conflicts. Clean reloads stay quiet on purpose (rapid
	-- agent rewrites would otherwise flood notifications).
	vim.api.nvim_create_autocmd("FileChangedShellPost", {
		group = grp,
		pattern = "*",
		desc = "sync: report deletion/conflict, keep buffer",
		callback = function(args)
			local reason = vim.v.fcs_reason or ""
			local buf = args.buf
			if reason == "deleted" then
				vim.notify(
					"File deleted on disk: " .. vim.fn.fnamemodify(args.file, ":~:.") .. " — buffer kept, nothing lost.",
					vim.log.levels.WARN,
					{ title = "[sync]" }
				)
			elseif reason == "conflict" then
				if vim.api.nvim_buf_is_valid(buf) then
					throttled_notify(
						buf,
						vim.log.levels.WARN,
						"File changed on disk and has unsaved edits — not reloaded. :w! keeps your edits, :e! takes the disk version.",
						"[sync]"
					)
				end
			end
		end,
	})

	-- Watch buffers that already exist at setup time (session restore).
	vim.schedule(function()
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(buf) then
				M.watch(buf)
			end
		end
	end)
end

-- Test hooks (same _test_ convention as dev.inspect).
function M._test_count()
	return watcher_count
end

function M._test_watched(buf)
	return watchers[buf] ~= nil
end

function M._test_reset()
	for buf in pairs(watchers) do
		cleanup(buf)
	end
	last_notify = {}
	failed_once_notified = false
end

return M
