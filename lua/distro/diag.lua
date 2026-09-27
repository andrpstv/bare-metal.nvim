-- distro diagnostic command: consumer-facing LspAttach and path timings.
--
-- Design decisions (why this shape, not another):
--
-- 1. Async everywhere. The spec says the consumer's machine may be slow;
--    a sync wait can still hang if the server never responds. We use async
--    buf_request + a bounded wait loop, so we always make progress: either
--    the response arrives, or the wait expires and we record NOT MEASURED
--    with the reason and move on.
--
-- 2. Watchdog on the whole run (120 s). Learned from probe4.lua: an errored
--    callback that never fires left qa! unreachable. The watchdog writes
--    WATCHDOG_TIMEOUT and forces qa! regardless — a partial report beats a
--    window the user cannot close.
--
-- 3. No external binaries, no shell for measurement. We use only vim APIs
--    (vim.lsp, vim.uv, vim.fn) so the consumer on Windows without rg/git
--    still gets a report.
--
-- 4. Two hands, always. The "clean" hand does not depend on the consumer
--    having a Go project on disk: we synthesise a minimal Go module in
--    stdpath("cache")/distro-diag/ and measure that, then delete it. The
--    project-vs-module comparison is the point of the report; an unmeasured
--    clean hand makes the report worthless.
--
-- 5. Cumulative vs delta. Autocmd timestamps are cumulative from the start
--    of :edit. Printing them raw makes a 0.1 ms phase look like 65 ms. We
--    therefore record events in an ORDERED sequence (autocmds fire in a
--    defined order; a hash table does not preserve it) and report both
--    <phase>_at_ms (cumulative) and <phase>_delta_ms (cost of the phase
--    itself, i.e. the gap from the previous event).
--
-- 6. Every output line is either a number or says NOT MEASURED with a
--    reason. The self-check section counts them explicitly.

local M = {}

local uv = vim.uv or vim.loop

--- Phases we time, in the order :edit fires them. Order matters: deltas
--- are computed against the previous event actually recorded.
local PHASES = { "BufReadPre", "BufReadPost", "Syntax", "FileType", "BufEnter", "LspAttach" }

local function ms(t0)
	return (uv.hrtime() - t0) / 1e6
end

--- number -> "123.4ms", nil -> "n/a"
local function fmt_ms(v)
	if v == nil then
		return "n/a"
	end
	return string.format("%.1fms", v)
end

--- Count of loaded Lua modules (proxy for module-activation cost).
local function count_loaded_modules()
	local n = 0
	for _ in pairs(package.loaded) do
		n = n + 1
	end
	return n
end

