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

--- Viewer state, keyed by BUFFER handle.
---
--- Was `vim.b[win]`, which is a bug: `vim.b`/`vim.w` are indexed by buffer, and
--- `nvim_open_win` returns a WINDOW id. `win` 1001 is not a buffer, so every
--- read or write raised "scoped variable: Invalid buffer id: 1001" — the
--- viewer could not open at all. Buffer vars would be the wrong tool anyway:
--- the state outlives nothing, and we want it to be reachable from the
--- `<CR>`/`s` callbacks without depending on a live window id.
---@type table<integer, table>
local state = {}

--- Parse one TSV row.
---
--- The first 8 columns are the frozen legacy format; columns 9-14 were added
--- for the action tree and are optional. We split the whole line rather than
--- padding and hard-stopping at 8, so an 8-field log yields nil for the new
--- fields instead of raising, and a 14-field log is read in full (previously the
--- extra columns were silently dropped, so span_id was unreachable).
---@return table|nil
local function parse(line)
	local f = {}
	for part in (line .. "\t"):gmatch("([^\t]*)\t") do
		f[#f + 1] = part
	end
	if not f[1] or f[1] == "" or not tonumber(f[1]) then
		return nil
	end
	local num = function(i)
		local v = f[i]
		return (v and v ~= "-") and tonumber(v) or nil
	end
	return {
		seq = tonumber(f[1]),
		at = tonumber(f[2]) or 0,
		event = f[3] or "?",
		dur = num(4),
		detail = (f[5] ~= "-" and f[5]) or nil,
		buf = (f[6] ~= "-" and vim.fn.fnamemodify(f[6], ":t")) or nil,
		ft = (f[7] ~= "-" and f[7]) or nil,
		run = f[8] or "-",
		-- New, optional.
		span_id = num(9),
		parent_id = num(10),
		own_ms = num(11),
		kind = f[12] or "event",
		async_from = num(13),
		group = (f[14] ~= "-" and f[14]) or nil,
	}
end
M._parse = parse

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

--- Build the action tree from parsed rows.
---
--- The rules, and why each one exists:
---  * A node becomes a CHILD only via `parent_id`, which the writer sets only
---    when the parent frame was provably open in the same Lua call stack
---    (see trace.lua). A stray CursorMoved that fired while gd was waiting for
---    gopls therefore CANNOT be filed under that gd.
---  * A row with `async_from` is shown as its own "happened during <event>"
---    level under the top level, never as a subtree. Time adjacency is never
---    used to guess a parent.
---  * `group` is a link the CALLER wrote (pick_lsp/definition naming its own
---    phases), which is a declaration, not a guess.
---  * Rows with no span data at all (legacy 8-field logs) all stay at the top
---    level, so an old log still opens.
---@param rows table[]
---@return table[] roots
function M.build_tree(rows)
	local by_span, roots, async_of = {}, {}, {}
	for _, r in ipairs(rows) do
		if r.span_id then
			by_span[r.span_id] = r
		end
	end
	for _, r in ipairs(rows) do
		r.children = nil
		r.happened = nil
		r.is_child = nil
		r.happened_parent = nil
		r.own = r.own_ms or r.dur
	end
	-- children by proven parent
	for _, r in ipairs(rows) do
		local p = r.parent_id and by_span[r.parent_id]
		if p and p ~= r then
			p.children = p.children or {}
			p.children[#p.children + 1] = r
			r.is_child = true
		end
	end
	-- declared group members, but only if not already a proven child
	for _, r in ipairs(rows) do
		if r.group and not r.is_child then
			for _, c in ipairs(rows) do
				if c.event == r.group and c.span_id and c.span_id ~= r.span_id then
					c.children = c.children or {}
					c.children[#c.children + 1] = r
					r.is_child = true
					break
				end
			end
		end
	end
	-- "happened during": attributed, but structurally separate
	for _, r in ipairs(rows) do
		if r.async_from and not r.is_child then
			local owner = by_span[r.async_from]
			if owner then
				owner.happened = owner.happened or {}
				owner.happened[#owner.happened + 1] = r
				-- Mark it so it is not ALSO listed as a top-level root: it is
				-- accounted for under its owner, just not as a subtree.
				r.happened_parent = owner
			end
		end
	end
	for _, r in ipairs(rows) do
		if not r.is_child and not r.happened_parent then
			roots[#roots + 1] = r
		end
	end
	-- A row that is both a declared group member AND has children is a root of
	-- its own action; keep roots sorted below.
	for _, r in ipairs(roots) do
		r.depth = 0
	end
	return roots
end

--- Own time for ranking: falls back to dur, then to -1 so untimed events sort
--- last instead of jumping to the top of a "slowest first" list.
---@param r table
---@return number
function M.own_of(r)
	return r.own_ms or r.dur or -1
end

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
	vim.api.nvim_set_hl(0, "DistroTraceTree", { fg = "#6c8ebf" })
	vim.api.nvim_set_hl(0, "DistroTraceAction", { bold = true })
	vim.api.nvim_set_hl(0, "DistroTraceHappened", { fg = "#8a8a8a", italic = true })
	vim.api.nvim_set_hl(0, "DistroTraceSummary", { fg = "#9fd0a0", bold = true })
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
	-- Everything starts collapsed. The complaint being fixed is "I see every
	-- action at once", so the default view is the top level only.
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
	state[b] = { path = path, sort = sort, expanded = {} }

	local function render()
		local rows = M.rows(path, 4000, sort)
		-- Сигнатура лога БЕЗ новой разметки подспанов (старый формат, до 6fa8fde):
		-- НИ ОДНОЙ строки с числовой длительностью. Легаси-лог выглядит как
		-- "правок не было": сортировка по времени уводит все стадии вниз, в сводке
		-- их нет. Помечаем явно, чтобы не читать старый лог как пустой.
		--
		-- ВАЖНО: одного лишь "dur == nil и event со /" мало. Мгновенное событие
		-- нового формата (напр. trace/enable) тоже имеет dur = "-" и event со "/",
		-- и такие события легальны в любом логе. Поэтому метку ставим только когда
		-- НИ ОДНОЙ строки во всём логе не имеет длительности: это отличает старый
		-- формат от нового и не даёт ложного предупреждения на новых логах.
		local timed, slash_nodur = 0, 0
		for _, r in ipairs(rows) do
			if r.dur ~= nil then
				timed = timed + 1
			elseif r.event and r.event:find("/", 1, true) then
				slash_nodur = slash_nodur + 1
			end
		end
		local legacy = (timed == 0 and slash_nodur > 0) and slash_nodur or 0
		local roots = M.build_tree(rows)
		if sort == "time" then
			table.sort(roots, function(a, b)
				return M.own_of(a) > M.own_of(b)
			end)
		end
		-- Legacy 8-field logs carry no span ids at all, so there is no tree to
		-- draw: fall back to the old flat listing rather than showing an empty
		-- screen. Same data, same order, no crash.
		local flat = (legacy > 0)
		-- Headline numbers: what a consumer actually reports.
		local slowest, total, sum = 0, 0, 0
		for _, r in ipairs(rows) do
			local own = M.own_of(r)
			if r.dur and r.dur > 0 then
				total = total + 1
				sum = sum + r.dur
				if r.dur > slowest then
					slowest = r.dur
				end
			end
		end
		local actions = #roots
		local lines = {}
		local slow_names = {}
		for _, r in ipairs(roots) do
			if M.own_of(r) >= SLOW_MS and M.own_of(r) > 0 then
				slow_names[#slow_names + 1] = r.event
			end
		end
		lines[#lines + 1] = string.format(
			"DistroTrace  —  %d action(s) at top level  —  %d row(s) in log  —  total measured %s ms  —  slowest %s ms (%s)",
			actions,
			#rows,
			sum > 0 and string.format("%.2f", sum) or "-",
			slowest > 0 and string.format("%.2f", slowest) or "-",
			#slow_names > 0 and slow_names[1] or "n/a"
		)
		lines[#lines + 1] = string.format("file: %s", path)
		lines[#lines + 1] = string.format(
			"sort: %s   %s   %s   red >= %d ms, yellow >= %d ms",
			sort,
			sort == "time" and "slowest own time first" or "chronological",
			flat and "LEGACY LOG: no span data, flat list" or "own time per node (not cumulative)",
			VERY_SLOW_MS,
			SLOW_MS
		)
		if flat then
			lines[#lines + 1] = string.format(
				"note: this log predates sub-stage timing and span ids (%d rows, no durations); shown as a flat list, not as a tree.",
				legacy
			)
		else
			lines[#lines + 1] = "legend: ▾/▸ expand/collapse   ├─/└─ real nested call (a synchronous Lua frame)   · happened during: NOT a nested call, just an event that arrived in between"
		end
		lines[#lines + 1] = ""
		-- lineno -> node, for <CR>. Rebuilt every render because expansion
		-- changes which lines exist.
		local line_map, meta = {}, {}
		-- An OPT-IN set: a node is expanded only if it is named here. An empty
		-- table therefore means "everything collapsed", which is the required
		-- default. Inverting this to a `collapsed` set made the default the
		-- exact opposite of what the consumer asked for.
		local expanded = state[b].expanded or {}
		local shown = 0

		-- Emit one node and, when expanded, its children.
		-- `guide` is the vertical rail inherited from the ancestors; the
		-- connector itself is drawn per level so the shape reads as a tree
		-- rather than as a list that happens to be indented.
		local function emit(r, depth, is_last, guide, kind_label)
			local kids = r.children or {}
			local happened = r.happened or {}
			local expandable = (#kids + #happened) > 0
			local key = r.span_id or ("s" .. tostring(r.seq))
			local is_open = expandable and expanded[key] == true
			local own = M.own_of(r)
			local mark = "·"
			if expandable then
				mark = is_open and "▾" or "▸"
			end
			local label = r.event
			if kind_label == "happened" then
				-- Said out loud on the row itself: this is NOT a nested call.
				label = "happened during: " .. r.event
			end
			local dur = own >= 0 and string.format("%9.2f ms", own) or string.format("%9s", "instant")
			local connector = depth > 0 and ((is_last and "└─ " or "├─ ") or "") or ""
			local line = string.format("%s%s%s %-34s %s", guide, connector, mark, label, dur)
			if r.detail and r.detail ~= "" then
				line = line .. "  " .. r.detail:sub(1, 44)
			end
			shown = shown + 1
			local idx = #lines + 1
			lines[#lines + 1] = line
			line_map[idx] = r
			meta[#meta + 1] = { row = idx, own = own, depth = depth, kind = kind_label and "h" or "n" }
			if is_open then
				local child_guide = guide
				if depth > 0 then
					child_guide = guide .. (is_last and "    " or "│   ")
				end
				for i, c in ipairs(kids) do
					emit(c, depth + 1, i == #kids, child_guide, nil)
				end
				for i, h in ipairs(happened) do
					emit(h, depth + 1, i == #happened, child_guide, "happened")
				end
			end
		end

		if #roots == 0 then
			lines[#lines + 1] = "(no rows)"
		elseif flat then
			local sorted = vim.deepcopy(rows)
			if sort == "time" then
				table.sort(sorted, function(a, b)
					return M.own_of(a) > M.own_of(b)
				end)
			end
			for _, r in ipairs(sorted) do
				local l = fmt_row(r)
				lines[#lines + 1] = l
			end
		else
			for i, r in ipairs(roots) do
				emit(r, 0, i == #roots, "", nil)
			end
		end
		lines[#lines + 1] = ""
		lines[#lines + 1] = string.format("<Enter> expand/collapse   s sort   e expand all   c collapse all   q close   (%d line(s) shown)", shown)
		vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
		-- Highlight the duration cell of slow nodes, so an anomaly is visible
		-- without reading numbers.
		local ns = vim.api.nvim_create_namespace("distro_trace_hl")
		vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
		for _, m in ipairs(meta) do
			-- The duration cell is the last whitespace-delimited run of the
			-- line: locate it by searching backwards from the detail separator.
			local text = lines[m.row]
			local col = text:find(" ms", 1, true)
			if col then
				-- 9-wide right-aligned number plus the " ms" suffix.
				local s0 = math.max(0, col - 9)
				if m.own >= SLOW_MS then
					vim.api.nvim_buf_add_highlight(
						b,
						ns,
						m.own >= VERY_SLOW_MS and "DistroTraceVerySlow" or "DistroTraceSlow",
						m.row - 1,
						s0,
						col + 3
					)
				end
				if m.kind == "h" then
					vim.api.nvim_buf_add_highlight(b, ns, "DistroTraceHappened", m.row - 1, 0, s0)
				end
			end
		end
		state[b] = { path = path, rows = rows, roots = roots, sort = sort, line_map = line_map, expanded = expanded }
		-- Title shows WHAT is open, per the requirement: which log, how many.
		pcall(vim.api.nvim_win_set_config, win, {
			relative = "editor",
			title = string.format(" DistroTrace — %s — %d actions ", vim.fn.fnamemodify(path, ":t"), actions),
		})
	end
	render()

	local function close()
		pcall(vim.api.nvim_win_close, win, true)
		-- bufhidden=wipe means the buffer outlives nothing, but drop the state
		-- with the window so a re-open cannot inherit a stale path.
		state[b] = nil
	end
	vim.keymap.set("n", "q", close, { buffer = b, nowait = true })
	vim.keymap.set("n", "<Esc>", close, { buffer = b, nowait = true })
	vim.keymap.set("n", "s", function()
		sort = (sort == "time") and "seq" or "time"
		state[b].sort = sort
		render()
		pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
	end, { buffer = b, nowait = true, desc = "trace: toggle sort" })

	-- Expand/collapse. This is the interaction the consumer asked for by name:
	-- start at the top level, press Enter on an action to see its phases.
	vim.keymap.set("n", "<CR>", function()
		local info = state[b]
		local cur = vim.api.nvim_win_get_cursor(0)[1]
		local r = info and info.line_map and info.line_map[cur]
		if not r then
			return
		end
		local kids = #(r.children or {}) + #(r.happened or {})
		if kids == 0 then
			-- Leaf: no subtree to show, so open the raw detail view instead of
			-- silently doing nothing.
			M.detail(info.path, r)
			return
		end
		local key = r.span_id or ("s" .. tostring(r.seq))
		local exp = info.expanded or {}
		exp[key] = not exp[key]
		state[b].expanded = exp
		render()
		-- Keep the cursor on the same node after the line count changes.
		pcall(vim.api.nvim_win_set_cursor, win, { math.min(cur, vim.api.nvim_buf_line_count(b)), 0 })
	end, { buffer = b, nowait = true, desc = "trace: expand/collapse node" })

	vim.keymap.set("n", "e", function()
		local exp = {}
		for _, r in ipairs(state[b].roots or {}) do
			if (r.children and #r.children > 0) or (r.happened and #r.happened > 0) then
				exp[r.span_id or ("s" .. tostring(r.seq))] = true
			end
		end
		state[b].expanded = exp
		render()
		pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
	end, { buffer = b, nowait = true, desc = "trace: expand all" })
	vim.keymap.set("n", "c", function()
		state[b].expanded = {}
		render()
		pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
	end, { buffer = b, nowait = true, desc = "trace: collapse all" })
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
			x.dur and ("(own dur %.3f)"):format(x.dur) or ""
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
