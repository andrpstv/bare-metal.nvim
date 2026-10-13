-- scripts/regress-ide.lua — информативные мелочи интерфейса без TUI и без конфига:
--   * core.fold: текст свёртки = первая строка + «··· N lines»;
--   * dev.gcdetails: короткие метки решений компилятора (тексты — с настоящего gopls 0.22),
--     вырезка из publishDiagnostics, метки в буфере;
--   * dev.scrollbar: раскладка меток по строкам полосы, приоритет, ползунок, флоат;
--   * dev.agentmine: «ваши правки до сессии» = изменено от HEAD минус изменено от базы;
--   * keymap/statusline: прогресс LSP в статуслайне, хлебные крошки в winbar;
--   * core.external: место последней внешней правки + follow().
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-ide.lua
-- Exit 0 when all cases pass, 1 otherwise. No network, no user config.

local failures = 0
local total = 0

local function check(desc, cond)
	total = total + 1
	if cond then
		print("OK " .. desc)
	else
		failures = failures + 1
		print("FAIL " .. desc)
	end
end

---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function() end

local function scratch(lines, name)
	local b = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
	if name then
		vim.api.nvim_buf_set_name(b, name)
	end
	return b
end

-- ---------------------------------------------------------------- core.fold
local fb = scratch({ "local function f()", "\treturn 1", "end", "x = 1" })
vim.api.nvim_set_current_buf(fb)
vim.bo[fb].filetype = "lua"
pcall(vim.treesitter.start, fb, "lua")
vim.wo.foldmethod = "manual"
vim.wo.foldtext = "v:lua.require'core.fold'.text()"
vim.cmd("1,3fold")
local ft = vim.fn.foldtextresult(1)
check("fold text keeps the first line", ft:find("local function f()", 1, true) ~= nil)
check("fold text counts hidden lines", ft:find("··· 3 lines", 1, true) ~= nil)
local chunks = vim.api.nvim_win_call(0, function()
	return vim.api.nvim_eval("v:lua.require'core.fold'.text()")
end)
check("fold text is a chunk list (highlighted)", type(chunks) == "table" and type(chunks[1]) == "table")

-- ---------------------------------------------------------------- dev.gcdetails
local gc = require("dev.gcdetails")
check("escape -> ↑name", gc._short("escape(t escapes to heap)") == "↑t")
check("moved to heap -> ↑name", gc._short("escape(moved to heap: buf)") == "↑buf")
check("empty escape() is noise", gc._short("escape()") == nil)
check("compiler temporaries (~r0) are noise", gc._short("escape(~r0 escapes to heap)") == nil)
check("composite literal keeps only the type", gc._short("escape(&Square{...} escapes to heap)") == "↑&Square")
check("canInline -> inl", gc._short("canInlineFunction(cost: 12)") == "inl")
check("cannotInline -> no-inl", gc._short("cannotInlineFunction(function too complex: cost 108 exceeds budget 80)") == "no-inl")
check("inlineCall -> inl name", gc._short("inlineCall(fmt.Println)") == "inl Println")
local function d(line, msg, source)
	return { range = { start = { line = line, character = 0 }, ["end"] = { line = line, character = 1 } }, message = msg, source = source or gc.SOURCE, severity = 3 }
end
local agg = gc._lines({ d(4, "escape(t escapes to heap)"), d(4, "escape(t escapes to heap)"), d(4, "canInlineFunction(cost: 4)"), d(5, "escape()") })
check("per-line aggregation, deduped", agg[4] == "↑t · inl" and agg[5] == nil)
local gpath = vim.fn.tempname() .. ".go"
vim.fn.writefile({ "package main", "", "func f() {}", "", "func g() {}" }, gpath)
vim.cmd("edit " .. vim.fn.fnameescape(gpath))
local gb = vim.api.nvim_get_current_buf()
local passed
local real_publish = vim.lsp.diagnostic.on_publish_diagnostics
vim.lsp.diagnostic.on_publish_diagnostics = function(_, result)
	passed = result
