-- distro.traceui — viewer for the trace log.
--
-- Reads the log by line offset, never slurping the whole file into memory:
-- a long session produces tens of thousands of rows and building a full
-- index of them in one go is itself a visible stall (and the thing we are
-- trying to measure). We page backwards from the end of the file.
--
-- Sort is by duration, longest first — that is the only ordering that answers
-- "what is slow here".

local M = {}

local PAGE = 200

--- Parse one TSV row.
---@return table|nil
local function parse(line)
	local f = {}
	local n = 0
	for part in (line .. "\t\t\t\t\t\t\t"):gmatch("([^\t]*)\t?") do
		n = n + 1
		if n > 8 then
			break
		end
		f[n] = part
	end
	if not f[1] or f[1] == "" or not tonumber(f[1]) then
		return nil
	end
	return {
		seq = tonumber(f[1]),
		at = tonumber(f[2]) or 0,
		event = f[3] or "?",
		dur = tonumber(f[4]),
		detail = (f[5] ~= "-" and f[5]) or nil,
		buf = (f[6] ~= "-" and vim.fn.fnamemodify(f[6], ":t")) or nil,
		ft = (f[7] ~= "-" and f[7]) or nil,
		run = f[8] or "-",
	}
end

--- Read the last `limit` lines of a file, without loading the whole file.
--- Uses a reverse chunk read: seek to EOF, walk backwards in 64KB blocks.
---@return string[] lines (in file order)
local function tail_lines(path, limit)
	local uv = vim.uv or vim.loop
	local fd = uv.fs_open(path, "r", 420)
	if not fd then
		return {}
	end
	local size = uv.fs_fstat(fd).size or 0
	local CHUNK = 65536
	local pos = size
	local carry = ""
	local acc = {}
	local want = limit
	while pos > 0 and want > 0 do
		local start = math.max(0, pos - CHUNK)
		local len = pos - start
		local data = uv.fs_read(fd, len, start)
		if not data or #data == 0 then
			break
		end
		local blob = data .. carry
		local parts = {}
		for l in (blob .. "\n"):gmatch("([^\n]*)\n") do
			parts[#parts + 1] = l
		end
		-- last element may be a partial line (continues before this chunk)
		carry = table.remove(parts) or ""
		for i = #parts, 1, -1 do
			if parts[i] ~= "" then
				acc[#acc + 1] = parts[i]
				want = want - 1
				if want == 0 then
					break
				end
			end
		end
		pos = start
	end
	if carry ~= "" and want > 0 then
		acc[#acc + 1] = carry
	end
	pcall(uv.fs_close, fd)
	local out = {}
	for i = #acc, 1, -1 do
		out[#out + 1] = acc[i]
	end
	return out
end
M._tail_lines = tail_lines

--- Rows of the current log.
--- sort: "time" (default) — longest duration first, the ordering that answers
--- "what is slow here"; "seq" — chronological, the ordering that reads as a
--- flow of events. Both are needed: a slow hop hides in chronological order,
--- and unrelated background events bury it in duration order.
---@param sort "time"|"seq"
---@return table[]
function M.rows(path, limit, sort)
	local raws = tail_lines(path, limit or 2000)
	local rows = {}
	for _, l in ipairs(raws) do
		local r = parse(l)
		if r then
			rows[#rows + 1] = r
		end
	end
	if sort == "seq" then
		table.sort(rows, function(a, b)
			return a.seq < b.seq
		end)
	else
		table.sort(rows, function(a, b)
			return (a.dur or -1) > (b.dur or -1)
		end)
	end
	return rows
end

M.SORTS = { "time", "seq" }

--- Anomaly thresholds, ms. Slow >= SLOW, very slow >= VERY_SLOW.
local SLOW_MS, VERY_SLOW_MS = 50, 200

--- Highlight groups. Created lazily so importing this module has no side
--- effect on a session that never opens the viewer.
local hl_defined = false
local function ensure_hl()
	if hl_defined then
		return
	end
	hl_defined = true
	vim.api.nvim_set_hl(0, "DistroTraceSlow", { fg = "#e0a030", bold = true })
	vim.api.nvim_set_hl(0, "DistroTraceVerySlow", { fg = "#ff5f5f", bold = true })
	vim.api.nvim_set_hl(0, "DistroTraceHead", { bold = true, reverse = true })
	vim.api.nvim_set_hl(0, "DistroTraceSub", { italic = true })
end

--- One row. Returns the rendered line and the duration in ms (or nil) so the
--- caller can highlight it. Both `at` (cumulative, ms since process start) and
--- `dur` (own cost) are shown: sub-stages are cumulative, so the delta between
--- neighbouring rows is the phase, and hiding `at` made that unreadable.
---@return string line, number|nil dur
local function fmt_row(r)
	local dur = r.dur and string.format("%9.2f", r.dur) or string.format("%9s", "-")
	local line = string.format("#%-5d %s ms  at %9.2f  %-34s %-6s %s", r.seq, dur, r.at, r.event, r.ft or "-", r.buf or "")
	if r.detail and r.detail ~= "" then
		line = line .. "  " .. r.detail:sub(1, 46)
	end
	return line, r.dur
end

local function buf_of(lines, ft)
	local b = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(b, "modifiable", false)
	vim.api.nvim_buf_set_option(b, "filetype", ft or "distro-trace")
	vim.api.nvim_buf_set_option(b, "bufhidden", "wipe")
	return b
end

local function float(b, title, height)
	local h = math.min(height or (#vim.api.nvim_buf_get_lines(b, 0, -1, false)), vim.o.lines - 4)
	return vim.api.nvim_open_win(b, true, {
		relative = "editor",
		width = math.min(120, vim.o.columns - 6),
		height = h,
		row = 1,
		col = math.max(0, (vim.o.columns - 120) / 2),
		style = "minimal",
		border = "rounded",
		title = " " .. title .. " ",
	})
end

--- Main view. sort: "time" (longest first) or "seq" (chronological).
function M.open(path, sort)
	ensure_hl()
	path = path or require("distro.trace").path
	if not path or vim.fn.filereadable(path) == 0 then
		vim.notify("No trace log yet — :DistroTrace on first", vim.log.levels.WARN, { title = "trace" })
		return
	end
	sort = sort or "time"
	local b = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(b, true, {
		relative = "editor",
		width = math.min(150, vim.o.columns - 6),
		height = math.min(40, vim.o.lines - 4),
		row = 1,
		col = math.max(0, (vim.o.columns - 150) / 2),
		style = "minimal",
		border = "rounded",
		title = " DistroTrace ",
	})
	vim.b[win].distro_trace = { path = path }

	local function render()
		local rows = M.rows(path, 4000, sort)
		local slowest, total = 0, 0
		local lines = {
			string.format("DistroTrace — %d rows (tail) — sort: %s%s", #rows, sort, sort == "time" and "  (slowest first)" or "  (chronological)"),
			string.format("file: %s", path),
		}
		-- Headline numbers: what a consumer actually reports.
		for _, r in ipairs(rows) do
			if r.dur and r.dur > 0 then
				total = total + 1
				if r.dur > slowest then
					slowest = r.dur
				end
			end
		end
		lines[#lines + 1] = string.format("slowest event: %s ms   measured: %d   red >= %d ms, yellow >= %d ms", slowest > 0 and string.format("%.2f", slowest) or "-", total, VERY_SLOW_MS, SLOW_MS)
		lines[#lines + 1] = ""
		lines[#lines + 1] = "        duration      at  event                             ft     buffer"
		if #rows == 0 then
			lines[#lines + 1] = "(no rows)"
		end
		local durs = {}
		for _, r in ipairs(rows) do
			local line, dur = fmt_row(r)
			lines[#lines + 1] = line
			durs[#durs + 1] = dur
		end
		lines[#lines + 1] = ""
		lines[#lines + 1] = "<Enter> details   s — switch sort (time/seq)   q — close"
		vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
		-- Highlight the duration cell of slow rows, so an anomaly is visible
		-- without reading numbers.
		local ns = vim.api.nvim_create_namespace("distro_trace_hl")
		vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
		for i, dur in ipairs(durs) do
			if dur and dur >= SLOW_MS then
				vim.api.nvim_buf_add_highlight(b, ns, vim.api.nvim_str_byteindex(b, i, 0, false), vim.api.nvim_str_byteindex(b, i, 0, false), dur >= VERY_SLOW_MS and "DistroTraceVerySlow" or "DistroTraceSlow")
			end
		end
		vim.b[win].distro_trace = { path = path, rows = rows, sort = sort }
	end
	render()

	local function close()
		pcall(vim.api.nvim_win_close, win, true)
	end
	vim.keymap.set("n", "q", close, { buffer = b, nowait = true })
	vim.keymap.set("n", "<Esc>", close, { buffer = b, nowait = true })
	vim.keymap.set("n", "s", function()
		sort = (sort == "time") and "seq" or "time"
		render()
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
	end, { buffer = b, nowait = true, desc = "trace: toggle sort" })
	vim.keymap.set("n", "<CR>", function()
		local info = vim.b[win].distro_trace
		local r = info.rows and info.rows[vim.api.nvim_win_get_cursor(0)[1] - 7]
		if r then
			M.detail(info.path, r)
		end
	end, { buffer = b, nowait = true })
	return win
end

--- Detail view for one span: full row + nearby rows of the same run.
function M.detail(path, r)
	-- Sub-stages: rows of the same run emitted inside [r.at - r.dur, r.at].
	local raws = tail_lines(path, 4000)
	local all = {}
	for _, l in ipairs(raws) do
		local x = parse(l)
		if x then
			all[#all + 1] = x
		end
	end
	local subs = {}
	if r.dur then
		local lo, hi = r.at - r.dur - 1, r.at + 1
		for _, x in ipairs(all) do
			if x.run == r.run and x.at >= lo and x.at <= hi and x.seq ~= r.seq then
				subs[#subs + 1] = x
			end
		end
		table.sort(subs, function(a, b)
			return a.seq < b.seq
		end)
	end
	local lines = {
		"=== span ===",
		string.format("  seq        #%d", r.seq),
		string.format("  event      %s", r.event),
		string.format("  duration   %s", r.dur and string.format("%.3f ms", r.dur) or "n/a (instant event)"),
		string.format("  at         %.3f ms (monotonic, since process start)", r.at),
		string.format("  run_id     %s", r.run),
		string.format("  buffer     %s", r.buf or "-"),
		string.format("  filetype   %s", r.ft or "-"),
		string.format("  detail     %s", r.detail or "-"),
		"",
		string.format("=== phases in window (%d) ===", #subs),
	}
	if #subs == 0 then
		lines[#lines + 1] = "(none recorded)"
	end
	-- Sub-stage rows are CUMULATIVE (ms since the span started), so the phase
	-- cost is the difference from the previous row — printing the raw value
	-- made every phase look like it cost the full span. The delta column is
	-- what actually answers "where did the time go".
	local prev_at = (r.at - (r.dur or 0))
	local sub_durs = {}
	for _, x in ipairs(subs) do
		local delta = x.at - prev_at
		prev_at = x.at
		sub_durs[#sub_durs + 1] = { delta = delta, event = x.event }
		lines[#lines + 1] = string.format(
			"  cum %8.3f  Δ %8.3f ms  %-38s %s",
			x.at - r.at + (r.dur or 0),
			delta,
			x.event,
			x.dur and string.format("(own dur %.3f)" % x.dur) or ""
		)
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "q — назад"
	local b = buf_of(lines)
	local win = float(b, "DistroTrace span", #lines)
	vim.keymap.set("n", "q", function()
		pcall(vim.api.nvim_win_close, win, true)
	end, { buffer = b, nowait = true })
	vim.keymap.set("n", "<Esc>", function()
		pcall(vim.api.nvim_win_close, win, true)
	end, { buffer = b, nowait = true })
end

--- Text summary for :DistroTrace report (no float).
---@return string
function M.report(path, n)
	local trace = require("distro.trace")
	path = path or trace.path
	if not path or vim.fn.filereadable(path) == 0 then
		return "No trace log yet — :DistroTrace on"
	end
	local rows = M.rows(path, 2000)
	local out = {
		string.format("DistroTrace report — %d rows (tail), longest first", #rows),
		string.format("file: %s", path),
		"",
	}
	for i = 1, math.min(n or 15, #rows) do
		out[#out + 1] = fmt_row(rows[i])
	end
	return table.concat(out, "\n")
end

M.PAGE = PAGE
return M
