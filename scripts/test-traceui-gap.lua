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
	-- M.detail на строке dur=nil падал arithmetic-on-nil, и падаЛ ВНУТРИ себя,
	-- до всякой проверки: необработанная ошибка оборвала бы весь скрипт, и прогон
	-- завис бы вместо того, чтобы отдать внятный FAIL. Поэтому ошибка вьюера
	-- снимается здесь и становится значением, которое можно проверить.
	local ok, err = pcall(traceui.detail, path, r)
	if not ok then
		return nil, nil, r, ("вьюер упал: %s"):format(tostring(err))
	end
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

-- ---------------------------------------------------------------------------
-- КЕЙС dur=nil: карточка, открытая НА МГНОВЕННОЙ СТРОКЕ.
--
-- Это отдельный кейс, а не ещё одна проверка внутри verify(), потому что
-- проверяет он другую ветку: verify() открывает ТАЙМИРОВАННЫЙ span, где у
-- r.dur есть, и #subs > 0. Мгновенная строка (dur=nil, kind=event) — это
-- все autocmd/*: CursorMoved, BufEnter, FileType, DiagnosticChanged, плюс
-- trace/enable. В логе 484230425125 это 268 строк из 327, и именно они самые
-- частые узлы дерева, на которых владелец кликает. Регресс 3330de3 унёс гард
-- `r.dur or 0` ровно на этом пути: строка шла ДО проверки #subs, то есть
-- падала ВСЕГДА, а не на каком-то краю. Проверок выше это не ловили ни одной —
-- отсюда и 14/14 на сломанном коде.
-- ---------------------------------------------------------------------------
local function verify_instant_card(path, seq, label)
	print("")
	print(("== %s (%s, мгновенная строка seq %d) =="):format(label, vim.fn.fnamemodify(path, ":t"), seq))
	local rows = read_log(path)

	-- Сколько в логе строк без собственного времени: это и есть «частые узлы».
	-- Печатаем, потому что сам по себе факт «ветка покрыта» ничего не значит,
	-- если ветка пустая.
	local instant_total = 0
	for _, x in ipairs(rows) do
		if x.dur == nil then
			instant_total = instant_total + 1
		end
	end
	print(("  в логе строк с dur=nil: %d из %d — ветка не пустая, карточку открыть есть на чем"):format(
		instant_total, #rows))

	-- 1. Кейс не вырожденный: мы правда открываем строку БЕЗ собственного
	--    времени. Иначе проверка ниже проходила бы на любой строке.
	local target
	for _, x in ipairs(rows) do
		if x.seq == seq then
			target = x
		end
	end
	if not target then
		check(false, label .. ": нет строки seq=" .. seq)
		return
	end
	check(target.dur == nil, ("%s seq %d %s действительно мгновенная (dur=nil), а не таймированная"):format(
		label, seq, target.event))

	-- 2. ГЛАВНОЕ. Регресс 3330de3: M.detail падал на
	--    `local prev_at = r.at - r.dur` для ЛЮБОЙ строки с dur=nil, потому
	--    что строка шла безусловно, до `#subs`. Карточка обязана открыться.
	local lines, got, r, err = card(path, rows, seq)
	if not lines then
		check(false, ("%s карточка на мгновенной строке seq %d %s открылась (dur=nil, kind=%s)"):format(
			label, seq, target.event, tostring(target.kind)) .. " — " .. tostring(err))
		return
	end
	check(true, ("%s карточка на мгновенной строке seq %d %s открылась (dur=nil, kind=%s)"):format(
		label, seq, target.event, tostring(target.kind)))

	-- 3. Это именно карточка span-а, а не пустой буфер после ошибки.
	local has_head, has_dur, has_ev = false, false, false
	for _, l in ipairs(lines) do
		if l:match("^=== span ===$") then
			has_head = true
		end
		if l:match("n/a %(instant event%)") then
			has_dur = true
		end
		if l:match("^%s+event%s+" .. vim.pesc(target.event) .. "$") then
			has_ev = true
		end
	end
	check(has_head, label .. ": карточка на мгновенной строке напечатала заголовок === span ===")
	check(has_dur, label .. ": карточка на мгновенной строке напечатала duration как \"n/a (instant event)\"")
	check(has_ev, ("%s: карточка на мгновенной строке назвала событие %s"):format(label, target.event))

	-- 4. Строка-окно на мгновенной строке пуста по построению (окно строится
	--    только при r.dur), и это должно быть сказано вслух, а не молча пропущено.
	local said_none = false
	for _, l in ipairs(lines) do
		if l == "(none recorded)" then
			said_none = true
		end
	end
	check(said_none, label .. ": пустое окно мгновенной строки сказано вслух — \"(none recorded)\"")
end

print("DistroTrace card regression — PERF-1D")
print("Логи: " .. LOGDIR)

verify(LOGDIR .. "/distro-trace-484230425125.log", 123,
	"pick_lsp/definition/request_to_response", 5237.924, 5238.042, "лог 484230425125")

verify(LOGDIR .. "/distro-trace-544190817791.log", 107,
	"pick_lsp/definition/request_to_response", 142.046, 142.172, "лог 544190817791")

-- Карточка на МГНОВЕННОЙ строке: seq 117 = autocmd/CursorMoved, поле 4 = "-",
-- то есть dur=nil. Именно на ней 3330de3 ронял арифметику.
verify_instant_card(LOGDIR .. "/distro-trace-484230425125.log", 117, "лог 484230425125")

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
