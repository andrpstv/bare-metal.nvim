-- dev.testmarks — результаты Go-тестов/бенчмарков/покрытия прямо в коде (eol virtual text).
--
-- Почему свой модуль, а не часть dev.test: там и так разбор прогона + qf + coverage-знаки;
-- здесь только «данные → extmarks», без процессов. Нет плагина: это ~150 строк поверх
-- extmarks, а neotest ради гаттера тащит nio + адаптер. Грузится лениво из dev.test.

local M = {}

local ns_t = vim.api.nvim_create_namespace("devtest_results")
local ns_b = vim.api.nvim_create_namespace("devtest_bench")
local ns_c = vim.api.nvim_create_namespace("devtest_covfunc")

-- shortcut: хранилище только в памяти, бенч-baseline живёт одну сессию Neovim; нужна история между
-- сессиями или сравнение с main — писать в stdpath("state") (json) и ключевать по ревизии.
local store = { tests = {}, bench = {}, cover = {} } -- tests/bench: dir -> name -> {...}; cover: abs file -> lnum -> pct

--- realpath-нормализация (/var vs /private/var): ключи dir и имена буферов должны сходиться.
function M.canon(p)
	local ok, rp = pcall(vim.uv.fs_realpath, p)
	if ok and rp and rp ~= "" then
		return rp
	end
	return vim.fs.normalize(p)
end

local function fmt_elapsed(s)
	s = s or 0
	if s < 1 then
		return string.format("%dms", math.floor(s * 1000 + 0.5))
	end
	return string.format("%.2fs", s)
end

--- `go test -json` строки -> { Name = {status, elapsed} }. Подтесты (с "/") и не-Test (бенчи) пропускаем.
---@param lines string[]
function M._parse_tests(lines)
	local res = {}
	for _, line in ipairs(lines) do
		local ok, ev = pcall(vim.json.decode, line)
		if ok and type(ev) == "table" and ev.Test and not ev.Test:find("/", 1, true) and ev.Test:match("^Test[%w_]*$") then
			if ev.Action == "pass" or ev.Action == "fail" or ev.Action == "skip" then
				res[ev.Test] = { status = ev.Action, elapsed = tonumber(ev.Elapsed) or 0 }
			end
		end
	end
	return res
end

--- Склеенный Output-поток -> { Name = {ns, allocs?} }. go -json режет строки, поэтому на вход blob.
---@param blob string
function M._parse_bench(blob)
	local res = {}
	for line in blob:gmatch("[^\n]+") do
		local name, ns, rest = line:match("^(Benchmark[%w_]*)%-?%d*%s+%d+%s+([%d%.]+)%s+ns/op(.*)$")
		if name then
			res[name] = { ns = tonumber(ns), allocs = tonumber(rest:match("(%d+)%s+allocs/op")) }
		end
	end
	return res
end

--- Дельта ns/op к прошлому прогону: nil (первый запуск) или {text, hl}.
function M._delta(prev, cur)
	if not prev or prev <= 0 then
		return nil
	end
	local pct = (cur - prev) / prev * 100
	if pct > 5 then
		return { text = string.format("▲%+.0f%%", pct), hl = "DiagnosticError" }
	elseif pct < -5 then
		return { text = string.format("▼%+.0f%%", pct), hl = "DiagnosticOk" }
	end
	return { text = "≈", hl = "Comment" }
end

--- Вывод `go tool cover -func`: список {file, lnum, pct}; строка `total:` не матчится (нет номера строки).
function M._parse_cover_func(text)
	local res = {}
	for line in text:gmatch("[^\n]+") do
		local file, lnum, pct = line:match("^(.-):(%d+):%s+%S+%s+([%d%.]+)%%%s*$")
		if file then
			res[#res + 1] = { file = file, lnum = tonumber(lnum), pct = tonumber(pct) }
		end
	end
	return res
end

local function cov_hl(pct)
	return pct < 50 and "DiagnosticError" or pct < 80 and "DiagnosticWarn" or "DiagnosticOk"
end

local function mark(buf, ns, row, chunks)
	pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, { virt_text = chunks, virt_text_pos = "eol" })
