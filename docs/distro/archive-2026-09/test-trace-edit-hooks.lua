-- Регресс PERF-2E: хуки пути РЕДАКТИРОВАНИЯ обязаны САМИ сработать, а не просто
-- быть зарегистрированными.
--
-- Что было до тикета: setup_autocmds регистрировал ровно 7 событий, и ни одно
-- не наблюдает ни набор символа, ни запись буфера на диск (CursorMoved/
-- CursorMovedI, BufEnter, FileType, LspAttach, DiagnosticChanged, BufReadPost).
-- Пути «правка» и «сохранение» не были закрыты ВООБЩЕ — это нулевое покрытие,
-- а не поломка хука. Тикет закрывает именно покрытие.
--
-- Ключевое различие между «зарегистрирован» и «сработал». Регистрация
-- проверяется двадцатью строками кода. Но если событие есть в augroup, а по
-- какой-то причине не доходит до trace.log (буфер не тот, режим не тот, файл не
-- открыт, отложенный flush не случился) — лог останется пустым, и это молчание
-- НЕОТЛИЧИМО от «хука нет». Ровно тот класс лжи, который уже чинили в колонке
-- Δ. Поэтому тест не спрашивает «есть ли autocmd», а САЖАЕТ ПРАВКУ, СОХРАНЯЕТ
-- ФАЙЛ и читает лог.
--
-- Проверяются ТРИ события, потому что покрытие должно быть настоящим: обычный
-- набор — это TextChangedI (insert), правка вне insert — TextChanged, и
-- запись на диск — BufWritePost. Ограничиться одним было бы формальным закрытием.
--
-- ВАЖНО про harness (дорого стоило): «правка не вызвала хук» в headless —
-- почти всегда вина СПОСОБА ПРАВКИ, а не хука. Neovim ловит изменение текста в
-- check_text_changed() в ГЛАВНОМ ЦИКЛЕ. Всё, что исполняется внутри
-- `--headless -c 'luafile ...'`, идёт под блокировкой этой команды, и главный
-- цикл не доходит до точки проверки: nvim_buf_set_lines / feedkeys / :normal!
-- МЕНЯЮТ буфер (это видно по строкам), но не порождают НИ ОДНОГО TextChanged.
-- Обход: эмитить правки из отложенных колбэков vim.defer_fn с интервалом —
-- тогда между шагами главный цикл «дышит» и проверка текста срабатывает. Нужен
-- интервал иначе колбэки сливаются.
--
-- Ещё одна особенность: `nvim_input` (в отличие от feedkeys с флагом "x",
-- который работает как :normal и САМ дописывает <Esc>) оставляет нас в insert,
-- если <Esc> не послан. Это единственный способ в headless поймать TextChangedI:
-- набрать текст и остаться в insert на один такт главного цикла.
--
-- Файл НЕ трогает ~/.cache/nvim/distro-trace: трейсер включается на временный
-- путь (как в test-trace-own-ms.lua — модуль кэширует дескриптор в upvalue fd,
-- поэтому путь сменить можно только после disable()).
--
-- Запуск:
--   nvim --headless --clean -c 'luafile scripts/test-trace-edit-hooks.lua'
-- Выход: 0 = всё прошло, 1 = есть проваленная проверка.
--
-- Ожидание: на коде ДО PERF-2E падает (в логе 0 из 3 событий), на коде ПОСЛЕ —
-- проходит. Иначе тест ничего не доказывает.

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
local tracehooks = require("distro.tracehooks")
local uv = vim.uv or vim.loop

say("DistroTrace edit-path regression — PERF-2E")
say("")

-- Временные пути: лог трейсера и настоящий редактируемый файл.
local tmp_log = vim.fn.tempname()
local dir = vim.fn.tempname()
local probe = dir .. "/perf2e-probe.lua"

-- Настоящий трейсер, направленный во временный файл.
if trace.enabled then
	trace.disable()
end
trace.enabled, trace.path, trace.run_id = true, tmp_log, "perf2e"

-- Настоящие хуки, а не вызов обработчика руками: поднимаем ровно то, что
-- поднимает :DistroTrace.
tracehooks.setup_autocmds()