local function header_block()
	local lines = {}

	local ver = vim.version()
	lines[#lines + 1] = "nvim          : " .. ver.major .. "." .. ver.minor .. "." .. ver.patch

	local os_name = "unknown"
	if vim.fn.has("win32") == 1 then
		os_name = "Windows"
	elseif vim.fn.has("win32unix") == 1 then
		os_name = "WSL"
	elseif vim.fn.has("mac") == 1 then
		os_name = "macOS"
	elseif vim.fn.has("linux") == 1 then
		os_name = "Linux"
	end
	lines[#lines + 1] = "os            : " .. os_name

	-- %LOCALAPPDATA% on Windows; the stdpath("cache") equivalent elsewhere.
	-- These are DIFFERENT directories, so we label which one we report
	-- rather than printing a bare path that looks like the wrong variable.
	if vim.fn.has("win32") == 1 then
		local lad = vim.env.LOCALAPPDATA
		if lad == nil or lad == "" then
			lines[#lines + 1] = "localappdata  : NOT MEASURED: %LOCALAPPDATA% not set"
		else
			lines[#lines + 1] = "localappdata  : " .. lad .. "  (%LOCALAPPDATA%)"
		end
	else
		lines[#lines + 1] = "localappdata  : n/a (Windows-only variable)"
		lines[#lines + 1] = "nvim_cache    : " .. vim.fn.stdpath("cache") .. "  (stdpath cache, unix equivalent)"
	end

	local gopls_path = vim.fn.exepath("gopls")
	if gopls_path == "" then
		lines[#lines + 1] = "gopls_path     : NOT MEASURED: gopls not on PATH"
	else
		lines[#lines + 1] = "gopls_path     : " .. gopls_path
	end

	local gopls_ver = "NOT MEASURED: gopls version query failed"
	if gopls_path ~= "" then
		-- Было: io.popen(gopls_path .. " version") + handle:read("*a").
		-- Это СИНХРОННЫЙ блокирующий вызов: он не крутит цикл событий, значит
		-- watchdog (таймер ниже) в этот момент молчит. Если gopls завис (а он
		-- зависает — network/версия/лицензия/заблокированный кэш), handle:read
		-- ждёт бесконечно, и ":DistroDiag" не завершается никогда. Для
		-- потребителя это главный риск: команда, которую нельзя прервать.
		-- Стало: асинхронный vim.system с явным timeout. Процесс принудительно
		-- убивается на 5000мс, ожидание ограничено тем же бюджетом и крутит
		-- цикл событий (vim.wait), так что watchdog наконец работает.
		local GopLS_VERSION_TIMEOUT_MS = 5000
		local finished, out, spawn_err = false, nil, nil
		pcall(vim.system, { gopls_path, "version" }, { text = true, timeout = GopLS_VERSION_TIMEOUT_MS }, function(obj)
			finished = true
			if obj and obj.code == 124 then
				spawn_err = "gopls version timed out after " .. GopLS_VERSION_TIMEOUT_MS .. "ms (process killed)"
			elseif obj and obj.code ~= 0 then
				spawn_err = "gopls version exited " .. tostring(obj.code) .. ": " .. vim.trim(tostring(obj.stderr or obj.stdout or ""))
			else
				out = tostring(obj and obj.stdout or "")
			end
		end)
		local w0 = uv.hrtime()
		while not finished and (uv.hrtime() - w0) / 1e6 < GopLS_VERSION_TIMEOUT_MS + 250 do
			vim.wait(20) -- pumps the loop: watchdog + editor stay alive
		end
		if not finished then
			gopls_ver = "NOT MEASURED: gopls version did not complete within " .. GopLS_VERSION_TIMEOUT_MS .. "ms (killed)"
		elseif spawn_err then
			gopls_ver = "NOT MEASURED: " .. spawn_err
		else
			gopls_ver = (out:match("gopls v([%d%.]+)") or out:match("(%d+%.%d+%.%d+)") or "unknown")
		end
	end
	lines[#lines + 1] = "gopls_version  : " .. gopls_ver

	local modcache_size = "NOT MEASURED: go module cache not found"
	for _, p in ipairs({
		vim.fn.expand("$GOMODCACHE"),
		vim.fn.expand("~/go/pkg/mod"),
		vim.fn.expand("$GOPATH/pkg/mod"),
	}) do
		if p ~= "" and vim.fn.isdirectory(p) == 1 then
			local count = 0
			local scan = uv.fs_scandir(p)
			if scan then
				while true do
					local name = uv.fs_scandir_next(scan)
					if not name then
						break
					end
					count = count + 1
				end
			end
			modcache_size = tostring(count) .. " entries at " .. p
			break
		end
	end
	lines[#lines + 1] = "modcache_size : " .. modcache_size

	local drive_kind = "LOCAL"
	if vim.fn.has("win32") == 1 and vim.fn.has("network") == 1 then
		drive_kind = "NETWORK"
	end
	lines[#lines + 1] = "drive_kind     : " .. drive_kind

	local ok_nproc, cpu_count = pcall(uv.nproc)
	if not ok_nproc then
		cpu_count = 1
	end
	lines[#lines + 1] = "weak_hw_profile: " .. (cpu_count <= 2 and "weak (<=2 CPUs)" or "off")

	local turbo_status = "off"
	local ok_turbo, turbo_mod = pcall(require, "core.turbo")
	if ok_turbo and turbo_mod.is_on then
		turbo_status = turbo_mod.is_on() and "on" or "off"
	end
	lines[#lines + 1] = "turbo          : " .. turbo_status

	return lines
end

--- Two sequential LSP requests, timed. Cold = first request (server has not
--- answered this session), warm = second (protocol and index warm).
--@param bufnr number
--@param sink table list to push NOT MEASURED reasons into
--@return table { RTT1_ms, RTT2_ms }
local function measure_lsp_rtt(bufnr, sink)
	local out = { RTT1_ms = nil, RTT2_ms = nil }

	local fname = vim.api.nvim_buf_get_name(bufnr)
	if fname == "" or fname:match("^%[") then
		sink[#sink + 1] = "gopls_RTT: buffer has no file on disk"
		return out
	end

	-- Put the cursor on a known symbol so the request has something to
	-- resolve. Prefer an identifier word over whitespace.
	--
	-- Возвращает позицию (строка, колонка) и само слово, либо nil. Раньше
	-- park_cursor_on_symbol() всегда сканировал с первой строки и в��звращал
	-- курсор в ТУ ЖЕ позицию: "nudge" не менял символ, поэтому RTT2 был
	-- вторым запросом к тому же самому слову и не был тёплым (warm не был
	-- быстрее cold -- именно это и видели 12.6/12.7 против 12.2/12.9).
	-- Теперь skip_known уводит на ДРУГОЙ идентификатор, и символ попадает
	-- в отчёт, чтобы это можно было проверить по числам.
	local function park_cursor_on_symbol(skip_known)
		local known_word = nil
		if skip_known then
			local cur = vim.api.nvim_win_get_cursor(0)
			local text = vim.api.nvim_buf_get_lines(bufnr, cur[1] - 1, cur[1], false)[1] or ""
			known_word = text:sub(cur[2] + 1):match("^[%a_][%w_]*")
		end
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, math.min(400, vim.api.nvim_buf_line_count(bufnr)), false)
		for i, text in ipairs(lines) do
			local from = 1
			while true do
				local s, e = text:find("[%a_][%w_]*", from)
				if not s then
					break
				end
				local word = text:sub(s, e)
				-- Пропускаем именно то слово, на котором стояли при RTT1.
				if not (known_word and word == known_word) then
					local col = math.max(s - 1, 0)
					pcall(vim.api.nvim_win_set_cursor, 0, { i, col })
					return { i, col }, word
				end
				from = e + 1
			end
		end
		return nil, nil
	end

	local rtt1_pos, rtt1_word = park_cursor_on_symbol()
	if not rtt1_pos then
		sink[#sink + 1] = "gopls_RTT: no identifier found in buffer"
		return out
	end
	out.symbol1 = rtt1_word

	local function do_request()
		local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/hover" })
		if #clients == 0 then
			-- Broaden: any client on the buffer, whatever its methods.
			clients = vim.lsp.get_clients({ bufnr = bufnr })
		end
		if #clients == 0 then
			return nil, "no LSP client attached to buffer"
		end

		local params = vim.lsp.util.make_position_params(0, "utf-16", { bufnr = bufnr })
		if not params then
			return nil, "make_position_params failed"
		end

		local t_start = uv.hrtime()
		local done, response, rerr = false, nil, nil

		local ok, req_err = pcall(vim.lsp.buf_request, bufnr, "textDocument/hover", params, function(err, res)
			rerr = err
			response = res
			done = true
		end)
		if not ok then
			return nil, "buf_request failed: " .. tostring(req_err)
		end

		local budget = 20000
		local w0 = uv.hrtime()
		while not done and (uv.hrtime() - w0) / 1e6 < budget do
			vim.wait(10)
		end

		local dt = (uv.hrtime() - t_start) / 1e6
		if not done then
			return nil, string.format("timeout after %.0fms (method textDocument/hover)", dt)
		end
		if rerr then
			return nil, "server error: " .. tostring(type(rerr) == "table" and (rerr.message or rerr.code) or rerr)
		end
		-- No error and a nil payload is a REAL round trip: the server
		-- answered "nothing to hover here". Reporting that as NOT
		-- MEASURED hid the headline numbers of this report.
		return dt, (response == nil and "empty payload" or nil)
	end

	local note = nil
	local rtt1, err1 = do_request()
	if rtt1 then
		out.RTT1_ms = rtt1
		note = err1
	else
		sink[#sink + 1] = "gopls_RTT1 (cold): " .. tostring(err1)
	end

	-- Warm: второй запрос. Уводим курсор на ДРУГОЙ идентификатор, иначе это
	-- тот же самый запрос к тому же слову и "warm" ничего не значит.
	local rtt2_pos, rtt2_word = park_cursor_on_symbol(true)
	if not rtt2_pos then
		-- Единственного-различного-символа в буфере нет: честно NOT MEASURED,
		-- а не выдаём повтор того же запроса за тёплый.
		sink[#sink + 1] = "gopls_RTT2 (warm): buffer has no second identifier distinct from '" .. tostring(rtt1_word) .. "'"
		out.note = note
		return out
	end
	out.symbol2 = rtt2_word
	local rtt2, err2 = do_request()
	if rtt2 then
		out.RTT2_ms = rtt2
	else
		sink[#sink + 1] = "gopls_RTT2 (warm): " .. tostring(err2)
	end
	out.note = note

	return out
end

--- Measure one file open: phase timings (cumulative + delta), LspAttach,
--- two LSP round-trips, and module counts.
--@param file_path string
--@param label string
--@return table result
local function measure_file_open(file_path, label)
	local t0 = uv.hrtime()

	local result = {
		file = file_path,
		label = label,
		phases = {}, -- ordered array of { name, at_ms, delta_ms }
		EDIT_total_ms = nil,
		modules_first_frame = nil,
		modules_settled = nil,
		not_measured = {},
	}

	local modules_before = count_loaded_modules()

	-- ORDERED event log. The autocmd firing order is the source of truth
	-- for deltas; iterating a hash table here would make the deltas
	-- irreproducible.
	local seq = {}
	local first_event_ms = nil

	local function record_event(name)
		local at = ms(t0)
		local delta = nil
		if #seq == 0 then
			first_event_ms = at
		else
			delta = at - seq[#seq].at_ms
		end
		seq[#seq + 1] = { name = name, at_ms = at, delta_ms = delta }
	end

	local augroup_id = vim.api.nvim_create_augroup("DistroDiagMeasure", { clear = true })

	for _, ev in ipairs(PHASES) do
		vim.api.nvim_create_autocmd(ev, {
			group = augroup_id,
			callback = function(args)
				-- Ignore events from buffers we are not measuring.
				if args and args.buf and args.buf ~= vim.api.nvim_get_current_buf() then
					return
				end
				record_event(ev)
			end,
		})
	end

	local modules_after_edit = nil
	-- Аудит блокирующих вызовов (watchdog молчит только там, где не крутится
	-- цикл событий):
	--   * io.popen "gopls version"  -- был единственным НЕОГРАНИЧЕННЫМ вызовом
	--     (жёсткий внешний процесс, ждал вечно). Теперь vim.system+timeout.
	--   * vim.cmd("edit") ниже -- синхронный, НО читает локальный файл только
	--     что записанный нами самим (make_clean/make_heavy_go_module) и не
	--     запускает внешних процессов. Зависнуть не на чем; время входит в
	--     EDIT_total_ms.
	--   * uv.fs_scandir по go/pkg/mod -- синхронный обход каталога, без
	--     внешних процессов; риск только медленный HDD, и это само по себе
	--     измеряемая величина для потребителя.
	--   * все vim.wait(...) -- ПОМИМО ОЖИДАНИЯ крутят цикл событий, поэтому
	--     watchdog и таймеры в них живы.
	-- Вывод: неограниченного блокирующего вызова, способного повесить команду,
	-- в diag.lua не осталось.
	local ok_edit, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(file_path))
	if not ok_edit then
		result.not_measured[#result.not_measured + 1] = "file_open: " .. tostring(err)
		pcall(vim.api.nvim_del_augroup_by_id, augroup_id)
		return result
	end

	-- Module count "at first frame": right after :edit returns, before we
	-- block on LSP. This is what the user sees on screen.
	modules_after_edit = count_loaded_modules()
	result.modules_first_frame = modules_after_edit

	-- Wait for LspAttach (bounded), then settle, then measure RTTs.
	local wait_start = uv.hrtime()
	local wait_budget = 15000 -- 15 s
	while ms(wait_start) < wait_budget do
		local last = seq[#seq]
		if last and last.name == "LspAttach" then
			break
		end
		vim.wait(25)
	end

	local attached = false
	for _, e in ipairs(seq) do
		if e.name == "LspAttach" then
			attached = true
		end
	end
	if not attached then
		result.not_measured[#result.not_measured + 1] = "LspAttach: not received in 15s"
	end

	-- Settle: let queued work (treesitter, ftplugins, gopls indexing) run,
	-- then take the settled module count.
	vim.wait(1500)
	result.modules_settled = count_loaded_modules()
	result.modules_delta = result.modules_settled - modules_after_edit
	result.modules_loaded_by_edit = modules_after_edit - modules_before

	-- LSP round-trips on the freshly opened buffer.
	local bufnr = vim.api.nvim_get_current_buf()
	local rtt = measure_lsp_rtt(bufnr, result.not_measured)
	result.gopls_RTT1_ms = rtt.RTT1_ms
	result.gopls_RTT2_ms = rtt.RTT2_ms
	result.symbol1 = rtt.symbol1
	result.symbol2 = rtt.symbol2

	result.EDIT_total_ms = ms(t0)
	result.phases = seq
	result.first_event_ms = first_event_ms

	pcall(vim.api.nvim_del_augroup_by_id, augroup_id)
	return result
end

--- Measure the gd path via the real mapping function.
local function measure_gd_path(bufnr)
	-- dispatch_return_ms — отдельное, честно названное поле: это НЕ ответ.
	local out = { symbol = "n/a", dispatch_return_ms = nil, to_response_ms = nil, jump_ms = nil, slow_response_notice = "NO" }

	local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/definition" })
	if #clients == 0 then
		return out, "no LSP definition client on buffer"
	end
	local pick_lsp = _G._pick_lsp
	if not pick_lsp then
		return out, "_pick_lsp not available (gd mapping not loaded)"
	end

	local before = vim.api.nvim_win_get_cursor(0)

	-- _pick_lsp АСИНХРОНЕН (keymap/pick.lua -> vim.lsp.buf_request), поэтому
	-- время возврата из pcall(pick_lsp, ...) — это диспетчеризация, а НЕ
	-- время до ответа. Замерять его и называть "to_response" — ровно тот
	-- дефект, который 6fa8fde починил в трейсе. Поэтому мы перехватываем
	-- vim.lsp.buf_request на время прогона и снимаем реальные метки:
	--   t_send     — запрос ушёл серверу
	--   t_response — сервер ответил (колбэк вызван)
	--   курсор     — наблюдаем до реального прыжка
	local orig_buf_request = vim.lsp.buf_request
	local t_send, t_response, saw_request = nil, nil, false
	vim.lsp.buf_request = function(b, method, params, handler)
		if method ~= "textDocument/definition" then
			return orig_buf_request(b, method, params, handler)
		end
		saw_request = true
		t_send = uv.hrtime()
		return orig_buf_request(b, method, params, function(...)
			if t_response == nil then
				t_response = uv.hrtime()
			end
			return handler(...)
		end)
	end

	local t0 = uv.hrtime()
	local ok, err = pcall(pick_lsp, "definition", { jump1 = true })
	out.dispatch_return_ms = (uv.hrtime() - t0) / 1e6
	if not ok then
		vim.lsp.buf_request = orig_buf_request
		out.symbol = vim.fn.expand("<cword>")
		out.slow_response_notice = "YES"
		pcall(vim.api.nvim_win_set_cursor, 0, before)
		return out, "gd raised: " .. tostring(err)
	end

	-- Ждём ответа, крутя цикл событий (иначе колбэк не придёт).
	local budget_ms = 15000
	local w0 = uv.hrtime()
	while t_response == nil and (uv.hrtime() - w0) / 1e6 < budget_ms do
		vim.wait(10)
	end
	vim.lsp.buf_request = orig_buf_request

	out.symbol = vim.fn.expand("<cword>")

	if not saw_request then
		out.slow_response_notice = "YES"
		return out, "gd did not issue textDocument/definition (client missing, or request rejected before dispatch)"
	end
	if t_response == nil then
		out.slow_response_notice = "YES"
		return out, string.format("no server response to textDocument/definition within %dms", budget_ms)
	end

	-- Время ДО ОТВЕТА: отправка -> колбэк сервера.
	out.to_response_ms = (t_response - t_send) / 1e6

	-- Прыжок происходит в том же колбэке (vim.cmd.edit + set_cursor), плюс
	-- возможен асинхронный hop. Наблюдаем курсор, пока тот не уедет.
	local t_jump = nil
	local jw0 = uv.hrtime()
	local jbudget = 5000
	while (uv.hrtime() - jw0) / 1e6 < jbudget do
		local cur = vim.api.nvim_win_get_cursor(0)
		if cur[1] ~= before[1] or cur[2] ~= before[2] then
			t_jump = uv.hrtime()
			break
		end
		vim.wait(10)
	end

	if t_jump then
		-- Время ДО ПРЫЖКА: от отправки запроса до движения курсора.
		out.jump_ms = (t_jump - t_send) / 1e6
	else
		-- Нет прыжка — это не ноль и не "быстро": такого измерения нет.
		out.no_jump_reason = "cursor did not move within 5s (multi-result picker, no results, or cursor moved first)"
	end
	if out.to_response_ms > 2000 then
		out.slow_response_notice = "YES"
	end
	return out, nil
end

--- Probe executable() calls and time them.
local function probe_executable()
	local out = { calls = 0, total_ms = 0 }
	local t0 = uv.hrtime()
	for _, bin in ipairs({ "rg", "git", "gopls", "go", "lua", "gcc", "make", "curl" }) do
		out.calls = out.calls + 1
		vim.fn.executable(bin)
	end
	out.total_ms = (uv.hrtime() - t0) / 1e6
	return out
end

--- Build a minimal Go module on disk so the "clean project" hand can
--- always be measured, in any environment, without a Go project present.
--@return string|nil dir, table cleanup
local function make_clean_go_module()
	local dir = vim.fn.stdpath("cache") .. "/distro-diag/clean-go"
	vim.fn.mkdir(dir, "p")

	vim.fn.writefile({ "module distrodiag/clean", "", "go 1.21", "" }, dir .. "/go.mod")
	vim.fn.writefile({
		"package main",
		"",
		"import \"fmt\"",
		"",
		"// Greet is a deliberately small symbol for hover/definition probes.",
		"func Greet(name string) string {",
		"\treturn fmt.Sprintf(\"hello, %s\", name)",
		"}",
		"",
		"func main() {",
		"\tmsg := Greet(\"distro\")",
		"\tfmt.Println(msg)",
		"}",
		"",
	}, dir .. "/main.go")

	local function cleanup()
		vim.fn.delete(dir, "rf")
	end
	return dir, { cleanup = cleanup }
end

--- Build a Go module that actually imports the mongo driver.
--- gopls refuses to answer requests for files that live INSIDE the module
--- cache ("no package metadata for file ..."), so the heavy hand has to be
--- a real module that imports the driver. That reproduces the expensive
--- case (many transitive imports, real type info) in any environment.
--@return string|nil dir, table|nil handle
--- Find a mongo-driver version present in the module cache, so the heavy
--- hand can require exactly the version the consumer actually has.
--@return string|nil module_path, string|nil version
local function detect_mongo_driver()
	local candidates = {
		{ mod = "go.mongodb.org/mongo-driver/v2", dir = "mongo-driver/v2" },
		{ mod = "go.mongodb.org/mongo-driver", dir = "mongo-driver" },
	}
	for _, root in ipairs({
		vim.fn.expand("$GOMODCACHE"),
		vim.fn.expand("~/go/pkg/mod"),
		vim.fn.expand("$GOPATH/pkg/mod"),
	}) do
		if root ~= "" and vim.fn.isdirectory(root) == 1 then
			for _, c in ipairs(candidates) do
				local base = root .. "/go.mongodb.org/" .. c.dir
				if vim.fn.isdirectory(base) == 1 then
					-- Module cache names versions as <name>@<version>
					local versions = vim.fn.glob(base .. "@*", true, true)
					if #versions > 0 then
						local newest = versions[#versions]
						local ver = newest:match("@([^/]+)$")
						if ver then
							return c.mod, ver
						end
					end
				end
			end
		end
	end
	return nil, nil
end

local function make_heavy_go_module(driver_module, driver_version)
	local dir = vim.fn.stdpath("cache") .. "/distro-diag/heavy-go"
	vim.fn.mkdir(dir, "p")

	vim.fn.writefile({
		"module distrodiag/heavy",
		"",
		"go 1.21",
		"",
		"require " .. driver_module .. " " .. driver_version,
		"",
	}, dir .. "/go.mod")

	vim.fn.writefile({
		"package main",
		"",
		"import (",
		"\t\"context\"",
		"\t\"fmt\"",
		"",
		"\t\"go.mongodb.org/mongo-driver/v2/mongo\"",
		"\t\"go.mongodb.org/mongo-driver/v2/mongo/options\"",
		"\t\"go.mongodb.org/mongo-driver/v2/mongo/readpref\"",
		")",
		"",
		"// Connect is the probe symbol: hovering or jumping to it forces gopls",
		"// to load the driver's package graph.",
		"func Connect(uri string) (*mongo.Client, error) {",
		"\tclient, err := mongo.Connect(options.Client().ApplyURI(uri))",
		"\tif err != nil {",
		"\t\treturn nil, err",
		"\t}",
		"\tif err := client.Ping(context.Background(), readpref.Primary()); err != nil {",
		"\t\treturn nil, err",
		"\t}",
		"\treturn client, nil",
		"}",
		"",
		"func main() {",
		"\tfmt.Println(\"distro-diag heavy probe\")",
		"}",
		"",
	}, dir .. "/main.go")

	local function cleanup()
		vim.fn.delete(dir, "rf")
	end
	return dir, { cleanup = cleanup }
end

local function file_block_lines(result, label)
	local lines = {}
	lines[#lines + 1] = "--- per-file open: " .. label .. " ---"
	lines[#lines + 1] = "file            : " .. result.file
	lines[#lines + 1] = "-- phase columns:"
	lines[#lines + 1] = "--   <phase>_at_ms    = cumulative ms since :edit started"
	lines[#lines + 1] = "--   <phase>_delta_ms = ms THIS phase cost (at_ms minus previous event's at_ms)"
	lines[#lines + 1] = "-- events fire in this order; deltas follow the recorded order."

	for _, e in ipairs(result.phases) do
		lines[#lines + 1] = string.format("%-16s_at_ms    : %s", e.name, fmt_ms(e.at_ms))
		if e.delta_ms == nil then
			lines[#lines + 1] = string.format("%-16s_delta_ms : n/a (first event)", e.name)
		else
			lines[#lines + 1] = string.format("%-16s_delta_ms : %s", e.name, fmt_ms(e.delta_ms))
		end
	end

	lines[#lines + 1] = "EDIT_total_ms   : " .. fmt_ms(result.EDIT_total_ms)
	lines[#lines + 1] = "modules_first_frame : " .. tostring(result.modules_first_frame or "n/a")
	lines[#lines + 1] = "modules_settled : " .. tostring(result.modules_settled or "n/a")
	lines[#lines + 1] = "modules_loaded_by_edit : " .. tostring(result.modules_loaded_by_edit or "n/a")
	lines[#lines + 1] = "gopls_RTT1_ms (cold, symbol '" .. tostring(result.symbol1 or "?") .. "') : " .. fmt_ms(result.gopls_RTT1_ms)
	lines[#lines + 1] = "gopls_RTT2_ms (warm, DIFFERENT symbol '" .. tostring(result.symbol2 or "?") .. "') : " .. fmt_ms(result.gopls_RTT2_ms)

	for _, nm in ipairs(result.not_measured) do
		lines[#lines + 1] = "NOT MEASURED: " .. nm
	end
	return lines
end

local function gd_block_lines(result, err)
	local lines = {}
	lines[#lines + 1] = "--- gd path ---"
	lines[#lines + 1] = "gd_symbol       : " .. (result.symbol or "n/a")
	-- Имена намеренно длинные: gd_response_wait_ms — от отправки запроса до
	-- ОТВЕТА сервера; gd_dispatch_return_ms — синхронный возврат _pick_lsp
	-- (диспетчеризация, НЕ время до ответа). Одно нельзя прочитать как другое.
	lines[#lines + 1] = "gd_dispatch_return_ms (_pick_lsp sync return, NOT a response time) : " .. fmt_ms(result.dispatch_return_ms)
	lines[#lines + 1] = "gd_response_wait_ms (request sent -> server response) : " .. fmt_ms(result.to_response_ms)
	lines[#lines + 1] = "gd_jump_ms (request sent -> cursor moved on result) : " .. fmt_ms(result.jump_ms)
	if result.no_jump_reason then
		lines[#lines + 1] = "gd_jump_not_measured : " .. result.no_jump_reason
	end
	lines[#lines + 1] = "slow_response_notice : " .. (result.slow_response_notice or "NO")
	if err then
		lines[#lines + 1] = "NOT MEASURED: gd path: " .. err
	end
	return lines
end

local function executable_block_lines(result)
	return {
		"--- executable() probe ---",
		"executable_calls        : " .. tostring(result.calls),
		"executable_total_ms     : " .. string.format("%.1fms", result.total_ms),
	}
end

local function selfcheck_block_lines(all_lines)
	local lines = { "=== self-check ===" }
	local measured, not_measured = 0, 0
	local details = {}
	for _, line in ipairs(all_lines) do
		if line:match("NOT MEASURED") then
			not_measured = not_measured + 1
			details[#details + 1] = line
		elseif line:match("%d+%.?%d*ms") or line:match("%d+ entries") or line:match(":%s*%d+$") then
			measured = measured + 1
		end
	end
	lines[#lines + 1] = string.format("SELFCHECK: %d measured, %d NOT MEASURED", measured, not_measured)
	for _, d in ipairs(details) do
		lines[#lines + 1] = "  " .. d
	end
	return lines
end

local function run_diag()
	local all_lines = {}
	local cleanups = {}

	local watchdog = uv.new_timer()
	watchdog:start(120000, 0, vim.schedule_wrap(function()
		all_lines[#all_lines + 1] = "WATCHDOG_TIMEOUT: overall run exceeded 120s"
		local p = vim.fn.stdpath("cache") .. "/distro-diag.txt"
		vim.fn.mkdir(vim.fn.stdpath("cache"), "p")
		vim.fn.writefile(vim.split(table.concat(all_lines, "\n"), "\n", { plain = true }), p)
		for _, c in ipairs(cleanups) do
			pcall(c)
		end
		vim.cmd("qa!")
	end))

	all_lines[#all_lines + 1] = "=== distro diagnostic ==="
	for _, l in ipairs(header_block()) do
		all_lines[#all_lines + 1] = l
	end
	all_lines[#all_lines + 1] = ""

	-- Hand 1: clean project. Synthesised, so it exists everywhere.
	local clean_dir, clean_handle = make_clean_go_module()
	if clean_handle then
		cleanups[#cleanups + 1] = clean_handle.cleanup
	end
	if clean_dir then
		local r = measure_file_open(clean_dir .. "/main.go", "clean project (synthesised)")
		for _, l in ipairs(file_block_lines(r, "clean project (synthesised)")) do
			all_lines[#all_lines + 1] = l
		end
		all_lines[#all_lines + 1] = ""
	end

	-- Hand 2: the heavy, many-imports case. gopls will not answer requests
	-- for a file inside the module cache itself ("no package metadata"),
	-- so we measure a synthesised module that genuinely imports the driver.
	local driver_module, driver_version = detect_mongo_driver()
	if driver_module then
		local heavy_dir, heavy_handle = make_heavy_go_module(driver_module, driver_version)
		if heavy_handle then
			cleanups[#cleanups + 1] = heavy_handle.cleanup
		end
		local r = measure_file_open(heavy_dir .. "/main.go", "heavy import (" .. driver_module .. ")")
		for _, l in ipairs(file_block_lines(r, "heavy import (" .. driver_module .. ")")) do
			all_lines[#all_lines + 1] = l
		end
		all_lines[#all_lines + 1] = ""
	else
		all_lines[#all_lines + 1] = "NOT MEASURED: go.mongodb.org/mongo-driver not in module cache"
		all_lines[#all_lines + 1] = ""
	end

	-- gd path on whichever Go buffer is current
	local gd_result, gd_err = measure_gd_path(vim.api.nvim_get_current_buf())
	for _, l in ipairs(gd_block_lines(gd_result, gd_err)) do
		all_lines[#all_lines + 1] = l
	end
	all_lines[#all_lines + 1] = ""

	for _, l in ipairs(executable_block_lines(probe_executable())) do
		all_lines[#all_lines + 1] = l
	end
	all_lines[#all_lines + 1] = ""

	for _, l in ipairs(selfcheck_block_lines(all_lines)) do
		all_lines[#all_lines + 1] = l
	end

	pcall(watchdog.stop, watchdog)
	pcall(watchdog.close, watchdog)

	-- Remove the synthesised module BEFORE writing the report, so nothing
	-- temporary survives the run.
	for _, c in ipairs(cleanups) do
		pcall(c)
	end

	local report = table.concat(all_lines, "\n")
	local cache_dir = vim.fn.stdpath("cache")
	vim.fn.mkdir(cache_dir, "p")
	local report_path = cache_dir .. "/distro-diag.txt"
	vim.fn.writefile(vim.split(report, "\n", { plain = true }), report_path)

	local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or ""
	local temp_path = nil
	if temp_dir ~= "" then
		if vim.fn.isdirectory(temp_dir) == 0 then
			vim.fn.mkdir(temp_dir, "p")
		end
		temp_path = temp_dir .. "/distro-diag-latest.txt"
		vim.fn.writefile(vim.split(report, "\n", { plain = true }), temp_path)
	end

	vim.cmd("new")
	vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(report, "\n", { plain = true }))
	vim.bo.modifiable = false
	vim.bo.filetype = "markdown"

	vim.cmd("echo 'DistroDiag report: " .. report_path .. "'")
	if temp_path then
		vim.cmd("echo 'Copy in %TEMP%: " .. temp_path .. "'")
	end
end

vim.api.nvim_create_user_command("DistroDiag", run_diag, {
	nargs = "?",
	desc = "distro: consumer diagnostic (LspAttach, paths, timings)",
	complete = function()
		return {}
	end,
})

M.run = run_diag
return M
