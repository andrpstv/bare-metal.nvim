-- distro.trace — append-only, async, batched action tracing.
--
-- Design constraints (all verified, do not "optimize" away):
--   * M.enabled defaults to FALSE. Every hook starts with `if not M.enabled then
--     return end` so the disabled cost is one table index.
--   * Nothing is ever written synchronously. Autocmds fire inside the event
--     loop; a blocking write there stalls the UI for the length of the fs call.
--     Lines are buffered in memory and flushed on vim.schedule via
--     vim.uv.fs_open/fs_write.
--   * No vim.notify per line. Notification on every event is a stall and a
--     wall of spam.
--   * Log file: stdpath("cache")/distro-trace/distro-trace-<run_id>.log
--     One file per run_id (hrtime at enable), append-only inside it.
--
-- Line format (tab separated, no tabs/newlines allowed in fields):
--   seq \t monotonic_ms \t event \t duration_ms \t detail \t buffer \t filetype \t run_id
--        \t span_id \t parent_id \t own_ms \t kind \t async_from \t group
--
-- The first 8 columns are FROZEN. Logs written by older builds sit on consumer
-- HDD and must keep opening; new columns are appended right and are optional —
-- a missing tail simply means "this log predates spans".
--
-- Spans: M.span(name, fn) is the normal API — it times fn and emits one row
-- with a duration. Sub-stages are emitted by the caller inside the span via
-- M.sub(name, stage, ms).
--
-- ON HONESTY OF THE PARENT (see docs/distro/21-trace-tree-design.md §1):
-- parent_id is written ONLY when the parent frame is provably on the stack in
-- this very Lua frame — i.e. a real synchronous call nesting. Everything else
-- (a CursorMoved that happened while a gd was waiting for gopls, an LSP
-- response callback, a scheduled callback) is NOT a child: it gets
-- kind="event" plus async_from=<span_id> and the viewer draws it as a
-- separate "happened during" level, never as a subtree. Time adjacency is
-- never used to invent a parent — it is exactly the mechanism that puts an
-- unrelated CursorMoved under the wrong gd.

local M = {}

M.enabled = false

local uv = vim.uv or vim.loop

local dir = (function()
	local d = vim.fn.stdpath("cache") .. "/distro-trace"
	vim.fn.mkdir(d, "p")
	return d
end)()

--- Current run id — set on enable, cleared on disable.
M.run_id = nil

--- Wall origin for monotonic_ms, in nanoseconds.
local origin = uv.hrtime()

--- Monotonic milliseconds since process start (not unix time; no clock jumps).
---@return number
function M.now_ms()
	return (uv.hrtime() - origin) / 1e6
end

--- Unsorted (sequence) counter.
local seq = 0
--- Buffered lines, flushed on schedule.
local buf = {}
--- Set while a flush is scheduled/queued.
local flush_scheduled = false
--- Open fd cache for the current run file.
local fd = nil
--- Current log path.
M.path = nil

local function sanitize(s, n)
	if s == nil then
		return "-"
	end
	s = tostring(s):gsub("[\t\r\n]", " ")
	return #s > (n or 200) and s:sub(1, n or 200) .. "…" or s
end

--- Open frames, innermost last. A frame is pushed only by M.begin, i.e. only
--- around a real synchronous call, so "stack top" is a fact and not a guess.
---@type {id:number, name:string, t0:number}[]
local frames = {}

--- A frame older than this is assumed leaked (a span that never closed) and is
--- dropped, so a stuck span cannot adopt the rest of the session as children.
local STALE_MS = 2000

--- Next span id within a run.
local next_span = 0

--- Last cumulative value per sub-stage group, for own_ms.
local last_cum = {}

