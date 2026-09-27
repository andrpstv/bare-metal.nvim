-- distro.tracehooks — installs the instrumentation for :DistroTrace.
--
-- Step 3 (the one that matters): in THIS config gd does not go through
-- vim.lsp.buf.definition. It goes keymap/pick.lua -> _G._pick_lsp(scope, opts),
-- a hand-written shim that calls vim.lsp.buf_request itself. Wrapping
-- vim.lsp.buf / buf_request would therefore trace nothing at all. So we wrap
-- the shim, at the boundary, and time the whole call: keypress -> request ->
-- response -> cursor placement, with the sub-stages logged as separate rows
-- inside the parent span's time window.
--
-- All hooks early-return on `not M.enabled`. No tracing, no allocations.

local M = {}

--- P0-1 session state for the "cold gd" question. Plain counters, no log I/O.
M._gd_count = 0
M._seen_targets = {}
M._bufread_at = nil -- trace.now_ms() of the last BufReadPost (any buffer)
M._lspattach_at = nil -- trace.now_ms() of the last LspAttach
--- P0-4 per-window frames: frame_id -> {begin,report,end,titles,indexing,diag,t0}.
--- The registry only routes $/progress + DiagnosticChanged into the window
--- that is open; every counter lives in the per-frame table and the entry is
--- dropped at TOTAL — never a global counter.
M._active = {}
M._progress_wrapped = false
M._progress_orig = nil

local function ctx()
	local buf = vim.api.nvim_get_current_buf()
	local ft = vim.bo[buf].filetype
	local name = vim.api.nvim_buf_get_name(buf)
	-- P0-1: symbol under the cursor. 4th return, so the three existing
	-- callers (`local buf, name, ft = ctx()`) are untouched.
	local sym = nil
	pcall(function()
		sym = vim.fn.expand("<cword>")
	end)
	if sym == "" then
		sym = nil
	end
	return buf, name, ft, sym
end

--- Target class for the cold-gd question, via the existing is_go_lib.
---@return string "workspace"|"modcache"|"stdlib"|"other"
local function classify_target(uri)
	local s = tostring(uri or ""):gsub("^file://", "")
	if s:match("/go/pkg/mod/") or s:match("\\go\\pkg\\mod\\") then
		return "modcache"
	end
	local ok_u, utils = pcall(require, "modules.utils")
	if ok_u and utils and utils.is_go_lib and utils.is_go_lib(s) then
		return "stdlib"
	end
	if s == "" then
		return "other"
	end
	if s:match("^%a[%w%.%+%-]*://") then
		return "other"
	end
	return "workspace"
end

--- Ages of BufReadPost / LspAttach in seconds, for the detail text.
---@return string br, string la ("n/a" when the event predates tracing)
local function ages(trace)
	local now = trace.now_ms()
	local br, la = "n/a", "n/a"
	if M._bufread_at then
		br = string.format("%.1fs", (now - M._bufread_at) / 1000)
	end
	if M._lspattach_at then
		la = string.format("%.1fs", (now - M._lspattach_at) / 1000)
	end
	return br, la
end

--- Freshness of LspAttach in ms, or nil when unknown.
local function lsp_age_ms(trace)
	if not M._lspattach_at then
		return nil
	end
	return trace.now_ms() - M._lspattach_at
end

--- First location URI out of a definition/hover response, or nil.
local function first_target_uri(res)
	if type(res) ~= "table" then
		return nil
	end
	if type(res.uri) == "string" then
		return res.uri
	end
	if type(res.targetUri) == "string" then
		return res.targetUri
	end
	local first = res[1]
	if type(first) == "table" then
		return first.uri or first.targetUri
	end
	return nil
end

local function short_target(uri)
	local s = tostring(uri or ""):gsub("^file://", "")
	if #s > 60 then
		s = "…" .. s:sub(-59)
	end
	return s
end

local function cfg_hash()
	local ok, trace = pcall(require, "distro.trace")
	if ok and trace.config_hash then
		local ok_h, h = pcall(trace.config_hash)
		if ok_h and type(h) == "string" then
			return h
		end
	end
	return "n/a"
end

