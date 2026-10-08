-- dev.test — Go test workflow поверх `go test -json` (без neotest).
--
-- Почему свой: neotest — это движок + адаптер + nio + queries ради обёртки
-- над JSON-стримом, который парсится в ~100 строк. Здесь: run pkg/func/all,
-- failures → quickfix (файл:строка из вывода), summary-notify, rerun-failed,
-- coverage-профиль → знаки непокрытых строк + %, debug-test через dev.debug.
-- Процессов в фоне нет: `go test` живёт только пока идёт прогон.

local M = {}

M.last_failed = {} ---@type string[] пакеты последнего красного прогона
M.last_cmd = nil ---@type table? последний argv для rerun-all
M.last_output = {} ---@type string[] сырой вывод последнего прогона

local function go_bin()
	if vim.fn.executable("go") ~= 1 then
		vim.notify("[test] 'go' not in PATH", vim.log.levels.ERROR, { title = "test" })
		return false
	end
	return true
end

--- Каталог пакета текущего буфера (по go.mod вверх, иначе каталог файла).
local function pkg_dir()
	local f = vim.api.nvim_buf_get_name(0)
	local mod = vim.fs.root(f, { "go.mod", "go.work" })
	if mod then
		-- Относительный ./путь от модуля точнее для go test.
		local dir = vim.fn.fnamemodify(f, ":p:h")
		return dir
	end
	return vim.fn.fnamemodify(f, ":p:h")
end

--- Ближайший `func TestXxx` выше курсора (regex, без treesitter-зависимости).
--- Второй return: true если это метод с ресивером (`func (s *S) TestX`)
--- такие `go test -run` напрямую не запускает (нужен suite-runner).
---@return string? имя, boolean? is_method
function M.nearest_test()
	return M._nearest_func("Test")
end

--- Ближайший `func BenchmarkXxx` выше курсора. Та же механика, что у тестов.
---@return string? имя, boolean? is_method
function M.nearest_bench()
	return M._nearest_func("Benchmark")
end

---@param prefix "Test"|"Benchmark"
---@return string? имя, boolean? is_method
function M._nearest_func(prefix)
	local cur = vim.api.nvim_win_get_cursor(0)[1]
	local lines = vim.api.nvim_buf_get_lines(0, 0, cur, false)
	for i = #lines, 1, -1 do
		local line = lines[i]
		-- Сначала форма с ресивером: `func (s *Suite) TestX(...)`.
		-- %b() ест сбалансированные скобки (дженерик-ресиверы тоже).
		local name = line:match("^%s*func%s*%b()%s*((" .. prefix .. ")%w*)%s*%(")
		if name then
			return name, true
		end
		name = line:match("^%s*func%s*((" .. prefix .. ")%w*)%s*%(")
		if name then
			return name, false
		end
	end
	return nil, false
end

