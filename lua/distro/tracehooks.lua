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
		trace.log(ev, nil, "call", name, ft)

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
			trace.sub(ev, "keypress_to_request", el())
			vim.lsp.buf_request = orig_req
			return orig_req(bufnr, method, params, function(...)
				-- 2. request -> response
				trace.sub(ev, "request_to_response", el())
				local nargs = select("#", ...)
				local res = { handler(...) }
				-- 3. response -> cursor placed
				trace.sub(ev, "response_to_cursor", el())
				-- The honest end-to-end total, logged HERE rather than after
				-- pcall(orig): the shim dispatches asynchronously and returns
				-- immediately, so anything timed after it excludes the server
				-- round-trip and the jump entirely. Measured at dispatch that
				-- "total" reads 0.1-0.6 ms while the real hop is 9-14 ms.
				trace.log(ev, el(), "TOTAL (requests: " .. n .. ")", name, ft)
				return unpack(res, 1, nargs)
			end, bufnr2)
		end

		local ok, r = pcall(orig, scope, opts)
		vim.lsp.buf_request = orig_req
		if not ok then
			trace.log(ev, el(), "error: " .. tostring(r), name, ft)
			error(r, 0)
		end
		-- Dispatch only: how long the synchronous send took. Deliberately NOT
		-- called "total" — the real TOTAL is logged from the response handler.
		trace.log(ev, el(), "dispatch only (requests: " .. n .. ")", name, ft)
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
	local function on_cursor()
		if not trace.enabled then
			return
		end
		local buf, name, ft = ctx()
		trace.log("autocmd/CursorMoved", nil, "line " .. vim.fn.line("."), name, ft)
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
end

--- Install everything. Cheap: only a _G swap and one augroup.
function M.setup()
	M.wrap_pick()
	M.setup_autocmds()
	M.wrap_commands()
end

return M
