-- distroManager bench — self benchmark that runs anywhere, incl. weak Windows.
-- Pure Lua (no shell, no bash): spawns child nvim for open timings, measures
-- LSP round-trips in-session. Open with :DistroBench. See docs, Step 11+.

local M = {}

local function ms(t0)
	return math.floor((vim.uv.hrtime() - t0) / 1e6)
end

--- Wall time of `nvim --headless <file> +qa` (min of 3). `clean=true` adds --clean.
---@return number? ms, string? err
local function child_open(file, clean)
	local best = nil
	for _ = 1, 3 do
		local argv = { vim.v.progpath, "--headless" }
		if clean then
			argv[#argv + 1] = "--clean"
		end
		argv[#argv + 1] = file
		argv[#argv + 1] = "+qa"
		local t0 = vim.uv.hrtime()
		local obj = vim.system(argv, { timeout = 60000 }):wait()
		if not obj or obj.code ~= 0 then
			return nil, "child nvim failed (exit " .. tostring(obj and obj.code) .. ")"
		end
		local dt = ms(t0)
		if not best or dt < best then
			best = dt
		end
	end
	return best
end

local function tmpfile(lines, suffix)
	local dir = vim.fn.stdpath("cache") .. "/distro-bench"
	vim.fn.mkdir(dir, "p")
	local p = dir .. "/bench-" .. lines .. (suffix or ".txt")
	local f = assert(io.open(p, "w"))
	for i = 1, lines do
		f:write(string.format("line %06d " .. string.rep("x", 40) .. "\n", i))
	end
	f:close()
	return p
end

--- LSP round-trip best-of-3 at current cursor (definition + references).
---@return table { attach: number?, definition: number?, references: number?, note: string? }
local function lsp_rtt()
	local out = {}
	if #vim.lsp.get_clients({ bufnr = 0 }) == 0 then
		out.note = "no LSP attached here — open a code file first"
		return out
	end
	local function best(method)
		local b = nil
		for _ = 1, 3 do
			local params
			local ok_p, p = pcall(vim.lsp.util.make_position_params, 0, "utf-16")
			if not ok_p then
				return nil
			end
			params = p
			local s = vim.uv.hrtime()
			local r = vim.lsp.buf_request_sync(0, method, params, 8000)
			local dt = ms(s)
			if r then
				b = (b == nil or dt < b) and dt or b
			end
		end
		return b
	end
	out.definition = best("textDocument/definition")
	out.references = best("textDocument/references")
	return out
end

--- Async LSP round-trip. Returns ms elapsed, or nil on error.
--- Uses buf_request (async), NOT buf_request_sync: sync returns results=0
--- where the async callback gets 1, so sync measures an empty answer.
--- NOTE the 5th param of buf_request is `on_unsupported` (a function), NOT a
--- buffer number — passing a number there throws
--- "on_unsupported: expected function, got number". Passing nil is correct.
---@param method string
---@param bufnr number
---@param params table
---@param cb fun(ms:number?, nresults:number, err:string?, target:string?)
local function lsp_async(method, bufnr, params, cb)
	local t0 = vim.uv.hrtime()
	vim.lsp.buf_request(bufnr, method, params, function(err, result)
		local dt = (vim.uv.hrtime() - t0) / 1e6
		local n = 0
		-- P1-7: first target URI for the cold/warm verdict (peek only).
		local target = nil
		if type(result) == "table" then
			if result.uri then
				n = 1
				target = result.uri
			elseif type(result.targetUri) == "string" then
				n = 1
				target = result.targetUri
			else
				n = #result
				if type(result[1]) == "table" then
					target = result[1].uri or result[1].targetUri
				end
			end
		end
		if err then
			cb(nil, 0, (err.message or tostring(err)), nil)
		else
			cb(dt, n, nil, type(target) == "string" and target or nil)
		end
	end, nil)
end

--- Target class for the cold/warm verdict, via the existing is_go_lib.
---@return string "workspace"|"modcache"|"stdlib"|"other"
local function target_class(uri)
	local s = tostring(uri or "")
	if s:match("/go/pkg/mod/") or s:match("\\go\\pkg\\mod\\") then
		return "modcache"
	end
	local ok, u = pcall(require, "modules.utils")
	if ok and u and u.is_go_lib and u.is_go_lib(s) then
		return "stdlib"
	end
	if s == "" then
		return "other"
	end
	return "workspace"
end

--- COLD/WARM for gd/gr at the current buffer.
---
--- Rules that are not negotiable, learned the hard way:
---  * COLD must be the FIRST and ONLY measurement of that symbol. Anything
---    else and the "cold" run is already warm — it warmed itself inside the
---    loop, and the number is fiction.
---  * WARM is best-of-3, but on a DIFFERENT symbol each time. Repeating one
---    symbol degenerates into a cache hit and reports an unrealistically
---    optimistic number.
---@param on_done fun(out:table)|nil Called when the async run finishes.
---@return table out (immediately; out.done is false until the last response)
local function cold_warm(on_done)
	local out = { done = false }
	local clients = vim.lsp.get_clients({ bufnr = 0 })
	if #clients == 0 then
		out.note = "no LSP attached here — open a code file first"
		return out
	end
	local buf = vim.api.nvim_get_current_buf()
	if vim.bo[buf].buftype ~= "" then
		out.note = "current buffer is not a file (buftype=" .. vim.bo[buf].buftype .. ")"
		return out
	end

	---Distinct identifier positions: only real symbols, skipping keywords.
	---Pure string scan of the buffer — no vim.fn.search cursor walking. The
	---earlier search-loop version could fail to advance and spin forever.
	local KW = {
		["if"] = true, ["for"] = true, ["while"] = true, ["return"] = true,
		["func"] = true, ["var"] = true, ["const"] = true, ["type"] = true,
		["end"] = true, ["then"] = true, ["else"] = true, ["elseif"] = true,
		["do"] = true, ["nil"] = true, ["true"] = true, ["false"] = true,
		["package"] = true, ["import"] = true, ["local"] = true,
		["int"] = true, ["string"] = true, ["error"] = true, ["range"] = true,
	}
	local function symbols(n)
		local out_syms, seen = {}, {}
		local total = vim.api.nvim_buf_line_count(buf)
		local limit = math.min(total, 3000)
		for ln = 1, limit do
			local line = vim.api.nvim_buf_get_lines(buf, ln - 1, ln, false)[1] or ""
			local init = 1
			while init <= #line do
				local s, e = line:find("[%a_][%w_]*", init)
				if not s then
					break
				end
				local m = line:sub(s, e)
				if #m > 2 and not KW[m] and not seen["s" .. m] then
					seen["s" .. m] = true
					out_syms[#out_syms + 1] = { ln = ln, col = s - 1, name = m }
					if #out_syms >= n then
						return out_syms
					end
				end
				init = e + 1
			end
		end
		return out_syms
	end

	local syms = symbols(10)
	if #syms == 0 then
		out.note = "no identifier under/near cursor to measure"
		return out
	end

	local orig_win = vim.api.nvim_get_current_win()
	local pos = vim.api.nvim_win_get_cursor(orig_win)
	local function restore()
		if vim.api.nvim_win_is_valid(orig_win) then
			pcall(vim.api.nvim_set_current_win, orig_win)
			pcall(vim.api.nvim_win_set_cursor, orig_win, pos)
		end
	end

	local function measure(sym, method, cb)
		vim.api.nvim_win_set_cursor(orig_win, { sym.ln, math.max(0, sym.col) })
		local ok_p, params = pcall(vim.lsp.util.make_position_params, orig_win, "utf-16")
		if not ok_p then
			cb(nil, 0, "make_position_params failed", nil)
			return
		end
		lsp_async(method, buf, params, function(ms, n, err, target)
			restore()
			cb(ms, n, err, target)
		end)
	end

	-- Serial async loop (explicit state machine, always advances).
	--
	-- A per-request timeout is mandatory, not defensive fluff: a request that
	-- is never answered (server busy, cold gopls on external libs) would
	-- otherwise stall the state machine forever and the bench window would sit
	-- on "measuring…" with no result and no error. The whole point of the
	-- async approach is that we never block the UI, so we must also never wait
	-- unboundedly in the measurement itself.
	local TIMEOUT_MS = 5000
	local function run(specs, cb)
		local i = 0
		local results = {}
		local finished = false
		local function next()
			i = i + 1
			if i > #specs then
				if not finished then
					finished = true
					cb(results)
				end
				return
			end
			local sp = specs[i]
			local advanced = false
			local advance = function(ms, n, err, target)
				if advanced then
					return -- late response after the timeout already moved on
				end
				advanced = true
				results[i] = { ms = ms, n = n, err = err, sym = sp.sym.name, method = sp.method, label = sp.label, target = target }
				restore()
				vim.schedule(next)
			end
			local timer = vim.uv.new_timer()
			timer:start(
				TIMEOUT_MS,
				0,
				vim.schedule_wrap(function()
					if timer then
						timer:stop()
						timer:close()
						timer = nil
					end
					advance(nil, 0, "timeout after " .. TIMEOUT_MS .. "ms", nil)
				end)
			)
			measure(sp.sym, sp.method, function(ms, n, err, target)
				if timer then
					timer:stop()
					timer:close()
					timer = nil
				end
				advance(ms, n, err, target)
			end)
		end
		next()
	end

	local method_def = "textDocument/definition"
	local method_ref = "textDocument/references"

	-- Rules being enforced here:
	--  * COLD is the FIRST and ONLY run for that method+symbol. Nothing may
	--    touch it before, or the "cold" number is fiction.
	--  * WARM is best-of-3, and each of the 3 runs uses a DIFFERENT symbol.
	--    Repeating one symbol degenerates into a cache hit and reports an
	--    unrealistically optimistic number.
	--  * Definition and references use disjoint symbol sets, so a symbol
	--    already warmed by one method is not reused as "cold" for the other.
	-- Needs 8 distinct symbols: 1 cold + 3 warm (def) + 1 cold + 3 warm (ref).
	if #syms < 8 then
		out.note = string.format("only %d distinct symbol(s) here — need >=8 for a COLD/WARM split", #syms)
		return out
	end
	local specs = {
		{ sym = syms[1], method = method_def, label = "COLD definition" },
		{ sym = syms[2], method = method_def, label = "WARM definition" },
		{ sym = syms[3], method = method_def, label = "WARM definition" },
		{ sym = syms[4], method = method_def, label = "WARM definition" },
		{ sym = syms[5], method = method_ref, label = "COLD references" },
		{ sym = syms[6], method = method_ref, label = "WARM references" },
		{ sym = syms[7], method = method_ref, label = "WARM references" },
		{ sym = syms[8], method = method_ref, label = "WARM references" },
	}

	run(specs, function(rs)
		out.runs = rs
		out.symbols = syms
		out.done = true
		restore()
		if on_done then
			vim.schedule(function()
				on_done(out)
			end)
		end
	end)
	return out
end

function M.run()
	-- PERF: шапка показывает режим; child nvim наследует NVIM_PERF_* из env
	-- родителя (vim.system), а NVIM_DISTRO_SYNC здесь НЕ выставляем (погасит defer).
	local perf_txt = "PERF_DEFER OFF + PERF_LEAN OFF"
	pcall(function()
		perf_txt = require("core.perf").status()
	end)
	local lines = { " DistroBench — " .. perf_txt .. " — this machine, wall clock (file open: best-of-3; LSP COLD single / WARM best-of-3, see block below).", "" }
	-- 1. session age (equals startup time only if run right after open)
	if vim.g.start_time then
		local age_s = vim.fn.reltimefloat(vim.fn.reltime(vim.g.start_time))
		local age_txt = age_s < 10 and string.format("%.0fms", age_s * 1000) or string.format("%.0fs", age_s)
		lines[#lines + 1] = " session age: " .. age_txt .. " (≈ startup if run just after open)"
	else
		lines[#lines + 1] = " session age: n/a (no start_time)"
	end
	lines[#lines + 1] = ""
	-- 2. file open: child processes (does not disturb this session)
	local small = tmpfile(100)
	local big = tmpfile(20000)
	for _, item in ipairs({ { "small file", small }, { "big file", big } }) do
		local name, file = item[1], item[2]
		local clean_ms, clean_err = child_open(file, true)
		local our_ms, our_err = child_open(file, false)
		if clean_ms and our_ms then
			lines[#lines + 1] = string.format(" open %-10s clean %4dms · ours %4dms (+%dms)", name, clean_ms, our_ms, our_ms - clean_ms)
		else
			lines[#lines + 1] = string.format(" open %-10s FAILED: %s", name, clean_err or our_err)
		end
	end
	lines[#lines + 1] = ""
	-- 3. LSP round-trips at cursor
	local rtt = lsp_rtt()
	if rtt.note then
		lines[#lines + 1] = " gd/gr: " .. rtt.note
	else
		lines[#lines + 1] = string.format(
			" gd/gr RTT (best-of-3 here, sync probe): definition %sms · references %sms",
			rtt.definition ~= nil and rtt.definition or "?",
			rtt.references ~= nil and rtt.references or "?"
		)
		lines[#lines + 1] = "   (sync probe returns 0 results where async returns 1 — read the COLD/WARM block below instead)"
	end
	lines[#lines + 1] = ""
	-- Sections 1–3 above are synchronous and expensive (child processes), so
	-- they are computed exactly once and reused on the async re-render.
	local head = lines
	local head_len = #lines

	-- forward-declared so the cold_warm callback below can reach them
	local buf, win, set_lines

	--- Lines for the COLD/WARM section + footer, given a result table.
	local function build(cw)
		local out = vim.list_slice(head, 1, head_len)
		out[#out + 1] = ""
		out[#out + 1] = " COLD/WARM — async; COLD is the first and only run on its symbol, WARM = best-of-3 on a NEW symbol each time."
		if not cw.done and not cw.note then
			out[#out + 1] = "   measuring… (7 async round-trips, one at a time)"
		elseif cw.note then
			out[#out + 1] = "   " .. cw.note
		else
			local by_label = {}
			for _, r in ipairs(cw.runs or {}) do
				by_label[r.label] = by_label[r.label] or {}
				if r.ms then
					table.insert(by_label[r.label], r)
				end
			end
			for _, label in ipairs({ "COLD definition", "WARM definition", "COLD references", "WARM references" }) do
				local rs = by_label[label]
				if not rs or #rs == 0 then
					out[#out + 1] = string.format("   %-18s н/д", label)
				else
					local best, best_sym = rs[1].ms, rs[1].sym
					local nres = 0
					for _, r in ipairs(rs) do
						if r.ms < best then
							best, best_sym = r.ms, r.sym
						end
						nres = nres + r.n
					end
					out[#out + 1] = string.format(
						"   %-18s %7.1fms  (best of %d, symbol %s, %d result(s))",
						label, best, #rs, best_sym, nres
					)
				end
			end
			local function pick(lbl)
				local rs = by_label[lbl]
				if not rs then
					return nil
				end
				local b = nil
				for _, r in ipairs(rs) do
					if r.ms and (b == nil or r.ms < b) then
						b = r.ms
					end
				end
				return b
			end
			local cd, wd = pick("COLD definition"), pick("WARM definition")
			local cr, wr = pick("COLD references"), pick("WARM references")
			if cd and wd and cd > 0 then
				out[#out + 1] = string.format("   delta definition: %+.1fms (%.0f%%)", wd - cd, (wd - cd) / cd * 100)
			end
			if cr and wr and cr > 0 then
				out[#out + 1] = string.format("   delta references: %+.1fms (%.0f%%)", wr - cr, (wr - cr) / cr * 100)
			end
			-- P1-7: one-line verdict under delta (1-2 lines total).
			local function verdict(cold, warm, cold_target)
				if not cold or not warm or cold <= 0 or warm <= 0 then
					return nil
				end
				if cold > warm * 2 and cold > 500 and cold_target == "modcache" then
					return "cold norm"
				end
				if cold > 1000 and warm > 1000 and math.abs(cold - warm) / math.max(cold, warm) < 0.3 then
					return "graph not indexed, not config"
				end
				return nil
			end
			local function cold_target(label)
				for _, rr in ipairs(cw.runs or {}) do
					if rr.label == label and rr.target then
						return target_class(rr.target)
					end
				end
				return nil
			end
			local vd = verdict(cd, wd, cold_target("COLD definition"))
			if vd then
				out[#out + 1] = "   verdict definition: " .. vd
			end
			local vr = verdict(cr, wr, cold_target("COLD references"))
			if vr then
				out[#out + 1] = "   verdict references: " .. vr
			end
		end
		out[#out + 1] = ""
		out[#out + 1] = " Render timings under --headless: н/д, нужен UI (nvim__redraw is a no-op without one)."
		out[#out + 1] = "   Run :DistroBench from a real terminal for redraw numbers."
		out[#out + 1] = ""
		out[#out + 1] = " q/Esc closes. Compare across machines by re-running."
		return out
	end

	local cw = cold_warm(function(done)
		if not buf or not vim.api.nvim_buf_is_valid(buf) or not win or not vim.api.nvim_win_is_valid(win) then
			return
		end
		set_lines(build(done))
	end)

	buf = vim.api.nvim_create_buf(false, true)
	set_lines = function(ls)
		vim.api.nvim_buf_set_option(buf, "modifiable", true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, ls)
		vim.api.nvim_buf_set_option(buf, "modifiable", false)
	end
	local initial = build(cw)
	set_lines(initial)
	win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = 78,
		height = math.min(#initial, vim.o.lines - 4),
		row = 2,
		col = math.max(1, (vim.o.columns - 78) / 2),
		style = "minimal",
		border = "rounded",
		title = "DistroBench",
	})
	local function back()
		pcall(vim.api.nvim_win_close, win, true)
	end
	vim.keymap.set("n", "q", back, { buffer = buf, nowait = true })
	vim.keymap.set("n", "<Esc>", back, { buffer = buf, nowait = true })
	return win
end

return M
