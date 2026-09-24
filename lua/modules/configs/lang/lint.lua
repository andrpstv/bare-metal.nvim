return function()
	local lint = require("lint")

	lint.linters_by_ft = {
		go = { "golangcilint" },
	}

	-- PERF: ленивая загрузка golangcilint линтера только при первом запуске.
	-- Это избегает 150ms require('lint.linters.golangcilint') при открытии файла.
	local golangcilint_loaded = false
	local original_try_lint = lint.try_lint
	lint.try_lint = function(...)
		local args = { ... }
		if not golangcilint_loaded and vim.fn.executable("golangci-lint") == 1 then
			-- Загружаем конфиг линтера асинхронно при первом вызове
			vim.schedule(function()
				lint.linters.golangcilint.ignore_exitcode = true
				golangcilint_loaded = true
				original_try_lint(unpack(args))
			end)
			return
		end
		return original_try_lint(unpack(args))
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
	vim.api.nvim_create_autocmd({ "BufWritePost" }, {
		pattern = { "*.go", "*.mod", "*.tmpl" },
		callback = function(a)
			local f = vim.api.nvim_buf_get_name(a.buf)
			if f:match("go/pkg/mod") or f:match("Program Files\\Go") or f:match("/go/src/") then
				return
			end
			lint.try_lint()
		end,
	})
end
