-- dev.debug — Vim-native отладка Go поверх nvim-dap (без dap-ui/nio/dap-go).
--
-- Архитектура: движок — вендоренный nvim-dap (протокол, сессии, breakpoints);
-- delve-адаптер — 20 строк (dlv dap, бинарь уже provision'ится через
-- :DistroBinaries); UI — dap.ui.widgets ИЗ ЯДРА dap (hover/preview/sidebar),
-- repl — встроенный; состояние — знаки (:signs в tool.dap) + notify.
-- Загрузка dap — только по первому debug-keymap (ensure): пока не дебажишь,
-- цена ноль (нет event/cmd-триггеров в manifest осознанно).

local M = {}

local ensured = false

-- Owned delve server handles, spawned by our adapter only (never matched
-- by executable name: taskkill /IM dlv.exe could hit another project or
-- another Neovim instance). Entries removed when the process exits.
M._dlv_handles = M._dlv_handles or {}

local function track_dlv(handle)
	if handle then
		M._dlv_handles[#M._dlv_handles + 1] = handle
	end
end

local function untrack_dlv(handle)
	for i, h in ipairs(M._dlv_handles) do
		if h == handle then
			table.remove(M._dlv_handles, i)
			return
		end
	end
end

--- Kill owned live delve processes. Only handles WE spawned are touched.
---@param why string notify context (empty = silent)
local function kill_owned_dlv(why)
	for _, h in ipairs(M._dlv_handles) do
		local ok_c, closing = pcall(h.is_closing, h)
		if ok_c and not closing then
			if pcall(h.kill, h, "sigterm") and why ~= "" then
				vim.notify("[debug] stopped owned dlv (" .. why .. ")", vim.log.levels.INFO, { title = "debug" })
			end
		end
	end
end

-- Redact credentials embedded in proxy URLs before dlv/go output reaches
-- notify: test-binary compilation errors can echo the (corp, credentialed)
-- GOPROXY URL. Same helper shape as distro.diag / core.health.
local function redact_proxy(s)
	local ok, mirror = pcall(require, "distro.mirror")
	if ok and mirror and mirror.redact then
		local ok2, out = pcall(mirror.redact, tostring(s or ""))
		if ok2 and type(out) == "string" then
			return out
		end
	end
	return tostring(s or ""):gsub("://[^@]*@", "://***@")
end

--- Загрузить dap + delve-адаптер + конфигурации. Идемпотентно.
---@return boolean ok, any dap_or_err
function M.ensure()
	if ensured then
		return true, require("dap")
	end
	local ok_ld = require("distro.loader").load("nvim-dap")
	if not ok_ld then
		vim.notify("[debug] nvim-dap missing — :DistroInstall nvim-dap", vim.log.levels.ERROR, { title = "debug" })
		return false, nil
	end
	local ok_dap, dap = pcall(require, "dap")
	if not ok_dap then
		vim.notify("[debug] dap load failed: " .. tostring(dap):sub(1, 160), vim.log.levels.ERROR, { title = "debug" })
		return false, nil
	end
	if vim.fn.executable("dlv") ~= 1 then
		vim.notify(
			"[debug] 'dlv' not in PATH — run :DistroBinaries to install delve",
			vim.log.levels.WARN,
			{ title = "debug" }
		)
	end
	-- Delve DAP напрямую, без nvim-dap-go: меньше версий — меньше дрейфа.
	-- Windows-закалка (по тикету: висело с консолью "_debug_bin.exe"):
	--   1. dlv резолвим в абсолютный путь (exepath находит .exe, пробелы
	--      в пути больше не вопрос shell-квотинга — spawn без shell);
	--   2. свободный порт вместо фиксированного (коллизии/файрвол-профили);
	--   3. пайпы ОБЯЗАТЕЛЬНО читаем: нечитаемый stderr переполняется и
	--      delve встаёт насмерть — это и было зависание;
	--   4. hide=true на Windows: без него консольному dlv винда рисует
	--      отдельное окно (DETACHED_PROCESS консоли не прячет);
	--   5. ждём listen вместо sleep(100): на медленной VM delve поднимается
	--      дольше; колбэк отдаём только когда порт реально слушает, иначе
	--      nvim-dap пишет "adapter didn't respond";
	--   6. stderr копим (срез) и показываем хвост при неудаче — вместо тишины.
	dap.adapters.go = function(callback)
		local dlv = vim.fn.exepath("dlv")
		if dlv == "" then
			vim.schedule(function()
				vim.notify("[debug] 'dlv' not found in PATH — run :DistroBinaries to install delve", vim.log.levels.ERROR, { title = "debug" })
			end)
			return
		end
    -- Свободный порт отдаёт сам delve: `-l 127.0.0.1:0`, ОС выбирает порт,
    -- delve печатает `DAP server listening at: 127.0.0.1:PORT`. Парсим эту
    -- строку из stdout вместо пробных TCP-соединений: голый connect без
    -- handshake delve трактует как обрыв и может завершаться, а парсинг
    -- ничего лишнего не трогает.
    local stdout = vim.uv.new_pipe(false)
    local stderr = vim.uv.new_pipe(false)
    local errlog = {}
    local finished = false
    local outbuf = ""
    local function finish(ok, port)
      if finished then
        return
      end
      finished = true
      if ok and port then
        -- Колбэк — только из главного цикла: read-колбэки libuv —
        -- fast event, а nvim-dap внутри attach тянет
        -- require("dap.session") → logger → mkdir, что в fast event
        -- запрещено (E5560).
        -- initialize_timeout_sec: delve собирает тестовый бинарь ДО ответа
        -- на initialize; дефолт nvim-dap (4с) даёт ложный "adapter didn't
        -- respond" на холодную сборку. 20с покрывает реалистичную сборку,
        -- но не маскирует мёртвый адаптер: до initialize дело доходит
        -- только после реального listen (см. выше), а провал listen и
        -- код выхода отчитываются отдельно.
        vim.schedule(function()
          callback({ type = "server", host = "127.0.0.1", port = port, options = { initialize_timeout_sec = 20 } })
        end)
      else
        local tail = redact_proxy(table.concat(errlog):sub(-500))
        pcall(function()
          if handle then
            handle:kill("sigterm")
            untrack_dlv(handle)
          end
        end)
        vim.schedule(function()
          vim.notify(
            "[debug] dlv did not start listening within 20s"
              .. (tail ~= "" and (" — dlv output: " .. tail:gsub("%s+", " ")) or " — check firewall/antivirus for localhost listeners and that `dlv dap` works manually"),
            vim.log.levels.ERROR,
            { title = "debug" }
          )
        end)
      end
    end
    local started = vim.uv.hrtime()
    local function drain(pipe)
      pcall(vim.uv.read_start, pipe, function(err, data)
        if finished then
          return
        end
        if data then
          -- Срез: delve болтлив (сборка тестов), память не растим.
          errlog[#errlog + 1] = data:sub(-4000)
          if #errlog > 8 then
            table.remove(errlog, 1)
          end
          -- Слушаем оба пайпа: delve пишет listening-строку то в stdout,
          -- то в stderr в зависимости от версии/платформы.
          outbuf = (outbuf .. data):sub(-2000)
          local port = outbuf:match("DAP server listening at:%s*127%.0%.0%.1:(%d+)")
          if port then
            finish(true, tonumber(port))
            return
          end
          if (vim.uv.hrtime() - started) / 1e6 > 20000 then
            finish(false)
          end
        elseif err then
          pcall(vim.uv.read_stop, pipe)
        end
      end)
    end
    local is_win = vim.uv.os_uname().sysname == "Windows_NT"
    local handle, pid_or_err = vim.uv.spawn(dlv, {
      stdio = { nil, stdout, stderr },
      args = { "dap", "-l", "127.0.0.1:0" },
      detached = true,
      hide = is_win or nil, -- CREATE_NO_WINDOW: без консольного окна
    }, function(code)
		pcall(vim.uv.read_stop, stdout)
		pcall(vim.uv.read_stop, stderr)
		pcall(stdout.close, stdout)
		pcall(stderr.close, stderr)
		if handle then
			pcall(handle.close, handle)
			untrack_dlv(handle)
			handle = nil
		end
		-- Процесс мёртв: 20s-сторож слушанья больше не актуален, иначе он
		-- следом выдаст ложное "did not start listening" поверх уже
		-- показанной причины (например, "exited with code 3"). Флаг
		-- ставим ПОСЛЕ разбора кода — ветке code==0 он нужен для решения.
		if code ~= 0 then
			local tail = redact_proxy(table.concat(errlog):sub(-500))
			vim.schedule(function()
				vim.notify(
					"[debug] dlv exited with code " .. code .. (tail ~= "" and (": " .. tail:gsub("%s+", " ")) or ""),
					vim.log.levels.ERROR,
					{ title = "debug" }
				)
			end)
		elseif not finished then
			-- Умер до listen без ошибки: без этого вообще ни одного
			-- сообщения (код 0 молчит, а 20s-сторож ниже глушим).
			vim.schedule(function()
				vim.notify("[debug] dlv exited before listening (code 0) — check `dlv dap` manually", vim.log.levels.ERROR, { title = "debug" })
			end)
		end
		finished = true
	end)
    if not handle then
      vim.schedule(function()
        vim.notify("[debug] cannot start dlv: " .. tostring(pid_or_err), vim.log.levels.ERROR, { title = "debug" })
      end)
      return
    end
    track_dlv(handle)
    -- read_start СТРОГО после spawn: чтение, начатое до спавна, libuv
    -- молча инвалидирует при dup пайпов в потомка — данные не приходят
    -- вообще (проверено: до — тишина, после — 41 байт listening-строки).
    drain(stdout)
    drain(stderr)
    -- Независимый 20s-сторож: проверка таймаута внутри drain срабатывает
    -- только на входящих данных; молча висящий процесс (ни байта в stdout
    -- и stderr) иначе ждал бы только 90s-сторожа. finish идемпотентен.
    vim.defer_fn(function()
      finish(false)
    end, 20000)
    -- Сторож от orphan-dlv: если launch упал, nvim-dap сессию не создаёт,
    -- а адаптерный dlv остаётся слушать навсегда (видели живой процесс
    -- после "Failed to launch"). Через 90с проверяем: хендл жив, а сессии
    -- нет — значит этот запуск ни во что не превратился, гасим.
    -- Ложное срабатывание (сборка дольше 90с) лечится повторным запуском.
    -- Edge: успешный повторный запуск маскирует старый stray (сессия есть) —
    -- остаток в худшем случае один процесс на цепочку fail→retry, чинится
    -- повторным dx/выходом; тихое накопление исключено.
    local my_handle = handle
    vim.defer_fn(function()
      local ok_s, dapmod = pcall(require, "dap")
      if ok_s and dapmod.session() ~= nil then
        return -- живая сессия: руки прочь
      end
      if not my_handle then
        return
      end
      local ok_c, closing = pcall(my_handle.is_closing, my_handle)
      if not ok_c or closing then
        return -- уже мёртв/закрыт
      end
      if pcall(my_handle.kill, my_handle, "sigterm") then
        vim.notify("[debug] killed stale dlv without session — safe to retry", vim.log.levels.WARN, { title = "debug" })
      end
    end, 90000)
  end
	dap.configurations.go = {
		{
			type = "go",
			name = "Debug package",
			request = "launch",
			program = "${fileDirname}",
		},
		{
			type = "go",
			name = "Debug file",
			request = "launch",
			program = "${file}",
		},
		{
			type = "go",
			name = "Debug test",
			request = "launch",
			mode = "test",
			program = "${fileDirname}",
		},
	}
	-- Lifecycle: по окончании сессии (terminate / program exit / disconnect —
	-- любой путь) закрываем stale DAP-floats (scopes/frames/hover показывают
	-- данные мёртвой сессии). Ownership явный: только filetype dap-float
	-- (наши виджеты). REPL (dap-repl) НЕ трогаем — там вывод/история,
	-- пользовательские окна — тем более. Повторный debug стартует чисто.
	local function close_dap_floats()
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			local ok_b, b = pcall(vim.api.nvim_win_get_buf, w)
			if ok_b and vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == "dap-float" then
				pcall(vim.api.nvim_win_close, w, true)
			end
		end
	end
	dap.listeners.after.event_terminated["dev_float_cleanup"] = close_dap_floats
	dap.listeners.after.event_exited["dev_float_cleanup"] = close_dap_floats
	-- Owned-dlv cleanup on session end: `dlv dap` в server-режиме после
	-- disconnect сам не всегда завершается — без этого каждый stop
	-- оставлял бы слушающий процесс до 90с-сторожа (и плодил бы их при
	-- start/stop-циклах). Гасим СВОИ хендлы с короткой задержкой (сессия
	-- уже мертва, 5с — на доставку событий), но только если не поднялась
	-- новая сессия (быстрый retry/run_last её переживает).
	local function owned_cleanup_after_session()
		vim.defer_fn(function()
			local ok_s, dapmod = pcall(require, "dap")
			if ok_s and dapmod.session() ~= nil then
				return
			end
			kill_owned_dlv("")
		end, 5000)
	end
	dap.listeners.after.event_terminated["dev_owned_dlv_cleanup"] = owned_cleanup_after_session
	dap.listeners.after.event_exited["dev_owned_dlv_cleanup"] = owned_cleanup_after_session
	-- Editor exit with an active session: nvim-dap никого не гасит сам,
	-- :qa! оставлял бы живой `dlv dap`. VimLeavePre — только свои хендлы.
	if not M._leave_autocmd then
		M._leave_autocmd = true
		vim.api.nvim_create_autocmd("VimLeavePre", {
			desc = "debug: stop owned delve servers on editor exit",
			callback = function()
				kill_owned_dlv("editor exit")
			end,
		})
	end
	-- Canonicalize program paths (symlinked checkouts!): delve сравнивает
	-- program-dir с корнем модуля, и symlink-форма (/var → /private/var
	-- на macOS, /tmp, джанкшены) роняет сборку с криптичным
	-- "Failed to launch ... outside main module". Хук независим от порядка
	-- относительно встроенного expand_variable: если мы первые — раскрываем
	-- ${} сами сразу в canonical-форму, встроенному раскрывать нечего;
	-- если встроенный первый — добиваем canonicalize по готовому пути.
	-- Работает и для inline-конфигов dt (там program уже конкретный).
	dap.listeners.on_config["dev_realpath_program"] = function(config)
		if type(config.program) == "string" then
			local v = config.program
			v = v:gsub("%${fileDirname}", function()
				local d = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p:h")
				local ok_r, rp = pcall(vim.uv.fs_realpath, d)
				return (ok_r and rp) or d
			end)
			v = v:gsub("%${file}", function()
				local f = vim.api.nvim_buf_get_name(0)
				local ok_r, rp = pcall(vim.uv.fs_realpath, f)
				return (ok_r and rp) or f
			end)
			if not v:match("%${") and vim.uv.fs_stat(v) then
				local ok_r, rp = pcall(vim.uv.fs_realpath, v)
				if ok_r and rp then
					config.program = rp
				end
			else
				config.program = v
			end
		end
		return config
	end
	ensured = true
	return true, dap
end

--- Вызов dap-метода с гарантией загрузки. Не дебажишь — dap не грузится.
---@param fn fun(dap: any)
local function with(fn)
	return function()
		local ok, dap = M.ensure()
		if ok then
			fn(dap)
		end
	end
end

--- Виджетам (scopes/frames/hover) без активной сессии нечего показывать:
--- вместо пустого/битого float — честный нотифай. Иначе повторный debug
--- после terminate требует ручной уборки (противоречит lifecycle).
---@param dap any
---@return boolean
local function need_session(dap)
	if dap.session() then
		return true
	end
	vim.notify("[debug] no active session — start with <leader>dc", vim.log.levels.INFO, { title = "debug" })
	return false
end

function M.setup_keymaps()
	local map = vim.keymap.set
	local function dapmap(lhs, method_or_fn, desc)
		map("n", lhs, with(function(dap)
			if type(method_or_fn) == "string" then
				dap[method_or_fn]()
			else
				method_or_fn(dap)
			end
		end), { noremap = true, silent = true, desc = desc })
	end
	dapmap("<leader>db", "toggle_breakpoint", "debug: Toggle breakpoint")
	dapmap("<leader>dB", function(dap)
		vim.ui.input({ prompt = "Breakpoint condition: " }, function(cond)
			if cond and cond ~= "" then
				-- nvim-dap API — позиционные строки, НЕ таблица:
				-- set_breakpoint(condition?, hit?, log?). Таблица роняет
				-- assert внутри toggle_breakpoint (E5108).
				dap.set_breakpoint(cond)
			end
		end)
	end, "debug: Conditional breakpoint")
	dapmap("<leader>dc", "continue", "debug: Continue / start")
	dapmap("<leader>dn", "step_over", "debug: Step over (next)")
	dapmap("<leader>di", "step_into", "debug: Step into")
	dapmap("<leader>do", "step_out", "debug: Step out")
	dapmap("<leader>dx", function(dap)
		-- Только terminate, БЕЗ dap.close(): close() синхронно сносит объект
		-- сессии, и ответ/ terminated-exited событиям некуда диспетчериться —
		-- гаснут и наши слушатели очистки, и чужие. terminate сам доводит
		-- сессию до конца (события → cleanup → закрытие).
		dap.terminate()
	end, "debug: Terminate")
	dapmap("<leader>dl", "run_last", "debug: Run last")
	dapmap("<leader>dr", function(dap)
		dap.repl.toggle({ height = 12 })
		-- repl.toggle НЕ переносит фокус: пользователь печатает в код.
		-- После открытия (окно dap-repl есть) — фокус туда + insert;
		-- после закрытия (окна нет) — no-op, фокус и так в коде.
		vim.schedule(function()
			for _, w in ipairs(vim.api.nvim_list_wins()) do
				local b = vim.api.nvim_win_get_buf(w)
				if vim.bo[b].filetype == "dap-repl" then
					vim.api.nvim_set_current_win(w)
					vim.cmd("startinsert")
					return
				end
			end
		end)
	end, "debug: Toggle REPL")
	dapmap("<leader>de", function(dap)
		if not need_session(dap) then
			return
		end
		require("dap.ui.widgets").hover()
	end, "debug: Evaluate under cursor")
	dapmap("<leader>dw", function(dap)
		if not need_session(dap) then
			return
		end
		local widgets = require("dap.ui.widgets")
		widgets.centered_float(widgets.scopes)
	end, "debug: Scopes/variables")
	dapmap("<leader>df", function(dap)
		if not need_session(dap) then
			return
		end
		local widgets = require("dap.ui.widgets")
		widgets.centered_float(widgets.frames)
	end, "debug: Stack frames")
	dapmap("<leader>dt", function(dap)
		-- Debug nearest test: та же точка входа, что dev.test.nearest_test.
		-- Fallback-семантика — как у gt: TestMain/suite-метод напрямую
		-- не дебажатся, вместо молчаливого "ничего не матчится" — пакет
		-- с явным объяснением.
		local ok_t, tst = pcall(require, "dev.test")
		local name, is_method = ok_t and tst.nearest_test() or nil
		if not name then
			vim.notify("[debug] no Test func above cursor", vim.log.levels.WARN, { title = "debug" })
			return
		end
		local args = { "-test.run", "^" .. name .. "$" }
		local label = name
		if name == "TestMain" or is_method then
			args = {}
			label = label .. " (whole package)"
			vim.notify("[debug] " .. name .. " can't run alone — debugging whole package instead", vim.log.levels.INFO, { title = "debug" })
		end
		dap.run({
			type = "go",
			name = "Debug " .. label,
			request = "launch",
			mode = "test",
			program = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p:h"),
			args = args,
		})
	end, "debug: Debug test under cursor")
end

return M
