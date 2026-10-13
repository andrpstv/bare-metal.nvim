-- scripts/regress-testmarks.lua — результаты Go inline (dev.testmarks):
--   * разбор go test -json (pass/fail/skip, подтесты), бенчей, `cover -func`;
--   * дельта бенча (порог 5%), слияние прогонов, рендер в буфер, coverage_clear;
--   * сквозной путь dev.test._execute / coverage с заглушкой vim.system (go не нужен).
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-testmarks.lua
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

local tm = require("dev.testmarks")

local function ev(t)
	return vim.json.encode(t)
end

-- ---------------------------------------------------------------- parse tests
local res = tm._parse_tests({
	ev({ Action = "run", Test = "TestA" }),
	ev({ Action = "pass", Test = "TestA", Elapsed = 0.012 }),
	ev({ Action = "fail", Test = "TestB", Elapsed = 1.238 }),
	ev({ Action = "skip", Test = "TestC", Elapsed = 0 }),
	ev({ Action = "pass", Test = "TestA/sub", Elapsed = 0.1 }),
	ev({ Action = "pass", Package = "p", Elapsed = 1 }),
	"not json",
})
check("test pass parsed", res.TestA and res.TestA.status == "pass" and res.TestA.elapsed == 0.012)
check("test fail parsed", res.TestB and res.TestB.status == "fail")
check("test skip parsed", res.TestC and res.TestC.status == "skip")
check("subtest ignored", res["TestA/sub"] == nil)
check("package event ignored", vim.tbl_count(res) == 3)

-- ---------------------------------------------------------------- parse bench
local b = tm._parse_bench(table.concat({
	"BenchmarkFoo-8   \t 1000000\t      1840 ns/op\t      64 B/op\t       3 allocs/op",
	"BenchmarkBar\t100\t12.5 ns/op",
	"BenchmarkFoo/sub-8\t10\t5 ns/op",
	"PASS",
}, "\n"))
check("bench suffix stripped + allocs", b.BenchmarkFoo and b.BenchmarkFoo.ns == 1840 and b.BenchmarkFoo.allocs == 3)
check("bench optional fields / no suffix", b.BenchmarkBar and b.BenchmarkBar.ns == 12.5 and b.BenchmarkBar.allocs == nil)
check("sub-benchmark ignored", vim.tbl_count(b) == 2)

-- ---------------------------------------------------------------- delta
check("first run -> no delta", tm._delta(nil, 100) == nil)
local d = tm._delta(100, 112)
check("+12% up error", d.text == "▲+12%" and d.hl == "DiagnosticError")
d = tm._delta(100, 92)
check("-8% down ok", d.text == "▼-8%" and d.hl == "DiagnosticOk")
d = tm._delta(100, 103)
check("+3% approx", d.text == "≈" and d.hl == "Comment")

-- ---------------------------------------------------------------- cover -func
local cf = tm._parse_cover_func(
	"example.com/mod/pkg/file.go:12:\tFuncName\t\t73.3%\nexample.com/mod/pkg/file.go:30:\t(*T).M\t\t0.0%\ntotal:\t\t\t(statements)\t50.0%\n"
)
check("cover -func: two funcs, total ignored", #cf == 2)
check("cover -func fields", cf[1].file == "example.com/mod/pkg/file.go" and cf[1].lnum == 12 and cf[1].pct == 73.3)

-- ---------------------------------------------------------------- render
local function marks(buf, nsname)
	local ns = vim.api.nvim_get_namespaces()[nsname]
	local out = {}
	for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
		local text = ""
		for _, c in ipairs(m[4].virt_text) do
			text = text .. c[1]
		end
		out[m[2]] = { text = text, hl = m[4].virt_text[1][2], pos = m[4].virt_text_pos }
	end
	return out
end

local dir = "/tmp/x"
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(buf, dir .. "/foo_test.go")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
	"package x",
	"func TestA(t *testing.T) {}",
	"func TestB(t *testing.T) {}",
	"func TestC(t *testing.T) {}",
	"func BenchmarkFoo(b *testing.B) {}",
	"func helper() {}",
})

tm._reset()
tm.apply(dir, "test", {
	ev({ Action = "pass", Test = "TestA", Elapsed = 0.012 }),
	ev({ Action = "fail", Test = "TestB", Elapsed = 1.238 }),
	ev({ Action = "skip", Test = "TestC", Elapsed = 0 }),
})
local m = marks(buf, "devtest_results")
check("TestA mark row 1", m[1] and m[1].text == " ✓ 12ms" and m[1].hl == "DiagnosticOk" and m[1].pos == "eol")
check("TestB mark row 2", m[2] and m[2].text == " ✗ 1.24s" and m[2].hl == "DiagnosticError")
check("TestC mark row 3", m[3] and m[3].text == " ↷ skip" and m[3].hl == "Comment")
check("no mark on helper", m[5] == nil)