-- ---------------------------------------------------------------------------
-- A. КОНТРОЛЬНАЯ ГРУППА: события ЗАРЕГИСТРИРОВАНЫ в augroup трейсера.
-- Это не результат, а точка отсчёта: если событие зарегистрировано, но ниже
-- не сработало, разрыв виден прямо между двумя секциями.
-- ---------------------------------------------------------------------------
local reg = {}
for _, a in ipairs(vim.api.nvim_get_autocmds({ group = "DistroTraceHooks" })) do
	local evs = type(a.event) == "table" and a.event or { a.event }
	for _, e in ipairs(evs) do
		reg[e] = (reg[e] or 0) + 1
	end
end
say("== A. Регистрация (контрольная группа, augroup DistroTraceHooks) ==")
for _, ev in ipairs({ "TextChanged", "TextChangedI", "BufWritePost" }) do
	say(("  %-14s зарегистрировано: %d"):format(ev, reg[ev] or 0))
end
check((reg.TextChanged or 0) == 1 and (reg.TextChangedI or 0) == 1 and (reg.BufWritePost or 0) == 1,
	"A: три события зарегистрированы в augroup трейсера (контрольная группа непустая)")

-- ---------------------------------------------------------------------------
-- B. ЖИВОЙ ПРОГОН: правим, сохраняем, читаем лог.
-- Всё — из отложенных колбэков, между которыми главный цикл дышит (см. шапку).
-- ---------------------------------------------------------------------------
vim.defer_fn(function()
	vim.fn.mkdir(dir, "p")
	vim.fn.writefile({ "AAA", "BBB" }, probe)
	vim.cmd.edit(vim.fn.fnameescape(probe))
	local b = vim.api.nvim_get_current_buf()
	vim.bo[b].filetype = "lua"  -- осмысленное ft в строке лога, а не пустое поле 7
end, 40)

-- T1: правка В INSERT, остаёмся в insert на один такт => TextChangedI.
vim.defer_fn(function()
	vim.api.nvim_input("GoINSMARK")  -- G=последняя строка, o=новая строка+insert; далее печатается весь INSMARK
end, 150)

