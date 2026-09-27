-- Регресс PERF-2B: own_ms (поле 11) не может быть отрицательным.
--
-- Дефект жил в арифметике M.sub (lua/distro/trace.lua):
--     own = ms - (last_cum[name] or 0)
-- `ms` — это ЭЛЬЗИЯ СВОЕГО t0 (t0 берётся в tracehooks.traced на каждый вызов
-- _G._pick_lsp), а базис `last_cum` кэшировался по `name` — по МЕТКЕ, общей для
-- всех нажатий. Два разных механизма, оба ломали границы кадра:
--
--   A) re-entry: базис от предыдущего нажатия (0.112 - 9.786 = -9.674);
--   B) overlap: два нажатия в полёте затирают слот друг друга
--      (444.965 [свой t0] - 5248.960 [чужой t0] = -4803.995).
--
-- Проверяются ДВА независимых утверждения, а не одно:
--   A. ЖИВОЙ эмиттер: реальный M.sub получает обе ситуации и обязан выдать
--      конкретные неотрицательные числа (плюс телескопия: сумма own_ms кадра ==
--      его последнему кумулятивному — определение «собственного времени»).
--   B. ЛОГ 484230425125 целиком пересчитывается по обеим формулам. Старая
--      обязана ВОСПРОИЗВЕСТИ отрицательные значения из файла (иначе оракул врёт и
--      доказывает не то), новая — дать ноль отрицательных.
--
-- Границы кадров в логе не записаны, поэтому для пересчёта они ВЫВОДЯТСЯ из
-- самого лога: у каждой sub-строки t0 = f2 - f4, и он обязан совпасть с t0
-- какой-то строки keypress_to_request. Это независимая проверка, а не
-- предположение: seq 121/122 попадают в кадр seq 114, а seq 124/126 — в кадр
-- seq 118, то есть лог сам доказывает переплетение двух нажатий.
--
-- Запуск:
--   nvim --headless --clean -c 'luafile scripts/test-trace-own-ms.lua'
-- Выход: 0 = всё прошло, 1 = есть проваленная проверка.

local failures, checks = {}, 0

-- print() в headless nvim буферизуется, и строки разных print схлопываются в
-- одну. Явный flush держит порядок вывода в том же виде, что и на экране.
local function say(s)
	io.stdout:write(s .. "\n")
	io.stdout:flush()
end

