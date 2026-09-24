return function()
	local ok_lint, lint = pcall(require, "lint")
	if not ok_lint then
		vim.notify("[lint] nvim-lint unavailable, go lint disabled", vim.log.levels.WARN, { title = "lint" })
		return
	end

	lint.linters_by_ft = {
		go = { "golangcilint" },
	}

	-- PERF: ленивая загрузка golangcilint линтера только при первом запуске.
	-- Это избегает 150ms require('lint.linters.golangcilint') при открытии файла.
	local golangcilint_loaded = false
	local original_try_lint = lint.try_lint
	-- unpack: LuaJIT имеет только глобальный unpack, table.unpack может не быть.
	local t_unpack = table.unpack or unpack
	lint.try_lint = function(...)
		local args = { ... }
		if not golangcilint_loaded and vim.fn.executable("golangci-lint") == 1 then
			-- Загружаем конфиг линтера асинхронно при первом вызове
			vim.schedule(function()
				lint.linters.golangcilint.ignore_exitcode = true
				golangcilint_loaded = true
				original_try_lint(t_unpack(args))
			end)
			return
		end
		return original_try_lint(t_unpack(args))
	end

	-- Без mason: golangci-lint ставится системно (go install / brew).
	-- Нет бинарника — нет линта, молча.
	if vim.fn.executable("golangci-lint") ~= 1 then
		vim.notify(
			"[lint] golangci-lint not found in $PATH, go lint disabled",
			vim.log.levels.WARN,
			{ title = "lint" }
		)
		return
	end

	-- PERF: линт только по сохранению. BufEnter/InsertLeave устраивали
	-- 1-2 конкурентных golangci-lint на каждое открытие (включая stdlib).
	-- Один таймер вместо очереди: частые сейвы не плодят процессы.
	local lint_timer = vim.uv.new_timer()
	local lint_group = vim.api.nvim_create_augroup("GoLintOnSave", { clear = true })
	vim.api.nvim_create_autocmd({ "BufWritePost" }, {
		group = lint_group,
		pattern = { "*.go", "*.mod", "*.tmpl" },
		callback = function(a)
			if vim.b[a.buf].large_file then
				return
			end
			local f = vim.api.nvim_buf_get_name(a.buf)
			if f:match("go/pkg/mod") or f:match("Program Files\\Go") or f:match("/go/src/") then
				return
			end
			if vim.fn.executable("golangci-lint") ~= 1 then
				return
			end
			if lint_timer then
				lint_timer:stop()
				lint_timer:start(
					1000,
					0,
					vim.schedule_wrap(function()
						-- try_lint работает только с текущим буфером: если за секунду
						-- дебаунса юзер ушёл — скипаем, а не линтуем чужой буфер.
						if vim.api.nvim_buf_is_valid(a.buf) and vim.api.nvim_get_current_buf() == a.buf then
							lint.try_lint()
						end
					end)
				)
			end
		end,
	})
end
