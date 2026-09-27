-- Регрессия PERF-1D: карточка span-а вьюера не имеет права приписывать
-- простой нашей строке (traceui.lua, M.detail).
--
-- Что проверяется, по фактам PERF-1A
-- (docs/distro/29-trace-delta-forensics.md):
--   * старая формула `delta = x.at - prev_at` — это gap ДО строки, а не её
--     стоимость; мгновенная строка (dur=nil) забирала в Δ весь простой перед
--     собой: autocmd/CursorMoved в логе 484230425125 печатался с Δ 4478.898 ms
--     при собственном времени 0;
--   * подпись "own dur" печатала x.dur — это кумулятивное поле 4, а не
--     собственное поле 11 (own_ms);
--   * хвост окна терялся молча.
--
-- Тест НАМЕРЕННО разбирает ОБА формата карточки (старый и новый), чтобы один
-- и тот же бинарник можно было прогнать ДО фикса и ПОСЛЕ него: на старом коде
-- проверки обязаны падать, иначе они ничего не доказывают.
--
-- Запуск:
--   nvim --headless --clean -c 'luafile scripts/test-traceui-gap.lua'
-- Выход: 0 = все проверки прошли, 1 = есть проваленная.

local failures = {}
local checks = 0
local skipped = 0

local function check(ok, label)
	checks = checks + 1
	if not ok then
		failures[#failures + 1] = label
		print("  FAIL: " .. label)
	else
		print("  ok: " .. label)
	end
end

local DASH = "\u{2014}" -- то, чем помечается «числа нет»
local LOGDIR = vim.fn.expand("~/.cache/nvim/distro-trace")

pcall(function()
	vim.o.lines = 90
	vim.o.columns = 220
end)

-- `--clean` не кладёт репозиторий в runtimepath, поэтому require не находит
-- модуль. Кладём явно, иначе тест «падает» на подгрузке, а не на сути.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local traceui = require("distro.traceui")

-- ---- оракул: читаем лог напрямую, мимо вьюера ------------------------------
-- Ожидаемые величины берутся из самого лога, а не из вывода вьюера: иначе тест
-- согласился бы с любым его враньём, которое сам же и вызвал.
local function read_log(path)
	local rows = {}
	for _, l in ipairs(vim.fn.readfile(path)) do
		local x = traceui._parse(l)
		if x then
			rows[#rows + 1] = x
		end
	end
	table.sort(rows, function(a, b)
		return a.seq < b.seq
	end)
	return rows
end

-- Строки окна — предикат, выписанный здесь заново по данным лога, чтобы
-- проверка не была само-ссылкой на ту же строку кода, что и проверяет.
local function expected_window(rows, r)
	local out = {}
	if not r.dur then
		return out
	end
	local lo, hi = r.at - r.dur - 1, r.at + 1
	for _, x in ipairs(rows) do
		if x.run == r.run and x.at >= lo and x.at <= hi and x.seq ~= r.seq then
			out[#out + 1] = x
		end
	end
	return out
end

-- ---- разбор карточки, толерантный к обоим форматам -------------------------
-- Возвращает { fmt = "new"|"old", rows = { {event=, own=, gap=}, ... } }.
local function scan_card(lines)
	local out = { rows = {} }
	for _, l in ipairs(lines) do
		local mark, own, gap, unit, seq, ev =
			l:match("^%s*(%a+)%s+own%s+(%S+)%s+gap%s+(%S+)%s*(%a*)%s+#(%d+)%s+(%S+)%s*(.*)$")
		if mark then
			out.fmt = "new"
			out.rows[#out.rows + 1] = { event = ev, own = own, gap = gap, seq = tonumber(seq), mark = mark }
		else
			local cum, d, e, rest = l:match("^%s*cum%s+(%S+)%s+\u{0394}%s+(%S+)%s+ms%s+(%S+)%s*(.*)$")
			if cum then
				out.fmt = out.fmt or "old"
				local od = rest and rest:match("own dur%s+(%S+)")
				out.rows[#out.rows + 1] = { event = e, cum = cum, gap = d, own = od }
			end
		end
	end
	return out
end

-- Найти в карточке строку по имени события (nth по счёту, 1-based).
local function nth(rows, event, n)
	local seen = 0
	for _, row in ipairs(rows) do
		if row.event == event then
			seen = seen + 1
			if seen == n then
				return row
			end
		end
	end
	return nil
end

-- Числовое значение ячейки, или nil, если там прочерк.
local function num(v)
	if v == nil or v == DASH then
		return nil
	end
	return tonumber((v:gsub("ms", "")))
end

-- Открыть карточку span-а и вернуть её строки + распознанные факты.
local function card(path, rows, seq)
	local r
	for _, x in ipairs(rows) do
		if x.seq == seq then
			r = x
		end
	end
	if not r then
		return nil, nil, "нет строки seq=" .. seq
	end
	traceui.detail(path, r)
	local b = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
	pcall(vim.api.nvim_win_close, 0, true)
	return lines, scan_card(lines), r
end

-- ---------------------------------------------------------------------------
-- Проверка одного лога.
-- ---------------------------------------------------------------------------
local function verify(path, span_seq, headline, want_own, want_not_own, label)
	print("")
	print(("== %s (%s, span seq %d) =="):format(label, vim.fn.fnamemodify(path, ":t"), span_seq))
	local rows = read_log(path)
	local lines, got, r = card(path, rows, span_seq)
	if not got then
		check(false, label .. ": карточка не открылась — " .. tostring(r))
		return
	end

	local exp = expected_window(rows, r)
	local tag = "[fmt=" .. tostring(got.fmt) .. "]"

	-- 1. Ни одна строка лога не потеряна: хвост/пропуск — тоже молчание.
	check(#got.rows == #exp, ("%s %s карточка печатает все %d строк окна (напечатано %d)"):format(
		tag, label, #exp, #got.rows))

	-- 2. ГЛАВНОЕ: мгновенной строке (dur=nil) нельзя достаться ненулевой gap.
	--    В старом коде именно это и лгало: gap ДО строки выдавался за её цену.
	local instant_rows, bad = 0, {}
	for i, row in ipairs(got.rows) do
		local x = exp[i]
		if x and x.dur == nil then
			instant_rows = instant_rows + 1
			local g = num(row.gap)
			if g ~= nil and g ~= 0 then
				bad[#bad + 1] = ("seq %d %s: gap %.3f ms при собственной стоимости 0"):format(x.seq, x.event, g)
			end
		end
	end
	check(instant_rows > 0, ("%s %s в окне есть мгновенные строки (%d) — иначе проверка пустая"):format(
		tag, label, instant_rows))
	check(#bad == 0, ("%s %s мгновенные строки не получают ненулевой gap%s"):format(
		tag, label, #bad == 0 and "" or (": " .. table.concat(bad, "; "))))

	-- 3. Собственная стоимость — поле 11 (own_ms), а не кумулятивное поле 4.
	local hl = nth(got.rows, headline, 1)
	check(hl ~= nil, ("%s %s карточка содержит строку %s"):format(tag, label, headline))
	if hl then
		local o = num(hl.own)
		local extra = (o == nil) and (" — в карточке: " .. tostring(hl.own)) or ""
		check(o ~= nil and math.abs(o - want_own) < 0.001,
			("%s %s %s печатает own = %.3f (поле 11 own_ms)%s"):format(tag, label, headline, want_own, extra))
		check(o == nil or math.abs(o - want_not_own) > 0.001,
			("%s %s %s НЕ печатает кумулятивное поле 4 = %.3f под подписью own"):format(tag, label, headline, want_not_own))
	end

	-- 4. Хвост окна закрыт вслух, а не выброшен молча.
	local has_accounting = false
	for _, l in ipairs(lines) do
		if l:match("own_ms total") then
			has_accounting = true
		end
	end
	check(has_accounting, ("%s %s карточка печатает блок accounting (хвост окна не теряется молча)"):format(tag, label))
end

print("DistroTrace card regression — PERF-1D")
print("Логи: " .. LOGDIR)

verify(LOGDIR .. "/distro-trace-484230425125.log", 123,
	"pick_lsp/definition/request_to_response", 5237.924, 5238.042, "лог 484230425125")

verify(LOGDIR .. "/distro-trace-544190817791.log", 107,
	"pick_lsp/definition/request_to_response", 142.046, 142.172, "лог 544190817791")

-- ---------------------------------------------------------------------------
-- Третий лог НЕ является опровержением: там нечем открыть карточку.
-- Фиксируем это честно, а не как «баг не воспроизводится».
-- ---------------------------------------------------------------------------
print("")
print("== лог 813143361750 — ПРОВЕРКА НЕВОЗМОЖНА (не «баг не найден») ==")
local p3 = LOGDIR .. "/distro-trace-813143361750.log"
if vim.fn.filereadable(p3) == 1 then
	local rows3 = read_log(p3)
	local timed, spans = 0, 0
	for _, x in ipairs(rows3) do
		if x.dur and x.dur > 0 then
			timed = timed + 1
		end
		if x.dur and x.dur > 1 then
			spans = spans + 1
		end
	end
	print(("  строк с dur>0: %d, кандидатов в span (>1 ms): %d — карточку открыть не на чем"):format(timed, spans))
	if spans > 0 then
		skipped = skipped + 1
		print("  кандидаты в span есть, но карточка для них не проверялась этим тестом —")
		print("  UNVERIFIABLE, не «баг не воспроизводится».")
	else
		skipped = skipped + 1
		print("  => UNVERIFIABLE: этот лог НЕ доказывает ни наличия, ни отсутствия бага.")
		print("     Воспроизведение держится на двух логах выше, где карточка достижима.")
	end
else
	skipped = skipped + 1
	print("  лог отсутствует — проверка невозможна")
end

print("")
print(string.format("RESULT: %d проверок, провалено: %d, непроверяемых кейсов: %d", checks, #failures, skipped))
for _, f in ipairs(failures) do
	print("  - " .. f)
end
if #failures > 0 then
	vim.cmd("cquit 1")
end
print("ALL PASS")
vim.cmd("qa!")