-- слияние: перезапуск одного теста обновляет только его метку
tm.apply(dir, "test", { ev({ Action = "fail", Test = "TestA", Elapsed = 0.02 }) })
m = marks(buf, "devtest_results")
check("merge updates TestA", m[1].text == " ✗ 20ms")
check("merge keeps TestB", m[2] and m[2].text == " ✗ 1.24s")

local blob = "BenchmarkFoo-8 \t100\t1000 ns/op\t8 B/op\t3 allocs/op\n"
tm.apply(dir, "bench", blob)
m = marks(buf, "devtest_bench")
check("bench first run no delta", m[4] and m[4].text == " 1000 ns/op · 3 allocs")
tm.apply(dir, "bench", "BenchmarkFoo-8 \t100\t1120 ns/op\t8 B/op\t3 allocs/op\n")
m = marks(buf, "devtest_bench")
check("bench second run delta", m[4] and m[4].text == " 1120 ns/op · 3 allocs ▲+12%")

-- повторный рендер идемпотентен
tm.render(buf)
check("render idempotent", vim.tbl_count(marks(buf, "devtest_results")) == 3)

-- буфер, открытый позже, получает метки через BufWinEnter
local late = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(late, dir .. "/late_test.go")
vim.api.nvim_buf_set_lines(late, 0, -1, false, { "package x", "func TestA(t *testing.T) {}" })
vim.api.nvim_set_current_buf(late)
vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = late })
check("late buffer rendered via BufWinEnter", marks(late, "devtest_results")[1] ~= nil)

-- чужой каталог не получает метки
local other = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(other, "/tmp/elsewhere/foo_test.go")
vim.api.nvim_buf_set_lines(other, 0, -1, false, { "func TestA(t *testing.T) {}" })
tm.render(other)
check("other dir not marked", vim.tbl_count(marks(other, "devtest_results")) == 0)

-- ---------------------------------------------------------------- coverage per func
local src = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(src, dir .. "/file.go")
vim.api.nvim_buf_set_lines(src, 0, -1, false, { "package x", "", "func Foo() {}", "func Bar() {}", "func Baz() {}" })
tm.apply_cover({
	{ file = "m/file.go", lnum = 3, pct = 73.3 },
	{ file = "m/file.go", lnum = 4, pct = 20 },
	{ file = "m/file.go", lnum = 5, pct = 100 },
	{ file = "m/gone.go", lnum = 1, pct = 100 },
}, function(f)
	return f == "m/file.go" and tm.canon(dir .. "/file.go") or nil
end)
m = marks(src, "devtest_covfunc")
check("cover 73% warn", m[2] and m[2].text == " 73%" and m[2].hl == "DiagnosticWarn")
check("cover 20% error", m[3] and m[3].text == " 20%" and m[3].hl == "DiagnosticError")
check("cover 100% ok", m[4] and m[4].text == " 100%" and m[4].hl == "DiagnosticOk")

-- сквозной: dev.test.coverage_clear чистит func-метки
local T = require("dev.test")
T.coverage_clear()
check("coverage_clear removes func marks", vim.tbl_count(marks(src, "devtest_covfunc")) == 0)

-- ---------------------------------------------------------------- сквозной _execute (vim.system заглушен)
tm._reset()
tm.render(buf) -- снять старые метки, чтобы ждать именно новые
local real_system = vim.system
---@diagnostic disable-next-line: duplicate-set-field
vim.system = function(argv, _, cb)
	cb({
		code = 0,
		stdout = ev({ Action = "pass", Test = "TestA", Elapsed = 0.5 }) .. "\n" .. ev({ Action = "pass", Package = "x" }),
		stderr = "",
	})
end
T._execute({ "go", "test", "-json" }, dir, "pkg", "test")
vim.wait(2000, function()
	return marks(buf, "devtest_results")[1] ~= nil
end, 20)
m = marks(buf, "devtest_results")
check("_execute renders test marks", m[1] and m[1].text == " ✓ 500ms")
vim.system = real_system

