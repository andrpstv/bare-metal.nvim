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

--- Drop frames that have outlived STALE_MS. Проверяем ВЕСЬ стек, а не
--- только верх: нижний протухший фрейм иначе остаётся и усыновляет чужие
--- события, даже когда верх свежий (стек упорядочен по t0 по возрастанию,
--- так что протухнуть может именно низ).
local function prune(now)
	local kept = {}
	for i = 1, #frames do
		if (now - frames[i].t0) <= STALE_MS * 1e6 then
			kept[#kept + 1] = frames[i]
		end
	end
	for i = 1, #frames do
		frames[i] = nil
	end
	for i = 1, #kept do
		frames[i] = kept[i]
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
--- The baseline must come from the SAME INVOCATION as the value it is
--- subtracted from. `ms` is elapsed since that invocation's own t0, so it is
--- comparable only with a mark taken in the same invocation. Keying the
--- baseline by `name` — a label shared by every invocation of the same command
--- — broke that in two separate ways, both of which wrote a NEGATIVE own_ms:
---
---   * re-entry: the last cumulative of invocation N-1 was still in the slot
---     when invocation N logged its first phase, so 0.112 - 9.786 = -9.674
---     (a phase that cost 0.112 ms was charged -9.674);
---   * overlap: two invocations in flight overwrote each other's slot, so
---     444.965 (invocation B, measured from B's t0) was reduced by 5248.960
---     (invocation A's total, from A's t0): 444.965 - 5248.960 = -4803.995.
---
--- `frame` is the caller's per-invocation identity (the id M.begin returned).
--- The baseline is kept per frame, so the first phase of an invocation has no
--- predecessor and correctly owns its whole `ms`. It is deliberately NOT
--- clamped with max(0, ...): a clamp would silence both defects above while
--- leaving the mismatched boundaries in place, and would still hide the
--- positive half of the same bug — a leaked baseline also UNDER-reports (seq
--- 118's own was 0.006 instead of its true 0.118: nothing to clamp, silently
--- wrong anyway).
---
--- `group` links the phase to the span named `name`. It is a declared link
--- written by the caller, not a time-inferred one: the viewer attaches the row
--- to the span whose event equals that name. `frame` changes only which
--- baseline slot is used and never reaches the log, so fields 12/13/14 and the
--- viewer's grouping are untouched.
---@param name string
---@param stage string "keypress_to_request", "request_to_response", ...
---@param ms number|nil elapsed ms since the parent span started
---@param detail string|nil
---@param frame any|nil per-invocation identity; defaults to `name`
function M.sub(name, stage, ms, detail, frame)
	if not M.enabled then
		return
	end
	local key = frame == nil and name or frame
	local own = nil
	if ms then
		own = ms - (last_cum[key] or 0)
		last_cum[key] = ms
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

--- Cached snapshot lines, computed once per enable (never per action).
--- Cleared at the top of M.enable so a re-enable re-reads the world.
M._config_line = nil
M._config_hash = nil
M._goenv_line = nil
M._gopls_pv = nil

--- 8 hex chars of the config line. Used in every action detail so a reader
--- can tell whether two actions ran under the same settings.
---@return string
local function short_hash(s)
	s = tostring(s or "")
	local ok, h = pcall(vim.fn.sha256, s)
	if ok and type(h) == "string" and #h >= 8 then
		return h:sub(1, 8)
	end
	local x = 5381
	for i = 1, #s do
		x = (x * 33 + s:byte(i)) % 4294967296
	end
	return string.format("%08x", x)
end

--- gopls binary path + version. Cached; vim.system with a 2 s timeout,
--- called ONLY from M.config_line (i.e. only at enable), never per action.
---@return string "path=... ver=..." | "gopls=missing" | "gopls_path=..."
local function gopls_path_ver()
	if M._gopls_pv then
		return M._gopls_pv
	end
	local path = vim.fn.exepath("gopls")
	if path == "" then
		M._gopls_pv = "gopls=missing"
		return M._gopls_pv
	end
	local ver = "unknown"
	local ok, obj = pcall(function()
		return vim.system({ "gopls", "version" }, { text = true, timeout = 2000 }):wait(2500)
	end)
	if ok and obj and obj.code == 0 then
		local out = tostring(obj.stdout or "")
		ver = out:match("gopls v([%d%.]+)") or out:match("(%d+%.%d+%.%d+)") or "unknown"
	end
	M._gopls_pv = "gopls_path=" .. path .. " gopls_ver=" .. ver
	return M._gopls_pv
end

--- CONFIG snapshot: lean_on + lean axes (core/perf), gopls debounce /
--- semanticTokens / completeUnimported / fieldalignment / 8-codelens bitmask /
--- usePlaceholders / staticcheck (read lazily via pcall require — this module
--- must NOT load the lsp config at startup), perf.status(), gopls path+ver.
--- Full line is logged once at trace/enable; M.config_hash (8 hex of it)
--- goes into every action detail.
---@return string
function M.config_line()
	if M._config_line then
		return M._config_line
	end
	local parts = {}
	local ok_perf, perf = pcall(require, "core.perf")
	if ok_perf and perf and perf.lean_on then
		local ok_l, lean = pcall(perf.lean_on)
		local axes = {}
		if ok_perf and perf.lean_axis then
			for _, a in ipairs({ "gopls", "theme", "treesitter", "debounce" }) do
				local ok_a, on = pcall(perf.lean_axis, a)
				axes[#axes + 1] = a .. "=" .. ((ok_a and on) and "1" or "0")
			end
		end
		parts[#parts + 1] = "lean=" .. ((ok_l and lean) and "on" or "off") .. "(" .. table.concat(axes, ",") .. ")"
		local ok_s, st = pcall(perf.status)
		if ok_s and type(st) == "string" then
			parts[#parts + 1] = "perf=" .. (st:gsub("[\t\r\n]", " "))
		end
	else
		parts[#parts + 1] = "lean=n/a"
	end
	local ok_g, gcfg = pcall(require, "modules.configs.completion.servers.gopls")
	if ok_g and type(gcfg) == "table" then
		local flags = gcfg.flags or {}
		local gs = (gcfg.settings or {}).gopls or {}
		local an = gs.analyses or {}
		local cl = gs.codelenses or {}
		local order = { "generate", "gc_details", "test", "tidy", "vendor", "regenerate_cgo", "upgrade_dependency", "organizeImports" }
		local bits = {}
		for _, k in ipairs(order) do
			bits[#bits + 1] = cl[k] and "1" or "0"
		end
		parts[#parts + 1] = string.format(
			"gopls debounce=%s sem=%s unimp=%s fieldalign=%s usePH=%s static=%s codelens=%s",
			tostring(flags.debounce_text_changes),
			tostring(gs.semanticTokens),
			tostring(gs.completeUnimported),
			tostring(an.fieldalignment),
			tostring(gs.usePlaceholders),
			tostring(gs.staticcheck),
			table.concat(bits)
		)
	else
		parts[#parts + 1] = "gopls_cfg=n/a"
	end
	parts[#parts + 1] = gopls_path_ver()
	M._config_line = table.concat(parts, " ")
	M._config_hash = short_hash(M._config_line)
	return M._config_line
end

---@return string 8 hex chars of M.config_line(), cached (no work per action)
function M.config_hash()
	if M._config_hash then
		return M._config_hash
	end
	M.config_line()
	return M._config_hash or "n/a"
end

--- Redact secrets in proxy-like values (GOPROXY userinfo/token) before they
--- hit the trace log. Primary: distro.mirror.redact(); fallback: local
--- userinfo scrub when the mirror module cannot be loaded.
---@param s string|nil
---@return string
local function redact_proxy(s)
	local ok, mirror = pcall(require, "distro.mirror")
	if ok and mirror and mirror.redact then
		local ok2, out = pcall(mirror.redact, tostring(s or ""))
		if ok2 and type(out) == "string" then
			return out
		end
	end
	return tostring(s or ""):gsub("://[^@]*@", "://***@")
end

--- `go env` snapshot, ONE `go env ...` call with a 5 s timeout, plus
--- modcache entries + du size and the mongo-driver version when present.
--- Cached per enable. "go: missing" when there is no go binary.
--- NOTE: GOPROXY is passed through redact_proxy(); GOMODCACHE/GOPATH are
--- local paths, GOVERSION a version, GOFLAGS build flags — none carries
--- userinfo, so only the proxy-like value is redacted.
---@return string
function M.goenv_line()
	if M._goenv_line then
		return M._goenv_line
	end
	if vim.fn.exepath("go") == "" then
		M._goenv_line = "go: missing"
		return M._goenv_line
	end
	local ok, obj = pcall(function()
		return vim.system(
			{ "go", "env", "GOMODCACHE", "GOPROXY", "GOPATH", "GOVERSION", "GOFLAGS" },
			{ text = true, timeout = 5000 }
		):wait(5500)
	end)
	if not ok or not obj or obj.code ~= 0 then
		M._goenv_line = "go env: NOT MEASURED (timeout/error)"
		return M._goenv_line
	end
	local vals = {}
	for l in (tostring(obj.stdout or "") .. "\n"):gmatch("([^\n]*)\n") do
		if l ~= "" then
			vals[#vals + 1] = l
		end
	end
	local modcache, goproxy, gopath, goversion, goflags =
		vals[1] or "?", vals[2] or "?", vals[3] or "?", vals[4] or "?", vals[5] or ""
	local entries, size_txt = nil, "n/a"
	if modcache ~= "" and modcache ~= "?" and vim.fn.isdirectory(modcache) == 1 then
		local n = 0
		local scan = uv.fs_scandir(modcache)
		if scan then
			while true do
				local nm = uv.fs_scandir_next(scan)
				if not nm then
					break
				end
				n = n + 1
			end
		end
		entries = n
		local ok_du, du = pcall(function()
			return vim.system({ "du", "-sk", modcache }, { text = true, timeout = 5000 }):wait(5500)
		end)
		if ok_du and du and du.code == 0 then
			local kb = tostring(du.stdout or ""):match("^(%d+)")
			if kb then
				size_txt = kb .. "KB"
			end
		end
	end
	local mongo = "n/a"
	if modcache ~= "" and modcache ~= "?" then
		for _, d in ipairs({ modcache .. "/go.mongodb.org/mongo-driver/v2", modcache .. "/go.mongodb.org/mongo-driver" }) do
			if vim.fn.isdirectory(d) == 1 then
				local vers = vim.fn.glob(d .. "@*", true, true)
				if #vers > 0 then
					local v = vers[#vers]:match("@([^/]+)$")
					if v then
						mongo = v
						break
					end
				end
			end
		end
	end
	M._goenv_line = string.format(
		"GOMODCACHE=%s GOPROXY=%s GOPATH=%s GOVERSION=%s GOFLAGS=%s modcache=%sentries/%s mongo-driver=%s",
		modcache,
		redact_proxy(goproxy),
		gopath,
		goversion,
		goflags,
		entries ~= nil and (tostring(entries)) or "?",
		size_txt,
		mongo
	)
	return M._goenv_line
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
	-- Fresh snapshot per enable (config may have changed since last time);
	-- per-action rows reuse the cache via M.config_hash (no work per action).
	M._config_line = nil
	M._config_hash = nil
	M._goenv_line = nil
	M._gopls_pv = nil
	M.log("trace/enable", nil, "pid=" .. tostring(vim.fn.getpid()))
	-- Full CONFIG + go env lines once per enable; each is one row, so the
	-- column format is untouched. pcall: enable must never fail on snapshot.
	pcall(function()
		M.log("trace/config", nil, M.config_line() .. " cfg=" .. M.config_hash())
	end)
	pcall(function()
		M.log("trace/goenv", nil, M.goenv_line())
	end)
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
	-- Базлайны sub-фаз per-frame иначе переживают сессию и вычитаются из
	-- чужой инвокации (отрицательный own_ms); enable тоже чистит, но
	-- disable — точка, где висеть им нечего.
	last_cum = {}
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
	-- При enabled fd открыт на текущий лог: закрыть до unlink, иначе
	-- удаляем файл из-под открытого дескриптора. После удаления fd=nil —
	-- следующий flush лениво переоткроет M.path заново (пустым).
	if fd then
		pcall(uv.fs_close, fd)
		fd = nil
	end
	for _, f in ipairs(M.logs()) do
		pcall(uv.fs_unlink, f.path)
	end
	return #M.logs()
end

return M