local function check(ok, label)
	checks = checks + 1
	if not ok then
		failures[#failures + 1] = label
		say("  FAIL: " .. label)
	end
	return ok
end

vim.opt.runtimepath:prepend(vim.fn.getcwd())
local trace = require("distro.trace")
local uv = vim.uv or vim.loop

-- ===========================================================================
-- A. ЖИВОЙ ЭМИТТЕР
-- ===========================================================================
-- Эмиттер пишет в файл только при M.enabled, поэтому включаем его на
-- ВРЕМЕННЫЙ путь: реальный каталог трассировки не пачкаем.
--
-- Два подсобного в самом харкасе: модуль кэширует файловый дескриптор в upvalue `fd`, и после unlink второго вызова flush() пишет в удалённый
-- инод, и файл больше не появляется вовсе. Поэтому перед сменой пути закрываем файл через disable(), а путь свой.
local function emit(steps)
	if trace.enabled then
		trace.disable()
	end
	local tmp = vim.fn.tempname()
	trace.enabled, trace.path, trace.run_id = true, tmp, "test"
	for _, s in ipairs(steps) do
		trace.sub(s[1], s[2], s[3], nil, s[4])
	end
	trace.flush()
	local out = {}
	for _, l in ipairs(vim.fn.readfile(tmp)) do
		local f = {}
		for part in (l .. "\t"):gmatch("([^\t]*)\t") do
			f[#f + 1] = part
		end
		if f[3] then
			out[#out + 1] = { ev = f[3], cum = tonumber(f[4]), own = tonumber(f[11]) }
		end
	end
	trace.disable()
	pcall(uv.fs_unlink, tmp)
	return out
end

local function show(rows)
	for i, r in ipairs(rows) do
		say(("    %d. %-52s cum=%-10.3f own=%s"):format(
			i, r.ev, r.cum, r.own and ("%+.3f"):format(r.own) or "—"))
	end
end

say("DistroTrace own_ms regression — PERF-2B")
say("")
say("== A1. Механизм A: re-entry (базис от ПРЕДЫДУЩЕГО нажатия) ==")
local a1 = emit({
	{ "pick_lsp/definition", "keypress_to_request", 0.112, 101 },
	{ "pick_lsp/definition", "request_to_response", 9.786, 101 },
	{ "pick_lsp/definition", "response_to_cursor", 9.828, 101 },
	-- второе нажатие ТОЙ ЖЕ клавиши: базис не имеет права долететь из кадра 101
	{ "pick_lsp/definition", "keypress_to_request", 0.112, 202 },
	{ "pick_lsp/definition", "request_to_response", 9.898, 202 },
})
show(a1)
check(a1[4].own ~= nil and math.abs(a1[4].own - 0.112) < 0.001,
	("A1: первый кадр нового нажатия (keypress 0.112) не обнулён чужим базисом, own=%.3f (было -9.716)"):format(a1[4].own or -999))
check(a1[5].own ~= nil and math.abs(a1[5].own - 9.786) < 0.001,
	("A1: request_to_response второго нажатия own=%.3f = 9.898-0.112 (было 0.070 из-за 9.828)"):format(a1[5].own or -999))
for i, r in ipairs(a1) do
	check(r.own == nil or r.own >= 0, ("A1: own[%d] (%s) неотрицателен, got %.3f"):format(i, r.ev, r.own or 0))
end

say("")
say("== A2. Механизм B: overlap (два нажатия в полёте, базисы затирают друг друга) ==")
-- Порядок строк — ровно как в логе 484230425125 (seq 114,118,121,122,124,126).
local a2 = emit({
	{ "pick_lsp/definition", "keypress_to_request", 0.112, 301 },
	{ "pick_lsp/definition", "keypress_to_request", 0.118, 302 },
	{ "pick_lsp/definition", "request_to_response", 5238.042, 301 },
	{ "pick_lsp/definition", "response_to_cursor", 5248.960, 301 },
	{ "pick_lsp/definition", "request_to_response", 444.965, 302 },
	{ "pick_lsp/definition", "response_to_cursor", 454.500, 302 },
})
show(a2)
check(a2[5].own ~= nil and math.abs(a2[5].own - 444.847) < 0.001,
	("A2: переплетённый кадр 302 request_to_response own=%.3f (было -4803.995 = 444.965-5248.960)"):format(a2[5].own or -999))
check(a2[3].own ~= nil and math.abs(a2[3].own - 5237.930) < 0.001,
	("A2: кадр 301 request_to_response own=%.3f = 5238.042-0.112 СВОЕГО кадра (было 5237.924 — вычитался keypress чужого кадра)"):format(a2[3].own or -999))
for i, r in ipairs(a2) do
	check(r.own == nil or r.own >= 0, ("A2: own[%d] (%s) неотрицателен, got %.3f"):format(i, r.ev, r.own or 0))
end
-- Телескопия: сумма собственных времён кадра == его полному кумулятивному.
-- Это и есть определение, а не проверка «неотрицательности».
for _, f in ipairs({ { 301, { 1, 3, 4 }, 5248.960 }, { 302, { 2, 5, 6 }, 454.500 } }) do
	local sum = 0
	for _, i in ipairs(f[2]) do
		sum = sum + a2[i].own
	end
	check(math.abs(sum - f[3]) < 0.001,
		("A2: сумма own_ms кадра %d = %.3f == его кумулятивному %.3f"):format(f[1], sum, f[3]))
end

say("")
say("== A3. Совместимость: вызов без frame (старый контракт) не падает ==")
local a3 = emit({ { "cmd/DistroFoo", "phase_one", 2.5, nil }, { "cmd/DistroFoo", "phase_two", 4.0, nil } })
show(a3)
check(a3[1].own ~= nil and math.abs(a3[1].own - 2.5) < 0.001 and a3[2].own ~= nil and math.abs(a3[2].own - 1.5) < 0.001,
	("A3: без frame базис по-прежнему по name, own = 2.500 / 1.500 (got %s / %s)")
		:format(tostring(a3[1].own), tostring(a3[2].own)))

-- ===========================================================================
-- B. ПЕРЕСЧЁТ РЕАЛЬНОГО ЛОГА ЦЕЛИКОМ
-- ===========================================================================
say("")
say("== B. Пересчёт лога distro-trace-484230425125.log ==")
local LOG = vim.fn.expand("~/.cache/nvim/distro-trace/distro-trace-484230425125.log")
if vim.fn.filereadable(LOG) ~= 1 then
	check(false, "B: лог не найден: " .. LOG)
else
	local rows = {}
	for _, l in ipairs(vim.fn.readfile(LOG)) do
		local f = {}
		for part in (l .. "\t"):gmatch("([^\t]*)\t") do
			f[#f + 1] = part
		end
		if f[3] then
			rows[#rows + 1] = {
				seq = tonumber(f[1]),
				at = tonumber(f[2]),
				ev = f[3],
				cum = f[4] ~= "-" and tonumber(f[4]) or nil,
				own = f[11] ~= "-" and tonumber(f[11]) or nil,
				kind = f[12],
			}
		end
	end

	-- Старая формула: базис по метке name, сквозь все нажатия.
	local old_last, old_rows, old_neg, old_min = {}, {}, 0, nil
	-- Новая: кадр = t0, восстановленный из f2 - f4 и сопоставленный с keypress.
	local frames, new_rows, unmatched = {}, {}, 0

	for _, r in ipairs(rows) do
		if r.kind == "sub" and r.cum then
			local g = r.ev:gsub("/[^/]*$", "")
			local o_old = r.cum - (old_last[g] or 0)
			old_last[g] = r.cum
			old_rows[#old_rows + 1] = { r = r, own = o_old }

			if r.ev:match("keypress_to_request$") then
				frames[#frames + 1] = { t0 = r.at - r.cum, last = nil, seq = r.seq }
			end
			local t0 = r.at - r.cum
			local best, bd = nil, 1e9
			for _, f in ipairs(frames) do
				local d = math.abs(t0 - f.t0)
				if d < bd then
					bd, best = d, f
				end
			end
			local o_new
			if best and bd <= 0.5 then
				o_new = r.cum - (best.last or 0)
				best.last = r.cum
			else
				unmatched = unmatched + 1
			end
			new_rows[#new_rows + 1] = { r = r, own = o_new, frame = best and best.seq, dt = bd }
		end
	end

	local function tally(list, nname, nvar, negvar)
		for _, x in ipairs(list) do
			if x.own ~= nil then
				if x.own < 0 then
					negvar[1] = negvar[1] + 1
					say(("    ОТРИЦАТЕЛЕН seq=%-4d %-46s %s=%+.3f"):format(x.r.seq, x.r.ev, nname, x.own))
				end
				if nvar[1] == nil or x.own < nvar[1] then
					nvar[1] = x.own
				end
			end
		end
		return negvar[1], nvar[1]
	end

	say(("  строк в логе: %d, из них с own_ms: %d"):format(#rows, #old_rows))
	old_neg, old_min = tally(old_rows, "own_ms", { nil }, { 0 })
	say(("  ДО  (базис по метке name): отрицательных %d, минимум %+.3f"):format(old_neg, old_min or 0))

	new_neg, new_min = tally(new_rows, "own_ms", { nil }, { 0 })
	say(("  ПОСЛЕ (базис по кадру t0):  отрицательных %d, минимум %+.3f"):format(new_neg, new_min or 0))
	say(("  строк, чей кадр не удалось восстановить (dt > 0.5 ms): %d"):format(unmatched))

	-- Оракул обязан воспроизвести то, что лежит В ФАЙЛЕ, иначе пересчёт выше
	-- доказывает не то, что мы думаем.
	local maxdiff, mismatch = 0, 0
	for i, x in ipairs(old_rows) do
		local fv = x.r.own
		if fv ~= nil then
			local d = math.abs(fv - x.own)
			if d > maxdiff then
				maxdiff = d
			end
			-- f4 и f11 каждый записаны с 3 знака после деления: разность двух
			-- округлённых дробовых чисел легко отличается на полуулевула
			-- (0.001 = половина окрайлена). Граница 0.0015, а не 0.001.
			if d > 0.0015 then
				mismatch = mismatch + 1
			end
		end
		_ = i
	end
	check(mismatch == 0,
		("B: старая формула воспроизводит поле 11 файла (расхождений > 0.001 ms: %d, максимум %.4f ms)"):format(mismatch, maxdiff))
	check(old_neg > 0,
		("B: оракул нашёл в логе отрицательные own_ms ДО фикса (%d) — иначе проверка пустая"):format(old_neg))
	check(new_neg == 0,
		("B: ПОСЛЕ фикса в логе НЕТ ни одного отрицательного own_ms (найдено %d, минимум %+.3f)"):format(new_neg, new_min or 0))
	check(unmatched == 0,
		("B: границы кадров восстановлены для всех строк с own_ms (не найдено: %d)"):format(unmatched))

	-- Таблица изменившихся строк — те самые числа, что стоят в закоммиченных
	-- документах, поэтому они обязаны быть видны, а не спрятаны за сводкой.
	say("")
	say("  Строки, чьё own_ms изменилось:")
	say(("  %-5s %-46s %12s %12s %8s"):format("seq", "событие", "было", "стало", "кадр"))
	for i, x in ipairs(new_rows) do
		if x.own ~= nil and x.r.own ~= nil and math.abs(x.own - x.r.own) > 0.0005 then
			-- Изменение меньше 0.0015 ms — это окрайление хранения вычисленного поля (три знака), а не исправление.
			local note = ""
			if math.abs(x.own - x.r.own) <= 0.0015 then
				note = "  (окрайление)"
			end
			say(("  %-5d %-46s %+12.3f %+12.3f %8s%s"):format(
				x.r.seq, x.r.ev, x.r.own, x.own, tostring(x.frame), note))
		end
		_ = i
	end
end

-- ===========================================================================
say("")
print(("Проверок: %d, провалено: %d"):format(checks, #failures))
if #failures > 0 then
	say("РЕГРЕСС PERF-2B: ПРОВАЛ")
	for _, f in ipairs(failures) do
		say("  - " .. f)
	end
	vim.cmd("cquit 1")
else
	say("РЕГРЕСС PERF-2B: ЗЕЛЁНЫЙ")
	vim.cmd("quitall!")
end
