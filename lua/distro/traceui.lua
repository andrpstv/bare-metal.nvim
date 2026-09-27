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
---  * kind=action is the node the consumer asked about. It carries the FULL
---    end-to-end time of the action (keypress -> response -> cursor), so it is
---    the TOP node, and the synchronous span frame of the same name plus every
---    `group` phase hang under it. Filing the action row under the synchronous
---    span instead — which is what the pure `group` rule did, because the span
---    is the only row of that name carrying a span_id — made the viewer lead
---    with the cost of *sending* the request (4.24 ms) for an action that really
---    took 343 ms. That is the same off-by-80x defect we already fixed twice.
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
		r.is_action = (r.kind == "action")
		-- An action node has no writer-side own cost column filled: the log
		-- format predates it for kind=action. Leaving it "-" ranked the node as
		-- "untimed" against every phase that did carry own_ms, so filling it
		-- with the action's full dur keeps sorting and display consistent.
		if r.is_action and not r.own_ms and r.dur then
			r.own_ms = r.dur
		end
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
	-- Declared group members, but only if not already a proven child.
	-- The owner of a group is the row of that name that ANSWERS THE QUESTION:
	-- the kind=action row when there is one (full end-to-end time), otherwise
	-- the synchronous span frame. Falling back unconditionally to the span —
	-- the only row of that name that has a span_id — is exactly what buried the
	-- action total under a 4 ms dispatch frame.
	for _, r in ipairs(rows) do
		if r.group and not r.is_child and not r.is_action then
			local owner
			-- Prefer the kind=action row: it is the row that answers "how long
			-- did this take", so the phases belong directly under it and its
			-- arithmetic adds up. Fall back to the synchronous span frame for
			-- groups that have no action row at all.
			for _, c in ipairs(rows) do
				if c.event == r.group and c.is_action then
					owner = c
					break
				end
			end
			if not owner then
				for _, c in ipairs(rows) do
					if c.event == r.group and not c.is_action and c.span_id and c.span_id ~= r.span_id then
						owner = c
						break
					end
				end
			end
			if owner then
				owner.children = owner.children or {}
				owner.children[#owner.children + 1] = r
				r.is_child = true
			end
		end
	end
	-- The synchronous span frame of an action becomes a child of that action:
	-- the action row is the same action measured honestly end to end, so the
	-- frame is a detail of it, not the node the viewer leads with. The action
	-- row is skipped in the loop above precisely to keep this from becoming a
	-- cycle (action is the span's parent AND the span's child -> both roots
	-- disappear and the action vanishes from the viewer entirely).
	for _, r in ipairs(rows) do
		if r.is_action then
			for _, c in ipairs(rows) do
				if not c.is_action and c.event == r.event and c.span_id and not c.is_child then
					r.children = r.children or {}
					table.insert(r.children, 1, c)
					c.is_child = true
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
	-- An action row is the answer to "how long did that take", so it is always a
	-- root even if something already claimed it: a top level that shows 4 ms
	-- for a 343 ms action is the defect, not the nesting. Detach it from
	-- whatever claimed it first, so nothing can hide the action.
	for _, r in ipairs(rows) do
		if r.is_action and r.happened_parent then
			r.happened_parent = nil
			roots[#roots + 1] = r
		end
		if r.is_action and r.is_child then
			for _, p in ipairs(rows) do
				local kids = p.children
				if kids then
					for i = #kids, 1, -1 do
						if kids[i] == r then
							table.remove(kids, i)
						end
					end
					if #kids == 0 then
						p.children = nil
					end
				end
			end
			r.is_child = false
			roots[#roots + 1] = r
		end
	end
	for _, r in ipairs(roots) do
		r.depth = 0
	end
	-- Children are ordered by seq, ALWAYS. They inherit insertion order, which
	-- comes from the row list, and that list is re-sorted by duration in "time"
	-- mode — so without this a node's phases printed as 3.88 + 1.32 + 27.95,
	-- the second phase before the first, and the sum became unreadable. The
	-- order of a node's own phases is a property of the run, not of the sort.
	local function by_seq(list)
		table.sort(list, function(a, b)
			return a.seq < b.seq
		end)
		return list
	end
	for _, r in ipairs(rows) do
		if r.children then
			by_seq(r.children)
		end
		if r.happened then
			by_seq(r.happened)
		end
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

--- The number to PRINT next to a node — which is not always own_ms.
---
--- Top level and action nodes show the FULL time of the action: the person
--- pressed a key and wants the wall time until the cursor moved, not the cost
--- of the synchronous frame. Details (phases) show own_ms, because there
--- "cost of this phase alone" is both true and the useful question.
---@param r table
---@param depth integer
---@return number
function M.cost_of(r, depth)
	if r.kind == "action" then
		return r.dur or -1
	end
	if (depth or 0) == 0 then
		return r.dur or r.own_ms or -1
	end
	return r.own_ms or r.dur or -1
end

--- "332.09 + 7.17 + 4.23 (sync dispatch) = 343.49" — the arithmetic behind a
--- node's total.
---
--- Only kind="sub" rows are ADDED: they are the disjoint phases (own_ms = cost
--- of that phase alone), so their sum is the time the action really spent
--- waiting. The synchronous span frame is NOT added: it measures the same
--- keypress->dispatch window as the first phase, so including it would double
--- count. Its cost is printed as an explicit remainder instead, which is what
--- makes the printed equation literally true and auditable rather than a
--- plausible-looking sum.
---@param r table
---@param depth integer
---@return string|nil
function M.phase_sum(r, depth)
	local kids = r.children or {}
	if (depth or 0) > 0 or #kids == 0 then
		return nil
	end
	local parts, sum = {}, 0
	for _, c in ipairs(kids) do
		if c.kind == "sub" then
			local ms = M.cost_of(c, 1)
			if ms and ms >= 0 then
				parts[#parts + 1] = string.format("%.2f", ms)
				sum = sum + ms
			end
		end
	end
	if #parts == 0 then
		return nil
	end
	local total = M.cost_of(r, 0)
	local rest = total - sum
	local eq = "= " .. table.concat(parts, " + ")
	if rest > 0.05 then
		eq = eq .. string.format(" + %.2f (sync dispatch)", rest)
	elseif rest < -0.05 then
		eq = eq .. string.format(" - %.2f (overlap)", -rest)
	end
	return string.format("%s = %.2f", eq, total)
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
		--
		-- "slowest" MUST be derived from the list the user is looking at, i.e.
		-- from `roots` after the current sort, with the SAME value the row
		-- prints. It used to be a max over every row by raw dur, so the header
		-- could name one event while the first line of the list showed another
		-- with a different magnitude — the exact "the summary and the list
		-- disagree" defect.
		local total, sum = 0, 0
		for _, r in ipairs(rows) do
			if r.dur and r.dur > 0 then
				total = total + 1
				sum = sum + r.dur
			end
		end
		local top = roots[1]
		local top_cost = top and M.cost_of(top, 0) or -1
		local actions = #roots
		local lines = {}
		-- The label follows the sort: under "time" the first row really is the
		-- slowest, under "seq" it is merely the first in time and may well have
		-- no duration at all. Calling that row "slowest" is the same summary/list
		-- disagreement, only with a different word in it.
		lines[#lines + 1] = string.format(
			"DistroTrace  —  %d action(s) at top level  —  %d row(s) in log  —  total measured %s ms  —  %s %s ms (%s)",
			actions,
			#rows,
			sum > 0 and string.format("%.2f", sum) or "-",
			sort == "time" and "slowest" or "first",
			top_cost > 0 and string.format("%.2f", top_cost) or "-",
			top and top.event or "n/a"
		)
		lines[#lines + 1] = string.format("file: %s", path)
		lines[#lines + 1] = string.format(
			"sort: %s   %s   %s   red >= %d ms, yellow >= %d ms",
			sort,
			sort == "time" and "slowest own time first" or "chronological",
			flat and "LEGACY LOG: no span data, flat list" or "top level = full action time, children = phase own_ms",
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
			lines[#lines + 1] = "        TOP LEVEL number = FULL time of the action (keypress -> cursor), what you actually waited.   CHILD number = own_ms = cost of that phase alone.   The two are different quantities; an action's own_ms column is its full dur."
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
			local own = M.cost_of(r, depth)
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
			-- An expanded top-level action always shows its arithmetic: without
			-- it a 343 ms total is a number the reader cannot audit.
			if is_open then
				local eq = M.phase_sum(r, depth)
				if eq then
					line = line .. "   [ " .. eq .. " ]"
				end
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
		string.format("=== rows in window (%d) ===", #subs),
	}
	if #subs == 0 then
		lines[#lines + 1] = "(none recorded)"
	else
		lines[#lines + 1] = "  own = this row's own cost (log field 11).  gap = wall-clock"
		lines[#lines + 1] = "  since the previous row — it belongs to NO row: waiting, not work."
		lines[#lines + 1] = "  [idle] rows are instant events that happened during the span; they"
		lines[#lines + 1] = "  are listed, because the tracer records them on purpose"
		lines[#lines + 1] = "  (trace.lua:242-256), but no cost is ever charged to them."
	end
	-- A row's cost is NOT the difference to the previous row. That difference is
	-- the wall-clock GAP between two rows, and it belongs to neither of them: it
	-- is time in which the emitter recorded nothing. Printing it as the row's
	-- cost made an instant event (dur=nil) swallow the whole idle in front of
	-- it, while the row that was really waiting showed a near-zero cost — the
	-- card then claimed "autocommands ate 4.5 s" about an autocommand that
	-- waited for nothing. On distro-trace-484230425125 that was CursorMoved
	-- charged 4478.898 ms while the real work, request_to_response, showed
	-- 433.717 ms for its own 5237.924 ms.
	--
	-- So: own is the row's own cost, read from log field 11 (own_ms) under its
	-- real name; gap is idle since the previous row, shown for timed rows only
	-- and never charged to anybody. Instant events are kept and marked, not
	-- dropped — dropping them would lose the "happened during" distinction the
	-- tracer goes out of its way to record.
	--
	-- own_ms can be negative in the log (seq 114 = -9.674, seq 124 =
	-- -4803.995). That is an emiter defect belonging to Lane B; this label no
	-- longer conceals it behind a cumulative number.
	local prev_at = r.at - r.dur
	local own_sum, work_idle, idle_idle = 0.0, 0.0, 0.0
	for _, x in ipairs(subs) do
		local gap = x.at - prev_at
		prev_at = x.at
		local instant = (x.dur == nil)
		local note = ""
		if instant then
			idle_idle = idle_idle + gap
			note = x.async_from and ("(happened during #%d — no work of its own)"):format(x.async_from)
				or "(happened during — no work of its own)"
		else
			work_idle = work_idle + gap
		end
		own_sum = own_sum + (x.own_ms or 0)
		lines[#lines + 1] = string.format(
			"  %-4s own %9s  gap %9s  #%-5d %-38s %s",
			instant and "idle" or "work",
			x.own_ms and ("%.3f"):format(x.own_ms) or "—",
			instant and "—" or ("%.3f ms"):format(gap),
			x.seq,
			x.event,
			note
		)
	end
	if #subs > 0 then
		-- The tail used to be dropped without a word: prev_at stopped at the
		-- last row and the remainder of the window was simply never printed.
		-- It belongs to no row either, so it is now stated out loud.
		local tail = r.at - prev_at
		lines[#lines + 1] = ""
		lines[#lines + 1] = "  --- accounting (no interval is silently dropped) ---"
		lines[#lines + 1] = string.format("  span wall-clock   %11.3f ms", r.dur)
		lines[#lines + 1] = string.format("  own_ms total      %11.3f ms  (sum over timed rows, field 11)", own_sum)
		lines[#lines + 1] = string.format("  idle before work  %11.3f ms  (charged to no row)", work_idle)
		lines[#lines + 1] = string.format("  idle before idle  %11.3f ms  (charged to no row)", idle_idle)
		if tail >= 0 then
			lines[#lines + 1] = string.format("  tail after last   %11.3f ms  (to end of span, charged to no row)", tail)
		else
			-- The window runs to r.at + 1, so rows emitted in that last
			-- millisecond fall inside it. Say so rather than print a tail that
			-- has quietly gone backwards.
			lines[#lines + 1] =
				string.format("  past span end     %11.3f ms  (last rows lie beyond the span; window slack ±1 ms)", -tail)
		end
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