-- ---------------------------------------------------------------- фаза 2: живые тесты
local ls, rest = tm._split("", '{"a":1}\n{"b"')
check("split: целая строка + хвост", #ls == 1 and ls[1] == '{"a":1}' and rest == '{"b"')
ls, rest = tm._split(rest, ':2}\n\n')
check("split: хвост достраивается, пустая строка", #ls == 2 and ls[1] == '{"b":2}' and ls[2] == "" and rest == "")

local st = { running = {}, done = 0, total = 0, fail = 0 }
tm._live_reduce(st, { Action = "run", Test = "TestA" }, 1000)
tm._live_reduce(st, { Action = "run", Test = "TestB" }, 1000)
tm._live_reduce(st, { Action = "run", Test = "TestA/sub" }, 1000)
local nm, rs = tm._live_reduce(st, { Action = "fail", Test = "TestB", Elapsed = 2 }, 1500)
check("reduce: подтесты не считаются", st.total == 2)
check("reduce: fail -> done/fail, результат", nm == "TestB" and rs.status == "fail" and st.done == 1 and st.fail == 1 and st.running.TestB == nil)
check("live_text: до 150 мс пусто", tm._live_text({ t0 = 1000, st = st, frame = 0, anim = true }, 1100) == "")
local txt = tm._live_text({ t0 = 1000, st = st, frame = 2, anim = true }, 1200)
check("live_text: спиннер done/total · ✗N", txt:find("⠹", 1, true) and txt:find("1/2", 1, true) and txt:find("✗1", 1, true))
check("live_text: без анимаций статично", tm._live_text({ t0 = 0, st = st, frame = 2, anim = false }, 1200):find("…", 1, true) ~= nil)
check("live_text: компиляция (0 тестов) — «build», не «0/0»", tm._live_text({ t0 = 0, st = { done = 0, total = 0, fail = 0 }, frame = 0, anim = true }, 1200):find("build", 1, true) ~= nil)

-- сквозной: события -> метки на func-строках (спиннер, затем результат)
local ldir = vim.fn.tempname()
vim.fn.mkdir(ldir, "p")
local lbuf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(lbuf, ldir .. "/x_test.go")
vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, { "package x", "func TestZ(t *testing.T) {}" })
tm._reset()
tm.live_start(ldir) -- headless: fx.enabled() = false, статичный режим
tm.live_feed(ev({ Action = "run", Test = "TestZ" }))
local lm = vim.api.nvim_buf_get_extmarks(lbuf, vim.api.nvim_create_namespace("devtest_results"), 0, -1, { details = true })
check("live: у бегущего теста метка-спиннер", lm[1] and lm[1][4].virt_text[1][1]:find("…", 1, true) ~= nil)
tm.live_feed(ev({ Action = "pass", Test = "TestZ", Elapsed = 0.5 }))
lm = vim.api.nvim_buf_get_extmarks(lbuf, vim.api.nvim_create_namespace("devtest_results"), 0, -1, { details = true })
check("live: pass заменяет спиннер на ✓", lm[1] and lm[1][4].virt_text[1][1] == " ✓ 500ms")
tm.live_stop()
check("live_stop сбрасывает состояние", tm.live == nil)
tm._reset()

-- ---------------------------------------------------------------- фаза 2: конвейер check
local bd = require("dev.build")
local pipe = { frame = 2, anim = true, steps = { { name = "build", state = "ok" }, { name = "vet", state = "run" }, { name = "lint", state = "pend" } } }
local pt = bd._pipe_text(pipe, 0)
check("pipe: build ✓ teal", pt:find("[build %#StlMT#✓", 1, true) ~= nil)
check("pipe: vet спиннер", pt:find("[vet %#StlMV#⠹", 1, true) ~= nil)
check("pipe: lint pending", pt:find("[lint %#StlMeta#·", 1, true) ~= nil)
check("pipe: клик с индексом шага", pt:find("%2@v:lua._tl_check_click@", 1, true) ~= nil and pt:find("%X", 1, true) ~= nil)
pipe.steps[1].state, pipe.steps[2].state = "fail", "fail"
check("pipe: fail красный", bd._pipe_text(pipe, 0):find("%#DiagnosticError#✗", 1, true) ~= nil)
pipe.done_at = 1000
check("pipe: после 60 с пусто", bd._pipe_text(pipe, 62000) == "" and bd._pipe_text(pipe, 30000) ~= "")
local its = { { text = "[build] a" }, { text = "[vet] b" }, { text = "[vet] c" } }
check("pipe: фильтр элементов шага", #bd._pipe_items(its, "vet") == 2 and #bd._pipe_items(its, "lint") == 0)

-- ---------------------------------------------------------------- фаза 2: новые диагностики
local nd = require("dev.newdiag")
local snap = { ["foo\0boom"] = 1 }
local rows = nd._new(snap, { { lnum = 5, key = "foo\0boom" }, { lnum = 9, key = "bar\0bad" }, { lnum = 7, key = "foo\0boom" } })
check("newdiag: старая ошибка со сдвигом строки не новая, дубль и новая — да", #rows == 2 and rows[1] == 7 and rows[2] == 9)
check("newdiag: пустой снимок — всё новое", #nd._new({}, { { lnum = 1, key = "k" } }) == 1)

print(string.format("total=%d failures=%d", total, failures))
os.exit(failures > 0 and 1 or 0)