-- T2: выходим из insert, обычная правка вне insert => TextChanged.
vim.defer_fn(function()
	vim.api.nvim_input(vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
	vim.wait(60, function() return false end)
	vim.cmd("normal! ggdd")
end, 350)

-- T3: реальная запись на диск => BufWritePost.
vim.defer_fn(function()
	vim.cmd("write!")
end, 520)

-- T4: дать отложенному flush (vim.schedule) дойти, затем собрать вердикт.
vim.defer_fn(function()
	local ok, err = pcall(function()
		vim.wait(120, function() return false end)
		trace.flush()
		trace.disable()

		local raw = vim.fn.filereadable(tmp_log) == 1 and vim.fn.readfile(tmp_log) or {}
		say("")
		say("== B. Живой прогон: временный лог " .. vim.fn.fnamemodify(tmp_log, ":t") .. " ==")
		say(("  строк в логе: %d"):format(#raw))
		check(#raw > 0, "B: лог непуст — трейсер вообще пишет (иначе проверки ниже пусты)")

		-- Разбор по TAB: 14 колонок; нужны 1(seq) 2(at) 3(event) 5(detail)
		-- 6(bufname) 7(ft) 12(kind). Ничего нового не изобретаем — та же схема.
		local rows = {}
		for _, l in ipairs(raw) do
			local f = {}
			for part in (l .. "\t"):gmatch("([^\t]*)\t") do
				f[#f + 1] = part
			end
			if f[3] then
				rows[#rows + 1] = { seq=tonumber(f[1]), at=f[2], ev=f[3], detail=f[5],
						bufname=f[6], ft=f[7], kind=f[12] }
			end
		end

		local function find(ev)
			for _, r in ipairs(rows) do
				if r.ev == ev then
					return r
				end
			end
			return nil
		end

		-- ДОСЛОВНЫЕ строки: это и есть доказательство «сработало», а не «зарегистрировано».
		say("")
		say("  Дословные строки, доказывающие срабатывание:")
		for _, ev in ipairs({ "autocmd/TextChanged", "autocmd/TextChangedI", "autocmd/BufWritePost" }) do
			local r = find(ev)
			if r then
				say(("    seq=%-4s at=%-14s %-22s detail=%-26s file=%s")
					:format(tostring(r.seq), r.at, r.ev, r.detail, r.bufname))
			else
				say(("    %-22s ОТСУТСТВЕТ"):format(ev))
			end
		end

		-- 1. ГЛАВНОЕ: оба события тикета физически в логе.
		local tc, tw = find("autocmd/TextChanged"), find("autocmd/BufWritePost")
		check(tc ~= nil, "B: autocmd/TextChanged физически есть в логе (правка вне insert вызвала хук)")
		check(tw ~= nil, "B: autocmd/BufWritePost физически есть в логе (реальный :write вызвал хук)")

		-- 2. Insert-путь тоже закрыт: обычный набор — это TextChangedI.
		check(find("autocmd/TextChangedI") ~= nil, "B: autocmd/TextChangedI физически есть в логе (правка в insert вызвала хук)")

		-- 3. Общая схема, а не новый формат: те же поля, мгновенная строка (dur=nil, kind=event).
		for _, pair in ipairs({ { tc, "TextChanged" }, { tw, "BufWritePost" } }) do
			local r, name = pair[1], pair[2]
			if r then
				check(r.ft == "lua" and r.bufname:find("perf2e-probe.lua", 1, true) ~= nil,
					("B: %s в общей схеме — ft=%s, файл=%s"):format(name, r.ft, r.bufname))
				check(r.kind == "event",
					("B: %s — обычная мгновенная строка (kind=event, %s), а не новый формат"):format(name, r.kind))
			end
		end
		if tc then
			check(tc.detail:find("tick", 1, true) ~= nil,
				("B: детализация TextChanged содержательна, а не пуста: %q"):format(tc.detail))
		end

		-- 4. Файл ДЕЙСТВИТЕЛЬНО изменён на диске: BufWritePost не должен быть
		--    само-свидетельством. INSMARK (insert-правка) есть, AAA (строка удалена
		--    правкой вне insert) отсутствует.
		local on_disk = vim.fn.readfile(probe)
		local joined = table.concat(on_disk, "\n")
		say("")
		say(("  файл на диске: %d строк, INSMARK есть: %s, AAA удалён: %s"):format(
			#on_disk,
			tostring(joined:find("INSMARK", 1, true) ~= nil),
			tostring(joined:find("AAA", 1, true) == nil)))
		check(joined:find("INSMARK", 1, true) ~= nil,
			"B: записанный файл содержит insert-правку — TextChangedI не само-свидетельство")
		check(joined:find("AAA", 1, true) == nil,
			"B: записанный файл потерял удалённую строку — правка вне insert дошла до диска")

		-- -------------------------------------------------------------------------
		-- C. ПУТЬ РЕГИСТРАЦИИ НЕ ЗАДЕВАЕТ СТАРТ.
		-- Не «мы уверены», а проверка из исходника: setup_autocmds обязан вызываться
		-- ТОЛЬКО из :DistroTrace (ветки on и toggle). Это и есть обещание «горячий
		-- путь не тронут»: автокоманды ставятся по команде владельца, не на бутсте.
		-- -------------------------------------------------------------------------
		say("")
		say("== C. Регистрация остаётся ленивой ==")
		local n_calls = 0
		for _, path in ipairs(vim.api.nvim_get_runtime_file("lua/distro/init.lua", false)) do
			for _, l in ipairs(vim.fn.readfile(path)) do
				if l:find("tracehooks") and l:find("%.setup") then
					n_calls = n_calls + 1
				end
			end
		end
		say(("  мест, вызывающих tracehooks.setup: %d (ожидается 2 — on и toggle)"):format(n_calls))
		check(n_calls == 2,
			("C: setup_autocmds вызывается только из :DistroTrace (%d вызова(ов), не из пути загрузки)"):format(n_calls))
	end)
	if not ok then
		failures[#failures + 1] = "финальный этап упал: " .. tostring(err)
		say("  FAIL: финальный этап упал: " .. tostring(err))
	end

	-- Уборка. Порядок важен: disable() уже закрыл fd, теперь unlink.
	pcall(uv.fs_unlink, tmp_log)
	pcall(vim.fn.delete, dir, "rf")

	say("")
	say(("Проверок: %d, провалено: %d"):format(checks, #failures))
	if #failures > 0 then
		say("РЕГРЕСС PERF-2E: ПРОВАЛ")
		for _, f in ipairs(failures) do
			say("  - " .. f)
		end
		vim.cmd("cquit 1")
	else
		say("РЕГРЕСС PERF-2E: ЗЕЛЁНЫЙ")
		vim.cmd("quitall!")
	end
end, 700)
