-- distroManager benchui — UI render benchmark for the LIVE session.
-- Measures the Lua side of the render pipeline (NOT monitor vsync/GPU):
-- statusline eval, :redraw, splits, treesitter parse, folds, float open.
-- Pure Lua, Windows-safe. Open with :DistroBenchUI. Restores your layout after.

local M = {}

local function ms(t0)
	return (vim.uv.hrtime() - t0) / 1e6
end

--- Average over n runs of fn (fn must be side-effect free-ish).
local function avg(n, fn)
	local best = nil
	for _ = 1, n do
		local t0 = vim.uv.hrtime()
		local ok = pcall(fn)
		local dt = ms(t0)
		if ok and (not best or dt < best) then
			best = dt
		end
	end
	return best
end

local function fmt(v)
	if v == nil then
		return "n/a"
	end
	if v < 0.01 then
		return string.format("%.0fµs", v * 1000)
	elseif v < 1 then
		return string.format("%.2fms", v)
	end
	return string.format("%.1fms", v)
end

function M.run()
	local cur_win, cur_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
	local cur_view = vim.fn.winsaveview()
	local lines = { " DistroBenchUI — render pipeline (Lua side), best-of-N.", "" }

	-- 1. statusline: what every redraw pays
	local sl = avg(100, function()
		if _G._statusline then
			_G._statusline()
		end
	end)
	lines[#lines + 1] = string.format(" statusline eval (x100 best):  %s / redraw", fmt(sl))

	-- 2. full redraw (bang: force real work, no early-out)
	local rd = avg(10, function()
		vim.cmd("redraw!")
	end)
	lines[#lines + 1] = string.format(" :redraw! (x10 best):           %s", fmt(rd))

	-- 3. splits: 2x2 grid, redraw, then close ONLY what we opened
	local sp
	do
		local before = {}
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			before[w] = true
		end
		vim.cmd("vsplit")
		vim.cmd("split")
		pcall(vim.cmd, "wincmd j")
		vim.cmd("split")
		sp = avg(5, function()
			vim.cmd("redraw!")
		end)
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			if not before[w] and vim.api.nvim_win_is_valid(w) then
				pcall(vim.api.nvim_win_close, w, true)
			end
		end
	end
	lines[#lines + 1] = string.format(" redraw with 4 splits (x5 best): %s", fmt(sp))

	-- back to the user's context BEFORE the remaining tests (they assume it)
	pcall(vim.api.nvim_set_current_win, cur_win)
	if vim.api.nvim_buf_is_valid(cur_buf) then
		pcall(vim.api.nvim_win_set_buf, cur_win, cur_buf)
	end
	pcall(vim.fn.winrestview, cur_view)

	-- 4. treesitter full parse of the current buffer (if a parser is attached)
	local parse_ms, parse_note = nil, nil
	do
		local ok, parser = pcall(vim.treesitter.get_parser, cur_buf)
		if ok and parser then
			parse_ms = avg(3, function()
				parser:parse(true)
			end)
		else
			parse_note = "no parser for this buffer"
		end
	end
	lines[#lines + 1] = string.format(" treesitter parse current buf:  %s", parse_ms and fmt(parse_ms) or parse_note)

	-- 5. folds recompute (zx) + restore view
	local fold_ms = avg(3, function()
		vim.cmd("silent! normal! zx")
	end)
	pcall(vim.fn.winrestview, cur_view)
	lines[#lines + 1] = string.format(" folds recompute zx (x3 best):   %s", fmt(fold_ms))

	-- 6. float open: our own :Distro render + window (excl. interaction)
	local float_ms = avg(3, function()
		local ok_ui, ui = pcall(require, "distro.ui")
		if not ok_ui then
			return
		end
		local ui_lines = ui.render()
		local b = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(b, 0, -1, false, ui_lines)
		local w = vim.api.nvim_open_win(b, false, {
			relative = "editor",
			width = 60,
			height = 10,
			row = 2,
			col = 2,
			style = "minimal",
			border = "rounded",
		})
		pcall(vim.api.nvim_win_close, w, true)
		pcall(vim.api.nvim_buf_delete, b, { force = true })
	end)
	lines[#lines + 1] = string.format(" float render+open (x3 best):   %s", fmt(float_ms))

	-- 7. file open render: :edit + :redraw!, cold (bwipeout first) vs warm.
	-- Cold pays disk read + FileType chain; warm pays re-read + redraw.
	-- Compares directly against clean nvim (there: read + redraw only).
	local function test_file(name, nlines)
		local dir = vim.fn.stdpath("cache") .. "/distro-bench"
		vim.fn.mkdir(dir, "p")
		local p = dir .. "/" .. name
		if vim.fn.filereadable(p) ~= 1 then
			local f = assert(io.open(p, "w"))
			for i = 1, nlines do
				f:write(string.format("line %06d " .. string.rep("x", 40) .. "\n", i))
			end
			f:close()
		end
		return p
	end
	local function wipe_by_name(path)
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_get_name(b) == path then
				pcall(vim.cmd, "bwipeout! " .. b)
			end
		end
	end
	local function open_render(path, cold)
		if cold then
			wipe_by_name(path)
		end
		local t0 = vim.uv.hrtime()
		local ok = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
		if not ok then
			return nil
		end
		pcall(vim.cmd, "redraw!")
		return ms(t0)
	end
	for _, item in ipairs({ { "open small cold", "open-small.txt", 100, true }, { "open small warm", "open-small.txt", 100, false }, { "open big cold", "open-big.txt", 20000, true }, { "open big warm", "open-big.txt", 20000, false } }) do
		local label, fname, nlines, cold = item[1], item[2], item[3], item[4]
		local p = test_file(fname, nlines)
		local best = nil
		for _ = 1, cold and 1 or 3 do
			local dt = open_render(p, cold)
			if dt and (not best or dt < best) then
				best = dt
			end
		end
		lines[#lines + 1] = string.format(" %-28s %s", label .. ":", best and fmt(best) or "n/a")
	end

	-- 8. buffer switch render: alternate two loaded buffers + redraw.
	do
		local f1 = test_file("open-small.txt", 100)
		local f2 = test_file("open-big.txt", 20000)
		pcall(vim.cmd, "edit " .. vim.fn.fnameescape(f1))
		pcall(vim.cmd, "edit " .. vim.fn.fnameescape(f2))
		local best = avg(3, function()
			pcall(vim.cmd, "bprev")
			pcall(vim.cmd, "redraw!")
			pcall(vim.cmd, "bnext")
			pcall(vim.cmd, "redraw!")
		end)
		-- avg wraps the pair; halve for per-switch
		lines[#lines + 1] = string.format(" buffer switch + redraw:        %s", best and fmt(best / 2) or "n/a")
	end

	-- 9. hotkey-to-picker: <leader>ff equivalent, time until picker visible.
	-- MiniPick.builtin.* is a BLOCKING modal loop, so a plain call would hang
	-- the bench: queue <Esc> into typeahead first; the loop consumes it right
	-- after first render and aborts. Measured ~= open + first draw + abort.
	do
		local pick_ms = nil
		if _G._pick ~= nil then
			local t0 = vim.uv.hrtime()
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "t", false)
			local ok = pcall(_G._pick, "files")
			if ok then
				pick_ms = ms(t0)
			end
			pcall(function()
				require("mini.pick").stop()
			end)
		end
		lines[#lines + 1] = string.format(" hotkey files-picker visible:   %s", pick_ms and fmt(pick_ms) or "n/a (pick unavailable)")
	end

	-- restore layout
	pcall(vim.api.nvim_set_current_win, cur_win)
	if vim.api.nvim_buf_is_valid(cur_buf) then
		pcall(vim.api.nvim_win_set_buf, cur_win, cur_buf)
	end
	pcall(vim.fn.winrestview, cur_view)

	lines[#lines + 1] = ""
	lines[#lines + 1] = " Honest scope: Lua-side costs. GPU/monitor vsync not measurable"
	lines[#lines + 1] = " from inside. q/Esc closes."
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "filetype", "distro-benchui")
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = 74,
		height = math.min(#lines, vim.o.lines - 4),
		row = 2,
		col = math.max(1, (vim.o.columns - 74) / 2),
		style = "minimal",
		border = "rounded",
		title = "DistroBenchUI",
	})
	local function back()
		pcall(vim.api.nvim_win_close, win, true)
	end
	vim.keymap.set("n", "q", back, { buffer = buf, nowait = true })
	vim.keymap.set("n", "<Esc>", back, { buffer = buf, nowait = true })
end

return M
