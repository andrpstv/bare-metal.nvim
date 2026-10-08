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
	dap.adapters.go = function(callback)
		local stdout = vim.uv.new_pipe(false)
		local stderr = vim.uv.new_pipe(false)
		local handle
		local port = 38697
		handle = vim.uv.spawn("dlv", {
			stdio = { nil, stdout, stderr },
			args = { "dap", "-l", "127.0.0.1:" .. port },
			detached = true,
		}, function(code)
			if handle then
				stdout:close()
				stderr:close()
				handle:close()
			end
			if code ~= 0 then
				vim.schedule(function()
					vim.notify("[debug] dlv exited with code " .. code, vim.log.levels.ERROR, { title = "debug" })
				end)
			end
		end)
		vim.defer_fn(function()
			callback({ type = "server", host = "127.0.0.1", port = port })
		end, 100)
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
		local ok_t, tst = pcall(require, "dev.test")
		local name = ok_t and tst.nearest_test() or nil
		if not name then
			vim.notify("[debug] no Test func above cursor", vim.log.levels.WARN, { title = "debug" })
			return
		end
		dap.run({
			type = "go",
			name = "Debug " .. name,
			request = "launch",
			mode = "test",
			program = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p:h"),
			args = { "-test.run", "^" .. name .. "$" },
		})
	end, "debug: Debug test under cursor")
end

return M