end

--- Перерисовать метки одного буфера из хранилища (идемпотентно).
function M.render(buf)
	if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
		return
	end
	local name = vim.api.nvim_buf_get_name(buf)
	if not name:match("%.go$") then
		return
	end
	for _, ns in ipairs({ ns_t, ns_b, ns_c }) do
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	end
	local dir = M.canon(vim.fs.dirname(name))
	local tests, bench = store.tests[dir], store.bench[dir]
	local cov = store.cover[M.canon(name)]
	if name:match("_test%.go$") and (tests or bench) then
		for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
			local t = tests and l:match("^func (Test[%w_]+)%(")
			local b = bench and l:match("^func (Benchmark[%w_]+)%(")
			local r = t and tests[t]
			if r then
				local icon, hl = "✓", "DiagnosticOk"
				if r.status == "fail" then
					icon, hl = "✗", "DiagnosticError"
				elseif r.status == "skip" then
					icon, hl = "↷", "Comment"
				end
				local txt = r.status == "skip" and (icon .. " skip") or (icon .. " " .. fmt_elapsed(r.elapsed))
				mark(buf, ns_t, i - 1, { { " " .. txt, hl } })
			end
			r = b and bench[b]
			if r then
				local txt = string.format(" %g ns/op", r.ns) .. (r.allocs and (" · " .. r.allocs .. " allocs") or "")
				local chunks = { { txt, "Comment" } }
				if r.delta then
					chunks[2] = { " " .. r.delta.text, r.delta.hl }
				end
				mark(buf, ns_b, i - 1, chunks)
			end
		end
	end
	if cov then
		for lnum, pct in pairs(cov) do
			mark(buf, ns_c, lnum - 1, { { string.format(" %d%%", math.floor(pct + 0.5)), cov_hl(pct) } })
		end
	end
end

local function render_all()
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		M.render(b)
	end
end

local augrp
--- Лениво: автокоманда появляется только когда есть что показывать (старт не платит).
local function ensure_autocmd()
	if not augrp then
		augrp = vim.api.nvim_create_augroup("devtest_marks", { clear = true })
		vim.api.nvim_create_autocmd("BufWinEnter", {
			group = augrp,
			pattern = "*.go",
			callback = function(a)
				M.render(a.buf)
			end,
		})
	end
end

--- Влить результаты прогона. mode "test": raw — строки -json; "bench": blob Output-потока.
---@param dir string
---@param mode "test"|"bench"
---@param data string[]|string
function M.apply(dir, mode, data)
	dir = M.canon(dir)
	if mode == "bench" then
		local per = store.bench[dir] or {}
		for n, r in pairs(M._parse_bench(data)) do
			-- Дельта считается от предыдущего ns/op этого же бенча; остаётся до следующего прогона.
			r.delta = M._delta(per[n] and per[n].ns, r.ns)
			per[n] = r
		end
		store.bench[dir] = per
	else
		local per = store.tests[dir] or {}
		for n, r in pairs(M._parse_tests(data)) do
			per[n] = r -- слияние: перезапуск одного теста обновляет только его метку
		end
		store.tests[dir] = per
	end
	ensure_autocmd()
	render_all()
end

--- Покрытие по функциям: items из _parse_cover_func, resolve — отображение import-path -> абсолютный файл.
function M.apply_cover(items, resolve)
	store.cover = {}
	for _, it in ipairs(items) do
		local abs = resolve(it.file)
		if abs then
			store.cover[abs] = store.cover[abs] or {}
			store.cover[abs][it.lnum] = it.pct
		end
	end
	ensure_autocmd()
	render_all()
end

function M.clear_cover()
	store.cover = {}
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) then
			vim.api.nvim_buf_clear_namespace(b, ns_c, 0, -1)
		end
	end
end

--- Для тестов: сбросить всё состояние.
function M._reset()
	store = { tests = {}, bench = {}, cover = {} }
end

return M
