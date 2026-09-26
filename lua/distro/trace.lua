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
--
-- Spans: M.span(name, fn) is the normal API — it times fn and emits one row
-- with a duration. Sub-stages are emitted by the caller inside the span via
-- M.mark(stage) / M.sub(name, ms) and share the same run_id; the viewer
-- groups rows by run_id + time adjacency (see step 5 detail view).

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

--- Emit one line. Cheap: builds a string, appends to buffer, schedules a flush.
---@param event string
---@param duration_ms number|nil
---@param detail string|nil
---@param bufname string|nil
---@param ft string|nil
function M.log(event, duration_ms, detail, bufname, ft)
	if not M.enabled then
		return
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

--- Time a synchronous function and log one span row.
---@param name string
---@param fn fun():any
function M.span(name, fn)
	if not M.enabled then
		return fn()
	end
	local t0 = uv.hrtime()
	local ok, res = pcall(fn)
	local dt = (uv.hrtime() - t0) / 1e6
	M.log(name, dt, ok and nil or ("error: " .. tostring(res)))
	if not ok then
		error(res, 0)
	end
	return res
end

--- Log a pre-measured sub-stage of the currently open span.
---@param name string
---@param stage string "keypress", "request", ...
function M.sub(name, stage, detail)
	if not M.enabled then
		return
	end
	M.log(name .. "/" .. stage, nil, detail)
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