--- Fold one $/progress notification into a per-frame table.
local function note_progress(st, result)
	local v = result and result.value
	if type(v) ~= "table" then
		return
	end
	local kind = v.kind
	if kind == "begin" then
		st.begin = (st.begin or 0) + 1
	elseif kind == "report" then
		st.report = (st.report or 0) + 1
	elseif kind == "end" then
		st["end"] = (st["end"] or 0) + 1
	end
	local title = tostring(v.title or "")
	local msg = tostring(v.message or "")
	local t = title ~= "" and title or msg
	if t ~= "" then
		local low = (title .. " " .. msg):lower()
		if low:find("index", 1, true) then
			st.indexing = true
		end
		local dup = false
		for _, x in ipairs(st.titles) do
			if x == t then
				dup = true
				break
			end
		end
		if not dup and #st.titles < 5 then
			st.titles[#st.titles + 1] = t:sub(1, 40):gsub("[\t\r\n]", " ")
		end
	end
end

--- Install the $/progress wrapper for the gd window only (P2 explicitly
--- defers a subscription outside it). Routes into every open per-frame
--- table; the wrapper is removed when the last window closes.
local function ensure_progress_wrap()
	if M._progress_wrapped then
		return
	end
	M._progress_orig = vim.lsp.handlers["$/progress"]
	M._progress_wrapped = true
	vim.lsp.handlers["$/progress"] = function(err, result, ctx_, config_)
		local ok, trace = pcall(require, "distro.trace")
		if ok and trace.enabled then
			pcall(function()
				for _, st in pairs(M._active) do
					note_progress(st, result)
				end
			end)
		end
		if type(M._progress_orig) == "function" then
			return M._progress_orig(err, result, ctx_, config_)
		end
	end
end

local function restore_progress_if_idle()
	if not M._progress_wrapped then
		return
	end
	if next(M._active) ~= nil then
		return
	end
	vim.lsp.handlers["$/progress"] = M._progress_orig
	M._progress_orig = nil
	M._progress_wrapped = false
end

--- Wrap _G._pick_lsp once, idempotently.
--- The "already wrapped" flag lives on the module, not on the function: a
--- function value cannot be indexed in Lua (rawset-able, but pointless).
function M.wrap_pick()
	if M._pick_wrapped then
		return false
	end
	local orig = _G._pick_lsp
	if type(orig) ~= "function" then
		return false
	end
	M._pick_wrapped = true
	local trace = require("distro.trace")
	local uv = vim.uv or vim.loop

	local function traced(scope, opts)
		-- ZERO COST GUARD: the whole point of the boolean first line.
		if not trace.enabled then
			return orig(scope, opts)
		end
		local buf, name, ft, sym = ctx()
		sym = sym or "?"
		-- P0-1: gd counter of the session (#N) + provisional cold flag
		-- (final cold adds "target unseen", known only at TOTAL).
		M._gd_count = M._gd_count + 1
		local gd_n = M._gd_count
		local br_age, la_age = ages(trace)
		local la_ms = lsp_age_ms(trace)
		local cold_prov = (gd_n == 1) or (la_ms ~= nil and la_ms < 2000)
		local t0 = uv.hrtime()
		local el = function()
			return (uv.hrtime() - t0) / 1e6
		end
		local ev = "pick_lsp/" .. tostring(scope)
		-- A real synchronous frame around the dispatch. It closes as soon as the
		-- request is sent; the response arrives in a different frame, so the
		-- response phases CANNOT be sync children of this span and are not
		-- claimed as such. They are linked by `group` (a declared link written by
		-- the caller in M.sub) so the viewer can show one "what did my gd cost"
		-- node without pretending the await boundary was a call boundary.
		-- The span id doubles as the INVOCATION identity: every phase below is
		-- measured from THIS t0, so each one's own_ms must be reduced only by a
		-- mark of this same invocation, never by one of a later or concurrent
		-- press of the same key (see M.sub).
		local frame = trace.begin(ev)

		-- P0-4: per-window table for this gd (dropped at TOTAL, never global).
		-- Stale entries (>30 s, response never came) are pruned so a hung
		-- server cannot grow the registry; then the $/progress wrapper lives
		-- only while a window is open.
		local now_ms = trace.now_ms()
		for id, st in pairs(M._active) do
			if st.t0 and (now_ms - st.t0) > 30000 then
				M._active[id] = nil
			end
		end
		restore_progress_if_idle()
		local fstate = { begin = 0, report = 0, ["end"] = 0, titles = {}, indexing = false, diag = 0, t0 = now_ms }
		M._active[frame] = fstate
		ensure_progress_wrap()
		local function close_window()
			M._active[frame] = nil
			restore_progress_if_idle()
		end

		-- We must not steal the shim's callback: it owns the jump/picker logic.
		-- So wrap buf_request, hand the original callback a delegating wrapper,
		-- and restore the original in every exit path. Restoration happens
		-- AFTER dispatch (pcall) and on TOTAL, not on the first request: the
		-- shim may send multi-requests synchronously and all must be counted.
		local orig_req = vim.lsp.buf_request
		local n = 0
		local frame_closed = false
		vim.lsp.buf_request = function(bufnr, method, params, handler, bufnr2)
			n = n + 1
			-- 1. keypress -> request (каждый синхронный запрос шима виден:
			-- restore перенесён на закрытие TOTAL, см. ниже).
			-- P0-1: symbol, gd counter, ages, provisional cold — всё в
			-- detail-тексте, колонки лога не тронуты.
			trace.sub(
				ev,
				"keypress_to_request",
				el(),
				string.format("sym=%s #%d bufread=%s lspattach=%s cold=%s", sym, gd_n, br_age, la_age, cold_prov and "YES" or "NO"),
				frame
			)
			-- Синхронный фрейм закрывается один раз — на первом запросе;
			-- повторный end_span закрыл бы чужой фрейм при перекрытии.
			if not frame_closed then
				frame_closed = true
				trace.end_span(frame, ev)
			end
			-- restore НЕ здесь: шим может слать мульти-запросы синхронно,
			-- обёртка живёт до конца dispatch (pcall ниже) + страховка на TOTAL.
			return orig_req(bufnr, method, params, function(...)
				-- Peek the target BEFORE logging the phase: its class is part
				-- of the sub detail (P0-1). Peeking never consumes the args.
				local res_arg = select(2, ...)
				local target_uri = first_target_uri(res_arg)
				local target_class = target_uri and classify_target(target_uri) or "n/a"
				-- 2. request -> response
				trace.sub(
					ev,
					"request_to_response",
					el(),
					string.format("sym=%s target=%s", sym, target_class),
					frame
				)
				local nargs = select("#", ...)
				local res = { handler(...) }
				-- 3. response -> cursor placed
				trace.sub(ev, "response_to_cursor", el(), string.format("sym=%s #%d", sym, gd_n), frame)
				-- The honest end-to-end total, logged HERE rather than after
				-- pcall(orig): the shim dispatches asynchronously and returns
				-- immediately, so anything timed after it excludes the server
				-- round-trip and the jump entirely. Measured at dispatch that
				-- "total" reads 0.1-0.6 ms while the real hop is 9-14 ms.
				-- P0-1 + P0-2 + P0-4: target class, final cold, ages,
				-- indexing titles, DiagnosticChanged count, config hash —
				-- all inside the detail text; column layout is unchanged.
				local la_ms2 = lsp_age_ms(trace)
				local br2, la2 = ages(trace)
				local unseen = target_uri and not M._seen_targets[target_uri] or false
				local cold = cold_prov or unseen or (la_ms2 ~= nil and la_ms2 < 2000)
				local idx_txt = "indexing=" .. (fstate.indexing and "YES" or "NO")
				if #fstate.titles > 0 then
					idx_txt = idx_txt .. " [" .. table.concat(fstate.titles, ", ") .. "]"
				else
					idx_txt = idx_txt .. " []"
				end
				if target_uri then
					M._seen_targets[target_uri] = true
				end
				trace.log(
					ev,
					el(),
					-- cfg= sits before the variable-length tail (titles) so a
					-- 300-char sanitize cut never eats the config hash.
					string.format(
						"TOTAL (requests: %d) sym=%s #%d target=%s:%s cold=%s cfg=%s bufread=%s lspattach=%s %s diag=%d",
						n,
						sym,
						gd_n,
						target_class,
						short_target(target_uri),
						cold and "YES" or "NO",
						cfg_hash(),
						br2,
						la2,
						idx_txt,
						fstate.diag or 0
					),
					name,
					ft,
					{ kind = "action", group = ev }
				)
				vim.lsp.buf_request = orig_req
				close_window()
				return unpack(res, 1, nargs)
			end, bufnr2)
		end

		local ok, r = pcall(orig, scope, opts)
		-- Dispatch окончен: все синхронные запросы шима уже посчитаны.
		-- Снимаем обёртку здесь (и страховка в TOTAL-колбэке выше).
		vim.lsp.buf_request = orig_req
		if not ok then
			trace.log(ev, el(), "error: " .. tostring(r), name, ft)
			close_window()
			if not frame_closed then
				frame_closed = true
				trace.end_span(frame, ev)
			end
			error(r, 0)
		end
		if n == 0 then
			-- Шим не вызвал buf_request (нет клиента): закрыть фрейм с меткой,
			-- иначе висит до STALE_MS и усыновляет чужие события.
			close_window()
			frame_closed = true
			trace.end_span(frame, ev, "no-request")
		end
		-- Dispatch only: how long the synchronous send took. Deliberately NOT
		-- called "total" — the real TOTAL is logged from the response handler.
		trace.log(ev, el(), "dispatch only (requests: " .. n .. ") sym=" .. sym .. " #" .. gd_n, name, ft, { kind = "phase", group = ev })
		trace.flush()
		return r
	end
	_G._pick_lsp = traced
	M._pick_orig = orig
	M._restore_pick = function()
		_G._pick_lsp = orig
		M._pick_wrapped = false
	end
	return true
end

--- Wrap every Distro*/Turbo*/WeakHw*/Format* user command with a timed row.
---
--- Done centrally instead of editing ~20 registration sites: re-create each
--- command with the SAME opts and the SAME callback, only the callback body
--- gains a span. Registration order matters — this must run after the modules
--- that define the commands, so :DistroTrace calls it on enable.
---
--- The wrapped function re-dispatches through the original command, so
--- completion, nargs and bang semantics are untouched; args/bang are forwarded.
--- Commands whose name is in M._cmd_orig are never wrapped twice.
function M.wrap_commands()
	if M._cmds_wrapped then
		return false
	end
	local trace = require("distro.trace")
	local uv = vim.uv or vim.loop
	local api = vim.api
	-- Lua-паттерны без `|`: явный список префиксов через vim.startswith.
	local prefixes = { "Distro", "Turbo", "WeakHw", "Perf", "Format" }
	local cmds = api.nvim_get_commands({ builtin = false })
	local names = {}
	for name in pairs(cmds) do
		for _, p in ipairs(prefixes) do
			if vim.startswith(name, p) then
				names[#names + 1] = name
				break
			end
		end
	end
	if #names == 0 then
		return false
	end
	table.sort(names)
	M._cmd_orig = M._cmd_orig or {}
	for _, name in ipairs(names) do
		if not M._cmd_orig[name] then
			local info = cmds[name]
			local orig = info.definition
			do
				if type(orig) == "function" then
					local opts = {}
					for _, k in ipairs({ "nargs", "bang", "bar", "range", "count", "complete", "addr", "reg" }) do
						opts[k] = info[k]
					end
					if info.complete and type(info.complete) == "string" then
						opts.complete = info.complete
					end
					M._cmd_orig[name] = { fn = orig, opts = opts }
					api.nvim_create_user_command(name, function(copts)
						if not trace.enabled then
							return orig(copts)
						end
						local t0 = uv.hrtime()
						local ok, res = pcall(orig, copts)
						local dt = (uv.hrtime() - t0) / 1e6
						trace.log("command:" .. name, dt, ok and nil or ("error: " .. tostring(res)))
						trace.flush()
						if not ok then
							error(res, 0)
						end
						return res
					end, vim.tbl_extend("force", opts, {
						desc = (opts.desc or ("distro: " .. name)) .. " [traced]",
					}))
				end
			end
		end
	end
	M._cmds_wrapped = true
	return true
end

--- Autocmd-level instrumentation.
function M.setup_autocmds()
	local grp = vim.api.nvim_create_augroup("DistroTraceHooks", { clear = true })
	local trace = require("distro.trace")
	-- CursorMoved is the ONLY event that can produce a million-line log (spec
	-- §3.4: it is emitted for every keypress of j/k, and the user complaint is
	-- precisely "I see every action at once"). It is aggregated instead of
	-- written per event: at most one row per RATE_MS per buffer, carrying how
	-- many movements it stands for. Nothing is lost — the count and the elapsed
	-- window are both in the row — and the log stays readable.
	local RATE_MS = 200
	local last_seen, last_row = {}, {}
	local suppressed = 0
	local function on_cursor()
		if not trace.enabled then
			return
		end
		local buf, name, ft = ctx()
		local now = trace.now_ms()
		local prev = last_row[buf]
		if prev and (now - prev) < RATE_MS then
			suppressed = suppressed + 1
			last_seen[buf] = last_seen[buf] + 1
			return
		end
		local n = last_seen[buf] or 0
		suppressed = suppressed - n
		last_row[buf], last_seen[buf] = now, 0
		local detail = "line " .. vim.fn.line(".")
		if n > 0 then
			detail = detail .. string.format("  (+%d more in %.0f ms)", n, RATE_MS)
		end
		trace.log("autocmd/CursorMoved", nil, detail, name, ft)
	end
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = grp,
		callback = on_cursor,
	})
	vim.api.nvim_create_autocmd("BufEnter", {
		group = grp,
		callback = function()
			if not trace.enabled then
				return
			end
			local buf, name, ft = ctx()
			trace.log("autocmd/BufEnter", nil, "size " .. tostring(vim.api.nvim_buf_line_count(buf)), name, ft)
		end,
	})
	vim.api.nvim_create_autocmd("FileType", {
		group = grp,
		callback = function(ev)
			if not trace.enabled then
				return
			end
			local buf, name = ev.buf, vim.api.nvim_buf_get_name(ev.buf)
			trace.log("autocmd/FileType", nil, vim.bo[ev.buf].filetype, name, vim.bo[ev.buf].filetype)
		end,
	})
	vim.api.nvim_create_autocmd("LspAttach", {
		group = grp,
		callback = function(ev)
			if not trace.enabled then
				return
			end
			-- P0-1: anchor for the cold-gd age (sec since attach).
			M._lspattach_at = trace.now_ms()
			local name = vim.api.nvim_buf_get_name(ev.buf)
			local cl = vim.lsp.get_clients({ bufnr = ev.buf })
			trace.log("autocmd/LspAttach", nil, #cl .. " client(s)", name, vim.bo[ev.buf].filetype)
		end,
	})
	vim.api.nvim_create_autocmd("DiagnosticChanged", {
		group = grp,
		callback = function(ev)
			if not trace.enabled then
				return
			end
			-- P0-4: count per open gd window (frame-local, not global).
			pcall(function()
				for _, st in pairs(M._active) do
					st.diag = (st.diag or 0) + 1
				end
			end)
			local name = vim.api.nvim_buf_get_name(ev.buf)
			local n = #vim.diagnostic.get(ev.buf)
			trace.log("autocmd/DiagnosticChanged", nil, n .. " diagnostic(s)", name, vim.bo[ev.buf].filetype)
		end,
	})
	-- Time the whole BufReadPost / syntax+ft work: a plain autocmd cannot give a
	-- duration, so we bracket it with two marks the viewer can pair by seq.
	vim.api.nvim_create_autocmd("BufReadPost", {
		group = grp,
		callback = function(ev)
			if not trace.enabled then
				return
			end
			-- P0-1: anchor for the cold-gd age (sec since file read).
			M._bufread_at = trace.now_ms()
			trace.log("buf/BufReadPost", nil, "lines " .. tostring(vim.api.nvim_buf_line_count(ev.buf)), vim.api.nvim_buf_get_name(ev.buf), vim.bo[ev.buf].filetype)
		end,
	})


	-- ---------------------------------------------------------------------
	-- PERF-2E: the EDIT PATH (TextChanged / TextChangedI / BufWritePost).
	--
	-- Until this block the tracer covered the READ and NAVIGATION path only:
	-- seven events, none of which can observe a character being typed or a
	-- buffer reaching disk. So "what did my edit cost" had no row to point at,
	-- and an empty result was indistinguishable from a broken hook. That is
	-- zero coverage, not a defect in a hook, and it is closed here.
	--
	-- TextChanged fires on EVERY text mutation, so at typing speed it is the
	-- same million-line hazard the RATE_MS block above was written for. It
	-- therefore gets the SAME treatment, for the same stated reason: at most
	-- one row per RATE_MS per buffer, and the row carries how many changes it
	-- stands for. Nothing is lost (the count is in the row), the log stays
	-- readable, and the default stays "logging ON".
	--
	-- The state is deliberately SEPARATE from the cursor's. A shared window
	-- would let a burst of typing swallow the CursorMoved row for the same
	-- buffer, and a burst of j/k swallow the typing row: they are different
	-- events with different cadence, and neither has the right to censor the
	-- other. The cursor block above is left byte-for-byte as it was.
	local edit_last, edit_seen, edit_tick = {}, {}, {}
	local function on_edit(ev)
		if not trace.enabled then
			return
		end
		local buf = ev.buf
		local name = vim.api.nvim_buf_get_name(buf)
		local ft = vim.bo[buf].filetype
		local now = trace.now_ms()
		local prev = edit_last[buf]
		if prev and (now - prev) < RATE_MS then
			edit_seen[buf] = (edit_seen[buf] or 0) + 1
			return
		end
		local n = edit_seen[buf] or 0
		edit_seen[buf] = 0
		edit_last[buf] = now
		-- changedtick counts EVERY mutation, including the ones the window
		-- above swallowed, so "how much text actually changed" survives the
		-- aggregation instead of disappearing together with the row.
		local tick = vim.b[buf].changedtick or 0
		local dtick = 0
		if prev then
			dtick = tick - (edit_tick[buf] or 0)
		end
		edit_tick[buf] = tick
		local detail = "tick " .. tostring(tick)
		if dtick > 0 then
			detail = detail .. string.format("  (+%d ticks)", dtick)
		end
		if n > 0 then
			detail = detail .. string.format("  (+%d more in %.0f ms)", n, RATE_MS)
		end
		-- Logged under the event Neovim ACTUALLY fired, not under a hardcoded
		-- "TextChanged": TextChangedI is a distinct event, and collapsing the
		-- two would make the log assert something that did not happen.
		trace.log("autocmd/" .. tostring(ev.event), nil, detail, name, ft)
	end
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = grp,
		callback = on_edit,
	})

	-- BufWritePost is NOT rate-limited, and that asymmetry is deliberate.
	-- A save is a discrete, user-initiated act, not a stream: at most one per
	-- keystroke of :w, and aggregating them would hide exactly the moment the
	-- owner asked to see. CursorMoved and TextChanged are rate-limited because
	-- their frequency is a function of typing/navigation speed, which nobody
	-- schedules; a write always is.
	--
	-- The same reasoning says: no `trace_textchanged` flag. A flag defaulting
	-- to OFF would reproduce the very defect this ticket closes — a registered
	-- hook that never fires, indistinguishable from a broken one — and a flag
	-- defaulting to ON would put a config surface in front of a problem RATE_MS
	-- already bounds, with no measurement yet saying the bound is too loose. If
	-- the log is still too big after this, the honest response is to retune
	-- RATE_MS with a measurement in hand, not to pre-ship a switch nobody has
	-- asked to turn.
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = grp,
		callback = function(ev)
			if not trace.enabled then
				return
			end
			local buf = ev.buf
			trace.log("autocmd/BufWritePost", nil, "lines " .. tostring(vim.api.nvim_buf_line_count(buf)), vim.api.nvim_buf_get_name(buf), vim.bo[buf].filetype)
		end,
	})
end

--- Install everything. Cheap: only a _G swap and one augroup.
function M.setup()
	M.wrap_pick()
	M.setup_autocmds()
	M.wrap_commands()
end

return M
