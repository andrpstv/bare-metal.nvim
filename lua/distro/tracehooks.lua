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

local function ctx()
	local buf = vim.api.nvim_get_current_buf()
	local ft = vim.bo[buf].filetype
	local name = vim.api.nvim_buf_get_name(buf)
	return buf, name, ft
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
		local buf, name, ft = ctx()
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

		-- We must not steal the shim's callback: it owns the jump/picker logic.
		-- So wrap buf_request, hand the original callback a delegating wrapper,
		-- and restore the original in every exit path. Restoration is done by
		-- the wrapper's first invocation, not before: the shim calls
		-- buf_request synchronously, so restoring right after the call is safe
		-- and avoids leaking a patched global if the shim errors.
		local orig_req = vim.lsp.buf_request
		local n = 0
		vim.lsp.buf_request = function(bufnr, method, params, handler, bufnr2)
			n = n + 1
			-- 1. keypress -> request
			trace.sub(ev, "keypress_to_request", el(), nil, frame)
			-- The synchronous frame closes here: everything after the request is
			-- sent happens in a frame this call no longer owns.
			trace.end_span(trace.current_span(), ev)
			vim.lsp.buf_request = orig_req
			return orig_req(bufnr, method, params, function(...)
				-- 2. request -> response
				trace.sub(ev, "request_to_response", el(), nil, frame)
				local nargs = select("#", ...)
				local res = { handler(...) }
				-- 3. response -> cursor placed
				trace.sub(ev, "response_to_cursor", el(), nil, frame)
				-- The honest end-to-end total, logged HERE rather than after
				-- pcall(orig): the shim dispatches asynchronously and returns
				-- immediately, so anything timed after it excludes the server
				-- round-trip and the jump entirely. Measured at dispatch that
				-- "total" reads 0.1-0.6 ms while the real hop is 9-14 ms.
				trace.log(ev, el(), "TOTAL (requests: " .. n .. ")", name, ft, { kind = "action", group = ev })
				return unpack(res, 1, nargs)
			end, bufnr2)
		end

		local ok, r = pcall(orig, scope, opts)
		vim.lsp.buf_request = orig_req
		if not ok then
			trace.log(ev, el(), "error: " .. tostring(r), name, ft)
			trace.end_span(trace.current_span(), ev)
			error(r, 0)
		end
		-- Dispatch only: how long the synchronous send took. Deliberately NOT
		-- called "total" — the real TOTAL is logged from the response handler.
		trace.log(ev, el(), "dispatch only (requests: " .. n .. ")", name, ft, { kind = "phase", group = ev })
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
	local pattern = "^(Distro.*|Turbo.*|WeakHw.*|Format.*)$"
	local cmds = api.nvim_get_commands({ builtin = false })
	local names = {}
	for name in pairs(cmds) do
		if name:match(pattern) then
			names[#names + 1] = name
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