end
gc.on_publish(nil, {
	uri = vim.uri_from_fname(vim.api.nvim_buf_get_name(gb)),
	diagnostics = { d(2, "canInlineFunction(cost: 4)"), d(4, "undefined: x", "compiler") },
}, { client_id = 1 })
local ok_bad = pcall(gc.on_publish, nil, { uri = "", diagnostics = { d(1, "undefined: y", "compiler") } }, { client_id = 1 })
check("uri without a scheme: no crash, diagnostics passed through", ok_bad and passed and #passed.diagnostics == 1)
gc.on_publish(nil, {
	uri = vim.uri_from_fname(vim.api.nvim_buf_get_name(gb)),
	diagnostics = { d(2, "canInlineFunction(cost: 4)"), d(4, "undefined: x", "compiler") },
}, { client_id = 1 })
vim.lsp.diagnostic.on_publish_diagnostics = real_publish
check("optimizer details cut from the diagnostics stream", passed and #passed.diagnostics == 1 and passed.diagnostics[1].source == "compiler")
local gns = vim.api.nvim_create_namespace("dev_gcdetails")
local gm = vim.api.nvim_buf_get_extmarks(gb, gns, 0, -1, { details = true })
check("optimizer details drawn as a quiet eol mark", #gm == 1 and gm[1][2] == 2 and gm[1][4].virt_text[1][1]:find("inl", 1, true))

-- ---------------------------------------------------------------- dev.scrollbar
local sb = require("dev.scrollbar")
local rows, t1, t2 = sb._layout({ { 10, "add" }, { 10, "error" }, { 90, "warn" } }, 100, 10, 1, 20)
check("scrollbar: error beats git on the same row", rows[1] == "error")
check("scrollbar: warn at the bottom", rows[9] == "warn")
check("scrollbar: thumb covers the visible part", t1 == 0 and t2 == 1)
local long = {}
for i = 1, 300 do
	long[i] = "line " .. i
end
local lb = scratch(long)
vim.api.nvim_set_current_buf(lb)
local dns = vim.api.nvim_create_namespace("regress_ide_diag")
vim.diagnostic.set(dns, lb, { { lnum = 150, col = 0, message = "boom", severity = vim.diagnostic.severity.ERROR } })
sb.render()
local bar
for _, w in ipairs(vim.api.nvim_list_wins()) do
	if vim.api.nvim_win_get_config(w).relative ~= "" then
		bar = w
	end
end
check("scrollbar: float opened for a long buffer", bar ~= nil)
local bl = bar and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(bar), 0, -1, false) or {}
check("scrollbar: one row per window line", #bl == vim.api.nvim_win_get_height(0))
check("scrollbar: error mark present", table.concat(bl):find("━", 1, true) ~= nil)
vim.api.nvim_set_current_buf(fb)
sb.render()
check("scrollbar: hidden when the file fits the window", not (bar and vim.api.nvim_win_is_valid(bar)))

-- ---------------------------------------------------------------- dev.agentmine
local am = require("dev.agentmine")
local head = { "a", "b", "c", "d", "e" }
local base = { "a", "B", "c", "d", "e" } -- вы до сессии поменяли строку 2
local cur = { "a", "B", "c", "D", "e" } -- агент потом поменял строку 4
local mine = am._mine(head, base, cur)
check("agentmine: only your pre-session line", #mine == 1 and mine[1] == 1)
cur = { "x", "y", "a", "B", "c", "D", "e" } -- агент вставил 2 строки сверху: ваша строка съехала
mine = am._mine(head, base, cur)
check("agentmine: follows lines shifted by the agent", #mine == 1 and mine[1] == 3)
check("agentmine: line you and the agent both changed counts as agent's", #am._mine(head, base, { "a", "Z", "c", "d", "e" }) == 0)

-- ---------------------------------------------------------------- statusline: progress + crumbs
package.loaded["dev.project"] = {
	root = function()
		return "/work/demo"
	end,
}
require("keymap.statusline")
local function progress(kind, value)
	value.kind = kind
	vim.api.nvim_exec_autocmds("LspProgress", {
		pattern = kind,
		data = { client_id = 77, params = { token = "load", value = value } },
	})
end
progress("begin", { title = "Loading packages", percentage = 10 })
local st = _G._statusline()
check("statusline: progress title + percent", st:find("Loading packages 10%%", 1, true) ~= nil)
progress("report", { message = "3/12", percentage = 40 })
st = _G._statusline()
check("statusline: report keeps the title", st:find("Loading packages: 3/12 40%%", 1, true) ~= nil)
progress("end", {})
check("statusline: progress gone after end", not _G._statusline():find("Loading packages", 1, true))

local cb = scratch({ "local M = {}", "function M.start()", "\tlocal function say()", "\t\treturn 1", "\tend", "end", "return M" })
vim.api.nvim_set_current_buf(cb)
vim.bo[cb].filetype = "lua"
vim.treesitter.get_parser(cb, "lua"):parse()
vim.api.nvim_win_set_cursor(0, { 4, 0 })
-- winbar рисуется только для файловых буферов с именем — даём имя.
vim.api.nvim_buf_set_name(cb, vim.fn.tempname() .. ".lua")
package.loaded["modules.utils"] = {
	is_file_buffer = function()
		return true
	end,
}
local wb = _G._winbar()
check("winbar: crumbs outer › inner", wb:find("M.start", 1, true) ~= nil and wb:find("say", 1, true) ~= nil
	and wb:find("M.start", 1, true) < wb:find("say", 1, true))
vim.api.nvim_win_set_cursor(0, { 7, 0 })
check("winbar: no crumbs outside functions", not _G._winbar():find("M.start", 1, true))

-- ---------------------------------------------------------------- core.external: last edit + follow
local ext = require("core.external")
vim.o.autoread = true
ext.setup()
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/agent.txt"
vim.fn.writefile({ "one", "two", "three" }, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
local eb = vim.api.nvim_get_current_buf()
ext.watch(eb)
vim.wait(100)
vim.fn.writefile({ "one", "two", "THREE" }, path)
vim.wait(3000, function()
	return ext.last_edit ~= nil
end)
check("last external edit recorded with its row", ext.last_edit and ext.last_edit.buf == eb and ext.last_edit.row == 2)
check("context bar shows where the edit landed", _G._tabline():find("agent.txt:3", 1, true) ~= nil)
vim.cmd("enew")
ext.follow()
check("follow jumps to the edited buffer and line", vim.api.nvim_get_current_buf() == eb and vim.api.nvim_win_get_cursor(0)[1] == 3)
ext._test_reset()
vim.fn.delete(dir, "rf")

print(string.format("total=%d failures=%d", total, failures))
os.exit(failures > 0 and 1 or 0)
