-- scripts/regress-fx.lua — ASCII-анимации и «живой» интерфейс без TUI:
--   * dev.fx: changed_rows (правка/вставка/удаление), тикер (кадры, стоп по false
--     и снаружи), след внешней правки — в т.ч. насквозь через core.external
--     (видимый буфер — след есть, скрытый — нет);
--   * dev.bear: busy/done/wow/sleep/wake и приоритеты состояний;
--   * dev.start: финальный кадр = логотип + капли, шум на первом кадре, пункт
--     сессии только при сессии, узкое окно без логотипа, подсветки в границах строк;
--   * keymap/statusline: контекстная строка (проект, итог go test), морда медведя
--     и ошибки в статуслайне.
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-fx.lua
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

local fx = require("dev.fx")
local bear = require("dev.bear")
local start = require("dev.start")

-- ---------------------------------------------------------------- fx.changed_rows
local base = { "a", "b", "c", "d", "e" }
check("no change -> no rows", #fx.changed_rows(base, base) == 0)
local rows = fx.changed_rows(base, { "a", "B", "c", "d", "e" })
check("modified line -> its row", #rows == 1 and rows[1] == 1)
rows = fx.changed_rows(base, { "a", "b", "x", "y", "c", "d", "e" })
check("inserted lines -> both rows", #rows == 2 and rows[1] == 2 and rows[2] == 3)
rows = fx.changed_rows(base, { "a", "b", "d", "e" })
check("deleted line -> row it followed", #rows == 1 and rows[1] == 1)
rows = fx.changed_rows(base, { "b", "c", "d", "e" })
check("deleted first line -> row 0", #rows == 1 and rows[1] == 0)
local big_a, big_b = {}, {}
for i = 1, 3000 do
	big_a[i] = "x" .. i
	big_b[i] = "y" .. i
end
check("full rewrite capped at 1000 rows", #fx.changed_rows(big_a, big_b) == 1000)

-- ---------------------------------------------------------------- fx.ticker
local seen = {}
fx.ticker(5, function(i)
	seen[#seen + 1] = i
	return i < 3
end)
vim.wait(500, function()
	return #seen >= 3
end)
vim.wait(50)
check("ticker runs frames 1..3 and stops on false", #seen == 3 and seen[3] == 3)
local n = 0
local stop = fx.ticker(5, function()
	n = n + 1
end)
vim.wait(200, function()
	return n >= 2
end)
stop()
local frozen = n
vim.wait(60)
check("ticker stop() halts frames", n == frozen and n >= 2)
check("headless: animations disabled", fx.enabled() == false)

-- ---------------------------------------------------------------- fx.trail
local trail_ns = vim.api.nvim_create_namespace("dev_fx_trail")
local function trail_rows(buf)
	local out = {}
	for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, trail_ns, 0, -1, {})) do
		out[#out + 1] = m[2]
	end
	return out
end
local tb = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(tb, 0, -1, false, { "a", "B", "c", "x", "d", "e" })
fx.trail(tb, base)
local tr = trail_rows(tb)
check("trail marks changed rows (static without UI)", #tr == 2 and tr[1] == 1 and tr[2] == 3)
check("trail makes the bear say wow", bear.state() == "wow")
vim.wait(2000, function()
	return #trail_rows(tb) == 0
end)
check("static trail clears itself", #trail_rows(tb) == 0)
vim.wait(1000, function()
	return bear.state() == nil
end)
check("wow flash expires", bear.state() == nil)

-- ---------------------------------------------------------------- bear
bear.sleep()
check("idle -> sleeping", bear.sleeping() and bear.text() == "ʕ -ᴥ- ʔz")
bear.wake()
check("wake -> plain face", bear.state() == nil)
bear.busy("test")
check("busy -> spinner state", bear.state() == "busy")
check("busy text: face + still tail without UI", bear.text() == "ʕ ·ᴥ· ʔ~")
bear.busy("go")
bear.done("test", true)
check("one of two jobs done -> still busy", bear.state() == "busy")
bear.wow()
check("wow does not interrupt busy", bear.state() == "busy")
bear.done("go", false)
check("last job failed -> fail flash", bear.state() == "fail")
bear.sleep()
check("sleep does not override a flash", bear.state() == "fail")
bear.busy("test")
bear.done("test", true)
check("next green run -> pass flash", bear.state() == "pass" and bear.text():find("ᵔᴥᵔ", 1, true) ~= nil)

-- ---------------------------------------------------------------- start screen
local function seq(m)
	return m
end
local settle = start.settle_map(seq)
local info = { project = "demo", version = "0.12.5", ms = 41.4, session = false }
local lines, hls, crow = start.render(120, 40, info, start.FRAMES + 1, settle, seq)
local text = table.concat(lines, "\n")
local logo_ok = true
for _, l in ipairs(start.LOGO) do
	logo_ok = logo_ok and text:find(vim.pesc(l), 1) ~= nil
end
check("final frame shows the whole logo", logo_ok)
check("final frame shows drips", text:find("|", text:find(vim.pesc(start.LOGO[5])) + #start.LOGO[5], true) ~= nil)
check("info line: project, version, startup ms", text:find("demo · nvim 0.12.5 · ready in 41 ms", 1, true) ~= nil)
check("no session -> no restore item", not text:find("restore session", 1, true))
check("cursor on the first menu row", crow and lines[crow + 1]:find("[e]", 1, true) ~= nil)
local in_bounds = true
for _, h in ipairs(hls) do
	local l = lines[h[1] + 1]
	in_bounds = in_bounds and l ~= nil and h[2] >= 0 and h[3] <= #l and h[2] < h[3]
end
check("highlights stay inside their lines", in_bounds)
-- Кадр 1: rand всегда возвращает верхнюю границу — все символы ещё шум.
local first = start.render(120, 40, info, 1, start.settle_map(function(_, hi)
	return hi
end), function(_, hi)
	return hi
end)
local noisy = table.concat(first, "\n")
check("frame 1 is noise, not the logo", not noisy:find(vim.pesc(start.LOGO[2]), 1))
info.session = true
check("session -> restore item", table.concat(start.render(120, 40, info, start.FRAMES + 1, settle, seq), "\n"):find("restore session", 1, true) ~= nil)
local narrow = table.concat(start.render(40, 40, info, start.FRAMES + 1, settle, seq), "\n")
check("narrow window -> no logo, menu kept", not narrow:find(vim.pesc(start.LOGO[2]), 1) and narrow:find("[f]", 1, true) ~= nil)

-- ---------------------------------------------------------------- statusline + context bar
package.loaded["dev.project"] = {
	root = function()
		return "/work/demo-proj"
	end,
}
require("keymap.statusline")
check("tabline option points to the context bar", vim.o.tabline == "%!v:lua._tabline()")
local tl = _G._tabline()
check("context bar shows the project", tl:find("demo-proj", 1, true) ~= nil)
check("context bar: no test segment before a run", not tl:find("go test", 1, true))
package.loaded["dev.test"] = { last_summary = { pass = 3, fail = 0, ok = true } }
check("context bar: green run", _G._tabline():find("go test: %#StlMT#3 pkg ok", 1, true) ~= nil)
package.loaded["dev.test"].last_summary = { pass = 1, fail = 2, ok = false }
check("context bar: red run", _G._tabline():find("2 pkg failed", 1, true) ~= nil)
vim.g.gitsigns_head = "feature/x"
check("context bar shows the branch", _G._tabline():find("feature/x", 1, true) ~= nil)
vim.wait(3500, function()
	return bear.state() == nil
end)
check("pass flash expires to plain face", bear.state() == nil and bear.text() == nil)
check("statusline: plain mode face", _G._statusline():find("ʕ ᵔᴥᵔ ʔ NOR", 1, true) ~= nil)
local eb = vim.api.nvim_get_current_buf()
local dns = vim.api.nvim_create_namespace("regress_fx_diag")
vim.diagnostic.set(dns, eb, { { lnum = 0, col = 0, message = "boom", severity = vim.diagnostic.severity.ERROR } })
check("statusline: errors -> x face in normal", _G._statusline():find("ʕ xᴥx ʔ", 1, true) ~= nil)
bear.busy("test")
check("statusline: bear state beats the error face", _G._statusline():find("ʕ ·ᴥ· ʔ~ NOR", 1, true) ~= nil)
bear.done("test", true)
vim.diagnostic.reset(dns, eb)

-- ---------------------------------------------------------------- external -> trail
local ext = require("core.external")
vim.o.autoread = true
ext.setup()
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/agent.txt"
vim.fn.writefile({ "one", "two", "three" }, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
local fb = vim.api.nvim_get_current_buf()
ext.watch(fb)
vim.wait(100)
vim.fn.writefile({ "one", "TWO", "three", "four" }, path)
vim.wait(3000, function()
	return #trail_rows(fb) > 0
end)
local fr = trail_rows(fb)
check("external edit of a visible buffer -> trail on changed rows", #fr == 2 and fr[1] == 1 and fr[2] == 3)
-- Скрытый буфер: снимок не берётся, следа нет (но перезагрузка есть).
local hidden_path = dir .. "/hidden.txt"
vim.fn.writefile({ "a" }, hidden_path)
vim.cmd("badd " .. vim.fn.fnameescape(hidden_path))
local hb = vim.fn.bufnr(hidden_path)
vim.fn.bufload(hb)
ext.watch(hb)
vim.wait(100)
vim.fn.writefile({ "a", "b" }, hidden_path)
vim.wait(1500, function()
	return vim.api.nvim_buf_line_count(hb) == 2
end)
check("hidden buffer reloads", vim.api.nvim_buf_line_count(hb) == 2)
check("hidden buffer -> no trail", #trail_rows(hb) == 0)
ext._test_reset()
vim.fn.delete(dir, "rf")

print(string.format("total=%d failures=%d", total, failures))
os.exit(failures > 0 and 1 or 0)
