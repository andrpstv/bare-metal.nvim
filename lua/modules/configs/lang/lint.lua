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

	vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "InsertLeave" }, {
		pattern = { "*.go", "*.mod", "*.tmpl" },
		callback = function()
			lint.try_lint()
		end,
	})
end
