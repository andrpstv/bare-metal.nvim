-- Runtime benchmark: measures what the editor does ONCE RUNNING, not startup.
--
-- Usage (note -c luafile, NOT -l):
--   nvim --headless <file> --cmd 'let g:rtbench_label="ours"' -c 'luafile scripts/runtime-bench.lua'
--   nvim --clean --headless <file> --cmd 'let g:rtbench_label="clean"' -c 'luafile scripts/runtime-bench.lua'
--
-- Startup speed is deliberately NOT measured here: this measures the work
-- Neovim does during a session — parsing, highlighting, LSP round-trips and
-- redraws — which is what a user actually feels while editing.
--
-- Emits one JSON object on stdout under the marker line RUNTIME_BENCH_JSON:.

-- The file MUST be passed as a startup argument AND this script must be loaded
-- with `-c 'luafile ...'`, never with `-l`.
-- `nvim -l` runs the script before the config's BufReadPost/VimEnter path has
-- run, so filetype, treesitter and LSP never attach. Measured that way it
-- compares an editor doing nothing against a fully loaded one and manufactures
-- a fake speedup — we hit exactly that and threw those numbers away.
-- The script now refuses to run unless filetype really was detected.
local label = vim.g.rtbench_label or vim.v.argv[#vim.v.argv] or "run"

local function real_path(p)
	local ok, r = pcall(vim.fs.normalize, p)
	return ok and r or p
end

local bufname = vim.api.nvim_buf_get_name(0)
if bufname == "" or not vim.api.nvim_buf_is_loaded(0) or vim.fn.filereadable(bufname) == 0 then
	io.stderr:write("runtime-bench: buffer 0 is not a loaded file: '" .. bufname .. "'\n")
	io.stderr:write("usage: nvim --headless <file> --cmd 'let g:rtbench_label=\"x\"' -c 'luafile scripts/runtime-bench.lua'\n")
	vim.cmd("cq 2")
end

-- Guard against the exact false result described above: an editor with no
-- filetype is an editor doing no work, and its timings are meaningless.
local ft_seen = false
vim.wait(5000, function()
	ft_seen = vim.bo.filetype ~= "" and vim.bo.filetype ~= "off"
	return ft_seen
end, 50)
if not ft_seen then
	io.stderr:write("runtime-bench: filetype never detected on '" .. bufname .. "'\n")
	io.stderr:write("  load this with -c 'luafile', not -l, or the numbers are meaningless\n")
	vim.cmd("cq 3")
end

local function hr()
	return vim.uv.hrtime()
end

local function ms(t0, t1)
	return math.floor((t1 - t0) / 1e6 * 100) / 100
end

local out = { file = bufname, label = label, nvim = vim.version().major .. "." .. vim.version().minor }

-- Record any error Neovim raises while we work. Runtime safety is half the
-- brief: a fast config that throws E5113 on a real file is not shippable.
local errors = {}
local function capture_errors()
	local orig = vim.notify
	vim.notify = function(msg, lvl, o)
		if lvl and lvl >= vim.log.levels.ERROR then
			errors[#errors + 1] = tostring(msg)
		end
		return orig(msg, lvl, o)
	end
end
capture_errors()

local t0 = hr()
out.open_ms = ms(t0, hr())

out.lines = vim.api.nvim_buf_line_count(0)
out.bytes = vim.fn.getfsize(real_path(bufname))

-- Feature state matters more than any timing below. If LSP or treesitter has
-- not attached yet, the numbers compare a working editor against one that
-- has not started working, and the "speed" is meaningless. Wait for each to
-- settle (bounded), and report what was actually active so a reader can tell
-- whether two runs are comparable.
out.ft = vim.bo.filetype
out.syntax = tostring(vim.bo.syntax)

-- wait for filetype detection
vim.wait(5000, function()
	return vim.bo.filetype ~= "" and vim.bo.filetype ~= "off"
end, 50)

out.ft_after_wait = vim.bo.filetype
out.syntax_after_wait = tostring(vim.bo.syntax)

-- Treesitter: did a parser attach, and how long did the first parse take?
out.has_treesitter = false
pcall(function()
	vim.wait(5000, function()
		local ok2, p = pcall(vim.treesitter.get_parser, 0)
		return ok2 and p ~= nil
	end, 100)
end)
local ok, parser = pcall(function()
	local ok2, p = pcall(vim.treesitter.get_parser, 0)
	if ok2 and p then
		return p
	end
	return nil
end)
if ok and parser then
	out.has_treesitter = true
	local t = hr()
	pcall(function()
		parser:parse(true)
	end)
	out.ts_parse_ms = ms(t, hr())
end

-- Syntax highlighting cost, separate from treesitter.
local t = hr()
pcall(vim.cmd, "redraw")
out.first_redraw_ms = ms(t, hr())

-- Scrolling: move through the buffer and force a redraw each step. This is
-- the closest headless proxy for "does scrolling feel smooth".
local scroll_steps = math.min(out.lines, 2000)
local t = hr()
for i = 1, 10 do
	vim.api.nvim_win_set_cursor(0, { math.max(1, math.floor(out.lines * i / 10)), 0 })
	pcall(vim.cmd, "redraw")
end
out.scroll_10_gotos_redraw_ms = ms(t, hr())
out.scroll_steps_available = scroll_steps

-- Editing: insert then undo, on a real buffer. Measures the edit path, not
-- just the read path.
local t = hr()
local cur = vim.api.nvim_win_get_cursor(0)
vim.api.nvim_buf_set_lines(0, -1, -1, false, { "-- runtime-bench probe" })
out.insert_ms = ms(t, hr())
local t = hr()
pcall(vim.cmd, "undo")
out.undo_ms = ms(t, hr())
pcall(function()
	vim.api.nvim_win_set_cursor(0, cur)
end)

-- Jump to the end of the file: worst case for a large buffer.
local t = hr()
vim.api.nvim_win_set_cursor(0, { out.lines, 0 })
pcall(vim.cmd, "redraw")
out.goto_end_ms = ms(t, hr())

-- LSP: measure the round-trips a user feels, not just "did it attach".
-- gopls may still be starting; give it a bounded window so both runs are
-- compared with the same feature set, not with one side still warming up.
local lsp_t0 = hr()
if #vim.lsp.get_clients({ bufnr = 0 }) == 0 then
	vim.wait(15000, function()
		return #vim.lsp.get_clients({ bufnr = 0 }) > 0
	end, 100)
end
out.lsp_clients = #vim.lsp.get_clients({ bufnr = 0 })
out.lsp_attach_wait_ms = ms(lsp_t0, hr())
out.lsp_definition_ms = nil
out.lsp_hover_ms = nil
out.lsp_diag_ms = nil

if out.lsp_clients > 0 then
	local client = vim.lsp.get_clients({ bufnr = 0 })[1]
	local deadline = hr() + 15e9
	while hr() < deadline and #vim.diagnostic.get(0) == 0 do
		vim.wait(200, function()
			return false
		end)
	end
	out.lsp_diag_ms = ms(t0, hr())

	-- Find a symbol position to query.
	local line = nil
	for i = 1, math.min(out.lines, 400) do
		local text = vim.api.nvim_buf_get_lines(0, i - 1, i, false)[1]
		if text and text:match("^%s*(func|type|var|const)%s") then
			line = i
			break
		end
	end

	if line and client and client.supports_method("textDocument/definition") then
		local t = hr()
		pcall(function()
			vim.lsp.buf_request(0, "textDocument/definition", {
				textDocument = { uri = vim.uri_from_bufnr(0) },
				position = { line = line - 1, character = 0 },
			}, function() end)
			vim.wait(8000, function()
				return false
			end)
		end)
		out.lsp_definition_ms = ms(t, hr())
		out.lsp_query_line = line
	end
end

-- Memory: a config that looks fast but eats RAM will feel slow on weak PCs.
collectgarbage("collect")
out.mem_mb = math.floor(collectgarbage("count") / 1024 * 100) / 100

out.errors = errors
out.error_count = #errors

print("RUNTIME_BENCH_JSON:" .. vim.json.encode(out))