--- Разбор `go test -json`: failures → qf items, counters → summary.
local function parse_json(raw)
	local qf, pass, fail, skip, cached = {}, 0, 0, 0, 0
	local fail_pkgs = {}
	for _, line in ipairs(raw) do
		local ok, ev = pcall(vim.json.decode, line)
		if ok and type(ev) == "table" then
			if ev.Action == "pass" and ev.Test == nil then
				pass = pass + 1
				if ev.Package then
					fail_pkgs[ev.Package] = fail_pkgs[ev.Package] or false
				end
			elseif ev.Action == "fail" and ev.Test == nil then
				fail = fail + 1
				if ev.Package then
					fail_pkgs[ev.Package] = true
				end
			elseif ev.Action == "skip" and ev.Test == nil then
				skip = skip + 1
			elseif ev.Action == "output" and ev.Output then
				if ev.Output:find("%(cached%)") then
					cached = cached + 1
				end
				-- Строка вида "    foo_test.go:42: message".
				local f, l, msg = ev.Output:match("^%s+([%w_%.%-]+%.go):(%d+):%s*(.-)%s*$")
				if f and msg and msg ~= "" then
					qf[#qf + 1] = { filename = f, lnum = tonumber(l), col = 1, text = (ev.Test and (ev.Test .. ": ") or "") .. msg }
				end
			end
		end
	end
	local failed = {}
	for pkg, bad in pairs(fail_pkgs) do
		if bad then
			failed[#failed + 1] = pkg
		end
	end
	return qf, { pass = pass, fail = fail, skip = skip, cached = cached }, failed
end

--- Прогон. scope: "func"|"pkg"|"all"|"rerun". extra — доп. флаги go test.
---@param scope string
---@param extra string[]?
function M.run(scope, extra)
	if not go_bin() then
		return
	end
	if vim.bo.filetype ~= "go" and scope ~= "rerun" then
		vim.notify("[test] Go buffers only", vim.log.levels.WARN, { title = "test" })
		return
	end
	local argv = { "go", "test", "-json", "-count=1" }
	local dir = pkg_dir()
	if scope == "func" then
		local t, is_method = M.nearest_test()
		if not t then
			vim.notify("[test] no Test func above cursor (try <leader>ta for package)", vim.log.levels.WARN, { title = "test" })
			return
		end
		if t == "TestMain" then
			-- TestMain(m) запускает весь пакет через m.Run(): -run на него
			-- ничего не сматчит. Пакетный прогон — честная интерпретация.
			vim.notify("[test] TestMain runs the whole package — running package instead", vim.log.levels.INFO, { title = "test" })
			argv[#argv + 1] = "."
		elseif is_method then
			-- Suite-метод (`func (s *S) TestX`): go test -run его напрямую
			-- не видит (нужен suite-Runner), молчаливый "pass" был бы враньём.
			-- Пакетный прогон с явным объяснением вместо тихого не-того-теста.
			vim.notify("[test] " .. t .. " is a suite method — no direct -run support, running package instead", vim.log.levels.INFO, { title = "test" })
			argv[#argv + 1] = "."
		else
			vim.list_extend(argv, { "-run", "^" .. t .. "$", "." })
		end
	elseif scope == "pkg" then
		argv[#argv + 1] = "."
	elseif scope == "all" then
		argv[#argv + 1] = "./..."
	elseif scope == "rerun" then
		if #M.last_failed == 0 then
			vim.notify("[test] nothing failed yet — run <leader>ta first", vim.log.levels.INFO, { title = "test" })
			return
		end
		for _, p in ipairs(M.last_failed) do
			argv[#argv + 1] = p
		end
	else
		vim.notify("[test] unknown scope: " .. scope, vim.log.levels.ERROR, { title = "test" })
		return
	end
	if extra then
		vim.list_extend(argv, extra)
	end
	M._execute(argv, dir, scope, "test")
end

--- Прогон конкретных тестов по именам (для codelens-адаптера: имена уже
--- точные, из lens arguments — курсор не нужен). Имена экранируем.
---@param names string[]
function M.run_names(names)
	if not go_bin() then
		return
	end
	if #names == 0 then
		return
	end
	local esc = {}
	for _, n in ipairs(names) do
		esc[#esc + 1] = n:gsub("([^%w])", "%%%1")
	end
	local argv = { "go", "test", "-json", "-count=1", "-run", "^(" .. table.concat(esc, "|") .. ")$", "." }
	M._execute(argv, pkg_dir(), "lens", "test")
end

--- Benchmark: func под курсором, иначе весь пакет. Бенч НЕ трогает
--- last_failed (состояние тестов), но пишет last_output (сырой вывод
--- для :TestOutput). Флаги: тесты скипаем (-run=^$), benchtime дефолтный.
function M.bench()
	if not go_bin() then
		return
	end
	if vim.bo.filetype ~= "go" then
		vim.notify("[test] Go buffers only", vim.log.levels.WARN, { title = "test" })
		return
	end
	local name, is_bmethod = M.nearest_bench()
	local argv = { "go", "test", "-json", "-count=1", "-run=^$" }
	local btitle = "bench:pkg"
	if name and not is_bmethod then
		vim.list_extend(argv, { "-bench=^" .. name .. "$", "." })
		btitle = "bench:" .. name
	else
		if name then
			vim.notify("[test] " .. name .. " is a suite method — running package benchmarks instead", vim.log.levels.INFO, { title = "test" })
		end
		vim.list_extend(argv, { "-bench=.", "." })
	end
	M._execute(argv, pkg_dir(), btitle, "bench")
end

--- Benchmark конкретных имён (для codelens-адаптера).
---@param names string[]
function M.bench_names(names)
	if not go_bin() then
		return
	end
	if #names == 0 then
		return
	end
	local esc = {}
	for _, n in ipairs(names) do
		esc[#esc + 1] = n:gsub("([^%w])", "%%%1")
	end
	local argv = { "go", "test", "-json", "-count=1", "-run=^$", "-bench=^(" .. table.concat(esc, "|") .. ")$", "." }
	M._execute(argv, pkg_dir(), "lens-bench", "bench")
end

--- Общее выполнение: notify-start, vim.system, разбор, qf, summary.
--- mode "test": полное состояние (last_failed). mode "bench": last_failed
--- не трогаем, в summary добавляем строки ns/op.
---@param argv string[]
---@param dir string
---@param title string
---@param mode "test"|"bench"
function M._execute(argv, dir, title, mode)
	M.last_cmd = { argv = argv, dir = dir }
	vim.notify("[test] " .. table.concat(argv, " "), vim.log.levels.INFO, { title = "test" })
	vim.system(argv, { text = true, cwd = dir }, function(obj)
		vim.schedule(function()
			M.last_output = vim.split(obj and obj.stdout or "", "\n", { plain = true })
			local qf, sum, failed = parse_json(M.last_output)
			if mode == "test" then
				M.last_failed = failed
			end
			if #failed > 0 or (obj and obj.code ~= 0 and #qf > 0) then
				-- Абсолютные пути: qf открывается из любого окна.
				for _, it in ipairs(qf) do
					if it.filename and not it.filename:match("^/") and not it.filename:match("^%a:") then
						it.filename = dir .. "/" .. it.filename
					end
				end
				vim.fn.setqflist({}, " ", { title = "go " .. (mode == "bench" and "bench" or "test") .. ": " .. title, items = qf })
				vim.cmd("copen")
			else
				pcall(vim.cmd, "cclose")
			end
			local msg = string.format("pass=%d fail=%d skip=%d", sum.pass, sum.fail, sum.skip)
			if sum.cached > 0 then
				msg = msg .. " (cached lines in output)"
			end
			if mode == "bench" then
				-- go test -json режет длинные строки на куски: имя бенчмарка
				-- ("BenchmarkFoo-4 \t") и результат ("... ns/op") часто лежат
				-- в РАЗНЫХ Output-событиях (проверено живьём). Поэтому сначала
				-- склеиваем весь Output-поток в один blob и ищем в нём —
				-- построчный поиск молча ничего не находит.
				local parts = {}
				for _, l in ipairs(M.last_output) do
					local okj, ev = pcall(vim.json.decode, l)
					if okj and type(ev) == "table" and ev.Action == "output" and type(ev.Output) == "string" then
						parts[#parts + 1] = ev.Output
					elseif not okj then
						parts[#parts + 1] = l -- не-JSON строка (go warnings и т.п.)
					end
				end
				local lines = {}
				for b in table.concat(parts):gmatch("Benchmark[^\n]-ns/op") do
					if #lines >= 8 then
						break
					end
					lines[#lines + 1] = vim.trim((b:gsub("%s+", " ")))
				end
				if #lines > 0 then
					msg = table.concat(lines, " | ") .. " — full output: :TestOutput"
				else
					msg = msg .. " — full output: :TestOutput"
				end
			end
			-- bench не наполняет last_failed: подсказка про tr была бы враньём
			-- (перезапустилось бы старое). Для bench — только факт.
			local tail = ""
			if mode == "test" then
				tail = #failed > 0 and " — rerun with <leader>tr" or " — all green"
			end
			vim.notify("[test] " .. msg .. tail, (#failed > 0) and vim.log.levels.WARN or vim.log.levels.INFO, { title = "test" })
		end)
	end)
end

function M.rerun()
	M.run("rerun")
end

--- Сырой вывод последнего прогона в split (read-only).
function M.show_output()
	if #M.last_output == 0 then
		vim.notify("[test] no test run yet", vim.log.levels.INFO, { title = "test" })
		return
	end
	vim.cmd("botright split")
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(0, buf)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.last_output)
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "devtest-output"
end

-- Coverage: профиль → знаки непокрытых строк + %.
local cov_ns = vim.api.nvim_create_namespace("devtest_cov")

function M.coverage()
	if not go_bin() then
		return
	end
	local dir = pkg_dir()
	local out = vim.fn.stdpath("cache") .. "/devtest-cover.out"
	vim.fn.mkdir(vim.fn.fnamemodify(out, ":h"), "p")
	vim.notify("[test] go test -coverprofile …", vim.log.levels.INFO, { title = "test" })
	vim.system({ "go", "test", "-count=1", "-coverprofile=" .. out, "." }, { text = true, cwd = dir }, function(obj)
		vim.schedule(function()
			-- Профиль пишется даже при красных тестах (exit 1 при успешной
			-- сборке) — покрытие от exit-кода не зависит. Падаем только если
			-- профиля нет/не читается; иначе показываем покрытие как есть.
			local f = io.open(out, "r")
			if not f then
				vim.notify(
					"[test] coverage failed: " .. tostring(obj and obj.stderr or "?"):sub(1, 200),
					vim.log.levels.ERROR,
					{ title = "test" }
				)
				return
			end
			local stmts, covered = 0, 0
			local uncovered = {} --- absfile -> { {s,e} }
			-- Пути в профиле — от корня модуля С префиксом module-path
			-- (example.com/demo/main.go), а не файловая система: префикс
			-- надо снять, иначе знаки ложатся в никуда. Модуль читаем из go.mod.
			local modpath = nil
			do
				local gomod = (vim.fs.root(dir, { "go.mod" }) or dir) .. "/go.mod"
				local f = io.open(gomod, "r")
				if f then
					local first = f:read("*l")
					f:close()
					if first then
						modpath = first:match("^module%s+(%S+)")
					end
				end
			end
			local modroot = vim.fs.root(dir, { "go.mod" }) or dir
			--- realpath-нормализация: /var vs /private/var (macOS) и т.п.
			--- иначе uncovered-ключи не сходятся с именами буферов.
			local function canon(p)
				local ok, rp = pcall(vim.uv.fs_realpath, p)
				if ok and rp and rp ~= "" then
					return rp
				end
				return vim.fs.normalize(p)
			end
			local function resolve(file)
				if file:match("^/") or file:match("^%a:") then
					return canon(file)
				end
				if modpath and file:sub(1, #modpath) == modpath then
					local rel = file:sub(#modpath + 2)
					if rel ~= "" and vim.uv.fs_stat(modroot .. "/" .. rel) then
						return canon(modroot .. "/" .. rel)
					end
				end
				if vim.uv.fs_stat(modroot .. "/" .. file) then
					return canon(modroot .. "/" .. file)
				end
				return nil
			end
			for line in f:lines() do
				local file, sl, sc, el, ec, num, cnt =
					line:match("^(.+):(%d+)%.(%d+),(%d+)%.(%d+)%s+(%d+)%s+(%d+)$")
				if file and num then
					stmts = stmts + tonumber(num)
					if tonumber(cnt) > 0 then
						covered = covered + tonumber(num)
					else
						local abs = resolve(file)
						if abs then
							uncovered[abs] = uncovered[abs] or {}
							uncovered[abs][#uncovered[abs] + 1] = { tonumber(sl), tonumber(el) }
						end
					end
				end
			end
			f:close()
			-- Знаки только в видимых буферах (дешево, без обхода всех файлов).
			pcall(vim.fn.sign_define, "DevTestUncovered", { text = "▎", texthl = "DiagnosticWarn" })
			local placed = 0
			for _, b in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_is_loaded(b) then
					local name = vim.api.nvim_buf_get_name(b)
					local ok_c, canon_name = pcall(vim.uv.fs_realpath, name)
					local ranges = uncovered[ok_c and canon_name or name]
					if ranges then
						vim.api.nvim_buf_clear_namespace(b, cov_ns, 0, -1)
						for _, r in ipairs(ranges) do
							for l = r[1], r[2] do
								pcall(vim.fn.sign_place, 0, "DevTestCov", "DevTestUncovered", b, { lnum = l })
								placed = placed + 1
							end
						end
					end
				end
			end
			local pct = stmts > 0 and (covered / stmts * 100) or 0
			vim.notify(
				string.format("[test] coverage %.1f%% (%d/%d stmts), uncovered marks: %d — clear with :TestCovClear", pct, covered, stmts, placed),
				vim.log.levels.INFO,
				{ title = "test" }
			)
		end)
	end)
end

function M.coverage_clear()
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) then
			pcall(vim.fn.sign_unplace, "DevTestCov", { buffer = b })
		end
	end
	vim.notify("[test] coverage marks cleared", vim.log.levels.INFO, { title = "test" })
end

return M
