return function()
	local lint = require("lint")

	lint.linters_by_ft = {
		go = { "golangcilint" },
	}

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

	lint.linters.golangcilint.ignore_exitcode = true

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
