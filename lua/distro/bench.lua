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

function M.run()
	local lines = { " DistroBench — this machine, min-of-3, wall clock.", "" }
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
			" gd/gr RTT (best-of-3 here): definition %sms · references %sms",
			rtt.definition ~= nil and rtt.definition or "?",
			rtt.references ~= nil and rtt.references or "?"
		)
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = " q/Esc closes. Compare across machines by re-running."
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "filetype", "distro-bench")
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = 78,
		height = math.min(#lines, vim.o.lines - 4),
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
end

return M