--- Drop frames that have outlived STALE_MS (and anything stacked under them).
local function prune(now)
	while #frames > 0 and (now - frames[#frames].t0) > STALE_MS * 1e6 do
		frames[#frames] = nil
	end
end

--- Id of the provably-current parent, or nil.
---@return number|nil
local function current_parent()
	local f = frames[#frames]
	return f and f.id or nil
end

--- Emit one line. Cheap: builds a string, appends to buffer, schedules a flush.
---@param event string
---@param duration_ms number|nil
---@param detail string|nil
---@param bufname string|nil
---@param ft string|nil
---@param extra table|nil {span_id,parent_id,own_ms,kind,async_from,group}
function M.log(event, duration_ms, detail, bufname, ft, extra)
	if not M.enabled then
		return
	end
	if not extra then
		-- A plain instantaneous event (CursorMoved, BufEnter, FileType...). If a
		-- span frame is open right now, the event fired while that work was in
		-- flight. It is NOT a child of it — it is an unrelated event that
		-- happened to arrive in between. Record the link as async_from so the
		-- viewer can show "happened during" without drawing a subtree.
		extra = { kind = "event", async_from = current_parent() }
	end
	seq = seq + 1
	buf[#buf + 1] = table.concat({
		tostring(seq),
		string.format("%.3f", M.now_ms()),
		sanitize(event, 60),
		duration_ms and string.format("%.3f", duration_ms) or "-",
		sanitize(detail, 300) or "-",
		sanitize(bufname, 120) or "-",
		sanitize(ft, 40) or "-",
		M.run_id or "-",
		extra.span_id and tostring(extra.span_id) or "-",
		extra.parent_id and tostring(extra.parent_id) or "-",
		extra.own_ms and string.format("%.3f", extra.own_ms) or "-",
		extra.kind or "event",
		extra.async_from and tostring(extra.async_from) or "-",
		extra.group and sanitize(extra.group, 60) or "-",
	}, "\t")
	if #buf >= 256 then
		M.flush()
	elseif not flush_scheduled then
		flush_scheduled = true
		vim.schedule(function()
			flush_scheduled = false
			M.flush()
		end)
	end
end

--- Open a span. Returns its id (a number) to pass to M.end_span, or nil when
--- tracing is off. Prefer M.span, which pairs the two.
---@param name string
---@return number|nil
function M.begin(name)
	if not M.enabled then
		return nil
	end
	local now = uv.hrtime()
	prune(now)
	next_span = next_span + 1
	local id = next_span
	frames[#frames + 1] = { id = id, name = name, t0 = now }
	return id
end

--- Id of the innermost open frame, or nil. Callers use it to close the frame
--- they opened without having to carry the id across an async boundary.
---@return number|nil
function M.current_span()
	local f = frames[#frames]
	return f and f.id or nil
end

--- Close a span opened by M.begin and emit its row.
---@param id number
---@param name string
---@param detail string|nil
function M.end_span(id, name, detail)
	if not M.enabled or not id then
		return
	end
	local now = uv.hrtime()
	-- Pop until our frame is on top: a leaked inner frame must not orphan us.
	local i = #frames
	while i > 0 and frames[i].id ~= id do
		i = i - 1
	end
	-- Read t0 and the parent BEFORE popping: after the pop our own frame is
	-- gone and the elapsed time is unrecoverable.
	local t0 = i > 0 and frames[i].t0 or nil
	local parent_id = nil
	if i > 0 then
		-- Our real caller frame is the one below ours.
		parent_id = i > 1 and frames[i - 1].id or nil
		for k = #frames, i, -1 do
			frames[k] = nil
		end
	end
	-- i == 0 means our frame was already pruned as stale, so its t0 is gone.
	-- A nil duration is honest; a fabricated 0 is not.
	local dt = t0 and (now - t0) / 1e6 or nil
	M.log(name, dt, detail, nil, nil, {
		span_id = id,
		parent_id = parent_id,
		kind = "span",
	})
end

--- Time a synchronous function and log one span row.
---@param name string
---@param fn fun():any
function M.span(name, fn)
	if not M.enabled then
		return fn()
	end
	local id = M.begin(name)
	local ok, res = pcall(fn)
	-- ВНИМАНИЕ, здесь была ошибка: `ok and nil or ("error: "..res)` из-за
	-- приоритета `and/or` даёт "error: ..." ПРИ УСПЕХЕ (ok=true -> (ok and nil)=nil
	-- -> nil or X = X). Каждый успешный спан писал в detail строку "error: true".
	-- Поэтому только через явную ветку, а не тернарником.
	local detail = nil
	if not ok then
		detail = "error: " .. tostring(res)
	end
	M.end_span(id, name, detail)
	if not ok then
		error(res, 0)
	end
	return res
end

--- Log a pre-measured sub-stage of the currently open span.
---
--- The elapsed value goes into the DURATION column, not into a detail string.
--- That distinction decides everything downstream: the viewer sorts by
--- duration, so a sub-stage whose timing lives in `detail` has dur=nil and
--- sorts to the BOTTOM of a "longest first" list, buried under events that
--- legitimately took no time. That is how a 14 ms hop ended up ranked below a
--- 0.1 ms dispatch.
--- Phases live in the CUMULATIVE ms column (field 4) and stay there: that is
--- the field the legacy detail view and legacy logs read, and the delta shown
--- next to it is what answers "where did the time go". The NEW own_ms column
--- (field 11) carries the phase's own cost, computed here as the difference to
--- the previous phase of the same group. Sorting by own_ms therefore ranks
--- phases by what they actually cost, instead of ranking cumulative marks of
--- different magnitudes against each other — the known defect this replaces.
---
--- `group` links the phase to the span named `name`. It is a declared link
--- written by the caller, not a time-inferred one: the viewer attaches the row
--- to the span whose event equals that name.
---@param name string
---@param stage string "keypress_to_request", "request_to_response", ...
---@param ms number|nil elapsed ms since the parent span started
---@param detail string|nil
function M.sub(name, stage, ms, detail)
	if not M.enabled then
		return
	end
	local own = nil
	if ms then
		own = ms - (last_cum[name] or 0)
		last_cum[name] = ms
	end
	M.log(name .. "/" .. stage, ms, detail, nil, nil, {
		own_ms = own,
		kind = "sub",
		group = name,
	})
end

--- Write buffered lines. Async: fs_open + fs_write, never blocking syscalls.
function M.flush()
	if #buf == 0 then
		return
	end
	local payload = table.concat(buf, "\n") .. "\n"
	buf = {}
	if not M.enabled or not M.path then
		return
	end
	if not fd then
		fd = uv.fs_open(M.path, "a", 438) -- 0666
		if not fd then
			return
		end
	end
	uv.fs_write(fd, payload, -1)
end

--- Start tracing. Returns the log path.
---@return string
function M.enable()
	if M.enabled then
		return M.path
	end
	M.run_id = string.format("%d", uv.hrtime() % 1e12)
	M.path = string.format("%s/distro-trace-%s.log", dir, M.run_id)
	M.enabled = true
	seq = 0
	buf = {}
	frames = {}
	last_cum = {}
	next_span = 0
	M.log("trace/enable", nil, "pid=" .. tostring(vim.fn.getpid()))
	M.flush()
	return M.path
end

--- Stop tracing (flushes first so the tail is not lost).
function M.disable()
	if not M.enabled then
		return
	end
	M.log("trace/disable", nil, "lines=" .. tostring(#buf + seq))
	M.flush()
	M.enabled = false
	if fd then
		pcall(uv.fs_close, fd)
		fd = nil
	end
end

function M.toggle()
	if M.enabled then
		M.disable()
		return false
	end
	M.enable()
	return true
end

--- All log files, newest first.
function M.logs()
	local out = {}
	local scan = uv.fs_scandir(dir)
	if not scan then
		return out
	end
	while true do
		local name = uv.fs_scandir_next(scan)
		if not name then
			break
		end
		if name:match("^distro%-trace%-.*%.log$") then
			local p = dir .. "/" .. name
			local st = uv.fs_stat(p)
			out[#out + 1] = { path = p, mtime = st and st.mtime and st.mtime.sec or 0 }
		end
	end
	table.sort(out, function(a, b)
		return a.mtime > b.mtime
	end)
	return out
end

function M.clear()
	M.flush()
	for _, f in ipairs(M.logs()) do
		pcall(uv.fs_unlink, f.path)
	end
	return #M.logs()
end

return M
